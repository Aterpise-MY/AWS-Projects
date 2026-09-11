#!/usr/bin/env bash
#
# redrive.sh - move messages from a DLQ back to its source queue.
#
# Wraps `aws sqs start-message-move-task`, the native SQS redrive API, and then
# polls `list-message-move-tasks` until the task stops running.
#
# Phase 5 of the scenario: once the fix is deployed (for example
# LOYALTY_API_DOWN back to "false"), the parked transactions are replayed. This
# is only safe because the consumers are idempotent - every transaction_id is
# claimed with a DynamoDB conditional write, so a replayed message that was in
# fact already processed is logged as duplicate_skipped instead of awarding
# points twice (requirement R4).
#
# Do NOT redrive poison messages. They failed on their content, not on a
# dependency, so a redrive just burns another maxReceiveCount cycle and puts
# them straight back in the DLQ. Triage first with the runbook.

set -euo pipefail

# Rate limit for the move task. The reason this is not left unbounded: the
# downstream that just came back up is the weakest part of the system at that
# moment, and dumping a 14-day DLQ backlog into it at full speed is how a
# recovered outage becomes a second outage. 10 messages/second replays 600
# transactions per minute, which is in line with MekarMart's normal 6,000/hour
# load, so the loyalty platform sees nothing it does not already handle daily.
MAX_MESSAGES_PER_SECOND=10

POLL_INTERVAL_SECONDS=5

SOURCE_ARN=""
DESTINATION_ARN=""
REGION="ap-southeast-1"
ASSUME_YES="false"
DRY_RUN="false"

usage() {
  cat <<'USAGE'
Usage: redrive.sh --source-arn <dlq-arn> [options]

Moves messages from a dead-letter queue back to its source queue using the
SQS message move task API, rate limited so the recovered downstream is not
overwhelmed a second time.

Required:
  --source-arn ARN         ARN of the DLQ to drain (the *source* of the move).

Options:
  --destination-arn ARN    Queue to move messages into. Omit to use each
                           message's original source queue, which is what the
                           DLQ's redrive allow policy already pins down.
  --region REGION          AWS region (default: ap-southeast-1).
  --rate N                 Max messages moved per second (default: 10).
  --yes                    Skip the interactive confirmation.
  --dry-run                Show the DLQ depth and the command, run nothing.
  -h, --help               Show this help.

Examples:
  ./scripts/redrive.sh --source-arn arn:aws:sqs:ap-southeast-1:022499047467:pos-loyalty-dlq --dry-run
  ./scripts/redrive.sh --source-arn arn:aws:sqs:ap-southeast-1:022499047467:pos-loyalty-dlq --yes
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-arn)      SOURCE_ARN="${2:-}"; shift 2 ;;
    --destination-arn) DESTINATION_ARN="${2:-}"; shift 2 ;;
    --region)          REGION="${2:-}"; shift 2 ;;
    --rate)            MAX_MESSAGES_PER_SECOND="${2:-}"; shift 2 ;;
    --yes)             ASSUME_YES="true"; shift ;;
    --dry-run)         DRY_RUN="true"; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "${SOURCE_ARN}" ]]; then
  echo "Error: --source-arn is required." >&2
  usage >&2
  exit 2
fi

command -v aws >/dev/null 2>&1 || { echo "Error: the AWS CLI is not on PATH." >&2; exit 1; }

# The queue URL is needed for get-queue-attributes; derive it from the ARN
# (arn:aws:sqs:<region>:<account>:<name>) rather than asking for both.
ARN_REGION="$(cut -d: -f4 <<<"${SOURCE_ARN}")"
ACCOUNT_ID="$(cut -d: -f5 <<<"${SOURCE_ARN}")"
QUEUE_NAME="$(cut -d: -f6 <<<"${SOURCE_ARN}")"
if [[ -z "${ARN_REGION}" || -z "${ACCOUNT_ID}" || -z "${QUEUE_NAME}" ]]; then
  echo "Error: --source-arn does not look like an SQS queue ARN." >&2
  exit 2
fi
QUEUE_URL="https://sqs.${ARN_REGION}.amazonaws.com/${ACCOUNT_ID}/${QUEUE_NAME}"

echo "DLQ            : ${QUEUE_NAME}"
echo "Region         : ${REGION}"
echo "Rate limit     : ${MAX_MESSAGES_PER_SECOND} messages/second"
if [[ -n "${DESTINATION_ARN}" ]]; then
  echo "Destination    : ${DESTINATION_ARN}"
else
  echo "Destination    : original source queue of each message"
fi

# Read the depth before doing anything. It is both the go/no-go number for the
# operator and the baseline to compare the move task's progress against.
DEPTH="$(aws sqs get-queue-attributes \
  --queue-url "${QUEUE_URL}" \
  --region "${REGION}" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --query 'Attributes.ApproximateNumberOfMessages' \
  --output text)"

echo "Messages ready : ${DEPTH}"

if [[ "${DEPTH}" == "0" ]]; then
  echo "Nothing to redrive."
  exit 0
fi

MOVE_ARGS=(
  --source-arn "${SOURCE_ARN}"
  --max-number-of-messages-per-second "${MAX_MESSAGES_PER_SECOND}"
  --region "${REGION}"
)
if [[ -n "${DESTINATION_ARN}" ]]; then
  MOVE_ARGS+=(--destination-arn "${DESTINATION_ARN}")
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  echo ""
  echo "Dry run - would execute:"
  printf '  aws sqs start-message-move-task'
  printf ' %q' "${MOVE_ARGS[@]}"
  echo ""
  exit 0
fi

if [[ "${ASSUME_YES}" != "true" ]]; then
  echo ""
  echo "This replays ${DEPTH} message(s). Confirm the downstream is healthy and"
  echo "that these are transient failures, not poison messages."
  read -r -p "Proceed? [y/N] " REPLY
  if [[ ! "${REPLY}" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
  fi
fi

TASK_HANDLE="$(aws sqs start-message-move-task \
  "${MOVE_ARGS[@]}" \
  --query 'TaskHandle' \
  --output text)"

echo ""
echo "Move task started: ${TASK_HANDLE:0:24}..."

# Poll until the task leaves RUNNING. SQS keeps the most recent tasks for a
# source ARN, so --max-results 1 is the task just started.
while true; do
  sleep "${POLL_INTERVAL_SECONDS}"

  read -r STATUS MOVED < <(aws sqs list-message-move-tasks \
    --source-arn "${SOURCE_ARN}" \
    --max-results 1 \
    --region "${REGION}" \
    --query 'Results[0].[Status,ApproximateNumberOfMessagesMoved]' \
    --output text)

  echo "  Status: ${STATUS}  Moved: ${MOVED}"

  if [[ "${STATUS}" != "RUNNING" ]]; then
    break
  fi
done

echo ""
echo "Final status: ${STATUS} (${MOVED} message(s) moved)"
echo "Verify with the runbook: each replayed transaction_id should appear once"
echo "as processed, or as duplicate_skipped if it had already succeeded."

if [[ "${STATUS}" == "FAILED" ]]; then
  aws sqs list-message-move-tasks --source-arn "${SOURCE_ARN}" --max-results 1 \
    --region "${REGION}" --query 'Results[0].FailureReason' --output text >&2
  exit 1
fi
