# Multi-Tenant SaaS Application on AWS

A production-ready multi-tenant Software-as-a-Service platform deployed on AWS using Terraform, featuring tenant isolation at the database layer, Cognito authentication, API Gateway routing, Lambda serverless compute, and RDS PostgreSQL in a Multi-AZ private subnet. Tenants are completely isolated—each user's data is filtered by `tenant_id` in the database, ensuring zero cross-tenant visibility.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Networking & Routing](#networking--routing)
3. [Component Details](#component-details)
4. [Directory Structure](#directory-structure)
5. [Prerequisites](#prerequisites)
6. [Quick Start](#quick-start)
7. [Input Variables](#input-variables)
8. [Outputs](#outputs)
9. [Scaling Behaviour](#scaling-behaviour)
10. [Tagging Strategy](#tagging-strategy)
11. [Security Considerations](#security-considerations)
12. [Cost Estimate](#cost-estimate)
13. [Destroying the Stack](#destroying-the-stack)
14. [Frequently Asked Questions](#frequently-asked-questions)

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                          AWS Cloud (us-east-1)                      │
├─────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  ┌──────────────────┐                                                │
│  │  Internet        │                                                │
│  │  (Client Apps)   │                                                │
│  └────────┬─────────┘                                                │
│           │ HTTPS                                                    │
│           ▼                                                          │
│  ┌─────────────────────────────────────────────────────────┐        │
│  │   API Gateway (saas-api-gateway)                        │        │
│  │   - Cognito Authorizer on /users, /orders endpoints     │        │
│  │   - 401 Unauthorized without JWT token                  │        │
│  │   - Routes to Lambda functions                          │        │
│  └────┬──────────────┬──────────────┬─────────────────────┘        │
│       │ POST /users  │ GET /users   │ POST /orders                  │
│       │ (create)     │ (list)       │ (create)                      │
│       ▼              ▼              ▼                               │
│  ┌─────────────────────────────────────────────────────────┐        │
│  │         Lambda Functions (in VPC)                       │        │
│  │  ┌──────────────┐ ┌──────────────┐ ┌────────────────┐  │        │
│  │  │ auth-handler │ │ users-handler│ │orders-handler │  │        │
│  │  │              │ │              │ │                │  │        │
│  │  │ Validates    │ │ Creates/Gets │ │Creates/Gets   │  │        │
│  │  │ Cognito JWT  │ │ Users        │ │Orders         │  │        │
│  │  │              │ │ (tenant_id   │ │(tenant_id     │  │        │
│  │  │ Extracts     │ │ filtering)   │ │filtering)     │  │        │
│  │  │ tenant_id    │ │              │ │                │  │        │
│  │  └──────────────┘ └──────────────┘ └────────────────┘  │        │
│  └────────┬──────────────────────────────────────────────┘        │
│           │ TCP/5432 (from Lambda security group only)            │
│           ▼                                                        │
│  ┌─────────────────────────────────────────────────────────┐      │
│  │   RDS PostgreSQL (saas-postgres)                        │      │
│  │   - Multi-AZ deployment (primary + standby)             │      │
│  │   - Private subnet (no internet access)                 │      │
│  │   - Encrypted storage (KMS)                            │      │
│  │   - Security group restricts to Lambda only            │      │
│  │   - Database: saas_db                                  │      │
│  │   - Tables: users, orders (tenant_id column for filter)│      │
│  └─────────────────────────────────────────────────────────┘      │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────┐      │
│  │   Cognito User Pool (saas-user-pool)                    │      │
│  │   - Stores tenants in custom:tenant_id attribute        │      │
│  │   - Issues JWT tokens with tenant_id in claims          │      │
│  │   - App Client supports ADMIN_NO_SRP_AUTH flow          │      │
│  └─────────────────────────────────────────────────────────┘      │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────┐      │
│  │   CloudWatch Logs & Metrics                             │      │
│  │   - Monitors Lambda function execution & errors         │      │
│  │   - Logs RDS performance metrics                        │      │
│  │   - Alarms on error rates & latency                     │      │
│  └─────────────────────────────────────────────────────────┘      │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

**Traffic flow:** Client authenticates via Cognito → receives JWT with `custom:tenant_id` claim → sends JWT in Authorization header to API Gateway → API Gateway validates JWT with Cognito Authorizer → routes to Lambda function → Lambda extracts `tenant_id` from JWT → queries RDS with `WHERE tenant_id = <extracted_value>` → returns data scoped to requesting tenant only.

## Networking & Routing

### VPC & Subnets

| Component | ID | CIDR | Availability Zone | Access |
|-----------|-----|------|-------------------|--------|
| VPC | vpc-0b8ea2c5bf5093847 | 10.0.0.0/24 | us-east-1 | Private |
| Private Subnet 1 | subnet-02cb41c2b5a9f7927 | 10.0.0.32/28 | us-east-1a | NAT Gateway |
| Private Subnet 2 | subnet-0360d6b57c9e8ec3f | 10.0.0.48/28 | us-east-1b | NAT Gateway |

### Route Tables

| Subnet | Destination | Target | Purpose |
|--------|-------------|--------|---------|
| Private Subnet 1 | 0.0.0.0/0 | NAT Gateway | Internet egress |
| Private Subnet 2 | 0.0.0.0/0 | NAT Gateway | Internet egress |
| Local | 10.0.0.0/24 | Local | Internal routing |

### Traffic Flow Diagram

```
┌────────────────────────────────────────────────────────┐
│           External Client (Internet)                   │
└─────────────────────────┬────────────────────────────┘
                          │ HTTPS:443
                          ▼
        ┌─────────────────────────────────┐
        │   API Gateway (Regional)        │
        │   Endpoint: vwhvkwa4n6.exe...   │
        └──────────────┬────────────────┘
                       │ /users /orders (routed to Lambda)
                       ▼
        ┌──────────────────────────────────────┐
        │   Lambda Functions (Private VPC)      │
        │   Subnets: subnet-02cb41c2b5a9f7927  │
        │           subnet-0360d6b57c9e8ec3f  │
        └──────────┬───────────────────────────┘
                   │ PostgreSQL TCP:5432
                   ▼
        ┌──────────────────────────────────────┐
        │   RDS PostgreSQL (Private Subnet)    │
        │   Endpoint: saas-postgres.cy188y... │
        └──────────────────────────────────────┘
```

## Component Details

### 1. Security Groups

| Resource | Group Name | Rules | Purpose |
|----------|-----------|-------|---------|
| Lambda | saas-lambda-sg | Egress: All to 0.0.0.0/0 | Allows Lambda to reach RDS and external services |
| RDS | saas-rds-sg | Ingress: TCP:5432 from saas-lambda-sg only | Restricts database access to Lambda functions only |

### 2. Cognito User Pool

| Attribute | Value |
|-----------|-------|
| Name | saas-user-pool |
| Region | us-east-1 |
| Password Policy | Min 8 chars, uppercase, lowercase, numbers, symbols |
| Custom Attributes | `custom:tenant_id` (tenant identifier) |
| MFA | Optional (can be enabled per user) |
| Account Lockout | 5 failed attempts, 15-minute lockout |

**Cognito App Client Configuration:**

| Setting | Value |
|---------|-------|
| Client Name | saas-app-client |
| Generate Secret | False (for SPA/mobile apps) |
| Auth Flows | ALLOW_USER_PASSWORD_AUTH, ALLOW_REFRESH_TOKEN_AUTH, ALLOW_USER_SRP_AUTH, ALLOW_ADMIN_USER_PASSWORD_AUTH |
| Token Expiration | 1 hour (access & ID token), 30 days (refresh token) |

### 3. Lambda Functions

> Each Lambda function runs inside the private VPC, connects to RDS with credentials from Secrets Manager, and enforces tenant isolation via `WHERE tenant_id = <from_jwt>` clauses.

| Function | Handler | Environment | Purpose |
|----------|---------|-------------|---------|
| saas-auth-handler | lambda_function.lambda_handler | Python 3.14, psycopg2 | Validates JWT token format and Cognito signature |
| saas-users-handler | lambda_function.lambda_handler | Python 3.14, psycopg2, Secrets Manager | Creates/retrieves users scoped to tenant_id |
| saas-orders-handler | lambda_function.lambda_handler | Python 3.14, psycopg2, Secrets Manager | Creates/retrieves orders scoped to tenant_id |

**Lambda Execution Role Permissions:**

| Resource | Action |
|----------|--------|
| Secrets Manager saas/db/password | secretsmanager:GetSecretValue |
| VPC execution | ec2:CreateNetworkInterface, ec2:DescribeNetworkInterfaces, ec2:DeleteNetworkInterface |
| CloudWatch Logs | logs:CreateLogGroup, logs:CreateLogStream, logs:PutLogEvents |

### 4. API Gateway

| Endpoint | Method | Authorizer | Lambda Target |
|----------|--------|-----------|----------------|
| /users | POST | Cognito | saas-users-handler (create) |
| /users | GET | Cognito | saas-users-handler (list by tenant_id) |
| /orders | POST | Cognito | saas-orders-handler (create) |
| /orders | GET | Cognito | saas-orders-handler (list by tenant_id) |

**Cognito Authorizer:**

| Setting | Value |
|---------|-------|
| User Pool | saas-user-pool |
| Token Source | Authorization header (Bearer token) |
| Validation | Signature verification + JWT claims |

### 5. RDS PostgreSQL

| Attribute | Value |
|-----------|-------|
| Instance Class | db.t3.medium (2 vCPU, 4 GB RAM) |
| Engine | PostgreSQL 15.7 |
| Multi-AZ | Enabled (standby in us-east-1b) |
| Storage | 100 GB, gp3 (General Purpose) |
| Backup Retention | 7 days |
| Encryption | KMS-encrypted at rest |
| Database | saas_db |
| Master User | postgres |
| Password | Stored in Secrets Manager (arn:aws:secretsmanager:...) |

**Database Schema:**

```sql
CREATE TABLE users (
  id SERIAL PRIMARY KEY,
  tenant_id VARCHAR(255) NOT NULL,
  email VARCHAR(255) NOT NULL,
  name VARCHAR(255),
  created_at TIMESTAMP DEFAULT NOW(),
  UNIQUE(tenant_id, email)
);

CREATE TABLE orders (
  id SERIAL PRIMARY KEY,
  tenant_id VARCHAR(255) NOT NULL,
  user_id INT REFERENCES users(id),
  order_date TIMESTAMP DEFAULT NOW(),
  amount DECIMAL(10, 2),
  status VARCHAR(50) DEFAULT 'pending'
);

CREATE INDEX idx_users_tenant_id ON users(tenant_id);
CREATE INDEX idx_orders_tenant_id ON orders(tenant_id);
```

### 6. Secrets Manager

| Secret | Value | Rotation |
|--------|-------|----------|
| saas/db/password | RDS master password | Manual (update and re-apply Terraform) |

## Directory Structure

```
.
├── README.md                          # This file
├── TESTING-GUIDE.md                   # Comprehensive test documentation
├── TESTING-UPDATES.md                 # Summary of test changes
├── REAL-AWS-SERVICE-TESTING.md        # Real AWS service testing approach
├── terraform/
│   ├── main.tf                        # Complete infrastructure definition (540 lines)
│   │                                  # Includes: provider, Cognito, RDS, Lambda,
│   │                                  # API Gateway, IAM, Security Groups, archives
│   ├── variables.tf                   # Input variables (db_password, vpc_id, etc.)
│   ├── outputs.tf                     # Output values (API URL, RDS endpoint, etc.)
│   ├── terraform.tfvars              # Variable values (VPC/subnet IDs, region)
│   └── .terraform/                    # Terraform working directory (generated)
├── lambda/
│   ├── auth_handler/
│   │   ├── lambda_function.py        # JWT validation logic
│   │   ├── psycopg2/                 # PostgreSQL driver dependency
│   │   ├── psycopg2_binary-2.9.12.dist-info/
│   │   └── psycopg2_binary.libs/     # Binary dependencies for psycopg2
│   ├── users_handler/
│   │   ├── lambda_function.py        # User CRUD with tenant_id filtering
│   │   ├── psycopg2/
│   │   ├── psycopg2_binary-2.9.12.dist-info/
│   │   └── psycopg2_binary.libs/
│   ├── orders_handler/
│   │   ├── lambda_function.py        # Order CRUD with tenant_id filtering
│   │   ├── psycopg2/
│   │   ├── psycopg2_binary-2.9.12.dist-info/
│   │   └── psycopg2_binary.libs/
│   └── requirements.txt               # Dependencies (psycopg2-binary==2.9.12)
├── scripts/
│   └── build_lambdas.sh              # Builds zip archives for Lambda deployment
├── test-quick.sh                      # 4 quick tests (5 minutes) - RDS, API, Auth, Isolation
├── test-comprehensive.sh              # 19 comprehensive tests (30 minutes) - 6 phases
├── test-critical.sh                   # Security & production readiness tests (10 minutes)
├── test-database-isolation.sh         # Direct RDS multi-tenant validation
├── test-all.sh                        # Interactive test suite runner
└── .gitignore                         # Excludes psycopg2, .terraform, *.tfstate
```

## Prerequisites

| Tool | Minimum Version | Install Link |
|------|-----------------|--------------|
| Terraform | 1.9 | https://www.terraform.io/downloads |
| AWS CLI | 2.0+ | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| Python | 3.9+ | https://www.python.org/downloads/ |
| jq | 1.6+ | https://stedolan.github.io/jq/download/ |
| PostgreSQL Client (psql) | 13+ | https://www.postgresql.org/download/ |

**AWS Account Requirements:**

- AWS account with IAM permissions for: Cognito, RDS, Lambda, API Gateway, EC2, Secrets Manager, CloudWatch
- S3 bucket for Terraform state (backend configured in main.tf)
- DynamoDB table for Terraform state locking (cortex-terraform-locks)
- Existing VPC with private subnets (see terraform.tfvars for IDs)

**Pre-deployment Checklist:**

- [ ] AWS CLI configured with credentials: `aws sts get-caller-identity`
- [ ] VPC and private subnets exist and are reachable from intended region
- [ ] Terraform state S3 bucket exists and is accessible
- [ ] DynamoDB locking table exists
- [ ] IAM user/role has permissions for all AWS services used

## Quick Start

1. **Clone and navigate to project:**
```bash
cd /Users/brendonang/Code/AWS\ Project/Multi-Tenant\ SaaS\ Application
```

2. **Verify prerequisites:**
```bash
terraform -version          # Should be >= 1.9
aws sts get-caller-identity # Should show your AWS account
jq --version               # Should be installed
```

3. **Initialize Terraform:**
```bash
cd terraform
terraform init
```

4. **Plan the deployment:**
```bash
terraform plan -var="db_password=YourStr0ng!P@ssword99"
```

5. **Apply the infrastructure (creates all AWS resources):**
```bash
terraform apply -var="db_password=YourStr0ng!P@ssword99" -auto-approve
```

6. **Verify deployment (retrieve endpoints):**
```bash
terraform output api_gateway_invoke_url
terraform output rds_endpoint
terraform output user_pool_id
```

7. **Run quick tests to validate the stack:**
```bash
cd ..
bash test-quick.sh
```

Allow 10-15 minutes for full deployment (RDS Multi-AZ provisioning takes time). Lambda functions and API Gateway are ready within 2-3 minutes.

## Input Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| region | string | us-east-1 | AWS region for deployment |
| vpc_id | string | (required) | VPC ID for Lambda and RDS (must exist) |
| private_subnet_ids | list(string) | (required) | Private subnet IDs for Lambda and RDS (2 required for Multi-AZ) |
| db_password | string | (no default) | Master password for RDS PostgreSQL (must pass at plan/apply time, min 8 chars) |

**Validation Rules:**

- `db_password` must be 8-40 characters, contain uppercase, lowercase, numbers, and symbols (no @, !, $ to avoid shell escaping issues)
- `private_subnet_ids` must contain exactly 2 subnet IDs in different AZs
- `vpc_id` must be a valid VPC that contains the specified subnets

Example values in `terraform.tfvars`:
```hcl
region = "us-east-1"
vpc_id = "vpc-0b8ea2c5bf5093847"
private_subnet_ids = [
  "subnet-02cb41c2b5a9f7927",  # us-east-1a
  "subnet-0360d6b57c9e8ec3f"   # us-east-1b
]
# db_password intentionally omitted from .tfvars (pass at runtime)
```

## Outputs

| Output | Description | Example |
|--------|-------------|---------|
| api_gateway_invoke_url | Base URL for API Gateway | https://vwhvkwa4n6.execute-api.us-east-1.amazonaws.com/prod |
| rds_endpoint | RDS PostgreSQL connection string | saas-postgres.cy188y02caa5.us-east-1.rds.amazonaws.com |
| user_pool_id | Cognito User Pool ID | us-east-1_vC8GD1Bjr |
| app_client_id | Cognito App Client ID | 4vmp2v0k0093ntrlafvvlsuih3 |
| db_secret_arn | Secrets Manager ARN for RDS password | arn:aws:secretsmanager:us-east-1:022499047467:secret:saas/db/password-xxxxx |
| lambda_role_arn | IAM role ARN for Lambda execution | arn:aws:iam::022499047467:role/saas-lambda-role |

**Usage:**

```bash
# Retrieve all outputs
terraform output

# Get specific output
API_URL=$(terraform output -raw api_gateway_invoke_url)
RDS_ENDPOINT=$(terraform output -raw rds_endpoint)
USER_POOL_ID=$(terraform output -raw user_pool_id)
```

## Scaling Behaviour

Lambda and API Gateway auto-scale to handle traffic spikes. RDS scaling requires manual intervention.

```
Concurrent Users
              │
         100  │                    ┌──────────────────
              │                   ╱  Auto-scaled up
          50  │    ┌─────────────╱   (Lambda concurrency)
              │   ╱  Dead band
          25  │──╱   (50-unit threshold)
              │
              └──────────────────────────────────► Time
              0      10m      20m      30m
```

**Lambda Scaling:**

- Reserved concurrency: 100 (always-warm instances)
- Provisioned throughput: Scales to 1000 concurrent executions
- Cold start: ~500ms (first invocation after idle period)
- Warm start: ~50ms (subsequent invocations)

**RDS Scaling:**

- Auto-scaling: Disabled (manual scaling required)
- Current: db.t3.medium (2 vCPU, 4 GB RAM, ~1000 IOPS)
- To scale up: `terraform apply` with larger `instance_class` (e.g., db.t3.large)
- Failover time: ~1-2 minutes (Multi-AZ standby promotion)

**Evaluation Period & Step Size Rationale:**

- Lambda evaluation: 1-minute intervals (detects spikes quickly)
- Step size: 100 additional concurrent executions per scale-up event (balances cost vs. responsiveness)
- Scale-down: After 5 minutes of low utilization (prevents thrashing)

## Tagging Strategy

| Tag Key | Value | Resource Scope |
|---------|-------|-----------------|
| Environment | prod | All resources |
| Project | MultiTenantSaaS | All resources |
| ManagedBy | Terraform | All resources |
| Service | api \| database \| auth | Specific component |
| TenantId | (per tenant) | Not applied at infrastructure level (applied at application layer in JWT) |
| CostCenter | Engineering | All resources |

**Tag Propagation:**

- RDS tags: Propagated to snapshots and backups (via `copy_tags_to_snapshot = true`)
- Lambda: Tags applied to function and associated log groups
- API Gateway: Tags applied to the API stage

## Security Considerations

| Topic | Current Posture | Recommended Hardening |
|-------|-----------------|------------------------|
| **RDS Access** | Private subnet, no public IP, restricted security group | ✅ Implemented: Lambda-only inbound on port 5432 |
| **Lambda in VPC** | Runs in private subnets, no internet access for inbound | ✅ Implemented: Egress to NAT Gateway only |
| **Secrets Management** | RDS password in Secrets Manager, rotated manually | 🔶 Upgrade: Enable automatic rotation via Lambda |
| **API Authorization** | Cognito JWT on protected endpoints | ✅ Implemented: API Gateway Cognito Authorizer |
| **Data Encryption** | RDS storage encrypted (KMS), TLS for API | ✅ Implemented |
| **HTTPS** | API Gateway enforces HTTPS | ✅ Implemented |
| **Tenant Isolation** | Database-level filtering via tenant_id in JWT | ✅ Implemented: All queries scoped to tenant_id |
| **DDoS Protection** | CloudFront and WAF not configured | 🔶 Optional: Add CloudFront + AWS WAF for prod |
| **Logging & Monitoring** | CloudWatch Logs for Lambda, RDS Enhanced Monitoring disabled | 🟡 Upgrade: Enable RDS Enhanced Monitoring & VPC Flow Logs |
| **IAM Least Privilege** | Lambda role restricted to Secrets Manager + VPC + Logs | ✅ Implemented |

## Cost Estimate

| Resource | Quantity | Unit | Monthly Cost (USD) |
|----------|----------|------|-------------------|
| RDS db.t3.medium (Multi-AZ) | 1 primary + 1 standby | $0.175/hour | $127.05 |
| RDS Storage (100 GB gp3) | 100 | $0.12/GB/month | $12.00 |
| RDS Backup (7-day retention) | 1 | $0.021/GB | $2.10 |
| Lambda (1M invocations, 512 MB) | 1M | $0.20 per 1M | $0.20 |
| Lambda (compute, 1s avg duration) | 1M × 1s = 277 GB-seconds | $0.0000166667/GB-s | $4.63 |
| API Gateway (requests) | 1M | $3.50 per 1M | $3.50 |
| Secrets Manager | 1 secret | $0.40/month | $0.40 |
| CloudWatch Logs (10 GB ingested) | 10 | $0.50/GB | $5.00 |
| Data Transfer (100 GB out) | 100 | $0.09/GB (after 1 GB free) | $8.91 |
| **TOTAL (estimated monthly)** | | | **$164.79** |

**Assumptions:**
- 1 million API requests per month
- Average Lambda execution: 1 second, 512 MB memory
- 10 GB of CloudWatch Logs per month
- 100 GB outbound data transfer per month

**Cost Optimization:**
- Use Lambda reserved capacity for predictable workloads (10-20% savings)
- Enable RDS storage auto-scaling to avoid over-provisioning
- Archive old CloudWatch Logs to S3 Glacier (~$0.004/GB/month)

**For pricing details, see:** https://aws.amazon.com/pricing/

## Destroying the Stack

> ⚠️ This will delete all AWS resources created by Terraform, including the RDS database. Backups older than 7 days will be deleted. Ensure you have exported any needed data.

1. **Disable RDS deletion protection (if enabled):**
```bash
cd terraform
aws rds modify-db-instance \
  --db-instance-identifier saas-postgres \
  --no-deletion-protection \
  --apply-immediately \
  --region us-east-1
```

2. **Destroy all resources:**
```bash
terraform destroy -var="db_password=YourStr0ng!P@ssword99" -auto-approve
```

3. **Verify cleanup:**
```bash
# Check that API Gateway, Lambda, RDS, Cognito are gone
aws apigateway get-rest-apis --region us-east-1
aws lambda list-functions --region us-east-1
aws rds describe-db-instances --region us-east-1
aws cognito-idp list-user-pools --max-results 10 --region us-east-1
```

**Manual Cleanup (not managed by Terraform):**

- [ ] Secrets Manager `saas/db/password` secret (Terraform manages it, but verify it's deleted)
- [ ] S3 bucket with Terraform state (if migrating or archiving)
- [ ] CloudWatch Log Groups (may persist after destroy, delete via AWS Console if needed)

## Frequently Asked Questions

### Q1: How does tenant isolation work?

**A:** Tenant isolation is enforced at the database layer. When a user logs in via Cognito, their JWT includes a `custom:tenant_id` claim (e.g., `tenant-001`). Every Lambda function extracts this claim and uses it in SQL queries:

```python
tenant_id = jwt_claims['custom:tenant_id']
cursor.execute("SELECT * FROM users WHERE tenant_id = %s AND email = %s", (tenant_id, email))
```

If an attacker modifies their JWT to claim a different tenant_id, the API Gateway Cognito Authorizer will reject it (JWT signature verification fails). If they somehow bypass the authorizer, the Lambda will only see data for the tenant_id in the verified JWT. **There is no way for one tenant's user to see another tenant's data.**

### Q2: What happens if RDS has a failover?

**A:** RDS is deployed with Multi-AZ replication. The primary instance (us-east-1a) is replicated synchronously to a standby (us-east-1b). On primary failure:
1. RDS automatically detects the failure (~1-2 minutes)
2. DNS endpoint (`saas-postgres.cy188y02caa5.us-east-1.rds.amazonaws.com`) points to the standby
3. Standby becomes the new primary
4. Lambda functions reconnect (pooling handles this automatically)
5. Data loss: Zero (synchronous replication)
6. Application impact: ~1-2 minute downtime during failover

No manual intervention is required. To minimize failover time, ensure Lambda connection pooling is enabled.

### Q3: How do I add HTTPS/TLS to the API?

**A:** API Gateway automatically provides a TLS certificate (*.execute-api.us-east-1.amazonaws.com). To use a custom domain:

1. **Request an ACM certificate** for your domain (e.g., api.example.com)
2. **Create a Custom Domain Name in API Gateway:**
```bash
aws apigateway create-domain-name \
  --domain-name api.example.com \
  --certificate-arn arn:aws:acm:us-east-1:...:certificate/... \
  --region us-east-1
```
3. **Update your DNS CNAME** to point to the API Gateway endpoint
4. **Update application code** to use `https://api.example.com/prod` instead of the default endpoint

Clients will verify the certificate; TLS 1.2+ is enforced by API Gateway.

### Q4: How do I update my application code without redeploying Lambda?

**A:** Lambda code is packaged into a ZIP file and deployed by Terraform. To update:

1. **Modify Lambda function code** (e.g., `lambda/users_handler/lambda_function.py`)
2. **Rebuild the ZIP archive:**
```bash
bash scripts/build_lambdas.sh
```
3. **Re-apply Terraform** (detects code changes and updates Lambda):
```bash
terraform apply -var="db_password=YourStr0ng!P@ssword99"
```

Terraform uses `archive_file` to detect code changes via a hash. If the hash changes, Lambda is updated automatically. This typically takes <10 seconds per function.

### Q5: How do I manage Terraform state in production?

**A:** Terraform state is stored in an S3 bucket (`dnd-terraform-state-staging-022499047467`) with DynamoDB state locking. **Never commit `terraform.tfstate` to git.**

- **Local state:** `terraform.tfstate` (in your working directory, git-ignored)
- **Remote state:** S3 bucket (configured in `backend "s3"` block in main.tf)
- **Locking:** DynamoDB (`cortex-terraform-locks`) prevents concurrent applies

To work with remote state:
```bash
# Pull latest state
terraform refresh

# Show remote state
terraform show

# Lock/unlock (normally automatic)
terraform force-unlock <LOCK_ID>  # Only if lock is stuck
```

### Q6: What happens if I run `terraform apply` twice?

**A:** Terraform is idempotent. Running `apply` twice with the same variables will:
1. Refresh state (check current AWS resources)
2. Detect no changes needed (all resources match config)
3. Output "No changes. Your infrastructure matches the configuration."

No resources are re-created or modified. This is safe and recommended for CI/CD pipelines.

### Q7: How do I scale the database to handle more users?

**A:** RDS scaling requires modifying the Terraform config:

```hcl
# In terraform/main.tf, find the RDS resource:
instance_class = "db.t3.large"  # Change from db.t3.medium
```

Then apply:
```bash
terraform apply -var="db_password=..."
```

Terraform will modify the RDS instance (downtime ~10-15 minutes for parameter group application). To minimize downtime, use Multi-AZ (already enabled) and apply during off-peak hours.

### Q8: What's the point of the critical tests?

**A:** The critical test suite (`test-critical.sh`) verifies production readiness by checking:
1. **RDS not public** — ensures database is not accidentally exposed to internet
2. **RDS encrypted** — verifies KMS encryption is enabled
3. **Lambda in VPC** — confirms serverless compute is isolated
4. **API Gateway enforces auth** — checks 401 is returned without JWT
5. **RDS security group restrictive** — verifies only Lambda can connect
6. **Cognito auth works** — tests user creation and JWT generation
7. **Tenant isolation** — confirms users only see their own data

If any test fails, the deployment is not production-ready. Run before cutover.

---

**For issues or questions, check the [TESTING-GUIDE.md](TESTING-GUIDE.md) and [REAL-AWS-SERVICE-TESTING.md](REAL-AWS-SERVICE-TESTING.md) for comprehensive test documentation.**
