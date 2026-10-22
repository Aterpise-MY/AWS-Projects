"""Minimal Telegram Bot API client (stdlib only).

The bot token is part of every request URL, so this module never logs a URL
and never includes one in an exception message.
"""

import json
import os
import urllib.error
import urllib.request
import uuid

import boto3

API_BASE = os.environ.get("TELEGRAM_API_BASE", "https://api.telegram.org")
MAX_MESSAGE_CHARS = 4000  # Telegram hard limit is 4096
MAX_CAPTION_CHARS = 1000  # Telegram hard limit is 1024


class TelegramError(Exception):
    """Raised when Telegram rejects a request or cannot be reached."""


def load_credentials(secret_arn):
    """Read {"bot_token": ..., "chat_id": ...} from Secrets Manager.

    Read on every invocation (no cache), so a rotated secret takes effect
    without a redeploy.
    """
    resp = boto3.client("secretsmanager").get_secret_value(SecretId=secret_arn)
    data = json.loads(resp["SecretString"])
    if not data.get("bot_token") or not data.get("chat_id"):
        raise TelegramError("telegram secret is missing bot_token or chat_id")
    return data


def _call(creds, method, body, content_type, timeout=15):
    url = f"{API_BASE}/bot{creds['bot_token']}/{method}"
    req = urllib.request.Request(url, data=body, method="POST", headers={"Content-Type": content_type})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise TelegramError(f"telegram {method} returned HTTP {exc.code}") from None
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise TelegramError(f"telegram {method} unreachable: {type(exc).__name__}") from None
    except ValueError:
        raise TelegramError(f"telegram {method} returned non-JSON") from None
    if not payload.get("ok"):
        raise TelegramError(f"telegram {method} not ok: {payload.get('description', 'unknown')}")
    return payload


def send_message(creds, text):
    if len(text) > MAX_MESSAGE_CHARS:
        text = text[: MAX_MESSAGE_CHARS - 20] + "\n…（已截断 / truncated）"
    body = json.dumps(
        {"chat_id": creds["chat_id"], "text": text, "disable_web_page_preview": True}
    ).encode("utf-8")
    return _call(creds, "sendMessage", body, "application/json")


def send_document(creds, filename, content, caption=""):
    """Upload `content` (bytes) as a file attachment."""
    if len(caption) > MAX_CAPTION_CHARS:
        caption = caption[: MAX_CAPTION_CHARS - 1] + "…"
    boundary = uuid.uuid4().hex
    parts = []
    for name, value in (("chat_id", str(creds["chat_id"])), ("caption", caption)):
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode("utf-8")
        )
    parts.append(
        (
            f'--{boundary}\r\nContent-Disposition: form-data; name="document"; filename="{filename}"\r\n'
            "Content-Type: application/octet-stream\r\n\r\n"
        ).encode("utf-8")
        + content
        + b"\r\n"
    )
    parts.append(f"--{boundary}--\r\n".encode("utf-8"))
    return _call(creds, "sendDocument", b"".join(parts), f"multipart/form-data; boundary={boundary}", timeout=30)
