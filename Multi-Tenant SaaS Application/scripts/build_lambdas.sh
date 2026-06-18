#!/usr/bin/env bash
# ================================================================
# Build Lambda deployment packages
# Run this before `terraform apply` or `cli/deploy.sh`
# ================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAMBDA_DIR="$SCRIPT_DIR/../lambda"

FUNCTIONS=(users orders auth)

for FUNC in "${FUNCTIONS[@]}"; do
  SRC_DIR="$LAMBDA_DIR/${FUNC}_handler"
  ZIP_OUT="$LAMBDA_DIR/${FUNC}_handler.zip"

  echo "─── Building $FUNC handler ───"

  if [[ ! -d "$SRC_DIR" ]]; then
    echo "ERROR: $SRC_DIR not found" >&2
    exit 1
  fi

  # Install dependencies into the source directory (Lambda deployment package layout)
  pip install \
    -r "$LAMBDA_DIR/requirements.txt" \
    -t "$SRC_DIR" \
    --upgrade \
    --quiet \
    --platform manylinux2014_x86_64 \
    --only-binary=:all:

  # Create the zip; handler.py must be at the root of the archive
  (cd "$SRC_DIR" && zip -qr "$ZIP_OUT" .)

  SIZE=$(du -sh "$ZIP_OUT" | cut -f1)
  echo "    Built: $ZIP_OUT ($SIZE)"
done

echo
echo "All Lambda packages built. You can now run terraform apply or cli/deploy.sh."
