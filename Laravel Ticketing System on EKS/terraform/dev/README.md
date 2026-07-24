# terraform/dev

Root Terraform composition for the **dev** environment of the Laravel ticketing
platform. It wires the seven reusable modules under `../modules` into a single
stack and stores its state in the S3 backend created by `../bootstrap`.

## Prerequisites

1. Apply the bootstrap stack first — it creates the state bucket, lock table,
   and KMS key this directory's backend points at:

   ```bash
   cd ../bootstrap
   terraform init
   terraform apply
   ```

2. AWS credentials for account `022499047467` with permission to manage the
   resources, targeting region `ap-southeast-1`.

## Wiring order

```
network ──▶ eks ──┬──▶ ecr        (pull principals = node roles)
                  ├──▶ database   (ingress from node SG)
                  ├──▶ cache      (ingress from node SG)
                  ├──▶ storage    (bucket ARN ──▶ eks app IRSA)
                  └──▶ secrets    (4 secret ARNs ──▶ eks external-secrets IRSA)
```

> The eks module consumes `storage.bucket_arn` and the four secret ARNs while
> database and cache consume `eks.node_security_group_id`. Terraform resolves
> this at resource granularity, so there is no dependency cycle.

## Usage

```bash
# First init (offline / before backend exists):
terraform init -backend=false
terraform validate

# Real init once bootstrap is applied:
terraform init

cp terraform.tfvars.example terraform.tfvars   # then edit
terraform plan
# terraform apply   # deploy — not run during authoring
```

## Files

| File | Purpose |
|---|---|
| `versions.tf` | Terraform and provider version constraints |
| `backend.tf` | S3 remote state backend (bucket `ticketing-dev-tfstate-022499047467`) |
| `providers.tf` | AWS provider + `default_tags` |
| `variables.tf` | Input variables with contract defaults |
| `main.tf` | Module composition and cross-module wiring |
| `outputs.tf` | Environment outputs consumed by scripts, Helm, and CI |
| `terraform.tfvars.example` | Placeholder variable values (no secrets) |

## Key inputs

| Variable | Default | Notes |
|---|---|---|
| `owner_email` | none (required) | Written to the `Owner` tag |
| `admin_principal_arns` | `[]` | IAM principals granted cluster-admin via EKS access entries |
| `region` | `ap-southeast-1` | |
| `cluster_name` | `ticketing-dev` | Shared by network subnet tags and eks |
| `kubernetes_version` | `1.36` | |
| `vpc_cidr` | `10.42.0.0/16` | |
| `enable_flow_logs` | `false` | VPC flow logs are billed per GB |

## Outputs

`cluster_name`, `cluster_endpoint`, `region`, `ecr_repository_url`,
`ecr_cache_repository_url`, `attachments_bucket`, `rds_address`, `redis_address`,
`irsa_role_arns`, `secret_names`, `vpc_id`, `private_subnet_ids`,
`node_security_group_id`.

> No plaintext credential is ever an output. The DB password and Redis AUTH
> token exist only in Terraform state and Secrets Manager; workloads read them
> through the External Secrets Operator using the names in `secret_names`.
