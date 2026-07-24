#!/usr/bin/env bash
#
# teardown.sh — ordered, safe destruction of the ticketing dev environment.
#
# THE ORDER IS THE WHOLE POINT OF THIS SCRIPT. Each step exists because doing it
# later (or not at all) produces a specific, well-known failure:
#
#   Step 1  Scale the workloads to zero.
#           Stops the app writing to RDS/Redis/S3 mid-teardown, and stops the
#           scheduler CronJob spawning new pods while we are uninstalling.
#
#   Step 2  `helm uninstall` the release.
#           This deletes the Ingress object, which is the ONLY thing that tells
#           the AWS Load Balancer Controller to delete the ALB it provisioned.
#           The ALB and its controller-managed security groups are NOT in the
#           Terraform state — they were created by a controller running inside
#           the cluster. If you skip this step and go straight to
#           `terraform destroy`, the ALB survives, its ENIs stay attached to the
#           private subnets, and its managed security groups stay attached to
#           the node security group. Terraform then hangs for ~20 minutes and
#           finally fails with DependencyViolation on subnet, security group and
#           VPC deletion, leaving you to hand-delete the load balancer, wait for
#           the ENIs to detach, and re-run destroy. That is the orphaned-load-
#           balancer trap and it is entirely avoidable by uninstalling first.
#
#   Step 3  WAIT for the ALB to actually disappear.
#           `helm uninstall` returns as soon as the Kubernetes objects are gone.
#           The controller's finalizer-driven AWS deletion is asynchronous and
#           takes 1-3 minutes; ENI detachment takes longer still. We poll
#           `aws elbv2 describe-load-balancers` until nothing in this VPC remains,
#           then poll for the controller-managed security groups.
#
#   Step 4  `terraform destroy`.
#           Only now is the VPC actually free of foreign dependencies.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

ASSUME_YES=0
KEEP_INFRA=0
ALB_WAIT_SECONDS=600

usage() {
  cat <<'EOF'
Usage: scripts/teardown.sh [options]

Destroys the ticketing dev environment in dependency-safe order:
  workloads -> helm uninstall -> wait for ALB + managed SGs -> terraform destroy

Options:
  --yes                 Skip the interactive typed confirmation (for automation)
  --keep-infra          Do everything except `terraform destroy`
                        (drops the ALB and pods; leaves the cluster/RDS/cache)
  --alb-timeout <secs>  How long to wait for the ALB to vanish (default: 600)
  --profile <name>      AWS profile
  --region <name>       AWS region (default: ap-southeast-1)
  -h, --help            Show this help and exit

THIS IS DESTRUCTIVE. Without --yes you must type DESTROY at the prompt.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)         ASSUME_YES=1; shift ;;
    --keep-infra)  KEEP_INFRA=1; shift ;;
    --alb-timeout) ALB_WAIT_SECONDS="$2"; shift 2 ;;
    --profile)     AWS_PROFILE="$2"; export AWS_PROFILE; shift 2 ;;
    --region)      AWS_REGION="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             usage >&2; die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null || die "jq is required"
START_TS=$SECONDS

CLUSTER_NAME="$(tf_out cluster_name)"
VPC_ID="$(tf_out vpc_id)"

log_section "Teardown target"
log_info "Cluster : ${CLUSTER_NAME}"
log_info "VPC     : ${VPC_ID}"
log_info "Region  : ${AWS_REGION}"

if (( ! ASSUME_YES )); then
  confirm "This will DELETE the EKS cluster, RDS instance, ElastiCache group, S3 bucket and VPC above. Data is not recoverable (skip_final_snapshot = true)." "DESTROY"
fi

# ---------------------------------------------------------------------------
# Step 1 — quiesce the workloads.
# Suspend the scheduler CronJob first so it cannot create a new Job while we are
# scaling Deployments down, then scale web and worker to zero and wait.
# ---------------------------------------------------------------------------
log_section "Step 1/4 — scale workloads down"
if kubectl get namespace "$K8S_NAMESPACE" >/dev/null 2>&1; then
  kubectl -n "$K8S_NAMESPACE" patch cronjob -l "app.kubernetes.io/instance=${HELM_RELEASE}" \
    -p '{"spec":{"suspend":true}}' --type=merge 2>/dev/null || log_warn "no CronJob to suspend"
  kubectl -n "$K8S_NAMESPACE" scale deployment --all --replicas=0 2>/dev/null || log_warn "no Deployments to scale"
  kubectl -n "$K8S_NAMESPACE" wait --for=delete pod \
    -l "app.kubernetes.io/instance=${HELM_RELEASE}" --timeout=180s 2>/dev/null || true
  log_ok "workloads quiesced"
else
  log_warn "namespace ${K8S_NAMESPACE} not present — nothing to scale"
fi

# ---------------------------------------------------------------------------
# Step 2 — helm uninstall. This deletes the Ingress and hands the ALB deletion
# to the AWS Load Balancer Controller. --wait blocks on the Kubernetes objects
# only; the AWS-side deletion is handled by step 3.
# ---------------------------------------------------------------------------
log_section "Step 2/4 — helm uninstall"
if helm status "$HELM_RELEASE" -n "$K8S_NAMESPACE" >/dev/null 2>&1; then
  helm uninstall "$HELM_RELEASE" -n "$K8S_NAMESPACE" --wait --timeout 10m \
    || die "helm uninstall failed — resolve this before destroying, or you WILL orphan the ALB"
  log_ok "release ${HELM_RELEASE} uninstalled"
else
  log_warn "release ${HELM_RELEASE} not installed — continuing"
fi

# ---------------------------------------------------------------------------
# Step 3 — wait for AWS to catch up. Two independent gates.
# ---------------------------------------------------------------------------
log_section "Step 3/4 — wait for the ALB and its managed security groups"

no_load_balancers_in_vpc() {
  local count
  count="$(aws_cli elbv2 describe-load-balancers \
    --query "length(LoadBalancers[?VpcId=='${VPC_ID}'])" --output text 2>/dev/null || echo "unknown")"
  [[ "$count" == "0" ]]
}

# The controller tags every security group it creates with elbv2.k8s.aws/cluster.
# These are what actually block security-group and VPC deletion once the ALB is
# gone but its SGs linger.
no_controller_security_groups() {
  local count
  count="$(aws_cli ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag-key,Values=elbv2.k8s.aws/cluster" \
    --query 'length(SecurityGroups)' --output text 2>/dev/null || echo "unknown")"
  [[ "$count" == "0" ]]
}

if retry_until "$ALB_WAIT_SECONDS" 15 "load balancers in ${VPC_ID} to be deleted" no_load_balancers_in_vpc; then
  log_ok "no load balancers remain in ${VPC_ID}"
else
  aws_cli elbv2 describe-load-balancers \
    --query "LoadBalancers[?VpcId=='${VPC_ID}'].[LoadBalancerName,State.Code]" --output table || true
  die "load balancers still present in ${VPC_ID} after ${ALB_WAIT_SECONDS}s. Delete them by hand before destroying, otherwise terraform destroy will fail on DependencyViolation."
fi

if retry_until 300 15 "controller-managed security groups to be deleted" no_controller_security_groups; then
  log_ok "no elbv2.k8s.aws-tagged security groups remain"
else
  aws_cli ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag-key,Values=elbv2.k8s.aws/cluster" \
    --query 'SecurityGroups[].[GroupId,GroupName]' --output table || true
  die "controller-managed security groups survived. Detach and delete them, then re-run."
fi

# ---------------------------------------------------------------------------
# Step 4 — terraform destroy.
# ---------------------------------------------------------------------------
if (( KEEP_INFRA )); then
  log_warn "--keep-infra given: stopping before terraform destroy"
else
  log_section "Step 4/4 — terraform destroy"
  terraform -chdir="$TF_DIR" destroy -auto-approve -input=false \
    || die "terraform destroy failed — inspect the error, it is almost always a leftover ENI or SG"
  log_ok "infrastructure destroyed"
fi

# ---------------------------------------------------------------------------
# Estimated monthly saving. List prices, ap-southeast-1, 730 h/month, no free
# tier, excluding data transfer and CloudWatch ingestion. This is what the
# environment stops costing, not a billing statement.
# ---------------------------------------------------------------------------
log_section "Estimated monthly saving"
SAVINGS_TABLE=$(cat <<'EOF'
EKS control plane (1 cluster)|73.00
Interface VPC endpoints (4 x 2 AZ)|75.92
NAT Gateway (1, hourly only)|32.85
Application Load Balancer (hourly + ~1 LCU)|22.28
System node t4g.small on-demand (1)|15.48
App nodes t4g.medium spot (2)|21.90
RDS db.t4g.micro single-AZ|13.14
RDS gp3 storage 20 GiB|2.76
ElastiCache cache.t4g.micro|13.14
EBS gp3 node volumes (3 x 20 GiB)|4.80
Secrets Manager (4 secrets)|1.60
CloudWatch Logs + ECR storage (approx.)|3.00
EOF
)
printf '%s\n' "$SAVINGS_TABLE" | awk -F'|' '
  BEGIN { printf "  %-46s %10s\n  %-46s %10s\n", "Resource", "USD/month", "----------------------------------------------", "----------" }
  { total += $2; printf "  %-46s %10.2f\n", $1, $2 }
  END { printf "  %-46s %10s\n  %-46s %10.2f\n", "----------------------------------------------", "----------", "TOTAL", total }'
printf '\n'
log_info "Teardown wall time: $(human_duration $(( SECONDS - START_TS )))"
log_info "Estimate is AWS list price for ap-southeast-1 and excludes data transfer."
