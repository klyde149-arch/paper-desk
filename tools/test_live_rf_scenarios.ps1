# test_live_rf_scenarios.ps1 - сценарная матрица live_rf_engine.ps1 на mock-транспорте (без сети/токена).
# Подключается из test_live_rf.ps1 (секция scenarios). Каждый сценарий: чистый корень + фикстуры/очередь
# mock-ответов + прогон тиков движка ДОЧЕРНИМ процессом (изоляция script-scope кэшей) + assert'ы по json.
# Время фиксированное: среда 2026-07-15 (будни), вотермарки выставлены так, что дневной/часовой хуки
# не лезут в сеть (сигнальный путь покрыт golden-replay против paper).

$WORK = Join-Path $env:TEMP 'lrf_scenarios'
if (Test-Path $WORK) { Remove-Item $WORK -Recurse -Force }
New-Item -ItemType Directory -Force $WORK | Out-Null
$ENGINE = Join-Path $PSScriptRoot 'live_rf_engine.ps1'
$MSKOFF = [long]10800000

function MskToNowMs([string]$MskStr) { (UtcStrToMs $MskStr) - $MSKOFF }

function Write-Json([string]$Path, $Obj) {
  $json = ConvertTo-Json -InputObject $Obj -Depth 14
  [IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-SynthSeries([string]$Root, [string]$Name, [double]$Close, [double]$Range) {
  # 40 будних баров, заканчиваются 2026-07-14; h-l = Range (ATR ~= Range), close = Close
  $bars = New-Object System.Collections.Generic.List[object]
  $d = [datetime]'2026-07-14'
  $days = New-Object System.Collections.Generic.List[string]
  while ($days.Count -lt 40) {
    if ($d.DayOfWeek -ne 'Saturday' -and $d.DayOfWeek -ne 'Sunday') { $days.Insert(0, $d.ToString('yyyy-MM-dd')) }
    $d = $d.AddDays(-1)
  }
  foreach ($day in $days) {
    $bars.Add([pscustomobject]@{ t = (UtcStrToMs "$day 00:00"); o = $Close; h = [math]::Round($Close + $Range/2, 6)
      l = [math]::Round($Close - $Range/2, 6); c = $Close; v = 1000 })
  }
  Write-Json (Join-Path $Root "data\live_rf\series\$Name.json") $bars.ToArray()
}

function New-BaseState([string]$Root) {
  # состояние «спокойного» дня: вотермарки текущие, фронты NG/CNY, пустые рукава
  [pscustomobject]@{
    schema = 1; mode = 'prod'; account_id = 'acc1'
    meta = [pscustomobject]@{ profile = 'C3b-live'; created = '2026-07-14 00:00'; base_rub = 700000.0
      core_risk = 0.05; seta_risk = 0.02; mom_weight = 0.5 }
    sleeves = [pscustomobject]@{
      core = [pscustomobject]@{ eq_rub = 700000.0; month_start_eq = 700000.0; day_start_eq = 700000.0
        halt_day = $null; positions = @(); equity_mtm = 700000.0 }
      setA = [pscustomobject]@{ eq_rub = 700000.0; month_start_eq = 700000.0; day_start_eq = 700000.0
        halt_day = $null; positions = @(); equity_mtm = 700000.0 }
      mom = [pscustomobject]@{ eq_rub = 350000.0; month_start_eq = 350000.0; cash_rub = 350000.0
        holdings = @(); last_rebalance_month = ''; equity_mtm = 350000.0 } }
    profile_eq = 700000.0; profile_month_start = 700000.0; cur_month = '2026-07'
    day_start_eq = 700000.0; day_start_date = '2026-07-15'; peak_eq = 700000.0
    watermarks = [pscustomobject]@{ last_daily_day = '2026-07-14'; last_hour_ts = (UtcStrToMs '2026-07-15 09:00')
      ops_since = '2026-07-15T06:00:00Z'; last_eq_snap = [long]0; last_report_day = ''
      orders_day = '2026-07-15'; orders_day_n = 0 }
    fronts = [pscustomobject]@{
      NG  = [pscustomobject]@{ secid = 'NGQ6'; lasttrade = '2026-08-27'; next = 'NGU6'; next_lasttrade = '2026-09-28' }
      CNY = [pscustomobject]@{ secid = 'CRU6'; lasttrade = '2026-09-17'; next = 'CRZ6'; next_lasttrade = '2026-12-17' } }
    active = [pscustomobject]@{ NG = 'NGQ6'; CNY = 'CRU6' }
    rearm = [pscustomobject]@{}
    entries_halt = [pscustomobject]@{ active = $false; reason = ''; since = '' }
    go = [pscustomobject]@{ used_rub = 0.0; budget_rub = 0.0; peak_day_rub = 0.0 }
    drift = [pscustomobject]@{ D2 = 0; D4 = 0; D5 = 0; D6 = 0; stocks_deficit = 0; last = '' }
    pending_intents = @()
    next_intent_id = 10
    stats = [pscustomobject]@{ trades = 0; wins = 0; losses = 0; fees_rub = 0.0; realized_rub = 0.0
      orders_posted = 0; fills = 0; skipped_qty0 = 0; signal_mismatch = 0 }
    consec_fail = 0
  }
}

function New-Card([string]$Sleeve, [string]$Asset, [string]$Secid, [string]$Uid, [string]$Side, [int]$Lots,
                  [double]$Entry, [double]$Stop, [double]$RubPt, $Tp1 = $null) {
  [pscustomobject]@{
    id = "Ltest$Asset$Sleeve"; sleeve = $Sleeve; asset = $Asset; secid = $Secid; uid = $Uid; figi = 'F'
    side = $Side; lots = $Lots; lots_initial = $Lots
    entry_px_pts = $Entry; entry_day = '2026-07-14'; entry_ts = (UtcStrToMs '2026-07-14 10:01')
    stop_px_pts = $Stop; stop_order_id = 'stop-live-1'; stop_lots = $Lots
    tp1_px_pts = $Tp1; tp1_order_id = ''; tp1_done = $false; be_moved = $false
    mfe_pts = $Entry; atr_entry = 0.1145
    risk_rub = 35000.0; rub_per_pt = $RubPt; go_per_lot = 6340.0
    rolls = 0; fees_rub = 0.0; realized_rub = 0.0
    d6_fails = 0; quarantine = $false; stop_deferred = $null; last_stop_update = ''
    lat_sp = 0; lat_pf = 0
  }
}

function New-EntryIntent([string]$Sleeve, [string]$Asset, [string]$Side, [double]$StopDist, [double]$Atr, [double]$RefPx, [double]$RiskPct, [double]$Swing = 0) {
  $ctx = [pscustomobject]@{ stop_dist = $StopDist; atr = $Atr; risk_pct = $RiskPct; ref_px = $RefPx; note = 'test' }
  if ($Swing -ne 0) { $ctx | Add-Member -NotePropertyName swing -NotePropertyValue $Swing }
  [pscustomobject]@{
    id = 'i00001'; kind = 'entry'; sleeve = $Sleeve; asset = $Asset; ticker = ''; uid = ''
    side = $Side; lots = 0; filled_lots = 0; avg_fill_px = $null
    order_key = (New-TiOrderKey 'i00001' 'entry'); broker_order_id = ''
    state = 'INTENT'; attempts = 0
    t_signal = (UtcStrToMs '2026-07-14 23:50'); t_post = [long]0; t_ack = [long]0; t_fill = [long]0
    created_day = '2026-07-14'; state_ts = (UtcStrToMs '2026-07-15 00:25'); last_error = ''
    ctx = $ctx
  }
}

function Write-DefaultFixtures([string]$Mock) {
  New-Item -ItemType Directory -Force $Mock | Out-Null
  Write-Json (Join-Path $Mock 'UsersService.GetMarginAttributes.json') ([pscustomobject]@{
    liquidPortfolio = [pscustomobject]@{ units = '700000'; nano = 0; currency = 'rub' }
    startingMargin  = [pscustomobject]@{ units = '0'; nano = 0; currency = 'rub' } })
  Write-Json (Join-Path $Mock 'OperationsService.GetPortfolio.json') ([pscustomobject]@{ positions = @() })
  Write-Json (Join-Path $Mock 'StopOrdersService.GetStopOrders.json') ([pscustomobject]@{ stopOrders = @() })
  Write-Json (Join-Path $Mock 'OperationsService.GetOperations.json') ([pscustomobject]@{ operations = @() })
  Write-Json (Join-Path $Mock 'MarketDataService.GetLastPrices.json') ([pscustomobject]@{ lastPrices = @() })
  Write-Json (Join-Path $Mock 'MarketDataService.GetTradingStatus.json') ([pscustomobject]@{ tradingStatus = 'SECURITY_TRADING_STATUS_NORMAL_TRADING' })
  Write-Json (Join-Path $Mock 'OperationsService.GetPositions.json') ([pscustomobject]@{
    money = @([pscustomobject]@{ currency = 'rub'; units = '700000'; nano = 0 }) })
  Write-Json (Join-Path $Mock 'InstrumentsService.FutureBy.json') ([pscustomobject]@{ instrument = [pscustomobject]@{
    uid = 'uid-NGQ6'; figi = 'FUTNG'; ticker = 'NGQ6'; class_code = 'SPBFUT'; lot = 1
    min_price_increment = [pscustomobject]@{ units = '0'; nano = 1000000 }
    api_trade_available_flag = $true; last_trade_date = '2026-08-27T00:00:00Z' } })
  Write-Json (Join-Path $Mock 'InstrumentsService.GetFuturesMargin.json') ([pscustomobject]@{
    initial_margin_on_buy  = [pscustomobject]@{ units = '6340'; nano = 0; currency = 'rub' }
    initial_margin_on_sell = [pscustomobject]@{ units = '6340'; nano = 0; currency = 'rub' }
    min_price_increment_amount = [pscustomobject]@{ units = '7'; nano = 749120000 } })
  # семантика боевого API (прод 2026-07-21, инцидент L00008): executedOrderPrice = ИТОГО ₽ за все
  # лоты; initialOrderPricePt = пункты ЗА 1 ЛОТ (не сумма! деление на лоты дало вход 14.83 вместо 88.99)
  # Оба поля ОБЯЗАНЫ описывать одну сделку: 19 лот x 2.905 x 7749.12 ₽/пункт = 427712.6784 ₽.
  # До 2026-08-04 здесь стояло 427675 (=2.90474 за лот) — расхождение не всплывало, потому что
  # лестница брала initialOrderPricePt первым. Теперь первой идёт исполненная цена, и фикстура,
  # не сходящаяся сама с собой, ломает тест — как и должна.
  Write-Json (Join-Path $Mock 'OrdersService.PostOrder.json') ([pscustomobject]@{
    orderId = 'ord-default'; executionReportStatus = 'EXECUTION_REPORT_STATUS_FILL'; lotsExecuted = '19'
    initialOrderPricePt = [pscustomobject]@{ units = '2'; nano = 905000000 }   # 2.905 за лот
    executedOrderPrice = [pscustomobject]@{ units = '427712'; nano = 678400000; currency = 'rub' } })
  Write-Json (Join-Path $Mock 'StopOrdersService.PostStopOrder.json') ([pscustomobject]@{ stopOrderId = 'stop-new-1' })
  Write-Json (Join-Path $Mock 'OrdersService.CancelOrder.json') ([pscustomobject]@{})
  Write-Json (Join-Path $Mock 'StopOrdersService.CancelStopOrder.json') ([pscustomobject]@{})
  Write-Json (Join-Path $Mock 'OrdersService.GetOrderState.json') ([pscustomobject]@{
    executionReportStatus = 'EXECUTION_REPORT_STATUS_FILL'; lotsExecuted = 0
    executedOrderPrice = [pscustomobject]@{ units = '2'; nano = 905000000; currency = 'rub' } })
}

function New-Scenario([string]$Name) {
  $root = Join-Path $WORK $Name
  New-Item -ItemType Directory -Force (Join-Path $root 'data\live_rf\series') | Out-Null
  Write-SynthSeries $root 'NG' 2.9 0.1145
  Write-SynthSeries $root 'CNY' 11.686 0.2614
  Write-DefaultFixtures (Join-Path $root 'mock')
  return $root
}
function Set-Queue([string]$Root, $Entries) {
  Write-Json (Join-Path $Root 'mock\scenario.json') ([pscustomobject]@{ queue = @($Entries) })
}
function Run-Tick([string]$Root, [string]$MskTime, [string]$Mode = 'prod', [switch]$DirectSleeveAccess) {
  $nowMs = MskToNowMs $MskTime
  $oldDirectSleeveAccess = $env:LIVE_RF_DIRECT_SLEEVE_ACCESS
  try {
    $env:TINVEST_MODE = $Mode; $env:TINVEST_MOCK_DIR = Join-Path $Root 'mock'
    $env:TINVEST_ACCOUNT_ID = 'acc1'; $env:TINVEST_TOKEN = 'test-token'
    $env:LIVE_RF_DIRECT_SLEEVE_ACCESS = if ($DirectSleeveAccess) { '1' } else { $null }
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -Command ". '$ENGINE' -Root '$Root' -NowMs $nowMs" 2>&1
    return ($out | Out-String)
  } finally {
    $env:TINVEST_MOCK_DIR = $null
    $env:LIVE_RF_DIRECT_SLEEVE_ACCESS = $oldDirectSleeveAccess
  }
}
function Get-State([string]$Root) { Read-JsonFile (Join-Path $Root 'data\live_rf\portfolio.json') }
function Get-Calls([string]$Root, [string]$Method = '') {
  $p = Join-Path $Root 'mock\calls_log.jsonl'
  if (-not (Test-Path $p)) { return @() }
  $rows = @(Get-Content $p -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
  if ($Method) { $rows = @($rows | Where-Object { $_.method -eq $Method }) }
  return ,$rows
}
function Get-Trades([string]$Root) {
  $t = Read-JsonFile (Join-Path $Root 'data\live_rf\trades.json')
  return ,@(@($t) | Where-Object { $null -ne $_ })
}

# ================================ СЦЕНАРИИ ================================

# --- 1. entry-fill: вход исполняется, карточка + стоп в том же тике, сайзинг 19 лотов
function Scn-EntryFill {
  $r = New-Scenario 'entry-fill'
  $s = New-BaseState $r
  $s.pending_intents = @(New-EntryIntent 'core' 'NG' 'buy' 0.229 0.1145 2.9 0.05)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  [void](Run-Tick $r '2026-07-15 10:05')
  $st = Get-State $r
  $pos = @($st.sleeves.core.positions)
  Check 'entry-fill: карточка создана' ($pos.Count -eq 1)
  if ($pos.Count) {
    Check 'entry-fill: 19 лотов (35000/(0.229*7749.12))' ([int]$pos[0].lots -eq 19)
    Check 'entry-fill: entry=2.905 (из executedOrderPrice)' ([math]::Abs([double]$pos[0].entry_px_pts - 2.905) -lt 1e-9)
    Check 'entry-fill: стоп = 2.905-0.229=2.676' ([math]::Abs([double]$pos[0].stop_px_pts - 2.676) -lt 1e-9)
    Check 'entry-fill: стоп-заявка выставлена в том же тике' ([string]$pos[0].stop_order_id -eq 'stop-new-1')
  }
  Check 'entry-fill: интент удалён' (@($st.pending_intents).Count -eq 0)
  Check 'entry-fill: комиссия списана' ([double]$st.sleeves.core.eq_rub -lt 700000)
  Check 'entry-fill: PostStopOrder вызван 1 раз' ((Get-Calls $r 'PostStopOrder').Count -eq 1)
}

# Canary: the direct sleeve accessor must preserve the write-ahead entry/stop invariant.
function Scn-DirectSleeveAccess {
  $r = New-Scenario 'direct-sleeve-access'
  $s = New-BaseState $r
  $s.pending_intents = @(New-EntryIntent 'core' 'NG' 'buy' 0.229 0.1145 2.9 0.05)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  [void](Run-Tick $r '2026-07-15 10:05' 'prod' -DirectSleeveAccess)
  $st = Get-State $r
  $pos = @($st.sleeves.core.positions)
  Check 'direct-sleeve: core card created' ($pos.Count -eq 1)
  if ($pos.Count) {
    Check 'direct-sleeve: entry price preserved' ([math]::Abs([double]$pos[0].entry_px_pts - 2.905) -lt 1e-9)
    Check 'direct-sleeve: stop was armed in the same tick' ([string]$pos[0].stop_order_id -eq 'stop-new-1')
  }
  Check 'direct-sleeve: intent removed after fill' (@($st.pending_intents).Count -eq 0)
  Check 'direct-sleeve: exactly one market order' ((Get-Calls $r 'PostOrder').Count -eq 1)
  Check 'direct-sleeve: exactly one stop order' ((Get-Calls $r 'PostStopOrder').Count -eq 1)
}

# --- 2. entry-reject: заявка отклонена -> интента нет, карточек нет
function Scn-EntryReject {
  $r = New-Scenario 'entry-reject'
  $s = New-BaseState $r
  $s.pending_intents = @(New-EntryIntent 'core' 'NG' 'buy' 0.229 0.1145 2.9 0.05)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Set-Queue $r @([pscustomobject]@{ service='OrdersService'; method='PostOrder'
    response = [pscustomobject]@{ orderId='ord-r'; executionReportStatus='EXECUTION_REPORT_STATUS_REJECTED' } })
  [void](Run-Tick $r '2026-07-15 10:05')
  $st = Get-State $r
  Check 'entry-reject: карточек нет' (@($st.sleeves.core.positions).Count -eq 0)
  Check 'entry-reject: интент снят' (@($st.pending_intents).Count -eq 0)
}

# --- 3. entry-lost-adopt: postOrder упал сетью, операция нашлась -> adopt по факту
function Scn-EntryLostAdopt {
  $r = New-Scenario 'entry-lost-adopt'
  $s = New-BaseState $r
  $s.pending_intents = @(New-EntryIntent 'core' 'NG' 'buy' 0.229 0.1145 2.9 0.05)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Set-Queue $r @([pscustomobject]@{ service='OrdersService'; method='PostOrder'; error='network' })
  [void](Run-Tick $r '2026-07-15 10:05')
  $st = Get-State $r
  Check 'lost-adopt: интент LOST после сетевой ошибки' (@($st.pending_intents | Where-Object { $_.state -eq 'LOST' }).Count -eq 1)
  # тик 2: операция в GetOperations -> adopt FILLED
  Write-Json (Join-Path $r 'mock\OperationsService.GetOperations.json') ([pscustomobject]@{ operations = @(
    [pscustomobject]@{ id='op1'; date='2026-07-15T07:05:30Z'; instrumentUid='uid-NGQ6'; operationType='OPERATION_TYPE_BUY'; quantity='19'
      price=[pscustomobject]@{units='2';nano=910000000} } ) })
  # и позиция уже видна у брокера (иначе D2... нет: intent LOST её объясняет)
  [void](Run-Tick $r '2026-07-15 10:06')
  $st = Get-State $r
  $pos = @($st.sleeves.core.positions)
  Check 'lost-adopt: карточка создана по операции' ($pos.Count -eq 1)
  if ($pos.Count) { Check 'lost-adopt: entry=2.91 из операции' ([math]::Abs([double]$pos[0].entry_px_pts - 2.91) -lt 1e-9) }
  Check 'lost-adopt: интентов не осталось' (@($st.pending_intents).Count -eq 0)
}

# --- 4. entry-lost-repost: операции нет -> повторная постановка ТЕМ ЖЕ order_key
function Scn-EntryLostRepost {
  $r = New-Scenario 'entry-lost-repost'
  $s = New-BaseState $r
  $s.pending_intents = @(New-EntryIntent 'core' 'NG' 'buy' 0.229 0.1145 2.9 0.05)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Set-Queue $r @([pscustomobject]@{ service='OrdersService'; method='PostOrder'; error='network' })
  [void](Run-Tick $r '2026-07-15 10:05')
  [void](Run-Tick $r '2026-07-15 10:06')   # репост -> дефолт-фикстура FILL
  $st = Get-State $r
  Check 'lost-repost: карточка после репоста' (@($st.sleeves.core.positions).Count -eq 1)
  $posts = Get-Calls $r 'PostOrder'
  Check 'lost-repost: 2 вызова PostOrder' ($posts.Count -eq 2)
  if ($posts.Count -eq 2) {
    $k1 = ($posts[0].body | ConvertFrom-Json).orderId
    $k2 = ($posts[1].body | ConvertFrom-Json).orderId
    $guidOk = $false; try { [void][guid]::Parse($k1); $guidOk = $true } catch {}
    Check 'lost-repost: тот же идемпотентный order_key (UUID)' ($k1 -eq $k2 -and $guidOk)
  }
}

# --- 5. qty0: стоп дороже риск-бюджета -> пропуск сделки с логом
function Scn-Qty0 {
  $r = New-Scenario 'qty0'
  $s = New-BaseState $r
  $it = New-EntryIntent 'setA' 'NG' 'buy' 0 0.1145 2.9 0.02 2.4   # swing 2.4 -> stopDist=0.5 -> 3875р/лот... риск 14000 -> 3 лота; сделаем дороже
  $it.ctx.atr = 3.0    # 1xATR=3.0 -> stopDist=max(0.5, 3.0)=3.0 -> 23247р/лот > 14000
  $s.pending_intents = @($it)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  [void](Run-Tick $r '2026-07-15 10:05')
  $st = Get-State $r
  Check 'qty0: сделка пропущена' (@($st.sleeves.setA.positions).Count -eq 0)
  Check 'qty0: счётчик skipped_qty0=1' ([int]$st.stats.skipped_qty0 -eq 1)
  Check 'qty0: PostOrder не вызывался' ((Get-Calls $r 'PostOrder').Count -eq 0)
}

# --- 6. go-cap: предиктивный ГО-чек режет вход до нуля
function Scn-GoCap {
  $r = New-Scenario 'go-cap'
  $s = New-BaseState $r
  $s.pending_intents = @(New-EntryIntent 'core' 'NG' 'buy' 0.229 0.1145 2.9 0.05)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  # уже использовано 170к ГО из бюджета (700-0акций-50рез)*0.6=390к... сделаем бюджет меньше: занято 389к
  Write-Json (Join-Path $r 'mock\UsersService.GetMarginAttributes.json') ([pscustomobject]@{
    liquidPortfolio = [pscustomobject]@{ units='700000'; nano=0 }
    startingMargin  = [pscustomobject]@{ units='388000'; nano=0 } })
  [void](Run-Tick $r '2026-07-15 10:05')
  $st = Get-State $r
  Check 'go-cap: вход не состоялся (390k кэп, занято 388k, лот ГО 6340)' (@($st.sleeves.core.positions).Count -eq 0)
  Check 'go-cap: PostOrder не вызывался' ((Get-Calls $r 'PostOrder').Count -eq 0)
}

# --- 7. go-trim: ГО > 75% бюджета -> LIFO-закрытие последней позиции
function Scn-GoTrim {
  $r = New-Scenario 'go-trim'
  $s = New-BaseState $r
  $s.sleeves.core.positions = @(New-Card 'core' 'NG' 'NGQ6' 'uid-NGQ6' 'long' 19 2.905 2.676 7749.12)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'mock\OperationsService.GetPortfolio.json') ([pscustomobject]@{ positions = @(
    [pscustomobject]@{ instrumentUid='uid-NGQ6'; instrumentType='futures'; quantityLots=[pscustomobject]@{units='19';nano=0} } ) })
  Write-Json (Join-Path $r 'mock\StopOrdersService.GetStopOrders.json') ([pscustomobject]@{ stopOrders = @(
    [pscustomobject]@{ stopOrderId='stop-live-1' } ) })
  Write-Json (Join-Path $r 'mock\UsersService.GetMarginAttributes.json') ([pscustomobject]@{
    liquidPortfolio = [pscustomobject]@{ units='700000'; nano=0 }
    startingMargin  = [pscustomobject]@{ units='500000'; nano=0 } })   # 500k/650k=77% > 75%
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'go-trim: позиция закрыта LIFO' (@($st.sleeves.core.positions).Count -eq 0)
  $tr = Get-Trades $r
  Check 'go-trim: причина emergency' ($tr.Count -eq 1 -and [string]$tr[0].exitReason -eq 'emergency')
  Check 'go-trim: entries_halt активен' ([bool]$st.entries_halt.active)
}

# --- 7b. НОВЫЕ пороги ГО (решение пользователя 2026-08-13): кэп 0.60 -> 0.75, трим 0.75 -> 0.90.
# Пороги приходят ОВЕРРАЙДОМ config.json (движок, строка ~70) - код не трогали. Тесты выше
# (Scn-GoCap/Scn-GoTrim) намеренно оставлены на дефолтах 0.60/0.75: они защищают сам механизм
# лестницы, эти - конкретную боевую настройку.
#
# Проверяются все три зоны, и главная из них - СРЕДНЯЯ. Между кэпом и тримом бот обязан остановить
# НОВЫЕ входы, но продолжать вести уже открытую позицию. Ровно этот зазор исчез бы, если поднять
# кэп до 0.75, оставив трим на 0.75: те же 77% из Scn-GoTrim тогда резали бы свежую позицию по
# рынку не по стратегии, а из-за дёрнувшегося залога.
$GO_CFG = [pscustomobject]@{ go_cap_pct = 0.75; go_trim_pct = 0.90 }   # бюджет песочницы = 650k

function New-GoLadderScenario([string]$Name, [int]$StartingMargin, [switch]$WithPosition) {
  $r = New-Scenario $Name
  Write-Json (Join-Path $r 'data\live_rf\config.json') $GO_CFG
  $s = New-BaseState $r
  if ($WithPosition) {
    $s.sleeves.core.positions = @(New-Card 'core' 'NG' 'NGQ6' 'uid-NGQ6' 'long' 19 2.905 2.676 7749.12)
  }
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  if ($WithPosition) {
    Write-Json (Join-Path $r 'mock\OperationsService.GetPortfolio.json') ([pscustomobject]@{ positions = @(
      [pscustomobject]@{ instrumentUid='uid-NGQ6'; instrumentType='futures'; quantityLots=[pscustomobject]@{units='19';nano=0} } ) })
    Write-Json (Join-Path $r 'mock\StopOrdersService.GetStopOrders.json') ([pscustomobject]@{ stopOrders = @(
      [pscustomobject]@{ stopOrderId='stop-live-1' } ) })
  }
  Write-Json (Join-Path $r 'mock\UsersService.GetMarginAttributes.json') ([pscustomobject]@{
    liquidPortfolio = [pscustomobject]@{ units='700000'; nano=0 }
    startingMargin  = [pscustomobject]@{ units=[string]$StartingMargin; nano=0 } })
  return $r
}

# Зона 1 - под кэпом (455k/650k = 70%): ни халта, ни трима, позиция ведётся как обычно.
function Scn-GoNewBelowCap {
  $r = New-GoLadderScenario 'go-new-below' 455000 -WithPosition
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'ГО-75/90 зона1 (70%): позиция цела' (@($st.sleeves.core.positions).Count -eq 1)
  Check 'ГО-75/90 зона1 (70%): входы разрешены' (-not [bool]$st.entries_halt.active)
  Check 'ГО-75/90 зона1 (70%): бюджет как ожидалось (650k)' ([math]::Abs([double]$st.go.budget_rub - 650000) -lt 1)
}

# Зона 2 - МЕЖДУ кэпом и тримом (500k/650k = 77%): входы стоп, но позиция ЖИВА.
# При старом триме 0.75 этот же случай (Scn-GoTrim) закрывал позицию - в этом вся суть зазора.
function Scn-GoNewBetween {
  $r = New-GoLadderScenario 'go-new-between' 500000 -WithPosition
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'ГО-75/90 зона2 (77%): позиция НЕ закрыта (зазор работает)' (@($st.sleeves.core.positions).Count -eq 1)
  Check 'ГО-75/90 зона2 (77%): сделок не записано' ((Get-Trades $r).Count -eq 0)
  Check 'ГО-75/90 зона2 (77%): entries_halt активен' ([bool]$st.entries_halt.active)
  Check 'ГО-75/90 зона2 (77%): причина халта - ГО' ([string]$st.entries_halt.reason -like 'ГО *')
}

# Зона 3 - выше трима (617.5k/650k = 95%): LIFO-закрытие последней позиции.
function Scn-GoNewAboveTrim {
  $r = New-GoLadderScenario 'go-new-above' 617500 -WithPosition
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'ГО-75/90 зона3 (95%): позиция закрыта LIFO' (@($st.sleeves.core.positions).Count -eq 0)
  $tr = Get-Trades $r
  Check 'ГО-75/90 зона3 (95%): причина emergency' ($tr.Count -eq 1 -and [string]$tr[0].exitReason -eq 'emergency')
}

# Практический смысл повышения кэпа: фикстура Scn-GoCap (занято 388k из бюджета 650k = 59.7%) при
# старом кэпе 0.60 вход ОТКЛОНЯЛА (лимит 390k, лот ГО 6340 не влезал). При кэпе 0.75 лимит 487.5k,
# запас 99.5k - вход обязан состояться. Это ровно то, ради чего кэп поднимали.
function Scn-GoNewCapAllowsEntry {
  $r = New-GoLadderScenario 'go-new-entry' 388000
  $s = Get-State $r
  $s.pending_intents = @(New-EntryIntent 'core' 'NG' 'buy' 0.229 0.1145 2.9 0.05)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  [void](Run-Tick $r '2026-07-15 10:05')
  $st = Get-State $r
  Check 'ГО-75/90 вход: при кэпе 0.75 вход состоялся (при 0.60 отклонялся)' (@($st.sleeves.core.positions).Count -eq 1)
  Check 'ГО-75/90 вход: PostOrder вызывался' ((Get-Calls $r 'PostOrder').Count -ge 1)
  Check 'ГО-75/90 вход: интент не отменён по go-cap' (@($st.pending_intents | Where-Object { $_.state -eq 'CANCELLED' }).Count -eq 0)
}

# --- 8. hard-dd: -35% от пика РЕАЛЬНОГО капитала брокера -> закрыть всё + HALT_RF_LIVE
# С 2026-08-07 governors считают dd от bot_capital_rub/capital_peak_rub (Set-BotCapital), а не
# от блендовой profile_eq/peak_eq - тот же источник, что вечерний отчёт (a21d81456). Пик 700k
# засеян явно (в проде он тянется из истории equity.json/растёт монотонно), капитал брокера
# в GetPortfolio упал до 420k -> dd 40% > 35%.
function Scn-HardDd {
  $r = New-Scenario 'hard-dd'
  $s = New-BaseState $r
  $s.sleeves.core.positions = @(New-Card 'core' 'NG' 'NGQ6' 'uid-NGQ6' 'long' 19 2.905 2.676 7749.12)
  $s.go | Add-Member -NotePropertyName capital_peak_rub -NotePropertyValue 700000.0 -Force
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'mock\OperationsService.GetPortfolio.json') ([pscustomobject]@{
    total_amount_currencies = [pscustomobject]@{ units = '420000'; nano = 0; currency = 'rub' }
    total_amount_portfolio  = [pscustomobject]@{ units = '420000'; nano = 0; currency = 'rub' }
    positions = @([pscustomobject]@{ instrumentUid='uid-NGQ6'; instrumentType='futures'; quantityLots=[pscustomobject]@{units='19';nano=0} }) })
  Write-Json (Join-Path $r 'mock\StopOrdersService.GetStopOrders.json') ([pscustomobject]@{ stopOrders = @(
    [pscustomobject]@{ stopOrderId='stop-live-1' } ) })
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'hard-dd: все позиции закрыты' (@($st.sleeves.core.positions).Count -eq 0)
  Check 'hard-dd: HALT_RF_LIVE создан' (Test-Path (Join-Path $r 'data\HALT_RF_LIVE'))
  $out2 = Run-Tick $r '2026-07-15 11:01'
  Check 'hard-dd: следующий тик не торгует (halt-файл)' ($out2 -notmatch 'tick ok')
}

# --- 8b. hard-dd НЕ путает загрязнённый блендовый peak_eq с реальной просадкой (регресс против
# старого источника): profile_eq/peak_eq оставлены в состоянии «фантомного» пика 2M (класс
# инцидента L00008, 2026-07-21), но реальный капитал брокера здоров и близок к своему пику ->
# governors не должны сработать вообще (до 2026-08-07 сработали бы: dd от блендовой пары = 65%).
function Scn-HardDdIgnoresBlendedPeak {
  $r = New-Scenario 'hard-dd-ignores-blended'
  $s = New-BaseState $r
  $s.peak_eq = 2000000.0
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'mock\OperationsService.GetPortfolio.json') ([pscustomobject]@{
    total_amount_currencies = [pscustomobject]@{ units = '700000'; nano = 0; currency = 'rub' }
    total_amount_portfolio  = [pscustomobject]@{ units = '700000'; nano = 0; currency = 'rub' }
    positions = @() })
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  $log = Get-Content (Join-Path $r 'data\live_rf\tick_log.txt') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  Check 'hard-dd-ignores-blended: HALT_RF_LIVE НЕ создан' (-not (Test-Path (Join-Path $r 'data\HALT_RF_LIVE')))
  Check 'hard-dd-ignores-blended: entries_halt не активен' (-not [bool]$st.entries_halt.active)
  Check 'hard-dd-ignores-blended: тик выжил (tick ok в логе)' ([string]$log -match 'tick ok')
}

# --- 8c. дневной стоп -8% - тоже от реального капитала (day_start_eq теперь несёт bot_capital_rub
# со старта дня, см. Invoke-LiveDayHook), а не от блендового profile_eq. capital_peak_rub не
# засеян нарочно - Set-BotCapital сам засеет его текущим капиталом (730k), так что hard-dd тут не
# должен вмешаться и заслонить дневную проверку.
function Scn-DayHaltReal {
  $r = New-Scenario 'day-halt-real'
  $s = New-BaseState $r
  $s.day_start_eq = 800000.0
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'mock\OperationsService.GetPortfolio.json') ([pscustomobject]@{
    total_amount_currencies = [pscustomobject]@{ units = '730000'; nano = 0; currency = 'rub' }
    total_amount_portfolio  = [pscustomobject]@{ units = '730000'; nano = 0; currency = 'rub' }
    positions = @() })
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'day-halt-real: entries_halt активен' ([bool]$st.entries_halt.active)
  Check 'day-halt-real: причина "day -..."' ([string]$st.entries_halt.reason -like 'day -*')
  Check 'day-halt-real: HALT_RF_LIVE НЕ создан (это не hard-dd)' (-not (Test-Path (Join-Path $r 'data\HALT_RF_LIVE')))
}

# --- 9. D2: чужая фьючерс-позиция -> аварийное закрытие + халт входов
function Scn-D2 {
  $r = New-Scenario 'd2-foreign'
  $s = New-BaseState $r
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'mock\OperationsService.GetPortfolio.json') ([pscustomobject]@{ positions = @(
    [pscustomobject]@{ instrumentUid='uid-ALIEN'; instrumentType='futures'; quantityLots=[pscustomobject]@{units='3';nano=0} } ) })
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'D2: счётчик' ([int]$st.drift.D2 -eq 1)
  Check 'D2: entries_halt' ([bool]$st.entries_halt.active)
  $posts = Get-Calls $r 'PostOrder'
  Check 'D2: маркет-закрытие чужой позиции (sell 3)' ($posts.Count -eq 1 -and ($posts[0].body -match '"quantity":"3"') -and ($posts[0].body -match 'SELL'))
}

# мок «непустого, но без нашего фьючерса» портфеля: валютная строка есть (счёт не битый - гейт
# пустого снимка в Invoke-Reconcile пропускает сверку дальше), фьючерса NGQ6 нет (реальный D4-кейс)
function Write-CashOnlyPortfolio([string]$Root) {
  Write-Json (Join-Path $Root 'mock\OperationsService.GetPortfolio.json') ([pscustomobject]@{ positions = @(
    [pscustomobject]@{ instrumentUid='uid-RUBCASH'; instrumentType='currency'; quantityLots=[pscustomobject]@{units='700000';nano=0} } ) })
}

# --- 10. D4-confirmed: карточки нет у брокера, операция стопа есть -> штатное закрытие
function Scn-D4Confirmed {
  $r = New-Scenario 'd4-confirmed'
  $s = New-BaseState $r
  $s.sleeves.core.positions = @(New-Card 'core' 'NG' 'NGQ6' 'uid-NGQ6' 'long' 19 2.905 2.676 7749.12)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-CashOnlyPortfolio $r
  Write-Json (Join-Path $r 'mock\OperationsService.GetOperations.json') ([pscustomobject]@{ operations = @(
    [pscustomobject]@{ id='op-stop'; date='2026-07-15T07:05:30Z'; instrumentUid='uid-NGQ6'; operationType='OPERATION_TYPE_SELL'; quantity='19'
      price=[pscustomobject]@{units='2';nano=676000000} } ) })
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'D4-ok: карточка закрыта' (@($st.sleeves.core.positions).Count -eq 0)
  $tr = Get-Trades $r
  Check 'D4-ok: причина stop, цена 2.676' ($tr.Count -eq 1 -and [string]$tr[0].exitReason -eq 'stop' -and [math]::Abs([double]$tr[0].exitPx - 2.676) -lt 1e-9)
  Check 'D4-ok: re-arm записан' ($null -ne $st.rearm.PSObject.Properties['c3b_NG'])
  Check 'D4-ok: без халта (это штатный случай)' (-not [bool]$st.entries_halt.active)
  Check 'D4-ok: убыток в леджере' ([double]$st.sleeves.core.eq_rub -lt 700000)
}

# --- 10b. D4-manual-ext: карточки нет у брокера, операция закрытия ЕСТЬ, но цена ЛУЧШЕ стопа
# карточки (стоп-маркет не может исполниться лучше триггера) -> закрытие вне бота, не 'stop'
function Scn-D4ManualExt {
  $r = New-Scenario 'd4-manual-ext'
  $s = New-BaseState $r
  $s.sleeves.core.positions = @(New-Card 'core' 'NG' 'NGQ6' 'uid-NGQ6' 'long' 19 2.905 2.676 7749.12)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-CashOnlyPortfolio $r
  Write-Json (Join-Path $r 'mock\OperationsService.GetOperations.json') ([pscustomobject]@{ operations = @(
    [pscustomobject]@{ id='op-ext'; date='2026-07-15T07:05:30Z'; instrumentUid='uid-NGQ6'; operationType='OPERATION_TYPE_SELL'; quantity='19'
      price=[pscustomobject]@{units='3';nano=50000000} } ) })   # 3.05, выше стопа 2.676 - стоп так закрыться не мог
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'D4-manual-ext: карточка закрыта' (@($st.sleeves.core.positions).Count -eq 0)
  $tr = Get-Trades $r
  Check 'D4-manual-ext: причина manual-ext, цена 3.05' ($tr.Count -eq 1 -and [string]$tr[0].exitReason -eq 'manual-ext' -and [math]::Abs([double]$tr[0].exitPx - 3.05) -lt 1e-9)
  Check 'D4-manual-ext: re-arm записан (как после обычного выхода)' ($null -ne $st.rearm.PSObject.Properties['c3b_NG'])
  Check 'D4-manual-ext: без халта' (-not [bool]$st.entries_halt.active)
}

# --- 10bb. D4-short-history: ручное закрытие шорта PLD несколько дней назад всё равно
# находится по расширенному окну операций; API может вернуть направление в коротком виде BUY.
function Scn-D4ShortHistoricalClose {
  $r = New-Scenario 'd4-short-history'
  $s = New-BaseState $r
  $c = New-Card 'setA' 'PLD' 'PDU6' 'uid-PDU6' 'short' 2 1312.975 1409.25 1.0
  $c.entry_ts = (UtcStrToMs '2026-08-14 10:01')
  $c.entry_day = '2026-08-14'
  $s.sleeves.setA.positions = @($c)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-CashOnlyPortfolio $r
  Write-Json (Join-Path $r 'mock\OperationsService.GetOperations.json') ([pscustomobject]@{ operations = @(
    [pscustomobject]@{ id='op-pld-ext'; date='2026-08-15T08:05:30Z'; instrumentUid='uid-PDU6'; operationType='BUY'; quantity='2'
      price=[pscustomobject]@{units='1280';nano=0} } ) })
  [void](Run-Tick $r '2026-08-17 11:00')
  $st = Get-State $r
  Check 'D4-short-history: PLD убран из открытых позиций' (@($st.sleeves.setA.positions).Count -eq 0)
  $tr = Get-Trades $r
  Check 'D4-short-history: ручное закрытие шорта найдено по истории' ($tr.Count -eq 1 -and [string]$tr[0].asset -eq 'PLD' -and [string]$tr[0].exitReason -eq 'manual-ext' -and [math]::Abs([double]$tr[0].exitPx - 1280) -lt 1e-9)
}

# --- 10bc. D4-pending: отсутствие позиции без операции не выдаётся за открытую.
function Scn-D4PendingStatus {
  $r = New-Scenario 'd4-pending-status'
  $s = New-BaseState $r
  $s.sleeves.setA.positions = @(New-Card 'setA' 'PLD' 'PDU6' 'uid-PDU6' 'short' 2 1312.975 1409.25 1.0)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-CashOnlyPortfolio $r
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r; $card = @($st.sleeves.setA.positions)[0]
  Check 'D4-pending: статус сверки выставлен после первого отсутствия' ([string]$card.reconcile_status -eq 'broker-absent' -and [long]$card.reconcile_since_ts -gt 0)
  Check 'D4-pending: позиция ещё не списана без подтверждения' (@($st.sleeves.setA.positions).Count -eq 1)
}

# --- 10c. D4-stop-alive: операция ровно по стопу, НО стоп-заявка карточки всё ещё живёт у брокера
# (позицию закрыли, не тронув стоп) -> закрытие всё равно не 'stop' (иначе живая заявка) + заявка снята
function Scn-D4StopAlive {
  $r = New-Scenario 'd4-stop-alive'
  $s = New-BaseState $r
  $s.sleeves.core.positions = @(New-Card 'core' 'NG' 'NGQ6' 'uid-NGQ6' 'long' 19 2.905 2.676 7749.12)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-CashOnlyPortfolio $r
  Write-Json (Join-Path $r 'mock\StopOrdersService.GetStopOrders.json') ([pscustomobject]@{ stopOrders = @(
    [pscustomobject]@{ stopOrderId = 'stop-live-1' } ) })
  Write-Json (Join-Path $r 'mock\OperationsService.GetOperations.json') ([pscustomobject]@{ operations = @(
    [pscustomobject]@{ id='op-stop'; date='2026-07-15T07:05:30Z'; instrumentUid='uid-NGQ6'; operationType='OPERATION_TYPE_SELL'; quantity='19'
      price=[pscustomobject]@{units='2';nano=676000000} } ) })
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'D4-stop-alive: карточка закрыта' (@($st.sleeves.core.positions).Count -eq 0)
  $tr = Get-Trades $r
  Check 'D4-stop-alive: причина manual-ext (стоп ещё жив у брокера)' ($tr.Count -eq 1 -and [string]$tr[0].exitReason -eq 'manual-ext')
  $cancels = Get-Calls $r 'CancelStopOrder'
  Check 'D4-stop-alive: осиротевшая стоп-заявка снята ровно 1 раз' ($cancels.Count -eq 1 -and $cancels[0].body -like '*stop-live-1*')
}

# --- 11. D4-quarantine: позиции нет и операции нет ДВА тика подряд -> карантин + халт.
# Подтверждение двумя тиками (d4_fails) - фикс инцидента 2026-07-27 (L00011): разовый битый
# снимок GetPortfolio без строки фьючерса раньше карантинил живую позицию с первого тика.
function Scn-D4Quarantine {
  $r = New-Scenario 'd4-quarantine'
  $s = New-BaseState $r
  $s.sleeves.core.positions = @(New-Card 'core' 'NG' 'NGQ6' 'uid-NGQ6' 'long' 19 2.905 2.676 7749.12)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-CashOnlyPortfolio $r
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'D4-q тик1: ещё НЕ в карантине (1-е подряд real=0)' (-not [bool]@($st.sleeves.core.positions)[0].quarantine)
  Check 'D4-q тик1: d4_fails=1' ([int]@($st.sleeves.core.positions)[0].d4_fails -eq 1)
  Check 'D4-q тик1: без халта' (-not [bool]$st.entries_halt.active)
  Check 'D4-q тик1: счётчик D4 ещё 0' ([int]$st.drift.D4 -eq 0)
  [void](Run-Tick $r '2026-07-15 11:15')
  $st = Get-State $r
  Check 'D4-q тик2: карточка в карантине (2-й подряд тик)' ([bool]@($st.sleeves.core.positions)[0].quarantine)
  Check 'D4-q тик2: счётчик D4' ([int]$st.drift.D4 -eq 1)
  Check 'D4-q тик2: entries_halt' ([bool]$st.entries_halt.active)
}

# --- 11b. D4-transient: разовый битый снимок (карточка "пропадает" на 1 тик, потом снова видна) ->
# НЕ карантинится вовсе; регрессия ровно на инцидент 2026-07-27 (L00011, GDU6, 3 дня без входов)
function Scn-D4Transient {
  $r = New-Scenario 'd4-transient'
  $s = New-BaseState $r
  $s.sleeves.core.positions = @(New-Card 'core' 'NG' 'NGQ6' 'uid-NGQ6' 'long' 19 2.905 2.676 7749.12)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-CashOnlyPortfolio $r
  [void](Run-Tick $r '2026-07-15 11:00')   # тик1: позиции у брокера "нет" (разовый глюк) - d4_fails=1
  # тик2: позиция снова видна у брокера (глюк прошёл)
  Write-Json (Join-Path $r 'mock\OperationsService.GetPortfolio.json') ([pscustomobject]@{ positions = @(
    [pscustomobject]@{ instrumentUid='uid-RUBCASH'; instrumentType='currency'; quantityLots=[pscustomobject]@{units='700000';nano=0} },
    [pscustomobject]@{ instrumentUid='uid-NGQ6'; instrumentType='futures'; quantityLots=[pscustomobject]@{units='19';nano=0} } ) })
  Write-Json (Join-Path $r 'mock\StopOrdersService.GetStopOrders.json') ([pscustomobject]@{ stopOrders = @(
    [pscustomobject]@{ stopOrderId='stop-live-1' } ) })
  [void](Run-Tick $r '2026-07-15 11:15')
  $st = Get-State $r
  Check 'D4-transient: карточка жива, НЕ в карантине' (@($st.sleeves.core.positions).Count -eq 1 -and -not [bool]@($st.sleeves.core.positions)[0].quarantine)
  Check 'D4-transient: d4_fails сброшен в 0' ([int]@($st.sleeves.core.positions)[0].d4_fails -eq 0)
  Check 'D4-transient: счётчик D4 остался 0' ([int]$st.drift.D4 -eq 0)
  Check 'D4-transient: халта не было' (-not [bool]$st.entries_halt.active)
}

# --- 11c. D4-empty-snapshot: снимок ПОЛНОСТЬЮ пуст (positions=[]) -> сверка целиком пропущена
# (не только D4/D5 - карточка не трогается вообще, включая D6), решение отложено на след. тик
function Scn-D4EmptySnapshot {
  $r = New-Scenario 'd4-empty-snapshot'
  $s = New-BaseState $r
  $s.sleeves.core.positions = @(New-Card 'core' 'NG' 'NGQ6' 'uid-NGQ6' 'long' 19 2.905 2.676 7749.12)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  # дефолтная фикстура УЖЕ пустая (positions=@()) - ничего переопределять не нужно
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  $log = Get-Content (Join-Path $r 'data\live_rf\tick_log.txt') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  Check 'D4-empty: карточка цела, НЕ в карантине' (@($st.sleeves.core.positions).Count -eq 1 -and -not [bool]@($st.sleeves.core.positions)[0].quarantine)
  Check 'D4-empty: счётчик D4 остался 0' ([int]$st.drift.D4 -eq 0)
  Check 'D4-empty: халта нет' (-not [bool]$st.entries_halt.active)
  Check 'D4-empty: сверка отложена (лог)' ([string]$log -match 'снимок портфеля пуст')
}

# --- 12. D5: лоты разошлись без объяснения -> усечь к брокеру
function Scn-D5 {
  $r = New-Scenario 'd5-trunc'
  $s = New-BaseState $r
  $s.sleeves.core.positions = @(New-Card 'core' 'NG' 'NGQ6' 'uid-NGQ6' 'long' 19 2.905 2.676 7749.12)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'mock\OperationsService.GetPortfolio.json') ([pscustomobject]@{ positions = @(
    [pscustomobject]@{ instrumentUid='uid-NGQ6'; instrumentType='futures'; quantityLots=[pscustomobject]@{units='17';nano=0} } ) })
  Write-Json (Join-Path $r 'mock\StopOrdersService.GetStopOrders.json') ([pscustomobject]@{ stopOrders = @(
    [pscustomobject]@{ stopOrderId='stop-live-1' } ) })
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'D5: лоты усечены 19->17' ([int]@($st.sleeves.core.positions)[0].lots -eq 17)
  Check 'D5: счётчик' ([int]$st.drift.D5 -eq 1)
}

# --- 13. D6: стоп-заявка исчезла -> немедленный перевзвод
function Scn-D6Repost {
  $r = New-Scenario 'd6-repost'
  $s = New-BaseState $r
  $s.sleeves.core.positions = @(New-Card 'core' 'NG' 'NGQ6' 'uid-NGQ6' 'long' 19 2.905 2.676 7749.12)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'mock\OperationsService.GetPortfolio.json') ([pscustomobject]@{ positions = @(
    [pscustomobject]@{ instrumentUid='uid-NGQ6'; instrumentType='futures'; quantityLots=[pscustomobject]@{units='19';nano=0} } ) })
  # GetStopOrders пуст (дефолт) -> D6
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'D6: перевзвод (новый stopOrderId)' ([string]@($st.sleeves.core.positions)[0].stop_order_id -eq 'stop-new-1')
  Check 'D6: счётчик' ([int]$st.drift.D6 -eq 1)
  Check 'D6: позиция жива' (@($st.sleeves.core.positions).Count -eq 1)
}

# --- 14. D6-fail: перевзвод не удаётся дважды -> аварийное закрытие
function Scn-D6Fail {
  $r = New-Scenario 'd6-fail'
  $s = New-BaseState $r
  $s.sleeves.core.positions = @(New-Card 'core' 'NG' 'NGQ6' 'uid-NGQ6' 'long' 19 2.905 2.676 7749.12)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'mock\OperationsService.GetPortfolio.json') ([pscustomobject]@{ positions = @(
    [pscustomobject]@{ instrumentUid='uid-NGQ6'; instrumentType='futures'; quantityLots=[pscustomobject]@{units='19';nano=0} } ) })
  $neterr = 1..6 | ForEach-Object { [pscustomobject]@{ service='StopOrdersService'; method='PostStopOrder'; error='network' } }
  Set-Queue $r $neterr
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'D6-fail тик1: d6_fails=1, позиция жива' (@($st.sleeves.core.positions).Count -eq 1 -and [int]@($st.sleeves.core.positions)[0].d6_fails -eq 1)
  [void](Run-Tick $r '2026-07-15 11:01')
  $st = Get-State $r
  Check 'D6-fail тик2: аварийное закрытие' (@($st.sleeves.core.positions).Count -eq 0)
  $tr = Get-Trades $r
  Check 'D6-fail: причина emergency' ($tr.Count -eq 1 -and [string]$tr[0].exitReason -eq 'emergency')
}

# --- 15. stocks-deficit: пользователь продал «наши» лоты -> усечь бот-леджер
function Scn-StocksDeficit {
  $r = New-Scenario 'stocks-deficit'
  $s = New-BaseState $r
  $s.sleeves.mom.holdings = @([pscustomobject]@{ sym='GAZP'; uid='uid-GAZP'; lots=10; lot_size=10.0
    avg_px=120.0; last_px=120.0; buy_day='2026-07-01' })
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'mock\OperationsService.GetPortfolio.json') ([pscustomobject]@{ positions = @(
    [pscustomobject]@{ instrumentUid='uid-GAZP'; instrumentType='share'; quantityLots=[pscustomobject]@{units='4';nano=0} } ) })
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'stocks-deficit: лоты усечены 10->4' ([int]@($st.sleeves.mom.holdings)[0].lots -eq 4)
  Check 'stocks-deficit: счётчик' ([int]$st.drift.stocks_deficit -eq 1)
}

# --- 16. stocks-surplus: у пользователя больше акций, чем у бота - НЕ дрифт
function Scn-StocksSurplus {
  $r = New-Scenario 'stocks-surplus'
  $s = New-BaseState $r
  $s.sleeves.mom.holdings = @([pscustomobject]@{ sym='GAZP'; uid='uid-GAZP'; lots=10; lot_size=10.0
    avg_px=120.0; last_px=120.0; buy_day='2026-07-01' })
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'mock\OperationsService.GetPortfolio.json') ([pscustomobject]@{ positions = @(
    [pscustomobject]@{ instrumentUid='uid-GAZP'; instrumentType='share'; quantityLots=[pscustomobject]@{units='50';nano=0} } ) })
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'stocks-surplus: бот-лоты не тронуты' ([int]@($st.sleeves.mom.holdings)[0].lots -eq 10)
  Check 'stocks-surplus: дрифта нет' ([int]$st.drift.stocks_deficit -eq 0)
}

# --- 17. clearing-gate: 14:00 MSK - клиринг, ролл не исполняется, сигнал не теряется
function Scn-ClearingGate {
  $r = New-Scenario 'clearing-gate'
  $s = New-BaseState $r
  $card = New-Card 'core' 'NG' 'NGQ6' 'uid-NGQ6' 'long' 10 2.905 2.676 7749.12
  $card | Add-Member -NotePropertyName roll_signal_to -NotePropertyValue 'NGU6' -Force
  $s.sleeves.core.positions = @($card)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'mock\OperationsService.GetPortfolio.json') ([pscustomobject]@{ positions = @(
    [pscustomobject]@{ instrumentUid='uid-NGQ6'; instrumentType='futures'; quantityLots=[pscustomobject]@{units='10';nano=0} } ) })
  Write-Json (Join-Path $r 'mock\StopOrdersService.GetStopOrders.json') ([pscustomobject]@{ stopOrders = @(
    [pscustomobject]@{ stopOrderId='stop-live-1' } ) })
  [void](Run-Tick $r '2026-07-15 23:50')   # ЕТС: единственный клиринг - ночной 23:50-00:30
  $st = Get-State $r
  Check 'clearing: PostOrder не вызывался' ((Get-Calls $r 'PostOrder').Count -eq 0)
  Check 'clearing: ролл-сигнал не потерян' ([string]@($st.sleeves.core.positions)[0].roll_signal_to -eq 'NGU6')
}

# --- 18. weekend: суббота - лёгкий тик без заявок
function Scn-Weekend {
  $r = New-Scenario 'weekend'
  $s = New-BaseState $r
  $s.watermarks.orders_day = '2026-07-18'
  $s.pending_intents = @(New-EntryIntent 'core' 'NG' 'buy' 0.229 0.1145 2.9 0.05)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  [void](Run-Tick $r '2026-07-18 10:05')   # суббота
  $st = Get-State $r
  Check 'weekend: PostOrder не вызывался' ((Get-Calls $r 'PostOrder').Count -eq 0)
  Check 'weekend: интент цел' (@($st.pending_intents | Where-Object { $_.state -eq 'INTENT' }).Count -eq 1)
}

# --- 19. halt-entries-file: kill-файл HALT_RF_ENTRIES блокирует входы
function Scn-HaltEntriesFile {
  $r = New-Scenario 'halt-entries'
  $s = New-BaseState $r
  $s.pending_intents = @(New-EntryIntent 'core' 'NG' 'buy' 0.229 0.1145 2.9 0.05)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  New-Item -ItemType Directory -Force (Join-Path $r 'data') | Out-Null
  Set-Content (Join-Path $r 'data\HALT_RF_ENTRIES') 'test' -Encoding ASCII
  [void](Run-Tick $r '2026-07-15 10:05')
  Check 'halt-entries: PostOrder не вызывался' ((Get-Calls $r 'PostOrder').Count -eq 0)
}

# --- 20. halt-close-file: HALT_RF_CLOSE закрывает всё маркетом
function Scn-HaltCloseFile {
  $r = New-Scenario 'halt-close'
  $s = New-BaseState $r
  $s.sleeves.core.positions = @(New-Card 'core' 'NG' 'NGQ6' 'uid-NGQ6' 'long' 19 2.905 2.676 7749.12)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  New-Item -ItemType Directory -Force (Join-Path $r 'data') | Out-Null
  Set-Content (Join-Path $r 'data\HALT_RF_CLOSE') 'test' -Encoding ASCII
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'halt-close: позиции закрыты' (@($st.sleeves.core.positions).Count -eq 0)
  $tr = Get-Trades $r
  Check 'halt-close: причина emergency' ($tr.Count -eq 1 -and [string]$tr[0].exitReason -eq 'emergency')
}

# --- 21. flood-cap: лимит заявок в день -> entries_halt
function Scn-FloodCap {
  $r = New-Scenario 'flood-cap'
  $s = New-BaseState $r
  $i1 = New-EntryIntent 'core' 'NG' 'buy' 0.229 0.1145 2.9 0.05
  $i2 = New-EntryIntent 'setA' 'NG' 'buy' 0 0.1145 2.9 0.02 2.7
  $i2.id = 'i00002'; $i2.order_key = 'LRF-i00002-entry'
  $i3 = New-EntryIntent 'core' 'CNY' 'buy' 0.5228 0.2614 11.686 0.05
  $i3.id = 'i00003'; $i3.order_key = 'LRF-i00003-entry'
  $s.pending_intents = @($i1, $i2, $i3)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'data\live_rf\config.json') ([pscustomobject]@{ max_orders_day = 2 })
  # каждому входу нужен свой инструмент: очередь FutureBy по body_like
  Set-Queue $r @(
    [pscustomobject]@{ service='InstrumentsService'; method='FutureBy'; body_like='CRU6'
      response=[pscustomobject]@{ instrument=[pscustomobject]@{ uid='uid-CRU6'; figi='FUTCNY'; ticker='CRU6'; class_code='SPBFUT'; lot=1
        min_price_increment=[pscustomobject]@{units='0';nano=1000000}; api_trade_available_flag=$true; last_trade_date='2026-09-17T00:00:00Z' } } }
  )
  [void](Run-Tick $r '2026-07-15 10:05')
  $st = Get-State $r
  # 2 заявки прошли (вход1: market+stop это 1 market... каждый вход = 1 PostOrder), третья должна упереться
  Check 'flood-cap: entries_halt активен' ([bool]$st.entries_halt.active)
  Check 'flood-cap: PostOrder <= 2' ((Get-Calls $r 'PostOrder').Count -le 2)
}

# --- 22. tp1-sync: TP1-заявка исполнилась у брокера -> пол-позиции закрыто, стоп в БУ
function Scn-Tp1Sync {
  $r = New-Scenario 'tp1-sync'
  $s = New-BaseState $r
  $card = New-Card 'setA' 'NG' 'NGQ6' 'uid-NGQ6' 'long' 4 2.9 2.676 7749.12 3.236
  $card.tp1_order_id = 'tp-9'
  $s.sleeves.setA.positions = @($card)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'mock\OperationsService.GetPortfolio.json') ([pscustomobject]@{ positions = @(
    [pscustomobject]@{ instrumentUid='uid-NGQ6'; instrumentType='futures'; quantityLots=[pscustomobject]@{units='2';nano=0} } ) })
  Write-Json (Join-Path $r 'mock\StopOrdersService.GetStopOrders.json') ([pscustomobject]@{ stopOrders = @(
    [pscustomobject]@{ stopOrderId='stop-live-1' } ) })   # tp-9 исчез = исполнился
  Write-Json (Join-Path $r 'mock\OperationsService.GetOperations.json') ([pscustomobject]@{ operations = @(
    [pscustomobject]@{ id='op-tp'; date='2026-07-15T07:05:30Z'; instrumentUid='uid-NGQ6'; operationType='OPERATION_TYPE_SELL'; quantity='2'
      price=[pscustomobject]@{units='3';nano=236000000} } ) })
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  $c = @($st.sleeves.setA.positions)[0]
  Check 'tp1: лоты 4->2' ([int]$c.lots -eq 2)
  Check 'tp1: tp1_done' ([bool]$c.tp1_done)
  Check 'tp1: стоп в безубыток (=entry)' ([math]::Abs([double]$c.stop_px_pts - 2.9) -lt 1e-9)
  Check 'tp1: профит в леджере' ([double]$st.sleeves.setA.eq_rub -gt 700000)
}

# --- 23. roll-flow: сигнал ролла -> закрытие старого + открытие нового + стоп
function Scn-RollFlow {
  $r = New-Scenario 'roll-flow'
  $s = New-BaseState $r
  $card = New-Card 'core' 'NG' 'NGQ6' 'uid-NGQ6' 'long' 10 2.905 2.676 7749.12
  $card | Add-Member -NotePropertyName roll_signal_to -NotePropertyValue 'NGU6' -Force
  $s.sleeves.core.positions = @($card)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'mock\OperationsService.GetPortfolio.json') ([pscustomobject]@{ positions = @(
    [pscustomobject]@{ instrumentUid='uid-NGQ6'; instrumentType='futures'; quantityLots=[pscustomobject]@{units='10';nano=0} } ) })
  Write-Json (Join-Path $r 'mock\StopOrdersService.GetStopOrders.json') ([pscustomobject]@{ stopOrders = @(
    [pscustomobject]@{ stopOrderId='stop-live-1' } ) })
  Set-Queue $r @(
    [pscustomobject]@{ service='OrdersService'; method='PostOrder'; body_like='SELL'
      response=[pscustomobject]@{ orderId='ord-rc'; executionReportStatus='EXECUTION_REPORT_STATUS_FILL'; lotsExecuted='10'
        initialOrderPricePt=[pscustomobject]@{units='2';nano=900000000} } },   # 2.9 за лот
    [pscustomobject]@{ service='InstrumentsService'; method='FutureBy'; body_like='NGU6'
      response=[pscustomobject]@{ instrument=[pscustomobject]@{ uid='uid-NGU6'; figi='FUTNGU'; ticker='NGU6'; class_code='SPBFUT'; lot=1
        min_price_increment=[pscustomobject]@{units='0';nano=1000000}; api_trade_available_flag=$true; last_trade_date='2026-09-28T00:00:00Z' } } },
    [pscustomobject]@{ service='OrdersService'; method='PostOrder'; body_like='BUY'
      response=[pscustomobject]@{ orderId='ord-ro'; executionReportStatus='EXECUTION_REPORT_STATUS_FILL'; lotsExecuted='10'
        initialOrderPricePt=[pscustomobject]@{units='2';nano=950000000} } }   # 2.95 за лот
  )
  [void](Run-Tick $r '2026-07-15 10:30')
  $st = Get-State $r
  $c = @($st.sleeves.core.positions)[0]
  Check 'roll: карточка жива' (@($st.sleeves.core.positions).Count -eq 1)
  Check 'roll: перешла в NGU6' ([string]$c.secid -eq 'NGU6' -and [string]$c.uid -eq 'uid-NGU6')
  Check 'roll: rolls=1' ([int]$c.rolls -eq 1)
  Check 'roll: стоп пересчитан по ratio и перевыставлен' ([string]$c.stop_order_id -eq 'stop-new-1' -and [double]$c.stop_px_pts -gt 2.676)
  Check 'roll: realized учтён (закрытие 2.9 при входе 2.905 = небольшой минус)' ([double]$c.realized_rub -lt 0)
}

# --- 24. mom-rebalance: sells тик1 -> buys тик2
function Scn-MomRebalance {
  $r = New-Scenario 'mom-rebalance'
  Write-SynthSeries $r 'SBER' 320.0 6.0
  $s = New-BaseState $r
  $s.sleeves.mom.holdings = @([pscustomobject]@{ sym='GAZP'; uid='uid-GAZP'; lots=100; lot_size=10.0
    avg_px=120.0; last_px=120.0; buy_day='2026-06-01' })
  $s.sleeves.mom.cash_rub = 230000.0
  $s.sleeves.mom | Add-Member -NotePropertyName reb_target -NotePropertyValue ([pscustomobject]@{
    day='2026-07-14'; gate=$true; target=@('SBER'); done=$false }) -Force
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'mock\OperationsService.GetPortfolio.json') ([pscustomobject]@{ positions = @(
    [pscustomobject]@{ instrumentUid='uid-GAZP'; instrumentType='share'; quantityLots=[pscustomobject]@{units='100';nano=0} } ) })
  Set-Queue $r @(
    [pscustomobject]@{ service='InstrumentsService'; method='ShareBy'; body_like='GAZP'
      response=[pscustomobject]@{ instrument=[pscustomobject]@{ uid='uid-GAZP'; figi='SGAZP'; ticker='GAZP'; class_code='TQBR'; lot=10
        min_price_increment=[pscustomobject]@{units='0';nano=10000000}; api_trade_available_flag=$true } } },
    [pscustomobject]@{ service='OrdersService'; method='PostOrder'; body_like='SELL'
      response=[pscustomobject]@{ orderId='ord-ms'; executionReportStatus='EXECUTION_REPORT_STATUS_FILL'; lotsExecuted='100'
        executedOrderPrice=[pscustomobject]@{units='125000';nano=0} } },   # 100 лот x lot10 x 125₽
    [pscustomobject]@{ service='InstrumentsService'; method='ShareBy'; body_like='SBER'
      response=[pscustomobject]@{ instrument=[pscustomobject]@{ uid='uid-SBER'; figi='SSBER'; ticker='SBER'; class_code='TQBR'; lot=10
        min_price_increment=[pscustomobject]@{units='0';nano=10000000}; api_trade_available_flag=$true } } },
    [pscustomobject]@{ service='OrdersService'; method='PostOrder'; body_like='BUY'
      response=[pscustomobject]@{ orderId='ord-mb'; executionReportStatus='EXECUTION_REPORT_STATUS_FILL'; lotsExecuted='110'
        executedOrderPrice=[pscustomobject]@{units='352000';nano=0} } }   # ~110 лот x lot10 x 320₽
  )
  [void](Run-Tick $r '2026-07-15 10:12')
  $st = Get-State $r
  Check 'mom тик1: GAZP продан' (@($st.sleeves.mom.holdings | Where-Object { $_.sym -eq 'GAZP' }).Count -eq 0)
  Check 'mom тик1: кэш вырос (100x10x125)' ([double]$st.sleeves.mom.cash_rub -gt 350000)
  [void](Run-Tick $r '2026-07-15 10:13')
  $st = Get-State $r
  $sb = @($st.sleeves.mom.holdings | Where-Object { $_.sym -eq 'SBER' })
  Check 'mom тик2: SBER куплен' ($sb.Count -eq 1)
  if ($sb.Count) { Check 'mom тик2: лоты > 50 (бюджет 0.5xeq / 3200р лот)' ([int]$sb[0].lots -gt 50) }
  Check 'mom: ребаланс done' ([bool]$st.sleeves.mom.reb_target.done)
}

# --- 25. crash-recovery: интент завис в POSTED без broker_id (краш между persist и post) -> LOST -> adopt
function Scn-CrashRecovery {
  $r = New-Scenario 'crash-recovery'
  $s = New-BaseState $r
  $it = New-EntryIntent 'core' 'NG' 'buy' 0.229 0.1145 2.9 0.05
  $it.state = 'POSTED'; $it.attempts = 1; $it.lots = 19; $it.uid = 'uid-NGQ6'; $it.ticker = 'NGQ6'
  $it.broker_order_id = ''   # ответ не успел записаться
  $it.ctx | Add-Member -NotePropertyName risk_rub -NotePropertyValue 35000.0
  $s.pending_intents = @($it)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  # заявка реально встала и исполнилась: операция есть
  Write-Json (Join-Path $r 'mock\OperationsService.GetOperations.json') ([pscustomobject]@{ operations = @(
    [pscustomobject]@{ id='op-c'; date='2026-07-15T07:05:30Z'; instrumentUid='uid-NGQ6'; operationType='OPERATION_TYPE_BUY'; quantity='19'
      price=[pscustomobject]@{units='2';nano=908000000} } ) })
  [void](Run-Tick $r '2026-07-15 10:06')   # тик1: POSTED без id -> LOST -> adopt в том же тике полинга
  $st = Get-State $r
  Check 'crash: карточка восстановлена по операции' (@($st.sleeves.core.positions).Count -eq 1)
  Check 'crash: PostOrder НЕ дублировался' ((Get-Calls $r 'PostOrder').Count -eq 0)
}

# --- 25b. funding: рублей нет -> бот продаёт серебро под ГО и входит
function Scn-Funding {
  $r = New-Scenario 'funding'
  $s = New-BaseState $r
  $s.pending_intents = @(New-EntryIntent 'core' 'NG' 'buy' 0.229 0.1145 2.9 0.05)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'data\live_rf\config.json') ([pscustomobject]@{ funding = @('uid-XAG') })
  Write-Json (Join-Path $r 'mock\InstrumentsService.GetInstrumentBy.json') ([pscustomobject]@{ instrument = [pscustomobject]@{
    uid = 'uid-XAG'; ticker = 'SLVRUB_TOM'; class_code = 'CETS'; lot = 100
    min_price_increment = [pscustomobject]@{ units = '0'; nano = 50000000 }
    api_trade_available_flag = $true } })
  Write-Json (Join-Path $r 'mock\MarketDataService.GetLastPrices.json') ([pscustomobject]@{ lastPrices = @(
    [pscustomobject]@{ instrumentUid = 'uid-XAG'; price = [pscustomobject]@{ units = '139'; nano = 100000000 } } ) })
  Write-Json (Join-Path $r 'mock\OperationsService.GetPortfolio.json') ([pscustomobject]@{ positions = @(
    [pscustomobject]@{ instrumentUid = 'uid-XAG'; instrumentType = 'currency'; quantityLots = [pscustomobject]@{ units = '18'; nano = 0 } } ) })
  Set-Queue $r @(
    [pscustomobject]@{ service='OperationsService'; method='GetPositions'
      response=[pscustomobject]@{ money = @([pscustomobject]@{ currency='rub'; units='1000'; nano=0 }) } },
    [pscustomobject]@{ service='OperationsService'; method='GetPositions'
      response=[pscustomobject]@{ money = @([pscustomobject]@{ currency='rub'; units='300000'; nano=0 }) } }
  )
  [void](Run-Tick $r '2026-07-15 10:05')
  $st = Get-State $r
  $posts = Get-Calls $r 'PostOrder'
  $sellXag = @($posts | Where-Object { $_.body -match 'uid-XAG' -and $_.body -match 'SELL' })
  Check 'funding: серебро продано под ГО' ($sellXag.Count -eq 1)
  Check 'funding: вход состоялся после продажи' (@($st.sleeves.core.positions).Count -eq 1)
  Check 'funding: funding-интент погашен' (@($st.pending_intents | Where-Object { $_.kind -eq 'funding_sell' }).Count -eq 0)
}

# --- 26. DRYRUN e2e: полный цикл входа БЕЗ ЕДИНОГО мутирующего вызова наружу
function Scn-DryrunE2e {
  $r = New-Scenario 'dryrun-e2e'
  $s = New-BaseState $r
  $s.pending_intents = @(New-EntryIntent 'core' 'NG' 'buy' 0.229 0.1145 2.9 0.05)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  [void](Run-Tick $r '2026-07-15 10:05' 'dryrun')   # вход: WOULD CALL PostOrder -> виртуальный филл -> WOULD CALL PostStopOrder
  [void](Run-Tick $r '2026-07-15 11:00' 'dryrun')   # обычный тик: reconcile log-only, дрейфа/аварий нет
  $st = Get-State $r
  $pos = @($st.sleeves.core.positions)
  Check 'dryrun: виртуальная карточка создана' ($pos.Count -eq 1)
  if ($pos.Count) {
    Check 'dryrun: филл по референс-цене 2.9' ([math]::Abs([double]$pos[0].entry_px_pts - 2.9) -lt 1e-9)
    Check 'dryrun: виртуальный стоп' ([string]$pos[0].stop_order_id -eq 'dryrun-stop')
  }
  Check 'dryrun: позиция пережила второй тик (сверка log-only)' (@($st.sleeves.core.positions).Count -eq 1)
  Check 'dryrun: дрифт-счётчики нулевые' ([int]$st.drift.D2 -eq 0 -and [int]$st.drift.D4 -eq 0 -and [int]$st.drift.D6 -eq 0)
  $mut = @('PostOrder','CancelOrder','PostStopOrder','CancelStopOrder')
  $bad = @((Get-Calls $r) | Where-Object { $mut -contains $_.method })
  Check 'dryrun: НОЛЬ мутирующих вызовов в транспорт' ($bad.Count -eq 0)
  $would = Get-Content (Join-Path $r 'data\live_rf\dryrun_calls.log') -ErrorAction SilentlyContinue
  Check 'dryrun: WOULD CALL записаны (>=2: market + stop)' (@($would).Count -ge 2)
}

# --- 27b. funding-инструмент не торгуется (металлы CETS открываются в 10:00, FORTS в 07:00):
# продажа НЕ постится, интент входа ждёт, тик жив (инцидент 2026-07-20: серебро в 07:00)
function Scn-FundingGated {
  $r = New-Scenario 'funding-gated'
  $s = New-BaseState $r
  $s.pending_intents = @(New-EntryIntent 'core' 'NG' 'buy' 0.229 0.1145 2.9 0.05)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'data\live_rf\config.json') ([pscustomobject]@{ funding = @('uid-XAG') })
  Write-Json (Join-Path $r 'mock\InstrumentsService.GetInstrumentBy.json') ([pscustomobject]@{ instrument = [pscustomobject]@{
    uid = 'uid-XAG'; ticker = 'SLVRUB_TOM'; class_code = 'CETS'; lot = 100
    min_price_increment = [pscustomobject]@{ units = '0'; nano = 50000000 }
    api_trade_available_flag = $true } })
  Set-Queue $r @(
    # рублей мало -> нужен фандинг
    [pscustomobject]@{ service='OperationsService'; method='GetPositions'
      response=[pscustomobject]@{ money = @([pscustomobject]@{ currency='rub'; units='1000'; nano=0 }) } },
    # статус #1: NG (гейт входа) - торгуется
    [pscustomobject]@{ service='MarketDataService'; method='GetTradingStatus'
      response=[pscustomobject]@{ tradingStatus = 'SECURITY_TRADING_STATUS_NORMAL_TRADING' } },
    # статус #2: серебро - НЕ торгуется (утро, металлы ещё закрыты)
    [pscustomobject]@{ service='MarketDataService'; method='GetTradingStatus'
      response=[pscustomobject]@{ tradingStatus = 'SECURITY_TRADING_STATUS_NOT_AVAILABLE_FOR_TRADING' } }
  )
  [void](Run-Tick $r '2026-07-15 07:05')
  $st = Get-State $r
  $log = Get-Content (Join-Path $r 'data\live_rf\tick_log.txt') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  $ret = Get-Calls $r 'PostOrder'
  $posts = @($ret | Where-Object { $null -ne $_ })
  Check 'fund-gate: тик выжил' ([string]$log -match 'tick ok')
  Check 'fund-gate: ноль PostOrder (ни серебра, ни входа)' ($posts.Count -eq 0)
  Check 'fund-gate: интент входа ждёт (INTENT)' (@($st.pending_intents | Where-Object { $_.kind -eq 'entry' -and $_.state -eq 'INTENT' }).Count -eq 1)
  Check 'fund-gate: причина в логе (не торгуется)' ([string]$log -match 'не торгуется')
}

# --- 28. PostOrder HTTP 400: отказ брокера = судьба ИНТЕНТА (REJECTED), тик ЖИВ.
# Инцидент 2026-07-20: 400 на funding_sell валил каждый тик, state machine замерзала.
function Scn-Post400 {
  $r = New-Scenario 'post-400'
  $s = New-BaseState $r
  $s.pending_intents = @(New-EntryIntent 'core' 'NG' 'buy' 0.229 0.1145 2.9 0.05)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Set-Queue $r @([pscustomobject]@{ service='OrdersService'; method='PostOrder'; http = 400; message = 'mock broker reject' })
  [void](Run-Tick $r '2026-07-15 10:05')
  $st = Get-State $r
  # лог движка - UTF-8; PS 5.1 без -Encoding читает ANSI и кириллица в -match ломается
  $log = Get-Content (Join-Path $r 'data\live_rf\tick_log.txt') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  # Get-Calls возвращает ,$rows: СНАЧАЛА присвоить (снимает обёртку), ПОТОМ пайпить -
  # прямой пайп функции отдаёт внутренний массив одним элементом (Count всегда 1)
  $ret = Get-Calls $r 'PostOrder'
  $posts = @($ret | Where-Object { $null -ne $_ })
  Check 'post-400: тик выжил (tick ok в логе)' ([string]$log -match 'tick ok')
  Check 'post-400: тик НЕ упал (нет tick ERROR)' ([string]$log -notmatch 'tick ERROR')
  Check 'post-400: карточек нет' (@($st.sleeves.core.positions).Count -eq 0)
  Check 'post-400: интенты вычищены (REJECTED убран cleanup-ом)' (@($st.pending_intents).Count -eq 0)
  Check 'post-400: попытка PostOrder была ровно одна' ($posts.Count -eq 1)
}

# --- 29. operations падают в adopt: LOST остаётся LOST, репоста НЕТ (риск двойного филла), тик ЖИВ
function Scn-AdoptOpsFail {
  $r = New-Scenario 'adopt-ops-fail'
  $s = New-BaseState $r
  $it = New-EntryIntent 'core' 'NG' 'buy' 0.229 0.1145 2.9 0.05
  $it.state = 'LOST'; $it.attempts = 1; $it.lots = 3
  $it.ticker = 'NGQ6'; $it.uid = 'uid-NGQ6'
  $it.t_post = (UtcStrToMs '2026-07-15 07:02'); $it.state_ts = (UtcStrToMs '2026-07-15 07:02')
  $s.pending_intents = @($it)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Set-Queue $r @([pscustomobject]@{ service='OperationsService'; method='GetOperations'; http = 400; message = 'mock ops fail' })
  [void](Run-Tick $r '2026-07-15 10:05')
  $st = Get-State $r
  $log = Get-Content (Join-Path $r 'data\live_rf\tick_log.txt') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  $lost = @($st.pending_intents | Where-Object { $_.state -eq 'LOST' })
  $ret = Get-Calls $r 'PostOrder'
  $posts = @($ret | Where-Object { $null -ne $_ })
  Check 'adopt-fail: тик выжил (tick ok в логе)' ([string]$log -match 'tick ok')
  Check 'adopt-fail: интент остался LOST' ($lost.Count -eq 1)
  Check 'adopt-fail: attempts не вырос (репоста не было)' ($lost.Count -eq 1 -and [int]$lost[0].attempts -eq 1)
  Check 'adopt-fail: ноль PostOrder в транспорт' ($posts.Count -eq 0)
  Check 'adopt-fail: причина в логе (репост отложен)' ([string]$log -match 'репост отложен')
}

# --- 30. пустой снимок счёта: брокер вернул нулевой портфель (транзиентный глюк) -> bot_capital
# и account_liquid НЕ затираются мусором, несётся последнее валидное (инцидент 2026-07-23,
# фантомная просадка ~97% в кривой капитала на дашборде «Фьючерсы·Реал»)
function Scn-EmptySnapshot {
  $r = New-Scenario 'empty-snapshot'
  $s = New-BaseState $r
  # прошлый валидный тик уже записал точный капитал бота и ликвидность счёта
  $s.go | Add-Member -NotePropertyName bot_capital_rub -NotePropertyValue 796000.0 -Force
  $s.go | Add-Member -NotePropertyName account_liquid_rub -NotePropertyValue 1400000.0 -Force
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  # прод: маржа отключена -> preflight падает на GetPortfolio; брокер вернул ПУСТОЙ портфель
  # (дефолтная фикстура: positions=@(), нет total_amount_portfolio -> liquid=0, totRub=0)
  Set-Queue $r @([pscustomobject]@{ service='UsersService'; method='GetMarginAttributes'; http=400; message='margin disabled' })
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  $log = Get-Content (Join-Path $r 'data\live_rf\tick_log.txt') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  Check 'empty-snap: тик выжил (tick ok в логе)' ([string]$log -match 'tick ok')
  Check 'empty-snap: bot_capital НЕ затёрт (несёт 796000)' ([double]$st.go.bot_capital_rub -eq 796000.0)
  Check 'empty-snap: account_liquid НЕ затёрт (несёт 1400000)' ([double]$st.go.account_liquid_rub -eq 1400000.0)
  $eq = @(Read-JsonFile (Join-Path $r 'data\live_rf\equity.json'))
  Check 'empty-snap: точка эквити с валидным bot_capital (не мусор)' ($eq.Count -ge 1 -and [double]$eq[-1].bot_capital -eq 796000.0)
}

# --- 33. entry-px-exec: у рыночной заявки «подано» != «исполнено» -> берём исполненную цену
# Инцидент 2026-08-04: initialOrderPricePt у рыночной заявки MOEX идёт с защитной полосой
# (~0.2% в сторону сделки). Лестница брала его первым, расхождение проходило сквозь 30%-ые
# ворота, и записанный вход ложился ВНЕ диапазона рынка — всегда в худшую сторону.
function Scn-EntryPxExecuted {
  $r = New-Scenario 'entry-px-exec'
  $s = New-BaseState $r
  $s.pending_intents = @(New-EntryIntent 'core' 'NG' 'buy' 0.229 0.1145 2.9 0.05)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  # подано 2.912 (защитная полоса), исполнено 2.905 = 19 лот x 2.905 x 7749.12 ₽/пункт
  Write-Json (Join-Path $r 'mock\OrdersService.PostOrder.json') ([pscustomobject]@{
    orderId = 'ord-px'; executionReportStatus = 'EXECUTION_REPORT_STATUS_FILL'; lotsExecuted = '19'
    initialOrderPricePt = [pscustomobject]@{ units = '2'; nano = 912000000 }
    executedOrderPrice = [pscustomobject]@{ units = '427712'; nano = 678400000; currency = 'rub' } })
  [void](Run-Tick $r '2026-07-15 10:05')
  $pos = @((Get-State $r).sleeves.core.positions)
  Check 'entry-px-exec: карточка создана' ($pos.Count -eq 1)
  if ($pos.Count) {
    Check 'entry-px-exec: вход 2.905 (исполнено), а НЕ 2.912 (подано)' ([math]::Abs([double]$pos[0].entry_px_pts - 2.905) -lt 1e-9)
    Check 'entry-px-exec: стоп от реальной цены = 2.676' ([math]::Abs([double]$pos[0].stop_px_pts - 2.676) -lt 1e-9)
  }
}

# --- 34. entry-px-repair: исполненной цены в ответе НЕТ -> карточка чинится по операциям
# Ровно случай L00017/L00018 (04.08): в ответе только «подано», карточка записала защитную
# цену. Confirm-EntryPx подтверждает вход по операциям брокера — источнику, которому движок
# уже верит при стопах/TP1/adopt — и правит цену. Живую стоп-заявку при этом НЕ двигает.
function Scn-EntryPxRepair {
  $r = New-Scenario 'entry-px-repair'
  $s = New-BaseState $r
  $s.pending_intents = @(New-EntryIntent 'core' 'NG' 'buy' 0.229 0.1145 2.9 0.05)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'mock\OrdersService.PostOrder.json') ([pscustomobject]@{
    orderId = 'ord-pxr'; executionReportStatus = 'EXECUTION_REPORT_STATUS_FILL'; lotsExecuted = '19'
    initialOrderPricePt = [pscustomobject]@{ units = '2'; nano = 912000000 } })   # только «подано»
  Write-Json (Join-Path $r 'mock\OperationsService.GetOperations.json') ([pscustomobject]@{ operations = @(
    [pscustomobject]@{ id = 'op-px'; date = '2026-07-15T07:05:30Z'; instrumentUid = 'uid-NGQ6'
      operationType = 'OPERATION_TYPE_BUY'; quantity = '19'
      price = [pscustomobject]@{ units = '2'; nano = 905000000 } } ) })
  [void](Run-Tick $r '2026-07-15 10:05')
  $pos = @((Get-State $r).sleeves.core.positions)
  Check 'entry-px-repair: карточка создана' ($pos.Count -eq 1)
  if ($pos.Count) {
    Check 'entry-px-repair: вход исправлен на 2.905 по операциям' ([math]::Abs([double]$pos[0].entry_px_pts - 2.905) -lt 1e-9)
    Check 'entry-px-repair: помечен подтверждённым (повторно не дёргаем API)' ([bool]$pos[0].entry_px_ok)
    # намеренно: живая стоп-заявка осталась там, где встала при входе (2.912-0.229)
    Check 'entry-px-repair: стоп у брокера НЕ сдвинут' ([math]::Abs([double]$pos[0].stop_px_pts - 2.683) -lt 1e-9)
    Check 'entry-px-repair: комиссия пересчитана от реальной цены' ([math]::Abs([double]$pos[0].fees_rub - [math]::Round(19 * 2.905 * 7749.12 * 0.00025, 2)) -lt 0.01)
  }
}

# --- 34. sleeve-rebase: конфиг задаёт новую базу капитала рукава -> eq_rub встаёт на цель, базы
# доходности едут тем же множителем (иначе отчёт показал бы фантомный скачок), применяется РОВНО
# один раз на id. Решение пользователя 2026-08-12: леджеры отстали от реального капитала счёта.
function Scn-SleeveRebase {
  $r = New-Scenario 'sleeve-rebase'
  $s = New-BaseState $r
  $s.sleeves.core.month_start_eq = 600000.0   # доходность рукава +16.67% - должна пережить ребейз
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'data\live_rf\config.json') ([pscustomobject]@{
    sleeve_rebase = [pscustomobject]@{ id = 'test-rebase-1'; core = 1050000.0; setA = 1050000.0 } })
  $rC0 = 700000.0 / 600000.0 - 1
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'rebase: core eq_rub встал на цель' ([math]::Abs([double]$st.sleeves.core.eq_rub - 1050000.0) -lt 0.01)
  Check 'rebase: setA eq_rub встал на цель' ([math]::Abs([double]$st.sleeves.setA.eq_rub - 1050000.0) -lt 0.01)
  Check 'rebase: core month_start_eq x1.5 (600k -> 900k)' ([math]::Abs([double]$st.sleeves.core.month_start_eq - 900000.0) -lt 0.01)
  Check 'rebase: core day_start_eq x1.5' ([math]::Abs([double]$st.sleeves.core.day_start_eq - 1050000.0) -lt 0.01)
  $rC1 = [double]$st.sleeves.core.eq_rub / [double]$st.sleeves.core.month_start_eq - 1
  Check 'rebase: доходность рукава НЕ исказилась' ([math]::Abs($rC1 - $rC0) -lt 1e-9)
  Check 'rebase: вотермарка выставлена' ([string]$st.watermarks.sleeve_rebase_id -eq 'test-rebase-1')
  # второй тик с тем же id - ребейз не должен примениться повторно
  [void](Run-Tick $r '2026-07-15 11:15')
  $st2 = Get-State $r
  Check 'rebase: идемпотентность (второй тик не удвоил)' ([math]::Abs([double]$st2.sleeves.core.eq_rub - 1050000.0) -lt 0.01)
  Check 'rebase: month_start_eq тоже не уехал повторно' ([math]::Abs([double]$st2.sleeves.core.month_start_eq - 900000.0) -lt 0.01)
}

# --- 42. evening-entry: Путь A - вечерняя цена пробивает канал -> вход СЕГОДНЯ (не завтра)
# CNY синтетика (New-BaseState): 40 плоских будних баров close=11.686, h-l=range=0.2614,
# заканчиваются 2026-07-14 -> chHi(база-20, rearm нет) = 11.686+0.2614/2 = 11.8167.
# Мок-цена 12.0 > chHi -> лонг.
function Scn-EveningEntry {
  $r = New-Scenario 'evening-entry'
  $s = New-BaseState $r
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'mock\MarketDataService.GetLastPrices.json') ([pscustomobject]@{
    lastPrices = @([pscustomobject]@{ instrumentId='uid-NGQ6'; price=[pscustomobject]@{units='12';nano=0} }) })
  [void](Run-Tick $r '2026-07-15 23:40')
  $st = Get-State $r
  $pos = @($st.sleeves.core.positions | Where-Object { $_.asset -eq 'CNY' })
  Check 'evening: карточка CNY создана' ($pos.Count -eq 1)
  if ($pos.Count) { Check 'evening: вход СЕГОДНЯ (15.07), не завтра' ([string]$pos[0].entry_day -eq '2026-07-15') }
  Check 'evening: вотермарка выставлена' ([string]$st.watermarks.evening_confirm_day -eq '2026-07-15')
}

# --- 43. evening-no-signal: цена внутри канала -> сигнала нет, состояние не тронуто
# whitelist=CNY: мок GetLastPrices не различает запрошенный uid (отдаёт одно и то же значение
# любому вызывающему), поэтому без сужения до одного актива цена-полумера для CNY (11.686)
# случайно пробила бы канал NG (масштаб на порядок меньше) и дала ложный FAIL не по вине кода.
function Scn-EveningNoSignal {
  $r = New-Scenario 'evening-no-signal'
  $s = New-BaseState $r
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'data\live_rf\config.json') ([pscustomobject]@{ whitelist = @('CNY') })
  Write-Json (Join-Path $r 'mock\MarketDataService.GetLastPrices.json') ([pscustomobject]@{
    lastPrices = @([pscustomobject]@{ instrumentId='uid-NGQ6'; price=[pscustomobject]@{units='11';nano=686000000} }) })
  [void](Run-Tick $r '2026-07-15 23:40')
  $st = Get-State $r
  Check 'evening-no-signal: карточек нет' (@($st.sleeves.core.positions).Count -eq 0)
  Check 'evening-no-signal: интентов нет' (@($st.pending_intents).Count -eq 0)
  Check 'evening-no-signal: вотермарка всё равно выставлена (не долбим каждую минуту окна)' ([string]$st.watermarks.evening_confirm_day -eq '2026-07-15')
}

# --- 44. evening-idempotent: тот же вечер дважды в окне -> не задваивает
function Scn-EveningIdempotent {
  $r = New-Scenario 'evening-idempotent'
  $s = New-BaseState $r
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'mock\MarketDataService.GetLastPrices.json') ([pscustomobject]@{
    lastPrices = @([pscustomobject]@{ instrumentId='uid-NGQ6'; price=[pscustomobject]@{units='12';nano=0} }) })
  [void](Run-Tick $r '2026-07-15 23:40')
  [void](Run-Tick $r '2026-07-15 23:45')
  $st = Get-State $r
  Check 'evening-idempotent: ровно одна карточка CNY за вечер' (@($st.sleeves.core.positions | Where-Object { $_.asset -eq 'CNY' }).Count -eq 1)
}

# --- 45. evening-existing-position: у CNY уже есть карточка -> вечерняя проверка не лезет повторно
# (тот же $has-гейт, что защищает от дубля и с ночным 00:20-хуком - тут проверяем сам механизм)
function Scn-EveningExistingPosition {
  $r = New-Scenario 'evening-existing-position'
  $s = New-BaseState $r
  $card = New-Card 'core' 'CNY' 'CRU6' 'uid-NGQ6' 'long' 5 11.7 11.5 1000
  $s.sleeves.core.positions = @($card)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'mock\StopOrdersService.GetStopOrders.json') ([pscustomobject]@{ stopOrders = @(
    [pscustomobject]@{ stopOrderId='stop-live-1' } ) })
  Write-Json (Join-Path $r 'mock\OperationsService.GetPortfolio.json') ([pscustomobject]@{ positions = @(
    [pscustomobject]@{ instrumentUid='uid-NGQ6'; instrumentType='futures'; quantityLots=[pscustomobject]@{units='5';nano=0} } ) })
  Write-Json (Join-Path $r 'mock\MarketDataService.GetLastPrices.json') ([pscustomobject]@{
    lastPrices = @([pscustomobject]@{ instrumentId='uid-NGQ6'; price=[pscustomobject]@{units='12';nano=0} }) })
  [void](Run-Tick $r '2026-07-15 23:40')
  $st = Get-State $r
  Check 'evening-existing: карточка осталась одна (не задвоилась)' (@($st.sleeves.core.positions | Where-Object { $_.asset -eq 'CNY' }).Count -eq 1)
}

# --- 46. evening-halt: entries_halt активен -> вечерняя проверка ничего не делает
function Scn-EveningHalt {
  $r = New-Scenario 'evening-halt'
  $s = New-BaseState $r
  $s.entries_halt = [pscustomobject]@{ active = $true; reason = 'test halt'; since = '2026-07-15 09:00' }
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'mock\MarketDataService.GetLastPrices.json') ([pscustomobject]@{
    lastPrices = @([pscustomobject]@{ instrumentId='uid-NGQ6'; price=[pscustomobject]@{units='12';nano=0} }) })
  [void](Run-Tick $r '2026-07-15 23:40')
  $st = Get-State $r
  Check 'evening-halt: карточек нет' (@($st.sleeves.core.positions).Count -eq 0)
}

# --- авто-ребейз базы сайзинга на реальный капитал (решение пользователя 2026-08-13).
# eq_rub рукава растёт только на своём P&L, реальный капитал - ещё и на пополнениях, поэтому риск
# размывался (12.08 ядро рисковало 3.4% вместо 5%). Ребейз двусторонний, порог дрейфа 5%, только
# когда обе руки пусты (bot_capital включает var_margin открытых фьючерсов = плавающий P&L).
# База сценариев: eq_rub = 700000, month_start_eq = 600000 - множитель наблюдаем на ОБЕИХ базах,
# и MTD-доходность рукава обязана пережить ребейз без изменения (тот же приём, что в Scn-SleeveRebase).
$AR_CFG = [pscustomobject]@{ auto_rebase = [pscustomobject]@{ enabled = $true; drift_pct = 0.05; max_step_pct = 0.30 } }

function New-AutoRebaseScenario([string]$Name, [double]$CapRub, $Cfg = $AR_CFG, [switch]$WithPosition, [switch]$NoCapital) {
  $r = New-Scenario $Name
  if ($null -ne $Cfg) { Write-Json (Join-Path $r 'data\live_rf\config.json') $Cfg }
  $s = New-BaseState $r
  $s.sleeves.core.month_start_eq = 600000.0
  $s.sleeves.setA.month_start_eq = 600000.0
  if ($NoCapital) { $s.go | Add-Member -NotePropertyName bot_capital_rub -NotePropertyValue 0.0 -Force }
  if ($WithPosition) {
    $s.sleeves.core.positions = @(New-Card 'core' 'NG' 'NGQ6' 'uid-NGQ6' 'long' 19 2.905 2.676 7749.12)
  }
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  # -NoCapital: дефолтная фикстура портфеля (нет total_amount_portfolio) -> Set-BotCapital выходит
  # по guard totRub<=0 и капитал не считается вовсе; иначе капитал = total_amount_currencies
  # (позиций по фьючерсам нет -> var_margin 0, акций нет -> mom 0).
  if (-not $NoCapital) {
    $pos = @()
    if ($WithPosition) {
      $pos = @([pscustomobject]@{ instrumentUid='uid-NGQ6'; instrumentType='futures'; quantityLots=[pscustomobject]@{units='19';nano=0} })
    }
    Write-Json (Join-Path $r 'mock\OperationsService.GetPortfolio.json') ([pscustomobject]@{
      positions = $pos
      totalAmountCurrencies = [pscustomobject]@{ units=[string][long]$CapRub; nano=0; currency='rub' }
      totalAmountPortfolio  = [pscustomobject]@{ units=[string][long]($CapRub + 400000); nano=0; currency='rub' } })
  }
  if ($WithPosition) {
    Write-Json (Join-Path $r 'mock\StopOrdersService.GetStopOrders.json') ([pscustomobject]@{ stopOrders = @(
      [pscustomobject]@{ stopOrderId='stop-live-1' } ) })
  }
  return $r
}

function Get-TickLog([string]$Root) {
  return [string](Get-Content (Join-Path $Root 'data\live_rf\tick_log.txt') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
}

# Рост капитала 700k -> 770k (+10% > порога 5%): база сайзинга подтягивается, доходность не врёт.
function Scn-AutoRebaseGrow {
  $r = New-AutoRebaseScenario 'auto-rebase-grow' 770000
  $rC0 = 700000.0 / 600000.0 - 1
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'auto-rebase рост: core eq_rub подтянут к капиталу' ([math]::Abs([double]$st.sleeves.core.eq_rub - 770000.0) -lt 0.01)
  Check 'auto-rebase рост: setA eq_rub подтянут к капиталу' ([math]::Abs([double]$st.sleeves.setA.eq_rub - 770000.0) -lt 0.01)
  Check 'auto-rebase рост: month_start_eq сдвинут тем же множителем (x1.1)' ([math]::Abs([double]$st.sleeves.core.month_start_eq - 660000.0) -lt 0.01)
  $rC1 = [double]$st.sleeves.core.eq_rub / [double]$st.sleeves.core.month_start_eq - 1
  Check 'auto-rebase рост: MTD-доходность рукава не изменилась' ([math]::Abs($rC1 - $rC0) -lt 1e-9)
  Check 'auto-rebase рост: day_start_eq сдвинут (ложного -6% халта не будет)' ([math]::Abs([double]$st.sleeves.core.day_start_eq - 770000.0) -lt 0.01)
  Check 'auto-rebase рост: вотермарка дня проставлена' ([string]$st.watermarks.auto_rebase_day -eq '2026-07-15')
}

# Просадка капитала 700k -> 630k (-10%): двусторонность (fixed-fractional, как в бэктесте).
function Scn-AutoRebaseShrink {
  $r = New-AutoRebaseScenario 'auto-rebase-shrink' 630000
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'auto-rebase просадка: core eq_rub уменьшен до капитала' ([math]::Abs([double]$st.sleeves.core.eq_rub - 630000.0) -lt 0.01)
  Check 'auto-rebase просадка: month_start_eq сдвинут (x0.9)' ([math]::Abs([double]$st.sleeves.core.month_start_eq - 540000.0) -lt 0.01)
}

# Дрейф 2.1% < порога 5%: леджер не дёргаем на шуме.
function Scn-AutoRebaseBelowDrift {
  $r = New-AutoRebaseScenario 'auto-rebase-below' 715000
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'auto-rebase порог: eq_rub НЕ тронут (дрейф 2.1% < 5%)' ([math]::Abs([double]$st.sleeves.core.eq_rub - 700000.0) -lt 0.01)
  Check 'auto-rebase порог: month_start_eq НЕ тронут' ([math]::Abs([double]$st.sleeves.core.month_start_eq - 600000.0) -lt 0.01)
  Check 'auto-rebase порог: вотермарки дня нет' (-not $st.watermarks.PSObject.Properties['auto_rebase_day'])
}

# Открытая позиция: bot_capital включает var_margin -> база загрязнена плавающим P&L, ребейз ждёт.
function Scn-AutoRebaseOpenPosition {
  $r = New-AutoRebaseScenario 'auto-rebase-open' 770000 -WithPosition
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'auto-rebase позиция: eq_rub НЕ тронут' ([math]::Abs([double]$st.sleeves.core.eq_rub - 700000.0) -lt 0.01)
  Check 'auto-rebase позиция: причина в логе (отложен)' ((Get-TickLog $r) -match 'auto-rebase: отложен')
  Check 'auto-rebase позиция: карточка жива' (@($st.sleeves.core.positions).Count -eq 1)
}

# Ключа auto_rebase в конфиге нет - выкатка кода обязана быть инертной.
function Scn-AutoRebaseDisabled {
  $r = New-AutoRebaseScenario 'auto-rebase-off' 770000 $null
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'auto-rebase выкл: eq_rub НЕ тронут (по умолчанию выключен)' ([math]::Abs([double]$st.sleeves.core.eq_rub - 700000.0) -lt 0.01)
  Check 'auto-rebase выкл: вотермарки дня нет' (-not $st.watermarks.PSObject.Properties['auto_rebase_day'])
}

# Битый снимок счёта (капитал неизвестен): размер сделок не пересчитываем по мусору.
function Scn-AutoRebaseBadSnapshot {
  $r = New-AutoRebaseScenario 'auto-rebase-badsnap' 0 $AR_CFG -NoCapital
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'auto-rebase битый снимок: eq_rub НЕ тронут' ([math]::Abs([double]$st.sleeves.core.eq_rub - 700000.0) -lt 0.01)
  Check 'auto-rebase битый снимок: причина в логе' ((Get-TickLog $r) -match 'auto-rebase: капитал неизвестен')
}

# Капитал x2 за один шаг - клампинг 30% защищает от снимка, проскочившего guard totRub<=0.
function Scn-AutoRebaseClamp {
  $r = New-AutoRebaseScenario 'auto-rebase-clamp' 1400000
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'auto-rebase кламп: шаг ограничен 30% (910k, не 1.4M)' ([math]::Abs([double]$st.sleeves.core.eq_rub - 910000.0) -lt 0.01)
  Check 'auto-rebase кламп: month_start_eq сдвинут тем же множителем (x1.3)' ([math]::Abs([double]$st.sleeves.core.month_start_eq - 780000.0) -lt 0.01)
}

# Второй тик того же дня ничего не двигает (вотермарка + нулевой дрейф).
function Scn-AutoRebaseIdempotent {
  $r = New-AutoRebaseScenario 'auto-rebase-idem' 770000
  [void](Run-Tick $r '2026-07-15 11:00')
  [void](Run-Tick $r '2026-07-15 11:15')
  $st = Get-State $r
  Check 'auto-rebase идемпотентность: eq_rub не удвоился' ([math]::Abs([double]$st.sleeves.core.eq_rub - 770000.0) -lt 0.01)
  Check 'auto-rebase идемпотентность: month_start_eq не уехал' ([math]::Abs([double]$st.sleeves.core.month_start_eq - 660000.0) -lt 0.01)
}

# --- 55. margin_disabled: маржиналка на счёте отключена -> GetMarginAttributes НЕ зовём вовсе.
# Боевой факт 2026-08-18: вызов отдавал 400 каждый тик (~400 мс + мусор в latency_log), фолбэк
# на GetPortfolio был единственным рабочим путём. Флаг убирает заведомо провальный запрос.
function Scn-MarginDisabled {
  $r = New-Scenario 'margin-disabled'
  $s = New-BaseState $r
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'data\live_rf\config.json') ([pscustomobject]@{ margin_disabled = $true })
  [void](Run-Tick $r '2026-07-15 10:05')
  $st = Get-State $r
  $ret = Get-Calls $r 'GetMarginAttributes'
  $mg = @($ret | Where-Object { $null -ne $_ })
  $ret2 = Get-Calls $r 'GetPortfolio'
  $pf = @($ret2 | Where-Object { $null -ne $_ })
  Check 'margin-disabled: GetMarginAttributes НЕ вызывался' ($mg.Count -eq 0)
  Check 'margin-disabled: портфель запрошен (фолбэк-путь жив)' ($pf.Count -ge 1)
  Check 'margin-disabled: бюджет ГО посчитан' ([double]$st.go.budget_rub -gt 0)
}

# --- 56. зеркало к 55: без флага (дефолт) маржа опрашивается как раньше - защита от того,
# что оптимизация случайно отключит вызов на счетах, где маржиналка ВКЛЮЧЕНА.
function Scn-MarginEnabledDefault {
  $r = New-Scenario 'margin-enabled'
  $s = New-BaseState $r
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  [void](Run-Tick $r '2026-07-15 10:05')
  $st = Get-State $r
  $ret = Get-Calls $r 'GetMarginAttributes'
  $mg = @($ret | Where-Object { $null -ne $_ })
  Check 'margin-default: GetMarginAttributes вызывался' ($mg.Count -ge 1)
  Check 'margin-default: бюджет ГО посчитан' ([double]$st.go.budget_rub -gt 0)
}

# --- 57. long_only: шорт по VTBR/SBRF до брокера НЕ доходит. Боевой факт 2026-08-27 (i00041,
# i00042): VBU6 - поставочный фьючерс на акции, шорт по нему на экспирации = продажа самих
# акций, которых нет; маржиналка на счёте выключена -> PostOrder 400 / 30051. Интент должен
# умереть у нас, не тратя заявку и не поднимая отказ брокера.
function Scn-LongOnlyShortBlocked {
  $r = New-Scenario 'long-only-short'
  $s = New-BaseState $r
  $s.active | Add-Member -NotePropertyName VTBR -NotePropertyValue 'VBU6' -Force
  $s.pending_intents = @(New-EntryIntent 'core' 'VTBR' 'sell' 0.229 0.1145 2.9 0.05)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  [void](Run-Tick $r '2026-07-15 10:05')
  $st = Get-State $r
  $log = Get-Content (Join-Path $r 'data\live_rf\tick_log.txt') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  $ret = Get-Calls $r 'PostOrder'
  $posts = @($ret | Where-Object { $null -ne $_ })
  Check 'long-only шорт: ни одной заявки брокеру' ($posts.Count -eq 0)
  Check 'long-only шорт: интент вычищен (CANCELLED убран cleanup-ом)' (@($st.pending_intents).Count -eq 0)
  Check 'long-only шорт: карточек нет' (@($st.sleeves.core.positions).Count -eq 0)
  Check 'long-only шорт: причина в логе' ([string]$log -match 'SKIP long-only')
  Check 'long-only шорт: тик выжил' ([string]$log -match 'tick ok')
  Check 'long-only шорт: слот заявок дня не потрачен' ([int]$st.watermarks.orders_day_n -eq 0)
}

# --- 58. зеркало к 57: ЛОНГ по тому же активу проходит как обычно. Гейт обязан резать только
# сторону - иначе он молча выключит VTBR/SBRF из торговли целиком.
function Scn-LongOnlyLongPasses {
  $r = New-Scenario 'long-only-long'
  $s = New-BaseState $r
  $s.active | Add-Member -NotePropertyName VTBR -NotePropertyValue 'VBU6' -Force
  $s.pending_intents = @(New-EntryIntent 'core' 'VTBR' 'buy' 0.229 0.1145 2.9 0.05)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  [void](Run-Tick $r '2026-07-15 10:05')
  $st = Get-State $r
  $log = Get-Content (Join-Path $r 'data\live_rf\tick_log.txt') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  $ret = Get-Calls $r 'PostOrder'
  $posts = @($ret | Where-Object { $null -ne $_ })
  Check 'long-only лонг: заявка ушла брокеру' ($posts.Count -eq 1)
  Check 'long-only лонг: гейт не сработал' ([string]$log -notmatch 'SKIP long-only')
}

# --- 59. гейт НЕ трогает выход: закрытие лонга по VTBR - это side=sell, но kind=exit, и оно
# обязано проходить. Заблокированный выход = зависшая позиция на реальных деньгах.
function Scn-LongOnlyExitAllowed {
  $r = New-Scenario 'long-only-exit'
  $s = New-BaseState $r
  $s.active | Add-Member -NotePropertyName VTBR -NotePropertyValue 'VBU6' -Force
  $c = New-Card 'setA' 'VTBR' 'VBU6' 'uid-VBU6' 'long' 5 2.9 2.6 7749.12
  $s.sleeves.setA.positions = @($c)
  $ex = New-EntryIntent 'setA' 'VTBR' 'sell' 0.229 0.1145 2.9 0.02
  $ex.kind = 'exit'; $ex.lots = 5; $ex.ticker = 'VBU6'; $ex.uid = 'uid-VBU6'
  $ex.ctx = [pscustomobject]@{ card_id = $c.id; reason = 'trail-ema20' }
  $s.pending_intents = @($ex)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  [void](Run-Tick $r '2026-07-15 10:05')
  $log = Get-Content (Join-Path $r 'data\live_rf\tick_log.txt') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  $ret = Get-Calls $r 'PostOrder'
  $posts = @($ret | Where-Object { $null -ne $_ })
  Check 'long-only выход: заявка на закрытие ушла' ($posts.Count -eq 1)
  Check 'long-only выход: гейт не сработал' ([string]$log -notmatch 'SKIP long-only')
}

# --- 60. вечерний same-day путь: именно он породил боевой i00041 (26.08 20:35Z). Шорт-сигнал по
# VTBR обязан умереть на сигнале, НЕ создав интент - Invoke-EveningConfirm постит заявку сразу,
# без ожидания окна входов, поэтому гейт на постановке тут был бы уже поздно виден в логе.
# whitelist=VTBR по той же причине, что в evening-no-signal: мок цен не различает uid.
function Scn-LongOnlyEveningShort {
  $r = New-Scenario 'long-only-evening'
  Write-SynthSeries $r 'VTBR' 2.9 0.1145
  $s = New-BaseState $r
  $s.active | Add-Member -NotePropertyName VTBR -NotePropertyValue 'VBU6' -Force
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'data\live_rf\config.json') ([pscustomobject]@{ whitelist = @('VTBR') })
  # цена ниже нижней границы канала (2.9 - 0.1145/2 = 2.84275) -> донч-сигнал short
  Write-Json (Join-Path $r 'mock\MarketDataService.GetLastPrices.json') ([pscustomobject]@{
    lastPrices = @([pscustomobject]@{ instrumentId='uid-NGQ6'; price=[pscustomobject]@{units='2';nano=500000000} }) })
  [void](Run-Tick $r '2026-07-15 23:40')
  $st = Get-State $r
  $log = Get-Content (Join-Path $r 'data\live_rf\tick_log.txt') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  $ret = Get-Calls $r 'PostOrder'
  $posts = @($ret | Where-Object { $null -ne $_ })
  Check 'long-only вечер: ни одной заявки брокеру' ($posts.Count -eq 0)
  Check 'long-only вечер: интент даже не создан' (@($st.pending_intents).Count -eq 0)
  Check 'long-only вечер: карточек нет' (@($st.sleeves.core.positions).Count -eq 0)
  Check 'long-only вечер: причина в логе (@evening)' ([string]$log -match 'SKIP long-only \[core\] VTBR short @evening')
}

# --- брокерская правда в отчётности (2026-09-01) -------------------------------------------
# Контекст: на дашборде «Фьючерсы·Реал» врали ВСЕ числа. Капитал завышался на вариационную
# маржу (она уже внутри total_amount_currencies, а Set-BotCapital прибавлял её ещё раз:
# 1 665 629 вместо 1 568 657), «за сегодня» считалось от своей базы вместо daily_yield брокера,
# комиссии показывались оценкой по тарифу (8 362 против фактических 21 684), а «за всё время»
# бралось от profile_eq - бумажной модели, к счёту отношения не имеющей.
# Подпись бага лежала в самом состоянии: user_assets = -96 972, отрицательные чужие активы.

# Портфель брокера для моков. varMargin ЕСТЬ в позиции, но в тотал он НЕ добавляется отдельной
# строкой - ровно как на боевом счёте (рубли + серебро = total_amount_currencies = total).
function New-PfResponse([double]$Currencies, [double]$Total, [double]$VarMargin, [double]$ExpYield = 0.0, [double]$DailyYield = 0.0) {
  $money = { param($v) [pscustomobject]@{ units = ([long][math]::Truncate($v)).ToString(); nano = [int](($v - [math]::Truncate($v)) * 1e9); currency = 'rub' } }
  [pscustomobject]@{
    total_amount_currencies = (& $money $Currencies)
    total_amount_portfolio  = (& $money $Total)
    total_amount_shares     = (& $money ($Total - $Currencies))
    total_amount_futures    = (& $money 8444542.0)
    daily_yield             = (& $money $DailyYield)
    daily_yield_relative    = [pscustomobject]@{ units = '6'; nano = 840000000 }
    expected_yield          = [pscustomobject]@{ units = '2'; nano = 910000000 }
    positions = @([pscustomobject]@{
      instrument_type = 'futures'; instrument_uid = 'uid-NGQ6'; figi = 'FUTNG'; ticker = 'NGQ6'
      quantity = [pscustomobject]@{ units = '3'; nano = 0 }; quantity_lots = [pscustomobject]@{ units = '3'; nano = 0 }
      average_position_price = [pscustomobject]@{ units = '2'; nano = 905000000; currency = 'pt.' }
      current_price = [pscustomobject]@{ units = '3'; nano = 0; currency = 'pt.' }
      expected_yield = (& $money $ExpYield)
      var_margin = (& $money $VarMargin)
      var_margin_settled = (& $money ($VarMargin / 2))
    })
  }
}

# --- капитал НЕ двоит вариационку: bot_capital_account = валюты + акции бота, без var_margin
function Scn-CapitalNoVarMarginDoubleCount {
  $r = New-Scenario 'capital-no-double-count'
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') (New-BaseState $r)
  Set-Queue $r @(
    [pscustomobject]@{ service='UsersService'; method='GetMarginAttributes'; http=400; message='margin disabled' },
    [pscustomobject]@{ service='OperationsService'; method='GetPortfolio'; response=(New-PfResponse 1000000.0 1000000.0 100000.0 12345.0 100564.0) })
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  $cb = $st.capital_breakdown
  Check 'capital: bot_capital_account = валюты (без вариационки)' ([double]$st.go.bot_capital_account_rub -eq 1000000.0)
  Check 'capital: старая модель по-прежнему пишется (переключение - отдельный этап)' ([double]$st.go.bot_capital_rub -eq 1100000.0)
  Check 'capital: user_assets НЕ отрицательный' ([double]$cb.user_assets -ge 0)
  Check 'capital: user_assets = 0 (чужих бумаг нет)' ([double]$cb.user_assets -eq 0.0)
  Check 'capital: тождество currencies+mom+user = portfolio_total' (
    [math]::Abs(([double]$cb.currencies + [double]$cb.mom_shares + [double]$cb.user_assets) - [double]$cb.portfolio_total) -lt 0.01)
  Check 'capital: futures - это memo вариационки, а не слагаемое' ([double]$cb.futures -eq 100000.0)
  Check 'capital: обе модели в разбивке' ([double]$cb.capital_account -eq 1000000.0 -and [double]$cb.capital_legacy -eq 1100000.0)
}

# --- чужие бумаги считаются БЕЗ вычета вариационки (иначе остаток структурно отрицательный)
function Scn-CapitalUserAssetsNeverNegative {
  $r = New-Scenario 'capital-user-assets'
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') (New-BaseState $r)
  Set-Queue $r @(
    [pscustomobject]@{ service='UsersService'; method='GetMarginAttributes'; http=400; message='margin disabled' },
    [pscustomobject]@{ service='OperationsService'; method='GetPortfolio'; response=(New-PfResponse 1000000.0 1200000.0 150000.0 0.0 0.0) })
  [void](Run-Tick $r '2026-07-15 11:00')
  $cb = (Get-State $r).capital_breakdown
  Check 'user-assets: 200 000 (акции пользователя), вариационка не вычитается' ([double]$cb.user_assets -eq 200000.0)
  Check 'user-assets: тождество сходится' (
    [math]::Abs(([double]$cb.currencies + [double]$cb.mom_shares + [double]$cb.user_assets) - [double]$cb.portfolio_total) -lt 0.01)
}

# --- блок брокера пишется ДОСЛОВНО и БЕЗ единого лишнего вызова к API
function Scn-BrokerBlockPersisted {
  $r = New-Scenario 'broker-block'
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') (New-BaseState $r)
  Set-Queue $r @(
    [pscustomobject]@{ service='UsersService'; method='GetMarginAttributes'; http=400; message='margin disabled' },
    [pscustomobject]@{ service='OperationsService'; method='GetPortfolio'; response=(New-PfResponse 1000000.0 1000000.0 100000.0 12345.0 100564.0) })
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  $b = $st.broker
  Check 'broker: блок записан' ($null -ne $b)
  Check 'broker: тоталы дословно' ([double]$b.totals.portfolio -eq 1000000.0 -and [double]$b.totals.currencies -eq 1000000.0)
  Check 'broker: номинал фьючерсов - отдельным memo' ([double]$b.totals.futures_nominal -eq 8444542.0)
  Check 'broker: дневная доходность дословно' ([double]$b.daily_yield_rub -eq 100564.0 -and [double]$b.daily_yield_rel_pct -eq 6.84)
  $bp = @($b.positions)
  Check 'broker: позиция записана' ($bp.Count -eq 1 -and [string]$bp[0].ticker -eq 'NGQ6')
  Check 'broker: expected_yield и var_margin дословно' ([double]$bp[0].expected_yield -eq 12345.0 -and [double]$bp[0].var_margin -eq 100000.0)
  Check 'broker: сведённая вариационка записана' ([double]$bp[0].var_margin_settled -eq 50000.0)
  # ГЛАВНОЕ: снимок собирается из УЖЕ полученного ответа и не стоит ни одного вызова.
  # Бюджет тика на GetPortfolio = 2, оба вызова были и до правки: preflight (маржа отключена ->
  # фолбэк на портфель, оттуда же считается капитал) и Invoke-Reconcile (сверка позиций).
  # Если число вырастет - значит отчётность начала ходить к брокеру сама, а это ровно тот
  # класс регрессии, из-за которого леджер съедал GetOperations у adopt (см. Scn-AdoptOpsFail).
  $pfCalls = Get-Calls $r 'GetPortfolio'
  Check 'broker: бюджет тика на GetPortfolio не вырос (preflight + reconcile = 2)' (@($pfCalls | Where-Object { $null -ne $_ }).Count -eq 2)
  $opsCalls = Get-Calls $r 'GetOperations'
  Check 'broker: леджер НЕ дёргает операции в торговые часы' (@($opsCalls | Where-Object { $null -ne $_ }).Count -eq 0)
}

# --- битый снимок портфеля: блок брокера НЕСЁТСЯ, а не обнуляется (инцидент 2026-07-23)
function Scn-BrokerBlockSurvivesEmptySnapshot {
  $r = New-Scenario 'broker-block-empty'
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') (New-BaseState $r)
  Set-Queue $r @(
    [pscustomobject]@{ service='UsersService'; method='GetMarginAttributes'; http=400; message='margin disabled' },
    [pscustomobject]@{ service='OperationsService'; method='GetPortfolio'; response=(New-PfResponse 1000000.0 1000000.0 100000.0 12345.0 100564.0) })
  [void](Run-Tick $r '2026-07-15 11:00')
  Check 'broker-empty: первый тик записал блок' ($null -ne (Get-State $r).broker)
  # второй тик: маржа 400 + ПУСТОЙ портфель из дефолтной фикстуры (positions=@(), тоталов нет)
  Set-Queue $r @([pscustomobject]@{ service='UsersService'; method='GetMarginAttributes'; http=400; message='margin disabled' })
  [void](Run-Tick $r '2026-07-15 11:20')
  $st = Get-State $r
  Check 'broker-empty: блок НЕ обнулён (несёт прошлый)' ([double]$st.broker.totals.portfolio -eq 1000000.0)
  Check 'broker-empty: дневная доходность тоже несётся' ([double]$st.broker.daily_yield_rub -eq 100564.0)
  Check 'broker-empty: bot_capital_account не затёрт' ([double]$st.go.bot_capital_account_rub -eq 1000000.0)
}

# --- брокерский леджер: реальные комиссии и сведённая вариационка, без двойного счёта
function Scn-BrokerLedgerFees {
  $r = New-Scenario 'broker-ledger'
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') (New-BaseState $r)
  $ops = [pscustomobject]@{ operations = @(
    [pscustomobject]@{ id='op1'; operation_type='OPERATION_TYPE_ACCRUING_VARMARGIN'; instrument_type=''
      payment=[pscustomobject]@{ units='40000'; nano=0; currency='rub' } },
    [pscustomobject]@{ id='op2'; operation_type='OPERATION_TYPE_WRITING_OFF_VARMARGIN'; instrument_type=''
      payment=[pscustomobject]@{ units='-10000'; nano=0; currency='rub' } },
    [pscustomobject]@{ id='op3'; operation_type='OPERATION_TYPE_BROKER_FEE'; instrument_type='futures'
      payment=[pscustomobject]@{ units='-2000'; nano=0; currency='rub' } },
    # комиссия по СВОИМ бумагам пользователя: бот её не платил -> в fees_other, не в fees
    [pscustomobject]@{ id='op4'; operation_type='OPERATION_TYPE_BROKER_FEE'; instrument_type='share'
      payment=[pscustomobject]@{ units='-500'; nano=0; currency='rub' } }) }
  Write-Json (Join-Path $r 'mock\OperationsService.GetOperations.json') $ops
  Set-Queue $r @([pscustomobject]@{ service='UsersService'; method='GetMarginAttributes'; http=400; message='margin disabled' })
  # вечернее окно: вариационка сводится на вечернем клиринге, раньше читать нечего
  [void](Run-Tick $r '2026-07-15 23:10')
  $lg = (Get-State $r).broker_ledger
  Check 'ledger: блок записан' ($null -ne $lg)
  Check 'ledger: сведённая вариационка 30 000' ([double]$lg.varmargin_rub -eq 30000.0)
  Check 'ledger: комиссии бота -2 000 (только фьючерсы)' ([double]$lg.fees_rub -eq -2000.0)
  Check 'ledger: чужие комиссии отдельно, не потеряны' ([double]$lg.fees_other_rub -eq -500.0)
  Check 'ledger: суточная вотермарка выставлена' ([string](Get-State $r).watermarks.broker_ledger_day -eq '2026-07-15')
  # повторный тик в тот же день: НЕ удваиваем
  [void](Run-Tick $r '2026-07-15 23:40')
  $lg2 = (Get-State $r).broker_ledger
  Check 'ledger: повторный тик не удвоил вариационку' ([double]$lg2.varmargin_rub -eq 30000.0)
  Check 'ledger: повторный тик не удвоил комиссии' ([double]$lg2.fees_rub -eq -2000.0)
}

# --- утренний тик леджер НЕ трогает: отчётность не должна тратить вызовы раньше state machine
function Scn-BrokerLedgerNotInTradingHours {
  $r = New-Scenario 'broker-ledger-hours'
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') (New-BaseState $r)
  Set-Queue $r @([pscustomobject]@{ service='UsersService'; method='GetMarginAttributes'; http=400; message='margin disabled' })
  [void](Run-Tick $r '2026-07-15 10:05')
  $st = Get-State $r
  Check 'ledger-hours: в торговые часы леджер не считался' (-not $st.PSObject.Properties['broker_ledger'])
  Check 'ledger-hours: вотермарка не выставлена' ([string]$st.watermarks.broker_ledger_day -ne '2026-07-15')
}

# ================= запуск =================
$scenarios = @(
  ${function:Scn-EntryPxExecuted}, ${function:Scn-EntryPxRepair},
  ${function:Scn-EntryFill}, ${function:Scn-DirectSleeveAccess}, ${function:Scn-EntryReject}, ${function:Scn-EntryLostAdopt}, ${function:Scn-EntryLostRepost},
  ${function:Scn-Qty0}, ${function:Scn-GoCap}, ${function:Scn-GoTrim}, ${function:Scn-HardDd},
  ${function:Scn-HardDdIgnoresBlendedPeak}, ${function:Scn-DayHaltReal},
  ${function:Scn-D2}, ${function:Scn-D4Confirmed}, ${function:Scn-D4ManualExt}, ${function:Scn-D4ShortHistoricalClose}, ${function:Scn-D4PendingStatus}, ${function:Scn-D4StopAlive}, ${function:Scn-D4Quarantine},
  ${function:Scn-D4Transient}, ${function:Scn-D4EmptySnapshot}, ${function:Scn-D5},
  ${function:Scn-D6Repost}, ${function:Scn-D6Fail}, ${function:Scn-StocksDeficit}, ${function:Scn-StocksSurplus},
  ${function:Scn-ClearingGate}, ${function:Scn-Weekend}, ${function:Scn-HaltEntriesFile}, ${function:Scn-HaltCloseFile},
  ${function:Scn-FloodCap}, ${function:Scn-Tp1Sync}, ${function:Scn-RollFlow}, ${function:Scn-MomRebalance},
  ${function:Scn-CrashRecovery}, ${function:Scn-Funding}, ${function:Scn-DryrunE2e},
  ${function:Scn-FundingGated}, ${function:Scn-Post400}, ${function:Scn-AdoptOpsFail},
  ${function:Scn-EmptySnapshot}, ${function:Scn-SleeveRebase},
  ${function:Scn-EveningEntry}, ${function:Scn-EveningNoSignal}, ${function:Scn-EveningIdempotent},
  ${function:Scn-EveningExistingPosition}, ${function:Scn-EveningHalt},
  ${function:Scn-GoNewBelowCap}, ${function:Scn-GoNewBetween}, ${function:Scn-GoNewAboveTrim},
  ${function:Scn-GoNewCapAllowsEntry},
  ${function:Scn-AutoRebaseGrow}, ${function:Scn-AutoRebaseShrink}, ${function:Scn-AutoRebaseBelowDrift},
  ${function:Scn-AutoRebaseOpenPosition}, ${function:Scn-AutoRebaseDisabled}, ${function:Scn-AutoRebaseBadSnapshot},
  ${function:Scn-AutoRebaseClamp}, ${function:Scn-AutoRebaseIdempotent},
  ${function:Scn-MarginDisabled}, ${function:Scn-MarginEnabledDefault},
  ${function:Scn-LongOnlyShortBlocked}, ${function:Scn-LongOnlyLongPasses}, ${function:Scn-LongOnlyExitAllowed},
  ${function:Scn-LongOnlyEveningShort},
  ${function:Scn-CapitalNoVarMarginDoubleCount}, ${function:Scn-CapitalUserAssetsNeverNegative},
  ${function:Scn-BrokerBlockPersisted}, ${function:Scn-BrokerBlockSurvivesEmptySnapshot},
  ${function:Scn-BrokerLedgerFees}, ${function:Scn-BrokerLedgerNotInTradingHours}
)
foreach ($fn in $scenarios) { & $fn }
