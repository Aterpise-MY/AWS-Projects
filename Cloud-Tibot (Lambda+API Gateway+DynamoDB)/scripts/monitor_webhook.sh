#!/bin/bash
# Real-time Webhook Monitoring Dashboard

REGION="us-east-1"
FUNCTION_NAME="cortex_git_radar"
LOG_GROUP="/aws/lambda/cortex_git_radar"

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

clear
echo -e "${CYAN}"
echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║                  🚀 WEBHOOK MONITORING DASHBOARD                           ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Check Lambda status
echo -e "\n${BLUE}📡 Lambda Function Status${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

LAMBDA_STATUS=$(aws lambda get-function --function-name $FUNCTION_NAME --region $REGION 2>&1)

if echo "$LAMBDA_STATUS" | grep -q "FunctionName"; then
    STATE=$(echo "$LAMBDA_STATUS" | grep -o '"State":"[^"]*"' | cut -d'"' -f4)
    LAST_UPDATE=$(echo "$LAMBDA_STATUS" | grep -o '"LastUpdateStatus":"[^"]*"' | cut -d'"' -f4)
    MEMORY=$(echo "$LAMBDA_STATUS" | grep -o '"MemorySize":[^,]*' | cut -d':' -f2)
    TIMEOUT=$(echo "$LAMBDA_STATUS" | grep -o '"Timeout":[^,]*' | cut -d':' -f2)
    
    echo -e "${GREEN}✅ Function: $FUNCTION_NAME${NC}"
    echo "   State: $STATE"
    echo "   Last Update: $LAST_UPDATE"
    echo "   Memory: ${MEMORY}MB"
    echo "   Timeout: ${TIMEOUT}s"
else
    echo -e "${RED}❌ Lambda function not found${NC}"
fi

# Check environment variables
echo -e "\n${BLUE}⚙️  Environment Variables${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ENV_VARS=$(aws lambda get-function-configuration --function-name $FUNCTION_NAME --region $REGION --query 'Environment.Variables' 2>&1)

if echo "$ENV_VARS" | grep -q "TELEGRAM_TOPIC_ID"; then
    TOPIC_ID=$(echo "$ENV_VARS" | grep -o '"TELEGRAM_TOPIC_ID":"[^"]*"' | cut -d'"' -f4)
    CHAT_ID=$(echo "$ENV_VARS" | grep -o '"TELEGRAM_CHAT_ID":"[^"]*"' | cut -d'"' -f4)
    REPO_NAME=$(echo "$ENV_VARS" | grep -o '"GITHUB_REPO_NAME":"[^"]*"' | cut -d'"' -f4)
    REPO_OWNER=$(echo "$ENV_VARS" | grep -o '"GITHUB_REPO_OWNER":"[^"]*"' | cut -d'"' -f4)
    
    echo -e "${GREEN}✅ Environment Variables Configured${NC}"
    echo "   TELEGRAM_TOPIC_ID: $TOPIC_ID"
    echo "   TELEGRAM_CHAT_ID: $CHAT_ID"
    echo "   GITHUB_REPO_NAME: $REPO_NAME"
    echo "   GITHUB_REPO_OWNER: $REPO_OWNER"
    
    # Validate configuration
    if [ "$TOPIC_ID" != "111" ]; then
        echo -e "   ${RED}⚠️  TOPIC_ID should be 111${NC}"
    fi
    if [ "$CHAT_ID" != "-1003702164149" ]; then
        echo -e "   ${RED}⚠️  CHAT_ID should include -100 prefix${NC}"
    fi
else
    echo -e "${RED}❌ Environment variables not properly configured${NC}"
fi

# Check recent logs
echo -e "\n${BLUE}📊 Recent Lambda Invocations (Last 10 minutes)${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TIMESTAMP=$(date -u -d '10 minutes ago' +%s)000 2>/dev/null || date -u -v-10M +%s000

RECENT_LOGS=$(aws logs filter-log-events \
    --log-group-name $LOG_GROUP \
    --start-time $TIMESTAMP \
    --filter-pattern "GIT RADAR" \
    --region $REGION 2>&1 | grep -c "Routing to" || echo "0")

if [ "$RECENT_LOGS" -gt 0 ]; then
    echo -e "${GREEN}✅ Recent Events Detected: $RECENT_LOGS${NC}"
else
    echo -e "${YELLOW}⚠️  No recent events in last 10 minutes${NC}"
fi

# Check for errors
echo -e "\n${BLUE}🚨 Error Check (Last 24 hours)${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ERROR_COUNT=$(aws logs filter-log-events \
    --log-group-name $LOG_GROUP \
    --filter-pattern "[ERROR]" \
    --region $REGION 2>&1 | grep -c "ERROR" || echo "0")

if [ "$ERROR_COUNT" -eq 0 ]; then
    echo -e "${GREEN}✅ No errors found${NC}"
else
    echo -e "${RED}❌ Found $ERROR_COUNT error messages${NC}"
    echo ""
    aws logs filter-log-events \
        --log-group-name $LOG_GROUP \
        --filter-pattern "[ERROR]" \
        --region $REGION 2>&1 | head -5
fi

# Check Telegram integration
echo -e "\n${BLUE}📱 Telegram Integration Check${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TELEGRAM_ATTEMPTS=$(aws logs filter-log-events \
    --log-group-name $LOG_GROUP \
    --filter-pattern "Telegram" \
    --start-time $TIMESTAMP \
    --region $REGION 2>&1 | grep -c "Telegram" || echo "0")

if [ "$TELEGRAM_ATTEMPTS" -gt 0 ]; then
    echo -e "${GREEN}✅ Telegram messages sent: $TELEGRAM_ATTEMPTS${NC}"
else
    echo -e "${YELLOW}⚠️  No Telegram attempts in last 10 minutes${NC}"
fi

# API Gateway check
echo -e "\n${BLUE}🌐 API Gateway Status${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

API_ID="6w72v0646f"
API_STATUS=$(aws apigatewayv2 get-api --api-id $API_ID --region $REGION 2>&1)

if echo "$API_STATUS" | grep -q "ApiId"; then
    echo -e "${GREEN}✅ API Gateway is operational${NC}"
    echo "   Endpoint: https://$API_ID.execute-api.us-east-1.amazonaws.com"
else
    echo -e "${RED}❌ API Gateway connection failed${NC}"
fi

# Summary
echo -e "\n${CYAN}"
echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║                            NEXT ACTIONS                                    ║"
echo "╠════════════════════════════════════════════════════════════════════════════╣"
echo "║ 1. Run webhook test: python3 scripts/test_webhook_all_events.py            ║"
echo "║ 2. Monitor logs:     aws logs tail $LOG_GROUP --follow                     ║"
echo "║ 3. Check Telegram:   CORTEX Git Radar topic (111)                          ║"
echo "║ 4. Verify webhook:   GitHub repo → Settings → Webhooks → Recent Deliveries║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
