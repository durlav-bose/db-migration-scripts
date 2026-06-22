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
