<#
.SYNOPSIS
    Run a Go vs Python transfer-service performance comparison using k6 + podman.

.DESCRIPTION
    Two-phase benchmark:
      Phase 1 — Go stack   (current golang branch, ports 8000-8004)
      Phase 2 — Python stack (origin/final branch, ports 9000-9004, isolated network)

    For each stack, five k6 scenarios are run in sequence:
      1. reg_throughput    — POST /register open-arrival-rate benchmark (measures bcrypt + DB insert)
      2. single_pair       — all VUs on one alice↔bob pair (DB row-contention ceiling)
      3. multi_user        — N unique sender/receiver pairs (true app throughput, near-zero lock contention)
      4. fan_out           — N senders → one hot receiver (merchant-account hot-row stress)
      5. transfer_journey  — sequential per-user flow: POST /transfer → wait → GET /balance → think time

    Each scenario's results are saved to:
      perf/results/<stack>-<scenario>-<timestamp>.json

    After both phases a terminal summary is printed and a unified HTML report is generated
    covering ALL four scenarios with per-scenario charts and SLO badges.

.PARAMETER MaxVUs
    Peak virtual users for transfer scenarios (default: 20)

.PARAMETER RampDuration
    Ramp-up stage duration, e.g. "20s" (default: "20s")

.PARAMETER SteadyDuration
    Measurement window for transfer scenarios, e.g. "60s" (default: "60s")

.PARAMETER NumUsers
    Number of perf users to register for multi_user / fan_out scenarios (default: 40)

.PARAMETER RegRate
    Target registrations/s for reg_throughput scenario (default: 10)

.PARAMETER RegDuration
    Measurement window for reg_throughput, e.g. "30s" (default: "30s")

.PARAMETER HealthTimeout
    Seconds to wait for stacks to become healthy (default: 120)

.PARAMETER SkipGo
    Skip the Go stack (run Python only, useful for debugging)

.PARAMETER SkipPython
    Skip the Python stack (run Go only)

.PARAMETER NoBuild
    Skip `--build` on compose up (use cached images)

.PARAMETER NoReport
    Skip HTML report generation after the run

.PARAMETER KeepK6Container
    Keep the k6 container after each run for log inspection.
    Clean up with: podman rm <container-id>

.EXAMPLE
    # Full comparison — all scenarios, both stacks
    .\tests\perf\run-bench.ps1

.EXAMPLE
    # Quick smoke run: fewer VUs, shorter windows
    .\tests\perf\run-bench.ps1 -MaxVUs 5 -RampDuration 10s -SteadyDuration 20s -RegDuration 15s

.EXAMPLE
    # Go stack only, 40 VUs
    .\tests\perf\run-bench.ps1 -SkipPython -MaxVUs 40 -SteadyDuration 120s
#>

[CmdletBinding()]
param(
    [int]    $MaxVUs         = 20,
    [string] $RampDuration   = '20s',
    [string] $SteadyDuration = '60s',
    [int]    $NumUsers       = 40,
    [int]    $RegRate        = 10,
    [string] $RegDuration    = '30s',
    [int]    $HealthTimeout  = 120,
    [switch] $SkipGo,
    [switch] $SkipPython,
    [switch] $NoBuild,
    [switch] $NoReport,
    [switch] $KeepK6Container
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Paths ─────────────────────────────────────────────────────────────────────
$RepoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
$PerfDir    = "$PSScriptRoot"
$K6Dir      = "$PerfDir\k6"
$ResultsDir = "$PerfDir\results"
$Timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'

New-Item -ItemType Directory -Force -Path $ResultsDir       | Out-Null
New-Item -ItemType Directory -Force -Path "$K6Dir\results"  | Out-Null

# Scenarios to run in order — reg_throughput first (cold DB), transfers after.
$AllScenarios = @('reg_throughput', 'single_pair', 'multi_user', 'fan_out', 'transfer_journey')

$K6Image = 'grafana/k6:latest'

# ── Helpers: coloured output ──────────────────────────────────────────────────
function Log-Step    ([string]$msg) { Write-Host "`n🔷 $msg"   -ForegroundColor Cyan   }
function Log-OK      ([string]$msg) { Write-Host "  ✅ $msg"   -ForegroundColor Green  }
function Log-Warn    ([string]$msg) { Write-Host "  ⚠️  $msg"  -ForegroundColor Yellow }
function Log-Info    ([string]$msg) { Write-Host "  ℹ  $msg"   -ForegroundColor Gray   }
function Log-Scenario([string]$msg) { Write-Host "`n  ▶  $msg" -ForegroundColor Magenta }

# ── Helper: wait for Kong ─────────────────────────────────────────────────────
function Wait-StackHealthy([int]$KongPort, [int]$TimeoutSecs) {
    Log-Info "Waiting for Kong on :$KongPort (timeout=${TimeoutSecs}s)..."
    $deadline = (Get-Date).AddSeconds($TimeoutSecs)
    while ((Get-Date) -lt $deadline) {
        $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 3 "http://localhost:$KongPort" 2>$null
        if ($LASTEXITCODE -eq 0 -and $code -match '^\d{3}$') {
            Log-OK "Kong on :$KongPort responding (HTTP $code)"; return
        }
        Start-Sleep -Seconds 3
    }
    throw "Stack on :$KongPort did not become healthy within ${TimeoutSecs}s"
}

# ── Helper: wait for full Kong → queue → consumer path ───────────────────────
function Wait-ServicesReady([int]$KongPort, [string]$Service, [int]$TimeoutSecs) {
    if ($Service -eq 'python-producer') {
        $url  = "http://localhost:$KongPort/api/auth/login"
        $body = '{"username":"alice","password":"Password1!"}'
        Log-Info "Waiting for Python auth consumer via $url (timeout=${TimeoutSecs}s)..."
        $deadline = (Get-Date).AddSeconds($TimeoutSecs)
        while ((Get-Date) -lt $deadline) {
            $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 8 `
                        -X POST -H 'Content-Type: application/json' -d $body $url 2>$null
            if ($LASTEXITCODE -eq 0 -and $code -eq '200') {
                Log-OK "Python auth consumer ready (HTTP 200)"; return
            }
            Log-Info "  Not ready (HTTP $code) — retrying in 5s..."
            Start-Sleep -Seconds 5
        }
        throw "Python auth consumer on :$KongPort did not become ready within ${TimeoutSecs}s"
    } else {
        $url = "http://localhost:$KongPort/api/health/$Service"
        Log-Info "Waiting for services via $url (timeout=${TimeoutSecs}s)..."
        $deadline = (Get-Date).AddSeconds($TimeoutSecs)
        while ((Get-Date) -lt $deadline) {
            $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 5 $url 2>$null
            if ($LASTEXITCODE -eq 0 -and $code -eq '200') {
                Log-OK "Services ready ($url → HTTP 200)"; return
            }
            Log-Info "  Not ready (HTTP $code) — retrying in 3s..."
            Start-Sleep -Seconds 3
        }
        throw "Services on :$KongPort/$Service did not become ready within ${TimeoutSecs}s"
    }
}

# ── Helper: run a single k6 scenario ─────────────────────────────────────────
# Returns the k6 process exit code.
# Saves: perf/results/<stack>-<scenario>-<timestamp>.json
function Run-K6Scenario([string]$Stack, [string]$BaseUrl, [string]$ScenarioName) {
    Log-Scenario "k6 scenario: $ScenarioName  (stack=$Stack)"

    $testPassword = if ($Stack -eq 'python') { 'Password1!' } else { 'Perf@1234' }

    $rmFlag = if ($KeepK6Container) { @() } else { @('--rm') }
    $k6Args = @('run') + $rmFlag + @(
        '--network=host',
        '-v', "${K6Dir}:/scripts",
        '-e', "STACK_TYPE=$Stack",
        '-e', "BASE_URL=$BaseUrl",
        '-e', "SCENARIO=$ScenarioName",
        '-e', "MAX_VUS=$MaxVUs",
        '-e', "RAMP_DURATION=$RampDuration",
        '-e', "STEADY_DURATION=$SteadyDuration",
        '-e', "N_USERS=$NumUsers",
        '-e', "REG_RATE=$RegRate",
        '-e', "REG_DURATION=$RegDuration",
        '-e', "TEST_PASSWORD=$testPassword",
        $K6Image,
        'run',
        '/scripts/scenario.js'
    )

    Log-Info "podman $($k6Args -join ' ')"

    $proc = Start-Process -FilePath 'podman' -ArgumentList $k6Args `
                          -Wait -NoNewWindow -PassThru
    if ($proc.ExitCode -ne 0) {
        Log-Warn "k6 exited $($proc.ExitCode) for $ScenarioName — results may be partial"
    }

    # scenario.js handleSummary writes: /scripts/results/<stack>-<scenario>-summary.json
    $src = "$K6Dir\results\${Stack}-${ScenarioName}-summary.json"
    $dst = "$ResultsDir\${Stack}-${ScenarioName}-${Timestamp}.json"
    if (Test-Path $src) {
        Copy-Item $src $dst -Force
        Log-OK "$ScenarioName results → tests/perf/results/${Stack}-${ScenarioName}-${Timestamp}.json"
    } else {
        Log-Warn "No summary JSON at $src — handleSummary may have failed"
    }

    return $proc.ExitCode
}

# ── Helper: reset perf-user balances directly in Postgres ────────────────────
# Runs via `podman exec <container> psql` — no extra endpoint needed.
#
# Resets every user whose username starts with "perf_" or "alice"/"bob" (Python
# stack seed users) back to the schema DEFAULT (100 000 units). This guarantees
# each scenario starts from a known state regardless of how many transfers the
# previous scenario executed, making back-to-back runs fully reproducible.
#
# Also removes stale perf_user_* rows created by multi_user / fan_out from any
# prior run so that batchRegisterAndLogin in setup() sees fresh inserts rather
# than 409 idempotent re-logins (both work, but fresh inserts give cleaner reg
# latency data for the reg_throughput scenario).
function Reset-Balances([string]$PgContainer) {
    Log-Info "Resetting perf-user balances in $PgContainer ..."
    $sql = "UPDATE users SET balance = 100000 WHERE username LIKE 'perf_%' OR username IN ('alice','bob');"
    $out = & podman exec $PgContainer psql -U banking -d banking -c $sql 2>&1
    if ($LASTEXITCODE -ne 0) {
        Log-Warn "Balance reset failed (exit $LASTEXITCODE): $out"
    } else {
        Log-OK "Balances reset ($out)"
    }
}

# ── Helper: run all scenarios against one stack ───────────────────────────────
# Returns hashtable: scenario → exit code
function Run-AllScenarios([string]$Stack, [string]$BaseUrl, [string]$PgContainer) {
    Log-Info "Pulling $K6Image ..."
    podman pull $K6Image 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

    Reset-Balances -PgContainer $PgContainer

    $exits = @{}
    foreach ($s in $AllScenarios) {
        # Reset balances before each transfer scenario so contention ceilings and
        # throughput numbers are not distorted by near-zero sender balances from
        # the previous scenario.
        if ($s -ne 'reg_throughput') {
            Reset-Balances -PgContainer $PgContainer
        }
        $exits[$s] = Run-K6Scenario -Stack $Stack -BaseUrl $BaseUrl -ScenarioName $s
    }
    return $exits
}

# ── Helper: extract stat from compact summary JSON ────────────────────────────
function Extract-Stat([string]$File, [string]$MetricName, [string]$Stat) {
    if (-not (Test-Path $File)) { return 'N/A' }
    try {
        $obj = Get-Content $File -Raw | ConvertFrom-Json
        $val = $obj.$MetricName.values.$Stat
        if ($null -eq $val) { return 'N/A' }
        return [math]::Round([double]$val, 2)
    } catch { return 'N/A' }
}

function Fmt([string]$raw, [string]$unit = '') {
    if ($raw -eq 'N/A') { return 'N/A' }
    try { return "$([math]::Round([double]$raw, 1))$unit" } catch { return 'N/A' }
}
function FmtPct([string]$raw) {
    if ($raw -eq 'N/A') { return 'N/A' }
    try { return "$([math]::Round([double]$raw * 100, 2))%" } catch { return 'N/A' }
}

# ── Per-scenario terminal summary ─────────────────────────────────────────────
function Show-ScenarioSummary([string]$ScenarioName, [string]$GoFile, [string]$PyFile) {
    $label = $ScenarioName.ToUpper().Replace('_', ' ')
    $line  = "─" * (60 - $label.Length - 2)
    Write-Host ""
    Write-Host ("  ── $label $line") -ForegroundColor DarkCyan
    Write-Host ("  {0,-38}  {1,12}  {2,12}" -f "Metric", "Go", "Python") -ForegroundColor DarkGray

    if ($ScenarioName -eq 'reg_throughput') {
        Show-Row "Reg latency avg"     (Fmt (Extract-Stat $GoFile 'reg_latency' 'avg')   'ms') (Fmt (Extract-Stat $PyFile 'reg_latency' 'avg')   'ms')
        Show-Row "Reg latency p95"     (Fmt (Extract-Stat $GoFile 'reg_latency' 'p(95)') 'ms') (Fmt (Extract-Stat $PyFile 'reg_latency' 'p(95)') 'ms')
        Show-Row "Reg latency p99"     (Fmt (Extract-Stat $GoFile 'reg_latency' 'p(99)') 'ms') (Fmt (Extract-Stat $PyFile 'reg_latency' 'p(99)') 'ms')
        Show-Row "Reg error rate"      (FmtPct (Extract-Stat $GoFile 'reg_errors' 'rate'))      (FmtPct (Extract-Stat $PyFile 'reg_errors' 'rate'))
        Show-Row "Registrations/s"     (Fmt (Extract-Stat $GoFile 'regs_completed' 'rate') '/s') (Fmt (Extract-Stat $PyFile 'regs_completed' 'rate') '/s') $false
    } elseif ($ScenarioName -eq 'transfer_journey') {
        # journey_latency = full sequential cycle (POST /transfer + GET /balance), no think time
        Show-Row "Journey latency p50"   (Fmt (Extract-Stat $GoFile 'journey_latency' 'med')   'ms') (Fmt (Extract-Stat $PyFile 'journey_latency' 'med')   'ms')
        Show-Row "Journey latency p95"   (Fmt (Extract-Stat $GoFile 'journey_latency' 'p(95)') 'ms') (Fmt (Extract-Stat $PyFile 'journey_latency' 'p(95)') 'ms')
        Show-Row "Journey latency p99"   (Fmt (Extract-Stat $GoFile 'journey_latency' 'p(99)') 'ms') (Fmt (Extract-Stat $PyFile 'journey_latency' 'p(99)') 'ms')
        Show-Row "Status check p95"      (Fmt (Extract-Stat $GoFile 'journey_status_latency' 'p(95)') 'ms') (Fmt (Extract-Stat $PyFile 'journey_status_latency' 'p(95)') 'ms')
        Show-Row "Transfer latency p95"  (Fmt (Extract-Stat $GoFile 'transfer_latency' 'p(95)') 'ms') (Fmt (Extract-Stat $PyFile 'transfer_latency' 'p(95)') 'ms')
        Show-Row "Journey error rate"    (FmtPct (Extract-Stat $GoFile 'journey_errors' 'rate'))       (FmtPct (Extract-Stat $PyFile 'journey_errors' 'rate'))
        Show-Row "Journeys completed"    (Fmt (Extract-Stat $GoFile 'journeys_completed' 'count') ' cycles') (Fmt (Extract-Stat $PyFile 'journeys_completed' 'count') ' cycles') $false
        Show-Row "Serialization retries" (FmtPct (Extract-Stat $GoFile 'serialization_retries' 'rate')) $(if ($PyFile -ne '') { 'n/a (RabbitMQ)' } else { 'N/A' })
    } else {
        Show-Row "Transfer latency p50"  (Fmt (Extract-Stat $GoFile 'transfer_latency' 'med')   'ms') (Fmt (Extract-Stat $PyFile 'transfer_latency' 'med')   'ms')
        Show-Row "Transfer latency p95"  (Fmt (Extract-Stat $GoFile 'transfer_latency' 'p(95)') 'ms') (Fmt (Extract-Stat $PyFile 'transfer_latency' 'p(95)') 'ms')
        Show-Row "Transfer latency p99"  (Fmt (Extract-Stat $GoFile 'transfer_latency' 'p(99)') 'ms') (Fmt (Extract-Stat $PyFile 'transfer_latency' 'p(99)') 'ms')
        Show-Row "Transfer error rate"   (FmtPct (Extract-Stat $GoFile 'transfer_errors' 'rate'))      (FmtPct (Extract-Stat $PyFile 'transfer_errors' 'rate'))
        Show-Row "Serialization retries" (FmtPct (Extract-Stat $GoFile 'serialization_retries' 'rate')) $(if ($PyFile -ne '') { 'n/a (RabbitMQ)' } else { 'N/A' })
        Show-Row "Throughput req/s"      (Fmt (Extract-Stat $GoFile 'http_reqs' 'rate') '/s') (Fmt (Extract-Stat $PyFile 'http_reqs' 'rate') '/s') $false
        Show-Row "Transfers completed"   (Fmt (Extract-Stat $GoFile 'transfers_completed' 'count') ' tx') (Fmt (Extract-Stat $PyFile 'transfers_completed' 'count') ' tx') $false
        Show-Row "Auth latency p95"      (Fmt (Extract-Stat $GoFile 'auth_latency' 'p(95)') 'ms') (Fmt (Extract-Stat $PyFile 'auth_latency' 'p(95)') 'ms')
        Show-Row "Balance latency p95"   (Fmt (Extract-Stat $GoFile 'balance_latency' 'p(95)') 'ms') (Fmt (Extract-Stat $PyFile 'balance_latency' 'p(95)') 'ms')
    }
}

function Show-Row([string]$Label, [string]$GoVal, [string]$PyVal, [bool]$LowerIsBetter = $true) {
    $gc = 'White'; $pc = 'White'
    try {
        $gn = [double]($GoVal -replace '[^\d.]', '')
        $pn = [double]($PyVal -replace '[^\d.]', '')
        if ($LowerIsBetter) {
            if ($gn -lt $pn) { $gc = 'Green'; $pc = 'Red'   }
            elseif ($pn -lt $gn) { $gc = 'Red';   $pc = 'Green' }
        } else {
            if ($gn -gt $pn) { $gc = 'Green'; $pc = 'Red'   }
            elseif ($pn -gt $gn) { $gc = 'Red';   $pc = 'Green' }
        }
    } catch {}
    Write-Host ("  {0,-38}" -f $Label) -NoNewline -ForegroundColor Gray
    Write-Host ("  {0,12}" -f $GoVal)  -NoNewline -ForegroundColor $gc
    Write-Host ("  {0,12}" -f $PyVal)  -ForegroundColor $pc
}

# ── Phase 1: Go stack ─────────────────────────────────────────────────────────
$goExits = @{}

if (-not $SkipGo) {
    Log-Step "PHASE 1 — Go stack (golang branch, port 8000)"

    Push-Location $RepoRoot
    try {
        $goUpArgs = @('compose', '-f', 'docker-compose.yml', '-f', 'tests/perf/docker-compose.override.yml', 'up', '-d')
        if (-not $NoBuild) { $goUpArgs += '--build' }
        Log-Info "podman $($goUpArgs -join ' ') ..."
        & podman @goUpArgs 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) { throw "compose up failed for Go stack (exit $LASTEXITCODE)" }

        # Wait for postgres then run migrations.
        $pgDeadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $pgDeadline) {
            & podman exec banking-postgres pg_isready -U banking 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Log-OK "Postgres ready"; break }
            Start-Sleep -Seconds 2
        }
        & podman @(
            'run', '--rm', '--network=host',
            '-v', "${RepoRoot}/migrations:/migrations",
            'migrate/migrate',
            '-path', '/migrations',
            '-database', 'postgresql://banking:bankingpass@localhost:5432/banking?sslmode=disable',
            'up'
        ) 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) {
            Log-Warn "migrate exited $LASTEXITCODE — tables may already exist ('no change' is safe)"
        } else {
            Log-OK "Migrations applied"
        }

        Wait-StackHealthy  -KongPort 8000 -TimeoutSecs $HealthTimeout
        Wait-ServicesReady -KongPort 8000 -Service 'auth' -TimeoutSecs 60

        $goExits = Run-AllScenarios -Stack 'go' -BaseUrl 'http://localhost:8000' -PgContainer 'banking-postgres'

    } finally {
        Log-Step "Tearing down Go stack..."
        podman compose -f docker-compose.yml down -v 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Pop-Location
    }
}

# ── Phase 2: Python stack ─────────────────────────────────────────────────────
$pyExits = @{}

if (-not $SkipPython) {
    Log-Step "PHASE 2 — Python stack (origin/final, port 9000)"

    Push-Location $RepoRoot
    try {
        $pyUpArgs = @('compose', '-f', 'tests/perf/docker-compose.python.yml', '-f', 'tests/perf/docker-compose.python.override.yml', 'up', '-d')
        if (-not $NoBuild) { $pyUpArgs += '--build' }
        Log-Info "podman $($pyUpArgs -join ' ') ..."
        & podman @pyUpArgs 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) { throw "compose up failed for Python stack (exit $LASTEXITCODE)" }

        Wait-StackHealthy  -KongPort 9000 -TimeoutSecs ($HealthTimeout + 30)
        Wait-ServicesReady -KongPort 9000 -Service 'python-producer' -TimeoutSecs 120

        $pyExits = Run-AllScenarios -Stack 'python' -BaseUrl 'http://localhost:9000' -PgContainer 'py-postgres'

    } finally {
        Log-Step "Tearing down Python stack..."
        podman compose -f tests/perf/docker-compose.python.yml down -v 2>&1 |
            ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Pop-Location
    }
}

# ── Terminal summary — all scenarios ─────────────────────────────────────────
Log-Step "BENCHMARK COMPLETE — All Scenarios Summary"
Write-Host ""
Write-Host ("=" * 80) -ForegroundColor White
Write-Host "  Go vs Python — Full Benchmark  ($Timestamp)" -ForegroundColor White
Write-Host "  VUs=$MaxVUs  Ramp=$RampDuration  Steady=$SteadyDuration  N=$NumUsers  RegRate=${RegRate}/s" -ForegroundColor Gray
Write-Host ("=" * 80) -ForegroundColor White

foreach ($s in $AllScenarios) {
    $gf = "$ResultsDir\go-${s}-${Timestamp}.json"
    $pf = "$ResultsDir\python-${s}-${Timestamp}.json"
    Show-ScenarioSummary -ScenarioName $s -GoFile $gf -PyFile $pf
}

Write-Host ""
Write-Host ("=" * 80) -ForegroundColor White
Write-Host ""
Write-Host "  Results → tests/perf/results/" -ForegroundColor Gray
Write-Host "  Go only:    .\tests\perf\run-bench.ps1 -SkipPython" -ForegroundColor Gray
Write-Host "  Faster run: .\tests\perf\run-bench.ps1 -MaxVUs 5 -SteadyDuration 20s -RegDuration 15s" -ForegroundColor Gray
Write-Host ""

# ── HTML report — unified report for ALL four scenarios ───────────────────────
if (-not $NoReport) {
    Log-Step "Generating unified HTML report (all scenarios)..."
    $reportScript = "$PerfDir\generate-report.ps1"
    if (Test-Path $reportScript) {
        & $reportScript `
            -GoMultiFile       "$ResultsDir\go-multi_user-${Timestamp}.json" `
            -PythonMultiFile   "$ResultsDir\python-multi_user-${Timestamp}.json" `
            -GoSingleFile      "$ResultsDir\go-single_pair-${Timestamp}.json" `
            -PythonSingleFile  "$ResultsDir\python-single_pair-${Timestamp}.json" `
            -GoFanOutFile      "$ResultsDir\go-fan_out-${Timestamp}.json" `
            -PythonFanOutFile  "$ResultsDir\python-fan_out-${Timestamp}.json" `
            -GoRegFile         "$ResultsDir\go-reg_throughput-${Timestamp}.json" `
            -PyRegFile         "$ResultsDir\python-reg_throughput-${Timestamp}.json" `
            -GoJourneyFile     "$ResultsDir\go-transfer_journey-${Timestamp}.json" `
            -PythonJourneyFile "$ResultsDir\python-transfer_journey-${Timestamp}.json" `
            -Timestamp         "$Timestamp" `
            -MaxVUs            $MaxVUs `
            -RampDuration      "$RampDuration" `
            -SteadyDuration    "$SteadyDuration" `
            -NumUsers          $NumUsers `
            -RegRate           $RegRate `
            -OutputDir         "$ResultsDir"
    } else {
        Log-Warn "generate-report.ps1 not found — skipping HTML report"
    }
}

# ── Exit code — non-zero if any scenario on any stack failed ──────────────────
$anyFailed = $false
foreach ($s in $AllScenarios) {
    if ($goExits[$s] -and $goExits[$s] -ne 0) {
        Log-Warn "Go/$s exited $($goExits[$s])"
        $anyFailed = $true
    }
    if ($pyExits[$s] -and $pyExits[$s] -ne 0) {
        Log-Warn "Python/$s exited $($pyExits[$s])"
        $anyFailed = $true
    }
}
if ($anyFailed) { exit 1 }
