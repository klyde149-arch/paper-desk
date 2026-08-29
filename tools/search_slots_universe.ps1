# search_slots_universe.ps1 - драйвер поиска «состав корзины × число слотов» для профиля C3b.
# Исследовательский контур. Торговые движки (rf_engine.ps1 / live_rf_engine.ps1) НЕ трогает,
# канонический $ASSETS в lib_rf_signals.ps1 НЕ меняет. Всё, что делает - гоняет
# tools\backtest_rf_queue.ps1 с разными аргументами и складывает рукава в C3b.
#
# C3b = ядро@CoreRisk + сетапА@SetARisk + 0.5×momentum, помесячно-аддитивно - ровно как
# tools\build_fut_combos.ps1 (строка 48). Реконструкция валидирована: на нынешнем проде
# (8 инструментов, 3+3, риск 5%/2%) даёт 5.22%/мес и худший месяц −23.4% против 5.15% и −23.4%
# в каноне docs\strategy\strategy_moex_fut.md.
#
# Режимы риска (-RiskMode):
#   fixed  - риск на сделку всегда 5% / 2% независимо от числа слотов (что будет в реальности)
#   budget - общий риск постоянен: 15%/n_core и 6%/n_setA (чистый тест идеи «размазать шире»).
#            При 3 слотах даёт ровно 5% и 2%, то есть воспроизводит базу.
#
# ВАЖНО про комиссии: -RealFees включает посимвольные ставки (2 руб/контракт на сторону от
# нотионала лота). Без него все символы платят плоские 0.0001, и мелконотиональные фьючерсы на
# акции выглядят лучше, чем в реальности - у ЭсЭфАй в 31 раз.
param(
  [string]$Root = '',
  [string]$OutJson = '',
  [ValidateSet('fixed','budget')][string]$RiskMode = 'fixed',
  [ValidateSet('none','direct','revalidate')][string]$QueueMode = 'none',
  [int]$CoreSlots = 3,
  [int]$SetASlots = 3,
  [switch]$RealFees,
  [string]$FromDate = '',
  [string]$ToDate = '',
  [string[]]$Universe = @(),
  [string]$Tag = 'run',
  # ДИСЦИПЛИНА ПОИСКА. Метрики C3b считаются только по dev-месяцам (январь-август каждого года),
  # сентябрь-декабрь остаются нетронутым резервом. Это помесячный аналог штатного деления
  # analyze_wf_years.ps1 (70/30 внутри каждого года: для полного года граница приходится примерно
  # на 13 сентября). Хронологический холдаут тут не годится - почти вся история новых инструментов
  # лежит в 2025-2026, и отсечка по 2024 сделала бы их неоцениваемыми.
  # Цена приёма: цепочка месяцев рвётся 4 раза в год, поэтому просадка занижена против истинной.
  # Искажение одинаково для всех конфигураций, так что сравнимость сохраняется, а вот сравнивать
  # эти цифры с полнопериодными (5.22%/мес у прода) НЕЛЬЗЯ.
  [switch]$DevOnly,
  # РЕЗЕРВ (сентябрь-декабрь каждого года) - держится нетронутым весь поиск, вскрывается ОДИН раз
  # для финально выбранной конфигурации. Зеркало -DevOnly с обратным фильтром месяца.
  [switch]$ReserveOnly,
  # Re-arm ядра: после выхода из брейкаут-позиции перевход в ту же сторону в течение ReArmBars баров
  # идёт по укороченному каналу ReArmN вместо BreakoutN. В БОЮ ВКЛЮЧЁН: lib_rf_signals.ps1 держит
  # $REARM_N=10 / $REARM_BARS=15, live_rf_engine.ps1 передаёт состояние в Get-DonchianSide.
  # Конфиг B20-rearm10x15 принят в замороженное ядро 2026-07 (strategy_moex_fut.md).
  # Дефолт 0 = выключено, потому что опубликованные C-кривые считались без него.
  [int]$ReArmN = 0,
  [int]$ReArmBars = 15,
  # Символы, которым re-arm НЕ применяется (проброс к -ReArmExclude в backtest_rf_queue.ps1).
  [string[]]$ReArmExclude = @(),
  # Символы, по которым разрешён только лонг (проброс к -LongOnly). Применяется к ОБОИМ рукавам;
  # momentum не затронут - он и так только покупает. Мотив 2026-08-27: VTBR/SBRF - поставочные
  # фьючерсы, шорт по ним брокер не принимает при выключенной маржиналке.
  [string[]]$LongOnly = @()
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
$DataDir = Join-Path $Root 'data\moex_fut'
$MomFile = Join-Path $Root 'data\moex\bt_monthly_mom63_full.json'

# Нотионал лота в рублях (цена × ₽/пункт, ISS 2026-08-12). Нужен только для модели комиссий.
$NOTIONAL = @{
  BR=73494; NG=22793; GOLD=361556; SILV=53897; Si=83311; RTS=145094; CNY=12357; MIX=235550
  Eu=96395; ED=94912; PLT=147804; PLD=114245; UCNY=82509; COCOA=4653; COFFEE=2781; COPPER=11806
  SBRF=29087; VTBR=5962; LKOH=47835; ROSN=35843; YDEX=4078; T=2875; NOTKM=10526; PLZLM=13438; SFIN=638
}
$RUB_PER_CONTRACT_SIDE = 2.0   # допущение: 4 ₽/контракт за круг = 2 ₽ на сторону. Тариф не подтверждён.

$ALL25 = @('BR','NG','GOLD','SILV','Si','RTS','CNY','MIX',
           'Eu','ED','PLT','PLD','UCNY','COCOA','COFFEE','COPPER',
           'SBRF','VTBR','LKOH','ROSN','YDEX','T','NOTKM','PLZLM','SFIN')
if (-not $Universe -or $Universe.Count -eq 0) { $Universe = $ALL25 }

function Get-FeeTable([string[]]$Syms) {
  $h = @{}
  if (-not $RealFees) { return $h }
  foreach ($s in $Syms) {
    if ($NOTIONAL.ContainsKey($s) -and [double]$NOTIONAL[$s] -gt 0) {
      $h[$s] = [math]::Round($RUB_PER_CONTRACT_SIDE / [double]$NOTIONAL[$s], 8)
    }
  }
  return $h
}

# Один прогон рукава -> путь к файлу кривой капитала
function Invoke-Sleeve([string]$Sleeve, [string[]]$Syms, [double]$Risk, [int]$Slots, [string]$OutTag) {
  $p = @{
    Symbols = $Syms; DataDir = $DataDir; FileSuffix = '_1d'; MaxLev = 3
    FeePct = 0.0001; RiskPct = $Risk; MaxConcurrent = $Slots
    DailyLossHaltPct = 0.06; QueueMode = $QueueMode; OutTag = $OutTag
  }
  if ($FromDate) { $p.FromDate = $FromDate }
  if ($ToDate)   { $p.ToDate   = $ToDate }
  $fees = Get-FeeTable $Syms
  if ($fees.Count) { $p.FeePctBySymbol = $fees }
  if ($LongOnly.Count) { $p.LongOnly = $LongOnly }
  if ($Sleeve -eq 'core') {
    $p.Breakout = $true; $p.BreakoutN = 20; $p.AtrStopMult = 2.0; $p.AtrTrailMult = 3.0
    if ($ReArmN -gt 0) { $p.ReArmN = $ReArmN; $p.ReArmBars = $ReArmBars; $p.ReArmExclude = $ReArmExclude }   # re-arm только у ядра
  }
  else { $p.AtrStopMult = 1.0 }
  $null = & (Join-Path $PSScriptRoot 'backtest_rf_queue.ps1') @p
  return (Join-Path $DataDir "btq_equity_$OutTag.json")
}

# Месячные доходности (в процентах) из кривой капитала
function Get-MonthlyPct([string]$Path) {
  $eq = Get-Content $Path -Raw | ConvertFrom-Json
  $last = [ordered]@{}
  foreach ($x in @($eq)) { $last[[string]$x.day.Substring(0,7)] = [double]$x.equity }
  $out = [ordered]@{}; $prev = $null
  foreach ($m in $last.Keys) {
    $out[$m] = if ($null -eq $prev) { 0.0 } else { ([double]$last[$m] / $prev - 1.0) * 100.0 }
    $prev = [double]$last[$m]
  }
  return $out
}

# Сборка C3b: ядро + setA + 0.5×momentum, помесячно-аддитивно
function Build-C3b($mCore, $mSetA, $mMom) {
  $months = @($mCore.Keys + $mSetA.Keys + $mMom.Keys | Sort-Object -Unique)
  if ($DevOnly) { $months = @($months | Where-Object { [int]$_.Substring(5,2) -le 8 }) }
  if ($ReserveOnly) { $months = @($months | Where-Object { [int]$_.Substring(5,2) -gt 8 }) }
  $eq = 100.0; $peak = 100.0; $dd = 0.0; $worst = 0.0; $n = 0
  foreach ($m in $months) {
    $r = 0.0
    if ($mCore.Contains($m)) { $r += [double]$mCore[$m] }
    if ($mSetA.Contains($m)) { $r += [double]$mSetA[$m] }
    if ($mMom.Contains($m))  { $r += 0.5 * [double]$mMom[$m] }
    if ($r -lt $worst) { $worst = $r }
    $eq *= (1 + $r / 100.0)
    if ($eq -gt $peak) { $peak = $eq }
    $d = ($peak - $eq) / $peak * 100.0; if ($d -gt $dd) { $dd = $d }
    $n++
  }
  $mo = if ($n -gt 0) { ([math]::Pow($eq / 100.0, 1.0 / $n) - 1) * 100.0 } else { 0.0 }
  return [pscustomobject]@{
    monthlyPct = [math]::Round($mo, 3); maxDDPct = [math]::Round($dd, 2)
    multiple = [math]::Round($eq / 100.0, 2); worstMonthPct = [math]::Round($worst, 2); months = $n
  }
}

$momRaw = Get-Content $MomFile -Raw | ConvertFrom-Json
$mMom = [ordered]@{}; foreach ($x in @($momRaw)) { $mMom[[string]$x.month] = [double]$x.ret_pct }

$coreRisk = if ($RiskMode -eq 'budget') { 0.15 / $CoreSlots } else { 0.05 }
$setaRisk = if ($RiskMode -eq 'budget') { 0.06 / $SetASlots } else { 0.02 }

$eqCore = Invoke-Sleeve 'core' $Universe $coreRisk $CoreSlots "srch_${Tag}_c"
$eqSetA = Invoke-Sleeve 'setA' $Universe $setaRisk $SetASlots "srch_${Tag}_a"
$res = Build-C3b (Get-MonthlyPct $eqCore) (Get-MonthlyPct $eqSetA) $mMom

$out = [pscustomobject]@{
  tag = $Tag; universe = $Universe; nSymbols = $Universe.Count
  coreSlots = $CoreSlots; setASlots = $SetASlots; riskMode = $RiskMode
  coreRisk = $coreRisk; setaRisk = $setaRisk; queueMode = $QueueMode
  realFees = [bool]$RealFees; fromDate = $FromDate; toDate = $ToDate; devOnly = [bool]$DevOnly; reserveOnly = [bool]$ReserveOnly
  longOnly = @($LongOnly)
  monthlyPct = $res.monthlyPct; maxDDPct = $res.maxDDPct; multiple = $res.multiple
  worstMonthPct = $res.worstMonthPct; months = $res.months
}
if ($OutJson) { $out | ConvertTo-Json -Depth 4 -Compress | Out-File $OutJson -Encoding utf8 }
return $out
