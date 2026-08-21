# Kubernetes GitOps with ArgoCD on AWS EKS

This project deploys a production-shaped **GitOps continuous-delivery platform** on AWS. Terraform provisions a dedicated VPC, an **Amazon EKS** control plane, and a managed worker node group, then installs **ArgoCD** (via its official Helm chart) as the in-cluster GitOps engine. ArgoCD continuously watches a Git repository — the single source of truth — and reconciles the desired application state in Git against the running state in the cluster, self-healing drift and pruning removed resources automatically. Worker nodes run in private subnets and reach the internet through a NAT gateway; the Kubernetes API server is exposed publicly (lock this down in production) so `kubectl` and the ArgoCD CLI can reach it. A sample application (the ArgoCD `guestbook` example) is wired in declaratively to demonstrate an end-to-end sync.

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
14. [Frequently Asked Questions](#14-frequently-asked-questions)

---

## 1. Architecture Overview

```
                                      ┌──────────────────────────┐
                          git push    │      Git Repository       │
        Developer ───────────────────▶│  (source of truth)        │
                                      │  argocd-example-apps      │
                                      └────────────┬─────────────┘
                                                   │ poll / webhook
                                                   ▼
   Internet                                ┌────────────────┐
      │                                    │    ArgoCD      │  reconcile loop
      │ kubectl / argocd CLI               │ (in cluster)   │─────────────┐
      ▼                                    └───────┬────────┘             │
┌───────────┐   public endpoint   ┌────────────────▼───────────────┐      │
│    IGW    │────────────────────▶│      EKS Control Plane          │     │ sync
└─────┬─────┘                     │   (managed API server, etcd)    │     │ desired
      │                           └───────────────┬────────────────┘      │ state
      │ (public subnets: ELBs, NAT)               │ manages               │
      ▼                                           ▼                       ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                              VPC  10.0.0.0/16                               │
│                                                                             │
│   Public Subnets (x3)                    Private Subnets (x3)               │
│   ┌───────────────┐                      ┌──────────────────────────────┐   │
│   │  NAT Gateway  │◀──── egress ─────────│  Managed Node Group           │  │
│   │  (single AZ)  │                      │  2x t3.medium worker nodes    │  │
│   └───────────────┘                      │  ├─ argocd pods               │  │
│                                          │  └─ guestbook pods (synced)   │  │
│                                          └──────────────────────────────┘   │
└───────────────────────────────────────────────────────────────────────────┘
                                                   │
                                                   ▼
                                          ┌──────────────────┐
                                          │   CloudWatch      │
                                          │  (control-plane   │
                                          │   logs, metrics)  │
                                          └──────────────────┘
```

**Traffic flow:** A developer commits Kubernetes manifests to the Git repository. ArgoCD, running inside the cluster, detects the change (poll or webhook), compares desired-vs-live state, and applies the diff through the EKS API server. Worker nodes in private subnets pull container images out through the NAT gateway. Operators reach the API server over the public endpoint via the Internet Gateway using `kubectl`, and reach the ArgoCD UI through a local `kubectl port-forward` tunnel. Control-plane logs and metrics flow to CloudWatch.

---

## 2. Networking & Routing

### VPC

| Attribute | Value |
|---|---|
| CIDR block | `10.0.0.0/16` |
| DNS hostnames | Enabled |
| DNS support | Enabled |
| Availability Zones | First 3 in the region (e.g. `us-east-1a/b/c`) |

### Subnets

| Subnet | Type | CIDR (per AZ) | Purpose | Key Tag |
|---|---|---|---|---|
| Public × 3 | Public | `10.0.128.0/20` … | NAT gateway, public load balancers | `kubernetes.io/role/elb = 1` |
| Private × 3 | Private | `10.0.0.0/20` … | EKS worker nodes, internal LBs | `kubernetes.io/role/internal-elb = 1` |

> CIDRs are derived with `cidrsubnet(vpc_cidr, 4, ...)`; private subnets use index `0-2`, public subnets index `8-10`.

### Route Tables

| Route Table | Associated Subnets | Route | Target |
|---|---|---|---|
| Public | Public × 3 | `0.0.0.0/0` | Internet Gateway (`igw`) |
| Private | Private × 3 | `0.0.0.0/0` | NAT Gateway (`nat`) |
| Local (implicit) | All | `10.0.0.0/16` | `local` |

### Traffic Flow

```
   kubectl / argocd CLI                        Worker node egress (image pulls)
          │                                              │
          ▼                                              ▼
   ┌─────────────┐                              ┌──────────────────┐
   │     IGW     │                              │  Private Subnet  │
   └──────┬──────┘                              │   worker node    │
          │ public API endpoint                 └────────┬─────────┘
          ▼                                              │ 0.0.0.0/0
   ┌──────────────────┐                                  ▼
   │ EKS API Server   │                          ┌──────────────┐
   │ (control plane)  │                          │ NAT Gateway  │ (public subnet)
   └──────────────────┘                          └──────┬───────┘
                                                        │
                                                        ▼
                                                    ┌───────┐
                                                    │  IGW  │──▶ Internet
                                                    └───────┘
```

---

## 3. Component Details

### 3.1 VPC & Subnets (`terraform-aws-modules/vpc/aws`)

| Attribute | Value |
|---|---|
| Module version | `~> 5.13` |
| NAT gateway | Single (cost-optimised; one per AZ for prod HA) |
| Public subnet tags | `kubernetes.io/role/elb = 1` |
| Private subnet tags | `kubernetes.io/role/internal-elb = 1` |

> The subnet role tags let the in-tree cloud provider and AWS Load Balancer Controller auto-discover where to place public vs internal load balancers.

### 3.2 EKS Control Plane (`terraform-aws-modules/eks/aws`)

| Attribute | Value |
|---|---|
| Module version | `~> 20.24` |
| Cluster name | `gitops-eks` (variable) |
| Kubernetes version | `1.30` (variable) |
| Public endpoint access | Enabled (restrict CIDRs in prod) |
| Creator admin permissions | Enabled — grants the Terraform identity cluster-admin |
| Nodes placement | Private subnets |

### 3.3 Cluster Add-ons

| Add-on | Purpose |
|---|---|
| `coredns` | In-cluster DNS |
| `kube-proxy` | Service networking / iptables rules |
| `vpc-cni` | Pod networking (ENIs from the VPC) |
| `eks-pod-identity-agent` | Pod-level IAM via EKS Pod Identity |

### 3.4 Managed Node Group

| Attribute | Value |
|---|---|
| Name | `worker-nodes` |
| Instance type | `t3.medium` (variable) |
| AMI type | `AL2023_x86_64_STANDARD` |
| Desired / Min / Max | `2 / 2 / 4` (variables) |
| Node label | `role = worker` |
| Subnets | Private × 3 |

### 3.5 ArgoCD (Helm release `argo-cd`)

| Attribute | Value |
|---|---|
| Chart version | `7.7.5` (variable) |
| Namespace | `argocd` (auto-created) |
| Service type | `ClusterIP` (reach UI via `port-forward`) |
| HA | Disabled for demo (`redis-ha=false`, single replicas) |
| `wait` / `timeout` | `true` / `600s` — blocks until CRDs + pods are Ready |

> ArgoCD is the GitOps engine. It runs a continuous reconcile loop: observe Git → diff against live cluster state → apply. `selfHeal` reverts manual drift; `prune` deletes resources removed from Git.

### 3.6 GitOps Application (Helm release `argocd-apps`)

| Attribute | Value |
|---|---|
| Chart version | `2.0.2` |
| Application name | `sample-app` |
| Source repo | `https://github.com/argoproj/argocd-example-apps.git` (variable) |
| Path | `guestbook` (variable) |
| Target revision | `HEAD` (variable) |
| Destination namespace | `default` (variable) |
| Sync policy | `automated` with `prune=true`, `selfHeal=true`, `CreateNamespace=true` |

> Delivering the `Application` through the `argocd-apps` chart (rather than a `kubernetes_manifest`) sidesteps the classic chicken-and-egg problem where the `Application` CRD does not yet exist at `plan` time on a brand-new cluster.

---

## 4. Directory Structure

```
Kubernetes GitOps with ArgoCD on EKS/
├── README.md                       # This document
├── .gitignore                      # Ignores state, plans, .terraform, secrets
├── manifests/
│   └── app.yaml                    # Standalone ArgoCD Application (manual kubectl apply path)
└── terraform/
    ├── versions.tf                 # Terraform + provider version constraints
    ├── providers.tf                # aws, kubernetes, helm providers (auth against EKS)
    ├── backend.tf                  # Commented S3 remote-state backend template
    ├── variables.tf                # All input variables + validation rules
    ├── terraform.tfvars.example    # Sample variable values (copy to terraform.tfvars)
    ├── vpc.tf                       # VPC module: subnets, NAT, route tables, k8s tags
    ├── eks.tf                       # EKS module: control plane, add-ons, node group
    ├── argocd.tf                    # Helm releases: argo-cd + argocd-apps (sample app)
    └── outputs.tf                  # Cluster + helper command outputs
```

---

## 5. Prerequisites

| Tool | Minimum Version | Install Link |
|---|---|---|
| Terraform | 1.5.0 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | 2.15 | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| kubectl | 1.29 | https://kubernetes.io/docs/tasks/tools/ |
| Helm | 3.14 | https://helm.sh/docs/intro/install/ |
| argocd CLI (optional) | 2.12 | https://argo-cd.readthedocs.io/en/stable/cli_installation/ |

Account-level requirements:

- AWS credentials configured (`aws configure`) with permissions to create VPC, EKS, IAM, and EC2 resources.
- An EKS service-linked role in the account (created automatically on first EKS use).
- Sufficient vCPU quota for the node group in your chosen region.

---

## 6. Quick Start

```bash
# 1. Move into the Terraform directory
cd "Kubernetes GitOps with ArgoCD on EKS/terraform"

# 2. (Optional) copy and edit variables — point gitops_repo_url at YOUR repo
cp terraform.tfvars.example terraform.tfvars

# 3. Initialise providers and modules
terraform init

# 4. Review the plan
terraform plan

# 5. Provision the VPC, EKS cluster, node group, and ArgoCD
terraform apply    # type "yes" to confirm

# 6. Point kubectl at the new cluster (command is also a Terraform output)
aws eks update-kubeconfig --region us-east-1 --name gitops-eks

# 7. Verify nodes and ArgoCD pods are Ready
kubectl get nodes
kubectl get pods -n argocd

# 8. Expose the ArgoCD UI locally
kubectl port-forward svc/argocd-server -n argocd 8080:443
#    → open https://localhost:8080

# 9. Retrieve the initial admin password (username: admin)
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 --decode; echo

# 10. Watch the sample app sync
kubectl get applications -n argocd
kubectl get pods -n default
```

Allow 15–20 minutes for the EKS control plane, node group, and ArgoCD to become healthy and for the first sync to complete.

---

## 7. Input Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `region` | string | `us-east-1` | AWS region to deploy into |
| `cluster_name` | string | `gitops-eks` | Name of the EKS cluster |
| `kubernetes_version` | string | `1.30` | Control-plane Kubernetes version |
| `vpc_cidr` | string | `10.0.0.0/16` | CIDR block for the VPC |
| `node_instance_type` | string | `t3.medium` | Worker node EC2 instance type |
| `node_desired_size` | number | `2` | Desired worker node count |
| `node_min_size` | number | `2` | Minimum worker node count |
| `node_max_size` | number | `4` | Maximum worker node count |
| `argocd_chart_version` | string | `7.7.5` | `argo-cd` Helm chart version |
| `argocd_namespace` | string | `argocd` | Namespace ArgoCD installs into |
| `gitops_repo_url` | string | `argocd-example-apps.git` | Git repo ArgoCD watches |
| `gitops_path` | string | `guestbook` | Manifest path within the repo |
| `gitops_target_revision` | string | `HEAD` | Branch/tag/commit to track |
| `gitops_dest_namespace` | string | `default` | Namespace the app deploys into |
| `tags` | map(string) | see `variables.tf` | Tags applied to all resources |

> **Cross-variable validation:** `vpc_cidr` must be a valid IPv4 CIDR (`cidrhost` check), and `node_max_size` must be `>= node_desired_size`. Both are enforced at plan time.

---

## 8. Outputs

| Output | Description |
|---|---|
| `cluster_name` | Name of the EKS cluster |
| `cluster_endpoint` | Kubernetes API server endpoint |
| `cluster_version` | Control-plane Kubernetes version |
| `cluster_security_group_id` | Security group attached to the control plane |
| `vpc_id` | ID of the VPC hosting the cluster |
| `private_subnet_ids` | Private subnet IDs the nodes run in |
| `argocd_namespace` | Namespace ArgoCD is installed into |
| `configure_kubectl` | `aws eks update-kubeconfig` command for this cluster |
| `argocd_port_forward` | `kubectl port-forward` command for the ArgoCD UI |
| `argocd_admin_password_cmd` | Command to decode the initial admin password |

```bash
# Example: print the ready-to-run kubeconfig command
terraform output -raw configure_kubectl
```

---

## 9. Scaling Behaviour

The managed node group scales between `node_min_size` and `node_max_size`. In this demo the desired/min are both `2`, giving a stable floor, with headroom to `4` for the Kubernetes **Cluster Autoscaler** or **Karpenter** to add capacity when pods go `Pending` for lack of resources. (This stack sizes the group; it does not install an autoscaler — see the FAQ.)

```
 nodes
   4 ┤                                 ┌──────────────  max_size (4)
     │                                 │  autoscaler adds nodes
   3 ┤                        ┌────────┘  when pods are Pending
     │                        │
   2 ┤━━━━━━━━━━━━━━━━━━━━━━━━┛━━━━━━━━━━━━━━━━━━━━━━━━  desired/min (2)
     │   steady state          scale-up on pressure
   1 ┤
     │
   0 ┼────┬────┬────┬────┬────┬────┬────┬────┬────▶ time
        deploy      more workloads scheduled
```

- **Dead-band:** with desired = min = 2, the group never scales *below* 2 — no flapping at idle.
- **Evaluation:** the Cluster Autoscaler (if installed) evaluates unschedulable pods roughly every 10s and scales the ASG behind the node group.
- **Step size:** managed node groups add/remove nodes one at a time by default; the max of `4` bounds blast radius and cost while still absorbing a burst of new workloads synced from Git.

---

## 10. Tagging Strategy

| Tag Key | Value |
|---|---|
| `Project` | `kubernetes-gitops-argocd` |
| `Environment` | `demo` |
| `ManagedBy` | `terraform` |
| `Owner` | `platform-team` |

Applied globally via the AWS provider `default_tags` block, so every taggable resource inherits them. Additional resource-specific tags:

| Resource | Extra Tag | Value |
|---|---|---|
| Public subnets | `kubernetes.io/role/elb` | `1` |
| Private subnets | `kubernetes.io/role/internal-elb` | `1` |
| Node group | `NodeGroup` | `worker-nodes` |

> The `kubernetes.io/role/*` tags are **functional, not cosmetic** — the cloud provider reads them to place load balancers. Do not remove them.

---

## 11. Security Considerations

| Topic | Current posture | Recommended hardening |
|---|---|---|
| API server endpoint | Public (`0.0.0.0/0`) | Restrict `cluster_endpoint_public_access_cidrs` to office/VPN ranges, or make private-only |
| ArgoCD UI exposure | `ClusterIP` + `port-forward` only | Front with an internal ALB + OIDC/SSO; never expose the admin service publicly |
| ArgoCD admin credential | Auto-generated `argocd-initial-admin-secret` | Rotate immediately, disable the local admin, wire up SSO |
| Node placement | Private subnets, egress via NAT | Keep private; add VPC endpoints (ECR, S3, STS) to cut NAT cost and data exfil surface |
| Cluster access | Terraform identity is cluster-admin | Use EKS Access Entries / IAM roles scoped per team; avoid shared admin |
| Secrets in Git | Plain manifests | Use Sealed Secrets, SOPS, or External Secrets Operator — never commit plaintext secrets |
| Control-plane logging | Default | Enable `api`, `audit`, `authenticator` log types to CloudWatch |
| Pod IAM | `eks-pod-identity-agent` add-on present | Grant least-privilege IAM via EKS Pod Identity / IRSA per workload |

---

## 12. Cost Estimate

Approximate **us-east-1** on-demand pricing, cluster running 24×7 for a full month.

| Resource | Quantity | Monthly cost (USD) |
|---|---|---|
| EKS control plane | 1 cluster | $73.00 |
| Worker nodes (`t3.medium`) | 2 × $0.0416/hr | $60.74 |
| EBS gp3 root volumes | 2 × 20 GB | $3.20 |
| NAT Gateway (hourly) | 1 × $0.045/hr | $32.85 |
| NAT Gateway (data processing) | ~10 GB | $0.45 |
| Elastic IP (for NAT) | 1 (in use) | $0.00 |
| CloudWatch logs/metrics | low volume | ~$2.00 |
| **Total** | | **≈ $172.24 / month** |

> The two largest levers are the **NAT gateway** (~$33/mo — replace with VPC endpoints for AWS-only egress) and the **control plane** (fixed $73/mo per cluster). Running only during work hours, or using Spot/Fargate for nodes, cuts the node line substantially. Estimate with the [AWS Pricing Calculator](https://calculator.aws/).

---

## 13. Destroying the Stack

```bash
cd "Kubernetes GitOps with ArgoCD on EKS/terraform"

# Destroy Helm releases, node group, EKS control plane, and VPC
terraform destroy    # type "yes" to confirm
```

Manual pre-steps and caveats:

- **Delete synced workloads that provision AWS resources first.** If the GitOps app created a `Service type=LoadBalancer`, delete that app in ArgoCD (or `kubectl delete`) *before* `terraform destroy`, so the ELB and its ENIs are removed — otherwise the VPC destroy fails on lingering dependencies.
  ```bash
  kubectl delete application sample-app -n argocd
  ```
- **Orphaned ENIs / security groups** left by the CNI or a load balancer can block VPC deletion; remove them in the console if `destroy` stalls.
- **Not managed by Terraform (will survive):** the CloudWatch log group `/aws/eks/gitops-eks/cluster` if control-plane logging was enabled manually, and any `kubectl`-created resources not tracked in Git or state.

---

## 14. Frequently Asked Questions

**Q1. My pods show `502`/`503` or the guestbook UI is unreachable — what's wrong?**
A `502/503` from an ingress or load balancer almost always means no healthy backend pods. Check `kubectl get pods -n default` — if they're `Pending`, the node group may be at capacity (bump `node_max_size`); if `CrashLoopBackOff`, inspect `kubectl logs`. Also confirm the ArgoCD `Application` is `Synced`/`Healthy` with `kubectl get applications -n argocd`.

**Q2. Everything sits in a few AZs / a single NAT gateway — isn't that a risk?**
Yes. The demo uses `single_nat_gateway = true` so all private-subnet egress funnels through one AZ's NAT — if that AZ fails, image pulls stop. The nodes themselves spread across three private subnets/AZs, so running pods survive an AZ loss. For production set `single_nat_gateway = false` (one NAT per AZ) to remove the shared egress SPOF.

**Q3. How do I add HTTPS / expose ArgoCD or my app publicly?**
Install the **AWS Load Balancer Controller**, then either set the ArgoCD `server.service.type` to `LoadBalancer` or create an `Ingress` with an ACM certificate ARN annotation. The subnet `kubernetes.io/role/elb` tags already let the controller discover public subnets. For the app, add an `Ingress`/`Service type=LoadBalancer` to its manifests in Git and let ArgoCD sync it.

**Q4. How do I deploy MY application instead of the guestbook sample?**
Point `gitops_repo_url`, `gitops_path`, and `gitops_target_revision` at your repo (in `terraform.tfvars`) and re-apply — or edit `manifests/app.yaml` and `kubectl apply -f` it. ArgoCD then watches your repo: every `git push` to the tracked revision is reconciled automatically because `syncPolicy.automated` is on.

**Q5. I edited a running resource with `kubectl` and it reverted — why?**
That's GitOps working as designed. `selfHeal: true` makes ArgoCD treat Git as authoritative and revert any live drift. To make a lasting change, commit it to the Git repo; ArgoCD syncs it from there. Disable `selfHeal` only for break-glass debugging.

**Q6. Why doesn't `terraform apply` create the ArgoCD `Application` with a `kubernetes_manifest` resource?**
Because `kubernetes_manifest` performs a server-side lookup of the resource's CRD at **plan** time — and on a brand-new cluster the `argoproj.io` CRDs don't exist yet, so the plan fails. This stack instead delivers the `Application` through the `argocd-apps` Helm chart, which only touches the API server at **apply** time, after ArgoCD's CRDs are installed.

**Q7. Should I use remote state?**
Yes, for anything beyond a solo experiment. Local state can't be shared or locked safely. Uncomment the S3 backend block in `backend.tf`, supply an S3 bucket and DynamoDB lock table, and re-run `terraform init` to migrate.

**Q8. Does this autoscale the cluster automatically?**
The node group is *sized* (2→4) but no autoscaler is installed, so it stays at the desired count. To make it elastic, deploy the **Cluster Autoscaler** or **Karpenter** — ideally itself managed by ArgoCD as another `Application`, keeping the platform fully GitOps-driven.
