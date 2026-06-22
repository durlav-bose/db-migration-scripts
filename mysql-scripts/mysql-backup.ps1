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
