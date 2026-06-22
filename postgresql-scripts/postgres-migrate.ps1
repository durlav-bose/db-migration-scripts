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
