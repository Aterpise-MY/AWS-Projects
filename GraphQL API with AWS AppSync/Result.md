# Deployment Result — GraphQL API with AWS AppSync

**Date:** 2026-06-23
**Region:** us-east-1
**Environment:** dev
**Account:** 022499047467

---

## All AWS Resources Created

| # | Resource Type | Name / ID | ARN |
|---|---|---|---|
| 1 | AppSync GraphQL API | `graphql-appsync-todo-api` / `nimn7y7g7nhfhcrsa6dfnvkjtq` | `arn:aws:appsync:us-east-1:022499047467:apis/nimn7y7g7nhfhcrsa6dfnvkjtq` |
| 2 | AppSync API Key | `da2-nxyuesz5mbb5fa7tilb6dagwp4` | — |
| 3 | AppSync Data Source | `TodosDynamoDB` | `arn:aws:appsync:us-east-1:022499047467:apis/nimn7y7g7nhfhcrsa6dfnvkjtq/datasources/TodosDynamoDB` |
| 4 | AppSync Resolver | `Query.getTodos` | `arn:aws:appsync:us-east-1:022499047467:apis/nimn7y7g7nhfhcrsa6dfnvkjtq/types/Query/resolvers/getTodos` |
| 5 | AppSync Resolver | `Query.getTodo` | `arn:aws:appsync:us-east-1:022499047467:apis/nimn7y7g7nhfhcrsa6dfnvkjtq/types/Query/resolvers/getTodo` |
| 6 | AppSync Resolver | `Mutation.addTodo` | `arn:aws:appsync:us-east-1:022499047467:apis/nimn7y7g7nhfhcrsa6dfnvkjtq/types/Mutation/resolvers/addTodo` |
| 7 | AppSync Resolver | `Mutation.updateTodo` | `arn:aws:appsync:us-east-1:022499047467:apis/nimn7y7g7nhfhcrsa6dfnvkjtq/types/Mutation/resolvers/updateTodo` |
| 8 | AppSync Resolver | `Mutation.deleteTodo` | `arn:aws:appsync:us-east-1:022499047467:apis/nimn7y7g7nhfhcrsa6dfnvkjtq/types/Mutation/resolvers/deleteTodo` |
| 9 | DynamoDB Table | `graphql-appsync-todo-todos` / `7eea4318-55dc-4fb7-a25b-77d669a672f9` | `arn:aws:dynamodb:us-east-1:022499047467:table/graphql-appsync-todo-todos` |
| 10 | IAM Role | `graphql-appsync-todo-appsync-dynamodb-role` / `AROAQKPIMHAV6ECPRRBF7` | `arn:aws:iam::022499047467:role/graphql-appsync-todo-appsync-dynamodb-role` |
| 11 | IAM Role | `graphql-appsync-todo-appsync-logs-role` / `AROAQKPIMHAV7RLZQ3PBV` | `arn:aws:iam::022499047467:role/graphql-appsync-todo-appsync-logs-role` |
| 12 | IAM Role Policy | `graphql-appsync-todo-dynamodb-access` | — |
| 13 | IAM Role Policy | `graphql-appsync-todo-cloudwatch-logs-access` | — |
| 14 | CloudWatch Log Group | `/aws/appsync/apis/nimn7y7g7nhfhcrsa6dfnvkjtq` | `arn:aws:logs:us-east-1:022499047467:log-group:/aws/appsync/apis/nimn7y7g7nhfhcrsa6dfnvkjtq` |
| 15 | CloudWatch Alarm | `graphql-appsync-todo-4xx-errors` | `arn:aws:cloudwatch:us-east-1:022499047467:alarm:graphql-appsync-todo-4xx-errors` |
| 16 | CloudWatch Alarm | `graphql-appsync-todo-5xx-errors` | `arn:aws:cloudwatch:us-east-1:022499047467:alarm:graphql-appsync-todo-5xx-errors` |
| 17 | CloudWatch Alarm | `graphql-appsync-todo-high-latency` | `arn:aws:cloudwatch:us-east-1:022499047467:alarm:graphql-appsync-todo-high-latency` |

**Total: 17 Terraform-managed resources**

---

## Key Outputs

| Output | Value |
|---|---|
| `appsync_api_id` | `nimn7y7g7nhfhcrsa6dfnvkjtq` |
| `appsync_api_arn` | `arn:aws:appsync:us-east-1:022499047467:apis/nimn7y7g7nhfhcrsa6dfnvkjtq` |
| `appsync_api_url` | `https://znnj45kpyjcwffqhop3nkk4ana.appsync-api.us-east-1.amazonaws.com/graphql` |
| `appsync_api_key` | *(sensitive — retrieve with `terraform output -raw appsync_api_key`)* |
| `appsync_api_key_id` | `nimn7y7g7nhfhcrsa6dfnvkjtq:da2-nxyuesz5mbb5fa7tilb6dagwp4` |
| `dynamodb_table_name` | `graphql-appsync-todo-todos` |
| `dynamodb_table_arn` | `arn:aws:dynamodb:us-east-1:022499047467:table/graphql-appsync-todo-todos` |
| `cloudwatch_log_group` | `/aws/appsync/apis/nimn7y7g7nhfhcrsa6dfnvkjtq` |
| `region` | `us-east-1` |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Client (HTTP/WSS)                        │
└────────────────────────────┬────────────────────────────────────┘
                             │  HTTPS POST /graphql
                             │  wss:// (Realtime subscriptions)
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│              AWS AppSync  (API_KEY auth)                        │
│         graphql-appsync-todo-api                                │
│         ID: nimn7y7g7nhfhcrsa6dfnvkjtq                         │
│                                                                 │
│  Schema:                                                        │
│    Query   ─── getTodos, getTodo                                │
│    Mutation ── addTodo, updateTodo, deleteTodo                  │
│                                                                 │
│  Resolvers (VTL, UNIT kind) ──► Data Source: TodosDynamoDB      │
└────────────────────────────┬────────────────────────────────────┘
                             │  IAM Role: appsync-dynamodb-role
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│              Amazon DynamoDB                                    │
│         Table: graphql-appsync-todo-todos                       │
│         Billing: PAY_PER_REQUEST  │  PITR: ENABLED              │
│         Hash Key: id (S)                                        │
└─────────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│              Amazon CloudWatch                                  │
│         Log Group: /aws/appsync/apis/nimn7y7g7nhfhcrsa6dfnvkjtq│
│         Retention: 30 days  │  Role: appsync-logs-role          │
│                                                                 │
│  Alarms:                                                        │
│    ├── 4XXError  > 50 / 1 min   → OK                           │
│    ├── 5XXError  > 10 / 1 min   → OK                           │
│    └── Latency p99 > 1000ms / 3 min → OK                       │
└─────────────────────────────────────────────────────────────────┘
```

**Traffic flow:** Client sends GraphQL query/mutation over HTTPS to AppSync endpoint → AppSync authenticates via API key → resolves field using VTL mapping template → calls DynamoDB `TodosDynamoDB` data source via IAM role → returns JSON result. Errors and latency metrics are emitted to CloudWatch with three alarms monitoring health.

---

## AppSync API Status

| Property | Value |
|---|---|
| API Name | `graphql-appsync-todo-api` |
| API ID | `nimn7y7g7nhfhcrsa6dfnvkjtq` |
| Authentication | `API_KEY` |
| Visibility | `GLOBAL` |
| Introspection | `ENABLED` |
| GraphQL URL | `https://znnj45kpyjcwffqhop3nkk4ana.appsync-api.us-east-1.amazonaws.com/graphql` |
| Realtime URL | `wss://znnj45kpyjcwffqhop3nkk4ana.appsync-realtime-api.us-east-1.amazonaws.com/graphql` |
| X-Ray Tracing | `Disabled` |
| Log Level | `ERROR` |
| Exclude Verbose Content | `true` |

---

## Resolvers Status

| Type | Field | Data Source | Kind | Operation | Status |
|---|---|---|---|---|---|
| Query | `getTodos` | `TodosDynamoDB` | UNIT | `Scan` | Active |
| Query | `getTodo` | `TodosDynamoDB` | UNIT | `GetItem` | Active |
| Mutation | `addTodo` | `TodosDynamoDB` | UNIT | `PutItem` | Active |
| Mutation | `updateTodo` | `TodosDynamoDB` | UNIT | `UpdateItem` | Active |
| Mutation | `deleteTodo` | `TodosDynamoDB` | UNIT | `DeleteItem` | Active |

---

## DynamoDB Table Status

| Property | Value |
|---|---|
| Table Name | `graphql-appsync-todo-todos` |
| Table ID | `7eea4318-55dc-4fb7-a25b-77d669a672f9` |
| Table Status | `ACTIVE` |
| Table Class | `STANDARD` |
| Billing Mode | `PAY_PER_REQUEST` |
| Hash Key | `id` (String) |
| Item Count | `0` |
| Table Size | `0 bytes` |
| Point-in-Time Recovery | `ENABLED` (35-day recovery window) |
| Deletion Protection | `Disabled` |
| Warm Throughput (Read) | 12,000 units/sec |
| Warm Throughput (Write) | 4,000 units/sec |
| Created | `2026-06-23T03:41:55Z` |

---

## IAM Roles Status

| Role Name | Role ID | Created | Principal |
|---|---|---|---|
| `graphql-appsync-todo-appsync-dynamodb-role` | `AROAQKPIMHAV6ECPRRBF7` | 2026-06-23T03:41:55Z | `appsync.amazonaws.com` |
| `graphql-appsync-todo-appsync-logs-role` | `AROAQKPIMHAV7RLZQ3PBV` | 2026-06-23T03:41:55Z | `appsync.amazonaws.com` |

### DynamoDB Role Policy — Allowed Actions
| Action | Resource |
|---|---|
| `dynamodb:GetItem` | `arn:aws:dynamodb:us-east-1:022499047467:table/graphql-appsync-todo-todos` |
| `dynamodb:PutItem` | `arn:aws:dynamodb:us-east-1:022499047467:table/graphql-appsync-todo-todos` |
| `dynamodb:UpdateItem` | `arn:aws:dynamodb:us-east-1:022499047467:table/graphql-appsync-todo-todos` |
| `dynamodb:DeleteItem` | `arn:aws:dynamodb:us-east-1:022499047467:table/graphql-appsync-todo-todos` |
| `dynamodb:Query` | `arn:aws:dynamodb:us-east-1:022499047467:table/graphql-appsync-todo-todos` |
| `dynamodb:Scan` | `arn:aws:dynamodb:us-east-1:022499047467:table/graphql-appsync-todo-todos` |

### Logs Role Policy — Allowed Actions
| Action | Resource |
|---|---|
| `logs:CreateLogGroup` | `arn:aws:logs:*:*:*` |
| `logs:CreateLogStream` | `arn:aws:logs:*:*:*` |
| `logs:PutLogEvents` | `arn:aws:logs:*:*:*` |

---

## CloudWatch Log Group

| Property | Value |
|---|---|
| Log Group Name | `/aws/appsync/apis/nimn7y7g7nhfhcrsa6dfnvkjtq` |
| Retention | 30 days |
| Class | `STANDARD` |
| Stored Bytes | `0` (no traffic yet) |
| Created | 2026-06-23 |

---

## CloudWatch Alarms Status

| Alarm | Metric | Threshold | Evaluation | State | Reason |
|---|---|---|---|---|---|
| `graphql-appsync-todo-4xx-errors` | `4XXError` Sum | > 50 / 1 min | 1 period | **OK** | No datapoints — treated as non-breaching |
| `graphql-appsync-todo-5xx-errors` | `5XXError` Sum | > 10 / 1 min | 1 period | **OK** | No datapoints — treated as non-breaching |
| `graphql-appsync-todo-high-latency` | `Latency` p99 | > 1000 ms / 3 min | 3 periods | **OK** | No datapoints — treated as non-breaching |

> All alarms are in **OK** state. No actions configured (SNS topics can be attached via `alarm_actions`).

---

## API Key Details

| Property | Value |
|---|---|
| Key ID | `da2-nxyuesz5mbb5fa7tilb6dagwp4` |
| Description | `Managed by Terraform` |
| Expires | `2027-01-01T00:00:00Z` |
| Deletes | `2028-01-20T00:00:00Z` |

---

## GraphQL Schema

```graphql
type Todo {
  id: ID!
  title: String!
  completed: Boolean!
}

type Query {
  getTodos: [Todo]
  getTodo(id: ID!): Todo
}

type Mutation {
  addTodo(title: String!): Todo
  updateTodo(id: ID!, completed: Boolean!): Todo
  deleteTodo(id: ID!): ID
}
```

---

## Security Posture

| Topic | Current Posture | Recommended Hardening |
|---|---|---|
| Authentication | API_KEY — simple but shared secret | Migrate to `AMAZON_COGNITO_USER_POOLS` or `AWS_IAM` for production |
| API Key Expiry | Expires 2027-01-01 | Rotate annually; automate rotation via Lambda |
| CloudWatch Logs | ERROR level only, verbose content excluded | Increase to `ALL` in dev for debugging; keep ERROR in prod |
| DynamoDB Deletion Protection | Disabled | Enable `deletion_protection_enabled = true` for production tables |
| IAM Role Scope | Logs role uses `arn:aws:logs:*:*:*` (all log groups) | Narrow to specific log group ARN |
| X-Ray Tracing | Disabled | Enable `xray_enabled = true` for request tracing and performance analysis |
| Alarm Actions | No SNS actions configured | Attach SNS topic to receive notifications on alarm state changes |
| DynamoDB Encryption | AWS-owned key (default) | Use customer-managed KMS key for compliance requirements |

---

## Cost Estimate

| Resource | Pricing Model | Estimated Monthly Cost (USD) |
|---|---|---|
| AWS AppSync — Query/Mutation | $4.00 per million requests | ~$0.00 (dev/low traffic) |
| AWS AppSync — Real-time | $2.00 per million messages | ~$0.00 (dev/low traffic) |
| DynamoDB — On-Demand reads | $0.25 per million RCUs | ~$0.00 (dev/low traffic) |
| DynamoDB — On-Demand writes | $1.25 per million WCUs | ~$0.00 (dev/low traffic) |
| DynamoDB — PITR | $0.20 per GB-hour | ~$0.00 (empty table) |
| CloudWatch Logs — Ingestion | $0.50 per GB | ~$0.00 (ERROR level only) |
| CloudWatch Logs — Storage | $0.03 per GB | ~$0.00 (0 bytes stored) |
| CloudWatch Alarms | $0.10 per alarm/month | ~$0.30 (3 alarms) |
| **Total** | | **~$0.30/month** |

> Cost is essentially zero at development/low-traffic volumes. AppSync and DynamoDB on-demand pricing means no charge until queries are made.
