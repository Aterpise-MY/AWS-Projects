#!/usr/bin/env bash
# ================================================================
# Install Lambda dependencies
# Run this before `terraform apply` or `cli/deploy.sh`
# Note: Terraform will create the zip files via archive_file data source
# ================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAMBDA_DIR="$SCRIPT_DIR/../lambda"

FUNCTIONS=(users orders auth)

for FUNC in "${FUNCTIONS[@]}"; do
  SRC_DIR="$LAMBDA_DIR/${FUNC}_handler"

  echo "─── Installing dependencies for $FUNC handler ───"

  if [[ ! -d "$SRC_DIR" ]]; then
    echo "ERROR: $SRC_DIR not found" >&2
    exit 1
  fi

  # Remove old dependencies to ensure clean install
  find "$SRC_DIR" -mindepth 1 -maxdepth 1 -not -name "handler.py" -type d -exec rm -rf {} + 2>/dev/null || true
  find "$SRC_DIR" -mindepth 1 -maxdepth 1 -not -name "handler.py" -type f ! -name "*.py" -delete 2>/dev/null || true

  # Install dependencies into the source directory with deterministic options
  # Using no-cache-dir for reproducibility across different environments
  pip install \
    -r "$LAMBDA_DIR/requirements.txt" \
    -t "$SRC_DIR" \
    --no-cache-dir \
    --quiet \
    --platform manylinux2014_x86_64 \
    --only-binary=:all:

  echo "    Dependencies installed"
done

echo
echo "All Lambda dependencies installed. Terraform will create zip files via archive_file."
