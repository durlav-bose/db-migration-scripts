#!/usr/bin/env bash
# Loads .env (from this file's directory) and exports all keys for child processes.
# Dot-source it from another script:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   ROOT_DIR="$(dirname "$SCRIPT_DIR")"   # scripts live in a subfolder; loader is at root
#   source "$ROOT_DIR/load-env.sh"
#   require MYSQL_HOST

_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$_ENV_DIR/.env}"

if [ ! -f "$ENV_FILE" ]; then
  echo "Env file not found: $ENV_FILE" >&2
  exit 1
fi

# set -a => every variable assigned while sourcing .env is exported.
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# require KEY -> exit with a clear message if it's missing/empty in .env
require() {
  if [ -z "${!1:-}" ]; then
    echo "Missing required key '$1' in $ENV_FILE" >&2
    exit 1
  fi
}
