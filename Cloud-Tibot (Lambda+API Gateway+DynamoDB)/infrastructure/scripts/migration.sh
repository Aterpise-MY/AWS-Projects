#!/bin/bash
set -e

echo "🚀 Starting CORTEX repository restructure..."

# Safety: Create backup
echo "📦 Creating backup..."
tar -czf "../cortex_backup_$(date +%Y%m%d_%H%M%S).tar.gz" .

# Safety: Commit current state
echo "💾 Creating pre-restructure commit..."
git add -A
git commit -m "Pre-restructure snapshot" || true
git tag "pre-restructure-$(date +%Y%m%d)"

# Create new directory structure
echo "📁 Creating new directory structure..."
mkdir -p infrastructure/terraform
mkdir -p tests/{unit,integration,fixtures}
mkdir -p scripts/{build,deployment,monitoring,testing,telegram}
mkdir -p docs/{architecture,setup,deployment,integration,implementation,testing}

# Move infrastructure
echo "🏗️ Moving infrastructure files..."
git mv *.tf infrastructure/terraform/
git mv terraform.tfvars.example infrastructure/
git mv tfplan-dev infrastructure/terraform/ 2>/dev/null || true
git rm terraform.tfstate.backup

# Move documentation
echo "📚 Reorganizing documentation..."
cd docs

git mv ../COMPLETE_SYSTEM_SUMMARY.md architecture/

mkdir -p setup
git mv ../QUICK_START_30MIN.md setup/
git mv ../QUICKSTART_OPENAI.md setup/
git mv ../COPILOT_AUTH_SETUP.md setup/
git mv ../GITHUB_APP_SETUP.md setup/
git mv ../MONITOR_SETUP.md setup/

mkdir -p deployment
git mv ../DEPLOYMENT_CHECKLIST.md deployment/
git mv ../DEPLOYMENT_CHECKLIST_GITHUB_ACTIONS.md deployment/

mkdir -p integration
git mv GITHUB_COPILOT_INTEGRATION.md integration/ 2>/dev/null || true
git mv GITHUB_COPILOT_SDK_INTEGRATION.md integration/ 2>/dev/null || true
git mv COPILOT_SDK_QUICK_START.md integration/ 2>/dev/null || true
git mv ../GITHUB_AI_INTEGRATION_GUIDE.md integration/
git mv ../INTEGRATION_CHECKLIST.md integration/
git mv ../GITHUB_ACTIONS_TELEGRAM_GUIDE.md integration/

mkdir -p implementation
git mv ../CORTEX_GUARDIAN_README.md implementation/
git mv ../CORTEX_GUARDIAN_IMPLEMENTATION.md implementation/
git mv ../CORTEX_GUARDIAN_QUICKSTART.md implementation/
git mv ../ACTION_PLAN.md implementation/
git mv ../AUTH_FIX_SUMMARY.md implementation/
git mv ../IMPLEMENTATION_COMPLETE.md implementation/
git mv ../GITHUB_ACTIONS_SUMMARY.md implementation/

mkdir -p testing
git mv ../TESTING_GUIDE.md testing/
git mv ../TEST_SUMMARY.md testing/

git mv ../INDEX.md .

cd ..

# Move scripts
echo "⚙️ Reorganizing scripts..."
git mv Build-LambdaPackages.ps1 scripts/build/
git mv setup-github-actions.ps1 scripts/deployment/
git mv monitor.ps1 scripts/monitoring/
git mv monitor_logs.py scripts/monitoring/
git mv requirements-monitor.txt scripts/monitoring/requirements.txt
git mv Test-AllPipelines.ps1 scripts/testing/

# Reorganize telegram scripts
if [ -f "scripts/telegram_bot.py" ]; then
  mkdir -p scripts/telegram
  git mv scripts/telegram_bot.py scripts/telegram/ 2>/dev/null || true
  git mv scripts/requirements.txt scripts/telegram/ 2>/dev/null || true
fi

# Move tests
echo "🧪 Reorganizing tests..."
git mv test-payloads tests/fixtures
git mv test-auth.json tests/fixtures/
git mv test-github-push-event.json tests/fixtures/

echo "✅ File migration complete!"
echo ""
echo "⚠️  NEXT STEPS:"
echo "1. Run validation script: ./validate.sh"
echo "2. Update file references (see ARCHITECTURE_AUDIT_REPORT.md Phase 3)"
echo "3. Test Terraform: cd infrastructure/terraform && terraform plan"
echo "4. Test Lambda build: cd scripts/build && ./Build-LambdaPackages.ps1"
echo "5. Commit changes: git add -A && git commit -m 'Refactor: Enterprise architecture'"
