#!/usr/bin/env bash
#
# rebuild.sh — the exact inverse of teardown.sh: bring the whole environment
# back from nothing.
#
#   1. terraform apply          (VPC, EKS, ECR, RDS, ElastiCache, S3, secrets)
#   2. kubeconfig
#   3. platform add-ons         (ALB controller, External Secrets, autoscaler,
#                                metrics-server, KEDA, Fluent Bit)
#   4. helm upgrade --install   (the application chart)
#   5. verify-deployment.sh     (proof it actually works)
#
# It prints total elapsed wall time at the end. That number is the point: if the
# environment can be destroyed at night and rebuilt in the morning inside a
# published, repeatable duration, the Infrastructure-as-Code is real rather than
# a description of something that was clicked together once.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

IMAGE_TAG=""
SKIP_VERIFY=0
SKIP_ADDONS=0
AUTO_APPROVE=1

usage() {
  cat <<'EOF'
Usage: scripts/rebuild.sh [options]

Rebuilds the ticketing dev environment end to end and reports total wall time.

Options:
  --image-tag <sha>   Full 40-char image tag to deploy
                      (default: `git rev-parse HEAD`; never `latest`)
  --skip-addons       Do not reconcile the platform add-ons
  --skip-verify       Do not run scripts/verify-deployment.sh at the end
  --plan-only         Run `terraform plan` instead of apply, then stop
  --profile <name>    AWS profile
  --region <name>     AWS region (default: ap-southeast-1)
  -h, --help          Show this help and exit
EOF
}

PLAN_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-tag)  IMAGE_TAG="$2"; shift 2 ;;
    --skip-addons) SKIP_ADDONS=1; shift ;;
    --skip-verify) SKIP_VERIFY=1; shift ;;
    --plan-only)  PLAN_ONLY=1; shift ;;
    --profile)    AWS_PROFILE="$2"; export AWS_PROFILE; shift 2 ;;
    --region)     AWS_REGION="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            usage >&2; die "unknown argument: $1" ;;
  esac
done

START_TS=$SECONDS

# ---------------------------------------------------------------------------
# 1. Terraform
# ---------------------------------------------------------------------------
log_section "Step 1/5 — terraform apply"
terraform -chdir="$TF_DIR" init -input=false >/dev/null || die "terraform init failed"
if (( PLAN_ONLY )); then
  terraform -chdir="$TF_DIR" plan -input=false
  log_info "--plan-only: stopping here"
  exit 0
fi
APPLY_ARGS=(-input=false)
(( AUTO_APPROVE )) && APPLY_ARGS+=(-auto-approve)
terraform -chdir="$TF_DIR" apply "${APPLY_ARGS[@]}" || die "terraform apply failed"
log_ok "infrastructure applied ($(human_duration $(( SECONDS - START_TS ))) so far)"

CLUSTER_NAME="$(tf_out cluster_name)"
ECR_URL="$(tf_out ecr_repository_url)"
VPC_ID="$(tf_out vpc_id)"
ACCOUNT_ID="$(aws_cli sts get-caller-identity --query Account --output text)"
IRSA_ALB="$(tf_out_json      | jq -r '.irsa_role_arns.value.alb_controller')"
IRSA_ESO="$(tf_out_json      | jq -r '.irsa_role_arns.value.external_secrets')"
IRSA_CA="$(tf_out_json       | jq -r '.irsa_role_arns.value.cluster_autoscaler')"
IRSA_APP="$(tf_out_json      | jq -r '.irsa_role_arns.value.app')"
IRSA_FLUENT="$(tf_out_json   | jq -r '.irsa_role_arns.value.fluent_bit')"

# ---------------------------------------------------------------------------
# 2. kubeconfig
# ---------------------------------------------------------------------------
log_section "Step 2/5 — kubeconfig"
aws_cli eks update-kubeconfig --name "$CLUSTER_NAME" --alias "$CLUSTER_NAME" >/dev/null \
  || die "update-kubeconfig failed"
kubectl config use-context "$CLUSTER_NAME" >/dev/null
retry_until 600 15 "the EKS API server to answer" kubectl get --raw /readyz \
  || die "cluster API never became ready"
log_ok "connected to ${CLUSTER_NAME}"

# ---------------------------------------------------------------------------
# 3. Platform add-ons. Every one of these is scheduled onto the tainted system
#    node group, so each carries the CriticalAddonsOnly toleration.
# ---------------------------------------------------------------------------
SYSTEM_TOLERATION=(
  --set "tolerations[0].key=CriticalAddonsOnly"
  --set "tolerations[0].operator=Equal"
  --set "tolerations[0].value=true"
  --set "tolerations[0].effect=NoSchedule"
  --set "nodeSelector.role=system"
)

install_addon() {
  local release="$1" repo_name="$2" repo_url="$3" chart="$4" ns="$5" version="$6"; shift 6
  helm repo add "$repo_name" "$repo_url" >/dev/null 2>&1 || true
  helm upgrade --install "$release" "$chart" \
    --repo "$repo_url" --version "$version" \
    --namespace "$ns" --create-namespace \
    --atomic --timeout 10m --wait "$@" \
    || die "add-on ${release} failed to install"
  log_ok "add-on ${release} ready"
}

if (( SKIP_ADDONS )); then
  log_warn "Step 3/5 — skipping platform add-ons on request"
else
  log_section "Step 3/5 — platform add-ons"

  install_addon aws-load-balancer-controller eks https://aws.github.io/eks-charts \
    aws-load-balancer-controller kube-system 1.13.0 \
    --set "clusterName=${CLUSTER_NAME}" \
    --set "region=${AWS_REGION}" \
    --set "vpcId=${VPC_ID}" \
    --set "serviceAccount.create=true" \
    --set "serviceAccount.name=aws-load-balancer-controller" \
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${IRSA_ALB}" \
    "${SYSTEM_TOLERATION[@]}"

  install_addon external-secrets external-secrets https://charts.external-secrets.io \
    external-secrets external-secrets 0.14.0 \
    --set "installCRDs=true" \
    --set "serviceAccount.name=external-secrets" \
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${IRSA_ESO}" \
    "${SYSTEM_TOLERATION[@]}"

  install_addon cluster-autoscaler autoscaler https://kubernetes.github.io/autoscaler \
    cluster-autoscaler kube-system 9.46.0 \
    --set "autoDiscovery.clusterName=${CLUSTER_NAME}" \
    --set "awsRegion=${AWS_REGION}" \
    --set "rbac.serviceAccount.name=cluster-autoscaler" \
    --set "rbac.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${IRSA_CA}" \
    "${SYSTEM_TOLERATION[@]}"

  install_addon metrics-server metrics-server https://kubernetes-sigs.github.io/metrics-server \
    metrics-server kube-system 3.12.2 "${SYSTEM_TOLERATION[@]}"

  # KEDA scales the worker Deployment on Redis list length. Its chart nests
  # tolerations per component, so it does not take SYSTEM_TOLERATION verbatim.
  install_addon keda kedacore https://kedacore.github.io/charts \
    keda keda 2.17.0 \
    --set "nodeSelector.role=system" \
    --set "tolerations[0].key=CriticalAddonsOnly" \
    --set "tolerations[0].operator=Equal" \
    --set "tolerations[0].value=true" \
    --set "tolerations[0].effect=NoSchedule"

  install_addon aws-for-fluent-bit eks https://aws.github.io/eks-charts \
    aws-for-fluent-bit amazon-cloudwatch 0.1.35 \
    --set "cloudWatchLogs.region=${AWS_REGION}" \
    --set "cloudWatchLogs.logGroupName=/aws/eks/${CLUSTER_NAME}/workloads" \
    --set "serviceAccount.name=fluent-bit" \
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${IRSA_FLUENT}"
fi

# ---------------------------------------------------------------------------
# 4. Application chart
# ---------------------------------------------------------------------------
log_section "Step 4/5 — helm upgrade --install ticketing"
if [[ -z "$IMAGE_TAG" ]]; then
  IMAGE_TAG="$(git -C "$PROJECT_ROOT" rev-parse HEAD)" || die "could not resolve a git SHA; pass --image-tag"
fi
[[ ${#IMAGE_TAG} -eq 40 ]] || die "image tag must be a full 40-char git SHA, got '${IMAGE_TAG}' (never deploy 'latest')"

if ! aws_cli ecr describe-images --repository-name "${ECR_URL##*/}" \
      --image-ids "imageTag=${IMAGE_TAG}" >/dev/null 2>&1; then
  die "image ${ECR_URL}:${IMAGE_TAG} does not exist in ECR — push it first (build-deploy.yml does this on merge to main)"
fi

helm upgrade --install "$HELM_RELEASE" "$HELM_CHART_DIR" \
  --namespace "$K8S_NAMESPACE" --create-namespace \
  --atomic --timeout 10m --wait \
  --set "image.repository=${ECR_URL}" \
  --set "image.tag=${IMAGE_TAG}" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${IRSA_APP}" \
  --set "aws.region=${AWS_REGION}" \
  --set "aws.accountId=${ACCOUNT_ID}" \
  || die "helm upgrade failed (--atomic already rolled back)"
log_ok "release ${HELM_RELEASE} deployed at ${IMAGE_TAG}"

# ---------------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------------
if (( SKIP_VERIFY )); then
  log_warn "Step 5/5 — skipping verification on request"
else
  log_section "Step 5/5 — verify"
  "${SCRIPT_DIR}/verify-deployment.sh" || die "post-deploy verification FAILED"
fi

ELAPSED=$(( SECONDS - START_TS ))
log_section "Rebuild complete"
printf '  Cluster        : %s\n' "$CLUSTER_NAME"
printf '  Image          : %s:%s\n' "$ECR_URL" "$IMAGE_TAG"
printf '  Total wall time: %s (%d seconds)\n\n' "$(human_duration "$ELAPSED")" "$ELAPSED"
