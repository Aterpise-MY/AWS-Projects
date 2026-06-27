"""Shared fan-out helper bundled into every broadcasting Lambda zip.

Queries the Connections sessionId-index GSI for all connectionIds in a session
and posts a payload to each via the API Gateway Management API. Stale (410 Gone)
connections are pruned from the Connections table.
"""
import json

import boto3
from boto3.dynamodb.conditions import Key


def post_to_session(event, connections_table, session_id, payload):
    """Fan out `payload` (dict) to every active connection in `session_id`."""
    ctx = event["requestContext"]
    endpoint = f"https://{ctx['domainName']}/{ctx['stage']}"
    api = boto3.client("apigatewaymanagementapi", endpoint_url=endpoint)

    items = connections_table.query(
        IndexName="sessionId-index",
        KeyConditionExpression=Key("sessionId").eq(session_id),
    ).get("Items", [])

    data = json.dumps(payload, default=_decimal_default).encode("utf-8")
    delivered = 0
    for item in items:
        connection_id = item["connectionId"]
        try:
            api.post_to_connection(ConnectionId=connection_id, Data=data)
            delivered += 1
        except api.exceptions.GoneException:
            connections_table.delete_item(Key={"connectionId": connection_id})
    return delivered


def post_to_one(event, connection_id, payload):
    """Send `payload` to a single requesting connection only."""
    ctx = event["requestContext"]
    endpoint = f"https://{ctx['domainName']}/{ctx['stage']}"
    api = boto3.client("apigatewaymanagementapi", endpoint_url=endpoint)
    data = json.dumps(payload, default=_decimal_default).encode("utf-8")
    try:
        api.post_to_connection(ConnectionId=connection_id, Data=data)
    except api.exceptions.GoneException:
        pass


def _decimal_default(value):
    # DynamoDB returns numbers as Decimal; render whole numbers as int.
    from decimal import Decimal
    if isinstance(value, Decimal):
        return int(value) if value % 1 == 0 else float(value)
    raise TypeError
