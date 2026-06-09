#!/bin/bash

################################################################################
# Connectivity Test - Verify application is reachable
################################################################################

set -o pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_failure() { echo -e "${RED}✗${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
log_info() { echo "ℹ $1"; }

get_terraform_output() {
    cd "$PROJECT_DIR" || return 1
    terraform output -json 2>/dev/null | jq -r ".$1" 2>/dev/null
}

# Test DNS resolution
test_dns() {
    echo -e "\n${BLUE}=== DNS Resolution ===${NC}"

    ALB_DNS=$(get_terraform_output "alb_dns_name")

    if [ -z "$ALB_DNS" ] || [ "$ALB_DNS" = "null" ]; then
        log_failure "ALB DNS not found"
        return 1
    fi

    if dig +short "$ALB_DNS" &>/dev/null; then
        IP=$(dig +short "$ALB_DNS" | head -1)
        log_success "DNS resolves to: $IP"
    else
        log_failure "DNS resolution failed"
        return 1
    fi
}

# Test HTTP connectivity
test_http() {
    echo -e "\n${BLUE}=== HTTP Connectivity ===${NC}"

    ALB_DNS=$(get_terraform_output "alb_dns_name")

    if [ -z "$ALB_DNS" ] || [ "$ALB_DNS" = "null" ]; then
        log_failure "ALB DNS not found"
        return 1
    fi

    URL="http://$ALB_DNS"
    log_info "Testing: $URL"

    # Test with timing
    RESPONSE=$(curl -w "\n%{http_code}\n%{time_connect}\n%{time_starttransfer}" -s -o /tmp/response_body.txt "$URL" --connect-timeout 10 --max-time 15 2>/dev/null)

    HTTP_CODE=$(echo "$RESPONSE" | tail -3 | head -1)
    CONNECT_TIME=$(echo "$RESPONSE" | tail -2 | head -1)
    TRANSFER_TIME=$(echo "$RESPONSE" | tail -1)

    if [ -z "$HTTP_CODE" ]; then
        log_failure "Could not reach ALB"
        return 1
    fi

    log_info "HTTP Status: $HTTP_CODE"
    log_info "Connect time: ${CONNECT_TIME}s"
    log_info "Transfer time: ${TRANSFER_TIME}s"

    case $HTTP_CODE in
        200)
            log_success "HTTP 200 - OK"
            ;;
        301|302|303|307)
            log_success "HTTP $HTTP_CODE - Redirect (expected for some apps)"
            ;;
        404)
            log_warning "HTTP 404 - Page not found"
            ;;
        502|503)
            log_failure "HTTP $HTTP_CODE - Backend unavailable"
            return 1
            ;;
        *)
            log_warning "HTTP $HTTP_CODE - Unexpected status"
            ;;
    esac

    # Show response preview
    log_info "Response preview:"
    head -5 /tmp/response_body.txt | sed 's/^/  /'
    rm -f /tmp/response_body.txt
}

# Test health endpoint
test_health_endpoint() {
    echo -e "\n${BLUE}=== Health Endpoint ===${NC}"

    ALB_DNS=$(get_terraform_output "alb_dns_name")

    if [ -z "$ALB_DNS" ] || [ "$ALB_DNS" = "null" ]; then
        return 1
    fi

    URL="http://$ALB_DNS/health"
    log_info "Testing: $URL"

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$URL" --connect-timeout 5 2>/dev/null)

    case $HTTP_CODE in
        200)
            log_success "Health endpoint returning 200"
            ;;
        404)
            log_warning "Health endpoint not found (verify endpoint path)"
            ;;
        502|503)
            log_failure "Health endpoint unavailable"
            ;;
        *)
            log_warning "Health endpoint returned $HTTP_CODE"
            ;;
    esac
}

# Test response headers
test_headers() {
    echo -e "\n${BLUE}=== Response Headers ===${NC}"

    ALB_DNS=$(get_terraform_output "alb_dns_name")

    if [ -z "$ALB_DNS" ] || [ "$ALB_DNS" = "null" ]; then
        return 1
    fi

    URL="http://$ALB_DNS"
    log_info "Headers from: $URL"

    HEADERS=$(curl -s -I "$URL" 2>/dev/null)

    if [ -z "$HEADERS" ]; then
        log_failure "Could not retrieve headers"
        return 1
    fi

    # Show key headers
    echo "$HEADERS" | grep -E "^(HTTP|Server|Content|Date)" | sed 's/^/  /'
}

# Test with different HTTP methods
test_http_methods() {
    echo -e "\n${BLUE}=== HTTP Methods ===${NC}"

    ALB_DNS=$(get_terraform_output "alb_dns_name")

    if [ -z "$ALB_DNS" ] || [ "$ALB_DNS" = "null" ]; then
        return 1
    fi

    URL="http://$ALB_DNS"

    for METHOD in GET POST PUT DELETE; do
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X "$METHOD" "$URL" --connect-timeout 5 2>/dev/null)
        log_info "$METHOD: $HTTP_CODE"
    done
}

# Performance test
test_performance() {
    echo -e "\n${BLUE}=== Performance Test ===${NC}"

    ALB_DNS=$(get_terraform_output "alb_dns_name")

    if [ -z "$ALB_DNS" ] || [ "$ALB_DNS" = "null" ]; then
        return 1
    fi

    URL="http://$ALB_DNS"
    log_info "Running 10 sequential requests..."

    TOTAL_TIME=0
    MIN_TIME=999
    MAX_TIME=0

    for i in {1..10}; do
        TIME=$(curl -s -o /dev/null -w "%{time_total}" "$URL" --connect-timeout 5 2>/dev/null)
        TOTAL_TIME=$(echo "$TOTAL_TIME + $TIME" | bc)

        if (( $(echo "$TIME < $MIN_TIME" | bc -l) )); then
            MIN_TIME=$TIME
        fi
        if (( $(echo "$TIME > $MAX_TIME" | bc -l) )); then
            MAX_TIME=$TIME
        fi

        echo -ne "  Request $i: ${TIME}s\r"
    done

    AVG_TIME=$(echo "scale=3; $TOTAL_TIME / 10" | bc)

    echo -e "\n  Average: ${AVG_TIME}s"
    echo -e "  Min: ${MIN_TIME}s"
    echo -e "  Max: ${MAX_TIME}s"

    if (( $(echo "$AVG_TIME < 1.0" | bc -l) )); then
        log_success "Response time excellent"
    elif (( $(echo "$AVG_TIME < 3.0" | bc -l) )); then
        log_success "Response time good"
    else
        log_warning "Response time slow (>3s)"
    fi
}

# Test HTTPS (if configured)
test_https() {
    echo -e "\n${BLUE}=== HTTPS (if configured) ===${NC}"

    ALB_DNS=$(get_terraform_output "alb_dns_name")

    if [ -z "$ALB_DNS" ] || [ "$ALB_DNS" = "null" ]; then
        return
    fi

    URL="https://$ALB_DNS"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$URL" --connect-timeout 5 2>/dev/null)

    if [ "$HTTP_CODE" = "000" ] || [ -z "$HTTP_CODE" ]; then
        log_warning "HTTPS not configured or not responding"
    else
        log_success "HTTPS responding with status $HTTP_CODE"
    fi
}

# Main
main() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Application Connectivity Tests${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "Time: $(date)\n"

    if ! aws sts get-caller-identity &>/dev/null; then
        log_failure "AWS credentials invalid"
        exit 1
    fi

    ALB_DNS=$(get_terraform_output "alb_dns_name")
    if [ -z "$ALB_DNS" ] || [ "$ALB_DNS" = "null" ]; then
        log_failure "Could not retrieve ALB DNS from Terraform outputs"
        exit 1
    fi

    log_info "ALB DNS: $ALB_DNS"

    test_dns
    test_http
    test_health_endpoint
    test_headers
    test_http_methods
    test_performance
    test_https

    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}Connectivity Tests Complete${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

main
