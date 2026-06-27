"""Scenario 3 — Route: designVote — new product design preference survey.

Payload: {"action": "designVote", "surveyId": "...", "designId": "...", "sessionId": "..."}
Atomically increments votes[designId] in DesignSurveys and fans the updated
votes map out to all clients in the session.
"""
import json
import os

import boto3
from botocore.exceptions import ClientError

from _broadcast import post_to_session, post_to_one

DESIGN_TABLE = os.environ["DESIGN_TABLE"]
CONNECTIONS_TABLE = os.environ["CONNECTIONS_TABLE"]

dynamodb = boto3.resource("dynamodb")
surveys = dynamodb.Table(DESIGN_TABLE)
connections = dynamodb.Table(CONNECTIONS_TABLE)


def lambda_handler(event, context):
    body = json.loads(event.get("body") or "{}")
    survey_id = body.get("surveyId")
    design_id = body.get("designId")
    session_id = body.get("sessionId", "default")
    connection_id = event["requestContext"]["connectionId"]

    if not survey_id or not design_id:
        return {"statusCode": 400, "body": "surveyId and designId are required"}

    try:
        result = surveys.update_item(
            Key={"surveyId": survey_id},
            UpdateExpression="ADD votes.#did :one",
            ConditionExpression="attribute_exists(surveyId) AND #st = :open",
            ExpressionAttributeNames={"#did": design_id, "#st": "status"},
            ExpressionAttributeValues={":one": 1, ":open": "open"},
            ReturnValues="ALL_NEW",
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            post_to_one(event, connection_id, {"type": "error", "reason": "survey_closed"})
            return {"statusCode": 409, "body": "Survey closed"}
        raise

    payload = {
        "type": "designVoteUpdate",
        "surveyId": survey_id,
        "votes": result["Attributes"].get("votes", {}),
    }
    delivered = post_to_session(event, connections, session_id, payload)

    return {"statusCode": 200, "body": json.dumps({"delivered": delivered})}
