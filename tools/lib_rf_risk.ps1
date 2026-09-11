# lib_rf_risk.ps1 - риск-политика боевого контура RF (rf-early-exit-v1): ЧИСТЫЕ функции.
# Никакой сети, записи состояния, алертов и «текущего времени» внутри: всё приходит аргументами,
# наружу - решение с расчётами и причинами. Поэтому любое решение воспроизводимо по сохранённому
# входному снимку (ТЗ §4). Движок (live_rf_engine.ps1) собирает входы из уже полученных в тике
# данных и сам решает, что делать с результатом.
#
# Деньги, цены и шаг цены - [decimal]. ConvertFrom-Json в PS 5.1 и в pwsh 7 отдаёт разные числовые
# типы (decimal/double/long/int), поэтому каждое входное число явно приводится (RkDec).
# Смысл величин (канон): docs/strategy/live_tinvest_design.md, раздел «Риск-политика».
#   - предел стопа stop_cap_pct - доля ЦЕНЫ фьючерса от цены входа;
#   - risk_pct, потолки бюджета, дневной предел - доли КАПИТАЛА бота;
#   - процент от ГО здесь не используется вовсе.

$script:RF_RISK_SCHEMA = 1
$script:RF_RISK_SIZING_RULE = 'min_original_and_capped_same_budget'
$script:RF_RISK_FX_DEFAULT = @('Si','CNY','Eu')
# Модель расходов по умолчанию - ТОЛЬКО резерв в расчёте риска. Источник: брокерский леджер за
# 17.07-01.09 - 21 684 ₽ фактических комиссий против 8 362 ₽ оценочных, ≈0,043% за сторону; берём с
# запасом 0,045%. Плюс неблагоприятное исполнение стоп-маркета 0,05% (допущение, не измерение).
# Деньги в леджере по-прежнему списываются по LIVE.fee_est - его правка отдельное решение (BACKLOG №12).
$script:RF_RISK_COST_DEFAULT = [ordered]@{
  fee_pct_side = [decimal]'0.00045'; stop_slip_pct = [decimal]'0.0005'
  source = 'broker_ledger 2026-07-17..2026-09-01 (~0.043%/side) + stop slip assumption'
}
$script:RF_RISK_TOL_DEFAULT = [decimal]'0.10'

# ---------------- базовые помощники ----------------
function RkIsNum($v) {
  return ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal] -or $v -is [single] -or
          $v -is [int16] -or $v -is [byte] -or $v -is [uint32] -or $v -is [uint64])
}
function RkDec($v) {
  if ($null -eq $v) { return $null }
  if ($v -is [string]) {
    if ($v.Trim() -eq '') { return $null }
    return [decimal]::Parse($v, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture)
  }
  return [decimal]$v
}
function RkFmt($d) {
  if ($null -eq $d) { return 'null' }
  return ([decimal]$d).ToString('G29', [Globalization.CultureInfo]::InvariantCulture)
}
function RkProp($Obj, [string]$Name) {
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [System.Collections.IDictionary]) { if ($Obj.Contains($Name)) { return $Obj[$Name] }; return $null }
  $p = $Obj.PSObject.Properties[$Name]
  if ($null -eq $p) { return $null }
  return $p.Value
}
function RkHas($Obj, [string]$Name) {
  if ($null -eq $Obj) { return $false }
  if ($Obj -is [System.Collections.IDictionary]) { return $Obj.Contains($Name) }
  return ($null -ne $Obj.PSObject.Properties[$Name])
}
function RkKeys($Obj) {
  if ($null -eq $Obj) { return @() }
  if ($Obj -is [System.Collections.IDictionary]) { return @($Obj.Keys | ForEach-Object { [string]$_ }) }
  return @($Obj.PSObject.Properties | ForEach-Object { $_.Name })
}
# +1 лонг/покупка, -1 шорт/продажа. Иное - ошибка вызывающего кода, а не молчаливый шорт.
function RkSideSign([string]$Side) {
  switch ($Side) { 'long' { return 1 } 'buy' { return 1 } 'short' { return -1 } 'sell' { return -1 } }
  throw "lib_rf_risk: неизвестная сторона '$Side'"
}
function RkSha256([string]$s) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)) } finally { $sha.Dispose() }
  return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

# ---------------- конфигурация ----------------
# Проверяет блок rf_risk_policy из data/live_rf/config.json. Возврат:
#   { ok; mode = off|shadow|pilot|active|invalid; policy_id; version; hash; p; error }
# Нет блока или mode='off' -> off. Любая ошибка схемы при запрошенной политике -> ok=$false,
# mode='invalid': движок обязан остановить новые входы, а НЕ вернуться молча к прежнему риску 5%.
# Типы строгие: число строкой ("0.02") - ошибка, как и число вне диапазона.
function Resolve-RfRiskPolicy($Raw) {
  $off = [pscustomobject]@{ ok = $true; mode = 'off'; policy_id = ''; version = 0; hash = ''; p = $null; error = '' }
  if ($null -eq $Raw) { return $off }
  $mode = RkProp $Raw 'mode'
  if ($mode -isnot [string] -or @('off','shadow','pilot','active') -notcontains $mode) {
    return [pscustomobject]@{ ok = $false; mode = 'invalid'; policy_id = ''; version = 0; hash = ''; p = $null
      error = "mode: неизвестный режим '$mode'" }
  }
  if ($mode -eq 'off') { return $off }

  $errs = New-Object System.Collections.Generic.List[string]
  function Need-Num($Obj, [string]$Name, $Lo, $Hi, [switch]$LoOpen, [switch]$AllowNull, [string]$Path, [switch]$Int) {
    $v = RkProp $Obj $Name
    if ($null -eq $v) {
      if ($AllowNull) { return $null }
      $errs.Add("${Path}: обязательное число"); return $null
    }
    if (-not (RkIsNum $v)) { $errs.Add("${Path}: ожидалось число, получено '$v' ($($v.GetType().Name))"); return $null }
    $d = RkDec $v
    if ($Int -and $d -ne [math]::Floor($d)) { $errs.Add("${Path}: ожидалось целое, получено $(RkFmt $d)"); return $null }
    $lo = [decimal]$Lo; $hi = [decimal]$Hi
    $okLo = if ($LoOpen) { $d -gt $lo } else { $d -ge $lo }
    if (-not $okLo -or $d -gt $hi) {
      $br = if ($LoOpen) { '(' } else { '[' }
      $errs.Add("${Path}: $(RkFmt $d) вне диапазона $br$(RkFmt $lo); $(RkFmt $hi)]"); return $null
    }
    return $d
  }
  function Need-Str($Obj, [string]$Name, [string]$Path, [string[]]$Allowed = @()) {
    $v = RkProp $Obj $Name
    if ($v -isnot [string] -or $v.Trim() -eq '') { $errs.Add("${Path}: обязательная строка"); return '' }
    if (@($Allowed).Count -and @($Allowed) -notcontains $v) { $errs.Add("${Path}: '$v' не из ($($Allowed -join ', '))"); return '' }
    return $v
  }

  $ver = Need-Num $Raw 'schema_version' 1 1 -Path 'schema_version' -Int
  $pid0 = RkProp $Raw 'policy_id'
  $policyId = ''
  if ($pid0 -isnot [string] -or $pid0 -notmatch '^[a-z0-9][a-z0-9.\-]{2,63}$') { $errs.Add("policy_id: ожидалась строка [a-z0-9.-], 3-64 символа") }
  else { $policyId = $pid0 }
  [void](Need-Str $Raw 'apply_to' 'apply_to' @('new_entries'))
  [void](Need-Str $Raw 'capital_source' 'capital_source' @('broker_verified'))
  [void](Need-Str $Raw 'sizing_rule' 'sizing_rule' @($script:RF_RISK_SIZING_RULE))
  $core = RkProp $Raw 'core'; $seta = RkProp $Raw 'setA'
  if ($null -eq $core) { $errs.Add('core: обязательный блок') }
  if ($null -eq $seta) { $errs.Add('setA: обязательный блок') }
  $cCap = Need-Num $core 'stop_cap_pct' 0 '0.10' -LoOpen -AllowNull -Path 'core.stop_cap_pct'
  $cRisk = Need-Num $core 'risk_pct' 0 '0.02' -LoOpen -Path 'core.risk_pct'
  $aCap = Need-Num $seta 'stop_cap_pct' 0 '0.10' -LoOpen -AllowNull -Path 'setA.stop_cap_pct'
  $aRisk = Need-Num $seta 'risk_pct' 0 '0.02' -LoOpen -Path 'setA.risk_pct'
  $totCap = Need-Num $Raw 'futures_open_risk_cap_pct' 0 '0.10' -LoOpen -Path 'futures_open_risk_cap_pct'
  $fxCap = Need-Num $Raw 'fx_same_direction_cap_pct' 0 '0.10' -LoOpen -Path 'fx_same_direction_cap_pct'
  if ($null -ne $totCap -and $null -ne $fxCap -and $fxCap -gt $totCap) { $errs.Add('fx_same_direction_cap_pct: больше общего потолка futures_open_risk_cap_pct') }
  $dayHalt = Need-Num $Raw 'daily_entry_loss_halt_pct' 0 '0.10' -LoOpen -Path 'daily_entry_loss_halt_pct'
  $qAge = Need-Num $Raw 'quote_max_age_sec' 1 86400 -Path 'quote_max_age_sec' -Int
  $cAge = Need-Num $Raw 'capital_max_age_sec' 1 86400 -Path 'capital_max_age_sec' -Int

  $cost = [pscustomobject]@{ fee_pct_side = $script:RF_RISK_COST_DEFAULT.fee_pct_side
    stop_slip_pct = $script:RF_RISK_COST_DEFAULT.stop_slip_pct; source = $script:RF_RISK_COST_DEFAULT.source }
  $rc = RkProp $Raw 'cost'
  if ($null -ne $rc) {
    $cost.fee_pct_side = Need-Num $rc 'fee_pct_side' 0 '0.005' -Path 'cost.fee_pct_side'
    $cost.stop_slip_pct = Need-Num $rc 'stop_slip_pct' 0 '0.01' -Path 'cost.stop_slip_pct'
    $cost.source = Need-Str $rc 'source' 'cost.source'
  }
  $tol = $script:RF_RISK_TOL_DEFAULT
  if (RkHas $Raw 'excess_tolerance_pct') { $tol = Need-Num $Raw 'excess_tolerance_pct' 0 '0.5' -Path 'excess_tolerance_pct' }
  $fxg = $script:RF_RISK_FX_DEFAULT
  if (RkHas $Raw 'fx_group') {
    $g = @(RkProp $Raw 'fx_group')
    $bad = @($g | Where-Object { $_ -isnot [string] -or $_.Trim() -eq '' })
    if ($g.Count -eq 0 -or $bad.Count) { $errs.Add('fx_group: ожидался непустой список кодов активов') } else { $fxg = @($g) }
  }

  if ($errs.Count) {
    return [pscustomobject]@{ ok = $false; mode = 'invalid'; policy_id = $policyId; version = 0; hash = ''; p = $null
      error = ($errs.ToArray() -join '; ') }
  }
  $p = [pscustomobject]@{
    policy_id = $policyId; schema_version = [int]$ver; mode = $mode
    core = [pscustomobject]@{ stop_cap_pct = $cCap; risk_pct = $cRisk }
    setA = [pscustomobject]@{ stop_cap_pct = $aCap; risk_pct = $aRisk }
    futures_open_risk_cap_pct = $totCap; fx_same_direction_cap_pct = $fxCap
    daily_entry_loss_halt_pct = $dayHalt
    quote_max_age_sec = [int]$qAge; capital_max_age_sec = [int]$cAge
    cost = $cost; excess_tolerance_pct = $tol; fx_group = @($fxg)
  }
  # Хеш ПАРАМЕТРОВ (без режима: shadow и pilot с одинаковыми числами - одна и та же политика).
  # Каноническая строка: фиксированный порядок ключей, числа в InvariantCulture без хвостовых нулей.
  $canon = @(
    "schema_version=$($p.schema_version)", "policy_id=$($p.policy_id)",
    "apply_to=new_entries", "capital_source=broker_verified", "sizing_rule=$($script:RF_RISK_SIZING_RULE)",
    "core.stop_cap_pct=$(RkFmt $p.core.stop_cap_pct)", "core.risk_pct=$(RkFmt $p.core.risk_pct)",
    "setA.stop_cap_pct=$(RkFmt $p.setA.stop_cap_pct)", "setA.risk_pct=$(RkFmt $p.setA.risk_pct)",
    "futures_open_risk_cap_pct=$(RkFmt $p.futures_open_risk_cap_pct)", "fx_same_direction_cap_pct=$(RkFmt $p.fx_same_direction_cap_pct)",
    "daily_entry_loss_halt_pct=$(RkFmt $p.daily_entry_loss_halt_pct)",
    "quote_max_age_sec=$($p.quote_max_age_sec)", "capital_max_age_sec=$($p.capital_max_age_sec)",
    "cost.fee_pct_side=$(RkFmt $p.cost.fee_pct_side)", "cost.stop_slip_pct=$(RkFmt $p.cost.stop_slip_pct)", "cost.source=$($p.cost.source)",
    "excess_tolerance_pct=$(RkFmt $p.excess_tolerance_pct)", "fx_group=$(@($p.fx_group) -join ',')"
  ) -join "`n"
  return [pscustomobject]@{ ok = $true; mode = $mode; policy_id = $policyId; version = [int]$ver
    hash = (RkSha256 $canon); p = $p; error = '' }
}

# ---------------- капитал ----------------
# Капитал политики - bot_capital_account_rub из снимка брокера этого тика (капитал на последний клиринг:
# валюты + акции бота; внутридневная вариационка в него не входит - плавающий результат учитывается
# отдельно через R_mark и дневной P&L). Свежесть - по времени СНИМКА, а не чтения файла.
function Get-RfRiskCapital($CapitalRub, $CapturedMs, [long]$NowMs, [int]$MaxAgeSec) {
  $r = [pscustomobject]@{ ok = $false; rub = [decimal]0; age_sec = $null; src = 'bot_capital_account_rub'; reason = '' }
  if ($null -eq $CapitalRub -or -not (RkIsNum $CapitalRub)) { $r.reason = 'капитал не посчитан'; return $r }
  $cap = RkDec $CapitalRub
  if ($cap -le 0) { $r.reason = "капитал $(RkFmt $cap) <= 0"; return $r }
  if ($null -eq $CapturedMs -or [long]$CapturedMs -le 0) { $r.reason = 'нет времени снимка капитала'; return $r }
  $age = [math]::Round(($NowMs - [long]$CapturedMs) / 1000.0, 1)
  $r.age_sec = $age
  if ($age -lt 0 -or $age -gt $MaxAgeSec) { $r.reason = "снимок капитала устарел ($age с, допустимо $MaxAgeSec с)"; return $r }
  $r.ok = $true; $r.rub = $cap
  return $r
}

# ---------------- стоп ----------------
# Округление стопа к шагу цены ТОЛЬКО в сторону цены входа: лонг - вверх, шорт - вниз.
# Округление к ближайшему (Round-ToIncrement) могло отодвинуть стоп на полшага - то есть расширить риск.
function Get-RfStopRounded([string]$Side, $Px, $Tick) {
  $s = RkSideSign $Side
  $px = RkDec $Px; $t = RkDec $Tick
  if ($null -eq $px -or $null -eq $t -or $t -le 0) { return $null }
  $n = $px / $t
  $k = if ($s -gt 0) { [math]::Ceiling($n) } else { [math]::Floor($n) }
  return ([decimal]$k * $t)
}
# Действующий стоп: более близкий из исходного стратегического и предела CapPct от реальной цены входа
# (ТЗ §5): лонг max(S_str, E(1-p)), шорт min(S_str, E(1+p)); затем округление к цене входа.
# CapPct = $null - без предела (сетап A: стоп и TP1 сохраняются). Невалидный стоп (на/за входом
# после округления, шаг <= 0) - вход пропускается, предел ради минимальной дистанции НЕ расширяется.
function Get-RfEffectiveStop([string]$Side, $Entry, $StrategyStop, $CapPct, $Tick) {
  $s = RkSideSign $Side
  $e = RkDec $Entry; $ss = RkDec $StrategyStop; $t = RkDec $Tick
  $res = [pscustomobject]@{ valid = $false; stop = $null; raw = $null; strategy = $ss; capped = $false; reason = '' }
  if ($null -eq $e -or $e -le 0) { $res.reason = 'нет цены входа'; return $res }
  if ($null -eq $ss) { $res.reason = 'нет исходного стопа'; return $res }
  if ($null -eq $t -or $t -le 0) { $res.reason = 'шаг цены <= 0'; return $res }
  $raw = $ss
  if ($null -ne $CapPct) {
    $p = RkDec $CapPct
    $cap = if ($s -gt 0) { $e * (1 - $p) } else { $e * (1 + $p) }
    if (($s -gt 0 -and $cap -gt $ss) -or ($s -lt 0 -and $cap -lt $ss)) { $raw = $cap; $res.capped = $true }
  }
  $res.raw = $raw
  $st = Get-RfStopRounded $Side $raw $t
  $res.stop = $st
  if (($s -gt 0 -and $st -ge $e) -or ($s -lt 0 -and $st -le $e)) { $res.reason = 'после округления стоп на/за ценой входа'; return $res }
  $res.valid = $true
  return $res
}

# ---------------- расходы ----------------
# Резерв расходов на лот, ₽. Новый вход: комиссия входа + комиссия выхода + проскальзывание стопа.
# Открытая позиция (-ExitOnly): входная комиссия уже списана, резерв - только выход.
function Get-RfCostPerLot($Px, $RubPerPt, $FeePctSide, $StopSlipPct, [switch]$ExitOnly) {
  $n = (RkDec $Px) * (RkDec $RubPerPt)
  $f = RkDec $FeePctSide; $sl = RkDec $StopSlipPct
  $legs = if ($ExitOnly) { [decimal]1 } else { [decimal]2 }
  return ($n * ($legs * $f + $sl))
}

# ---------------- объём ----------------
# Правило min_original_and_capped_same_budget (ТЗ §6): в одной точке времени с ОДНИМ бюджетом B
#   q_reference = floor(B / убыток на лот при исходном стопе с расходами)
#   q_capped    = floor(B / убыток на лот при ограниченном стопе с расходами)
#   q_final     = min(q_reference, q_capped, прочие кэпы)
# Более близкий стоп сам по себе никогда не увеличивает объём (q_capped >= q_reference всегда).
# q_reference = 0 -> вход пропускается даже при q_capped > 0: иначе предел открывал бы сделки,
# которых нет в контрольном варианте. $Caps - упорядоченный словарь имя -> максимум лотов ($null = нет).
function Get-RfEntrySize($Budget, $StratDist, $CappedDist, $RubPerPt, $CostPerLot, $Caps) {
  $res = [pscustomobject]@{ q_final = 0; q_reference = 0; q_capped = 0; loss_ref_per_lot = $null
    loss_cap_per_lot = $null; binding = ''; reason = '' }
  $B = RkDec $Budget; $rpp = RkDec $RubPerPt; $c = RkDec $CostPerLot
  $dS = RkDec $StratDist; $dC = RkDec $CappedDist
  if ($null -eq $c) { $c = [decimal]0 }
  if ($null -eq $B -or $B -le 0) { $res.reason = 'бюджет риска <= 0'; return $res }
  if ($null -eq $rpp -or $rpp -le 0) { $res.reason = 'стоимость пункта <= 0'; return $res }
  if ($null -eq $dS -or $dS -le 0 -or $null -eq $dC -or $dC -le 0) { $res.reason = 'дистанция стопа <= 0'; return $res }
  if ($dC -gt $dS) { $dC = $dS }   # предел никогда не отдаляет стоп
  $lossRef = $dS * $rpp + $c; $lossCap = $dC * $rpp + $c
  $res.loss_ref_per_lot = $lossRef; $res.loss_cap_per_lot = $lossCap
  $res.q_reference = [int][math]::Floor($B / $lossRef)
  $res.q_capped = [int][math]::Floor($B / $lossCap)
  if ($res.q_reference -le 0) { $res.reason = 'q_reference=0'; return $res }
  $q = [math]::Min($res.q_reference, $res.q_capped); $bind = 'reference'
  if ($null -ne $Caps) {
    foreach ($k in @($Caps.Keys)) {
      $v = $Caps[$k]
      if ($null -eq $v) { continue }
      if ([int]$v -lt $q) { $q = [int]$v; $bind = [string]$k }
    }
  }
  if ($q -lt 0) { $q = 0 }
  $res.q_final = [int]$q; $res.binding = $bind
  if ($q -le 0) { $res.reason = "объём 0 (ограничение $bind)" }
  return $res
}

# ---------------- риск позиции и открытый риск ----------------
# ТЗ §7:  R_from_entry = max(0, q·pv·side·(entry-stop));  R_from_mark = max(0, q·pv·side·(mark-stop));
#         R_charge = max(обоих) + резерв на выход. Максимум, а не сумма - консервативная нагрузка на бюджет.
# Нет котировки -> mark = entry (позиция только что открыта). Рынок уже за стопом при живой позиции ->
# mark_beyond_stop: риск такой позиции стопом не ограничен, движок обязан считать его неизвестным.
function Get-RfPositionRisk([string]$Side, $Lots, $Entry, $Stop, $Mark, $RubPerPt, $ExitCostPerLot) {
  $s = RkSideSign $Side
  $q = RkDec $Lots; $e = RkDec $Entry; $st = RkDec $Stop; $rpp = RkDec $RubPerPt
  $m = RkDec $Mark
  if ($null -eq $m -or $m -le 0) { $m = $e }
  $ec = RkDec $ExitCostPerLot
  if ($null -eq $ec) { $ec = [decimal]0 }
  $rE = $q * $rpp * $s * ($e - $st); if ($rE -lt 0) { $rE = [decimal]0 }
  $rM = $q * $rpp * $s * ($m - $st); if ($rM -lt 0) { $rM = [decimal]0 }
  return [pscustomobject]@{ r_entry = $rE; r_mark = $rM; r_charge = ([math]::Max($rE, $rM) + $q * $ec)
    mark = $m; mark_beyond_stop = (($s * ($m - $st)) -lt 0) }
}
# Сводный риск: позиции ОБОИХ рукавов + ещё способные исполниться входные заявки. $Items - список
# { kind; id; asset; side; r_charge; unknown; reason }. Валютная группа считается по направлениям
# раздельно: противоположные позиции НЕ взаимозачитываются (ТЗ §7).
function Get-RfOpenRisk($Items, $FxGroup) {
  $fx = if ($null -ne $FxGroup -and @($FxGroup).Count) { @($FxGroup) } else { $script:RF_RISK_FX_DEFAULT }
  $byAsset = [ordered]@{}
  $unk = New-Object System.Collections.Generic.List[string]
  $total = [decimal]0; $fxL = [decimal]0; $fxS = [decimal]0; $n = 0
  foreach ($it in @($Items)) {
    if ($null -eq $it) { continue }
    $n = $n + 1
    if ([bool](RkProp $it 'unknown')) { $unk.Add(("{0} {1}: {2}" -f (RkProp $it 'kind'), (RkProp $it 'id'), (RkProp $it 'reason'))) }
    $r = RkDec (RkProp $it 'r_charge')
    if ($null -eq $r) { continue }
    $total += $r
    $a = [string](RkProp $it 'asset')
    if ($a) { if ($byAsset.Contains($a)) { $byAsset[$a] = $byAsset[$a] + $r } else { $byAsset[$a] = $r } }
    if ($fx -contains $a) {
      if ((RkSideSign ([string](RkProp $it 'side'))) -gt 0) { $fxL += $r } else { $fxS += $r }
    }
  }
  return [pscustomobject]@{ total = $total; fx_long = $fxL; fx_short = $fxS; by_asset = $byAsset
    unknown = $unk.ToArray(); items = $n }
}

# ---------------- дневной P&L бота (решение пользователя 2026-09-11) ----------------
# Не разница капитала: на капитал счёта влияют пополнения, выводы и сделки пользователя со СВОИМИ
# бумагами - покупка своих бумаг за рубли выглядела бы убытком бота, продажа прятала бы настоящий.
# Считаем результат самого бота по брокерским данным с проверенной дневной базы (после ночного клиринга):
#   фьючерсы: для каждого инструмента  (var_margin сейчас + маржа закрытых после базы) - var_margin на базе
#             (var_margin непрерывен внутри окна между клирингами; вечерняя сессия прошлого дня уже в базе);
#   акции бота: изменение стоимости mom-рукава; минус комиссии заявок после базы.
# $Base: { vm_by_uid; mom_eq; base_ms; e_base }.  $Now: { vm_by_uid; settle_items[{uid,rub,ts}]; mom_eq; fees_since_base }.
# Инструмент с базы, исчезнувший без записи о марже закрытия, делает результат непроверенным (ok=$false).
function Get-RfDayPnl($Base, $Now) {
  $res = [pscustomobject]@{ ok = $false; pnl = [decimal]0; loss = [decimal]0; fut = [decimal]0; mom = [decimal]0
    fees = [decimal]0; e_base = $null; reason = '' }
  if ($null -eq $Base) { $res.reason = 'нет проверенной дневной базы'; return $res }
  if ($null -eq $Now) { $res.reason = 'нет снимка брокера на этом тике'; return $res }
  $res.e_base = RkDec (RkProp $Base 'e_base')
  $baseVm = RkProp $Base 'vm_by_uid'; $nowVm = RkProp $Now 'vm_by_uid'
  $baseMs = [long](RkProp $Base 'base_ms')
  $settled = @{}
  foreach ($x in @(RkProp $Now 'settle_items')) {
    if ($null -eq $x) { continue }
    if ([long](RkProp $x 'ts') -lt $baseMs) { continue }   # закрыто до базы - не сегодняшний результат
    $u = [string](RkProp $x 'uid'); $v = RkDec (RkProp $x 'rub')
    if (-not $u -or $null -eq $v) { continue }
    if ($settled.ContainsKey($u)) { $settled[$u] = $settled[$u] + $v } else { $settled[$u] = $v }
  }
  $uids = @{}
  foreach ($k in (RkKeys $baseVm)) { $uids[$k] = $true }
  foreach ($k in (RkKeys $nowVm)) { $uids[$k] = $true }
  foreach ($k in $settled.Keys) { $uids[$k] = $true }
  $fut = [decimal]0
  $missing = New-Object System.Collections.Generic.List[string]
  foreach ($u in @($uids.Keys)) {
    $start = RkDec (RkProp $baseVm $u); if ($null -eq $start) { $start = [decimal]0 }
    $hasNow = RkHas $nowVm $u
    $end = [decimal]0
    if ($hasNow) { $v = RkDec (RkProp $nowVm $u); if ($null -ne $v) { $end += $v } }
    if ($settled.ContainsKey($u)) { $end += $settled[$u] }
    if (-not $hasNow -and -not $settled.ContainsKey($u) -and $start -ne 0) { $missing.Add([string]$u) }
    $fut += ($end - $start)
  }
  if ($missing.Count) { $res.reason = "позиция с базы исчезла без записи о марже закрытия: $($missing.ToArray() -join ', ')"; return $res }
  $mb = RkDec (RkProp $Base 'mom_eq'); $mn = RkDec (RkProp $Now 'mom_eq')
  $mom = if ($null -ne $mb -and $null -ne $mn) { $mn - $mb } else { [decimal]0 }
  $fees = RkDec (RkProp $Now 'fees_since_base'); if ($null -eq $fees) { $fees = [decimal]0 }
  $res.fut = $fut; $res.mom = $mom; $res.fees = $fees
  $res.pnl = $fut + $mom - $fees
  $res.loss = if ($res.pnl -lt 0) { -$res.pnl } else { [decimal]0 }
  $res.ok = $true
  return $res
}

# ---------------- решение по входу ----------------
# Все бюджеты от капитала E. $New: { sleeve; asset; side; q_final (после сайзинга и прежних кэпов);
# q_reference; charge_per_lot (нагрузка на бюджет за 1 лот при действующем стопе с расходами) }.
# Итог: allow + q_final (может быть МЕНЬШЕ входного из-за общего/валютного бюджета, никогда не больше);
# kind: 'wait' - временная причина (интент ждёт), 'hard' - вход отменяется.
function Test-RfEntryRisk($P, $Capital, $Open, $New, $Day) {
  $d = [pscustomobject]@{ allow = $false; kind = 'wait'; q_final = 0; binding = ''; reasons = @(); budgets = $null }
  $rs = New-Object System.Collections.Generic.List[string]
  if ($null -eq $Capital -or -not $Capital.ok) {
    $why = if ($null -ne $Capital) { [string]$Capital.reason } else { 'нет данных' }
    $rs.Add("капитал: $why"); $d.reasons = $rs.ToArray(); return $d
  }
  $E = [decimal]$Capital.rub
  $sp = RkProp $P ([string]$New.sleeve)
  $riskPct = RkDec (RkProp $sp 'risk_pct')
  if ($null -eq $riskPct) { $riskPct = [decimal]0 }
  $totCap = $E * [decimal]$P.futures_open_risk_cap_pct
  $fxCap = $E * [decimal]$P.fx_same_direction_cap_pct
  $bud = [pscustomobject]@{
    capital_rub = $E; trade_rub = ($E * $riskPct)
    total_cap_rub = $totCap; total_used_rub = [decimal]$Open.total; total_left_rub = ($totCap - [decimal]$Open.total)
    fx_cap_rub = $fxCap; fx_long_rub = [decimal]$Open.fx_long; fx_short_rub = [decimal]$Open.fx_short
    day_loss_rub = $null; day_limit_rub = $null
  }
  $d.budgets = $bud
  if (@($Open.unknown).Count) { $rs.Add('неизвестный риск: ' + (@($Open.unknown) -join '; ')); $d.reasons = $rs.ToArray(); return $d }
  if ($null -eq $Day -or -not $Day.ok) {
    $why = if ($null -ne $Day) { [string]$Day.reason } else { 'нет данных' }
    $rs.Add("дневной результат не проверен: $why"); $d.reasons = $rs.ToArray(); return $d
  }
  $eBase = if ($null -ne $Day.e_base -and [decimal]$Day.e_base -gt 0) { [decimal]$Day.e_base } else { $E }
  $bud.day_loss_rub = [decimal]$Day.loss
  $bud.day_limit_rub = $eBase * [decimal]$P.daily_entry_loss_halt_pct
  $d.kind = 'hard'
  if ([decimal]$Day.loss -ge $bud.day_limit_rub) {
    $rs.Add("дневной предел: убыток $(RkFmt ([math]::Round([decimal]$Day.loss, 0))) >= $(RkFmt ([math]::Round($bud.day_limit_rub, 0)))")
    $d.reasons = $rs.ToArray(); return $d
  }
  if ([int]$New.q_reference -le 0) { $rs.Add('q_reference=0'); $d.reasons = $rs.ToArray(); return $d }
  $q = [int]$New.q_final; $bind = if ($New.PSObject.Properties['binding'] -and $New.binding) { [string]$New.binding } else { 'reference' }
  if ($q -le 0) { $rs.Add("объём 0 ($bind)"); $d.reasons = $rs.ToArray(); return $d }
  $per = RkDec $New.charge_per_lot
  if ($null -eq $per -or $per -le 0) { $rs.Add('нагрузка на лот <= 0'); $d.reasons = $rs.ToArray(); return $d }
  $qTot = if ($bud.total_left_rub -gt 0) { [int][math]::Floor($bud.total_left_rub / $per) } else { 0 }
  if ($qTot -lt $q) { $q = $qTot; $bind = 'общий бюджет' }
  if (@($P.fx_group) -contains [string]$New.asset) {
    $used = if ((RkSideSign ([string]$New.side)) -gt 0) { [decimal]$Open.fx_long } else { [decimal]$Open.fx_short }
    $left = $fxCap - $used
    $qFx = if ($left -gt 0) { [int][math]::Floor($left / $per) } else { 0 }
    if ($qFx -lt $q) { $q = $qFx; $bind = 'валютная группа' }
  }
  if ($q -lt 1) { $rs.Add("бюджет исчерпан ($bind)"); $d.reasons = $rs.ToArray(); return $d }
  $d.allow = $true; $d.kind = ''; $d.q_final = [int]$q; $d.binding = $bind
  $d.reasons = $rs.ToArray()
  return $d
}

# ---------------- виртуальная ветка (парное сравнение, ТЗ §12) ----------------
# Касание стопа виртуальной ветки по часовому бару. Гэп за уровень: исполнение по худшему из
# открытия и стопа, плюс неблагоприятное проскальзывание.
function Test-RfVirtualBar([string]$Side, $Stop, $Bar, $SlipPct) {
  $s = RkSideSign $Side
  $st = RkDec $Stop; $slip = RkDec $SlipPct
  if ($null -eq $slip) { $slip = [decimal]0 }
  $o = RkDec (RkProp $Bar 'o'); $h = RkDec (RkProp $Bar 'h'); $l = RkDec (RkProp $Bar 'l')
  if ($s -gt 0) {
    if ($l -gt $st) { return [pscustomobject]@{ hit = $false; fill = $null; gap = $false } }
    $gap = ($o -lt $st)
    $b = if ($gap) { $o } else { $st }
    return [pscustomobject]@{ hit = $true; fill = ($b * (1 - $slip)); gap = $gap }
  }
  if ($h -lt $st) { return [pscustomobject]@{ hit = $false; fill = $null; gap = $false } }
  $gap = ($o -gt $st)
  $b = if ($gap) { $o } else { $st }
  return [pscustomobject]@{ hit = $true; fill = ($b * (1 + $slip)); gap = $gap }
}
