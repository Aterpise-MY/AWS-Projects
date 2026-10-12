"""e-Invoice consumer: submits the transaction to the tax authority API.

The tax API is rate limited and answers HTTP 429 under load, which is why this
lane is configured with `maxReceiveCount = 8` and a 360 s visibility timeout
(scenario section 5): a roughly 48-minute retry window absorbs throttling
without parking compliance records in a DLQ.

`EINVOICE_THROTTLE_RATE` (0-1) simulates that throttling. The decision is made
from a stable hash of the `transaction_id` rather than `random`, so the same
transaction is throttled on every attempt within a run and the unit tests are
reproducible. Note this means a retry of a throttled transaction is throttled
again at the same rate setting - the drill clears by lowering the rate, which
is the point: the tax authority recovering is what unblocks the lane.
"""

import hashlib
import os

from common.errors import TransientError
from common.processing import process_batch

SERVICE = os.environ.get("SERVICE", "einvoice")

_HASH_SPACE = 2 ** 32


def _throttle_rate():
    """Read the simulated 429 rate, tolerating an unset or malformed value."""
    try:
        return max(0.0, min(1.0, float(os.environ.get("EINVOICE_THROTTLE_RATE", "0"))))
    except ValueError:
        return 0.0


def _is_throttled(transaction_id, rate):
    """Deterministically decide whether this transaction is rate limited."""
    if rate <= 0:
        return False
    digest = hashlib.sha256(transaction_id.encode("utf-8")).digest()
    position = int.from_bytes(digest[:4], "big") / _HASH_SPACE
    return position < rate


def submit_einvoice(transaction):
    """Submit the e-invoice, failing transiently when the API throttles us."""
    transaction_id = transaction["transaction_id"]
    if _is_throttled(transaction_id, _throttle_rate()):
        raise TransientError("tax authority returned 429")

    return {
        "invoice_amount": transaction.get("total_amount"),
        "currency": transaction.get("currency", "MYR"),
        "line_items": len(transaction["items"]),
    }


def lambda_handler(event, context):
    """SQS entry point. Returns `batchItemFailures` for the failed records."""
    return process_batch(
        event,
        validate=None,
        side_effect=submit_einvoice,
        service=os.environ.get("SERVICE", SERVICE),
    )
