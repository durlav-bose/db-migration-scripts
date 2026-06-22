#!/usr/bin/env bash
# MySQL backup only (Ubuntu). Reads config from .env.
# Backup file name comes from MYSQL_BACKUP_NAME in .env; if blank it defaults
# to <DB>_<timestamp>.sql.gz
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/load-env.sh"

require MYSQL_HOST
require MYSQL_USER
require MYSQL_DB
PORT="${MYSQL_PORT:-3306}"

BACKUP_DIR="$ROOT_DIR/backups"
mkdir -p "$BACKUP_DIR"

# Output file: MYSQL_BACKUP_NAME from .env if set, else <DB>_<timestamp>.sql.gz
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

# Password: use .env value if set, otherwise prompt securely.
if [ -n "${MYSQL_PASSWORD:-}" ]; then
  export MYSQL_PWD="$MYSQL_PASSWORD"
else
  read -r -s -p "Enter MySQL password for $MYSQL_USER: " MYSQL_PWD; echo
  export MYSQL_PWD
fi

echo "Backing up MySQL database: $MYSQL_DB"

mysqldump \
  -h "$MYSQL_HOST" \
  -P "$PORT" \
  -u "$MYSQL_USER" \
  --ssl-mode=REQUIRED \
  --single-transaction \
  --set-gtid-purged=OFF \
  --no-tablespaces \
  --routines \
  --triggers \
  --events \
  "$MYSQL_DB" | gzip > "$BACKUP_FILE"

echo "Backup completed:"
echo "$BACKUP_FILE"
