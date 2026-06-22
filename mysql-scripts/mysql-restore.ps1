#!/usr/bin/env pwsh
# MySQL restore only. Reads target config from .env.
# Usage: .\mysql-restore.ps1 .\backups\mydb_20260606_120000.sql.gz
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
# Resolve to an absolute path so .NET file APIs (which use the process working
# directory, not the PowerShell location) read the right file.
$BackupFile = (Resolve-Path -LiteralPath $BackupFile).Path

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
