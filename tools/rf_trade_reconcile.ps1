# rf_trade_reconcile.ps1 - офлайн-сверка закрытых сделок боевого RF-контура с операциями брокера.
# Этап 0 риск-политики. Читает ТОЛЬКО выгрузку tools/rf_broker_dump.ps1 (сеть не нужна), пишет рядом
# reconciliation.json и RECONCILIATION_RU.md. Выгрузка приватная - результат тоже.
#
# Что делается по каждому циклу из trades.json бота:
#   - собираются операции брокера: базовый актив (префикс кода контракта - переживает роллы),
#     направление, день входа, объём; позиция цикла должна вернуться в ноль к моменту выхода;
#   - фактические комиссии - поле commission операции-сделки (брокер отдаёт его по каждой сделке);
#   - валовый результат по суммам сделок: цена исполнения x объём x стоимость пункта ТОГО периода
#     (стоимость пункта берётся из самой операции: |payment| / (qty x price));
#   - сравнение с записью бота. ВАЖНО о смысле pnlRub: Close-CardLedger кладёт туда результат БЕЗ
#     комиссии входа (она списана с рукава отдельно при входе), поэтому для сравнения с брокером из
#     pnlRub вычитается оценка комиссии входа по fee_est.
# Статус: verified - цикл однозначно собран; estimated - собран с допущением (роллы, пересечение
# циклов одного актива, день входа не совпал); unresolved - не собран. Неразрешённое не
# распределяется по сделкам, а выводится списком.
param(
  [Parameter(Mandatory = $true)][string]$Snapshot,
  [double]$FeeEst = 0.00025
)
$ErrorActionPreference = 'Stop'
$MSK = [TimeSpan]::FromHours(3)
function Load-Snap([string]$Name) {
  $x = Get-Content (Join-Path $Snapshot $Name) -Raw -Encoding UTF8 | ConvertFrom-Json
  # ранние выгрузки сериализовали массив в обёртке {"value":[...],"Count":N}
  if ($null -ne $x -and $x.PSObject.Properties['value'] -and $x.PSObject.Properties['Count']) { return ,@($x.value) }
  return ,@($x)
}
function Q($q) {
  if ($null -eq $q) { return [decimal]0 }
  $u = if ($q.PSObject.Properties['units'] -and [string]$q.units -ne '') { [decimal][string]$q.units } else { [decimal]0 }
  $n = if ($q.PSObject.Properties['nano'] -and $null -ne $q.nano) { [decimal]$q.nano } else { [decimal]0 }
  return $u + $n / [decimal]1000000000
}
function To-Ms($v) {
  if ($v -is [datetime]) {
    $u = if ($v.Kind -eq [DateTimeKind]::Unspecified) { [datetime]::SpecifyKind($v, [DateTimeKind]::Utc) } else { $v.ToUniversalTime() }
    return ([DateTimeOffset]$u).ToUnixTimeMilliseconds()
  }
  $sty = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
  return [DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, $sty).ToUnixTimeMilliseconds()
}
function R2($d) { return [math]::Round([decimal]$d, 2) }

$trades = Load-Snap 'repo_data_live_rf_trades.json'
$ops = Load-Snap 'operations_by_cursor.json'

# --- фьючерсные сделки брокера (исполненные), по времени
$rows = New-Object System.Collections.Generic.List[object]
foreach ($o in $ops) {
  if ($null -eq $o -or [string]$o.instrumentKind -ne 'INSTRUMENT_TYPE_FUTURES') { continue }
  if (@('OPERATION_TYPE_BUY', 'OPERATION_TYPE_SELL') -notcontains [string]$o.type) { continue }
  if ([string]$o.state -ne 'OPERATION_STATE_EXECUTED') { continue }
  $qty = [int][string]$o.quantityDone
  if ($qty -le 0) { $qty = [int][string]$o.quantity }
  $px = Q $o.price
  $pay = [math]::Abs((Q $o.payment))
  $ms = To-Ms $o.date
  $tk = [string]$o.ticker
  $rows.Add([pscustomobject]@{
    id = [string]$o.id; ticker = $tk; prefix = $(if ($tk.Length -gt 2) { $tk.Substring(0, $tk.Length - 2) } else { $tk })
    dir = $(if ([string]$o.type -eq 'OPERATION_TYPE_BUY') { 'buy' } else { 'sell' }); qty = $qty; px = $px; pay = $pay
    rpp = $(if ($qty -gt 0 -and $px -gt 0) { $pay / $qty / $px } else { [decimal]0 })
    fee = [math]::Abs((Q $o.commission)); ms = $ms
    msk_day = ([DateTimeOffset]::FromUnixTimeMilliseconds($ms)).ToOffset($MSK).ToString('yyyy-MM-dd')
    fills = @($o.tradesInfo.trades).Count; used = $false })
}
$rows = @($rows | Sort-Object ms)

# --- циклы бота
$cycles = New-Object System.Collections.Generic.List[object]
$tsorted = @($trades | Where-Object { $null -ne $_ } | Sort-Object { [string]$_.exitUtc })
foreach ($t in $tsorted) {
  $secid = [string]$t.secid
  $prefix = if ($secid.Length -gt 2) { $secid.Substring(0, $secid.Length - 2) } else { $secid }
  $s = if ([string]$t.side -eq 'long') { 1 } else { -1 }
  $inDir = if ($s -gt 0) { 'buy' } else { 'sell' }
  $exitMs = To-Ms (([string]$t.exitUtc).Replace(' ', 'T') + ':00Z')
  $notes = New-Object System.Collections.Generic.List[string]
  $status = 'verified'
  # вход: неиспользованная операция нужного направления, того же актива, в день входа, объём = lots
  $entry = @($rows | Where-Object { -not $_.used -and $_.prefix -eq $prefix -and $_.dir -eq $inDir -and $_.msk_day -eq [string]$t.entryDay -and $_.qty -eq [int]$t.lots -and $_.ms -le $exitMs }) | Select-Object -First 1
  if ($null -eq $entry) {
    $entry = @($rows | Where-Object { -not $_.used -and $_.prefix -eq $prefix -and $_.dir -eq $inDir -and $_.qty -eq [int]$t.lots -and $_.ms -le $exitMs }) | Select-Object -Last 1
    if ($null -ne $entry) { $status = 'estimated'; $notes.Add("день входа у брокера $($entry.msk_day), в записи $($t.entryDay)") }
  }
  $rec = [ordered]@{ id = [string]$t.id; asset = [string]$t.asset; sleeve = [string]$t.sleeve; side = [string]$t.side
    lots = [int]$t.lots; entry_day = [string]$t.entryDay; exit_utc = [string]$t.exitUtc; exit_reason = [string]$t.exitReason
    rolls = [int]$t.rolls; bot = [ordered]@{ entry = [double]$t.entry; exit = [double]$t.exitPx; pnl_rub = [double]$t.pnlRub; fees_rub = [double]$t.feesRub }
    broker = $null; diff = $null; status = 'unresolved'; notes = @(); op_ids = @() }
  if ($null -eq $entry) { $rec.notes = @('операция входа не найдена'); $cycles.Add([pscustomobject]$rec); continue }
  # проход по операциям актива после входа, пока позиция цикла не вернётся в ноль (роллы и частичные выходы)
  $legs = New-Object System.Collections.Generic.List[object]
  $legs.Add($entry); $pos = $s * $entry.qty
  foreach ($x in $rows) {
    if ($pos -eq 0) { break }
    if ($x.used -or $x.id -eq $entry.id -or $x.prefix -ne $prefix -or $x.ms -lt $entry.ms) { continue }
    if ($x.ms -gt $exitMs + 300000) { break }
    $d = if ($x.dir -eq 'buy') { 1 } else { -1 }
    $legs.Add($x); $pos += $d * $x.qty
  }
  if ($pos -ne 0) {
    $rec.notes = @("позиция цикла не вернулась в ноль к выходу (остаток $pos)")
    $rec.op_ids = @($legs | ForEach-Object { $_.id })
    $cycles.Add([pscustomobject]$rec); continue
  }
  foreach ($l in $legs) { $l.used = $true }
  # пересечение с другим циклом того же актива - сборка по порядку могла смешать операции
  $overlap = @($trades | Where-Object { $null -ne $_ -and [string]$_.id -ne [string]$t.id -and ([string]$_.secid).StartsWith($prefix) -and
    [string]$_.entryDay -le ([DateTimeOffset]::FromUnixTimeMilliseconds($exitMs)).ToOffset($MSK).ToString('yyyy-MM-dd') -and
    (To-Ms (([string]$_.exitUtc).Replace(' ', 'T') + ':00Z')) -ge $entry.ms }).Count
  if ($overlap) { $status = 'estimated'; $notes.Add('в это время был другой цикл того же актива') }
  $rollLegs = @($legs | Where-Object { $_.ticker -ne $entry.ticker }).Count
  if ([int]$t.rolls -gt 0) { $status = 'estimated'; $notes.Add("роллов в записи: $([int]$t.rolls), операций другого контракта: $rollLegs") }
  # Валовый результат по ЦЕНАМ, по каждому контракту цикла отдельно (ролл = два отрезка):
  #   пункты = Σ(цена x объём продаж) - Σ(цена x объём покупок); рубли = пункты x стоимость пункта.
  # Стоимость пункта валютных контрактов (BR, GOLD, SILV, PLD - в долларах) меняется с курсом, а
  # вариационная маржа начисляется по цене и курсу КАЖДОГО дня - по двум сделкам точное значение не
  # восстановить. Берём среднюю стоимость пункта по сделкам отрезка и показываем диапазон.
  # Разность «сумм сделок» (номинал x смена курса) результатом фьючерса НЕ является - только справочно.
  $gross = [decimal]0; $band = [decimal]0; $payGross = [decimal]0; $fees = [decimal]0
  foreach ($g in @($legs | Group-Object ticker)) {
    $pts = [decimal]0
    $rpps = New-Object System.Collections.Generic.List[decimal]
    foreach ($l in $g.Group) {
      $pts += $(if ($l.dir -eq 'sell') { $l.px * $l.qty } else { -$l.px * $l.qty })
      if ($l.rpp -gt 0) { $rpps.Add([decimal]$l.rpp) }
    }
    if ($rpps.Count) {
      $lo = [decimal]($rpps | Measure-Object -Minimum).Minimum
      $hi = [decimal]($rpps | Measure-Object -Maximum).Maximum
      $mid = [decimal]($rpps | Measure-Object -Average).Average
      $gross += $pts * $mid
      $band += [math]::Abs($pts) * ($hi - $lo) / 2
    }
  }
  foreach ($l in $legs) { $payGross += $(if ($l.dir -eq 'sell') { $l.pay } else { -$l.pay }); $fees += $l.fee }
  $last = $legs[$legs.Count - 1]
  $exitLegs = @($legs | Where-Object { $_.ticker -eq $last.ticker -and $_.dir -ne $inDir })
  $exitQty = ($exitLegs | Measure-Object qty -Sum).Sum
  $exitPx = if ($exitQty -gt 0) { [decimal](($exitLegs | ForEach-Object { $_.px * $_.qty } | Measure-Object -Sum).Sum) / $exitQty } else { $last.px }
  $netBroker = $gross - $fees
  $entryFeeEst = [decimal]$t.lots * $entry.px * $entry.rpp * [decimal]$FeeEst
  $botNetFull = [decimal]$t.pnlRub - $entryFeeEst
  $rec.broker = [ordered]@{ entry = [double](R2 $entry.px); entry_fills = $entry.fills; exit = [double][math]::Round($exitPx, 6)
    rub_per_pt_entry = [double][math]::Round($entry.rpp, 4); rub_per_pt_exit = [double][math]::Round($last.rpp, 4)
    gross_rub = [double](R2 $gross); gross_band_rub = [double](R2 $band); payments_gross_rub = [double](R2 $payGross)
    fees_rub = [double](R2 $fees); net_rub = [double](R2 $netBroker) }
  $rec.diff = [ordered]@{ entry_px = [double][math]::Round([decimal]$t.entry - $entry.px, 6); exit_px = [double][math]::Round([decimal]$t.exitPx - $exitPx, 6)
    fees_rub = [double](R2 ($fees - [decimal]$t.feesRub)); bot_net_full_rub = [double](R2 $botNetFull); net_rub = [double](R2 ($netBroker - $botNetFull)) }
  $rec.status = $status
  $rec.notes = $notes.ToArray()
  $rec.op_ids = @($legs | ForEach-Object { $_.id })
  $cycles.Add([pscustomobject]$rec)
}

# --- неразобранные фьючерсные операции (открытая сейчас позиция, аварийные закрытия и т.п.)
$left = @($rows | Where-Object { -not $_.used } | ForEach-Object { [ordered]@{ id = $_.id; ticker = $_.ticker; dir = $_.dir; qty = $_.qty; px = [double]$_.px
  utc = ([DateTimeOffset]::FromUnixTimeMilliseconds($_.ms)).ToString('yyyy-MM-dd HH:mm') } })
$sumFeeFact = [decimal]0; $sumFeeBot = [decimal]0; $sumNetDiff = [decimal]0
foreach ($c in $cycles) { if ($null -ne $c.broker) { $sumFeeFact += [decimal]$c.broker.fees_rub; $sumFeeBot += [decimal]$c.bot.fees_rub; $sumNetDiff += [decimal]$c.diff.net_rub } }
$vm = [decimal]0; foreach ($o in $ops) { if ($null -ne $o -and [string]$o.type -like '*VARMARGIN*') { $vm += Q $o.payment } }
$feeOpsFut = [decimal]0
$tradeIds = @{}; foreach ($r in $rows) { $tradeIds[$r.id] = $true }
foreach ($o in $ops) { if ($null -ne $o -and [string]$o.type -like '*FEE*' -and $tradeIds.ContainsKey([string]$o.parentOperationId)) { $feeOpsFut += [math]::Abs((Q $o.payment)) } }
$summary = [ordered]@{
  snapshot = (Split-Path $Snapshot -Leaf); cycles = $cycles.Count
  verified = @($cycles | Where-Object { $_.status -eq 'verified' }).Count
  estimated = @($cycles | Where-Object { $_.status -eq 'estimated' }).Count
  unresolved = @($cycles | Where-Object { $_.status -eq 'unresolved' }).Count
  fees_fact_rub = [double](R2 $sumFeeFact); fees_bot_rub = [double](R2 $sumFeeBot)
  fee_ops_futures_rub = [double](R2 $feeOpsFut)
  net_diff_sum_rub = [double](R2 $sumNetDiff)
  varmargin_ops_sum_rub = [double](R2 $vm)
  unassigned_futures_ops = $left.Count; fee_est = $FeeEst
}
$outObj = [ordered]@{ summary = $summary; cycles = $cycles.ToArray(); unassigned = $left }
[IO.File]::WriteAllText((Join-Path $Snapshot 'reconciliation.json'), (ConvertTo-Json -InputObject $outObj -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

# --- человекочитаемый отчёт
$ci = [Globalization.CultureInfo]'ru-RU'
function F($v, [int]$dg = 0) { if ($null -eq $v) { return '—' }; return ([double]$v).ToString("N$dg", $ci) }
$md = New-Object System.Collections.Generic.List[string]
$md.Add('# Сверка закрытых сделок RF-live с операциями брокера')
$md.Add('')
$md.Add("Выгрузка ``$($summary.snapshot)``. Циклов $($summary.cycles): подтверждено $($summary.verified), с допущением $($summary.estimated), не собрано $($summary.unresolved).")
$md.Add('')
$md.Add("Комиссии: факт брокера $(F $summary.fees_fact_rub) ₽ против записанных ботом $(F $summary.fees_bot_rub) ₽ (оценка fee_est $FeeEst за сторону). Сумма комиссий-операций по фьючерсным сделкам брокера за весь период: $(F $summary.fee_ops_futures_rub) ₽.")
$md.Add('')
$md.Add('«Бот нетто» = pnlRub минус оценка комиссии входа (pnlRub её не содержит). «Брокер нетто» = разница цен исполнения брокера x объём x средняя стоимость пункта по сделкам цикла, минус фактические комиссии. У валютных контрактов (BR, GOLD, SILV, PLD) стоимость пункта меняется с курсом, а вариационная маржа начисляется по курсу каждого дня; «±» - диапазон из-за этого, точнее по двум сделкам не восстановить. Вариационная маржа по циклам не распределяется: её операции идут по контракту, а не по циклу.')
$md.Add('')
$md.Add('| Цикл | Актив | Сторона | Лоты | Вход бот / брокер | Выход бот / брокер | Комиссии бот / факт, ₽ | Бот нетто / брокер нетто, ₽ | Статус |')
$md.Add('|---|---|---|---:|---|---|---|---|---|')
foreach ($c in $cycles) {
  if ($null -eq $c.broker) {
    $md.Add("| $($c.id) | $($c.asset) | $($c.side) | $($c.lots) | $(F $c.bot.entry 4) / — | $(F $c.bot.exit 4) / — | $(F $c.bot.fees_rub) / — | $(F $c.bot.pnl_rub) / — | не собран: $($c.notes -join '; ') |")
    continue
  }
  $st = if ($c.status -eq 'verified') { 'подтверждён' } else { 'допущение: ' + ($c.notes -join '; ') }
  $md.Add("| $($c.id) | $($c.asset) | $($c.side) | $($c.lots) | $(F $c.bot.entry 4) / $(F $c.broker.entry 4) | $(F $c.bot.exit 4) / $(F $c.broker.exit 4) | $(F $c.bot.fees_rub) / $(F $c.broker.fees_rub) | $(F $c.diff.bot_net_full_rub) / $(F $c.broker.net_rub) ±$(F $c.broker.gross_band_rub) | $st |")
}
if ($left.Count) {
  $md.Add('')
  $md.Add('Фьючерсные операции брокера, не вошедшие ни в один закрытый цикл (открытая позиция, аварийные закрытия и т.п.):')
  $md.Add('')
  foreach ($l in $left) { $md.Add("- $($l.utc) UTC $($l.ticker) $($l.dir) $($l.qty) по $(F $l.px 4)") }
}
[IO.File]::WriteAllText((Join-Path $Snapshot 'RECONCILIATION_RU.md'), ($md -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("сверка: циклов {0}, подтверждено {1}, с допущением {2}, не собрано {3}; комиссии факт {4} против {5} в записи" -f $summary.cycles, $summary.verified, $summary.estimated, $summary.unresolved, $summary.fees_fact_rub, $summary.fees_bot_rub)
