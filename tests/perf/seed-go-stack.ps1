<#
.SYNOPSIS
    Apply DB migrations and register perf test users against a running Go stack.

.DESCRIPTION
    Run this once after `podman compose up -d` before executing k6 manually.
    It is idempotent: migrate is safe to re-run (reports "no change"), and
    register returns 409 if the user already exists (treated as success).

    run-bench.ps1 already calls this logic inline for automated bench runs,
    so this script is only needed for ad-hoc / manual testing.

.PARAMETER KongPort
    Kong proxy port (default: 8000)

.PARAMETER SenderUser
    Username to register as the k6 sender (default: perf_alice)

.PARAMETER ReceiverUser
    Username to register as the k6 receiver (default: perf_bob)

.PARAMETER Password
    Password for both users (default: Perf@1234)

.PARAMETER SenderPhone
    Phone number for the sender user (default: 0901111100)

.PARAMETER ReceiverPhone
    Phone number for the receiver user (default: 0901111101)

.EXAMPLE
    # Default — seeds against localhost:8000
    .\perf\seed-go-stack.ps1

.EXAMPLE
    # Custom port / credentials
    .\perf\seed-go-stack.ps1 -KongPort 8000 -Password "MyPass@99"
#>

[CmdletBinding()]
param(
    [int]    $KongPort     = 8000,
    [string] $SenderUser   = 'perf_alice',
    [string] $ReceiverUser = 'perf_bob',
    [string] $Password     = 'Perf@1234',
    [string] $SenderPhone  = '0901111100',
    [string] $ReceiverPhone= '0901111101'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path

function Log-Step  ([string]$msg) { Write-Host "`n🔷 $msg" -ForegroundColor Cyan }
function Log-OK    ([string]$msg) { Write-Host "  ✅ $msg" -ForegroundColor Green }
function Log-Warn  ([string]$msg) { Write-Host "  ⚠️  $msg" -ForegroundColor Yellow }
function Log-Info  ([string]$msg) { Write-Host "  ℹ  $msg" -ForegroundColor Gray }

# ── Step 1: wait for postgres ─────────────────────────────────────────────────
Log-Step "Waiting for postgres (banking-postgres) to be ready..."
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    $check = & podman exec banking-postgres pg_isready -U banking 2>&1
    if ($LASTEXITCODE -eq 0) { Log-OK "Postgres ready"; break }
    Log-Info "Not ready yet — retrying in 2s..."
    Start-Sleep -Seconds 2
}
if ($LASTEXITCODE -ne 0) { throw "Postgres did not become ready within 60s" }

# ── Step 2: run migrations ─────────────────────────────────────────────────────
Log-Step "Running DB migrations..."
$migrateArgs = @(
    'run', '--rm', '--network=host',
    '-v', "${RepoRoot}/migrations:/migrations",
    'migrate/migrate',
    '-path', '/migrations',
    '-database', "postgresql://banking:bankingpass@localhost:5432/banking?sslmode=disable",
    'up'
)
$migrateOut  = & podman @migrateArgs 2>&1
$migrateExit = $LASTEXITCODE
$migrateOut | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
# exit 1 with "no change" is normal when schema already exists
if ($migrateExit -ne 0) {
    Log-Warn "migrate exited $migrateExit — likely 'no change' (safe to ignore)"
} else {
    Log-OK "Migrations applied"
}

# ── Step 3: wait for Kong + auth-service to be reachable ─────────────────────
Log-Step "Waiting for Kong on :$KongPort and auth-service to be ready..."
$deadline = (Get-Date).AddSeconds(120)
$url = "http://localhost:$KongPort/api/health/auth"
while ((Get-Date) -lt $deadline) {
    $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 4 $url 2>$null
    if ($LASTEXITCODE -eq 0 -and $code -eq '200') {
        Log-OK "Auth-service reachable via Kong ($url → HTTP $code)"
        break
    }
    Log-Info "Not ready yet (HTTP $code) — retrying in 3s..."
    Start-Sleep -Seconds 3
}

# ── Step 4: register perf users via the register endpoint ─────────────────────
Log-Step "Registering perf users via POST http://localhost:$KongPort/api/users ..."

function Register-User([string]$username, [string]$phone) {
    $body = "{`"username`":`"$username`",`"password`":`"$Password`",`"phone`":`"$phone`"}"
    $tmp  = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmp, $body)
    try {
        $resp = & curl.exe -s -o NUL -w '%{http_code}' -X POST `
            "http://localhost:$KongPort/api/users" `
            -H "Content-Type: application/json" `
            --data-binary "@$tmp" 2>$null
        return $resp
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

function Verify-Login([string]$username) {
    $body = "{`"username`":`"$username`",`"password`":`"$Password`"}"
    $tmp  = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmp, $body)
    try {
        $resp = curl.exe -s -X POST `
            "http://localhost:$KongPort/api/sessions" `
            -H "Content-Type: application/json" `
            --data-binary "@$tmp" 2>$null
        $json = $resp | ConvertFrom-Json -ErrorAction SilentlyContinue
        return ($null -ne $json -and $json.session -ne $null -and $json.session -ne '')
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

foreach ($pair in @(
    @{ name = $SenderUser;   phone = $SenderPhone   },
    @{ name = $ReceiverUser; phone = $ReceiverPhone  }
)) {
    $status = Register-User -username $pair.name -phone $pair.phone
    if ($status -eq '201') {
        Log-OK "$($pair.name) registered (201 Created)"
    } elseif ($status -eq '409') {
        Log-Info "$($pair.name) already exists (409 Conflict) — skipping"
    } else {
        Log-Warn "$($pair.name) register returned HTTP $status — may need investigation"
    }
}

# ── Step 5: smoke-test login ──────────────────────────────────────────────────
Log-Step "Verifying login for both users..."
foreach ($u in @($SenderUser, $ReceiverUser)) {
    if (Verify-Login -username $u) {
        Log-OK "$u login OK"
    } else {
        throw "Login failed for $u — check auth-service logs"
    }
}

Write-Host ""
Log-OK "Seed complete. Stack is ready for k6:"
Write-Host "  podman run --rm --network=host -v `"${RepoRoot}/perf/k6:/scripts`" ``" -ForegroundColor Gray
Write-Host "    -e STACK_TYPE=go -e BASE_URL=http://localhost:$KongPort ``" -ForegroundColor Gray
Write-Host "    grafana/k6:latest run /scripts/scenario.js" -ForegroundColor Gray
Write-Host ""
