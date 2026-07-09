#!/usr/bin/env bash
# ===========================================================================
# build.sh — package the migration Lambda for python3.12 / x86_64.
# ---------------------------------------------------------------------------
# Produces a self-contained zip containing:
#   handler.py
#   psycopg2 (manylinux wheel, so it runs on the Lambda Linux runtime)
#   sql/  (a copy of ../schema/*.sql — the version-controlled DDL)
#
# Output: ../../terraform/modules/migration/dist/migration.zip
# Run from anywhere; paths are resolved relative to this script.
# Idempotent: rebuilds cleanly each run.
# ===========================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_DIR="$(cd "$HERE/../schema" && pwd)"
DIST_DIR="$(cd "$HERE/../../terraform/modules/migration" && pwd)/dist"
BUILD_DIR="$HERE/.build"
ZIP_PATH="$DIST_DIR/migration.zip"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/sql" "$DIST_DIR"

# Handler + DDL.
cp "$HERE/handler.py" "$BUILD_DIR/handler.py"
cp "$SCHEMA_DIR"/*.sql "$BUILD_DIR/sql/"

# psycopg2 built for the Lambda runtime (Amazon Linux, x86_64, cp312).
python3 -m pip install \
  --platform manylinux2014_x86_64 \
  --implementation cp \
  --python-version 3.12 \
  --only-binary=:all: \
  --upgrade \
  --target "$BUILD_DIR" \
  "psycopg2-binary==2.9.9"

# Zip it (deterministic-ish).
rm -f "$ZIP_PATH"
( cd "$BUILD_DIR" && zip -q -r -X "$ZIP_PATH" . -x '*.pyc' -x '*__pycache__*' )

echo "built: $ZIP_PATH"
