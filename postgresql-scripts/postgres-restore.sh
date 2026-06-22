#!/usr/bin/env bash
# PostgreSQL restore only (Ubuntu). Reads target config from .env.
# Usage: ./postgres-restore.sh ./backups/mydb_20260606_120000.dump
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/load-env.sh"

require PG_TARGET_HOST
require PG_TARGET_USER
require PG_TARGET_DB
PORT="${PG_TARGET_PORT:-5432}"

BACKUP_FILE="${1:-}"
if [ -z "$BACKUP_FILE" ]; then
  echo "Usage: ./postgres-restore.sh backup.dump" >&2
  exit 1
fi
if [ ! -f "$BACKUP_FILE" ]; then
  echo "Backup file not found: $BACKUP_FILE" >&2
  exit 1
fi

echo "Target database: $PG_TARGET_HOST / $PG_TARGET_DB"
read -r -p "Type YES to continue: " CONFIRM
[ "$CONFIRM" = "YES" ] || { echo "Cancelled."; exit 1; }

if [ -n "${PG_TARGET_PASSWORD:-}" ]; then
  export PGPASSWORD="$PG_TARGET_PASSWORD"
else
  read -r -s -p "Enter PostgreSQL password for $PG_TARGET_USER: " PGPASSWORD; echo
  export PGPASSWORD
fi

echo "Restoring $BACKUP_FILE to $PG_TARGET_DB..."

pg_restore \
  -h "$PG_TARGET_HOST" \
  -p "$PORT" \
  -U "$PG_TARGET_USER" \
  -d "$PG_TARGET_DB" \
  --clean \
  --if-exists \
  --no-owner \
  --no-privileges \
  "$BACKUP_FILE"

echo "Restore completed successfully."
