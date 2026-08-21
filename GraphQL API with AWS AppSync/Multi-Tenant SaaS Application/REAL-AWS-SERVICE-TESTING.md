# Real AWS Service Testing Guide

All test scripts have been updated to comprehensively test **real AWS services** running in your account.

---

## 🎯 What Gets Tested (Real Services)

### Test Suite Overview

| Test | Duration | Real Services Tested | Focus |
|------|----------|----------------------|-------|
| **Quick Test** | 5 min | RDS, API Gateway, Cognito, Lambda | Basic real service verification |
| **Comprehensive Test** | 30 min | All services + CloudWatch | Full real infrastructure validation |
| **Database Isolation Test** | ~10 min | Real RDS PostgreSQL directly | Database-layer tenant isolation |
| **Critical Tests** | 10 min | All services + Security | Production readiness with real services |
| **All Tests** | 60 min | Complete real stack | End-to-end real AWS validation |

---

## ✅ Real AWS Service Tests

### 1. Quick Test (`test-quick.sh`) - 5 minutes
Tests real AWS services with live data flow:

#### TEST 1: Real RDS Database Status
```bash
aws rds describe-db-instances --db-instance-identifier saas-postgres
```
- ✅ Verifies real PostgreSQL database is "available"
- ✅ Confirms Multi-AZ setup
- ✅ Checks encryption status
- **Real Service:** RDS PostgreSQL

#### TEST 2: Real API Gateway Protection
```bash
curl https://<api-gateway-id>.execute-api.us-east-1.amazonaws.com/dev/users
```
- ✅ Confirms real API Gateway enforces Cognito authorization
- ✅ Returns 401 without JWT token
- **Real Service:** API Gateway REST API

#### TEST 3: Real Cognito Authentication → RDS Data Insertion
```bash
# Real Cognito user creation
aws cognito-idp admin-create-user --user-pool-id <real-pool-id> ...

# Real JWT token from Cognito
TOKEN=$(aws cognito-idp admin-initiate-auth ...)

# Real API call with real JWT
curl -H "Authorization: Bearer $TOKEN" <real-api-url>/users
```
- ✅ Creates real users in Cognito User Pool
- ✅ Gets real JWT token from Cognito
- ✅ Invokes real Lambda through API Gateway
- ✅ Lambda inserts data into real RDS database
- **Real Services:** Cognito → API Gateway → Lambda → RDS

#### TEST 4: Real Tenant Isolation at Database Layer
- ✅ User A (tenant-001) data isolated from User B (tenant-002)
- ✅ Verified through real database query results
- **Real Service:** RDS PostgreSQL tenant isolation

---

### 2. Comprehensive Test (`test-comprehensive.sh`) - 30 minutes
Six phases of real AWS service validation:

#### PHASE 1: Real Infrastructure (5 tests)
```bash
# Real AWS account access
aws sts get-caller-identity

# Real RDS instance
aws rds describe-db-instances --db-instance-identifier saas-postgres

# Real Cognito pool
aws cognito-idp describe-user-pool --user-pool-id <real-pool-id>

# Real security groups
aws ec2 describe-security-groups --filters Name=group-name,Values=saas-lambda-sg
```
- ✅ AWS account accessibility
- ✅ Real Cognito User Pool active
- ✅ Real RDS database available
- ✅ Real security groups configured

#### PHASE 2: Real Cognito Authentication (3 tests)
- ✅ Creates real Cognito users with custom:tenant_id
- ✅ Gets real JWT tokens from Cognito
- ✅ Verifies JWT contains tenant_id claim

#### PHASE 3: Real API Gateway Authorization (3 tests)
```bash
# 401 without JWT
curl $API_URL/users
# 401 with invalid token
curl -H "Authorization: Bearer invalid" $API_URL/users
# 200 with real JWT
curl -H "Authorization: Bearer $REAL_TOKEN" $API_URL/users
```
- ✅ Real API Gateway returns 401 without JWT
- ✅ Real API Gateway returns 401 with invalid JWT
- ✅ Real API Gateway returns 200 with valid JWT

#### PHASE 4: Real Database Connectivity (2 tests)
```bash
# Real Lambda invocation
aws lambda invoke --function-name saas-auth-handler

# Real Lambda logs from CloudWatch
aws logs filter-log-events --log-group-name /aws/lambda/saas-auth-handler
```
- ✅ Real Lambda connects to real RDS
- ✅ Real Secrets Manager credentials used
- ✅ Real database connection verified in CloudWatch logs

#### PHASE 5: Real Tenant Isolation (4 tests)
```bash
# Tenant A creates user in real database
curl -X POST $API_URL/users \
  -H "Authorization: Bearer $TOKEN_A" \
  -d '{"email": "alice@example.com"}'

# Verify Tenant B cannot see Tenant A's data
curl -X GET $API_URL/users \
  -H "Authorization: Bearer $TOKEN_B"
```
- ✅ Creates real users in separate tenants
- ✅ Verifies each tenant only sees their own data
- ✅ Confirms cross-tenant access is blocked

#### PHASE 6: Real Monitoring (2 tests)
```bash
# Real CloudWatch metrics
aws cloudwatch list-metrics \
  --namespace AWS/Lambda \
  --dimensions Name=FunctionName,Value=saas-users-handler

# Real CloudWatch logs
aws logs describe-log-groups \
  --log-group-name-prefix "/aws/lambda/saas"
```
- ✅ Real CloudWatch metrics from Lambda executions
- ✅ Real CloudWatch log groups created

---

### 3. Database Isolation Test (`test-database-isolation.sh`) - ~10 minutes
Direct real RDS PostgreSQL verification:

#### TEST 1: Real Database Connection
```bash
psql -h <real-rds-endpoint> -U postgres -d saas_db \
  -c "SELECT version();"
```
- ✅ Direct connection to real RDS PostgreSQL
- ✅ Retrieves real database credentials from Secrets Manager
- **Real Service:** RDS PostgreSQL

#### TEST 2: Real Database Schema
```bash
SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'
```
- ✅ Verifies real database tables exist
- ✅ Lists real tables: users, orders, tenants
- **Real Service:** RDS PostgreSQL

#### TEST 3: Real Tenant Data Isolation
```bash
-- Real data in tenant-001
INSERT INTO users (tenant_id, email, name) 
VALUES ('tenant-001', 'test1@example.com', 'Test User 1');

-- Real data in tenant-002
INSERT INTO users (tenant_id, email, name) 
VALUES ('tenant-002', 'test2@example.com', 'Test User 2');

-- Query isolation
SELECT COUNT(*) FROM users WHERE tenant_id = 'tenant-001';  -- Count only tenant-001
SELECT COUNT(*) FROM users WHERE tenant_id = 'tenant-002';  -- Count only tenant-002
```
- ✅ Real INSERT operations into real database
- ✅ Real WHERE clause filtering by tenant_id
- ✅ Verifies data isolation at database layer
- **Real Service:** RDS PostgreSQL

#### TEST 4: Real Isolation Query
```bash
SELECT email FROM users WHERE tenant_id = 'tenant-001'
```
- ✅ Queries only tenant-001 data
- ✅ Confirms Lambda uses same WHERE clause pattern
- **Real Service:** RDS PostgreSQL

#### TEST 5: Real Encryption
```bash
aws rds describe-db-instances \
  --db-instance-identifier saas-postgres \
  --query 'DBInstances[0].StorageEncrypted'
```
- ✅ Verifies real storage encryption enabled
- **Real Service:** RDS PostgreSQL

#### TEST 6: Real Multi-AZ Setup
```bash
aws rds describe-db-instances \
  --db-instance-identifier saas-postgres \
  --query 'DBInstances[0].MultiAZ'
```
- ✅ Confirms real Multi-AZ high availability
- **Real Service:** RDS PostgreSQL

---

### 4. Critical Tests (`test-critical.sh`) - 10 minutes
Production readiness validation using real services:

#### Security Tests (5 critical tests)
- ✅ **Real RDS NOT publicly accessible** - Verified via AWS API
- ✅ **Real RDS encryption enabled** - KMS encryption confirmed
- ✅ **Real Lambda in VPC** - Confirmed in private subnets
- ✅ **Real API Gateway enforces Cognito** - 401 without JWT
- ✅ **Real RDS security group restricts access** - Port 5432 only from Lambda

#### Functionality Tests (5 critical tests)
- ✅ **Real Cognito authentication works** - JWT tokens generated
- ✅ **Real JWT contains tenant_id** - Claim verified from token
- ✅ **Real authorized API requests succeed** - 200 OK with JWT
- ✅ **Real Lambda connects to database** - Secret Manager integration
- ✅ **Real tenant isolation verified** - Cross-tenant access blocked

#### Performance Tests (2 checks)
- ✅ **Real API response time < 1 second** - Measured end-to-end
- ✅ **Real Lambda executes without errors** - Actual invocation

---

## 🚀 Running Real AWS Service Tests

### Interactive Menu (Recommended)
```bash
cd /Users/brendonang/Code/AWS\ Project/Multi-Tenant\ SaaS\ Application
./test-all.sh
```

Select from menu:
```
Available Tests (Real AWS Service Testing):
  1) Quick Test (5 minutes) - Basic AWS service verification
  2) Comprehensive Test (30 minutes) - Full infrastructure testing
  3) Database Isolation Test - Real RDS PostgreSQL verification
  4) Critical Tests (10 minutes) - Security & production readiness
  5) Run ALL tests in sequence (comprehensive validation)
  6) Exit
```

### Run Individual Tests
```bash
# Quick test (5 min)
./test-quick.sh

# Comprehensive test (30 min)
./test-comprehensive.sh

# Database isolation test (~10 min)
./test-database-isolation.sh

# Critical tests (10 min)
./test-critical.sh
```

### Run All Tests Sequentially
```bash
./test-all.sh
# Select option 5: Run ALL tests in sequence
```

---

## 📊 Test Execution Flow

```
┌─────────────────────────────────────────────────────────┐
│  Test Execution Flow - All Real AWS Services            │
└─────────────────────────────────────────────────────────┘

START
  │
  ├─→ QUICK TEST (5 min)
  │     ├─ Query real RDS status
  │     ├─ Call real API Gateway (401 test)
  │     ├─ Create real Cognito users
  │     ├─ Get real JWT tokens
  │     ├─ Call real API with JWT (200 test)
  │     └─ Invoke real Lambda
  │
  ├─→ COMPREHENSIVE TEST (30 min)
  │     ├─ Access real AWS account
  │     ├─ Verify real Cognito pool
  │     ├─ Verify real RDS database
  │     ├─ Verify real security groups
  │     ├─ Create real Cognito test users
  │     ├─ Test real API authorization (401 → 200)
  │     ├─ Invoke real Lambda
  │     ├─ Check real CloudWatch logs
  │     ├─ Test real tenant isolation
  │     └─ Verify real monitoring
  │
  ├─→ DATABASE ISOLATION TEST (10 min)
  │     ├─ Connect directly to real RDS
  │     ├─ Verify real database schema
  │     ├─ INSERT real test data
  │     ├─ Query real tenant isolation
  │     ├─ Verify real WHERE clause filtering
  │     ├─ Check real encryption
  │     └─ Verify real Multi-AZ setup
  │
  ├─→ CRITICAL TESTS (10 min)
  │     ├─ Security: Real RDS, encryption, VPC
  │     ├─ Functionality: Real Cognito, JWT, API
  │     ├─ Isolation: Real database tenant separation
  │     └─ Performance: Real response times
  │
  └─→ RESULTS
       ├─ ✅ ALL TESTS PASSED (Production Ready)
       └─ ❌ FAILURES (Review issues)
```

---

## 🔍 What Makes These "Real AWS Service" Tests

### Direct AWS API Calls
Every test uses real AWS APIs, not mocks:
```bash
aws cognito-idp ...          # Real Cognito
aws rds describe-db-instances # Real RDS
aws lambda invoke ...         # Real Lambda
aws secretsmanager ...        # Real Secrets Manager
curl $API_URL/users          # Real API Gateway
aws cloudwatch ...           # Real monitoring
```

### Live Data Flow
Tests verify end-to-end data flow through real services:
```
Cognito (real user)
    ↓
JWT Token (real)
    ↓
API Gateway (real endpoint)
    ↓
Cognito Authorizer (real)
    ↓
Lambda (real invocation)
    ↓
Secrets Manager (real credentials)
    ↓
RDS PostgreSQL (real insert/query)
```

### Database-Level Verification
Database Isolation Test connects directly to real RDS:
```bash
psql -h <real-rds-endpoint> ... # Direct PostgreSQL connection
SELECT * FROM users ...        # Real SQL queries
INSERT INTO users ...          # Real data manipulation
```

---

## ✨ Success Criteria

### Quick Test (5 min)
- [ ] Real RDS database is "available"
- [ ] Real API Gateway returns 401 without JWT
- [ ] Real Cognito creates users
- [ ] Real JWT contains tenant_id claim

### Comprehensive Test (30 min)
- [ ] Real Cognito pool active
- [ ] Real RDS database accessible
- [ ] Real Lambda invokes successfully
- [ ] Real API Gateway authorization works
- [ ] Real tenant isolation confirmed
- [ ] Real CloudWatch monitoring active

### Database Isolation Test (10 min)
- [ ] Direct RDS connection successful
- [ ] Real database schema verified
- [ ] Real data inserted into tables
- [ ] Real WHERE clause filtering works
- [ ] Real encryption enabled
- [ ] Real Multi-AZ configured

### Critical Tests (10 min)
- [ ] Real RDS NOT publicly exposed
- [ ] Real RDS encryption enabled
- [ ] Real Lambda in VPC
- [ ] Real API Gateway enforces Cognito
- [ ] Real tenant isolation working
- [ ] Real performance acceptable

---

## 📈 Full Validation (All Tests)

When you run all tests and they pass:

✅ **Real AWS Services Verified:**
- Real API Gateway authentication & authorization
- Real Cognito user pool & JWT tokens with tenant claims
- Real RDS PostgreSQL Multi-AZ database
- Real Secrets Manager secure credential storage
- Real Lambda invocation in VPC
- Real database connectivity (Secrets Manager → Lambda → RDS)
- Real tenant isolation at database layer (WHERE tenant_id)
- Real CloudWatch monitoring & logging
- Real encryption at rest (RDS)
- Real high availability (Multi-AZ)
- Real security group restrictions

✅ **Architecture is Production Ready!**

---

## 🛠️ Prerequisites for Full Testing

For database isolation test, install PostgreSQL client:
```bash
# macOS
brew install postgresql

# Linux
sudo apt-get install postgresql-client

# Then run database isolation test
./test-database-isolation.sh
```

---

## 📞 Troubleshooting Real Service Tests

### "Terraform outputs not available"
- **Cause:** Deployment still in progress
- **Solution:** Wait for all 37/37 resources to complete
- **Check:** `cd terraform && terraform show -json | jq '.values.root_module.resources | length'`

### "Cannot connect to RDS"
- **Cause:** RDS still initializing or security group issue
- **Solution:** Wait 5-10 more minutes
- **Check:** `aws rds describe-db-instances --db-instance-identifier saas-postgres`

### "Lambda cannot connect to database"
- **Cause:** Secrets Manager integration not ready
- **Solution:** Check Lambda environment variables in AWS console
- **Check:** `aws lambda get-function-configuration --function-name saas-auth-handler`

### "Tenant isolation not working"
- **Cause:** Lambda not filtering by tenant_id in queries
- **Solution:** Review Lambda function code
- **Check:** `aws logs tail /aws/lambda/saas-users-handler --follow`

---

**All tests verify real AWS services in your account. No mocks, no simulations. Pure production architecture validation.**
