"""Reporter: weekday 18:00 MYT daily Business Sync report.

Reads only S3 (per-run summary.json / changes.csv) and the two DLQ depths. Never calls Ebteqdesk.
Writes business-sync/daily-reports/<YYYY>/<MM>/<DD>/{report.json,runs.csv,new-businesses.csv}
(overwritten on re-run), then sends one Telegram message with the CSVs attached.

Invoke manually / backfill with {"report_date": "YYYY-MM-DD"}.
"""

import json
import os
import re
from datetime import date

import boto3

import report
import telegram_client
from handler import BRAND_NAMES

RUN_KEY_RE = re.compile(r"^business-sync/[^/]+/\d{4}/\d{2}/\d{2}/(?P<run>[^/]+)/attempt-(?P<attempt>\d+)/(?P<file>[^/]+)$")
RUNS_CSV_COLUMNS = ["portal", "run_id", "scheduled_time_myt", "attempts", "outcome", "seen", "created",
                    "updated", "unchanged", "failed", "duration_s", "error"]
NEW_BUSINESS_COLUMNS = ["portal", "id", "name", "first_seen_run"]
STATUS_EMOJI = {"green": "🟢", "yellow": "🟡", "red": "🔴", "disabled": "⚪"}
MAX_FAILURE_LINES = 10
MAX_NAMES_IN_MESSAGE = 5


def log(level, message, **fields):
    print(json.dumps({"level": level, "message": message, **fields}, ensure_ascii=False, default=str))


def _config():
    return {
        "bucket": os.environ["REPORT_BUCKET"],
        "service": os.environ.get("SERVICE_NAME", "ebteqdesk-business-sync"),
        "allowed_portals": [p.strip() for p in os.environ.get("ALLOWED_PORTALS", "").split(",") if p.strip()],
        "portals": json.loads(os.environ.get("PORTALS_JSON", "{}")),
        "sync_dlq_url": os.environ.get("SYNC_DLQ_URL", ""),
        "scheduler_dlq_url": os.environ.get("SCHEDULER_DLQ_URL", ""),
        "telegram_secret_arn": os.environ.get("TELEGRAM_SECRET_ARN", ""),
    }


def report_date(event):
    """report_date (backfill) > MYT date of scheduled_time > today MYT."""
    if event.get("report_date"):
        return date.fromisoformat(str(event["report_date"]))
    scheduled = report.parse_iso(event.get("scheduled_time"))
    return report.to_myt(scheduled or report.utcnow()).date()


# ---------------------------------------------------------------- S3 reads


def _list_keys(s3, bucket, prefix):
    keys = []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix):
        keys.extend(obj["Key"] for obj in page.get("Contents", []))
    return keys


def _read(s3, bucket, key):
    return s3.get_object(Bucket=bucket, Key=key)["Body"].read()


def collect_runs(s3, bucket, portal, day):
    """Return the final (highest-attempt) result of each run, oldest first."""
    prefix = f"{report.PREFIX}/{portal}/{report.date_path(day)}/"
    attempts = {}  # run -> {attempt: set(files)}
    for key in _list_keys(s3, bucket, prefix):
        m = RUN_KEY_RE.match(key)
        if m:
            attempts.setdefault(m["run"], {}).setdefault(int(m["attempt"]), set()).add(m["file"])
    runs = []
    for run in sorted(attempts):
        with_summary = [n for n, files in attempts[run].items() if "summary.json" in files]
        if not with_summary:
            log("WARNING", "run folder without summary.json skipped", portal=portal, run=run)
            continue
        attempt = max(with_summary)
        base = report.attempt_prefix(portal, day, run, attempt)
        summary = json.loads(_read(s3, bucket, base + "summary.json").decode("utf-8"))
        changes = []
        if "changes.csv" in attempts[run][attempt]:
            changes = report.read_csv_bytes(_read(s3, bucket, base + "changes.csv"))
        runs.append({"run": run, "attempt": attempt, "summary": summary, "changes": changes})
    return runs


def dlq_depth(sqs, url):
    if not url:
        return None
    try:
        attrs = sqs.get_queue_attributes(QueueUrl=url, AttributeNames=["ApproximateNumberOfMessagesVisible"])
        return int(attrs["Attributes"]["ApproximateNumberOfMessagesVisible"])
    except Exception as exc:  # noqa: BLE001 - shown as "?" in the report
        log("ERROR", "could not read DLQ depth", queue_url=url, error=str(exc))
        return None


# ---------------------------------------------------------------- figures


def _myt_hhmm(value):
    dt = report.parse_iso(value)
    return report.to_myt(dt).strftime("%H:%M") if dt else None


def _duration_s(summary):
    remote = summary.get("remote_run") or {}
    started, finished = report.parse_iso(remote.get("started_at")), report.parse_iso(remote.get("finished_at"))
    if started and finished:
        return round((finished - started).total_seconds(), 1)
    return round((summary.get("lambda_duration_ms") or 0) / 1000, 1)


def brand_status(enabled, expected, recorded, succeeded, last_ok):
    if not enabled:
        return "disabled"
    if succeeded == 0 or not last_ok:
        return "red"
    if succeeded == recorded and recorded >= expected - 1:
        return "green"
    return "yellow"


def summarise_brand(portal, cfg_portal, runs):
    enabled = bool(cfg_portal.get("enabled", False))
    expected = int(cfg_portal.get("expected_runs_per_day", 0))
    ok_runs = [r for r in runs if r["summary"].get("outcome") == "success"]
    last = runs[-1]["summary"] if runs else None

    new_businesses, created_seen, updated_ids = [], set(), set()
    for r in runs:
        for row in r["changes"]:
            if row.get("action") == "created" and row.get("id") not in created_seen:
                created_seen.add(row.get("id"))
                new_businesses.append({"portal": portal, "id": row.get("id"), "name": row.get("name", ""),
                                       "first_seen_run": r["run"]})
            elif row.get("action") == "updated":
                updated_ids.add(row.get("id"))

    run_rows = []
    for r in runs:
        s, counts = r["summary"], r["summary"].get("counts") or {}
        sched = report.parse_iso(s.get("scheduled_time"))
        run_rows.append({
            "portal": portal, "run_id": r["run"],
            "scheduled_time_myt": report.to_myt(sched).strftime("%Y-%m-%d %H:%M") if sched else "",
            "attempts": r["attempt"], "outcome": s.get("outcome", ""),
            **{k: counts.get(k, 0) for k in ("seen", "created", "updated", "unchanged", "failed")},
            "duration_s": _duration_s(s), "error": s.get("error") or "",
        })

    status = brand_status(enabled, expected, len(runs), len(ok_runs), bool(last and last.get("outcome") == "success"))
    return {
        "portal": portal,
        "brand": BRAND_NAMES.get(portal, portal),
        "enabled": enabled,
        "status": status,
        "status_emoji": STATUS_EMOJI[status],
        "expected_runs": expected,
        "runs_recorded": len(runs),
        "succeeded": len(ok_runs),
        "failed": len(runs) - len(ok_runs),
        "first_success_myt": _myt_hhmm(ok_runs[0]["summary"].get("generated_at")) if ok_runs else None,
        "last_success_myt": _myt_hhmm(ok_runs[-1]["summary"].get("generated_at")) if ok_runs else None,
        "new_businesses": new_businesses,
        "updated_businesses": len(updated_ids),
        "latest_record_failures": int((last or {}).get("counts", {}).get("failed", 0)),
        "latest_failure_lines": list((last or {}).get("failure_lines") or [])[:MAX_FAILURE_LINES],
        "runs": run_rows,
    }


# ---------------------------------------------------------------- message


def build_message(day, brands, dlq, report_uri):
    alarm = any(b["enabled"] and b["status"] == "red" for b in brands)
    head = f"{'🚨 ' if alarm else ''}📊 Business Sync 日报 {day.isoformat()}（{'一二三四五六日'[day.weekday()]}）"
    lines = [head]
    for b in brands:
        if not b["enabled"]:
            lines.append(f"{b['status_emoji']} {b['brand']}：已停用 disabled（今天 {b['runs_recorded']} 次手动 run）")
            continue
        names = "、".join(n["name"] or f"#{n['id']}" for n in b["new_businesses"][:MAX_NAMES_IN_MESSAGE])
        more = "…" if len(b["new_businesses"]) > MAX_NAMES_IN_MESSAGE else ""
        line = (f"{b['status_emoji']} {b['brand']}：成功 {b['succeeded']}/{b['expected_runs']} · 失败 {b['failed']}"
                f" · 新 business {len(b['new_businesses'])}{f'（{names}{more}）' if names else ''}"
                f" · 更新 {b['updated_businesses']} · record 失败 {b['latest_record_failures']}")
        lines.append(line)
        if b["status"] == "red":
            lines.append("   ↳ 今天没有成功的 sync" if b["succeeded"] == 0 else "   ↳ 最后一次 run 失败")
        if b["last_success_myt"]:
            lines.append(f"   首次/最后成功 first/last success：{b['first_success_myt']} / {b['last_success_myt']}")
    fmt = lambda v: "?" if v is None else str(v)  # noqa: E731
    lines.append(f"DLQ：sync {fmt(dlq['sync'])} · scheduler {fmt(dlq['scheduler'])}")
    lines.append(f"报告 report：{report_uri}")
    return "\n".join(lines), alarm


# ---------------------------------------------------------------- handler


def lambda_handler(event, context):
    cfg = _config()
    event = event or {}
    day = report_date(event)
    s3, sqs = boto3.client("s3"), boto3.client("sqs")

    brands = [summarise_brand(p, cfg["portals"].get(p, {}), collect_runs(s3, cfg["bucket"], p, day))
              for p in cfg["allowed_portals"]]
    dlq = {"sync": dlq_depth(sqs, cfg["sync_dlq_url"]), "scheduler": dlq_depth(sqs, cfg["scheduler_dlq_url"])}
    runs_rows = [row for b in brands for row in b["runs"]]
    new_rows = [row for b in brands for row in b["new_businesses"]]

    prefix = report.daily_report_prefix(day)
    report_uri = f"s3://{cfg['bucket']}/{prefix}"
    text, alarm = build_message(day, brands, dlq, report_uri)
    doc = {"report_date": day.isoformat(), "generated_at": report.iso(report.utcnow()), "alarm": alarm,
           "dlq_depth": dlq, "brands": brands}

    # S3 first (idempotent overwrite), so the report survives a Telegram outage.
    runs_csv = report.csv_bytes(RUNS_CSV_COLUMNS, runs_rows)
    new_csv = report.csv_bytes(NEW_BUSINESS_COLUMNS, new_rows)
    report.put_object(s3, cfg["bucket"], prefix + "report.json", report.to_json_bytes(doc), "application/json")
    report.put_object(s3, cfg["bucket"], prefix + "runs.csv", runs_csv, "text/csv")
    report.put_object(s3, cfg["bucket"], prefix + "new-businesses.csv", new_csv, "text/csv")

    report.emit_metrics(cfg["service"], {"ReportGenerated": 1})
    for b in brands:
        report.emit_metrics(cfg["service"], {"DailySyncSuccesses": b["succeeded"], "DailySyncFailures": b["failed"],
                                             "NewBusinesses": len(b["new_businesses"])}, portal=b["portal"])

    # Telegram errors propagate: the Lambda async retry (max 2) re-runs the whole report, then the report DLQ.
    creds = telegram_client.load_credentials(cfg["telegram_secret_arn"])
    telegram_client.send_message(creds, text)
    telegram_client.send_document(creds, f"runs-{day.isoformat()}.csv", runs_csv, caption="runs.csv")
    if new_rows:
        telegram_client.send_document(creds, f"new-businesses-{day.isoformat()}.csv", new_csv,
                                      caption="new-businesses.csv")
    log("INFO", "daily report sent", report_date=day.isoformat(), alarm=alarm)
    return {"report_date": day.isoformat(), "alarm": alarm, "report_prefix": report_uri}
