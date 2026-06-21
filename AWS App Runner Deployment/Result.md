# Deployment Result — AWS App Runner Deployment

**Date:** 2026-06-21
**Region:** us-east-1
**Environment:** dev
**Account:** 022499047467
**Terraform resources managed:** 9

---

## All AWS Resources Created

| Resource | Name / ID | ARN / URI |
|---|---|---|
| App Runner Service | `my-web-app-service` | `arn:aws:apprunner:us-east-1:022499047467:service/my-web-app-service/1c28aa51172e4f54b10d98fa0eb2c203` |
| App Runner Auto Scaling Config | `my-web-app-auto-scaling` rev 1 | `arn:aws:apprunner:us-east-1:022499047467:autoscalingconfiguration/my-web-app-auto-scaling/1/66a65ef7d4db4488930464c6d26b4061` |
| ECR Repository | `my-web-app` | `022499047467.dkr.ecr.us-east-1.amazonaws.com/my-web-app` |
| ECR Lifecycle Policy | keep last 10 images | attached to `my-web-app` |
| IAM Role (service) | `my-web-app-app-runner-service-role` | `arn:aws:iam::022499047467:role/my-web-app-app-runner-service-role` |
| IAM Role (instance) | `my-web-app-app-runner-instance-role` | `arn:aws:iam::022499047467:role/my-web-app-app-runner-instance-role` |
| IAM Policy Attachment | `AWSAppRunnerServicePolicyForECRAccess` | `arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess` |
| IAM Inline Policy | `my-web-app-app-runner-instance-logs-policy` | attached to instance role |
| CloudWatch Log Group | `/aws/apprunner/my-web-app` | `arn:aws:logs:us-east-1:022499047467:log-group:/aws/apprunner/my-web-app` |
| CloudWatch Alarm — CPU | `my-web-app-cpu-high` | `arn:aws:cloudwatch:us-east-1:022499047467:alarm:my-web-app-cpu-high` |
| CloudWatch Alarm — Memory | `my-web-app-memory-high` | `arn:aws:cloudwatch:us-east-1:022499047467:alarm:my-web-app-memory-high` |
| CloudWatch Alarm — Deploy | `my-web-app-deployment-failed` | `arn:aws:cloudwatch:us-east-1:022499047467:alarm:my-web-app-deployment-failed` |

---

## Key Outputs

| Output | Value |
|---|---|
| `app_runner_service_url` | `kdetiinmir.us-east-1.awsapprunner.com` |
| `app_runner_service_arn` | `arn:aws:apprunner:us-east-1:022499047467:service/my-web-app-service/1c28aa51172e4f54b10d98fa0eb2c203` |
| `app_runner_service_status` | `RUNNING` |
| `app_runner_service_role_arn` | `arn:aws:iam::022499047467:role/my-web-app-app-runner-service-role` |
| `app_runner_instance_role_arn` | `arn:aws:iam::022499047467:role/my-web-app-app-runner-instance-role` |
| `auto_scaling_configuration_arn` | `arn:aws:apprunner:us-east-1:022499047467:autoscalingconfiguration/my-web-app-auto-scaling/1/66a65ef7d4db4488930464c6d26b4061` |
| `auto_scaling_configuration_revision` | `1` |
| `ecr_repository_url` | `022499047467.dkr.ecr.us-east-1.amazonaws.com/my-web-app` |
| `ecr_registry_id` | `022499047467` |
| `ecr_repository_arn` | `arn:aws:ecr:us-east-1:022499047467:repository/my-web-app` |
| `cloudwatch_log_group_name` | `/aws/apprunner/my-web-app` |
| `cloudwatch_log_group_arn` | `arn:aws:logs:us-east-1:022499047467:log-group:/aws/apprunner/my-web-app` |
| `cpu_alarm_arn` | `arn:aws:cloudwatch:us-east-1:022499047467:alarm:my-web-app-cpu-high` |
| `memory_alarm_arn` | `arn:aws:cloudwatch:us-east-1:022499047467:alarm:my-web-app-memory-high` |
| `deployment_alarm_arn` | `arn:aws:cloudwatch:us-east-1:022499047467:alarm:my-web-app-deployment-failed` |

---

## App Runner Service Detail

| Attribute | Value |
|---|---|
| Service Name | `my-web-app-service` |
| Service ID | `1c28aa51172e4f54b10d98fa0eb2c203` |
| Status | `RUNNING` |
| Public URL | `https://kdetiinmir.us-east-1.awsapprunner.com` |
| Created | 2026-06-21T13:10:04+08:00 |
| Auto Deployments | Enabled |
| vCPU | 0.25 vCPU (256 units) |
| Memory | 512 MB |
| Image | `022499047467.dkr.ecr.us-east-1.amazonaws.com/my-web-app:latest` |
| Image Type | ECR (private) |
| Container Port | 8080 |
| Network | Public (`IsPubliclyAccessible: true`) |
| Egress | DEFAULT (AWS-managed NAT) |
| IP Address Type | IPv4 |

### Health Check Configuration

| Parameter | Value |
|---|---|
| Protocol | TCP |
| Port | 8080 |
| Interval | 5 s |
| Timeout | 2 s |
| Healthy threshold | 1 |
| Unhealthy threshold | 5 |

---

## ECR Image

| Attribute | Value |
|---|---|
| Repository | `my-web-app` |
| Tag | `latest` |
| Digest | `sha256:ca9562945e22b02fbbfe566c4c3e9f77f7fb1a3ae9b6a9169696d98de941cdfb` |
| Architecture | `linux/amd64` |
| Size (compressed) | ~43 MB (44,977,517 bytes) |
| Pushed | 2026-06-21T12:47:58+08:00 |
| Last pulled | 2026-06-21T13:10:29+08:00 |
| Scan on push | Enabled |
| Encryption | AES256 |
| Tag mutability | MUTABLE |
| Lifecycle policy | Keep last 10 images (expire older) |

---

## IAM Configuration

### Service Role — `my-web-app-app-runner-service-role`

| Attribute | Value |
|---|---|
| ARN | `arn:aws:iam::022499047467:role/my-web-app-app-runner-service-role` |
| Role ID | `AROAQKPIMHAV4UL6ZZFK4` |
| Trust principal | `build.apprunner.amazonaws.com` |
| Managed policy | `AWSAppRunnerServicePolicyForECRAccess` |
| Last used | 2026-06-21T05:01:29Z (us-east-1) |

### Instance Role — `my-web-app-app-runner-instance-role`

| Attribute | Value |
|---|---|
| ARN | `arn:aws:iam::022499047467:role/my-web-app-app-runner-instance-role` |
| Role ID | `AROAQKPIMHAVRBSCXT6M3` |
| Trust principal | `tasks.apprunner.amazonaws.com` |
| Inline policy | `my-web-app-app-runner-instance-logs-policy` (CloudWatch Logs write) |

---

## Auto Scaling Configuration

| Attribute | Value |
|---|---|
| Name | `my-web-app-auto-scaling` |
| Revision | 1 |
| Status | `active` |
| Min instances | 1 |
| Max instances | 4 |
| Max concurrency | 100 requests per instance |
| Associated service | `my-web-app-service` |

---

## CloudWatch

### Log Groups

| Log Group | Retention | Purpose |
|---|---|---|
| `/aws/apprunner/my-web-app` | 7 days | Terraform-managed application log group |
| `/aws/apprunner/my-web-app-service/1c28aa51172e4f54b10d98fa0eb2c203/application` | — | App Runner application stdout/stderr |
| `/aws/apprunner/my-web-app-service/1c28aa51172e4f54b10d98fa0eb2c203/service` | — | App Runner platform/deployment events |

### Alarm Status

| Alarm | Metric | Threshold | Evaluation | State | Reason |
|---|---|---|---|---|---|
| `my-web-app-cpu-high` | `CPUUtilization` (avg) | > 80% | 2 × 5 min | `INSUFFICIENT_DATA` | No metric data yet (service just deployed) |
| `my-web-app-memory-high` | `MemoryUtilization` (avg) | > 80% | 2 × 5 min | `INSUFFICIENT_DATA` | No metric data yet (service just deployed) |
| `my-web-app-deployment-failed` | `DeploymentFailures` (sum) | >= 1 | 1 × 5 min | `INSUFFICIENT_DATA` | No metric data yet (service just deployed) |

> `INSUFFICIENT_DATA` on all three alarms is expected immediately after first deployment. They will transition to `OK` once App Runner emits its first metric data points (~5–10 minutes of uptime).

---

## Architecture Overview

```
                          Internet
                             │
                             ▼
                   ┌──────────────────┐
                   │   App Runner     │
                   │  (AWS-managed    │
                   │   control plane) │
                   └────────┬─────────┘
                            │  pulls image on deploy
                            ▼
                   ┌──────────────────┐
                   │   Amazon ECR     │
                   │  my-web-app:latest│
                   │  (linux/amd64)   │
                   └──────────────────┘
                            │
                   ┌────────┘
                   │  runs container
                   ▼
         ┌──────────────────────┐
         │  App Runner Instance  │
         │  0.25 vCPU / 512 MB  │
         │  Node.js on port 8080 │
         │  TCP health check ✓   │
         └──────────┬────────────┘
                    │
         ┌──────────┘
         │
         ▼
┌──────────────────────────────────────────┐
│          CloudWatch                       │
│  Log group: /aws/apprunner/my-web-app     │
│  Alarms: CPU high / Memory high /         │
│          Deployment failed                │
└──────────────────────────────────────────┘

Traffic flow:
  HTTPS (443) → kdetiinmir.us-east-1.awsapprunner.com
  → App Runner managed ingress
  → Container port 8080 (Node.js HTTP server)
  → Response: 200 OK "Hello from AWS App Runner!"

Auto-deployment pipeline:
  ECR push to :latest tag
  → App Runner detects change (auto-deploy enabled)
  → Pulls new image → health check → swap traffic
```

---

## Test Script Results

Script: `Script/test_architecture.sh`
Run date: 2026-06-21

| Group | Test | Result |
|---|---|---|
| App Runner | Service `my-web-app-service` is RUNNING | PASS |
| App Runner | HTTP endpoint returns 200 | PASS |
| App Runner | Auto-deployments enabled | PASS |
| ECR | Repository `my-web-app` exists | PASS |
| ECR | Image tag `latest` present | PASS |
| ECR | Scan on push enabled | PASS |
| ECR | Lifecycle policy attached | PASS |
| IAM | Service role exists | PASS |
| IAM | Service role trusts `build.apprunner.amazonaws.com` | PASS |
| IAM | `AWSAppRunnerServicePolicyForECRAccess` attached | PASS |
| IAM | Instance role exists | PASS |
| IAM | Instance role trusts `tasks.apprunner.amazonaws.com` | PASS |
| Auto Scaling | Config `my-web-app-auto-scaling` is active | PASS |
| Auto Scaling | Min instances = 1 | PASS |
| Auto Scaling | Max instances = 4 | PASS |
| Auto Scaling | Max concurrency = 100 | PASS |
| CloudWatch | Log group `/aws/apprunner/my-web-app` exists | PASS |
| CloudWatch | Log retention = 7 days | PASS |
| CloudWatch | Alarm `my-web-app-cpu-high` exists | WARN (INSUFFICIENT_DATA) |
| CloudWatch | Alarm `my-web-app-memory-high` exists | WARN (INSUFFICIENT_DATA) |
| CloudWatch | Alarm `my-web-app-deployment-failed` exists | WARN (INSUFFICIENT_DATA) |

**Total: 21 tests — 18 PASS / 3 WARN / 0 FAIL**

> WARN on CloudWatch alarms is expected: alarms enter `INSUFFICIENT_DATA` at creation and transition to `OK` once App Runner emits its first metric data points.

---

## Audit Summary

| Item | Count |
|---|---|
| Terraform-managed resources | 9 |
| Tests passed | 18 / 21 |
| Tests warned (non-critical) | 3 / 21 |
| Tests failed | 0 / 21 |
| Alarms in ALARM state | 0 |
| App Runner status | RUNNING |
| HTTP endpoint | 200 OK |
