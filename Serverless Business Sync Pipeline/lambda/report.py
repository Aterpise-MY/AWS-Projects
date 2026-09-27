"""Shared helpers: MYT time, console-output parsing, S3 layout, CSV and EMF metrics."""

import csv
import io
import json
import re
from datetime import datetime, timedelta, timezone

# Asia/Kuala_Lumpur has no DST, so a fixed offset is exact and needs no tzdata.
MYT = timezone(timedelta(hours=8), "MYT")
PREFIX = "business-sync"
METRIC_NAMESPACE = "EbteqdeskBusinessSync"

# Pinned by Ebteqdesk tests — safe to parse.
COUNTS_RE = re.compile(
    r"seen:\s*(\d+)\s*\|\s*created:\s*(\d+)\s*\|\s*updated:\s*(\d+)\s*\|\s*unchanged:\s*(\d+)\s*\|\s*failed:\s*(\d+)"
)
# Best-effort: "created #123 Some Name — col1, col2"
CHANGE_RE = re.compile(r"^\s*(created|updated)\s+#(\S+)\s+(.*?)(?:\s+[—-]\s+(.*))?\s*$")
FAILURE_RE = re.compile(r"\b(failed|error|exception)\b", re.IGNORECASE)
CHANGES_CSV_COLUMNS = ["run_id", "portal", "action", "id", "name", "changed_columns"]
MAX_FAILURE_LINES = 50


# ---------------------------------------------------------------- time


def utcnow():
    return datetime.now(timezone.utc)


def parse_iso(value):
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def to_myt(dt):
    return dt.astimezone(MYT)


def fmt_duration(seconds):
    seconds = max(0, int(seconds))
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    if days:
        return f"{days}d {hours}h {minutes}m"
    if hours:
        return f"{hours}h {minutes}m"
    return f"{minutes}m"


# ---------------------------------------------------------------- output parsing


def parse_counts(output):
    matches = COUNTS_RE.findall(output or "")
    if not matches:
        return None
    seen, created, updated, unchanged, failed = (int(x) for x in matches[-1])
    return {"seen": seen, "created": created, "updated": updated, "unchanged": unchanged, "failed": failed}


def parse_changes(output):
    changes = []
    for line in (output or "").splitlines():
        m = CHANGE_RE.match(line)
        if m:
            changes.append(
                {"action": m.group(1), "id": m.group(2), "name": m.group(3).strip(), "changed_columns": (m.group(4) or "").strip()}
            )
    return changes


def parse_failure_lines(output):
    lines = []
    for line in (output or "").splitlines():
        if COUNTS_RE.search(line):
            continue
        if FAILURE_RE.search(line):
            lines.append(line.strip())
            if len(lines) >= MAX_FAILURE_LINES:
                break
    return lines


# ---------------------------------------------------------------- S3 layout (dates are MYT)


def date_path(day):
    return f"{day.year:04d}/{day.month:02d}/{day.day:02d}"


def run_prefix(portal, day, run):
    return f"{PREFIX}/{portal}/{date_path(day)}/{run}/"


def attempt_prefix(portal, day, run, attempt):
    return f"{run_prefix(portal, day, run)}attempt-{attempt}/"


def failure_key(portal, day, run, attempt):
    return f"{PREFIX}/failures/{portal}/{date_path(day)}/{run}-attempt-{attempt}.json"


def latest_key(portal):
    return f"{PREFIX}/{portal}/latest.json"


def daily_report_prefix(day):
    return f"{PREFIX}/daily-reports/{date_path(day)}/"


# ---------------------------------------------------------------- serialisation


def to_json_bytes(obj):
    return json.dumps(obj, ensure_ascii=False, indent=2, default=str).encode("utf-8")


def csv_bytes(columns, rows):
    """UTF-8 with BOM so Excel opens Chinese names correctly."""
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=columns, extrasaction="ignore", lineterminator="\n")
    writer.writeheader()
    for row in rows:
        writer.writerow(row)
    return b"\xef\xbb\xbf" + buf.getvalue().encode("utf-8")


def read_csv_bytes(data):
    text = data.decode("utf-8-sig")
    return list(csv.DictReader(io.StringIO(text)))


def put_object(s3, bucket, key, body, content_type):
    s3.put_object(Bucket=bucket, Key=key, Body=body, ContentType=content_type)


# ---------------------------------------------------------------- metrics


def emit_metrics(service, metrics, portal=None, unit="Count"):
    """Print one CloudWatch Embedded Metric Format record. `metrics` is {name: value}."""
    dims = ["Service", "Portal"] if portal else ["Service"]
    record = {
        "_aws": {
            "Timestamp": int(utcnow().timestamp() * 1000),
            "CloudWatchMetrics": [
                {
                    "Namespace": METRIC_NAMESPACE,
                    "Dimensions": [dims],
                    "Metrics": [
                        {"Name": name, "Unit": "Milliseconds" if name.endswith("Ms") else unit} for name in metrics
                    ],
                }
            ],
        },
        "Service": service,
        **metrics,
    }
    if portal:
        record["Portal"] = portal
    print(json.dumps(record))
