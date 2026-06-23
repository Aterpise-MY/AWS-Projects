#!/usr/bin/env bash
# GraphQL API with AWS AppSync — Architecture Test Script
# Run from the project root: bash scripts/test_architecture.sh

set -euo pipefail

PASS=0
FAIL=0
WARN=0

pass() { echo "  [PASS] $1"; ((PASS++)); }
fail() { echo "  [FAIL] $1"; ((FAIL++)); }
warn() { echo "  [WARN] $1"; ((WARN++)); }
section() { echo; echo "=== $1 ==="; }

for cmd in aws terraform jq curl; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not installed"; exit 1; }
done

echo "Loading Terraform outputs..."
cd "$(dirname "$0")/../terraform"

API_URL=$(terraform output -raw appsync_api_url   2>/dev/null) || { echo "ERROR: run terraform apply first"; exit 1; }
API_KEY=$(terraform output -raw appsync_api_key    2>/dev/null)
API_ID=$(terraform output -raw appsync_api_id      2>/dev/null)
TABLE=$(terraform output -raw dynamodb_table_name  2>/dev/null)
LOG_GROUP=$(terraform output -raw cloudwatch_log_group 2>/dev/null)
REGION=$(terraform output -raw region              2>/dev/null)

# ── 1. Terraform state ────────────────────────────────────────────────────────
section "1. Terraform State"

count=$(terraform show -json | jq '.values.root_module.resources | length')
if [ "$count" -ge 12 ]; then
  pass "State: $count resources managed"
else
  warn "State: $count resources (expected ≥12)"
fi

# ── 2. AppSync API ────────────────────────────────────────────────────────────
section "2. AppSync GraphQL API"

api=$(aws appsync get-graphql-api --api-id "$API_ID" --region "$REGION" \
  --query 'graphqlApi.{name:name,auth:authenticationType}' --output json 2>/dev/null || echo "{}")
api_name=$(echo "$api" | jq -r '.name // empty')

if [ -n "$api_name" ]; then
  auth=$(echo "$api" | jq -r '.auth')
  pass "API exists: $api_name (auth: $auth)"
else
  fail "AppSync API not found (ID: $API_ID)"
fi

# data source
ds=$(aws appsync list-data-sources --api-id "$API_ID" --region "$REGION" \
  --query 'dataSources[0].{name:name,type:type}' --output json 2>/dev/null || echo "{}")
ds_name=$(echo "$ds" | jq -r '.name // empty')
if [ -n "$ds_name" ]; then
  pass "Data source: $ds_name ($(echo "$ds" | jq -r '.type'))"
else
  fail "No data source attached to API"
fi

# resolvers
q_count=$(aws appsync list-resolvers --api-id "$API_ID" --type-name Query \
  --region "$REGION" --query 'length(resolvers)' --output text 2>/dev/null || echo 0)
m_count=$(aws appsync list-resolvers --api-id "$API_ID" --type-name Mutation \
  --region "$REGION" --query 'length(resolvers)' --output text 2>/dev/null || echo 0)
total=$((q_count + m_count))
if [ "$total" -ge 5 ]; then
  pass "Resolvers: $q_count Query + $m_count Mutation"
else
  fail "Resolver count $total < 5 expected"
fi

# ── 3. API Key ────────────────────────────────────────────────────────────────
section "3. API Key"

key=$(aws appsync list-api-keys --api-id "$API_ID" --region "$REGION" \
  --query 'apiKeys[0].{id:id,expires:expires}' --output json 2>/dev/null || echo "{}")
key_id=$(echo "$key" | jq -r '.id // empty')
if [ -n "$key_id" ]; then
  pass "API key active: $key_id (expires: $(echo "$key" | jq -r '.expires'))"
else
  fail "No active API key found"
fi

# ── 4. DynamoDB ───────────────────────────────────────────────────────────────
section "4. DynamoDB Table"

table=$(aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" \
  --query 'Table.{status:TableStatus,billing:BillingModeSummary.BillingMode}' \
  --output json 2>/dev/null || echo "{}")
t_status=$(echo "$table" | jq -r '.status // empty')
if [ "$t_status" = "ACTIVE" ]; then
  pass "Table ACTIVE: $TABLE (billing: $(echo "$table" | jq -r '.billing // "PROVISIONED"'))"
else
  fail "Table not ACTIVE: $TABLE (status: $t_status)"
fi

pitr=$(aws dynamodb describe-continuous-backups --table-name "$TABLE" --region "$REGION" \
  --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus' \
  --output text 2>/dev/null || echo "UNKNOWN")
if [ "$pitr" = "ENABLED" ]; then
  pass "Point-in-time recovery enabled"
else
  warn "PITR status: $pitr"
fi

# ── 5. IAM Roles ──────────────────────────────────────────────────────────────
section "5. IAM Roles"

for role_suffix in "appsync-dynamodb-role" "appsync-logs-role"; do
  role_name="${var_project_name:-graphql-appsync-todo}-${role_suffix}"
  result=$(aws iam get-role --role-name "$role_name" \
    --query 'Role.RoleName' --output text 2>/dev/null || echo "NOT_FOUND")
  if [ "$result" != "NOT_FOUND" ]; then
    pass "IAM role exists: $result"
  else
    warn "IAM role not found: $role_name (check project_name variable)"
  fi
done

# ── 6. CloudWatch ─────────────────────────────────────────────────────────────
section "6. CloudWatch Monitoring"

lg=$(aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --region "$REGION" \
  --query 'logGroups[0].logGroupName' --output text 2>/dev/null || echo "None")
if [ "$lg" != "None" ] && [ -n "$lg" ]; then
  pass "Log group: $lg"
else
  warn "Log group not found: $LOG_GROUP (AppSync creates it on first request)"
fi

alarm_count=$(aws cloudwatch describe-alarms --alarm-name-prefix "graphql-appsync-todo" \
  --region "$REGION" --query 'length(MetricAlarms)' --output text 2>/dev/null || echo 0)
if [ "$alarm_count" -ge 3 ]; then
  pass "CloudWatch alarms: $alarm_count configured"
else
  warn "CloudWatch alarms: $alarm_count (expected ≥3)"
fi

# ── 7. Live GraphQL Tests ─────────────────────────────────────────────────────
section "7. Live GraphQL API Tests"

gql() {
  curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "x-api-key: $API_KEY" \
    -d "$1"
}

# addTodo
add_resp=$(gql '{"query":"mutation { addTodo(title: \"Arch test todo\") { id title completed } }"}')
todo_id=$(echo "$add_resp" | jq -r '.data.addTodo.id // empty')
if [ -n "$todo_id" ]; then
  pass "addTodo: created id=$todo_id"
else
  fail "addTodo: $(echo "$add_resp" | jq -r '.errors[0].message // "unknown error"')"
fi

# getTodos
get_resp=$(gql '{"query":"query { getTodos { id title completed } }"}')
count=$(echo "$get_resp" | jq '.data.getTodos | length // 0')
if [ "$count" -gt 0 ]; then
  pass "getTodos: returned $count item(s)"
else
  fail "getTodos: no items returned"
fi

# getTodo
if [ -n "$todo_id" ]; then
  single_resp=$(gql "{\"query\":\"query { getTodo(id: \\\"$todo_id\\\") { id title completed } }\"}")
  got_id=$(echo "$single_resp" | jq -r '.data.getTodo.id // empty')
  if [ "$got_id" = "$todo_id" ]; then
    pass "getTodo: fetched id=$got_id"
  else
    fail "getTodo: expected $todo_id, got $got_id"
  fi
fi

# updateTodo
if [ -n "$todo_id" ]; then
  upd_resp=$(gql "{\"query\":\"mutation { updateTodo(id: \\\"$todo_id\\\", completed: true) { id completed } }\"}")
  completed=$(echo "$upd_resp" | jq -r '.data.updateTodo.completed // empty')
  if [ "$completed" = "true" ]; then
    pass "updateTodo: marked completed"
  else
    fail "updateTodo: $(echo "$upd_resp" | jq -r '.errors[0].message // "unknown error"')"
  fi
fi

# deleteTodo
if [ -n "$todo_id" ]; then
  del_resp=$(gql "{\"query\":\"mutation { deleteTodo(id: \\\"$todo_id\\\") }\"}")
  deleted_id=$(echo "$del_resp" | jq -r '.data.deleteTodo // empty')
  if [ "$deleted_id" = "$todo_id" ]; then
    pass "deleteTodo: deleted id=$deleted_id"
  else
    fail "deleteTodo: $(echo "$del_resp" | jq -r '.errors[0].message // "unknown error"')"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "================================================================"
echo "  Architecture Test Results"
echo "================================================================"
printf "  PASS : %d\n" "$PASS"
printf "  FAIL : %d\n" "$FAIL"
printf "  WARN : %d\n" "$WARN"
printf "  Total: %d\n" "$((PASS + FAIL + WARN))"
echo "================================================================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
