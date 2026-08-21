#!/bin/bash

################################################################################
# MASTER TEST RUNNER
# Runs all three testing levels: Quick (5m), Comprehensive (30m), Critical
################################################################################

echo "╔════════════════════════════════════════════════════════════════════════╗"
echo "║         🧪 MULTI-TENANT SAAS TEST SUITE - MASTER RUNNER              ║"
echo "║      Quick Test (5m) → Comprehensive Test (30m) → Critical Tests      ║"
echo "╚════════════════════════════════════════════════════════════════════════╝"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Function to run a test
run_test() {
    local test_name=$1
    local script_name=$2
    local test_path="$SCRIPT_DIR/$script_name"

    if [ ! -f "$test_path" ]; then
        echo -e "${RED}❌ Test script not found: $script_name${NC}"
        return 1
    fi

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Running: $test_name${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if bash "$test_path"; then
        echo -e "${GREEN}✅ $test_name PASSED${NC}"
        return 0
    else
        echo -e "${RED}❌ $test_name FAILED${NC}"
        return 1
    fi
}

# Check if deployment is complete
echo "Checking deployment status..."
cd "$SCRIPT_DIR/terraform"

API_URL=$(terraform output -raw api_gateway_invoke_url 2>/dev/null || echo "")
if [ -z "$API_URL" ]; then
    echo -e "${RED}❌ ERROR: Terraform deployment not complete${NC}"
    echo ""
    echo "Deployment status:"
    terraform show -json 2>/dev/null | jq '.values.root_module.resources | length' 2>/dev/null || echo "Unable to determine status"
    echo ""
    echo "Please wait for 'terraform apply tfplan' to complete (15-20 minutes)"
    exit 1
fi

echo -e "${GREEN}✅ Deployment is ready${NC}"
echo ""

# Menu for test selection
echo "Available Tests (Real AWS Service Testing):"
echo "  1) Quick Test (5 minutes) - Basic AWS service verification"
echo "  2) Comprehensive Test (30 minutes) - Full infrastructure testing"
echo "  3) Database Isolation Test - Real RDS PostgreSQL verification"
echo "  4) Critical Tests (10 minutes) - Security & production readiness"
echo "  5) Run ALL tests in sequence (comprehensive validation)"
echo "  6) Exit"
echo ""

read -p "Select test to run (1-6): " test_choice

case $test_choice in
    1)
        run_test "QUICK TEST" "test-quick.sh"
        exit $?
        ;;
    2)
        run_test "COMPREHENSIVE TEST" "test-comprehensive.sh"
        exit $?
        ;;
    3)
        run_test "DATABASE ISOLATION TEST" "test-database-isolation.sh"
        exit $?
        ;;
    4)
        run_test "CRITICAL TESTS" "test-critical.sh"
        exit $?
        ;;
    5)
        echo "Running ALL tests in sequence (Full Real AWS Validation)..."
        echo ""

        TOTAL_PASSED=0
        TOTAL_FAILED=0

        # Test 1: Quick
        if run_test "QUICK TEST" "test-quick.sh"; then
            ((TOTAL_PASSED++))
        else
            ((TOTAL_FAILED++))
        fi

        echo ""
        echo "Waiting before next test..."
        sleep 5
        echo ""

        # Test 2: Comprehensive
        if run_test "COMPREHENSIVE TEST" "test-comprehensive.sh"; then
            ((TOTAL_PASSED++))
        else
            ((TOTAL_FAILED++))
        fi

        echo ""
        echo "Waiting before database isolation test..."
        sleep 5
        echo ""

        # Test 3: Database Isolation
        if run_test "DATABASE ISOLATION TEST" "test-database-isolation.sh"; then
            ((TOTAL_PASSED++))
        else
            ((TOTAL_FAILED++))
        fi

        echo ""
        echo "Waiting before critical security test..."
        sleep 5
        echo ""

        # Test 4: Critical
        if run_test "CRITICAL TESTS" "test-critical.sh"; then
            ((TOTAL_PASSED++))
        else
            ((TOTAL_FAILED++))
        fi

        # Final summary
        echo ""
        echo "╔════════════════════════════════════════════════════════════════════════╗"
        echo "║              📊 OVERALL TEST RESULTS - Real AWS Services              ║"
        echo "╚════════════════════════════════════════════════════════════════════════╝"
        echo ""
        echo "Tests Passed: $TOTAL_PASSED"
        echo "Tests Failed: $TOTAL_FAILED"
        echo ""

        if [ $TOTAL_FAILED -eq 0 ]; then
            echo -e "${GREEN}✅ ALL TESTS PASSED - REAL AWS ARCHITECTURE IS PRODUCTION READY${NC}"
            echo ""
            echo "Verified Real AWS Services:"
            echo "  ✓ Real API Gateway authentication & authorization"
            echo "  ✓ Real Cognito user pool & JWT tokens"
            echo "  ✓ Real RDS PostgreSQL database"
            echo "  ✓ Real Secrets Manager credential retrieval"
            echo "  ✓ Real Lambda invocation & database connectivity"
            echo "  ✓ Real tenant isolation at database layer"
            echo "  ✓ Real CloudWatch monitoring & logging"
            echo ""
            exit 0
        else
            echo -e "${RED}❌ SOME TESTS FAILED - REVIEW ABOVE${NC}"
            exit 1
        fi
        ;;
    6)
        echo "Exiting..."
        exit 0
        ;;
    *)
        echo -e "${RED}❌ Invalid choice${NC}"
        exit 1
        ;;
esac
