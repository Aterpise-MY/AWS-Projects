#!/usr/bin/env bash
# =============================================================================
# setup-oidc.sh — One-time OIDC setup for GitHub Actions → AWS
#
# Run once per AWS account. Creates:
#   1. OIDC Identity Provider for token.actions.githubusercontent.com
#   2. IAM role that GitHub Actions can assume via OIDC
#   3. Inline policy granting Terraform the permissions it needs
#
# Usage:
#   bash .github/scripts/setup-oidc.sh
#
# After running, add the printed role ARN as a GitHub secret:
#   gh secret set AWS_ROLE_ARN -R Brendon20011007/AWS-Projects
# =============================================================================

set -euo pipefail

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REPO="Aterpise-MY/AWS-Projects"
ROLE_NAME="github-actions-terraform"
REGION="us-east-1"

echo "Account : $ACCOUNT_ID"
echo "Repo    : $REPO"
echo "Role    : $ROLE_NAME"
echo ""

# ── 1. Create OIDC Provider (idempotent) ─────────────────────────────────────
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" \
  --query "Url" --output text 2>/dev/null | grep -q "token.actions"; then
  echo "OIDC provider already exists — skipping creation"
else
  echo "Creating OIDC identity provider …"
  aws iam create-open-id-connect-provider \
    --url "https://token.actions.githubusercontent.com" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1"
  echo "OIDC provider created: $OIDC_ARN"
fi

# ── 2. Trust Policy ───────────────────────────────────────────────────────────
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${REPO}:*"
        }
      }
    }
  ]
}
EOF
)

# ── 3. Create or Update IAM Role ─────────────────────────────────────────────
if aws iam get-role --role-name "$ROLE_NAME" 2>/dev/null | grep -q "RoleName"; then
  echo "Role already exists — updating trust policy …"
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "$TRUST_POLICY"
else
  echo "Creating IAM role ${ROLE_NAME} …"
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "Assumed by GitHub Actions for Terraform deployments"
fi

# ── 4. Inline Permissions Policy ─────────────────────────────────────────────
PERMISSIONS_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformStateBackend",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::dnd-terraform-state-staging-${ACCOUNT_ID}",
        "arn:aws:s3:::dnd-terraform-state-staging-${ACCOUNT_ID}/*"
      ]
    },
    {
      "Sid": "TerraformStateLock",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"
      ],
      "Resource": "arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/cortex-terraform-locks"
    },
    {
      "Sid": "TerraformDeploy",
      "Effect": "Allow",
      "Action": [
        "cognito-idp:*",
        "rds:*",
        "lambda:*",
        "apigateway:*",
        "secretsmanager:*",
        "iam:GetRole", "iam:CreateRole", "iam:DeleteRole",
        "iam:AttachRolePolicy", "iam:DetachRolePolicy",
        "iam:PutRolePolicy", "iam:DeleteRolePolicy",
        "iam:PassRole", "iam:GetRolePolicy",
        "ec2:DescribeVpcs", "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups", "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup", "ec2:AuthorizeSecurityGroupIngress",
        "ec2:AuthorizeSecurityGroupEgress", "ec2:RevokeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupEgress", "ec2:CreateTags"
      ],
      "Resource": "*"
    }
  ]
}
EOF
)

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "terraform-deploy-policy" \
  --policy-document "$PERMISSIONS_POLICY"

echo ""
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query "Role.Arn" --output text)
echo "============================================"
echo " OIDC setup complete."
echo " Role ARN: ${ROLE_ARN}"
echo ""
echo " Add this as a GitHub secret:"
echo "   gh secret set AWS_ROLE_ARN --body '${ROLE_ARN}' -R ${REPO}"
echo "============================================"
