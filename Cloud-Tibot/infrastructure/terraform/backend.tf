/**
 * Project CORTEX — Terraform Remote Backend Configuration
 * 
 * Stores terraform.tfstate in S3 with DynamoDB-based state locking.
 * This is the enterprise-standard approach to prevent concurrent
 * modifications and ensure state durability.
 *
 * PREREQUISITES (one-time setup):
 *   1. Create S3 bucket:
 *      aws s3api create-bucket --bucket cortex-terraform-state-<ACCOUNT_ID> \
 *        --region us-east-1
 *
 *   2. Enable versioning:
 *      aws s3api put-bucket-versioning --bucket cortex-terraform-state-<ACCOUNT_ID> \
 *        --versioning-configuration Status=Enabled
 *
 *   3. Enable encryption:
 *      aws s3api put-bucket-encryption --bucket cortex-terraform-state-<ACCOUNT_ID> \
 *        --server-side-encryption-configuration \
 *        '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
 *
 *   4. Create DynamoDB lock table:
 *      aws dynamodb create-table --table-name cortex-terraform-locks \
 *        --attribute-definitions AttributeName=LockID,AttributeType=S \
 *        --key-schema AttributeName=LockID,KeyType=HASH \
 *        --billing-mode PAY_PER_REQUEST \
 *        --region us-east-1
 *
 *   5. After creating resources, uncomment the backend block below and run:
 *      terraform init -migrate-state
 */

# ⚠️ S3 Backend — ACTIVE ⚠️
terraform {
  backend "s3" {
    bucket         = "dnd-terraform-state-staging-022499047467"
    key            = "cortex/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "cortex-terraform-locks"
  }
}
