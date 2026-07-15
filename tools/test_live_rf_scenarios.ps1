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
    order_key = 'LRF-i00001-entry'; broker_order_id = ''
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
  Write-Json (Join-Path $Mock 'InstrumentsService.FutureBy.json') ([pscustomobject]@{ instrument = [pscustomobject]@{
    uid = 'uid-NGQ6'; figi = 'FUTNG'; ticker = 'NGQ6'; class_code = 'SPBFUT'; lot = 1
    min_price_increment = [pscustomobject]@{ units = '0'; nano = 1000000 }
    api_trade_available_flag = $true; last_trade_date = '2026-08-27T00:00:00Z' } })
  Write-Json (Join-Path $Mock 'InstrumentsService.GetFuturesMargin.json') ([pscustomobject]@{
    initial_margin_on_buy  = [pscustomobject]@{ units = '6340'; nano = 0; currency = 'rub' }
    initial_margin_on_sell = [pscustomobject]@{ units = '6340'; nano = 0; currency = 'rub' }
    min_price_increment_amount = [pscustomobject]@{ units = '7'; nano = 749120000 } })
  Write-Json (Join-Path $Mock 'OrdersService.PostOrder.json') ([pscustomobject]@{
    orderId = 'ord-default'; executionReportStatus = 'EXECUTION_REPORT_STATUS_FILL'
    executedOrderPrice = [pscustomobject]@{ units = '2'; nano = 905000000; currency = 'rub' } })
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
function Run-Tick([string]$Root, [string]$MskTime, [string]$Mode = 'prod') {
  $nowMs = MskToNowMs $MskTime
  $env:TINVEST_MODE = $Mode; $env:TINVEST_MOCK_DIR = Join-Path $Root 'mock'
  $env:TINVEST_ACCOUNT_ID = 'acc1'; $env:TINVEST_TOKEN = 'test-token'
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -Command ". '$ENGINE' -Root '$Root' -NowMs $nowMs" 2>&1
  $env:TINVEST_MOCK_DIR = $null
  return ($out | Out-String)
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
    [pscustomobject]@{ id='op1'; instrumentUid='uid-NGQ6'; operationType='OPERATION_TYPE_BUY'; quantity='19'
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
    Check 'lost-repost: тот же идемпотентный order_key' ($k1 -eq $k2 -and $k1 -eq 'LRF-i00001-entry')
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

# --- 8. hard-dd: -35% от пика -> закрыть всё + HALT_RF_LIVE
function Scn-HardDd {
  $r = New-Scenario 'hard-dd'
  $s = New-BaseState $r
  $s.sleeves.core.positions = @(New-Card 'core' 'NG' 'NGQ6' 'uid-NGQ6' 'long' 19 2.905 2.676 7749.12)
  $s.sleeves.core.eq_rub = 420000.0   # rC = -0.4 -> profile_eq ~ 420k при peak 700k -> DD 40% > 35%
  $s.sleeves.core.equity_mtm = 420000.0
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'mock\OperationsService.GetPortfolio.json') ([pscustomobject]@{ positions = @(
    [pscustomobject]@{ instrumentUid='uid-NGQ6'; instrumentType='futures'; quantityLots=[pscustomobject]@{units='19';nano=0} } ) })
  Write-Json (Join-Path $r 'mock\StopOrdersService.GetStopOrders.json') ([pscustomobject]@{ stopOrders = @(
    [pscustomobject]@{ stopOrderId='stop-live-1' } ) })
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'hard-dd: все позиции закрыты' (@($st.sleeves.core.positions).Count -eq 0)
  Check 'hard-dd: HALT_RF_LIVE создан' (Test-Path (Join-Path $r 'data\HALT_RF_LIVE'))
  $out2 = Run-Tick $r '2026-07-15 11:01'
  Check 'hard-dd: следующий тик не торгует (halt-файл)' ($out2 -notmatch 'tick ok')
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

# --- 10. D4-confirmed: карточки нет у брокера, операция стопа есть -> штатное закрытие
function Scn-D4Confirmed {
  $r = New-Scenario 'd4-confirmed'
  $s = New-BaseState $r
  $s.sleeves.core.positions = @(New-Card 'core' 'NG' 'NGQ6' 'uid-NGQ6' 'long' 19 2.905 2.676 7749.12)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  Write-Json (Join-Path $r 'mock\OperationsService.GetOperations.json') ([pscustomobject]@{ operations = @(
    [pscustomobject]@{ id='op-stop'; instrumentUid='uid-NGQ6'; operationType='OPERATION_TYPE_SELL'; quantity='19'
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

# --- 11. D4-quarantine: позиции нет и операции нет -> карантин + халт
function Scn-D4Quarantine {
  $r = New-Scenario 'd4-quarantine'
  $s = New-BaseState $r
  $s.sleeves.core.positions = @(New-Card 'core' 'NG' 'NGQ6' 'uid-NGQ6' 'long' 19 2.905 2.676 7749.12)
  Write-Json (Join-Path $r 'data\live_rf\portfolio.json') $s
  [void](Run-Tick $r '2026-07-15 11:00')
  $st = Get-State $r
  Check 'D4-q: карточка в карантине' ([bool]@($st.sleeves.core.positions)[0].quarantine)
  Check 'D4-q: счётчик D4' ([int]$st.drift.D4 -eq 1)
  Check 'D4-q: entries_halt' ([bool]$st.entries_halt.active)
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
  [void](Run-Tick $r '2026-07-15 14:00')
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
    [pscustomobject]@{ id='op-tp'; instrumentUid='uid-NGQ6'; operationType='OPERATION_TYPE_SELL'; quantity='2'
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
      response=[pscustomobject]@{ orderId='ord-rc'; executionReportStatus='EXECUTION_REPORT_STATUS_FILL'
        executedOrderPrice=[pscustomobject]@{units='2';nano=900000000} } },
    [pscustomobject]@{ service='InstrumentsService'; method='FutureBy'; body_like='NGU6'
      response=[pscustomobject]@{ instrument=[pscustomobject]@{ uid='uid-NGU6'; figi='FUTNGU'; ticker='NGU6'; class_code='SPBFUT'; lot=1
        min_price_increment=[pscustomobject]@{units='0';nano=1000000}; api_trade_available_flag=$true; last_trade_date='2026-09-28T00:00:00Z' } } },
    [pscustomobject]@{ service='OrdersService'; method='PostOrder'; body_like='BUY'
      response=[pscustomobject]@{ orderId='ord-ro'; executionReportStatus='EXECUTION_REPORT_STATUS_FILL'
        executedOrderPrice=[pscustomobject]@{units='2';nano=950000000} } }
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
    [pscustomobject]@{ service='OrdersService'; method='PostOrder'; body_like='SELL'
      response=[pscustomobject]@{ orderId='ord-ms'; executionReportStatus='EXECUTION_REPORT_STATUS_FILL'
        executedOrderPrice=[pscustomobject]@{units='125';nano=0} } },
    [pscustomobject]@{ service='InstrumentsService'; method='ShareBy'; body_like='SBER'
      response=[pscustomobject]@{ instrument=[pscustomobject]@{ uid='uid-SBER'; figi='SSBER'; ticker='SBER'; class_code='TQBR'; lot=10
        min_price_increment=[pscustomobject]@{units='0';nano=10000000}; api_trade_available_flag=$true } } },
    [pscustomobject]@{ service='OrdersService'; method='PostOrder'; body_like='BUY'
      response=[pscustomobject]@{ orderId='ord-mb'; executionReportStatus='EXECUTION_REPORT_STATUS_FILL'
        executedOrderPrice=[pscustomobject]@{units='321';nano=0} } }
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
    [pscustomobject]@{ id='op-c'; instrumentUid='uid-NGQ6'; operationType='OPERATION_TYPE_BUY'; quantity='19'
      price=[pscustomobject]@{units='2';nano=908000000} } ) })
  [void](Run-Tick $r '2026-07-15 10:06')   # тик1: POSTED без id -> LOST -> adopt в том же тике полинга
  $st = Get-State $r
  Check 'crash: карточка восстановлена по операции' (@($st.sleeves.core.positions).Count -eq 1)
  Check 'crash: PostOrder НЕ дублировался' ((Get-Calls $r 'PostOrder').Count -eq 0)
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

# ================= запуск =================
$scenarios = @(
  ${function:Scn-EntryFill}, ${function:Scn-EntryReject}, ${function:Scn-EntryLostAdopt}, ${function:Scn-EntryLostRepost},
  ${function:Scn-Qty0}, ${function:Scn-GoCap}, ${function:Scn-GoTrim}, ${function:Scn-HardDd},
  ${function:Scn-D2}, ${function:Scn-D4Confirmed}, ${function:Scn-D4Quarantine}, ${function:Scn-D5},
  ${function:Scn-D6Repost}, ${function:Scn-D6Fail}, ${function:Scn-StocksDeficit}, ${function:Scn-StocksSurplus},
  ${function:Scn-ClearingGate}, ${function:Scn-Weekend}, ${function:Scn-HaltEntriesFile}, ${function:Scn-HaltCloseFile},
  ${function:Scn-FloodCap}, ${function:Scn-Tp1Sync}, ${function:Scn-RollFlow}, ${function:Scn-MomRebalance},
  ${function:Scn-CrashRecovery}, ${function:Scn-DryrunE2e}
)
foreach ($fn in $scenarios) { & $fn }
