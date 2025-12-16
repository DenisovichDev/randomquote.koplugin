#!/bin/bash
set -e

# -------- CONFIG --------
KINDLE_DRIVE="D:"
KINDLE_MOUNT="/mnt/d"
TARGET="$KINDLE_MOUNT/koreader"
# ------------------------

echo "Deploying KOReader to Kindle (PW3)..."

# Ensure Kindle is mounted (WSL USB hotplug is flaky)
if [ -z "$(ls -A "$KINDLE_MOUNT" 2>/dev/null)" ]; then
  echo "Kindle not visible in WSL, mounting now..."
  sudo mount -t drvfs $KINDLE_DRIVE $KINDLE_MOUNT
fi

# Sanity check
if [ ! -d "$KINDLE_MOUNT" ]; then
  echo "ERROR: Kindle mount point not found."
  exit 1
fi

if [ ! -d "$TARGET" ]; then
  echo "ERROR: $TARGET does not exist. Is KOReader installed on the Kindle?"
  exit 1
fi

echo "Syncing files..."
rsync -av \
  --delete \
  --exclude=".git" \
  --exclude=".github" \
  --exclude="build/" \
  --exclude="*.o" \
  --exclude="*.a" \
  --exclude="quotes.lua" \
  --exclude="deploy-kindle.sh" \
  --exclude="*.log" \
  ./ \
  "$TARGET"

sync
echo "Deploy complete."
echo "Safely eject the Kindle from Windows before unplugging."
