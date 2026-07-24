#!/usr/bin/env python3
"""Garbage-collect stale Packer-built AMIs and their backing EBS snapshots.

Why this exists
---------------
Deregistering an AMI does NOT delete the EBS snapshot behind it. Every Packer
build that is never cleaned up leaves a ~2-4 GiB snapshot billed monthly,
forever. A CI pipeline that bakes a node image on every merge produces a slow,
silent cost leak that nobody notices until the EBS line item on the bill is
larger than the compute it supports.

This script closes the loop:

  1. Find AMIs owned by this account tagged ``Project=<project>`` whose
     ``CreationDate`` is older than ``--max-age-days``.
  2. Refuse to touch any AMI that is currently referenced by a launch template
     version or a running instance (see ``--skip-in-use`` checks).
  3. Always retain the newest ``--keep-latest`` images regardless of age, so a
     rollback target survives even during a quiet period.
  4. Deregister the AMI, then delete the snapshots that its block device mapping
     pointed at.
  5. Optionally sweep *orphaned* snapshots — tagged ``Project=<project>`` but no
     longer referenced by any AMI — which is where the leak actually accumulates
     when someone deregisters an image by hand in the console.

Safety
------
``--dry-run`` defaults to ON. Nothing is mutated unless ``--no-dry-run`` is
passed explicitly. Every decision is logged with the reason.

Usage
-----
    ./cleanup-old-amis.py                              # report only
    ./cleanup-old-amis.py --max-age-days 30            # report only
    ./cleanup-old-amis.py --no-dry-run                 # actually delete
    ./cleanup-old-amis.py --no-dry-run --include-orphan-snapshots
"""

from __future__ import annotations

import argparse
import logging
import sys
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple

try:
    import boto3
    from botocore.exceptions import BotoCoreError, ClientError
except ImportError:  # pragma: no cover - environment problem, not logic
    print(
        "boto3 is required: pip install boto3",
        file=sys.stderr,
    )
    raise

LOGGER = logging.getLogger("cleanup-old-amis")

DEFAULT_REGION = "ap-southeast-1"
DEFAULT_PROJECT_TAG = "ticketing"
DEFAULT_MAX_AGE_DAYS = 30
DEFAULT_KEEP_LATEST = 3

# EC2 returns CreationDate as an ISO-8601 string with a trailing Z.
_AWS_TIME_FORMATS: Tuple[str, ...] = (
    "%Y-%m-%dT%H:%M:%S.%fZ",
    "%Y-%m-%dT%H:%M:%SZ",
)


class CleanupError(RuntimeError):
    """Raised when the sweep cannot complete safely."""


def configure_logging(verbose: bool) -> None:
    """Set up structured, timestamped logging on stderr."""
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(name)s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S%z",
        stream=sys.stderr,
    )


def parse_aws_timestamp(value: str) -> datetime:
    """Parse an EC2 CreationDate string into an aware UTC datetime."""
    for fmt in _AWS_TIME_FORMATS:
        try:
            return datetime.strptime(value, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    # Fall back to fromisoformat for any future format drift.
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:  # pragma: no cover
        raise CleanupError(f"unparseable AWS timestamp: {value!r}") from exc
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def tags_to_dict(tags: Optional[Sequence[Dict[str, str]]]) -> Dict[str, str]:
    """Convert the EC2 [{Key,Value}] tag shape into a plain dict."""
    return {t["Key"]: t["Value"] for t in (tags or [])}


def get_account_id(session: "boto3.session.Session") -> str:
    """Return the caller's AWS account ID."""
    return str(session.client("sts").get_caller_identity()["Account"])


def describe_project_images(
    ec2: Any, account_id: str, project_tag: str
) -> List[Dict[str, Any]]:
    """Return all self-owned AMIs carrying Project=<project_tag>."""
    paginator = ec2.get_paginator("describe_images")
    images: List[Dict[str, Any]] = []
    for page in paginator.paginate(
        Owners=[account_id],
        Filters=[{"Name": "tag:Project", "Values": [project_tag]}],
    ):
        images.extend(page.get("Images", []))
    LOGGER.info(
        "found %d AMI(s) tagged Project=%s in account %s",
        len(images),
        project_tag,
        account_id,
    )
    return images


def snapshot_ids_for_image(image: Dict[str, Any]) -> List[str]:
    """Extract every EBS snapshot ID referenced by an AMI's device mapping."""
    snapshots: List[str] = []
    for mapping in image.get("BlockDeviceMappings", []):
        ebs = mapping.get("Ebs") or {}
        snapshot_id = ebs.get("SnapshotId")
        if snapshot_id:
            snapshots.append(snapshot_id)
    return snapshots


def images_in_use(ec2: Any) -> Set[str]:
    """Return AMI IDs referenced by a live instance or a launch template version.

    Deleting an AMI that a launch template still points at turns the next node
    scale-out into a hard failure with a cryptic error, so this check is not
    optional.
    """
    in_use: Set[str] = set()

    instance_paginator = ec2.get_paginator("describe_instances")
    for page in instance_paginator.paginate(
        Filters=[
            {
                "Name": "instance-state-name",
                "Values": ["pending", "running", "stopping", "stopped"],
            }
        ]
    ):
        for reservation in page.get("Reservations", []):
            for instance in reservation.get("Instances", []):
                image_id = instance.get("ImageId")
                if image_id:
                    in_use.add(image_id)

    lt_paginator = ec2.get_paginator("describe_launch_templates")
    for page in lt_paginator.paginate():
        for template in page.get("LaunchTemplates", []):
            template_id = template["LaunchTemplateId"]
            version_paginator = ec2.get_paginator("describe_launch_template_versions")
            for vpage in version_paginator.paginate(LaunchTemplateId=template_id):
                for version in vpage.get("LaunchTemplateVersions", []):
                    image_id = (version.get("LaunchTemplateData") or {}).get("ImageId")
                    if image_id:
                        in_use.add(image_id)

    LOGGER.info("%d AMI(s) are referenced by instances or launch templates", len(in_use))
    return in_use


def select_expired_images(
    images: Iterable[Dict[str, Any]],
    cutoff: datetime,
    keep_latest: int,
    in_use: Set[str],
) -> Tuple[List[Dict[str, Any]], List[Tuple[Dict[str, Any], str]]]:
    """Split images into (to_delete, [(image, retention_reason), ...])."""
    ordered = sorted(
        images,
        key=lambda img: parse_aws_timestamp(img["CreationDate"]),
        reverse=True,
    )

    to_delete: List[Dict[str, Any]] = []
    retained: List[Tuple[Dict[str, Any], str]] = []

    for index, image in enumerate(ordered):
        image_id = image["ImageId"]
        created = parse_aws_timestamp(image["CreationDate"])

        if index < keep_latest:
            retained.append((image, f"within newest {keep_latest} (rollback target)"))
            continue
        if image_id in in_use:
            retained.append((image, "referenced by an instance or launch template"))
            continue
        if created >= cutoff:
            age_days = (datetime.now(timezone.utc) - created).days
            retained.append((image, f"only {age_days}d old"))
            continue
        to_delete.append(image)

    return to_delete, retained


def find_orphan_snapshots(
    ec2: Any, account_id: str, project_tag: str, cutoff: datetime
) -> List[Dict[str, Any]]:
    """Return project-tagged snapshots older than the cutoff with no parent AMI.

    These are the real cost leak: a snapshot whose AMI was deregistered by hand
    is invisible in the AMI console view and bills indefinitely.
    """
    referenced: Set[str] = set()
    for image in describe_project_images(ec2, account_id, project_tag):
        referenced.update(snapshot_ids_for_image(image))

    paginator = ec2.get_paginator("describe_snapshots")
    orphans: List[Dict[str, Any]] = []
    for page in paginator.paginate(
        OwnerIds=[account_id],
        Filters=[{"Name": "tag:Project", "Values": [project_tag]}],
    ):
        for snapshot in page.get("Snapshots", []):
            if snapshot["SnapshotId"] in referenced:
                continue
            start_time = snapshot["StartTime"]
            if start_time.tzinfo is None:
                start_time = start_time.replace(tzinfo=timezone.utc)
            if start_time >= cutoff:
                continue
            orphans.append(snapshot)

    LOGGER.info("found %d orphaned snapshot(s) older than the cutoff", len(orphans))
    return orphans


def deregister_image(ec2: Any, image_id: str, dry_run: bool) -> bool:
    """Deregister an AMI. Returns True when the call was actually made."""
    if dry_run:
        LOGGER.info("[dry-run] would deregister AMI %s", image_id)
        return False
    try:
        ec2.deregister_image(ImageId=image_id)
    except (ClientError, BotoCoreError) as exc:
        LOGGER.error("failed to deregister AMI %s: %s", image_id, exc)
        return False
    LOGGER.info("deregistered AMI %s", image_id)
    return True


def delete_snapshot(ec2: Any, snapshot_id: str, dry_run: bool) -> bool:
    """Delete an EBS snapshot. Returns True when the call was actually made."""
    if dry_run:
        LOGGER.info("[dry-run] would delete snapshot %s", snapshot_id)
        return False
    try:
        ec2.delete_snapshot(SnapshotId=snapshot_id)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code == "InvalidSnapshot.InUse":
            LOGGER.warning(
                "snapshot %s still in use by another AMI; leaving it alone",
                snapshot_id,
            )
            return False
        LOGGER.error("failed to delete snapshot %s: %s", snapshot_id, exc)
        return False
    except BotoCoreError as exc:
        LOGGER.error("failed to delete snapshot %s: %s", snapshot_id, exc)
        return False
    LOGGER.info("deleted snapshot %s", snapshot_id)
    return True


def build_parser() -> argparse.ArgumentParser:
    """Construct the CLI parser."""
    parser = argparse.ArgumentParser(
        description=(
            "Deregister stale Packer-built AMIs tagged Project=<tag> and delete "
            "their backing EBS snapshots. Dry-run is ON by default."
        ),
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--region", default=DEFAULT_REGION, help="AWS region to sweep.")
    parser.add_argument(
        "--profile", default=None, help="AWS named profile. Omit to use the default chain."
    )
    parser.add_argument(
        "--project-tag",
        default=DEFAULT_PROJECT_TAG,
        help="Value of the Project tag identifying images this script may delete.",
    )
    parser.add_argument(
        "--max-age-days",
        type=int,
        default=DEFAULT_MAX_AGE_DAYS,
        help="Delete AMIs created more than this many days ago.",
    )
    parser.add_argument(
        "--keep-latest",
        type=int,
        default=DEFAULT_KEEP_LATEST,
        help="Always retain this many newest AMIs regardless of age.",
    )
    parser.add_argument(
        "--include-orphan-snapshots",
        action="store_true",
        help="Also delete project-tagged snapshots that no AMI references any more.",
    )

    dry_run_group = parser.add_mutually_exclusive_group()
    dry_run_group.add_argument(
        "--dry-run",
        dest="dry_run",
        action="store_true",
        default=True,
        help="Report what would happen without mutating anything (default).",
    )
    dry_run_group.add_argument(
        "--no-dry-run",
        dest="dry_run",
        action="store_false",
        help="Actually deregister AMIs and delete snapshots.",
    )

    parser.add_argument("-v", "--verbose", action="store_true", help="Debug logging.")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    """Entry point. Returns a process exit code."""
    args = build_parser().parse_args(argv)
    configure_logging(args.verbose)

    if args.keep_latest < 0:
        LOGGER.error("--keep-latest must be >= 0")
        return 2
    if args.max_age_days < 1:
        LOGGER.error("--max-age-days must be >= 1")
        return 2

    if args.dry_run:
        LOGGER.warning("DRY RUN — nothing will be mutated. Pass --no-dry-run to apply.")

    session = boto3.session.Session(profile_name=args.profile, region_name=args.region)
    ec2 = session.client("ec2")

    try:
        account_id = get_account_id(session)
    except (ClientError, BotoCoreError) as exc:
        LOGGER.error("cannot resolve AWS identity: %s", exc)
        return 1

    cutoff = datetime.now(timezone.utc) - timedelta(days=args.max_age_days)
    LOGGER.info(
        "region=%s account=%s project=%s cutoff=%s keep_latest=%d",
        args.region,
        account_id,
        args.project_tag,
        cutoff.isoformat(),
        args.keep_latest,
    )

    images = describe_project_images(ec2, account_id, args.project_tag)
    if not images:
        LOGGER.info("nothing tagged Project=%s; nothing to do", args.project_tag)
        return 0

    in_use = images_in_use(ec2)
    to_delete, retained = select_expired_images(
        images, cutoff, args.keep_latest, in_use
    )

    for image, reason in retained:
        LOGGER.debug(
            "retaining %s (%s): %s",
            image["ImageId"],
            image.get("Name", "<unnamed>"),
            reason,
        )

    LOGGER.info("%d AMI(s) selected for removal", len(to_delete))

    deregistered = 0
    snapshots_deleted = 0
    for image in to_delete:
        image_id = image["ImageId"]
        tags = tags_to_dict(image.get("Tags"))
        LOGGER.info(
            "removing %s name=%s created=%s git_sha=%s",
            image_id,
            image.get("Name", "<unnamed>"),
            image["CreationDate"],
            tags.get("GitSHA", "<none>"),
        )
        snapshot_ids = snapshot_ids_for_image(image)
        if deregister_image(ec2, image_id, args.dry_run):
            deregistered += 1
        # Snapshot deletion is attempted regardless of dry-run so the report
        # shows the full blast radius; delete_snapshot itself honours dry-run.
        for snapshot_id in snapshot_ids:
            if delete_snapshot(ec2, snapshot_id, args.dry_run):
                snapshots_deleted += 1

    orphans_deleted = 0
    if args.include_orphan_snapshots:
        for snapshot in find_orphan_snapshots(
            ec2, account_id, args.project_tag, cutoff
        ):
            snapshot_id = snapshot["SnapshotId"]
            LOGGER.info(
                "orphan snapshot %s size=%dGiB started=%s",
                snapshot_id,
                snapshot.get("VolumeSize", 0),
                snapshot["StartTime"],
            )
            if delete_snapshot(ec2, snapshot_id, args.dry_run):
                orphans_deleted += 1

    LOGGER.info(
        "summary: amis_deregistered=%d snapshots_deleted=%d orphans_deleted=%d dry_run=%s",
        deregistered,
        snapshots_deleted,
        orphans_deleted,
        args.dry_run,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
