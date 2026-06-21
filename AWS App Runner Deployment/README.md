# AWS App Runner Deployment

Deploy a fully managed, containerized web application using AWS App Runner. This Terraform configuration automates the creation of an ECR repository, App Runner service with auto-scaling, CloudWatch monitoring, and IAM roles. App Runner handles container orchestration, scaling, and networking without requiring manual infrastructure management, making it ideal for developers who want a serverless containerized application experience.

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
│                          AWS App Runner                             │
│                         Deployment Flow                             │
└─────────────────────────────────────────────────────────────────────┘

                            Internet Users
                                   │
                                   ▼
                    ┌──────────────────────────┐
                    │   App Runner Service     │
                    │  (Public URL + TLS)      │
                    │   - Containerized App    │
                    │   - Auto-scaling         │
                    │   - Health Checks        │
                    └──────────────────────────┘
                              │
                ┌─────────────┼─────────────┐
                │             │             │
                ▼             ▼             ▼
            ┌─────────┐  ┌─────────┐  ┌─────────┐
            │Instance │  │Instance │  │Instance │
            │   1     │  │   2     │  │   N     │
            │ :8080   │  │ :8080   │  │ :8080   │
            └─────────┘  └─────────┘  └─────────┘
                │             │             │
                └─────────────┼─────────────┘
                              │
                    ┌─────────────────────┐
                    │   ECR Repository    │
                    │  (Docker Images)    │
                    └─────────────────────┘
                              │
                    ┌─────────────────────┐
                    │  CloudWatch Logs    │
                    │ (Service Metrics)   │
                    └─────────────────────┘

Traffic flow: Internet → App Runner Public URL (HTTPS/TLS termination)
→ Container instances running your application (internal port 8080)
→ Auto-scaling group adjusts instance count based on CPU/Memory → CloudWatch
metrics collected for monitoring and alarming
```

## Networking & Routing

### VPC & Network Configuration

| Component | Configuration | Details |
|-----------|---------------|---------|
| **Network Type** | AWS Managed | App Runner manages networking; public URL provided automatically |
| **Ingress** | Public HTTP/HTTPS | Accessible via public URL; TLS terminated at App Runner |
| **Egress** | DEFAULT or VPC | DEFAULT: direct internet access; VPC: optional for private database connectivity |
| **DNS** | Managed by AWS | Public URL format: `<service-name>.<region>.awsapprunner.com` |
| **TLS/SSL** | Automatic | AWS Certificate Manager certificate provisioned automatically |

### Traffic Flow

```
┌─────────────────────────────────────────────────────────────┐
│                  Internet Request (HTTPS)                   │
│  https://<service>.us-east-1.awsapprunner.com:443           │
└────────────────────────────┬────────────────────────────────┘
                             │
                    (TLS Termination)
                             │
                             ▼
            ┌───────────────────────────────┐
            │   App Runner Service          │
            │   (Internal Load Balancer)    │
            │   - Health Checks (HTTP GET)  │
            │   - Route to Healthy Instances│
            └───────────┬───────────────────┘
                        │
        ┌───────────────┼───────────────┐
        │               │               │
        ▼               ▼               ▼
    ┌────────┐     ┌────────┐     ┌────────┐
    │Container│    │Container│    │Container│
    │1:8080  │     │2:8080  │     │3:8080  │
    └────────┘     └────────┘     └────────┘
        │               │               │
        └───────────────┴───────────────┘
                        │
                        ▼
              ┌──────────────────────┐
              │ Application Response │
              │ (JSON/HTML/etc)      │
              └──────────────────────┘
```

## Component Details

### 1. ECR Repository

Stores Docker container images for deployment to App Runner.

| Attribute | Value | Notes |
|-----------|-------|-------|
| **Naming** | `${project_name}-ecr-repo` | Immutable or mutable tags based on configuration |
| **Image Scanning** | Enabled (configurable) | Scans images on push for vulnerabilities |
| **Lifecycle Policy** | Keep last 10 images | Automatic cleanup of old images to manage storage |
| **Access Control** | IAM role-based | Only App Runner service role can pull images |
| **Storage** | Unlimited | Pay per GB-month for stored images |

> **Production Note:** Set `image_tag_mutability = "IMMUTABLE"` in production to prevent accidental overwrites of tagged releases.

### 2. App Runner Service

Fully managed container runtime handling deployment, scaling, and networking.

| Attribute | Value | Notes |
|-----------|-------|-------|
| **Service Name** | Configurable | Must be unique within region |
| **Container Port** | Default: 8080 | Application should listen on this port |
| **Public URL** | `https://<service>.<region>.awsapprunner.com` | Automatically provisioned with TLS certificate |
| **Deployment Source** | ECR repository | Pulls image specified by `image_tag` |
| **Health Checks** | HTTP GET to `/` | Configurable path and timeout (default 5s, 10s timeout) |
| **Response Timeout** | 30 seconds | Time to receive first byte from container |
| **Idle Timeout** | 90 seconds | Keep-alive for persistent connections |

> **Important:** Ensure your application returns HTTP 200 on `GET /` (or configure a custom path). Failing health checks trigger instance replacement.

### 3. IAM Roles & Policies

Service Role and Instance Role with least-privilege permissions.

| Role | Permissions | Purpose |
|------|-------------|---------|
| **Service Role** | ECR GetDownloadUrlForLayer, BatchGetImage | Allows App Runner to pull images from ECR |
| **Instance Role** | CloudWatch Logs PutLogEvents | Allows containers to write application logs |

### 4. Auto Scaling Configuration

Manages horizontal scaling based on concurrency and resource utilization.

| Parameter | Default | Range | Notes |
|-----------|---------|-------|-------|
| **Min Instances** | 1 | 1–25 | Minimum running instances (always on) |
| **Max Instances** | 4 | 1–25 | Maximum instances during peak load |
| **Max Concurrency** | 100 | 1–200 | Concurrent requests per instance before scaling out |
| **Scale-out Trigger** | Concurrency exceeded | Dynamic | Adds instances when requests exceed max concurrency |
| **Scale-in Behavior** | No requests for 15+ min | Dynamic | Removes idle instances to reduce costs |

> **Scaling Logic:** App Runner monitors average concurrency across instances. When concurrency exceeds the threshold, new instances launch. Instances terminate after 15 minutes of zero traffic.

### 5. CloudWatch Monitoring

Metrics and alarms for proactive monitoring.

| Alarm | Metric | Threshold | Action | Period |
|-------|--------|-----------|--------|--------|
| **CPU High** | CPUUtilization | >80% (configurable) | Triggers alert | 5 min avg, 2 periods |
| **Memory High** | MemoryUtilization | >80% (configurable) | Triggers alert | 5 min avg, 2 periods |
| **Deployment Failed** | DeploymentFailures | ≥1 event | Triggers alert | 5 min sum |

Available metrics in CloudWatch:
- `CPUUtilization` — CPU usage percentage
- `MemoryUtilization` — Memory usage percentage
- `RequestCount` — HTTP requests per minute
- `RequestLatency` — P50, P90, P99 latency
- `DeploymentFailures` — Count of failed deployments
- `SuccessfulDeploymentCount` — Count of successful deployments

### 6. Instance Configuration

CPU and memory allocation per container instance.

| CPU (vCPU) | Memory (MB) | Typical Use Case | Est. Throughput |
|------------|-------------|------------------|-----------------|
| 0.25 | 512 | Minimal apps, dev/test | 10–50 req/s |
| 0.5 | 512–1024 | Small services, APIs | 50–200 req/s |
| 1.0 | 1024–2048 | Standard applications | 200–500 req/s |
| 2.0 | 2048–4096 | High-traffic apps | 500–2000 req/s |
| 4.0 | 4096 | Very high traffic | 2000+ req/s |

> **Memory Validation Rule:** Memory must match or exceed CPU tier minimums (e.g., 1 vCPU requires ≥1 GB RAM).

## Directory Structure

```
AWS App Runner Deployment/
├── README.md                      # This file with full deployment documentation
├── main.tf                        # Primary Terraform configuration (App Runner, ECR, IAM, monitoring)
├── variables.tf                   # Variable definitions with validation and constraints
├── outputs.tf                     # Output definitions (service URL, ARNs, log group)
├── terraform.tfvars               # Active variable values (gitignored — do not commit secrets)
├── terraform.tfvars.example       # Example values for terraform.tfvars (copy and customize)
├── .gitignore                     # Git ignore rules (terraform state, sensitive files)
├── .dockerignore                  # Docker build exclusions (.terraform/, *.tfstate, *.tfvars)
├── Dockerfile                     # Node.js multi-stage Dockerfile (build locally, push to ECR)
├── Dockerfile.example             # Original example Dockerfile for reference
├── server.js                      # Minimal Node.js HTTP server (listens on PORT || 8080)
├── package.json                   # Node.js package manifest with start script
├── package-lock.json              # Locked dependency tree for reproducible installs
└── Script/
    └── test_architecture.sh       # Architecture health-check script (tests all AWS resources)
```

## Prerequisites

| Tool | Minimum Version | Install Link |
|------|-----------------|--------------|
| **Terraform** | 1.0+ | [terraform.io/downloads](https://www.terraform.io/downloads) |
| **AWS CLI** | 2.0+ | [aws.amazon.com/cli](https://aws.amazon.com/cli/) |
| **Docker** | 20.10+ | [docker.com/products](https://www.docker.com/products) |
| **Git** | 2.0+ | [git-scm.com](https://git-scm.com/) |
| **jq** | 1.6+ (optional) | [stedolan.github.io/jq](https://stedolan.github.io/jq/) |

### AWS Account Requirements

- **IAM Permissions:** `apprunner:*`, `ecr:*`, `iam:*`, `logs:*`, `cloudwatch:*`
- **Service Limits:** Verify App Runner service quotas for your account (default: 10 services per region)
- **VPC (optional):** If using VPC egress, create VPC Connector separately or specify existing ARN

### Account-Level Setup

```bash
# Verify AWS credentials are configured
aws sts get-caller-identity

# Check App Runner service quota
aws service-quotas list-service-quotas --service-code apprunner --region us-east-1
```

## Quick Start

### 1. Prerequisites Check

Ensure all tools and AWS credentials are in place:

```bash
terraform --version
aws --version
docker --version
aws sts get-caller-identity
```

### 2. Clone/Copy the Project

```bash
cd /Users/brendonang/Code/AWS\ Project/AWS\ App\ Runner\ Deployment
```

### 3. Prepare Your Docker Image

Create a simple containerized application (or use existing Dockerfile):

```dockerfile
# Dockerfile
FROM node:18-alpine
WORKDIR /app
COPY . .
RUN npm install
EXPOSE 8080
CMD ["npm", "start"]
```

Build and test locally:

```bash
docker build -t my-app-runner-app:latest .
docker run -p 8080:8080 my-app-runner-app:latest
```

### 4. Create Terraform Variables File

```bash
# Copy example and customize
cp terraform.tfvars.example terraform.tfvars

# Edit terraform.tfvars with your values
# Replace placeholders: project_name, ecr_repository_name, service_name, etc.
```

### 5. Initialize Terraform

```bash
terraform init
```

### 6. Plan and Review Changes

```bash
terraform plan -out=tfplan
# Review the plan output to verify ECR, App Runner, roles, and alarms
```

### 7. Push Docker Image to ECR First

> **Critical:** App Runner pulls the image immediately on service creation. Push the image to ECR **before** running `terraform apply`, or the App Runner service will fail with `CREATE_FAILED`.

```bash
# Temporarily apply only ECR resources, skip App Runner
terraform apply -target=aws_ecr_repository.app_runner_repo \
                -target=aws_ecr_lifecycle_policy.app_runner_lifecycle
```

Then authenticate, build, and push:

```bash

```bash
# Get repository URL from Terraform output
ECR_REPO=$(terraform output -raw ecr_repository_url)

# Authenticate Docker with ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin $ECR_REPO

# Tag and push image
docker tag my-app-runner-app:latest $ECR_REPO:latest
docker push $ECR_REPO:latest
```

### 8. Apply Full Configuration

Now that the image exists in ECR, apply the remaining resources:

```bash
terraform apply tfplan
# App Runner service creation takes 5–10 minutes
```

### 9. Verify Deployment

```bash
# Get the public service URL
SERVICE_URL=$(terraform output -raw app_runner_service_url)
echo "Visit: https://$SERVICE_URL"

# Check service status
aws apprunner describe-service \
  --service-arn $(terraform output -raw app_runner_service_arn) \
  --region us-east-1

# View logs
aws logs tail "/aws/apprunner/$(terraform output -raw project_name | jq -r)" --follow
```

### 10. Access Your Application

Open the service URL in a browser:

```
https://<service-name>.<region>.awsapprunner.com
```

**Allow 2–5 minutes for health checks and initial deployment.** If the service is not responding, check logs for container startup errors.

## Input Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `aws_region` | string | `us-east-1` | AWS region for deployment |
| `project_name` | string | — | Project name for resource naming (lowercase, hyphens only; required) |
| `environment` | string | — | Environment: `dev`, `staging`, or `prod` (required) |
| `service_name` | string | — | App Runner service name (unique within region; required) |
| `ecr_repository_name` | string | — | ECR repository name (required) |
| `image_tag` | string | `latest` | Docker image tag to deploy |
| `image_tag_mutability` | string | `MUTABLE` | ECR image tag mutability: `MUTABLE` or `IMMUTABLE` |
| `enable_image_scanning` | bool | `true` | Enable ECR image vulnerability scanning on push |
| `container_port` | number | `8080` | Port exposed by the container (1–65535) |
| `cpu` | string | `256` | CPU allocation: `256`, `512`, `1024`, `2048`, or `4096` |
| `memory` | string | `512` | Memory allocation: `512`, `1024`, `2048`, `3072`, or `4096` MB |
| `min_instances` | number | `1` | Minimum auto-scaling instances (1–25) |
| `max_instances` | number | `4` | Maximum auto-scaling instances (1–25) |
| `max_concurrency` | number | `100` | Max concurrent requests per instance (1–200) |
| `environment_variables` | map(string) | `{}` | Container environment variables (key-value pairs) |
| `environment_secrets` | map(string) | `{}` | Secrets Manager ARNs for secure environment values |
| `is_publicly_accessible` | bool | `true` | Whether service is publicly accessible via HTTP/HTTPS |
| `egress_type` | string | `DEFAULT` | Egress: `DEFAULT` (internet) or `VPC` (private networks) |
| `vpc_connector_arn` | string | `null` | VPC Connector ARN (required if `egress_type = "VPC"`) |
| `log_retention_days` | number | `7` | CloudWatch log retention (1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653) |
| `cpu_alarm_threshold` | number | `80` | CPU utilization alarm threshold (%) |
| `memory_alarm_threshold` | number | `80` | Memory utilization alarm threshold (%) |

### Cross-Variable Validation Rules

- **CPU vs Memory:** Memory must be compatible with chosen CPU tier
  - 0.25 vCPU → 512 MB only
  - 0.5 vCPU → 512–1024 MB
  - 1.0 vCPU → 1024–2048 MB
  - 2.0 vCPU → 2048–4096 MB
  - 4.0 vCPU → 4096 MB only
- **VPC Egress:** If `egress_type = "VPC"`, then `vpc_connector_arn` must be provided
- **Min/Max Instances:** `min_instances` ≤ `max_instances` (Terraform validates)

## Outputs

| Output | Description |
|--------|-------------|
| `app_runner_service_arn` | ARN of the App Runner service |
| `app_runner_service_url` | Public HTTPS URL to access the application |
| `app_runner_service_status` | Current service status (RUNNING, DEPLOYMENT_IN_PROGRESS, FAILED, etc.) |
| `ecr_repository_url` | ECR repository URL for pushing Docker images |
| `ecr_repository_arn` | ARN of the ECR repository |
| `ecr_registry_id` | AWS account ID hosting the ECR repository |
| `cloudwatch_log_group_name` | CloudWatch log group name for application logs |
| `cloudwatch_log_group_arn` | ARN of the CloudWatch log group |
| `app_runner_service_role_arn` | ARN of the service IAM role (ECR pull permissions) |
| `app_runner_instance_role_arn` | ARN of the instance IAM role (logs write permissions) |
| `auto_scaling_configuration_arn` | ARN of the auto-scaling configuration |
| `auto_scaling_configuration_revision` | Revision number of the auto-scaling configuration |
| `cpu_alarm_arn` | ARN of the CPU utilization alarm |
| `memory_alarm_arn` | ARN of the memory utilization alarm |
| `deployment_alarm_arn` | ARN of the deployment failure alarm |

### Usage Example

```bash
# Display all outputs
terraform output

# Get specific output (e.g., service URL)
SERVICE_URL=$(terraform output -raw app_runner_service_url)
echo "Application URL: https://$SERVICE_URL"

# Save outputs to a file
terraform output -json > outputs.json
```

## Scaling Behaviour

App Runner uses concurrency-based scaling to adjust instance count dynamically. Below is a typical scaling pattern over time:

```
Concurrency (requests/instance)
│
│     ┌─────────────────────────────────────────────────────
│     │ MAX_CONCURRENCY = 100 (scale-out threshold)
│     │
│ 100 ├─────────────────────────────────────────────────────
│     │                ▲ Scale-out event
│     │               ╱ ╲
│ 80  ├─────────────╱─────╲───────────────────────────────
│     │             │     │
│ 60  ├─────────────┼─────┼───────────────────────────────
│     │            ╱       ╲
│ 40  ├────────────────────────╲────────────────────────
│     │                         │  ▼ Scale-in event
│ 20  ├─────────────────────────────────────────────────
│     │                         │ (after 15 min idle)
│     │                         ▼
│ 0   └─────────────────────────────────────────────────
└──────────────────────────────────────────────────────────
  0    5    10   15   20   25   30   35   40   Time (minutes)

Instances
│
│
4 ├──────────┬────────────────────────────
│           │
3 ├─────────┤ (added during peak)
│         │
2 ├────────┤ (baseline instances)
│        │
1 ├───────┴─────────────────────────────
│ (always ≥ min_instances)
└──────────────────────────────────────
  0    5    10   15   20   25   30   35   40   Time (minutes)
```

### Scaling Details

**Scale-Out Mechanism:**
- Monitors average concurrency per instance
- When `concurrency > max_concurrency`, launches new instance (up to `max_instances`)
- Evaluation period: 1 minute
- New instance typically ready in 30–60 seconds

**Scale-In Mechanism:**
- Instances with zero requests for ≥15 minutes are terminated
- Scales down to `min_instances` (never below this count)
- Gradual reduction prevents unnecessary churn

**Dead-Band Rationale:**
- The 15-minute idle grace period prevents rapid scale-in/out cycles (thrashing)
- Aligns with typical transient traffic spikes
- Reduces costs by allowing instances to fully empty before termination

**Scaling Policy Configuration:**
- **max_concurrency:** Tuned to application response time and throughput
  - Low-latency apps (e.g., <100ms): Can sustain 200+ concurrent requests per instance
  - High-latency apps (e.g., >1s): Recommend 10–50 concurrent requests per instance
- **min_instances:** Always keep at least this many running (even at 0 traffic)
  - Production: `min_instances = 2` for redundancy
  - Dev/test: `min_instances = 1` to minimize costs

## Tagging Strategy

All resources are tagged with a consistent naming scheme for cost allocation, automation, and organization.

| Tag Key | Value | Scope | Purpose |
|---------|-------|-------|---------|
| `Environment` | `dev`, `staging`, `prod` | All resources | Environment segregation for billing and access control |
| `Project` | `${project_name}` | All resources | Project owner identification and cost tracking |
| `ManagedBy` | `Terraform` | All resources | Identifies infrastructure-as-code managed resources |
| ~~`CreatedDate`~~ | ~~`YYYY-MM-DD`~~ | ~~All resources~~ | Removed — `formatdate(timestamp())` in `default_tags` causes provider inconsistency errors during apply (see Known Issues) |
| `Name` | Resource-specific (e.g., `my-app-ecr-repo`) | Individual resources | Human-readable resource identification |

### Tag Propagation Notes

- **App Runner Service:** Tags applied to service resource; visible in AWS Cost Explorer
- **ECR Repository:** Tags applied; visible in ECR console and Cost Explorer
- **CloudWatch Log Group:** Tags applied (visible in CloudWatch console)
- **IAM Roles:** Tags applied; useful for cross-account audits and access policies

### Cost Allocation Example

Filter resources by tags in AWS Cost Explorer:
```
Filter: Project = "my-web-app"
Filter: Environment = "prod"
Result: All production infrastructure costs for the project
```

## Security Considerations

| Topic | Current Posture | Recommended Hardening |
|-------|-----------------|----------------------|
| **Image Vulnerability Scanning** | Enabled (configurable) | Set `enable_image_scanning = true` in production; use private ECR registry |
| **IAM Least Privilege** | Scoped roles with minimal permissions | Regularly audit role policies; remove unused permissions via `aws iam get-role-policy` |
| **TLS/HTTPS** | AWS-managed certificate (auto-renewed) | Use HTTPS-only; configure `is_publicly_accessible = false` if behind private API Gateway |
| **Secrets Management** | Environment variable injection | Use AWS Secrets Manager ARNs in `environment_secrets`; never hardcode secrets in Dockerfile |
| **Network Access** | Public endpoint by default | For private backends: set `egress_type = "VPC"` with VPC Connector to access private RDS/databases |
| **Logging** | CloudWatch Logs retention (default 7 days) | Increase `log_retention_days` for prod (30–90 days); ship logs to Splunk/DataDog for long-term retention |
| **Deployment Source** | ECR registry (pull-based) | Restrict ECR repository access via resource-based policies; sign images with Cosign (optional) |
| **Container Runtime** | App Runner managed (no SSH access) | Containers are read-only filesystems; use `docker exec` locally for debugging (not available on App Runner) |

### Security Best Practices

1. **Dockerfile:**
   - Use minimal base images (`alpine`, `distroless`)
   - Don't run containers as root; use `USER` directive
   - Remove unnecessary packages with `RUN rm -rf /var/cache/*`

2. **Secrets:**
   ```hcl
   # Use Secrets Manager for sensitive values
   environment_secrets = {
     DATABASE_PASSWORD = "arn:aws:secretsmanager:us-east-1:123456789012:secret:db-pass-XXXXX"
   }
   ```

3. **Network Isolation:**
   ```hcl
   # For private databases (RDS, ElastiCache)
   egress_type       = "VPC"
   vpc_connector_arn = "arn:aws:apprunner:us-east-1:123456789012:vpcconnector/my-connector"
   ```

4. **ECR Repository Policy:**
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Principal": { "AWS": "arn:aws:iam::ACCOUNT_ID:role/AppRunnerServiceRole" },
         "Action": "ecr:*"
       }
     ]
   }
   ```

## Cost Estimate

Monthly cost breakdown based on typical usage patterns (pricing as of 2024, US East 1).

| Resource | Quantity | Monthly Cost (USD) | Notes |
|----------|----------|-------------------|-------|
| **App Runner (vCPU-hours)** | 4 instances × 0.25 vCPU × 730 hrs × avg 50% utilization | $36.50 | Scales 1–4 instances based on load |
| **App Runner (Memory-hours)** | 4 instances × 512 MB × 730 hrs × avg 50% utilization | $9.13 | Memory cost (per GB-hour) |
| **ECR Storage** | 100 MB avg (1 image) | $0.10 | Storage per GB-month |
| **ECR Data Transfer** | 10 GB/month (pulls from App Runner) | $1.00 | Regional data transfer |
| **CloudWatch Logs** | 100 MB ingested/month | $0.50 | Log ingestion (~0.005 per GB) |
| **CloudWatch Alarms** | 3 custom metrics | $0.10 | Per alarm (~0.036 each) |
| **ECR Image Scan** | 1 scan/month | $0.00 | Free tier for first 30 scans/month |
| | | | |
| **TOTAL MONTHLY** | | **~$47.33** | Scales linearly with instance count and traffic |

> **Cost Optimization Tips:**
> - Use `min_instances = 1` for dev/staging to reduce baseline cost
> - Set `log_retention_days = 3` for non-prod environments
> - Use reserved capacity pricing if predictable workload (negotiate with AWS)
> - Monitor unused ECR images with lifecycle policies (enabled by default)

### Pricing Calculator Link

[AWS Pricing Calculator — App Runner](https://calculator.aws/#/estimate/apprunner)

## Destroying the Stack

### Pre-Destruction Manual Steps

1. **Backup Application Data** (if applicable):
   ```bash
   # Export any critical data before destroying
   aws apprunner describe-service \
     --service-arn $(terraform output -raw app_runner_service_arn) \
     > backup-service-config.json
   ```

2. **Save ECR Images** (if needed for recovery):
   ```bash
   # Tag and push images to a backup registry before ECR deletion
   docker tag $ECR_REPO:latest backup-registry/my-app:latest
   docker push backup-registry/my-app:latest
   ```

3. **Disable Deletion Protection** (if configured):
   ```bash
   # Not applicable for App Runner (no deletion protection by default)
   ```

### Destroy Terraform Stack

```bash
# Review resources to be destroyed
terraform plan -destroy

# Destroy all resources
terraform destroy

# Confirm by typing "yes" when prompted
```

### Resources Destroyed

| Resource | Status | Notes |
|----------|--------|-------|
| **App Runner Service** | Destroyed | Service stopped; public URL disabled |
| **ECR Repository** | Destroyed | All images deleted (unrecoverable if not backed up) |
| **IAM Roles & Policies** | Destroyed | Service role, instance role, and policies removed |
| **CloudWatch Log Group** | Destroyed | Application logs deleted (backup first if needed) |
| **CloudWatch Alarms** | Destroyed | CPU, memory, and deployment alarms removed |
| **Auto Scaling Configuration** | Destroyed | Scaling rules removed |

### Resources NOT Destroyed by Terraform

| Resource | Reason | Manual Action |
|----------|--------|---|
| **VPC Connector** | User-created separately | Delete manually via `aws apprunner delete-vpc-connector` if no longer needed |
| **Custom DNS Records** | Created outside Terraform | Update Route 53/DNS records to point elsewhere |
| **Secrets in Secrets Manager** | Not managed by Terraform | Delete manually if no longer needed |
| **CloudTrail Logs** (if enabled) | Not managed by this stack | Persist in S3 bucket for audit purposes |

### Recovery After Destruction

```bash
# To redeploy the same stack:
terraform apply -var="image_tag=latest"

# To redeploy with saved outputs:
terraform apply -var-file=terraform.tfvars
```

## Frequently Asked Questions

### Q1: How do I update my application after initial deployment?

**A:** Update your application code and redeploy the Docker image:

```bash
# 1. Rebuild Docker image locally
docker build -t my-app:v2 .

# 2. Push to ECR
docker tag my-app:v2 $ECR_REPO:v2
docker push $ECR_REPO:v2

# 3. Update Terraform to deploy new image version
terraform apply -var="image_tag=v2"

# OR manually update via AWS Console:
# App Runner → Service → Deployments → Deploy new image
```

App Runner will perform a rolling update (gradual instance replacement) with minimal downtime.

---

### Q2: Why is my application returning 502 errors after deployment?

**A:** Common causes:

1. **Container not listening on port 8080:**
   ```bash
   # Verify port in application code
   grep -r "8080" your-app/
   # Update if necessary and redeploy
   ```

2. **Health check failing:**
   ```bash
   # App Runner expects HTTP 200 on GET /
   # Verify with curl locally
   curl http://localhost:8080/
   
   # If custom path needed, configure in App Runner console or Terraform
   ```

3. **Application startup errors:**
   ```bash
   # Check CloudWatch logs
   aws logs tail "/aws/apprunner/my-web-app" --follow
   ```

4. **Insufficient memory/CPU:**
   ```bash
   # Monitor metrics
   aws cloudwatch get-metric-statistics \
     --namespace AWS/AppRunner \
     --metric-name CPUUtilization \
     --start-time 2024-01-01T00:00:00Z \
     --end-time 2024-01-01T01:00:00Z \
     --period 300 \
     --statistics Average
   
   # Increase if consistently >90%
   terraform apply -var="memory=1024"
   ```

---

### Q3: Can I deploy from GitHub directly instead of ECR?

**A:** Yes, App Runner supports GitHub repository deployments (source code repositories). Modify the Terraform configuration:

```hcl
# Replace image_repository block with:
github_repository {
  arn = "arn:aws:codestarconnections:us-east-1:ACCOUNT_ID:connection/github-connection"
  repository_owner = "your-username"
  repository_name  = "your-repo"
  branch           = "main"
  configuration_source = "REPOSITORY" # or "API"
}
```

Benefits: App Runner builds and deploys automatically on git push. Drawback: Build times are longer (~3–5 min).

---

### Q4: How do I add HTTPS and custom domain names?

**A:** App Runner provides automatic HTTPS with AWS Certificate Manager. For custom domains:

```bash
# 1. Create Route 53 hosted zone (if not exists)
aws route53 create-hosted-zone --name example.com

# 2. Add CNAME record pointing to App Runner service URL
aws route53 change-resource-record-sets \
  --hosted-zone-id Z1234567 \
  --change-batch '{"Changes":[{"Action":"CREATE","ResourceRecordSet":{"Name":"api.example.com","Type":"CNAME","TTL":300,"ResourceRecords":[{"Value":"<service>.awsapprunner.com"}]}}]}'

# 3. Wait ~5 min for DNS propagation
# 4. Verify: https://api.example.com
```

App Runner automatically resolves custom domain and issues wildcard certificate.

---

### Q5: How does auto-scaling work if I have single-AZ instances?

**A:** App Runner manages instances across multiple availability zones automatically:

- **Multi-AZ by Default:** App Runner distributes instances across 2–3 AZs in the region
- **No Single-AZ Concentration:** You cannot pin instances to one AZ; this is handled by AWS
- **Health Checks:** If an instance fails, the service automatically replaces it in a different AZ
- **Zero-Downtime Scaling:** Existing instances continue serving requests while new instances become ready

To verify AZ distribution:
```bash
aws apprunner describe-service \
  --service-arn $(terraform output -raw app_runner_service_arn) \
  --query 'Service.ServiceStatus' \
  | grep -i 'running\|healthy'
```

---

### Q6: How do I configure remote state for team collaboration?

**A:** Enable remote state in S3 with locking:

```hcl
# Create backend.tf
terraform {
  backend "s3" {
    bucket         = "my-terraform-state"
    key            = "apprunner/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}
```

Initialize backend:
```bash
# Create S3 bucket and DynamoDB table first
aws s3api create-bucket --bucket my-terraform-state --region us-east-1
aws dynamodb create-table \
  --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5

# Then initialize
terraform init

# Commit backend.tf to git (other developers run terraform init)
git add backend.tf
git commit -m "Enable remote state"
```

Team members now share the same state file with automatic locking.

---

### Q7: Why doesn't my scaling policy trigger even under high load?

**A:** Check the following:

1. **Concurrency threshold not exceeded:**
   ```bash
   # Monitor actual concurrency
   aws cloudwatch get-metric-statistics \
     --namespace AWS/AppRunner \
     --metric-name RequestCount \
     --start-time $(date -u -d '10 min ago' +%Y-%m-%dT%H:%M:%S)Z \
     --end-time $(date -u +%Y-%m-%dT%H:%M:%S)Z \
     --period 60 \
     --statistics Sum
   
   # If lower than max_concurrency, no scale-out yet
   ```

2. **Check max_instances limit:**
   ```bash
   # Verify auto-scaling config
   terraform output auto_scaling_configuration_arn
   aws apprunner describe-auto-scaling-configuration \
     --auto-scaling-configuration-arn <ARN>
   ```

3. **Increase max_concurrency or reduce max_instances threshold:**
   ```hcl
   # Adjust in terraform.tfvars
   max_concurrency = 50  # Triggers scale-out sooner
   max_instances   = 10  # Allow more scaling headroom
   ```

4. **Allow time for health checks:**
   - New instances take 30–60 seconds to become healthy
   - During this window, they don't receive traffic

---

### Q8: Can I use App Runner with private databases (RDS)?

**A:** Yes, use VPC Connector for private network access:

```hcl
# Create VPC Connector (one-time setup, separate Terraform)
resource "aws_apprunner_vpc_connector" "main" {
  vpc_connector_name = "app-runner-connector"
  subnets            = ["subnet-12345678"]
  security_groups    = ["sg-12345678"]
}

# Configure App Runner to use VPC Connector
egress_type       = "VPC"
vpc_connector_arn = aws_apprunner_vpc_connector.main.arn
environment_variables = {
  RDS_ENDPOINT = "my-database.123456789.us-east-1.rds.amazonaws.com"
}
```

Database is now accessible from within the VPC. Traffic routes through NAT Gateway (costs apply).

---

### Q9: How are logs retained and where should I ship them for long-term storage?

**A:** CloudWatch Logs are retained based on `log_retention_days` (default 7 days):

```bash
# View logs
aws logs tail "/aws/apprunner/my-web-app" --follow

# Export logs to S3 for archival
aws logs create-export-task \
  --log-group-name "/aws/apprunner/my-web-app" \
  --from $(date -d '30 days ago' +%s)000 \
  --to $(date +%s)000 \
  --destination "my-log-archive-bucket" \
  --destination-prefix "apprunner-logs"
```

For long-term retention (>90 days), integrate with Splunk, DataDog, or ship to S3 via CloudWatch Logs subscription filters.

---

### Q10: What happens to in-flight requests when App Runner redeploys?

**A:** App Runner performs a **graceful shutdown** with connection draining:

1. New instance launches and becomes healthy (30–60 sec)
2. Old instance receives `SIGTERM` signal; stops accepting new requests
3. Existing connections are allowed to complete (timeout: 90 sec)
4. Old instance terminates after all requests finish or timeout expires
5. Traffic is fully moved to new instance(s)

**Result:** Minimal impact; long-running requests (>90 sec) may be interrupted. Configure appropriate timeouts in your application.

---

### Q11: Why does App Runner health check always fail even though my container works locally?

**A:** If you are on Apple Silicon (M1/M2/M3 Mac), your default `docker build` produces an `arm64` image. App Runner runs on `amd64` (x86_64). The Node.js binary inside the container immediately exits with an **Exec format error** before binding to any port, so the TCP health check never sees an open port — and no application log stream is created in CloudWatch because the process exits before writing anything.

**Diagnose:**
```bash
docker image inspect my-web-app:latest --format '{{.Architecture}}/{{.Os}}'
# arm64/linux  ← wrong for App Runner
# amd64/linux  ← correct
```

**Fix — always build for `linux/amd64` before pushing to ECR:**
```bash
docker buildx build --platform linux/amd64 -t my-web-app:latest --load .
docker tag my-web-app:latest <account>.dkr.ecr.us-east-1.amazonaws.com/my-web-app:latest
docker push <account>.dkr.ecr.us-east-1.amazonaws.com/my-web-app:latest
```

> Add `--platform linux/amd64` to every `docker buildx build` command when developing on Apple Silicon. Skipping it means the container silently fails in App Runner with no actionable error message.

---

## Known Deployment Issues & Fixes

Issues encountered during real deployment of this stack, with root causes and applied fixes.

---

### Issue 1: `formatdate(timestamp())` Causes Provider Inconsistency

**Symptom:**

```
Error: Provider produced inconsistent final plan
... produced an invalid new value for .tags_all: new element "CreatedDate" has appeared.
```

**Root cause:** `timestamp()` is non-deterministic — it returns a different value during `plan` and `apply`. The AWS provider sees a changed tag value and rejects the plan as inconsistent.

**Fix applied:** Remove `CreatedDate` from `common_tags` in `main.tf`:

```hcl
# BEFORE (broken)
locals {
  common_tags = {
    CreatedDate = formatdate("YYYY-MM-DD", timestamp())  # Remove this line
  }
}

# AFTER (fixed)
locals {
  common_tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "Terraform"
  }
}
```

---

### Issue 2: Wrong IAM Trust Principal for App Runner Service Role

**Symptom:**

```
[AppRunner] Failed to pull your application image.
Reason: Invalid Access Role in AuthenticationConfiguration.
```

**Root cause:** The service role (used to pull images from ECR) must trust `build.apprunner.amazonaws.com`, not `apprunner.amazonaws.com`. The build service — not the runtime service — performs ECR pulls.

**Fix applied** in `main.tf`:

```hcl
# BEFORE (broken)
Principal = {
  Service = "apprunner.amazonaws.com"
}

# AFTER (fixed)
Principal = {
  Service = "build.apprunner.amazonaws.com"
}
```

---

### Issue 3: Inline ECR Policy Has Incorrect Resource Scoping

**Symptom:** ECR pull silently fails with `Invalid Access Role` even with correct trust principal.

**Root cause:** `ecr:GetAuthorizationToken` is a global action — it cannot be scoped to a specific repository ARN. Assigning it to a resource ARN makes the permission invalid. Additionally, the inline policy was missing `ecr:BatchCheckLayerAvailability`.

**Fix applied:** Replace the inline `aws_iam_role_policy` with the AWS-managed policy:

```hcl
# BEFORE (broken inline policy)
resource "aws_iam_role_policy" "app_runner_ecr_policy" {
  policy = jsonencode({
    Statement = [{
      Action   = ["ecr:GetAuthorizationToken", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
      Resource = aws_ecr_repository.app_runner_repo.arn  # Invalid for GetAuthorizationToken
    }]
  })
}

# AFTER (managed policy — correct and complete)
resource "aws_iam_role_policy_attachment" "app_runner_ecr_policy" {
  role       = aws_iam_role.app_runner_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess"
}
```

---

### Issue 4: Docker Image Must Exist in ECR Before `terraform apply`

**Symptom:** App Runner service `CREATE_FAILED` immediately after Terraform creates it.

**Root cause:** App Runner pulls the image at service creation time. If the ECR repository is empty, the pull fails and the service enters `CREATE_FAILED`.

**Fix:** Use a two-phase apply — create ECR first, push image, then apply the full stack:

```bash
# Phase 1 — create only the ECR repository
terraform apply \
  -target=aws_ecr_repository.app_runner_repo \
  -target=aws_ecr_lifecycle_policy.app_runner_lifecycle

# Phase 2 — build and push the image
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  <account>.dkr.ecr.us-east-1.amazonaws.com

docker build -t my-web-app:latest .
docker tag my-web-app:latest <account>.dkr.ecr.us-east-1.amazonaws.com/my-web-app:latest
docker push <account>.dkr.ecr.us-east-1.amazonaws.com/my-web-app:latest

# Phase 3 — apply everything
terraform apply
```

---

### Issue 5: GID 1000 Conflict in `node:18-alpine`

**Symptom:**

```
addgroup: gid '1000' in use
```

**Root cause:** `node:18-alpine` already reserves GID 1000 for its built-in `node` group. Attempting to create another group with the same GID fails.

**Fix applied** in `Dockerfile`:

```dockerfile
# BEFORE (broken)
RUN addgroup -g 1000 appuser && adduser -D -u 1000 -G appuser appuser

# AFTER (fixed)
RUN addgroup -g 1001 appuser && adduser -D -u 1001 -G appuser appuser
```

---

### Issue 6: Multi-Stage Build Fails With Zero Production Dependencies

**Symptom:**

```
COPY --from=builder /app/node_modules ./node_modules: not found
```

**Root cause:** `npm ci --only=production` with zero production dependencies creates no `node_modules/` directory. The subsequent `COPY --from=builder` fails because the source path does not exist.

**Fix applied:** Add at least one production dependency so `node_modules/` is created:

```json
// package.json
"dependencies": {
  "dotenv": "^16.0.0"
}
```

Alternatively, switch to a single-stage Dockerfile if there are no build-time dependencies.

---

### Issue 7: `.dockerignore` Missing — Terraform State Baked Into Image

**Symptom:** Docker image is unexpectedly large (328 MB) and contains sensitive files (`terraform.tfstate`, `.terraform/` provider binaries).

**Root cause:** `COPY . .` in the Dockerfile copies the entire project directory, including `.terraform/`, `terraform.tfstate`, and `terraform.tfvars` into the image.

**Fix applied:** Added `.dockerignore`:

```
.terraform/
terraform.tfstate
terraform.tfstate.backup
*.tfstate*
*.tfvars
*.tf
Script/
node_modules/
.git/
```

> **Security note:** `terraform.tfstate` contains resource IDs and may contain sensitive values. Never bake it into a Docker image.

---

### Issue 8: arm64 Image Built on Apple Silicon Fails TCP Health Check Silently

**Symptom:** App Runner `CREATE_FAILED` after ~18 minutes. Deployment log shows:

```
[AppRunner] Performing health check on protocol `TCP` [Port: '8080'].
[AppRunner] Health check failed on protocol `TCP` [Port: '8080'].
  Check your configured port number. For more information, see the application logs.
[AppRunner] Deployment failed. Failure reason: Health check failed.
```

No application log stream exists in CloudWatch. Container runs and returns HTTP 200 locally.

**Root cause:** Docker image built on Apple Silicon (arm64) without `--platform linux/amd64`. App Runner runs on `amd64` (x86_64). When App Runner starts the container, the `node` binary receives an **Exec format error** and exits immediately — before binding to port 8080 and before writing anything to stdout. This is why:
- TCP health check always fails (port never opens)
- No application log stream is created (process never writes stdout)
- Container works fine locally (same arm64 machine that built it)

The App Runner error message "check your configured port number" is misleading — the port is correct; the binary cannot execute.

**Diagnose:**
```bash
docker image inspect my-web-app:latest --format '{{.Architecture}}/{{.Os}}'
# arm64/linux  ← wrong; App Runner needs amd64/linux
# amd64/linux  ← correct
```

**Fix applied:** Always build with `--platform linux/amd64` from an Apple Silicon Mac:

```bash
docker buildx build --platform linux/amd64 -t my-web-app:latest --load .

# Verify before pushing
docker image inspect my-web-app:latest --format '{{.Architecture}}/{{.Os}}'
# Must print: amd64/linux

docker tag my-web-app:latest <account>.dkr.ecr.us-east-1.amazonaws.com/my-web-app:latest
docker push <account>.dkr.ecr.us-east-1.amazonaws.com/my-web-app:latest
```

> **Critical:** Push the correct amd64 image to ECR **before** running `terraform apply`. If `apply` starts while the wrong image is in ECR, App Runner pulls it immediately and the deploy will fail with no useful error. Delete the `CREATE_FAILED` service, push the fixed image, then re-apply.

---

### Issue 9: Test Script Exits Immediately — Bash Arithmetic Zero-Return Bug

**Symptom:** `Script/test_architecture.sh` exits after the first warning with no output, even though `set -e` was removed.

**Root cause:** Bash arithmetic expressions `((VAR++))` return exit code `1` when the variable's value is `0` (because `0` is falsy in bash arithmetic context). With `set -uo pipefail` still active, this triggers an immediate script exit the first time any counter starts at zero and is incremented.

```bash
# BAD — exits with code 1 when WARN=0
((WARN++))

# GOOD — always returns exit code 0
WARN=$((WARN + 1))
```

**Fix applied:**

1. Changed `set -euo pipefail` → `set -uo pipefail` (removed `-e` to avoid false exits from intentional non-zero commands like `grep` returning 1 for no match)
2. Replaced all `((VAR++))` increments with `VAR=$((VAR + 1))` for `PASS`, `FAIL`, and `WARN` counters

> This is a common bash gotcha when combining `set -e` with arithmetic counters that start at zero. The `$((expr))` form always returns exit code 0 regardless of the arithmetic result.

