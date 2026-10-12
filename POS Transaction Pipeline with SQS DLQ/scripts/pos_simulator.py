#!/usr/bin/env python3
"""POS terminal simulator for the MekarMart transaction pipeline.

Stands in for the 180 stores' POS terminals by publishing transaction messages
to the `pos-transactions` SNS topic. The subscriptions use raw message
delivery, so whatever this script publishes is exactly what each consumer
Lambda receives in `record["body"]`.

Modes map onto the scenario's test cases:

    normal     TC-01  N well-formed transactions
    poison     TC-02  N copies of the firmware v2.3 poison shape (`items: null`)
    duplicate  TC-04  the same `transaction_id` published N times
    mixed      TC-03  N-1 good transactions plus 1 poison in the same burst
    burst      TC-05  N transactions published concurrently (the 50-message
                      Phase 4 outage drill)

Examples:

    ./scripts/pos_simulator.py --mode normal --count 10
    ./scripts/pos_simulator.py --mode mixed --count 10 --dry-run
    ./scripts/pos_simulator.py --mode burst --count 50 --region ap-southeast-1

Nothing is published in `--dry-run`; the payloads are printed instead, which is
the safe way to eyeball the schema before touching a live topic.
"""

import argparse
import json
import random
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

DEFAULT_REGION = "ap-southeast-1"

# Malaysia/Singapore store codes, mirroring scenario section 1: Johor Bahru,
# Kuala Lumpur, Penang and Singapore.
STORE_PREFIXES = ("JB", "KL", "PG", "SG")

# A small, realistic convenience-store catalogue: (sku, unit_price in MYR).
CATALOGUE = (
    ("SKU-100234", 4.50),
    ("SKU-100871", 2.30),
    ("SKU-200145", 12.90),
    ("SKU-200999", 7.80),
    ("SKU-300412", 1.50),
    ("SKU-300777", 25.00),
    ("SKU-400188", 3.20),
    ("SKU-400256", 18.60),
)

# Terraform output names tried in order when --topic-arn is not supplied.
TOPIC_OUTPUT_CANDIDATES = (
    "pos_transactions_topic_arn",
    "sns_topic_arn",
    "transactions_topic_arn",
    "topic_arn",
)

MYT = timezone(timedelta(hours=8))


def store_id(rng):
    """Return a store code such as `JB012`."""
    return "{}{:03d}".format(rng.choice(STORE_PREFIXES), rng.randint(1, 60))


def transaction_id(store, seq, now):
    """Build `TXN-<store>-<YYYYMMDD>-<6-digit seq>` per scenario section 6."""
    return "TXN-{}-{}-{:06d}".format(store, now.strftime("%Y%m%d"), seq)


def build_items(rng):
    """Pick 1-5 catalogue lines with realistic quantities."""
    lines = rng.sample(CATALOGUE, rng.randint(1, 5))
    return [
        {"sku": sku, "qty": rng.randint(1, 4), "unit_price": price}
        for sku, price in lines
    ]


def build_transaction(seq, rng, now=None):
    """Build one well-formed transaction message (scenario section 6 schema)."""
    now = now or datetime.now(MYT)
    store = store_id(rng)
    items = build_items(rng)
    # total_amount must agree with the line items; a mismatch would be a data
    # bug the consumers cannot detect, and this simulator is meant to produce
    # only the failure modes it is asked for.
    total = round(sum(item["qty"] * item["unit_price"] for item in items), 2)

    return {
        "transaction_id": transaction_id(store, seq, now),
        "store_id": store,
        "terminal_id": "POS-{:02d}".format(rng.randint(1, 4)),
        "member_id": "M-{:08d}".format(rng.randint(10000000, 99999999)),
        "timestamp": now.isoformat(timespec="seconds"),
        "items": items,
        "total_amount": total,
        "currency": "MYR",
        "firmware_version": "3.1.0",
    }


def build_poison(seq, rng, now=None):
    """Build the firmware v2.3 poison message from scenario section 6.

    `items` is null, which every consumer rejects as a permanent error, so the
    message burns its `maxReceiveCount` and lands in the DLQ.
    """
    now = now or datetime.now(MYT)
    store = store_id(rng)
    return {
        "transaction_id": transaction_id(store, seq, now),
        "store_id": store,
        "items": None,
        "total_amount": round(rng.uniform(5.0, 60.0), 2),
        "firmware_version": "2.3.0",
    }


def build_payloads(mode, count, rng):
    """Return the list of message bodies for the requested mode."""
    if mode == "poison":
        return [build_poison(i, rng) for i in range(1, count + 1)]

    if mode == "duplicate":
        # One transaction, published `count` times: SQS at-least-once delivery
        # and DLQ redrive both look like this to the consumer.
        transaction = build_transaction(1, rng)
        return [dict(transaction) for _ in range(count)]

    if mode == "mixed":
        payloads = [build_transaction(i, rng) for i in range(1, max(count, 1))]
        payloads.insert(rng.randrange(len(payloads) + 1), build_poison(count, rng))
        return payloads

    # normal and burst share the same payloads; only the send strategy differs.
    return [build_transaction(i, rng) for i in range(1, count + 1)]


def resolve_topic_arn(terraform_dir):
    """Read the topic ARN from `terraform output -raw` in `terraform_dir`."""
    for name in TOPIC_OUTPUT_CANDIDATES:
        try:
            result = subprocess.run(
                ["terraform", "output", "-raw", name],
                cwd=terraform_dir,
                capture_output=True,
                text=True,
                check=False,
            )
        except FileNotFoundError:
            raise SystemExit(
                "terraform not found on PATH; pass --topic-arn explicitly"
            )
        value = result.stdout.strip()
        if result.returncode == 0 and value.startswith("arn:"):
            return value

    raise SystemExit(
        "could not resolve the topic ARN from terraform outputs in {}; "
        "pass --topic-arn explicitly".format(terraform_dir)
    )


def publish_one(client, topic_arn, payload):
    """Publish a single message and return its SNS MessageId."""
    response = client.publish(
        TopicArn=topic_arn,
        Message=json.dumps(payload),
        MessageAttributes={
            "store_id": {
                "DataType": "String",
                "StringValue": payload.get("store_id", "UNKNOWN"),
            }
        },
    )
    return response["MessageId"]


def publish(payloads, topic_arn, region, concurrent):
    """Publish every payload; `concurrent` drives the burst mode fan-out."""
    import boto3  # imported late so --dry-run works without boto3 installed

    client = boto3.client("sns", region_name=region)

    if not concurrent:
        return [publish_one(client, topic_arn, payload) for payload in payloads]

    # Burst mode: the Phase 4 drill needs the 50 messages in the queue before
    # the retry window starts ticking, so they go out in parallel.
    with ThreadPoolExecutor(max_workers=10) as pool:
        futures = [
            pool.submit(publish_one, client, topic_arn, payload)
            for payload in payloads
        ]
        return [future.result() for future in futures]


def summarise(mode, payloads, dry_run, topic_arn, elapsed=None):
    """Print what was (or would have been) sent."""
    poison = sum(1 for p in payloads if p.get("items") is None)
    unique = len({p["transaction_id"] for p in payloads})

    print("")
    print("-" * 62)
    print("mode            : {}".format(mode))
    print("messages        : {}".format(len(payloads)))
    print("unique txn ids  : {}".format(unique))
    print("poison messages : {}".format(poison))
    print("topic           : {}".format(topic_arn if not dry_run else "(dry run)"))
    if elapsed is not None:
        print("elapsed         : {:.2f}s".format(elapsed))
    print("-" * 62)

    if mode == "duplicate":
        print("Expect: points awarded once; the other copies logged duplicate_skipped.")
    elif mode == "poison":
        print("Expect: 5 failed receives per message, then loyalty-dlq depth {}.".format(
            len(payloads)
        ))
    elif mode == "mixed":
        print("Expect: 1 batch item failure; the rest processed exactly once.")


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Publish simulated POS transactions to the pos-transactions SNS topic.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--topic-arn",
        help="SNS topic ARN. Resolved from terraform outputs when omitted.",
    )
    parser.add_argument(
        "--terraform-dir",
        default="terraform",
        help="Directory to run `terraform output` in (default: terraform).",
    )
    parser.add_argument("--region", default=DEFAULT_REGION, help="AWS region.")
    parser.add_argument("--count", type=int, default=10, help="Number of messages.")
    parser.add_argument(
        "--mode",
        choices=("normal", "poison", "duplicate", "mixed", "burst"),
        default="normal",
        help="Traffic pattern to generate.",
    )
    parser.add_argument(
        "--seed", type=int, help="Seed the generator for reproducible payloads."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the payloads and publish nothing.",
    )
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)

    if args.count < 1:
        raise SystemExit("--count must be at least 1")
    if args.mode == "mixed" and args.count < 2:
        raise SystemExit("--mode mixed needs --count >= 2 (N-1 good plus 1 poison)")

    rng = random.Random(args.seed)
    payloads = build_payloads(args.mode, args.count, rng)

    if args.dry_run:
        for payload in payloads:
            print(json.dumps(payload))
        summarise(args.mode, payloads, True, None)
        return 0

    topic_arn = args.topic_arn or resolve_topic_arn(args.terraform_dir)

    started = datetime.now(timezone.utc)
    message_ids = publish(payloads, topic_arn, args.region, args.mode == "burst")
    elapsed = (datetime.now(timezone.utc) - started).total_seconds()

    for payload, message_id in zip(payloads, message_ids):
        print("published {} -> {}".format(payload["transaction_id"], message_id))

    summarise(args.mode, payloads, False, topic_arn, elapsed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
