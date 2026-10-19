#!/bin/bash

# ═══════════════════════════════════════════════════════════════════════════════
# 🤖 Copilot PR Guardian — Automated Deployment Script
# ═══════════════════════════════════════════════════════════════════════════════
# 
# This script will:
# 1. Verify credentials are set
# 2. Plan Terraform deployment
# 3. Deploy new Lambda function
# 4. Output webhook URL for GitHub configuration
# 5. Run tests
#
# Usage:
#   bash scripts/deploy_copilot_guardian.sh
#
# Requirements:
#   - AWS CLI configured with credentials
#   - Terraform installed
#   - GitHub token (ghp_...)
#   - Telegram token and chat ID
# ═══════════════════════════════════════════════════════════════════════════════

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ─────────────────────────────────────────────────────────────────────────────
# Function: Print section headers
# ─────────────────────────────────────────────────────────────────────────────

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_step() {
    echo -e "${YELLOW}→${NC} $1"
}

print_success() {
    echo -e "${GREEN}✅${NC} $1"
}

print_error() {
    echo -e "${RED}❌${NC} $1"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Verify environment
# ─────────────────────────────────────────────────────────────────────────────

print_header "Step 1: Verify Environment"

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    print_error "AWS CLI not found. Install it first: https://aws.amazon.com/cli/"
    exit 1
fi
print_success "AWS CLI found"

# Check Terraform
if ! command -v terraform &> /dev/null; then
    print_error "Terraform not found. Install it first: https://www.terraform.io/downloads"
    exit 1
fi
print_success "Terraform found (version $(terraform version -json | grep terraform_version | head -1))"

# Check credentials
print_step "Checking credentials..."

if [ -z "$GITHUB_TOKEN" ]; then
    print_error "GITHUB_TOKEN not set"
    echo ""
    echo "Set it with:"
    echo "  export GITHUB_TOKEN=\"ghp_your_actual_token_here\""
    exit 1
fi
print_success "GITHUB_TOKEN is set"

if [ -z "$TELEGRAM_TOKEN" ]; then
    print_error "TELEGRAM_TOKEN not set"
    echo ""
    echo "Set it with:"
    echo "  export TELEGRAM_TOKEN=\"8281522719:AAHb8gk-sIVpjnGmOIYbE5FuzZ347J4FKTc\""
    exit 1
fi
print_success "TELEGRAM_TOKEN is set"

if [ -z "$TELEGRAM_CHAT_ID" ]; then
    print_error "TELEGRAM_CHAT_ID not set"
    echo ""
    echo "Set it with:"
    echo "  export TELEGRAM_CHAT_ID=\"-1003702164149\""
    exit 1
fi
print_success "TELEGRAM_CHAT_ID is set"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Verify AWS credentials
# ─────────────────────────────────────────────────────────────────────────────

print_header "Step 2: Verify AWS Credentials"

if ! aws sts get-caller-identity > /dev/null 2>&1; then
    print_error "AWS credentials not configured or invalid"
    echo ""
    echo "Configure AWS credentials with:"
    echo "  aws configure"
    exit 1
fi

AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(aws configure get region || echo "us-east-1")
print_success "AWS Account: $AWS_ACCOUNT"
print_success "AWS Region: $AWS_REGION"

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Navigate to Terraform directory
# ─────────────────────────────────────────────────────────────────────────────

print_header "Step 3: Initialize Terraform"

cd infrastructure/terraform || exit 1
print_success "Changed to infrastructure/terraform directory"

# Initialize Terraform if needed
if [ ! -d ".terraform" ]; then
    print_step "Initializing Terraform..."
    terraform init
    print_success "Terraform initialized"
else
    print_success "Terraform already initialized"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Plan deployment
# ─────────────────────────────────────────────────────────────────────────────

print_header "Step 4: Plan Deployment"

print_step "Creating Terraform plan..."

terraform plan \
    -var-file=../terraform.tfvars.dev \
    -var="github_token=$GITHUB_TOKEN" \
    -out=plan.copilot

print_success "Plan created: plan.copilot"

echo ""
echo "Resources that will be created:"
echo "  - aws_lambda_function.copilot_guardian"
echo "  - aws_iam_role.lambda_copilot_guardian"
echo "  - aws_cloudwatch_log_group.copilot_guardian"
echo "  - aws_lambda_permission.copilot_guardian_apigw"
echo "  - aws_apigatewayv2_integration.copilot_guardian"
echo "  - aws_apigatewayv2_route.copilot_webhook"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Apply deployment
# ─────────────────────────────────────────────────────────────────────────────

print_header "Step 5: Deploy Lambda Function"

read -p "Ready to deploy? (yes/no) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_error "Deployment cancelled"
    exit 1
fi

print_step "Applying Terraform configuration..."

terraform apply plan.copilot

print_success "Deployment complete!"

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Get outputs
# ─────────────────────────────────────────────────────────────────────────────

print_header "Step 6: Deployment Summary"

WEBHOOK_URL=$(terraform output -raw github_copilot_webhook_url)
LAMBDA_NAME=$(terraform output -json lambda_function_names | grep copilot_guardian | cut -d'"' -f4)
LOG_GROUP=$(terraform output -json cloudwatch_log_groups | grep copilot_guardian | cut -d'"' -f4)

print_success "Lambda Function: $LAMBDA_NAME"
print_success "Log Group: $LOG_GROUP"
print_success "Webhook URL: $WEBHOOK_URL"

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: Next steps
# ─────────────────────────────────────────────────────────────────────────────

print_header "Next Steps"

echo "1. Configure GitHub webhook:"
echo ""
echo "   - Go to: https://github.com/Aterpise-MY/IB-DND-5e-Platform/settings/hooks"
echo "   - Click 'Add webhook'"
echo "   - Payload URL: $WEBHOOK_URL"
echo "   - Content type: application/json"
echo "   - Events: Pull requests > reviewed"
echo "   - Active: ✓"
echo "   - Click 'Add webhook'"
echo ""

echo "2. Test Copilot detection:"
echo ""
echo "   cd ../.."
echo "   python3 scripts/test_pr_review_notifier.py --copilot"
echo ""

echo "3. Create a test PR:"
echo ""
echo "   - Open: https://github.com/Aterpise-MY/IB-DND-5e-Platform"
echo "   - Create a test PR or use existing PR #78"
echo "   - Wait for Copilot to auto-review"
echo "   - Check Telegram Topic 118 for the message"
echo ""

echo "4. Monitor Lambda logs:"
echo ""
echo "   aws logs tail $LOG_GROUP --follow"
echo ""

print_success "Deployment script complete!"

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────────────────

# Move back to root
cd ../..

print_header "✅ All Done!"
echo "Your Copilot PR Guardian Lambda is now live!"
echo ""
