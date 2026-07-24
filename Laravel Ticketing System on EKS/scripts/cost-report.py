#!/usr/bin/env python3
"""Cost report for the ticketing platform, broken down by the ``Component`` tag.

Queries AWS Cost Explorer (``ce:GetCostAndUsage``) for a trailing window,
groups unblended cost by the ``Component`` cost-allocation tag, and compares
each component against the immediately preceding window of the same length.

Every module in ``terraform/`` merges a ``Component`` value into its tags
(``network``, ``compute``, ``registry``, ``data``), so this report answers
"which layer of the stack is the money going to" rather than the far less
useful "which AWS service is the money going to".

Example
-------
    ./scripts/cost-report.py --days 7 --profile default
    ./scripts/cost-report.py --days 30 --json > cost.json

Requires the ``Component`` tag to be activated as a cost-allocation tag in
Billing -> Cost allocation tags. Until that is done AWS returns every row under
the empty key, which this script renders as ``(untagged)``.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import logging
import sys
from typing import Any, Dict, List, Optional, Tuple

try:
    import boto3
    from botocore.exceptions import BotoCoreError, ClientError
except ImportError:  # pragma: no cover - dependency guard
    print("boto3 is required: pip install boto3", file=sys.stderr)
    raise SystemExit(2)

LOGGER = logging.getLogger("cost-report")

TAG_KEY = "Component"
METRIC = "UnblendedCost"

# Cost Explorer is a global service with a single regional endpoint. Sending the
# request anywhere else fails with an endpoint resolution error, so the client is
# pinned here regardless of --region (which still selects the session/profile
# region for anything else and is recorded in the output for traceability).
CE_ENDPOINT_REGION = "us-east-1"


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        prog="cost-report.py",
        description="Cost Explorer report grouped by the Component tag, "
        "compared against the previous period of equal length.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--days", type=int, default=7,
                        help="Length of the reporting window in days (1-180)")
    parser.add_argument("--profile", default=None,
                        help="AWS named profile to use")
    parser.add_argument("--region", default="ap-southeast-1",
                        help="AWS region for the session (Cost Explorer itself "
                             "is always queried via us-east-1)")
    parser.add_argument("--granularity", default="DAILY", choices=("DAILY", "MONTHLY"),
                        help="Cost Explorer granularity for the underlying query")
    parser.add_argument("--json", dest="as_json", action="store_true",
                        help="Emit machine-readable JSON instead of a table")
    parser.add_argument("--log-level", default="INFO",
                        choices=("DEBUG", "INFO", "WARNING", "ERROR"),
                        help="Logging verbosity")
    args = parser.parse_args(argv)
    if not 1 <= args.days <= 180:
        parser.error("--days must be between 1 and 180")
    return args


def configure_logging(level: str) -> None:
    """Send structured logs to stderr so --json output on stdout stays clean."""
    logging.basicConfig(
        level=getattr(logging, level),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%SZ",
        stream=sys.stderr,
    )
    logging.Formatter.converter = lambda *_: dt.datetime.now(dt.timezone.utc).timetuple()


def periods(days: int) -> Tuple[Tuple[str, str], Tuple[str, str]]:
    """Return ((current_start, current_end), (previous_start, previous_end)).

    Cost Explorer end dates are exclusive. Today is excluded because the current
    day is always partial and would make every component look like it is
    trending down.
    """
    today = dt.datetime.now(dt.timezone.utc).date()
    cur_end = today
    cur_start = cur_end - dt.timedelta(days=days)
    prev_end = cur_start
    prev_start = prev_end - dt.timedelta(days=days)
    fmt = "%Y-%m-%d"
    return (
        (cur_start.strftime(fmt), cur_end.strftime(fmt)),
        (prev_start.strftime(fmt), prev_end.strftime(fmt)),
    )


def fetch_costs(client: Any, start: str, end: str, granularity: str) -> Dict[str, float]:
    """Return {component: total unblended cost} for [start, end)."""
    totals: Dict[str, float] = {}
    next_token: Optional[str] = None
    page = 0
    while True:
        page += 1
        kwargs: Dict[str, Any] = {
            "TimePeriod": {"Start": start, "End": end},
            "Granularity": granularity,
            "Metrics": [METRIC],
            "GroupBy": [{"Type": "TAG", "Key": TAG_KEY}],
        }
        if next_token:
            kwargs["NextPageToken"] = next_token
        LOGGER.debug("GetCostAndUsage page=%d window=%s..%s", page, start, end)
        response = client.get_cost_and_usage(**kwargs)

        for result in response.get("ResultsByTime", []):
            for group in result.get("Groups", []):
                # Keys come back as "Component$compute"; "Component$" means untagged.
                raw_key = group["Keys"][0]
                component = raw_key.split("$", 1)[1] if "$" in raw_key else raw_key
                component = component or "(untagged)"
                amount = float(group["Metrics"][METRIC]["Amount"])
                totals[component] = totals.get(component, 0.0) + amount

        next_token = response.get("NextPageToken")
        if not next_token:
            break
    LOGGER.info("window %s..%s -> %d component(s) across %d page(s)",
                start, end, len(totals), page)
    return totals


def build_report(current: Dict[str, float], previous: Dict[str, float],
                 cur_period: Tuple[str, str], prev_period: Tuple[str, str],
                 region: str) -> Dict[str, Any]:
    """Assemble the comparison structure, sorted by current cost descending."""
    rows: List[Dict[str, Any]] = []
    for component in sorted(set(current) | set(previous),
                            key=lambda c: current.get(c, 0.0), reverse=True):
        now = round(current.get(component, 0.0), 4)
        before = round(previous.get(component, 0.0), 4)
        delta = round(now - before, 4)
        pct: Optional[float] = round(delta / before * 100.0, 1) if before else None
        rows.append({"component": component, "current": now, "previous": before,
                     "delta": delta, "delta_pct": pct})
    return {
        "region": region,
        "tag_key": TAG_KEY,
        "metric": METRIC,
        "current_period": {"start": cur_period[0], "end": cur_period[1]},
        "previous_period": {"start": prev_period[0], "end": prev_period[1]},
        "components": rows,
        "total_current": round(sum(current.values()), 4),
        "total_previous": round(sum(previous.values()), 4),
    }


def render_table(report: Dict[str, Any]) -> str:
    """Render the report as a fixed-width table (no emoji, per repo style rules)."""
    cur, prev = report["current_period"], report["previous_period"]
    lines: List[str] = [
        "",
        f"Cost by {report['tag_key']} tag  ({report['metric']}, {report['region']})",
        f"  current  : {cur['start']} .. {cur['end']}  (end exclusive)",
        f"  previous : {prev['start']} .. {prev['end']}",
        "",
        f"  {'Component':<20}{'Current':>12}{'Previous':>12}{'Delta':>12}{'Change':>10}",
        f"  {'-' * 20}{'-' * 12:>12}{'-' * 12:>12}{'-' * 12:>12}{'-' * 10:>10}",
    ]
    for row in report["components"]:
        pct = "n/a" if row["delta_pct"] is None else f"{row['delta_pct']:+.1f}%"
        lines.append(
            f"  {row['component']:<20}{row['current']:>12.2f}{row['previous']:>12.2f}"
            f"{row['delta']:>+12.2f}{pct:>10}"
        )
    total_delta = report["total_current"] - report["total_previous"]
    lines += [
        f"  {'-' * 20}{'-' * 12:>12}{'-' * 12:>12}{'-' * 12:>12}{'-' * 10:>10}",
        f"  {'TOTAL':<20}{report['total_current']:>12.2f}"
        f"{report['total_previous']:>12.2f}{total_delta:>+12.2f}{'':>10}",
        "",
    ]
    return "\n".join(lines)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    configure_logging(args.log_level)

    cur_period, prev_period = periods(args.days)
    LOGGER.info("reporting window: %s days ending %s", args.days, cur_period[1])

    try:
        session = boto3.Session(profile_name=args.profile, region_name=args.region)
        client = session.client("ce", region_name=CE_ENDPOINT_REGION)
        current = fetch_costs(client, *cur_period, granularity=args.granularity)
        previous = fetch_costs(client, *prev_period, granularity=args.granularity)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "Unknown")
        if code in ("AccessDeniedException", "AccessDenied"):
            LOGGER.error("access denied: this principal needs ce:GetCostAndUsage, and "
                         "Cost Explorer must be enabled in the payer account")
        else:
            LOGGER.error("Cost Explorer call failed (%s): %s", code, exc)
        return 1
    except BotoCoreError as exc:
        LOGGER.error("AWS SDK error: %s", exc)
        return 1

    report = build_report(current, previous, cur_period, prev_period, args.region)

    if not report["components"]:
        LOGGER.warning("no cost data returned — usage may be too recent "
                       "(Cost Explorer lags roughly 24 hours)")

    if args.as_json:
        json.dump(report, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        sys.stdout.write(render_table(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
