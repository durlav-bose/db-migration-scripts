#!/usr/bin/env bash
# PostgreSQL backup only (Ubuntu). Reads config from .env.
# Backup file name comes from PG_BACKUP_NAME in .env; if blank it defaults
# to <DB>_<timestamp>.dump
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/load-env.sh"

require PG_HOST
require PG_USER
require PG_DB
PORT="${PG_PORT:-5432}"

BACKUP_DIR="$ROOT_DIR/backups"
mkdir -p "$BACKUP_DIR"

# Output file: PG_BACKUP_NAME from .env if set, else <DB>_<timestamp>.dump
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

if [ -n "${PG_PASSWORD:-}" ]; then
  export PGPASSWORD="$PG_PASSWORD"
else
  read -r -s -p "Enter PostgreSQL password for $PG_USER: " PGPASSWORD; echo
  export PGPASSWORD
fi

echo "Backing up PostgreSQL database: $PG_DB"

pg_dump \
  -h "$PG_HOST" \
  -p "$PORT" \
  -U "$PG_USER" \
  -d "$PG_DB" \
  -Fc \
  -f "$BACKUP_FILE"

echo "Backup completed:"
echo "$BACKUP_FILE"
