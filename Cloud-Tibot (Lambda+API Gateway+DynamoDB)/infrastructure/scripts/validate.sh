#!/bin/bash
set -e

echo "🔍 Validating CORTEX repository restructure..."

# Check directory structure
echo "📁 Checking directory structure..."
required_dirs=(
  "infrastructure/terraform"
  "src"
  "tests/unit"
  "tests/integration"
  "tests/fixtures"
  "scripts/build"
  "scripts/deployment"
  "scripts/monitoring"
  "scripts/testing"
  "docs/architecture"
  "docs/setup"
  "docs/deployment"
  "docs/integration"
  "docs/implementation"
  "docs/testing"
)

for dir in "${required_dirs[@]}"; do
  if [ -d "$dir" ]; then
    echo "  ✅ $dir"
  else
    echo "  ❌ MISSING: $dir"
    exit 1
  fi
done

# Check essential files
echo ""
echo "📄 Checking essential files..."
required_files=(
  "README.md"
  ".gitignore"
  "Makefile"
  "infrastructure/terraform/provider.tf"
  "infrastructure/terraform/lambda.tf"
  "docs/INDEX.md"
  "scripts/build/Build-LambdaPackages.ps1"
)

for file in "${required_files[@]}"; do
  if [ -f "$file" ]; then
    echo "  ✅ $file"
  else
    echo "  ❌ MISSING: $file"
    exit 1
  fi
done

# Check root directory is clean
echo ""
echo "📊 Root directory status..."
root_file_count=$(find . -maxdepth 1 -type f ! -name '.gitignore' | wc -l)
echo "  Files in root: $root_file_count (target: <10)"

if [ $root_file_count -lt 10 ]; then
  echo "  ✅ Root directory clean"
else
  echo "  ⚠️  Root still has too many files"
fi

# Verify Lambda modules exist
echo ""
echo "🔧 Checking Lambda modules..."
for module in src/module*; do
  if [ -f "$module/lambda_function.py" ] || [ -f "$module/pr_guardian.py" ]; then
    echo "  ✅ $module"
  else
    echo "  ❌ Missing code in $module"
    exit 1
  fi
done

# Check Terraform syntax
echo ""
echo "🏗️ Validating Terraform..."
cd infrastructure/terraform
if terraform fmt -check > /dev/null 2>&1; then
  echo "  ✅ Terraform formatting"
else
  echo "  ⚠️  Terraform needs formatting (run: terraform fmt)"
fi

if terraform validate > /dev/null 2>&1; then
  echo "  ✅ Terraform valid"
else
  echo "  ❌ Terraform validation failed"
  terraform validate
  exit 1
fi
cd ../..

echo ""
echo "✅ Validation complete! Repository structure is correct."
echo ""
echo "📝 Final steps:"
echo "1. Test Lambda build: cd scripts/build && ./Build-LambdaPackages.ps1"
echo "2. Review and update documentation links in README.md"
echo "3. Commit changes: git add -A && git commit -m 'Refactor: Enterprise architecture'"
