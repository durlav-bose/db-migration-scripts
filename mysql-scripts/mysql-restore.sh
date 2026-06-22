#!/usr/bin/env bash
# MySQL restore only (Ubuntu). Reads target config from .env.
# Usage: ./mysql-restore.sh ./backups/mydb_20260606_120000.sql.gz
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/load-env.sh"

require MYSQL_TARGET_HOST
require MYSQL_TARGET_USER
require MYSQL_TARGET_DB
PORT="${MYSQL_TARGET_PORT:-3306}"

BACKUP_FILE="${1:-}"
if [ -z "$BACKUP_FILE" ]; then
  echo "Usage: ./mysql-restore.sh backup.sql.gz" >&2
  exit 1
fi
if [ ! -f "$BACKUP_FILE" ]; then
  echo "Backup file not found: $BACKUP_FILE" >&2
  exit 1
fi

echo "Target database: $MYSQL_TARGET_HOST / $MYSQL_TARGET_DB"
read -r -p "Type YES to continue: " CONFIRM
[ "$CONFIRM" = "YES" ] || { echo "Cancelled."; exit 1; }

if [ -n "${MYSQL_TARGET_PASSWORD:-}" ]; then
  export MYSQL_PWD="$MYSQL_TARGET_PASSWORD"
else
  read -r -s -p "Enter MySQL password for $MYSQL_TARGET_USER: " MYSQL_PWD; echo
  export MYSQL_PWD
fi

echo "Restoring $BACKUP_FILE to $MYSQL_TARGET_DB..."

if [[ "$BACKUP_FILE" == *.gz ]]; then
  gunzip < "$BACKUP_FILE" | mysql \
    -h "$MYSQL_TARGET_HOST" \
    -P "$PORT" \
    -u "$MYSQL_TARGET_USER" \
    --ssl-mode=REQUIRED \
    "$MYSQL_TARGET_DB"
else
  mysql \
    -h "$MYSQL_TARGET_HOST" \
    -P "$PORT" \
    -u "$MYSQL_TARGET_USER" \
    --ssl-mode=REQUIRED \
    "$MYSQL_TARGET_DB" < "$BACKUP_FILE"
fi

echo "Restore completed successfully."
