#!/bin/bash

# ═══════════════════════════════════════════════════════════════════════════════
# 🔐 Credentials Helper — Find & Verify Your Tokens
# ═══════════════════════════════════════════════════════════════════════════════

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}"
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║          🔐 Copilot PR Guardian — Credentials Helper              ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# Section 1: GitHub Token
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${YELLOW}1️⃣  GitHub Personal Access Token${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -z "$GITHUB_TOKEN" ]; then
    echo -e "${RED}❌ GITHUB_TOKEN not set in environment${NC}"
    echo ""
    echo "Options:"
    echo ""
    echo "  Option A: Use GitHub CLI (fastest)"
    echo "  ┌─ Run this: ${YELLOW}gh auth token${NC}"
    echo "  └─ This will output your existing token"
    echo ""
    echo "  Option B: Create new token at"
    echo "  ┌─ https://github.com/settings/tokens"
    echo "  ├─ Click 'Generate new token (classic)'"
    echo "  ├─ Scopes: ✅ repo, ✅ workflow, ✅ read:org"
    echo "  └─ Copy the token (format: ghp_...)"
    echo ""
    echo "Once you have your token, set it:"
    echo "  ${YELLOW}export GITHUB_TOKEN=\"ghp_your_token_here\"${NC}"
    echo ""
    read -p "Do you have a GitHub token ready? (yes/no) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        read -p "Paste your GitHub token (hidden): " -s GITHUB_TOKEN
        echo
        export GITHUB_TOKEN
    else
        echo -e "${RED}❌ Cannot continue without GitHub token${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}✅ GITHUB_TOKEN is set${NC}"
    echo "  Token (hidden): ghp_***${GITHUB_TOKEN: -8}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section 2: Telegram Token
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${YELLOW}2️⃣  Telegram Bot Token${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

EXPECTED_TELEGRAM_TOKEN="8281522719:AAHb8gk-sIVpjnGmOIYbE5FuzZ347J4FKTc"

if [ -z "$TELEGRAM_TOKEN" ]; then
    echo -e "${RED}❌ TELEGRAM_TOKEN not set${NC}"
    echo ""
    echo "Pre-configured token (Cloud-Tibot bot):"
    echo "  ${YELLOW}export TELEGRAM_TOKEN=\"$EXPECTED_TELEGRAM_TOKEN\"${NC}"
    export TELEGRAM_TOKEN="$EXPECTED_TELEGRAM_TOKEN"
    echo ""
    echo -e "${GREEN}✅ Set automatically${NC}"
else
    if [ "$TELEGRAM_TOKEN" = "$EXPECTED_TELEGRAM_TOKEN" ]; then
        echo -e "${GREEN}✅ TELEGRAM_TOKEN is correct${NC}"
    else
        echo -e "${YELLOW}⚠️  TELEGRAM_TOKEN doesn't match expected value${NC}"
        echo "  Your token: ${TELEGRAM_TOKEN:0:20}..."
        echo "  Expected:   ${EXPECTED_TELEGRAM_TOKEN:0:20}..."
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section 3: Telegram Chat ID
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${YELLOW}3️⃣  Telegram Chat ID${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

EXPECTED_CHAT_ID="-1003702164149"

if [ -z "$TELEGRAM_CHAT_ID" ]; then
    echo -e "${RED}❌ TELEGRAM_CHAT_ID not set${NC}"
    echo ""
    echo "Pre-configured for Aterpise-MY main group:"
    echo "  ${YELLOW}export TELEGRAM_CHAT_ID=\"$EXPECTED_CHAT_ID\"${NC}"
    export TELEGRAM_CHAT_ID="$EXPECTED_CHAT_ID"
    echo ""
    echo -e "${GREEN}✅ Set automatically${NC}"
else
    if [ "$TELEGRAM_CHAT_ID" = "$EXPECTED_CHAT_ID" ]; then
        echo -e "${GREEN}✅ TELEGRAM_CHAT_ID is correct${NC}"
    else
        echo -e "${YELLOW}⚠️  TELEGRAM_CHAT_ID doesn't match expected value${NC}"
        echo "  Your ID: $TELEGRAM_CHAT_ID"
        echo "  Expected: $EXPECTED_CHAT_ID"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section 4: Verify all tokens
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${YELLOW}4️⃣  Verification${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Verify GitHub token format
if [[ $GITHUB_TOKEN == ghp_* ]]; then
    echo -e "${GREEN}✅ GitHub token format is correct${NC}"
else
    echo -e "${RED}❌ GitHub token format is invalid (should start with ghp_)${NC}"
    echo "   Your token: ${GITHUB_TOKEN:0:20}..."
fi

# Test Telegram token
echo -n "Testing Telegram bot token... "
TELEGRAM_TEST=$(curl -s "https://api.telegram.org/bot${TELEGRAM_TOKEN}/getMe" | grep -q '"ok":true' && echo "OK" || echo "FAIL")

if [ "$TELEGRAM_TEST" = "OK" ]; then
    echo -e "${GREEN}✅ Valid${NC}"
else
    echo -e "${RED}❌ Invalid${NC}"
    echo "  Check your token at: https://api.telegram.org/bot${TELEGRAM_TOKEN}/getMe"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ All credentials ready!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
echo ""

echo "Export these for future sessions:"
echo ""
echo "  ${YELLOW}export GITHUB_TOKEN=\"${GITHUB_TOKEN}\"${NC}"
echo "  ${YELLOW}export TELEGRAM_TOKEN=\"${TELEGRAM_TOKEN}\"${NC}"
echo "  ${YELLOW}export TELEGRAM_CHAT_ID=\"${TELEGRAM_CHAT_ID}\"${NC}"
echo ""

echo "Or save to ~/.bashrc or ~/.zshrc:"
echo ""
echo "  cat >> ~/.zshrc <<'EOF'"
echo "  # Cloud-Tibot Copilot Guardian"
echo "  export GITHUB_TOKEN=\"${GITHUB_TOKEN}\""
echo "  export TELEGRAM_TOKEN=\"${TELEGRAM_TOKEN}\""
echo "  export TELEGRAM_CHAT_ID=\"${TELEGRAM_CHAT_ID}\""
echo "  EOF"
echo ""

# Save to current session
export GITHUB_TOKEN
export TELEGRAM_TOKEN
export TELEGRAM_CHAT_ID

echo -e "${GREEN}✅ Credentials exported to this session${NC}"
echo ""

# Offer to run deployment
read -p "Ready to deploy Lambda? (yes/no) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    cd /Users/brendonang/Code/Cloud-Tibot
    bash scripts/deploy_copilot_guardian.sh
fi
