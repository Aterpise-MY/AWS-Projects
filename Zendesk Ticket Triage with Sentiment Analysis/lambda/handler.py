"""Zendesk ticket triage with AWS Comprehend sentiment analysis.

Flow (invoked by API Gateway proxy, fired by a Zendesk webhook/trigger):
  1. Verify the Zendesk HMAC-SHA256 request signature.
  2. Extract ticket id / subject / description from the JSON body.
  3. Score sentiment with AWS Comprehend.
  4. Apply triage rules -> priority + tag (+ escalation group).
  5. Write the scored record to DynamoDB (audit/analytics).
  6. PUT the triage decision back into the Zendesk ticket via the Tickets API.
  7. Publish an SNS alert when a ticket is escalated to urgent.
"""

import base64
import hashlib
import hmac
import json
import os
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

import boto3

TABLE_NAME = os.environ["TABLE_NAME"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
SECRET_ARN = os.environ["SECRET_ARN"]
ZENDESK_SUBDOMAIN = os.environ["ZENDESK_SUBDOMAIN"]
ESCALATION_GROUP_ID = int(os.environ.get("ZENDESK_ESCALATION_GROUP_ID", "0"))
LANGUAGE_CODE = os.environ.get("COMPREHEND_LANGUAGE_CODE", "en")
NEG_THRESHOLD = float(os.environ.get("NEGATIVE_CONFIDENCE_THRESHOLD", "0.80"))
POS_THRESHOLD = float(os.environ.get("POSITIVE_CONFIDENCE_THRESHOLD", "0.80"))

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)
comprehend = boto3.client("comprehend")
sns = boto3.client("sns")
secrets = boto3.client("secretsmanager")

# Comprehend DetectSentiment accepts at most 5000 UTF-8 bytes.
MAX_TEXT_BYTES = 5000

_secret_cache = None


def _get_secret():
    """Fetch and cache the Zendesk credentials for the life of the container."""
    global _secret_cache
    if _secret_cache is None:
        raw = secrets.get_secret_value(SecretId=SECRET_ARN)["SecretString"]
        _secret_cache = json.loads(raw)
    return _secret_cache


def lambda_handler(event, context):
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode("utf-8")

    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}

    if not _verify_signature(headers, body):
        print("Signature verification failed")
        return _resp(401, {"error": "Invalid or missing webhook signature"})

    try:
        payload = json.loads(body or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON body"})

    ticket_id = str(payload.get("id") or payload.get("ticket_id") or "")
    if not ticket_id:
        return _resp(400, {"error": "Ticket id is required"})

    subject = (payload.get("subject") or payload.get("title") or "").strip()
    description = (payload.get("description") or "").strip()
    text = (subject + "\n" + description).strip()
    if not text:
        return _resp(400, {"error": "Ticket has no text to analyse"})

    sentiment, confidence = _detect_sentiment(text)
    priority, tag, assign_group = _triage(sentiment, confidence)

    created_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    group_id = ESCALATION_GROUP_ID if assign_group and ESCALATION_GROUP_ID else 0

    _write_record(ticket_id, created_at, subject, description,
                  sentiment, confidence, priority, tag, group_id)

    zendesk_status = _update_zendesk_ticket(ticket_id, priority, tag, group_id)

    if priority == "urgent":
        _publish_alert(ticket_id, subject, sentiment, confidence, priority)

    return _resp(200, {
        "ticket_id": ticket_id,
        "sentiment": sentiment,
        "confidence": round(confidence, 4),
        "priority": priority,
        "tag": tag,
        "group_id": group_id,
        "zendesk_update": zendesk_status,
    })


def _verify_signature(headers, body):
    """Verify Zendesk's HMAC-SHA256 signature over (timestamp + raw body)."""
    signature = headers.get("x-zendesk-webhook-signature")
    timestamp = headers.get("x-zendesk-webhook-signature-timestamp")
    if not signature or not timestamp:
        return False

    secret = _get_secret().get("webhook_signing_secret", "")
    if not secret:
        return False

    mac = hmac.new(secret.encode("utf-8"),
                   (timestamp + body).encode("utf-8"),
                   hashlib.sha256)
    expected = base64.b64encode(mac.digest()).decode("utf-8")
    return hmac.compare_digest(expected, signature)


def _detect_sentiment(text):
    encoded = text.encode("utf-8")[:MAX_TEXT_BYTES]
    result = comprehend.detect_sentiment(
        Text=encoded.decode("utf-8", errors="ignore"),
        LanguageCode=LANGUAGE_CODE,
    )
    sentiment = result["Sentiment"]  # POSITIVE | NEGATIVE | NEUTRAL | MIXED
    score = result["SentimentScore"][sentiment.capitalize()]
    return sentiment, float(score)


def _triage(sentiment, confidence):
    """Return (priority, tag, assign_escalation_group)."""
    if sentiment == "NEGATIVE" and confidence >= NEG_THRESHOLD:
        return "urgent", "neg_sentiment", True
    if sentiment in ("NEGATIVE", "MIXED"):
        return "high", "review", False
    if sentiment == "POSITIVE" and confidence >= POS_THRESHOLD:
        return "normal", "positive_sentiment", False
    return "normal", "neutral_sentiment", False


def _write_record(ticket_id, created_at, subject, description,
                  sentiment, confidence, priority, tag, group_id):
    table.put_item(Item={
        "TicketID": ticket_id,
        "CreatedAt": created_at,
        "Subject": subject,
        "Description": description,
        "Sentiment": sentiment,
        "Confidence": str(round(confidence, 4)),
        "Priority": priority,
        "Tag": tag,
        "ZendeskGroupID": str(group_id),
    })


def _update_zendesk_ticket(ticket_id, priority, tag, group_id):
    """PUT priority/tag/group back to the Zendesk ticket via the Tickets API."""
    creds = _get_secret()
    email = creds.get("email", "")
    api_token = creds.get("api_token", "")
    if not email or not api_token or ZENDESK_SUBDOMAIN in ("", "your-subdomain"):
        return "skipped (zendesk credentials not configured)"

    ticket = {"priority": priority, "additional_tags": [tag]}
    if group_id:
        ticket["group_id"] = group_id

    url = f"https://{ZENDESK_SUBDOMAIN}.zendesk.com/api/v2/tickets/{ticket_id}.json"
    data = json.dumps({"ticket": ticket}).encode("utf-8")
    auth = base64.b64encode(f"{email}:{api_token}".encode("utf-8")).decode("utf-8")

    req = urllib.request.Request(url, data=data, method="PUT")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", f"Basic {auth}")

    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            return f"updated (HTTP {resp.status})"
    except urllib.error.HTTPError as e:
        print(f"Zendesk API error: {e.code} {e.read().decode('utf-8', 'ignore')}")
        return f"error (HTTP {e.code})"
    except urllib.error.URLError as e:
        print(f"Zendesk API connection error: {e.reason}")
        return "error (connection)"


def _publish_alert(ticket_id, subject, sentiment, confidence, priority):
    message = (
        f"URGENT Zendesk ticket escalated by sentiment triage\n\n"
        f"Ticket: #{ticket_id}\n"
        f"Subject: {subject}\n"
        f"Sentiment: {sentiment} ({confidence:.0%} confidence)\n"
        f"Priority set to: {priority}\n"
        f"View: https://{ZENDESK_SUBDOMAIN}.zendesk.com/agent/tickets/{ticket_id}"
    )
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=f"[URGENT] Negative ticket #{ticket_id}",
        Message=message,
    )


def _resp(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
