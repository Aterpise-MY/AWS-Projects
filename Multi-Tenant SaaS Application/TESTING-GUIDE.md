# Multi-Tenant SaaS Testing Guide

## 🚀 Deployment Status

Your `terraform apply tfplan` is **in progress**. 

- **Resources Created**: 29/37 (78%)
- **Status**: Actively deploying
- **Estimated Time Remaining**: 5-10 minutes (RDS Multi-AZ setup)

Key components deployed:
- ✅ Cognito User Pool
- ✅ API Gateway REST API
- ✅ Lambda functions
- ✅ Security Groups
- ⏳ RDS PostgreSQL (in progress)

**Wait for terraform apply to complete before running tests.**

---

## 🧪 Testing Your Architecture

Three comprehensive test suites have been created to verify your multi-tenant SaaS architecture:

### Test Scripts Location
```
/Users/brendonang/Code/AWS Project/Multi-Tenant SaaS Application/
├── test-quick.sh              (5 minutes - basic functionality)
├── test-comprehensive.sh      (30 minutes - 19 detailed tests)
├── test-critical.sh           (10 minutes - security & production readiness)
└── test-all.sh                (master runner - runs all tests)
```

---

## ⚡ Quick Start: Run Tests

### Option 1: Interactive Menu (Recommended)
```bash
cd /Users/brendonang/Code/AWS\ Project/Multi-Tenant\ SaaS\ Application
./test-all.sh
```

Then select from the menu:
1. Quick Test (5m)
2. Comprehensive Test (30m)
3. Critical Tests (10m)
4. Run ALL tests
5. Exit

### Option 2: Run Individual Tests
```bash
# Run quick test (5 minutes)
./test-quick.sh

# Run comprehensive test (30 minutes)
./test-comprehensive.sh

# Run critical security tests (10 minutes)
./test-critical.sh
```

---

## 📋 Test Coverage

### Level 1: Quick Test (5 minutes) ⚡
**Tests**: 3 basic functionality tests
- API Gateway blocks unauthorized requests
- Cognito authentication works
- Tenant isolation verified

**When to run**: After terraform apply completes
**Pass criteria**: All 3 tests pass
**Use case**: Verify basic setup

### Level 2: Comprehensive Test (30 minutes) 📊
**Tests**: 19 detailed tests across 6 phases

**Phase 1**: Infrastructure (5 tests)
- AWS account access
- Terraform outputs available
- Cognito pool created
- RDS database accessible
- Security groups configured

**Phase 2**: Authentication (3 tests)
- Create users in Cognito
- Get JWT tokens
- Verify JWT contains tenant_id claim

**Phase 3**: API Authorization (3 tests)
- 401 without JWT
- 401 with invalid token
- 200 OK with valid JWT

**Phase 4**: Database (2 tests)
- Lambda fetches secrets from Secrets Manager
- Database connections logged in CloudWatch

**Phase 5**: Tenant Isolation (4 tests)
- Create users in different tenants
- Verify tenant isolation
- Cross-tenant access blocked
- Cross-tenant updates blocked

**Phase 6**: Monitoring (2 tests)
- CloudWatch Lambda metrics available
- CloudWatch logs available

**When to run**: After terraform apply completes and quick test passes
**Pass criteria**: All 19 tests pass
**Use case**: Full functionality verification

### Level 3: Critical Tests (10 minutes) 🔐
**Tests**: Must-pass tests for production

**Security Tests** (5 critical):
- ✅ RDS NOT publicly accessible
- ✅ RDS encryption enabled
- ✅ Lambda in VPC (not public)
- ✅ API Gateway enforces Cognito
- ✅ RDS security group restricts access

**Functionality Tests** (5 critical):
- ✅ Cognito authentication works
- ✅ JWT contains tenant_id
- ✅ Authorized API requests succeed
- ✅ Lambda connects to database
- ✅ Tenant isolation verified

**Performance Tests** (2 checks):
- ✅ API response < 1 second
- ✅ Lambda executes without errors

**When to run**: Before production deployment
**Pass criteria**: ALL critical tests must pass
**Use case**: Production readiness verification

---

## 📊 What Each Test Verifies

### Quick Test Output Example
```
✅ TEST 1: API Gateway Blocks Unauthorized Requests
   Received 401 Unauthorized (as expected)

✅ TEST 2: Cognito Authentication
   Test users created
   User A (tenant-001): quicktest-a@example.com
   User B (tenant-002): quicktest-b@example.com

✅ TEST 3: Tenant Isolation Verification
   User A JWT contains custom:tenant_id = tenant-001

✅ ALL QUICK TESTS PASSED
```

### Comprehensive Test Output Example
```
PHASE 1: INFRASTRUCTURE VERIFICATION (5 tests)
✅ AWS Account Connection: Account 022499047467
✅ Terraform Outputs Available: All outputs present
✅ Cognito User Pool Created: saas-user-pool active
✅ RDS Database Available: Status available
✅ Security Groups Configured: Lambda and RDS SGs exist

PHASE 2: COGNITO AUTHENTICATION (3 tests)
✅ Create Test Users in Cognito
✅ Authenticate and Get JWT Token
✅ Verify JWT Contains tenant_id Claim

PHASE 3: API GATEWAY AUTHORIZATION (3 tests)
✅ Test 401 Without JWT
✅ Test 401 With Invalid Token
✅ Test 200 OK With Valid JWT

PHASE 4: DATABASE CONNECTIVITY (2 tests)
✅ Lambda Can Fetch Secret from Secrets Manager
✅ Check Lambda Logs for DB Connection

PHASE 5: TENANT ISOLATION (4 tests)
✅ Create Users in Different Tenants
✅ Verify Tenant Isolation - User A Cannot See User B's Data
✅ Verify User B Cannot Update User A's Data
✅ Verify User B Cannot Delete User A's Data

PHASE 6: MONITORING & PERFORMANCE (2 tests)
✅ CloudWatch Lambda Metrics Available
✅ CloudWatch Logs Available

Tests Passed: 19
✅ ALL TESTS PASSED!
```

### Critical Test Output Example
```
SECURITY TESTS (MUST PASS)
✅ RDS NOT Publicly Accessible
✅ RDS Encryption Enabled
✅ Lambda in VPC (Not Public)
✅ API Gateway Enforces Cognito Authorization
✅ RDS Security Group Restricts Access

FUNCTIONALITY TESTS (MUST PASS)
✅ Cognito Authentication Works
✅ JWT Contains Required tenant_id Claim
✅ Authorized API Requests Succeed
✅ Lambda Can Access Database

TENANT ISOLATION TESTS (CRITICAL SECURITY)
✅ Create Isolated Tenant Data
✅ Tenant 1 User Cannot Read Tenant 2 Data
✅ Tenant 2 Cannot Modify Tenant 1 Data

PERFORMANCE TESTS
✅ API Response Time < 1 second (125ms)
✅ Lambda Execution Succeeds

✅ ALL CRITICAL TESTS PASSED - PRODUCTION READY
```

---

## ⏱️ Timing Guide

| Test | Duration | When | Purpose |
|------|----------|------|---------|
| Quick | 5 min | After deploy | Verify basics |
| Comprehensive | 30 min | After quick passes | Full validation |
| Critical | 10 min | Before prod | Production checklist |
| All (sequential) | 50 min | Full validation | Complete verification |

---

## 🔐 Success Criteria

### Quick Test
- [ ] All 3 tests pass
- [ ] No errors in output

### Comprehensive Test
- [ ] All 19 tests pass (0 failures)
- [ ] Infrastructure phase: 5/5
- [ ] Authentication phase: 3/3
- [ ] API Authorization phase: 3/3
- [ ] Database phase: 2/2
- [ ] Tenant Isolation phase: 4/4
- [ ] Monitoring phase: 2/2

### Critical Test
- [ ] All security tests pass
- [ ] All functionality tests pass
- [ ] All tenant isolation tests pass
- [ ] Performance metrics acceptable

### Production Ready Checklist
- [ ] All critical tests pass ✅
- [ ] No errors in CloudWatch logs ✅
- [ ] RDS Multi-AZ is active ✅
- [ ] Tenant isolation verified ✅
- [ ] API response time < 1s ✅
- [ ] Lambda functions executing ✅
- [ ] Encryption enabled ✅
- [ ] Security groups configured correctly ✅

---

## 📝 Manual Testing (Optional)

If you want to manually test specific functionality:

### 1. Get Terraform Outputs
```bash
cd terraform
terraform output -raw api_gateway_invoke_url
terraform output -raw user_pool_id
terraform output -raw app_client_id
```

### 2. Create a Test User
```bash
USER_POOL_ID="us-east-1_xxxxxxxxx"
aws cognito-idp admin-create-user \
  --user-pool-id $USER_POOL_ID \
  --username testuser@example.com \
  --user-attributes Name=email,Value=testuser@example.com \
                     Name=custom:tenant_id,Value=tenant-001 \
  --message-action SUPPRESS \
  --region us-east-1
```

### 3. Set Password
```bash
aws cognito-idp admin-set-user-password \
  --user-pool-id $USER_POOL_ID \
  --username testuser@example.com \
  --password "TestPassword123@" \
  --permanent \
  --region us-east-1
```

### 4. Get JWT Token
```bash
CLIENT_ID="abc123def456..."
aws cognito-idp admin-initiate-auth \
  --user-pool-id $USER_POOL_ID \
  --client-id $CLIENT_ID \
  --auth-flow ADMIN_NO_SRP_AUTH \
  --auth-parameters USERNAME=testuser@example.com,PASSWORD="TestPassword123@" \
  --region us-east-1
```

### 5. Test API
```bash
API_URL="https://xxxxxxx.execute-api.us-east-1.amazonaws.com/dev"
TOKEN="<ID_TOKEN_from_step_4>"

# Without authorization (should return 401)
curl $API_URL/users

# With authorization (should return 200)
curl -H "Authorization: Bearer $TOKEN" $API_URL/users
```

---

## 🆘 Troubleshooting

### Test Fails: "Terraform outputs not available"
**Cause**: Deployment still in progress
**Solution**: Wait for `terraform apply tfplan` to complete (15-20 minutes)
**Check**:
```bash
cd terraform
terraform output -raw api_gateway_invoke_url
```

### Test Fails: "Cannot authenticate users"
**Cause**: Cognito User Pool not fully initialized
**Solution**: Wait 2-3 minutes and retry
**Check**:
```bash
aws cognito-idp describe-user-pool --user-pool-id <POOL_ID> --region us-east-1
```

### Test Fails: "Lambda cannot connect to database"
**Cause**: RDS still initializing or Lambda security group issue
**Solution**: Wait for RDS to reach "available" status (up to 10 minutes)
**Check**:
```bash
aws rds describe-db-instances --db-instance-identifier saas-postgres --region us-east-1
```

### Test Fails: "Tenant isolation not working"
**Cause**: Lambda code not filtering by tenant_id
**Solution**: Check Lambda function code
**Verify**:
```bash
aws logs tail /aws/lambda/saas-users-handler --follow
```

---

## 📚 Additional Resources

- [Architecture Guide](./README.md) - Full architecture documentation
- [Requirements Checklist](./REQUIREMENTS_CHECKLIST.md) - Requirement verification
- [Quick Start Guide](./QUICK_START.md) - Deployment instructions

---

## 🎯 Next Steps After Testing

1. ✅ Run Quick Test (5 min) - verify basics
2. ✅ Run Comprehensive Test (30 min) - full validation
3. ✅ Run Critical Test (10 min) - production readiness
4. 🚀 Deploy to production (if all tests pass)
5. 📊 Set up monitoring and alerts
6. 🔐 Enable additional security features (MFA, WAF, etc.)

---

**Strong Password Set**: `MultiTenant@Saas2026!`
**Stored in**: AWS Secrets Manager (saas/db/password)
**Created**: 2026-06-19

