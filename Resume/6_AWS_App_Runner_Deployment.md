# AWS App Runner Deployment — Resume Summary

## Project Overview

A containerised Node.js web application deployed on **AWS App Runner** with its infrastructure in Terraform. It covers the whole container workflow without managing a VPC, EC2 instances, or a load balancer. A multi-stage `node:18-alpine` Docker image (non-root user, built for `linux/amd64`) is pushed to a private **Amazon ECR** repository with scan-on-push and a keep-last-10 lifecycle policy. App Runner pulls it through a least-privilege **service role** trusted by `build.apprunner.amazonaws.com`, runs it at 0.25 vCPU / 512 MB on port 8080, and serves it over an AWS-managed HTTPS endpoint. A dedicated **auto-scaling configuration** (min 1 / max 4 instances, 100 concurrent requests per instance) handles load, auto-deployment swaps in each new `:latest` image with zero downtime, and CloudWatch collects logs and three alarms (CPU, memory, deployment failures). The stack was deployed to account `022499047467` in `us-east-1` (`dev`) on 2026-06-21, audited live with the service `RUNNING` and returning HTTP 200, and passed a 21-test architecture script with **18 PASS / 3 WARN / 0 FAIL**.

## Architecture

```
                             Internet (HTTPS :443)
                                      │
                                      ▼
                 ┌──────────────────────────────────────────┐
                 │  App Runner managed ingress + TLS         │
                 │  kdetiinmir.us-east-1.awsapprunner.com    │
                 └────────────────────┬─────────────────────┘
                                      │ route to healthy instances
                                      ▼
 ┌──────────────────────────────────────────────────────────────────────┐
 │  App Runner service  my-web-app-service   (RUNNING)                   │
 │  auto-scaling my-web-app-auto-scaling: min 1 · max 4 · 100 req/inst   │
 │  ┌────────────────────┐  ┌────────────────────┐  ┌──────────────────┐ │
 │  │ Instance 1         │  │ Instance 2 (scale) │  │ ... up to 4      │ │
 │  │ 0.25 vCPU / 512 MB │  │ 0.25 vCPU / 512 MB │  │                  │ │
 │  │ Node.js :8080      │  │ Node.js :8080      │  │                  │ │
 │  │ TCP health check   │  │ TCP health check   │  │                  │ │
 │  └────────────────────┘  └────────────────────┘  └──────────────────┘ │
 │  instance role (tasks.apprunner) ──► CloudWatch Logs write             │
 └───────────────▲──────────────────────────────────────────┬───────────┘
                 │ pull image on deploy                      │ logs + metrics
                 │ (service role, build.apprunner)           ▼
 ┌───────────────┴──────────────────┐      ┌────────────────────────────────┐
 │  Amazon ECR  my-web-app:latest    │      │ CloudWatch                      │
 │  linux/amd64 · ~43 MB             │      │ /aws/apprunner/my-web-app (7 d) │
 │  scan-on-push · keep last 10      │      │ alarms: cpu-high · memory-high  │
 └───────────────▲──────────────────┘      │         deployment-failed       │
                 │ docker buildx --platform └────────────────────────────────┘
                 │ linux/amd64 · push :latest → auto-deploy
        ┌────────┴─────────┐
        │ Developer (Mac)  │
        └──────────────────┘
```

## Technology Stack

| Layer | Technology | Purpose |
|---|---|---|
| **Container runtime** | AWS App Runner | Fully managed container hosting with managed ingress, TLS, health checks, and auto-deploy |
| **Registry** | Amazon ECR (private) | `my-web-app` repository, scan-on-push, AES256 encryption, keep-last-10 lifecycle policy |
| **Image build** | Docker buildx (`--platform linux/amd64`), multi-stage `node:18-alpine` | Small non-root image (UID/GID 1001) built for App Runner's x86_64 hosts from Apple Silicon |
| **Application** | Node.js 18 (`server.js`, `dotenv`) | Minimal HTTP server on `PORT` or 8080 returning "Hello from AWS App Runner!" |
| **Scaling** | `aws_apprunner_auto_scaling_configuration_version` | Concurrency-based scaling: min 1, max 4, max concurrency 100 |
| **Identity** | IAM service role + instance role | `AWSAppRunnerServicePolicyForECRAccess` for pulls; inline CloudWatch Logs policy for the runtime |
| **Observability** | Amazon CloudWatch Logs + 3 metric alarms | 7-day log retention; CPU > 80%, memory > 80%, deployment failures ≥ 1 |
| **IaC** | Terraform `>= 1.0`, AWS provider `~> 5.0` | 12 resource blocks in `main.tf`; cross-variable validation on CPU/memory, VPC egress, min/max |
| **Verification** | Bash (`Script/test_architecture.sh`) | 21 automated checks across 6 component groups |

## Key Achievements

- **Serverless container delivery end to end**: Dockerfile → ECR → App Runner → public HTTPS URL, with no VPC, subnets, load balancer, or EC2 to manage. The service reached `RUNNING` and returned HTTP 200.
- **Least-privilege IAM with the correct trust principals**: separate service and instance roles. The ECR-pull role trusts `build.apprunner.amazonaws.com` and uses the AWS-managed `AWSAppRunnerServicePolicyForECRAccess`; the runtime role trusts `tasks.apprunner.amazonaws.com` and can only write logs.
- **Root-caused a misleading health-check failure**: App Runner reported "check your configured port number", but the real cause was an arm64 image built on Apple Silicon that died with an exec-format error before binding port 8080. Fixed with `docker buildx --platform linux/amd64` and an architecture check before every push.
- **Hardened, lean container image**: multi-stage build with production-only dependencies, a non-root `appuser` (UID/GID 1001), and a `.dockerignore` that keeps `terraform.tfstate`, `.terraform/`, `*.tfvars`, and `*.tf` out of the image. The original image had ballooned to 328 MB with state baked in; the fixed push is ~43 MB compressed.
- **Zero-downtime auto-deployment**: pushing a new `:latest` to ECR triggers App Runner to pull, health-check, and swap traffic automatically.
- **Guard-railed configuration**: Terraform validation enforces valid CPU/memory pairings (e.g. 0.25 vCPU → 512 MB only), requires `vpc_connector_arn` when `egress_type = "VPC"`, and checks `min_instances ≤ max_instances`.
- **Nine deployment issues root-caused and documented**, from a non-deterministic `timestamp()` tag to a bash arithmetic bug in the test script.
- **Automated verification**: a 21-test architecture script covering App Runner, ECR, IAM, auto scaling, and CloudWatch returned **18 PASS / 3 WARN / 0 FAIL**. The three WARNs were alarms still in `INSUFFICIENT_DATA` immediately after first deploy.

## Infrastructure Components

The audit (`Result.md`) confirmed the following live objects; its header records 9 Terraform-managed resources, and `main.tf` contains 12 resource blocks.

| Component | Count | Details |
|---|---|---|
| **App Runner service** | 1 | `my-web-app-service` (ID `1c28aa51172e4f54b10d98fa0eb2c203`), 0.25 vCPU / 512 MB, port 8080, public, egress `DEFAULT`, auto-deploy on |
| **Auto-scaling configuration** | 1 | `my-web-app-auto-scaling` rev 1: min 1, max 4, max concurrency 100 |
| **ECR repository** | 1 | `my-web-app`, scan-on-push, AES256, tag mutability `MUTABLE` |
| **ECR lifecycle policy** | 1 | Keep last 10 images, expire older |
| **IAM service role** | 1 | `my-web-app-app-runner-service-role`, trusts `build.apprunner.amazonaws.com` |
| **IAM managed policy attachment** | 1 | `AWSAppRunnerServicePolicyForECRAccess` |
| **IAM instance role** | 1 | `my-web-app-app-runner-instance-role`, trusts `tasks.apprunner.amazonaws.com` |
| **IAM inline policy** | 1 | `my-web-app-app-runner-instance-logs-policy` (CloudWatch Logs write) |
| **CloudWatch log group** | 1 | `/aws/apprunner/my-web-app`, 7-day retention (plus App Runner's own `application` and `service` groups) |
| **CloudWatch alarms** | 3 | `my-web-app-cpu-high` (> 80%, 2 × 5 min), `my-web-app-memory-high` (> 80%, 2 × 5 min), `my-web-app-deployment-failed` (≥ 1, 1 × 5 min) |
| **Health check** | — | TCP on 8080, 5 s interval, 2 s timeout, healthy 1 / unhealthy 5 |

## Deployment Issues Diagnosed & Resolved

| Issue | Root cause | Fix |
|---|---|---|
| `Provider produced inconsistent final plan` (new `CreatedDate` in `tags_all`) | `formatdate(timestamp())` in `common_tags` returns a different value at plan and at apply | Removed `CreatedDate`; tags are now `Environment`, `Project`, `ManagedBy` only |
| `Failed to pull your application image ... Invalid Access Role` | Service role trusted `apprunner.amazonaws.com`, but ECR pulls are done by `build.apprunner.amazonaws.com` | Changed the trust principal to `build.apprunner.amazonaws.com` |
| ECR pull still failed with `Invalid Access Role` | Inline policy scoped the global action `ecr:GetAuthorizationToken` to a repo ARN and omitted `ecr:BatchCheckLayerAvailability` | Replaced the inline policy with the managed `AWSAppRunnerServicePolicyForECRAccess` |
| Service `CREATE_FAILED` immediately after creation | App Runner pulls the image at creation time and the ECR repository was empty | Two-phase apply: `-target` the ECR repo and lifecycle policy, build and push, then run the full `apply` |
| `addgroup: gid '1000' in use` | `node:18-alpine` already reserves GID 1000 for its `node` group | Created `appuser` with UID/GID 1001 |
| `COPY --from=builder /app/node_modules ... not found` | `npm ci --only=production` with zero production dependencies creates no `node_modules/` | Added `dotenv` as a production dependency so the directory exists |
| Image 328 MB and containing `terraform.tfstate` / `.terraform/` | `COPY . .` with no `.dockerignore` copied the whole project, including state | Added `.dockerignore` excluding Terraform state, providers, `*.tfvars`, `*.tf`, `Script/`, `node_modules/`, `.git/` |
| `CREATE_FAILED` after ~18 min, "Health check failed on protocol TCP [Port: 8080]", no application log stream | Image built for arm64 on Apple Silicon; on App Runner's amd64 hosts `node` hit an exec-format error before opening the port or writing stdout | Rebuilt with `docker buildx build --platform linux/amd64`, verified with `docker image inspect --format '{{.Architecture}}/{{.Os}}'`, deleted the failed service, pushed, re-applied |
| `test_architecture.sh` exited silently after the first warning | `((VAR++))` returns exit code 1 when the counter is 0, which aborts under `set -e` | Removed `-e` (`set -uo pipefail`) and replaced increments with `VAR=$((VAR + 1))` |

## Test Results

`Script/test_architecture.sh`, run 2026-06-21 against the live stack:

| Group | Tests | Result |
|---|---|---|
| App Runner | Service `RUNNING`; HTTP endpoint returns 200; auto-deployments enabled | 3 PASS |
| ECR | Repo exists; `latest` tag present; scan-on-push on; lifecycle policy attached | 4 PASS |
| IAM | Service role exists + trusts `build.apprunner`; ECR managed policy attached; instance role exists + trusts `tasks.apprunner` | 5 PASS |
| Auto Scaling | Config active; min 1; max 4; max concurrency 100 | 4 PASS |
| CloudWatch – logs | Log group exists; retention = 7 days | 2 PASS |
| CloudWatch – alarms | `cpu-high`, `memory-high`, `deployment-failed` exist | 3 WARN (`INSUFFICIENT_DATA`, just deployed) |
| **Total** | **21 tests** | **18 PASS / 3 WARN / 0 FAIL** |

> The WARNs are expected. Alarms start in `INSUFFICIENT_DATA` and move to `OK` once App Runner emits its first metric data points (~5–10 minutes of uptime). No alarm was in `ALARM` state at audit time.

## Quick Start

```bash
# 1. Configure variables
cd "AWS App Runner Deployment"
cp terraform.tfvars.example terraform.tfvars
terraform init

# 2. Phase 1: create only the ECR repository + lifecycle policy
terraform apply -target=aws_ecr_repository.app_runner_repo \
                -target=aws_ecr_lifecycle_policy.app_runner_lifecycle

# 3. Build for amd64 (required on Apple Silicon), verify, and push
docker buildx build --platform linux/amd64 -t my-web-app:latest --load .
docker image inspect my-web-app:latest --format '{{.Architecture}}/{{.Os}}'   # amd64/linux
ECR_REPO=$(terraform output -raw ecr_repository_url)
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin "$ECR_REPO"
docker tag my-web-app:latest "$ECR_REPO:latest" && docker push "$ECR_REPO:latest"

# 4. Phase 2: apply the full stack, then verify
terraform apply
curl -s "https://$(terraform output -raw app_runner_service_url)"
./Script/test_architecture.sh
```

> Service creation takes 5–10 minutes. Allow a further 2–5 minutes for health checks and the initial deployment.

## Cost Estimate

The README's estimate (US East 1) assumes all 4 instances at ~50% average utilisation:

| Resource | Quantity | Monthly (USD) |
|---|---|---|
| App Runner vCPU-hours | 4 × 0.25 vCPU × 730 h × ~50% | ~$36.50 |
| App Runner memory-hours | 4 × 512 MB × 730 h × ~50% | ~$9.13 |
| ECR storage | ~100 MB | ~$0.10 |
| ECR data transfer | ~10 GB/month of pulls | ~$1.00 |
| CloudWatch Logs | ~100 MB ingested | ~$0.50 |
| CloudWatch alarms | 3 | ~$0.10 |
| ECR image scanning | 1 scan/month | $0.00 |
| **Total (4-instance scenario)** | | **~$47.33 / month** |

> At the deployed configuration (1 instance, 0.25 vCPU / 512 MB) the repository's root README estimates **~$16–26/month**. Cost scales roughly linearly with instance count and traffic. See the [AWS Pricing Calculator](https://calculator.aws/#/estimate/apprunner).

## Security Posture

| Topic | Posture |
|---|---|
| Transit encryption | HTTPS only at the edge via an AWS-managed, auto-renewed certificate; TLS terminated by App Runner |
| Network exposure | Public endpoint (`is_publicly_accessible = true`), egress `DEFAULT`; VPC Connector path supported via `egress_type = "VPC"` for private backends |
| IAM | Two scoped roles with correct trust principals; managed ECR-access policy for pulls; logs-only inline policy for the runtime |
| Container | Non-root `appuser` (UID/GID 1001); minimal Alpine base; no SSH or exec access on App Runner |
| Image supply chain | Private ECR, scan-on-push enabled, AES256 at rest; tags `MUTABLE` (README recommends `IMMUTABLE` for production) |
| Build hygiene | `.dockerignore` keeps Terraform state, provider binaries, and `*.tfvars` out of the image |
| Secrets | `environment_secrets` variable accepts Secrets Manager ARNs; `*.tfvars` gitignored |
| Logging | 7-day retention (README recommends 30–90 days for production) |

## Project Structure

```
AWS App Runner Deployment/
├── main.tf                    # ECR + lifecycle, IAM roles/policies, log group, App Runner
│                              #   service, auto-scaling config, 3 CloudWatch alarms
├── variables.tf               # Inputs with validation (CPU/memory, egress, instance bounds)
├── outputs.tf                 # Service URL/ARN/status, role ARNs, ECR URL, log group, alarms
├── terraform.tfvars.example   # Copy to terraform.tfvars and customise
├── Dockerfile                 # Multi-stage node:18-alpine, non-root appuser (1001), port 8080
├── Dockerfile.example         # Original example Dockerfile
├── .dockerignore              # Keeps Terraform state/providers/tfvars out of the image
├── .gitignore                 # Excludes state, .terraform/, *.tfvars (keeps .example)
├── server.js                  # Minimal Node.js HTTP server (PORT || 8080)
├── package.json               # Start script; dotenv production dependency
├── package-lock.json          # Locked dependency tree
├── README.md                  # Full documentation (14 sections + 9 known issues)
├── Result.md                  # Live audit results (2026-06-21)
└── Script/
    └── test_architecture.sh   # 21-test architecture verification script
```

## Key Learnings & Technical Decisions

**Image architecture is part of the deployment contract.** Nothing about the arm64 image looked wrong locally. On App Runner the `node` binary couldn't execute, so the port never opened and no log stream was ever created, and the platform's "check your configured port number" message pointed in the wrong direction. The lasting fix is procedural: always build with `--platform linux/amd64` and assert the architecture before pushing.

**App Runner has two distinct IAM identities.** The access (service) role is assumed by `build.apprunner.amazonaws.com` to pull from ECR. The instance role is assumed by `tasks.apprunner.amazonaws.com` for what the running code does. Mixing up the principals, or hand-scoping a global action like `ecr:GetAuthorizationToken` to a repository ARN, both surface as the same vague `Invalid Access Role`. The AWS-managed policy is the correct and complete choice here.

**Create-time dependencies need an explicit ordering.** App Runner pulls the image the moment the service is created, so an empty repository means `CREATE_FAILED`. A targeted first apply (ECR only), then push, then full apply makes that ordering explicit instead of relying on luck.

**Non-determinism doesn't belong in Terraform tags.** `timestamp()` inside `default_tags` changes between plan and apply and trips the provider's consistency check. Tags should be pure functions of variables.

**Managed platforms trade control for speed.** App Runner removes VPC, load balancer, and instance management and adds concurrency-based scaling and zero-downtime deploys. In exchange there's no shell access, only coarse CPU/memory tiers, and network isolation that needs a VPC Connector.

## What I'd Do Differently

- **Automate the build-and-push in CI** (e.g. GitHub Actions with `buildx --platform linux/amd64` and an architecture assertion) so the arm64 trap and the empty-repo ordering can't recur.
- **Deploy immutable, versioned tags** (`image_tag_mutability = "IMMUTABLE"`, git-SHA tags) instead of `:latest` for traceable rollbacks.
- **Use an HTTP health check on a dedicated path** rather than TCP, so a process that opens the port but can't serve is detected.
- **Wire the three alarms to SNS** so CPU, memory, and deployment-failure alarms actually notify someone.
- **Enable a remote S3 backend** and extend log retention for anything beyond `dev`.
- **Set `min_instances = 2` for production** for redundancy, per the README's scaling guidance.

## Summary

This project delivers a working serverless container pipeline on AWS: a hardened, multi-stage, non-root Node.js image built for `linux/amd64`, stored in a scanned private ECR repository, and run by App Runner behind a managed HTTPS endpoint, with concurrency-based auto scaling (1–4 instances), zero-downtime auto-deploy, correctly scoped service and instance IAM roles, and CloudWatch logs and alarms, all in Terraform. It was deployed to `us-east-1` on 2026-06-21, where the audit confirmed the service `RUNNING` and serving HTTP 200. The 21-test architecture script returned **18 PASS / 3 WARN / 0 FAIL**. Nine real deployment issues were root-caused and fixed, most notably an Apple Silicon arm64 image that failed App Runner's TCP health check with a misleading error.
