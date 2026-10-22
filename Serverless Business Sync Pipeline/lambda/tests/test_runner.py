import json

import pytest
from conftest import FakeContext

import handler
import report

OUTPUT_OK = "\n".join([
    "Syncing business directory for salonv3",
    "created #501 Glow Beauty KL — name, phone",
    "updated #77 Hair Lab — phone",
    "seen: 120 | created: 1 | updated: 1 | unchanged: 118 | failed: 0",
])
OUTPUT_FAILED = "\n".join([
    "Syncing business directory for salonv3",
    "failed #88 Broken Salon — POS returned 500",
    "seen: 120 | created: 0 | updated: 0 | unchanged: 119 | failed: 1",
])


def run(status, output=None, run_id=41, trigger_id="sched-x"):
    body = {"id": run_id, "status": status, "trigger_id": trigger_id, "exit_code": None,
            "accepted_at": "2026-09-28T01:00:01Z", "started_at": "2026-09-28T01:00:02Z", "finished_at": None}
    if status in ("succeeded", "failed"):
        body.update(exit_code=0 if status == "succeeded" else 1, finished_at="2026-09-28T01:00:40Z",
                    output=output or "", error=None if status == "succeeded" else "command exited 1")
    return body


def sqs_record(portal="salonv3", scheduled="2026-09-28T01:00:00Z", attempt=1, message_id="m-1"):
    body = {"trigger": "eventbridge-scheduler", "portal": portal, "scheduled_time": scheduled,
            "execution_id": "e-1", "scheduler_attempt": "0"}
    return {"messageId": message_id, "body": json.dumps(body),
            "attributes": {"ApproximateReceiveCount": str(attempt), "SentTimestamp": "1790000000000"}}


def invoke(record, context=None):
    return handler.lambda_handler({"Records": [record]}, context or FakeContext())


def latest(aws, portal="salonv3"):
    return aws.json(report.latest_key(portal))


# ---------------------------------------------------------------- success path


def test_success_writes_report_and_no_telegram(aws, stub):
    stub.trigger_response = (202, run("queued"))
    stub.run_sequence = [run("running"), run("succeeded", OUTPUT_OK)]
    result = invoke(sqs_record())
    assert result["results"][0]["outcome"] == "success"
    assert stub.posts[0]["trigger_id"] == "sched-2026-09-28T01:00:00Z"
    assert stub.posts[0]["auth"] == "Bearer t0ken"
    keys = aws.keys("business-sync/salonv3/2026/09/28/")
    run_folder = keys[0].split("/")[5]
    assert run_folder.startswith("090000-")  # 01:00Z = 09:00 MYT
    assert {k.rsplit("/", 1)[1] for k in keys} == {"summary.json", "changes.csv", "output.log"}
    summary = aws.json(next(k for k in keys if k.endswith("summary.json")))
    assert summary["counts"] == {"seen": 120, "created": 1, "updated": 1, "unchanged": 118, "failed": 0}
    assert summary["outcome"] == "success" and summary["final_attempt"] is False
    assert stub.messages == []
    assert aws.keys("business-sync/failures/") == []
    assert latest(aws)["consecutive_failures"] == 0


def test_adopts_any_active_run_returned_with_200(aws, stub):
    # Ebteqdesk returns another trigger's active run instead of starting a second sweep.
    stub.trigger_response = (200, run("running", run_id=7, trigger_id="manual-other"))
    stub.run_sequence = [run("succeeded", OUTPUT_OK, run_id=7, trigger_id="manual-other")]
    result = invoke(sqs_record())
    assert result["results"][0]["outcome"] == "success"
    assert len(stub.posts) == 1
    summary = aws.json(next(k for k in aws.keys("business-sync/salonv3/2026/") if k.endswith("summary.json")))
    assert summary["adopted_active_run"] is True
    assert summary["remote_run"]["id"] == 7


# ---------------------------------------------------------------- failure / retry


def test_no_alert_on_non_final_failure(aws, stub):
    stub.trigger_response = (202, run("queued"))
    stub.run_sequence = [run("failed", OUTPUT_FAILED)]
    with pytest.raises(handler.SyncAttemptFailed):
        invoke(sqs_record(attempt=1))
    assert stub.messages == [] and stub.documents == []
    assert len(aws.keys("business-sync/failures/salonv3/2026/09/28/")) == 1  # record for every failed attempt
    assert latest(aws)["consecutive_failures"] == 0  # streak only moves on the final attempt


def test_alert_on_first_and_third_consecutive_final_failure_not_second(aws, stub):
    stub.trigger_response = (202, run("queued"))
    stub.run_sequence = [run("failed", OUTPUT_FAILED)]
    sent_after = []
    for hour in (1, 2, 3):
        with pytest.raises(handler.SyncAttemptFailed):
            invoke(sqs_record(scheduled=f"2026-09-28T0{hour}:00:00Z", attempt=2))
        sent_after.append(len(stub.messages))
        assert latest(aws)["consecutive_failures"] == hour
    assert sent_after == [1, 1, 2]
    assert "streak: 1 次" in stub.messages[0]
    assert "streak: 3 次" in stub.messages[1]
    assert "Broken Salon" in stub.messages[0]
    # output.log attached on every alert that has output
    assert len(stub.documents) == 2
    assert stub.documents[0][0].endswith("output.log")
    assert b"failed: 1" in stub.documents[0][1]


def test_recovery_message_and_streak_persisted(aws, stub):
    stub.trigger_response = (202, run("queued"))
    stub.run_sequence = [run("failed", OUTPUT_FAILED)]
    for hour in (1, 2):
        with pytest.raises(handler.SyncAttemptFailed):
            invoke(sqs_record(scheduled=f"2026-09-28T0{hour}:00:00Z", attempt=2))
    state = latest(aws)
    assert state["consecutive_failures"] == 2
    assert state["failing_since"] is not None and state["last_success_at"] is None

    stub.gets = 0
    stub.run_sequence = [run("succeeded", OUTPUT_OK)]
    invoke(sqs_record(scheduled="2026-09-28T03:00:00Z", attempt=1))
    assert stub.messages[-1].startswith("✅ Salon V3 已恢复")
    assert "连续失败 2 次" in stub.messages[-1]
    state = latest(aws)
    assert state["consecutive_failures"] == 0
    assert state["failing_since"] is None
    assert state["last_success_at"] is not None


def test_still_running_non_final_raises_without_telegram(aws, stub):
    stub.trigger_response = (202, run("running"))
    stub.run_sequence = [run("running")]
    with pytest.raises(handler.SyncAttemptFailed):
        invoke(sqs_record(attempt=1), FakeContext(remaining_ms=100_000, step_ms=30_000))
    assert stub.messages == []
    summary = aws.json(next(k for k in aws.keys("business-sync/salonv3/2026/") if k.endswith("summary.json")))
    assert summary["outcome"] == "still_running"


def test_still_running_on_final_attempt_counts_as_failure(aws, stub):
    stub.trigger_response = (200, run("running"))
    stub.run_sequence = [run("running")]
    with pytest.raises(handler.SyncAttemptFailed):
        invoke(sqs_record(attempt=2), FakeContext(remaining_ms=100_000, step_ms=30_000))
    assert latest(aws)["consecutive_failures"] == 1
    assert len(stub.messages) == 1 and "still_running" in stub.messages[0]


def test_html_200_is_never_success(aws, stub):
    stub.trigger_response = (200, "text/html", b"<html>challenge</html>")
    with pytest.raises(handler.SyncAttemptFailed):
        invoke(sqs_record(attempt=2))
    assert "firewall" in stub.messages[0]
    assert "api_error" in stub.messages[0]


def test_401_is_reported(aws, stub):
    stub.trigger_response = (401, {"message": "Unauthenticated."})
    with pytest.raises(handler.SyncAttemptFailed):
        invoke(sqs_record(attempt=2))
    assert "401" in stub.messages[0]


def test_invalid_portal_alerts_immediately_and_is_dropped(aws, stub):
    result = invoke(sqs_record(portal="hacker", attempt=1))
    assert result["results"][0]["outcome"] == "invalid_portal"
    assert len(stub.messages) == 1 and "白名单" in stub.messages[0]
    assert stub.posts == []
    assert aws.keys("business-sync/failures/hacker/")


def test_telegram_down_on_final_failure_still_raises(aws, stub):
    stub.trigger_response = (202, run("queued"))
    stub.run_sequence = [run("failed", OUTPUT_FAILED)]
    stub.telegram_fail = True
    with pytest.raises(handler.SyncAttemptFailed):
        invoke(sqs_record(attempt=2))
    assert latest(aws)["consecutive_failures"] == 1


def test_manual_message_without_scheduled_time_uses_message_id(aws, stub):
    stub.trigger_response = (202, run("queued"))
    stub.run_sequence = [run("succeeded", OUTPUT_OK)]
    record = {"messageId": "abc-123", "body": json.dumps({"trigger": "manual", "portal": "warni"}),
              "attributes": {"ApproximateReceiveCount": "1", "SentTimestamp": "1790000000000"}}
    invoke(record)
    assert stub.posts[0]["trigger_id"] == "manual-abc-123"
    assert stub.posts[0]["path"].endswith("/warni")


def test_should_alert_rule():
    assert [n for n in range(1, 10) if handler.should_alert(n, 3)] == [1, 3, 6, 9]
