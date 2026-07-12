<#
.SYNOPSIS
    Parse k6 JSON output files and generate a unified, self-contained HTML benchmark report
    covering all five scenarios: reg_throughput, single_pair, multi_user, fan_out, transfer_journey.

.DESCRIPTION
    Reads the k6 handleSummary JSON files produced by run-bench.ps1 and emits a single
    self-contained HTML file with:
      - Executive summary: overall SLO pass/fail, best-stack badge per scenario
      - Per-scenario sections with SVG bar charts and full metric breakdown tables
      - SLO badge table per scenario
      - Architecture reference table
      - Run metadata (VUs, timestamps, stack config)

    Accepts optional scenario-specific files for each of the five scenarios.
    Any file not supplied is auto-discovered from the results directory (latest).

.PARAMETER GoMultiFile
    Go multi_user summary JSON (true throughput baseline).

.PARAMETER PythonMultiFile
    Python multi_user summary JSON.

.PARAMETER GoSingleFile
    Go single_pair summary JSON (contention ceiling).

.PARAMETER PythonSingleFile
    Python single_pair summary JSON.

.PARAMETER GoFanOutFile
    Go fan_out summary JSON (hot-account stress).

.PARAMETER PythonFanOutFile
    Python fan_out summary JSON.

.PARAMETER GoRegFile
    Go reg_throughput summary JSON (registration benchmark).

.PARAMETER PyRegFile
    Python reg_throughput summary JSON.

.PARAMETER Timestamp
    Run timestamp string (used in filename; defaults to now).

.PARAMETER MaxVUs
    Peak VU count used in the run (display only).

.PARAMETER RampDuration
    Ramp stage duration (display only).

.PARAMETER SteadyDuration
    Steady measurement window (display only).

.PARAMETER NumUsers
    User pool size (display only).

.PARAMETER RegRate
    Registration target rate (display only).

.PARAMETER OutputDir
    Directory to write the HTML report into (default: same dir as script).

.EXAMPLE
    # Generate from existing result files (all scenarios)
    .\tests\perf\generate-report.ps1 `
      -GoMultiFile   tests/perf/results/go-multi_user-20250115-143022.json `
      -PythonMultiFile tests/perf/results/python-multi_user-20250115-143022.json

.EXAMPLE
    # Called automatically by run-bench.ps1 after each run
    .\tests\perf\generate-report.ps1 -Timestamp 20250115-143022 -MaxVUs 20
#>

[CmdletBinding()]
param(
    # multi_user (primary signal — true throughput)
    [string] $GoMultiFile,
    [string] $PythonMultiFile,
    # single_pair (contention ceiling)
    [string] $GoSingleFile,
    [string] $PythonSingleFile,
    # fan_out (hot-account stress)
    [string] $GoFanOutFile,
    [string] $PythonFanOutFile,
    # reg_throughput (registration benchmark)
    [string] $GoRegFile,
    [string] $PyRegFile,
    # transfer_journey (sequential user journey — primary latency signal)
    [string] $GoJourneyFile,
    [string] $PythonJourneyFile,
    # capacity / breakpoint (optional — only shown if files provided)
    [string] $GoCapFile,
    [string] $PyCapFile,
    # Legacy compat: accept old -GoFile / -PythonFile as aliases for multi_user
    [string] $GoFile,
    [string] $PythonFile,
    # Metadata
    [string] $Timestamp      = (Get-Date -Format 'yyyyMMdd-HHmmss'),
    [int]    $MaxVUs         = 20,
    [string] $RampDuration   = '20s',
    [string] $SteadyDuration = '60s',
    [int]    $NumUsers       = 40,
    [int]    $RegRate        = 20,
    [string] $OutputDir
)

Set-StrictMode -Version Latest

$ResultsDir = "$PSScriptRoot\results"

# ── Legacy compat: -GoFile / -PythonFile → multi_user ─────────────────────────
if ($GoFile     -and -not $GoMultiFile)     { $GoMultiFile     = $GoFile     }
if ($PythonFile -and -not $PythonMultiFile) { $PythonMultiFile = $PythonFile }

# ── Auto-discover files when not supplied ─────────────────────────────────────
function Discover([string]$pattern, [string]$label) {
    $f = Get-ChildItem "$ResultsDir\$pattern" -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    if ($f) { Write-Host "  ℹ  Auto-detected $label : $f" -ForegroundColor Gray }
    return $f
}

if (-not $GoMultiFile)     { $GoMultiFile     = Discover 'go-multi_user-*.json'     'Go multi_user' }
if (-not $PythonMultiFile) { $PythonMultiFile = Discover 'python-multi_user-*.json' 'Python multi_user' }
if (-not $GoSingleFile)    { $GoSingleFile    = Discover 'go-single_pair-*.json'    'Go single_pair' }
if (-not $PythonSingleFile){ $PythonSingleFile= Discover 'python-single_pair-*.json''Python single_pair' }
if (-not $GoFanOutFile)    { $GoFanOutFile    = Discover 'go-fan_out-*.json'        'Go fan_out' }
if (-not $PythonFanOutFile){ $PythonFanOutFile= Discover 'python-fan_out-*.json'    'Python fan_out' }
if (-not $GoRegFile)       { $GoRegFile       = Discover 'go-reg_throughput-*.json' 'Go reg_throughput' }
if (-not $PyRegFile)       { $PyRegFile       = Discover 'python-reg_throughput-*.json' 'Python reg_throughput' }
if (-not $GoJourneyFile)   { $GoJourneyFile   = Discover 'go-transfer_journey-*.json'    'Go transfer_journey' }
if (-not $PythonJourneyFile){ $PythonJourneyFile = Discover 'python-transfer_journey-*.json' 'Python transfer_journey' }
# capacity: NOT auto-discovered — must be supplied explicitly or via explicit path
# (auto-discovery would accidentally pick up an old capacity run from a different config)

if (-not $OutputDir) { $OutputDir = $ResultsDir }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# ── Stat extraction helpers ───────────────────────────────────────────────────
$script:_statCache = @{}
function Get-ParsedSummary([string]$File) {
    if (-not $File -or -not (Test-Path $File)) { return $null }
    if ($script:_statCache.ContainsKey($File)) { return $script:_statCache[$File] }
    try {
        $obj = Get-Content $File -Raw | ConvertFrom-Json
        $script:_statCache[$File] = $obj
        return $obj
    } catch { return $null }
}

function Get-Stat([string]$File, [string]$MetricName, [string]$StatKey) {
    $obj = Get-ParsedSummary $File
    if ($null -eq $obj) { return $null }
    $metric = $obj.$MetricName
    if ($null -eq $metric) { return $null }
    $val = $metric.values.$StatKey
    if ($null -eq $val) { return $null }
    return [math]::Round([double]$val, 2)
}

function Get-Rate([string]$File, [string]$MetricName) {
    $v = Get-Stat $File $MetricName 'rate'
    if ($null -eq $v) { return $null }
    # Round to 3 decimal places so low-rate events (0.12%) are not silently
    # displayed as "0%" and confused with a true zero-error run.
    return [math]::Round($v * 100, 4)
}

function Get-Count([string]$File, [string]$MetricName) {
    $v = Get-Stat $File $MetricName 'count'
    if ($null -eq $v) { return $null }
    return [math]::Round($v, 0)
}

# ── Collect metrics for one stack+file ───────────────────────────────────────
function Get-TransferMetrics([string]$File) {
    return @{
        tx_avg   = Get-Stat $File 'transfer_latency' 'avg'
        tx_med   = Get-Stat $File 'transfer_latency' 'med'
        tx_p90   = Get-Stat $File 'transfer_latency' 'p(90)'
        tx_p95   = Get-Stat $File 'transfer_latency' 'p(95)'
        tx_p99   = Get-Stat $File 'transfer_latency' 'p(99)'
        tx_max   = Get-Stat $File 'transfer_latency' 'max'
        wait_avg = Get-Stat $File 'transfer_waiting'    'avg'
        wait_p95 = Get-Stat $File 'transfer_waiting'    'p(95)'
        conn_avg = Get-Stat $File 'transfer_connecting' 'avg'
        recv_avg = Get-Stat $File 'transfer_receiving'  'avg'
        auth_avg = Get-Stat $File 'auth_latency' 'avg'
        auth_p95 = Get-Stat $File 'auth_latency' 'p(95)'
        bal_avg  = Get-Stat $File 'balance_latency' 'avg'
        bal_p95  = Get-Stat $File 'balance_latency' 'p(95)'
        tx_err   = Get-Rate $File 'transfer_errors'
        auth_err = Get-Rate $File 'auth_errors'
        bal_err  = Get-Rate $File 'balance_errors'
        serial   = Get-Rate $File 'serialization_retries'
        rps      = Get-Stat $File 'http_reqs' 'rate'
        tx_ok    = Get-Count $File 'transfers_completed'
        checks   = Get-Rate $File 'checks'
        iter_p95 = Get-Stat $File 'iteration_duration' 'p(95)'
    }
}

function Get-RegMetrics([string]$File) {
    return @{
        reg_avg = Get-Stat  $File 'reg_latency'    'avg'
        reg_med = Get-Stat  $File 'reg_latency'    'med'
        reg_p90 = Get-Stat  $File 'reg_latency'    'p(90)'
        reg_p95 = Get-Stat  $File 'reg_latency'    'p(95)'
        reg_p99 = Get-Stat  $File 'reg_latency'    'p(99)'
        reg_max = Get-Stat  $File 'reg_latency'    'max'
        reg_err = Get-Rate  $File 'reg_errors'
        reg_rps = Get-Stat  $File 'regs_completed' 'rate'
        reg_ok  = Get-Count $File 'regs_completed'
        checks  = Get-Rate  $File 'checks'
    }
}

# journey_latency = wall-clock from POST /transfer start → GET /balance end (no think time).
# journey_status_latency = just the GET /balance step inside the cycle.
function Get-JourneyMetrics([string]$File) {
    return @{
        j_avg    = Get-Stat  $File 'journey_latency'        'avg'
        j_med    = Get-Stat  $File 'journey_latency'        'med'
        j_p90    = Get-Stat  $File 'journey_latency'        'p(90)'
        j_p95    = Get-Stat  $File 'journey_latency'        'p(95)'
        j_p99    = Get-Stat  $File 'journey_latency'        'p(99)'
        j_max    = Get-Stat  $File 'journey_latency'        'max'
        st_avg   = Get-Stat  $File 'journey_status_latency' 'avg'
        st_p95   = Get-Stat  $File 'journey_status_latency' 'p(95)'
        tx_p95   = Get-Stat  $File 'transfer_latency'       'p(95)'
        tx_wait  = Get-Stat  $File 'transfer_waiting'       'p(95)'
        tx_conn  = Get-Stat  $File 'transfer_connecting'    'p(99)'
        j_err    = Get-Rate  $File 'journey_errors'
        tx_err   = Get-Rate  $File 'transfer_errors'
        serial   = Get-Rate  $File 'serialization_retries'
        j_ok     = Get-Count $File 'journeys_completed'
        checks   = Get-Rate  $File 'checks'
    }
}

$goMulti    = Get-TransferMetrics $GoMultiFile
$pyMulti    = Get-TransferMetrics $PythonMultiFile
$goSingle   = Get-TransferMetrics $GoSingleFile
$pySingle   = Get-TransferMetrics $PythonSingleFile
$goFanOut   = Get-TransferMetrics $GoFanOutFile
$pyFanOut   = Get-TransferMetrics $PythonFanOutFile
$goReg      = Get-RegMetrics $GoRegFile
$pyReg      = Get-RegMetrics $PyRegFile
$goJourney  = Get-JourneyMetrics $GoJourneyFile
$pyJourney  = Get-JourneyMetrics $PythonJourneyFile
$goCap      = Get-TransferMetrics $GoCapFile
$pyCap      = Get-TransferMetrics $PyCapFile

# ── SLO evaluation ────────────────────────────────────────────────────────────
function Slo([object]$value, [double]$threshold, [bool]$lowerBetter = $true) {
    if ($null -eq $value) { return 'na' }
    $v = [double]$value
    if ($lowerBetter) { if ($v -le $threshold) { return 'pass' } else { return 'fail' } }
    else              { if ($v -ge $threshold) { return 'pass' } else { return 'fail' } }
}

function Badge([string]$state) {
    switch ($state) {
        'pass' { return "<span class='badge pass'>PASS</span>" }
        'fail' { return "<span class='badge fail'>FAIL</span>" }
        default { return "<span class='badge na'>N/A</span>" }
    }
}

# ── SLO badge set for a transfer metrics hashtable ────────────────────────────
function Get-Slos([hashtable]$go, [hashtable]$py, [bool]$isGoPy = $true) {
    return @{
        go_tx_p95   = Badge (Slo $go.tx_p95   1500)
        py_tx_p95   = Badge (Slo $py.tx_p95   1500)
        go_tx_p99   = Badge (Slo $go.tx_p99   3000)
        py_tx_p99   = Badge (Slo $py.tx_p99   3000)
        go_tx_err   = Badge (Slo $go.tx_err   2)
        py_tx_err   = Badge (Slo $py.tx_err   2)
        go_serial   = Badge (Slo $go.serial   5)
        py_serial   = Badge 'na'
        go_auth_p95 = Badge (Slo $go.auth_p95 500)
        py_auth_p95 = Badge (Slo $py.auth_p95 500)
        go_bal_p95  = Badge (Slo $go.bal_p95  200)
        py_bal_p95  = Badge (Slo $py.bal_p95  200)
        go_wait_p95 = Badge (Slo $go.wait_p95 1200)
        py_wait_p95 = Badge (Slo $py.wait_p95 1200)
        go_checks   = Badge (Slo $go.checks   99 $false)
        py_checks   = Badge (Slo $py.checks   99 $false)
    }
}

$sloMulti  = Get-Slos $goMulti  $pyMulti
$sloSingle = Get-Slos $goSingle $pySingle
$sloFanOut = Get-Slos $goFanOut $pyFanOut

# ── SVG bar chart builder ─────────────────────────────────────────────────────
function Build-BarChart {
    param(
        [string[]] $Labels,
        [object[]] $GoVals,
        [object[]] $PyVals,
        [double]   $MaxVal = 0,
        [string]   $Unit = 'ms',
        [int]      $Height = 220,
        [bool]     $HigherBetter = $false
    )

    $n = $Labels.Count
    $svgW = [math]::Max(420, $n * 100 + 80)
    $svgH = $Height
    $padL = 52; $padR = 16; $padT = 20; $padB = 56

    $chartW = $svgW - $padL - $padR
    $chartH = $svgH - $padT - $padB

    $allVals = @(($GoVals + $PyVals) | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($allVals.Count -eq 0) {
        return "<svg width='$svgW' height='$svgH'><text x='50%' y='50%' text-anchor='middle' fill='#999' font-size='13' dominant-baseline='middle'>No data</text></svg>"
    }

    if ($MaxVal -le 0) { $MaxVal = [math]::Ceiling(($allVals | Measure-Object -Maximum).Maximum * 1.20) }
    if ($MaxVal -eq 0) { $MaxVal = 1 }

    $groupW = $chartW / $n
    $barW   = [math]::Max(8,  [math]::Floor($groupW * 0.32))
    $gap    = [math]::Max(2,  [math]::Floor($groupW * 0.06))

    $goColor   = '#3b82d4'
    $pyColor   = '#e8943a'
    $axisFill  = '#8b949e'
    $gridColor = '#e5e7eb'

    $svg = New-Object System.Text.StringBuilder
    [void]$svg.Append("<svg xmlns='http://www.w3.org/2000/svg' width='$svgW' height='$svgH' style='font-family:-apple-system,Segoe UI,sans-serif'>")

    # Grid lines (4 horizontal)
    for ($g = 1; $g -le 4; $g++) {
        $gy = $padT + $chartH - [math]::Round($chartH * $g / 4)
        $gv = [math]::Round($MaxVal * $g / 4, 0)
        [void]$svg.Append("<line x1='$padL' y1='$gy' x2='$($padL+$chartW)' y2='$gy' stroke='$gridColor' stroke-width='1'/>")
        [void]$svg.Append("<text x='$($padL-6)' y='$($gy+4)' text-anchor='end' font-size='10' fill='$axisFill'>$gv</text>")
    }

    # X-axis baseline
    $axisY = $padT + $chartH
    [void]$svg.Append("<line x1='$padL' y1='$axisY' x2='$($padL+$chartW)' y2='$axisY' stroke='$gridColor' stroke-width='1'/>")

    # Bars
    for ($i = 0; $i -lt $n; $i++) {
        $groupX = $padL + [math]::Round($i * $groupW + $groupW * 0.10)
        $gv = $GoVals[$i]
        $pv = $PyVals[$i]

        if ($null -ne $gv) {
            $bh = [math]::Max(2, [math]::Round($chartH * [math]::Min([double]$gv, $MaxVal) / $MaxVal))
            $bx = $groupX; $by = $axisY - $bh
            [void]$svg.Append("<rect x='$bx' y='$by' width='$barW' height='$bh' fill='$goColor' rx='2'/>")
            [void]$svg.Append("<text x='$($bx+$barW/2)' y='$($by-3)' text-anchor='middle' font-size='9' fill='$goColor'>$gv</text>")
        }

        if ($null -ne $pv) {
            $bh = [math]::Max(2, [math]::Round($chartH * [math]::Min([double]$pv, $MaxVal) / $MaxVal))
            $bx = $groupX + $barW + $gap; $by = $axisY - $bh
            [void]$svg.Append("<rect x='$bx' y='$by' width='$barW' height='$bh' fill='$pyColor' rx='2'/>")
            [void]$svg.Append("<text x='$($bx+$barW/2)' y='$($by-3)' text-anchor='middle' font-size='9' fill='$pyColor'>$pv</text>")
        }

        $lx = $groupX + $barW + $gap / 2
        [void]$svg.Append("<text x='$lx' y='$($axisY+16)' text-anchor='middle' font-size='10' fill='$axisFill'>$($Labels[$i])</text>")
    }

    # Legend
    $lx = $padL; $ly = $svgH - 10
    [void]$svg.Append("<rect x='$lx' y='$($ly-9)' width='12' height='10' fill='$goColor' rx='2'/>")
    [void]$svg.Append("<text x='$($lx+16)' y='$ly' font-size='11' fill='$axisFill'>Go</text>")
    [void]$svg.Append("<rect x='$($lx+44)' y='$($ly-9)' width='12' height='10' fill='$pyColor' rx='2'/>")
    [void]$svg.Append("<text x='$($lx+60)' y='$ly' font-size='11' fill='$axisFill'>Python</text>")

    [void]$svg.Append("<text x='$($svgW-$padR)' y='$($padT+10)' text-anchor='end' font-size='10' fill='$axisFill'>$Unit</text>")
    [void]$svg.Append("</svg>")
    return $svg.ToString()
}

# ── HTML cell helpers ─────────────────────────────────────────────────────────
function Cell([object]$goVal, [object]$pyVal, [string]$unit = 'ms', [bool]$lowerBetter = $true) {
    $gd = if ($null -eq $goVal) { '<span class="na">N/A</span>' } else { "$goVal$unit" }
    $pd = if ($null -eq $pyVal) { '<span class="na">N/A</span>' } else { "$pyVal$unit" }
    $gClass = 'neutral'; $pClass = 'neutral'
    if ($null -ne $goVal -and $null -ne $pyVal) {
        $gv = [double]$goVal; $pv = [double]$pyVal; $tol = 0.05
        if ($lowerBetter) {
            if     ($gv -lt $pv * (1 - $tol)) { $gClass = 'win';  $pClass = 'lose' }
            elseif ($pv -lt $gv * (1 - $tol)) { $gClass = 'lose'; $pClass = 'win'  }
        } else {
            if     ($gv -gt $pv * (1 + $tol)) { $gClass = 'win';  $pClass = 'lose' }
            elseif ($pv -gt $gv * (1 + $tol)) { $gClass = 'lose'; $pClass = 'win'  }
        }
    }
    return "<td class='num $gClass'>$gd</td><td class='num $pClass'>$pd</td>"
}

function CellPct([object]$goVal, [object]$pyVal) { return Cell $goVal $pyVal '%' }

# ── Build charts for each transfer scenario ───────────────────────────────────
function Build-TransferCharts([hashtable]$go, [hashtable]$py) {
    $latChart = Build-BarChart `
        -Labels @('avg','p50','p90','p95','p99') `
        -GoVals @($go.tx_avg, $go.tx_med, $go.tx_p90, $go.tx_p95, $go.tx_p99) `
        -PyVals @($py.tx_avg, $py.tx_med, $py.tx_p90, $py.tx_p95, $py.tx_p99) `
        -Unit 'ms'

    $ttfbChart = Build-BarChart `
        -Labels @('wait avg','wait p95','conn avg','recv avg') `
        -GoVals @($go.wait_avg, $go.wait_p95, $go.conn_avg, $go.recv_avg) `
        -PyVals @($py.wait_avg, $py.wait_p95, $py.conn_avg, $py.recv_avg) `
        -Unit 'ms' -Height 180

    $errChart = Build-BarChart `
        -Labels @('tx err','auth err','bal err') `
        -GoVals @($go.tx_err, $go.auth_err, $go.bal_err) `
        -PyVals @($py.tx_err, $py.auth_err, $py.bal_err) `
        -Unit '%' -Height 180

    $rpsChart = Build-BarChart `
        -Labels @('req/s','tx/run') `
        -GoVals @($go.rps, $go.tx_ok) `
        -PyVals @($py.rps, $py.tx_ok) `
        -Unit 'rps/cnt' -Height 180 -HigherBetter $true

    return @{ latChart=$latChart; ttfbChart=$ttfbChart; errChart=$errChart; rpsChart=$rpsChart }
}

$chartsMulti  = Build-TransferCharts $goMulti  $pyMulti
$chartsSingle = Build-TransferCharts $goSingle $pySingle
$chartsFanOut = Build-TransferCharts $goFanOut $pyFanOut

# Journey charts — cycle latency percentiles and breakdown
$journeyLatChart = Build-BarChart `
    -Labels @('avg','p50','p90','p95','p99') `
    -GoVals @($goJourney.j_avg,$goJourney.j_med,$goJourney.j_p90,$goJourney.j_p95,$goJourney.j_p99) `
    -PyVals @($pyJourney.j_avg,$pyJourney.j_med,$pyJourney.j_p90,$pyJourney.j_p95,$pyJourney.j_p99) `
    -Unit 'ms'

$journeyBreakChart = Build-BarChart `
    -Labels @('tx p95','status p95','wait p95') `
    -GoVals @($goJourney.tx_p95,$goJourney.st_p95,$goJourney.tx_wait) `
    -PyVals @($pyJourney.tx_p95,$pyJourney.st_p95,$pyJourney.tx_wait) `
    -Unit 'ms' -Height 180

$journeyErrChart  = Build-BarChart `
    -Labels @('journey err','tx err','serial retry') `
    -GoVals @($goJourney.j_err,$goJourney.tx_err,$goJourney.serial) `
    -PyVals @($pyJourney.j_err,$pyJourney.tx_err,$null) `
    -Unit '%' -Height 180

$journeyTxChart   = Build-BarChart `
    -Labels @('cycles/run') `
    -GoVals @($goJourney.j_ok) `
    -PyVals @($pyJourney.j_ok) `
    -Unit 'cycles' -Height 180 -HigherBetter $true

$regLatChart  = Build-BarChart `
    -Labels @('avg','p50','p90','p95','p99','max') `
    -GoVals @($goReg.reg_avg,$goReg.reg_med,$goReg.reg_p90,$goReg.reg_p95,$goReg.reg_p99,$goReg.reg_max) `
    -PyVals @($pyReg.reg_avg,$pyReg.reg_med,$pyReg.reg_p90,$pyReg.reg_p95,$pyReg.reg_p99,$pyReg.reg_max) `
    -Unit 'ms' -Height 200

$regRpsChart  = Build-BarChart `
    -Labels @('reg/s') `
    -GoVals @($goReg.reg_rps) `
    -PyVals @($pyReg.reg_rps) `
    -Unit 'reg/s' -Height 180 -HigherBetter $true

# ── Executive summary helpers ─────────────────────────────────────────────────
# Count PASS / FAIL for a scenario's key SLOs
function Count-Slo([hashtable]$m, [string]$prefix) {
    $pass = 0; $fail = 0; $na = 0
    $keys = 'tx_p95','tx_p99','tx_err','auth_p95','bal_p95','wait_p95'
    foreach ($k in $keys) {
        $v = $m[$k]
        $thresh = switch ($k) {
            'tx_p95'   { 1500 }  'tx_p99'   { 3000 }
            'tx_err'   { 2    }  'auth_p95' { 500  }
            'bal_p95'  { 200  }  'wait_p95' { 1200 }
        }
        $lower = if ($k -eq 'rps') { $false } else { $true }
        $s = Slo $v $thresh $lower
        switch ($s) { 'pass' { $pass++ } 'fail' { $fail++ } default { $na++ } }
    }
    return @{ pass=$pass; fail=$fail; na=$na }
}

$sumMultiGo   = Count-Slo $goMulti  ''
$sumMultiPy   = Count-Slo $pyMulti  ''
$sumSingleGo  = Count-Slo $goSingle ''
$sumSinglePy  = Count-Slo $pySingle ''
$sumFanOutGo  = Count-Slo $goFanOut ''
$sumFanOutPy  = Count-Slo $pyFanOut ''

# Journey SLO counts — key thresholds: j_p95<3000, st_p95<200, j_err<2, tx_err<2
function Count-JourneySlo([hashtable]$m) {
    $pass = 0; $fail = 0; $na = 0
    $checks = @(
        @{ key='j_p95';  thresh=3000; lower=$true },
        @{ key='st_p95'; thresh=200;  lower=$true },
        @{ key='j_err';  thresh=2;    lower=$true },
        @{ key='tx_err'; thresh=2;    lower=$true }
    )
    foreach ($c in $checks) {
        $v = $m[$c.key]
        $s = Slo $v $c.thresh $c.lower
        switch ($s) { 'pass' { $pass++ } 'fail' { $fail++ } default { $na++ } }
    }
    return @{ pass=$pass; fail=$fail; na=$na }
}
$sumJourneyGo = Count-JourneySlo $goJourney
$sumJourneyPy = Count-JourneySlo $pyJourney

function ExecBadge([int]$fail) {
    if ($fail -eq 0) { return "<span class='badge pass'>ALL PASS</span>" }
    else             { return "<span class='badge fail'>$fail FAIL</span>" }
}

$runDate        = try { [datetime]::ParseExact($Timestamp,'yyyyMMdd-HHmmss',$null).ToString('yyyy-MM-dd HH:mm:ss') } catch { $Timestamp }
$hasRegData     = ($null -ne $goReg.reg_avg)    -or ($null -ne $pyReg.reg_avg)
$hasCapData     = ($null -ne $goCap.tx_p95)     -or ($null -ne $pyCap.tx_p95)
$hasJourneyData = ($null -ne $goJourney.j_avg)  -or ($null -ne $pyJourney.j_avg)

# ── Transfer metric table block (reused per scenario) ─────────────────────────
function Build-MetricTable([hashtable]$go, [hashtable]$py, [hashtable]$slos, [string]$serialLabel) {
    return @"
    <table>
      <thead>
        <tr>
          <th>Metric</th>
          <th class="stack-go">Go (NATS · SERIALIZABLE)</th>
          <th class="stack-py">Python (RabbitMQ · READ COMMITTED)</th>
        </tr>
      </thead>
      <tbody>
        <tr class="subhead"><td colspan="3">Transfer Latency (end-to-end RTT)</td></tr>
        <tr><td class="label">avg</td>$(Cell $go.tx_avg  $py.tx_avg)</tr>
        <tr><td class="label">p50 (median)</td>$(Cell $go.tx_med  $py.tx_med)</tr>
        <tr><td class="label">p90</td>$(Cell $go.tx_p90  $py.tx_p90)</tr>
        <tr><td class="label">p95 ✦</td>$(Cell $go.tx_p95  $py.tx_p95)</tr>
        <tr><td class="label">p99 ✦</td>$(Cell $go.tx_p99  $py.tx_p99)</tr>
        <tr><td class="label">max</td>$(Cell $go.tx_max  $py.tx_max)</tr>

        <tr class="subhead"><td colspan="3">HTTP Sub-Timings (transfer requests only)</td></tr>
        <tr><td class="label">TTFB avg — waiting</td>$(Cell $go.wait_avg $py.wait_avg)</tr>
        <tr><td class="label">TTFB p95 — waiting ✦</td>$(Cell $go.wait_p95 $py.wait_p95)</tr>
        <tr><td class="label">TCP connect avg</td>$(Cell $go.conn_avg $py.conn_avg)</tr>
        <tr><td class="label">Body receive avg</td>$(Cell $go.recv_avg $py.recv_avg)</tr>

        <tr class="subhead"><td colspan="3">Auth &amp; Balance Latency</td></tr>
        <tr><td class="label">Auth avg</td>$(Cell $go.auth_avg $py.auth_avg)</tr>
        <tr><td class="label">Auth p95 ✦</td>$(Cell $go.auth_p95 $py.auth_p95)</tr>
        <tr><td class="label">Balance avg</td>$(Cell $go.bal_avg $py.bal_avg)</tr>
        <tr><td class="label">Balance p95 ✦</td>$(Cell $go.bal_p95 $py.bal_p95)</tr>

        <tr class="subhead"><td colspan="3">Error Rates ✦ = SLO-tracked</td></tr>
        <tr><td class="label">Transfer errors ✦</td>$(CellPct $go.tx_err  $py.tx_err)</tr>
        <tr><td class="label">Auth errors</td>$(CellPct $go.auth_err $py.auth_err)</tr>
        <tr><td class="label">Balance errors</td>$(CellPct $go.bal_err $py.bal_err)</tr>
        <tr>
          <td class="label">Serialization retries ✦</td>
          <td class="num $(if ($null -ne $go.serial -and $go.serial -gt 5) { 'lose' } else { '' })">$(if ($null -ne $go.serial) { "$($go.serial)%" } else { '<span class="na">N/A</span>' })</td>
          <td class="num na">$serialLabel</td>
        </tr>
        <tr><td class="label">Check pass rate</td>$(Cell $go.checks $py.checks '%' $false)</tr>

        <tr class="subhead"><td colspan="3">Throughput &amp; Business Volume</td></tr>
        <tr><td class="label">HTTP req/s (all endpoints)</td>$(Cell $go.rps $py.rps 'rps' $false)</tr>
        <tr><td class="label">Successful transfers</td>$(Cell $go.tx_ok $py.tx_ok ' tx' $false)</tr>
        <tr><td class="label">Iteration duration p95</td>$(Cell $go.iter_p95 $py.iter_p95)</tr>
      </tbody>
    </table>

    <table class="slo-table" style="margin-top:14px">
      <thead>
        <tr><th>SLO</th><th>Threshold</th><th class="stack-go">Go</th><th class="stack-py">Python</th></tr>
      </thead>
      <tbody>
        <tr><td class="label">transfer_latency p95</td><td class="num">&lt;1500ms</td><td class="slo-col">$($slos.go_tx_p95)</td><td class="slo-col">$($slos.py_tx_p95)</td></tr>
        <tr><td class="label">transfer_latency p99</td><td class="num">&lt;3000ms</td><td class="slo-col">$($slos.go_tx_p99)</td><td class="slo-col">$($slos.py_tx_p99)</td></tr>
        <tr><td class="label">transfer_errors rate</td><td class="num">&lt;2%</td><td class="slo-col">$($slos.go_tx_err)</td><td class="slo-col">$($slos.py_tx_err)</td></tr>
        <tr><td class="label">serialization_retries</td><td class="num">&lt;5%</td><td class="slo-col">$($slos.go_serial)</td><td class="slo-col">$($slos.py_serial)</td></tr>
        <tr><td class="label">auth_latency p95</td><td class="num">&lt;500ms</td><td class="slo-col">$($slos.go_auth_p95)</td><td class="slo-col">$($slos.py_auth_p95)</td></tr>
        <tr><td class="label">balance_latency p95</td><td class="num">&lt;200ms</td><td class="slo-col">$($slos.go_bal_p95)</td><td class="slo-col">$($slos.py_bal_p95)</td></tr>
        <tr><td class="label">transfer_waiting p95 (TTFB)</td><td class="num">&lt;1200ms</td><td class="slo-col">$($slos.go_wait_p95)</td><td class="slo-col">$($slos.py_wait_p95)</td></tr>
        <tr><td class="label">checks pass rate</td><td class="num">&ge;99%</td><td class="slo-col">$($slos.go_checks)</td><td class="slo-col">$($slos.py_checks)</td></tr>
      </tbody>
    </table>
"@
}

# ── Assemble HTML ─────────────────────────────────────────────────────────────
$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Banking Demo — Benchmark Report $Timestamp</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  :root {
    --bg: #ffffff;
    --surface: #f7f8fa;
    --border: #e5e7eb;
    --text: #1f2328;
    --muted: #57606a;
    --go:  #3b82d4;
    --py:  #e8943a;
    --win-bg:  #d4edda; --win-fg:  #155724;
    --lose-bg: #f8d7da; --lose-fg: #721c24;
    --pass-bg: #d4edda; --pass-fg: #155724;
    --fail-bg: #f8d7da; --fail-fg: #721c24;
    --na-fg:   #6c757d;
  }
  body { background:var(--bg); color:var(--text); font-family:-apple-system,"Segoe UI",system-ui,sans-serif; font-size:14px; line-height:1.6; }
  .page { max-width:980px; margin:0 auto; padding:32px 24px 64px; }

  .header { border-bottom:2px solid var(--border); padding-bottom:20px; margin-bottom:28px; }
  .header h1 { font-size:22px; font-weight:700; letter-spacing:-.3px; margin-bottom:4px; }
  .header .sub { color:var(--muted); font-size:13px; }
  .meta { display:flex; gap:12px; flex-wrap:wrap; margin-top:12px; }
  .meta-chip { background:var(--surface); border:1px solid var(--border); border-radius:4px; padding:3px 10px; font-size:12px; color:var(--muted); }
  .meta-chip strong { color:var(--text); }

  .legend { display:flex; gap:18px; margin-bottom:28px; align-items:center; }
  .legend-item { display:flex; align-items:center; gap:7px; font-size:13px; font-weight:600; }
  .dot { width:14px; height:14px; border-radius:3px; flex-shrink:0; }
  .dot-go { background:var(--go); }
  .dot-py { background:var(--py); }

  /* Scenario tabs */
  .tab-bar { display:flex; gap:0; border-bottom:2px solid var(--border); margin-bottom:24px; flex-wrap:wrap; }
  .tab-btn { padding:8px 18px; font-size:13px; font-weight:600; color:var(--muted); cursor:pointer; border:none; background:none; border-bottom:3px solid transparent; margin-bottom:-2px; transition:color .15s,border-color .15s; }
  .tab-btn:hover  { color:var(--text); }
  .tab-btn.active { color:var(--text); border-bottom-color:var(--go); }
  .tab-content { display:none; }
  .tab-content.active { display:block; }

  /* Executive summary */
  .exec-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(200px,1fr)); gap:12px; margin-bottom:28px; }
  .exec-card { background:var(--surface); border:1px solid var(--border); border-radius:6px; padding:14px 16px; }
  .exec-card .title { font-size:11px; font-weight:700; text-transform:uppercase; letter-spacing:.5px; color:var(--muted); margin-bottom:6px; }
  .exec-card .vals  { display:flex; gap:10px; align-items:baseline; flex-wrap:wrap; }
  .exec-card .stack { font-size:12px; font-weight:600; color:var(--muted); margin-right:4px; }
  .exec-card .go-v  { color:var(--go); font-size:13px; font-weight:700; }
  .exec-card .py-v  { color:var(--py); font-size:13px; font-weight:700; }
  .exec-card .slo-row { margin-top:6px; font-size:12px; }

  .section { margin-bottom:36px; }
  .section-title { font-size:13px; font-weight:700; text-transform:uppercase; letter-spacing:.6px; color:var(--muted); border-bottom:1px solid var(--border); padding-bottom:6px; margin-bottom:14px; }

  .charts { display:grid; grid-template-columns:repeat(auto-fit,minmax(320px,1fr)); gap:16px; margin-bottom:20px; }
  .chart-card { background:var(--surface); border:1px solid var(--border); border-radius:6px; padding:12px 14px; }
  .chart-card h3 { font-size:11px; font-weight:700; color:var(--muted); margin-bottom:8px; text-transform:uppercase; letter-spacing:.5px; }
  .chart-card svg { max-width:100%; display:block; }

  table { width:100%; border-collapse:collapse; font-size:13px; }
  thead th { background:var(--surface); font-weight:700; font-size:11px; text-transform:uppercase; letter-spacing:.5px; color:var(--muted); padding:8px 10px; border:1px solid var(--border); text-align:left; }
  thead th.stack-go { color:var(--go); }
  thead th.stack-py { color:var(--py); }
  tbody tr:hover { background:#fafbfc; }
  td { padding:7px 10px; border:1px solid var(--border); font-size:13px; vertical-align:middle; }
  td.label   { color:var(--text); font-weight:500; }
  td.num     { font-variant-numeric:tabular-nums; text-align:right; }
  td.win     { background:var(--win-bg);  color:var(--win-fg);  font-weight:600; }
  td.lose    { background:var(--lose-bg); color:var(--lose-fg); }
  td.neutral { }
  td.slo-col { text-align:center; }
  tr.subhead td { background:var(--surface); font-weight:700; font-size:11px; text-transform:uppercase; letter-spacing:.5px; color:var(--muted); }
  .na { color:var(--na-fg); }

  .badge { display:inline-block; padding:2px 8px; border-radius:10px; font-size:11px; font-weight:700; letter-spacing:.4px; }
  .badge.pass { background:var(--pass-bg); color:var(--pass-fg); }
  .badge.fail { background:var(--fail-bg); color:var(--fail-fg); }
  .badge.na   { background:var(--surface); color:var(--na-fg); border:1px solid var(--border); }

  .footer { margin-top:52px; padding-top:16px; border-top:1px solid var(--border); text-align:center; font-size:11px; color:var(--muted); }
</style>
</head>
<body>
<div class="page">

  <!-- Header -->
  <div class="header">
    <h1>Banking Demo — Go vs Python Benchmark</h1>
    <div class="sub">Transfer-service load comparison &middot; k6 &middot; $runDate</div>
    <div class="meta">
      <span class="meta-chip">Peak VUs: <strong>$MaxVUs</strong></span>
      <span class="meta-chip">Ramp: <strong>$RampDuration</strong></span>
      <span class="meta-chip">Steady: <strong>$SteadyDuration</strong></span>
      <span class="meta-chip">Pool: <strong>$NumUsers users</strong></span>
      <span class="meta-chip">Reg rate: <strong>${RegRate}/s</strong></span>
      <span class="meta-chip">Traffic mix: <strong>20% auth / 60% transfer / 20% balance</strong></span>
      <span class="meta-chip">Think time: <strong>100–300ms</strong></span>
    </div>
  </div>

  <!-- Stack legend -->
  <div class="legend">
    <div class="legend-item"><div class="dot dot-go"></div>Go — NATS micro-RPC &middot; SERIALIZABLE tx &middot; Redis HSET balance</div>
    <div class="legend-item"><div class="dot dot-py"></div>Python — RabbitMQ AMQP &middot; READ COMMITTED &middot; Redis pub/sub</div>
  </div>

  <!-- Executive summary cards -->
  <div class="section">
    <div class="section-title">Executive Summary — SLO Pass/Fail by Scenario</div>
    <div class="exec-grid">
      <div class="exec-card">
        <div class="title">multi_user (true throughput)</div>
        <div class="slo-row"><span class="stack go-v">Go:</span> $(ExecBadge $sumMultiGo.fail)</div>
        <div class="slo-row"><span class="stack py-v">Python:</span> $(ExecBadge $sumMultiPy.fail)</div>
      </div>
      <div class="exec-card">
        <div class="title">single_pair (contention ceiling)</div>
        <div class="slo-row"><span class="stack go-v">Go:</span> $(ExecBadge $sumSingleGo.fail)</div>
        <div class="slo-row"><span class="stack py-v">Python:</span> $(ExecBadge $sumSinglePy.fail)</div>
      </div>
      <div class="exec-card">
        <div class="title">fan_out (hot-account stress)</div>
        <div class="slo-row"><span class="stack go-v">Go:</span> $(ExecBadge $sumFanOutGo.fail)</div>
        <div class="slo-row"><span class="stack py-v">Python:</span> $(ExecBadge $sumFanOutPy.fail)</div>
      </div>$(if ($hasJourneyData) { @"

      <div class="exec-card">
        <div class="title">transfer_journey (sequential cycle ★)</div>
        <div class="slo-row"><span class="stack go-v">Go:</span> $(ExecBadge $sumJourneyGo.fail)</div>
        <div class="slo-row"><span class="stack py-v">Python:</span> $(ExecBadge $sumJourneyPy.fail)</div>
      </div>
      <div class="exec-card">
        <div class="title">Journey p95 (full cycle)</div>
        <div class="vals">
          <span class="stack">Go:</span><span class="go-v">$(if ($null -ne $goJourney.j_p95) { "$($goJourney.j_p95)ms" } else { 'N/A' })</span>
          <span class="stack">Python:</span><span class="py-v">$(if ($null -ne $pyJourney.j_p95) { "$($pyJourney.j_p95)ms" } else { 'N/A' })</span>
        </div>
        <div class="vals" style="margin-top:6px">
          <span class="stack">cycles Go:</span><span class="go-v">$(if ($null -ne $goJourney.j_ok) { "$($goJourney.j_ok)" } else { 'N/A' })</span>
          <span class="stack">Python:</span><span class="py-v">$(if ($null -ne $pyJourney.j_ok) { "$($pyJourney.j_ok)" } else { 'N/A' })</span>
        </div>
      </div>
"@ } else { '' })
      <div class="exec-card">
        <div class="title">Key throughput (multi_user)</div>
        <div class="vals">
          <span class="stack">Go:</span><span class="go-v">$(if ($null -ne $goMulti.rps) { "$($goMulti.rps) rps" } else { 'N/A' })</span>
          <span class="stack">Python:</span><span class="py-v">$(if ($null -ne $pyMulti.rps) { "$($pyMulti.rps) rps" } else { 'N/A' })</span>
        </div>
        <div class="vals" style="margin-top:6px">
          <span class="stack">tx/run Go:</span><span class="go-v">$(if ($null -ne $goMulti.tx_ok) { "$($goMulti.tx_ok)" } else { 'N/A' })</span>
          <span class="stack">Python:</span><span class="py-v">$(if ($null -ne $pyMulti.tx_ok) { "$($pyMulti.tx_ok)" } else { 'N/A' })</span>
        </div>
      </div>
    </div>
  </div>

  <!-- Scenario tabs -->
  <div class="tab-bar">
    <button class="tab-btn active" id="tab-multi"   >multi_user</button>
    <button class="tab-btn"        id="tab-single"  >single_pair</button>
    <button class="tab-btn"        id="tab-fanout"  >fan_out</button>$(if ($hasJourneyData) { "
    <button class=`"tab-btn`"        id=`"tab-journey`" >transfer_journey ★</button>" })$(if ($hasRegData) { "
    <button class=`"tab-btn`"        id=`"tab-reg`"    >reg_throughput</button>" })
    <button class="tab-btn"        id="tab-arch"   >Architecture</button>
  </div>

  <!-- ── TAB: multi_user ────────────────────────────────────────────────────── -->
  <div class="tab-content active" id="pane-multi">
    <div class="section">
      <div class="section-title">multi_user — True App Throughput</div>
      <p style="font-size:13px;color:var(--muted);margin-bottom:14px">
        N unique sender/receiver pairs — lock contention approaches zero.
        Cleanly measures framework + message bus + Redis pipeline overhead.
        Primary benchmark signal for overall stack performance.
      </p>
      <div class="charts">
        <div class="chart-card"><h3>Transfer latency percentiles (ms)</h3>$($chartsMulti.latChart)</div>
        <div class="chart-card"><h3>HTTP sub-timings (ms)</h3>$($chartsMulti.ttfbChart)</div>
        <div class="chart-card"><h3>Error rates (%)</h3>$($chartsMulti.errChart)</div>
        <div class="chart-card"><h3>Throughput (req/s &amp; tx count)</h3>$($chartsMulti.rpsChart)</div>
      </div>
      $(Build-MetricTable $goMulti $pyMulti $sloMulti 'n/a (READ COMMITTED)')
    </div>
  </div>

  <!-- ── TAB: single_pair ───────────────────────────────────────────────────── -->
  <div class="tab-content" id="pane-single">
    <div class="section">
      <div class="section-title">single_pair — Contention Ceiling</div>
      <p style="font-size:13px;color:var(--muted);margin-bottom:14px">
        All VUs hammer a single alice↔bob pair bidirectionally. Measures the
        DB row-lock ceiling under SERIALIZABLE. Low throughput is expected —
        this reveals where serialization retries dominate cost.
      </p>
      <div class="charts">
        <div class="chart-card"><h3>Transfer latency percentiles (ms)</h3>$($chartsSingle.latChart)</div>
        <div class="chart-card"><h3>HTTP sub-timings (ms)</h3>$($chartsSingle.ttfbChart)</div>
        <div class="chart-card"><h3>Error rates (%)</h3>$($chartsSingle.errChart)</div>
        <div class="chart-card"><h3>Throughput (req/s &amp; tx count)</h3>$($chartsSingle.rpsChart)</div>
      </div>
      $(Build-MetricTable $goSingle $pySingle $sloSingle 'n/a (READ COMMITTED)')
    </div>
  </div>

  <!-- ── TAB: fan_out ───────────────────────────────────────────────────────── -->
  <div class="tab-content" id="pane-fanout">
    <div class="section">
      <div class="section-title">fan_out — Hot-Account Stress</div>
      <p style="font-size:13px;color:var(--muted);margin-bottom:14px">
        N senders → one fixed receiver (perf_user_0). Simulates a merchant
        account receiving payments from many customers simultaneously.
        Shows how SERIALIZABLE behaves under maximum write contention on one row.
      </p>
      <div class="charts">
        <div class="chart-card"><h3>Transfer latency percentiles (ms)</h3>$($chartsFanOut.latChart)</div>
        <div class="chart-card"><h3>HTTP sub-timings (ms)</h3>$($chartsFanOut.ttfbChart)</div>
        <div class="chart-card"><h3>Error rates (%)</h3>$($chartsFanOut.errChart)</div>
        <div class="chart-card"><h3>Throughput (req/s &amp; tx count)</h3>$($chartsFanOut.rpsChart)</div>
      </div>
      $(Build-MetricTable $goFanOut $pyFanOut $sloFanOut 'n/a (READ COMMITTED)')
    </div>
  </div>

  <!-- ── TAB: transfer_journey (conditional) ──────────────────────────────── -->$(if ($hasJourneyData) { @"

  <div class="tab-content" id="pane-journey">
    <div class="section">
      <div class="section-title">transfer_journey — Sequential User Journey ★</div>
      <p style="font-size:13px;color:var(--muted);margin-bottom:14px">
        Each VU models one real user: <strong>POST /transfer → wait → GET /balance → think time → repeat</strong>.
        No randomness — every iteration executes both steps in sequence. A VU never has two
        requests in-flight simultaneously. <code>journey_latency</code> is the full wall-time
        (transfer + balance combined, think time excluded); <code>journey_status_latency</code>
        isolates the balance check to verify Redis caching.
      </p>
      <div class="charts">
        <div class="chart-card"><h3>Journey cycle latency percentiles (ms)</h3>$journeyLatChart</div>
        <div class="chart-card"><h3>Step breakdown — transfer vs status check (ms)</h3>$journeyBreakChart</div>
        <div class="chart-card"><h3>Error rates (%)</h3>$journeyErrChart</div>
        <div class="chart-card"><h3>Completed cycles (count)</h3>$journeyTxChart</div>
      </div>
      <table>
        <thead>
          <tr>
            <th>Metric</th>
            <th class="stack-go">Go (NATS · SERIALIZABLE)</th>
            <th class="stack-py">Python (RabbitMQ · READ COMMITTED)</th>
          </tr>
        </thead>
        <tbody>
          <tr class="subhead"><td colspan="3">Full Cycle Latency — POST /transfer + GET /balance (wall-time, think time excluded)</td></tr>
          <tr><td class="label">avg</td>$(Cell $goJourney.j_avg $pyJourney.j_avg)</tr>
          <tr><td class="label">p50 (median)</td>$(Cell $goJourney.j_med $pyJourney.j_med)</tr>
          <tr><td class="label">p90</td>$(Cell $goJourney.j_p90 $pyJourney.j_p90)</tr>
          <tr><td class="label">p95 ✦</td>$(Cell $goJourney.j_p95 $pyJourney.j_p95)</tr>
          <tr><td class="label">p99 ✦</td>$(Cell $goJourney.j_p99 $pyJourney.j_p99)</tr>
          <tr><td class="label">max</td>$(Cell $goJourney.j_max $pyJourney.j_max)</tr>

          <tr class="subhead"><td colspan="3">Step Breakdown</td></tr>
          <tr><td class="label">Transfer latency p95 (step 1)</td>$(Cell $goJourney.tx_p95 $pyJourney.tx_p95)</tr>
          <tr><td class="label">Status check p95 — GET /balance (step 2)</td>$(Cell $goJourney.st_p95 $pyJourney.st_p95)</tr>
          <tr><td class="label">Status check avg</td>$(Cell $goJourney.st_avg $pyJourney.st_avg)</tr>
          <tr><td class="label">Transfer TTFB p95 (waiting)</td>$(Cell $goJourney.tx_wait $pyJourney.tx_wait)</tr>
          <tr><td class="label">TCP connect p99</td>$(Cell $goJourney.tx_conn $pyJourney.tx_conn)</tr>

          <tr class="subhead"><td colspan="3">Error Rates &amp; Quality</td></tr>
          <tr><td class="label">Journey error rate ✦</td>$(CellPct $goJourney.j_err $pyJourney.j_err)</tr>
          <tr><td class="label">Transfer error rate ✦</td>$(CellPct $goJourney.tx_err $pyJourney.tx_err)</tr>
          <tr>
            <td class="label">Serialization retries ✦</td>
            <td class="num $(if ($null -ne $goJourney.serial -and [double]$goJourney.serial -gt 5) { 'lose' } else { '' })">$(if ($null -ne $goJourney.serial) { "$($goJourney.serial)%" } else { '<span class="na">N/A</span>' })</td>
            <td class="num na">n/a (READ COMMITTED)</td>
          </tr>
          <tr><td class="label">Check pass rate</td>$(Cell $goJourney.checks $pyJourney.checks '%' $false)</tr>

          <tr class="subhead"><td colspan="3">Business Volume</td></tr>
          <tr><td class="label">Completed cycles</td>$(Cell $goJourney.j_ok $pyJourney.j_ok ' cycles' $false)</tr>
        </tbody>
      </table>
      <table class="slo-table" style="margin-top:14px">
        <thead>
          <tr><th>SLO</th><th>Threshold</th><th class="stack-go">Go</th><th class="stack-py">Python</th></tr>
        </thead>
        <tbody>
          <tr><td class="label">journey_latency p95</td><td class="num">&lt;3000ms</td>
              <td class="slo-col">$(Badge (Slo $goJourney.j_p95 3000))</td>
              <td class="slo-col">$(Badge (Slo $pyJourney.j_p95 3000))</td></tr>
          <tr><td class="label">journey_latency p99</td><td class="num">&lt;5000ms</td>
              <td class="slo-col">$(Badge (Slo $goJourney.j_p99 5000))</td>
              <td class="slo-col">$(Badge (Slo $pyJourney.j_p99 5000))</td></tr>
          <tr><td class="label">journey_status_latency p95</td><td class="num">&lt;200ms</td>
              <td class="slo-col">$(Badge (Slo $goJourney.st_p95 200))</td>
              <td class="slo-col">$(Badge (Slo $pyJourney.st_p95 200))</td></tr>
          <tr><td class="label">journey_errors rate</td><td class="num">&lt;2%</td>
              <td class="slo-col">$(Badge (Slo $goJourney.j_err 2))</td>
              <td class="slo-col">$(Badge (Slo $pyJourney.j_err 2))</td></tr>
          <tr><td class="label">transfer_errors rate</td><td class="num">&lt;2%</td>
              <td class="slo-col">$(Badge (Slo $goJourney.tx_err 2))</td>
              <td class="slo-col">$(Badge (Slo $pyJourney.tx_err 2))</td></tr>
          <tr><td class="label">checks pass rate</td><td class="num">&ge;99%</td>
              <td class="slo-col">$(Badge (Slo $goJourney.checks 99 $false))</td>
              <td class="slo-col">$(Badge (Slo $pyJourney.checks 99 $false))</td></tr>
        </tbody>
      </table>
    </div>
  </div>
"@ } else { '' })

  <!-- ── TAB: reg_throughput (conditional) ─────────────────────────────────── -->$(if ($hasRegData) { @"

  <div class="tab-content" id="pane-reg">
    <div class="section">
      <div class="section-title">reg_throughput — Registration Benchmark</div>
      <p style="font-size:13px;color:var(--muted);margin-bottom:14px">
        Open arrival-rate: fires $RegRate registrations/s. Each iteration registers a
        brand-new user (bcrypt hash + DB INSERT). No lock contention — pure
        single-operation throughput ceiling for the auth stack.
      </p>
      <div class="charts">
        <div class="chart-card"><h3>Registration latency percentiles (ms)</h3>$regLatChart</div>
        <div class="chart-card"><h3>Registration rate (reg/s)</h3>$regRpsChart</div>
      </div>
      <table>
        <thead>
          <tr><th>Metric</th><th class="stack-go">Go</th><th class="stack-py">Python</th></tr>
        </thead>
        <tbody>
          <tr class="subhead"><td colspan="3">Registration Latency (bcrypt + INSERT)</td></tr>
          <tr><td class="label">avg</td>$(Cell $goReg.reg_avg $pyReg.reg_avg)</tr>
          <tr><td class="label">p50 (median)</td>$(Cell $goReg.reg_med $pyReg.reg_med)</tr>
          <tr><td class="label">p90</td>$(Cell $goReg.reg_p90 $pyReg.reg_p90)</tr>
          <tr><td class="label">p95 ✦</td>$(Cell $goReg.reg_p95 $pyReg.reg_p95)</tr>
          <tr><td class="label">p99 ✦</td>$(Cell $goReg.reg_p99 $pyReg.reg_p99)</tr>
          <tr><td class="label">max</td>$(Cell $goReg.reg_max $pyReg.reg_max)</tr>
          <tr class="subhead"><td colspan="3">Throughput &amp; Quality</td></tr>
          <tr><td class="label">registrations/s</td>$(Cell $goReg.reg_rps $pyReg.reg_rps 'reg/s' $false)</tr>
          <tr><td class="label">total registered</td>$(Cell $goReg.reg_ok $pyReg.reg_ok ' users' $false)</tr>
          <tr><td class="label">error rate ✦</td>$(CellPct $goReg.reg_err $pyReg.reg_err)</tr>
          <tr><td class="label">check pass rate</td>$(Cell $goReg.checks $pyReg.checks '%' $false)</tr>
        </tbody>
      </table>
      <table class="slo-table" style="margin-top:14px">
        <thead>
          <tr><th>SLO</th><th>Threshold</th><th class="stack-go">Go</th><th class="stack-py">Python</th></tr>
        </thead>
        <tbody>
          <tr><td class="label">reg_latency p95</td><td class="num">&lt;2000ms</td>
              <td class="slo-col">$(Badge (Slo $goReg.reg_p95 2000))</td>
              <td class="slo-col">$(Badge (Slo $pyReg.reg_p95 2000))</td></tr>
          <tr><td class="label">reg_latency p99</td><td class="num">&lt;4000ms</td>
              <td class="slo-col">$(Badge (Slo $goReg.reg_p99 4000))</td>
              <td class="slo-col">$(Badge (Slo $pyReg.reg_p99 4000))</td></tr>
          <tr><td class="label">reg_errors rate</td><td class="num">&lt;1%</td>
              <td class="slo-col">$(Badge (Slo $goReg.reg_err 1))</td>
              <td class="slo-col">$(Badge (Slo $pyReg.reg_err 1))</td></tr>
          <tr><td class="label">checks pass rate</td><td class="num">&ge;99%</td>
              <td class="slo-col">$(Badge (Slo $goReg.checks 99 $false))</td>
              <td class="slo-col">$(Badge (Slo $pyReg.checks 99 $false))</td></tr>
        </tbody>
      </table>
    </div>
  </div>
"@ } else { '' })

  <!-- ── TAB: Architecture ──────────────────────────────────────────────────── -->
  <div class="tab-content" id="pane-arch">
    <div class="section">
      <div class="section-title">Architecture Under Test</div>
      <table>
        <thead>
          <tr><th>Layer</th><th class="stack-go">Go (port 8000)</th><th class="stack-py">Python (port 9000)</th></tr>
        </thead>
        <tbody>
          <tr><td class="label">Gateway</td><td>Kong</td><td>Kong</td></tr>
          <tr><td class="label">Producer</td><td>Go chi</td><td>Python FastAPI</td></tr>
          <tr><td class="label">Message bus</td><td>NATS micro-RPC</td><td>RabbitMQ AMQP (aio_pika)</td></tr>
          <tr><td class="label">DB isolation</td><td>SERIALIZABLE</td><td>READ COMMITTED</td></tr>
          <tr><td class="label">Balance model</td><td>Redis HSET write-through</td><td>Redis pub/sub notify only</td></tr>
          <tr><td class="label">Session store</td><td>Redis</td><td>Redis</td></tr>
          <tr><td class="label">Auth method</td><td>X-Session header</td><td>X-Session header</td></tr>
        </tbody>
      </table>
    </div>
    <div class="section">
      <div class="section-title">SLO Definitions</div>
      <table>
        <thead>
          <tr><th>Metric</th><th>Threshold</th><th>Rationale</th></tr>
        </thead>
        <tbody>
          <tr><td class="label">transfer_latency p95</td><td>&lt;1500ms</td><td>REST POST/write baseline — includes DB lock wait</td></tr>
          <tr><td class="label">transfer_latency p99</td><td>&lt;3000ms</td><td>Tail latency — covers 99% of real users</td></tr>
          <tr><td class="label">transfer_errors</td><td>&lt;2%</td><td>Revenue-critical path — near-zero tolerance</td></tr>
          <tr><td class="label">serialization_retries</td><td>&lt;5%</td><td>Go SERIALIZABLE: &gt;5% = DB contention ceiling hit</td></tr>
          <tr><td class="label">auth_latency p95</td><td>&lt;500ms</td><td>Auth/login — stricter, security-sensitive path</td></tr>
          <tr><td class="label">balance_latency p95</td><td>&lt;200ms</td><td>Balance read from Redis cache — should be fast</td></tr>
          <tr><td class="label">transfer_waiting p95</td><td>&lt;1200ms</td><td>TTFB = server-side DB/queue backlog</td></tr>
          <tr><td class="label">checks pass rate</td><td>&ge;99%</td><td>Inline assertion sanity: 99% of all checks must pass</td></tr>
          <tr><td class="label">reg_latency p95</td><td>&lt;2000ms</td><td>bcrypt + INSERT — inherently slow, wider budget</td></tr>
        </tbody>
      </table>
    </div>
    <div class="section">
      <div class="section-title">Tuning Reference</div>
      <table>
        <thead>
          <tr><th>Signal</th><th>Probable cause</th><th>Action</th></tr>
        </thead>
        <tbody>
          <tr><td class="label">transfer_waiting p95 spikes</td><td>DB lock queuing (SERIALIZABLE)</td><td>Raise postgres CPU cap, reduce VUs, check index usage</td></tr>
          <tr><td class="label">transfer_connecting rising</td><td>Connection pool exhaustion</td><td>Increase pool size, check for connection leaks</td></tr>
          <tr><td class="label">serialization_retries &gt;5%</td><td>SERIALIZABLE conflict ceiling</td><td>Go-specific: reduce concurrency, or check for missing index</td></tr>
          <tr><td class="label">auth/balance errors rising</td><td>Redis backpressure or session expiry</td><td>Check Redis memory, connection pool, session TTL</td></tr>
          <tr><td class="label">Python p95 high at &gt;20 VUs</td><td>asyncio loop + sync SQLAlchemy pool</td><td>Expected: Python GIL limits concurrency under heavy load</td></tr>
        </tbody>
      </table>
    </div>
  </div>

  <!-- Tab switching (inline, no event handler stripping) -->
  <div id="tab-script-anchor"></div>

  <div class="footer">
    Report generated $runDate &middot; k6 load test &middot; banking-demo benchmark<br>
    <small style="opacity:.6">Made with IBM Bob</small>
  </div>

</div>
<script>
(function(){
  var tabs  = document.querySelectorAll('.tab-btn');
  var panes = document.querySelectorAll('.tab-content');
  var map = {
    'tab-multi':'pane-multi','tab-single':'pane-single',
    'tab-fanout':'pane-fanout','tab-journey':'pane-journey',
    'tab-reg':'pane-reg','tab-arch':'pane-arch'
  };
  tabs.forEach(function(btn){
    btn.addEventListener('click',function(){
      tabs.forEach(function(b){ b.classList.remove('active'); });
      panes.forEach(function(p){ p.classList.remove('active'); });
      btn.classList.add('active');
      var pane = document.getElementById(map[btn.id]);
      if(pane) pane.classList.add('active');
    });
  });
})();
</script>
</body>
</html>
"@

# ── Write HTML ────────────────────────────────────────────────────────────────
$outFile = "$OutputDir\report-${Timestamp}.html"
[System.IO.File]::WriteAllText($outFile, $html, [System.Text.Encoding]::UTF8)
Write-Host "  ✅ HTML report → $outFile" -ForegroundColor Green
Write-Host "     Open in browser: start `"$outFile`"" -ForegroundColor Gray

# ── Write Markdown summary ────────────────────────────────────────────────────
# One tight table per scenario — only the metrics that matter for a quick
# Go vs Python verdict. N/A cells are shown explicitly so missing data is
# visible rather than silently omitted.
function Md([object]$v, [string]$unit = 'ms') {
    if ($null -eq $v) { return 'N/A' }
    return "$v$unit"
}
function MdPct([object]$v) {
    if ($null -eq $v) { return 'N/A' }
    return "$v%"
}
# Winner marker: ← appended to the better value (lower is better by default)
function MdRow([string]$label, [object]$go, [object]$py,
               [string]$unit = 'ms', [bool]$lowerBetter = $true) {
    $gs = Md $go $unit
    $ps = Md $py $unit
    $mark = ''
    if ($null -ne $go -and $null -ne $py) {
        $gn = [double]$go; $pn = [double]$py; $tol = 0.05
        if ($lowerBetter) {
            if ($gn -lt $pn * (1 - $tol)) { $gs = "**$gs** ←" }
            elseif ($pn -lt $gn * (1 - $tol)) { $ps = "**$ps** ←" }
        } else {
            if ($gn -gt $pn * (1 + $tol)) { $gs = "**$gs** ←" }
            elseif ($pn -gt $gn * (1 + $tol)) { $ps = "**$ps** ←" }
        }
    }
    return "| $label | $gs | $ps |"
}
function MdPctRow([string]$label, [object]$go, [object]$py, [bool]$lowerBetter = $true) {
    return MdRow $label $go $py '%' $lowerBetter
}

$mdLines = [System.Collections.Generic.List[string]]::new()
$mdLines.Add("# Go vs Python — Benchmark Critical Metrics")
$mdLines.Add("")
$mdLines.Add("> Run: ``$Timestamp``  |  VUs: ``$MaxVUs``  |  Ramp: ``$RampDuration``  |  Steady: ``$SteadyDuration``  |  Pool: ``$NumUsers users``")
$mdLines.Add("")
$mdLines.Add("> **Bold + ←** = winner (>5% better). Lower is better unless noted.")
$mdLines.Add("")

# ── transfer_journey (sequential cycle — primary signal) ─────────────────────
if ($hasJourneyData) {
    $mdLines.Add("## transfer_journey — Sequential Cycle (POST /transfer → GET /balance)")
    $mdLines.Add("")
    $mdLines.Add("Each VU sends one transfer, waits for the full response, then reads balance to confirm.")
    $mdLines.Add("`journey_latency` = full cycle wall-time (think time excluded).")
    $mdLines.Add("")
    $mdLines.Add("| Metric | Go | Python |")
    $mdLines.Add("|--------|-------|--------|")
    $mdLines.Add((MdRow  "Journey latency p50 (median cycle)"     $goJourney.j_med   $pyJourney.j_med))
    $mdLines.Add((MdRow  "Journey latency p95 ✦ SLO <3000ms"     $goJourney.j_p95   $pyJourney.j_p95))
    $mdLines.Add((MdRow  "Journey latency p99"                    $goJourney.j_p99   $pyJourney.j_p99))
    $mdLines.Add((MdRow  "Transfer step p95 (POST /transfer)"     $goJourney.tx_p95  $pyJourney.tx_p95))
    $mdLines.Add((MdRow  "Status check p95 (GET /balance) ✦"     $goJourney.st_p95  $pyJourney.st_p95))
    $mdLines.Add((MdRow  "Transfer TTFB p95 (DB/queue wait)"      $goJourney.tx_wait $pyJourney.tx_wait))
    $mdLines.Add((MdPctRow "Journey error rate ✦ SLO <2%"         $goJourney.j_err   $pyJourney.j_err))
    $mdLines.Add((MdPctRow "Serialization retries (Go only)"      $goJourney.serial  $null))
    $mdLines.Add((MdRow  "Cycles completed"                       $goJourney.j_ok    $pyJourney.j_ok '' $false))
    $mdLines.Add("")
}

# ── multi_user (true throughput) ──────────────────────────────────────────────
$mdLines.Add("## multi_user — True App Throughput (20% auth / 60% transfer / 20% balance)")
$mdLines.Add("")
$mdLines.Add("N unique sender/receiver pairs — zero lock contention.")
$mdLines.Add("Primary signal for framework + message bus overhead.")
$mdLines.Add("")
$mdLines.Add("| Metric | Go | Python |")
$mdLines.Add("|--------|-------|--------|")
$mdLines.Add((MdRow  "Transfer latency p50"                      $goMulti.tx_med  $pyMulti.tx_med))
$mdLines.Add((MdRow  "Transfer latency p95 ✦ SLO <1500ms"       $goMulti.tx_p95  $pyMulti.tx_p95))
$mdLines.Add((MdRow  "Transfer latency p99 ✦ SLO <3000ms"       $goMulti.tx_p99  $pyMulti.tx_p99))
$mdLines.Add((MdRow  "Transfer TTFB p95 (DB/queue wait)"         $goMulti.wait_p95 $pyMulti.wait_p95))
$mdLines.Add((MdRow  "Auth latency p95 ✦ SLO <500ms"            $goMulti.auth_p95 $pyMulti.auth_p95))
$mdLines.Add((MdRow  "Balance latency p95 ✦ SLO <200ms"         $goMulti.bal_p95  $pyMulti.bal_p95))
$mdLines.Add((MdPctRow "Transfer error rate ✦ SLO <2%"           $goMulti.tx_err  $pyMulti.tx_err))
$mdLines.Add((MdPctRow "Serialization retries (Go only)"         $goMulti.serial  $null))
$mdLines.Add((MdRow  "HTTP req/s (all endpoints)"                $goMulti.rps     $pyMulti.rps 'rps' $false))
$mdLines.Add((MdRow  "Successful transfers"                      $goMulti.tx_ok   $pyMulti.tx_ok ' tx' $false))
$mdLines.Add("")

# ── single_pair (contention ceiling) ─────────────────────────────────────────
$mdLines.Add("## single_pair — Contention Ceiling (all VUs → one alice↔bob pair)")
$mdLines.Add("")
$mdLines.Add("| Metric | Go | Python |")
$mdLines.Add("|--------|-------|--------|")
$mdLines.Add((MdRow  "Transfer latency p50"                      $goSingle.tx_med  $pySingle.tx_med))
$mdLines.Add((MdRow  "Transfer latency p95"                      $goSingle.tx_p95  $pySingle.tx_p95))
$mdLines.Add((MdPctRow "Transfer error rate"                     $goSingle.tx_err  $pySingle.tx_err))
$mdLines.Add((MdPctRow "Serialization retries (Go only)"         $goSingle.serial  $null))
$mdLines.Add((MdRow  "HTTP req/s"                                $goSingle.rps     $pySingle.rps 'rps' $false))
$mdLines.Add("")

# ── fan_out (hot-account stress) ──────────────────────────────────────────────
$mdLines.Add("## fan_out — Hot-Account Stress (N senders → 1 receiver)")
$mdLines.Add("")
$mdLines.Add("| Metric | Go | Python |")
$mdLines.Add("|--------|-------|--------|")
$mdLines.Add((MdRow  "Transfer latency p50"                      $goFanOut.tx_med  $pyFanOut.tx_med))
$mdLines.Add((MdRow  "Transfer latency p95"                      $goFanOut.tx_p95  $pyFanOut.tx_p95))
$mdLines.Add((MdPctRow "Transfer error rate"                     $goFanOut.tx_err  $pyFanOut.tx_err))
$mdLines.Add((MdPctRow "Serialization retries (Go only)"         $goFanOut.serial  $null))
$mdLines.Add((MdRow  "HTTP req/s"                                $goFanOut.rps     $pyFanOut.rps 'rps' $false))
$mdLines.Add("")

# ── reg_throughput (registration benchmark) ───────────────────────────────────
if ($hasRegData) {
    $mdLines.Add("## reg_throughput — Registration (bcrypt + INSERT)")
    $mdLines.Add("")
    $mdLines.Add("| Metric | Go | Python |")
    $mdLines.Add("|--------|-------|--------|")
    $mdLines.Add((MdRow    "Reg latency p95 ✦ SLO <2000ms"       $goReg.reg_p95  $pyReg.reg_p95))
    $mdLines.Add((MdRow    "Reg latency p99 ✦ SLO <4000ms"       $goReg.reg_p99  $pyReg.reg_p99))
    $mdLines.Add((MdPctRow "Reg error rate ✦ SLO <1%"            $goReg.reg_err  $pyReg.reg_err))
    $mdLines.Add((MdRow    "Registrations/s"                      $goReg.reg_rps  $pyReg.reg_rps 'reg/s' $false))
    $mdLines.Add("")
}

# ── SLO verdict ───────────────────────────────────────────────────────────────
$mdLines.Add("## SLO Verdict")
$mdLines.Add("")
$mdLines.Add("| Scenario | Go failures | Python failures |")
$mdLines.Add("|----------|------------|-----------------|")
$mdLines.Add("| multi_user | $($sumMultiGo.fail) / 6 | $($sumMultiPy.fail) / 6 |")
$mdLines.Add("| single_pair | $($sumSingleGo.fail) / 6 | $($sumSinglePy.fail) / 6 |")
$mdLines.Add("| fan_out | $($sumFanOutGo.fail) / 6 | $($sumFanOutPy.fail) / 6 |")
if ($hasJourneyData) {
    $mdLines.Add("| transfer_journey | $($sumJourneyGo.fail) / 4 | $($sumJourneyPy.fail) / 4 |")
}
$mdLines.Add("")
$mdLines.Add("---")
$mdLines.Add("*Generated by `generate-report.ps1` from k6 JSON summaries.*")

$mdFile = "$OutputDir\summary-${Timestamp}.md"
[System.IO.File]::WriteAllText($mdFile, ($mdLines -join "`n"), [System.Text.Encoding]::UTF8)
Write-Host "  ✅ Markdown summary → $mdFile" -ForegroundColor Green
