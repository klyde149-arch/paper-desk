# challenge\tools\backtest.ps1 - standalone backtest engine for the 30-day challenge.
# Written from scratch. One entry per UTC day, best-of-universe pick, isolated-margin
# leverage with liquidation modeling, real funding, gap-aware stops. 1h signal TF + 4h trend TF.
param(
    [string[]]$Symbols = @('BTC-USDT','ETH-USDT','SOL-USDT','BNB-USDT','XRP-USDT','DOGE-USDT','ADA-USDT','AVAX-USDT','LINK-USDT'),
    [double]$StartEquity = 1000,
    [string]$DataDir = '',
    [string]$OutDir = '',
    [string]$Tag = 'run',

    [ValidateSet('S1','S2','S3','S4','S5')]
    [string]$Setup = 'S1',
    [int]$BreakN = 24,              # S1: 1h Donchian lookback (hours)
    [double]$BurstRangeMult = 2.0,  # S3: bar range >= k * ATR14(1h)
    [double]$BurstVolMult = 2.0,    # S3: volume >= m * SMA20(vol)

    [ValidateSet('trail','tp2r','tp3r')]
    [string]$ExitMode = 'trail',
    [double]$TrailMult = 3.0,       # chandelier: stop = MFE - TrailMult*ATR
    [double]$AtrStopMult = 2.0,     # initial stop = AtrStopMult * ATR14(1h)
    [int]$MaxHoldBars = 48,

    [double]$RiskPct = 0.05,
    [double]$LevTarget = 15,
    [double]$MMR = 0.005,           # maintenance margin rate
    [double]$LiqSafety = 0.8,       # stop must sit inside liq with this safety factor
    [double]$MarginCapPct = 0.9,

    [double]$FeePct = 0.0005,
    [double]$SlipPct = 0.0003,
    [double]$StopSlipPct = 0.0005,
    [double]$DefaultFunding8h = 0.0001,

    [double]$MinScore = 0,
    [double]$ChallengeStopPct = 0,  # 0 = off (research); live doc enforces -50%
    [string]$FromDate = '2021-01-01',
    [string]$ToDate = '',
    [switch]$LongOnly,
    [int]$Warmup1h = 60,
    [int]$Warmup4h = 160,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web.Extensions
$JS = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$JS.MaxJsonLength = [int]::MaxValue
$INV = [System.Globalization.CultureInfo]::InvariantCulture

$root = Split-Path $PSScriptRoot -Parent
if (-not $DataDir) { $DataDir = Join-Path $root 'data' }
if (-not $OutDir)  { $OutDir  = Join-Path $root 'data' }

$HOUR = 3600000L; $H4 = 14400000L; $DAY = 86400000L; $SLOT8H = 28800000L

# ---------- data loading ----------
function Load-Candles([string]$path) {
    $raw = $JS.DeserializeObject([System.IO.File]::ReadAllText($path))
    $n = $raw.Count
    $t = New-Object 'long[]' $n;   $o = New-Object 'double[]' $n
    $h = New-Object 'double[]' $n; $l = New-Object 'double[]' $n
    $c = New-Object 'double[]' $n; $v = New-Object 'double[]' $n
    for ($i = 0; $i -lt $n; $i++) {
        $r = $raw[$i]
        $t[$i] = [long]$r['t']; $o[$i] = [double]$r['o']; $h[$i] = [double]$r['h']
        $l[$i] = [double]$r['l']; $c[$i] = [double]$r['c']; $v[$i] = [double]$r['v']
    }
    return @{ n = $n; t = $t; o = $o; h = $h; l = $l; c = $c; v = $v }
}

function Load-Funding([string]$path) {
    $map = New-Object 'System.Collections.Generic.Dictionary[long,double]'
    $tsArr = New-Object 'System.Collections.Generic.List[long]'
    $rArr  = New-Object 'System.Collections.Generic.List[double]'
    if (Test-Path $path) {
        $raw = $JS.DeserializeObject([System.IO.File]::ReadAllText($path))
        foreach ($r in $raw) {
            $ts = [long]$r['t']; $rate = [double]$r['r']
            if (-not $map.ContainsKey($ts)) { $map[$ts] = $rate; $tsArr.Add($ts); $rArr.Add($rate) }
        }
    }
    return @{ map = $map; ts = $tsArr; r = $rArr }
}

# ---------- indicators (flat loops, no pipelines) ----------
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
function Calc-RSI([double[]]$cl, [int]$n) {
    $len = $cl.Length; $out = New-Object 'double[]' $len
    for ($i = 0; $i -lt $len; $i++) { $out[$i] = [double]::NaN }
    if ($len -le $n) { return $out }
    $ag = 0.0; $al = 0.0
    for ($i = 1; $i -le $n; $i++) {
        $df = $cl[$i] - $cl[$i-1]
        if ($df -gt 0) { $ag += $df } else { $al -= $df }
    }
    $ag = $ag / $n; $al = $al / $n
    if ($al -eq 0) { $out[$n] = 100 } else { $out[$n] = 100 - 100 / (1 + $ag / $al) }
    for ($i = $n + 1; $i -lt $len; $i++) {
        $df = $cl[$i] - $cl[$i-1]
        $g = 0.0; $ls = 0.0
        if ($df -gt 0) { $g = $df } else { $ls = -$df }
        $ag = ($ag * ($n - 1) + $g) / $n
        $al = ($al * ($n - 1) + $ls) / $n
        if ($al -eq 0) { $out[$i] = 100 } else { $out[$i] = 100 - 100 / (1 + $ag / $al) }
    }
    return $out
}
function Calc-SMA([double[]]$src, [int]$n) {
    $len = $src.Length; $out = New-Object 'double[]' $len
    $sum = 0.0
    for ($i = 0; $i -lt $len; $i++) {
        $sum += $src[$i]
        if ($i -ge $n) { $sum -= $src[$i-$n] }
        if ($i -ge $n - 1) { $out[$i] = $sum / $n } else { $out[$i] = [double]::NaN }
    }
    return $out
}
# rolling max over window [i-N+1 .. i] via block decomposition, O(n)
function Calc-RollMax([double[]]$src, [int]$n) {
    $len = $src.Length; $out = New-Object 'double[]' $len
    $pre = New-Object 'double[]' $len; $suf = New-Object 'double[]' $len
    for ($i = 0; $i -lt $len; $i++) {
        if ($i % $n -eq 0) { $pre[$i] = $src[$i] }
        elseif ($src[$i] -gt $pre[$i-1]) { $pre[$i] = $src[$i] } else { $pre[$i] = $pre[$i-1] }
    }
    for ($i = $len - 1; $i -ge 0; $i--) {
        if ((($i + 1) % $n -eq 0) -or ($i -eq $len - 1)) { $suf[$i] = $src[$i] }
        elseif ($src[$i] -gt $suf[$i+1]) { $suf[$i] = $src[$i] } else { $suf[$i] = $suf[$i+1] }
    }
    for ($i = 0; $i -lt $len; $i++) {
        if ($i -lt $n - 1) { $out[$i] = [double]::NaN }
        else {
            $l0 = $i - $n + 1
            if ($suf[$l0] -gt $pre[$i]) { $out[$i] = $suf[$l0] } else { $out[$i] = $pre[$i] }
        }
    }
    return $out
}
function Calc-RollMin([double[]]$src, [int]$n) {
    $len = $src.Length; $neg = New-Object 'double[]' $len
    for ($i = 0; $i -lt $len; $i++) { $neg[$i] = -$src[$i] }
    $mx = Calc-RollMax $neg $n
    $out = New-Object 'double[]' $len
    for ($i = 0; $i -lt $len; $i++) { $out[$i] = -$mx[$i] }
    return $out
}

# ---------- load all symbols ----------
$swAll = [Diagnostics.Stopwatch]::StartNew()
$nSym = $Symbols.Count
$D1 = @{}; $D4 = @{}; $FU = @{}
foreach ($sym in $Symbols) {
    $fb = $sym.Replace('-','_')
    $D1[$sym] = Load-Candles (Join-Path $DataDir "${fb}_1h.json")
    $D4[$sym] = Load-Candles (Join-Path $DataDir "${fb}_4h.json")
    $FU[$sym] = Load-Funding (Join-Path $DataDir "${fb}_funding.json")
}
$tLoad = $swAll.Elapsed.TotalSeconds

# ---------- per-symbol precompute ----------
$MKT = @{}
foreach ($sym in $Symbols) {
    $cd1 = $D1[$sym]; $cd4 = $D4[$sym]; $cfu = $FU[$sym]
    $n1 = $cd1.n; $n4 = $cd4.n
    $t1 = $cd1.t; $o1 = $cd1.o; $h1 = $cd1.h; $l1 = $cd1.l; $c1 = $cd1.c; $v1 = $cd1.v
    $t4 = $cd4.t; $c4 = $cd4.c

    $ema20_4 = Calc-EMA $c4 20
    $ema50_4 = Calc-EMA $c4 50
    $atr1 = Calc-ATR $h1 $l1 $c1 14
    $volSma = Calc-SMA $v1 20

    # map4[i] = index of last CLOSED 4h bar at the close time of 1h bar i (no lookahead)
    $map4 = New-Object 'int[]' $n1
    $j = -1
    for ($i = 0; $i -lt $n1; $i++) {
        $decTs = $t1[$i] + $HOUR
        while (($j + 1) -lt $n4 -and ($t4[$j+1] + $H4) -le $decTs) { $j++ }
        $map4[$i] = $j
    }

    # funding rate known at bar i (latest event with t <= t1[i]); default if none yet
    $rateAt = New-Object 'double[]' $n1
    $fp = -1; $fts = $cfu.ts; $fr = $cfu.r; $fn = $fts.Count
    for ($i = 0; $i -lt $n1; $i++) {
        while (($fp + 1) -lt $fn -and $fts[$fp+1] -le $t1[$i]) { $fp++ }
        if ($fp -ge 0) { $rateAt[$i] = $fr[$fp] } else { $rateAt[$i] = $DefaultFunding8h }
    }

    # prior-UTC-day high/low per 1h bar
    $pdHigh = New-Object 'double[]' $n1; $pdLow = New-Object 'double[]' $n1
    $dayHi = New-Object 'System.Collections.Generic.Dictionary[int,double]'
    $dayLo = New-Object 'System.Collections.Generic.Dictionary[int,double]'
    for ($i = 0; $i -lt $n1; $i++) {
        $di = [int][math]::Floor($t1[$i] / $DAY)
        if ($dayHi.ContainsKey($di)) {
            if ($h1[$i] -gt $dayHi[$di]) { $dayHi[$di] = $h1[$i] }
            if ($l1[$i] -lt $dayLo[$di]) { $dayLo[$di] = $l1[$i] }
        } else { $dayHi[$di] = $h1[$i]; $dayLo[$di] = $l1[$i] }
    }
    for ($i = 0; $i -lt $n1; $i++) {
        $di = [int][math]::Floor($t1[$i] / $DAY) - 1
        if ($dayHi.ContainsKey($di)) { $pdHigh[$i] = $dayHi[$di]; $pdLow[$i] = $dayLo[$di] }
        else { $pdHigh[$i] = [double]::NaN; $pdLow[$i] = [double]::NaN }
    }

    # setup-specific break levels
    $donchHi = $null; $donchLo = $null; $rsi1 = $null
    if ($Setup -eq 'S1' -or $Setup -eq 'S4') {
        $donchHi = Calc-RollMax $h1 $BreakN   # window ending at i; use [i-1] for prev-window
        $donchLo = Calc-RollMin $l1 $BreakN
    }
    if ($Setup -eq 'S5') { $rsi1 = Calc-RSI $c1 14 }

    # signal precompute: scoreL[i]/scoreS[i] = NaN if no signal, else score
    $scoreL = New-Object 'double[]' $n1; $scoreS = New-Object 'double[]' $n1
    $minI = $Warmup1h
    if (($Setup -eq 'S1' -or $Setup -eq 'S4') -and ($BreakN + 1) -gt $minI) { $minI = $BreakN + 1 }
    for ($i = 0; $i -lt $n1; $i++) {
        $scoreL[$i] = [double]::NaN; $scoreS[$i] = [double]::NaN
        if ($i -lt $minI) { continue }
        $m = $map4[$i]
        if ($m -lt $Warmup4h) { continue }
        $atr = $atr1[$i]
        if ([double]::IsNaN($atr) -or $atr -le 0) { continue }
        $e20 = $ema20_4[$m]; $e50 = $ema50_4[$m]; $cc4 = $c4[$m]
        $upTrend = ($cc4 -gt $e50) -and ($e20 -gt $e50)
        $dnTrend = ($cc4 -lt $e50) -and ($e20 -lt $e50)
        if (-not ($upTrend -or $dnTrend)) { continue }
        $cl = $c1[$i]
        $penL = [double]::NaN; $penS = [double]::NaN
        if ($Setup -eq 'S1') {
            $bh = $donchHi[$i-1]; $bl = $donchLo[$i-1]
            if ($upTrend -and -not [double]::IsNaN($bh) -and $cl -gt $bh) { $penL = ($cl - $bh) / $atr }
            if ($dnTrend -and -not [double]::IsNaN($bl) -and $cl -lt $bl) { $penS = ($bl - $cl) / $atr }
        } elseif ($Setup -eq 'S2') {
            $bh = $pdHigh[$i]; $bl = $pdLow[$i]
            if ($upTrend -and -not [double]::IsNaN($bh) -and $cl -gt $bh) { $penL = ($cl - $bh) / $atr }
            if ($dnTrend -and -not [double]::IsNaN($bl) -and $cl -lt $bl) { $penS = ($bl - $cl) / $atr }
        } elseif ($Setup -eq 'S4') {
            # sweep-reclaim: wick pierces the N-hour extreme, close reclaims it; WITH the 4h trend
            $bl = $donchLo[$i-1]; $bh = $donchHi[$i-1]
            if ($upTrend -and -not [double]::IsNaN($bl) -and $l1[$i] -le $bl -and $cl -gt $bl) { $penL = ($bl - $l1[$i]) / $atr }
            if ($dnTrend -and -not [double]::IsNaN($bh) -and $h1[$i] -ge $bh -and $cl -lt $bh) { $penS = ($h1[$i] - $bh) / $atr }
        } elseif ($Setup -eq 'S5') {
            # RSI dip with the 4h trend
            $rv = $rsi1[$i]
            if (-not [double]::IsNaN($rv)) {
                if ($upTrend -and $rv -lt 30) { $penL = (30 - $rv) / 10 }
                if ($dnTrend -and $rv -gt 70) { $penS = ($rv - 70) / 10 }
            }
        } else { # S3 volatility burst
            $rng = $h1[$i] - $l1[$i]
            $vs = $volSma[$i]
            if (-not [double]::IsNaN($vs) -and $vs -gt 0 -and $rng -ge $BurstRangeMult * $atr -and $v1[$i] -ge $BurstVolMult * $vs) {
                $p = ($rng / $atr) - $BurstRangeMult; if ($p -lt 0) { $p = 0 }
                if ($upTrend -and $cl -gt $o1[$i]) { $penL = $p }
                if ($dnTrend -and $cl -lt $o1[$i]) { $penS = $p }
            }
        }
        if ([double]::IsNaN($penL) -and [double]::IsNaN($penS)) { continue }
        $trendGap = 100.0 * [math]::Abs($e20 - $e50) / $cl
        $r8 = $rateAt[$i]
        if (-not [double]::IsNaN($penL)) {
            $ft = 0.0
            if ($r8 -lt -0.0001) { $ft = 0.3 } elseif ($r8 -gt 0.0001) { $ft = -0.3 }
            $p = $penL; if ($p -gt 1.5) { $p = 1.5 }
            $scoreL[$i] = $trendGap + 0.5 * $p + $ft
        }
        if (-not [double]::IsNaN($penS)) {
            $ft = 0.0
            if ($r8 -gt 0.0001) { $ft = 0.3 } elseif ($r8 -lt -0.0001) { $ft = -0.3 }
            $p = $penS; if ($p -gt 1.5) { $p = 1.5 }
            $scoreS[$i] = $trendGap + 0.5 * $p + $ft
        }
    }

    $MKT[$sym] = @{
        n = $n1; t = $t1; o = $o1; h = $h1; l = $l1; c = $c1
        atr = $atr1; scoreL = $scoreL; scoreS = $scoreS
        fmap = $cfu.map
    }
}
$tPre = $swAll.Elapsed.TotalSeconds - $tLoad

# ---------- master hourly loop ----------
$fromMs = [long]([DateTimeOffset]::Parse($FromDate + 'T00:00:00Z')).ToUnixTimeMilliseconds()
if ($ToDate) { $toMs = [long]([DateTimeOffset]::Parse($ToDate + 'T00:00:00Z')).ToUnixTimeMilliseconds() + $DAY }
else { $toMs = [long]::MaxValue }

$startTs = [long]::MaxValue; $endTs = 0L
foreach ($sym in $Symbols) {
    $d = $MKT[$sym]
    if ($d.n -gt 0) {
        if ($d.t[0] -lt $startTs) { $startTs = $d.t[0] }
        if ($d.t[$d.n-1] -gt $endTs) { $endTs = $d.t[$d.n-1] }
    }
}
if ($toMs -ne [long]::MaxValue -and ($toMs - $HOUR) -lt $endTs) { $endTs = $toMs - $HOUR }

$ptr = @{}; $cur = @{}; $lastClose = @{}
foreach ($sym in $Symbols) { $ptr[$sym] = 0; $cur[$sym] = -1; $lastClose[$sym] = [double]::NaN }

$equity = $StartEquity
$pos = $null
$pending = $null
$dayUsed = New-Object 'System.Collections.Generic.HashSet[int]'
$trades = New-Object 'System.Collections.Generic.List[object]'
$dailies = New-Object 'System.Collections.Generic.List[object]'
$halted = $false; $haltDay = ''
$liqCount = 0
$grossProfit = 0.0; $grossLoss = 0.0; $totFees = 0.0; $totFund = 0.0

function New-IsoUtc([long]$ms) { return [DateTimeOffset]::FromUnixTimeMilliseconds($ms).ToString('yyyy-MM-dd HH:mm') }

$exitReasons = @{}

for ($ts = $startTs; $ts -le $endTs; $ts += $HOUR) {
    $inWindow = ($ts -ge $fromMs -and $ts -lt $toMs)

    # advance pointers
    foreach ($sym in $Symbols) {
        $d = $MKT[$sym]; $p = $ptr[$sym]
        while ($p -lt $d.n -and $d.t[$p] -lt $ts) { $p++ }
        if ($p -lt $d.n -and $d.t[$p] -eq $ts) {
            $cur[$sym] = $p; $ptr[$sym] = $p + 1; $lastClose[$sym] = $d.c[$p]
        } else { $cur[$sym] = -1; $ptr[$sym] = $p }
    }

    # ----- manage open position -----
    if ($null -ne $pos) {
        $sym = $pos.sym; $i = $cur[$sym]
        if ($i -ge 0) {
            $d = $MKT[$sym]
            $side = $pos.side # +1 long, -1 short
            $op = $d.o[$i]; $hi = $d.h[$i]; $lo = $d.l[$i]; $cl = $d.c[$i]
            $pos.barsHeld++

            # funding at 8h slots (bar open time)
            if (($ts % $SLOT8H) -eq 0) {
                $r8 = $DefaultFunding8h
                if ($d.fmap.ContainsKey($ts)) { $r8 = $d.fmap[$ts] }
                $pos.fund += (-$side) * $pos.qty * $op * $r8
            }

            $exitPx = 0.0; $reason = ''
            if ($side -gt 0) {
                if ($op -le $pos.liqPx) { $reason = 'liquidation' }
                elseif ($op -le $pos.stop) { $exitPx = $op * (1 - $StopSlipPct); $reason = 'stop-gap' }
                elseif ($lo -le $pos.stop) { $exitPx = $pos.stop * (1 - $StopSlipPct); $reason = 'stop' }
                elseif ($pos.tp -gt 0 -and $hi -ge $pos.tp) { $exitPx = $pos.tp * (1 - $SlipPct); $reason = 'tp' }
                elseif ($pos.barsHeld -ge $MaxHoldBars) { $exitPx = $cl * (1 - $SlipPct); $reason = 'time' }
            } else {
                if ($op -ge $pos.liqPx) { $reason = 'liquidation' }
                elseif ($op -ge $pos.stop) { $exitPx = $op * (1 + $StopSlipPct); $reason = 'stop-gap' }
                elseif ($hi -ge $pos.stop) { $exitPx = $pos.stop * (1 + $StopSlipPct); $reason = 'stop' }
                elseif ($pos.tp -gt 0 -and $lo -le $pos.tp) { $exitPx = $pos.tp * (1 + $SlipPct); $reason = 'tp' }
                elseif ($pos.barsHeld -ge $MaxHoldBars) { $exitPx = $cl * (1 + $SlipPct); $reason = 'time' }
            }

            if ($reason -ne '') {
                if ($reason -eq 'liquidation') {
                    $pnlNet = -$pos.margin + $pos.fund
                    $exitFee = 0.0; $exitPx = $pos.liqPx
                    $liqCount++
                } else {
                    $pnlRaw = $side * $pos.qty * ($exitPx - $pos.entry)
                    $exitFee = $pos.qty * $exitPx * $FeePct
                    $pnlNet = $pnlRaw - $exitFee + $pos.fund
                }
                $equity += $pnlNet
                $tradePnl = $pnlNet - $pos.entryFee
                if ($tradePnl -gt 0) { $grossProfit += $tradePnl } else { $grossLoss += - $tradePnl }
                $totFees += $pos.entryFee + $exitFee; $totFund += $pos.fund
                if ($pos.stop -gt $pos.stop0 -and $side -gt 0 -and $reason -like 'stop*') { $reason = 'trail-' + $reason }
                elseif ($pos.stop -lt $pos.stop0 -and $side -lt 0 -and $reason -like 'stop*') { $reason = 'trail-' + $reason }
                if ($exitReasons.ContainsKey($reason)) { $exitReasons[$reason]++ } else { $exitReasons[$reason] = 1 }
                $sideTxt = 'short'; if ($side -gt 0) { $sideTxt = 'long' }
                $trades.Add(@{
                    sym = $sym; side = $sideTxt
                    tsIn = (New-IsoUtc $pos.entryTs); tsOut = (New-IsoUtc $ts)
                    entryDay = $pos.entryDay
                    entry = [math]::Round($pos.entry, 6); exit = [math]::Round($exitPx, 6)
                    qty = [math]::Round($pos.qty, 6); notional = [math]::Round($pos.qty * $pos.entry, 2)
                    levEff = [math]::Round($pos.levEff, 2); marginUsd = [math]::Round($pos.margin, 2)
                    stop0 = [math]::Round($pos.stop0, 6); liqPx = [math]::Round($pos.liqPx, 6)
                    exitOpen = [math]::Round($op, 6)
                    reason = $reason; barsHeld = $pos.barsHeld
                    riskUsd = [math]::Round($pos.riskUsd, 2); score = [math]::Round($pos.score, 3)
                    feeUsd = [math]::Round($pos.entryFee + $exitFee, 2); fundUsd = [math]::Round($pos.fund, 2)
                    pnlUsd = [math]::Round($tradePnl, 2); eqAfter = [math]::Round($equity, 2)
                })
                $pos = $null
            } else {
                # trail ratchet AFTER exit checks (no same-bar lookahead)
                if ($ExitMode -eq 'trail') {
                    if ($side -gt 0) {
                        if ($hi -gt $pos.mfe) { $pos.mfe = $hi }
                        $ns = $pos.mfe - $TrailMult * $d.atr[$i]
                        if ($ns -gt $pos.stop) { $pos.stop = $ns }
                    } else {
                        if ($lo -lt $pos.mfe) { $pos.mfe = $lo }
                        $ns = $pos.mfe + $TrailMult * $d.atr[$i]
                        if ($ns -lt $pos.stop) { $pos.stop = $ns }
                    }
                }
            }
        }
    }

    # ----- fill pending entry (next bar open after signal) -----
    if ($null -ne $pending) {
        if ($ts -eq $pending.fillTs -and $null -eq $pos -and -not $halted) {
            $sym = $pending.sym; $i = $cur[$sym]
            $fillDay = [int][math]::Floor($ts / $DAY)
            if ($i -ge 0 -and -not $dayUsed.Contains($fillDay) -and $equity -gt 0) {
                $d = $MKT[$sym]; $side = $pending.side
                $entry = $d.o[$i] * (1 + $side * $SlipPct)
                $stopDist = $AtrStopMult * $pending.atr
                if ($stopDist -gt 0 -and $entry -gt 0) {
                    $stopPct = $stopDist / $entry
                    $levMaxStop = $LiqSafety / ($stopPct + $MMR)
                    $levEff = $LevTarget; if ($levMaxStop -lt $levEff) { $levEff = $levMaxStop }
                    $qty = $equity * $RiskPct / $stopDist
                    $margin = $qty * $entry / $levEff
                    if ($margin -gt $MarginCapPct * $equity) {
                        $qty = $MarginCapPct * $equity * $levEff / $entry
                        $margin = $qty * $entry / $levEff
                    }
                    if ($qty * $entry -ge 5) {
                        $liqPx = $entry * (1 - $side * (1.0 / $levEff - $MMR))
                        $stop0 = $entry - $side * $stopDist
                        $tp = 0.0
                        if ($ExitMode -eq 'tp2r') { $tp = $entry + $side * 2.0 * $stopDist }
                        elseif ($ExitMode -eq 'tp3r') { $tp = $entry + $side * 3.0 * $stopDist }
                        $entryFee = $qty * $entry * $FeePct
                        $equity -= $entryFee
                        $mfe0 = $d.h[$i]; if ($side -lt 0) { $mfe0 = $d.l[$i] }
                        $pos = @{
                            sym = $sym; side = $side; entryTs = $ts
                            entryDay = [DateTimeOffset]::FromUnixTimeMilliseconds($ts).ToString('yyyy-MM-dd')
                            entry = $entry; qty = $qty; margin = $margin; levEff = $levEff
                            stop = $stop0; stop0 = $stop0; liqPx = $liqPx; tp = $tp
                            mfe = $mfe0; barsHeld = 0; fund = 0.0
                            entryFee = $entryFee; riskUsd = $qty * $stopDist; score = $pending.score
                        }
                        [void]$dayUsed.Add($fillDay)
                        # entry bar itself can stop out: run exit checks vs this same bar (after entry at open)
                        $hi = $d.h[$i]; $lo = $d.l[$i]; $cl = $d.c[$i]
                        $exitPx = 0.0; $reason = ''
                        if ($side -gt 0) {
                            if ($lo -le $pos.stop) { $exitPx = $pos.stop * (1 - $StopSlipPct); $reason = 'stop' }
                            elseif ($pos.tp -gt 0 -and $hi -ge $pos.tp) { $exitPx = $pos.tp * (1 - $SlipPct); $reason = 'tp' }
                        } else {
                            if ($hi -ge $pos.stop) { $exitPx = $pos.stop * (1 + $StopSlipPct); $reason = 'stop' }
                            elseif ($pos.tp -gt 0 -and $lo -le $pos.tp) { $exitPx = $pos.tp * (1 + $SlipPct); $reason = 'tp' }
                        }
                        if ($reason -ne '') {
                            $pnlRaw = $side * $pos.qty * ($exitPx - $pos.entry)
                            $exitFee = $pos.qty * $exitPx * $FeePct
                            $pnlNet = $pnlRaw - $exitFee + $pos.fund
                            $equity += $pnlNet
                            $tradePnl = $pnlNet - $pos.entryFee
                            if ($tradePnl -gt 0) { $grossProfit += $tradePnl } else { $grossLoss += - $tradePnl }
                            $totFees += $pos.entryFee + $exitFee; $totFund += $pos.fund
                            if ($exitReasons.ContainsKey($reason)) { $exitReasons[$reason]++ } else { $exitReasons[$reason] = 1 }
                            $sideTxt = 'short'; if ($side -gt 0) { $sideTxt = 'long' }
                            $trades.Add(@{
                                sym = $sym; side = $sideTxt
                                tsIn = (New-IsoUtc $ts); tsOut = (New-IsoUtc $ts)
                                entryDay = $pos.entryDay
                                entry = [math]::Round($pos.entry, 6); exit = [math]::Round($exitPx, 6)
                                qty = [math]::Round($pos.qty, 6); notional = [math]::Round($pos.qty * $pos.entry, 2)
                                levEff = [math]::Round($pos.levEff, 2); marginUsd = [math]::Round($pos.margin, 2)
                                stop0 = [math]::Round($pos.stop0, 6); liqPx = [math]::Round($pos.liqPx, 6)
                                exitOpen = [math]::Round($d.o[$i], 6)
                                reason = $reason; barsHeld = 0
                                riskUsd = [math]::Round($pos.riskUsd, 2); score = [math]::Round($pos.score, 3)
                                feeUsd = [math]::Round($pos.entryFee + $exitFee, 2); fundUsd = [math]::Round($pos.fund, 2)
                                pnlUsd = [math]::Round($tradePnl, 2); eqAfter = [math]::Round($equity, 2)
                            })
                            $pos = $null
                        } elseif ($ExitMode -eq 'trail') {
                            if ($side -gt 0) {
                                $ns = $pos.mfe - $TrailMult * $d.atr[$i]
                                if ($ns -gt $pos.stop) { $pos.stop = $ns }
                            } else {
                                $ns = $pos.mfe + $TrailMult * $d.atr[$i]
                                if ($ns -lt $pos.stop) { $pos.stop = $ns }
                            }
                        }
                    }
                }
            }
        }
        $pending = $null
    }

    # ----- entry scan on bar close -----
    if ($null -eq $pos -and $null -eq $pending -and $inWindow -and -not $halted) {
        $dayNow = [int][math]::Floor($ts / $DAY)
        if (-not $dayUsed.Contains($dayNow)) {
            $bestScore = $MinScore; $bestSym = ''; $bestSide = 0; $bestAtr = 0.0
            foreach ($sym in $Symbols) {
                $i = $cur[$sym]
                if ($i -lt 0) { continue }
                $d = $MKT[$sym]
                $sl = $d.scoreL[$i]
                if (-not [double]::IsNaN($sl) -and $sl -gt $bestScore) {
                    $bestScore = $sl; $bestSym = $sym; $bestSide = 1; $bestAtr = $d.atr[$i]
                }
                if (-not $LongOnly) {
                    $ss = $d.scoreS[$i]
                    if (-not [double]::IsNaN($ss) -and $ss -gt $bestScore) {
                        $bestScore = $ss; $bestSym = $sym; $bestSide = -1; $bestAtr = $d.atr[$i]
                    }
                }
            }
            if ($bestSide -ne 0) {
                $pending = @{ sym = $bestSym; side = $bestSide; score = $bestScore; atr = $bestAtr; fillTs = $ts + $HOUR }
            }
        }
    }

    # ----- daily close bookkeeping -----
    $dayNow2 = [int][math]::Floor($ts / $DAY)
    $dayNext = [int][math]::Floor(($ts + $HOUR) / $DAY)
    if ($dayNext -ne $dayNow2 -and $inWindow) {
        $mtm = $equity
        if ($null -ne $pos) {
            $lc = $lastClose[$pos.sym]
            if (-not [double]::IsNaN($lc)) { $mtm += $pos.side * $pos.qty * ($lc - $pos.entry) + $pos.fund }
        }
        $traded = 0; if ($dayUsed.Contains($dayNow2)) { $traded = 1 }
        $dailies.Add(@{ d = [DateTimeOffset]::FromUnixTimeMilliseconds($ts).ToString('yyyy-MM-dd'); eq = [math]::Round($mtm, 2); traded = $traded })
        if ($ChallengeStopPct -gt 0 -and -not $halted -and $mtm -le $StartEquity * (1 - $ChallengeStopPct)) {
            $halted = $true; $haltDay = [DateTimeOffset]::FromUnixTimeMilliseconds($ts).ToString('yyyy-MM-dd')
            if ($null -ne $pos) {
                # flatten at last close
                $sym = $pos.sym; $lc = $lastClose[$sym]; $side = $pos.side
                $exitPx = $lc * (1 - $side * $SlipPct)
                $pnlRaw = $side * $pos.qty * ($exitPx - $pos.entry)
                $exitFee = $pos.qty * $exitPx * $FeePct
                $pnlNet = $pnlRaw - $exitFee + $pos.fund
                $equity += $pnlNet
                $tradePnl = $pnlNet - $pos.entryFee
                if ($tradePnl -gt 0) { $grossProfit += $tradePnl } else { $grossLoss += - $tradePnl }
                $totFees += $pos.entryFee + $exitFee; $totFund += $pos.fund
                $sideTxt = 'short'; if ($side -gt 0) { $sideTxt = 'long' }
                $trades.Add(@{
                    sym = $sym; side = $sideTxt; tsIn = (New-IsoUtc $pos.entryTs); tsOut = (New-IsoUtc $ts)
                    entryDay = $pos.entryDay; entry = [math]::Round($pos.entry, 6); exit = [math]::Round($exitPx, 6)
                    qty = [math]::Round($pos.qty, 6); notional = [math]::Round($pos.qty * $pos.entry, 2)
                    levEff = [math]::Round($pos.levEff, 2); marginUsd = [math]::Round($pos.margin, 2)
                    stop0 = [math]::Round($pos.stop0, 6); liqPx = [math]::Round($pos.liqPx, 6)
                    exitOpen = [math]::Round($lc, 6); reason = 'challenge-stop'; barsHeld = $pos.barsHeld
                    riskUsd = [math]::Round($pos.riskUsd, 2); score = [math]::Round($pos.score, 3)
                    feeUsd = [math]::Round($pos.entryFee + $exitFee, 2); fundUsd = [math]::Round($pos.fund, 2)
                    pnlUsd = [math]::Round($tradePnl, 2); eqAfter = [math]::Round($equity, 2)
                })
                $pos = $null
            }
        }
    }
}

# close any remaining open position at the last in-window bar
if ($null -ne $pos) {
    $sym = $pos.sym; $lc = $lastClose[$sym]; $side = $pos.side
    if (-not [double]::IsNaN($lc)) {
        $exitPx = $lc * (1 - $side * $SlipPct)
        $pnlRaw = $side * $pos.qty * ($exitPx - $pos.entry)
        $exitFee = $pos.qty * $exitPx * $FeePct
        $pnlNet = $pnlRaw - $exitFee + $pos.fund
        $equity += $pnlNet
        $tradePnl = $pnlNet - $pos.entryFee
        if ($tradePnl -gt 0) { $grossProfit += $tradePnl } else { $grossLoss += - $tradePnl }
        $totFees += $pos.entryFee + $exitFee; $totFund += $pos.fund
        $sideTxt = 'short'; if ($side -gt 0) { $sideTxt = 'long' }
        $trades.Add(@{
            sym = $sym; side = $sideTxt; tsIn = (New-IsoUtc $pos.entryTs); tsOut = 'eod'
            entryDay = $pos.entryDay; entry = [math]::Round($pos.entry, 6); exit = [math]::Round($exitPx, 6)
            qty = [math]::Round($pos.qty, 6); notional = [math]::Round($pos.qty * $pos.entry, 2)
            levEff = [math]::Round($pos.levEff, 2); marginUsd = [math]::Round($pos.margin, 2)
            stop0 = [math]::Round($pos.stop0, 6); liqPx = [math]::Round($pos.liqPx, 6)
            exitOpen = [math]::Round($lc, 6); reason = 'eod'; barsHeld = $pos.barsHeld
            riskUsd = [math]::Round($pos.riskUsd, 2); score = [math]::Round($pos.score, 3)
            feeUsd = [math]::Round($pos.entryFee + $exitFee, 2); fundUsd = [math]::Round($pos.fund, 2)
            pnlUsd = [math]::Round($tradePnl, 2); eqAfter = [math]::Round($equity, 2)
        })
        $pos = $null
    }
}

# ---------- metrics ----------
$nTr = $trades.Count
$wins = 0; $longs = 0
foreach ($tr in $trades) {
    if ($tr.pnlUsd -gt 0) { $wins++ }
    if ($tr.side -eq 'long') { $longs++ }
}
$pf = 0.0
if ($grossLoss -gt 0) { $pf = $grossProfit / $grossLoss } elseif ($grossProfit -gt 0) { $pf = 999 }
$peak = $StartEquity; $maxDD = 0.0
foreach ($dd in $dailies) {
    if ($dd.eq -gt $peak) { $peak = $dd.eq }
    $ddPct = ($peak - $dd.eq) / $peak
    if ($ddPct -gt $maxDD) { $maxDD = $ddPct }
}
$nDays = $dailies.Count
$tpd = 0.0; if ($nDays -gt 0) { $tpd = $nTr / [double]$nDays }
$totRet = ($equity / $StartEquity - 1) * 100
$grossAbs = $grossProfit + $grossLoss
$costShare = 0.0; if ($grossAbs -gt 0) { $costShare = 100.0 * ($totFees + [math]::Abs($totFund)) / $grossAbs }
$winRate = 0.0; if ($nTr -gt 0) { $winRate = 100.0 * $wins / $nTr }

$fromTxt = $FromDate; $toTxt = $ToDate; if (-not $toTxt) { $toTxt = (New-IsoUtc $endTs).Substring(0,10) }

# ---------- artifacts ----------
$sumObj = @{
    tag = $Tag; setup = $Setup; exitMode = $ExitMode; breakN = $BreakN
    atrStopMult = $AtrStopMult; trailMult = $TrailMult
    riskPct = $RiskPct; levTarget = $LevTarget; longOnly = [bool]$LongOnly
    from = $fromTxt; to = $toTxt; days = $nDays
    trades = $nTr; longs = $longs; shorts = ($nTr - $longs)
    tradesPerDay = [math]::Round($tpd, 3)
    totalReturnPct = [math]::Round($totRet, 1)
    finalEquity = [math]::Round($equity, 2)
    profitFactor = [math]::Round($pf, 3)
    winRatePct = [math]::Round($winRate, 1)
    maxDDPct = [math]::Round($maxDD * 100, 1)
    liquidations = $liqCount
    feesUsd = [math]::Round($totFees, 2); fundingUsd = [math]::Round($totFund, 2)
    costSharePct = [math]::Round($costShare, 1)
    challengeHaltDay = $haltDay
    exitReasons = $exitReasons
    loadSec = [math]::Round($tLoad, 1); preSec = [math]::Round($tPre, 1)
    totalSec = [math]::Round($swAll.Elapsed.TotalSeconds, 1)
}
$trArr = @($trades.ToArray())
$dlArr = @($dailies.ToArray())
[System.IO.File]::WriteAllText((Join-Path $OutDir "bt_${Tag}_trades.json"), (ConvertTo-Json $trArr -Compress -Depth 5), [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText((Join-Path $OutDir "bt_${Tag}_daily.json"),  (ConvertTo-Json $dlArr -Compress -Depth 5), [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText((Join-Path $OutDir "bt_${Tag}_summary.json"), (ConvertTo-Json $sumObj -Compress -Depth 5), [System.Text.Encoding]::UTF8)

if (-not $Quiet) {
    Write-Host ("CFG: {0} setup={1} exit={2} breakN={3} risk={4}% lev={5}x stopATR={6}" -f $Tag, $Setup, $ExitMode, $BreakN, ($RiskPct*100), $LevTarget, $AtrStopMult)
    Write-Host ("Period: {0} -> {1} ({2} days)" -f $fromTxt, $toTxt, $nDays)
    Write-Host ("Trades: {0} (long {1} / short {2})" -f $nTr, $longs, ($nTr - $longs))
    Write-Host ("Trades/day: {0:n2}" -f $tpd)
    Write-Host ("Total return: {0:n1}%" -f $totRet)
    Write-Host ("Final equity: {0:n2}" -f $equity)
    Write-Host ("Profit factor: {0:n3}" -f $pf)
    Write-Host ("Win rate: {0:n1}%" -f $winRate)
    Write-Host ("Max drawdown: {0:n1}%" -f ($maxDD * 100))
    Write-Host ("Liquidations: {0}" -f $liqCount)
    Write-Host ("Fees {0:n2} / funding {1:n2} (costs = {2:n1}% of gross)" -f $totFees, $totFund, $costShare)
    if ($haltDay) { Write-Host ("CHALLENGE STOP hit on {0}" -f $haltDay) }
    Write-Host ("Timing: load {0:n1}s, precompute {1:n1}s, total {2:n1}s" -f $tLoad, $tPre, $swAll.Elapsed.TotalSeconds)
}
