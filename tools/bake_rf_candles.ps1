# bake_rf_candles.ps1 - печёт свечи T-Invest в data/live_rf/candles/<CODE>_<tf>.json.
# ТОЛЬКО на VPS: токен T-Invest есть лишь там; build_vizdata (GitHub Actions/локально) и браузер
# токена не имеют. Вызывается из deploy/live_rf_tick.sh на 15-минутных марках (перед git add).
# Формат файла: массивы [t,o,h,l,c,v], t = MSK-как-UTC ms (Get-TiCandles уже сдвигает +3ч).
# Потребители: build_vizdata.ps1 (мини-графики позиций) и report/chart.html (большой график),
# оба предпочитают эти файлы с фолбэком на MOEX ISS. Только чтение - торговлю не трогает.
param([string]$Root = '', [switch]$SnapshotOnly, [int]$TimeBudgetSec = 240)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'lib_engine.ps1')
. (Join-Path $PSScriptRoot 'lib_tinvest.ps1')
. (Join-Path $PSScriptRoot 'lib_msg_ru.ps1')

$lrfDir = Join-Path $Root 'data\live_rf'
$mode = if ($env:TINVEST_MODE) { $env:TINVEST_MODE } else { 'prod' }
Initialize-TInvest $lrfDir $mode

$outDir = Join-Path $lrfDir 'candles'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force $outDir | Out-Null }

# Универсум графиков = фьючерсы (коды активов, как в chart.html SYMS) + 12 momentum-акций TQBR.
# ВНИМАНИЕ: это СОБСТВЕННАЯ копия списка, файл не дот-сорсит lib_rf_signals.ps1 -
# при правке $ASSETS в каноне синхронизировать здесь вручную (2026-08: 8 -> 12).
$ASSETS = @('BR', 'NG', 'GOLD', 'SILV', 'Si', 'CNY', 'MIX', 'Eu', 'COCOA', 'VTBR', 'PLD', 'SBRF')
$TICKERS = @('SBER', 'GAZP', 'LKOH', 'ROSN', 'NVTK', 'GMKN', 'TATN', 'MGNT', 'CHMF', 'PLZL', 'YDEX')

# фронт-контракты (секиды) из portfolio.json
$fronts = @{}
$pfPath = Join-Path $lrfDir 'portfolio.json'
if (Test-Path $pfPath) {
  try {
    $pf = Get-Content $pfPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($pf.PSObject.Properties['fronts']) {
      foreach ($a in $pf.fronts.PSObject.Properties.Name) { $fronts[$a] = [string]$pf.fronts.$a.secid }
    }
  } catch { Write-Host "bake_rf_candles: portfolio.json нечитаем: $($_.Exception.Message)" }
}

# Единый read-model для ассистента, Mini App и статического отчёта. Он строится ПОСЛЕ
# торгового тика и никогда не участвует в принятии заявок; ошибка здесь не ломает движок.
function Pct($Now, $Base) {
  if ($null -eq $Now -or $null -eq $Base -or [double]$Base -le 0) { return $null }
  return [math]::Round((([double]$Now / [double]$Base) - 1) * 100, 2)
}
function Build-RfPresentationSnapshot($State) {
  $eqRows = @()
  $eqPath = Join-Path $lrfDir 'equity.json'
  if (Test-Path $eqPath) { try { $eqRows = @((Get-Content $eqPath -Raw -Encoding UTF8 | ConvertFrom-Json) | Where-Object { $null -ne $_ }) } catch { throw "equity.json: $($_.Exception.Message)" } }
  $trades = @()
  $trPath = Join-Path $lrfDir 'trades.json'
  if (Test-Path $trPath) { try { $trades = @((Get-Content $trPath -Raw -Encoding UTF8 | ConvertFrom-Json) | Where-Object { $null -ne $_ }) } catch { throw "trades.json: $($_.Exception.Message)" } }

  # Кривая капитала. Точка берётся по модели «счёт брокера» (bot_capital_account), как только
  # эта колонка появилась в строке; до неё - историческая bot_capital, завышенная на вариационку
  # того тика. Иначе последняя точка кривой разошлась бы с плиткой «Капитал бота», которая уже
  # показывает число брокера. Стык помечаем явно ($capJoinTs) - подпись под графиком объясняет
  # его пользователю, а не делает вид, что ряд однороден.
  $capRows = @($eqRows | Where-Object { $_.PSObject.Properties['bot_capital'] -and $_.PSObject.Properties['account_liquid'] -and $null -ne $_.bot_capital -and [double]$_.account_liquid -gt 0 })
  $capJoinTs = $null
  foreach ($r in $capRows) {
    if ($r.PSObject.Properties['bot_capital_account'] -and $null -ne $r.bot_capital_account) { $capJoinTs = [long]$r.ts; break }
  }
  $capCurve = @($capRows | ForEach-Object {
    $v = if ($_.PSObject.Properties['bot_capital_account'] -and $null -ne $_.bot_capital_account) { [double]$_.bot_capital_account } else { [double]$_.bot_capital }
    ,@([long]$_.ts, $v)
  })
  $curve = @($eqRows | Where-Object { $_.PSObject.Properties['total'] -and $null -ne $_.total -and [double]$_.total -gt 0 } | ForEach-Object { ,@([long]$_.ts, [double]$_.total) })
  $brk = if ($State.PSObject.Properties['broker']) { $State.broker } else { $null }
  # КАПИТАЛ = счёт у брокера (total_amount_portfolio), решение пользователя 2026-09-01.
  # Приоритет: bot_capital_account_rub (Set-BotCapital, без двойного счёта вариационки) ->
  # исторический bot_capital_rub -> paper-модель. Прямое чтение broker.totals.portfolio НЕ
  # берём: bot_capital_account_rub уже вычитает то, что брокер держит, но бот не считает своим.
  $capital = if ($State.go.PSObject.Properties['bot_capital_account_rub'] -and $null -ne $State.go.bot_capital_account_rub) { [double]$State.go.bot_capital_account_rub }
             elseif ($State.go.PSObject.Properties['bot_capital_rub'] -and $null -ne $State.go.bot_capital_rub) { [double]$State.go.bot_capital_rub }
             else { [double]$State.profile_eq }
  $peak = if ($State.go.PSObject.Properties['capital_peak_rub'] -and $null -ne $State.go.capital_peak_rub) { [double]$State.go.capital_peak_rub } else { [double]$State.peak_eq }
  $capModel = if ($null -ne $State.capital_breakdown -and $State.capital_breakdown.PSObject.Properties['model']) { [string]$State.capital_breakdown.model } else { 'legacy' }
  # Пик копился на СТАРОЙ шкале (капитал + вариационка), поэтому просадка от него к новому
  # капиталу - арифметика двух разных линеек. Пока модели не совпали, просадку не показываем
  # вовсе: заведомо неверное число хуже прочерка. Ребейз пика - отдельный этап.
  $peakStale = ($capModel -eq 'legacy' -and $State.go.PSObject.Properties['bot_capital_account_rub'] -and $null -ne $State.go.bot_capital_account_rub)
  $ddPct = if ($peakStale) { $null } else { Pct $capital $peak }
  $today = (Get-Date).ToUniversalTime().AddHours(3).ToString('yyyy-MM-dd')
  $dayBase = $null; $daySource = 'day_start_eq_stale'; $todayAmt = $null; $todayPct = $null
  # «Сегодня» - число САМОГО брокера (daily_yield / daily_yield_relative), то же, что видно в
  # приложении. Наш прежний расчёт (капитал - база дня) брал базу из day_start_eq либо из
  # закрытия прошлого дня и на 2026-09-01 давал +89 829 / +5,65% против брокерских
  # +100 564 / +6,84%: он наследовал завышение капитала и терял переоценку валют.
  if ($null -ne $brk -and $null -ne $brk.daily_yield_rub) {
    $todayAmt = [double]$brk.daily_yield_rub
    $todayPct = if ($null -ne $brk.daily_yield_rel_pct) { [math]::Round([double]$brk.daily_yield_rel_pct, 2) } else { $null }
    $dayBase = [math]::Round($capital - $todayAmt, 2)
    $daySource = 'broker_daily_yield'
  }
  else {
    if ([string]$State.day_start_date -eq $today -and [double]$State.day_start_eq -gt 0) { $dayBase = [double]$State.day_start_eq; $daySource = 'day_start_eq' }
    else {
      $start = [datetimeoffset]::Parse("${today}T00:00:00+03:00").ToUnixTimeMilliseconds()
      $before = @($capCurve | Where-Object { [long]$_[0] -lt $start })
      if ($before.Count) { $dayBase = [double]$before[-1][1]; $daySource = 'prev_day_close' }
      elseif ([double]$State.day_start_eq -gt 0) { $dayBase = [double]$State.day_start_eq }
    }
    if ($null -ne $dayBase) { $todayAmt = [math]::Round($capital - $dayBase, 2); $todayPct = (Pct $capital $dayBase) }
  }
  # Брокерский P&L по карточкам пишет движок (Invoke-Mtm) - здесь только чтение.
  $cardPnl = @{}
  if ($State.PSObject.Properties['broker_pnl_by_card'] -and $null -ne $State.broker_pnl_by_card) {
    foreach ($pr in $State.broker_pnl_by_card.PSObject.Properties) { $cardPnl[$pr.Name] = [double]$pr.Value }
  }
  $brkByUid = @{}
  if ($null -ne $brk) { foreach ($bp in @($brk.positions)) { if ($null -ne $bp -and $bp.uid) { $brkByUid[[string]$bp.uid] = $bp } } }
  $names = Get-RuNames $Root
  $positions = @()
  foreach ($sn in 'core','setA') {
    foreach ($p in @($State.sleeves.$sn.positions | Where-Object { $null -ne $_ })) {
      $entry = [double]$p.entry_px_pts; $cur = if ($null -ne $p.cur_px) { [double]$p.cur_px } else { $null }
      # pctChg - движение ЦЕНЫ, не доходность. Оставлен в payload ради контракта Mini App,
      # но дашборд его больше не рисует: рядом с рублями он читался как доходность и врал
      # (Eu показывал +0,13% при +36 680 ₽). Замена - pnlPctGo, см. ниже. DEPRECATED.
      $ratio = if ($p.side -eq 'short' -and $null -ne $cur -and $cur -ne 0) { $entry / $cur } else { if ($null -ne $cur -and $entry -ne 0) { $cur / $entry } else { $null } }
      $pct = if ($null -ne $ratio) { [math]::Round((($ratio - 1) * 100), 2) } else { $null }
      # Главная цифра P&L позиции - БРОКЕРСКАЯ (expected_yield: накопленная вариационка по
      # контракту с момента открытия). Именно её показывает приложение Т-Инвестиций, и именно
      # её берёт вечерний отчёт. Наш upnl_rub (переоценка открытых лотов от цены входа)
      # остаётся рядом как второе, подписанное число - он отвечает на другой вопрос.
      $bPnl = if ($cardPnl.ContainsKey([string]$p.id)) { [math]::Round([double]$cardPnl[[string]$p.id], 2) } else { $null }
      $bp = if ($p.uid -and $brkByUid.ContainsKey([string]$p.uid)) { $brkByUid[[string]$p.uid] } else { $null }
      # ГО этой позиции: lots * go_per_lot (сумма по карточкам сходится с go.used_rub).
      $goRub = if ($null -ne $p.go_per_lot) { [math]::Round([double]$p.lots * [double]$p.go_per_lot, 0) } else { $null }
      # Процент = доходность на задействованную маржу (решение пользователя 2026-09-01).
      # База - P&L ЭТОЙ позиции (upnl), а НЕ brokerPnl: expected_yield брокера считается по
      # КОНТРАКТУ с момента, когда позиция по нему была нулевой, и у контракта, переоткрытого
      # в тот же день без выхода в ноль, включает прибыль уже закрытых сделок. По CRU6 27.08
      # это давало 55 910 вместо 18 177 -> 23,89% на ГО вместо 7,73%, причём те же рубли
      # второй раз лежали в «P&L сделок» и в таблице закрытых сделок.
      $pnlPctGo = if ($null -ne $p.upnl_rub -and $null -ne $goRub -and $goRub -gt 0) { [math]::Round(100.0 * [double]$p.upnl_rub / $goRub, 2) } else { $null }
      $positions += [pscustomobject]@{ id=$p.id; sleeve=$sn; asset=$p.asset; secid=$p.secid; title=(RuName $names 'fut' ([string]$p.asset) ([string]$p.secid)); side=$p.side; lots=$p.lots; entry=$entry; stop=$p.stop_px_pts; tp1=$p.tp1_px_pts; cur=$cur; upnl=$p.upnl_rub; risk=$p.risk_rub; entryDay=$p.entry_day; entryTs=$p.entry_ts; rolls=$p.rolls; rubPerPt=$p.rub_per_pt; notional=[math]::Round([double]$p.lots*$entry*[double]$p.rub_per_pt,0); pctChg=$pct; reconcileStatus=$p.reconcile_status; reconcileSinceTs=$p.reconcile_since_ts
        brokerPnl=$bPnl; goRub=$goRub; pnlPctGo=$pnlPctGo
        brokerVarMargin=$(if ($null -ne $bp) { $bp.var_margin } else { $null })
        brokerVarMarginSettled=$(if ($null -ne $bp) { $bp.var_margin_settled } else { $null })
        brokerAvgPx=$(if ($null -ne $bp) { $bp.avg_px } else { $null })
        brokerCurPx=$(if ($null -ne $bp) { $bp.cur_px } else { $null })
        brokerLots=$(if ($null -ne $bp) { $bp.lots } else { $null }) }
    }
  }
  # sleeve/lots нужны дашборду (колонка «Рукав» в «Закрытых сделках»); Mini App лишние поля игнорирует.
  $closed = @($trades | ForEach-Object { [pscustomobject]@{ id=$_.id; sleeve=$_.sleeve; asset=$_.asset; secid=$_.secid; title=(RuName $names 'fut' ([string]$_.asset) ([string]$_.secid)); side=$_.side; lots=$_.lots; entryDay=$_.entryDay; entry=$_.entry; exitDay=$_.exitDay; exitPx=$_.exitPx; exitReason=$_.exitReason; pnl=$_.pnlRub; rMultiple=$_.rMultiple; fees=$_.feesRub } })
  $wins = @($closed | Where-Object { [double]$_.pnl -gt 0 }).Count
  $holdings = @($State.sleeves.mom.holdings | Where-Object { $null -ne $_ } | ForEach-Object { [pscustomobject]@{ sym=$_.sym; lots=$_.lots; lotSize=$_.lot_size; avg=$_.avg_px; last=$_.last_px } })
  $realizedPnl = [math]::Round(($closed | Measure-Object pnl -Sum).Sum, 2)
  $feesEst = [math]::Round(($closed | Measure-Object fees -Sum).Sum, 2)
  # Плавающий P&L открытых позиций - по брокеру (строки в сверке не считаем: их у брокера нет).
  $openPnl = 0.0
  foreach ($op in $positions) {
    if ($op.reconcileStatus) { continue }
    if ($null -ne $op.brokerPnl) { $openPnl += [double]$op.brokerPnl }
    elseif ($null -ne $op.upnl) { $openPnl += [double]$op.upnl }
  }
  $openPnl = [math]::Round($openPnl, 2)
  # РЕЗУЛЬТАТ БОТА с запуска. Источник - брокерский леджер (Invoke-BrokerLedger): сведённая на
  # клирингах вариационка + текущая несведённая - фактические комиссии. Сверено 2026-09-01:
  # 60 379,99 + 99 844,00 - 21 684,47 = 138 539,52 ₽.
  # НЕЛЬЗЯ считать как «закрытые + открытые по брокеру»: expected_yield копится по КОНТРАКТУ с
  # момента, когда позиция по нему была нулевой, и у переоткрытого внутри дня контракта
  # (CRU6/EuU6 27.08) включает P&L сделок, которые уже лежат в trades.json - те же 84 тыс.
  # пришли бы дважды. Фолбэк без леджера - наш собственный, внутренне согласованный набор
  # (закрытые + переоценка открытых лотов), он тоже не двоит.
  $lg = if ($State.PSObject.Properties['broker_ledger']) { $State.broker_ledger } else { $null }
  $curVm = if ($null -ne $State.capital_breakdown -and $null -ne $State.capital_breakdown.futures) { [double]$State.capital_breakdown.futures } else { 0.0 }
  $feesFact = $null; $netSince = $null; $netSource = 'ledger'
  if ($null -ne $lg -and $null -ne $lg.varmargin_rub) {
    $feesFact = [math]::Abs([math]::Round([double]$lg.fees_rub, 2))
    $netSince = [math]::Round([double]$lg.varmargin_rub + $curVm + [double]$lg.fees_rub, 2)
    $netSource = 'broker_ops'
  } else {
    $ownOpen = 0.0
    foreach ($op in $positions) { if (-not $op.reconcileStatus -and $null -ne $op.upnl) { $ownOpen += [double]$op.upnl } }
    $netSince = [math]::Round($realizedPnl + $ownOpen, 2)
  }
  # Процента «за период» у этого счёта честного нет: пополнений деньгами не было, счёт вырос
  # переводом собственных бумаг пользователя в рубли. Даём оценку от базы «капитал минус сам
  # результат» и подписываем, что это оценка, а не доходность за период.
  $netBase = $capital - $netSince
  $netPct = if ($netBase -gt 0) { [math]::Round(100.0 * $netSince / $netBase, 2) } else { $null }
  $accTotal = if ($null -ne $State.capital_breakdown -and $null -ne $State.capital_breakdown.portfolio_total) { [double]$State.capital_breakdown.portfolio_total } elseif ($null -ne $brk -and $null -ne $brk.totals) { $brk.totals.portfolio } else { $null }
  $userAssets = if ($null -ne $State.capital_breakdown -and $null -ne $State.capital_breakdown.user_assets) { [double]$State.capital_breakdown.user_assets } else { $null }
  return [ordered]@{
    schema=1; generatedAtMs=(UtcNowMs); sourceAtMs=$State.watermarks.last_eq_snap
    summary=[ordered]@{ mode=$State.mode; accountId=$State.account_id; capital=$capital; peak=$peak; drawdownPct=$ddPct; peakStale=[bool]$peakStale; capitalModel=$capModel; accountTotal=$accTotal; userAssets=$userAssets; dayBase=$dayBase; dayBaseSource=$daySource; todayAmt=$todayAmt; todayPct=$todayPct; allTimePct=$netPct; allTimeAmt=$netSince; allTimeNote='результат бота с запуска по данным брокера; пополнений деньгами не было — рост счёта дал перевод ваших бумаг в рубли, поэтому процент здесь оценочный'; allTimeSource=$netSource; openPositions=$positions.Count; tradesPnl=$realizedPnl; fees=$feesEst; feesBrokerRub=$feesFact; openPnlBroker=$openPnl; winRate=$(if($closed.Count){[math]::Round(100*$wins/$closed.Count,1)}else{$null}); wins=$wins; losses=$closed.Count-$wins; entriesHalt=[bool]$State.entries_halt.active; haltReason=$State.entries_halt.reason; goUsed=$State.go.used_rub; goBudget=$State.go.budget_rub; accountLiquid=$State.go.account_liquid_rub; lastDailyDay=$State.watermarks.last_daily_day }
    broker=$brk; capitalCurveJoinTs=$capJoinTs
    operational=[ordered]@{ go=$State.go; drift=$State.drift; stats=$State.stats; capitalBreakdown=$State.capital_breakdown; active=$State.active; consecFail=$State.consec_fail }
    sleeves=[ordered]@{ core=[ordered]@{equity=$State.sleeves.core.equity_mtm; dayPct=(Pct $State.sleeves.core.equity_mtm $State.sleeves.core.day_start_eq)}; setA=[ordered]@{equity=$State.sleeves.setA.equity_mtm; dayPct=(Pct $State.sleeves.setA.equity_mtm $State.sleeves.setA.day_start_eq)}; mom=[ordered]@{equity=$State.sleeves.mom.equity_mtm; dayPct=(Pct $State.sleeves.mom.equity_mtm $State.sleeves.mom.day_start_eq)} }
    positions=$positions; holdings=$holdings; closedTrades=$closed; equity=$curve; capitalCurve=$capCurve
  }
}
if ($pf) {
  try { Write-JsonAtomic (Join-Path $Root 'data\rf_presentation_snapshot.json') (Build-RfPresentationSnapshot $pf) 12; Write-Host 'rf presentation snapshot: готово' }
  catch { Write-Warning "rf presentation snapshot: $($_.Exception.Message)" }
}
if ($SnapshotOnly) { return }
if (-not $script:TI.token) { Write-Host 'bake_rf_candles: нет токена T-Invest - свечи пропущены'; return }
if ($TimeBudgetSec -le 0) { Write-Host 'bake_rf_candles: TimeBudgetSec=0 - свечи пропущены'; return }

# Бюджет времени. Обход 23 инструментов - это ~180 вызовов GetCandles/FutureBy, и его цена
# целиком зависит от того, как быстро сегодня отвечает брокер: обычно 40-75 с, но 2026-08-18
# с 17:15 до 17:47 UTC свечные ответы замедлились вдвое и выпечка перевалила за 100 с. Тогда
# она жила внутри торгового тика и убивала его по TimeoutStartSec=110 ДО git-коммита - час без
# публикации состояния. Выпечка вынесена в свой юнит (deploy/rf-bake.*), но бюджет нужен и там:
# без него медленный прогон наезжает на следующий и flock -n глотает очередной запуск.
# Исчерпание бюджета - штатный исход, а не ошибка: записанное остаётся валидным (каждый файл
# пишется целиком), недостающее доберёт следующий прогон через 15 минут.
$script:bakeSw = [Diagnostics.Stopwatch]::StartNew()
function Test-BudgetLeft([string]$Next) {
  if ($script:bakeSw.Elapsed.TotalSeconds -lt $TimeBudgetSec) { return $true }
  Write-Host ("bake_rf_candles: бюджет {0} с исчерпан перед {1} - остальное доберёт следующий прогон" -f $TimeBudgetSec, $Next)
  return $false
}

# ТФ дашборда для РФ = 1h и 1D (chart.html поддерживает только их для fut/moex).
# Окна ограничены, чтобы влезть в лимиты диапазона GetCandles и не раздувать git.
$TFS = @(
  @{ id = '1h'; iv = 'CANDLE_INTERVAL_HOUR'; days = 30;  win = 7 },
  @{ id = '1D'; iv = 'CANDLE_INTERVAL_DAY';  days = 365; win = 300 }
)

$uidCache = @{}
function Resolve-Uid([string]$Code, [string]$Kind) {
  $key = "$Kind|$Code"
  if ($uidCache.ContainsKey($key)) { return $uidCache[$key] }
  $u = ''
  try { $i = Get-TiInstrument $Code $Kind; $u = [string]$i.uid } catch { Write-Host "  uid $Code ($Kind): $($_.Exception.Message)" }
  $uidCache[$key] = $u
  return $u
}

function Get-CandlesWindowed([string]$Uid, [string]$Iv, [int]$Days, [int]$Win) {
  $rows = New-Object System.Collections.Generic.List[object]
  $nowU = (Get-Date).ToUniversalTime()
  $from = $nowU.AddDays(-$Days)
  while ($from -lt $nowU) {
    $to = $from.AddDays($Win); if ($to -gt $nowU) { $to = $nowU }
    $fi = $from.ToString('yyyy-MM-ddTHH:mm:ssZ'); $ti = $to.ToString('yyyy-MM-ddTHH:mm:ssZ')
    try { foreach ($c in (Get-TiCandles $Uid $Iv $fi $ti)) { $rows.Add($c) } }
    catch { Write-Host "  окно $fi..${ti}: $($_.Exception.Message)" }
    $from = $to
  }
  return $rows
}

function Save-CodeCandles([string]$Code, [string]$Uid) {
  if (-not $Uid) { Write-Host "  ${Code}: нет uid - пропуск"; return }
  foreach ($tf in $TFS) {
    $rows = Get-CandlesWindowed $Uid $tf.iv $tf.days $tf.win
    if (-not $rows.Count) { continue }
    # dedup по t (окна могут перекрываться на границе) + сортировка
    $seen = @{}
    $arr = @($rows | Sort-Object t | Where-Object { if ($seen.ContainsKey($_.t)) { $false } else { $seen[$_.t] = $true; $true } } |
      ForEach-Object { , @([long]$_.t, [double]$_.o, [double]$_.h, [double]$_.l, [double]$_.c, [double]$_.v) })
    if (-not $arr.Count) { continue }
    $json = ConvertTo-Json -InputObject $arr -Depth 4 -Compress
    $fp = Join-Path $outDir ("{0}_{1}.json" -f $Code, $tf.id)
    $old = if (Test-Path $fp) { [IO.File]::ReadAllText($fp) } else { '' }
    if ($old -ne $json) {
      [IO.File]::WriteAllText($fp, $json, (New-Object System.Text.UTF8Encoding($false)))
      Write-Host ("  {0}_{1}: {2} свечей" -f $Code, $tf.id, $arr.Count)
    }
    Start-Sleep -Milliseconds 80   # мягкий троттлинг под лимиты
  }
}

foreach ($a in $ASSETS) {
  if (-not (Test-BudgetLeft $a)) { break }
  $secid = if ($fronts.ContainsKey($a)) { $fronts[$a] } else { '' }
  if (-not $secid) { Write-Host "  ${a}: нет фронта в portfolio.json - пропуск"; continue }
  # Страховка от коллизии имён: если код фьючерса совпадёт с тикером momentum-акции, свечи
  # разного масштаба (пункты против рублей) ушли бы в один файл. Сейчас пересечений нет -
  # акция VTBR выведена из $TICKERS ровно поэтому, - но проверка оставлена на будущее.
  if ($TICKERS -contains $a) { throw "bake_rf_candles: код фьючерса '$a' совпадает с momentum-тикером - свечи затрут друг друга" }
  Save-CodeCandles $a (Resolve-Uid $secid 'fut')
}
foreach ($t in $TICKERS) {
  if (-not (Test-BudgetLeft $t)) { break }
  Save-CodeCandles $t (Resolve-Uid $t 'share')
}

Write-Host ('bake_rf_candles: готово за {0:n1} с' -f $script:bakeSw.Elapsed.TotalSeconds)
