"""Route: sendVote — processes a general poll vote.

Payload: {"action": "sendVote", "pollId": "...", "option": "..."}
Atomically increments votes[option] in the Polls table.
"""
import json
import os

import boto3

POLLS_TABLE = os.environ["POLLS_TABLE"]

dynamodb = boto3.resource("dynamodb")
polls = dynamodb.Table(POLLS_TABLE)


def lambda_handler(event, context):
    body = json.loads(event.get("body") or "{}")
    poll_id = body.get("pollId")
    option = body.get("option")

    if not poll_id or not option:
        return {"statusCode": 400, "body": "pollId and option are required"}

    result = polls.update_item(
        Key={"pollId": poll_id},
        UpdateExpression="ADD votes.#opt :one",
        ExpressionAttributeNames={"#opt": option},
        ExpressionAttributeValues={":one": 1},
        ReturnValues="UPDATED_NEW",
    )

    return {
        "statusCode": 200,
        "body": json.dumps({"pollId": poll_id, "option": option}),
    }
