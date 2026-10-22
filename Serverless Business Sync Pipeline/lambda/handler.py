"""Runner: SQS message -> Ebteqdesk trigger API -> poll -> S3 report -> streak-based Telegram alerts.

One SQS message = one scheduled sync of one brand. SQS delivers it at most
MAX_RECEIVE_COUNT times (default 2: one automatic retry ~15 min later), then the
message moves to the sync DLQ.

Alert policy (per brand, streak kept in business-sync/<portal>/latest.json):
  * non-final failed attempt  -> no Telegram; raise so SQS retries
  * final failed attempt      -> Telegram only when consecutive_failures == 1 or
                                 consecutive_failures % ALERT_EVERY_N_FAILURES == 0; raise (-> DLQ)
  * success after failures    -> Telegram "✅ <brand> 已恢复"
  * invalid portal / message  -> Telegram immediately, no retry (a retry cannot fix it)
A failure record is written to business-sync/failures/... for every failed attempt.
"""

import hashlib
import json
import os
import time
import traceback
from datetime import datetime, timezone

import boto3

import report
import telegram_client
from ebteqdesk_api import FINISHED_STATUSES, ApiError, EbteqdeskClient

BRAND_NAMES = {"salonv3": "Salon V3", "warni": "Warni"}
ZERO_COUNTS = {"seen": 0, "created": 0, "updated": 0, "unchanged": 0, "failed": 0}


class SyncAttemptFailed(Exception):
    """Raised so SQS redelivers the message (or moves it to the DLQ on the final attempt)."""


# ---------------------------------------------------------------- config


def _config():
    return {
        "bucket": os.environ["REPORT_BUCKET"],
        "service": os.environ.get("SERVICE_NAME", "ebteqdesk-business-sync"),
        "allowed_portals": [p.strip() for p in os.environ.get("ALLOWED_PORTALS", "").split(",") if p.strip()],
        "base_url": os.environ.get("EBTEQDESK_BASE_URL", ""),
        "ebteqdesk_secret_arn": os.environ.get("EBTEQDESK_SECRET_ARN", ""),
        "telegram_secret_arn": os.environ.get("TELEGRAM_SECRET_ARN", ""),
        "max_attempts": int(os.environ.get("MAX_RECEIVE_COUNT", "2")),
        "alert_every_n": max(1, int(os.environ.get("ALERT_EVERY_N_FAILURES", "3"))),
        "notify_on_success": os.environ.get("TELEGRAM_NOTIFY_ON_SUCCESS", "false").lower() == "true",
        "poll_interval": float(os.environ.get("POLL_INTERVAL_SECONDS", "10")),
        "poll_safety_ms": int(float(os.environ.get("POLL_SAFETY_SECONDS", "45")) * 1000),
    }


def brand(portal):
    return BRAND_NAMES.get(portal, portal)


def log(level, message, **fields):
    print(json.dumps({"level": level, "message": message, **fields}, ensure_ascii=False, default=str))


# ---------------------------------------------------------------- Telegram


def _notify(cfg, text, attachment=None):
    """Send a Telegram message (+ optional (filename, bytes) attachment). Returns True on success."""
    try:
        creds = telegram_client.load_credentials(cfg["telegram_secret_arn"])
        telegram_client.send_message(creds, text)
        if attachment and attachment[1]:
            telegram_client.send_document(creds, attachment[0], attachment[1], caption=attachment[0])
        return True
    except Exception as exc:  # noqa: BLE001 - every Telegram problem is logged loudly
        log("ERROR", "telegram notification failed", error=f"{type(exc).__name__}: {exc}")
        return False


# ---------------------------------------------------------------- streak state


def read_latest(s3, cfg, portal):
    try:
        obj = s3.get_object(Bucket=cfg["bucket"], Key=report.latest_key(portal))
        return json.loads(obj["Body"].read().decode("utf-8"))
    except Exception as exc:  # noqa: BLE001
        code = getattr(exc, "response", {}).get("Error", {}).get("Code", "")
        if code in ("NoSuchKey", "404"):
            return {}
        if code in ("AccessDenied", "403"):
            # The runner has no s3:ListBucket, so a missing key comes back as 403.
            log("WARNING", "latest.json not readable (missing on first run, or IAM drift)", portal=portal)
            return {}
        log("ERROR", "could not read latest.json; streak restarts from 0", portal=portal, error=str(exc))
        return {}


def next_streak(prev, outcome_ok, final, now):
    """Return the streak fields for latest.json after this attempt."""
    streak = {
        "consecutive_failures": int(prev.get("consecutive_failures", 0) or 0),
        "failing_since": prev.get("failing_since"),
        "last_success_at": prev.get("last_success_at"),
        "last_failure_at": prev.get("last_failure_at"),
    }
    if outcome_ok:
        streak.update(consecutive_failures=0, failing_since=None, last_success_at=report.iso(now))
    elif final:
        streak["consecutive_failures"] += 1
        streak["failing_since"] = streak["failing_since"] or report.iso(now)
        streak["last_failure_at"] = report.iso(now)
    return streak


def should_alert(consecutive_failures, every_n):
    return consecutive_failures == 1 or consecutive_failures % every_n == 0


# ---------------------------------------------------------------- message identity


def _identity(record, body):
    scheduled = report.parse_iso(body.get("scheduled_time"))
    if scheduled is None:
        # Manual message without scheduled_time: SentTimestamp is stable across retries.
        sent_ms = int(record.get("attributes", {}).get("SentTimestamp", "0") or 0)
        scheduled = datetime.fromtimestamp(sent_ms / 1000, tz=timezone.utc) if sent_ms else report.utcnow()
    if body.get("trigger_id"):
        trigger_id = str(body["trigger_id"])[:100]
    elif body.get("trigger") == "eventbridge-scheduler":
        # Same scheduled_time on every SQS retry -> same X-Trigger-Id.
        trigger_id = f"sched-{report.iso(scheduled)}"
    else:
        trigger_id = f"manual-{record.get('messageId', 'unknown')}"[:100]
    myt = report.to_myt(scheduled)
    run = f"{myt:%H%M%S}-{hashlib.sha1(trigger_id.encode()).hexdigest()[:8]}"
    return scheduled, trigger_id, myt.date(), run


# ---------------------------------------------------------------- sync


def _run_sync(cfg, portal, trigger_id, context):
    """Trigger (or adopt) a sweep and poll it. Returns (outcome, remote_run, error, adopted)."""
    try:
        secret = boto3.client("secretsmanager").get_secret_value(SecretId=cfg["ebteqdesk_secret_arn"])
        token = json.loads(secret["SecretString"]).get("token")
        if not token:
            return "api_error", {}, "Ebteqdesk secret 没有 token", False
        client = EbteqdeskClient(cfg["base_url"], token)
        http_status, run = client.trigger(portal, trigger_id)
        adopted = http_status == 200
        if adopted:
            log("INFO", "adopted already-active Ebteqdesk run", portal=portal, remote_run_id=run.get("id"),
                remote_trigger_id=run.get("trigger_id"))
        while run.get("status") not in FINISHED_STATUSES:
            if context.get_remaining_time_in_millis() < cfg["poll_safety_ms"]:
                return "still_running", run, "sweep 还没跑完（still_running），下一次尝试会接手同一个 run", adopted
            time.sleep(cfg["poll_interval"])
            run = client.get_run(run["id"])
        if run["status"] == "succeeded":
            return "success", run, None, adopted
        return "failed", run, run.get("error") or f"Ebteqdesk run failed (exit code {run.get('exit_code')})", adopted
    except ApiError as exc:
        return "api_error", {}, str(exc), False
    except Exception as exc:  # noqa: BLE001 - surfaced through the normal failure path
        return "api_error", {}, f"{type(exc).__name__}: {exc}", False


def _write(s3, cfg, key, body, content_type):
    try:
        report.put_object(s3, cfg["bucket"], key, body, content_type)
        return True
    except Exception as exc:  # noqa: BLE001
        log("ERROR", "S3 write failed", key=key, error=f"{type(exc).__name__}: {exc}")
        return False


def _counts_line(counts):
    return " | ".join(f"{k}: {counts.get(k, 0)}" for k in ZERO_COUNTS)


def _failure_message(summary, streak, cfg, failure_uri, now):
    since = (
        report.fmt_duration((now - report.parse_iso(streak["last_success_at"])).total_seconds())
        if streak.get("last_success_at")
        else "没有成功记录 / never"
    )
    lines = [
        f"❌ {brand(summary['portal'])} Business Sync 失败",
        f"尝试 attempt: {summary['attempt']}/{summary['max_attempts']}（最后一次，消息会进入 DLQ）",
        f"结果 outcome: {summary['outcome']}",
        f"错误 error: {summary.get('error') or '-'}",
        f"counts: {_counts_line(summary['counts'])}",
        f"连续失败 streak: {streak['consecutive_failures']} 次 · 距上次成功 since last success: {since}",
        f"提醒规则: 第 1 次，之后每 {cfg['alert_every_n']} 次提醒一次",
        f"失败记录: {failure_uri}",
        f"run: {summary['run_id']} · trigger: {summary['trigger_id']}",
    ]
    if summary["failure_lines"]:
        lines.append("失败行 failure lines:")
        lines.extend(f"• {line}" for line in summary["failure_lines"][:5])
    return "\n".join(lines)


def process_record(record, context):
    cfg = _config()
    s3 = boto3.client("s3")
    now = report.utcnow()
    started = time.monotonic()
    attempt = int(record.get("attributes", {}).get("ApproximateReceiveCount", "1"))
    final = attempt >= cfg["max_attempts"]

    try:
        body = json.loads(record.get("body") or "{}")
    except ValueError:
        body = None
    portal = (body or {}).get("portal", "")
    if body is None or portal not in cfg["allowed_portals"]:
        # A retry cannot fix a bad message: alert immediately, keep a record, drop it.
        scheduled, trigger_id, day, run = _identity(record, body or {})
        key = report.failure_key(portal or "invalid", day, run, attempt)
        _write(s3, cfg, key, report.to_json_bytes({"outcome": "invalid_portal", "body": record.get("body")}),
               "application/json")
        _notify(cfg, "\n".join([
            "❌ 无法执行 Business Sync：portal 不在白名单" if body is not None else "❌ 无法执行：SQS 消息不是 JSON",
            f"portal: {portal!r} · ALLOWED_PORTALS: {','.join(cfg['allowed_portals'])}",
            f"失败记录: s3://{cfg['bucket']}/{key}",
        ]))
        log("ERROR", "invalid message dropped", portal=portal, attempt=attempt)
        return {"outcome": "invalid_portal"}

    scheduled, trigger_id, day, run = _identity(record, body)
    outcome, remote_run, error, adopted = _run_sync(cfg, portal, trigger_id, context)
    output = remote_run.get("output") or ""
    counts = report.parse_counts(output) or dict(ZERO_COUNTS)
    changes = report.parse_changes(output)
    failure_lines = report.parse_failure_lines(output) if outcome != "success" or counts["failed"] else []
    ok = outcome == "success"

    summary = {
        "portal": portal,
        "run_id": run,
        "trigger_id": trigger_id,
        "scheduled_time": report.iso(scheduled),
        "attempt": attempt,
        "max_attempts": cfg["max_attempts"],
        "final_attempt": final,
        "outcome": outcome,
        "adopted_active_run": adopted,
        "counts": counts,
        "remote_run": {k: v for k, v in remote_run.items() if k != "output"},
        "changes_count": len(changes),
        "failure_lines": failure_lines,
        "error": error,
        "lambda_duration_ms": int((time.monotonic() - started) * 1000),
        "generated_at": report.iso(now),
    }
    prefix = report.attempt_prefix(portal, day, run, attempt)
    _write(s3, cfg, prefix + "summary.json", report.to_json_bytes(summary), "application/json")
    if changes:
        rows = [{"run_id": run, "portal": portal, **c} for c in changes]
        _write(s3, cfg, prefix + "changes.csv", report.csv_bytes(report.CHANGES_CSV_COLUMNS, rows), "text/csv")
    if output:
        _write(s3, cfg, prefix + "output.log", output.encode("utf-8"), "text/plain; charset=utf-8")

    failure_uri = None
    if not ok:
        fkey = report.failure_key(portal, day, run, attempt)
        _write(s3, cfg, fkey, report.to_json_bytes({**summary, "report_prefix": prefix}), "application/json")
        failure_uri = f"s3://{cfg['bucket']}/{fkey}"

    # Read the previous streak before overwriting latest.json.
    prev = read_latest(s3, cfg, portal)
    streak = next_streak(prev, ok, final, now)
    latest = {"portal": portal, "run_id": run, "attempt": attempt, "outcome": outcome,
              "report_prefix": f"s3://{cfg['bucket']}/{prefix}", "updated_at": report.iso(now), **streak}
    _write(s3, cfg, report.latest_key(portal), report.to_json_bytes(latest), "application/json")

    report.emit_metrics(cfg["service"], {
        "SyncSucceeded": 1 if ok else 0,
        "SyncFailed": 0 if ok else 1,
        "RecordsSeen": counts["seen"],
        "RecordsFailed": counts["failed"],
        "SyncDurationMs": summary["lambda_duration_ms"],
    }, portal=portal)

    if ok:
        prev_failures = int(prev.get("consecutive_failures", 0) or 0)
        if prev_failures:
            down_since = report.parse_iso(prev.get("failing_since")) or report.parse_iso(prev.get("last_success_at"))
            downtime = report.fmt_duration((now - down_since).total_seconds()) if down_since else "未知 / unknown"
            _notify(cfg, "\n".join([
                f"✅ {brand(portal)} 已恢复",
                f"之前连续失败 {prev_failures} 次 · 中断 downtime: {downtime}",
                f"counts: {_counts_line(counts)}",
                f"run: {run}",
            ]))
        elif cfg["notify_on_success"]:
            _notify(cfg, f"✅ {brand(portal)} Business Sync 成功\ncounts: {_counts_line(counts)}\nrun: {run}")
        log("INFO", "sync succeeded", portal=portal, run=run, attempt=attempt, counts=counts)
        return {"outcome": outcome, "run_id": run}

    if not final:
        # The next attempt (~15 min later) re-sends the same X-Trigger-Id and adopts a still-active run.
        log("WARNING", "sync attempt failed; SQS will retry", portal=portal, run=run, attempt=attempt,
            outcome=outcome, error=error)
        raise SyncAttemptFailed(f"{portal} attempt {attempt}/{cfg['max_attempts']} {outcome}: {error}")

    if should_alert(streak["consecutive_failures"], cfg["alert_every_n"]):
        _notify(cfg, _failure_message(summary, streak, cfg, failure_uri, now),
                attachment=(f"{portal}-{run}-attempt-{attempt}-output.log", output.encode("utf-8")) if output else None)
    else:
        log("WARNING", "final failure; Telegram suppressed by streak rule", portal=portal,
            consecutive_failures=streak["consecutive_failures"])
    raise SyncAttemptFailed(f"{portal} final attempt {attempt} {outcome}: {error}")


def lambda_handler(event, context):
    results = []
    for record in event.get("Records", []):
        try:
            results.append(process_record(record, context))
        except SyncAttemptFailed:
            raise
        except Exception:
            log("ERROR", "unhandled runner error", trace=traceback.format_exc())
            raise
    return {"results": results}
