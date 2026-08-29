# RF (MOEX futures) single-sleeve backtest with an optional "reactivate blocked signal on slot-free"
# queue experiment. Derived from tools\backtest.ps1's Donchian-breakout (core/"ядро") and
# pullback (setA/"сетап А") branches, trimmed to RF-only concerns (no crypto BTC-filter/funding/F&G/
# range-setup/anti-chase research knobs - canon RF research runs never use them, see
# tools\research_runs.ps1 -Set fut/futre). Does NOT modify backtest.ps1 / rf_engine.ps1 / live_rf_engine.ps1.
#
# Context: MAXCONC=3 per sleeve (tools\lib_rf_signals.ps1) blocks a signal SILENTLY and PERMANENTLY for
# that day if the sleeve is already full when the once-daily signal check runs (tools\live_rf_engine.ps1
# Invoke-LiveDayHook). -QueueMode lets us test whether remembering that blocked signal and reactivating
# it the moment a slot frees up (same event Close-CardLedger fires on) would have helped or hurt, on
# historical data, before touching the live engine.
#
#   none       - baseline: exactly today's behaviour (blocked signal is lost, matches backtest.ps1 bit-for-bit)
#   direct     - reactivate on slot-free using the ORIGINAL side, recompute stop/qty on the CURRENT bar
#   revalidate - reactivate only if the entry condition (breakout/pullback) still holds on the CURRENT bar
#
# Canonical baseline configs (tools\research_runs.ps1 -Set fut, frozen core = 'B20-trail3'):
#   core (ядро):  -Breakout -BreakoutN 20 -AtrStopMult 2.0 -AtrTrailMult 3.0
#   setA (сетап A): (no -Breakout), defaults already match ATR_STOP_A=1.0/TPR=1.5/PBLOOK=3
# Both: -Symbols BR,NG,GOLD,SILV,Si,RTS,CNY,MIX -DataDir data\moex_fut -FileSuffix _1d -MaxLev 3 -FeePct 0.00025
param(
  [string[]]$Symbols = @('BR','NG','GOLD','SILV','Si','RTS','CNY','MIX'),
  [double]$StartEquity = 10000,
  [double]$RiskPct = 0.01,
  [double]$MaxLev = 3,
  [int]$MaxConcurrent = 3,
  [double]$FeePct = 0.00025,
  [double]$SlipPct = 0.0003,
  [double]$StopSlipPct = 0.0005,
  [double]$RewardR = 1.5,
  [double]$Tp1ClosePct = 0.5,
  [int]$PullbackLookback = 3,
  [double]$DailyLossHaltPct = 0.03,
  [double]$MaxDDFlagPct = 0.08,
  [switch]$HardHalt,
  [string]$FromDate,
  [string]$ToDate,
  [double]$AtrStopMult = 1.0,
  [switch]$Breakout,
  [int]$BreakoutN = 20,
  [double]$AtrTrailMult = 0,
  [int]$ReArmN = 0,
  [int]$ReArmBars = 15,
  # Символы, которым re-arm НЕ применяется, даже когда -ReArmN > 0. Пусто = как раньше, бит-в-бит.
  # Зачем (2026-08): re-arm одним инструментам помогает, другим мешает - у золота и юаня вклад
  # менял знак от одного его включения. Это позволяет проверить выборочное отключение.
  # ВНИМАНИЕ: в боевом движке такого механизма НЕТ ($REARM_N в lib_rf_signals.ps1 глобальный),
  # перенос в бой потребует правки торгового пути.
  [string[]]$ReArmExclude = @(),
  # Символы, по которым разрешён ТОЛЬКО лонг: шорт-сигнал гасится и слот НЕ занимает. Пусто = как
  # раньше, бит-в-бит. Зачем (2026-08-27): VTBR и SBRF - поставочные фьючерсы на акции, шорт по ним
  # брокер не примет при выключенной маржиналке (PostOrder -> 30051), в бою это гасит
  # Test-SideAllowed в live_rf_engine.ps1. Флаг позволяет померить цену этого ограничения.
  [string[]]$LongOnly = @(),
  [string]$DataDir = 'C:\Users\klyde\trading-sim\data\moex_fut',
  [string]$FileSuffix = '_1d',
  [int]$WarmupBars = 60,
  [ValidateSet('none', 'revalidate', 'direct')][string]$QueueMode = 'none',
  [int]$QueueExpiryBars = 3,
  [string]$OutTag = '',
  # Кластерный лимит: из перечисленных символов держать НЕ БОЛЕЕ ОДНОЙ позиции одновременно.
  # Пусто (по умолчанию) = выключено, поведение бит-в-бит как раньше.
  # Мотив (2026-08): Eu = Si * ED и CNY = Si / UCNY, то есть валютные пары к рублю - это одна и та
  # же ставка. Без лимита при MaxConcurrent=3 все слоты рукава может занять один фактор.
  [string[]]$ClusterGroup = @(),
  # Сколько позиций из -ClusterGroup разрешено держать ОДНОВРЕМЕННО. 1 = прежнее поведение
  # ("не более одной"), бит-в-бит. 2 = "не более двух". Действует только вместе с -ClusterGroup.
  [int]$ClusterMax = 1,
  # Множитель риска для ВТОРОЙ и последующих позиций из -ClusterGroup: 1.0 = выключено, бит-в-бит.
  # 0.5 = вторая коррелированная позиция открывается половинным размером. Мягкая альтернатива
  # жёсткому запрету: сделка не теряется, но совместный убыток кластера ограничен.
  [double]$ClusterRiskScale = 1.0,
  # Посимвольная комиссия: @{ SFIN=0.0031; T=0.0007 }. Символы, которых тут нет, платят $FeePct.
  # Пусто (по умолчанию) = поведение бит-в-бит как раньше.
  # Зачем (2026-08): $FeePct - это доля от нотионала, а сборы на FORTS берутся ЗА КОНТРАКТ.
  # У фьючерсов на акции нотионал лота мелкий (ЭсЭфАй 638 руб против 73 494 у нефти), поэтому
  # одна общая ставка занижает их издержки в разы - у ЭсЭфАй в 31 раз. Без этого поиск состава
  # корзины систематически предпочитал бы мелконотиональные инструменты по причине артефакта модели.
  [hashtable]$FeePctBySymbol = @{},
  # TELEMETRY ONLY. When set, dumps one row per open-position bar to this path (JSON).
  # Purely observational: it reads state that the management block already computed and
  # appends to a list. It must never influence an entry, an exit, a stop or a fill.
  [string]$TelemetryPath = ''
)
$ErrorActionPreference = 'Stop'
$dir = $DataDir

# Ставка комиссии для символа: из -FeePctBySymbol, иначе общий -FeePct.
function Get-SymFee([string]$Sym) {
  if ($FeePctBySymbol -and $FeePctBySymbol.ContainsKey($Sym)) { return [double]$FeePctBySymbol[$Sym] }
  return [double]$FeePct
}

# Кластерный лимит (см. параметр -ClusterGroup). Возвращает $true, если символ входит в группу
# и в группе УЖЕ есть открытая позиция. Пустая группа = всегда $false, то есть выключено.
function Test-ClusterBlocked([string]$Sym, $Open) {
  if (-not $ClusterGroup -or $ClusterGroup.Count -eq 0) { return $false }
  if ($ClusterGroup -notcontains $Sym) { return $false }
  $n = 0
  foreach ($os in @($Open.Keys)) { if ($ClusterGroup -contains $os) { $n++ } }
  return ($n -ge $ClusterMax)
}

function EMAseries([double[]]$v, [int]$p) {
  $n = $v.Count; $out = New-Object 'double[]' $n
  $k = 2.0 / ($p + 1); $sum = 0.0
  for ($i = 0; $i -lt $n; $i++) {
    if ($i -lt $p) { $sum += $v[$i]; $out[$i] = [double]::NaN; if ($i -eq $p - 1) { $out[$i] = $sum / $p } }
    else { $out[$i] = $v[$i] * $k + $out[$i - 1] * (1 - $k) }
  }
  return $out
}
function RSIseries([double[]]$v, [int]$p) {
  $n = $v.Count; $out = New-Object 'double[]' $n
  for ($i = 0; $i -lt $n; $i++) { $out[$i] = [double]::NaN }
  if ($n -le $p + 1) { return $out }
  $g = 0.0; $l = 0.0
  for ($i = 1; $i -le $p; $i++) { $d = $v[$i] - $v[$i - 1]; if ($d -gt 0) { $g += $d } else { $l -= $d } }
  $ag = $g / $p; $al = $l / $p
  $out[$p] = if ($al -eq 0) { 100 } else { 100 - 100 / (1 + $ag / $al) }
  for ($i = $p + 1; $i -lt $n; $i++) {
    $d = $v[$i] - $v[$i - 1]; $gg = 0.0; $ll = 0.0; if ($d -gt 0) { $gg = $d } else { $ll = -$d }
    $ag = ($ag * ($p - 1) + $gg) / $p; $al = ($al * ($p - 1) + $ll) / $p
    $out[$i] = if ($al -eq 0) { 100 } else { 100 - 100 / (1 + $ag / $al) }
  }
  return $out
}
function ATRseries([double[]]$h, [double[]]$l, [double[]]$c, [int]$p) {
  $n = $c.Count; $tr = New-Object 'double[]' $n; $out = New-Object 'double[]' $n
  for ($i = 0; $i -lt $n; $i++) {
    if ($i -eq 0) { $tr[$i] = $h[$i] - $l[$i] }
    else { $tr[$i] = [math]::Max($h[$i] - $l[$i], [math]::Max([math]::Abs($h[$i] - $c[$i - 1]), [math]::Abs($l[$i] - $c[$i - 1]))) }
    $out[$i] = [double]::NaN
  }
  $sum = 0.0
  for ($i = 0; $i -lt $p; $i++) { $sum += $tr[$i] }
  $out[$p - 1] = $sum / $p
  for ($i = $p; $i -lt $n; $i++) { $out[$i] = ($out[$i - 1] * ($p - 1) + $tr[$i]) / $p }
  return $out
}

# ---- load symbols, precompute indicators ----
$S = @{}
foreach ($sym in $Symbols) {
  $path = Join-Path $dir "$($sym.Replace('-', '_'))$FileSuffix.json"
  if (-not (Test-Path $path)) { Write-Warning "no data $sym"; continue }
  $bars = Get-Content $path -Raw | ConvertFrom-Json
  $o = [double[]]($bars.o); $h = [double[]]($bars.h); $l = [double[]]($bars.l); $c = [double[]]($bars.c); $t = [long[]]($bars.t)
  $S[$sym] = @{
    t = $t; o = $o; h = $h; l = $l; c = $c
    ema20 = EMAseries $c 20; ema50 = EMAseries $c 50; rsi = RSIseries $c 14; atr = ATRseries $h $l $c 14
    idx = @{}
  }
  for ($i = 0; $i -lt $t.Count; $i++) { $S[$sym].idx[$t[$i]] = $i }
}

$allTs = New-Object System.Collections.Generic.SortedSet[long]
foreach ($sym in $S.Keys) { foreach ($tt in $S[$sym].t) { [void]$allTs.Add($tt) } }
$timeline = @($allTs)
if ($FromDate) {
  $fromMs = [long]([DateTimeOffset]::new([datetime]::SpecifyKind([datetime]$FromDate, 'Utc'))).ToUnixTimeMilliseconds()
  $timeline = @($timeline | Where-Object { $_ -ge $fromMs })
}
if ($ToDate) {
  $toMs = [long]([DateTimeOffset]::new([datetime]::SpecifyKind([datetime]$ToDate, 'Utc'))).ToUnixTimeMilliseconds()
  $timeline = @($timeline | Where-Object { $_ -le $toMs })
}

function New-TradeRecord($sym, $p, $exitDay, $reason, $fill, $exitTs) {
  $sd = $p.stopDist0
  $mfeR = $null; $maeR = $null
  if ($sd -gt 0 -and $null -ne $p.mfePx) {
    if ($p.side -eq 'long') { $mfeR = [math]::Round(($p.mfePx - $p.entry) / $sd, 2); $maeR = [math]::Round(($p.entry - $p.maePx) / $sd, 2) }
    else { $mfeR = [math]::Round(($p.entry - $p.mfePx) / $sd, 2); $maeR = [math]::Round(($p.maePx - $p.entry) / $sd, 2) }
  }
  [pscustomobject]@{
    sym = $sym; side = $p.side; entryDay = $p.entryDay; exitDay = $exitDay
    entry = [math]::Round($p.entryRaw, 6); exitReason = $reason
    pnlUsd = [math]::Round($p.realized, 2); tp1done = [bool]$p.tp1done
    entryTs = $p.entryTs; exitTs = $exitTs; exitPx = [math]::Round($fill, 6)
    stop0 = [math]::Round($p.stop0, 6); stopDistPct = [math]::Round(100 * $sd / $p.entry, 3)
    riskUsd = $p.riskUsd; mfeR = $mfeR; maeR = $maeR; barsHeld = $p.bars
    fromQueue = [bool]$p.fromQueue
  }
}

# ---- portfolio state ----
$equity = $StartEquity; $peak = $StartEquity
$dayStartEquity = $StartEquity; $curDay = $null; $haltDay = $false
$open = @{}
$reArm = @{}
$queued = $null   # single-slot FIFO queue: @{ sym; side; day; barIdx }
$queuedCount = 0; $queuedFilled = 0; $queuedExpired = 0; $queuedDropped = 0
$trades = New-Object System.Collections.Generic.List[object]
$equityCurve = New-Object System.Collections.Generic.List[object]
$maxDD = 0.0; $ddBreached = $false; $ddBreachDate = $null
$telemetry = if ($TelemetryPath) { New-Object System.Collections.Generic.List[object] } else { $null }

# stop distance for a hypothetical entry of $side in $sym at bar $i (breakout: ATR-based; pullback: swing-based)
function Get-StopDist([string]$sym, [int]$i, [string]$side) {
  $atr = $S[$sym].atr[$i]
  if ([double]::IsNaN($atr) -or $atr -le 0) { return 0.0 }
  if ($Breakout) { return $AtrStopMult * $atr }
  $cl = $S[$sym].c[$i]
  $lo = [math]::Max(0, $i - $PullbackLookback)
  if ($side -eq 'long') {
    $entry = $cl * (1 + $SlipPct)
    $swing = ($S[$sym].l[$lo..$i] | Measure-Object -Minimum).Minimum
    return [math]::Max($entry - $swing, $AtrStopMult * $atr)
  } else {
    $entry = $cl * (1 - $SlipPct)
    $swing = ($S[$sym].h[$lo..$i] | Measure-Object -Maximum).Maximum
    return [math]::Max($swing - $entry, $AtrStopMult * $atr)
  }
}

# entry condition at bar $i: '' | 'long' | 'short' (breakout: Donchian-N + re-arm; else: EMA20/50 pullback)
function Get-Signal([string]$sym, [int]$i) {
  if ($i -lt $WarmupBars) { return '' }
  # long-only: шорт гасится ЗДЕСЬ, на сигнале - так же, как Test-SideAllowed в боевом движке
  # (сигнал теряется, слот не занимает, re-arm не трогает: он ставится на выходе, не на сигнале)
  $noShort = ($LongOnly -contains $sym)
  $atr = $S[$sym].atr[$i]
  if ([double]::IsNaN($atr) -or $atr -le 0) { return '' }
  if ($Breakout) {
    if ($i -lt ($BreakoutN + 1)) { return '' }
    $cl = $S[$sym].c[$i]
    $chHi = ($S[$sym].h[($i - $BreakoutN)..($i - 1)] | Measure-Object -Maximum).Maximum
    $chLo = ($S[$sym].l[($i - $BreakoutN)..($i - 1)] | Measure-Object -Minimum).Minimum
    if ($ReArmN -gt 0 -and ($ReArmExclude -notcontains $sym) -and $reArm.ContainsKey($sym) -and $i -ge ($ReArmN + 1)) {
      $ra = $reArm[$sym]; $dEx = $i - $ra.exitIdx
      if ($dEx -ge 1 -and $dEx -le $ReArmBars) {
        if ($ra.dir -eq 'long') { $chHi = ($S[$sym].h[($i - $ReArmN)..($i - 1)] | Measure-Object -Maximum).Maximum }
        else { $chLo = ($S[$sym].l[($i - $ReArmN)..($i - 1)] | Measure-Object -Minimum).Minimum }
      }
    }
    if ($cl -gt $chHi) { return 'long' }
    if ($cl -lt $chLo) { if ($noShort) { return '' }; return 'short' }
    return ''
  }
  $e20 = $S[$sym].ema20[$i]; $e50 = $S[$sym].ema50[$i]; $rsi = $S[$sym].rsi[$i]
  if ([double]::IsNaN($e50) -or [double]::IsNaN($e20) -or [double]::IsNaN($rsi)) { return '' }
  $cl = $S[$sym].c[$i]; $op = $S[$sym].o[$i]
  $up = ($cl -gt $e50) -and ($e20 -gt $e50)
  $down = ($cl -lt $e50) -and ($e20 -lt $e50)
  if ($up) {
    $touched = $false; $rsiCool = $false
    for ($j = $i - $PullbackLookback; $j -lt $i; $j++) { if ($j -ge 0) { if ($S[$sym].l[$j] -le $S[$sym].ema20[$j]) { $touched = $true }; if ($S[$sym].rsi[$j] -le 50.0) { $rsiCool = $true } } }
    $trigger = ($cl -gt $op) -and ($cl -gt $e20) -and ($S[$sym].c[$i - 1] -le $S[$sym].ema20[$i - 1] -or $S[$sym].rsi[$i - 1] -le 50.0)
    if ($touched -and $rsiCool -and $trigger) { return 'long' }
  } elseif ($down) {
    $touched = $false; $rsiHot = $false
    for ($j = $i - $PullbackLookback; $j -lt $i; $j++) { if ($j -ge 0) { if ($S[$sym].h[$j] -ge $S[$sym].ema20[$j]) { $touched = $true }; if ($S[$sym].rsi[$j] -ge 50.0) { $rsiHot = $true } } }
    $trigger = ($cl -lt $op) -and ($cl -lt $e20) -and ($S[$sym].c[$i - 1] -ge $S[$sym].ema20[$i - 1] -or $S[$sym].rsi[$i - 1] -ge 50.0)
    if ($touched -and $rsiHot -and $trigger) { if ($noShort) { return '' }; return 'short' }
  }
  return ''
}

function Open-Position([string]$sym, [string]$side, [double]$stopDist, [int]$i, [string]$day, [long]$ts, [bool]$fromQueue) {
  if ($stopDist -le 0) { return }
  $cl = $S[$sym].c[$i]
  $entryRaw = $cl
  $entry = if ($side -eq 'long') { $cl * (1 + $SlipPct) } else { $cl * (1 - $SlipPct) }
  $stop = if ($side -eq 'long') { $entry - $stopDist } else { $entry + $stopDist }
  $tp1 = if ($Breakout) { $null } elseif ($side -eq 'long') { $entry + $RewardR * $stopDist } else { $entry - $RewardR * $stopDist }
  $rp = $RiskPct
  if ($ClusterRiskScale -ne 1.0 -and $ClusterGroup -and $ClusterGroup.Count -gt 0 -and $ClusterGroup -contains $sym) {
    $nOpen = 0
    foreach ($os in @($script:open.Keys)) { if ($ClusterGroup -contains $os) { $nOpen++ } }
    if ($nOpen -gt 0) { $rp = $RiskPct * $ClusterRiskScale }
  }
  $qty = ($script:equity * $rp) / $stopDist
  if ($qty * $entry -gt $MaxLev * $script:equity) { $qty = $MaxLev * $script:equity / $entry }
  $symFee = Get-SymFee $sym
  $efee = $qty * $entry * $symFee; $script:equity -= $efee
  $script:open[$sym] = @{
    feePct = $symFee
    side = $side; bo = [bool]$Breakout; entry = $entry; entryRaw = $entryRaw; qty = $qty; stop = $stop; tp1 = $tp1
    tp1done = $false; entryIdx = $i; entryDay = $day; entryTs = $ts; realized = (-$efee)
    stop0 = $stop; stopDist0 = $stopDist; mfePx = $entry; maePx = $entry; bars = 0
    riskUsd = [math]::Round($qty * $stopDist, 2); fromQueue = $fromQueue
  }
}

foreach ($ts in $timeline) {
  $day = [DateTimeOffset]::FromUnixTimeMilliseconds($ts).UtcDateTime.ToString('yyyy-MM-dd')
  if ($day -ne $curDay) { $curDay = $day; $dayStartEquity = $equity; $haltDay = $false }

  # ---------- 1) manage open positions ----------
  foreach ($sym in @($open.Keys)) {
    $p = $open[$sym]
    if (-not $S[$sym].idx.ContainsKey($ts)) { continue }
    $i = $S[$sym].idx[$ts]
    if ($i -le $p.entryIdx) { continue }
    $hi = $S[$sym].h[$i]; $lo = $S[$sym].l[$i]; $cl = $S[$sym].c[$i]; $e20 = $S[$sym].ema20[$i]; $opn = $S[$sym].o[$i]
    $p.bars++
    if ($null -ne $telemetry) { $tlMfePrev = $p.mfePx; $tlStopIn = $p.stop }
    if ($p.side -eq 'long') { if ($hi -gt $p.mfePx) { $p.mfePx = $hi }; if ($lo -lt $p.maePx) { $p.maePx = $lo } }
    else { if ($lo -lt $p.mfePx) { $p.mfePx = $lo }; if ($hi -gt $p.maePx) { $p.maePx = $hi } }
    $exited = $false

    if ($p.bo -and $AtrTrailMult -gt 0) {
      if ($p.side -eq 'long') {
        if ($lo -le $p.stop) { $fill = ([math]::Min($p.stop, $opn)) * (1 - $StopSlipPct); $pnl = ($fill - $p.entry) * $p.qty - $fill * $p.qty * $p.feePct; $equity += $pnl; $p.realized += $pnl; $exited = $true; $reason = if ($fill -gt $p.entry) { 'atr-trail' } else { 'stop' } }
      } else {
        if ($hi -ge $p.stop) { $fill = ([math]::Max($p.stop, $opn)) * (1 + $StopSlipPct); $pnl = ($p.entry - $fill) * $p.qty - $fill * $p.qty * $p.feePct; $equity += $pnl; $p.realized += $pnl; $exited = $true; $reason = if ($fill -lt $p.entry) { 'atr-trail' } else { 'stop' } }
      }
      if (-not $exited) {
        $atrNow = $S[$sym].atr[$i]
        if (-not [double]::IsNaN($atrNow)) {
          if ($p.side -eq 'long') { $ns = $p.mfePx - $AtrTrailMult * $atrNow; if ($ns -gt $p.stop) { $p.stop = $ns } }
          else { $ns = $p.mfePx + $AtrTrailMult * $atrNow; if ($ns -lt $p.stop) { $p.stop = $ns } }
        }
      }
    } elseif ($p.side -eq 'long') {
      $stopHit = ($lo -le $p.stop)
      $tpHit = (-not $p.tp1done) -and ($null -ne $p.tp1) -and ($hi -ge $p.tp1)
      if ($stopHit) {
        $fill = ([math]::Min($p.stop, $opn)) * (1 - $StopSlipPct)
        $pnl = ($fill - $p.entry) * $p.qty - $fill * $p.qty * $p.feePct
        $equity += $pnl; $p.realized += $pnl; $exited = $true; $reason = if ($p.tp1done) { 'trail-stop/BE' } else { 'stop' }
      } elseif ($tpHit) {
        $half = $p.qty * $Tp1ClosePct; $fill = $p.tp1
        $pnl = ($fill - $p.entry) * $half - $fill * $half * $p.feePct
        $equity += $pnl; $p.realized += $pnl
        $p.qty -= $half; $p.tp1done = $true; $p.stop = $p.entry
      }
      if (-not $exited -and $p.tp1done -and ($cl -lt $e20)) {
        $fill = $cl * (1 - $SlipPct)
        $pnl = ($fill - $p.entry) * $p.qty - $fill * $p.qty * $p.feePct
        $equity += $pnl; $p.realized += $pnl; $exited = $true; $reason = 'trail-EMA20'
      }
    } else {
      $stopHit = ($hi -ge $p.stop)
      $tpHit = (-not $p.tp1done) -and ($null -ne $p.tp1) -and ($lo -le $p.tp1)
      if ($stopHit) {
        $fill = ([math]::Max($p.stop, $opn)) * (1 + $StopSlipPct)
        $pnl = ($p.entry - $fill) * $p.qty - $fill * $p.qty * $p.feePct
        $equity += $pnl; $p.realized += $pnl; $exited = $true; $reason = if ($p.tp1done) { 'trail-stop/BE' } else { 'stop' }
      } elseif ($tpHit) {
        $half = $p.qty * $Tp1ClosePct; $fill = $p.tp1
        $pnl = ($p.entry - $fill) * $half - $fill * $half * $p.feePct
        $equity += $pnl; $p.realized += $pnl
        $p.qty -= $half; $p.tp1done = $true; $p.stop = $p.entry
      }
      if (-not $exited -and $p.tp1done -and ($cl -gt $e20)) {
        $fill = $cl * (1 + $SlipPct)
        $pnl = ($p.entry - $fill) * $p.qty - $fill * $p.qty * $p.feePct
        $equity += $pnl; $p.realized += $pnl; $exited = $true; $reason = 'trail-EMA20'
      }
    }
    if ($null -ne $telemetry) {
      # mfePrev/stopIn = state in force DURING this bar (chandelier updates only at bar close),
      # mfe/stopOut = state after this bar was folded in. P is signed toward the trade's favour.
      $tlP = if ($p.side -eq 'long') { $p.mfePx - $p.entry } else { $p.entry - $p.mfePx }
      $tlPPrev = if ($p.side -eq 'long') { $tlMfePrev - $p.entry } else { $p.entry - $tlMfePrev }
      $telemetry.Add([pscustomobject]@{
          sym = $sym; side = $p.side; entryTs = $p.entryTs; entryDay = $p.entryDay
          day = $day; ts = $ts; barNo = $p.bars
          o = $opn; h = $hi; l = $lo; c = $cl
          atr14 = $S[$sym].atr[$i]
          entry = $p.entry; stopDist0 = $p.stopDist0; initial_stop = $p.stop0
          mfePrev = $tlMfePrev; mfe = $p.mfePx; pPrev = $tlPPrev; p = $tlP
          stopIn = $tlStopIn; stopOut = $p.stop
          exited = [bool]$exited; exitReason = $(if ($exited) { $reason } else { '' })
        })
    }
    if ($exited) {
      $trades.Add((New-TradeRecord $sym $p $day $reason $fill $ts))
      $open.Remove($sym)
      if ($p.bo -and $ReArmN -gt 0 -and ($ReArmExclude -notcontains $sym)) { $reArm[$sym] = @{ exitIdx = $i; dir = $p.side } }
    }
  }

  # ---------- 2) equity curve / drawdown ----------
  $mtm = $equity
  foreach ($sym in $open.Keys) {
    $p = $open[$sym]; if (-not $S[$sym].idx.ContainsKey($ts)) { continue }
    $cl = $S[$sym].c[$S[$sym].idx[$ts]]
    if ($p.side -eq 'long') { $mtm += ($cl - $p.entry) * $p.qty } else { $mtm += ($p.entry - $cl) * $p.qty }
  }
  if ($mtm -gt $peak) { $peak = $mtm }
  $dd = if ($peak -gt 0) { ($peak - $mtm) / $peak } else { 0 }
  if ($dd -gt $maxDD) { $maxDD = $dd }
  if ($dd -ge $MaxDDFlagPct -and -not $ddBreached) { $ddBreached = $true; $ddBreachDate = $day }
  if ($HardHalt -and $dd -ge $MaxDDFlagPct) {
    foreach ($sym in @($open.Keys)) {
      $p = $open[$sym]; if (-not $S[$sym].idx.ContainsKey($ts)) { continue }
      $cl = $S[$sym].c[$S[$sym].idx[$ts]]
      if ($p.side -eq 'long') { $pnl = ($cl * (1 - $SlipPct) - $p.entry) * $p.qty - $cl * $p.qty * $p.feePct } else { $pnl = ($p.entry - $cl * (1 + $SlipPct)) * $p.qty - $cl * $p.qty * $p.feePct }
      $equity += $pnl; $p.realized += $pnl
      $trades.Add((New-TradeRecord $sym $p $day 'hard-halt' $cl $ts))
    }
    $open.Clear(); $queued = $null
    $equityCurve.Add([pscustomobject]@{ day = $day; ts = $ts; equity = [math]::Round($equity, 2) })
    break
  }
  if ((($dayStartEquity - $mtm) / $dayStartEquity) -ge $DailyLossHaltPct) { $haltDay = $true }
  $equityCurve.Add([pscustomobject]@{ day = $day; ts = $ts; equity = [math]::Round($mtm, 2) })

  if ($haltDay) { continue }

  # ---------- 3) reactivate a queued signal if a slot just freed up ----------
  if ($null -ne $queued -and $open.Count -lt $MaxConcurrent) {
    $qsym = $queued.sym
    if ($S.ContainsKey($qsym) -and $S[$qsym].idx.ContainsKey($ts) -and -not $open.ContainsKey($qsym) `
        -and -not (Test-ClusterBlocked $qsym $open)) {
      $qi = $S[$qsym].idx[$ts]
      if (($qi - $queued.barIdx) -gt $QueueExpiryBars) {
        $queued = $null; $queuedExpired++
      } elseif ($QueueMode -eq 'direct') {
        $sd = Get-StopDist $qsym $qi $queued.side
        if ($sd -gt 0) { Open-Position $qsym $queued.side $sd $qi $day $ts $true; $queuedFilled++ } else { $queuedDropped++ }
        $queued = $null
      } elseif ($QueueMode -eq 'revalidate') {
        $sig2 = Get-Signal $qsym $qi
        if ($sig2 -eq $queued.side) {
          $sd = Get-StopDist $qsym $qi $sig2
          if ($sd -gt 0) { Open-Position $qsym $sig2 $sd $qi $day $ts $true; $queuedFilled++ } else { $queuedDropped++ }
        } else { $queuedDropped++ }
        $queued = $null
      }
    }
  }

  # ---------- 4) look for new entries ----------
  foreach ($sym in $Symbols) {
    if (-not $S.ContainsKey($sym)) { continue }
    if ($open.ContainsKey($sym)) { continue }
    if (Test-ClusterBlocked $sym $open) { continue }
    if ($open.Count -ge $MaxConcurrent -and ($QueueMode -eq 'none' -or $null -ne $queued)) { break }
    if (-not $S[$sym].idx.ContainsKey($ts)) { continue }
    $i = $S[$sym].idx[$ts]
    $side = Get-Signal $sym $i
    if ($side -eq '') { continue }
    if ($open.Count -lt $MaxConcurrent) {
      $sd = Get-StopDist $sym $i $side
      Open-Position $sym $side $sd $i $day $ts $false
    } elseif ($QueueMode -ne 'none' -and $null -eq $queued) {
      $queued = @{ sym = $sym; side = $side; day = $day; barIdx = $i }
      $queuedCount++
    }
  }
}

# close any still-open at the last bar
if ($timeline.Count) {
  $lastTs = $timeline[$timeline.Count - 1]
  foreach ($sym in @($open.Keys)) {
    $p = $open[$sym]
    $li = -1
    if ($S[$sym].idx.ContainsKey($lastTs)) { $li = $S[$sym].idx[$lastTs] }
    else { for ($q = $S[$sym].t.Count - 1; $q -ge 0; $q--) { if ($S[$sym].t[$q] -le $lastTs) { $li = $q; break } } }
    $last = $S[$sym].c[$li]
    if ($p.side -eq 'long') { $pnl = ($last - $p.entry) * $p.qty - $last * $p.qty * $p.feePct } else { $pnl = ($p.entry - $last) * $p.qty - $last * $p.qty * $p.feePct }
    $equity += $pnl; $p.realized += $pnl
    $trades.Add((New-TradeRecord $sym $p 'EOD' 'eod-close' $last $lastTs))
  }
}

# ---- metrics ----
$wins = @($trades | Where-Object { $_.pnlUsd -gt 0 })
$losses = @($trades | Where-Object { $_.pnlUsd -le 0 })
$grossWin = ($wins | Measure-Object pnlUsd -Sum).Sum
$grossLoss = [math]::Abs(($losses | Measure-Object pnlUsd -Sum).Sum)
$pf = if ($grossLoss -gt 0) { [math]::Round($grossWin / $grossLoss, 2) } else { 'inf' }
$firstDay = $equityCurve[0].day; $lastDay = $equityCurve[-1].day
$months = ([datetime]$lastDay - [datetime]$firstDay).TotalDays / 30.44
$totRet = ($equity / $StartEquity - 1)
$monthlyGeo = if ($months -gt 0) { [math]::Pow(($equity / $StartEquity), 1 / $months) - 1 } else { 0 }
$queueTrades = @($trades | Where-Object { $_.fromQueue })

$outSuffix = if ($OutTag) { "_$OutTag" } else { '' }
$trades | ConvertTo-Json -Depth 3 | Out-File (Join-Path $dir "btq_trades$outSuffix.json") -Encoding utf8
$equityCurve | ConvertTo-Json -Depth 2 | Out-File (Join-Path $dir "btq_equity$outSuffix.json") -Encoding utf8
if ($null -ne $telemetry) { $telemetry | ConvertTo-Json -Depth 3 | Out-File $TelemetryPath -Encoding utf8 }

"===================== RF QUEUE BACKTEST ($QueueMode) ====================="
"Mode              : $(if($Breakout){'core (Donchian breakout)'}else{'setA (pullback)'})  | QueueMode=$QueueMode QueueExpiryBars=$QueueExpiryBars"
"Period            : $firstDay -> $lastDay  (~$([math]::Round($months, 1)) months)"
"Final equity      : `$$([math]::Round($equity, 2))  | Total return: $([math]::Round(100 * $totRet, 2))%  | Monthly geo: $([math]::Round(100 * $monthlyGeo, 2))%"
"Trades            : $($trades.Count)  | Wins: $($wins.Count)  Losses: $($losses.Count)  | Win rate: $([math]::Round(100 * $wins.Count / [math]::Max(1, $trades.Count), 1))%"
"Profit factor     : $pf"
"Max drawdown      : $([math]::Round(100 * $maxDD, 2))%  | 8% DD breached: $ddBreached $(if ($ddBreached) { "(first at $ddBreachDate)" })"
"Queue stats       : queued=$queuedCount filled=$queuedFilled expired=$queuedExpired dropped(cond-failed)=$queuedDropped | trades-from-queue=$($queueTrades.Count)"
"============================================================================="
