#!/usr/bin/env bash
# lib.sh — shared helpers for the ticketing platform operator scripts.
#
# This file is sourced, never executed. Keeping logging, version comparison,
# Terraform-output lookup and confirmation prompts here is what keeps each of
# bootstrap/teardown/rebuild/verify-deployment small enough to read in one sitting
# instead of each growing its own slightly-different copy of the same 60 lines.
#
# Every caller sets: set -euo pipefail

# ---------------------------------------------------------------------------
# Contract constants. These mirror the build contract; nothing here is guessed.
# ---------------------------------------------------------------------------
: "${PROJECT_ROOT:="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"}"
: "${TF_DIR:="${PROJECT_ROOT}/terraform/dev"}"
: "${AWS_REGION:="ap-southeast-1"}"
: "${K8S_NAMESPACE:="ticketing"}"
: "${HELM_RELEASE:="ticketing"}"
: "${HELM_CHART_DIR:="${PROJECT_ROOT}/helm/ticketing"}"

# ---------------------------------------------------------------------------
# Logging. Colour only when stdout is a TTY, so CI logs stay clean.
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  _C_RED=$'\033[31m'; _C_YEL=$'\033[33m'; _C_GRN=$'\033[32m'
  _C_BLU=$'\033[34m'; _C_OFF=$'\033[0m'
else
  _C_RED=""; _C_YEL=""; _C_GRN=""; _C_BLU=""; _C_OFF=""
fi

_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log_info()  { printf '%s [%sINFO%s]  %s\n'  "$(_ts)" "$_C_BLU" "$_C_OFF" "$*"; }
log_ok()    { printf '%s [%s OK %s]  %s\n'  "$(_ts)" "$_C_GRN" "$_C_OFF" "$*"; }
log_warn()  { printf '%s [%sWARN%s]  %s\n'  "$(_ts)" "$_C_YEL" "$_C_OFF" "$*" >&2; }
log_error() { printf '%s [%sFAIL%s]  %s\n'  "$(_ts)" "$_C_RED" "$_C_OFF" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# Section banner. Box-drawing characters per repo style rules.
log_section() {
  printf '\n┌─%s─┐\n│ %s │\n└─%s─┘\n' \
    "$(printf '─%.0s' $(seq 1 ${#1}))" "$1" "$(printf '─%.0s' $(seq 1 ${#1}))"
}

# ---------------------------------------------------------------------------
# version_ge <have> <want>  — true when <have> >= <want>, semver-aware.
# Uses sort -V so 1.10.0 correctly sorts above 1.9.0 (a plain string compare
# gets this backwards, which is the classic "my tooling check passes but the
# binary is two years old" bug).
# ---------------------------------------------------------------------------
version_ge() {
  [[ "$1" == "$2" ]] && return 0
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# require_tool <binary> <min-version> <version-command...>
# Extracts the first dotted-numeric token from the version command output.
require_tool() {
  local bin="$1" min="$2"; shift 2
  command -v "$bin" >/dev/null 2>&1 || die "'${bin}' not found on PATH (need >= ${min})"
  local raw have
  raw="$("$@" 2>&1 || true)"
  have="$(printf '%s' "$raw" | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)"
  [[ -n "$have" ]] || die "could not parse a version number out of: ${*}"
  if version_ge "$have" "$min"; then
    log_ok "$(printf '%-10s %-12s (min %s)' "$bin" "$have" "$min")"
  else
    die "${bin} ${have} is older than the required minimum ${min}"
  fi
}

# ---------------------------------------------------------------------------
# Terraform outputs. Nothing in these scripts hardcodes an account ID, an ECR
# registry hostname or a cluster name — it all comes from `terraform output`.
# tf_out caches the whole JSON blob once per process; terraform output is slow
# and we read half a dozen values.
# ---------------------------------------------------------------------------
_TF_OUT_CACHE=""
tf_out_json() {
  if [[ -z "$_TF_OUT_CACHE" ]]; then
    [[ -d "${TF_DIR}/.terraform" ]] || die "Terraform is not initialised in ${TF_DIR} — run scripts/bootstrap.sh first"
    _TF_OUT_CACHE="$(terraform -chdir="${TF_DIR}" output -json)" \
      || die "terraform output failed in ${TF_DIR}"
  fi
  printf '%s' "$_TF_OUT_CACHE"
}

# tf_out <output_name> [--optional]
tf_out() {
  local name="$1" optional="${2:-}" value
  value="$(tf_out_json | jq -r --arg k "$name" '.[$k].value // empty')"
  if [[ -z "$value" || "$value" == "null" ]]; then
    [[ "$optional" == "--optional" ]] && return 0
    die "Terraform output '${name}' is empty — is the dev stack applied?"
  fi
  printf '%s' "$value"
}

# ---------------------------------------------------------------------------
# confirm <prompt> <expected-word>
# Interactive typed confirmation. Callers that pass --yes skip this entirely.
# ---------------------------------------------------------------------------
confirm() {
  local prompt="$1" expected="$2" answer
  [[ -t 0 ]] || die "refusing to proceed: stdin is not a TTY and --yes was not given"
  printf '%s\nType %s to continue: ' "$prompt" "$expected"
  read -r answer
  [[ "$answer" == "$expected" ]] || die "confirmation did not match ('${answer}' != '${expected}') — aborting"
}

# retry_until <timeout-seconds> <interval-seconds> <description> <command...>
# Polls until the command succeeds. Returns 1 on timeout.
retry_until() {
  local timeout="$1" interval="$2" what="$3"; shift 3
  local deadline=$(( SECONDS + timeout ))
  while (( SECONDS < deadline )); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    printf '  ... waiting for %s (%ds left)\n' "$what" "$(( deadline - SECONDS ))"
    sleep "$interval"
  done
  return 1
}

# human_duration <seconds> -> "1h 04m 07s"
human_duration() {
  local s="$1"
  printf '%dh %02dm %02ds' $(( s / 3600 )) $(( (s % 3600) / 60 )) $(( s % 60 ))
}

# aws_cli <args...> — always pins region, honours AWS_PROFILE when set.
aws_cli() {
  if [[ -n "${AWS_PROFILE:-}" ]]; then
    aws --region "$AWS_REGION" --profile "$AWS_PROFILE" "$@"
  else
    aws --region "$AWS_REGION" "$@"
  fi
}
