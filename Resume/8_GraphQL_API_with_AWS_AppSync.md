# GraphQL API with AWS AppSync — Resume Summary

## Project Overview

A fully serverless GraphQL backend built on AWS AppSync and Amazon DynamoDB, provisioned end to end with Terraform. The API (`graphql-appsync-todo-api`) exposes a small Todo schema — one `Todo` type, two queries (`getTodos`, `getTodo`) and three mutations (`addTodo`, `updateTodo`, `deleteTodo`) — each backed by a UNIT VTL resolver that maps the GraphQL operation directly onto a DynamoDB API call (`Scan`, `GetItem`, `PutItem`, `UpdateItem`, `DeleteItem`) with no Lambda in the path. Clients authenticate with an API key in the `x-api-key` header; AppSync reaches the on-demand, PITR-enabled `graphql-appsync-todo-todos` table through a table-scoped IAM role, writes field-level logs to CloudWatch through a separate logs role, and three metric alarms watch 5XX, 4XX, and p99 latency. There is no VPC, EC2, or load balancer. The stack was deployed and audited on 2026-06-23 to account `022499047467` in `us-east-1` (`dev` environment): all **17 Terraform-managed resources** were created, the table was `ACTIVE`, all five resolvers were active, and all three alarms were in `OK` state.

## Architecture

```
                        Client (HTTPS / wss)
                                 │  POST /graphql
                                 │  x-api-key: da2-...
                                 ▼
┌────────────────────────────────────────────────────────────────┐
│  AWS AppSync  graphql-appsync-todo-api                         │
│  ID nimn7y7g7nhfhcrsa6dfnvkjtq  ·  auth API_KEY                │
│                                                                │
│  ┌──────────────────────┐        ┌──────────────────────────┐  │
│  │ Query                │        │ Mutation                 │  │
│  │  getTodos  → Scan    │        │  addTodo    → PutItem    │  │
│  │  getTodo   → GetItem │        │  updateTodo → UpdateItem │  │
│  └──────────┬───────────┘        │  deleteTodo → DeleteItem │  │
│             │                    └────────────┬─────────────┘  │
│             └──────────────┬──────────────────┘                │
│                            ▼                                   │
│           VTL resolvers (UNIT, 2018-05-29)                     │
│           data source TodosDynamoDB                            │
└────────────────────────────┬───────────────────────────────────┘
                             │ IAM role appsync-dynamodb-role
                             ▼
┌────────────────────────────────────────────────────────────────┐
│  DynamoDB  graphql-appsync-todo-todos                          │
│  PK id (S)  ·  PAY_PER_REQUEST  ·  PITR enabled                │
└────────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌────────────────────────────────────────────────────────────────┐
│  CloudWatch   (via appsync-logs-role)                          │
│  /aws/appsync/apis/nimn7y7g7nhfhcrsa6dfnvkjtq  · 30-day        │
│  ├── 5XXError  > 10 / 1 min                                    │
│  ├── 4XXError  > 50 / 1 min                                    │
│  └── Latency p99 > 1000 ms / 3 min                             │
└────────────────────────────────────────────────────────────────┘
```

## Technology Stack

| Layer | Technology | Purpose |
|---|---|---|
| **API** | AWS AppSync (GraphQL, `API_KEY` auth) | Managed HTTPS GraphQL endpoint; inline SDL schema |
| **Resolvers** | Apache VTL mapping templates (UNIT, `2018-05-29`) | Direct GraphQL-to-DynamoDB mapping with no Lambda |
| **Database** | Amazon DynamoDB (on-demand) | `graphql-appsync-todo-todos`, partition key `id`, PITR enabled |
| **Identity** | AWS IAM (2 service roles, `appsync.amazonaws.com` trust) | Table-scoped data role + separate CloudWatch Logs role |
| **Observability** | CloudWatch Logs + 3 metric alarms | Field-level logs at `ERROR`, verbose content excluded; 5XX / 4XX / p99 latency alarms |
| **IaC** | Terraform `>= 1.9` (AWS provider `~> 5.0`) | 17 resources across 7 `.tf` files; `common_tags` local |
| **Testing** | Bash + AWS CLI + `jq` + `curl` | `scripts/test_architecture.sh` infrastructure checks plus live GraphQL CRUD calls |

## Key Achievements

- **Full CRUD with zero compute** — five VTL resolvers translate GraphQL directly into DynamoDB calls, so there is no Lambda to package, cold-start, or pay for.
- **Mutations cannot silently upsert** — `updateTodo` and `deleteTodo` carry a `condition: attribute_exists(id)` guard; AppSync turns the resulting `ConditionalCheckFailedException` into a GraphQL error instead of creating a new item.
- **Server-generated IDs** — `addTodo` assigns `id` with `$util.autoId()` in the request template and defaults `completed` to `false`.
- **Least-privilege data access** — the DynamoDB role's six actions are scoped to the single table ARN; logging runs under a separate role.
- **Durable by default** — point-in-time recovery enabled (35-day window, confirmed in the audit).
- **Quiet-safe alarms** — all three alarms use `treat_missing_data = notBreaching`, so an idle API stays `OK`; the audit confirmed `OK` on all three.
- **Validated inputs** — Terraform validation on `environment` (`dev`/`staging`/`prod`), `log_level` (`NONE`/`ERROR`/`ALL`), and `cloudwatch_retention_days` (valid CloudWatch values only).
- **Deployed and audited** — 17 resources live on 2026-06-23 with IDs, ARNs, and state recorded in `Result.md`.

## Infrastructure Components

| Component | Count | Details |
|---|---|---|
| **AppSync GraphQL API** | 1 | `graphql-appsync-todo-api` (`nimn7y7g7nhfhcrsa6dfnvkjtq`), `API_KEY`, visibility `GLOBAL`, introspection enabled, X-Ray disabled |
| **AppSync API key** | 1 | `da2-nxyuesz5mbb5fa7tilb6dagwp4`, expires `2027-01-01T00:00:00Z` |
| **AppSync data source** | 1 | `TodosDynamoDB`, type `AMAZON_DYNAMODB` |
| **AppSync resolvers** | 5 | `Query.getTodos`, `Query.getTodo`, `Mutation.addTodo`, `Mutation.updateTodo`, `Mutation.deleteTodo` |
| **DynamoDB table** | 1 | `graphql-appsync-todo-todos`, `PAY_PER_REQUEST`, PK `id` (S), PITR on, deletion protection off |
| **IAM roles** | 2 | `graphql-appsync-todo-appsync-dynamodb-role` (`AROAQKPIMHAV6ECPRRBF7`), `graphql-appsync-todo-appsync-logs-role` (`AROAQKPIMHAV7RLZQ3PBV`) |
| **IAM inline policies** | 2 | `graphql-appsync-todo-dynamodb-access`, `graphql-appsync-todo-cloudwatch-logs-access` |
| **CloudWatch log group** | 1 | `/aws/appsync/apis/nimn7y7g7nhfhcrsa6dfnvkjtq`, 30-day retention |
| **CloudWatch alarms** | 3 | `graphql-appsync-todo-5xx-errors`, `-4xx-errors`, `-high-latency` |
| **Total** | **17** | Terraform-managed (matches `Result.md`) |

## Deployment Issues Diagnosed & Resolved

No deployment issues are recorded in the project sources — `Result.md` documents a clean deployment of all 17 resources, and there is no troubleshooting log in the folder. The README's FAQ does document the failure modes the design anticipates:

| Issue | Root cause | Fix |
|---|---|---|
| No deployment issues recorded | — | — |
| *(documented failure mode)* `403` when calling the API | Missing or incorrect `x-api-key` header, or an expired key | Retrieve the key with `terraform output -raw appsync_api_key`; check expiry with `aws appsync list-api-keys --api-id <id>` |
| *(documented failure mode)* `updateTodo` / `deleteTodo` error for an unknown `id` | `attribute_exists(id)` condition fails by design | Expected behaviour — prevents silent upserts; returns a GraphQL error |
| *(documented failure mode)* `getTodos` empty after `addTodo` | `addTodo` returned an `errors` payload that was ignored, or resolver not attached | Inspect the raw response for `errors`; confirm with `aws appsync list-resolvers --api-id <id> --type-name Query` |

## Test Results

`Result.md` is a live-resource audit (2026-06-23) and is the recorded evidence below. `scripts/test_architecture.sh` is organised into 7 sections with 16 `pass` assertion points (11 infrastructure + 5 live GraphQL operations); the project and root READMEs describe it as a "12-check" script. No run output from the script is saved in the repository, so the live GraphQL rows show what the script tests, not a recorded pass count.

| Check | Scope | Recorded result |
|---|---|---|
| Terraform-managed resources | State / `Result.md` inventory | 17 resources created |
| AppSync API | `graphql-appsync-todo-api`, `API_KEY` auth | Present (`Result.md`) |
| Resolvers | 2 Query + 3 Mutation, UNIT, `TodosDynamoDB` | All 5 `Active` (`Result.md`) |
| API key | `da2-nxyuesz5mbb5fa7tilb6dagwp4` | Active, expires 2027-01-01 (`Result.md`) |
| DynamoDB table | `graphql-appsync-todo-todos` | `ACTIVE`, `PAY_PER_REQUEST` (`Result.md`) |
| Point-in-time recovery | Todos table | `ENABLED`, 35-day window (`Result.md`) |
| IAM roles | DynamoDB role + logs role | Both present (`Result.md`) |
| CloudWatch log group | `/aws/appsync/apis/<id>`, 30-day | Present, 0 bytes stored (`Result.md`) |
| CloudWatch alarms | 5XX, 4XX, p99 latency | All 3 `OK` (`Result.md`) |
| Live `addTodo` / `getTodos` / `getTodo` / `updateTodo` / `deleteTodo` | Section 7 of the test script | Defined in script; run output not recorded |

## Quick Start

```bash
# 1. Deploy
cd "GraphQL API with AWS AppSync/terraform"
aws sts get-caller-identity
terraform init
terraform plan
terraform apply

# 2. Capture endpoint and key
API_URL=$(terraform output -raw appsync_api_url)
API_KEY=$(terraform output -raw appsync_api_key)

# 3. Create a todo, then list all todos
curl -X POST "$API_URL" -H "Content-Type: application/json" -H "x-api-key: $API_KEY" \
  -d '{"query":"mutation { addTodo(title: \"My first todo\") { id title completed } }"}'
curl -X POST "$API_URL" -H "Content-Type: application/json" -H "x-api-key: $API_KEY" \
  -d '{"query":"query { getTodos { id title completed } }"}'

# 4. Run the architecture validation script
cd ..
bash scripts/test_architecture.sh
```

> Allow 2-3 minutes for AppSync to provision and for the API key to activate.

## Cost Estimate

All pricing `us-east-1`, pay-per-request; no resource has a standing hourly charge. Figures from the project `README.md` at 1M operations/month.

| Resource | Quantity (1M ops/month) | Monthly Cost (USD) |
|---|---|---|
| AppSync query and mutation operations | 1,000,000 | $4.00 |
| DynamoDB on-demand reads | 1,000,000 RRU | $0.25 |
| DynamoDB on-demand writes | 500,000 WRU | $0.63 |
| CloudWatch Logs ingestion | 0.5 GB | $0.25 |
| CloudWatch alarms | 3 | $0.30 |
| **Total** | | **~$5.43 / month** |

> At the audited dev/low-traffic level, `Result.md` estimates ~$0.30/month (the three alarms only). Free tier covers 250,000 AppSync operations per month for new accounts.

## Security Posture

| Topic | Posture |
|---|---|
| Authentication | Shared API key (`x-api-key`); Cognito User Pools or `AWS_IAM` recommended for production |
| API key lifecycle | Expires `2027-01-01T00:00:00Z`; manual rotation via `api_key_expires`; key value held in state as a `sensitive` output |
| Transport | HTTPS only, AWS-managed TLS; AppSync does not serve HTTP |
| Data-plane IAM | DynamoDB role scoped to the single table ARN (6 actions) |
| Logs-plane IAM | Logs role allows `CreateLogGroup/Stream/PutLogEvents` on `arn:aws:logs:*:*:*` — broader than needed |
| Logging | `ERROR` level with `exclude_verbose_content = true`, keeping request/response bodies out of logs |
| Encryption at rest | DynamoDB default AWS-owned key; CMK recommended for compliance workloads |
| Data protection | PITR on; deletion protection off (`deletion_protection_enabled = false`) |
| Alerting | 3 alarms configured with no `alarm_actions` (no SNS target) |
| Tracing | X-Ray disabled |

## Project Structure

```
GraphQL API with AWS AppSync/
├── README.md                    # Full documentation (14 sections, 8 FAQs)
├── Result.md                    # Live deployment audit (2026-06-23, 17 resources)
├── scripts/
│   └── test_architecture.sh     # 7-section infra checks + live GraphQL CRUD tests
└── terraform/
    ├── provider.tf              # Terraform >= 1.9, AWS ~> 5.0, common_tags local
    ├── variables.tf             # 9 input variables (3 with validation)
    ├── dynamodb.tf              # On-demand Todos table + PITR
    ├── iam.tf                   # 2 IAM roles + 2 inline policies
    ├── appsync.tf               # API + inline schema, API key, data source, 5 VTL resolvers
    ├── cloudwatch.tf            # Log group + 3 metric alarms
    └── outputs.tf               # 9 outputs (URL, IDs, ARNs, key, table, log group, region)
```

## Key Learnings & Technical Decisions

**Skip the Lambda when the resolver is just a mapping.** Every operation in this API is a single DynamoDB call, so VTL request/response templates are enough. Removing the Lambda removes cold starts, a deployment artifact, and a per-invocation cost, and leaves AppSync plus DynamoDB as the only moving parts.

**Put integrity rules in the resolver, not the client.** A plain `UpdateItem` or `DeleteItem` on a missing key would silently create or no-op. The `attribute_exists(id)` condition makes a bad ID an explicit GraphQL error, and `$util.autoId()` keeps ID generation on the server.

**Separate the data role from the logging role.** AppSync assumes one role to reach DynamoDB (scoped to one table ARN) and a different role to write CloudWatch Logs, so a change to logging permissions can never widen data access.

**Design alarms for a quiet API.** A dev API sees long idle periods; `treat_missing_data = notBreaching` keeps the alarms `OK` when there is no traffic, and the p99 latency alarm requires three consecutive breaching minutes to avoid flapping on a single slow request.

**`Scan` is a demo shortcut, not a pattern.** With only a partition key, `getTodos` must `Scan`. The README documents the production path: add a GSI (for example on a user or status attribute) and move the resolver to `Query` with pagination (`limit` / `nextToken`).

## What I'd Do Differently

- **Replace API-key auth with Cognito User Pools or `AWS_IAM`** for per-user identity.
- **Scope the logs role** from `arn:aws:logs:*:*:*` to the API's log group ARN.
- **Escape user input in `addTodo`.** The request template interpolates `"$ctx.args.title"` directly into JSON; using `$util.dynamodb.toDynamoDBJson($ctx.args.title)` would make quotes in a title safe.
- **Attach an SNS topic to the alarms** and enable X-Ray, so alarms notify someone and resolver latency is traceable.
- **Paginate `getTodos` and add a GSI** before the table grows beyond demo size.
- **Save the test-script output alongside `Result.md`** and reconcile the documented "12 checks" with the script's actual assertions; also correct the README's "10 resources" in the plan/destroy steps to the audited 17.
- **Enable deletion protection and a customer-managed KMS key** for any non-dev environment.

## Summary

This project delivers a compact, fully managed GraphQL backend: an AppSync API with an inline schema, five VTL resolvers performing full CRUD directly against an on-demand DynamoDB table, condition guards that prevent silent upserts, separate least-privilege roles for data and logging, and CloudWatch logging plus three alarms — with no servers, VPC, or Lambda. It was deployed with Terraform on 2026-06-23 to `us-east-1`, and the `Result.md` audit confirms all 17 resources live, all five resolvers active, PITR enabled, and all alarms `OK`. Estimated cost is ~$5.43/month at 1M operations and about $0.30/month at dev traffic levels.
