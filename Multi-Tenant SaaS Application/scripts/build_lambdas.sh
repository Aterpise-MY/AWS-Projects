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

  # Create deterministic zip with consistent timestamps
  rm -f "$ZIP_OUT"
  python3 << PYTHON_SCRIPT
import os
import zipfile

src_dir = "$SRC_DIR"
zip_out = "$ZIP_OUT"

# Use fixed date (1980-01-01 00:00:00) for all files for consistency
fixed_date_time = (1980, 1, 1, 0, 0, 0)

with zipfile.ZipFile(zip_out, 'w', zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(src_dir):
        for file in sorted(files):  # Sort for consistency
            file_path = os.path.join(root, file)
            arcname = os.path.relpath(file_path, src_dir)

            # Read file and add to zip with fixed timestamp
            with open(file_path, 'rb') as f:
                zinfo = zipfile.ZipInfo(arcname, date_time=fixed_date_time)
                zinfo.external_attr = 0o644 << 16  # Regular file, readable
                zf.writestr(zinfo, f.read(), compress_type=zipfile.ZIP_DEFLATED)
PYTHON_SCRIPT

  SIZE=$(du -sh "$ZIP_OUT" | cut -f1)
  echo "    Built: $ZIP_OUT ($SIZE)"
done

echo
echo "All Lambda packages built. You can now run terraform apply or cli/deploy.sh."
