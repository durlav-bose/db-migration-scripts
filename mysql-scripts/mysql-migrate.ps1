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
