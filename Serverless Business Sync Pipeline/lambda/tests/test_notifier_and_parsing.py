import json

import pytest

import ebteqdesk_api
import notifier
import report


def test_notifier_formats_alarm(aws, stub):
    alarm = {"AlarmName": "ebteqdesk-business-sync-sync-dlq-not-empty", "NewStateValue": "ALARM",
             "NewStateReason": "Threshold Crossed", "StateChangeTime": "2026-09-28T02:30:00Z",
             "AlarmDescription": "Sync DLQ 有消息"}
    notifier.lambda_handler({"Records": [{"Sns": {"Message": json.dumps(alarm)}}]}, None)
    assert stub.messages[0].startswith("🚨 ebteqdesk-business-sync-sync-dlq-not-empty → ALARM")


def test_notifier_raises_when_telegram_down(aws, stub):
    stub.telegram_fail = True
    with pytest.raises(notifier.telegram_client.TelegramError):
        notifier.lambda_handler({"Records": [{"Sns": {"Message": "{}"}}]}, None)


def test_telegram_error_never_contains_token(aws, stub):
    stub.telegram_fail = True
    creds = {"bot_token": "123:SECRET", "chat_id": "-1"}
    with pytest.raises(notifier.telegram_client.TelegramError) as exc:
        notifier.telegram_client.send_message(creds, "hi")
    assert "SECRET" not in str(exc.value)


def test_parse_counts_and_changes():
    out = "created #1 A — x\nupdated #2 B\nseen: 3 | created: 1 | updated: 1 | unchanged: 1 | failed: 0\n"
    assert report.parse_counts(out) == {"seen": 3, "created": 1, "updated": 1, "unchanged": 1, "failed": 0}
    assert report.parse_changes(out) == [
        {"action": "created", "id": "1", "name": "A", "changed_columns": "x"},
        {"action": "updated", "id": "2", "name": "B", "changed_columns": ""},
    ]
    assert report.parse_counts("nothing") is None


@pytest.mark.parametrize("url", ["http://ebteqdesk.example.com", "ftp://x", "https://"])
def test_base_url_must_be_https(url):
    with pytest.raises(ebteqdesk_api.ApiError):
        ebteqdesk_api.validate_base_url(url)


def test_trigger_id_validated():
    client = ebteqdesk_api.EbteqdeskClient("https://ebteqdesk.example.com", "t")
    with pytest.raises(ebteqdesk_api.ApiError):
        client.trigger("salonv3", "bad id with spaces")
