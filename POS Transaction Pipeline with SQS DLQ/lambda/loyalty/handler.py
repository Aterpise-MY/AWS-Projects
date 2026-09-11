"""Loyalty consumer: awards member points for a completed POS transaction.

The third-party loyalty platform is the dependency that failed for 40 minutes
during the 2026 Chinese New Year promotion and cost 3,140 transactions their
points, because the old consumer swallowed the timeout and let SQS delete the
message. Here an API failure raises `TransientError`, which reports the record
as a batch item failure so SQS redelivers it and, once `maxReceiveCount` (5) is
exhausted, parks it in `loyalty-dlq` where it is visible and replayable.

`LOYALTY_API_DOWN=true` simulates that outage for the Phase 4 drill.
"""

import os

from common.errors import TransientError
from common.processing import process_batch

SERVICE = os.environ.get("SERVICE", "loyalty")


def award_points(transaction):
    """Award loyalty points, or fail transiently while the platform is down.

    One point per whole currency unit spent; the fractional remainder is
    dropped rather than rounded up, matching the loyalty platform's own rule.
    """
    if os.environ.get("LOYALTY_API_DOWN", "false").strip().lower() == "true":
        raise TransientError("loyalty API returned 503")

    points = int(transaction.get("total_amount", 0))
    return {"member_id": transaction.get("member_id"), "points_awarded": points}


def lambda_handler(event, context):
    """SQS entry point. Returns `batchItemFailures` for the failed records."""
    return process_batch(
        event,
        validate=None,
        side_effect=award_points,
        service=os.environ.get("SERVICE", SERVICE),
    )
