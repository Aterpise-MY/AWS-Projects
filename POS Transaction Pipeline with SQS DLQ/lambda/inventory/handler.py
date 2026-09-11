"""Inventory consumer: deducts store stock for a completed POS transaction.

Inventory has no flaky external dependency, so its failure mode is bad data
rather than outages. It adds one service-specific permanent rule on top of the
shared validation: a negative quantity. A negative `qty` would silently *add*
stock instead of deducting it, which is worse than a rejected message, so it is
classified explicitly and sent to `inventory-dlq` with an inventory-specific
reason for Store Ops to act on.
"""

import os

from common.errors import PermanentError
from common.processing import process_batch

SERVICE = os.environ.get("SERVICE", "inventory")


def validate_quantities(transaction):
    """Reject negative quantities with an inventory-specific reason.

    This runs before the shared rules (which would report the generic "qty must
    be greater than zero") so the DLQ message carries the reason that tells the
    on-call engineer a terminal is sending stock-inflating records.
    """
    items = transaction.get("items")
    if not isinstance(items, list):
        return  # shape problems are the shared validator's job

    for index, item in enumerate(items):
        if not isinstance(item, dict):
            continue
        qty = item.get("qty")
        if isinstance(qty, (int, float)) and not isinstance(qty, bool) and qty < 0:
            raise PermanentError(
                "items[{}].qty is negative ({}): would inflate stock on hand".format(
                    index, qty
                )
            )


def deduct_stock(transaction):
    """Deduct the sold quantities from the store's stock on hand."""
    quantities = {}
    for item in transaction["items"]:
        sku = item["sku"]
        quantities[sku] = quantities.get(sku, 0) + item["qty"]

    return {"store_id": transaction.get("store_id"), "sku_quantities": quantities}


def lambda_handler(event, context):
    """SQS entry point. Returns `batchItemFailures` for the failed records."""
    return process_batch(
        event,
        validate=validate_quantities,
        side_effect=deduct_stock,
        service=os.environ.get("SERVICE", SERVICE),
    )
