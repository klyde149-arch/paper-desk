# rf_observer.ps1 - НАБЛЮДАТЕЛЬ стратегий RF (этап 4 плана восстановления 2026-09-19).
# Три независимых ВИРТУАЛЬНЫХ портфеля на живых данных. Денег не трогает вообще.
#
# ПОЧЕМУ ОТДЕЛЬНЫЙ ПРОЦЕСС, А НЕ ВЕТКА В ДВИЖКЕ:
#   1) у наблюдателя структурно НЕТ торгового транспорта - lib_tinvest.ps1 здесь не дот-сорсится,
#      поэтому Post-TiOrder / Cancel-TiOrder / Post-TiStopOrder / Ensure-RubFunding в его области
#      видимости просто не существуют. Это гарантия по построению, а не по флагу;
#   2) его сбой или медленный расчёт не задерживает сопровождение реальных позиций: боевой тик
#      к нему не обращается.
#
# ЧИТАЕТ (только чтение): data/live_rf/series/*.json (дневные серии ведёт движок),
#   data/live_rf/portfolio.json (денежная база и активные контракты), data/live_rf/config.json
#   (риск-политика). ПИШЕТ только в свой каталог data/live_rf/observer.
#
# ТРИ ВАРИАНТА (план §7):
#   core_2atr   - вечерний Core, исходный стоп 2 ATR (эталон: ровно то, что делает боевой Core);
#   core_cap2   - вечерний Core, стоп не дальше 2% от входа, объём ПРЕЖНИЙ (от стопа 2 ATR);
#   core_hourly - вход по ЗАВЕРШЁННОМУ часу, выходы те же, что у core_2atr.
# Плюс отдельный ВИРТУАЛЬНЫЙ журнал Setup A: в бою его новые входы выключены (setA.new_entries),
# и без этого журнала о его сигналах не осталось бы никакого следа. Мест и риска в реальном
# портфеле он не занимает - это отдельный список решений, не портфель.
# У каждого свои позиции, свои занятые места и свои последующие сигналы: вариант, взявший сделку,
# дальше живёт своей жизнью. Улучшать цену у списка реальных сделок нельзя - это была бы подгонка.
#
# ОБЩИЕ С БОЕМ: сигнальные функции (lib_rf_signals), расчёт риска и стопа (lib_rf_risk), денежная
# база, лимиты, модель расходов, округление лотов вниз. Формулы НЕ копируются - вызываются те же.
param(
  [string]$Root = '',
  [long]$NowMs = 0,
  [string]$OutDir = '',
  # Каталог с часовыми барами в виде файлов <secid>_<yyyy-MM-dd>.json. Задан - часовые бары
  # берутся ОТТУДА и сеть не трогается вовсе (герметичные тесты). Не задан - обычный путь через
  # MOEX ISS, как у боевого контура.
  [string]$HourlyDir = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'lib_engine.ps1')
. (Join-Path $PSScriptRoot 'lib_rf_risk.ps1')
$lrfDir = Join-Path $Root 'data\live_rf'
$serDir = Join-Path $lrfDir 'series'          # требование lib_rf_signals: определить ДО Get-Ser
. (Join-Path $PSScriptRoot 'lib_rf_signals.ps1')
if ($NowMs -le 0) { $NowMs = UtcNowMs }
if (-not $OutDir) { $OutDir = Join-Path $lrfDir 'observer' }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force $OutDir | Out-Null }

$mskNowMs = $NowMs + $MSK
$mskToday = MsToUtcDay $mskNowMs
$completedDay = Get-RfCompletedDay $mskNowMs
$statePath = Join-Path $OutDir 'state.json'
$journalPath = Join-Path $OutDir 'decisions.jsonl'
$VARIANTS = @('core_2atr', 'core_cap2', 'core_hourly')
$JOURNAL_MAX = 5000

function Obs-Log([string]$Line) {
  $p = Join-Path $OutDir 'observer_log.txt'
  [IO.File]::AppendAllText($p, ((MsToUtcStr $NowMs) + 'Z ' + $Line + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
}

# ---- журнал решений: одна строка = одно решение, восстановимое целиком ----
# Поля закреплены планом §7: актив/контракт, версия правил, временные метки, уровень пробоя, ATR,
# расстояние до уровня, цена и её возраст, исходный/эффективный стоп, лоты, риск до/после, ГО,
# причина допуска/отказа. Секретов здесь нет и быть не должно.
function Write-Decision($Rec) {
  $line = ConvertTo-Json -InputObject $Rec -Depth 8 -Compress
  [IO.File]::AppendAllText($journalPath, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
}
function Trim-Journal {
  if (-not (Test-Path $journalPath)) { return }
  $lines = @(Get-Content $journalPath -Encoding UTF8)
  if ($lines.Count -le $JOURNAL_MAX) { return }
  $keep = $lines[($lines.Count - $JOURNAL_MAX)..($lines.Count - 1)]
  [IO.File]::WriteAllLines($journalPath, $keep, (New-Object System.Text.UTF8Encoding($false)))
}

function New-VariantState([double]$Eq) {
  [pscustomobject]@{ eq_rub = $Eq; positions = @(); closed = 0; wins = 0; realized_rub = 0.0
    fees_rub = 0.0; rearm = [pscustomobject]@{} }
}

# ---- загрузка боевого контекста (ТОЛЬКО чтение) ----
$live = Read-JsonFile (Join-Path $lrfDir 'portfolio.json')
if ($null -eq $live) { Obs-Log 'нет portfolio.json - наблюдать не от чего'; return }
$cfgRaw = Read-JsonFile (Join-Path $lrfDir 'config.json')
$rp = Resolve-RfRiskPolicy $(if ($null -ne $cfgRaw -and $cfgRaw.PSObject.Properties['rf_risk_policy']) { $cfgRaw.rf_risk_policy } else { $null })
if (-not $rp.ok) { Obs-Log "конфиг риск-политики отклонён: $($rp.error) - наблюдение остановлено"; return }
# Денежная база у всех вариантов ОДНА и та же и берётся из боевой сводки: сравнивать варианты
# можно только при одинаковых деньгах. Если база неизвестна - наблюдать нечего.
$capital = 0.0
if ($live.PSObject.Properties['risk_budget'] -and $null -ne $live.risk_budget -and [double]$live.risk_budget.capital_rub -gt 0) {
  $capital = [double]$live.risk_budget.capital_rub
} elseif ($live.go.PSObject.Properties['bot_capital_account_rub']) { $capital = [double]$live.go.bot_capital_account_rub }
if ($capital -le 0) { Obs-Log 'капитал неизвестен - наблюдение пропущено'; return }

$st = Read-JsonFile $statePath
if ($null -eq $st) {
  $st = [pscustomobject]@{ schema = 1; created = (MsToUtcStr $NowMs); last_day = ''
    variants = [pscustomobject]@{} }
  foreach ($v in $VARIANTS) { $st.variants | Add-Member -NotePropertyName $v -NotePropertyValue (New-VariantState $capital) -Force }
  Obs-Log "наблюдатель инициализирован, база $([math]::Round($capital,2)) ₽"
}
foreach ($v in $VARIANTS) {
  if (-not $st.variants.PSObject.Properties[$v]) { $st.variants | Add-Member -NotePropertyName $v -NotePropertyValue (New-VariantState $capital) -Force }
  $st.variants.$v.positions = ToArr (@($st.variants.$v.positions) | Where-Object { $null -ne $_ })
}

# ГРАБЛЯ: имя $P занять нельзя - в циклах ниже используется $p (позиция), а PowerShell
# регистр не различает: foreach ($p in ...) затирал политику, и бюджет становился 0.
$POL = $rp.p
$feePct = [double]$POL.cost.fee_pct_side
$slipPct = [double]$POL.cost.stop_slip_pct

# ---- инструмент: только справочные числа из боевого кэша, без обращений к брокеру ----
$instCache = Read-JsonFile (Join-Path $lrfDir 'instruments.json')
function Obs-Inst([string]$Secid) {
  if ($null -eq $instCache -or -not $instCache.PSObject.Properties[$Secid]) { return $null }
  return $instCache.$Secid
}

# ---- сайзинг: те же чистые функции, что у боя ----
function Obs-Size([string]$Side, [double]$Entry, [double]$StopDist, $Inst, [double]$Budget, [double]$CapPct) {
  $rubPt = [double]$Inst.rub_per_pt
  if ($rubPt -le 0 -or $StopDist -le 0) { return $null }
  $tick = [double]$Inst.min_price_increment
  $sm = if ($Side -eq 'long') { 1.0 } else { -1.0 }
  $stratStop = $Entry - $sm * $StopDist
  $eff = if ($CapPct -gt 0) { Get-RfEffectiveStop $Side $Entry $stratStop $CapPct $tick } else { $null }
  $effStop = if ($null -ne $eff -and $eff.valid) { [double]$eff.stop } else { $stratStop }
  $costLot = Get-RfCostPerLot $Entry $rubPt $feePct $slipPct
  # объём считаем ВСЕГДА от ИСХОДНОГО стопа (2 ATR): в этом и смысл сравнения - у core_cap2
  # объём «прежний», меняется только защита. Приближение стопа само по себе объём не увеличивает.
  $lossPerLot = $StopDist * $rubPt + [double]$costLot
  if ($lossPerLot -le 0) { return $null }
  $lots = [int][math]::Floor($Budget / $lossPerLot)
  if ($lots -lt 1) { return $null }
  return [pscustomobject]@{ lots = $lots; stop = [math]::Round($effStop, 6); strat_stop = [math]::Round($stratStop, 6)
    loss_per_lot = [math]::Round($lossPerLot, 2); rub_per_pt = $rubPt }
}

# ---- один торговый день для одного варианта ----
function Step-Variant([string]$Variant, [string]$Day, [string]$Asset, $Bars, [int]$Idx, [double]$Atr, $Inst, $EntryCtx) {
  $vs = $st.variants.$Variant
  $bar = $Bars[$Idx]
  $secid = if ($null -ne $Inst) { [string]$Inst.ticker } else { '' }

  # 1. сопровождение открытых позиций этого варианта: MFE -> трейл -> проверка стопа по бару
  $keep = New-Object System.Collections.Generic.List[object]
  foreach ($p in @($vs.positions)) {
    if ($null -eq $p) { continue }
    if ([string]$p.asset -ne $Asset) { $keep.Add($p); continue }
    $side = [string]$p.side
    if ($side -eq 'long' -and [double]$bar.h -gt [double]$p.mfe) { $p.mfe = [double]$bar.h }
    if ($side -eq 'short' -and [double]$bar.l -lt [double]$p.mfe) { $p.mfe = [double]$bar.l }
    $ns = Get-ChandelierStop $side ([double]$p.mfe) ([double]$p.stop) $Atr
    if ($null -ne $ns) { $p.stop = [double]$ns }
    # стоп внутри дня: лонг - по low, шорт - по high. Гэп исполняется по открытию (хуже стопа).
    $hit = $false; $fill = 0.0
    if ($side -eq 'long' -and [double]$bar.l -le [double]$p.stop) {
      $hit = $true; $fill = [math]::Min([double]$bar.o, [double]$p.stop) * (1 - $slipPct)
    } elseif ($side -eq 'short' -and [double]$bar.h -ge [double]$p.stop) {
      $hit = $true; $fill = [math]::Max([double]$bar.o, [double]$p.stop) * (1 + $slipPct)
    }
    if (-not $hit) { $keep.Add($p); continue }
    $sm = if ($side -eq 'long') { 1.0 } else { -1.0 }
    $gross = $sm * ([double]$fill - [double]$p.entry) * [int]$p.lots * [double]$p.rub_per_pt
    $fee = [double]$fill * [int]$p.lots * [double]$p.rub_per_pt * $feePct
    $net = $gross - $fee
    $vs.eq_rub = [double]$vs.eq_rub + $net
    $vs.realized_rub = [double]$vs.realized_rub + $net
    $vs.fees_rub = [double]$vs.fees_rub + $fee + [double]$p.fee_entry
    $vs.closed = [int]$vs.closed + 1
    if ($net -gt 0) { $vs.wins = [int]$vs.wins + 1 }
    # re-arm: как в бою, ключ профиля на актив
    $vs.rearm | Add-Member -NotePropertyName $Asset -NotePropertyValue ([pscustomobject]@{ exit_day = $Day; dir = $side }) -Force
    Write-Decision ([ordered]@{ ts = $NowMs; utc = (MsToUtcStr $NowMs); variant = $Variant; kind = 'exit'
      day = $Day; asset = $Asset; contract = [string]$p.secid; side = $side; lots = [int]$p.lots
      entry = [double]$p.entry; exit = [math]::Round($fill, 6); stop = [double]$p.stop
      gross_rub = [math]::Round($gross, 2); fee_rub = [math]::Round($fee, 2); net_rub = [math]::Round($net, 2)
      eq_after_rub = [math]::Round([double]$vs.eq_rub, 2); reason = 'stop' })
  }
  $vs.positions = ToArr $keep

  # 2. вход: сигнал уже посчитан вызывающим (EntryCtx = $null, если сигнала нет)
  if ($null -eq $EntryCtx) { return }
  $side = [string]$EntryCtx.side
  $busy = @($vs.positions).Count
  $has = @(@($vs.positions) | Where-Object { [string]$_.asset -eq $Asset }).Count
  $capPct = if ($Variant -eq 'core_cap2') { [double]$POL.core.stop_cap_pct } else { 0.0 }
  $budget = [double]$vs.eq_rub * [double]$POL.core.risk_pct
  $entryPx = [double]$EntryCtx.px
  $stopDist = [double]$ATR_STOP_CORE * $Atr
  $sz = if ($null -ne $Inst) { Obs-Size $side $entryPx $stopDist $Inst $budget $capPct } else { $null }

  $deny = ''
  if ($null -eq $Inst) { $deny = 'нет справочных данных контракта' }
  elseif ($busy -ge $MAXCONC) { $deny = "мест нет ($busy из $MAXCONC)" }
  elseif ($has) { $deny = 'позиция по активу уже есть' }
  elseif ($null -eq $sz) { $deny = 'объём 0 по бюджету' }

  $goRub = if ($null -ne $Inst -and $null -ne $sz) {
    [math]::Round([int]$sz.lots * $(if ($side -eq 'long') { [double]$Inst.go_buy } else { [double]$Inst.go_sell }), 2) } else { $null }
  $rec = [ordered]@{
    ts = $NowMs; utc = (MsToUtcStr $NowMs); variant = $Variant; kind = 'entry'
    day = $Day; asset = $Asset; contract = $secid; side = $side
    rules_version = [string]$rp.hash; policy_id = [string]$rp.policy_id; schema = [int]$POL.schema_version
    t_signal = [string]$EntryCtx.t_signal; t_decision = (MsToUtcStr $NowMs)
    level = $(if ($null -ne $EntryCtx.level) { [math]::Round([double]$EntryCtx.level, 6) } else { $null })
    atr = [math]::Round($Atr, 6)
    dist_to_level = $(if ($null -ne $EntryCtx.level) { [math]::Round([double]$entryPx - [double]$EntryCtx.level, 6) } else { $null })
    px = [math]::Round($entryPx, 6); px_source = [string]$EntryCtx.px_source; px_age_sec = $EntryCtx.px_age_sec
    stop_strategy = $(if ($null -ne $sz) { $sz.strat_stop } else { $null })
    stop_effective = $(if ($null -ne $sz) { $sz.stop } else { $null })
    lots = $(if ($null -ne $sz) { [int]$sz.lots } else { 0 })
    budget_rub = [math]::Round($budget, 2)
    risk_before_rub = [math]::Round((Get-ObsOpenRisk $Variant), 2)
    risk_after_rub = $(if ($null -ne $sz) { [math]::Round((Get-ObsOpenRisk $Variant) + [int]$sz.lots * [double]$sz.loss_per_lot, 2) } else { $null })
    go_rub = $goRub
    eq_rub = [math]::Round([double]$vs.eq_rub, 2)
    allow = (-not $deny); reason = $(if ($deny) { $deny } else { 'вход принят' })
  }
  Write-Decision $rec
  if ($deny) { return }

  $feeEntry = $entryPx * [int]$sz.lots * [double]$sz.rub_per_pt * $feePct
  $vs.eq_rub = [double]$vs.eq_rub - $feeEntry
  $vs.positions = ToArr (@($vs.positions) + [pscustomobject]@{
    asset = $Asset; secid = $secid; side = $side; lots = [int]$sz.lots; entry = [math]::Round($entryPx, 6)
    stop = [double]$sz.stop; strat_stop = [double]$sz.strat_stop; mfe = [math]::Round($entryPx, 6)
    rub_per_pt = [double]$sz.rub_per_pt; entry_day = $Day; fee_entry = [math]::Round($feeEntry, 2)
    loss_per_lot = [double]$sz.loss_per_lot })
}

# суммарный открытый риск варианта (до стопа, с расходами) - для журнала «риск до/после»
function Get-ObsOpenRisk([string]$Variant) {
  $sum = 0.0
  foreach ($p in @($st.variants.$Variant.positions)) {
    if ($null -eq $p) { continue }
    $sm = if ([string]$p.side -eq 'long') { 1.0 } else { -1.0 }
    $d = $sm * ([double]$p.entry - [double]$p.stop)
    if ($d -lt 0) { $d = 0.0 }
    $sum += $d * [int]$p.lots * [double]$p.rub_per_pt
  }
  return $sum
}

# ---- главный проход: по всем новым завершённым дням ----
$lastDay = [string]$st.last_day
$days = New-Object System.Collections.Generic.List[string]
foreach ($a in $ASSETS) {
  $s = Get-Ser $a
  for ($j = $s.Count - 1; $j -ge 0; $j--) {
    $d = SerDay $s[$j]
    if ($lastDay -and $d -le $lastDay) { break }
    if ($d -le $completedDay -and -not $days.Contains($d)) { $days.Add($d) }
  }
}
$days = @($days | Sort-Object)
if (-not $days.Count) { Obs-Log "новых завершённых дней нет (последний обработанный: $lastDay)"; return }
# первый запуск: не переигрываем всю историю - берём только последний завершённый день
if (-not $lastDay -and $days.Count -gt 1) { $days = @($days[$days.Count - 1]) }

$hourlyFails = 0
foreach ($D in $days) {
  foreach ($a in $ASSETS) {
    $s = Get-Ser $a
    $i = Ser-IdxOfDay $s $D
    if ($i -lt 0 -or $i -lt ($BRK_N + 1)) { continue }
    $atr = Ser-ATR14 $s $i
    if ([double]::IsNaN($atr) -or $atr -le 0) { continue }
    $secid = if ($null -ne $live.active -and $live.active.PSObject.Properties[$a]) { [string]$live.active.$a } else { '' }
    $inst = if ($secid) { Obs-Inst $secid } else { $null }
    $cl = [double]$s[$i].c

    foreach ($v in $VARIANTS) {
      $ra = if ($st.variants.$v.rearm.PSObject.Properties[$a]) { $st.variants.$v.rearm.$a } else { $null }
      $dsig = Get-DonchianSide $s $i $ra
      $ctx = $null
      if ([string]$dsig.side -ne '') {
        $lvl = if ($dsig.side -eq 'long') { [double]$dsig.hi } else { [double]$dsig.lo }
        if ($v -eq 'core_hourly') {
          # Часовой вариант: вход по ЗАВЕРШЁННОМУ часу. Незакрытая свеча подтверждением не
          # является, будущие бары не используются - берём первый ЗАКРЫТЫЙ час этого дня, чей
          # close уже за уровнем, и входим по его закрытию.
          $hb = @()
          # ГРАБЛЯ (проверено в 5.1 и pwsh 7): @(команда) НЕ разворачивает массив, если команда
          # отдала его ОДНИМ объектом - а именно так делают и ConvertFrom-Json внутри
          # Read-JsonFile, и Get-IssCandles с её `,$rows`. Получался один элемент-массив, и
          # $b.c возвращал Object[] вместо числа. Разворачивать надо через промежуточную
          # ПЕРЕМЕННУЮ: @($var) разворачивает, @(cmd) - нет.
          $raw = $null
          if ($HourlyDir) {
            $hp = Join-Path $HourlyDir ("{0}_{1}.json" -f $secid, $D)
            if (Test-Path $hp) { $raw = Read-JsonFile $hp } else { $hourlyFails++ }
          } else {
            try { $raw = Get-IssCandles 'fut' $secid 60 $D $D } catch { $hourlyFails++ }
          }
          if ($null -ne $raw) { $hb = @($raw) }
          $hit = $null
          foreach ($b in $hb) {
            $c2 = [double]$b.c
            if ($dsig.side -eq 'long' -and $c2 -gt $lvl) { $hit = $b; break }
            if ($dsig.side -eq 'short' -and $c2 -lt $lvl) { $hit = $b; break }
          }
          if ($null -ne $hit) {
            $ctx = [pscustomobject]@{ side = [string]$dsig.side; px = [double]$hit.c; level = $lvl
              t_signal = ((MsToUtcStr ([long]$hit.t)) + ' (час закрыт)'); px_source = 'hourly-close'; px_age_sec = $null }
          }
        } else {
          $ctx = [pscustomobject]@{ side = [string]$dsig.side; px = $cl; level = $lvl
            t_signal = "$D 23:50"; px_source = 'daily-close'; px_age_sec = $null }
        }
      }
      Step-Variant $v $D $a $s $i $atr $inst $ctx
    }

    # Setup A: только журнал, без портфеля. Сигнал в бою сейчас не исполняется (рукав выключен),
    # поэтому единственный способ узнать, что он давал, - записать решение здесь.
    $asig = Get-SetupASignal $s $i
    if ($null -ne $asig) {
      $aStopDist = [math]::Max([double]$ATR_STOP_A * $atr, [math]::Abs($cl - [double]$asig.swing))
      $aSz = if ($null -ne $inst) { Obs-Size ([string]$asig.side) $cl $aStopDist $inst ([double]$capital * [double]$POL.setA.risk_pct) 0.0 } else { $null }
      Write-Decision ([ordered]@{ ts = $NowMs; utc = (MsToUtcStr $NowMs); variant = 'setA_virtual'; kind = 'signal'
        day = $D; asset = $a; contract = $(if ($null -ne $inst) { [string]$inst.ticker } else { '' }); side = [string]$asig.side
        rules_version = [string]$rp.hash; policy_id = [string]$rp.policy_id
        t_signal = "$D 23:50"; t_decision = (MsToUtcStr $NowMs)
        level = $null; atr = [math]::Round($atr, 6); swing = [math]::Round([double]$asig.swing, 6)
        dist_to_level = $null; px = [math]::Round($cl, 6); px_source = 'daily-close'; px_age_sec = $null
        stop_strategy = $(if ($null -ne $aSz) { $aSz.strat_stop } else { $null })
        stop_effective = $(if ($null -ne $aSz) { $aSz.stop } else { $null })
        lots = $(if ($null -ne $aSz) { [int]$aSz.lots } else { 0 })
        budget_rub = [math]::Round([double]$capital * [double]$POL.setA.risk_pct, 2)
        risk_before_rub = $null; risk_after_rub = $null
        go_rub = $(if ($null -ne $inst -and $null -ne $aSz) { [math]::Round([int]$aSz.lots * $(if ([string]$asig.side -eq 'long') { [double]$inst.go_buy } else { [double]$inst.go_sell }), 2) } else { $null })
        eq_rub = [math]::Round([double]$capital, 2)
        allow = $false; reason = 'рукав Setup A: новые реальные входы выключены, запись только виртуальная' })
    }
  }
  $st.last_day = $D
}
if ($hourlyFails) { Obs-Log "часовые свечи недоступны $hourlyFails раз - вариант core_hourly эти сигналы пропустил" }

Write-JsonAtomic $statePath $st 8
Trim-Journal
$sum = @()
foreach ($v in $VARIANTS) {
  $vs = $st.variants.$v
  $sum += ("{0}: eq={1:N0} ₽, сделок={2}, побед={3}, открыто={4}" -f $v, [double]$vs.eq_rub, [int]$vs.closed, [int]$vs.wins, @($vs.positions).Count)
}
Obs-Log ("дней обработано: {0} ({1}); {2}" -f $days.Count, ($days -join ','), ($sum -join ' | '))
Write-Host ("наблюдатель: дней {0}; {1}" -f $days.Count, ($sum -join ' | '))
