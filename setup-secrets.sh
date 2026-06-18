#!/usr/bin/env bash
# =============================================================================
# setup-secrets.sh — Set GitHub Secrets for Multi-Tenant SaaS deployment
# Run with:  bash setup-secrets.sh
# =============================================================================

set -euo pipefail
REPO="Brendon20011007/AWS-Projects"

prompt_secret() {
  local name="$1"
  local hint="$2"
  printf "\n%s\n  (%s)\n  Value: " "$name" "$hint"
  read -rs value
  echo
  if [ -n "$value" ]; then
    echo "$value" | gh secret set "$name" -R "$REPO"
    echo "  Set $name"
  else
    echo "  Skipped $name (empty — enter later)"
  fi
}

echo "============================================"
echo " GitHub Secrets — Multi-Tenant SaaS"
echo " Repo: $REPO"
echo " Press Enter to skip any secret."
echo "============================================"

prompt_secret "AWS_ACCESS_KEY_ID"     "IAM access key (starts with AKIA...)"
prompt_secret "AWS_SECRET_ACCESS_KEY" "IAM secret key"
prompt_secret "GH_PAT"                "GitHub PAT with 'repo' + 'workflow' scopes (for PR comments)"
prompt_secret "MULTITENANT_PRIVATE_SUBNET_IDS" \
  'Two private subnet IDs as JSON — e.g. ["subnet-aaa111","subnet-bbb222"]'
prompt_secret "MULTITENANT_DB_PASSWORD" \
  "RDS PostgreSQL master password (min 8 chars, no / @ \" or spaces)"

echo ""
echo "============================================"
echo " Done. Current secrets:"
gh secret list -R "$REPO"
echo "============================================"
