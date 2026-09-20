# rf_money_reconcile.ps1 - офлайн-сверка ДЕНЕГ боевого RF-контура (этап 1 плана восстановления
# 2026-09-19). Дополняет rf_trade_reconcile.ps1: тот сверяет отдельные СДЕЛКИ, этот - итоговый
# денежный результат и его составляющие.
#
# Читает ТОЛЬКО выгрузку tools/rf_broker_dump.ps1 (сеть и токен не нужны), ничего не меняет.
# Пишет рядом с выгрузкой money_reconciliation.json и MONEY_RECONCILIATION_RU.md.
#
# Зачем отдельный инструмент: «Результат бота с запуска» собирается из четырёх источников
# (вариационка, несведённая переоценка, комиссии, ручные коррекции), и до сих пор проверить его
# можно было только вручную. Разовая ручная коррекция -80 244,41 ₽ (NGU6/L00046) прожила в учёте
# 11 дней именно поэтому: её автор посмотрел клиринг ДАТЫ ЗАКРЫТИЯ, а брокер списал убыток
# вариационкой днём раньше. Этот скрипт делает такую проверку воспроизводимой.
#
# Что считается и откуда:
#   вариационка        - операции *VARMARGIN* (у них НЕТ инструмента: брокер начисляет её по счёту
#                        целиком за клиринг, разложить по позициям из операций нельзя);
#   комиссии бота      - FEE-операции по фьючерсам и обслуживание счёта без инструмента;
#   личные комиссии    - FEE-операции по бумагам пользователя (бот их не платил);
#   личные доходы      - дивиденды, купоны, налоги: к результату бота отношения не имеют;
#   пополнения/выводы  - INPUT/OUTPUT: не доход и не убыток, показываются отдельной строкой.
# BUY/SELL по фьючерсам НЕ суммируются: их payment - номинал контракта, а не денежный поток.
param(
  [Parameter(Mandatory = $true)][string]$Snapshot,
  [string]$Portfolio = '',   # по умолчанию - копия состояния внутри выгрузки
  [string]$Trades = ''
)
$ErrorActionPreference = 'Stop'
# ГРАБЛЯ (проверено в 5.1 и pwsh 7.6.3, в т.ч. на VPS): @($x) БРОСАЕТ 'Argument types do not match',
# если $x создан как New-Object System.Collections.Generic.List[object]. List[string], .ToArray(),
# foreach и конвейер по такому списку работают нормально, а обёртка @() - нет. Поэтому ниже списки
# разворачиваются через .ToArray(), а не привычным @().

function Load-Json([string]$Path) {
  $x = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
  # ранние выгрузки сериализовали массив в обёртке {"value":[...],"Count":N}
  if ($null -ne $x -and $x.PSObject.Properties['value'] -and $x.PSObject.Properties['Count']) { return $x.value }
  return $x
}
function Pay($o) {
  $p = $o.payment
  if ($null -eq $p) { return 0.0 }
  $u = if ($null -ne $p.units -and [string]$p.units -ne '') { [double][string]$p.units } else { 0.0 }
  $n = if ($null -ne $p.nano) { [double]$p.nano } else { 0.0 }
  return $u + $n / 1e9
}
function OpDate($o) {
  $v = $o.date
  if ($v -is [datetime]) {
    return $(if ($v.Kind -eq [DateTimeKind]::Unspecified) { [datetime]::SpecifyKind($v, [DateTimeKind]::Utc) } else { $v.ToUniversalTime() })
  }
  $sty = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
  return [datetime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, $sty)
}
function Fld($o, [string]$Snake) {
  # выгрузка может нести и snake_case, и camelCase - зависит от версии клиента
  if ($o.PSObject.Properties[$Snake]) { return $o.$Snake }
  $camel = ($Snake -split '_' | ForEach-Object { $_ }) -join ''
  $parts = $Snake -split '_'
  $camel = $parts[0] + (($parts | Select-Object -Skip 1 | ForEach-Object { $_.Substring(0,1).ToUpper() + $_.Substring(1) }) -join '')
  if ($o.PSObject.Properties[$camel]) { return $o.$camel }
  return $null
}

if (-not (Test-Path $Snapshot)) { throw "rf_money_reconcile: нет каталога выгрузки $Snapshot" }
if (-not $Portfolio) { $Portfolio = Join-Path $Snapshot 'repo_data_live_rf_portfolio.json' }
if (-not $Trades) { $Trades = Join-Path $Snapshot 'repo_data_live_rf_trades.json' }

$cursorPath = Join-Path $Snapshot 'operations_by_cursor.json'
$plainPath  = Join-Path $Snapshot 'operations.json'
if (-not (Test-Path $cursorPath)) { throw "rf_money_reconcile: нет $cursorPath" }
$opsCursor = @(Load-Json $cursorPath | Where-Object { $null -ne $_ })
$opsPlain  = if (Test-Path $plainPath) { @(Load-Json $plainPath | Where-Object { $null -ne $_ }) } else { @() }
$st = Load-Json $Portfolio
# ГРАБЛЯ: имя локальной НЕ должно совпадать с параметром (PowerShell не различает регистр):
# $trades при параметре [string]$Trades - одна и та же переменная, присваивание массива
# падает с 'Argument types do not match' ещё до первой строки вывода.
$tradeRows = @((Load-Json $Trades) | Where-Object { $null -ne $_ })

$FEE_OPS = @('OPERATION_TYPE_BROKER_FEE','OPERATION_TYPE_EXCHANGE_FEE',
  'OPERATION_TYPE_SERVICE_FEE','OPERATION_TYPE_MARGIN_FEE')
$CASH_IN_OUT = @('OPERATION_TYPE_INPUT','OPERATION_TYPE_OUTPUT')
$PERSONAL_INCOME = @('OPERATION_TYPE_DIVIDEND','OPERATION_TYPE_DIVIDEND_TAX','OPERATION_TYPE_COUPON',
  'OPERATION_TYPE_TAX','OPERATION_TYPE_BOND_TAX','OPERATION_TYPE_TAX_CORRECTION')

# --- разбор операций по экономическому смыслу; дедуп по id, как в движке
$seen = New-Object 'System.Collections.Generic.HashSet[string]'
$vmSum = 0.0; $vmN = 0; $feeBot = 0.0; $feeBotN = 0; $feeOther = 0.0; $feeOtherN = 0
$personal = 0.0; $personalN = 0; $cashFlow = 0.0; $cashFlowN = 0
$unknownTypes = @{}
$vmRows = New-Object System.Collections.Generic.List[object]
foreach ($o in $opsCursor) {
  $oid = [string](Fld $o 'id')
  if ($oid -and -not $seen.Add($oid)) { continue }   # одна операция учитывается ровно один раз
  $t = [string](Fld $o 'type')
  if (-not $t) { $t = [string](Fld $o 'operation_type') }
  $pay = Pay $o
  $itype = [string](Fld $o 'instrument_type')
  if ($t -like '*VARMARGIN*') {
    $vmSum += $pay; $vmN++
    $vmRows.Add([pscustomobject]@{ date = (OpDate $o).ToString('yyyy-MM-dd HH:mm') + 'Z'; rub = [math]::Round($pay, 2); id = $oid })
  }
  elseif ($FEE_OPS -contains $t) {
    if ($itype -eq 'futures' -or -not $itype) { $feeBot += $pay; $feeBotN++ } else { $feeOther += $pay; $feeOtherN++ }
  }
  elseif ($PERSONAL_INCOME -contains $t) { $personal += $pay; $personalN++ }
  elseif ($CASH_IN_OUT -contains $t) { $cashFlow += $pay; $cashFlowN++ }
  elseif ($t -eq 'OPERATION_TYPE_BUY' -or $t -eq 'OPERATION_TYPE_SELL') { }   # номинал, не денежный поток
  else { $unknownTypes[$t] = [int]$unknownTypes[$t] + 1 }
}

# --- контроль второго представления API: те же деньги не должны прийти дважды и не должны пропасть
$cursorIds = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($o in $opsCursor) { $id = [string](Fld $o 'id'); if ($id) { [void]$cursorIds.Add($id) } }
$missingInCursor = New-Object System.Collections.Generic.List[string]
foreach ($o in $opsPlain) {
  $id = [string](Fld $o 'id')
  $t = [string](Fld $o 'type'); if (-not $t) { $t = [string](Fld $o 'operation_type') }
  if (-not $id) { continue }
  if (($t -like '*VARMARGIN*' -or $FEE_OPS -contains $t) -and -not $cursorIds.Contains($id)) { $missingInCursor.Add("$t $id") }
}

# --- то, что записал у себя движок
$lg = $st.broker_ledger
$lgVm = if ($null -ne $lg) { [double]$lg.varmargin_rub } else { 0.0 }
$lgFee = if ($null -ne $lg) { [double]$lg.fees_rub } else { 0.0 }
$lgFeeOther = if ($null -ne $lg) { [double]$lg.fees_other_rub } else { 0.0 }
$curVm = if ($null -ne $st.capital_breakdown -and $null -ne $st.capital_breakdown.futures) { [double]$st.capital_breakdown.futures } else { 0.0 }
$pendAll = 0.0
foreach ($it in @($st.pending_settle.items)) { if ($null -ne $it) { $pendAll += [double]$it.rub } }

$adjRows = New-Object System.Collections.Generic.List[object]
$adjActive = 0.0
foreach ($m in @($st.manual_adjustments)) {
  if ($null -eq $m) { continue }
  $status = if ([string]$m.status) { [string]$m.status } else { 'active' }
  if ($status -ne 'superseded') { $adjActive += [double]$m.rub }
  $adjRows.Add([pscustomobject]@{ id = [string]$m.id; status = $status; rub = [double]$m.rub
    rub_original = $(if ($null -ne $m.rub_original) { [double]$m.rub_original } else { $null })
    basis = [string]$m.superseded_by })
}

$netBroker = $lgVm + $curVm + $pendAll + $lgFee
$netShown = $netBroker + $adjActive

# --- собственный учёт бота по карточкам (оценка, не деньги брокера)
$ownPnl = ($tradeRows | Measure-Object pnlRub -Sum).Sum
$ownFees = ($tradeRows | Measure-Object feesRub -Sum).Sum
$ownOpen = 0.0; $ownOpenFees = 0.0
foreach ($sn in 'core','setA') {
  foreach ($p in @($st.sleeves.$sn.positions | Where-Object { $null -ne $_ })) {
    if ($null -ne $p.upnl_rub) { $ownOpen += [double]$p.upnl_rub }
    if ($null -ne $p.fees_rub) { $ownOpenFees += [double]$p.fees_rub }
  }
}
$ownGross = $ownPnl + $ownOpen                       # pnlRub карточек - БЕЗ комиссий
$brokerGross = $lgVm + $curVm + $pendAll             # вариационка - тоже до комиссий

$dVm = [math]::Round($vmSum - $lgVm, 2)
$dFee = [math]::Round($feeBot - $lgFee, 2)
$dFeeOther = [math]::Round($feeOther - $lgFeeOther, 2)
$dGross = [math]::Round($brokerGross - $ownGross, 2)

$res = [ordered]@{
  tool = 'rf_money_reconcile.ps1'
  snapshot = (Resolve-Path $Snapshot).Path
  created_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  operations = [ordered]@{ cursor_rows = $opsCursor.Count; plain_rows = $opsPlain.Count
    missing_in_cursor = $missingInCursor.ToArray(); unknown_types = $unknownTypes }
  components = [ordered]@{
    varmargin_ops_rub = [math]::Round($vmSum, 2); varmargin_ops_count = $vmN
    fees_bot_rub = [math]::Round($feeBot, 2); fees_bot_count = $feeBotN
    fees_personal_rub = [math]::Round($feeOther, 2); fees_personal_count = $feeOtherN
    personal_income_rub = [math]::Round($personal, 2); personal_income_count = $personalN
    cash_in_out_rub = [math]::Round($cashFlow, 2); cash_in_out_count = $cashFlowN
  }
  engine_ledger = [ordered]@{ varmargin_rub = $lgVm; fees_rub = $lgFee; fees_other_rub = $lgFeeOther
    unsettled_futures_rub = $curVm; pending_settle_rub = $pendAll }
  diffs = [ordered]@{ varmargin = $dVm; fees_bot = $dFee; fees_personal = $dFeeOther }
  manual_adjustments = $adjRows.ToArray()
  varmargin_rows = $vmRows.ToArray()
  result = [ordered]@{ broker_net_rub = [math]::Round($netBroker, 2)
    manual_active_rub = [math]::Round($adjActive, 2)
    shown_net_rub = [math]::Round($netShown, 2)
    own_gross_rub = [math]::Round($ownGross, 2); broker_gross_rub = [math]::Round($brokerGross, 2)
    gross_gap_rub = $dGross
    own_fees_estimate_rub = [math]::Round($ownFees + $ownOpenFees, 2) }
}
$jsonPath = Join-Path $Snapshot 'money_reconciliation.json'
[IO.File]::WriteAllText($jsonPath, (ConvertTo-Json -InputObject $res -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

$ok = ([math]::Abs($dVm) -lt 0.01 -and [math]::Abs($dFee) -lt 0.01 -and $missingInCursor.Count -eq 0)
$L = New-Object System.Collections.Generic.List[string]
$L.Add('# Сверка денег RF-контура')
$L.Add('')
$L.Add(('Выгрузка: {0} - собрано {1}Z' -f (Split-Path $Snapshot -Leaf), (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')))
$L.Add('')
$L.Add('## Сходится ли леджер движка с операциями брокера')
$L.Add('')
$L.Add('| Составляющая | Операции брокера | Леджер движка | Расхождение |')
$L.Add('| --- | ---: | ---: | ---: |')
$L.Add(('| Вариационка (сведённая) | {0:N2} | {1:N2} | {2:N2} |' -f $vmSum, $lgVm, $dVm))
$L.Add(('| Комиссии бота | {0:N2} | {1:N2} | {2:N2} |' -f $feeBot, $lgFee, $dFee))
$L.Add(('| Комиссии личные | {0:N2} | {1:N2} | {2:N2} |' -f $feeOther, $lgFeeOther, $dFeeOther))
$L.Add('')
$L.Add(($(if ($ok) { 'Итог: леджер воспроизводится из операций брокера.' } else { 'Итог: ЕСТЬ РАСХОЖДЕНИЕ - разбирать до повышения режима.' })))
$L.Add('')
$L.Add('## Что к результату бота не относится (показано отдельно)')
$L.Add('')
$L.Add(('- личные доходы (дивиденды, купоны, налоги): {0:N2} ₽ ({1} оп.)' -f $personal, $personalN))
$L.Add(('- комиссии по бумагам пользователя: {0:N2} ₽ ({1} оп.)' -f $feeOther, $feeOtherN))
$L.Add(('- пополнения и выводы: {0:N2} ₽ ({1} оп.)' -f $cashFlow, $cashFlowN))
$L.Add('')
$L.Add('## Результат бота')
$L.Add('')
$L.Add(('- по деньгам брокера (вариационка + несведённая + комиссии): **{0:N2} ₽**' -f $netBroker))
$L.Add(('- действующие ручные коррекции: {0:N2} ₽' -f $adjActive))
$L.Add(('- показывается на дашборде: **{0:N2} ₽**' -f $netShown))
$L.Add('')
$L.Add('### Оценка по карточкам против денег брокера (брутто, до комиссий)')
$L.Add('')
$L.Add(('- учёт бота по сделкам: {0:N2} ₽ (оценка комиссий бота: {1:N2} ₽)' -f $ownGross, ($ownFees + $ownOpenFees)))
$L.Add(('- деньги брокера: {0:N2} ₽' -f $brokerGross))
$L.Add(('- расхождение: {0:N2} ₽' -f $dGross))
$L.Add('')
$L.Add('Оценка по карточкам считается по стоимости пункта на момент закрытия, брокер сводит')
$L.Add('вариационку каждый день по своей - полное совпадение этих чисел невозможно; это разные')
$L.Add('вопросы, а не проверка одного другим.')
if ($adjRows.Count) {
  $L.Add('')
  $L.Add('## Ручные коррекции')
  $L.Add('')
  $L.Add('| id | статус | в итоге, ₽ | было, ₽ | основание |')
  $L.Add('| --- | --- | ---: | ---: | --- |')
  foreach ($a in $adjRows) {
    $L.Add(('| {0} | {1} | {2:N2} | {3} | {4} |' -f $a.id, $a.status, $a.rub,
      $(if ($null -ne $a.rub_original) { '{0:N2}' -f $a.rub_original } else { '-' }), $a.basis))
  }
}
if ($unknownTypes.Count) {
  $L.Add('')
  $L.Add('## Неразобранные типы операций')
  $L.Add('')
  foreach ($k in $unknownTypes.Keys) { $L.Add(('- {0}: {1}' -f $k, $unknownTypes[$k])) }
}
$mdPath = Join-Path $Snapshot 'MONEY_RECONCILIATION_RU.md'
[IO.File]::WriteAllLines($mdPath, $L, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ("вариационка: операции {0:N2} vs леджер {1:N2} (расхождение {2:N2})" -f $vmSum, $lgVm, $dVm)
Write-Host ("комиссии бота: операции {0:N2} vs леджер {1:N2} (расхождение {2:N2})" -f $feeBot, $lgFee, $dFee)
Write-Host ("результат бота по брокеру {0:N2}; показывается {1:N2}" -f $netBroker, $netShown)
Write-Host ("отчёт: $mdPath")
if (-not $ok) { exit 2 }
