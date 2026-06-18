#!/usr/bin/env bash
# ================================================================
# Multi-Tenant SaaS Application — AWS CLI Deployment Script
# Services: Cognito · API Gateway · Lambda · RDS PostgreSQL
# Region:   us-east-1
# ================================================================
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# 0. CONFIGURATION — update these four values before running
# ─────────────────────────────────────────────────────────────
REGION="us-east-1"
VPC_ID="vpc-xxxxxxxxxxxxxxxxx"                                  # existing VPC
PRIVATE_SUBNET_IDS="subnet-xxxxxxxxxxxxxxxxx,subnet-yyyyyyyyyyyyyyyyy"  # ≥2 private subnets
DB_PASSWORD="YourStr0ng!P@ssword99"                             # min 8 chars, mixed case + symbols

# ─────────────────────────────────────────────────────────────
# Derived variables — do not modify below this line
# ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAMBDA_DIR="$(cd "$SCRIPT_DIR/../lambda" && pwd)"

IFS=',' read -ra SUBNET_ARRAY <<< "$PRIVATE_SUBNET_IDS"

# Build JSON array: "subnet-aaa","subnet-bbb"  →  ["subnet-aaa","subnet-bbb"]
_subnet_items=$(printf '"%s",' "${SUBNET_ARRAY[@]}" | sed 's/,$//')
SUBNET_JSON="[$_subnet_items]"

# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────
log()  { echo "    $*"; }
step() {
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  $*"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

echo
echo "  Deploying Multi-Tenant SaaS Application → $REGION"
echo "  VPC: $VPC_ID"

# ─────────────────────────────────────────────────────────────
# 1. SECRETS MANAGER — store DB password before creating RDS
# ─────────────────────────────────────────────────────────────
step "[1/9] Storing RDS password in Secrets Manager"

if aws secretsmanager describe-secret \
     --secret-id "saas/db/password" \
     --region "$REGION" &>/dev/null; then
  log "Secret already exists — updating value..."
  SECRET_ARN=$(aws secretsmanager put-secret-value \
    --secret-id "saas/db/password" \
    --secret-string "$DB_PASSWORD" \
    --region "$REGION" \
    --query 'ARN' \
    --output text)
else
  SECRET_ARN=$(aws secretsmanager create-secret \
    --name "saas/db/password" \
    --description "RDS master password for Multi-Tenant SaaS" \
    --secret-string "$DB_PASSWORD" \
    --region "$REGION" \
    --tags '[
      {"Key":"Name",       "Value":"saas-db-password"},
      {"Key":"Environment","Value":"production"}
    ]' \
    --query 'ARN' \
    --output text)
fi
log "Secret ARN: $SECRET_ARN"

# ─────────────────────────────────────────────────────────────
# 2. COGNITO USER POOL + APP CLIENT + HOSTED UI DOMAIN
# ─────────────────────────────────────────────────────────────
step "[2/9] Creating Cognito User Pool"

USER_POOL_ID=$(aws cognito-idp create-user-pool \
  --pool-name "saas-user-pool" \
  --region "$REGION" \
  --username-attributes email \
  --auto-verified-attributes email \
  --policies '{
    "PasswordPolicy": {
      "MinimumLength":             8,
      "RequireUppercase":          true,
      "RequireLowercase":          true,
      "RequireNumbers":            true,
      "RequireSymbols":            true,
      "TemporaryPasswordValidityDays": 7
    }
  }' \
  --schema '[
    {
      "Name":              "tenant_id",
      "AttributeDataType": "String",
      "Mutable":           true,
      "Required":          false,
      "StringAttributeConstraints": {"MinLength":"1","MaxLength":"256"}
    }
  ]' \
  --user-pool-tags '{"Name":"saas-user-pool","Environment":"production"}' \
  --query 'UserPool.Id' \
  --output text)
log "User Pool ID: $USER_POOL_ID"

# App Client — no client secret (SPA / mobile use)
APP_CLIENT_ID=$(aws cognito-idp create-user-pool-client \
  --user-pool-id "$USER_POOL_ID" \
  --client-name "saas-app-client" \
  --region "$REGION" \
  --no-generate-secret \
  --explicit-auth-flows \
    ALLOW_USER_PASSWORD_AUTH \
    ALLOW_REFRESH_TOKEN_AUTH \
    ALLOW_USER_SRP_AUTH \
  --query 'UserPoolClient.ClientId' \
  --output text)
log "App Client ID: $APP_CLIENT_ID"

# Cognito-hosted UI domain (prefix must be globally unique)
aws cognito-idp create-user-pool-domain \
  --domain "saas-app-prod" \
  --user-pool-id "$USER_POOL_ID" \
  --region "$REGION"
log "Hosted UI base URL: https://saas-app-prod.auth.$REGION.amazoncognito.com"

# ─────────────────────────────────────────────────────────────
# 3. SECURITY GROUPS
# ─────────────────────────────────────────────────────────────
step "[3/9] Creating Security Groups"

# Lambda SG — egress all, zero ingress from internet
LAMBDA_SG_ID=$(aws ec2 create-security-group \
  --group-name "saas-lambda-sg" \
  --description "Outbound-only SG for SaaS Lambda functions" \
  --vpc-id "$VPC_ID" \
  --region "$REGION" \
  --query 'GroupId' \
  --output text)
aws ec2 create-tags \
  --resources "$LAMBDA_SG_ID" \
  --region "$REGION" \
  --tags Key=Name,Value=saas-lambda-sg Key=Environment,Value=production
log "Lambda SG: $LAMBDA_SG_ID"

# RDS SG — port 5432 inbound from Lambda SG only
RDS_SG_ID=$(aws ec2 create-security-group \
  --group-name "saas-rds-sg" \
  --description "PostgreSQL 5432 inbound from Lambda SG only" \
  --vpc-id "$VPC_ID" \
  --region "$REGION" \
  --query 'GroupId' \
  --output text)
aws ec2 authorize-security-group-ingress \
  --group-id "$RDS_SG_ID" \
  --protocol tcp \
  --port 5432 \
  --source-group "$LAMBDA_SG_ID" \
  --region "$REGION"
aws ec2 create-tags \
  --resources "$RDS_SG_ID" \
  --region "$REGION" \
  --tags Key=Name,Value=saas-rds-sg Key=Environment,Value=production
log "RDS SG: $RDS_SG_ID"

# ─────────────────────────────────────────────────────────────
# 4. RDS — DB Subnet Group + PostgreSQL 15 instance
# ─────────────────────────────────────────────────────────────
step "[4/9] Creating RDS Subnet Group and PostgreSQL Instance"

aws rds create-db-subnet-group \
  --db-subnet-group-name "saas-db-subnet-group" \
  --db-subnet-group-description "Private subnets for SaaS RDS (Multi-AZ)" \
  --subnet-ids "${SUBNET_ARRAY[@]}" \
  --region "$REGION" \
  --tags '[
    {"Key":"Name",       "Value":"saas-db-subnet-group"},
    {"Key":"Environment","Value":"production"}
  ]'
log "DB subnet group created"

# Multi-AZ + deletion protection + 7-day backups, not publicly accessible
aws rds create-db-instance \
  --db-instance-identifier "saas-postgres" \
  --db-instance-class "db.t3.medium" \
  --engine postgres \
  --engine-version "15" \
  --master-username "saasadmin" \
  --master-user-password "$DB_PASSWORD" \
  --allocated-storage 20 \
  --storage-type gp3 \
  --db-name "saasdb" \
  --db-subnet-group-name "saas-db-subnet-group" \
  --vpc-security-group-ids "$RDS_SG_ID" \
  --multi-az \
  --backup-retention-period 7 \
  --deletion-protection \
  --no-publicly-accessible \
  --region "$REGION" \
  --tags '[
    {"Key":"Name",       "Value":"saas-postgres"},
    {"Key":"Environment","Value":"production"}
  ]'

log "Waiting for RDS to become available (Multi-AZ can take 15+ minutes)..."
aws rds wait db-instance-available \
  --db-instance-identifier "saas-postgres" \
  --region "$REGION"

RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "saas-postgres" \
  --region "$REGION" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)
log "RDS Endpoint: $RDS_ENDPOINT"

# ─────────────────────────────────────────────────────────────
# 5. IAM ROLE FOR LAMBDA
# ─────────────────────────────────────────────────────────────
step "[5/9] Creating IAM Role for Lambda"

TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect":    "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action":    "sts:AssumeRole"
  }]
}'

LAMBDA_ROLE_ARN=$(aws iam create-role \
  --role-name "saas-lambda-role" \
  --assume-role-policy-document "$TRUST_POLICY" \
  --tags '[
    {"Key":"Name",       "Value":"saas-lambda-role"},
    {"Key":"Environment","Value":"production"}
  ]' \
  --query 'Role.Arn' \
  --output text)

# Managed policies: VPC access (ENI) + basic execution (CloudWatch Logs)
aws iam attach-role-policy \
  --role-name "saas-lambda-role" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"

aws iam attach-role-policy \
  --role-name "saas-lambda-role" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

# Inline policy: allow Lambda to retrieve the DB secret
SECRETS_POLICY=$(cat <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect":   "Allow",
    "Action":   ["secretsmanager:GetSecretValue"],
    "Resource": "$SECRET_ARN"
  }]
}
POLICY
)
aws iam put-role-policy \
  --role-name "saas-lambda-role" \
  --policy-name "saas-lambda-secrets-access" \
  --policy-document "$SECRETS_POLICY"

log "Lambda Role ARN: $LAMBDA_ROLE_ARN"
log "Waiting 20s for IAM role to propagate globally..."
sleep 20

# ─────────────────────────────────────────────────────────────
# 6. LAMBDA FUNCTIONS
# ─────────────────────────────────────────────────────────────
step "[6/9] Packaging and Deploying Lambda Functions"

# Build a deployment zip for each handler.
# If the handler directory exists, the build script has already run;
# otherwise create a minimal placeholder so the rest of the script proceeds.
package_lambda() {
  local name="$1"
  local zip_out="$LAMBDA_DIR/${name}_handler.zip"

  if [[ -f "$zip_out" ]]; then
    log "Found existing $zip_out — skipping build"
    return
  fi

  local src_dir="$LAMBDA_DIR/${name}_handler"
  if [[ ! -d "$src_dir" ]]; then
    log "WARNING: $src_dir not found — creating minimal placeholder"
    mkdir -p "$src_dir"
    cat > "$src_dir/handler.py" <<'PY'
import json, os

def lambda_handler(event, context):
    tenant_id = (event.get("requestContext", {})
                      .get("authorizer", {})
                      .get("claims", {})
                      .get("custom:tenant_id", "unknown"))
    return {
        "statusCode": 200,
        "headers":    {"Content-Type": "application/json"},
        "body":       json.dumps({"tenant_id": tenant_id, "message": "placeholder"}),
    }
PY
  fi

  log "Building $zip_out (including pip dependencies)..."
  if [[ -f "$LAMBDA_DIR/requirements.txt" ]]; then
    pip install -r "$LAMBDA_DIR/requirements.txt" \
      -t "$src_dir" --quiet --upgrade 2>/dev/null || true
  fi
  (cd "$src_dir" && zip -qr "$zip_out" .)
  log "Packaged: $(du -sh "$zip_out" | cut -f1)  $zip_out"
}

for FUNC_NAME in users orders auth; do
  package_lambda "$FUNC_NAME"
done

# Shared VPC and environment config for all three functions
VPC_CONFIG=$(cat <<VPC
{
  "SubnetIds":        $SUBNET_JSON,
  "SecurityGroupIds": ["$LAMBDA_SG_ID"]
}
VPC
)

ENV_VARS=$(cat <<ENV
{
  "Variables": {
    "DB_HOST":    "$RDS_ENDPOINT",
    "DB_NAME":    "saasdb",
    "DB_USER":    "saasadmin",
    "SECRET_ARN": "$SECRET_ARN",
    "REGION":     "$REGION"
  }
}
ENV
)

deploy_lambda() {
  local func_name="$1"
  local zip_key="$2"
  log "Deploying $func_name..."
  aws lambda create-function \
    --function-name "$func_name" \
    --runtime python3.12 \
    --role "$LAMBDA_ROLE_ARN" \
    --handler "handler.lambda_handler" \
    --zip-file "fileb://$LAMBDA_DIR/${zip_key}_handler.zip" \
    --memory-size 256 \
    --timeout 30 \
    --vpc-config "$VPC_CONFIG" \
    --environment "$ENV_VARS" \
    --region "$REGION" \
    --tags "{\"Name\":\"$func_name\",\"Environment\":\"production\"}"
  log "$func_name deployed"
}

deploy_lambda "saas-users-handler"  "users"
deploy_lambda "saas-orders-handler" "orders"
deploy_lambda "saas-auth-handler"   "auth"

# ─────────────────────────────────────────────────────────────
# 7. API GATEWAY — REST API + Cognito Authorizer
# ─────────────────────────────────────────────────────────────
step "[7/9] Creating API Gateway REST API"

ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account \
  --output text)

API_ID=$(aws apigateway create-rest-api \
  --name "saas-api" \
  --description "Multi-Tenant SaaS REST API — protected by Cognito" \
  --region "$REGION" \
  --tags '{"Name":"saas-api","Environment":"production"}' \
  --query 'id' \
  --output text)
log "API ID: $API_ID"

ROOT_ID=$(aws apigateway get-resources \
  --rest-api-id "$API_ID" \
  --region "$REGION" \
  --query 'items[?path==`/`].id' \
  --output text)

USER_POOL_ARN="arn:aws:cognito-idp:$REGION:$ACCOUNT_ID:userpool/$USER_POOL_ID"
AUTHORIZER_ID=$(aws apigateway create-authorizer \
  --rest-api-id "$API_ID" \
  --name "saas-cognito-authorizer" \
  --type COGNITO_USER_POOLS \
  --provider-arns "$USER_POOL_ARN" \
  --identity-source "method.request.header.Authorization" \
  --region "$REGION" \
  --query 'id' \
  --output text)
log "Cognito Authorizer ID: $AUTHORIZER_ID"

# Create a resource, wire GET + POST to a Lambda, grant invoke permissions
setup_resource() {
  local PATH_PART="$1"
  local LAMBDA_NAME="$2"

  log "Configuring /$PATH_PART resource (GET + POST → $LAMBDA_NAME)..."

  RESOURCE_ID=$(aws apigateway create-resource \
    --rest-api-id "$API_ID" \
    --parent-id "$ROOT_ID" \
    --path-part "$PATH_PART" \
    --region "$REGION" \
    --query 'id' \
    --output text)

  LAMBDA_ARN="arn:aws:lambda:$REGION:$ACCOUNT_ID:function:$LAMBDA_NAME"
  INTEGRATION_URI="arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$LAMBDA_ARN/invocations"
  EXEC_ARN="arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID"

  for HTTP_METHOD in GET POST; do
    # Method with Cognito authorizer
    aws apigateway put-method \
      --rest-api-id "$API_ID" \
      --resource-id "$RESOURCE_ID" \
      --http-method "$HTTP_METHOD" \
      --authorization-type COGNITO_USER_POOLS \
      --authorizer-id "$AUTHORIZER_ID" \
      --region "$REGION"

    # Lambda proxy integration
    aws apigateway put-integration \
      --rest-api-id "$API_ID" \
      --resource-id "$RESOURCE_ID" \
      --http-method "$HTTP_METHOD" \
      --type AWS_PROXY \
      --integration-http-method POST \
      --uri "$INTEGRATION_URI" \
      --region "$REGION"

    # Grant API Gateway permission to invoke the Lambda
    aws lambda add-permission \
      --function-name "$LAMBDA_NAME" \
      --statement-id  "apigw-${PATH_PART}-${HTTP_METHOD}" \
      --action        lambda:InvokeFunction \
      --principal     apigateway.amazonaws.com \
      --source-arn    "$EXEC_ARN/*/$HTTP_METHOD/$PATH_PART" \
      --region "$REGION"
  done

  log "/$PATH_PART configured"
}

setup_resource "users"  "saas-users-handler"
setup_resource "orders" "saas-orders-handler"

# ─────────────────────────────────────────────────────────────
# 8. DEPLOY API GATEWAY TO "prod" STAGE
# ─────────────────────────────────────────────────────────────
step "[8/9] Deploying API Gateway to 'prod' stage"

aws apigateway create-deployment \
  --rest-api-id "$API_ID" \
  --stage-name "prod" \
  --stage-description "Production stage" \
  --description "Initial SaaS API deployment" \
  --region "$REGION"

API_INVOKE_URL="https://$API_ID.execute-api.$REGION.amazonaws.com/prod"
log "Invoke URL: $API_INVOKE_URL"

# ─────────────────────────────────────────────────────────────
# 9. SUMMARY
# ─────────────────────────────────────────────────────────────
step "[9/9] Deployment Complete"

echo
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│                    RESOURCE SUMMARY                          │"
echo "├──────────────────────────────────────────────────────────────┤"
printf "│  %-22s  %-37s│\n" "User Pool ID:"   "$USER_POOL_ID"
printf "│  %-22s  %-37s│\n" "App Client ID:"  "$APP_CLIENT_ID"
printf "│  %-22s  %-37s│\n" "RDS Endpoint:"   "$RDS_ENDPOINT"
printf "│  %-22s  %-37s│\n" "API Invoke URL:" "$API_INVOKE_URL"
printf "│  %-22s  %-37s│\n" "DB Secret ARN:"  "$SECRET_ARN"
echo "└──────────────────────────────────────────────────────────────┘"
echo
echo "  Quick test (requires a valid Cognito JWT in \$TOKEN):"
echo "    curl -s -H \"Authorization: \$TOKEN\" $API_INVOKE_URL/users"
echo
