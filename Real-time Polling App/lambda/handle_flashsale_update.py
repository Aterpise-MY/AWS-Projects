"""Scenario 2 — Route: flashPurchase — flash sale inventory tracker.

Payload: {"action": "flashPurchase", "itemId": "...", "sessionId": "..."}
Atomically decrements remainingStock (guarded by remainingStock > 0) and
increments purchaseCount. Broadcasts new stock to the session, or returns
sold_out to the requesting client only.
"""
import json
import os

import boto3
from botocore.exceptions import ClientError

from _broadcast import post_to_session, post_to_one

FLASHSALE_TABLE = os.environ["FLASHSALE_TABLE"]
CONNECTIONS_TABLE = os.environ["CONNECTIONS_TABLE"]

dynamodb = boto3.resource("dynamodb")
items = dynamodb.Table(FLASHSALE_TABLE)
connections = dynamodb.Table(CONNECTIONS_TABLE)


def lambda_handler(event, context):
    body = json.loads(event.get("body") or "{}")
    item_id = body.get("itemId")
    session_id = body.get("sessionId", "default")
    connection_id = event["requestContext"]["connectionId"]

    if not item_id:
        return {"statusCode": 400, "body": "itemId is required"}

    try:
        result = items.update_item(
            Key={"itemId": item_id},
            UpdateExpression="SET remainingStock = remainingStock - :one, "
                             "purchaseCount = purchaseCount + :one",
            ConditionExpression="remainingStock > :zero",
            ExpressionAttributeValues={":one": 1, ":zero": 0},
            ReturnValues="ALL_NEW",
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            # Stock depleted — flip status and notify only the buyer.
            try:
                items.update_item(
                    Key={"itemId": item_id},
                    UpdateExpression="SET #st = :sold",
                    ExpressionAttributeNames={"#st": "status"},
                    ExpressionAttributeValues={":sold": "sold_out"},
                )
            except ClientError:
                pass
            post_to_one(event, connection_id, {"type": "flashSale", "itemId": item_id, "status": "sold_out"})
            return {"statusCode": 200, "body": json.dumps({"status": "sold_out"})}
        raise

    attrs = result["Attributes"]
    remaining = attrs.get("remainingStock", 0)
    status = "sold_out" if remaining == 0 else attrs.get("status", "active")
    if status == "sold_out":
        items.update_item(
            Key={"itemId": item_id},
            UpdateExpression="SET #st = :sold",
            ExpressionAttributeNames={"#st": "status"},
            ExpressionAttributeValues={":sold": "sold_out"},
        )

    payload = {
        "type": "flashSaleUpdate",
        "itemId": item_id,
        "remainingStock": remaining,
        "purchaseCount": attrs.get("purchaseCount", 0),
        "status": status,
    }
    delivered = post_to_session(event, connections, session_id, payload)

    return {"statusCode": 200, "body": json.dumps({"delivered": delivered, "remainingStock": int(remaining)})}
