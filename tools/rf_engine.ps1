# rf_engine.ps1 - живой форвард-тест рынка РФ: портфели C2 и C3b (решение пользователя 2026-07-10).
# Вызывается из auto_trade.ps1 каждый тик (или standalone). Два виртуальных счёта, в каждом 3 рукава:
#   core = Donchian-20 брейкаут + re-arm 10x15, стоп 2xATR14, трейл-люстра 3xATR (риск C2=3%, C3b=5%)
#   setA = трендовый откат к EMA20 (дневки), стоп max(свинг,1xATR), TP1 1.5R(50%)->БУ->трейл EMA20 (риск 1%/2%)
#   mom  = топ-4 акций по моментуму 63дн/skip21, гейт IMOEX>EMA200, ребаланс 1-й торговый день месяца (вес 0.3/0.5)
# Рукава НЕЗАВИСИМЫ (каждый со своей базой $10k), профиль = помесячно-аддитивная комбинация - ровно как
# build_fut_combos.ps1 считает опубликованные кривые C2/C3b.
# Исполнение: решения по ЗАКРЫТЫМ дневным барам MOEX; входы/выходы-по-закрытию исполняются на ОТКРЫТИИ
# следующей сессии (честное отличие от бэктеста, зафиксировано в docs\strategy\strategy_moex_fut.md); стопы/TP1 -
# ПО КАСАНИЮ через часовые свечи ISS; роллы фронт-контрактов за ~3 дня до экспирации ПЛАТНЫЕ (2x комиссия+слип).
# Модель без лотности/ГО (дробные контракты) - как в бэктесте. Все метки данных "MSK-как-UTC" (+3ч).
param(
  [string]$Root = '',
  [switch]$DryRun,
  [long]$NowMs = 0        # реальное UTC сейчас (мс); 0 = текущее
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'lib_engine.ps1')
. (Join-Path $PSScriptRoot 'lib_rf_signals.ps1')   # сигнальное ядро + константы стратегии + series io (общее с live-контуром)

# ---- константы МОДЕЛИ ИСПОЛНЕНИЯ paper (у live-контура свои: реальные комиссии/заявки) ----
$FUT_FEE = 0.0001; $SLIP = 0.0003; $STOPSLIP = 0.0005
$MOM_COST = 0.0013
$PROFILES = @(
  @{ id = 'c2';  label = 'C2';  core = 0.03; seta = 0.01; mom = 0.3 },
  @{ id = 'c3b'; label = 'C3b'; core = 0.05; seta = 0.02; mom = 0.5 }
)

if ($NowMs -le 0) { $NowMs = UtcNowMs }
$mskNowMs = $NowMs + $MSK
$mskToday = MsToUtcDay $mskNowMs
# дневной бар даты D финален, когда MSK-время >= D+1 00:15 (23:50 закрытие + запас на задержку ISS)
$completedDay = Get-RfCompletedDay $mskNowMs

$rfDir = Join-Path $Root 'data\rf'
$serDir = Join-Path $rfDir 'series'
if (-not (Test-Path $serDir)) { New-Item -ItemType Directory -Force $serDir | Out-Null }
$script:rfEvents = New-Object System.Collections.Generic.List[string]
$script:rfJournal = New-Object System.Collections.Generic.List[string]
$script:rfClosed = New-Object System.Collections.Generic.List[object]

# ================= state =================
function New-SleeveFut { [pscustomobject]@{ equity = 10000.0; month_start_eq = 10000.0; day_start_eq = 10000.0
  halt_day = $null; positions = @(); pending = @() } }
function New-SleeveMom { [pscustomobject]@{ equity = 10000.0; month_start_eq = 10000.0
  cash = 10000.0; holdings = @(); pending = @(); last_rebalance_month = '' } }
function New-RfProfile($cfg) {
  [pscustomobject]@{
    meta = [pscustomobject]@{ profile = $cfg.label; created = (MsToUtcStr $NowMs)
      core_risk = $cfg.core; seta_risk = $cfg.seta; mom_weight = $cfg.mom; start = 10000.0; halt_pct = $HALT_PCT }
    sleeves = [pscustomobject]@{ core = (New-SleeveFut); setA = (New-SleeveFut); mom = (New-SleeveMom) }
    profile_eq = 10000.0; profile_month_start = 10000.0; cur_month = ''
    day_start_eq = 10000.0; day_start_date = ''
    peak_eq = 10000.0
    stats = [pscustomobject]@{ trades = 0; wins = 0; losses = 0; fees = 0.0; realized = 0.0 }
  }
}

$sharedPath = Join-Path $rfDir 'shared.json'
$shared = Read-JsonFile $sharedPath
if ($null -eq $shared) {
  # старт: обработать ПОСЛЕДНИЙ завершённый дневной бар (хук за $completedDay) и докатать часовики с его конца
  $initDaily = (MsToUtc ((UtcStrToMs "$completedDay 00:00") - $DAY)).ToString('yyyy-MM-dd')
  $shared = [pscustomobject]@{ schema = 1; last_daily_day = $initDaily; last_hour_ts = (UtcStrToMs "$completedDay 23:00")
    fronts = $null; next_trade_id = 1; last_tick_utc = '' }
  # первичная инициализация серий: копия канонических склеек (текущий сегмент = сырой фронт)
  foreach ($a in $ASSETS) { Copy-Item (Join-Path $Root "data\moex_fut\$($a)_1d.json") (Join-Path $serDir "$a.json") -Force }
  foreach ($t in $TICKERS) { Copy-Item (Join-Path $Root "data\moex\$($t)_1d.json") (Join-Path $serDir "$t.json") -Force }
  Copy-Item (Join-Path $Root "data\moex\IMOEX_1d.json") (Join-Path $serDir "IMOEX.json") -Force
  Write-TickLog $Root "RF: state initialized (series seeded, watermark=$completedDay)"
}
$profState = @{}
function Normalize-Rf($p) {
  # PS 5.1: пустой JSON-массив '[]' десериализуется в $null -> в списках появляются null-элементы
  foreach ($slName in 'core', 'setA') {
    $sl = $p.sleeves.$slName
    $sl.positions = ToArr (@($sl.positions) | Where-Object { $null -ne $_ })
    $sl.pending   = ToArr (@($sl.pending)   | Where-Object { $null -ne $_ })
  }
  $m = $p.sleeves.mom
  $m.holdings = ToArr (@($m.holdings) | Where-Object { $null -ne $_ })
  $m.pending  = ToArr (@($m.pending)  | Where-Object { $null -ne $_ })
}
foreach ($cfg in $PROFILES) {
  $p = Read-JsonFile (Join-Path $rfDir "$($cfg.id)_portfolio.json")
  if ($null -eq $p) { $p = New-RfProfile $cfg; $script:rfEvents.Add("RF INIT $($cfg.label) `$10k") }
  Normalize-Rf $p
  $profState[$cfg.id] = $p
}

# series io + индикаторы + сигнальные функции - в lib_rf_signals.ps1 (общие с live-контуром)

# ================= ledger / stats =================
function Rf-CloseFill($cfg, [string]$sleeve, $pos, [double]$px, [long]$tsMsk, [string]$reason, [double]$qty = -1) {
  # qty=-1 -> вся позиция
  $p = $profState[$cfg.id]
  $sl = $p.sleeves.$sleeve
  $closeQty = if ($qty -le 0) { [double]$pos.qty } else { $qty }
  $sm = if ($pos.side -eq 'long') { 1.0 } else { -1.0 }
  $gross = $sm * $closeQty * ($px - [double]$pos.entry)
  $fee = $closeQty * $px * $FUT_FEE
  $sl.equity = [double]$sl.equity + $gross - $fee
  $pos.fees = [double]$pos.fees + $fee
  $pos.qty = [math]::Round([double]$pos.qty - $closeQty, 6)
  $full = ($pos.qty -le 0.000001)
  # накапливаем realized по ногам
  $pos.realized = [double]$pos.realized + $gross - $fee
  if ($full) {
    $net = [math]::Round([double]$pos.realized - [double]$pos.entry_fee, 2)
    $st = $p.stats
    $st.trades = [int]$st.trades + 1
    if ($net -gt 0) { $st.wins = [int]$st.wins + 1 } else { $st.losses = [int]$st.losses + 1 }
    $st.fees = [math]::Round([double]$st.fees + [double]$pos.fees + [double]$pos.entry_fee, 2)
    $st.realized = [math]::Round([double]$st.realized + $net, 2)
    $rec = [pscustomobject]@{
      id = $pos.id; profile = $cfg.label; sleeve = $sleeve; sym = $pos.asset; secid = $pos.secid; side = $pos.side
      entryDay = $pos.entry_day; entry = [double]$pos.entry; qty = [double]$pos.qty_initial
      exitDay = (MsToUtcDay $tsMsk); exitUtcMsk = (MsToUtcStr $tsMsk); exitPx = [math]::Round($px, 6)
      exitReason = $reason; pnlUsd = $net
      rMultiple = if ([double]$pos.risk_usd -gt 0) { [math]::Round($net / [double]$pos.risk_usd, 2) } else { $null }
      riskUsd = [double]$pos.risk_usd; fees = [math]::Round([double]$pos.fees + [double]$pos.entry_fee, 2)
      rolls = [int]$pos.rolls
    }
    $script:rfClosed.Add($rec)
    $script:rfEvents.Add("RF EXIT [$($cfg.label)/$sleeve] $($pos.id) $($pos.asset) $reason $net")
    $script:rfJournal.Add(("`r`n## {0} MSK — РФ АВТО [{1}/{2}]: закрыта {3} {4} {5} — {6:+0.00;-0.00} ({7})`r`n" -f (MsToUtcStr $tsMsk), $cfg.label, $sleeve, $pos.id, $pos.asset, $pos.side.ToUpper(), $net, $reason))
    $sl.positions = ToArr (@($sl.positions) | Where-Object { $_.id -ne $pos.id })
    # re-arm окно ядра
    if ($sleeve -eq 'core' -and $reason -ne 'roll') {
      if (-not $shared.PSObject.Properties['rearm']) { $shared | Add-Member -NotePropertyName rearm -NotePropertyValue ([pscustomobject]@{}) }
      $key = "$($cfg.id)_$($pos.asset)"
      $val = [pscustomobject]@{ exit_day = (MsToUtcDay $tsMsk); dir = $pos.side }
      if ($shared.rearm.PSObject.Properties[$key]) { $shared.rearm.$key = $val }
      else { $shared.rearm | Add-Member -NotePropertyName $key -NotePropertyValue $val }
    }
  }
  return $full
}

# ================= ДНЕВНОЙ ПРОХОД =================
function Invoke-RfDaily {
  # 1) фронты
  $fronts = Get-FutFronts $ASSETS
  $frontsRec = [ordered]@{}
  foreach ($a in $ASSETS) {
    if (-not $fronts.ContainsKey($a) -or -not @($fronts[$a]).Count) { throw "RF: нет фронта для $a" }
    $cur = $fronts[$a][0]
    $nxt = if (@($fronts[$a]).Count -gt 1) { $fronts[$a][1] } else { $null }
    $frontsRec[$a] = [pscustomobject]@{ secid = $cur.secid; lasttrade = $cur.lasttrade
      next = if ($nxt) { $nxt.secid } else { $null }; next_lasttrade = if ($nxt) { $nxt.lasttrade } else { $null } }
  }
  # активные контракты: если раньше не хранили - берём текущие фронты
  if (-not $shared.PSObject.Properties['active'] -or $null -eq $shared.active) {
    $act = [ordered]@{}
    foreach ($a in $ASSETS) { $act[$a] = $frontsRec[$a].secid }
    $shared | Add-Member -NotePropertyName active -NotePropertyValue ([pscustomobject]$act) -Force
  }
  $shared.fronts = [pscustomobject]$frontsRec

  # 2) дотянуть дневные серии до $completedDay (общий код с live-контуром - lib_rf_signals)
  $newDays = New-Object System.Collections.Generic.List[string]
  foreach ($a in $ASSETS) {
    Update-DailySeries $a 'fut' ([string]$shared.active.$a) $completedDay
  }
  foreach ($t in @($TICKERS) + @('IMOEX')) {
    $kind = if ($t -eq 'IMOEX') { 'index' } else { 'stock' }
    Update-DailySeries $t $kind $t $completedDay
  }

  # 3) хуки: ВСЕ торговые дни в диапазоне (last_daily_day, completedDay] по факту наличия баров в сериях
  $wm = [string]$shared.last_daily_day
  foreach ($nm in (@($ASSETS) + @('IMOEX'))) {
    $s = Get-Ser $nm
    for ($j = $s.Count - 1; $j -ge 0; $j--) {
      $d = SerDay $s[$j]
      if ($d -le $wm) { break }
      if ($d -le $completedDay -and -not $newDays.Contains($d)) { $newDays.Add($d) }
    }
  }
  foreach ($D in ($newDays | Sort-Object)) {
    Invoke-RfDayHook $D
  }
  $shared.last_daily_day = $completedDay
}

function Invoke-RfDayHook([string]$D) {
  $tsMsk = (UtcStrToMs "$D 23:50")
  # --- месяц/день роллы профилей (помесячно-аддитивная комбинация - как build_fut_combos) ---
  $mon = $D.Substring(0, 7)
  foreach ($cfg in $PROFILES) {
    $p = $profState[$cfg.id]
    if ($p.cur_month -eq '') { $p.cur_month = $mon }
    if ($mon -ne $p.cur_month) {
      # берём MTM-эквити рукава, если уже считали (нереализованное включено)
      $eC = if ($p.sleeves.core.PSObject.Properties['equity_mtm'] -and [double]$p.sleeves.core.equity_mtm -gt 0) { [double]$p.sleeves.core.equity_mtm } else { [double]$p.sleeves.core.equity }
      $eA = if ($p.sleeves.setA.PSObject.Properties['equity_mtm'] -and [double]$p.sleeves.setA.equity_mtm -gt 0) { [double]$p.sleeves.setA.equity_mtm } else { [double]$p.sleeves.setA.equity }
      $eM = [double]$p.sleeves.mom.equity
      $rC = ($eC / [double]$p.sleeves.core.month_start_eq) - 1
      $rA = ($eA / [double]$p.sleeves.setA.month_start_eq) - 1
      $rM = ($eM / [double]$p.sleeves.mom.month_start_eq) - 1
      $p.profile_month_start = [math]::Round([double]$p.profile_month_start * (1 + $rC + $rA + $cfg.mom * $rM), 2)
      $p.sleeves.core.month_start_eq = $eC
      $p.sleeves.setA.month_start_eq = $eA
      $p.sleeves.mom.month_start_eq = $eM
      $p.cur_month = $mon
    }
    if ($p.day_start_date -ne $D) {
      $p.day_start_date = $D
      $p.day_start_eq = [double]$p.profile_eq
      $p.sleeves.core.day_start_eq = [double]$p.sleeves.core.equity
      $p.sleeves.setA.day_start_eq = [double]$p.sleeves.setA.equity
      $p.sleeves.core.halt_day = $null; $p.sleeves.setA.halt_day = $null
    }
  }

  # --- фьючерсы: роллы, трейлы, сигналы ---
  foreach ($a in $ASSETS) {
    $s = Get-Ser $a
    $i = Ser-IdxOfDay $s $D
    if ($i -lt 0) { continue }   # инструмент в этот день не торговался
    $atr = Ser-ATR14 $s $i
    $bar = $s[$i]

    # ролл: до экспирации активного контракта <= 4 календарных дней
    $lt = [string]$shared.fronts.$a.lasttrade
    $curActive = [string]$shared.active.$a
    $frontNow = [string]$shared.fronts.$a.secid
    if ($curActive -ne $frontNow) {
      # биржа уже сменила фронт (наш активный экспирировал/убран) - принудительный ролл
      Invoke-RfRoll $a $curActive $frontNow $D $tsMsk
    } elseif ($shared.fronts.$a.next -and ((([datetime]$lt) - ([datetime]$D)).TotalDays -le 4)) {
      Invoke-RfRoll $a $curActive ([string]$shared.fronts.$a.next) $D $tsMsk
    }

    # трейл-люстра ядра + EMA20-выход сетапа A (по закрытию D; исполнение выхода - next open)
    foreach ($cfg in $PROFILES) {
      $p = $profState[$cfg.id]
      foreach ($pos in @($p.sleeves.core.positions | Where-Object { $_.asset -eq $a })) {
        if ([double]$bar.h -gt [double]$pos.mfe -and $pos.side -eq 'long') { $pos.mfe = [double]$bar.h }
        if ([double]$bar.l -lt [double]$pos.mfe -and $pos.side -eq 'short') { $pos.mfe = [double]$bar.l }
        $ns = Get-ChandelierStop ([string]$pos.side) ([double]$pos.mfe) ([double]$pos.stop) $atr
        if ($null -ne $ns) { $pos.stop = $ns }
      }
      foreach ($pos in @($p.sleeves.setA.positions | Where-Object { $_.asset -eq $a -and $_.tp1_done })) {
        if (Test-SetAEma20Exit $s $i ([string]$pos.side)) {
          $p.sleeves.setA.pending = ToArr (@($p.sleeves.setA.pending) + [pscustomobject]@{
            kind = 'exit'; pos_id = $pos.id; asset = $a; created_day = $D; reason = 'trail-ema20' })
        }
      }
    }

    # сигналы входа (close-based Donchian, окно без текущего бара) + re-arm
    if ($i -lt ($BRK_N + 1) -or [double]::IsNaN($atr) -or $atr -le 0) { continue }
    $cl = [double]$bar.c
    foreach ($cfg in $PROFILES) {
      $p = $profState[$cfg.id]
      # re-arm-состояние этого профиля по активу (укороченный канал в сторону выхода)
      $key = "$($cfg.id)_$a"
      $ra = if ($shared.PSObject.Properties['rearm'] -and $shared.rearm.PSObject.Properties[$key]) { $shared.rearm.$key } else { $null }
      $dsig = Get-DonchianSide $s $i $ra
      $side = [string]$dsig.side
      $chHi = [double]$dsig.hi; $chLo = [double]$dsig.lo
      if ($side -eq '') { continue }
      $slC = $p.sleeves.core
      if ($slC.halt_day -eq $D) { continue }
      $busy = @($slC.positions).Count + @($slC.pending | Where-Object { $_.kind -eq 'entry' }).Count
      if ($busy -ge $MAXCONC) { continue }
      if (@($slC.positions | Where-Object { $_.asset -eq $a }).Count -or @($slC.pending | Where-Object { $_.kind -eq 'entry' -and $_.asset -eq $a }).Count) { continue }
      $slC.pending = ToArr (@($slC.pending) + [pscustomobject]@{
        kind = 'entry'; sleeve = 'core'; asset = $a; side = $side; created_day = $D
        stop_dist = [math]::Round($ATR_STOP_CORE * $atr, 6); risk_pct = $cfg.core; note = "donchian close $cl vs [$([math]::Round($chLo,4)) / $([math]::Round($chHi,4))]" })
      $script:rfEvents.Add("RF SIGNAL [$($cfg.label)/core] $a $side @close $cl")
    }

    # setup A (дневки): тренд + откат к EMA20 + RSI-сброс + триггер (lib_rf_signals)
    $asig = Get-SetupASignal $s $i
    if ($null -ne $asig) {
      $sideA = [string]$asig.side
      $sw = [double]$asig.swing
      foreach ($cfg in $PROFILES) {
        $p = $profState[$cfg.id]
        $slA = $p.sleeves.setA
        if ($slA.halt_day -eq $D) { continue }
        $busy = @($slA.positions).Count + @($slA.pending | Where-Object { $_.kind -eq 'entry' }).Count
        if ($busy -ge $MAXCONC) { continue }
        if (@($slA.positions | Where-Object { $_.asset -eq $a }).Count -or @($slA.pending | Where-Object { $_.kind -eq 'entry' -and $_.asset -eq $a }).Count) { continue }
        $slA.pending = ToArr (@($slA.pending) + [pscustomobject]@{
          kind = 'entry'; sleeve = 'setA'; asset = $a; side = $sideA; created_day = $D
          swing = [math]::Round($sw, 6); atr = [math]::Round($atr, 6); risk_pct = $cfg.seta; note = 'setup A pullback' })
        $script:rfEvents.Add("RF SIGNAL [$($cfg.label)/setA] $a $sideA @close $cl")
      }
    }
  }

  # --- momentum: 1-й торговый день месяца (по серии IMOEX) ---
  $ix = Get-Ser 'IMOEX'
  $ii = Ser-IdxOfDay $ix $D
  if ($ii -gt 0) {
    $prevMonth = (SerDay $ix[$ii - 1]).Substring(0, 7)
    if ($mon -ne $prevMonth) {
      # гейт IMOEX>EMA200 + скоринг 63/21 - lib_rf_signals (общий с live-контуром)
      $msig = Get-MomentumTarget $D
      $gate = [bool]$msig.gate
      $target = @($msig.target)
      foreach ($cfg in $PROFILES) {
        $p = $profState[$cfg.id]
        $p.sleeves.mom.pending = ToArr (@($p.sleeves.mom.pending) + [pscustomobject]@{
          kind = 'rebalance'; created_day = $D; gate = $gate; target = @($target) })
        $p.sleeves.mom.last_rebalance_month = $mon
      }
      $script:rfEvents.Add("RF MOM-REBALANCE signal $D gate=$gate target=[$($target -join ',')]")
      $script:rfJournal.Add(("`r`n## {0} MSK — РФ АВТО: сигнал ребаланса momentum ({1}): гейт IMOEX>{2}EMA = {3}; цель: {4}`r`n" -f "$D 23:50", $mon, $IMOEX_EMA, $gate, $(if ($target.Count) { $target -join ', ' } else { 'кэш (гейт закрыт или нет кандидатов)' })))
    }
  }
}

function Invoke-RfRoll([string]$a, [string]$fromSec, [string]$toSec, [string]$D, [long]$tsMsk) {
  # цены обоих контрактов на день D
  $kOld = Get-IssCandles 'fut' $fromSec 24 $D $D
  $kNew = Get-IssCandles 'fut' $toSec 24 $D $D
  if (-not @($kOld).Count -or -not @($kNew).Count) { Write-TickLog $Root "RF roll $a deferred (нет баров $fromSec/$toSec на $D)"; return }
  $pxOld = [double]$kOld[-1].c; $pxNew = [double]$kNew[-1].c
  $ratio = $pxNew / $pxOld
  # рескейл непрерывной серии: история * ratio (якорь = новый контракт) - lib_rf_signals
  Invoke-SeriesRollRescale $a $ratio
  # позиции: закрыть по старому, переоткрыть по новому (2x комиссия + слип) - честнее бэктеста
  foreach ($cfg in $PROFILES) {
    $p = $profState[$cfg.id]
    foreach ($slName in 'core', 'setA') {
      $sl = $p.sleeves.$slName
      foreach ($pos in @($sl.positions | Where-Object { $_.asset -eq $a })) {
        $sm = if ($pos.side -eq 'long') { 1.0 } else { -1.0 }
        $fillOld = $pxOld * (1 - $sm * $SLIP)
        $gross = $sm * [double]$pos.qty * ($fillOld - [double]$pos.entry)
        $feeC = [double]$pos.qty * $fillOld * $FUT_FEE
        $sl.equity = [double]$sl.equity + $gross - $feeC
        $pos.realized = [double]$pos.realized + $gross - $feeC
        $qtyNew = [double]$pos.qty / $ratio
        $fillNew = $pxNew * (1 + $sm * $SLIP)
        $feeO = $qtyNew * $fillNew * $FUT_FEE
        $sl.equity = [double]$sl.equity - $feeO
        $pos.realized = [double]$pos.realized - $feeO
        $pos.fees = [double]$pos.fees + $feeC + $feeO
        $pos.entry = [math]::Round($fillNew, 6)
        $pos.qty = [math]::Round($qtyNew, 6)
        $pos.stop = [math]::Round([double]$pos.stop * $ratio, 6)
        if ($pos.PSObject.Properties['tp1'] -and $pos.tp1) { $pos.tp1 = [math]::Round([double]$pos.tp1 * $ratio, 6) }
        $pos.mfe = [math]::Round([double]$pos.mfe * $ratio, 6)
        $pos.secid = $toSec
        $pos.rolls = [int]$pos.rolls + 1
        $script:rfEvents.Add("RF ROLL [$($cfg.label)/$slName] $a $fromSec->$toSec")
      }
    }
  }
  $shared.active.$a = $toSec
  $script:rfJournal.Add(("`r`n## {0} MSK — РФ АВТО: ролл {1}: {2} → {3} (ratio {4})`r`n" -f (MsToUtcStr $tsMsk), $a, $fromSec, $toSec, [math]::Round($ratio, 5)))
}

# ================= ИНТРАДЕЙ ПРОХОД =================
function Invoke-RfIntraday {
  # активы/акции, где есть позиции или pending (по всем профилям)
  $needFut = New-Object System.Collections.Generic.List[string]
  $needStk = New-Object System.Collections.Generic.List[string]
  foreach ($cfg in $PROFILES) {
    $p = $profState[$cfg.id]
    foreach ($slName in 'core', 'setA') {
      foreach ($x in @($p.sleeves.$slName.positions)) { if (-not $needFut.Contains([string]$x.asset)) { $needFut.Add([string]$x.asset) } }
      foreach ($x in @($p.sleeves.$slName.pending)) { if (-not $needFut.Contains([string]$x.asset)) { $needFut.Add([string]$x.asset) } }
    }
    foreach ($x in @($p.sleeves.mom.pending)) {
      foreach ($t in @($x.target)) { if (-not $needStk.Contains([string]$t)) { $needStk.Add([string]$t) } }
      foreach ($h in @($p.sleeves.mom.holdings)) { if (-not $needStk.Contains([string]$h.sym)) { $needStk.Add([string]$h.sym) } }
    }
    foreach ($h in @($p.sleeves.mom.holdings)) { if (-not $needStk.Contains([string]$h.sym)) { $needStk.Add([string]$h.sym) } }
  }
  if (-not $needFut.Count -and -not $needStk.Count) { $shared.last_hour_ts = (FloorTo $mskNowMs $H1) - $H1; return }

  $fromTs = [long]$shared.last_hour_ts + $H1
  $lastClosedH = (FloorTo ($mskNowMs - 16 * 60000) $H1) - $H1   # задержка ISS ~15 мин
  if ($fromTs -gt $lastClosedH) { return }
  $fromDay = MsToUtcDay $fromTs

  $bars = @{}   # key -> array of hourly bars
  foreach ($a in $needFut) {
    $secid = [string]$shared.active.$a
    $all = Get-IssCandles 'fut' $secid 60 $fromDay   # присваивание разворачивает запятую-обёртку
    $bars["F:$a"] = @($all | Where-Object { [long]$_.t -ge $fromTs -and [long]$_.t -le $lastClosedH })
  }
  foreach ($t in $needStk) {
    $all = Get-IssCandles 'stock' $t 60 $fromDay
    $bars["S:$t"] = @($all | Where-Object { [long]$_.t -ge $fromTs -and [long]$_.t -le $lastClosedH })
  }

  # хронология по часам
  for ($ts = $fromTs; $ts -le $lastClosedH; $ts += $H1) {
    foreach ($cfg in $PROFILES) {
      $p = $profState[$cfg.id]
      foreach ($slName in 'core', 'setA') {
        $sl = $p.sleeves.$slName
        # pending entries/exits: исполняются на первом баре сессии дня > created_day
        foreach ($pd in @($sl.pending)) {
          $b = @($bars["F:$($pd.asset)"] | Where-Object { [long]$_.t -eq $ts })
          if (-not $b.Count) { continue }
          $b = $b[0]
          if ((MsToUtcDay $ts) -le [string]$pd.created_day) { continue }
          if ($pd.kind -eq 'entry') {
            $sm = if ($pd.side -eq 'long') { 1.0 } else { -1.0 }
            $fill = [double]$b.o * (1 + $sm * $SLIP)
            $stopDist = if ($pd.sleeve -eq 'core') { [double]$pd.stop_dist }
                        else { [math]::Max($sm * ($fill - [double]$pd.swing), $ATR_STOP_A * [double]$pd.atr) }
            if ($stopDist -le 0) { $sl.pending = ToArr (@($sl.pending) | Where-Object { $_ -ne $pd }); continue }
            $eq = [double]$sl.equity
            $riskUsd = $eq * [double]$pd.risk_pct
            $qty = $riskUsd / $stopDist
            if (($qty * $fill) -gt ($MAXLEV * $eq)) { $qty = $MAXLEV * $eq / $fill }
            $fee = $qty * $fill * $FUT_FEE
            $sl.equity = $eq - $fee
            $id = "R$($shared.next_trade_id)"; $shared.next_trade_id = [int]$shared.next_trade_id + 1
            $pos = [pscustomobject]@{
              id = $id; asset = $pd.asset; secid = [string]$shared.active.$($pd.asset); side = $pd.side
              qty = [math]::Round($qty, 6); qty_initial = [math]::Round($qty, 6)
              entry = [math]::Round($fill, 6); entry_day = (MsToUtcDay $ts); entry_ts = $ts
              stop = [math]::Round($fill - $sm * $stopDist, 6)
              tp1 = if ($pd.sleeve -eq 'setA') { [math]::Round($fill + $sm * $TPR * $stopDist, 6) } else { $null }
              tp1_done = $false; mfe = [math]::Round($fill, 6)
              risk_usd = [math]::Round($riskUsd, 2); entry_fee = [math]::Round($fee, 4); fees = 0.0; realized = 0.0; rolls = 0
            }
            $sl.positions = ToArr (@($sl.positions) + $pos)
            $sl.pending = ToArr (@($sl.pending) | Where-Object { $_ -ne $pd })
            $script:rfEvents.Add("RF ENTRY [$($cfg.label)/$slName] $id $($pd.asset) $($pd.side) @$([math]::Round($fill,4))")
            $script:rfJournal.Add(("`r`n## {0} MSK — РФ АВТО [{1}/{2}]: ВХОД {3} {4} {5} @{6}, стоп {7}, риск {8}`r`n" -f (MsToUtcStr $ts), $cfg.label, $slName, $id, $pd.asset, $pd.side.ToUpper(), [math]::Round($fill,4), $pos.stop, $pos.risk_usd))
          } elseif ($pd.kind -eq 'exit') {
            $pos = @($sl.positions | Where-Object { $_.id -eq $pd.pos_id })
            if ($pos.Count) {
              $sm = if ($pos[0].side -eq 'long') { 1.0 } else { -1.0 }
              [void](Rf-CloseFill $cfg $slName $pos[0] ([double]$b.o * (1 - $sm * $SLIP)) $ts ([string]$pd.reason))
            }
            $sl.pending = ToArr (@($sl.pending) | Where-Object { $_ -ne $pd })
          }
        }
        # стопы/TP по касанию
        foreach ($pos in @($sl.positions)) {
          $b = @($bars["F:$($pos.asset)"] | Where-Object { [long]$_.t -eq $ts })
          if (-not $b.Count) { continue }
          $b = $b[0]
          if ([long]$pos.entry_ts -ge $ts) { continue }
          $sm = if ($pos.side -eq 'long') { 1.0 } else { -1.0 }
          # gap-aware: первый бар новой сессии открылся за стопом
          $isSessionFirst = ((MsToUtcDay ([long]$b.t - $H1)) -ne (MsToUtcDay ([long]$b.t))) -or (-not @($bars["F:$($pos.asset)"] | Where-Object { [long]$_.t -eq ($ts - $H1) }).Count)
          $hitStop = if ($pos.side -eq 'long') { [double]$b.l -le [double]$pos.stop } else { [double]$b.h -ge [double]$pos.stop }
          if ($hitStop) {
            $base = [double]$pos.stop
            if ($isSessionFirst) {
              if (($pos.side -eq 'long' -and [double]$b.o -lt $base) -or ($pos.side -eq 'short' -and [double]$b.o -gt $base)) { $base = [double]$b.o }
            }
            $fill = $base * (1 - $sm * $STOPSLIP)
            $reason = if ($slName -eq 'core') { if (($sm -gt 0 -and $fill -gt [double]$pos.entry) -or ($sm -lt 0 -and $fill -lt [double]$pos.entry)) { 'atr-trail' } else { 'stop' } }
                      else { if ($pos.tp1_done) { 'be-stop' } else { 'stop' } }
            [void](Rf-CloseFill $cfg $slName $pos $fill $ts $reason)
            # дневной халт рукава
            $dl = ([double]$sl.day_start_eq - [double]$sl.equity) / [double]$sl.day_start_eq
            if ($dl -ge $HALT_PCT -and $sl.halt_day -ne (MsToUtcDay $ts)) {
              $sl.halt_day = (MsToUtcDay $ts)
              $sl.pending = ToArr (@($sl.pending) | Where-Object { $_.kind -ne 'entry' })
              $script:rfEvents.Add("RF DAY-HALT [$($cfg.label)/$slName] -$([math]::Round(100*$dl,1))%")
            }
            continue
          }
          if ($slName -eq 'setA' -and -not $pos.tp1_done -and $null -ne $pos.tp1) {
            $hitTp = if ($pos.side -eq 'long') { [double]$b.h -ge [double]$pos.tp1 } else { [double]$b.l -le [double]$pos.tp1 }
            if ($hitTp) {
              $half = [double]$pos.qty_initial * 0.5
              if ($half -gt [double]$pos.qty) { $half = [double]$pos.qty }
              $sm2 = if ($pos.side -eq 'long') { 1.0 } else { -1.0 }
              $gross = $sm2 * $half * ([double]$pos.tp1 - [double]$pos.entry)
              $fee = $half * [double]$pos.tp1 * $FUT_FEE
              $sl.equity = [double]$sl.equity + $gross - $fee
              $pos.realized = [double]$pos.realized + $gross - $fee
              $pos.fees = [double]$pos.fees + $fee
              $pos.qty = [math]::Round([double]$pos.qty - $half, 6)
              $pos.tp1_done = $true
              $pos.stop = [double]$pos.entry
              $script:rfEvents.Add("RF TP1 [$($cfg.label)/setA] $($pos.id) $($pos.asset)")
            }
          }
          # интрадей mfe (для трейла на дневном хуке)
          if ($pos.side -eq 'long' -and [double]$b.h -gt [double]$pos.mfe) { $pos.mfe = [double]$b.h }
          if ($pos.side -eq 'short' -and [double]$b.l -lt [double]$pos.mfe) { $pos.mfe = [double]$b.l }
        }
      }
      # momentum: ребаланс на первом баре сессии акций дня > created_day
      $slM = $p.sleeves.mom
      foreach ($pd in @($slM.pending)) {
        if ($null -eq $pd) { continue }
        if ((MsToUtcDay $ts) -le [string]$pd.created_day) { continue }
        # некого продавать и нечего покупать (гейт закрыт при пустом портфеле) - ребаланс-пустышка, снять
        $touchSyms = @(@($pd.target) + @($slM.holdings | ForEach-Object { $_.sym }) | Where-Object { $_ } | Sort-Object -Unique)
        if (-not $touchSyms.Count) {
          $slM.pending = ToArr (@($slM.pending) | Where-Object { $_ -ne $pd })
          continue
        }
        # нужен бар хотя бы одного затронутого тикера в этот час
        $anyBar = $false
        foreach ($t in $touchSyms) {
          if (@($bars["S:$t"] | Where-Object { [long]$_.t -eq $ts }).Count) { $anyBar = $true; break }
        }
        if (-not $anyBar) { continue }
        # sells: всё, чего нет в target (или всё при gate=false)
        foreach ($h in @($slM.holdings)) {
          if ($pd.gate -and (@($pd.target) -contains [string]$h.sym)) { continue }
          $b = @($bars["S:$($h.sym)"] | Where-Object { [long]$_.t -eq $ts })
          if (-not $b.Count) { continue }   # не торгуется - оставляем (как бэктест)
          $px = [double]$b[0].o
          $val = [double]$h.qty * $px
          $cost = $val * $MOM_COST
          $slM.cash = [double]$slM.cash + $val - $cost
          $pnl = [math]::Round(($px - [double]$h.entry) * [double]$h.qty - $cost, 2)
          $script:rfClosed.Add([pscustomobject]@{
            id = "M$($shared.next_trade_id)"; profile = $cfg.label; sleeve = 'mom'; sym = $h.sym; secid = $h.sym
            side = 'long'; entryDay = $h.entry_day; entry = [double]$h.entry; qty = [double]$h.qty
            exitDay = (MsToUtcDay $ts); exitPx = $px; exitReason = $(if ($pd.gate) { 'rebalance-out' } else { 'gate-off' })
            pnlUsd = $pnl; rMultiple = $null; riskUsd = $null; fees = [math]::Round($cost, 2); rolls = 0 })
          $shared.next_trade_id = [int]$shared.next_trade_id + 1
          $st = $p.stats; $st.trades = [int]$st.trades + 1
          if ($pnl -gt 0) { $st.wins = [int]$st.wins + 1 } else { $st.losses = [int]$st.losses + 1 }
          $st.fees = [math]::Round([double]$st.fees + $cost, 2); $st.realized = [math]::Round([double]$st.realized + $pnl, 2)
          $slM.holdings = ToArr (@($slM.holdings) | Where-Object { $_.sym -ne $h.sym })
          $script:rfEvents.Add("RF MOM SELL [$($cfg.label)] $($h.sym) $pnl")
        }
        # buys: новые имена, equal-split кэша
        if ($pd.gate) {
          $newNames = @($pd.target | Where-Object { $n = $_; -not @($slM.holdings | Where-Object { $_.sym -eq $n }).Count })
          $avail = @()
          foreach ($n in $newNames) { if (@($bars["S:$n"] | Where-Object { [long]$_.t -eq $ts }).Count) { $avail += $n } }
          if ($avail.Count -and [double]$slM.cash -gt 1) {
            $spendPer = [double]$slM.cash / $avail.Count
            foreach ($n in $avail) {
              $b = @($bars["S:$n"] | Where-Object { [long]$_.t -eq $ts })[0]
              $px = [double]$b.o
              $fee = $spendPer * $MOM_COST
              $qty = ($spendPer - $fee) / $px
              $slM.cash = [double]$slM.cash - $spendPer
              $slM.holdings = ToArr (@($slM.holdings) + [pscustomobject]@{ sym = $n; qty = [math]::Round($qty, 6); entry = [math]::Round($px, 4); entry_day = (MsToUtcDay $ts) })
              $script:rfEvents.Add("RF MOM BUY [$($cfg.label)] $n @$px")
            }
          }
        }
        $slM.pending = ToArr (@($slM.pending) | Where-Object { $_ -ne $pd })
        $script:rfJournal.Add(("`r`n## {0} MSK — РФ АВТО [{1}/mom]: ребаланс исполнен; держим: {2}; кэш {3}`r`n" -f (MsToUtcStr $ts), $cfg.label, $(if (@($slM.holdings).Count) { @($slM.holdings | ForEach-Object { $_.sym }) -join ', ' } else { '—' }), [math]::Round([double]$slM.cash, 2)))
      }
    }
  }
  $shared.last_hour_ts = $lastClosedH
}

# ================= MTM =================
function Invoke-RfMtm {
  # последние цены: активные фьючи + акции холдингов
  $px = @{}
  $needF = New-Object System.Collections.Generic.List[string]
  $needS = New-Object System.Collections.Generic.List[string]
  foreach ($cfg in $PROFILES) {
    $p = $profState[$cfg.id]
    foreach ($slName in 'core', 'setA') { foreach ($x in @($p.sleeves.$slName.positions)) { if (-not $needF.Contains([string]$x.asset)) { $needF.Add([string]$x.asset) } } }
    foreach ($h in @($p.sleeves.mom.holdings)) { if (-not $needS.Contains([string]$h.sym)) { $needS.Add([string]$h.sym) } }
  }
  foreach ($a in $needF) {
    $s = Get-Ser $a
    $px["F:$a"] = [double]$s[$s.Count - 1].c
    try {
      $k = Get-IssCandles 'fut' ([string]$shared.active.$a) 60 (MsToUtcDay ($mskNowMs - $DAY)) (MsToUtcDay $mskNowMs)
      $k = @($k | Where-Object { [long]$_.t -le $mskNowMs })   # не подглядывать вперёд при реплеях
      if ($k.Count) { $px["F:$a"] = [double]$k[-1].c }
    } catch {}
  }
  foreach ($t in $needS) {
    $s = Get-Ser $t
    $px["S:$t"] = [double]$s[$s.Count - 1].c
    try {
      $k = Get-IssCandles 'stock' $t 60 (MsToUtcDay ($mskNowMs - $DAY)) (MsToUtcDay $mskNowMs)
      $k = @($k | Where-Object { [long]$_.t -le $mskNowMs })
      if ($k.Count) { $px["S:$t"] = [double]$k[-1].c }
    } catch {}
  }
  foreach ($cfg in $PROFILES) {
    $p = $profState[$cfg.id]
    foreach ($slName in 'core', 'setA') {
      $sl = $p.sleeves.$slName
      $unreal = 0.0
      foreach ($pos in @($sl.positions)) {
        $cur = if ($px.ContainsKey("F:$($pos.asset)")) { [double]$px["F:$($pos.asset)"] } else { [double]$pos.entry }
        $sm = if ($pos.side -eq 'long') { 1.0 } else { -1.0 }
        $pu = $sm * [double]$pos.qty * ($cur - [double]$pos.entry)
        # сохраняем текущую цену и плавающий P&L на позиции — для дашборда (вкладка «Фьючерсы → Реальная»)
        if (-not $pos.PSObject.Properties['cur'])  { $pos | Add-Member -NotePropertyName cur  -NotePropertyValue 0.0 }
        if (-not $pos.PSObject.Properties['upnl']) { $pos | Add-Member -NotePropertyName upnl -NotePropertyValue 0.0 }
        $pos.cur  = [math]::Round($cur, 6)
        $pos.upnl = [math]::Round($pu, 2)
        $unreal += $pu
      }
      # equity рукава = реализованное (уже в equity) + нереализованное (пересчитываем на лету в отдельном поле)
      if (-not $sl.PSObject.Properties['equity_mtm']) { $sl | Add-Member -NotePropertyName equity_mtm -NotePropertyValue 0.0 }
      $sl.equity_mtm = [math]::Round([double]$sl.equity + $unreal, 2)
    }
    $slM = $p.sleeves.mom
    $hv = 0.0
    foreach ($h in @($slM.holdings)) {
      $cur = if ($px.ContainsKey("S:$($h.sym)")) { [double]$px["S:$($h.sym)"] } else { [double]$h.entry }
      $hv += [double]$h.qty * $cur
    }
    $slM.equity = [math]::Round([double]$slM.cash + $hv, 2)
    if (-not $slM.PSObject.Properties['equity_mtm']) { $slM | Add-Member -NotePropertyName equity_mtm -NotePropertyValue 0.0 }
    $slM.equity_mtm = $slM.equity
    # профиль: помесячно-аддитивно от месячных стартов
    $rC = ([double]$p.sleeves.core.equity_mtm / [double]$p.sleeves.core.month_start_eq) - 1
    $rA = ([double]$p.sleeves.setA.equity_mtm / [double]$p.sleeves.setA.month_start_eq) - 1
    $rM = ([double]$slM.equity_mtm / [double]$slM.month_start_eq) - 1
    $p.profile_eq = [math]::Round([double]$p.profile_month_start * (1 + $rC + $rA + $cfg.mom * $rM), 2)
    if ([double]$p.profile_eq -gt [double]$p.peak_eq) { $p.peak_eq = [double]$p.profile_eq }
  }
}

# ================= РУЧНОЕ ЗАКРЫТИЕ (заявки из Telegram-ассистента) =================
# Транспорт: data\rf\manual_close_req.json пишет ТОЛЬКО ассистент (VPS), результаты в
# data\rf\manual_close_res.json пишет ТОЛЬКО этот движок (Actions). Идемпотентность - реестр
# обработанных req_id в res-файле (заявки не удаляются). Вызывается ПОСЛЕ Invoke-RfIntraday:
# если позицию уже вынесло стопом в догнанных часах, заявка честно получает not-found.
function Invoke-RfManualClose {
  $reqPath = Join-Path $rfDir 'manual_close_req.json'
  $resPath = Join-Path $rfDir 'manual_close_res.json'
  $req = Read-JsonFile $reqPath
  if ($null -eq $req -or -not @($req.requests | Where-Object { $null -ne $_ }).Count) { return }
  $res = Read-JsonFile $resPath
  if ($null -eq $res) { $res = [pscustomobject]@{ schema = 1; results = @() } }
  $res.results = ToArr (@($res.results) | Where-Object { $null -ne $_ })
  $done = @{}; foreach ($r in @($res.results)) { $done[[string]$r.req_id] = $true }
  $newRes = $false

  foreach ($rq in @($req.requests | Where-Object { $null -ne $_ })) {
    if ([string]$rq.contour -ne 'paper') { continue }
    if (-not $rq.req_id -or $done.ContainsKey([string]$rq.req_id)) { continue }
    $sleeve = [string]$rq.sleeve; $asset = [string]$rq.asset
    $rec = [pscustomobject]@{ req_id = [string]$rq.req_id; status = ''; executed_utc = (MsToUtcStr $NowMs)
      chat_id = [string]$rq.chat_id; closed = @(); note = '' }

    # TTL 24ч (нечитаемый requested_utc = тоже протух)
    $reqMs = [long]0
    try { $reqMs = UtcStrToMs ([string]$rq.requested_utc) } catch {}
    if (($reqMs + 24 * 3600000) -lt $NowMs) {
      $rec.status = 'expired'; $rec.note = "заявка от $($rq.requested_utc) UTC старше 24ч - не исполнена"
    } elseif ($sleeve -notin @('core', 'setA') -or $asset -notin $ASSETS) {
      $rec.status = 'not-found'; $rec.note = "неизвестный актив/рукав: $asset/$sleeve"
    } else {
      # цена: последняя закрытая h1 активного контракта (как Invoke-RfMtm), фолбэк - close дневной серии
      $s = Get-Ser $asset
      $px = [double]$s[$s.Count - 1].c
      try {
        $k = Get-IssCandles 'fut' ([string]$shared.active.$asset) 60 (MsToUtcDay ($mskNowMs - $DAY)) (MsToUtcDay $mskNowMs)
        $k = @($k | Where-Object { [long]$_.t -le $mskNowMs })   # не подглядывать вперёд при реплеях
        if ($k.Count) { $px = [double]$k[-1].c }
      } catch {}
      foreach ($cfg in $PROFILES) {   # зеркально в обоих профилях - иначе портфели разойдутся
        $sl = $profState[$cfg.id].sleeves.$sleeve
        $pos = @($sl.positions | Where-Object { $_.asset -eq $asset })
        if (-not $pos.Count) { continue }
        $sm = if ($pos[0].side -eq 'long') { 1.0 } else { -1.0 }
        $fill = $px * (1 - $sm * $SLIP)
        [void](Rf-CloseFill $cfg $sleeve $pos[0] $fill $mskNowMs 'manual-tg')
        $cl = $script:rfClosed[$script:rfClosed.Count - 1]
        $rec.closed = ToArr (@($rec.closed) + [pscustomobject]@{
          profile = $cl.profile; id = $cl.id; asset = $cl.sym; side = $cl.side
          px = $cl.exitPx; pnl = $cl.pnlUsd; r = $cl.rMultiple })
      }
      if (@($rec.closed).Count) {
        $rec.status = 'done'
      } else {
        $rec.status = 'not-found'
        # позиции нет - поискать недавнее закрытие этого актива, чтобы объяснить пользователю
        $lt = @((Read-JsonFile (Join-Path $rfDir 'rf_trades.json')) | Where-Object { $null -ne $_ -and $_.sym -eq $asset -and $_.sleeve -eq $sleeve })
        if ($lt.Count) { $x = $lt[-1]; $rec.note = "позиция уже закрыта движком: $($x.exitReason) @$($x.exitPx) ($($x.exitUtcMsk) MSK)" }
        else { $rec.note = "открытой позиции $asset/$sleeve нет" }
      }
    }
    $res.results = ToArr (@($res.results) + $rec)
    $newRes = $true
    $script:rfEvents.Add("RF MANUAL-CLOSE $asset/$sleeve $($rec.status)")
  }

  if ($newRes) {
    # держим последние 200 записей, чтобы файл не рос вечно
    $all = @($res.results)
    if ($all.Count -gt 200) { $res.results = ToArr ($all | Select-Object -Last 200) }
    if (-not $DryRun) { Write-JsonAtomic $resPath $res 8 }
  }
}

# ================= RUN =================
try {
  if ([string]$shared.last_daily_day -lt $completedDay) { Invoke-RfDaily }
  Invoke-RfIntraday
  Invoke-RfManualClose
  Invoke-RfMtm

  $shared.last_tick_utc = MsToUtcStr $NowMs
  if (-not $DryRun) {
    Write-JsonAtomic $sharedPath $shared 8
    foreach ($cfg in $PROFILES) { Write-JsonAtomic (Join-Path $rfDir "$($cfg.id)_portfolio.json") $profState[$cfg.id] 10 }
    if ($script:rfClosed.Count) {
      $ltPath = Join-Path $rfDir 'rf_trades.json'
      $lt = New-Object System.Collections.Generic.List[object]
      foreach ($x in @((Read-JsonFile $ltPath))) { if ($null -ne $x) { $lt.Add($x) } }
      $have = @{}; foreach ($x in $lt) { $have["$($x.profile)|$($x.id)"] = $true }
      foreach ($r in $script:rfClosed) { if (-not $have.ContainsKey("$($r.profile)|$($r.id)")) { $lt.Add($r) } }
      Write-JsonAtomic $ltPath (ToArr $lt) 8
    }
    # кривая эквити
    $eqPath = Join-Path $rfDir 'rf_equity.json'
    $eq = New-Object System.Collections.Generic.List[object]
    foreach ($x in @((Read-JsonFile $eqPath))) { if ($null -ne $x) { $eq.Add($x) } }
    $nowStr = MsToUtcStr $NowMs
    if (-not $eq.Count -or [string]$eq[$eq.Count-1].utc -ne $nowStr) {
      # покривые по рынкам: futCx = аддитивная комбинация фьючерсных рукавов (ядро+сетап A), mom = акции (одинаков для профилей)
      function SlEq($sl) { if ($sl.PSObject.Properties['equity_mtm'] -and [double]$sl.equity_mtm -gt 0) { [double]$sl.equity_mtm } else { [double]$sl.equity } }
      $c2p = $profState['c2']; $c3p = $profState['c3b']
      $futC2  = [math]::Round(10000.0 * ((SlEq $c2p.sleeves.core) / 10000.0 + (SlEq $c2p.sleeves.setA) / 10000.0 - 1), 2)
      $futC3b = [math]::Round(10000.0 * ((SlEq $c3p.sleeves.core) / 10000.0 + (SlEq $c3p.sleeves.setA) / 10000.0 - 1), 2)
      $eq.Add([pscustomobject]@{ utc = $nowStr; ts = $NowMs
        c2 = [double]$profState['c2'].profile_eq; c3b = [double]$profState['c3b'].profile_eq
        mom = [math]::Round([double]$c2p.sleeves.mom.equity, 2); futC2 = $futC2; futC3b = $futC3b })
      Write-JsonAtomic $eqPath (ToArr $eq) 4
    }
    if ($script:rfJournal.Count) { Write-Journal $Root ($script:rfJournal -join '') }
  }
  $evTxt = if ($script:rfEvents.Count) { $script:rfEvents -join '; ' } else { '-' }
  Write-TickLog $Root ("RF ok: {0} | C2={1} C3b={2}" -f $evTxt, $profState['c2'].profile_eq, $profState['c3b'].profile_eq)
  "RF тик: события: $evTxt | C2 $($profState['c2'].profile_eq) | C3b $($profState['c3b'].profile_eq)"
} catch {
  Write-TickLog $Root ("RF ERROR: " + $_.Exception.Message + ' @ ' + ($_.ScriptStackTrace -split "`n")[0])
  Write-Warning "РФ-контур: тик отменён: $($_.Exception.Message)"
}
