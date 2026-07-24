#!/usr/bin/env bash
#
# bootstrap.sh — prepare a workstation to operate the ticketing platform.
#
#   1. verify every required tool exists AND is new enough (real version compare)
#   2. confirm which AWS identity/account/region we are actually pointed at
#   3. terraform init in terraform/dev
#   4. write a kubeconfig entry for the EKS cluster (only if the cluster exists)
#
# This script performs NO infrastructure mutation. `terraform init` downloads
# providers and configures the S3 backend; it does not create AWS resources.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

EXPECTED_ACCOUNT_ID="022499047467"
SKIP_KUBECONFIG=0
RECONFIGURE=0

usage() {
  cat <<'EOF'
Usage: scripts/bootstrap.sh [options]

Verifies local tooling, confirms the AWS identity, runs `terraform init` in
terraform/dev and writes the EKS kubeconfig entry.

Options:
  --profile <name>     AWS profile to use (also honours $AWS_PROFILE)
  --region <name>      AWS region (default: ap-southeast-1)
  --account <id>       Expected AWS account ID to assert against
                       (default: 022499047467; pass "any" to skip the check)
  --skip-kubeconfig    Do not call `aws eks update-kubeconfig`
  --reconfigure        Pass -reconfigure to `terraform init`
  -h, --help           Show this help and exit

Exit codes: 0 success, non-zero on the first failed check.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)         AWS_PROFILE="$2"; export AWS_PROFILE; shift 2 ;;
    --region)          AWS_REGION="$2"; shift 2 ;;
    --account)         EXPECTED_ACCOUNT_ID="$2"; shift 2 ;;
    --skip-kubeconfig) SKIP_KUBECONFIG=1; shift ;;
    --reconfigure)     RECONFIGURE=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 usage >&2; die "unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Tooling. Minimums are the versions whose features this repo actually uses:
#    terraform 1.9  -> provider-defined functions, `removed` blocks
#    aws cli   2.15 -> `eks describe-cluster-versions`, EKS access entries
#    kubectl   1.30 -> server 1.36 is within the +/- 1 minor skew policy at 1.35+,
#                      but 1.30 is the floor for the API resources the chart uses
#    helm      3.14 -> `--wait-for-jobs` reliability with hook weights
#    docker    24.0 -> BuildKit `type=registry` cache exporter
#    jq        1.6  -> used everywhere to read terraform output JSON
# ---------------------------------------------------------------------------
log_section "Tool versions"
require_tool terraform 1.9.0  terraform version
require_tool aws       2.15.0 aws --version
require_tool kubectl   1.30.0 kubectl version --client
require_tool helm      3.14.0 helm version --short
require_tool docker    24.0.0 docker --version
require_tool jq        1.6    jq --version

# ---------------------------------------------------------------------------
# 2. AWS identity
# ---------------------------------------------------------------------------
log_section "AWS identity"
CALLER_JSON="$(aws_cli sts get-caller-identity --output json)" \
  || die "aws sts get-caller-identity failed — are your credentials configured/valid?"
ACCOUNT_ID="$(printf '%s' "$CALLER_JSON" | jq -r '.Account')"
CALLER_ARN="$(printf '%s' "$CALLER_JSON" | jq -r '.Arn')"

log_info "Profile : ${AWS_PROFILE:-<default credential chain>}"
log_info "Region  : ${AWS_REGION}"
log_info "Account : ${ACCOUNT_ID}"
log_info "Identity: ${CALLER_ARN}"

if [[ "$EXPECTED_ACCOUNT_ID" != "any" && "$ACCOUNT_ID" != "$EXPECTED_ACCOUNT_ID" ]]; then
  die "wrong AWS account: got ${ACCOUNT_ID}, expected ${EXPECTED_ACCOUNT_ID}. Refusing to init state against the wrong account."
fi
log_ok "AWS identity confirmed"

# ---------------------------------------------------------------------------
# 3. terraform init
# ---------------------------------------------------------------------------
log_section "terraform init (terraform/dev)"
[[ -d "$TF_DIR" ]] || die "${TF_DIR} does not exist"
INIT_ARGS=(-input=false)
(( RECONFIGURE )) && INIT_ARGS+=(-reconfigure)
terraform -chdir="$TF_DIR" init "${INIT_ARGS[@]}" \
  || die "terraform init failed — has terraform/bootstrap been applied to create the state bucket and lock table?"
terraform -chdir="$TF_DIR" validate || die "terraform validate failed"
log_ok "Terraform initialised and validated"

# ---------------------------------------------------------------------------
# 4. kubeconfig. Skipped silently when the stack has not been applied yet —
#    bootstrap must be safe to run on a clean checkout before any apply.
# ---------------------------------------------------------------------------
if (( SKIP_KUBECONFIG )); then
  log_warn "Skipping kubeconfig on request"
  exit 0
fi

log_section "kubeconfig"
CLUSTER_NAME="$(tf_out cluster_name --optional || true)"
if [[ -z "$CLUSTER_NAME" ]]; then
  log_warn "No 'cluster_name' output yet — the dev stack has not been applied. Skipping kubeconfig."
  log_info "Run scripts/rebuild.sh to apply, then re-run this script."
  exit 0
fi

aws_cli eks update-kubeconfig --name "$CLUSTER_NAME" --alias "$CLUSTER_NAME" \
  || die "aws eks update-kubeconfig failed for cluster ${CLUSTER_NAME}"
kubectl config use-context "$CLUSTER_NAME" >/dev/null
kubectl version --output=json >/dev/null 2>&1 \
  || die "kubectl cannot reach the API server — check that your principal has an EKS access entry"
log_ok "kubeconfig written; current context is ${CLUSTER_NAME}"

log_section "Ready"
log_info "Next: scripts/rebuild.sh (full build) or scripts/verify-deployment.sh (smoke test)"
