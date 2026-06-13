"""
Users Lambda — GET /users and POST /users
Tenant isolation: every query is filtered by tenant_id extracted from the
Cognito JWT claims that API Gateway injects into requestContext.authorizer.
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
    """Pull custom:tenant_id from the JWT claims Cognito authorizer injects."""
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
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                cur.execute(
                    "SELECT id, email, created_at FROM users WHERE tenant_id = %s ORDER BY created_at DESC",
                    (tenant_id,),
                )
                rows = cur.fetchall()
            return _response(200, list(rows))

        if method == "POST":
            payload = json.loads(event.get("body") or "{}")
            email = payload.get("email", "").strip()
            if not email:
                return _response(400, {"error": "email is required"})

            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO users (tenant_id, email) VALUES (%s, %s) RETURNING id",
                    (tenant_id, email),
                )
                new_id = cur.fetchone()[0]
            conn.commit()
            return _response(201, {"id": new_id, "tenant_id": tenant_id, "email": email})

        return _response(405, {"error": f"Method {method} not allowed"})

    except PermissionError as exc:
        return _response(401, {"error": str(exc)})
    except psycopg2.Error as exc:
        conn = _get_conn()
        conn.rollback()
        return _response(500, {"error": "Database error"})
    except Exception:
        return _response(500, {"error": "Internal server error"})
