"""Unit tests for the three POS consumers.

Run from the project root with:

    python3 -m unittest discover lambda -v

The tests are deliberately offline: no boto3, no credentials, no network. The
DynamoDB client is replaced with an in-memory fake that honours the same
conditional-write semantics as the real table, because the behaviour under test
is the *contract* between the batch loop and the idempotency store, not the AWS
SDK.

Test ids map to the scenario's section 9 test cases.
"""

import json
import os
import sys
import unittest
from unittest import mock

# `python3 -m unittest discover lambda` already puts `lambda/` on sys.path, but
# adding it explicitly keeps the file runnable directly and under other
# runners. Handlers must import `common` exactly as they do inside Lambda,
# where the whole `lambda/` tree is the package root.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import idempotency  # noqa: E402
from common.errors import PermanentError, TransientError  # noqa: E402
from einvoice import handler as einvoice_handler  # noqa: E402
from inventory import handler as inventory_handler  # noqa: E402
from loyalty import handler as loyalty_handler  # noqa: E402

TABLE_NAME = "pos-processed-transactions"


class _ConditionalCheckFailed(Exception):
    """Stand-in for botocore's ConditionalCheckFailedException."""

    def __init__(self):
        super().__init__("The conditional request failed")
        self.response = {"Error": {"Code": "ConditionalCheckFailedException"}}


class _ThrottlingError(Exception):
    """Stand-in for a retryable DynamoDB failure."""

    def __init__(self):
        super().__init__("Throughput exceeded")
        self.response = {"Error": {"Code": "ProvisionedThroughputExceededException"}}


class FakeDynamoDB:
    """In-memory DynamoDB double honouring `attribute_not_exists` puts."""

    def __init__(self):
        self.items = {}
        self.put_calls = 0
        self.delete_calls = 0
        self.put_error = None

    def put_item(self, TableName=None, Item=None, ConditionExpression=None):  # noqa: N803
        self.put_calls += 1
        if self.put_error is not None:
            raise self.put_error
        key = Item["transaction_id"]["S"]
        if ConditionExpression and key in self.items:
            raise _ConditionalCheckFailed()
        self.items[key] = Item
        return {}

    def delete_item(self, TableName=None, Key=None):  # noqa: N803
        self.delete_calls += 1
        self.items.pop(Key["transaction_id"]["S"], None)
        return {}


def make_transaction(seq=1, store="JB012", **overrides):
    """Build a scenario section 6 transaction message."""
    transaction = {
        "transaction_id": "TXN-{}-20260911-{:06d}".format(store, seq),
        "store_id": store,
        "terminal_id": "POS-03",
        "member_id": "M-88231077",
        "timestamp": "2026-09-11T14:32:05+08:00",
        "items": [{"sku": "SKU-100234", "qty": 2, "unit_price": 4.50}],
        "total_amount": 9.00,
        "currency": "MYR",
        "firmware_version": "3.1.0",
    }
    transaction.update(overrides)
    return transaction


POISON_TRANSACTION = {
    "transaction_id": "TXN-PG004-20260911-000871",
    "store_id": "PG004",
    "items": None,
    "total_amount": 12.80,
    "firmware_version": "2.3.0",
}


def make_record(body, message_id="msg-1", receive_count=1):
    """Build an SQS record as Lambda delivers it with raw message delivery."""
    if not isinstance(body, str):
        body = json.dumps(body)
    return {
        "messageId": message_id,
        "receiptHandle": "rh-{}".format(message_id),
        "body": body,
        "attributes": {"ApproximateReceiveCount": str(receive_count)},
    }


def make_event(records):
    return {"Records": records}


class ConsumerTestCase(unittest.TestCase):
    """Base class wiring the fake table and the baseline environment."""

    service = "loyalty"
    extra_env = {}

    def setUp(self):
        self.dynamodb = FakeDynamoDB()
        patcher = mock.patch.object(idempotency, "_DYNAMODB", self.dynamodb)
        patcher.start()
        self.addCleanup(patcher.stop)

        env = {
            "SERVICE": self.service,
            "IDEMPOTENCY_TABLE": TABLE_NAME,
            "LOG_LEVEL": "INFO",
            "LOYALTY_API_DOWN": "false",
            "EINVOICE_THROTTLE_RATE": "0",
        }
        env.update(self.extra_env)
        env_patcher = mock.patch.dict(os.environ, env, clear=False)
        env_patcher.start()
        self.addCleanup(env_patcher.stop)

    def invoke(self, handler, event):
        """Invoke a handler and return (response, parsed log entries)."""
        with self.assertLogs(level="DEBUG") as captured:
            response = handler.lambda_handler(event, None)
        entries = [json.loads(record.getMessage()) for record in captured.records]
        return response, entries

    def outcomes(self, entries):
        return [entry["outcome"] for entry in entries]


class TestHappyPath(ConsumerTestCase):
    """TC-01 - 10 normal transactions are all processed."""

    def test_tc01_ten_normal_transactions_have_no_batch_item_failures(self):
        records = [
            make_record(make_transaction(seq=i), message_id="msg-{}".format(i))
            for i in range(1, 11)
        ]

        with mock.patch.object(
            loyalty_handler, "award_points", wraps=loyalty_handler.award_points
        ) as side_effect:
            response, entries = self.invoke(loyalty_handler, make_event(records))

        self.assertEqual(response, {"batchItemFailures": []})
        self.assertEqual(side_effect.call_count, 10)
        self.assertEqual(self.outcomes(entries), ["processed"] * 10)
        self.assertEqual(len(self.dynamodb.items), 10)

    def test_points_are_awarded_from_the_whole_currency_amount(self):
        record = make_record(make_transaction(total_amount=9.90))
        _, entries = self.invoke(loyalty_handler, make_event([record]))

        self.assertEqual(entries[0]["detail"]["points_awarded"], 9)


class TestPoisonMessage(ConsumerTestCase):
    """TC-02 - the firmware v2.3 poison message is a permanent failure."""

    def test_tc02_items_null_is_one_permanent_batch_item_failure(self):
        record = make_record(POISON_TRANSACTION, message_id="msg-poison")

        response, entries = self.invoke(loyalty_handler, make_event([record]))

        self.assertEqual(response["batchItemFailures"], [{"itemIdentifier": "msg-poison"}])
        self.assertEqual(self.outcomes(entries), ["permanent_failure"])
        self.assertEqual(entries[0]["error_type"], "PermanentError")
        self.assertIn("items is null", entries[0]["reason"])
        # The side effect never ran, so no claim was taken.
        self.assertEqual(self.dynamodb.items, {})

    def test_non_json_body_is_permanent_and_does_not_crash(self):
        record = make_record("<html>gateway timeout</html>", message_id="msg-junk")

        response, entries = self.invoke(loyalty_handler, make_event([record]))

        self.assertEqual(response["batchItemFailures"], [{"itemIdentifier": "msg-junk"}])
        self.assertEqual(self.outcomes(entries), ["permanent_failure"])
        self.assertIn("not valid JSON", entries[0]["reason"])
        self.assertIsNone(entries[0]["transaction_id"])

    def test_missing_transaction_id_is_permanent(self):
        transaction = make_transaction()
        transaction["transaction_id"] = ""
        record = make_record(transaction, message_id="msg-noid")

        response, entries = self.invoke(loyalty_handler, make_event([record]))

        self.assertEqual(response["batchItemFailures"], [{"itemIdentifier": "msg-noid"}])
        self.assertIn("transaction_id", entries[0]["reason"])


class TestPartialBatchFailure(ConsumerTestCase):
    """TC-03 - one poison record must not drag down the other nine (R2)."""

    def test_tc03_nine_good_one_poison_isolates_the_poison_record(self):
        records = [
            make_record(make_transaction(seq=i), message_id="msg-{}".format(i))
            for i in range(1, 10)
        ]
        records.insert(4, make_record(POISON_TRANSACTION, message_id="msg-poison"))

        with mock.patch.object(
            loyalty_handler, "award_points", wraps=loyalty_handler.award_points
        ) as side_effect:
            response, entries = self.invoke(loyalty_handler, make_event(records))

        self.assertEqual(
            response["batchItemFailures"], [{"itemIdentifier": "msg-poison"}]
        )
        self.assertEqual(side_effect.call_count, 9)
        self.assertEqual(self.outcomes(entries).count("processed"), 9)
        self.assertEqual(self.outcomes(entries).count("permanent_failure"), 1)

    def test_a_failure_in_the_first_record_does_not_abort_the_batch(self):
        records = [
            make_record(POISON_TRANSACTION, message_id="msg-poison"),
            make_record(make_transaction(seq=2), message_id="msg-2"),
        ]

        response, entries = self.invoke(loyalty_handler, make_event(records))

        self.assertEqual(len(response["batchItemFailures"]), 1)
        self.assertEqual(self.outcomes(entries), ["permanent_failure", "processed"])


class TestIdempotency(ConsumerTestCase):
    """TC-04 - a repeated transaction_id awards points exactly once (R4)."""

    def test_tc04_same_transaction_three_times_runs_the_side_effect_once(self):
        transaction = make_transaction(seq=123)
        records = [
            make_record(transaction, message_id="msg-a"),
            make_record(transaction, message_id="msg-b"),
            make_record(transaction, message_id="msg-c"),
        ]

        with mock.patch.object(
            loyalty_handler, "award_points", wraps=loyalty_handler.award_points
        ) as side_effect:
            response, entries = self.invoke(loyalty_handler, make_event(records))

        self.assertEqual(response, {"batchItemFailures": []})
        self.assertEqual(side_effect.call_count, 1)
        self.assertEqual(
            self.outcomes(entries),
            ["processed", "duplicate_skipped", "duplicate_skipped"],
        )
        self.assertEqual(len(self.dynamodb.items), 1)

    def test_duplicate_across_invocations_is_skipped(self):
        transaction = make_transaction(seq=321)
        self.invoke(loyalty_handler, make_event([make_record(transaction, "msg-a")]))

        response, entries = self.invoke(
            loyalty_handler, make_event([make_record(transaction, "msg-b")])
        )

        self.assertEqual(response, {"batchItemFailures": []})
        self.assertEqual(self.outcomes(entries), ["duplicate_skipped"])

    def test_claim_item_carries_service_and_ttl(self):
        record = make_record(make_transaction(seq=7))
        self.invoke(loyalty_handler, make_event([record]))

        item = next(iter(self.dynamodb.items.values()))
        self.assertEqual(item["service"]["S"], "loyalty")
        self.assertIn("expires_at", item)
        self.assertGreater(int(item["expires_at"]["N"]), 0)

    def test_idempotency_store_failure_is_transient_not_permanent(self):
        self.dynamodb.put_error = _ThrottlingError()
        record = make_record(make_transaction(seq=9), message_id="msg-ddb")

        response, entries = self.invoke(loyalty_handler, make_event([record]))

        self.assertEqual(response["batchItemFailures"], [{"itemIdentifier": "msg-ddb"}])
        self.assertEqual(self.outcomes(entries), ["transient_failure"])


class TestLoyaltyOutage(ConsumerTestCase):
    """TC-05 - the Phase 4 outage drill (LOYALTY_API_DOWN=true)."""

    extra_env = {"LOYALTY_API_DOWN": "true"}

    def test_tc05_every_record_is_a_transient_failure_and_the_claim_is_released(self):
        records = [
            make_record(make_transaction(seq=i), message_id="msg-{}".format(i))
            for i in range(1, 11)
        ]

        response, entries = self.invoke(loyalty_handler, make_event(records))

        self.assertEqual(len(response["batchItemFailures"]), 10)
        self.assertEqual(self.outcomes(entries), ["transient_failure"] * 10)
        self.assertEqual(entries[0]["error_type"], "TransientError")
        self.assertEqual(entries[0]["reason"], "loyalty API returned 503")
        # Claims released: a retry must not be mistaken for a duplicate, which
        # would delete the message with the points never awarded.
        self.assertEqual(self.dynamodb.delete_calls, 10)
        self.assertEqual(self.dynamodb.items, {})

    def test_retry_after_recovery_processes_the_transaction(self):
        record = make_record(make_transaction(seq=55), message_id="msg-55")
        self.invoke(loyalty_handler, make_event([record]))

        os.environ["LOYALTY_API_DOWN"] = "false"
        retry = make_record(make_transaction(seq=55), message_id="msg-55", receive_count=2)
        response, entries = self.invoke(loyalty_handler, make_event([retry]))

        self.assertEqual(response, {"batchItemFailures": []})
        self.assertEqual(self.outcomes(entries), ["processed"])
        self.assertEqual(entries[0]["attempt"], 2)


class TestInventoryConsumer(ConsumerTestCase):
    """Inventory-specific validation and side effect."""

    service = "inventory"

    def test_negative_qty_is_a_permanent_inventory_failure(self):
        transaction = make_transaction(
            seq=42, items=[{"sku": "SKU-100234", "qty": -3, "unit_price": 4.50}]
        )
        record = make_record(transaction, message_id="msg-neg")

        response, entries = self.invoke(inventory_handler, make_event([record]))

        self.assertEqual(response["batchItemFailures"], [{"itemIdentifier": "msg-neg"}])
        self.assertEqual(self.outcomes(entries), ["permanent_failure"])
        self.assertIn("negative", entries[0]["reason"])
        self.assertIn("inflate stock", entries[0]["reason"])
        self.assertEqual(self.dynamodb.items, {})

    def test_stock_is_deducted_per_sku(self):
        transaction = make_transaction(
            seq=43,
            items=[
                {"sku": "SKU-1", "qty": 2, "unit_price": 1.00},
                {"sku": "SKU-2", "qty": 1, "unit_price": 3.00},
                {"sku": "SKU-1", "qty": 3, "unit_price": 1.00},
            ],
            total_amount=8.00,
        )

        _, entries = self.invoke(inventory_handler, make_event([make_record(transaction)]))

        self.assertEqual(entries[0]["outcome"], "processed")
        self.assertEqual(entries[0]["detail"]["sku_quantities"], {"SKU-1": 5, "SKU-2": 1})

    def test_inventory_still_rejects_the_shared_poison_shape(self):
        record = make_record(POISON_TRANSACTION, message_id="msg-poison")

        response, entries = self.invoke(inventory_handler, make_event([record]))

        self.assertEqual(len(response["batchItemFailures"]), 1)
        self.assertEqual(entries[0]["service"], "inventory")
        self.assertIn("items is null", entries[0]["reason"])


class TestEinvoiceConsumer(ConsumerTestCase):
    """e-Invoice throttling behaviour (deterministic, no randomness)."""

    service = "einvoice"

    def test_throttle_rate_one_makes_every_record_transient(self):
        os.environ["EINVOICE_THROTTLE_RATE"] = "1.0"
        records = [
            make_record(make_transaction(seq=i), message_id="msg-{}".format(i))
            for i in range(1, 6)
        ]

        response, entries = self.invoke(einvoice_handler, make_event(records))

        self.assertEqual(len(response["batchItemFailures"]), 5)
        self.assertEqual(self.outcomes(entries), ["transient_failure"] * 5)
        self.assertEqual(entries[0]["reason"], "tax authority returned 429")
        self.assertEqual(self.dynamodb.items, {})

    def test_throttle_rate_zero_submits_the_invoice(self):
        os.environ["EINVOICE_THROTTLE_RATE"] = "0"
        record = make_record(make_transaction(seq=8))

        response, entries = self.invoke(einvoice_handler, make_event([record]))

        self.assertEqual(response, {"batchItemFailures": []})
        self.assertEqual(entries[0]["detail"]["currency"], "MYR")
        self.assertEqual(entries[0]["detail"]["line_items"], 1)

    def test_throttling_decision_is_deterministic(self):
        decisions = [
            einvoice_handler._is_throttled("TXN-KL001-20260911-000001", 0.5)
            for _ in range(5)
        ]
        self.assertEqual(len(set(decisions)), 1)

    def test_malformed_throttle_rate_falls_back_to_zero(self):
        os.environ["EINVOICE_THROTTLE_RATE"] = "not-a-number"
        self.assertEqual(einvoice_handler._throttle_rate(), 0.0)


class TestTraceability(ConsumerTestCase):
    """R5 - every record emits exactly one line with the runbook's keys."""

    def test_log_line_carries_the_fields_the_runbook_query_filters_on(self):
        records = [
            make_record(make_transaction(seq=1), message_id="msg-good"),
            make_record(POISON_TRANSACTION, message_id="msg-poison", receive_count=5),
        ]

        _, entries = self.invoke(loyalty_handler, make_event(records))

        self.assertEqual(len(entries), 2)
        for entry in entries:
            for key in (
                "service",
                "transaction_id",
                "store_id",
                "message_id",
                "outcome",
                "error_type",
                "reason",
                "attempt",
            ):
                self.assertIn(key, entry)

        poison = entries[1]
        self.assertEqual(poison["transaction_id"], POISON_TRANSACTION["transaction_id"])
        self.assertEqual(poison["store_id"], "PG004")
        self.assertEqual(poison["message_id"], "msg-poison")
        self.assertEqual(poison["attempt"], 5)

    def test_empty_event_returns_an_empty_failure_list(self):
        self.assertEqual(
            loyalty_handler.lambda_handler({"Records": []}, None),
            {"batchItemFailures": []},
        )


class TestErrorTaxonomy(unittest.TestCase):
    """The error classes carry the reason used on the log line."""

    def test_permanent_and_transient_share_the_reason_contract(self):
        permanent = PermanentError("items is null")
        transient = TransientError("loyalty API returned 503")

        self.assertEqual(permanent.reason, "items is null")
        self.assertEqual(permanent.error_type, "PermanentError")
        self.assertEqual(transient.error_type, "TransientError")


if __name__ == "__main__":
    unittest.main(verbosity=2)
