"""
Orders Lambda — GET /orders and POST /orders
Tenant isolation: every query is scoped to the tenant_id from JWT claims.
"""

import json
import os
import boto3
import psycopg2
from psycopg2.extras import RealDictCursor

_cached_password: str | None = None
_cached_conn = None


def _get_db_password() -> str:
    global _cached_password
    if _cached_password:
        return _cached_password
    client = boto3.client("secretsmanager", region_name=os.environ["REGION"])
    result = client.get_secret_value(SecretId=os.environ["SECRET_ARN"])
    _cached_password = result["SecretString"]
    return _cached_password


def _get_conn():
    global _cached_conn
    try:
        if _cached_conn and not _cached_conn.closed:
            _cached_conn.cursor().execute("SELECT 1")
            return _cached_conn
    except Exception:
        pass
    _cached_conn = psycopg2.connect(
        host=os.environ["DB_HOST"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=_get_db_password(),
        connect_timeout=5,
        sslmode="require",
    )
    return _cached_conn


def _extract_tenant_id(event: dict) -> str:
    claims = (
        event.get("requestContext", {})
             .get("authorizer", {})
             .get("claims", {})
    )
    tenant_id = claims.get("custom:tenant_id")
    if not tenant_id:
        raise PermissionError("custom:tenant_id claim is missing from the token")
    return tenant_id


def _response(status: int, body: object) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=str),
    }


def lambda_handler(event: dict, context) -> dict:
    try:
        tenant_id = _extract_tenant_id(event)
        method = event["httpMethod"]
        conn = _get_conn()

        if method == "GET":
            params = event.get("queryStringParameters") or {}
            user_id = params.get("user_id")

            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                if user_id:
                    # Scoped to tenant AND a specific user — prevents cross-user leakage
                    cur.execute(
                        """SELECT id, user_id, amount, status, created_at
                           FROM orders
                           WHERE tenant_id = %s AND user_id = %s
                           ORDER BY created_at DESC""",
                        (tenant_id, user_id),
                    )
                else:
                    cur.execute(
                        """SELECT id, user_id, amount, status, created_at
                           FROM orders
                           WHERE tenant_id = %s
                           ORDER BY created_at DESC""",
                        (tenant_id,),
                    )
                rows = cur.fetchall()
            return _response(200, list(rows))

        if method == "POST":
            payload = json.loads(event.get("body") or "{}")
            user_id = payload.get("user_id")
            amount = payload.get("amount")
            if not user_id or amount is None:
                return _response(400, {"error": "user_id and amount are required"})

            with conn.cursor() as cur:
                cur.execute(
                    """INSERT INTO orders (tenant_id, user_id, amount, status)
                       VALUES (%s, %s, %s, 'pending')
                       RETURNING id""",
                    (tenant_id, user_id, amount),
                )
                new_id = cur.fetchone()[0]
            conn.commit()
            return _response(201, {
                "id": new_id,
                "tenant_id": tenant_id,
                "user_id": user_id,
                "amount": amount,
                "status": "pending",
            })

        return _response(405, {"error": f"Method {method} not allowed"})

    except PermissionError as exc:
        return _response(401, {"error": str(exc)})
    except psycopg2.Error:
        conn = _get_conn()
        conn.rollback()
        return _response(500, {"error": "Database error"})
    except Exception:
        return _response(500, {"error": "Internal server error"})
