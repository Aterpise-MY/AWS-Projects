# GraphQL API with AWS AppSync

Deploy a fully serverless GraphQL backend using AWS AppSync and Amazon DynamoDB. This Terraform configuration provisions an AppSync GraphQL API with API key authentication, five VTL-mapped resolvers (two queries, three mutations), a DynamoDB on-demand table with point-in-time recovery, least-privilege IAM roles, CloudWatch field-level logging, and three metric alarms — all without managing servers, VPCs, or load balancers.

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

---

## Architecture Overview

```
                          Internet (HTTPS/443)
                                  │
                                  ▼
              ┌─────────────────────────────────────────┐
              │         AWS AppSync GraphQL API         │
              │      Authentication: API Key            │
              │                                         │
              │  ┌─────────────┐  ┌─────────────────┐   │
              │  │   Queries   │  │   Mutations      │  │
              │  │ ─ getTodos  │  │ ─ addTodo        │  │
              │  │ ─ getTodo   │  │ ─ updateTodo     │  │ 
              │  └──────┬──────┘  │ ─ deleteTodo     │  │
              │         │         └────────┬────────┘   │
              │         │                  │            │
              │         ▼                  ▼            │
              │  ┌──────────────────────────────────┐   │ 
              │  │      VTL Resolvers (Unit)         │  │
              │  │  Scan / GetItem / PutItem /       │  │
              │  │  UpdateItem / DeleteItem          │  │
              │  └─────────────────┬────────────────┘   │
              └────────────────────┼────────────────────┘
                                   │  IAM Role
                                   ▼
                    ┌──────────────────────────┐
                    │     Amazon DynamoDB      │
                    │   Todos Table            │
                    │   On-Demand Capacity     │
                    │   PITR Enabled           │
                    └──────────────────────────┘
                                   │
                    ┌──────────────────────────┐
                    │    Amazon CloudWatch     │
                    │   Field-Level Logs       │
                    │   3 Metric Alarms        │
                    └──────────────────────────┘
```

Traffic flow: Client → AppSync HTTPS endpoint (TLS managed by AWS) → VTL resolver maps GraphQL operation to DynamoDB API call → DynamoDB returns result → VTL response template maps result to GraphQL type → CloudWatch captures field-level logs for every resolver execution.

---

## Networking & Routing

### API Endpoint Configuration

| Property | Value |
|----------|-------|
| **Endpoint type** | Public HTTPS (AWS-managed TLS) |
| **URL format** | `https://<api-id>.appsync-api.<region>.amazonaws.com/graphql` |
| **Protocol** | HTTP/1.1 POST (GraphQL over HTTP) |
| **Authentication** | API Key (`x-api-key` request header) |
| **VPC required** | No — AppSync is a fully managed regional service |
| **DNS** | AWS-managed; no Route 53 configuration needed |

### Traffic Flow

```
┌─────────────────────────────────────────────────────────┐
│              Client GraphQL Request (HTTPS)             │
│  POST https://<id>.appsync-api.us-east-1.amazonaws.com  │
│  Header: x-api-key: <key>                               │
└────────────────────────┬────────────────────────────────┘
                         │
              (TLS Termination + Auth Check)
                         │
                         ▼
          ┌──────────────────────────────┐
          │       AppSync Service        │
          │  Parses GraphQL operation    │
          │  Selects matching resolver   │
          └──────────────┬───────────────┘
                         │
          ┌──────────────┼───────────────┐
          │  Query       │  Mutation     │
          │  Resolvers   │  Resolvers    │
          └──────┬───────┴───────┬───────┘
                 │               │
                 ▼               ▼
          ┌───────────────────────────┐
          │       DynamoDB API        │
          │  (IAM-authenticated)      │
          └───────────────────────────┘
                         │
                         ▼
          ┌───────────────────────────┐
          │  CloudWatch Field Logs    │
          │  (async, ERROR level)     │
          └───────────────────────────┘
```

### AppSync Request Routing

| Operation | Resolver Type | DynamoDB Operation | Condition Check |
|-----------|--------------|-------------------|-----------------|
| `getTodos` | Query | `Scan` | None |
| `getTodo(id)` | Query | `GetItem` | None |
| `addTodo(title)` | Mutation | `PutItem` | None (auto-generated id) |
| `updateTodo(id, completed)` | Mutation | `UpdateItem` | `attribute_exists(id)` |
| `deleteTodo(id)` | Mutation | `DeleteItem` | `attribute_exists(id)` |

---

## Component Details

### 1. AppSync GraphQL API

| Attribute | Value |
|-----------|-------|
| **Name** | `graphql-appsync-todo-api` |
| **Authentication** | `API_KEY` |
| **Schema** | Inline SDL — 1 type (`Todo`), 2 queries, 3 mutations |
| **Field-level logging** | `ERROR` level (configurable via `log_level` variable) |
| **Verbose content excluded** | Yes — request/response bodies omitted from logs |
| **CloudWatch role** | Separate IAM role with `logs:CreateLogGroup/Stream/PutLogEvents` |

### 2. API Key

| Attribute | Value |
|-----------|-------|
| **Header name** | `x-api-key` |
| **Default expiry** | `2027-01-01T00:00:00Z` (configurable via `api_key_expires`) |
| **Rotation** | Manual — update `api_key_expires` variable and re-apply |
| **Scope** | All operations on this API |

> For production, switch authentication to `AMAZON_COGNITO_USER_POOLS` or `AWS_IAM` to gain per-user identity and fine-grained access control.

### 3. DynamoDB Table

| Attribute | Value |
|-----------|-------|
| **Table name** | `graphql-appsync-todo-todos` |
| **Partition key** | `id` (String) |
| **Sort key** | None |
| **Capacity mode** | On-demand (`PAY_PER_REQUEST`) |
| **Point-in-time recovery** | Enabled (35-day window) |
| **Deletion protection** | Disabled (enable for production) |
| **Encryption** | AWS-managed default encryption at rest |

### 4. DynamoDB Data Source

| Attribute | Value |
|-----------|-------|
| **Name** | `TodosDynamoDB` |
| **Type** | `AMAZON_DYNAMODB` |
| **IAM role** | `graphql-appsync-todo-appsync-dynamodb-role` |
| **Permissions** | `PutItem`, `GetItem`, `UpdateItem`, `DeleteItem`, `Scan`, `Query` on Todos table only |

### 5. VTL Resolvers

| Field | Template version | DynamoDB op | Key expression |
|-------|-----------------|------------|----------------|
| `Query.getTodos` | 2018-05-29 | `Scan` | — |
| `Query.getTodo` | 2018-05-29 | `GetItem` | `id = args.id` |
| `Mutation.addTodo` | 2018-05-29 | `PutItem` | `id = $util.autoId()` |
| `Mutation.updateTodo` | 2018-05-29 | `UpdateItem` | `id = args.id` |
| `Mutation.deleteTodo` | 2018-05-29 | `DeleteItem` | `id = args.id` |

> `updateTodo` and `deleteTodo` include a `condition: attribute_exists(id)` guard. AppSync converts a `ConditionalCheckFailedException` into a GraphQL error — no item is silently overwritten or created.

### 6. IAM Roles

| Role | Trust Principal | Permissions |
|------|----------------|-------------|
| `appsync-dynamodb-role` | `appsync.amazonaws.com` | DynamoDB: PutItem, GetItem, UpdateItem, DeleteItem, Scan, Query on Todos table ARN |
| `appsync-logs-role` | `appsync.amazonaws.com` | CloudWatch Logs: CreateLogGroup, CreateLogStream, PutLogEvents on `arn:aws:logs:*:*:*` |

### 7. CloudWatch Alarms

| Alarm | Metric | Threshold | Evaluation |
|-------|--------|-----------|------------|
| `graphql-appsync-todo-5xx-errors` | `5XXError` Sum | > 10 / minute | 1 period |
| `graphql-appsync-todo-4xx-errors` | `4XXError` Sum | > 50 / minute | 1 period |
| `graphql-appsync-todo-high-latency` | `Latency` p99 | > 1000 ms | 3 consecutive periods |

> All alarms use `treat_missing_data = notBreaching` — a quiet API will not self-alarm.

---

## Directory Structure

```
GraphQL API with AWS AppSync/
├── README.md                          # This file
├── terraform/
│   ├── provider.tf                    # AWS provider, Terraform settings, common locals
│   ├── variables.tf                   # All input variables with validation
│   ├── dynamodb.tf                    # DynamoDB Todos table (on-demand + PITR)
│   ├── iam.tf                         # 2 IAM roles + 2 inline policies
│   ├── appsync.tf                     # GraphQL API, API key, data source, 5 resolvers
│   ├── cloudwatch.tf                  # Log group + 3 metric alarms
│   └── outputs.tf                     # 9 output values
└── scripts/
    └── test_architecture.sh           # 12-check architecture validation script
```

---

## Prerequisites

| Tool | Minimum Version | Install |
|------|----------------|---------|
| **Terraform** | 1.9+ | [developer.hashicorp.com/terraform](https://developer.hashicorp.com/terraform/install) |
| **AWS CLI** | 2.0+ | [aws.amazon.com/cli](https://aws.amazon.com/cli/) |
| **jq** | 1.6+ | `brew install jq` |
| **curl** | 7.68+ | Pre-installed on macOS/Linux |
| **bash** | 4.0+ | Pre-installed; use `brew install bash` on macOS for v5 |

**Account requirements:**

- IAM permissions: `appsync:*`, `dynamodb:*`, `iam:*`, `logs:*`, `cloudwatch:*`
- AWS AppSync available in your target region
- No VPC, NAT gateway, or EC2 quota required

---

## Quick Start

```bash
# 1. Navigate to the Terraform directory
cd "GraphQL API with AWS AppSync/terraform"

# 2. Confirm AWS identity
aws sts get-caller-identity

# 3. Initialise providers
terraform init

# 4. Preview the deployment (10 resources)
terraform plan

# 5. Deploy — allow 2-3 minutes
terraform apply

# 6. Retrieve the GraphQL endpoint and API key
terraform output appsync_api_url
terraform output -raw appsync_api_key

# 7. Test — add a todo
API_URL=$(terraform output -raw appsync_api_url)
API_KEY=$(terraform output -raw appsync_api_key)

curl -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d '{"query":"mutation { addTodo(title: \"My first todo\") { id title completed } }"}'

# 8. Query all todos
curl -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d '{"query":"query { getTodos { id title completed } }"}'

# 9. Run the architecture validation script
cd ..
bash scripts/test_architecture.sh
```

Allow 2-3 minutes for AppSync to provision and for the API key to activate.

---

## Input Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `aws_region` | `string` | `"us-east-1"` | AWS region for all resources |
| `project_name` | `string` | `"graphql-appsync-todo"` | Prefix applied to all resource names |
| `environment` | `string` | `"dev"` | Deployment environment (`dev`, `staging`, `prod`) |
| `log_level` | `string` | `"ERROR"` | AppSync field-level log verbosity (`NONE`, `ERROR`, `ALL`) |
| `api_key_expires` | `string` | `"2027-01-01T00:00:00Z"` | API key expiry in RFC 3339 format (max 365 days from creation) |
| `cloudwatch_retention_days` | `number` | `30` | Log group retention in days |
| `alarm_5xx_threshold` | `number` | `10` | 5XX errors per minute before alarm fires |
| `alarm_4xx_threshold` | `number` | `50` | 4XX errors per minute before alarm fires |
| `alarm_latency_p99_ms` | `number` | `1000` | p99 latency in ms before latency alarm fires |

**Validation rules:**
- `environment` must be one of `dev`, `staging`, `prod`
- `log_level` must be one of `NONE`, `ERROR`, `ALL`
- `cloudwatch_retention_days` must be a valid CloudWatch retention value (1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653)

---

## Outputs

| Output | Description |
|--------|-------------|
| `appsync_api_url` | GraphQL endpoint — use this as the POST target |
| `appsync_api_id` | AppSync API ID — required for AWS CLI commands |
| `appsync_api_arn` | AppSync API ARN |
| `appsync_api_key` | API key value (sensitive) — pass in `x-api-key` header |
| `appsync_api_key_id` | API key identifier |
| `dynamodb_table_name` | DynamoDB table name |
| `dynamodb_table_arn` | DynamoDB table ARN |
| `cloudwatch_log_group` | CloudWatch log group name |
| `region` | Deployed AWS region |

```bash
# Print all non-sensitive outputs
terraform output

# Print the API key (sensitive)
terraform output -raw appsync_api_key
```

---

## Scaling Behaviour

AWS AppSync scales transparently — there are no instances, ASGs, or capacity settings to tune. The DynamoDB table uses on-demand capacity and also scales automatically.

```
Request Throughput (RPS)
│
300K ─────────────────────────────────────── AppSync default account limit
│                                            (request increase via Support)
│
50K ──────────────────────────────────────── Typical burst headroom (no config)
│
10K ──────────────────────────────────────── DynamoDB on-demand burst capacity
│
1K ───────────────────────────────────────── Normal sustained load
│
1 ────────────────────────────────────────── Baseline (zero idle cost)
└────────────────────────────────────────────► Time
         Cold start    Sustained   Burst     Throttle
         (<10ms)       (linear)    (absorb)  (429)
```

**Key scaling notes:**

- AppSync has no warm-up or cold-start latency at the API layer
- DynamoDB on-demand handles traffic spikes without manual capacity planning; throughput is capped at 2× the previous peak until a new peak is established
- The `getTodos` resolver uses a `Scan` — for large tables (> 1 MB) it will paginate; add a `limit` and `nextToken` argument pair for production use
- Rate limiting at the AppSync layer returns HTTP 429; DynamoDB throttling surfaces as a resolver error with `DynamoDB:ProvisionedThroughputExceededException`

---

## Tagging Strategy

| Tag Key | Value | Applied To |
|---------|-------|------------|
| `Project` | `GraphQL API with AWS AppSync` | All resources |
| `Environment` | `var.environment` | All resources |
| `ManagedBy` | `Terraform` | All resources |
| `Name` | Resource-specific name | DynamoDB table, CloudWatch log group, AppSync API |

> CloudWatch alarms and IAM policies inherit the `common_tags` local but do not support the `Name` tag at the policy level — it is applied at the role level only.

---

## Security Considerations

| Topic | Current Posture | Recommended Hardening |
|-------|----------------|----------------------|
| **Authentication** | API key in `x-api-key` header | Switch to Cognito User Pools or AWS IAM for user-level identity; API keys are suitable for dev/public read-only APIs only |
| **API key storage** | Stored in Terraform state (`sensitive = true`) | Store key in AWS Secrets Manager; retrieve at runtime |
| **IAM scope** | DynamoDB role scoped to single table ARN | Already least-privilege; add resource-based conditions if multiple tables added |
| **CloudWatch logs** | `ERROR` level only; verbose content excluded | Use `ALL` level in dev to debug resolver logic; keep `ERROR` in prod to avoid logging PII |
| **DynamoDB encryption** | AWS-managed default key | Replace with a customer-managed KMS key (`aws:kms`) for compliance requirements |
| **PITR** | Enabled (35-day window) | Enable DynamoDB deletion protection for production tables |
| **HTTPS** | TLS enforced by AppSync | No additional configuration needed; AppSync does not serve HTTP |
| **Input validation** | GraphQL type system enforces `String!`, `Boolean!`, `ID!` | Add a WAF ACL to the AppSync API for rate limiting and IP-based rules |
| **Scan exposure** | `getTodos` scans entire table | Restrict with a `filter` argument and add a GSI for indexed queries in production |

---

## Cost Estimate

All pricing is `us-east-1`, pay-as-you-go. No resources incur a standing hourly charge.

| Resource | Quantity (1M ops/month) | Unit Price | Monthly Cost (USD) |
|----------|------------------------|------------|-------------------|
| AppSync — query & mutation ops | 1,000,000 | $4.00 / million | $4.00 |
| DynamoDB on-demand reads | 1,000,000 RRU | $0.25 / million | $0.25 |
| DynamoDB on-demand writes | 500,000 WRU | $1.25 / million | $0.63 |
| CloudWatch Logs ingestion | 0.5 GB | $0.50 / GB | $0.25 |
| CloudWatch Alarms | 3 | $0.10 / alarm | $0.30 |
| **Total** | | | **~$5.43** |

**Free tier offsets (12-month new accounts):**
- AppSync: 250,000 query/mutation ops and 250,000 real-time updates free per month
- DynamoDB: 25 GB storage, 200M requests free per month

At free-tier scale this project costs approximately **$0/month**.

For cost estimates at higher scale, see the [AWS Pricing Calculator](https://calculator.aws/pricing/2/home).

---

## Destroying the Stack

```bash
cd "GraphQL API with AWS AppSync/terraform"

# Preview what will be destroyed
terraform plan -destroy

# Destroy all 10 resources
terraform destroy
```

**Resources destroyed by Terraform:**
- AppSync GraphQL API, API key, data source, 5 resolvers
- DynamoDB Todos table (all data permanently deleted)
- IAM roles and inline policies
- CloudWatch log group (log data deleted after retention period)
- CloudWatch metric alarms

**Resources NOT managed by Terraform (survive `destroy`):**
- CloudWatch log streams and events within the log group (deleted by the retention policy on schedule)
- Any DynamoDB backups triggered manually via PITR before destroy

> There is no deletion protection on the DynamoDB table by default. `terraform destroy` will permanently delete all todo data. Enable `deletion_protection_enabled = true` in `dynamodb.tf` for production.

---

## Frequently Asked Questions

**Q: I ran `terraform apply` but get a 403 when calling the API. What's wrong?**

A: The most common cause is an incorrect or missing `x-api-key` header. Retrieve the key with `terraform output -raw appsync_api_key` and confirm you are passing it in the header, not as a query parameter. Also verify the key has not expired by checking `terraform output appsync_api_key_id` against `aws appsync list-api-keys --api-id <id>`.

**Q: `getTodos` returns an empty list even after `addTodo` succeeded. Why?**

A: Both operations write to and read from the same DynamoDB table; there is no eventual-consistency lag for a `Scan` on a strongly-consistent table by default. The most likely cause is that `addTodo` returned an error that was silently ignored — check the raw `curl` response for an `errors` key. Also confirm the data source is attached to the `getTodos` resolver by running `aws appsync list-resolvers --api-id <id> --type-name Query`.

**Q: How do I add real-time subscriptions?**

A: Add a `Subscription` type to the schema:
```graphql
type Subscription {
  onAddTodo: Todo @aws_subscribe(mutations: ["addTodo"])
}
```
Update `schema { subscription: Subscription }` and add `"subscription"` to the `aws_appsync_graphql_api` `authentication_type` list or enable `additional_authentication_provider`. No resolver is required — AppSync handles WebSocket connections automatically. Connect clients using the `wss://` endpoint printed in the `REALTIME` URI map.

**Q: How do I update the app code (schema and resolvers)?**

A: Edit the `schema` string in `appsync.tf` and the VTL templates in the resolver resources, then run `terraform apply`. AppSync applies schema changes atomically. Note that removing or renaming a type that has an attached resolver will cause Terraform to destroy and recreate the resolver.

**Q: Can I use this without a frontend?**

A: Yes. The AppSync GraphQL Explorer in the AWS Console lets you run any query or mutation interactively against the live API. Navigate to AppSync → your API → Queries. For scripted access, use `curl` with the `x-api-key` header as shown in the Quick Start.

**Q: Why does `updateTodo` return an error for a non-existent ID?**

A: The resolver includes a `condition: { expression: "attribute_exists(id)" }` guard. AppSync converts the resulting `ConditionalCheckFailedException` from DynamoDB into a GraphQL error response. This prevents silent upserts — attempting to update an ID that does not exist returns a descriptive error rather than creating a new item.

**Q: Why is `getTodos` using `Scan` instead of `Query`?**

A: The Todos table has only a partition key (`id`). DynamoDB `Query` requires a sort key or a Global Secondary Index (GSI) to filter efficiently. For a production app with many todos, add a GSI on a user ID or status attribute and rewrite the resolver to use `Query` with a `KeyConditionExpression`. The `Scan` in this project is appropriate for a demo with a small number of items.

**Q: How do I switch from API key to Cognito authentication?**

A: Change `authentication_type = "API_KEY"` to `"AMAZON_COGNITO_USER_POOLS"` in `appsync.tf`, add a `user_pool_config` block with your Cognito User Pool ARN and default action, and remove the `aws_appsync_api_key` resource. Clients then pass a Cognito JWT in the `Authorization` header instead of `x-api-key`.
