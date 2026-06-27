"""Handles $connect and $disconnect WebSocket routes.

On $connect: stores connectionId + sessionId (from query string) with a 2-hour TTL.
On $disconnect: removes the connectionId record.
"""
import os
import time

import boto3

CONNECTIONS_TABLE = os.environ["CONNECTIONS_TABLE"]
TTL_SECONDS = int(os.environ.get("CONNECTION_TTL_SECONDS", "7200"))  # 2 hours

dynamodb = boto3.resource("dynamodb")
connections = dynamodb.Table(CONNECTIONS_TABLE)


def lambda_handler(event, context):
    ctx = event["requestContext"]
    route_key = ctx["routeKey"]
    connection_id = ctx["connectionId"]

    if route_key == "$connect":
        params = event.get("queryStringParameters") or {}
        session_id = params.get("sessionId", "default")
        now = int(time.time())
        connections.put_item(Item={
            "connectionId": connection_id,
            "sessionId": session_id,
            "connectedAt": now,
            "ttl": now + TTL_SECONDS,
        })
        return {"statusCode": 200, "body": "Connected"}

    if route_key == "$disconnect":
        connections.delete_item(Key={"connectionId": connection_id})
        return {"statusCode": 200, "body": "Disconnected"}

    return {"statusCode": 400, "body": f"Unsupported route: {route_key}"}
