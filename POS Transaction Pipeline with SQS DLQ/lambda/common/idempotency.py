"""DynamoDB-backed idempotency claims for POS transactions.

Requirement R4 says a DLQ redrive must not award loyalty points twice. SQS
Standard queues are at-least-once by design, and a redrive deliberately replays
messages, so exactly-once processing has to be enforced by the consumer rather
than by the queue.

The mechanism is a conditional write against the `processed-transactions`
table: `PutItem` with `attribute_not_exists(transaction_id)`. The write is
atomic, so of N concurrent invocations holding the same `transaction_id`
exactly one wins the claim and the rest are told to skip. Items carry a 7-day
TTL (`expires_at`), which is longer than the 4-day source-queue retention plus
a realistic redrive window, so a message can never outlive its own claim record
and get processed twice.

The claim is taken BEFORE the side effect, never after: a claim taken after a
successful side effect would leave a window in which the function dies between
the two and the retry double-awards.
"""

import os
import time
from datetime import datetime, timezone

from common.errors import TransientError

# The client is created lazily and cached at module scope rather than at import
# time. Two reasons: a cold start that never touches DynamoDB does not pay for
# the client construction, and the unit tests can swap `_DYNAMODB` for a fake
# without boto3 (or AWS credentials) being present at all.
_DYNAMODB = None

_CONDITIONAL_CHECK_FAILED = "ConditionalCheckFailedException"


def _dynamodb_client():
    """Return the cached DynamoDB client, creating it on first use."""
    global _DYNAMODB
    if _DYNAMODB is None:
        import boto3  # imported here so the module is importable without boto3

        _DYNAMODB = boto3.client("dynamodb")
    return _DYNAMODB


def _table_name():
    """Read the table name at call time so tests can set it per test case."""
    return os.environ.get("IDEMPOTENCY_TABLE", "")


def _error_code(exc):
    """Extract the AWS error code from a botocore exception.

    Matching on the error code rather than on
    `client.exceptions.ConditionalCheckFailedException` keeps this module free
    of a hard botocore import and, more practically, keeps it working when the
    client is a test double whose `.exceptions` attribute is not a real
    exception class.
    """
    response = getattr(exc, "response", None)
    if isinstance(response, dict):
        code = response.get("Error", {}).get("Code")
        if code:
            return code
    return type(exc).__name__


def claim(transaction_id, service, ttl_days=7):
    """Attempt to claim `transaction_id` for processing.

    Returns True when this invocation won the claim and must do the work, and
    False when the transaction was already processed and must be skipped. A
    False result is a success, not a failure: it is exactly what makes a DLQ
    redrive safe to run more than once.

    Any other DynamoDB failure is raised as a `TransientError` so the record is
    retried instead of being dropped — an unavailable idempotency store must
    never be a reason to lose a transaction.
    """
    now = time.time()
    item = {
        "transaction_id": {"S": transaction_id},
        "service": {"S": service},
        "processed_at": {"S": datetime.now(timezone.utc).isoformat()},
        "expires_at": {"N": str(int(now) + ttl_days * 86400)},
    }

    try:
        _dynamodb_client().put_item(
            TableName=_table_name(),
            Item=item,
            ConditionExpression="attribute_not_exists(transaction_id)",
        )
    except Exception as exc:  # noqa: BLE001 - re-raised below unless it is the claim race
        if _error_code(exc) == _CONDITIONAL_CHECK_FAILED:
            return False
        raise TransientError("idempotency store unavailable: {}".format(_error_code(exc)))

    return True


def release(transaction_id):
    """Delete a claim that was taken but whose work did not complete.

    This is the counterpart that makes the claim safe on a transient failure.
    Sequence without it:

        1. attempt 1 claims TXN-A, the loyalty API returns 503, the record is
           reported as a batch item failure and SQS redelivers it;
        2. attempt 2 finds the claim already present, logs `duplicate_skipped`
           and reports success;
        3. SQS deletes the message. The points were never awarded and nothing
           ever reaches the DLQ.

    That is precisely the silent data loss the project exists to eliminate, so
    the claim is released whenever the side effect fails. Releasing is
    best-effort: if the delete itself fails the message is still going to be
    retried, and a stale claim is handled by the 7-day TTL.
    """
    try:
        _dynamodb_client().delete_item(
            TableName=_table_name(),
            Key={"transaction_id": {"S": transaction_id}},
        )
        return True
    except Exception:  # noqa: BLE001 - never mask the original processing error
        return False
