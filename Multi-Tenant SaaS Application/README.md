# Multi-Tenant SaaS Application

A production-ready multi-tenant SaaS platform deployed entirely on AWS. Multiple customers (tenants) share a single AWS infrastructure stack while their data remains fully isolated at the query layer. Authentication is handled by Cognito; every API request carries a signed JWT whose `custom:tenant_id` claim is extracted by Lambda and used to scope every SQL query to the calling tenant's rows. API Gateway enforces authentication at the edge, Lambda executes Python 3.12 business logic inside a private VPC, and RDS PostgreSQL 15 stores all tenant data in a shared-schema, row-level-isolated database. Credentials never appear in environment variables — Lambda fetches the database password from Secrets Manager at cold-start.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Networking & Routing](#2-networking--routing)
3. [Component Details](#3-component-details)
4. [Directory Structure](#4-directory-structure)
5. [Prerequisites](#5-prerequisites)
6. [Quick Start](#6-quick-start)
7. [Input Variables](#7-input-variables)
8. [Outputs](#8-outputs)
9. [Scaling Behaviour](#9-scaling-behaviour)
10. [Tagging Strategy](#10-tagging-strategy)
11. [Security Considerations](#11-security-considerations)
12. [Cost Estimate](#12-cost-estimate)
13. [Destroying the Stack](#13-destroying-the-stack)
14. [Challenge Quests](#14-challenge-quests)
15. [Frequently Asked Questions](#15-frequently-asked-questions)

---

## 1. Architecture Overview

```
  ┌───────────────────────────────────────────────────────────────────────┐
  │                          us-east-1                               │
  │                                                                       │
  │   Client / SPA                                                        │
  │   ┌──────────┐   HTTPS Bearer JWT                                     │
  │   │  Browser │ ──────────────────────▶ ┌───────────────────────────┐  │
  │   │ / Mobile │                         │     API Gateway (REST)    │  │
  │   └──────────┘                         │  ┌─────────────────────┐  │  │
  │                                        │  │  Cognito Authorizer │  │  │
  │                                        │  │  validates JWT &    │  │  │
  │                                        │  │  injects claims     │  │  │
  │                                        │  └────────┬────────────┘  │  │
  │                                        │           │ AWS_PROXY     │  │
  │                                        └───────────┼───────────────┘  │
  │                                                    │                  │
  │                                                    ▼                  │
  │                          ┌─────────────────────────────────────┐      │
  │                          │  Lambda (Python 3.12, VPC-attached) │      │
  │                          │  ┌──────────────────────────────┐   │      │
  │                          │  │  1. Read tenant_id from JWT  │   │      │
  │                          │  │  2. Fetch DB password from   │   │      │
  │                          │  │     Secrets Manager (cached) │   │      │
  │                          │  │  3. Query RDS filtered by    │   │      │
  │                          │  │     WHERE tenant_id = ?      │   │      │
  │                          │  └──────────────────────────────┘   │      │
  │                          └───────────────┬─────────────────────┘      │
  │                                          │                            │
  │              ┌───────────────────────────┼────────────────┐           │
  │              │                           │                │           │
  │              ▼  SQL :5432                │                ▼           │
  │   ┌─────────────────────────┐            │   ┌────────────────────┐   │
  │   │   RDS PostgreSQL 15     │            │   │  Secrets Manager   │   │
  │   │   db.t3.medium Multi-AZ │            │   │  saas/db/password  │   │
  │   │   Private subnets only  │            │   └────────────────────┘   │
  │   │   saas-rds-sg           │            │                            │
  │   └─────────────────────────┘            │                            │
  │                                          │   ┌────────────────────┐   │
  │                                          └──▶│   CloudWatch Logs  │   │
  │                                              │   /aws/lambda/*    │   │
  │                                              └────────────────────┘   │
  └───────────────────────────────────────────────────────────────────────┘
```

**Traffic flow:** Client presents a Cognito-issued JWT as a Bearer token → API Gateway's Cognito Authorizer validates the signature and expiry → API Gateway injects the decoded claims into `requestContext.authorizer.claims` → Lambda proxy integration forwards the full event to the handler → Lambda extracts `custom:tenant_id` from the claims, fetches the database password from Secrets Manager on first invocation, then issues a parameterised SQL query with `WHERE tenant_id = ?` → RDS PostgreSQL returns only that tenant's rows → Lambda returns the JSON response.

---

## 2. Networking & Routing

### VPC

| Attribute       | Value                              |
|-----------------|------------------------------------|
| VPC ID          | supplied via `vpc_id` variable     |
| DNS Hostnames   | enabled (required for RDS endpoint)|
| DNS Resolution  | enabled                            |
| Region          | `us-east-1`                   |

### Subnets

| Name       | AZ                  | Visibility | Used by              |
|------------|---------------------|------------|----------------------|
| private-1  | `us-east-1a`   | Private    | RDS (primary), Lambda|
| private-2  | `us-east-1b`   | Private    | RDS (standby), Lambda|

> Subnets must be private (no direct route to an Internet Gateway). Lambda and RDS both reside in these subnets. Lambda requires outbound internet access (via NAT Gateway or VPC Endpoints) to reach Secrets Manager and CloudWatch.

### Route Tables

| Destination | Target       | Purpose                         |
|-------------|--------------|---------------------------------|
| VPC CIDR    | local        | Intra-VPC traffic (Lambda→RDS)  |
| `0.0.0.0/0` | NAT Gateway  | Lambda → Secrets Manager, CW   |

### Traffic Flow

```
  Internet
      │
      ▼
  ┌──────────────────────────┐
  │  API Gateway (public)    │  ← HTTPS only; no VPC attachment needed
  └──────────────┬───────────┘
                 │ VPC Lambda invocation
                 ▼
  ┌─────────────────────────────────────────────────┐
  │                  VPC (private)                  │
  │                                                 │
  │   ┌──────────────────┐    :5432   ┌──────────┐  │
  │   │  Lambda ENI      │ ──────────▶│  RDS     │  │
  │   │  saas-lambda-sg  │            │  saas-   │  │
  │   └──────────────────┘            │  rds-sg  │  │
  │          │                        └──────────┘  │
  │          │ outbound                             │
  │          ▼                                      │
  │   ┌──────────────┐                              │
  │   │  NAT Gateway │ ──▶  Secrets Manager (HTTPS) │
  │   └──────────────┘ ──▶  CloudWatch Logs         │
  └─────────────────────────────────────────────────┘
```

---

## 3. Component Details

### 3.1 Cognito User Pool

| Attribute                   | Value                                      |
|-----------------------------|--------------------------------------------|
| Pool name                   | `saas-user-pool`                           |
| Username attribute          | `email`                                    |
| Auto-verified attribute     | `email`                                    |
| Custom attribute            | `custom:tenant_id` (String, mutable)       |
| Password minimum length     | 8                                          |
| Password requirements       | uppercase, lowercase, numbers, symbols     |
| Hosted UI domain prefix     | `saas-app-prod`                            |
| App client name             | `saas-app-client`                          |
| App client secret           | none (SPA / mobile use)                    |
| Allowed auth flows          | `USER_PASSWORD_AUTH`, `USER_SRP_AUTH`, `REFRESH_TOKEN_AUTH` |

> The `custom:tenant_id` attribute is set once during onboarding (typically by an admin) and is signed into every JWT. Lambda reads it from `requestContext.authorizer.claims["custom:tenant_id"]` — it is never accepted from the request body.

### 3.2 API Gateway REST API

| Attribute          | Value                                         |
|--------------------|-----------------------------------------------|
| API name           | `saas-api`                                    |
| Type               | REST (regional)                               |
| Authorizer         | `saas-cognito-authorizer` (COGNITO_USER_POOLS)|
| Authorizer source  | `method.request.header.Authorization`         |
| Resources          | `/users`, `/orders`                           |
| Methods            | GET, POST on each resource                    |
| Integration type   | `AWS_PROXY` (Lambda proxy)                    |
| Stage              | `prod`                                        |

> All four method + resource combinations require a valid Cognito Bearer token. Requests without a token or with an expired/invalid token receive a `401 Unauthorized` response from API Gateway before Lambda is ever invoked.

### 3.3 Lambda Functions

| Function name          | Handler                    | Memory | Timeout | Trigger             |
|------------------------|----------------------------|--------|---------|---------------------|
| `saas-users-handler`   | `handler.lambda_handler`   | 256 MB | 30 s    | API Gateway `/users`|
| `saas-orders-handler`  | `handler.lambda_handler`   | 256 MB | 30 s    | API Gateway `/orders`|
| `saas-auth-handler`    | `handler.lambda_handler`   | 256 MB | 30 s    | API Gateway (utility)|

All three functions share the same:
- Runtime: Python 3.12
- IAM role: `saas-lambda-role`
- VPC: same private subnets as RDS
- Security group: `saas-lambda-sg`
- Environment variables: `DB_HOST`, `DB_NAME`, `DB_USER`, `SECRET_ARN`, `REGION`

> Connection objects and the resolved database password are cached in the Lambda execution context (module-level globals). Subsequent invocations on a warm container reuse the existing `psycopg2` connection, avoiding cold-start reconnect overhead on every request.

### 3.4 IAM Role — `saas-lambda-role`

| Policy                                  | Type     | Purpose                           |
|-----------------------------------------|----------|-----------------------------------|
| `AWSLambdaVPCAccessExecutionRole`       | Managed  | Create/delete ENIs for VPC access |
| `AWSLambdaBasicExecutionRole`           | Managed  | Write logs to CloudWatch          |
| `saas-lambda-secrets-access`            | Inline   | `secretsmanager:GetSecretValue` on `saas/db/password` only |

### 3.5 Security Groups

**`saas-lambda-sg`**

| Direction | Protocol | Port | Source / Destination | Purpose              |
|-----------|----------|------|----------------------|----------------------|
| Egress    | All      | All  | `0.0.0.0/0`          | RDS, Secrets Manager, CloudWatch |

**`saas-rds-sg`**

| Direction | Protocol | Port | Source               | Purpose                      |
|-----------|----------|------|----------------------|------------------------------|
| Ingress   | TCP      | 5432 | `saas-lambda-sg` ID  | PostgreSQL from Lambda only  |

### 3.6 RDS PostgreSQL Instance

| Attribute               | Value                        |
|-------------------------|------------------------------|
| Identifier              | `saas-postgres`              |
| Engine                  | PostgreSQL 15                |
| Instance class          | `db.t3.medium`               |
| Storage                 | 20 GB gp3                    |
| Database name           | `saasdb`                     |
| Master username         | `saasadmin`                  |
| Subnet group            | `saas-db-subnet-group`       |
| Security group          | `saas-rds-sg`                |
| Multi-AZ                | enabled                      |
| Publicly accessible     | disabled                     |
| Deletion protection     | enabled                      |
| Backup retention        | 7 days                       |
| Final snapshot          | `saas-postgres-final-snapshot`|

> Enabling Multi-AZ doubles the RDS cost but provides automatic failover to the standby replica in `us-east-1b` within 1–2 minutes if the primary becomes unavailable. Do not disable this for production workloads.

### 3.7 Secrets Manager

| Attribute      | Value                                  |
|----------------|----------------------------------------|
| Secret name    | `saas/db/password`                     |
| Secret type    | Plaintext string (the RDS password)    |
| Access control | IAM — `saas-lambda-role` only          |
| Rotation       | not configured (manual rotation recommended) |

---

## 4. Directory Structure

```
Multi-Tenant SaaS Application/
├── cli/
│   └── deploy.sh                  — end-to-end AWS CLI deployment script
├── terraform/
│   ├── main.tf                    — all AWS resource definitions
│   ├── variables.tf               — typed input variables with validation
│   ├── outputs.tf                 — post-apply output values
│   └── terraform.tfvars           — sample variable values (no secrets)
├── lambda/
│   ├── requirements.txt           — psycopg2-binary dependency
│   ├── users_handler/
│   │   └── handler.py             — GET /users, POST /users
│   ├── orders_handler/
│   │   └── handler.py             — GET /orders, POST /orders
│   └── auth_handler/
│       └── handler.py             — token inspection, tenant binding
└── scripts/
    └── build_lambdas.sh           — packages handlers + pip deps into zip files
```

---

## 5. Prerequisites

| Tool / Resource          | Minimum Version | Notes                                              |
|--------------------------|-----------------|----------------------------------------------------|
| AWS CLI                  | v2.x            | Configured with an IAM identity that has permissions to create Cognito, Lambda, RDS, API Gateway, IAM, Secrets Manager, and EC2 security group resources |
| Terraform                | 1.5             | Required only for the Terraform deployment path    |
| Python                   | 3.12            | Used by the Lambda build script (`build_lambdas.sh`) and local handler testing |
| pip                      | latest          | Used by `build_lambdas.sh` to bundle dependencies  |
| zip                      | system          | Used by `build_lambdas.sh` to create deployment packages |
| psql (PostgreSQL client) | 15.x            | Optional — useful for verifying RDS schema and row-level isolation after deployment |
| Existing VPC             | —               | Must have at least two private subnets in different AZs with outbound internet access (NAT Gateway or VPC Endpoints) |

---

## 6. Quick Start

### Option A — AWS CLI Script

Edit the four variables at the top of `cli/deploy.sh`, then run:

```bash
# 1. Set your deployment parameters
vim cli/deploy.sh          # update REGION, VPC_ID, PRIVATE_SUBNET_IDS, DB_PASSWORD

# 2. Build Lambda deployment packages (requires Python 3.12 + pip)
bash scripts/build_lambdas.sh

# 3. Deploy all resources (~20 minutes — RDS Multi-AZ provisioning dominates)
bash cli/deploy.sh
```

The script outputs the User Pool ID, App Client ID, RDS endpoint, and API invoke URL on completion.

### Option B — Terraform

```bash
# 1. Build Lambda deployment packages first — Terraform reads the zip files
bash scripts/build_lambdas.sh

# 2. Review and edit sample values
vim terraform/terraform.tfvars    # set vpc_id and private_subnet_ids

# 3. Initialise providers
cd terraform
terraform init

# 4. Preview the execution plan
terraform plan -var="db_password=YourStr0ng!P@ssword99"

# 5. Apply (~20 minutes for RDS Multi-AZ)
terraform apply -var="db_password=YourStr0ng!P@ssword99"
```

> Pass `db_password` on the command line or via `TF_VAR_db_password` — do not add it to `terraform.tfvars`, which is checked in to version control.

Allow approximately 20 minutes for RDS Multi-AZ health checks to pass before the deployment completes.

---

## 7. Input Variables

### Terraform variables (`terraform/variables.tf`)

| Variable             | Type           | Default            | Description                                             |
|----------------------|----------------|--------------------|---------------------------------------------------------|
| `region`             | `string`       | `us-east-1`   | AWS region for all resources                            |
| `vpc_id`             | `string`       | —                  | ID of the existing VPC                                  |
| `private_subnet_ids` | `list(string)` | —                  | At least two private subnet IDs in different AZs        |
| `db_password`        | `string`       | —                  | RDS master password; marked `sensitive = true`          |
| `common_tags`        | `map(string)`  | see below          | Tags merged onto every resource                         |

Default `common_tags`:

```hcl
{
  Environment = "production"
  ManagedBy   = "terraform"
}
```

**Validation rules:** `private_subnet_ids` must contain at least two entries; `db_password` must be at least 8 characters.

### CLI script variables (`cli/deploy.sh`)

| Variable              | Example value                                             |
|-----------------------|-----------------------------------------------------------|
| `REGION`              | `us-east-1`                                          |
| `VPC_ID`              | `vpc-0abc1234def56789a`                                   |
| `PRIVATE_SUBNET_IDS`  | `subnet-0aaa111122223333a,subnet-0bbb444455556666b`        |
| `DB_PASSWORD`         | `YourStr0ng!P@ssword99`                                   |

---

## 8. Outputs

| Output                  | Description                                              |
|-------------------------|----------------------------------------------------------|
| `user_pool_id`          | Cognito User Pool ID (`us-east-1_xxxxxxxxx`)        |
| `app_client_id`         | Cognito App Client ID used by frontend applications      |
| `cognito_hosted_ui_url` | Base URL for the Cognito hosted sign-in page             |
| `rds_endpoint`          | RDS writer endpoint hostname (private DNS)               |
| `api_gateway_invoke_url`| Full API invoke URL including stage, e.g. `https://{id}.execute-api.us-east-1.amazonaws.com/prod` |
| `db_secret_arn`         | ARN of the Secrets Manager secret for the database password |
| `lambda_role_arn`       | ARN of `saas-lambda-role` shared by all Lambda functions |

After a Terraform apply:

```bash
terraform output api_gateway_invoke_url
# https://abc123def4.execute-api.us-east-1.amazonaws.com/prod

# Quick smoke test (TOKEN must be a valid Cognito access token)
curl -s \
  -H "Authorization: Bearer $TOKEN" \
  "$(terraform output -raw api_gateway_invoke_url)/users"
```

---

## 9. Scaling Behaviour

Lambda scales by adding concurrent execution environments; RDS scales by handling more concurrent connections. The two limits interact — Lambda can burst faster than RDS can absorb connections.

```
  Lambda concurrency vs time (sudden traffic spike)
  ┌────────────────────────────────────────────────────────┐
  │ Concurrent                                             │
  │ executions                                             │
  │                                                        │
  │  1000 ─ ─ ─ ─ ─ ─ ─ ─  account limit ─ ─ ─ ─ ─ ─ ─  │
  │                                  ┌──────────────────── │
  │   500 ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┘                     │
  │                           ▲ burst                      │
  │   100 ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┘                            │
  │                     ▲ warm pool                        │
  │     0 ───────────────────────────────────────▶ time    │
  └────────────────────────────────────────────────────────┘

  RDS connection headroom (db.t3.medium ≈ 300 max_connections)
  ┌────────────────────────────────────────────────────────┐
  │  300 ─ ─ ─ ─ ─ ─ ─ ─  max_connections ─ ─ ─ ─ ─ ─ ─    │
  │  240 ─ ─ ─ ─ ─ ─ ─ ─  safe ceiling (80 %) ─ ─ ─ ─ ─    │
  │                                                        │
  │   50 ─ ─ ─ ─ ─ ─ ─┐ normal                             │
  │                    └──────┐ spike                      │
  │    0 ───────────────────────────────────────▶ time     │
  └────────────────────────────────────────────────────────┘
```

**Key limits and mitigations:**

| Limit                          | Default value          | Mitigation                                      |
|-------------------------------|------------------------|-------------------------------------------------|
| Lambda account concurrency     | 1 000 (soft limit)     | Request increase via Support; set reserved concurrency per function |
| Lambda burst concurrency       | 500–3 000 (region)     | Gradual ramp; use provisioned concurrency for latency-sensitive endpoints |
| RDS `max_connections`          | ~300 for db.t3.medium  | Add RDS Proxy to pool connections; Lambda reuses connections via module-level globals |
| Secrets Manager API TPS        | 10 000 / s             | Password cached in execution context; typically 1 call per cold-start |

> If concurrent Lambda executions approach the RDS connection limit, enable **RDS Proxy** (a `aws_db_proxy` resource). RDS Proxy multiplexes hundreds of Lambda connections into a smaller pool of persistent RDS connections and adds automatic failover during Multi-AZ switchover.

---

## 10. Tagging Strategy

All resources are tagged with the following keys:

| Tag Key       | Value          | Applied to                               |
|---------------|----------------|------------------------------------------|
| `Name`        | resource name  | every resource (unique per resource)     |
| `Environment` | `production`   | every resource                           |
| `ManagedBy`   | `terraform`    | every Terraform-managed resource         |

> Cognito User Pool tags use a flat `key=value` map format (`--user-pool-tags`), not the `Key`/`Value` JSON list that RDS and IAM use. The CLI script handles both formats. Terraform abstracts the difference with the `tags` attribute uniformly across providers.

Lambda function tags propagate to CloudWatch Log Groups only when the Log Group is created by Lambda on first invocation. If you create the Log Group in Terraform, tag it explicitly with `aws_cloudwatch_log_group`.

---

## 11. Security Considerations

| Topic                        | Current posture                                               | Recommended hardening                                                  |
|------------------------------|---------------------------------------------------------------|------------------------------------------------------------------------|
| API authentication           | All routes require a valid Cognito JWT Bearer token           | Enforce short token expiry (15–60 min); use refresh tokens              |
| Tenant isolation             | `tenant_id` read only from verified JWT claims; never from request body | Add integration tests that assert cross-tenant queries return 0 rows   |
| RDS network access           | No public accessibility; inbound 5432 from `saas-lambda-sg` only | Enable RDS encryption at rest; enforce SSL (`sslmode=require`)         |
| Database credentials         | Stored in Secrets Manager; fetched by Lambda at cold-start    | Enable automatic secret rotation with a Lambda rotation function       |
| Lambda environment variables | No secrets in env vars; only non-sensitive config (host, db name) | Review with `aws lambda get-function-configuration` in CI to assert no plaintext passwords |
| IAM least-privilege          | Lambda role scoped to one secret ARN for GetSecretValue       | Periodically run IAM Access Analyzer to surface over-permissioned policies |
| VPC egress                   | Lambda uses NAT Gateway for outbound (Secrets Manager, CloudWatch) | Replace NAT Gateway with VPC Endpoints for `secretsmanager` and `logs` to remove public egress entirely |
| HTTPS                        | API Gateway enforces TLS 1.2+ on all endpoints               | Add a custom domain with ACM certificate for a stable invoke URL        |
| Input validation             | Lambda validates required fields before issuing SQL           | Add JSON Schema validation at the API Gateway request model layer       |

---

## 12. Cost Estimate

Approximate monthly cost at **low volume** (< 100 000 API calls/month) in `us-east-1`:

| Resource                          | Quantity / Unit                     | Monthly cost (USD) |
|-----------------------------------|-------------------------------------|--------------------|
| RDS db.t3.medium Multi-AZ         | 730 hrs × $0.136/hr                 | $99.28             |
| RDS storage — 20 GB gp3           | 20 GB × $0.138/GB                   | $2.76              |
| RDS automated backups             | ≤ 20 GB (free tier = allocated)     | $0.00              |
| NAT Gateway (2 AZs)               | 2 × ~$35 (730 hrs × $0.048/hr)      | $70.08             |
| Lambda invocations (100 K)        | 100 K × $0.0000002 + 256 MB compute | $0.52              |
| API Gateway (100 K calls)         | 100 K × $3.50/million               | $0.35              |
| Secrets Manager (1 secret)        | $0.40/secret                        | $0.40              |
| CloudWatch Logs (5 GB ingested)   | 5 GB × $0.76/GB                     | $3.80              |
| Cognito (< 50 K MAUs)             | free tier                           | $0.00              |
| **Total**                         |                                     | **~$177/month**    |

> NAT Gateway dominates the bill for low-traffic deployments. Replacing NAT Gateway with VPC Interface Endpoints for `secretsmanager`, `logs`, and `monitoring` typically reduces this by $50–60/month once traffic is low, but endpoints carry a fixed hourly charge (~$7.20/endpoint/month) that becomes cheaper only if NAT data transfer fees exceed that threshold. Use the [AWS Pricing Calculator](https://calculator.aws/pricing/2/home) to model your actual traffic profile.

---

## 13. Destroying the Stack

### Terraform

```bash
cd terraform

# Deletion protection must be disabled on RDS before destroy
aws rds modify-db-instance \
  --db-instance-identifier saas-postgres \
  --no-deletion-protection \
  --apply-immediately \
  --region us-east-1

# Disable Cognito domain before destroy (Terraform cannot delete it while attached)
POOL_ID=$(terraform output -raw user_pool_id)
aws cognito-idp delete-user-pool-domain \
  --domain saas-app-prod \
  --user-pool-id "$POOL_ID" \
  --region us-east-1

terraform destroy -var="db_password=any-value-matches-state"
```

The final snapshot `saas-postgres-final-snapshot` is **not** managed by Terraform and will survive `terraform destroy`. Delete it manually once you have confirmed you no longer need the data:

```bash
aws rds delete-db-snapshot \
  --db-snapshot-identifier saas-postgres-final-snapshot \
  --region us-east-1
```

### AWS CLI deployed resources

```bash
# No automated teardown script is provided for the CLI path.
# Delete resources in this order to avoid dependency errors:
# 1. API Gateway deployment and REST API
# 2. Lambda functions
# 3. RDS instance (disable deletion protection first — see above)
# 4. RDS subnet group
# 5. Security groups
# 6. Cognito domain, app client, user pool
# 7. IAM role (detach policies first)
# 8. Secrets Manager secret
```

---

## 14. Challenge Quests

Work through these tasks in order. Each one builds on the previous. No solutions are provided — the goal is to understand the system by deploying and debugging it yourself.

- [ ] Deploy the Cognito User Pool with the `custom:tenant_id` attribute and confirm that a test user's ID token contains the `custom:tenant_id` claim by decoding the JWT at [jwt.io](https://jwt.io)
- [ ] Provision the RDS PostgreSQL instance in a private subnet with `publicly_accessible = false` and a security group that blocks all inbound traffic by default — verify it is unreachable from your local machine using `psql`
- [ ] Create one of the Lambda functions inside the same VPC as RDS and confirm it can open a database connection; update the RDS security group to allow inbound port 5432 exclusively from the Lambda security group
- [ ] Move the RDS password out of Lambda environment variables and into Secrets Manager; update the Lambda handler to fetch the password with `boto3.client("secretsmanager").get_secret_value()` and cache the result at module scope
- [ ] Attach the Cognito Authorizer to all four API Gateway method/resource combinations and verify that a request without an `Authorization` header returns `401 Unauthorized` before Lambda is invoked
- [ ] Implement tenant isolation in all Lambda handlers so that every `SELECT`, `INSERT`, `UPDATE`, and `DELETE` statement includes `WHERE tenant_id = <value from JWT claims>` — sign in as two different users belonging to different tenants and assert that User A cannot read, modify, or enumerate User B's records

---

## 15. Frequently Asked Questions

**Why does my Lambda function return a 502 Bad Gateway?**

A 502 from API Gateway with a Lambda proxy integration means Lambda returned a response that does not match the proxy contract. The response body must be a JSON string, and the object must include `statusCode` (integer), `headers` (object), and `body` (string). Verify that every code path in your handler returns this structure, including exception handlers. Check CloudWatch Logs at `/aws/lambda/<function-name>` for the Python traceback.

**All Lambda invocations land in one Availability Zone — why?**

Lambda places new execution environments in whichever AZ has available ENI capacity at the time of scaling. Under low concurrency, most invocations may land in the same AZ. This is expected behaviour. RDS Multi-AZ means the standby is always current, so an AZ failure will trigger automatic failover regardless of where Lambda was running. If you require AZ-balanced Lambda execution, you can create separate functions pinned to specific subnets, but this adds operational complexity without meaningful benefit for most workloads.

**How do I add HTTPS with a custom domain?**

1. Request a public certificate in ACM (`us-east-1`) for your domain.
2. Create a custom domain name in API Gateway and map it to the `prod` stage.
3. Add a CNAME or Alias record in Route 53 pointing to the API Gateway regional domain name.
4. Terraform resources: `aws_acm_certificate`, `aws_api_gateway_domain_name`, `aws_api_gateway_base_path_mapping`, `aws_route53_record`.

**How do I deploy updated Lambda code without re-running the full script?**

Rebuild the zip and update the function code directly:

```bash
bash scripts/build_lambdas.sh

# CLI
aws lambda update-function-code \
  --function-name saas-users-handler \
  --zip-file fileb://lambda/users_handler.zip \
  --region us-east-1

# Terraform — source_code_hash detects the changed zip automatically
terraform apply -var="db_password=$TF_VAR_db_password" -target=aws_lambda_function.users
```

**How do I store Terraform state remotely?**

Add an S3 backend block to `terraform/main.tf`:

```hcl
terraform {
  backend "s3" {
    bucket         = "your-tfstate-bucket"
    key            = "saas-app/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}
```

Create the S3 bucket and DynamoDB table before running `terraform init`. Enable versioning on the bucket so you can roll back to a previous state if a plan goes wrong.

**Why is the Cognito Authorizer used instead of a Lambda authorizer?**

A Cognito Authorizer offloads JWT signature verification and expiry checking to API Gateway itself — no Lambda cold-start penalty and no additional code to maintain. The tradeoff is that it only works with Cognito User Pool tokens. If you later need to support tokens from a third-party identity provider (e.g., Auth0, Okta), replace the Cognito Authorizer with a Lambda authorizer that calls the provider's JWKS endpoint.
