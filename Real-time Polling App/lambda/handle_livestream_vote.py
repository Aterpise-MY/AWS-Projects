"""Scenario 1 — Route: liveVote — live-stream product voting.

Payload: {"action": "liveVote", "sessionId": "...", "productId": "..."}
Atomically increments voteCounts[productId] in LiveStreamSessions, then fans the
updated tally out to all clients in the session.
"""
import json
import os

import boto3
from botocore.exceptions import ClientError

from _broadcast import post_to_session, post_to_one

LIVESTREAM_TABLE = os.environ["LIVESTREAM_TABLE"]
CONNECTIONS_TABLE = os.environ["CONNECTIONS_TABLE"]

dynamodb = boto3.resource("dynamodb")
sessions = dynamodb.Table(LIVESTREAM_TABLE)
connections = dynamodb.Table(CONNECTIONS_TABLE)


def lambda_handler(event, context):
    body = json.loads(event.get("body") or "{}")
    session_id = body.get("sessionId")
    product_id = body.get("productId")
    connection_id = event["requestContext"]["connectionId"]

    if not session_id or not product_id:
        return {"statusCode": 400, "body": "sessionId and productId are required"}

    try:
        result = sessions.update_item(
            Key={"sessionId": session_id},
            UpdateExpression="ADD voteCounts.#pid :one",
            ConditionExpression="attribute_exists(sessionId) AND #st = :active",
            ExpressionAttributeNames={"#pid": product_id, "#st": "status"},
            ExpressionAttributeValues={":one": 1, ":active": "active"},
            ReturnValues="ALL_NEW",
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            post_to_one(event, connection_id, {"type": "error", "reason": "session_not_active"})
            return {"statusCode": 409, "body": "Session not active"}
        raise

    payload = {
        "type": "liveVoteUpdate",
        "sessionId": session_id,
        "voteCounts": result["Attributes"].get("voteCounts", {}),
    }
    delivered = post_to_session(event, connections, session_id, payload)

    return {"statusCode": 200, "body": json.dumps({"delivered": delivered})}
