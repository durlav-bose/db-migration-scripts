#!/usr/bin/env bash
# PostgreSQL source -> target migration (Ubuntu). Reads config from .env.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/load-env.sh"

# Source
require PG_HOST
require PG_USER
require PG_DB
SOURCE_PORT="${PG_PORT:-5432}"

# Target
require PG_TARGET_HOST
require PG_TARGET_USER
require PG_TARGET_DB
TARGET_PORT="${PG_TARGET_PORT:-5432}"

BACKUP_DIR="$ROOT_DIR/backups"
mkdir -p "$BACKUP_DIR"

# Intermediate backup file: PG_BACKUP_NAME from .env if set, else <DB>_<timestamp>.dump
NAME="${PG_BACKUP_NAME:-}"
if [ -n "$NAME" ]; then
  case "$NAME" in
    *.dump) LEAF="$NAME" ;;
    *)      LEAF="$NAME.dump" ;;
  esac
  case "$LEAF" in
    /*) BACKUP_FILE="$LEAF" ;;
    *)  BACKUP_FILE="$BACKUP_DIR/$LEAF" ;;
  esac
else
  TIMESTAMP="$(date +"%Y%m%d_%H%M%S")"
  BACKUP_FILE="$BACKUP_DIR/${PG_DB}_${TIMESTAMP}.dump"
fi

echo "Starting PostgreSQL migration..."
echo "Source: $PG_HOST/$PG_DB"
echo "Target: $PG_TARGET_HOST/$PG_TARGET_DB"

echo ""
echo "Target database to be written: $PG_TARGET_HOST / $PG_TARGET_DB"
read -r -p "Type YES to continue: " CONFIRM
[ "$CONFIRM" = "YES" ] || { echo "Cancelled."; exit 1; }

# ---- Step 1: backup source (custom format, already compressed) ----
echo ""
echo "Step 1: Taking PostgreSQL custom-format backup..."
if [ -n "${PG_PASSWORD:-}" ]; then
  export PGPASSWORD="$PG_PASSWORD"
else
  read -r -s -p "Enter SOURCE PostgreSQL password for $PG_USER: " PGPASSWORD; echo
  export PGPASSWORD
fi

pg_dump \
  -h "$PG_HOST" \
  -p "$SOURCE_PORT" \
  -U "$PG_USER" \
  -d "$PG_DB" \
  -Fc \
  -f "$BACKUP_FILE"

echo "Backup created: $BACKUP_FILE"

# ---- Step 2: restore to target ----
echo ""
echo "Step 2: Restoring to target..."
if [ -n "${PG_TARGET_PASSWORD:-}" ]; then
  export PGPASSWORD="$PG_TARGET_PASSWORD"
else
  read -r -s -p "Enter TARGET PostgreSQL password for $PG_TARGET_USER: " PGPASSWORD; echo
  export PGPASSWORD
fi

pg_restore \
  -h "$PG_TARGET_HOST" \
  -p "$TARGET_PORT" \
  -U "$PG_TARGET_USER" \
  -d "$PG_TARGET_DB" \
  --clean \
  --if-exists \
  --no-owner \
  --no-privileges \
  "$BACKUP_FILE"

echo ""
echo "PostgreSQL migration completed successfully."
