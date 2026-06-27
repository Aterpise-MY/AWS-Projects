"""Route: broadcastResults — pushes current poll tallies to all session clients.

Payload: {"action": "broadcastResults", "pollId": "...", "sessionId": "..."}
Reads the Polls table and fans the votes map out to every connection in the session.
"""
import json
import os

import boto3

from _broadcast import post_to_session

POLLS_TABLE = os.environ["POLLS_TABLE"]
CONNECTIONS_TABLE = os.environ["CONNECTIONS_TABLE"]

dynamodb = boto3.resource("dynamodb")
polls = dynamodb.Table(POLLS_TABLE)
connections = dynamodb.Table(CONNECTIONS_TABLE)


def lambda_handler(event, context):
    body = json.loads(event.get("body") or "{}")
    poll_id = body.get("pollId")
    session_id = body.get("sessionId", "default")

    if not poll_id:
        return {"statusCode": 400, "body": "pollId is required"}

    item = polls.get_item(Key={"pollId": poll_id}).get("Item")
    if not item:
        return {"statusCode": 404, "body": "Poll not found"}

    payload = {
        "type": "pollResults",
        "pollId": poll_id,
        "votes": item.get("votes", {}),
    }
    delivered = post_to_session(event, connections, session_id, payload)

    return {"statusCode": 200, "body": json.dumps({"delivered": delivered})}
