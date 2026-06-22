# Database Backup, Restore & Migration Scripts (Ubuntu / Bash)

This document contains reusable **bash** scripts for Ubuntu:

- MySQL backup
- MySQL restore
- MySQL source → target migration
- PostgreSQL backup
- PostgreSQL restore
- PostgreSQL source → target migration

> **Windows users:** see the companion doc `db_backup_restore_migration_windows.md`
> (PowerShell `.ps1` scripts). Both the `.sh` and `.ps1` scripts read the **same
> `.env` file**, so configuration is shared across Windows and Ubuntu.

---

## Project layout

Scripts are grouped by database engine. Shared config and the `.env` loader live
at the repo root and are read by every script (each script resolves the root as
its own parent folder):

```
db-migration-scripts/
├─ .env  .env.example  .gitignore
├─ load-env.ps1  load-env.sh        (shared loaders)
├─ backups/                         (all backups land here)
├─ docs/                            (this file + the Windows doc)
├─ mysql-scripts/        mysql-backup.sh   mysql-restore.sh   mysql-migrate.sh   (+ .ps1)
└─ postgresql-scripts/   postgres-backup.sh  postgres-restore.sh  postgres-migrate.sh   (+ .ps1)
```

Run scripts **from the repo root** so the relative `./backups/...` paths line up,
e.g. `./mysql-scripts/mysql-backup.sh`.

---

# 0. Configuration via `.env` (read by every script)

Instead of hard-coding hosts/users inside each script, all settings live in a
single `.env` file. Copy the template and fill it in:

```bash
cp .env.example .env
nano .env
```

`.env`:

```bash
# ---- MySQL source / backup ----
MYSQL_HOST=your-host.rds.amazonaws.com
MYSQL_PORT=3306
MYSQL_USER=admin
MYSQL_DB=your_database
# Optional: if set, scripts use it instead of prompting. Leave blank to be prompted.
MYSQL_PASSWORD=
# Optional backup file name (overwritten each run). Blank => <DB>_<timestamp>.sql.gz
MYSQL_BACKUP_NAME=

# ---- MySQL target (for restore / migrate) ----
MYSQL_TARGET_HOST=
MYSQL_TARGET_PORT=3306
MYSQL_TARGET_USER=
MYSQL_TARGET_DB=
MYSQL_TARGET_PASSWORD=

# ---- PostgreSQL source / backup ----
PG_HOST=
PG_PORT=5432
PG_USER=
PG_DB=
PG_PASSWORD=
# Optional backup file name (overwritten each run). Blank => <DB>_<timestamp>.dump
PG_BACKUP_NAME=

# ---- PostgreSQL target (for restore / migrate) ----
PG_TARGET_HOST=
PG_TARGET_PORT=5432
PG_TARGET_USER=
PG_TARGET_DB=
PG_TARGET_PASSWORD=
```

Each script loads `.env` through a shared helper, `load-env.sh`:

```bash
#!/usr/bin/env bash
# Loads .env (from this file's directory) and exports all keys for child processes.
_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$_ENV_DIR/.env}"

if [ ! -f "$ENV_FILE" ]; then
  echo "Env file not found: $ENV_FILE" >&2
  exit 1
fi

# set -a => every variable assigned while sourcing .env is exported.
set -a
. "$ENV_FILE"
set +a

# require KEY -> exit with a clear message if it's missing/empty in .env
require() {
  if [ -z "${!1:-}" ]; then
    echo "Missing required key '$1' in $ENV_FILE" >&2
    exit 1
  fi
}
```

### Backup file naming rules

`MYSQL_BACKUP_NAME` (and `PG_BACKUP_NAME`) set the output name when **creating** a
backup. Best practice is a **bare filename** — the script automatically places it
in the root `backups/` folder:

| Value in `.env` | Resulting file | OK? |
|---|---|---|
| *(blank)* | `backups/<DB>_<timestamp>.sql.gz` (unique each run) | ✅ default |
| `claim_portal_backup` | `backups/claim_portal_backup.sql.gz` (extension auto-added) | ✅ |
| `claim_portal_backup.sql.gz` | `backups/claim_portal_backup.sql.gz` | ✅ recommended |
| `backups/claim_portal_backup.sql.gz` | `backups/backups/claim_portal_backup.sql.gz` (double-nested) | ❌ |
| `/backups/claim_portal_backup.sql.gz` | treated as an **absolute** path (filesystem root) | ❌ usually fails |

Rules:

- Use just the name. For PostgreSQL use `PG_BACKUP_NAME` with a `.dump` name.
- **Don't** prefix with `backups/` (double-nests) and **don't** start with `/`
  (read as an absolute path).
- The extension is auto-added if missing (`.sql.gz` for MySQL, `.dump` for Postgres).
- When set, the backup is **overwritten every run** (no history). Leave blank for
  a unique `<DB>_<timestamp>` name.
- **Restore** does **not** use this key — it takes the backup file as an explicit
  argument, e.g.
  `./mysql-scripts/mysql-restore.sh ./backups/claim_portal_backup.sql.gz`.

> **Passwords:** leave the `*_PASSWORD` keys blank to be prompted securely at
> runtime (the password is hidden and never written to disk). Fill them in only
> for unattended/scheduled runs. The `.env` file is git-ignored — never commit it.

---

# 1. MySQL Migration Script

Create file:

```bash
nano mysql-scripts/mysql-migrate.sh
```

Paste:

```bash
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
```

Make executable:

```bash
chmod +x mysql-scripts/mysql-migrate.sh
```

Run:

```bash
./mysql-scripts/mysql-migrate.sh
```

---

# Why These MySQL Options Are Used

## `set -euo pipefail`

Hardened version of `set -e`:

- `-e` — stop on the first failing command.
- `-u` — error on unset variables (catches typos in `.env` keys).
- `-o pipefail` — a pipeline (e.g. `mysqldump | gzip`) fails if **any** stage
  fails, not just the last one.

Why:

- Prevents continuing after a failed backup.
- Safer for migration.

---

## `--single-transaction`

Creates a consistent backup for InnoDB tables without locking the whole database.

Why:

- Good for production databases.
- Reduces downtime/locking.

Note:

- Best for InnoDB tables.
- Not perfect for MyISAM tables.

---

## `--set-gtid-purged=OFF` (required for AWS RDS)

Stops `mysqldump` from capturing GTID coordinates, which otherwise requires a
global read lock (`FLUSH TABLES WITH READ LOCK`).

Why:

- RDS does **not** grant the `RELOAD`/`SUPER` privilege to the master user, so the
  lock fails with `Access denied ... (1045)`.
- You also don't want GTID state when restoring into a *different* server — it
  causes `GTID_PURGED can only be set when GTID_EXECUTED is empty` errors.

---

## `--no-tablespaces` (recommended for AWS RDS)

Skips dumping tablespace definitions, which need the `PROCESS` privilege.

Why:

- RDS doesn't grant `PROCESS` to the master user, so without this you hit
  `Access denied; you need (at least one of) the PROCESS privilege(s)`.

---

## `--routines`

Includes stored procedures and functions.

---

## `--triggers`

Includes triggers.

---

## `--events`

Includes MySQL scheduled events.

---

## `gzip`

Compresses the backup.

Why:

- Smaller file size.
- Faster transfer/upload.
- Saves disk space.

---

# 2. MySQL Backup Only Script

Create:

```bash
nano mysql-scripts/mysql-backup.sh
```

Paste:

```bash
#!/usr/bin/env bash
# MySQL backup only (Ubuntu). Reads config from .env.
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
```

Run:

```bash
chmod +x mysql-scripts/mysql-backup.sh
./mysql-scripts/mysql-backup.sh
```

---

# 3. MySQL Restore Only Script

Create:

```bash
nano mysql-scripts/mysql-restore.sh
```

Paste:

```bash
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
```

Run:

```bash
chmod +x mysql-scripts/mysql-restore.sh
./mysql-scripts/mysql-restore.sh ./backups/mydb_20260606_120000.sql.gz
```

---

# 4. PostgreSQL Migration Script

Create:

```bash
nano postgresql-scripts/postgres-migrate.sh
```

Paste:

```bash
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
```

Make executable:

```bash
chmod +x postgresql-scripts/postgres-migrate.sh
```

Run:

```bash
./postgresql-scripts/postgres-migrate.sh
```

---

# Why These PostgreSQL Options Are Used

## `-Fc`

Creates a custom-format PostgreSQL backup.

Why:

- Better than plain `.sql` for PostgreSQL.
- Supports `pg_restore`.
- Can restore more flexibly.
- Already compressed (no separate gzip step needed).
- Supports parallel restore (`-j`).

---

## `--clean`

Drops existing database objects before restoring.

Why:

- Useful when refreshing test/temp DB from production.

Warning:

- Dangerous if used on the wrong database.

---

## `--if-exists`

Avoids errors if objects do not exist.

---

## `--no-owner`

Prevents ownership errors when source and target DB users are different.

Very useful for:

- Production → staging
- Local → RDS
- One server → another server

---

## `--no-privileges`

Prevents permission/GRANT related restore errors.

---

# 5. PostgreSQL Backup Only Script

Create:

```bash
nano postgresql-scripts/postgres-backup.sh
```

Paste:

```bash
#!/usr/bin/env bash
# PostgreSQL backup only (Ubuntu). Reads config from .env.
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
```

Run:

```bash
chmod +x postgresql-scripts/postgres-backup.sh
./postgresql-scripts/postgres-backup.sh
```

---

# 6. PostgreSQL Restore Only Script

Create:

```bash
nano postgresql-scripts/postgres-restore.sh
```

Paste:

```bash
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
```

Run:

```bash
chmod +x postgresql-scripts/postgres-restore.sh
./postgresql-scripts/postgres-restore.sh ./backups/mydb_20260606_120000.dump
```

---

# 7. Install Required Clients

## Ubuntu MySQL Client

```bash
sudo apt update
sudo apt install -y mysql-client
```

Check:

```bash
mysql --version
mysqldump --version
```

---

## Ubuntu PostgreSQL Client

```bash
sudo apt update
sudo apt install -y postgresql-client
```

Check:

```bash
psql --version
pg_dump --version
pg_restore --version
```

> **Version note:** the MySQL `mysqldump` client should be 8.0+ so it understands
> `--ssl-mode` and `--set-gtid-purged`. For PostgreSQL, install a `postgresql-client`
> whose major version is **>=** the server's, or `pg_restore` may reject a newer dump.

---

# 8. Performance Notes

## MySQL

For normal databases:

```
mysqldump + gzip + mysql restore
```

is okay.

For larger databases, `mysqldump` can still be slow.

Better options for very large MySQL databases:

- AWS DMS
- MySQL Shell Dump & Load
- Percona XtraBackup
- RDS snapshot restore

---

## PostgreSQL

For PostgreSQL, this is usually better:

```bash
pg_dump -Fc
pg_restore
```

For faster restore, if backup format supports it:

```bash
pg_restore -j 4
```

Example:

```bash
pg_restore \
  -h "$PG_TARGET_HOST" \
  -p "$PORT" \
  -U "$PG_TARGET_USER" \
  -d "$PG_TARGET_DB" \
  -j 4 \
  --clean \
  --if-exists \
  --no-owner \
  --no-privileges \
  "$BACKUP_FILE"
```

Why:

- `-j 4` uses 4 parallel jobs.
- Faster for larger databases.

---

# 9. Safety Checklist Before Running Migration

Before restoring into a target DB, confirm:

```
Source DB = production/test/local?
Target DB = test/temp/staging?
```

Never run a restore without confirming the target. Each migrate/restore script
above already includes a confirmation guard:

```bash
echo "Target database: $MYSQL_TARGET_HOST / $MYSQL_TARGET_DB"
read -r -p "Type YES to continue: " CONFIRM
[ "$CONFIRM" = "YES" ] || { echo "Cancelled."; exit 1; }
```

This prevents accidental production overwrite.

---

# 10. Best Practice

Scripts are grouped by engine, with the shared loader/config at the root:

```
load-env.sh                        (shared .env loader, at root)
mysql-scripts/
  mysql-backup.sh  mysql-restore.sh  mysql-migrate.sh
postgresql-scripts/
  postgres-backup.sh  postgres-restore.sh  postgres-migrate.sh
```

Keep credentials outside the scripts — all settings come from `.env`:

```
.env            (real values, git-ignored)
.env.example    (blank template, safe to commit)
```

or use:

```
AWS Secrets Manager
GitHub Secrets
local protected config file
```

The scripts never hard-code the password — they read it from `.env` if present,
otherwise prompt securely and pass it via `MYSQL_PWD` / `PGPASSWORD` only for the
duration of the run.

**Do not commit real credentials** (`.env` is already listed in `.gitignore`).
