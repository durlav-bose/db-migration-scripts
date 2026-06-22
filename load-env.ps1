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
