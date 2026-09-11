"""Shared SQS batch loop, validation and structured logging.

Everything the three consumers have in common lives here so that loyalty,
inventory and e-invoice cannot drift apart in how they classify and report
failures.

Two behaviours in this module are the heart of the project:

1. **Partial batch responses.** The event source mapping is created with
   `function_response_types = ["ReportBatchItemFailures"]`. Without it, one bad
   record in a batch of ten makes the whole invocation fail, so SQS redelivers
   all ten and the nine good transactions are processed again and again — which
   both wastes the retry budget of the poison message and, without idempotency,
   would award points repeatedly. By catching per record and returning only the
   failed `messageId`s, a poison message is isolated to itself (requirement R2).

2. **One structured JSON log line per record.** The on-call runbook traces a
   DLQ message back to its failure reason with a CloudWatch Logs Insights query
   over these fields (requirement R5), so the key names below are a contract:
   `service`, `transaction_id`, `store_id`, `message_id`, `outcome`,
   `error_type`, `reason`, `attempt`. Do not rename them without updating the
   runbook query.
"""

import json
import logging
import os

from common.errors import PermanentError, ProcessingError
from common.idempotency import claim, release

LOGGER = logging.getLogger()
LOGGER.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())

OUTCOME_PROCESSED = "processed"
OUTCOME_DUPLICATE = "duplicate_skipped"
OUTCOME_PERMANENT = "permanent_failure"
OUTCOME_TRANSIENT = "transient_failure"

_OUTCOME_LEVELS = {
    OUTCOME_PROCESSED: logging.INFO,
    OUTCOME_DUPLICATE: logging.INFO,
    OUTCOME_PERMANENT: logging.ERROR,
    OUTCOME_TRANSIENT: logging.WARNING,
}


def process_batch(event, validate, side_effect, service):
    """Process one SQS batch and return the partial-batch-failure response.

    `validate` is an optional per-service hook (it may be None) that receives
    the parsed transaction and raises `PermanentError` for service-specific
    poison shapes. `side_effect` performs the actual downstream work and may
    raise `TransientError`; anything it returns is merged into the record's log
    line as `detail`.

    Records are handled strictly one at a time and every failure is contained,
    so a failure in record 3 can never prevent records 4..10 from being
    processed.
    """
    failures = []

    for record in event.get("Records") or []:
        failures.extend(_process_record(record, validate, side_effect, service))

    return {"batchItemFailures": failures}


def _process_record(record, validate, side_effect, service):
    """Handle a single SQS record; return zero or one batch item failure."""
    message_id = record.get("messageId", "")
    attempt = _attempt(record)
    transaction_id = None
    store_id = None

    try:
        transaction = _parse_body(record)
        transaction_id = transaction.get("transaction_id")
        store_id = transaction.get("store_id")

        # The service hook runs before the shared rules so a service can give a
        # breach a more specific reason than the generic rule would (inventory
        # classifies a negative quantity as its own failure mode, for example).
        if validate is not None:
            validate(transaction)
        validate_transaction(transaction)

        # Claim before any side effect. A duplicate is a success: it is what
        # lets the DLQ be redriven repeatedly without double-awarding points.
        if not claim(transaction_id, service):
            _log(service, transaction_id, store_id, message_id, OUTCOME_DUPLICATE, attempt)
            return []

        try:
            detail = side_effect(transaction) or {}
        except ProcessingError:
            # The work did not complete, so the claim must not be left behind:
            # the retry would otherwise see a duplicate, skip it and let SQS
            # delete the message with the transaction never applied.
            release(transaction_id)
            raise

        _log(
            service,
            transaction_id,
            store_id,
            message_id,
            OUTCOME_PROCESSED,
            attempt,
            detail=detail,
        )
        return []

    except ProcessingError as exc:
        outcome = OUTCOME_PERMANENT if isinstance(exc, PermanentError) else OUTCOME_TRANSIENT
        _log(
            service,
            transaction_id,
            store_id,
            message_id,
            outcome,
            attempt,
            error_type=exc.error_type,
            reason=exc.reason,
        )
        return [{"itemIdentifier": message_id}]

    except Exception as exc:  # noqa: BLE001 - an unclassified bug must still be visible
        # An unexpected exception is treated as transient. A bug in our own code
        # is usually fixed by a redeploy, and retrying costs a few invocations;
        # treating it as permanent would park a perfectly valid transaction in
        # the DLQ. Either way it is logged and never silently dropped.
        _log(
            service,
            transaction_id,
            store_id,
            message_id,
            OUTCOME_TRANSIENT,
            attempt,
            error_type=type(exc).__name__,
            reason="unhandled exception: {}".format(exc),
        )
        return [{"itemIdentifier": message_id}]


def _parse_body(record):
    """Parse `record["body"]` as a transaction object.

    The SNS subscriptions use `raw_message_delivery = true`, so the body is the
    transaction JSON itself rather than an SNS envelope. A body that is not
    JSON, or that is JSON but not an object, can never become valid no matter
    how often it is retried, so it is permanent.
    """
    body = record.get("body")
    if body is None:
        raise PermanentError("record has no body")

    try:
        transaction = json.loads(body)
    except (json.JSONDecodeError, TypeError) as exc:
        raise PermanentError("body is not valid JSON: {}".format(exc))

    if not isinstance(transaction, dict):
        raise PermanentError("body is not a JSON object")

    return transaction


def validate_transaction(transaction):
    """Apply the validation rules shared by all three consumers.

    Every breach here is a `PermanentError`: the payload is structurally wrong
    and no number of retries will change it. The case that matters most is
    `items: null`, the poison message emitted by POS firmware v2.3 that retried
    for four days during the 2026 incident before expiring unnoticed.
    """
    transaction_id = transaction.get("transaction_id")
    if not isinstance(transaction_id, str) or not transaction_id.strip():
        raise PermanentError("transaction_id is missing or empty")

    if "items" not in transaction:
        raise PermanentError("items field is missing")

    items = transaction.get("items")
    if items is None:
        # Firmware v2.3 poison shape.
        raise PermanentError("items is null (POS firmware v2.3 poison message)")
    if not isinstance(items, list):
        raise PermanentError("items is not a list")
    if not items:
        raise PermanentError("items is empty")

    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise PermanentError("items[{}] is not an object".format(index))

        sku = item.get("sku")
        if not isinstance(sku, str) or not sku.strip():
            raise PermanentError("items[{}].sku is missing or empty".format(index))

        qty = item.get("qty")
        if not _is_number(qty):
            raise PermanentError("items[{}].qty is missing or not a number".format(index))
        if qty <= 0:
            raise PermanentError("items[{}].qty must be greater than zero".format(index))

        unit_price = item.get("unit_price")
        if not _is_number(unit_price):
            raise PermanentError(
                "items[{}].unit_price is missing or not a number".format(index)
            )
        if unit_price < 0:
            raise PermanentError("items[{}].unit_price must not be negative".format(index))

    total_amount = transaction.get("total_amount")
    if not _is_number(total_amount):
        raise PermanentError("total_amount is missing or not a number")
    if total_amount < 0:
        raise PermanentError("total_amount must not be negative")


def _is_number(value):
    """True for ints and floats, excluding bool (a bool is not a quantity)."""
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _attempt(record):
    """Read `ApproximateReceiveCount` so the log shows which retry this is.

    The count climbing towards `maxReceiveCount` in the logs is the visible
    evidence that a message is about to be parked in the DLQ.
    """
    try:
        return int((record.get("attributes") or {}).get("ApproximateReceiveCount", 1))
    except (TypeError, ValueError):
        return 1


def _log(
    service,
    transaction_id,
    store_id,
    message_id,
    outcome,
    attempt,
    error_type=None,
    reason=None,
    detail=None,
):
    """Emit the single structured JSON line that describes this record."""
    entry = {
        "service": service,
        "transaction_id": transaction_id,
        "store_id": store_id,
        "message_id": message_id,
        "outcome": outcome,
        "error_type": error_type,
        "reason": reason,
        "attempt": attempt,
    }
    if detail:
        entry["detail"] = detail

    LOGGER.log(_OUTCOME_LEVELS.get(outcome, logging.INFO), json.dumps(entry, default=str))
