# challenge\tools\analyze.ps1 - 30-day-window outcome distribution + Monte Carlo + engine invariants.
# Reads bt_<Tag>_daily.json / bt_<Tag>_trades.json produced by challenge\tools\backtest.ps1.
param(
    [Parameter(Mandatory=$true)][string]$Tag,
    [string]$DataDir = '',
    [int]$WindowDays = 30,
    [double]$RuinLevel = 0.5,     # challenge failed when multiple <= this
    [int]$McPaths = 10000,
    [int]$BlockLen = 5,
    [int]$Seed = 42,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web.Extensions
$JS = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$JS.MaxJsonLength = [int]::MaxValue

$root = Split-Path $PSScriptRoot -Parent
if (-not $DataDir) { $DataDir = Join-Path $root 'data' }

$dailies = $JS.DeserializeObject([System.IO.File]::ReadAllText((Join-Path $DataDir "bt_${Tag}_daily.json")))
$trades  = $JS.DeserializeObject([System.IO.File]::ReadAllText((Join-Path $DataDir "bt_${Tag}_trades.json")))

$nD = $dailies.Count
if ($nD -lt ($WindowDays + 10)) { Write-Host "Not enough daily rows ($nD) for window analysis"; exit 1 }

# daily returns
$nR = $nD - 1
$rets = New-Object 'double[]' $nR
$tradedFlags = New-Object 'int[]' $nD
for ($i = 0; $i -lt $nD; $i++) { $tradedFlags[$i] = [int]$dailies[$i]['traded'] }
for ($i = 1; $i -lt $nD; $i++) {
    $prev = [double]$dailies[$i-1]['eq']; $curEq = [double]$dailies[$i]['eq']
    if ($prev -gt 0) { $rets[$i-1] = $curEq / $prev - 1 } else { $rets[$i-1] = 0 }
}

function Get-Pctile([double[]]$sorted, [double]$q) {
    $n = $sorted.Length
    if ($n -eq 0) { return [double]::NaN }
    $idx = [int][math]::Floor($q * ($n - 1))
    return $sorted[$idx]
}

function Window-Stats([double[]]$mults, [bool[]]$ruined, [string]$label) {
    $n = $mults.Length
    $sorted = [double[]]$mults.Clone(); [Array]::Sort($sorted)
    $nRuin = 0; $ge2 = 0; $ge5 = 0; $ge10 = 0; $ge17 = 0; $geB = 0; $sum = 0.0
    for ($i = 0; $i -lt $n; $i++) {
        if ($ruined[$i]) { $nRuin++ }
        $m = $mults[$i]; $sum += $m
        if ($m -ge 2) { $ge2++ }; if ($m -ge 5) { $ge5++ }; if ($m -ge 10) { $ge10++ }
        if ($m -ge 17) { $ge17++ }; if ($m -ge 1) { $geB++ }
    }
    return @{
        label = $label; windows = $n
        median = [math]::Round((Get-Pctile $sorted 0.5), 3)
        mean = [math]::Round(($sum / $n), 3)
        p10 = [math]::Round((Get-Pctile $sorted 0.10), 3)
        p90 = [math]::Round((Get-Pctile $sorted 0.90), 3)
        best = [math]::Round($sorted[$n-1], 3)
        worst = [math]::Round($sorted[0], 3)
        pctGain = [math]::Round(100.0 * $geB / $n, 1)
        pct2x = [math]::Round(100.0 * $ge2 / $n, 2)
        pct5x = [math]::Round(100.0 * $ge5 / $n, 2)
        pct10x = [math]::Round(100.0 * $ge10 / $n, 2)
        pct17x = [math]::Round(100.0 * $ge17 / $n, 2)
        pctRuin = [math]::Round(100.0 * $nRuin / $n, 1)
    }
}

# ---- rolling historical windows ----
$nW = $nR - $WindowDays + 1
$wMult = New-Object 'double[]' $nW
$wRuin = New-Object 'bool[]' $nW
$wTrades = New-Object 'double[]' $nW
for ($s = 0; $s -lt $nW; $s++) {
    $m = 1.0; $ruined = $false; $tc = 0
    for ($k = 0; $k -lt $WindowDays; $k++) {
        $m *= (1 + $rets[$s + $k])
        $tc += $tradedFlags[$s + $k + 1]
        if ($m -le $RuinLevel) { $ruined = $true; break }
    }
    $wMult[$s] = $m; $wRuin[$s] = $ruined; $wTrades[$s] = $tc
}
$hist = Window-Stats $wMult $wRuin 'historical'
$sumT = 0.0; foreach ($x in $wTrades) { $sumT += $x }
$hist['avgTradesPerWindow'] = [math]::Round($sumT / $nW, 1)

# ---- Monte Carlo IID ----
$rng = New-Object System.Random($Seed)
$mMult = New-Object 'double[]' $McPaths
$mRuin = New-Object 'bool[]' $McPaths
for ($p = 0; $p -lt $McPaths; $p++) {
    $m = 1.0; $ruined = $false
    for ($k = 0; $k -lt $WindowDays; $k++) {
        $m *= (1 + $rets[$rng.Next(0, $nR)])
        if ($m -le $RuinLevel) { $ruined = $true; break }
    }
    $mMult[$p] = $m; $mRuin[$p] = $ruined
}
$mc = Window-Stats $mMult $mRuin 'mc-iid'

# ---- Monte Carlo block bootstrap ----
$rng2 = New-Object System.Random($Seed + 1)
$bMult = New-Object 'double[]' $McPaths
$bRuin = New-Object 'bool[]' $McPaths
$nBlocks = [int][math]::Ceiling($WindowDays / [double]$BlockLen)
for ($p = 0; $p -lt $McPaths; $p++) {
    $m = 1.0; $ruined = $false; $k = 0
    for ($b = 0; $b -lt $nBlocks -and -not $ruined; $b++) {
        $st = $rng2.Next(0, $nR - $BlockLen)
        for ($j = 0; $j -lt $BlockLen; $j++) {
            if ($k -ge $WindowDays) { break }
            $m *= (1 + $rets[$st + $j]); $k++
            if ($m -le $RuinLevel) { $ruined = $true; break }
        }
    }
    $bMult[$p] = $m; $bRuin[$p] = $ruined
}
$mcb = Window-Stats $bMult $bRuin 'mc-block'

# ---- losing streaks ----
$maxStreakDays = 0; $cur = 0
for ($i = 0; $i -lt $nR; $i++) {
    if ($rets[$i] -lt 0) { $cur++; if ($cur -gt $maxStreakDays) { $maxStreakDays = $cur } } else { $cur = 0 }
}
$maxStreakTrades = 0; $cur = 0
foreach ($tr in $trades) {
    if ([double]$tr['pnlUsd'] -lt 0) { $cur++; if ($cur -gt $maxStreakTrades) { $maxStreakTrades = $cur } } else { $cur = 0 }
}

# ---- engine invariants ----
$violDay = 0; $violLiq = 0; $violLiqGap = 0
$dayCount = New-Object 'System.Collections.Generic.Dictionary[string,int]'
foreach ($tr in $trades) {
    $ed = [string]$tr['entryDay']
    if ($dayCount.ContainsKey($ed)) { $dayCount[$ed]++ } else { $dayCount[$ed] = 1 }
    $isLong = ([string]$tr['side'] -eq 'long')
    $stop0 = [double]$tr['stop0']; $liqPx = [double]$tr['liqPx']
    if ($isLong) { if ($stop0 -le $liqPx) { $violLiq++ } }
    else { if ($stop0 -ge $liqPx) { $violLiq++ } }
    if ([string]$tr['reason'] -eq 'liquidation') {
        $eo = [double]$tr['exitOpen']
        if ($isLong) { if ($eo -gt $liqPx) { $violLiqGap++ } }
        else { if ($eo -lt $liqPx) { $violLiqGap++ } }
    }
}
foreach ($kv in $dayCount.GetEnumerator()) { if ($kv.Value -gt 1) { $violDay++ } }
$invOk = ($violDay -eq 0 -and $violLiq -eq 0 -and $violLiqGap -eq 0)

$out = @{
    tag = $Tag; windowDays = $WindowDays; ruinLevel = $RuinLevel
    dailyRows = $nD; trades = $trades.Count
    historical = $hist; mcIid = $mc; mcBlock = $mcb
    maxLosingStreakDays = $maxStreakDays; maxLosingStreakTrades = $maxStreakTrades
    invariants = @{ ok = $invOk; multiEntryDays = $violDay; stopOutsideLiq = $violLiq; liqWithoutGap = $violLiqGap }
}
[System.IO.File]::WriteAllText((Join-Path $DataDir "st_${Tag}.json"), (ConvertTo-Json $out -Compress -Depth 6), [System.Text.Encoding]::UTF8)

if (-not $Quiet) {
    Write-Host ("=== {0}: {1}-day windows (ruin at x{2}) ===" -f $Tag, $WindowDays, $RuinLevel)
    foreach ($ws in @($hist, $mc, $mcb)) {
        Write-Host ("{0,-11} n={1,-6} med={2,-6} p10={3,-6} p90={4,-6} best={5,-7} gain%={6,-5} 2x%={7,-6} 5x%={8,-6} 10x%={9,-5} 17x%={10,-5} ruin%={11}" -f `
            $ws.label, $ws.windows, $ws.median, $ws.p10, $ws.p90, $ws.best, $ws.pctGain, $ws.pct2x, $ws.pct5x, $ws.pct10x, $ws.pct17x, $ws.pctRuin)
    }
    Write-Host ("avg trades/window: {0} | max losing streak: {1} days / {2} trades" -f $hist.avgTradesPerWindow, $maxStreakDays, $maxStreakTrades)
    if ($invOk) { Write-Host "INVARIANTS: OK" } else {
        Write-Host ("INVARIANTS VIOLATED: multiEntryDays={0} stopOutsideLiq={1} liqWithoutGap={2}" -f $violDay, $violLiq, $violLiqGap)
    }
}
