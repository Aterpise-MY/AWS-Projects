"""Notifier: CloudWatch Alarm -> SNS -> Telegram."""

import json
import os

import telegram_client

STATE_PREFIX = {"ALARM": "🚨", "OK": "✅", "INSUFFICIENT_DATA": "⚠️"}


def format_alarm(alarm):
    state = alarm.get("NewStateValue", "UNKNOWN")
    return "\n".join([
        f"{STATE_PREFIX.get(state, 'ℹ️')} {alarm.get('AlarmName', 'unknown-alarm')} → {state}",
        alarm.get("AlarmDescription") or "",
        f"原因 reason: {alarm.get('NewStateReason', '-')}",
        f"时间 time: {alarm.get('StateChangeTime', '-')}",
    ]).replace("\n\n", "\n")


def lambda_handler(event, context):
    creds = telegram_client.load_credentials(os.environ["TELEGRAM_SECRET_ARN"])
    sent = 0
    for record in event.get("Records", []):
        raw = record.get("Sns", {}).get("Message", "")
        try:
            alarm = json.loads(raw)
            text = format_alarm(alarm) if isinstance(alarm, dict) else str(raw)
        except ValueError:
            text = f"ℹ️ SNS message:\n{raw}"
        # Raise on failure so SNS/Lambda async retry kicks in.
        telegram_client.send_message(creds, text)
        sent += 1
    return {"sent": sent}
