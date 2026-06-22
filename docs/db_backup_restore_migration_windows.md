# Database Backup, Restore & Migration Scripts (Windows / PowerShell)

This document contains reusable **PowerShell** scripts for:

- MySQL backup
- MySQL restore
- MySQL source → target migration
- PostgreSQL backup
- PostgreSQL restore
- PostgreSQL source → target migration

> **Ubuntu users:** see the companion doc `db_backup_restore_migration_ubuntu.md`
> (bash `.sh` scripts). Both the `.ps1` and `.sh` scripts read the **same `.env`
> file**, so configuration is shared across Windows and Ubuntu.

> These `.ps1` scripts use only PowerShell + .NET built-ins (no external
> `gzip`/`gunzip`). They run on Windows PowerShell 5.1 and PowerShell 7+.

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
├─ docs/                            (this file + the Ubuntu doc)
├─ mysql-scripts/        mysql-backup.ps1   mysql-restore.ps1   mysql-migrate.ps1   (+ .sh)
└─ postgresql-scripts/   postgres-backup.ps1  postgres-restore.ps1  postgres-migrate.ps1   (+ .sh)
```

Run scripts **from the repo root** so the relative `.\backups\...` paths line up,
e.g. `.\mysql-scripts\mysql-backup.ps1`.

---

## Requirements

- **PowerShell**: Windows PowerShell 5.1 (built in) or PowerShell 7+.
- **DB clients on `PATH`**: `mysqldump.exe`/`mysql.exe` (MySQL 8.0+),
  `pg_dump.exe`/`pg_restore.exe`. See section **7. Install Required Clients**.

### Running a script

```powershell
# If you hit an execution-policy error, allow scripts for this session only:
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

.\mysql-scripts\mysql-backup.ps1
```

Or run without changing policy at all:

```powershell
pwsh -File .\mysql-scripts\mysql-backup.ps1   # run from the repo root
```

> Each script reads its password from `.env` if present, otherwise prompts
> securely (hidden input, never written to disk). The password is passed to the
> client via the `MYSQL_PWD` / `PGPASSWORD` environment variable for the duration
> of the run, then cleared.

---

# 0. Configuration via `.env` (read by every script)

All settings live in a single `.env` file instead of being hard-coded. Copy the
template and fill it in:

```powershell
Copy-Item .env.example .env
notepad .env
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

Each script loads `.env` through a shared helper, `load-env.ps1`:

```powershell
#!/usr/bin/env pwsh
# Minimal .env loader for PowerShell (works on Windows 5.1+ and PowerShell 7+).
#   $Root = Split-Path $PSScriptRoot -Parent   # scripts live in a subfolder; loader is at root
#   . (Join-Path $Root "load-env.ps1")
#   $cfg = Import-DotEnv (Join-Path $Root ".env")
#   $HostName = Get-RequiredEnv $cfg "MYSQL_HOST"

function Import-DotEnv {
    [CmdletBinding()]
    param([string]$Path)

    if (-not $Path) { $Path = Join-Path (Get-Location) ".env" }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Env file not found: $Path"
    }

    $vars = @{}
    foreach ($raw in Get-Content -LiteralPath $Path) {
        $line = $raw.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { continue }
        $line = $line -replace '^\s*export\s+', ''
        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { continue }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        if ($val.Length -ge 2) {
            $first = $val[0]; $last = $val[$val.Length - 1]
            if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                $val = $val.Substring(1, $val.Length - 2)
            }
        }
        $vars[$key] = $val
    }
    return $vars
}

function Get-RequiredEnv {
    param([hashtable]$Env, [string]$Key)
    if (-not $Env.ContainsKey($Key) -or [string]::IsNullOrWhiteSpace($Env[$Key])) {
        throw "Missing required key '$Key' in .env file"
    }
    return $Env[$Key]
}
```

> **Backup file naming:** set `MYSQL_BACKUP_NAME` / `PG_BACKUP_NAME` in `.env` to
> back up to a predictable, fixed filename (handy for "always restore the latest
> backup" workflows). The file is **overwritten on every run** — there's no
> history. Leave it blank to get a unique `<DB>_<timestamp>` name each run.
>
> **Passwords:** leave the `*_PASSWORD` keys blank to be prompted securely at
> runtime. The `.env` file is git-ignored — never commit it.

---

# 1. MySQL Migration Script

Create file: `mysql-scripts/mysql-migrate.ps1`

```powershell
#!/usr/bin/env pwsh
# MySQL source -> target migration. Runs on Windows and Ubuntu (PowerShell 5.1+ / 7+).
# Reads config from .env. Intermediate backup name comes from MYSQL_BACKUP_NAME
# (blank => <SourceDB>_<timestamp>.sql.gz).
$ErrorActionPreference = "Stop"

# ---- Load config from .env ----
$Root = Split-Path $PSScriptRoot -Parent
. (Join-Path $Root "load-env.ps1")
$cfg = Import-DotEnv (Join-Path $Root ".env")

# Source
$SourceHost = Get-RequiredEnv $cfg "MYSQL_HOST"
$SourcePort = if ($cfg.MYSQL_PORT) { $cfg.MYSQL_PORT } else { "3306" }
$SourceUser = Get-RequiredEnv $cfg "MYSQL_USER"
$SourceDb   = Get-RequiredEnv $cfg "MYSQL_DB"

# Target
$TargetHost = Get-RequiredEnv $cfg "MYSQL_TARGET_HOST"
$TargetPort = if ($cfg.MYSQL_TARGET_PORT) { $cfg.MYSQL_TARGET_PORT } else { "3306" }
$TargetUser = Get-RequiredEnv $cfg "MYSQL_TARGET_USER"
$TargetDb   = Get-RequiredEnv $cfg "MYSQL_TARGET_DB"

$BackupDir = Join-Path $Root "backups"

# ---- Intermediate backup name from MYSQL_BACKUP_NAME (.env), else <SourceDB>_<timestamp>.sql.gz ----
$BackupName = $cfg.MYSQL_BACKUP_NAME
if ($BackupName) {
    if     ($BackupName -match '\.gz$')  { $leaf = $BackupName }
    elseif ($BackupName -match '\.sql$') { $leaf = "$BackupName.gz" }
    else                                 { $leaf = "$BackupName.sql.gz" }
    $GzFile = if ([System.IO.Path]::IsPathRooted($leaf)) { $leaf } else { Join-Path $BackupDir $leaf }
} else {
    $Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $GzFile = Join-Path $BackupDir "$($SourceDb)_$Timestamp.sql.gz"
}

function Compress-GZipFile {
    param([string]$InFile, [string]$OutFile)
    $in  = [System.IO.File]::OpenRead($InFile)
    $out = [System.IO.File]::Create($OutFile)
    try {
        $gz = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionMode]::Compress)
        try { $in.CopyTo($gz) } finally { $gz.Dispose() }
    } finally { $out.Dispose(); $in.Dispose() }
}

function Expand-GZipFile {
    param([string]$InFile, [string]$OutFile)
    $in  = [System.IO.File]::OpenRead($InFile)
    $out = [System.IO.File]::Create($OutFile)
    try {
        $gz = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
        try { $gz.CopyTo($out) } finally { $gz.Dispose() }
    } finally { $out.Dispose(); $in.Dispose() }
}

function Get-PlainPassword {
    param([string]$Prompt)
    $secure = Read-Host $Prompt -AsSecureString
    return [System.Net.NetworkCredential]::new("", $secure).Password
}

New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

Write-Host "Starting MySQL migration..."
Write-Host "Source: $SourceHost/$SourceDb"
Write-Host "Target: $TargetHost/$TargetDb"

# ---- Safety confirmation (target gets overwritten) ----
Write-Host ""
Write-Host "Target database to be written: $TargetHost / $TargetDb"
$confirm = Read-Host "Type YES to continue"
if ($confirm -ne "YES") { Write-Host "Cancelled."; exit 1 }

# ---- Step 1: backup source ----
Write-Host ""
Write-Host "Step 1: Taking compressed backup..."
$SqlFile = [System.IO.Path]::GetTempFileName()
if ($cfg.MYSQL_PASSWORD) {
    $env:MYSQL_PWD = $cfg.MYSQL_PASSWORD
} else {
    $env:MYSQL_PWD = Get-PlainPassword "Enter SOURCE MySQL password for $SourceUser"
}
try {
    mysqldump `
      -h $SourceHost `
      -P $SourcePort `
      -u $SourceUser `
      --ssl-mode=REQUIRED `
      --single-transaction `
      --set-gtid-purged=OFF `
      --no-tablespaces `
      --routines `
      --triggers `
      --events `
      --result-file=$SqlFile `
      $SourceDb
    if ($LASTEXITCODE -ne 0) { throw "mysqldump failed (exit $LASTEXITCODE)" }

    Compress-GZipFile -InFile $SqlFile -OutFile $GzFile
    Write-Host "Backup created: $GzFile"
}
finally {
    Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $SqlFile -ErrorAction SilentlyContinue
}

# ---- Step 2: restore to target ----
Write-Host ""
Write-Host "Step 2: Restoring backup to target..."
$tmpSql = [System.IO.Path]::GetTempFileName()
if ($cfg.MYSQL_TARGET_PASSWORD) {
    $env:MYSQL_PWD = $cfg.MYSQL_TARGET_PASSWORD
} else {
    $env:MYSQL_PWD = Get-PlainPassword "Enter TARGET MySQL password for $TargetUser"
}
try {
    Expand-GZipFile -InFile $GzFile -OutFile $tmpSql
    $mysqlArgs = @("-h", $TargetHost, "-P", $TargetPort, "-u", $TargetUser, "--ssl-mode=REQUIRED", $TargetDb)
    $proc = Start-Process -FilePath "mysql" -ArgumentList $mysqlArgs `
                          -RedirectStandardInput $tmpSql -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "mysql restore failed (exit $($proc.ExitCode))" }
}
finally {
    Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmpSql -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Migration completed successfully."
```

Run:

```powershell
.\mysql-scripts\mysql-migrate.ps1
```

---

# Why These MySQL Options Are Used

## `$ErrorActionPreference = "Stop"`

PowerShell equivalent of bash `set -e`. Makes cmdlet errors terminating so the
script stops instead of continuing after a failure. Native tools (`mysqldump`,
`mysql`) don't throw on a bad exit code, so the scripts also check
`$LASTEXITCODE` / `$proc.ExitCode` explicitly and `throw` on failure.

---

## `--single-transaction`

Creates a consistent backup for InnoDB tables without locking the whole database.
Good for production; reduces downtime/locking. Best for InnoDB (not perfect for
MyISAM).

---

## `--set-gtid-purged=OFF` (required for AWS RDS)

Stops `mysqldump` from capturing GTID coordinates, which otherwise requires a
global read lock (`FLUSH TABLES WITH READ LOCK`).

- RDS does **not** grant the `RELOAD`/`SUPER` privilege to the master user, so the
  lock fails with `Access denied ... (1045)`.
- You also don't want GTID state when restoring into a *different* server — it
  causes `GTID_PURGED can only be set when GTID_EXECUTED is empty` errors.

---

## `--no-tablespaces` (recommended for AWS RDS)

Skips dumping tablespace definitions, which need the `PROCESS` privilege. RDS
doesn't grant `PROCESS` to the master user, so without this you hit
`Access denied; you need (at least one of) the PROCESS privilege(s)`.

---

## `--routines` / `--triggers` / `--events`

Include stored procedures & functions, triggers, and scheduled events.

---

## `--result-file=...` instead of `> file`

In PowerShell, `>` redirection writes **UTF-16** by default, which corrupts a SQL
dump. `--result-file` makes `mysqldump` write the file itself in the correct
encoding/mode — portable and safe.

---

## GZip compression (.NET `GZipStream`)

Instead of the external `gzip` tool (not present on Windows), the scripts compress
with .NET's built-in `System.IO.Compression.GZipStream` — no external dependency,
identical on Windows and Ubuntu, and produces standard `.gz` files (still readable
by `gunzip` on Linux).

---

# 2. MySQL Backup Only Script

Create file: `mysql-scripts/mysql-backup.ps1`

```powershell
#!/usr/bin/env pwsh
# MySQL backup only. Runs on Windows and Ubuntu (PowerShell 5.1+ / 7+).
# Backup file name comes from MYSQL_BACKUP_NAME in .env; if blank it defaults
# to <DB>_<timestamp>.sql.gz
$ErrorActionPreference = "Stop"

# ---- Load config from .env ----
$Root = Split-Path $PSScriptRoot -Parent
. (Join-Path $Root "load-env.ps1")
$cfg = Import-DotEnv (Join-Path $Root ".env")

$HostName = Get-RequiredEnv $cfg "MYSQL_HOST"
$Port     = if ($cfg.MYSQL_PORT) { $cfg.MYSQL_PORT } else { "3306" }
$User     = Get-RequiredEnv $cfg "MYSQL_USER"
$Db       = Get-RequiredEnv $cfg "MYSQL_DB"

$BackupDir = Join-Path $Root "backups"

# ---- Output file name from MYSQL_BACKUP_NAME (.env), else <DB>_<timestamp>.sql.gz ----
$BackupName = $cfg.MYSQL_BACKUP_NAME
if ($BackupName) {
    if     ($BackupName -match '\.gz$')  { $leaf = $BackupName }
    elseif ($BackupName -match '\.sql$') { $leaf = "$BackupName.gz" }
    else                                 { $leaf = "$BackupName.sql.gz" }
    $GzFile = if ([System.IO.Path]::IsPathRooted($leaf)) { $leaf } else { Join-Path $BackupDir $leaf }
} else {
    $Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $GzFile = Join-Path $BackupDir "$($Db)_$Timestamp.sql.gz"
}
$SqlFile = [System.IO.Path]::GetTempFileName()   # uncompressed dump (temporary)

function Compress-GZipFile {
    param([string]$InFile, [string]$OutFile)
    $in  = [System.IO.File]::OpenRead($InFile)
    $out = [System.IO.File]::Create($OutFile)
    try {
        $gz = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionMode]::Compress)
        try { $in.CopyTo($gz) } finally { $gz.Dispose() }
    } finally { $out.Dispose(); $in.Dispose() }
}

New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

if ($cfg.MYSQL_PASSWORD) {
    $env:MYSQL_PWD = $cfg.MYSQL_PASSWORD
} else {
    $secure = Read-Host "Enter MySQL password for $User" -AsSecureString
    $env:MYSQL_PWD = [System.Net.NetworkCredential]::new("", $secure).Password
}
try {
    Write-Host "Backing up MySQL database: $Db"
    mysqldump `
      -h $HostName `
      -P $Port `
      -u $User `
      --ssl-mode=REQUIRED `
      --single-transaction `
      --set-gtid-purged=OFF `
      --no-tablespaces `
      --routines `
      --triggers `
      --events `
      --result-file=$SqlFile `
      $Db
    if ($LASTEXITCODE -ne 0) { throw "mysqldump failed (exit $LASTEXITCODE)" }

    Compress-GZipFile -InFile $SqlFile -OutFile $GzFile

    Write-Host "Backup completed:"
    Write-Host $GzFile
}
finally {
    Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $SqlFile -ErrorAction SilentlyContinue
}
```

Run:

```powershell
.\mysql-scripts\mysql-backup.ps1
```

---

# 3. MySQL Restore Only Script

Create file: `mysql-scripts/mysql-restore.ps1`

```powershell
#!/usr/bin/env pwsh
# MySQL restore only. Reads target config from .env.
# Usage: .\mysql-scripts\mysql-restore.ps1 .\backups\mydb_20260606_120000.sql.gz
param([Parameter(Mandatory = $true)][string]$BackupFile)

$ErrorActionPreference = "Stop"

# ---- Load config from .env ----
$Root = Split-Path $PSScriptRoot -Parent
. (Join-Path $Root "load-env.ps1")
$cfg = Import-DotEnv (Join-Path $Root ".env")

$TargetHost = Get-RequiredEnv $cfg "MYSQL_TARGET_HOST"
$TargetPort = if ($cfg.MYSQL_TARGET_PORT) { $cfg.MYSQL_TARGET_PORT } else { "3306" }
$TargetUser = Get-RequiredEnv $cfg "MYSQL_TARGET_USER"
$TargetDb   = Get-RequiredEnv $cfg "MYSQL_TARGET_DB"

if (-not (Test-Path -LiteralPath $BackupFile)) {
    Write-Error "Backup file not found: $BackupFile"
    exit 1
}

function Expand-GZipFile {
    param([string]$InFile, [string]$OutFile)
    $in  = [System.IO.File]::OpenRead($InFile)
    $out = [System.IO.File]::Create($OutFile)
    try {
        $gz = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
        try { $gz.CopyTo($out) } finally { $gz.Dispose() }
    } finally { $out.Dispose(); $in.Dispose() }
}

Write-Host "Target database: $TargetHost / $TargetDb"
$confirm = Read-Host "Type YES to continue"
if ($confirm -ne "YES") { Write-Host "Cancelled."; exit 1 }

if ($cfg.MYSQL_TARGET_PASSWORD) {
    $env:MYSQL_PWD = $cfg.MYSQL_TARGET_PASSWORD
} else {
    $secure = Read-Host "Enter MySQL password for $TargetUser" -AsSecureString
    $env:MYSQL_PWD = [System.Net.NetworkCredential]::new("", $secure).Password
}

$tmpSql = [System.IO.Path]::GetTempFileName()
try {
    Write-Host "Restoring $BackupFile to $TargetDb..."

    if ($BackupFile -match '\.gz$') {
        Expand-GZipFile -InFile $BackupFile -OutFile $tmpSql
        $inputFile = $tmpSql
    } else {
        $inputFile = (Resolve-Path -LiteralPath $BackupFile).Path
    }

    $mysqlArgs = @("-h", $TargetHost, "-P", $TargetPort, "-u", $TargetUser, "--ssl-mode=REQUIRED", $TargetDb)
    $proc = Start-Process -FilePath "mysql" -ArgumentList $mysqlArgs `
                          -RedirectStandardInput $inputFile -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "mysql restore failed (exit $($proc.ExitCode))" }

    Write-Host "Restore completed successfully."
}
finally {
    Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmpSql -ErrorAction SilentlyContinue
}
```

Run:

```powershell
.\mysql-scripts\mysql-restore.ps1 .\backups\mydb_20260606_120000.sql.gz
```

---

# 4. PostgreSQL Migration Script

Create file: `postgresql-scripts/postgres-migrate.ps1`

```powershell
#!/usr/bin/env pwsh
# PostgreSQL source -> target migration. Runs on Windows and Ubuntu.
# Reads config from .env. Intermediate backup name comes from PG_BACKUP_NAME
# (blank => <SourceDB>_<timestamp>.dump).
$ErrorActionPreference = "Stop"

# ---- Load config from .env ----
$Root = Split-Path $PSScriptRoot -Parent
. (Join-Path $Root "load-env.ps1")
$cfg = Import-DotEnv (Join-Path $Root ".env")

# Source
$SourceHost = Get-RequiredEnv $cfg "PG_HOST"
$SourcePort = if ($cfg.PG_PORT) { $cfg.PG_PORT } else { "5432" }
$SourceUser = Get-RequiredEnv $cfg "PG_USER"
$SourceDb   = Get-RequiredEnv $cfg "PG_DB"

# Target
$TargetHost = Get-RequiredEnv $cfg "PG_TARGET_HOST"
$TargetPort = if ($cfg.PG_TARGET_PORT) { $cfg.PG_TARGET_PORT } else { "5432" }
$TargetUser = Get-RequiredEnv $cfg "PG_TARGET_USER"
$TargetDb   = Get-RequiredEnv $cfg "PG_TARGET_DB"

$BackupDir = Join-Path $Root "backups"

# ---- Intermediate backup name from PG_BACKUP_NAME (.env), else <SourceDB>_<timestamp>.dump ----
$BackupName = $cfg.PG_BACKUP_NAME
if ($BackupName) {
    $leaf = if ($BackupName -match '\.dump$') { $BackupName } else { "$BackupName.dump" }
    $BackupFile = if ([System.IO.Path]::IsPathRooted($leaf)) { $leaf } else { Join-Path $BackupDir $leaf }
} else {
    $Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $BackupFile = Join-Path $BackupDir "$($SourceDb)_$Timestamp.dump"
}

function Get-PlainPassword {
    param([string]$Prompt)
    $secure = Read-Host $Prompt -AsSecureString
    return [System.Net.NetworkCredential]::new("", $secure).Password
}

New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

Write-Host "Starting PostgreSQL migration..."
Write-Host "Source: $SourceHost/$SourceDb"
Write-Host "Target: $TargetHost/$TargetDb"

Write-Host ""
Write-Host "Target database to be written: $TargetHost / $TargetDb"
$confirm = Read-Host "Type YES to continue"
if ($confirm -ne "YES") { Write-Host "Cancelled."; exit 1 }

# ---- Step 1: backup source (custom format, already compressed) ----
Write-Host ""
Write-Host "Step 1: Taking PostgreSQL custom-format backup..."
if ($cfg.PG_PASSWORD) {
    $env:PGPASSWORD = $cfg.PG_PASSWORD
} else {
    $env:PGPASSWORD = Get-PlainPassword "Enter SOURCE PostgreSQL password for $SourceUser"
}
try {
    pg_dump -h $SourceHost -p $SourcePort -U $SourceUser -d $SourceDb -Fc -f $BackupFile
    if ($LASTEXITCODE -ne 0) { throw "pg_dump failed (exit $LASTEXITCODE)" }
    Write-Host "Backup created: $BackupFile"
}
finally { Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue }

# ---- Step 2: restore to target ----
Write-Host ""
Write-Host "Step 2: Restoring to target..."
if ($cfg.PG_TARGET_PASSWORD) {
    $env:PGPASSWORD = $cfg.PG_TARGET_PASSWORD
} else {
    $env:PGPASSWORD = Get-PlainPassword "Enter TARGET PostgreSQL password for $TargetUser"
}
try {
    pg_restore -h $TargetHost -p $TargetPort -U $TargetUser -d $TargetDb `
        --clean --if-exists --no-owner --no-privileges $BackupFile
    if ($LASTEXITCODE -ne 0) { throw "pg_restore failed (exit $LASTEXITCODE)" }
}
finally { Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "PostgreSQL migration completed successfully."
```

Run:

```powershell
.\postgresql-scripts\postgres-migrate.ps1
```

> **Note:** `pg_restore` may print non-fatal warnings (e.g. about dropping objects
> that don't exist). Review the output carefully.

---

# Why These PostgreSQL Options Are Used

## `-Fc`

Creates a custom-format PostgreSQL backup. Better than plain `.sql`, supports
`pg_restore`, already compressed (no separate gzip step), supports parallel
restore (`-j`).

## `--clean`

Drops existing database objects before restoring. Useful when refreshing a
test/temp DB from production. **Dangerous if used on the wrong database.**

## `--if-exists`

Avoids errors if objects do not exist.

## `--no-owner`

Prevents ownership errors when source and target DB users differ (production →
staging, local → RDS, one server → another).

## `--no-privileges`

Prevents permission/GRANT related restore errors.

---

# 5. PostgreSQL Backup Only Script

Create file: `postgresql-scripts/postgres-backup.ps1`

```powershell
#!/usr/bin/env pwsh
# PostgreSQL backup only. Runs on Windows and Ubuntu.
# Backup file name comes from PG_BACKUP_NAME in .env; if blank it defaults
# to <DB>_<timestamp>.dump
$ErrorActionPreference = "Stop"

# ---- Load config from .env ----
$Root = Split-Path $PSScriptRoot -Parent
. (Join-Path $Root "load-env.ps1")
$cfg = Import-DotEnv (Join-Path $Root ".env")

$HostName = Get-RequiredEnv $cfg "PG_HOST"
$Port     = if ($cfg.PG_PORT) { $cfg.PG_PORT } else { "5432" }
$User     = Get-RequiredEnv $cfg "PG_USER"
$Db       = Get-RequiredEnv $cfg "PG_DB"

$BackupDir = Join-Path $Root "backups"

# ---- Output file name from PG_BACKUP_NAME (.env), else <DB>_<timestamp>.dump ----
$BackupName = $cfg.PG_BACKUP_NAME
if ($BackupName) {
    $leaf = if ($BackupName -match '\.dump$') { $BackupName } else { "$BackupName.dump" }
    $BackupFile = if ([System.IO.Path]::IsPathRooted($leaf)) { $leaf } else { Join-Path $BackupDir $leaf }
} else {
    $Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $BackupFile = Join-Path $BackupDir "$($Db)_$Timestamp.dump"
}

New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

if ($cfg.PG_PASSWORD) {
    $env:PGPASSWORD = $cfg.PG_PASSWORD
} else {
    $secure = Read-Host "Enter PostgreSQL password for $User" -AsSecureString
    $env:PGPASSWORD = [System.Net.NetworkCredential]::new("", $secure).Password
}
try {
    Write-Host "Backing up PostgreSQL database: $Db"
    pg_dump -h $HostName -p $Port -U $User -d $Db -Fc -f $BackupFile
    if ($LASTEXITCODE -ne 0) { throw "pg_dump failed (exit $LASTEXITCODE)" }
    Write-Host "Backup completed:"
    Write-Host $BackupFile
}
finally { Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue }
```

Run:

```powershell
.\postgresql-scripts\postgres-backup.ps1
```

---

# 6. PostgreSQL Restore Only Script

Create file: `postgresql-scripts/postgres-restore.ps1`

```powershell
#!/usr/bin/env pwsh
# PostgreSQL restore only. Reads target config from .env.
# Usage: .\postgresql-scripts\postgres-restore.ps1 .\backups\mydb_20260606_120000.dump
param([Parameter(Mandatory = $true)][string]$BackupFile)

$ErrorActionPreference = "Stop"

# ---- Load config from .env ----
$Root = Split-Path $PSScriptRoot -Parent
. (Join-Path $Root "load-env.ps1")
$cfg = Import-DotEnv (Join-Path $Root ".env")

$TargetHost = Get-RequiredEnv $cfg "PG_TARGET_HOST"
$TargetPort = if ($cfg.PG_TARGET_PORT) { $cfg.PG_TARGET_PORT } else { "5432" }
$TargetUser = Get-RequiredEnv $cfg "PG_TARGET_USER"
$TargetDb   = Get-RequiredEnv $cfg "PG_TARGET_DB"

if (-not (Test-Path -LiteralPath $BackupFile)) {
    Write-Error "Backup file not found: $BackupFile"
    exit 1
}

Write-Host "Target database: $TargetHost / $TargetDb"
$confirm = Read-Host "Type YES to continue"
if ($confirm -ne "YES") { Write-Host "Cancelled."; exit 1 }

if ($cfg.PG_TARGET_PASSWORD) {
    $env:PGPASSWORD = $cfg.PG_TARGET_PASSWORD
} else {
    $secure = Read-Host "Enter PostgreSQL password for $TargetUser" -AsSecureString
    $env:PGPASSWORD = [System.Net.NetworkCredential]::new("", $secure).Password
}
try {
    Write-Host "Restoring $BackupFile to $TargetDb..."
    pg_restore -h $TargetHost -p $TargetPort -U $TargetUser -d $TargetDb `
        --clean --if-exists --no-owner --no-privileges $BackupFile
    if ($LASTEXITCODE -ne 0) { throw "pg_restore failed (exit $LASTEXITCODE)" }
    Write-Host "Restore completed successfully."
}
finally { Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue }
```

Run:

```powershell
.\postgresql-scripts\postgres-restore.ps1 .\backups\mydb_20260606_120000.dump
```

---

# 7. Install Required Clients

## Windows

- **MySQL client** (`mysql.exe`, `mysqldump.exe`): install **MySQL Shell** or the
  MySQL Community Server / "Client only" via the MySQL Installer, then add the
  `bin` folder to your `PATH`. Use a 8.0+ client (for `--ssl-mode` /
  `--set-gtid-purged`).
- **PostgreSQL client** (`pg_dump.exe`, `pg_restore.exe`, `psql.exe`): install
  PostgreSQL from the EDB installer (you can pick "Command Line Tools" only), then
  add its `bin` folder to your `PATH`.

Verify:

```powershell
mysql --version
mysqldump --version
psql --version
pg_dump --version
pg_restore --version
```

---

# 8. Performance Notes

## MySQL

`mysqldump + GZip + mysql restore` is fine for normal databases. For very large
MySQL databases consider: AWS DMS, MySQL Shell Dump & Load, Percona XtraBackup,
or RDS snapshot restore.

## PostgreSQL

`pg_dump -Fc` + `pg_restore` is usually best. For faster restore, add parallel jobs:

```powershell
pg_restore -h $TargetHost -p $TargetPort -U $TargetUser -d $TargetDb `
    -j 4 --clean --if-exists --no-owner --no-privileges $BackupFile
```

`-j 4` uses 4 parallel jobs — faster for larger databases.

---

# 9. Safety Checklist Before Running Migration

Before restoring into a target DB, confirm:

```
Source DB = production/test/local?
Target DB = test/temp/staging?
```

Never run a restore without confirming the target. Each migrate/restore script
above already includes a `Read-Host "Type YES to continue"` guard:

```powershell
Write-Host "Target database: $TargetHost / $TargetDb"
$confirm = Read-Host "Type YES to continue"
if ($confirm -ne "YES") { Write-Host "Cancelled."; exit 1 }
```

---

# 10. Best Practice

Scripts are grouped by engine, with the shared loader/config at the root:

```
load-env.ps1                       (shared .env loader, at root)
mysql-scripts/
  mysql-backup.ps1  mysql-restore.ps1  mysql-migrate.ps1
postgresql-scripts/
  postgres-backup.ps1  postgres-restore.ps1  postgres-migrate.ps1
```

All configuration comes from `.env`:

```
.env            (real values, git-ignored)
.env.example    (blank template, safe to commit)
```

or use AWS Secrets Manager / GitHub Secrets / a local protected config file.

The scripts never hard-code the password — they read it from `.env` if present,
otherwise prompt securely and pass it via `MYSQL_PWD` / `PGPASSWORD` only for the
duration of the run.

**Do not commit real credentials** (`.env` is already listed in `.gitignore`).
