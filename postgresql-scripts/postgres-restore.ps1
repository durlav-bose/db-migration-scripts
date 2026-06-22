#!/usr/bin/env pwsh
# PostgreSQL restore only. Reads target config from .env.
# Usage: .\postgres-restore.ps1 .\backups\mydb_20260606_120000.dump
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
# Resolve to an absolute path so the file is found regardless of the working dir.
$BackupFile = (Resolve-Path -LiteralPath $BackupFile).Path

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
