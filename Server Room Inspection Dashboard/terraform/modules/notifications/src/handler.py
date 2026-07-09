"""Phase 5 breach-notifier Lambda (documented stub).

Runs on an EventBridge schedule after the AM/PM inspection shifts. Reads DB
credentials from Secrets Manager, queries the srid.v_flagged_records view for
recent environmental breaches, and emails a digest to the facilities recipients
via SES.

This is a self-contained stub so the Terraform module needs no external build
artifact. Harden before a real apply: add psycopg2 as a layer/dependency, tune
the lookback window, and template the email body.
"""

import json
import os
from datetime import datetime, timezone

import boto3

REGION = os.environ.get("REGION", "ap-southeast-1")
DB_SECRET_ARN = os.environ.get("DB_SECRET_ARN", "")
SENDER_EMAIL = os.environ.get("SENDER_EMAIL", "")
RECIPIENT_EMAILS = [
    e.strip() for e in os.environ.get("RECIPIENT_EMAILS", "").split(",") if e.strip()
]


def _get_db_credentials():
    """Fetch the RDS credentials secret (app_username / app_password)."""
    client = boto3.client("secretsmanager", region_name=REGION)
    resp = client.get_secret_value(SecretId=DB_SECRET_ARN)
    return json.loads(resp["SecretString"])


def _query_flagged_records(creds):
    """Return recent rows from srid.v_flagged_records.

    Placeholder: wire up psycopg2 here, e.g.

        import psycopg2
        conn = psycopg2.connect(
            host=creds["host"], port=creds["port"], dbname=creds["dbname"],
            user=creds["app_username"], password=creds["app_password"],
            connect_timeout=5,
        )
        with conn.cursor() as cur:
            cur.execute(
                "SELECT log_id, source_site, inspection_date, shift, "
                "temperature_c, humidity_pct, breach_reasons "
                "FROM srid.v_flagged_records "
                "WHERE inspected_at >= now() - interval '12 hours' "
                "ORDER BY inspected_at DESC"
            )
            return cur.fetchall()
    """
    return []


def _send_email(rows):
    """Email the breach digest via SES."""
    if not SENDER_EMAIL or not RECIPIENT_EMAILS:
        print("SES sender/recipients not configured; skipping send.")
        return
    ses = boto3.client("ses", region_name=REGION)
    subject = f"MCF SRID — {len(rows)} flagged reading(s) this shift"
    body = (
        f"Breach digest generated {datetime.now(timezone.utc).isoformat()}\n\n"
        + ("No breaches in the last shift window.\n" if not rows else "\n".join(str(r) for r in rows))
    )
    ses.send_email(
        Source=SENDER_EMAIL,
        Destination={"ToAddresses": RECIPIENT_EMAILS},
        Message={
            "Subject": {"Data": subject},
            "Body": {"Text": {"Data": body}},
        },
    )


def handler(event, context):
    creds = _get_db_credentials()
    rows = _query_flagged_records(creds)
    _send_email(rows)
    return {"flagged_count": len(rows)}
