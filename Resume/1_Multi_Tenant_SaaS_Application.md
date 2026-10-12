# Multi-Tenant SaaS Application — Resume Summary

## Project Overview

A multi-tenant Software-as-a-Service backend on AWS, provisioned with Terraform, that isolates tenants at the data layer rather than by separate stacks or databases. Users authenticate against an Amazon Cognito user pool (`saas-user-pool`) whose custom attribute `custom:tenant_id` is carried as a claim in the issued JWT. A regional API Gateway REST API (`saas-api`, stage `prod`) protects `GET`/`POST` on `/users` and `/orders` with a `COGNITO_USER_POOLS` authorizer and proxies requests (`AWS_PROXY`) to three Python 3.12 Lambda functions (`saas-users-handler`, `saas-orders-handler`, `saas-auth-handler`) running inside private VPC subnets. The functions read the database password from Secrets Manager (`saas/db/password`) and query an encrypted, Multi-AZ RDS PostgreSQL 15 instance (`saas-postgres`), scoping every statement with `WHERE tenant_id = <from_jwt>`. The stack targets `us-east-1`, reuses a pre-existing VPC and two private subnets, and keeps remote state in S3 with DynamoDB locking. The Terraform declares **37 resources**; the testing guide records an apply in progress at 29/37, and the commit that added the test suite records the 4-test quick suite passing against the live stack. Per the earlier resume summary (commit `bfabaf8`), the stack was destroyed after testing.

## Architecture

```
                        Client (SPA / mobile / test scripts)
                                      │ 1. InitiateAuth (email + password)
                                      ▼
              ┌───────────────────────────────────────────────┐
              │  Cognito user pool  saas-user-pool            │
              │  custom:tenant_id  ·  app client saas-app-client│
              │  hosted UI domain  saas-app-prod               │
              └───────────────────────┬───────────────────────┘
                                      │ 2. JWT (ID token carries custom:tenant_id)
                                      ▼  HTTPS  Authorization: <JWT>
              ┌───────────────────────────────────────────────┐
              │  API Gateway REST API  saas-api  (stage: prod) │
              │  saas-cognito-authorizer (COGNITO_USER_POOLS)  │
              │  GET/POST /users     GET/POST /orders          │
              │  missing / invalid token  ──►  401             │
              └───────────┬───────────────────────┬───────────┘
                          │ AWS_PROXY             │ AWS_PROXY
 ┌────────────────────────┼───────────────────────┼─────────────────────────┐
 │  Pre-existing VPC  vpc-0b8ea2c5bf5093847  10.0.0.0/24   (us-east-1a / 1b) │
 │                        ▼                       ▼                          │
 │  ┌───────────────────────────────────────────────────────────────────┐   │
 │  │  Lambda (python3.12, 256 MB, 30 s)   SG saas-lambda-sg (egress)    │   │
 │  │  saas-users-handler   saas-orders-handler   saas-auth-handler      │   │
 │  │  tenant_id taken from verified JWT claims → SQL WHERE filter       │   │
 │  └──────────────┬────────────────────────────────────┬───────────────┘   │
 │                 │ GetSecretValue                     │ tcp/5432           │
 │                 ▼                                    ▼                    │
 │  ┌──────────────────────────┐   ┌─────────────────────────────────────┐  │
 │  │ Secrets Manager          │   │ RDS PostgreSQL 15  saas-postgres     │  │
 │  │ saas/db/password         │   │ db.t3.medium · Multi-AZ · 20 GB gp3  │  │
 │  └──────────────────────────┘   │ encrypted · private · SG saas-rds-sg │  │
 │                                  │ 5432 from saas-lambda-sg only        │  │
 │                                  └─────────────────────────────────────┘  │
 └───────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
              ┌───────────────────────────────────────────────┐
              │  CloudWatch Logs  /aws/lambda/saas-*  (14 d)   │
              └───────────────────────────────────────────────┘
```

## Technology Stack

| Layer | Technology | Purpose |
|---|---|---|
| **Identity** | Amazon Cognito user pool + app client + domain | Email-username sign-in, strong password policy, `custom:tenant_id` attribute surfaced as a JWT claim |
| **API** | Amazon API Gateway (REST, regional) + Cognito authorizer | `GET`/`POST` on `/users` and `/orders`; `Authorization` header validated before any Lambda runs |
| **Compute** | AWS Lambda (`python3.12`, 256 MB, 30 s timeout, VPC-attached) | Three handlers packaged by Terraform `archive_file`; `psycopg2-binary==2.9.12` vendored per function |
| **Database** | Amazon RDS PostgreSQL 15 (`db.t3.medium`, Multi-AZ, 20 GB gp3) | Shared-schema tenant store; `tenant_id` column filters every query |
| **Secrets** | AWS Secrets Manager (`saas/db/password`) | RDS master password read by Lambda at runtime via `SECRET_ARN` env var |
| **Networking** | Pre-existing VPC + 2 private subnets; 2 security groups | Lambda SG egress-only; RDS SG accepts `5432` only from the Lambda SG |
| **Observability** | CloudWatch Logs (3 explicit log groups, 14-day retention) | Lambda execution logs with bounded retention |
| **IaC** | Terraform `>= 1.9` (aws `~> 5.0`, archive `~> 2.0`) | 37 resources; S3 backend with `encrypt = true` and DynamoDB locking |
| **Testing** | Bash + AWS CLI + `jq` + `psql` | Five scripts (quick, comprehensive, critical, database-isolation, runner) against live services |

## Key Achievements

- **Tenant isolation expressed through identity, not infrastructure** — one shared schema serves every tenant; the tenant boundary is the `custom:tenant_id` claim in a Cognito-signed JWT, and each handler filters `users`/`orders` by that value.
- **Authorization enforced at the edge** — all four API methods use `authorization = "COGNITO_USER_POOLS"`, so requests without a valid token are rejected with `401` by API Gateway before any Lambda is invoked.
- **Database never exposed** — `publicly_accessible = false`, `storage_encrypted = true`, and `saas-rds-sg` admits `tcp/5432` only from `saas-lambda-sg` by security-group reference.
- **Least-privilege Lambda role** — AWS-managed `AWSLambdaBasicExecutionRole` + `AWSLambdaVPCAccessExecutionRole`, plus one inline policy granting `secretsmanager:GetSecretValue` on the single secret ARN.
- **Deterministic Lambda packaging** — moved from shell-built zips to Terraform `archive_file` with `output_file_mode = "0666"`, eliminating the "Provider produced inconsistent final plan" hash drift between plan and apply.
- **Production-leaning database defaults** — Multi-AZ (`var.multi_az = true`), 7-day backups, `deletion_protection = true`, and a named final snapshot (`saas-postgres-final-snapshot`).
- **Five-script live test harness** — 4 quick, 19 comprehensive, 14 critical, and 6 database-isolation checks, all driven from `terraform output` values and real AWS API calls.
- **Cost-governed logging** — explicit `/aws/lambda/saas-*` log groups with 14-day retention so Lambda does not auto-create never-expiring groups.

## Infrastructure Components

Counts are Terraform resource blocks in `terraform/main.tf` (37 in total, matching the "29/37" progress figure recorded in `TESTING-GUIDE.md`).

| Component | Count | Details |
|---|---|---|
| **Cognito** | 3 | `aws_cognito_user_pool` (`saas-user-pool`) + `_client` (`saas-app-client`, no secret) + `_domain` (`saas-app-prod`) |
| **Secrets Manager** | 2 | `aws_secretsmanager_secret` (`saas/db/password`) + `_version` |
| **Security groups** | 2 | `saas-lambda-sg` (egress all) · `saas-rds-sg` (`5432` from Lambda SG only) |
| **RDS** | 2 | `aws_db_subnet_group` (`saas-db-subnet-group`) + `aws_db_instance` (`saas-postgres`, PostgreSQL 15, db `saasdb`, user `saasadmin`) |
| **IAM** | 4 | `saas-lambda-role` + 2 managed-policy attachments + inline `saas-lambda-secrets-access` |
| **CloudWatch log groups** | 3 | `/aws/lambda/saas-users-handler`, `-orders-handler`, `-auth-handler` (14-day retention) |
| **Lambda functions** | 3 | `python3.12`, handler `handler.lambda_handler`, 256 MB, 30 s, VPC config on both private subnets |
| **API Gateway** | 14 | REST API, Cognito authorizer, 2 resources, 4 methods, 4 `AWS_PROXY` integrations, deployment (`create_before_destroy`, redeploy trigger), `prod` stage |
| **Lambda permissions** | 4 | `apigateway.amazonaws.com` invoke grants for each method |
| **Data sources** | 6 | 3 `archive_file` zips, `aws_region`, 2 `aws_iam_policy_document` (trust + secrets) |
| **Pre-existing (not managed)** | — | VPC `vpc-0b8ea2c5bf5093847`, private subnets `subnet-02cb41c2b5a9f7927` / `subnet-0360d6b57c9e8ec3f`, NAT route, state bucket, lock table |

## Deployment Issues Diagnosed & Resolved

Sourced from the project's git history (commits on 2026-06-18 and 2026-06-19).

| Issue | Root cause | Fix |
|---|---|---|
| `terraform apply` failed with "Provider produced inconsistent final plan" on the Lambda functions | Zips built outside Terraform by `build_lambdas.sh` produced a different `source_code_hash` between plan and apply | Made the zips deterministic (commits `075b70f`, `78735e9`), then replaced external zipping with `data "archive_file"` per handler (`d06c289`) |
| Build script produced wrong zip paths | Quoted heredoc delimiter (`'PYTHON_SCRIPT'`) stopped Bash from expanding `$SRC_DIR` / `$ZIP_OUT` inside the embedded Python | Unquoted the delimiter so variables expand before Python runs (`78735e9`) |
| Lambda package hash still drifted after moving to `archive_file` | File-permission differences changed the archive hash between runs | Set `output_file_mode = "0666"` on all three `archive_file` sources (`b2161bc`) |
| Dependency install failed | `psycopg2-binary==2.9.9` was no longer available on PyPI | Pinned `psycopg2-binary==2.9.12` in `lambda/requirements.txt` (`c5fb6d2`) |
| `tflint` warning on the provider block | `hashicorp/archive` was used without a version constraint | Added `archive = { source = "hashicorp/archive", version = "~> 2.0" }` to `required_providers` (`950bb97`) |
| `terraform validate` errors after a merge | `variables.tf` and `outputs.tf` were accidentally deleted during a merge with `main` | Restored both files from earlier commits (`c8bb526`) |
| Test automation could not obtain tokens | App client lacked an admin password auth flow for scripted `admin-initiate-auth` | Added `ALLOW_ADMIN_USER_PASSWORD_AUTH`; test scripts also handle the Cognito `NEW_PASSWORD_REQUIRED` challenge (`d336224`) |

## Test Results

The only run outcome recorded in the project sources is the quick suite (commit `d336224`: "Quick test verified: All 4 core tests passing"). The other suites are authored and documented with expected output, but no captured run results are stored in the repo.

| Suite | Script | Checks in script | Recorded result |
|---|---|---|---|
| Quick | `test-quick.sh` | 4 — RDS available, API returns `401` without JWT, Cognito auth → Lambda → RDS insert, tenant isolation | **4/4 PASS** (recorded) |
| Comprehensive | `test-comprehensive.sh` | 19 across 6 phases (infrastructure 5, auth 3, API authz 3, database 2, tenant isolation 4, monitoring 2) | No captured run output |
| Critical | `test-critical.sh` | 14 — security (5), functionality (4), tenant isolation (3), performance (2) | No captured run output |
| Database isolation | `test-database-isolation.sh` | 6 — direct `psql` connect, schema, per-tenant inserts, `WHERE tenant_id` filter, encryption, Multi-AZ | No captured run output |
| Runner | `test-all.sh` | Interactive menu that runs the suites above in sequence | — |

## Quick Start

```bash
# 1. Enter the Terraform directory (S3 backend + DynamoDB lock table must already exist)
cd "Multi-Tenant SaaS Application/terraform"

# 2. Vendor Lambda dependencies (Terraform zips each handler via archive_file)
bash ../scripts/build_lambdas.sh

# 3. Initialise, plan, and apply (vpc_id + private_subnet_ids come from terraform.tfvars)
terraform init
terraform plan  -var="db_password=<strong-password>"
terraform apply -var="db_password=<strong-password>"

# 4. Read the endpoints
terraform output api_gateway_invoke_url
terraform output user_pool_id
terraform output app_client_id

# 5. Run the quick live test suite
cd .. && bash test-quick.sh
```

> Allow 10-15 minutes for the Multi-AZ RDS instance to reach `available`; Lambda and API Gateway are ready within 2-3 minutes.

## Cost Estimate

From the project README (`us-east-1`, 1M API requests/month, 1 s average Lambda duration, 10 GB logs, 100 GB egress).

| Resource | Quantity | Monthly (USD) |
|---|---|---|
| RDS `db.t3.medium` Multi-AZ | 1 primary + 1 standby | $127.05 |
| RDS storage (gp3) | 100 GB assumed | $12.00 |
| RDS backups (7-day) | — | $2.10 |
| Lambda requests | 1M | $0.20 |
| Lambda compute | 277 GB-s | $4.63 |
| API Gateway (REST) | 1M requests | $3.50 |
| Secrets Manager | 1 secret | $0.40 |
| CloudWatch Logs | 10 GB ingested | $5.00 |
| Data transfer out | 100 GB | $8.91 |
| **Total** | | **~$164.79 / month** |

> The README estimate assumes 100 GB of storage and 512 MB functions; the Terraform provisions 20 GB and 256 MB, so those lines are conservative. RDS Multi-AZ is the dominant cost. See the [AWS Pricing Calculator](https://calculator.aws/).

## Security Posture

| Topic | Posture |
|---|---|
| API authentication | Cognito user-pool authorizer on every method; no token or an invalid token returns `401` |
| Tenant isolation | Application-enforced: `tenant_id` read from verified JWT claims and applied in each SQL `WHERE` clause; no PostgreSQL row-level security |
| Database network | Private subnets, `publicly_accessible = false`, `5432` only from `saas-lambda-sg` |
| Encryption | RDS `storage_encrypted = true` (default AWS-managed key); API Gateway serves HTTPS only |
| Secrets | DB password in Secrets Manager, fetched at runtime; `db_password` variable marked `sensitive` and passed at apply time, not in `.tfvars`. It still lands in state, so the S3 backend is `encrypt = true` |
| IAM | Single Lambda role; `GetSecretValue` scoped to one secret ARN plus AWS-managed VPC/logging policies |
| Lambda egress | `saas-lambda-sg` allows all outbound; there are no VPC endpoints, so Secrets Manager traffic goes through the NAT route |
| Data safety | `deletion_protection = true`, 7-day backups, named final snapshot |
| Gaps | No WAF, throttling plan, secret rotation, or RDS Enhanced Monitoring; `ALLOW_USER_PASSWORD_AUTH` and admin auth flows enabled for testing |

## Project Structure

```
Multi-Tenant SaaS Application/
├── README.md                        # Full documentation (14 sections)
├── TESTING-GUIDE.md                 # Suite descriptions, timings, manual test steps
├── TESTING-UPDATES.md               # Changes to move the suites onto real AWS services
├── REAL-AWS-SERVICE-TESTING.md      # Per-test detail for live-service verification
├── terraform/
│   ├── main.tf                      # Backend, Cognito, Secrets, SGs, RDS, IAM, logs, Lambda, API GW
│   ├── variables.tf                 # region, vpc_id, private_subnet_ids (>=2), db_password, sizing
│   └── outputs.tf                   # API URL, RDS endpoint, pool/client IDs, secret + role ARNs
├── lambda/
│   ├── requirements.txt             # psycopg2-binary==2.9.12
│   ├── auth_handler/                # psycopg2/, psycopg2_binary-2.9.12.dist-info/, psycopg2_binary.libs/
│   ├── users_handler/               # same vendored psycopg2 layout
│   └── orders_handler/              # same vendored psycopg2 layout
├── scripts/
│   └── build_lambdas.sh             # pip-installs manylinux2014 wheels into each handler dir
├── test-quick.sh                    # 4 checks
├── test-comprehensive.sh            # 19 checks across 6 phases
├── test-critical.sh                 # 14 must-pass checks
├── test-database-isolation.sh       # 6 direct-psql checks
└── test-all.sh                      # Interactive runner
```

> The handler source files (`handler.py`, referenced by `handler = "handler.lambda_handler"`) are not in the current tree. They were removed in revert commit `53713c4`, so only the vendored dependencies remain under `lambda/*_handler/`.

## Key Learnings & Technical Decisions

**The JWT is the tenant boundary.** Storing `tenant_id` as a Cognito custom attribute means the tenant context arrives signed inside every request. API Gateway verifies the signature, so a client cannot change its tenant without invalidating the token. Handlers need no extra tenant lookup: they read the claim and filter by it. The trade-off is that isolation depends on every query including the filter. PostgreSQL row-level security would be the defence-in-depth layer.

**Let Terraform own the artifact it hashes.** The hardest deployment problem was build-system drift, not AWS. Zips built outside Terraform had different hashes at plan and at apply. Moving packaging into `archive_file` and fixing `output_file_mode` fixed this, because the hash Terraform plans against is now the hash it uploads.

**Reference security groups, not CIDRs.** `saas-rds-sg` trusts `saas-lambda-sg` by ID, so any function attached to that SG can reach the database and nothing else can. This holds whatever the subnet addressing inside the shared `10.0.0.0/24` VPC.

**Pay for Multi-AZ where the state lives.** Lambda and API Gateway are regional and scale without extra work, so the only single point of failure is the database. Multi-AZ RDS roughly doubles the database cost but covers the component that holds all tenant data. Instance class and Multi-AZ are variables (`db_instance_class`, `multi_az`) so dev/staging can run cheaper.

## What I'd Do Differently

- **Commit the handler source.** The Lambda `handler.py` files are missing from the current tree, so a fresh checkout cannot rebuild the functions.
- **Match the vendored wheel to the runtime.** The vendored `_psycopg.cpython-314-x86_64-linux-gnu.so` targets CPython 3.14 while the functions run `python3.12`. The build should pass `--python-version 3.12`, or use a Lambda layer.
- **Add row-level security** in PostgreSQL (`SET app.tenant_id` per connection) so a missed `WHERE` clause cannot leak data across tenants.
- **Capture test evidence.** Only the quick-suite pass is recorded. Saving the comprehensive, critical, and isolation runs (or a `Result.md` audit) would back up the full test claims.
- **Reconcile docs with code.** The README describes 100 GB storage, 512 MB functions, and database `saas_db`, but the Terraform declares 20 GB, 256 MB, and `saasdb`.
- **Harden the edge and secrets.** Add WAF and per-tenant usage-plan throttling, enable Secrets Manager rotation, and add a Secrets Manager VPC endpoint so Lambda does not need the NAT path.

## Summary

This project delivers a serverless multi-tenant SaaS backend in 37 Terraform resources: Cognito identity with a `custom:tenant_id` claim, a Cognito-authorized API Gateway REST API, three VPC-attached Python 3.12 Lambda functions, and an encrypted Multi-AZ RDS PostgreSQL store reachable only from the Lambda security group, with credentials in Secrets Manager and state in an encrypted, locked S3 backend. Tenant isolation is enforced by combining signed JWT claims with tenant-scoped SQL. The deployment surfaced a series of packaging and hash-drift problems, each traced to a root cause and fixed in version control. A five-script harness (4 + 19 + 14 + 6 checks) was written against the live services. The recorded outcome is the 4/4 quick-suite pass; the remaining suites are authored but have no captured run output in the repo.
