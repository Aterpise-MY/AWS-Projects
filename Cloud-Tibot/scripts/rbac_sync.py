#!/usr/bin/env python3
"""
rbac_sync.py — Idempotent seed script for the rbac-config DynamoDB table.

Usage:
    AWS_PROFILE=your-profile python scripts/rbac_sync.py [--dry-run]

Environment variables (all optional, fall back to defaults below):
    AWS_REGION          — default: us-east-1
    RBAC_TABLE_NAME     — default: rbac-config
    RBAC_SEED_FILE      — default: infrastructure/rbac-seed.json

The script performs put_item for each entry in the seed file (idempotent because
user_id is the partition key — re-running won't create duplicates).

Comment entries (those without a "user_id" key) are silently skipped.
"""

import argparse
import json
import os
import sys
from pathlib import Path

import boto3
from botocore.exceptions import ClientError

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
TABLE_NAME = os.environ.get("RBAC_TABLE_NAME", "rbac-config")

_SCRIPT_DIR = Path(__file__).resolve().parent
_WORKSPACE_ROOT = _SCRIPT_DIR.parent
SEED_FILE = Path(os.environ.get("RBAC_SEED_FILE", str(_WORKSPACE_ROOT / "infrastructure" / "rbac-seed.json")))

VALID_ROLES = {"viewer", "approver", "deployer"}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _load_seed(path: Path) -> list[dict]:
    with path.open() as fh:
        data = json.load(fh)
    # Filter out comment-only entries (those without user_id)
    return [entry for entry in data if "user_id" in entry]


def _validate_entry(entry: dict, idx: int) -> bool:
    """Return True if entry is valid; print error and return False otherwise."""
    if not entry.get("user_id"):
        print(f"  [SKIP] Entry #{idx}: missing user_id", file=sys.stderr)
        return False
    if entry.get("role") not in VALID_ROLES:
        print(f"  [ERROR] Entry #{idx} (user_id={entry['user_id']}): invalid role '{entry.get('role')}'. "
              f"Valid roles: {sorted(VALID_ROLES)}", file=sys.stderr)
        return False
    return True


def _sync(entries: list[dict], dry_run: bool) -> int:
    """Write entries to DynamoDB. Returns the number of written entries."""
    dynamodb = boto3.client("dynamodb", region_name=AWS_REGION)
    written = 0

    for idx, entry in enumerate(entries, start=1):
        if not _validate_entry(entry, idx):
            continue

        item = {
            "user_id":      {"S": str(entry["user_id"])},
            "role":         {"S": entry["role"]},
            "username":     {"S": entry.get("username", "")},
            "display_name": {"S": entry.get("display_name", "")},
        }

        if dry_run:
            print(f"  [DRY-RUN] Would write: user_id={entry['user_id']} role={entry['role']}")
            written += 1
            continue

        try:
            dynamodb.put_item(TableName=TABLE_NAME, Item=item)
            print(f"  ✅ Written: user_id={entry['user_id']} role={entry['role']} ({entry.get('display_name', '')})")
            written += 1
        except ClientError as exc:
            code = exc.response["Error"]["Code"]
            print(f"  ❌ Failed to write user_id={entry['user_id']}: {code} — {exc.response['Error']['Message']}",
                  file=sys.stderr)

    return written


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="Seed rbac-config DynamoDB table from JSON file")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print what would be written without making any DynamoDB calls")
    args = parser.parse_args()

    print(f"RBAC Sync — table: {TABLE_NAME} | region: {AWS_REGION}")
    print(f"Seed file: {SEED_FILE}")

    if not SEED_FILE.exists():
        print(f"❌ Seed file not found: {SEED_FILE}", file=sys.stderr)
        sys.exit(1)

    entries = _load_seed(SEED_FILE)
    print(f"Loaded {len(entries)} user entr{'y' if len(entries) == 1 else 'ies'} (comments excluded)\n")

    if not entries:
        print("Nothing to write — seed file contains no valid entries.")
        sys.exit(0)

    written = _sync(entries, dry_run=args.dry_run)

    tag = "[DRY-RUN] " if args.dry_run else ""
    print(f"\n{tag}Done. {written}/{len(entries)} entries processed.")


if __name__ == "__main__":
    main()
