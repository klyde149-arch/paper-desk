# Portfolio backtest of the trend-pullback strategy on cached 4h data.
# Mechanical version of docs\strategy\strategy.md setup A (trend pullback), risk 1%/trade,
# TP1 1.5R (close half) -> stop to breakeven -> trail EMA20, F&G filter, honest costs.
param(
  [string[]]$Symbols = @('BTC-USDT','ETH-USDT','SOL-USDT','BNB-USDT','XRP-USDT','DOGE-USDT','ADA-USDT','AVAX-USDT','LINK-USDT',
                         'DOT-USDT','LTC-USDT','BCH-USDT','UNI-USDT','ATOM-USDT','NEAR-USDT','OP-USDT','APT-USDT','ARB-USDT','SUI-USDT','AAVE-USDT'),
  [double]$StartEquity = 10000,
  [double]$RiskPct = 0.01,
  [double]$MaxLev = 5,
  [int]$MaxConcurrent = 3,
  [double]$FeePct = 0.0005,      # taker per side
  [double]$SlipPct = 0.0003,     # market entry slippage
  [double]$StopSlipPct = 0.0005, # extra slippage on stop fills
  [double]$FundingPerBar = 0.00005, # ~0.01%/8h -> per 4h bar drag on notional
  [double]$RewardR = 1.5,        # TP1 at 1.5R
  [double]$Tp1ClosePct = 0.5,    # fraction closed at TP1 (1.0 = close ALL at TP, no runner)
  [switch]$NoTp1,                # no TP at all: pure EMA20-close trail from entry (stop never moves to BE)
  [int]$PullbackLookback = 3,
  [double]$DailyLossHaltPct = 0.03,
  [double]$MaxDDFlagPct = 0.08,
  [switch]$BtcFilter,      # longs only if BTC trend != down; shorts only if BTC trend != up
  [switch]$HardHalt,       # permanently stop NEW entries once DD >= MaxDDFlagPct
  [string]$FromDate,       # yyyy-MM-dd: trade only bars from this UTC date (indicators still warm up on full history)
  [string]$ToDate,         # yyyy-MM-dd: trade only bars up to this UTC date
  [switch]$EqCurveFilter,  # scale risk by strategy's own recent PF (last 20 closed trades): PF<1 -> x0.5, PF<0.7 -> x0.25 probe
  [switch]$RangeSetup,     # setup B: mean-reversion off 30-bar range boundaries when regime is range (not up/down)
  [double]$MinAtrPct = 0,  # skip entries when ATR14 < this % of price (low-vol chop; 0 = off)
  [double]$MaxAtrPct = 0,  # skip entries when ATR14 > this % of price (overheated moves; 0 = off)
  [double]$AtrStopMult = 1.0, # stop distance floor = this x ATR14 (vol-normalized stops)
  [string]$FlatMode = 'off',  # reaction when index (BTC) regime is flat: off | skip | halfrisk | deeprsi
  [double]$FlatGapPct = 0,    # flat detector override: |EMA20-EMA50|/price*100 < this => flat (0 = flat when index regime == 'range')
  [double]$SlopePctMin = 0,   # per-asset trend strength: require |EMA50 slope| over 10 bars >= this % (0 = off)
  [double]$TrendGapPctMin = 0,# per-asset trend width: require |EMA20-EMA50|/price*100 >= this at entry (0 = off)
  [double]$MaxExtAtr = 0,     # anti-chase: skip setup-A entries when (close-EMA20)/ATR14 > this in trend direction (0 = off)
  [double]$RsiMaxLong = 0,    # anti-chase: skip setup-A longs when entry-bar RSI14 > this; shorts mirrored at (100 - this) (0 = off)
  [double]$BtcMomMaxLong = 0, # 2026-07 anatomy: skip setup-A longs when index 5d momentum (30 bars) >= this % (0 = off)
  [double]$MaxAtrPctLong = 0, # 2026-07 anatomy: long-only ATR cap - skip setup-A longs when ATR14 > this % of price (0 = off)
  [switch]$EarlyExit,         # v2: close position when 4h close crosses EMA50 against it (regime broken - don't wait for stop)
  [string]$FundingDir = '',   # v2: dir with SYM_funding.json ([{t,r}]) -> real funding costs instead of flat FundingPerBar
  [switch]$FundingFilter,     # v2: block new longs when funding > +0.05%/8h, shorts when < -0.05%/8h (needs FundingDir)
  [switch]$RangeV2,           # v2: range-fade setup, only when index (BTC) regime is 'range' (flat-market strategy)
  [switch]$Breakout,          # Donchian breakout setup (futures/commodity trend model); replaces setup A when on
  [int]$BreakoutN = 20,       # Donchian channel lookback (bars)
  [double]$AtrTrailMult = 0,  # breakout exit: chandelier ATR trail from MFE extreme (0 = default TP1+EMA20-trail path)
  [int]$ReArmN = 0,           # breakout re-entry: after a breakout exit, same-direction close beyond the ReArmN-bar channel re-enters (0 = off)
  [int]$ReArmBars = 15,       # re-entry window length (bars after the exit)
  [string]$DataDir = 'C:\Users\klyde\trading-sim\data',
  [string]$FileSuffix = '_4h',       # candle file suffix: crypto '_4h', MOEX '_1d'
  [string]$IndexSymbol = 'BTC-USDT', # regime-filter instrument (loaded even if not traded)
  [switch]$LongOnly,                 # no shorts (stock market profile)
  [switch]$NoFng,                    # skip Fear&Greed filter (crypto-specific)
  [int]$WarmupBars = 205             # bars skipped before first entry
)
$ErrorActionPreference = 'Stop'
$dir = $DataDir

function EMAseries([double[]]$v, [int]$p) {
  $n = $v.Count; $out = New-Object 'double[]' $n
  $k = 2.0 / ($p + 1); $sum = 0.0
  for ($i = 0; $i -lt $n; $i++) {
    if ($i -lt $p) { $sum += $v[$i]; $out[$i] = [double]::NaN; if ($i -eq $p-1){ $out[$i] = $sum/$p } }
    else { $out[$i] = $v[$i]*$k + $out[$i-1]*(1-$k) }
  }
  return $out
}
function RSIseries([double[]]$v, [int]$p) {
  $n = $v.Count; $out = New-Object 'double[]' $n
  for ($i=0;$i -lt $n;$i++){ $out[$i]=[double]::NaN }
  if ($n -le $p+1) { return $out }
  $g=0.0;$l=0.0
  for ($i=1;$i -le $p;$i++){ $d=$v[$i]-$v[$i-1]; if($d -gt 0){$g+=$d}else{$l-=$d} }
  $ag=$g/$p;$al=$l/$p
  $out[$p] = if($al -eq 0){100}else{100-100/(1+$ag/$al)}
  for ($i=$p+1;$i -lt $n;$i++){
    $d=$v[$i]-$v[$i-1]; $gg=0.0;$ll=0.0; if($d -gt 0){$gg=$d}else{$ll=-$d}
    $ag=($ag*($p-1)+$gg)/$p; $al=($al*($p-1)+$ll)/$p
    $out[$i]= if($al -eq 0){100}else{100-100/(1+$ag/$al)}
  }
  return $out
}
function ATRseries([double[]]$h,[double[]]$l,[double[]]$c,[int]$p){
  $n=$c.Count; $tr=New-Object 'double[]' $n; $out=New-Object 'double[]' $n
  for($i=0;$i -lt $n;$i++){
    if($i -eq 0){$tr[$i]=$h[$i]-$l[$i]}
    else{ $tr[$i]=[math]::Max($h[$i]-$l[$i],[math]::Max([math]::Abs($h[$i]-$c[$i-1]),[math]::Abs($l[$i]-$c[$i-1]))) }
    $out[$i]=[double]::NaN
  }
  $sum=0.0
  for($i=0;$i -lt $p;$i++){$sum+=$tr[$i]}
  $out[$p-1]=$sum/$p
  for($i=$p;$i -lt $n;$i++){ $out[$i]=($out[$i-1]*($p-1)+$tr[$i])/$p }
  return $out
}

# ---- load F&G, map day->value ----
$fng = @{}
if ((-not $NoFng) -and (Test-Path (Join-Path $dir 'fng.json'))) {
  $fj = Get-Content (Join-Path $dir 'fng.json') -Raw | ConvertFrom-Json
  foreach ($d in $fj) {
    $day = [DateTimeOffset]::FromUnixTimeSeconds([long]$d.ts).UtcDateTime.ToString('yyyy-MM-dd')
    $fng[$day] = [int]$d.v
  }
}

# ---- load symbols, precompute indicators (index instrument loaded too) ----
$S = @{}
$loadList = @($Symbols)
if ($loadList -notcontains $IndexSymbol) { $loadList += $IndexSymbol }
foreach ($sym in $loadList) {
  $path = Join-Path $dir "$($sym.Replace('-','_'))$FileSuffix.json"
  if (-not (Test-Path $path)) { Write-Warning "no data $sym"; continue }
  $bars = Get-Content $path -Raw | ConvertFrom-Json
  $o=[double[]]($bars.o); $h=[double[]]($bars.h); $l=[double[]]($bars.l); $c=[double[]]($bars.c); $t=[long[]]($bars.t)
  $S[$sym] = @{
    t=$t; o=$o; h=$h; l=$l; c=$c
    ema20=EMAseries $c 20; ema50=EMAseries $c 50; ema200=EMAseries $c 200
    rsi=RSIseries $c 14; atr=ATRseries $h $l $c 14
    idx=@{}  # timestamp -> index
  }
  for ($i=0;$i -lt $t.Count;$i++){ $S[$sym].idx[$t[$i]] = $i }
}

# ---- real funding history (optional): sym -> hashtable[fundingTs] = rate ----
$FUND = @{}
if ($FundingDir) {
  foreach ($sym in $Symbols) {
    $fp = Join-Path $FundingDir "$($sym.Replace('-','_'))_funding.json"
    if (-not (Test-Path $fp)) { Write-Warning "no funding data $sym"; continue }
    $fh = @{}
    foreach ($f in ((Get-Content $fp -Raw | ConvertFrom-Json) | ForEach-Object {$_})) { $fh[[long]$f.t] = [double]$f.r }
    $FUND[$sym] = $fh
  }
}
# latest funding rate at/before ts (funding events sit on 8h boundaries)
function FundingRateAt([string]$sym, [long]$ts) {
  if (-not $FUND.ContainsKey($sym)) { return $null }
  $slot = $ts - ($ts % 28800000)
  for ($k=0; $k -lt 3; $k++) {
    if ($FUND[$sym].ContainsKey($slot)) { return $FUND[$sym][$slot] }
    $slot -= 28800000
  }
  return $null
}

# ---- common timeline ----
$allTs = New-Object System.Collections.Generic.SortedSet[long]
foreach ($sym in $S.Keys) { foreach ($tt in $S[$sym].t) { [void]$allTs.Add($tt) } }
$timeline = @($allTs)
if ($FromDate) {
  $fromMs = [long]([DateTimeOffset]::new([datetime]::SpecifyKind([datetime]$FromDate,'Utc'))).ToUnixTimeMilliseconds()
  $timeline = @($timeline | Where-Object { $_ -ge $fromMs })
}
if ($ToDate) {
  $toMs = [long]([DateTimeOffset]::new([datetime]::SpecifyKind([datetime]$ToDate,'Utc'))).ToUnixTimeMilliseconds()
  $timeline = @($timeline | Where-Object { $_ -le $toMs })
}

# build a rich trade record: legacy fields unchanged + entry context, MFE/MAE (R), bars held
function New-TradeRecord($sym, $p, $exitDay, $reason, $fill, $exitTs, $btcExit) {
  $sd = $p.stopDist0
  $mfeR = $null; $maeR = $null
  if ($sd -gt 0 -and $null -ne $p.mfePx) {
    if ($p.side -eq 'long') { $mfeR = [math]::Round(($p.mfePx - $p.entry) / $sd, 2); $maeR = [math]::Round(($p.entry - $p.maePx) / $sd, 2) }
    else                    { $mfeR = [math]::Round(($p.entry - $p.mfePx) / $sd, 2); $maeR = [math]::Round(($p.maePx - $p.entry) / $sd, 2) }
  }
  [pscustomobject]@{
    sym=$sym; side=$p.side; entryDay=$p.entryDay; exitDay=$exitDay
    entry=[math]::Round($p.entryRaw,6); exitReason=$reason
    pnlUsd=[math]::Round($p.realized,2); tp1done=[bool]$p.tp1done
    entryTs=$p.entryTs; exitTs=$exitTs; exitPx=[math]::Round($fill,6)
    stop0=[math]::Round($p.stop0,6); tp1px=[math]::Round($p.tp1,6)
    stopDistPct=[math]::Round(100*$sd/$p.entry,3)
    atrPct=$p.atrPct; rsiEntry=$p.rsiEntry
    distEma20Pct=$p.distE20; distEma50Pct=$p.distE50
    btcTrendEntry=$p.btcEntry; btcTrendExit=$btcExit
    fgEntry=$p.fgEntry; riskUsd=$p.riskUsd
    mfeR=$mfeR; maeR=$maeR; barsHeld=$p.bars
  }
}

# ---- portfolio state ----
$equity = $StartEquity; $peak = $StartEquity
$dayStartEquity = $StartEquity; $curDay = $null; $haltDay = $false
$open = @{}   # sym -> position hashtable
$reArm = @{}  # sym -> @{exitIdx; dir} set on breakout exits; arms the -ReArmN re-entry window
$trades = New-Object System.Collections.Generic.List[object]
$equityCurve = New-Object System.Collections.Generic.List[object]
$maxDD = 0.0; $ddBreached = $false; $ddBreachDate = $null
$warmup = $WarmupBars

foreach ($ts in $timeline) {
  $day = [DateTimeOffset]::FromUnixTimeMilliseconds($ts).UtcDateTime.ToString('yyyy-MM-dd')
  if ($day -ne $curDay) { $curDay = $day; $dayStartEquity = $equity; $haltDay = $false }
  $fgVal = if ($fng.ContainsKey($day)) { $fng[$day] } else { $null }

  # index (BTC/IMOEX) regime at this bar - entry filter + trade context + flat detector
  $idxTrend = 'range'; $idxGapPct = $null; $idxMom5 = $null
  if ($S.ContainsKey($IndexSymbol) -and $S[$IndexSymbol].idx.ContainsKey($ts)) {
    $bi=$S[$IndexSymbol].idx[$ts]; $bc=$S[$IndexSymbol].c[$bi]; $be20=$S[$IndexSymbol].ema20[$bi]; $be50=$S[$IndexSymbol].ema50[$bi]
    if (-not [double]::IsNaN($be50)) {
      if(($bc -gt $be50)-and($be20 -gt $be50)){$idxTrend='up'}elseif(($bc -lt $be50)-and($be20 -lt $be50)){$idxTrend='down'}
      $idxGapPct = 100*[math]::Abs($be20-$be50)/$bc
    }
    if ($bi -ge 30) { $idxMom5 = 100*($bc/$S[$IndexSymbol].c[$bi-30] - 1) }
  }

  # ---------- 1) manage open positions on this bar ----------
  foreach ($sym in @($open.Keys)) {
    $p = $open[$sym]
    if (-not $S[$sym].idx.ContainsKey($ts)) { continue }
    $i = $S[$sym].idx[$ts]
    if ($i -le $p.entryIdx) { continue }   # no management on entry bar
    $hi=$S[$sym].h[$i]; $lo=$S[$sym].l[$i]; $cl=$S[$sym].c[$i]; $e20=$S[$sym].ema20[$i]; $opn=$S[$sym].o[$i]
    # funding on notional held: real history (event on this bar's open) or flat per-bar drag
    if ($FundingDir -and $FUND.ContainsKey($sym)) {
      if ($FUND[$sym].ContainsKey($ts)) {
        $rate = $FUND[$sym][$ts]
        $fpay = $p.qty * $cl * $rate
        if ($p.side -eq 'long') { $equity -= $fpay; $p.realized -= $fpay }
        else                    { $equity += $fpay; $p.realized += $fpay }
      }
    } else {
      $fdrag = $p.qty * $p.entry * $FundingPerBar
      $equity -= $fdrag; $p.realized -= $fdrag
    }
    # MFE/MAE + holding time tracking
    $p.bars++
    if ($p.side -eq 'long') { if($hi -gt $p.mfePx){$p.mfePx=$hi}; if($lo -lt $p.maePx){$p.maePx=$lo} }
    else                    { if($lo -lt $p.mfePx){$p.mfePx=$lo}; if($hi -gt $p.maePx){$p.maePx=$hi} }
    $exited = $false

    if ($p.range) {  # setup B position: fixed stop, full exit at target, no trailing
      if ($p.side -eq 'long') {
        if ($lo -le $p.stop) { $fill=([math]::Min($p.stop,$opn))*(1-$StopSlipPct); $pnl=($fill-$p.entry)*$p.qty - $fill*$p.qty*$FeePct; $equity+=$pnl; $p.realized+=$pnl; $exited=$true; $reason='range-stop' }
        elseif ($hi -ge $p.tp1) { $fill=$p.tp1; $pnl=($fill-$p.entry)*$p.qty - $fill*$p.qty*$FeePct; $equity+=$pnl; $p.realized+=$pnl; $exited=$true; $reason='range-tp' }
      } else {
        if ($hi -ge $p.stop) { $fill=([math]::Max($p.stop,$opn))*(1+$StopSlipPct); $pnl=($p.entry-$fill)*$p.qty - $fill*$p.qty*$FeePct; $equity+=$pnl; $p.realized+=$pnl; $exited=$true; $reason='range-stop' }
        elseif ($lo -le $p.tp1) { $fill=$p.tp1; $pnl=($p.entry-$fill)*$p.qty - $fill*$p.qty*$FeePct; $equity+=$pnl; $p.realized+=$pnl; $exited=$true; $reason='range-tp' }
      }
      if ($exited) {
        $trades.Add((New-TradeRecord $sym $p $day $reason $fill $ts $idxTrend))
        $open.Remove($sym)
      }
      continue
    }

    if ($p.bo -and $AtrTrailMult -gt 0) {  # breakout position, chandelier mode: pure ATR trail, no TP1
      # check stop at the pre-update level first (no intrabar lookahead), then ratchet for the next bar
      if ($p.side -eq 'long') {
        if ($lo -le $p.stop) { $fill=([math]::Min($p.stop,$opn))*(1-$StopSlipPct); $pnl=($fill-$p.entry)*$p.qty - $fill*$p.qty*$FeePct; $equity+=$pnl; $p.realized+=$pnl; $exited=$true; $reason=if($fill -gt $p.entry){'atr-trail'}else{'stop'} }
      } else {
        if ($hi -ge $p.stop) { $fill=([math]::Max($p.stop,$opn))*(1+$StopSlipPct); $pnl=($p.entry-$fill)*$p.qty - $fill*$p.qty*$FeePct; $equity+=$pnl; $p.realized+=$pnl; $exited=$true; $reason=if($fill -lt $p.entry){'atr-trail'}else{'stop'} }
      }
      if ($exited) {
        $trades.Add((New-TradeRecord $sym $p $day $reason $fill $ts $idxTrend))
        $open.Remove($sym)
        if ($ReArmN -gt 0) { $reArm[$sym] = @{ exitIdx=$i; dir=$p.side } }  # arm re-entry window
      } else {
        $atrNow = $S[$sym].atr[$i]
        if (-not [double]::IsNaN($atrNow)) {
          if ($p.side -eq 'long') { $ns = $p.mfePx - $AtrTrailMult*$atrNow; if ($ns -gt $p.stop) { $p.stop = $ns } }
          else                    { $ns = $p.mfePx + $AtrTrailMult*$atrNow; if ($ns -lt $p.stop) { $p.stop = $ns } }
        }
      }
      continue
    }

    if ($p.side -eq 'long') {
      $stopHit = ($lo -le $p.stop)
      $tpHit = (-not $NoTp1) -and (-not $p.tp1done) -and ($hi -ge $p.tp1)
      if ($stopHit) {
        $fill = ([math]::Min($p.stop, $opn)) * (1 - $StopSlipPct)   # gap-aware: fill at open when bar opens beyond the stop
        $pnl = ($fill - $p.entry) * $p.qty - $fill*$p.qty*$FeePct
        $equity += $pnl; $p.realized += $pnl; $exited=$true; $reason=if($p.tp1done){'trail-stop/BE'}else{'stop'}
      }
      elseif ($tpHit) {
        if ($Tp1ClosePct -ge 1.0) {   # full take-profit: close everything at TP, no runner
          $fill = $p.tp1
          $pnl = ($fill - $p.entry)*$p.qty - $fill*$p.qty*$FeePct
          $equity += $pnl; $p.realized += $pnl; $exited=$true; $reason='tp-full'
        } else {
          $half = $p.qty * $Tp1ClosePct
          $fill = $p.tp1
          $pnl = ($fill - $p.entry)*$half - $fill*$half*$FeePct
          $equity += $pnl; $p.realized += $pnl
          $p.qty -= $half; $p.tp1done=$true; $p.stop=$p.entry  # BE
        }
      }
      if (-not $exited -and ($p.tp1done -or $NoTp1) -and ($cl -lt $e20)) {
        $fill = $cl * (1 - $SlipPct)
        $pnl = ($fill - $p.entry)*$p.qty - $fill*$p.qty*$FeePct
        $equity += $pnl; $p.realized += $pnl
        $exited=$true; $reason='trail-EMA20'
      }
      if (-not $exited -and $EarlyExit) {
        $e50m = $S[$sym].ema50[$i]
        if (-not [double]::IsNaN($e50m) -and $cl -lt $e50m) {
          $fill = $cl * (1 - $SlipPct)
          $pnl = ($fill - $p.entry)*$p.qty - $fill*$p.qty*$FeePct
          $equity += $pnl; $p.realized += $pnl
          $exited=$true; $reason='early-exit'
        }
      }
    } else {
      $stopHit = ($hi -ge $p.stop)
      $tpHit = (-not $NoTp1) -and (-not $p.tp1done) -and ($lo -le $p.tp1)
      if ($stopHit) {
        $fill = ([math]::Max($p.stop, $opn)) * (1 + $StopSlipPct)   # gap-aware: fill at open when bar opens beyond the stop
        $pnl = ($p.entry - $fill) * $p.qty - $fill*$p.qty*$FeePct
        $equity += $pnl; $p.realized += $pnl; $exited=$true; $reason=if($p.tp1done){'trail-stop/BE'}else{'stop'}
      }
      elseif ($tpHit) {
        if ($Tp1ClosePct -ge 1.0) {   # full take-profit: close everything at TP, no runner
          $fill = $p.tp1
          $pnl = ($p.entry - $fill)*$p.qty - $fill*$p.qty*$FeePct
          $equity += $pnl; $p.realized += $pnl; $exited=$true; $reason='tp-full'
        } else {
          $half = $p.qty * $Tp1ClosePct; $fill=$p.tp1
          $pnl = ($p.entry - $fill)*$half - $fill*$half*$FeePct
          $equity += $pnl; $p.realized += $pnl
          $p.qty -= $half; $p.tp1done=$true; $p.stop=$p.entry
        }
      }
      if (-not $exited -and ($p.tp1done -or $NoTp1) -and ($cl -gt $e20)) {
        $fill = $cl * (1 + $SlipPct)
        $pnl = ($p.entry - $fill)*$p.qty - $fill*$p.qty*$FeePct
        $equity += $pnl; $p.realized += $pnl
        $exited=$true; $reason='trail-EMA20'
      }
      if (-not $exited -and $EarlyExit) {
        $e50m = $S[$sym].ema50[$i]
        if (-not [double]::IsNaN($e50m) -and $cl -gt $e50m) {
          $fill = $cl * (1 + $SlipPct)
          $pnl = ($p.entry - $fill)*$p.qty - $fill*$p.qty*$FeePct
          $equity += $pnl; $p.realized += $pnl
          $exited=$true; $reason='early-exit'
        }
      }
    }

    if ($exited) {
      $trades.Add((New-TradeRecord $sym $p $day $reason $fill $ts $idxTrend))
      $open.Remove($sym)
      if ($ReArmN -gt 0 -and $p.bo) { $reArm[$sym] = @{ exitIdx=$i; dir=$p.side } }  # arm re-entry window
    }
  }

  # update equity curve + drawdown (mark-to-market open positions)
  $mtm = $equity
  foreach ($sym in $open.Keys) {
    $p=$open[$sym]; if(-not $S[$sym].idx.ContainsKey($ts)){continue}
    $cl=$S[$sym].c[$S[$sym].idx[$ts]]
    if($p.side -eq 'long'){ $mtm += ($cl-$p.entry)*$p.qty } else { $mtm += ($p.entry-$cl)*$p.qty }
  }
  if ($mtm -gt $peak) { $peak = $mtm }
  $dd = if($peak -gt 0){ ($peak-$mtm)/$peak } else {0}
  if ($dd -gt $maxDD) { $maxDD = $dd }
  if ($dd -ge $MaxDDFlagPct -and -not $ddBreached) { $ddBreached=$true; $ddBreachDate=$day }
  if ($HardHalt -and $dd -ge $MaxDDFlagPct) {
    foreach ($sym in @($open.Keys)) {  # flatten at this bar's close
      $p=$open[$sym]; if(-not $S[$sym].idx.ContainsKey($ts)){continue}
      $cl=$S[$sym].c[$S[$sym].idx[$ts]]
      if($p.side -eq 'long'){ $pnl=($cl*(1-$SlipPct)-$p.entry)*$p.qty - $cl*$p.qty*$FeePct } else { $pnl=($p.entry-$cl*(1+$SlipPct))*$p.qty - $cl*$p.qty*$FeePct }
      $equity+=$pnl; $p.realized+=$pnl
      $trades.Add((New-TradeRecord $sym $p $day 'hard-halt-8pct' $cl $ts $idxTrend))
    }
    $open.Clear()
    $equityCurve.Add([pscustomobject]@{ day=$day; ts=$ts; equity=[math]::Round($equity,2) })
    $haltedHard=$true; break
  }
  if ((($dayStartEquity - $mtm)/$dayStartEquity) -ge $DailyLossHaltPct) { $haltDay = $true }
  $equityCurve.Add([pscustomobject]@{ day=$day; ts=$ts; equity=[math]::Round($mtm,2) })

  # ---------- 2) look for new entries ----------
  if ($haltDay) { continue }
  if ($open.Count -ge $MaxConcurrent) { continue }

  # equity-curve filter: risk multiplier from PF of last 20 closed trades (never 0 - probe trades keep the window rolling)
  $riskMult = 1.0
  if ($EqCurveFilter -and $trades.Count -ge 10) {
    $tail = $trades | Select-Object -Last 20
    $tw = ($tail | Where-Object {$_.pnlUsd -gt 0} | Measure-Object pnlUsd -Sum).Sum
    $tl = [math]::Abs(($tail | Where-Object {$_.pnlUsd -le 0} | Measure-Object pnlUsd -Sum).Sum)
    if ($null -eq $tw) { $tw = 0 }
    $pf20 = if ($tl -gt 0) { $tw / $tl } else { 99 }
    if ($pf20 -lt 0.7) { $riskMult = 0.25 } elseif ($pf20 -lt 1.0) { $riskMult = 0.5 }
  }

  # index regime at this bar (computed above once per bar): BTC for crypto, IMOEX for MOEX
  $btcTrend = $idxTrend

  # flat-regime reaction (research switch, default off)
  $rsiCoolTh = 50.0; $rsiHotTh = 50.0
  if ($FlatMode -ne 'off') {
    $isFlat = if ($FlatGapPct -gt 0) { ($null -ne $idxGapPct) -and ($idxGapPct -lt $FlatGapPct) } else { $idxTrend -eq 'range' }
    if ($isFlat) {
      if ($FlatMode -eq 'skip')     { continue }          # no new entries while index is flat
      if ($FlatMode -eq 'halfrisk') { $riskMult *= 0.5 }  # half risk while flat
      if ($FlatMode -eq 'deeprsi')  { $rsiCoolTh = 40.0; $rsiHotTh = 60.0 }  # demand deeper pullback
    }
  }

  foreach ($sym in $Symbols) {
    if (-not $S.ContainsKey($sym)) { continue }
    if ($open.ContainsKey($sym)) { continue }
    if ($open.Count -ge $MaxConcurrent) { break }
    if (-not $S[$sym].idx.ContainsKey($ts)) { continue }
    $i = $S[$sym].idx[$ts]
    if ($i -lt $warmup) { continue }

    $cl=$S[$sym].c[$i]; $op=$S[$sym].o[$i]; $e20=$S[$sym].ema20[$i]; $e50=$S[$sym].ema50[$i]; $rsi=$S[$sym].rsi[$i]; $atr=$S[$sym].atr[$i]
    if ([double]::IsNaN($e50) -or [double]::IsNaN($atr)) { continue }
    if ($MinAtrPct -gt 0 -and (100*$atr/$cl) -lt $MinAtrPct) { continue }
    if ($MaxAtrPct -gt 0 -and (100*$atr/$cl) -gt $MaxAtrPct) { continue }

    $up = ($cl -gt $e50) -and ($e20 -gt $e50)
    $down = ($cl -lt $e50) -and ($e20 -lt $e50)

    # funding-extreme filter (v2): overheated longs / shorts
    $frNow = $null; $fundOkL = $true; $fundOkS = $true
    if ($FundingFilter -and $FundingDir) {
      $frNow = FundingRateAt $sym $ts
      if ($null -ne $frNow) { $fundOkL = ($frNow -le 0.0005); $fundOkS = ($frNow -ge -0.0005) }
    }

    # per-asset trend strength / width research filters (default off)
    $slopeOk = $true; $gapOk = $true
    if ($SlopePctMin -gt 0 -and $i -ge 10 -and -not [double]::IsNaN($S[$sym].ema50[$i-10])) {
      $slope = 100*($e50 - $S[$sym].ema50[$i-10])/$S[$sym].ema50[$i-10]
      if ($up)   { $slopeOk = ($slope -ge $SlopePctMin) }
      if ($down) { $slopeOk = ($slope -le -$SlopePctMin) }
    }
    if ($TrendGapPctMin -gt 0) { $gapOk = (100*[math]::Abs($e20-$e50)/$cl) -ge $TrendGapPctMin }

    # anti-chase research filters (default off), setup A only: entry-bar extension from EMA20 and RSI cap
    $extOk = $true; $rsiCapOk = $true
    if ($MaxExtAtr -gt 0 -and $atr -gt 0) {
      if ($up)       { $extOk = ((($cl - $e20) / $atr) -le $MaxExtAtr) }
      elseif ($down) { $extOk = ((($e20 - $cl) / $atr) -le $MaxExtAtr) }
    }
    if ($RsiMaxLong -gt 0 -and -not [double]::IsNaN($rsi)) {
      if ($up)       { $rsiCapOk = ($rsi -le $RsiMaxLong) }
      elseif ($down) { $rsiCapOk = ($rsi -ge (100 - $RsiMaxLong)) }
    }

    # 2026-07 anatomy filters (default off), setup-A LONGS only: overheated-index block + long ATR cap
    $momOkL = $true; $atrOkL = $true
    if ($BtcMomMaxLong -gt 0 -and $null -ne $idxMom5) { $momOkL = ($idxMom5 -lt $BtcMomMaxLong) }
    if ($MaxAtrPctLong -gt 0) { $atrOkL = ((100*$atr/$cl) -le $MaxAtrPctLong) }

    # Donchian breakout setup (-Breakout replaces setup A): close breaks the N-bar channel
    if ($Breakout) {
      if ($i -lt ($BreakoutN + 1)) { continue }
      $chHi = ($S[$sym].h[($i-$BreakoutN)..($i-1)] | Measure-Object -Maximum).Maximum
      $chLo = ($S[$sym].l[($i-$BreakoutN)..($i-1)] | Measure-Object -Minimum).Minimum
      # re-entry window (-ReArmN): after a breakout exit the SAME direction re-triggers on a shorter channel
      if ($ReArmN -gt 0 -and $reArm.ContainsKey($sym) -and $i -ge ($ReArmN + 1)) {
        $ra = $reArm[$sym]; $dEx = $i - $ra.exitIdx
        if ($dEx -ge 1 -and $dEx -le $ReArmBars) {
          if ($ra.dir -eq 'long') { $chHi = ($S[$sym].h[($i-$ReArmN)..($i-1)] | Measure-Object -Maximum).Maximum }
          else                    { $chLo = ($S[$sym].l[($i-$ReArmN)..($i-1)] | Measure-Object -Minimum).Minimum }
        }
      }
      $stopDist = $AtrStopMult * $atr
      if ($stopDist -le 0) { continue }
      $fgOkL = ($null -eq $fgVal) -or ($fgVal -lt 80)
      $fgOkS = ($null -eq $fgVal) -or ($fgVal -gt 20)
      $btcOkL = (-not $BtcFilter) -or ($btcTrend -ne 'down')
      $btcOkS = (-not $BtcFilter) -or ($btcTrend -ne 'up')
      $side = ''
      if (($cl -gt $chHi) -and $fgOkL -and $btcOkL -and $slopeOk -and $gapOk -and $fundOkL) { $side = 'long' }
      elseif (($cl -lt $chLo) -and (-not $LongOnly) -and $fgOkS -and $btcOkS -and $slopeOk -and $gapOk -and $fundOkS) { $side = 'short' }
      if ($side -eq '') { continue }
      if ($side -eq 'long') { $entryRaw=$cl; $entry=$cl*(1+$SlipPct); $stop=$entry-$stopDist; $tp1=$entry+$RewardR*$stopDist }
      else                  { $entryRaw=$cl; $entry=$cl*(1-$SlipPct); $stop=$entry+$stopDist; $tp1=$entry-$RewardR*$stopDist }
      $qty = ($equity*$RiskPct*$riskMult)/$stopDist
      if ($qty*$entry -gt $MaxLev*$equity) { $qty = $MaxLev*$equity/$entry }
      $efee = $qty*$entry*$FeePct; $equity -= $efee
      $open[$sym] = @{ side=$side; bo=$true; entry=$entry; entryRaw=$entryRaw; qty=$qty; stop=$stop; tp1=$tp1; tp1done=$false; entryIdx=$i; entryDay=$day; entryTs=$ts; equityAtEntry=$equity; realized=(-$efee)
        stop0=$stop; stopDist0=$stopDist; mfePx=$entry; maePx=$entry; bars=0
        atrPct=[math]::Round(100*$atr/$cl,3); rsiEntry=[math]::Round($rsi,1)
        distE20=[math]::Round(100*($cl-$e20)/$e20,3); distE50=[math]::Round(100*($cl-$e50)/$e50,3)
        btcEntry=$idxTrend; fgEntry=$fgVal; riskUsd=[math]::Round($qty*$stopDist,2) }
      continue
    }

    if ($up) {
      # pullback: some low in last N bars touched EMA20 zone; RSI cooled <=threshold recently; trigger: bullish bar reclaiming EMA20
      $touched=$false; $rsiCool=$false
      for ($j=$i-$PullbackLookback; $j -lt $i; $j++){ if($j -ge 0){ if($S[$sym].l[$j] -le $S[$sym].ema20[$j]){$touched=$true}; if($S[$sym].rsi[$j] -le $rsiCoolTh){$rsiCool=$true} } }
      $trigger = ($cl -gt $op) -and ($cl -gt $e20) -and ($S[$sym].c[$i-1] -le $S[$sym].ema20[$i-1] -or $S[$sym].rsi[$i-1] -le $rsiCoolTh)
      $fgOk = ($null -eq $fgVal) -or ($fgVal -lt 80)   # block new longs only in extreme greed
      $btcOk = (-not $BtcFilter) -or ($btcTrend -ne 'down')
      if ($touched -and $rsiCool -and $trigger -and $fgOk -and $btcOk -and $slopeOk -and $gapOk -and $extOk -and $rsiCapOk -and $fundOkL -and $momOkL -and $atrOkL) {
        $entryRaw = $cl; $entry = $cl * (1 + $SlipPct)
        $swing = ($S[$sym].l[[math]::Max(0,$i-$PullbackLookback)..$i] | Measure-Object -Minimum).Minimum
        $stopDist = [math]::Max($entry - $swing, $AtrStopMult*$atr)
        if ($stopDist -le 0) { continue }
        $stop = $entry - $stopDist
        $qty = ($equity * $RiskPct * $riskMult) / $stopDist
        if ($qty*$entry -gt $MaxLev*$equity) { $qty = $MaxLev*$equity/$entry }
        $tp1 = $entry + $RewardR*$stopDist
        $efee = $qty*$entry*$FeePct; $equity -= $efee
        $open[$sym] = @{ side='long'; entry=$entry; entryRaw=$entryRaw; qty=$qty; stop=$stop; tp1=$tp1; tp1done=$false; entryIdx=$i; entryDay=$day; entryTs=$ts; equityAtEntry=$equity; realized=(-$efee)
          stop0=$stop; stopDist0=$stopDist; mfePx=$entry; maePx=$entry; bars=0
          atrPct=[math]::Round(100*$atr/$cl,3); rsiEntry=[math]::Round($rsi,1)
          distE20=[math]::Round(100*($cl-$e20)/$e20,3); distE50=[math]::Round(100*($cl-$e50)/$e50,3)
          btcEntry=$idxTrend; fgEntry=$fgVal; riskUsd=[math]::Round($qty*$stopDist,2) }
      }
    }
    elseif ($down -and -not $LongOnly) {
      $touched=$false; $rsiHot=$false
      for ($j=$i-$PullbackLookback; $j -lt $i; $j++){ if($j -ge 0){ if($S[$sym].h[$j] -ge $S[$sym].ema20[$j]){$touched=$true}; if($S[$sym].rsi[$j] -ge $rsiHotTh){$rsiHot=$true} } }
      $trigger = ($cl -lt $op) -and ($cl -lt $e20) -and ($S[$sym].c[$i-1] -ge $S[$sym].ema20[$i-1] -or $S[$sym].rsi[$i-1] -ge $rsiHotTh)
      $fgOk = ($null -eq $fgVal) -or ($fgVal -gt 20)   # block new shorts only in extreme fear
      $btcOk = (-not $BtcFilter) -or ($btcTrend -ne 'up')
      if ($touched -and $rsiHot -and $trigger -and $fgOk -and $btcOk -and $slopeOk -and $gapOk -and $extOk -and $rsiCapOk -and $fundOkS) {
        $entryRaw=$cl; $entry = $cl*(1-$SlipPct)
        $swing = ($S[$sym].h[[math]::Max(0,$i-$PullbackLookback)..$i] | Measure-Object -Maximum).Maximum
        $stopDist=[math]::Max($swing-$entry,$AtrStopMult*$atr)
        if ($stopDist -le 0){continue}
        $stop=$entry+$stopDist
        $qty=($equity*$RiskPct*$riskMult)/$stopDist
        if ($qty*$entry -gt $MaxLev*$equity){ $qty=$MaxLev*$equity/$entry }
        $tp1=$entry-$RewardR*$stopDist
        $efee = $qty*$entry*$FeePct; $equity -= $efee
        $open[$sym]=@{ side='short'; entry=$entry; entryRaw=$entryRaw; qty=$qty; stop=$stop; tp1=$tp1; tp1done=$false; entryIdx=$i; entryDay=$day; entryTs=$ts; equityAtEntry=$equity; realized=(-$efee)
          stop0=$stop; stopDist0=$stopDist; mfePx=$entry; maePx=$entry; bars=0
          atrPct=[math]::Round(100*$atr/$cl,3); rsiEntry=[math]::Round($rsi,1)
          distE20=[math]::Round(100*($cl-$e20)/$e20,3); distE50=[math]::Round(100*($cl-$e50)/$e50,3)
          btcEntry=$idxTrend; fgEntry=$fgVal; riskUsd=[math]::Round($qty*$stopDist,2) }
      }
    }
    elseif ($RangeSetup -or $RangeV2) {
      # setup B: fade the boundaries of a 30-bar range when regime is neither up nor down
      # v2 variant: additionally require the INDEX (BTC) to be flat too - trade ranges only in a range market
      if ($RangeV2 -and $idxTrend -ne 'range') { continue }
      if ($i -lt 35) { continue }
      $rl = ($S[$sym].l[($i-30)..($i-1)] | Measure-Object -Minimum).Minimum
      $rh = ($S[$sym].h[($i-30)..($i-1)] | Measure-Object -Maximum).Maximum
      if (($rh - $rl) -lt (3*$atr)) { continue }   # range must be wide enough to pay fees
      $mid = ($rh + $rl) / 2
      $loI = $S[$sym].l[$i]; $hiI = $S[$sym].h[$i]
      $fgOkL = ($null -eq $fgVal) -or ($fgVal -lt 80)
      $fgOkS = ($null -eq $fgVal) -or ($fgVal -gt 20)
      $btcOkL = (-not $BtcFilter) -or ($btcTrend -ne 'down')
      $btcOkS = (-not $BtcFilter) -or ($btcTrend -ne 'up')

      if (($loI -le ($rl + 0.5*$atr)) -and ($rsi -lt 35) -and ($cl -gt $op) -and $fgOkL -and $btcOkL) {
        $entryRaw=$cl; $entry=$cl*(1+$SlipPct)
        $stop = [math]::Min($loI, $rl) - 0.5*$atr
        $stopDist = $entry - $stop
        if ($stopDist -le 0) { continue }
        if ((($mid - $entry) / $stopDist) -lt 1.2) { continue }   # min R:R to mid-range
        $qty=($equity*$RiskPct*$riskMult)/$stopDist
        if ($qty*$entry -gt $MaxLev*$equity){ $qty=$MaxLev*$equity/$entry }
        $efee=$qty*$entry*$FeePct; $equity-=$efee
        $open[$sym]=@{ side='long'; range=$true; entry=$entry; entryRaw=$entryRaw; qty=$qty; stop=$stop; tp1=$mid; tp1done=$false; entryIdx=$i; entryDay=$day; entryTs=$ts; equityAtEntry=$equity; realized=(-$efee)
          stop0=$stop; stopDist0=$stopDist; mfePx=$entry; maePx=$entry; bars=0
          atrPct=[math]::Round(100*$atr/$cl,3); rsiEntry=[math]::Round($rsi,1)
          distE20=[math]::Round(100*($cl-$e20)/$e20,3); distE50=[math]::Round(100*($cl-$e50)/$e50,3)
          btcEntry=$idxTrend; fgEntry=$fgVal; riskUsd=[math]::Round($qty*$stopDist,2) }
      }
      elseif (($hiI -ge ($rh - 0.5*$atr)) -and ($rsi -gt 65) -and ($cl -lt $op) -and $fgOkS -and $btcOkS) {
        $entryRaw=$cl; $entry=$cl*(1-$SlipPct)
        $stop = [math]::Max($hiI, $rh) + 0.5*$atr
        $stopDist = $stop - $entry
        if ($stopDist -le 0) { continue }
        if ((($entry - $mid) / $stopDist) -lt 1.2) { continue }
        $qty=($equity*$RiskPct*$riskMult)/$stopDist
        if ($qty*$entry -gt $MaxLev*$equity){ $qty=$MaxLev*$equity/$entry }
        $efee=$qty*$entry*$FeePct; $equity-=$efee
        $open[$sym]=@{ side='short'; range=$true; entry=$entry; entryRaw=$entryRaw; qty=$qty; stop=$stop; tp1=$mid; tp1done=$false; entryIdx=$i; entryDay=$day; entryTs=$ts; equityAtEntry=$equity; realized=(-$efee)
          stop0=$stop; stopDist0=$stopDist; mfePx=$entry; maePx=$entry; bars=0
          atrPct=[math]::Round(100*$atr/$cl,3); rsiEntry=[math]::Round($rsi,1)
          distE20=[math]::Round(100*($cl-$e20)/$e20,3); distE50=[math]::Round(100*($cl-$e50)/$e50,3)
          btcEntry=$idxTrend; fgEntry=$fgVal; riskUsd=[math]::Round($qty*$stopDist,2) }
      }
    }
  }
}

# close any still-open at the last bar WITHIN the traded window (skipped if hard-halted, already flattened)
$lastTs = $timeline[$timeline.Count-1]
foreach ($sym in @($open.Keys)) {
  $p=$open[$sym]
  $li = -1
  if ($S[$sym].idx.ContainsKey($lastTs)) { $li = $S[$sym].idx[$lastTs] }
  else { for ($q=$S[$sym].t.Count-1; $q -ge 0; $q--) { if ($S[$sym].t[$q] -le $lastTs) { $li=$q; break } } }
  $last=$S[$sym].c[$li]
  if($p.side -eq 'long'){ $pnl=($last-$p.entry)*$p.qty - $last*$p.qty*$FeePct }
  else{ $pnl=($p.entry-$last)*$p.qty - $last*$p.qty*$FeePct }
  $equity += $pnl; $p.realized += $pnl
  $trades.Add((New-TradeRecord $sym $p 'EOD' 'eod-close' $last $lastTs $idxTrend))
}

# ---- metrics ----
$wins = @($trades | Where-Object { $_.pnlUsd -gt 0 })
$losses = @($trades | Where-Object { $_.pnlUsd -le 0 })
$grossWin = ($wins | Measure-Object pnlUsd -Sum).Sum
$grossLoss = [math]::Abs(($losses | Measure-Object pnlUsd -Sum).Sum)
$pf = if($grossLoss -gt 0){ [math]::Round($grossWin/$grossLoss,2) } else { 'inf' }
$firstDay = $equityCurve[0].day; $lastDay = $equityCurve[-1].day
$months = ([datetime]$lastDay - [datetime]$firstDay).TotalDays / 30.44
$totRet = ($equity/$StartEquity - 1)
$monthlyGeo = if($months -gt 0){ [math]::Pow(($equity/$StartEquity), 1/$months) - 1 } else { 0 }

# monthly returns from equity curve
$byMonth = $equityCurve | Group-Object { $_.day.Substring(0,7) }
$monthRows = foreach ($g in $byMonth) { [pscustomobject]@{ month=$g.Name; endEq=[math]::Round($g.Group[-1].equity,2) } }
$prev = $StartEquity; $monthly=@()
foreach($m in $monthRows){ $r=[math]::Round(100*($m.endEq/$prev-1),2); $monthly+=[pscustomobject]@{month=$m.month; ret_pct=$r; equity=$m.endEq}; $prev=$m.endEq }

# save
$outDir=$DataDir
$equityCurve | ConvertTo-Json -Depth 2 | Out-File (Join-Path $outDir 'bt_equity.json') -Encoding utf8
$trades | ConvertTo-Json -Depth 2 | Out-File (Join-Path $outDir 'bt_trades.json') -Encoding utf8
$monthly | ConvertTo-Json -Depth 2 | Out-File (Join-Path $outDir 'bt_monthly.json') -Encoding utf8

"===================== BACKTEST RESULT ====================="
"Period            : $firstDay -> $lastDay  (~$([math]::Round($months,1)) months)"
"Symbols           : $($Symbols.Count)  | Start equity: `$$StartEquity"
"Final equity      : `$$([math]::Round($equity,2))"
"Total return      : $([math]::Round(100*$totRet,2)) %"
"Monthly (geo avg) : $([math]::Round(100*$monthlyGeo,2)) %"
"Trades            : $($trades.Count)  | Wins: $($wins.Count)  Losses: $($losses.Count)"
"Win rate          : $([math]::Round(100*$wins.Count/[math]::Max(1,$trades.Count),1)) %"
"Profit factor     : $pf"
"Avg win / avg loss: `$$([math]::Round(($wins|Measure-Object pnlUsd -Average).Average,2)) / `$$([math]::Round(($losses|Measure-Object pnlUsd -Average).Average,2))"
"Max drawdown      : $([math]::Round(100*$maxDD,2)) %"
"8% DD breached    : $ddBreached $(if($ddBreached){"(first at $ddBreachDate)"})"
"==========================================================="
"Monthly returns:"
$monthly | Format-Table -AutoSize | Out-String
"Per-symbol P&L:"
$trades | Group-Object sym | ForEach-Object {
  $w=@($_.Group|Where-Object{$_.pnlUsd -gt 0}).Count
  [pscustomobject]@{ sym=$_.Name; trades=$_.Count; wins=$w; winRate=[math]::Round(100*$w/$_.Count,0); pnlUsd=[math]::Round(($_.Group|Measure-Object pnlUsd -Sum).Sum,2) }
} | Sort-Object pnlUsd -Descending | Format-Table -AutoSize | Out-String
