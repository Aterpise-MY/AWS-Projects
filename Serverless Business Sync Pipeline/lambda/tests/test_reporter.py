from datetime import date

import pytest
from conftest import BUCKET, SYNC_DLQ

import report
import reporter

DAY = date(2026, 9, 28)


def seed_attempt(aws, portal, run, attempt, outcome, day=DAY, created=(), updated=(), failed=0,
                 generated_at="2026-09-28T01:01:00Z", scheduled="2026-09-28T01:00:00Z", failure_lines=()):
    prefix = report.attempt_prefix(portal, day, run, attempt)
    summary = {
        "portal": portal, "run_id": run, "attempt": attempt, "max_attempts": 2, "final_attempt": attempt == 2,
        "outcome": outcome, "scheduled_time": scheduled,
        "counts": {"seen": 100, "created": len(created), "updated": len(updated),
                   "unchanged": 100 - len(created) - len(updated), "failed": failed},
        "remote_run": {"started_at": "2026-09-28T01:00:02Z", "finished_at": "2026-09-28T01:00:32Z"},
        "changes_count": len(created) + len(updated), "failure_lines": list(failure_lines),
        "error": None if outcome == "success" else f"{outcome}!", "lambda_duration_ms": 31000,
        "generated_at": generated_at,
    }
    aws.objects[(BUCKET, prefix + "summary.json")] = report.to_json_bytes(summary)
    rows = [{"run_id": run, "portal": portal, "action": "created", "id": i, "name": n, "changed_columns": ""}
            for i, n in created]
    rows += [{"run_id": run, "portal": portal, "action": "updated", "id": i, "name": n, "changed_columns": "phone"}
             for i, n in updated]
    if rows:
        aws.objects[(BUCKET, prefix + "changes.csv")] = report.csv_bytes(report.CHANGES_CSV_COLUMNS, rows)


def daily(aws, name, day=DAY):
    return aws.objects[(BUCKET, report.daily_report_prefix(day) + name)]


def brand(doc, portal):
    return next(b for b in doc["brands"] if b["portal"] == portal)


def full_green_day(aws, portal="salonv3", n=9):
    for h in range(n):
        seed_attempt(aws, portal, f"{9 + h:02d}0000-aaaa{h}", 1, "success",
                     generated_at=f"2026-09-28T{1 + h:02d}:01:00Z")


def test_mixed_day(aws, stub):
    # 09:00 success; 10:00 failed twice (retry); 11:00 still_running then success on retry.
    seed_attempt(aws, "salonv3", "090000-a", 1, "success", created=[("501", "Glow Beauty KL")],
                 generated_at="2026-09-28T01:01:00Z")
    seed_attempt(aws, "salonv3", "100000-b", 1, "failed", failed=1)
    seed_attempt(aws, "salonv3", "100000-b", 2, "failed", failed=1, failure_lines=["failed #88 Broken"])
    seed_attempt(aws, "salonv3", "110000-c", 1, "still_running")
    seed_attempt(aws, "salonv3", "110000-c", 2, "success", updated=[("77", "Hair Lab")],
                 generated_at="2026-09-28T03:16:00Z")
    aws.queue_depth[SYNC_DLQ] = 1

    result = reporter.lambda_handler({"trigger": "eventbridge-scheduler",
                                      "scheduled_time": "2026-09-28T10:00:00Z"}, None)
    assert result["report_date"] == "2026-09-28"
    doc = report.json.loads(daily(aws, "report.json"))
    s = brand(doc, "salonv3")
    assert (s["runs_recorded"], s["succeeded"], s["failed"]) == (3, 2, 1)
    assert s["status"] == "yellow"
    assert (s["first_success_myt"], s["last_success_myt"]) == ("09:01", "11:16")
    assert [n["id"] for n in s["new_businesses"]] == ["501"]
    assert s["updated_businesses"] == 1
    assert doc["dlq_depth"] == {"sync": 1, "scheduler": 0}

    runs = report.read_csv_bytes(daily(aws, "runs.csv"))
    assert [(r["run_id"], r["attempts"], r["outcome"]) for r in runs] == [
        ("090000-a", "1", "success"), ("100000-b", "2", "failed"), ("110000-c", "2", "success")]
    assert runs[0]["duration_s"] == "30.0"

    text = stub.messages[0]
    assert text.startswith("📊")  # yellow is not an alarm
    assert "🟡 Salon V3：成功 2/9 · 失败 1 · 新 business 1（Glow Beauty KL）" in text
    assert "DLQ：sync 1 · scheduler 0" in text
    assert [d[0] for d in stub.documents] == ["runs-2026-09-28.csv", "new-businesses-2026-09-28.csv"]


def test_empty_day_for_enabled_brand_is_red_with_siren(aws, stub):
    reporter.lambda_handler({"report_date": "2026-09-28"}, None)
    doc = report.json.loads(daily(aws, "report.json"))
    assert brand(doc, "salonv3")["status"] == "red"
    assert doc["alarm"] is True
    assert stub.messages[0].startswith("🚨")
    assert "今天没有成功的 sync" in stub.messages[0]
    # new-businesses.csv is written but not attached when empty
    assert [d[0] for d in stub.documents] == ["runs-2026-09-28.csv"]
    assert daily(aws, "new-businesses.csv").startswith(b"\xef\xbb\xbfportal,id,name,first_seen_run")


def test_last_run_failed_is_red(aws, stub):
    seed_attempt(aws, "salonv3", "090000-a", 1, "success")
    seed_attempt(aws, "salonv3", "100000-b", 2, "api_error")
    reporter.lambda_handler({"report_date": "2026-09-28"}, None)
    assert "最后一次 run 失败" in stub.messages[0]
    assert stub.messages[0].startswith("🚨")


def test_disabled_brand_is_white_and_no_siren(aws, stub):
    full_green_day(aws)
    reporter.lambda_handler({"report_date": "2026-09-28"}, None)
    doc = report.json.loads(daily(aws, "report.json"))
    assert brand(doc, "salonv3")["status"] == "green"
    assert brand(doc, "warni")["status"] == "disabled"
    assert doc["alarm"] is False
    assert not stub.messages[0].startswith("🚨")
    assert "🟢 Salon V3：成功 9/9" in stub.messages[0]
    assert "⚪ Warni：已停用 disabled" in stub.messages[0]


def test_one_missing_run_is_still_green(aws, stub):
    full_green_day(aws, n=8)  # expected 9, recorded 8 >= 9 - 1
    reporter.lambda_handler({"report_date": "2026-09-28"}, None)
    assert brand(report.json.loads(daily(aws, "report.json")), "salonv3")["status"] == "green"


def test_backfill_date(aws, stub):
    day = date(2026, 9, 25)
    seed_attempt(aws, "salonv3", "090000-a", 1, "success", day=day, generated_at="2026-09-25T01:01:00Z")
    result = reporter.lambda_handler({"report_date": "2026-09-25", "scheduled_time": "2026-09-28T10:00:00Z"}, None)
    assert result["report_date"] == "2026-09-25"
    assert brand(report.json.loads(daily(aws, "report.json", day)), "salonv3")["succeeded"] == 1
    assert "2026-09-25（五）" in stub.messages[0]
    # re-run overwrites (idempotent)
    reporter.lambda_handler({"report_date": "2026-09-25"}, None)
    assert len(aws.keys(report.daily_report_prefix(day))) == 3


@pytest.mark.parametrize("scheduled, expected", [
    ("2026-09-28T01:00:00Z", "2026-09-28"),  # 09:00 MYT on the 28th
    ("2026-09-27T16:30:00Z", "2026-09-28"),  # 00:30 MYT on the 28th
    ("2026-09-28T15:59:59Z", "2026-09-28"),  # 23:59:59 MYT
    ("2026-09-28T16:00:00Z", "2026-09-29"),  # midnight MYT
])
def test_myt_date_boundary(scheduled, expected):
    assert reporter.report_date({"scheduled_time": scheduled}).isoformat() == expected


def test_new_business_dedupe_across_runs(aws, stub):
    seed_attempt(aws, "salonv3", "090000-a", 1, "success", created=[("501", "Glow"), ("502", "Mane")])
    seed_attempt(aws, "salonv3", "100000-b", 1, "success", created=[("501", "Glow"), ("503", "Nail Bar")])
    reporter.lambda_handler({"report_date": "2026-09-28"}, None)
    rows = report.read_csv_bytes(daily(aws, "new-businesses.csv"))
    assert [(r["id"], r["first_seen_run"]) for r in rows] == [
        ("501", "090000-a"), ("502", "090000-a"), ("503", "100000-b")]
    assert "新 business 3（Glow、Mane、Nail Bar）" in stub.messages[0]


def test_telegram_down_report_still_written_and_raises(aws, stub):
    full_green_day(aws)
    stub.telegram_fail = True
    with pytest.raises(reporter.telegram_client.TelegramError):
        reporter.lambda_handler({"report_date": "2026-09-28"}, None)
    assert len(aws.keys(report.daily_report_prefix(DAY))) == 3


def test_emits_report_generated_metric(aws, stub, capsys):
    reporter.lambda_handler({"report_date": "2026-09-28"}, None)
    records = [report.json.loads(line) for line in capsys.readouterr().out.splitlines() if '"_aws"' in line]
    assert any(r.get("ReportGenerated") == 1 and r["_aws"]["CloudWatchMetrics"][0]["Dimensions"] == [["Service"]]
               for r in records)
    per_portal = {r["Portal"]: r for r in records if "Portal" in r}
    assert set(per_portal) == {"salonv3", "warni"}
    assert per_portal["salonv3"]["DailySyncSuccesses"] == 0
