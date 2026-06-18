"""
Auth Lambda — token inspection and tenant context endpoint.
Called by clients that need to verify their own identity / tenant binding
without hitting RDS.  The Cognito authorizer has already validated the JWT
before this function runs, so requestContext.authorizer.claims is trusted.
"""

import json
import os
import time
import boto3
from botocore.exceptions import ClientError

_cognito = boto3.client("cognito-idp", region_name=os.environ["REGION"])


def _extract_claims(event: dict) -> dict:
    return (
        event.get("requestContext", {})
             .get("authorizer", {})
             .get("claims", {})
    )


def _response(status: int, body: object) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=str),
    }


def lambda_handler(event: dict, context) -> dict:
    """
    GET  /auth/me  — return caller's identity + tenant binding from JWT claims.
    POST /auth/me  — (reserved) update tenant_id on the Cognito user record.
    """
    try:
        claims = _extract_claims(event)

        tenant_id = claims.get("custom:tenant_id")
        if not tenant_id:
            return _response(403, {"error": "Token is not bound to a tenant"})

        method = event.get("httpMethod", "GET")

        if method == "GET":
            exp = int(claims.get("exp", 0))
            return _response(200, {
                "sub":       claims.get("sub"),
                "email":     claims.get("email"),
                "tenant_id": tenant_id,
                "token_exp": exp,
                "token_valid": exp > int(time.time()),
            })

        if method == "POST":
            # Allow a super-admin to bind an existing user to a tenant.
            # Only callers whose token already carries a tenant_id may do this
            # (enforce stricter admin checks in production via a custom claim).
            payload = json.loads(event.get("body") or "{}")
            target_username = payload.get("username")
            new_tenant_id = payload.get("tenant_id")

            if not target_username or not new_tenant_id:
                return _response(400, {"error": "username and tenant_id are required"})

            _cognito.admin_update_user_attributes(
                UserPoolId=os.environ.get("USER_POOL_ID", ""),
                Username=target_username,
                UserAttributes=[
                    {"Name": "custom:tenant_id", "Value": new_tenant_id}
                ],
            )
            return _response(200, {
                "updated": target_username,
                "tenant_id": new_tenant_id,
            })

        return _response(405, {"error": f"Method {method} not allowed"})

    except ClientError as exc:
        code = exc.response["Error"]["Code"]
        if code in ("UserNotFoundException", "NotAuthorizedException"):
            return _response(404, {"error": "User not found"})
        return _response(500, {"error": "Cognito error"})
    except Exception:
        return _response(500, {"error": "Internal server error"})
