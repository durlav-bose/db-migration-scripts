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

$PgRestore = Resolve-PgTool $cfg "pg_restore"
Write-Host "Using pg_restore: $PgRestore"

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

    # Capture stderr to a file so we can classify pg_restore's errors after the run.
    # (Set Continue here so native-command stderr doesn't trip $ErrorActionPreference = "Stop".)
    $errLog = Join-Path ([System.IO.Path]::GetTempPath()) ("pg_restore_{0}.log" -f [System.Guid]::NewGuid())
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $PgRestore -h $TargetHost -p $TargetPort -U $TargetUser -d $TargetDb `
        --clean --if-exists --no-owner --no-privileges $BackupFile 2> $errLog
    $restoreExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP

    $errText = if (Test-Path -LiteralPath $errLog) { Get-Content -LiteralPath $errLog -Raw } else { "" }
    if ($errText) { Write-Host $errText }
    Remove-Item -LiteralPath $errLog -ErrorAction SilentlyContinue

    if ($restoreExit -eq 0) {
        Write-Host "Restore completed successfully." -ForegroundColor Green
    }
    else {
        # pg_restore returns non-zero whenever it ignored any error, even if all data restored.
        # Tolerate only the benign case: a SET emitted by a newer pg_dump that an older target
        # server doesn't recognize (e.g. transaction_timeout on PG < 17). Any other error fails.
        $errorLines = @($errText -split "`r?`n" | Where-Object { $_ -match 'pg_restore: error:' })
        $benign     = @($errorLines | Where-Object { $_ -match 'unrecognized configuration parameter' })

        if ($errorLines.Count -gt 0 -and $errorLines.Count -eq $benign.Count) {
            Write-Host "Restore completed with $($errorLines.Count) harmless ignored error(s)." -ForegroundColor Yellow
            Write-Host "(Unrecognized config parameter from a newer pg_dump than the target server -- safe to ignore.)" -ForegroundColor Yellow
        }
        else {
            throw "pg_restore failed (exit $restoreExit): $($errorLines.Count) error(s), $($benign.Count) benign."
        }
    }
}
finally {
    $ErrorActionPreference = "Continue"
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
}
