# challenge\tools\scan.ps1 - live daily-pick scanner for the 30-day challenge.
# Mirrors challenge\tools\backtest.ps1 signal logic exactly, on the last CLOSED 1h bar.
# Reads challenge\portfolio.json for account state (one entry per UTC day, one position at a time).
# Writes challenge\data\signal.json.
param(
    [string[]]$Symbols = @('BTC-USDT','ETH-USDT','SOL-USDT','BNB-USDT','XRP-USDT','DOGE-USDT','ADA-USDT','AVAX-USDT','LINK-USDT'),
    [string]$Setup = 'S1',
    [int]$BreakN = 24,
    [string]$ExitMode = 'trail',
    [double]$TrailMult = 3.0,
    [double]$AtrStopMult = 2.0,
    [double]$BurstRangeMult = 2.0,
    [double]$BurstVolMult = 2.0,
    [double]$RiskPct = 0.05,
    [double]$LevTarget = 15,
    [double]$MMR = 0.005,
    [double]$LiqSafety = 0.8,
    [double]$MarginCapPct = 0.9,
    [double]$MinScore = 0,
    [switch]$LongOnly,
    [string]$PortfolioPath = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root = Split-Path $PSScriptRoot -Parent
if (-not $PortfolioPath) { $PortfolioPath = Join-Path $root 'portfolio.json' }
$outPath = Join-Path $root 'data\signal.json'

$HOUR = 3600000L; $H4 = 14400000L; $DAY = 86400000L

function Calc-EMA([double[]]$src, [int]$n) {
    $len = $src.Length; $out = New-Object 'double[]' $len
    $k = 2.0 / ($n + 1); $out[0] = $src[0]
    for ($i = 1; $i -lt $len; $i++) { $out[$i] = $src[$i] * $k + $out[$i-1] * (1 - $k) }
    return $out
}
function Calc-ATR([double[]]$hi, [double[]]$lo, [double[]]$cl, [int]$n) {
    $len = $hi.Length; $out = New-Object 'double[]' $len
    for ($i = 0; $i -lt $len; $i++) { $out[$i] = [double]::NaN }
    if ($len -le $n) { return $out }
    $sum = 0.0
    for ($i = 1; $i -le $n; $i++) {
        $tr = $hi[$i] - $lo[$i]
        $a = [math]::Abs($hi[$i] - $cl[$i-1]); if ($a -gt $tr) { $tr = $a }
        $b = [math]::Abs($lo[$i] - $cl[$i-1]); if ($b -gt $tr) { $tr = $b }
        $sum += $tr
    }
    $out[$n] = $sum / $n
    for ($i = $n + 1; $i -lt $len; $i++) {
        $tr = $hi[$i] - $lo[$i]
        $a = [math]::Abs($hi[$i] - $cl[$i-1]); if ($a -gt $tr) { $tr = $a }
        $b = [math]::Abs($lo[$i] - $cl[$i-1]); if ($b -gt $tr) { $tr = $b }
        $out[$i] = ($out[$i-1] * ($n - 1) + $tr) / $n
    }
    return $out
}

function Get-Klines([string]$sym, [string]$interval, [long]$stepMs) {
    $bybitSym = $sym.Replace('-','')
    $nowMs = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    $url = "https://api.bybit.com/v5/market/kline?category=linear&symbol=$bybitSym&interval=$interval&limit=1000"
    $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 30
    if ($resp.retCode -ne 0) { throw "kline $sym retCode=$($resp.retCode)" }
    $list = @($resp.result.list) | Sort-Object { [long]$_[0] }
    $rows = @()
    foreach ($k in $list) {
        $ts = [long]$k[0]
        if (($ts + $stepMs) -le $nowMs) {
            $rows += ,@([long]$k[0], [double]$k[1], [double]$k[2], [double]$k[3], [double]$k[4], [double]$k[5])
        }
    }
    return ,$rows
}

function Get-FundingNow([string]$sym) {
    $bybitSym = $sym.Replace('-','')
    try {
        $url = "https://api.bybit.com/v5/market/tickers?category=linear&symbol=$bybitSym"
        $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 20
        if ($resp.retCode -eq 0 -and $resp.result.list.Count -gt 0) { return [double]$resp.result.list[0].fundingRate }
    } catch {}
    return 0.0001
}

# ---- account state ----
$pf = $null
if (Test-Path $PortfolioPath) { $pf = Get-Content $PortfolioPath -Raw -Encoding UTF8 | ConvertFrom-Json }
$equity = 1000.0; $openPos = $false; $enteredToday = $false
$todayUtc = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-dd')
if ($null -ne $pf) {
    $equity = [double]$pf.equity_usd
    if ($pf.open_position -and $pf.open_position.symbol) { $openPos = $true }
    if ($pf.last_entry_day_utc -eq $todayUtc) { $enteredToday = $true }
    if ($pf.challenge -and $pf.challenge.failed) { $enteredToday = $true }
}

$scanUtc = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-dd HH:mm')
$cands = @(); $best = $null

foreach ($sym in $Symbols) {
    $k1 = Get-Klines $sym '60' $HOUR
    $k4 = Get-Klines $sym '240' $H4
    Start-Sleep -Milliseconds 100
    $n1 = $k1.Count; $n4 = $k4.Count
    if ($n1 -lt ($BreakN + 20) -or $n1 -lt 80 -or $n4 -lt 170) { continue }

    $t1v = New-Object 'long[]' $n1
    $o1 = New-Object 'double[]' $n1; $h1 = New-Object 'double[]' $n1
    $l1 = New-Object 'double[]' $n1; $c1 = New-Object 'double[]' $n1; $v1 = New-Object 'double[]' $n1
    for ($i = 0; $i -lt $n1; $i++) {
        $t1v[$i] = [long]$k1[$i][0]; $o1[$i] = $k1[$i][1]; $h1[$i] = $k1[$i][2]
        $l1[$i] = $k1[$i][3]; $c1[$i] = $k1[$i][4]; $v1[$i] = $k1[$i][5]
    }
    $c4 = New-Object 'double[]' $n4; $t4v = New-Object 'long[]' $n4
    for ($i = 0; $i -lt $n4; $i++) { $t4v[$i] = [long]$k4[$i][0]; $c4[$i] = $k4[$i][4] }

    $iLast = $n1 - 1
    $decTs = $t1v[$iLast] + $HOUR
    $j = $n4 - 1
    while ($j -ge 0 -and ($t4v[$j] + $H4) -gt $decTs) { $j-- }
    if ($j -lt 0) { continue }

    $ema20_4 = Calc-EMA $c4 20; $ema50_4 = Calc-EMA $c4 50
    $atrArr = Calc-ATR $h1 $l1 $c1 14
    $atr = $atrArr[$iLast]
    if ([double]::IsNaN($atr) -or $atr -le 0) { continue }

    $e20 = $ema20_4[$j]; $e50 = $ema50_4[$j]; $cc4 = $c4[$j]
    $upTrend = ($cc4 -gt $e50) -and ($e20 -gt $e50)
    $dnTrend = ($cc4 -lt $e50) -and ($e20 -lt $e50)
    $cl = $c1[$iLast]
    $fund = Get-FundingNow $sym

    $penL = [double]::NaN; $penS = [double]::NaN
    $lvlL = 0.0; $lvlS = 0.0
    if ($Setup -eq 'S1') {
        $bh = $h1[($iLast - $BreakN)..($iLast - 1)] | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
        $bl = $l1[($iLast - $BreakN)..($iLast - 1)] | Measure-Object -Minimum | Select-Object -ExpandProperty Minimum
        $lvlL = $bh; $lvlS = $bl
        if ($upTrend -and $cl -gt $bh) { $penL = ($cl - $bh) / $atr }
        if ($dnTrend -and $cl -lt $bl) { $penS = ($bl - $cl) / $atr }
    } elseif ($Setup -eq 'S2') {
        $todayIdx = [int][math]::Floor($t1v[$iLast] / $DAY)
        $pdH = [double]::NaN; $pdL = [double]::NaN
        for ($i = 0; $i -lt $n1; $i++) {
            $di = [int][math]::Floor($t1v[$i] / $DAY)
            if ($di -eq ($todayIdx - 1)) {
                if ([double]::IsNaN($pdH) -or $h1[$i] -gt $pdH) { $pdH = $h1[$i] }
                if ([double]::IsNaN($pdL) -or $l1[$i] -lt $pdL) { $pdL = $l1[$i] }
            }
        }
        $lvlL = $pdH; $lvlS = $pdL
        if ($upTrend -and -not [double]::IsNaN($pdH) -and $cl -gt $pdH) { $penL = ($cl - $pdH) / $atr }
        if ($dnTrend -and -not [double]::IsNaN($pdL) -and $cl -lt $pdL) { $penS = ($pdL - $cl) / $atr }
    } elseif ($Setup -eq 'S4') {
        # sweep-reclaim: wick pierces the N-hour extreme of PRIOR bars, close reclaims it; with the 4h trend
        $bh = $h1[($iLast - $BreakN)..($iLast - 1)] | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
        $bl = $l1[($iLast - $BreakN)..($iLast - 1)] | Measure-Object -Minimum | Select-Object -ExpandProperty Minimum
        $lvlL = $bl; $lvlS = $bh
        if ($upTrend -and $l1[$iLast] -le $bl -and $cl -gt $bl) { $penL = ($bl - $l1[$iLast]) / $atr }
        if ($dnTrend -and $h1[$iLast] -ge $bh -and $cl -lt $bh) { $penS = ($h1[$iLast] - $bh) / $atr }
    } elseif ($Setup -eq 'S5') {
        # RSI14 dip with the 4h trend (Wilder)
        $nR = $n1; $ag = 0.0; $al = 0.0
        for ($i = 1; $i -le 14; $i++) {
            $df = $c1[$i] - $c1[$i-1]
            if ($df -gt 0) { $ag += $df } else { $al -= $df }
        }
        $ag = $ag / 14.0; $al = $al / 14.0
        for ($i = 15; $i -lt $nR; $i++) {
            $df = $c1[$i] - $c1[$i-1]
            $g = 0.0; $ls = 0.0
            if ($df -gt 0) { $g = $df } else { $ls = -$df }
            $ag = ($ag * 13 + $g) / 14.0
            $al = ($al * 13 + $ls) / 14.0
        }
        $rv = 100.0; if ($al -gt 0) { $rv = 100 - 100 / (1 + $ag / $al) }
        if ($upTrend -and $rv -lt 30) { $penL = (30 - $rv) / 10 }
        if ($dnTrend -and $rv -gt 70) { $penS = ($rv - 70) / 10 }
    } else {
        $vs = 0.0
        for ($i = $iLast - 19; $i -le $iLast; $i++) { $vs += $v1[$i] }
        $vs = $vs / 20.0
        $rng = $h1[$iLast] - $l1[$iLast]
        if ($vs -gt 0 -and $rng -ge $BurstRangeMult * $atr -and $v1[$iLast] -ge $BurstVolMult * $vs) {
            $p = ($rng / $atr) - $BurstRangeMult; if ($p -lt 0) { $p = 0 }
            if ($upTrend -and $cl -gt $o1[$iLast]) { $penL = $p }
            if ($dnTrend -and $cl -lt $o1[$iLast]) { $penS = $p }
        }
    }

    $trendGap = 100.0 * [math]::Abs($e20 - $e50) / $cl
    $trendTxt = 'flat'; if ($upTrend) { $trendTxt = 'up' } elseif ($dnTrend) { $trendTxt = 'down' }
    $rec = [ordered]@{
        symbol = $sym; trend = $trendTxt; close = $cl
        atr = [math]::Round($atr, 6); atrPct = [math]::Round(100 * $atr / $cl, 2)
        trendGapPct = [math]::Round($trendGap, 3); funding8h = $fund
        barUtc = [DateTimeOffset]::FromUnixTimeMilliseconds($t1v[$iLast]).ToString('yyyy-MM-dd HH:mm')
        breakLevelLong = $lvlL; breakLevelShort = $lvlS
        signalLong = (-not [double]::IsNaN($penL)); signalShort = (-not [double]::IsNaN($penS))
        score = $null; side = $null
    }
    $score = [double]::NaN; $side = ''
    if (-not [double]::IsNaN($penL)) {
        $ft = 0.0; if ($fund -lt -0.0001) { $ft = 0.3 } elseif ($fund -gt 0.0001) { $ft = -0.3 }
        $p = $penL; if ($p -gt 1.5) { $p = 1.5 }
        $score = $trendGap + 0.5 * $p + $ft; $side = 'long'
    }
    if ((-not $LongOnly) -and -not [double]::IsNaN($penS)) {
        $ft = 0.0; if ($fund -gt 0.0001) { $ft = 0.3 } elseif ($fund -lt -0.0001) { $ft = -0.3 }
        $p = $penS; if ($p -gt 1.5) { $p = 1.5 }
        $s2 = $trendGap + 0.5 * $p + $ft
        if ([double]::IsNaN($score) -or $s2 -gt $score) { $score = $s2; $side = 'short' }
    }
    if (-not [double]::IsNaN($score)) {
        $rec.score = [math]::Round($score, 3); $rec.side = $side
        if ($score -gt $MinScore -and ($null -eq $best -or $score -gt $best.score)) {
            $best = @{ symbol = $sym; side = $side; score = $score; close = $cl; atr = $atr; fund = $fund }
        }
    }
    $cands += [pscustomobject]$rec
}

# ---- build output ----
$out = [ordered]@{
    scannedUtc = $scanUtc
    strategy = "challenge-$Setup-$ExitMode"
    params = [ordered]@{ setup = $Setup; breakN = $BreakN; exitMode = $ExitMode; trailMult = $TrailMult
                          atrStopMult = $AtrStopMult; riskPct = $RiskPct; levTarget = $LevTarget }
    equity = $equity
    noTradeReason = $null
    pick = $null
    candidates = $cands
}

if ($openPos) { $out.noTradeReason = 'position-open' }
elseif ($enteredToday) { $out.noTradeReason = 'entry-already-today' }
elseif ($null -eq $best) { $out.noTradeReason = 'no-signal' }
else {
    $entry = $best.close   # market fill on next bar open ~ last close
    $stopDist = $AtrStopMult * $best.atr
    $stopPct = $stopDist / $entry
    $levMaxStop = $LiqSafety / ($stopPct + $MMR)
    $levEff = $LevTarget; if ($levMaxStop -lt $levEff) { $levEff = $levMaxStop }
    $sideMul = 1; if ($best.side -eq 'short') { $sideMul = -1 }
    $qty = $equity * $RiskPct / $stopDist
    $margin = $qty * $entry / $levEff
    if ($margin -gt $MarginCapPct * $equity) {
        $qty = $MarginCapPct * $equity * $levEff / $entry
        $margin = $qty * $entry / $levEff
    }
    $liqPx = $entry * (1 - $sideMul * (1.0 / $levEff - $MMR))
    $stop0 = $entry - $sideMul * $stopDist
    $tp = $null
    if ($ExitMode -eq 'tp2r') { $tp = $entry + $sideMul * 2.0 * $stopDist }
    elseif ($ExitMode -eq 'tp3r') { $tp = $entry + $sideMul * 3.0 * $stopDist }
    $out.pick = [ordered]@{
        symbol = $best.symbol; side = $best.side; score = [math]::Round($best.score, 3)
        entry = [math]::Round($entry, 6); stop = [math]::Round($stop0, 6)
        tp = $tp; liqPx = [math]::Round($liqPx, 6)
        levEff = [math]::Round($levEff, 2); qty = [math]::Round($qty, 6)
        notionalUsd = [math]::Round($qty * $entry, 2); marginUsd = [math]::Round($margin, 2)
        riskUsd = [math]::Round($qty * $stopDist, 2); riskPctEq = [math]::Round(100 * $qty * $stopDist / $equity, 2)
        funding8h = $best.fund
        exitPlan = $ExitMode; trailMult = $TrailMult; maxHoldBars = 48
    }
}

$json = ConvertTo-Json $out -Depth 6
[System.IO.File]::WriteAllText($outPath, $json, [System.Text.Encoding]::UTF8)
Write-Host "scan done -> $outPath"
if ($out.pick) { Write-Host ("PICK: {0} {1} score={2} entry={3} stop={4} lev={5}x margin={6}" -f $out.pick.symbol, $out.pick.side, $out.pick.score, $out.pick.entry, $out.pick.stop, $out.pick.levEff, $out.pick.marginUsd) }
else { Write-Host ("no trade: {0}" -f $out.noTradeReason) }
