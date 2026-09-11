"""Error taxonomy for the POS transaction pipeline.

Scenario section 6 splits consumer failures into two classes, and the whole DLQ
design depends on telling them apart:

* `TransientError`  - the downstream dependency is momentarily unavailable
  (loyalty API 503, tax authority 429, DynamoDB throttling). Retrying is
  useful, so the record is reported as a batch item failure, SQS redelivers it,
  and it only reaches the DLQ once `maxReceiveCount` is exhausted. After the
  dependency recovers the DLQ is redriven and the transaction completes.

* `PermanentError`  - the message itself is unprocessable (`items: null` from
  POS firmware v2.3, a non-JSON body, a negative quantity). Retrying can never
  succeed. The record is still reported as a batch item failure so that SQS
  parks it in the DLQ rather than deleting it — the 2026 incident was caused by
  a `try/except` that swallowed failures and let SQS delete the message, which
  is silent data loss. Visible failure in a DLQ is the goal, not success.

Both carry a `reason` string. That string is emitted on the structured log line
for the record, which is how requirement R5 (trace any DLQ message back to its
failure reason by `transaction_id`) is satisfied.
"""


class ProcessingError(Exception):
    """Base class for every failure the batch loop knows how to classify.

    `reason` is a short, stable, machine-greppable slug-or-sentence describing
    why the record failed. It is logged verbatim, so prefer wording that stays
    constant across deploys — the on-call runbook's Logs Insights query filters
    on it.
    """

    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason

    @property
    def error_type(self):
        """Class name of the error, logged as the `error_type` field."""
        return type(self).__name__


class PermanentError(ProcessingError):
    """The message can never succeed; retrying only wastes invocations."""


class TransientError(ProcessingError):
    """A dependency failed temporarily; the same message may succeed later."""
