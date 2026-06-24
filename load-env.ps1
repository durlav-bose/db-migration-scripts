#!/usr/bin/env pwsh
# Minimal .env loader for PowerShell (works on Windows 5.1+ and PowerShell 7+ on Linux).
# Dot-source this file, then call Import-DotEnv to get a hashtable of KEY -> value.
#
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
        if ($line -eq "" -or $line.StartsWith("#")) { continue }     # skip blanks / comments
        $line = $line -replace '^\s*export\s+', ''                   # tolerate "export KEY=..."
        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { continue }                                 # skip malformed lines
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        # strip a single pair of surrounding quotes, if present
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

# Resolve a PostgreSQL client tool (pg_dump, pg_restore, psql, ...).
# pg_dump/pg_restore must be >= the server version, so when several PostgreSQL
# installs exist on Windows we default to the newest one rather than whatever is
# first on PATH. Override with PG_BIN in .env to pin a specific install's bin dir.
function Resolve-PgTool {
    param([hashtable]$Env, [string]$Tool)

    if ($Env.PG_BIN) {
        foreach ($name in @("$Tool.exe", $Tool)) {
            $candidate = Join-Path $Env.PG_BIN $name
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
        throw "PG_BIN is set but '$Tool' was not found in '$($Env.PG_BIN)'"
    }

    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        $newest = Get-ChildItem "C:\Program Files\PostgreSQL\*\bin\$Tool.exe" -ErrorAction SilentlyContinue |
            Sort-Object { [int]($_.Directory.Parent.Name) } -Descending |
            Select-Object -First 1
        if ($newest) { return $newest.FullName }
    }

    return $Tool   # fall back to PATH
}
