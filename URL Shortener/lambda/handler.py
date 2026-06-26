import json
import os
import random
import string
import time

import boto3
from botocore.exceptions import ClientError

TABLE_NAME = os.environ["TABLE_NAME"]
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)


def lambda_handler(event, context):
    method = event.get("httpMethod", "")
    resource = event.get("resource", "")

    if method == "POST" and resource == "/shorten":
        return _handle_shorten(event)
    elif method == "GET" and resource == "/redirect":
        return _handle_redirect(event)
    elif method == "GET" and resource == "/stats":
        return _handle_stats(event)
    else:
        return _resp(404, {"error": "Not found"})


def _handle_shorten(event):
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "Invalid JSON body"})

    long_url = body.get("long_url")
    if not long_url:
        return _resp(400, {"error": "long_url is required"})

    custom_code = body.get("custom_code")
    created_by = body.get("created_by", "unknown")
    label = body.get("label", "")

    try:
        expires_in_days = int(body.get("expires_in_days", 3650))
        if not 1 <= expires_in_days <= 36500:
            return _resp(400, {"error": "expires_in_days must be between 1 and 36500"})
    except (ValueError, TypeError):
        return _resp(400, {"error": "expires_in_days must be an integer"})

    now = int(time.time())
    expires_at = now + (expires_in_days * 86400)

    if custom_code:
        short_code = custom_code.lower().replace(" ", "-")
        existing = table.get_item(Key={"short_code": short_code}).get("Item")
        if existing:
            return _resp(409, {"error": f"Short code '{short_code}' is already taken"})
    else:
        short_code = _generate_code()
        for _ in range(3):
            if not table.get_item(Key={"short_code": short_code}).get("Item"):
                break
            short_code = _generate_code()
        else:
            return _resp(500, {"error": "Failed to generate a unique short code; please retry"})

    table.put_item(Item={
        "short_code": short_code,
        "long_url": long_url,
        "label": label,
        "created_by": created_by,
        "created_at": now,
        "expires_at": expires_at,
        "click_count": 0,
        "last_accessed": 0,
    })

    return _resp(201, {
        "short_code": short_code,
        "long_url": long_url,
        "label": label,
        "expires_at": expires_at,
        "expires_in_days": expires_in_days,
    })


def _handle_redirect(event):
    params = event.get("queryStringParameters") or {}
    short_code = params.get("short_code")

    if not short_code:
        return _resp(400, {"error": "short_code query parameter is required"})

    item = table.get_item(Key={"short_code": short_code}).get("Item")
    if not item:
        return _resp(404, {"error": "Short link not found"})

    now = int(time.time())
    expires_at = int(item.get("expires_at", 0))
    if expires_at and now > expires_at:
        return _resp(410, {"error": "This short link has expired"})

    table.update_item(
        Key={"short_code": short_code},
        UpdateExpression="SET click_count = click_count + :inc, last_accessed = :now",
        ExpressionAttributeValues={":inc": 1, ":now": now},
    )

    return {
        "statusCode": 301,
        "headers": {
            "Location": item["long_url"],
            "Cache-Control": "no-cache, no-store",
        },
        "body": "",
    }


def _handle_stats(event):
    params = event.get("queryStringParameters") or {}
    short_code = params.get("short_code")

    if not short_code:
        return _resp(400, {"error": "short_code query parameter is required"})

    item = table.get_item(Key={"short_code": short_code}).get("Item")
    if not item:
        return _resp(404, {"error": "Short link not found"})

    return _resp(200, {
        "short_code": item["short_code"],
        "label": item.get("label", ""),
        "long_url": item.get("long_url", ""),
        "created_by": item.get("created_by", ""),
        "created_at": int(item.get("created_at", 0)),
        "click_count": int(item.get("click_count", 0)),
        "last_accessed": int(item.get("last_accessed", 0)),
        "expires_at": int(item.get("expires_at", 0)),
    })


def _generate_code(length=6):
    return "".join(random.choices(string.ascii_lowercase + string.digits, k=length))


def _resp(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body),
    }
