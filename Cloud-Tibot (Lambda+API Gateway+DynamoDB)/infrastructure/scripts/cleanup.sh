#!/bin/bash
# ⚠️ This script removes backup files - review first!

echo "⚠️  CLEANUP SCRIPT - This will DELETE files!"
echo ""
echo "Files to be deleted:"
echo "  - terraform.tfstate.backup (67 KB)"
echo "  - Any remaining .DS_Store or Thumbs.db files"
echo ""

read -p "Type 'DELETE' to confirm: " confirm
if [ "$confirm" != "DELETE" ]; then
  echo "❌ Aborted."
  exit 1
fi

echo "🗑️ Cleaning up backup and system files..."

# Remove backup file
if [ -f "terraform.tfstate.backup" ]; then
  git rm -f terraform.tfstate.backup
  echo "  ✅ Removed terraform.tfstate.backup"
fi

# Remove system files (Mac/Windows)
find . -name ".DS_Store" -type f -delete 2>/dev/null
find . -name "Thumbs.db" -type f -delete 2>/dev/null
find . -name "desktop.ini" -type f -delete 2>/dev/null

echo "✅ Cleanup complete."
