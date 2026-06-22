#!/usr/bin/env bash
# MySQL source -> target migration (Ubuntu). Reads config from .env.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/load-env.sh"

# Source
require MYSQL_HOST
require MYSQL_USER
require MYSQL_DB
SOURCE_PORT="${MYSQL_PORT:-3306}"

# Target
require MYSQL_TARGET_HOST
require MYSQL_TARGET_USER
require MYSQL_TARGET_DB
TARGET_PORT="${MYSQL_TARGET_PORT:-3306}"

BACKUP_DIR="$ROOT_DIR/backups"
mkdir -p "$BACKUP_DIR"

# Intermediate backup file: MYSQL_BACKUP_NAME from .env if set, else <DB>_<timestamp>.sql.gz
NAME="${MYSQL_BACKUP_NAME:-}"
if [ -n "$NAME" ]; then
  case "$NAME" in
    *.gz)  LEAF="$NAME" ;;
    *.sql) LEAF="$NAME.gz" ;;
    *)     LEAF="$NAME.sql.gz" ;;
  esac
  case "$LEAF" in
    /*) BACKUP_FILE="$LEAF" ;;
    *)  BACKUP_FILE="$BACKUP_DIR/$LEAF" ;;
  esac
else
  TIMESTAMP="$(date +"%Y%m%d_%H%M%S")"
  BACKUP_FILE="$BACKUP_DIR/${MYSQL_DB}_${TIMESTAMP}.sql.gz"
fi

echo "Starting MySQL migration..."
echo "Source: $MYSQL_HOST/$MYSQL_DB"
echo "Target: $MYSQL_TARGET_HOST/$MYSQL_TARGET_DB"

echo ""
echo "Target database to be written: $MYSQL_TARGET_HOST / $MYSQL_TARGET_DB"
read -r -p "Type YES to continue: " CONFIRM
[ "$CONFIRM" = "YES" ] || { echo "Cancelled."; exit 1; }

# ---- Step 1: backup source ----
echo ""
echo "Step 1: Taking compressed backup..."
if [ -n "${MYSQL_PASSWORD:-}" ]; then
  export MYSQL_PWD="$MYSQL_PASSWORD"
else
  read -r -s -p "Enter SOURCE MySQL password for $MYSQL_USER: " MYSQL_PWD; echo
  export MYSQL_PWD
fi

mysqldump \
  -h "$MYSQL_HOST" \
  -P "$SOURCE_PORT" \
  -u "$MYSQL_USER" \
  --ssl-mode=REQUIRED \
  --single-transaction \
  --set-gtid-purged=OFF \
  --no-tablespaces \
  --routines \
  --triggers \
  --events \
  "$MYSQL_DB" | gzip > "$BACKUP_FILE"

echo "Backup created: $BACKUP_FILE"

# ---- Step 2: restore to target ----
echo ""
echo "Step 2: Restoring backup to target..."
if [ -n "${MYSQL_TARGET_PASSWORD:-}" ]; then
  export MYSQL_PWD="$MYSQL_TARGET_PASSWORD"
else
  read -r -s -p "Enter TARGET MySQL password for $MYSQL_TARGET_USER: " MYSQL_PWD; echo
  export MYSQL_PWD
fi

gunzip < "$BACKUP_FILE" | mysql \
  -h "$MYSQL_TARGET_HOST" \
  -P "$TARGET_PORT" \
  -u "$MYSQL_TARGET_USER" \
  --ssl-mode=REQUIRED \
  "$MYSQL_TARGET_DB"

echo ""
echo "Migration completed successfully."
