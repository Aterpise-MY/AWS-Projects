"""Test fixtures: a fake boto3 module and one local stub HTTP server (Ebteqdesk + Telegram). No network."""

import io
import json
import re
import sys
import threading
import types
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

BUCKET = "test-bucket"
SYNC_DLQ = "https://sqs.local/sync-dlq"
SCHEDULER_DLQ = "https://sqs.local/scheduler-dlq"


# ---------------------------------------------------------------- fake boto3


class FakeClientError(Exception):
    def __init__(self, code, message=""):
        super().__init__(f"{code}: {message}")
        self.response = {"Error": {"Code": code, "Message": message}}


class FakeAWS:
    def __init__(self):
        self.objects = {}  # (bucket, key) -> bytes
        self.secrets = {}
        self.queue_depth = {SYNC_DLQ: 0, SCHEDULER_DLQ: 0}
        self.s3_put_fails = False

    def keys(self, prefix=""):
        return sorted(k for (_, k) in self.objects if k.startswith(prefix))

    def json(self, key):
        return json.loads(self.objects[(BUCKET, key)].decode("utf-8"))


class _Paginator:
    def __init__(self, aws):
        self.aws = aws

    def paginate(self, Bucket, Prefix):
        keys = sorted(k for (b, k) in self.aws.objects if b == Bucket and k.startswith(Prefix))
        # Two pages to exercise pagination.
        half = len(keys) // 2
        for chunk in (keys[:half], keys[half:]):
            yield {"Contents": [{"Key": k} for k in chunk]} if chunk else {}


class FakeS3:
    def __init__(self, aws):
        self.aws = aws

    def put_object(self, Bucket, Key, Body, ContentType=None):
        if self.aws.s3_put_fails:
            raise FakeClientError("InternalError", "s3 down")
        self.aws.objects[(Bucket, Key)] = Body if isinstance(Body, bytes) else Body.encode("utf-8")

    def get_object(self, Bucket, Key):
        if (Bucket, Key) not in self.aws.objects:
            raise FakeClientError("NoSuchKey", Key)
        return {"Body": io.BytesIO(self.aws.objects[(Bucket, Key)])}

    def get_paginator(self, name):
        assert name == "list_objects_v2"
        return _Paginator(self.aws)


class FakeSecrets:
    def __init__(self, aws):
        self.aws = aws

    def get_secret_value(self, SecretId):
        if SecretId not in self.aws.secrets:
            raise FakeClientError("ResourceNotFoundException", SecretId)
        return {"SecretString": json.dumps(self.aws.secrets[SecretId])}


class FakeSQS:
    def __init__(self, aws):
        self.aws = aws

    def get_queue_attributes(self, QueueUrl, AttributeNames):
        return {"Attributes": {"ApproximateNumberOfMessagesVisible": str(self.aws.queue_depth[QueueUrl])}}


_current = {"aws": FakeAWS()}
fake_boto3 = types.ModuleType("boto3")
fake_boto3.client = lambda name, **_: {"s3": FakeS3, "secretsmanager": FakeSecrets, "sqs": FakeSQS}[name](
    _current["aws"]
)
sys.modules["boto3"] = fake_boto3


# ---------------------------------------------------------------- stub HTTP server


class StubState:
    def reset(self):
        self.trigger_response = None  # (status, run_dict) or (status, content_type, raw_bytes)
        self.run_sequence = []  # successive GET /runs/{id} bodies; last one repeats
        self.posts = []
        self.gets = 0
        self.telegram_fail = False
        self.messages = []
        self.documents = []


STATE = StubState()
STATE.reset()


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, status, body, ctype="application/json"):
        raw = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        if self.path.startswith("/bot"):
            if STATE.telegram_fail:
                return self._send(502, {"ok": False, "description": "bad gateway"})
            if self.path.endswith("/sendMessage"):
                STATE.messages.append(json.loads(body)["text"])
            else:
                m = re.search(rb'filename="([^"]+)"\r\nContent-Type: application/octet-stream\r\n\r\n', body)
                content = body[m.end():body.rindex(b"\r\n--")]
                STATE.documents.append((m.group(1).decode(), content))
            return self._send(200, {"ok": True, "result": {}})
        if self.path.startswith("/api/integrations/business-sync/"):
            STATE.posts.append({"path": self.path, "trigger_id": self.headers.get("X-Trigger-Id"),
                                "auth": self.headers.get("Authorization")})
            resp = STATE.trigger_response
            if len(resp) == 3:
                return self._send(resp[0], resp[2], resp[1])
            return self._send(resp[0], {"data": resp[1]})
        self._send(404, {"error": "not found"})

    def do_GET(self):
        if self.path.startswith("/api/integrations/business-sync/runs/"):
            idx = min(STATE.gets, len(STATE.run_sequence) - 1)
            STATE.gets += 1
            return self._send(200, {"data": STATE.run_sequence[idx]})
        self._send(404, {"error": "not found"})


@pytest.fixture(scope="session")
def server():
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{httpd.server_address[1]}"
    httpd.shutdown()


class FakeContext:
    """Remaining time drops by `step_ms` on every call, to simulate polling until timeout."""

    def __init__(self, remaining_ms=600_000, step_ms=0):
        self.remaining = remaining_ms
        self.step = step_ms

    def get_remaining_time_in_millis(self):
        value = self.remaining
        self.remaining -= self.step
        return value


@pytest.fixture
def aws(server, monkeypatch):
    fresh = FakeAWS()
    fresh.secrets = {"ebteq-secret": {"token": "t0ken"}, "tg-secret": {"bot_token": "123:abc", "chat_id": "-100"}}
    _current["aws"] = fresh
    STATE.reset()
    import telegram_client

    monkeypatch.setattr(telegram_client, "API_BASE", server)
    for key, value in {
        "REPORT_BUCKET": BUCKET,
        "SERVICE_NAME": "ebteqdesk-business-sync",
        "ALLOWED_PORTALS": "salonv3,warni",
        "EBTEQDESK_BASE_URL": server,
        "EBTEQDESK_SECRET_ARN": "ebteq-secret",
        "TELEGRAM_SECRET_ARN": "tg-secret",
        "MAX_RECEIVE_COUNT": "2",
        "ALERT_EVERY_N_FAILURES": "3",
        "POLL_INTERVAL_SECONDS": "0",
        "POLL_SAFETY_SECONDS": "45",
        "PORTALS_JSON": json.dumps({
            "salonv3": {"schedule_expression": "cron(0 9-17 ? * MON-FRI *)", "enabled": True,
                        "expected_runs_per_day": 9},
            "warni": {"schedule_expression": "cron(30 9-16 ? * MON-FRI *)", "enabled": False,
                      "expected_runs_per_day": 8},
        }),
        "SYNC_DLQ_URL": SYNC_DLQ,
        "SCHEDULER_DLQ_URL": SCHEDULER_DLQ,
    }.items():
        monkeypatch.setenv(key, value)
    return fresh


@pytest.fixture
def stub():
    return STATE
