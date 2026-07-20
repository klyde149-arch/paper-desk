# live_rf_engine.ps1 - LIVE-контур C3b на РЕАЛЬНОМ счёте Т-Инвестиций (фьючерсы FORTS + акции TQBR).
# Дизайн: docs\strategy\live_tinvest_design.md. Сигналы БАЙТ-В-БАЙТ = paper (общий код lib_rf_signals.ps1,
# те же данные MOEX ISS); отличается ТОЛЬКО исполнение: целые лоты, рубли через стоимость шага,
# реальные market-заявки, брокерские стоп-заявки, виртуальные sleeve-леджеры (база 700k на рукав)
# поверх одного счёта. Polling-first: каждый тик = полная сверка позиции+заявки+стоп-заявки (стримов нет).
# Money-safety инварианты:
#   1) write-ahead intents: состояние персистится ДО каждого мутирующего API-вызова (adopt после краша);
#   2) позиция никогда не живёт без брокерской стоп-заявки дольше одного тика (D6 -> перевзвод/аварийное закрытие);
#   3) мутирующие вызовы не ретраятся транспортом - только state machine с идемпотентным order_id;
#   4) фьючерсы на счёте - эксклюзив бота (чужая позиция = D2 -> аварийное закрытие); акции - bot-owned lots.
# Режимы: TINVEST_MODE = dryrun | sandbox | prod; mock-транспорт для тестов (TINVEST_MOCK_DIR).
param(
  [string]$Root = '',
  [long]$NowMs = 0,        # реальное UTC сейчас (мс); 0 = текущее. Тесты подают свой «час».
  [switch]$DryRun          # форс dryrun поверх TINVEST_MODE
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'lib_engine.ps1')
. (Join-Path $PSScriptRoot 'lib_rf_signals.ps1')
. (Join-Path $PSScriptRoot 'lib_tinvest.ps1')
$alertsLib = Join-Path $PSScriptRoot 'lib_alerts.ps1'
if (Test-Path $alertsLib) { . $alertsLib } else { function Send-TgAlert([string]$Text) { $false } }

# ================= конфиг live-контура =================
$LIVE = [ordered]@{
  base_rub          = 700000.0   # база каждого sleeve-леджера (решение пользователя 2026-07-15)
  core_risk         = 0.05       # C3b ядро
  seta_risk         = 0.02       # C3b setup A
  mom_weight        = 0.5        # mom покупает на 0.5 x mom_eq
  go_cap_pct        = 0.60       # свой стоп по ГО: вход запрещён выше (боевой нюанс #6)
  go_trim_pct       = 0.75       # выше - LIFO-закрытие последней позиции
  reserve_rub       = 50000.0    # неприкосновенный резерв вне ГО-бюджета
  profile_day_halt  = 0.08       # доп. предохранитель: профиль-день -8% -> entries_halt до завтра
  hard_dd           = 0.35       # АВАРИЙНЫЙ СТОП: -35% от пика -> закрыть всё + HALT_RF_LIVE (решение пользователя)
  max_orders_day    = 20         # предохранитель флуда (нюанс #11: сделки:заявки не хуже 1:10)
  max_attempts      = 3          # лимит попыток state machine на intent
  fee_est           = 0.0001     # оценка комиссии (модель paper 1bps) до аудита тарифа в Phase 1
  # ЕТС-2026 (боевой факт 2026-07-17): торги с 06:00-07:00 MSK (утренняя сессия), paper входит по
  # open ПЕРВОГО часовика дня -> live-вход с самого утра; TradingStatus-гейт держит интент до
  # реального открытия инструмента, окно широкое (до 10:15) на случай позднего старта.
  entry_from = '06:01'; entry_till = '10:15'   # окно входов/выходов «на открытии» (MSK)
  roll_from  = '06:05'; roll_till  = '18:00'   # окно роллов
  mom_from   = '06:10'                          # mom-ребаланс
  report_at  = '19:30'                          # дневной отчёт
  whitelist  = @()               # Phase 3: @('CNY','NG'); пусто = весь универсум
  max_lots_override = 0          # Phase 3: 1 (0 = без лимита)
  mom_enabled = $true            # Phase 3: $false
  trade_weekends = $false        # выходные внебиржевые сессии НЕ торгуем (нюанс #8)
  emulate_stops = $false         # sandbox: StopOrders нет -> бот-сайд эмуляция по LastPrices
  # авто-финансирование (решение пользователя 2026-07-17): рублей на счёте почти нет, ликвидность
  # лежит в USD и серебре; перед сделкой бот продаёт funding-инструменты НА НУЖНУЮ СУММУ.
  # Список uid в порядке приоритета продажи. USD (CNGDOTC) через API НЕ торгуется - при нехватке
  # сверх funding-пула бот шлёт Telegram-алерт «продайте вручную».
  funding = @()
}
# клиринговые паузы MSK. Боевой факт 2026-07-17 (TradingSchedules + бары ISS): в ЕТС промежуточных
# клирингов НЕТ, только ночной 23:50-00:30 (интервал clearing 20:50-21:30Z).
$CLEARING = @(@('23:48','23:59'), @('00:00','00:32'))

$lrfDir = Join-Path $Root 'data\live_rf'
$serDir = Join-Path $lrfDir 'series'   # СОБСТВЕННЫЕ серии live-контура (lib_rf_signals читает $serDir)
if (-not (Test-Path $serDir)) { New-Item -ItemType Directory -Force $serDir | Out-Null }
# внешний конфиг-оверрайд (фазы запуска меняют лимиты без правки кода)
$cfgPath = Join-Path $lrfDir 'config.json'
$cfgOvr = Read-JsonFile $cfgPath
if ($null -ne $cfgOvr) { foreach ($p in $cfgOvr.PSObject.Properties) { $LIVE[$p.Name] = $p.Value } }

if ($NowMs -le 0) { $NowMs = UtcNowMs }
$mskNowMs = $NowMs + $MSK
$mskToday = MsToUtcDay $mskNowMs
$mskHHmm = (MsToUtc $mskNowMs).ToString('HH:mm')
$completedDay = Get-RfCompletedDay $mskNowMs

$script:ev = New-Object System.Collections.Generic.List[string]     # события тика (лог)
$script:jr = New-Object System.Collections.Generic.List[string]     # журнал (journal_live_rf.md)
$mode = if ($DryRun) { 'dryrun' } else { if ($env:TINVEST_MODE) { ([string]$env:TINVEST_MODE).ToLower() } else { 'dryrun' } }
Initialize-TInvest $lrfDir $mode

function Write-LiveLog([string]$Line) {
  $p = Join-Path $lrfDir 'tick_log.txt'
  $stamp = (MsToUtc $NowMs).ToString('yyyy-MM-dd HH:mm:ss')
  [IO.File]::AppendAllText($p, "$stamp`Z $Line`r`n", (New-Object System.Text.UTF8Encoding($false)))
  try { $fi = Get-Item $p; if ($fi.Length -gt 500KB) {
    $tail = Get-Content $p -Tail 2000; Set-Content $p $tail -Encoding UTF8 } } catch {}
}
function Write-LiveJournal([string]$Text) {
  [IO.File]::AppendAllText((Join-Path $Root 'journal_live_rf.md'), $Text, (New-Object System.Text.UTF8Encoding($false)))
}
function Alert([string]$Text) {
  $script:ev.Add("ALERT $Text")
  try { Send-TgAlert "RF-LIVE: $Text" | Out-Null } catch {}
  # фан-аут второму получателю (только фьючерсы) - если задан TG_CHAT_ID_FUT
  if ($env:TG_CHAT_ID_FUT) { try { Send-TgAlert "RF-LIVE: $Text" -Chat $env:TG_CHAT_ID_FUT | Out-Null } catch {} }
}

# ================= состояние =================
$stPath = Join-Path $lrfDir 'portfolio.json'
function New-LiveSleeveFut { [pscustomobject]@{ eq_rub = [double]$LIVE.base_rub; month_start_eq = [double]$LIVE.base_rub
  day_start_eq = [double]$LIVE.base_rub; halt_day = $null; positions = @(); equity_mtm = [double]$LIVE.base_rub } }
$st = Read-JsonFile $stPath
if ($null -eq $st) {
  # первичная инициализация: серии = копия paper-серий (та же непрерывная склейка => те же сигналы),
  # фолбэк - канонические склейки data\moex_fut / data\moex
  foreach ($a in $ASSETS) {
    $src = Join-Path $Root "data\rf\series\$a.json"
    if (-not (Test-Path $src)) { $src = Join-Path $Root "data\moex_fut\$($a)_1d.json" }
    Copy-Item $src (Join-Path $serDir "$a.json") -Force
  }
  foreach ($t in @($TICKERS) + @('IMOEX')) {
    $src = Join-Path $Root "data\rf\series\$t.json"
    if (-not (Test-Path $src)) { $src = Join-Path $Root "data\moex\$($t)_1d.json" }
    Copy-Item $src (Join-Path $serDir "$t.json") -Force
  }
  $initDaily = (MsToUtc ((UtcStrToMs "$completedDay 00:00") - $DAY)).ToString('yyyy-MM-dd')
  $st = [pscustomobject]@{
    schema = 1; mode = $mode; account_id = [string]$env:TINVEST_ACCOUNT_ID
    meta = [pscustomobject]@{ profile = 'C3b-live'; created = (MsToUtcStr $NowMs); base_rub = [double]$LIVE.base_rub
      core_risk = [double]$LIVE.core_risk; seta_risk = [double]$LIVE.seta_risk; mom_weight = [double]$LIVE.mom_weight }
    sleeves = [pscustomobject]@{
      core = (New-LiveSleeveFut); setA = (New-LiveSleeveFut)
      # mom-леджер = base x mom_weight, инвестируется ЦЕЛИКОМ (эквивалент paper: полный sleeve с весом
      # 0.5 в профиле; вкладывать половину от полной базы и снова взвешивать 0.5 - двойное занижение)
      mom = [pscustomobject]@{ eq_rub = [double]$LIVE.base_rub * [double]$LIVE.mom_weight
        month_start_eq = [double]$LIVE.base_rub * [double]$LIVE.mom_weight
        cash_rub = [double]$LIVE.base_rub * [double]$LIVE.mom_weight; holdings = @(); last_rebalance_month = ''
        equity_mtm = [double]$LIVE.base_rub * [double]$LIVE.mom_weight } }
    profile_eq = [double]$LIVE.base_rub; profile_month_start = [double]$LIVE.base_rub; cur_month = ''
    day_start_eq = [double]$LIVE.base_rub; day_start_date = ''; peak_eq = [double]$LIVE.base_rub
    watermarks = [pscustomobject]@{ last_daily_day = $initDaily; last_hour_ts = (UtcStrToMs "$completedDay 23:00")
      ops_since = (MsToUtc $NowMs).ToString('yyyy-MM-ddTHH:mm:ssZ'); last_eq_snap = [long]0
      last_report_day = ''; orders_day = ''; orders_day_n = 0 }
    fronts = $null; active = $null; rearm = [pscustomobject]@{}
    entries_halt = [pscustomobject]@{ active = $false; reason = ''; since = '' }
    go = [pscustomobject]@{ used_rub = 0.0; budget_rub = 0.0; peak_day_rub = 0.0 }
    drift = [pscustomobject]@{ D2 = 0; D4 = 0; D5 = 0; D6 = 0; stocks_deficit = 0; last = '' }
    pending_intents = @()
    next_intent_id = 1
    # соль идемпотентных order_id: intent-id стартуют с 1 в каждом новом state, а ключи у брокера
    # глобальны во времени -> без соли пересозданный state ловит «duplicate» на легитимные заявки
    # (боевой факт песочницы 2026-07-17)
    run_key = ([guid]::NewGuid().ToString('N'))
    stats = [pscustomobject]@{ trades = 0; orders_posted = 0; fills = 0; wins = 0; losses = 0
      fees_rub = 0.0; realized_rub = 0.0; skipped_qty0 = 0; signal_mismatch = 0 }
  }
  Write-LiveLog "LIVE-RF: state initialized (mode=$mode, base=$($LIVE.base_rub))"
}
# null-чистка списков после ConvertFrom-Json (PS 5.1: '[]' -> $null)
foreach ($sn in 'core','setA') { $sl = $st.sleeves.$sn
  $sl.positions = ToArr (@($sl.positions) | Where-Object { $null -ne $_ }) }
$st.sleeves.mom.holdings = ToArr (@($st.sleeves.mom.holdings) | Where-Object { $null -ne $_ })
$st.pending_intents = ToArr (@($st.pending_intents) | Where-Object { $null -ne $_ })

function Save-State { Write-JsonAtomic $stPath $st 12 }

# ================= инструменты (кэш 24ч) =================
$instPath = Join-Path $lrfDir 'instruments.json'
$script:INST = Read-JsonFile $instPath
if ($null -eq $script:INST) { $script:INST = [pscustomobject]@{} }
function Get-Inst([string]$Ticker, [string]$Kind) {
  # kind: fut|share; кэш по тикеру (для фьючей тикер = SECID контракта)
  $rec = if ($script:INST.PSObject.Properties[$Ticker]) { $script:INST.$Ticker } else { $null }
  $fresh = $false
  if ($null -ne $rec -and $rec.PSObject.Properties['refreshed']) {
    $fresh = ((UtcStrToMs ([string]$rec.refreshed)) -gt ($NowMs - 24 * 3600000))
  }
  if ($null -ne $rec -and $fresh) { return $rec }
  $info = Get-TiInstrument $Ticker $Kind
  Assert-Tradeable $info $Kind | Out-Null
  $rec = [pscustomobject]@{
    ticker = $Ticker; kind = $Kind; uid = [string]$info.uid; figi = [string]$info.figi
    lot = [int]$info.lot
    min_price_increment = [double](Q2D (Get-TiField $info 'min_price_increment'))
    rub_per_pt = 0.0; go_buy = 0.0; go_sell = 0.0
    last_trade_date = ''; expiration = ''
    refreshed = (MsToUtcStr $NowMs)
  }
  if ($Kind -eq 'fut') {
    if ($info.PSObject.Properties['last_trade_date']) { $rec.last_trade_date = ([string]$info.last_trade_date).Substring(0,10) }
    elseif ($info.PSObject.Properties['lastTradeDate']) { $rec.last_trade_date = ([string]$info.lastTradeDate).Substring(0,10) }
    $m = Get-TiFuturesMargin $rec.uid
    $rec.go_buy = [double](M2D $m.initial_margin_on_buy).value
    if ($rec.go_buy -eq 0 -and $m.PSObject.Properties['initialMarginOnBuy']) { $rec.go_buy = [double](M2D $m.initialMarginOnBuy).value }
    $rec.go_sell = [double](M2D $m.initial_margin_on_sell).value
    if ($rec.go_sell -eq 0 -and $m.PSObject.Properties['initialMarginOnSell']) { $rec.go_sell = [double](M2D $m.initialMarginOnSell).value }
    $amt = Get-TiField $m 'min_price_increment_amount'
    $inc = [double](Q2D (Get-TiField $info 'min_price_increment'))
    $rec.rub_per_pt = if ($inc -gt 0) { [double](Q2D $amt) / $inc } else { 0.0 }
    if ($rec.rub_per_pt -le 0) { throw "инструмент ${Ticker}: не удалось получить стоимость шага (rub_per_pt)" }
  } else {
    $rec.rub_per_pt = 1.0   # акции: цена уже в рублях
  }
  if ($script:INST.PSObject.Properties[$Ticker]) { $script:INST.$Ticker = $rec }
  else { $script:INST | Add-Member -NotePropertyName $Ticker -NotePropertyValue $rec }
  Write-JsonAtomic $instPath $script:INST 6
  return $rec
}

# ================= время/сессии =================
function In-Window([string]$From, [string]$Till) { return ($mskHHmm -ge $From -and $mskHHmm -le $Till) }
function Test-Weekend {
  $dow = (MsToUtc $mskNowMs).DayOfWeek
  return ($dow -eq [DayOfWeek]::Saturday -or $dow -eq [DayOfWeek]::Sunday)
}
function Test-Clearing {
  foreach ($w in $CLEARING) { if ($mskHHmm -ge $w[0] -and $mskHHmm -le $w[1]) { return $true } }
  return $false
}
# постановка заявок разрешена: будни, не клиринг, утро+осн.+веч. сессия (ЕТС: торги с ~06:00 MSK)
function Can-PostOrders {
  if ((Test-Weekend) -and -not $LIVE.trade_weekends) { return $false }
  if (Test-Clearing) { return $false }
  return ($mskHHmm -ge '06:00' -and $mskHHmm -le '23:47')
}
# инструмент реально торгуется сейчас? (утренний старт плавает: гейт держит интенты до открытия)
$script:tradingStatusCache = @{}
function Test-InstrumentTrading([string]$Uid) {
  if ($script:tradingStatusCache.ContainsKey($Uid)) { return $script:tradingStatusCache[$Uid] }
  $ok = $false
  try {
    $r = Get-TiTradingStatus $Uid
    $stt = [string](Get-TiField $r 'trading_status')
    $ok = ($stt -eq 'SECURITY_TRADING_STATUS_NORMAL_TRADING')
  } catch { $ok = $false }   # сбой статуса -> подождать следующего тика (интент живёт до конца окна)
  $script:tradingStatusCache[$Uid] = $ok
  return $ok
}

# ================= intents (write-ahead state machine) =================
function New-Intent([string]$Kind, [hashtable]$Fields) {
  $id = 'i{0:d5}' -f [int]$st.next_intent_id
  $st.next_intent_id = [int]$st.next_intent_id + 1
  $it = [pscustomobject]@{
    id = $id; kind = $Kind; sleeve = ''; asset = ''; ticker = ''; uid = ''
    side = ''; lots = 0; filled_lots = 0; avg_fill_px = $null
    order_key = ''; broker_order_id = ''
    state = 'INTENT'; attempts = 0
    t_signal = [long]0; t_post = [long]0; t_ack = [long]0; t_fill = [long]0
    created_day = $mskToday; state_ts = $NowMs; last_error = ''
    ctx = $null
  }
  foreach ($k in $Fields.Keys) { $it.$k = $Fields[$k] }
  if (-not $st.PSObject.Properties['run_key'] -or -not $st.run_key) {
    $st | Add-Member -NotePropertyName run_key -NotePropertyValue ([guid]::NewGuid().ToString('N')) -Force
  }
  $it.order_key = New-TiOrderKey "$($st.run_key)|$id" ($Kind -replace '_','')
  $st.pending_intents = ToArr (@($st.pending_intents) + $it)
  return $it
}
function Set-IntentState($It, [string]$State, [string]$Err = '') {
  $It.state = $State; $It.state_ts = $NowMs
  if ($Err) { $It.last_error = $Err }
}
function Remove-Intent($It) {
  $st.pending_intents = ToArr (@($st.pending_intents) | Where-Object { $_.id -ne $It.id })
}
function Count-OrdersToday {
  if ([string]$st.watermarks.orders_day -ne $mskToday) { $st.watermarks.orders_day = $mskToday; $st.watermarks.orders_day_n = 0 }
  return [int]$st.watermarks.orders_day_n
}
function Bump-OrdersToday {
  [void](Count-OrdersToday)
  $st.watermarks.orders_day_n = [int]$st.watermarks.orders_day_n + 1
  $st.stats.orders_posted = [int]$st.stats.orders_posted + 1
}
function Set-EntriesHalt([string]$Reason) {
  if (-not $st.entries_halt.active) {
    $st.entries_halt.active = $true; $st.entries_halt.reason = $Reason; $st.entries_halt.since = MsToUtcStr $NowMs
    Alert "entries_halt: $Reason"
  }
}

# цена филла ЗА ЕДИНИЦУ из ответа PostOrder/GetOrderState. Боевой факт (песочница 2026-07-17):
# executed_order_price = ИТОГО в РУБЛЯХ за все лоты; пунктовая сумма фьючерса - initial_order_price_pt.
# Фьючерс -> пункты за 1 лот; акция -> рубли за 1 акцию. $null = не распарсилось (падаем на референс).
function Get-FillPxPerUnit($It, $Resp, [int]$Lots) {
  if ($Lots -le 0 -or $null -eq $Resp) { return $null }
  $isShare = ([string]$It.kind -like 'mom_*')
  try {
    if (-not $isShare) {
      $ptTot = [double](Q2D (Get-TiField $Resp 'initial_order_price_pt'))
      if ($ptTot -gt 0) { return [math]::Round($ptTot / $Lots, 6) }
    }
    $totRub = [double](M2D (Get-TiField $Resp 'executed_order_price')).value
    if ($totRub -le 0) { return $null }
    $inst = Get-Inst ([string]$It.ticker) $(if ($isShare) { 'share' } else { 'fut' })
    if ($isShare) { return [math]::Round($totRub / $Lots / [double]$inst.lot, 6) }
    if ([double]$inst.rub_per_pt -gt 0) { return [math]::Round($totRub / $Lots / [double]$inst.rub_per_pt, 6) }
  } catch {}
  return $null
}

# постановка market-заявки для intent (write-ahead: Save-State ДО вызова API)
function Post-IntentMarket($It, [string]$Dir, [int]$Lots) {
  if ((Count-OrdersToday) -ge [int]$LIVE.max_orders_day) { Set-EntriesHalt "orders/day > $($LIVE.max_orders_day)"; return $false }
  $It.attempts = [int]$It.attempts + 1
  $It.t_post = $NowMs
  Set-IntentState $It 'POSTED'
  Save-State                       # write-ahead: intent в POSTED до сети
  Bump-OrdersToday
  $r = $null
  try { $r = Post-TiMarketOrder ([string]$st.account_id) ([string]$It.uid) $Dir $Lots ([string]$It.order_key) }
  catch {
    # Отказ брокера - судьба ИНТЕНТА, а не смерть тика. Инцидент 2026-07-20: HTTP 400 на
    # funding_sell (серебро) валил каждый тик с 07:00 MSK и замораживал state machine.
    $emsg = [string]$_.Exception.Message
    if ($emsg -match '^TINVEST_HTTP_4') {
      Set-IntentState $It 'REJECTED' $emsg
      $script:ev.Add("REJECTED(4xx) $($It.id) $($It.kind) $($It.ticker)")
      Alert "заявка $($It.id) $($It.kind) $($It.ticker) отклонена брокером: $emsg"
    } else {
      # 5xx/неожиданное: заявка МОГЛА встать у брокера - LOST, adopt/repost разберётся
      Set-IntentState $It 'LOST' $emsg
      $script:ev.Add("LOST(err) $($It.id) $($It.kind) $($It.ticker)")
    }
    return $false
  }
  $It.t_ack = if ($NowMs -eq $It.t_post) { $NowMs + 1 } else { $NowMs }
  if ($null -ne $r -and $r.PSObject.Properties['__lost'] -and $r.__lost) {
    Set-IntentState $It 'LOST' ([string]$r.error)
    $script:ev.Add("LOST $($It.id) $($It.kind) $($It.ticker)")
    return $false
  }
  if ($null -ne $r -and $r.PSObject.Properties['__dup'] -and $r.__dup) {
    # заявка уже была принята ранее (идемпотентный повтор) - ждём подтверждения через operations
    Set-IntentState $It 'LOST' 'dup: заявка уже принята, ждём операцию'
    $script:ev.Add("DUP $($It.id) $($It.kind) $($It.ticker) - adopt по операциям")
    return $true
  }
  if ($null -ne $r -and $r.PSObject.Properties['orderId']) { $It.broker_order_id = [string]$r.orderId }
  if ($null -ne $r -and $r.PSObject.Properties['__dryrun'] -and $r.__dryrun) {
    # DRYRUN: внутренняя симуляция - немедленный филл по референс-цене (реального брокера нет)
    $It.filled_lots = [int]$It.filled_lots + $Lots
    if ($null -ne $It.ctx -and $It.ctx.PSObject.Properties['ref_px'] -and [double]$It.ctx.ref_px -gt 0) { $It.avg_fill_px = [double]$It.ctx.ref_px }
    $It.t_fill = $NowMs
    Set-IntentState $It 'FILLED'
    Complete-IntentIfFilled $It
    return $true
  }
  $phase = if ($null -ne $r -and $r.PSObject.Properties['executionReportStatus']) { ConvertTo-TiOrderPhase ([string]$r.executionReportStatus) } else { 'POSTED' }
  if ($phase -eq 'FILLED') {
    $execLots = $Lots
    try { $le = Get-TiField $r 'lots_executed'; if ($null -ne $le -and [int]$le -gt 0) { $execLots = [int]$le } } catch {}
    $It.filled_lots = [int]$It.filled_lots + $execLots   # добор партиала не затирает ранние филлы
    $px = Get-FillPxPerUnit $It $r $execLots
    if ($null -ne $px -and $px -gt 0) { $It.avg_fill_px = $px }
    $It.t_fill = $NowMs
    Set-IntentState $It 'FILLED'
    Complete-IntentIfFilled $It   # немедленно: стоп-заявка должна встать в ТОМ ЖЕ тике (инвариант #2)
  } elseif ($phase -eq 'REJECTED') {
    Set-IntentState $It 'REJECTED' 'broker rejected'
  }
  return $true
}

# применение исполненного intent'а к леджеру/карточкам (общая точка для немедленного филла и полинга)
function Complete-IntentIfFilled($It) {
  if ([string]$It.state -ne 'FILLED') { return }
  if ($It.PSObject.Properties['applied'] -and $It.applied) { return }
  $It | Add-Member -NotePropertyName applied -NotePropertyValue $true -Force
  Apply-FilledIntent $It
  Remove-Intent $It
}

# ================= леджер / карточки позиций =================
function Get-SleeveRef([string]$Name) { return $st.sleeves.$Name }
function Close-CardLedger($Card, [double]$ExitPx, [string]$Reason, [double]$FeeRub) {
  $sl = Get-SleeveRef ([string]$Card.sleeve)
  $sm = if ($Card.side -eq 'long') { 1.0 } else { -1.0 }
  $pnl = $sm * [double]$Card.lots * ($ExitPx - [double]$Card.entry_px_pts) * [double]$Card.rub_per_pt - $FeeRub
  $sl.eq_rub = [double]$sl.eq_rub + $pnl
  $net = [math]::Round($pnl + [double]$Card.realized_rub, 2)
  $st.stats.trades = [int]$st.stats.trades + 1
  if ($net -gt 0) { $st.stats.wins = [int]$st.stats.wins + 1 } else { $st.stats.losses = [int]$st.stats.losses + 1 }
  $st.stats.fees_rub = [math]::Round([double]$st.stats.fees_rub + $FeeRub + [double]$Card.fees_rub, 2)
  $st.stats.realized_rub = [math]::Round([double]$st.stats.realized_rub + $net, 2)
  $st.stats.fills = [int]$st.stats.fills + 1
  # трейд-лог
  $rec = [pscustomobject]@{
    id = $Card.id; sleeve = $Card.sleeve; asset = $Card.asset; secid = $Card.secid; side = $Card.side
    entryDay = $Card.entry_day; entry = [double]$Card.entry_px_pts; lots = [int]$Card.lots_initial
    exitDay = $mskToday; exitUtc = (MsToUtcStr $NowMs); exitPx = [math]::Round($ExitPx, 6)
    exitReason = $Reason; pnlRub = $net
    rMultiple = if ([double]$Card.risk_rub -gt 0) { [math]::Round($net / [double]$Card.risk_rub, 2) } else { $null }
    riskRub = [double]$Card.risk_rub; feesRub = [math]::Round($FeeRub + [double]$Card.fees_rub, 2)
    rolls = [int]$Card.rolls
    latency = [pscustomobject]@{ signal_to_post_ms = $Card.lat_sp; post_to_fill_ms = $Card.lat_pf }
  }
  $tPath = Join-Path $lrfDir 'trades.json'
  $tr = New-Object System.Collections.Generic.List[object]
  foreach ($x in @((Read-JsonFile $tPath))) { if ($null -ne $x) { $tr.Add($x) } }
  $tr.Add($rec)
  Write-JsonAtomic $tPath (ToArr $tr) 8
  $sl.positions = ToArr (@($sl.positions) | Where-Object { $_.id -ne $Card.id })
  # re-arm окно ядра (как paper)
  if ([string]$Card.sleeve -eq 'core' -and $Reason -ne 'roll') {
    $key = "c3b_$($Card.asset)"
    $val = [pscustomobject]@{ exit_day = $mskToday; dir = $Card.side }
    if ($st.rearm.PSObject.Properties[$key]) { $st.rearm.$key = $val }
    else { $st.rearm | Add-Member -NotePropertyName $key -NotePropertyValue $val }
  }
  $script:ev.Add("EXIT [$($Card.sleeve)] $($Card.id) $($Card.asset) $Reason $net")
  $script:jr.Add(("`r`n## {0} MSK — RF-LIVE [{1}]: закрыта {2} {3} {4} — {5:+0.00;-0.00} ₽ ({6})`r`n" -f (MsToUtcStr $mskNowMs), $Card.sleeve, $Card.id, $Card.asset, $Card.side.ToUpper(), $net, $Reason))
  # дневной халт рукава -6% (как paper: снимает только ВХОДЫ, позиции живут)
  $dl = ([double]$sl.day_start_eq - [double]$sl.eq_rub) / [double]$sl.day_start_eq
  if ($dl -ge $HALT_PCT -and [string]$sl.halt_day -ne $mskToday) {
    $sl.halt_day = $mskToday
    foreach ($it in @($st.pending_intents | Where-Object { $_.kind -eq 'entry' -and $_.sleeve -eq $Card.sleeve -and $_.state -eq 'INTENT' })) { Set-IntentState $it 'CANCELLED' 'sleeve day-halt' }
    $script:ev.Add("DAY-HALT [$($Card.sleeve)] -$([math]::Round(100*$dl,1))%")
  }
}

# ================= стоп-менеджмент =================
function Post-CardStop($Card) {
  # stop-market противоположного направления на все лоты карточки; инвариант: не живём без стопа
  $dir = if ($Card.side -eq 'long') { 'sell' } else { 'buy' }
  $inst = Get-Inst ([string]$Card.secid) 'fut'
  $px = Round-ToIncrement ([decimal][double]$Card.stop_px_pts) ([pscustomobject]@{
    min_price_increment = [pscustomobject](D2Q ([decimal][double]$inst.min_price_increment)) })
  for ($try = 1; $try -le 3; $try++) {
    $r = $null
    try { $r = Post-TiStopOrder ([string]$st.account_id) ([string]$Card.uid) $dir ([int]$Card.lots) $px 'stop_loss' }
    catch { Write-LiveLog "PostStopOrder $($Card.id) (попытка $try): $($_.Exception.Message)" }
    if ($null -ne $r -and -not ($r.PSObject.Properties['__lost'] -and $r.__lost)) {
      $sid = if ($r.PSObject.Properties['stopOrderId']) { [string]$r.stopOrderId } else { '' }
      $Card.stop_order_id = $sid
      $Card.stop_lots = [int]$Card.lots
      $Card.last_stop_update = MsToUtcStr $NowMs
      return $true
    }
  }
  return $false
}
function Ensure-CardStop($Card, $BrokerStopIds) {
  # D6-watchdog: карточка без живой стоп-заявки -> немедленный перевзвод; 2 подряд неудачи -> аварийное закрытие
  if ($LIVE.emulate_stops) { return $true }   # sandbox: стопы эмулируются в Run-HourlyPass
  if ([string]$Card.stop_order_id -and $BrokerStopIds.ContainsKey([string]$Card.stop_order_id)) { return $true }
  $st.drift.D6 = [int]$st.drift.D6 + 1
  $st.drift.last = "D6 $($Card.id) $($Card.asset)"
  $ok = Post-CardStop $Card
  if ($ok) { $script:ev.Add("D6 перевзвод стопа $($Card.id) $($Card.asset)"); $Card.d6_fails = 0; return $true }
  $Card.d6_fails = [int]$Card.d6_fails + 1
  Alert "D6: не удалось перевыставить стоп $($Card.id) $($Card.asset) (попытка $($Card.d6_fails))"
  if ([int]$Card.d6_fails -ge 2) {
    Invoke-EmergencyClose $Card 'no-stop'
  }
  return $false
}
function Replace-CardStop($Card, [double]$NewStopPts) {
  # трейл: Cancel + Post через write-ahead intent kind=stop_replace (голое окно <= секунды)
  if ($LIVE.emulate_stops) { $Card.stop_px_pts = [math]::Round($NewStopPts, 6); return $true }
  if (-not (Can-PostOrders)) {
    # вне сессии/клиринг: отложить - положим намерение в карточку, батч в 09:45+
    $Card.stop_deferred = [math]::Round($NewStopPts, 6)
    return $false
  }
  $it = New-Intent 'stop_replace' @{ sleeve = [string]$Card.sleeve; asset = [string]$Card.asset
    ticker = [string]$Card.secid; uid = [string]$Card.uid; side = [string]$Card.side; lots = [int]$Card.lots
    ctx = [pscustomobject]@{ card_id = [string]$Card.id; new_stop = [math]::Round($NewStopPts, 6) } }
  Save-State
  if ([string]$Card.stop_order_id) {
    $rc = $null
    try { $rc = Cancel-TiStopOrder ([string]$st.account_id) ([string]$Card.stop_order_id) }
    catch {
      # 4xx на отмене (например, стоп уже исполнился/снят) - как cancel lost: D6 следующего тика разрулит
      Write-LiveLog "Cancel stop $($Card.id): $($_.Exception.Message)"
      Set-IntentState $it 'LOST' "cancel: $($_.Exception.Message)"
      return $false
    }
    if ($null -ne $rc -and $rc.PSObject.Properties['__lost'] -and $rc.__lost) {
      # отмена потерялась: стоп либо жив, либо отменён - D6-watchdog следующего тика разрулит
      Set-IntentState $it 'LOST' 'cancel lost'
      return $false
    }
  }
  $Card.stop_px_pts = [math]::Round($NewStopPts, 6)
  $Card.stop_order_id = ''
  $ok = Post-CardStop $Card
  if ($ok) { Set-IntentState $it 'FILLED'; Remove-Intent $it }
  else {
    Set-IntentState $it 'REJECTED' 'post stop failed'
    Alert "stop_replace не удался $($Card.id) $($Card.asset) - аварийное закрытие"
    Invoke-EmergencyClose $Card 'stop-replace-fail'
  }
  return $ok
}
function Invoke-EmergencyClose($Card, [string]$Why) {
  # аварийное закрытие: cancel стопа + market в обратную сторону (write-ahead)
  $script:ev.Add("EMERGENCY CLOSE $($Card.id) $($Card.asset) ($Why)")
  Alert "аварийное закрытие $($Card.id) $($Card.asset): $Why"
  if ([string]$Card.stop_order_id -and -not $LIVE.emulate_stops) {
    try { Cancel-TiStopOrder ([string]$st.account_id) ([string]$Card.stop_order_id) | Out-Null } catch {}
  }
  $dir = if ($Card.side -eq 'long') { 'sell' } else { 'buy' }
  $it = New-Intent 'emergency_close' @{ sleeve = [string]$Card.sleeve; asset = [string]$Card.asset
    ticker = [string]$Card.secid; uid = [string]$Card.uid; side = $dir; lots = [int]$Card.lots
    ctx = [pscustomobject]@{ card_id = [string]$Card.id; why = $Why } }
  [void](Post-IntentMarket $it $dir ([int]$Card.lots))
  Set-EntriesHalt "emergency close $($Card.id): $Why"
}

# ================= авто-финансирование (продажа USD/серебра под сделку) =================
function Get-FreeRub {
  try {
    $ps = Get-TiPositions ([string]$st.account_id)
    foreach ($m in @($ps.money)) {
      if ($null -eq $m) { continue }
      $v = M2D $m
      if ([string]$v.currency -eq 'rub') { return [double]$v.value }
    }
  } catch { Write-LiveLog "Get-FreeRub: $($_.Exception.Message)" }
  return 0.0
}
$script:instUidCache = @{}
function Get-InstUid([string]$Uid) {
  if ($script:instUidCache.ContainsKey($Uid)) { return $script:instUidCache[$Uid] }
  $i = Get-TiInstrumentByUid $Uid
  $script:instUidCache[$Uid] = $i
  return $i
}
# Обеспечить NeedRub свободных рублей: продать funding-инструменты (конфиг, приоритет по порядку)
# ровно на дефицит. false = рублей пока нет (интент останется INTENT и ретраится следующим тиком).
function Ensure-RubFunding([double]$NeedRub, [string]$Why) {
  $free = Get-FreeRub
  if ($free -ge $NeedRub) { return $true }
  if ($mode -eq 'dryrun') { return $true }   # dryrun: финансирование виртуально
  $deficit = $NeedRub - $free
  $soldAny = $false
  foreach ($fu in @($LIVE.funding)) {
    if ($deficit -le 0) { break }
    $uid = [string]$fu
    # уже висит непогашенная funding-продажа? не дублировать
    if (@($st.pending_intents | Where-Object { $_.kind -eq 'funding_sell' -and $_.uid -eq $uid -and $_.state -in @('INTENT','POSTED','PARTIAL','LOST') }).Count) { $soldAny = $true; continue }
    $inst = $null
    try { $inst = Get-InstUid $uid } catch { Write-LiveLog "funding: инструмент $uid недоступен: $($_.Exception.Message)"; continue }
    $apiOk = (Get-TiField $inst 'api_trade_available_flag')
    if ($apiOk -ne $true) { Write-LiveLog "funding: $($inst.ticker) api_trade=false - пропуск"; continue }
    $lotSize = [double]$inst.lot
    # сколько есть у пользователя
    $availLots = 0.0
    try {
      $pfF = Get-TiPortfolio ([string]$st.account_id)
      foreach ($p in @($pfF.positions)) {
        if ($null -ne $p -and [string](Get-TiField $p 'instrument_uid') -eq $uid) { $availLots = [double](Q2D (Get-TiField $p 'quantity_lots')) }
      }
    } catch {}
    if ($availLots -lt 1) { continue }
    $px = 0.0
    try {
      foreach ($lp in (Get-TiLastPrices @($uid))) { if ($null -ne $lp) { $px = [double](Q2D $lp.price) } }
    } catch {}
    if ($px -le 0) { continue }
    $lotRub = $px * $lotSize
    $sellLots = [math]::Ceiling($deficit / $lotRub)
    if ($sellLots -gt $availLots) { $sellLots = [math]::Floor($availLots) }
    if ($sellLots -lt 1) { continue }
    $it = New-Intent 'funding_sell' @{ sleeve = 'funding'; asset = [string]$inst.ticker; ticker = [string]$inst.ticker
      uid = $uid; side = 'sell'; lots = [int]$sellLots
      ctx = [pscustomobject]@{ why = $Why; ref_px = $px; lot_rub = [math]::Round($lotRub, 2) } }
    Save-State
    $script:ev.Add("FUNDING SELL $($inst.ticker) $sellLots лот (~$([math]::Round($sellLots*$lotRub,0)) ₽) для: $Why")
    [void](Post-IntentMarket $it 'sell' ([int]$sellLots))
    $soldAny = $true
    $deficit -= $sellLots * $lotRub * 0.995
  }
  if ($soldAny) {
    Start-Sleep -Seconds 3   # внутренние конверсии зачисляются быстро; иначе вход ретраится тиком
    if ((Get-FreeRub) -ge $NeedRub) { return $true }
  }
  # рублей всё ещё не хватает: троттленный алерт (не чаще раза в час) - доллары продаются только вручную
  $lastAl = if ($st.PSObject.Properties['last_funding_alert']) { [long]$st.last_funding_alert } else { [long]0 }
  if (($NowMs - $lastAl) -gt 3600000) {
    $st | Add-Member -NotePropertyName last_funding_alert -NotePropertyValue $NowMs -Force
    Alert ("не хватает рублей под '{0}': нужно ~{1} ₽, свободно {2} ₽. Продайте USD вручную в приложении (через API внутренний обмен недоступен)." -f $Why, [math]::Round($NeedRub, 0), [math]::Round($free, 0))
  }
  return $false
}

# ================= ГО-бюджет =================
function Update-GoBudget($Margin) {
  # бюджет = ликвидный портфель - стоимость bot-акций - резерв.
  # $Margin: объект MarginAttributes ЛИБО @{ liquid; used=$null } из GetPortfolio-фолбэка
  # (в песочнице MarginAttributes нет - 404, боевой факт 2026-07-17; used тогда = Σ ГО карточек)
  if ($null -ne $Margin) {
    $liquid = 0.0
    $lp = Get-TiField $Margin 'liquid_portfolio'
    if ($null -ne $lp) { $liquid = [double](M2D $lp).value }
    elseif ($Margin.PSObject.Properties['liquid']) { $liquid = [double]$Margin.liquid }
    # снапшот РЕАЛЬНОГО счёта для терминала (readonly-данные, обновляется каждый тик)
    $st.go | Add-Member -NotePropertyName account_liquid_rub -NotePropertyValue ([math]::Round($liquid, 2)) -Force
    $used = $null
    $sm = Get-TiField $Margin 'starting_margin'
    if ($null -ne $sm) { $used = [double](M2D $sm).value }
    if ($null -eq $used) {
      # оценка по собственным карточкам (фьючерсы - эксклюзив бота, оценка полна)
      $used = 0.0
      foreach ($sn in 'core','setA') {
        foreach ($c in @($st.sleeves.$sn.positions)) { $used += [double]$c.lots * [double]$c.go_per_lot }
      }
    }
    $st.go.used_rub = [math]::Round([double]$used, 2)
  }
  $stockVal = 0.0
  foreach ($h in @($st.sleeves.mom.holdings)) { $stockVal += [double]$h.lots * [double]$h.lot_size * [double]$h.last_px }
  # бот работает «свободными деньгами»: бюджет от СВОЕЙ базы, а не от всего счёта (счёт основной, есть чужие активы)
  $st.go.budget_rub = [math]::Round([double]$LIVE.base_rub - $stockVal - [double]$LIVE.reserve_rub, 2)
  if ([double]$st.go.used_rub -gt [double]$st.go.peak_day_rub) { $st.go.peak_day_rub = [double]$st.go.used_rub }
}
# Точный капитал бота (сверено на боевом счёте 2026-07-17): валюты (рубли+USD+серебро) +
# фьючерсы + momentum-акции бота. Чужие акции/облигации пользователя автоматически ВНЕ:
# их нет в total_amount_currencies и они не куплены ботом (mom.holdings). Серебро SLVRUB_TOM
# T-Invest классифицирует как currency -> уже в total_amount_currencies. Маржа на счёте
# отключена (GetMarginAttributes -> 400), поэтому берём всё из GetPortfolio, НЕ из маржи.
function Set-BotCapital($Pf) {
  if ($mode -eq 'dryrun') { return }   # dryrun: реального портфеля нет
  if ($null -eq $Pf) {
    try { $Pf = Get-TiPortfolio ([string]$st.account_id) }
    catch { Write-LiveLog "Set-BotCapital: портфель недоступен: $($_.Exception.Message)"; return }
  }
  $curRub = 0.0; $futRub = 0.0; $totRub = 0.0
  $c = Get-TiField $Pf 'total_amount_currencies'; if ($null -ne $c) { $curRub = [double](M2D $c).value }
  $f = Get-TiField $Pf 'total_amount_futures';    if ($null -ne $f) { $futRub = [double](M2D $f).value }
  $t = Get-TiField $Pf 'total_amount_portfolio';  if ($null -ne $t) { $totRub = [double](M2D $t).value }
  $momRub = 0.0
  foreach ($h in @($st.sleeves.mom.holdings)) { $momRub += [double]$h.lots * [double]$h.lot_size * [double]$h.last_px }
  $cap = [math]::Round($curRub + $futRub + $momRub, 2)
  if ($cap -le 0 -and $totRub -gt 0) { $cap = [math]::Round($totRub, 2) }   # sandbox/фолбэк: нет разбивки -> весь портфель
  $userRub = [math]::Round($totRub - $curRub - $futRub - $momRub, 2)         # чужие акции+облигации (для сверки)
  $st.go | Add-Member -NotePropertyName bot_capital_rub -NotePropertyValue $cap -Force
  $st | Add-Member -NotePropertyName capital_breakdown -NotePropertyValue ([pscustomobject]@{
    currencies = [math]::Round($curRub, 2); futures = [math]::Round($futRub, 2)
    mom_shares = [math]::Round($momRub, 2); user_assets = $userRub; portfolio_total = [math]::Round($totRub, 2)
  }) -Force
}
function Test-GoAllows([double]$AddGoRub) {
  return (([double]$st.go.used_rub + $AddGoRub) -le ([double]$LIVE.go_cap_pct * [double]$st.go.budget_rub))
}

# ================= reconcile (каждый тик, до любых действий) =================
function Get-BrokerStopIds {
  $stopIds = @{}
  if (-not $LIVE.emulate_stops) {
    foreach ($so in (Get-TiStopOrders ([string]$st.account_id))) {
      if ($null -ne $so) {
        $sid = if ($so.PSObject.Properties['stopOrderId']) { [string]$so.stopOrderId } else { [string]$so.stop_order_id }
        $stopIds[$sid] = $so
      }
    }
  }
  return $stopIds
}
function Invoke-Reconcile($stopIds) {
  # DRYRUN: виртуальные позиции заведомо расходятся с реальным счётом - сверка только логирует
  if ($mode -eq 'dryrun') {
    Write-LiveLog 'reconcile: dryrun - log-only (виртуальные позиции vs реальный счёт не сверяются)'
    return
  }
  $pf = Get-TiPortfolio ([string]$st.account_id)
  $brokerFut = @{}; $brokerStk = @{}
  foreach ($p in @($pf.positions)) {
    if ($null -eq $p) { continue }
    $uid = [string]$p.instrumentUid
    if (-not $uid -and $p.PSObject.Properties['instrument_uid']) { $uid = [string]$p.instrument_uid }
    $itype = [string]$p.instrumentType
    if (-not $itype -and $p.PSObject.Properties['instrument_type']) { $itype = [string]$p.instrument_type }
    $lots = [double](Q2D $p.quantityLots)
    if ($lots -eq 0 -and $p.PSObject.Properties['quantity_lots']) { $lots = [double](Q2D $p.quantity_lots) }
    if ($itype -eq 'futures') { $brokerFut[$uid] = $lots }
    elseif ($itype -eq 'share') { $brokerStk[$uid] = $lots }
  }
  # --- фьючерсы: строгая сверка (эксклюзив бота) ---
  $cardsByUid = @{}
  foreach ($sn in 'core','setA') {
    foreach ($c in @($st.sleeves.$sn.positions)) {
      $sm = if ($c.side -eq 'long') { 1.0 } else { -1.0 }
      if (-not $cardsByUid.ContainsKey([string]$c.uid)) { $cardsByUid[[string]$c.uid] = 0.0 }
      $cardsByUid[[string]$c.uid] += $sm * [double]$c.lots
    }
  }
  # D2: позиция у брокера без карточки (не объяснимая живыми intents)
  foreach ($uid in @($brokerFut.Keys)) {
    if ([double]$brokerFut[$uid] -eq 0) { continue }
    $known = $cardsByUid.ContainsKey($uid)
    $explain = @($st.pending_intents | Where-Object { $_.uid -eq $uid -and $_.state -in @('POSTED','PARTIAL','LOST') }).Count
    if (-not $known -and -not $explain) {
      $st.drift.D2 = [int]$st.drift.D2 + 1; $st.drift.last = "D2 $uid lots=$($brokerFut[$uid])"
      Alert "D2: чужая фьючерс-позиция $uid ($($brokerFut[$uid]) лотов) - аварийное закрытие"
      $dir = if ([double]$brokerFut[$uid] -gt 0) { 'sell' } else { 'buy' }
      $it = New-Intent 'emergency_close' @{ uid = $uid; ticker = $uid; side = $dir; lots = [int][math]::Abs([double]$brokerFut[$uid])
        ctx = [pscustomobject]@{ card_id = ''; why = 'D2 foreign position' } }
      Save-State
      [void](Post-IntentMarket $it $dir ([int][math]::Abs([double]$brokerFut[$uid])))
      Set-EntriesHalt 'D2 foreign futures position'
    }
  }
  # D4/D5 по карточкам
  foreach ($sn in 'core','setA') {
    foreach ($c in @($st.sleeves.$sn.positions)) {
      $sm = if ($c.side -eq 'long') { 1.0 } else { -1.0 }
      $real = if ($brokerFut.ContainsKey([string]$c.uid)) { [double]$brokerFut[[string]$c.uid] } else { 0.0 }
      $want = $sm * [double]$c.lots
      if ($real -eq 0.0) {
        # D4: вероятно сработала стоп-заявка - подтверждаем по operations (не раньше входа в позицию)
        $op = $null
        try { $op = Find-FillOperation ([string]$c.uid) $(if ($c.side -eq 'long') { 'sell' } else { 'buy' }) ([int]$c.lots) ([long]$c.entry_ts) }
        catch {
          # operations недоступны: НЕ кварантинить по отсутствию данных - проверка на следующем тике
          Write-LiveLog "D4 $($c.id): operations недоступны ($($_.Exception.Message)) - проверка отложена"
          continue
        }
        if ($null -ne $op) {
          $px = [double](M2D $op.price).value
          $fee = [math]::Abs([double]$c.lots) * $px * [double]$c.rub_per_pt * [double]$LIVE.fee_est
          Close-CardLedger $c $px 'stop' $fee
        } else {
          $st.drift.D4 = [int]$st.drift.D4 + 1; $st.drift.last = "D4 $($c.id)"
          Alert "D4: карточка $($c.id) $($c.asset) без позиции у брокера и без операции - карантин"
          $c.quarantine = $true
          Set-EntriesHalt "D4 $($c.id)"
        }
        continue
      }
      if ([math]::Abs($real - $want) -gt 0.0001) {
        $explain = @($st.pending_intents | Where-Object { $_.uid -eq $c.uid -and $_.state -in @('POSTED','PARTIAL','LOST') }).Count
        if (-not $explain) {
          # частичный fill TP1-заявки? проверяем операции, иначе усечь к брокеру
          $st.drift.D5 = [int]$st.drift.D5 + 1; $st.drift.last = "D5 $($c.id) real=$real want=$want"
          $newLots = [int][math]::Abs($real)
          Alert "D5: $($c.id) $($c.asset) лоты $($c.lots)->$newLots (приведено к брокеру)"
          $c.lots = $newLots
        }
      }
      # D6: стоп-заявка жива?
      if (-not $c.quarantine) { [void](Ensure-CardStop $c $stopIds) }
    }
  }
  # --- акции: bot-owned lots (real >= bot - норма; меньше - усечь + алерт) ---
  foreach ($h in @($st.sleeves.mom.holdings)) {
    $realShares = if ($brokerStk.ContainsKey([string]$h.uid)) { [double]$brokerStk[[string]$h.uid] } else { 0.0 }
    $botLots = [double]$h.lots
    if ($realShares -lt $botLots) {
      $st.drift.stocks_deficit = [int]$st.drift.stocks_deficit + 1
      Alert "stocks_deficit: $($h.sym) bot=$botLots real=$realShares - усечён bot-леджер"
      $h.lots = [int][math]::Max(0, $realShares)
    }
  }
  $st.sleeves.mom.holdings = ToArr (@($st.sleeves.mom.holdings) | Where-Object { [int]$_.lots -gt 0 })
}

# поиск исполнившейся операции по инструменту (подтверждение стоп-заявок и adopt LOST)
$script:opsCache = $null
function Get-OpsSince {
  if ($null -ne $script:opsCache) { return $script:opsCache }
  $to = (MsToUtc $NowMs).ToString('yyyy-MM-ddTHH:mm:ssZ')
  # НЕ кастовать ops_since через [string]: pwsh 7 грузит полный ISO из JSON как [datetime],
  # и [string] даёт культурный формат -> API 400 code 3 (инцидент 2026-07-20). Нормализация в либе.
  $script:opsCache = @(Get-TiOperations ([string]$st.account_id) (ConvertTo-TiIso $st.watermarks.ops_since) $to)
  return $script:opsCache
}
function Find-FillOperation([string]$Uid, [string]$Dir, [int]$Lots, [long]$SinceMs = 0, [double]$LotSize = 1) {
  # СТРОГИЙ матчинг (боевой урок 2026-07-17: слабый uid+dir подхватывал СТАРЫЕ операции -> ложные филлы):
  # инструмент + направление + время (не раньше SinceMs-60с) + количество (лоты или штуки = лоты x лот)
  $want = if ($Dir -eq 'buy') { 'OPERATION_TYPE_BUY' } else { 'OPERATION_TYPE_SELL' }
  foreach ($op in (Get-OpsSince)) {
    if ($null -eq $op) { continue }
    $ouid = [string](Get-TiField $op 'instrument_uid')
    $otype = [string](Get-TiField $op 'operation_type')
    if ($ouid -ne $Uid -or $otype -ne $want) { continue }
    if ($SinceMs -gt 0) {
      try {
        $od = [DateTimeOffset]::Parse([string](Get-TiField $op 'date')).ToUnixTimeMilliseconds()
        if ($od -lt ($SinceMs - 60000)) { continue }
      } catch { continue }
    }
    if ($Lots -gt 0) {
      $q = 0.0
      try { $q = [double][string](Get-TiField $op 'quantity') } catch {}
      if ($q -ne $Lots -and $q -ne ($Lots * $LotSize)) { continue }
    }
    return $op
  }
  return $null
}

# ================= state machine polling =================
function Invoke-IntentCleanup {
  # терминальные интенты убираем В ТОМ ЖЕ тике; roll_open REJECTED = позиция уже закрыта ногой 1
  foreach ($it in @($st.pending_intents)) {
    # страховка: применённый FILLED, не удалённый из-за аварийного тика (at-most-once по флагу applied)
    if ([string]$it.state -eq 'FILLED' -and $it.PSObject.Properties['applied'] -and $it.applied) { Remove-Intent $it; continue }
    if ([string]$it.state -notin @('REJECTED','CANCELLED','EXPIRED')) { continue }
    if ([string]$it.kind -eq 'roll_open') {
      $card = Find-Card ([string]$it.ctx.card_id)
      if ($null -ne $card) {
        Alert "roll_open $($it.id) $($it.ticker) не исполнился - позиция закрыта как roll-fail"
        Close-CardLedger $card ([double]$card.roll_close_px) 'roll-fail' 0.0
      }
    } elseif ([string]$it.kind -in @('emergency_close','exit')) {
      Alert "$($it.kind) $($it.id) $($it.ticker) НЕ исполнился ($($it.state)) - позиция может быть открыта, проверить вручную"
    }
    $script:ev.Add("$($it.state) $($it.id) $($it.kind) $($it.ticker) $($it.last_error)")
    Remove-Intent $it
  }
}

function Invoke-IntentPolling {
  # нормализация хвостов краша ДО обработки (write-ahead: postOrder мог уйти без записи ответа)
  foreach ($it in @($st.pending_intents)) {
    if ([string]$it.state -eq 'POSTED' -and -not [string]$it.broker_order_id) { Set-IntentState $it 'LOST' 'no broker id' }
    elseif ([string]$it.state -eq 'INTENT' -and [int]$it.attempts -gt 0 -and ([long]$NowMs - [long]$it.state_ts) -gt 90000) {
      Set-IntentState $it 'LOST' 'stale INTENT after crash'
    }
  }
  foreach ($it in @($st.pending_intents)) {
    if ([string]$it.state -eq 'POSTED') {
      $os = $null
      try { $os = Get-TiOrderState ([string]$st.account_id) ([string]$it.broker_order_id) } catch { continue }
      $phase = ConvertTo-TiOrderPhase ([string]$os.executionReportStatus)
      if ($phase -eq 'FILLED') {
        $it.filled_lots = [int]$it.lots
        $px = Get-FillPxPerUnit $it $os ([int]$it.lots)
        if ($null -ne $px -and $px -gt 0) { $it.avg_fill_px = $px }
        $it.t_fill = $NowMs
        Set-IntentState $it 'FILLED'
      } elseif ($phase -eq 'PARTIAL') {
        $done = 0
        if ($os.PSObject.Properties['lotsExecuted']) { $done = [int]$os.lotsExecuted }
        $it.filled_lots = $done
        Set-IntentState $it 'PARTIAL'
      } elseif ($phase -in @('REJECTED','CANCELLED')) {
        Set-IntentState $it $phase
      } else {
        # market-заявка висит > 3 тиков - алерт + попытка отмены
        if (($NowMs - [long]$it.state_ts) -gt 180000) {
          Alert "заявка $($it.id) висит POSTED >3 мин - отмена и сверка"
          try { Cancel-TiOrder ([string]$st.account_id) ([string]$it.broker_order_id) | Out-Null } catch {}
        }
      }
    }
    if ([string]$it.state -eq 'LOST') {
      # adopt: ищем операцию-исполнение НЕ РАНЬШЕ постановки; нет - repost ТЕМ ЖЕ order_key (идемпотентность)
      $sinceAd = if ([long]$it.t_post -gt 0) { [long]$it.t_post } else { [long]$it.state_ts }
      $lsAd = 1.0
      if ([string]$it.kind -like 'mom_*') { try { $lsAd = [double](Get-Inst ([string]$it.ticker) 'share').lot } catch {} }
      $op = $null
      try { $op = Find-FillOperation ([string]$it.uid) ([string]$it.side) ([int]$it.lots) $sinceAd $lsAd }
      catch {
        # operations недоступны: репост БЕЗ adopt-проверки опасен (двойной филл) - ждём следующего тика
        Write-LiveLog "adopt $($it.id): operations недоступны ($($_.Exception.Message)) - репост отложен"
        continue
      }
      if ($null -ne $op) {
        $it.filled_lots = [int]$it.lots
        $it.avg_fill_px = [double](M2D $op.price).value
        $it.t_fill = $NowMs
        Set-IntentState $it 'FILLED'
        $script:ev.Add("ADOPT $($it.id): найдено исполнение в operations")
      } elseif ([int]$it.attempts -lt [int]$LIVE.max_attempts) {
        if (Can-PostOrders) {
          $script:ev.Add("REPOST $($it.id) (attempt $([int]$it.attempts + 1), тот же order_key)")
          [void](Post-IntentMarket $it ([string]$it.side) ([int]$it.lots - [int]$it.filled_lots))
        }
      } else {
        Set-IntentState $it 'EXPIRED' 'lost: max attempts'
        Alert "intent $($it.id) $($it.kind) $($it.ticker) EXPIRED после $($it.attempts) попыток"
      }
    }
    if ([string]$it.state -eq 'PARTIAL') {
      # добор остатка новым ключом (тот же intent, суффикс fill{n})
      $rest = [int]$it.lots - [int]$it.filled_lots
      if ($rest -le 0) { Set-IntentState $it 'FILLED' }
      elseif ([int]$it.attempts -ge [int]$LIVE.max_attempts) {
        Set-IntentState $it 'FILLED' 'partial: max attempts, работаем с filled_lots'
        $it.lots = [int]$it.filled_lots   # карточка строится по фактически набранному
        Alert "partial $($it.id): добор не удался, работаем с $($it.filled_lots)"
      } elseif (Can-PostOrders) {
        $it.order_key = New-TiOrderKey ([string]$it.id) ("fill$([int]$it.attempts)")
        [void](Post-IntentMarket $it ([string]$it.side) $rest)
      }
    }
    # исполненные интенты применяем к леджеру/карточкам
    Complete-IntentIfFilled $it
  }
  # протухание entry-интентов: paper исполняет ПЕРВЫЙ торговый день ПОСЛЕ created_day (D+1, через
  # выходные - понедельник). Если в серии уже есть торговый день > created_day и он не сегодня -
  # окно упущено навсегда; если этот день сегодня - живёт до конца окна входов.
  foreach ($it in @($st.pending_intents | Where-Object { $_.kind -eq 'entry' -and $_.state -eq 'INTENT' })) {
    if ([string]$it.created_day -ge $mskToday) { continue }
    $missed = $false
    try {
      $sSer = Get-Ser ([string]$it.asset)
      for ($j = $sSer.Count - 1; $j -ge 0; $j--) {
        $d = SerDay $sSer[$j]
        if ($d -le [string]$it.created_day) { break }
        if ($d -lt $mskToday) { $missed = $true; break }   # торговый день между сигналом и сегодня уже был
      }
    } catch {}
    if ($missed -or ($mskHHmm -gt [string]$LIVE.entry_till)) {
      Set-IntentState $it 'EXPIRED' 'entry window passed'
    }
  }
  Invoke-IntentCleanup
}

function Apply-FilledIntent($It) {
  $px = if ($null -ne $It.avg_fill_px) { [double]$It.avg_fill_px } else { 0.0 }
  $lat = [pscustomobject]@{ sp = [long]$It.t_post - [long]$It.t_signal; pf = [long]$It.t_fill - [long]$It.t_post }
  switch ([string]$It.kind) {
    'entry' {
      $inst = Get-Inst ([string]$It.ticker) 'fut'
      if ($px -le 0) { $px = [double]$It.ctx.ref_px }
      $sl = Get-SleeveRef ([string]$It.sleeve)
      $sm = if ($It.side -eq 'buy') { 1.0 } else { -1.0 }
      $sideName = if ($It.side -eq 'buy') { 'long' } else { 'short' }
      # stopDist: core - из сигнала; setA - от ФАКТИЧЕСКОГО филла (как paper: max(свинг, 1xATR))
      $stopDist = [double]$It.ctx.stop_dist
      if ([string]$It.sleeve -eq 'setA') {
        $stopDist = [math]::Max($sm * ($px - [double]$It.ctx.swing), [double]$ATR_STOP_A * [double]$It.ctx.atr)
      }
      $fee = [int]$It.filled_lots * $px * [double]$inst.rub_per_pt * [double]$LIVE.fee_est
      $sl.eq_rub = [double]$sl.eq_rub - $fee
      $card = [pscustomobject]@{
        id = "L$($It.id.Substring(1))"; sleeve = [string]$It.sleeve; asset = [string]$It.asset
        secid = [string]$It.ticker; uid = [string]$It.uid; figi = [string]$inst.figi
        side = $sideName; lots = [int]$It.filled_lots; lots_initial = [int]$It.filled_lots
        entry_px_pts = [math]::Round($px, 6); entry_day = $mskToday; entry_ts = $NowMs
        stop_px_pts = [math]::Round($px - $sm * $stopDist, 6); stop_order_id = ''; stop_lots = 0
        tp1_px_pts = $(if ([string]$It.sleeve -eq 'setA') { [math]::Round($px + $sm * [double]$TPR * $stopDist, 6) } else { $null })
        tp1_order_id = ''; tp1_done = $false; be_moved = $false
        mfe_pts = [math]::Round($px, 6); atr_entry = [double]$It.ctx.atr
        risk_rub = [math]::Round([double]$It.ctx.risk_rub, 2); rub_per_pt = [double]$inst.rub_per_pt
        go_per_lot = $(if ($It.side -eq 'buy') { [double]$inst.go_buy } else { [double]$inst.go_sell })
        rolls = 0; fees_rub = [math]::Round($fee, 2); realized_rub = 0.0
        d6_fails = 0; quarantine = $false; stop_deferred = $null; last_stop_update = ''
        lat_sp = $lat.sp; lat_pf = $lat.pf
      }
      $sl.positions = ToArr (@($sl.positions) + $card)
      $st.stats.fills = [int]$st.stats.fills + 1
      $script:ev.Add("ENTRY [$($It.sleeve)] $($card.id) $($It.asset) $sideName $([int]$It.filled_lots) лот @$px")
      $script:jr.Add(("`r`n## {0} MSK — RF-LIVE [{1}]: ВХОД {2} {3} {4} {5} лот @{6}, стоп {7}, риск {8} ₽`r`n" -f (MsToUtcStr $mskNowMs), $It.sleeve, $card.id, $It.asset, $sideName.ToUpper(), [int]$It.filled_lots, $px, $card.stop_px_pts, $card.risk_rub))
      # НЕМЕДЛЕННО стоп-заявка (инвариант #2); TP1 для setA при lots >= 2
      if (-not (Post-CardStop $card)) {
        Alert "стоп не выставился после входа $($card.id) - аварийное закрытие"
        Invoke-EmergencyClose $card 'stop-after-entry-fail'
      } elseif ([string]$It.sleeve -eq 'setA' -and [int]$card.lots -ge 2 -and -not $LIVE.emulate_stops) {
        $half = [math]::Floor([int]$card.lots / 2)
        $dirTp = if ($card.side -eq 'long') { 'sell' } else { 'buy' }
        $rtp = Post-TiStopOrder ([string]$st.account_id) ([string]$card.uid) $dirTp ([int]$half) ([decimal][double]$card.tp1_px_pts) 'take_profit'
        if ($null -ne $rtp -and $rtp.PSObject.Properties['stopOrderId']) { $card.tp1_order_id = [string]$rtp.stopOrderId }
      }
    }
    'exit' {
      $card = Find-Card ([string]$It.ctx.card_id)
      if ($null -ne $card) {
        if ($px -le 0) { $px = [double]$card.entry_px_pts }
        $fee = [int]$card.lots * $px * [double]$card.rub_per_pt * [double]$LIVE.fee_est
        Close-CardLedger $card $px ([string]$It.ctx.reason) $fee
      }
    }
    'emergency_close' {
      $card = Find-Card ([string]$It.ctx.card_id)
      if ($null -ne $card) {
        if ($px -le 0) { $px = [double]$card.entry_px_pts }
        $fee = [int]$card.lots * $px * [double]$card.rub_per_pt * [double]$LIVE.fee_est
        Close-CardLedger $card $px 'emergency' $fee
      }
    }
    'roll_close' {
      $card = Find-Card ([string]$It.ctx.card_id)
      if ($null -ne $card) { Apply-RollClose $card $px ([string]$It.ctx.to_secid) }
    }
    'roll_open' {
      $card = Find-Card ([string]$It.ctx.card_id)
      if ($null -ne $card) { Apply-RollOpen $card $px }
    }
    'tp1_fill' {
      # sandbox-эмуляция TP1 (в проде TP1 - брокерская take-profit заявка, обрабатывается Invoke-Tp1Sync)
      $card = Find-Card ([string]$It.ctx.card_id)
      if ($null -ne $card) {
        if ($px -le 0) { $px = [double]$card.tp1_px_pts }
        $sm = if ($card.side -eq 'long') { 1.0 } else { -1.0 }
        $fee = [int]$It.filled_lots * $px * [double]$card.rub_per_pt * [double]$LIVE.fee_est
        $pnl = $sm * [int]$It.filled_lots * ($px - [double]$card.entry_px_pts) * [double]$card.rub_per_pt - $fee
        $sl = Get-SleeveRef ([string]$card.sleeve)
        $sl.eq_rub = [double]$sl.eq_rub + $pnl
        $card.realized_rub = [double]$card.realized_rub + $pnl
        $card.fees_rub = [double]$card.fees_rub + $fee
        $card.lots = [int]$card.lots - [int]$It.filled_lots
        $card.tp1_done = $true
        $card.stop_px_pts = [double]$card.entry_px_pts   # стоп в безубыток
        $script:ev.Add("TP1-emu fill $($card.id) $($card.asset) $([int]$It.filled_lots) лот @$px")
      }
    }
    'mom_sell' { Apply-MomSell $It $px }
    'mom_buy'  { Apply-MomBuy $It $px }
    'funding_sell' {
      # конверсия юзерского актива в рубли под сделку: НЕ P&L бота, только журнал
      $script:ev.Add("FUNDING done $($It.ticker) $([int]$It.filled_lots) лот @$px")
      $script:jr.Add(("`r`n## {0} MSK — RF-LIVE: продан {1} ({2} лот @{3}) под ликвидность: {4}`r`n" -f (MsToUtcStr $mskNowMs), $It.ticker, [int]$It.filled_lots, $px, $It.ctx.why))
    }
  }
}
function Find-Card([string]$CardId) {
  foreach ($sn in 'core','setA') {
    $hit = @($st.sleeves.$sn.positions | Where-Object { $_.id -eq $CardId })
    if ($hit.Count) { return $hit[0] }
  }
  return $null
}

# ================= роллы =================
function Apply-RollClose($Card, [double]$Px, [string]$ToSecid) {
  # нога 1: старый контракт закрыт; фиксируем realized и ставим маркер для ноги 2
  $sm = if ($Card.side -eq 'long') { 1.0 } else { -1.0 }
  $fee = [int]$Card.lots * $Px * [double]$Card.rub_per_pt * [double]$LIVE.fee_est
  $pnl = $sm * [double]$Card.lots * ($Px - [double]$Card.entry_px_pts) * [double]$Card.rub_per_pt - $fee
  $sl = Get-SleeveRef ([string]$Card.sleeve)
  $sl.eq_rub = [double]$sl.eq_rub + $pnl
  $Card.realized_rub = [double]$Card.realized_rub + $pnl
  $Card.fees_rub = [double]$Card.fees_rub + $fee
  $Card | Add-Member -NotePropertyName roll_pending_to -NotePropertyValue $ToSecid -Force
  $Card | Add-Member -NotePropertyName roll_close_px -NotePropertyValue $Px -Force
  $Card.stop_order_id = ''
  # нога 2 сразу (в то же окно): market в новый фронт
  $instNew = Get-Inst $ToSecid 'fut'
  $ratio = 1.0
  $sNew = Get-Ser ([string]$Card.asset)   # серия уже рескейлнута дневным хуком
  # лоты: сохранение нотионала (целочисленный аналог paper qtyNew = qty/ratio)
  $pxNewRef = [double]$sNew[$sNew.Count - 1].c
  if ($pxNewRef -gt 0 -and $Px -gt 0) { $ratio = $pxNewRef / $Px }
  $lotsNew = [math]::Max(1, [math]::Round([double]$Card.lots * $Px * [double]$Card.rub_per_pt / ($pxNewRef * [double]$instNew.rub_per_pt)))
  $dir = if ($Card.side -eq 'long') { 'buy' } else { 'sell' }
  $it = New-Intent 'roll_open' @{ sleeve = [string]$Card.sleeve; asset = [string]$Card.asset
    ticker = $ToSecid; uid = [string]$instNew.uid; side = $dir; lots = [int]$lotsNew
    ctx = [pscustomobject]@{ card_id = [string]$Card.id; ratio = $ratio } }
  Save-State
  [void](Post-IntentMarket $it $dir ([int]$lotsNew))
}
function Apply-RollOpen($Card, [double]$Px) {
  $inst = Get-Inst ([string]$Card.roll_pending_to) 'fut'
  $ratio = if ([double]$Card.roll_close_px -gt 0) { $Px / [double]$Card.roll_close_px } else { 1.0 }
  $fee = [int]$Card.lots * $Px * [double]$inst.rub_per_pt * [double]$LIVE.fee_est
  $sl = Get-SleeveRef ([string]$Card.sleeve)
  $sl.eq_rub = [double]$sl.eq_rub - $fee
  $Card.fees_rub = [double]$Card.fees_rub + $fee
  $Card.secid = [string]$Card.roll_pending_to
  $Card.uid = [string]$inst.uid
  $Card.rub_per_pt = [double]$inst.rub_per_pt
  $Card.entry_px_pts = [math]::Round($Px, 6)
  $Card.stop_px_pts = [math]::Round([double]$Card.stop_px_pts * $ratio, 6)
  if ($null -ne $Card.tp1_px_pts) { $Card.tp1_px_pts = [math]::Round([double]$Card.tp1_px_pts * $ratio, 6) }
  $Card.mfe_pts = [math]::Round([double]$Card.mfe_pts * $ratio, 6)
  $Card.rolls = [int]$Card.rolls + 1
  $Card.roll_pending_to = $null
  $script:ev.Add("ROLL [$($Card.sleeve)] $($Card.id) $($Card.asset) -> $($Card.secid)")
  if (-not (Post-CardStop $Card)) {
    Alert "стоп после ролла не выставился $($Card.id) - аварийное закрытие"
    Invoke-EmergencyClose $Card 'stop-after-roll-fail'
  }
}

# ================= momentum =================
function Apply-MomSell($It, [double]$Px) {
  $m = $st.sleeves.mom
  $h = @($m.holdings | Where-Object { $_.sym -eq [string]$It.ticker })
  if (-not $h.Count) { return }
  $h = $h[0]
  if ($Px -le 0) { $Px = [double]$h.last_px }
  $val = [int]$It.filled_lots * [double]$h.lot_size * $Px
  $fee = $val * [double]$LIVE.fee_est
  $m.cash_rub = [double]$m.cash_rub + $val - $fee
  $pnl = ([double]$Px - [double]$h.avg_px) * [int]$It.filled_lots * [double]$h.lot_size - $fee
  $h.lots = [int]$h.lots - [int]$It.filled_lots
  if ([int]$h.lots -le 0) { $m.holdings = ToArr (@($m.holdings) | Where-Object { $_.sym -ne $h.sym }) }
  $st.stats.fills = [int]$st.stats.fills + 1
  $script:ev.Add("MOM SELL $($It.ticker) $([int]$It.filled_lots) лот @$Px pnl=$([math]::Round($pnl,0))")
}
function Apply-MomBuy($It, [double]$Px) {
  $m = $st.sleeves.mom
  $inst = Get-Inst ([string]$It.ticker) 'share'
  if ($Px -le 0) { $Px = [double]$It.ctx.ref_px }
  $val = [int]$It.filled_lots * [double]$inst.lot * $Px
  $fee = $val * [double]$LIVE.fee_est
  $m.cash_rub = [double]$m.cash_rub - $val - $fee
  $m.holdings = ToArr (@($m.holdings) + [pscustomobject]@{
    sym = [string]$It.ticker; uid = [string]$inst.uid; lots = [int]$It.filled_lots
    lot_size = [double]$inst.lot; avg_px = [math]::Round($Px, 4); last_px = [math]::Round($Px, 4)
    buy_day = $mskToday })
  $st.stats.fills = [int]$st.stats.fills + 1
  $script:ev.Add("MOM BUY $($It.ticker) $([int]$It.filled_lots) лот @$Px")
}

# ================= дневной хук (сигналы = paper, исполнение своё) =================
function Invoke-LiveDaily {
  # фронты (тот же код ISS, что paper)
  $fronts = Get-FutFronts $ASSETS
  $frontsRec = [ordered]@{}
  foreach ($a in $ASSETS) {
    if (-not $fronts.ContainsKey($a) -or -not @($fronts[$a]).Count) { throw "LIVE-RF: нет фронта для $a" }
    $cur = $fronts[$a][0]
    $nxt = if (@($fronts[$a]).Count -gt 1) { $fronts[$a][1] } else { $null }
    $frontsRec[$a] = [pscustomobject]@{ secid = $cur.secid; lasttrade = $cur.lasttrade
      next = if ($nxt) { $nxt.secid } else { $null }; next_lasttrade = if ($nxt) { $nxt.lasttrade } else { $null } }
  }
  if ($null -eq $st.active) {
    $act = [ordered]@{}
    foreach ($a in $ASSETS) { $act[$a] = $frontsRec[$a].secid }
    $st.active = [pscustomobject]$act
  }
  $st.fronts = [pscustomobject]$frontsRec

  # докатка серий (общий код) + сверка SHA с paper-сериями (кросс-контроль идентичности сигналов)
  foreach ($a in $ASSETS) { Update-DailySeries $a 'fut' ([string]$st.active.$a) $completedDay }
  foreach ($t in @($TICKERS) + @('IMOEX')) {
    $kind = if ($t -eq 'IMOEX') { 'index' } else { 'stock' }
    Update-DailySeries $t $kind $t $completedDay
  }

  # хуки по всем торговым дням (wm, completedDay]
  $newDays = New-Object System.Collections.Generic.List[string]
  $wm = [string]$st.watermarks.last_daily_day
  foreach ($nm in (@($ASSETS) + @('IMOEX'))) {
    $s = Get-Ser $nm
    for ($j = $s.Count - 1; $j -ge 0; $j--) {
      $d = SerDay $s[$j]
      if ($d -le $wm) { break }
      if ($d -le $completedDay -and -not $newDays.Contains($d)) { $newDays.Add($d) }
    }
  }
  foreach ($D in ($newDays | Sort-Object)) { Invoke-LiveDayHook $D }
  $st.watermarks.last_daily_day = $completedDay
}

function Invoke-LiveDayHook([string]$D) {
  $mon = $D.Substring(0, 7)
  # месяц: помесячно-аддитивная модель профиля (как paper rf_engine)
  if ($st.cur_month -eq '') { $st.cur_month = $mon }
  if ($mon -ne [string]$st.cur_month) {
    $eC = [double]$st.sleeves.core.equity_mtm; $eA = [double]$st.sleeves.setA.equity_mtm; $eM = [double]$st.sleeves.mom.equity_mtm
    if ($eC -le 0) { $eC = [double]$st.sleeves.core.eq_rub }
    if ($eA -le 0) { $eA = [double]$st.sleeves.setA.eq_rub }
    if ($eM -le 0) { $eM = [double]$st.sleeves.mom.eq_rub }
    $rC = ($eC / [double]$st.sleeves.core.month_start_eq) - 1
    $rA = ($eA / [double]$st.sleeves.setA.month_start_eq) - 1
    $rM = ($eM / [double]$st.sleeves.mom.month_start_eq) - 1
    $st.profile_month_start = [math]::Round([double]$st.profile_month_start * (1 + $rC + $rA + [double]$LIVE.mom_weight * $rM), 2)
    $st.sleeves.core.month_start_eq = $eC; $st.sleeves.setA.month_start_eq = $eA; $st.sleeves.mom.month_start_eq = $eM
    $st.cur_month = $mon
  }
  if ([string]$st.day_start_date -ne $D) {
    $st.day_start_date = $D; $st.day_start_eq = [double]$st.profile_eq
    $st.sleeves.core.day_start_eq = [double]$st.sleeves.core.eq_rub
    $st.sleeves.setA.day_start_eq = [double]$st.sleeves.setA.eq_rub
    $st.sleeves.core.halt_day = $null; $st.sleeves.setA.halt_day = $null
    if ($st.entries_halt.active -and [string]$st.entries_halt.reason -like 'profile day*') {
      $st.entries_halt.active = $false; $st.entries_halt.reason = ''   # дневной халт снимается новым днём
    }
    $st.go.peak_day_rub = 0.0
  }

  foreach ($a in $ASSETS) {
    if (@($LIVE.whitelist).Count -and $LIVE.whitelist -notcontains $a) { continue }
    $s = Get-Ser $a
    $i = Ser-IdxOfDay $s $D
    if ($i -lt 0) { continue }
    $atr = Ser-ATR14 $s $i
    $bar = $s[$i]

    # ролл: как paper (<=4 дней до LASTTRADEDATE активного или биржа сменила фронт)
    $lt = [string]$st.fronts.$a.lasttrade
    $curActive = [string]$st.active.$a
    $frontNow = [string]$st.fronts.$a.secid
    $needRoll = $false; $toSec = ''
    if ($curActive -ne $frontNow) { $needRoll = $true; $toSec = $frontNow }
    elseif ($st.fronts.$a.next -and ((([datetime]$lt) - ([datetime]$D)).TotalDays -le 4)) { $needRoll = $true; $toSec = [string]$st.fronts.$a.next }
    if ($needRoll) {
      # рескейл серии тем же кодом, что paper (иначе разойдутся сигналы!)
      $kOld = Get-IssCandles 'fut' $curActive 24 $D $D
      $kNew = Get-IssCandles 'fut' $toSec 24 $D $D
      if (@($kOld).Count -and @($kNew).Count) {
        $ratio = [double]$kNew[-1].c / [double]$kOld[-1].c
        Invoke-SeriesRollRescale $a $ratio
        $st.active.$a = $toSec
        # позиции в старом контракте -> intents roll_close (исполнение в окно роллов)
        foreach ($sn in 'core','setA') {
          foreach ($c in @($st.sleeves.$sn.positions | Where-Object { $_.asset -eq $a -and $_.secid -eq $curActive })) {
            $c.roll_signal_to = $toSec
          }
        }
        $script:ev.Add("ROLL-SIGNAL $a $curActive -> $toSec (ratio $([math]::Round($ratio,5)))")
      } else { Write-LiveLog "roll $a deferred (нет баров $curActive/$toSec на $D)" }
    }

    # трейл-люстра ядра - ТОЛЬКО на дневном хуке (как paper; MFE копится по часовикам)
    foreach ($c in @($st.sleeves.core.positions | Where-Object { $_.asset -eq $a })) {
      if ([double]$bar.h -gt [double]$c.mfe_pts -and $c.side -eq 'long') { $c.mfe_pts = [double]$bar.h }
      if ([double]$bar.l -lt [double]$c.mfe_pts -and $c.side -eq 'short') { $c.mfe_pts = [double]$bar.l }
      $ns = Get-ChandelierStop ([string]$c.side) ([double]$c.mfe_pts) ([double]$c.stop_px_pts) $atr
      if ($null -ne $ns) { [void](Replace-CardStop $c ([double]$ns)) }
    }
    # трейл-выход setA после TP1: close за EMA20 -> exit-intent (market в окно входов)
    foreach ($c in @($st.sleeves.setA.positions | Where-Object { $_.asset -eq $a -and $_.tp1_done })) {
      if (Test-SetAEma20Exit $s $i ([string]$c.side)) {
        $dir = if ($c.side -eq 'long') { 'sell' } else { 'buy' }
        [void](New-Intent 'exit' @{ sleeve = 'setA'; asset = $a; ticker = [string]$c.secid; uid = [string]$c.uid
          side = $dir; lots = [int]$c.lots; t_signal = (UtcStrToMs "$D 23:50")
          ctx = [pscustomobject]@{ card_id = [string]$c.id; reason = 'trail-ema20' } })
      }
    }

    # сигналы входа: РОВНО как paper (Get-DonchianSide/Get-SetupASignal из lib_rf_signals)
    if ($i -lt ($BRK_N + 1) -or [double]::IsNaN($atr) -or $atr -le 0) { continue }
    $cl = [double]$bar.c
    # core (профиль c3b: re-arm ключ c3b_<asset> - тот же неймспейс, что paper)
    $key = "c3b_$a"
    $ra = if ($st.rearm.PSObject.Properties[$key]) { $st.rearm.$key } else { $null }
    $dsig = Get-DonchianSide $s $i $ra
    if ([string]$dsig.side -ne '') {
      $slC = $st.sleeves.core
      $busy = @($slC.positions).Count + @($st.pending_intents | Where-Object { $_.kind -eq 'entry' -and $_.sleeve -eq 'core' -and $_.state -in @('INTENT','POSTED','PARTIAL','LOST') }).Count
      $has = @($slC.positions | Where-Object { $_.asset -eq $a }).Count + @($st.pending_intents | Where-Object { $_.kind -eq 'entry' -and $_.sleeve -eq 'core' -and $_.asset -eq $a -and $_.state -in @('INTENT','POSTED','PARTIAL','LOST') }).Count
      if ([string]$slC.halt_day -ne $D -and $busy -lt $MAXCONC -and -not $has) {
        $dir = if ($dsig.side -eq 'long') { 'buy' } else { 'sell' }
        [void](New-Intent 'entry' @{ sleeve = 'core'; asset = $a; side = $dir; created_day = $D
          t_signal = (UtcStrToMs "$D 23:50")
          ctx = [pscustomobject]@{ stop_dist = [math]::Round([double]$ATR_STOP_CORE * $atr, 6); atr = [math]::Round($atr, 6)
            risk_pct = [double]$LIVE.core_risk; ref_px = $cl
            note = "donchian close $cl vs [$([math]::Round([double]$dsig.lo,4)) / $([math]::Round([double]$dsig.hi,4))]" } })
        $script:ev.Add("SIGNAL [core] $a $($dsig.side) @close $cl")
      }
    }
    # setA
    $asig = Get-SetupASignal $s $i
    if ($null -ne $asig) {
      $slA = $st.sleeves.setA
      $busy = @($slA.positions).Count + @($st.pending_intents | Where-Object { $_.kind -eq 'entry' -and $_.sleeve -eq 'setA' -and $_.state -in @('INTENT','POSTED','PARTIAL','LOST') }).Count
      $has = @($slA.positions | Where-Object { $_.asset -eq $a }).Count + @($st.pending_intents | Where-Object { $_.kind -eq 'entry' -and $_.sleeve -eq 'setA' -and $_.asset -eq $a -and $_.state -in @('INTENT','POSTED','PARTIAL','LOST') }).Count
      if ([string]$slA.halt_day -ne $D -and $busy -lt $MAXCONC -and -not $has) {
        $dir = if ($asig.side -eq 'long') { 'buy' } else { 'sell' }
        [void](New-Intent 'entry' @{ sleeve = 'setA'; asset = $a; side = $dir; created_day = $D
          t_signal = (UtcStrToMs "$D 23:50")
          ctx = [pscustomobject]@{ swing = [math]::Round([double]$asig.swing, 6); atr = [math]::Round($atr, 6)
            stop_dist = 0; risk_pct = [double]$LIVE.seta_risk; ref_px = $cl; note = 'setup A pullback' } })
        $script:ev.Add("SIGNAL [setA] $a $($asig.side) @close $cl")
      }
    }
  }

  # momentum: 1-й торговый день месяца (детект как paper: по prev-бару IMOEX)
  if ($LIVE.mom_enabled) {
    $ix = Get-Ser 'IMOEX'
    $ii = Ser-IdxOfDay $ix $D
    if ($ii -gt 0) {
      $prevMonth = (SerDay $ix[$ii - 1]).Substring(0, 7)
      if ($mon -ne $prevMonth -and [string]$st.sleeves.mom.last_rebalance_month -ne $mon) {
        $msig = Get-MomentumTarget $D
        $st.sleeves.mom.last_rebalance_month = $mon
        $st.sleeves.mom | Add-Member -NotePropertyName reb_target -NotePropertyValue ([pscustomobject]@{
          day = $D; gate = [bool]$msig.gate; target = @($msig.target); done = $false }) -Force
        $script:ev.Add("MOM-REBALANCE signal $D gate=$($msig.gate) target=[$(@($msig.target) -join ',')]")
      }
    }
  }
}

# ================= окна исполнения =================
function Invoke-EntryWindow {
  if ($st.entries_halt.active) { return }
  # exits первыми (освобождают ГО), затем entries
  foreach ($it in @($st.pending_intents | Where-Object { $_.kind -eq 'exit' -and $_.state -eq 'INTENT' })) {
    if (-not (Test-InstrumentTrading ([string]$it.uid))) { continue }   # ждём открытия торгов
    Save-State
    [void](Post-IntentMarket $it ([string]$it.side) ([int]$it.lots))
  }
  foreach ($it in @($st.pending_intents | Where-Object { $_.kind -eq 'entry' -and $_.state -eq 'INTENT' })) {
    if ([string]$it.created_day -ge $mskToday) { continue }   # вход на открытии СЛЕДУЮЩЕЙ сессии (как paper)
    $sl = Get-SleeveRef ([string]$it.sleeve)
    if ([string]$sl.halt_day -eq $mskToday) { Set-IntentState $it 'CANCELLED' 'sleeve halt'; continue }
    # сайзинг: пункты -> рубли (боевой нюанс #1) + кэп MAXLEV + предиктивный ГО-чек
    $secid = [string]$st.active.$([string]$it.asset)
    $inst = $null
    try { $inst = Get-Inst $secid 'fut' } catch { Set-IntentState $it 'CANCELLED' "инструмент: $($_.Exception.Message)"; Alert "вход $($it.asset) отменён: $($_.Exception.Message)"; continue }
    # не входить в контракт с <=4 дней до last_trade_date (нюанс #7)
    if ($inst.last_trade_date -and ((([datetime]$inst.last_trade_date) - ([datetime]$mskToday)).TotalDays -le 4)) {
      $nx = [string]$st.fronts.$([string]$it.asset).next
      if ($nx) { $secid = $nx; $inst = Get-Inst $secid 'fut' } else { Set-IntentState $it 'CANCELLED' 'фронт в зоне экспирации'; continue }
    }
    $it.ticker = $secid; $it.uid = [string]$inst.uid
    if (-not (Test-InstrumentTrading ([string]$inst.uid))) { continue }   # утро: торги ещё не открылись - интент ждёт
    $s = Get-Ser ([string]$it.asset)
    $refPx = [double]$s[$s.Count - 1].c
    $stopDist = [double]$it.ctx.stop_dist
    if ([string]$it.sleeve -eq 'setA') {
      $sm = if ($it.side -eq 'buy') { 1.0 } else { -1.0 }
      $stopDist = [math]::Max($sm * ($refPx - [double]$it.ctx.swing), [double]$ATR_STOP_A * [double]$it.ctx.atr)
    }
    if ($stopDist -le 0) { Set-IntentState $it 'CANCELLED' 'stopDist<=0'; continue }
    $riskRub = [double]$sl.eq_rub * [double]$it.ctx.risk_pct
    $stopRubPerLot = $stopDist * [double]$inst.rub_per_pt
    $lots = [math]::Floor($riskRub / $stopRubPerLot)
    $levCap = [math]::Floor(([double]$MAXLEV * [double]$sl.eq_rub) / ($refPx * [double]$inst.rub_per_pt))
    if ($lots -gt $levCap) { $lots = $levCap }
    if ([int]$LIVE.max_lots_override -gt 0 -and $lots -gt [int]$LIVE.max_lots_override) { $lots = [int]$LIVE.max_lots_override }
    if ($lots -lt 1) {
      $st.stats.skipped_qty0 = [int]$st.stats.skipped_qty0 + 1
      Set-IntentState $it 'CANCELLED' 'qty0'
      $script:ev.Add("SKIP qty0 [$($it.sleeve)] $($it.asset): riskRub=$([math]::Round($riskRub,0)) stopRub/lot=$([math]::Round($stopRubPerLot,0))")
      continue
    }
    # предиктивный ГО-чек (нюанс #6)
    $goPer = if ($it.side -eq 'buy') { [double]$inst.go_buy } else { [double]$inst.go_sell }
    while ($lots -ge 1 -and -not (Test-GoAllows ($lots * $goPer))) { $lots-- }
    if ($lots -lt 1) {
      Set-IntentState $it 'CANCELLED' 'go-cap'
      $script:ev.Add("SKIP go-cap [$($it.sleeve)] $($it.asset): used=$($st.go.used_rub) budget=$($st.go.budget_rub)")
      continue
    }
    $it.lots = [int]$lots
    $it.ctx | Add-Member -NotePropertyName risk_rub -NotePropertyValue ([math]::Round($riskRub, 2)) -Force
    $it.ctx | Add-Member -NotePropertyName stop_dist -NotePropertyValue ([math]::Round($stopDist, 6)) -Force
    $it.ctx.ref_px = $refPx
    # рубли под ГО: при нехватке продаётся funding (серебро); не вышло - интент ждёт следующего тика
    if (-not (Ensure-RubFunding ($lots * $goPer + 1500.0) "вход $($it.asset) $lots лот")) { continue }
    Save-State
    [void](Post-IntentMarket $it ([string]$it.side) ([int]$lots))
  }
}

function Invoke-RollWindow {
  foreach ($sn in 'core','setA') {
    foreach ($c in @($st.sleeves.$sn.positions | Where-Object { $_.PSObject.Properties['roll_signal_to'] -and $_.roll_signal_to })) {
      $already = @($st.pending_intents | Where-Object { $_.kind -in @('roll_close','roll_open') -and $_.ctx.card_id -eq $c.id -and $_.state -ne 'EXPIRED' }).Count
      if ($already) { continue }
      if (-not (Test-InstrumentTrading ([string]$c.uid))) { continue }   # ролл только при открытых торгах
      $toSec = [string]$c.roll_signal_to
      $c.roll_signal_to = $null
      # нога 1: cancel стопа + market-закрытие старого контракта
      if ([string]$c.stop_order_id -and -not $LIVE.emulate_stops) {
        try { Cancel-TiStopOrder ([string]$st.account_id) ([string]$c.stop_order_id) | Out-Null } catch {}
        $c.stop_order_id = ''
      }
      $dir = if ($c.side -eq 'long') { 'sell' } else { 'buy' }
      $it = New-Intent 'roll_close' @{ sleeve = $sn; asset = [string]$c.asset; ticker = [string]$c.secid
        uid = [string]$c.uid; side = $dir; lots = [int]$c.lots
        ctx = [pscustomobject]@{ card_id = [string]$c.id; to_secid = $toSec } }
      Save-State
      [void](Post-IntentMarket $it $dir ([int]$c.lots))
    }
  }
}

function Invoke-MomWindow {
  $m = $st.sleeves.mom
  if (-not $m.PSObject.Properties['reb_target'] -or $null -eq $m.reb_target -or $m.reb_target.done) { return }
  if ($st.entries_halt.active) { return }
  $target = @($m.reb_target.target)
  $gate = [bool]$m.reb_target.gate
  # sells: всё вне target (или всё при gate=false); только БОТ-лоты
  $sellsPending = $false
  foreach ($h in @($m.holdings)) {
    if ($gate -and ($target -contains [string]$h.sym)) { continue }
    $already = @($st.pending_intents | Where-Object { $_.kind -eq 'mom_sell' -and $_.ticker -eq $h.sym -and $_.state -ne 'EXPIRED' }).Count
    if ($already) { $sellsPending = $true; continue }
    if (-not (Test-InstrumentTrading ([string]$h.uid))) { $sellsPending = $true; continue }   # ждём открытия TQBR
    $it = New-Intent 'mom_sell' @{ sleeve = 'mom'; ticker = [string]$h.sym; uid = [string]$h.uid
      side = 'sell'; lots = [int]$h.lots; ctx = [pscustomobject]@{ ref_px = [double]$h.last_px } }
    Save-State
    [void](Post-IntentMarket $it 'sell' ([int]$h.lots))
    $sellsPending = $true
  }
  if ($sellsPending) { return }   # buys после подтверждения всех sells (следующий тик)
  # buys: новые имена, equal-split бюджета 0.5 x mom_eq
  if ($gate) {
    $newNames = @($target | Where-Object { $n = $_; -not @($m.holdings | Where-Object { $_.sym -eq $n }).Count })
    if ($newNames.Count) {
      $budget = [double]$m.eq_rub   # леджер уже = base x mom_weight, инвестируется целиком (как paper)
      $curVal = 0.0
      foreach ($h in @($m.holdings)) { $curVal += [double]$h.lots * [double]$h.lot_size * [double]$h.last_px }
      $spend = [math]::Min([double]$m.cash_rub, [math]::Max(0.0, $budget - $curVal))
      $per = $spend / $newNames.Count
      foreach ($n in $newNames) {
        $already = @($st.pending_intents | Where-Object { $_.kind -eq 'mom_buy' -and $_.ticker -eq $n -and $_.state -ne 'EXPIRED' }).Count
        if ($already) { continue }
        $inst = $null
        try { $inst = Get-Inst $n 'share' } catch { $script:ev.Add("MOM SKIP $n : $($_.Exception.Message)"); continue }
        if (-not (Test-InstrumentTrading ([string]$inst.uid))) { continue }   # buys подождут открытия
        $s = Get-Ser $n
        $px = [double]$s[$s.Count - 1].c
        $lots = [math]::Floor($per / ($px * [double]$inst.lot))
        if ($lots -lt 1) { $script:ev.Add("MOM SKIP qty0 $n (на имя $([math]::Round($per,0)) ₽, лот $([math]::Round($px*[double]$inst.lot,0)) ₽)"); continue }
        if (-not (Ensure-RubFunding ($lots * $px * [double]$inst.lot + 1500.0) "mom-покупка $n")) { continue }
        $it = New-Intent 'mom_buy' @{ sleeve = 'mom'; ticker = $n; uid = [string]$inst.uid
          side = 'buy'; lots = [int]$lots; ctx = [pscustomobject]@{ ref_px = $px } }
        Save-State
        [void](Post-IntentMarket $it 'buy' ([int]$lots))
      }
    }
  }
  $m.reb_target.done = $true
  $script:jr.Add(("`r`n## {0} MSK — RF-LIVE [mom]: ребаланс исполнен; цель: {1}`r`n" -f (MsToUtcStr $mskNowMs), $(if ($target.Count) { $target -join ', ' } else { 'кэш' })))
}

# ================= часовой проход: MFE-трекинг + BE-эмуляция TP1 lots==1 (+sandbox-стопы) =================
function Invoke-HourlyPass {
  $lastClosedH = (FloorTo ($mskNowMs - 16 * 60000) $H1) - $H1
  $fromTs = [long]$st.watermarks.last_hour_ts + $H1
  if ($fromTs -gt $lastClosedH) { return }
  $need = New-Object System.Collections.Generic.List[string]
  foreach ($sn in 'core','setA') {
    foreach ($c in @($st.sleeves.$sn.positions)) { if (-not $need.Contains([string]$c.asset)) { $need.Add([string]$c.asset) } }
  }
  if (-not $need.Count) { $st.watermarks.last_hour_ts = $lastClosedH; return }
  $fromDay = MsToUtcDay $fromTs
  foreach ($a in $need) {
    $secid = [string]$st.active.$a
    $bars = @()
    try { $all = Get-IssCandles 'fut' $secid 60 $fromDay
      $bars = @($all | Where-Object { [long]$_.t -ge $fromTs -and [long]$_.t -le $lastClosedH }) } catch { continue }
    foreach ($b in $bars) {
      foreach ($sn in 'core','setA') {
        foreach ($c in @($st.sleeves.$sn.positions | Where-Object { $_.asset -eq $a })) {
          if ([long]$c.entry_ts -ge [long]$b.t) { continue }
          # MFE по часовикам (трейл применяется на дневном хуке - как paper)
          if ($c.side -eq 'long' -and [double]$b.h -gt [double]$c.mfe_pts) { $c.mfe_pts = [double]$b.h }
          if ($c.side -eq 'short' -and [double]$b.l -lt [double]$c.mfe_pts) { $c.mfe_pts = [double]$b.l }
          # BE-эмуляция TP1 для lots==1 (брокерский TP невозможен на пол-лота)
          if ($sn -eq 'setA' -and -not $c.tp1_done -and [int]$c.lots_initial -eq 1 -and $null -ne $c.tp1_px_pts -and -not $c.be_moved) {
            $hit = if ($c.side -eq 'long') { [double]$b.h -ge [double]$c.tp1_px_pts } else { [double]$b.l -le [double]$c.tp1_px_pts }
            if ($hit) {
              $c.be_moved = $true; $c.tp1_done = $true
              [void](Replace-CardStop $c ([double]$c.entry_px_pts))
              $script:ev.Add("BE-move (tp1 touch, lots=1) $($c.id) $($c.asset)")
            }
          }
          # sandbox: эмуляция стопа по касанию часовика
          if ($LIVE.emulate_stops) {
            $hitStop = if ($c.side -eq 'long') { [double]$b.l -le [double]$c.stop_px_pts } else { [double]$b.h -ge [double]$c.stop_px_pts }
            if ($hitStop) {
              $dir = if ($c.side -eq 'long') { 'sell' } else { 'buy' }
              $it = New-Intent 'exit' @{ sleeve = $sn; asset = $a; ticker = [string]$c.secid; uid = [string]$c.uid
                side = $dir; lots = [int]$c.lots; ctx = [pscustomobject]@{ card_id = [string]$c.id; reason = 'stop-emu' } }
              Save-State
              [void](Post-IntentMarket $it $dir ([int]$c.lots))
              continue
            }
            # sandbox: эмуляция брокерского TP1 для lots>=2 (в проде это take-profit stop-order)
            if ($sn -eq 'setA' -and -not $c.tp1_done -and [int]$c.lots_initial -ge 2 -and $null -ne $c.tp1_px_pts) {
              $hitTp = if ($c.side -eq 'long') { [double]$b.h -ge [double]$c.tp1_px_pts } else { [double]$b.l -le [double]$c.tp1_px_pts }
              if ($hitTp) {
                $half = [math]::Floor([int]$c.lots_initial / 2)
                $dir = if ($c.side -eq 'long') { 'sell' } else { 'buy' }
                $it = New-Intent 'tp1_fill' @{ sleeve = $sn; asset = $a; ticker = [string]$c.secid; uid = [string]$c.uid
                  side = $dir; lots = [int]$half; ctx = [pscustomobject]@{ card_id = [string]$c.id } }
                Save-State
                [void](Post-IntentMarket $it $dir ([int]$half))
              }
            }
          }
        }
      }
    }
  }
  $st.watermarks.last_hour_ts = $lastClosedH
}

# ================= TP1-подтверждение (fill брокерского take-profit) =================
function Invoke-Tp1Sync($StopIds) {
  if ($mode -eq 'dryrun') { return }   # dryrun: брокерских TP1-заявок нет
  foreach ($c in @($st.sleeves.setA.positions | Where-Object { $_.tp1_order_id -and -not $_.tp1_done })) {
    if ($StopIds.ContainsKey([string]$c.tp1_order_id)) { continue }   # ещё жив
    # TP1-заявки больше нет: сработала (ищем операцию) или снята
    $dirTp = if ($c.side -eq 'long') { 'sell' } else { 'buy' }
    $half = [math]::Floor([int]$c.lots_initial / 2)
    $op = Find-FillOperation ([string]$c.uid) $dirTp ([int]$half) ([long]$c.entry_ts)
    if ($null -ne $op) {
      $px = [double](M2D $op.price).value
      $sm = if ($c.side -eq 'long') { 1.0 } else { -1.0 }
      $fee = $half * $px * [double]$c.rub_per_pt * [double]$LIVE.fee_est
      $pnl = $sm * $half * ($px - [double]$c.entry_px_pts) * [double]$c.rub_per_pt - $fee
      $sl = Get-SleeveRef 'setA'
      $sl.eq_rub = [double]$sl.eq_rub + $pnl
      $c.realized_rub = [double]$c.realized_rub + $pnl
      $c.fees_rub = [double]$c.fees_rub + $fee
      $c.lots = [int]$c.lots - $half
      $c.tp1_done = $true; $c.tp1_order_id = ''
      $script:ev.Add("TP1 fill $($c.id) $($c.asset) $half лот @$px")
      # стоп остатка в безубыток
      [void](Replace-CardStop $c ([double]$c.entry_px_pts))
    } else {
      $c.tp1_order_id = ''   # заявка исчезла без операции - перевыставим при следующем reconcile? нет: алерт
      Alert "TP1-заявка $($c.id) исчезла без операции - проверить вручную"
    }
  }
}

# ================= MTM / governors / отчёты =================
function Invoke-Mtm {
  $uids = New-Object System.Collections.Generic.List[string]
  foreach ($sn in 'core','setA') { foreach ($c in @($st.sleeves.$sn.positions)) { if (-not $uids.Contains([string]$c.uid)) { $uids.Add([string]$c.uid) } } }
  foreach ($h in @($st.sleeves.mom.holdings)) { if (-not $uids.Contains([string]$h.uid)) { $uids.Add([string]$h.uid) } }
  $px = @{}
  if ($uids.Count) {
    try {
      foreach ($lp in (Get-TiLastPrices $uids.ToArray())) {
        if ($null -eq $lp) { continue }
        $u = if ($lp.PSObject.Properties['instrumentUid']) { [string]$lp.instrumentUid } else { [string]$lp.instrument_uid }
        $px[$u] = [double](Q2D $lp.price)
      }
    } catch { Write-LiveLog "MTM: last prices недоступны: $($_.Exception.Message)" }
  }
  foreach ($sn in 'core','setA') {
    $sl = $st.sleeves.$sn
    $unreal = 0.0
    foreach ($c in @($sl.positions)) {
      $cur = if ($px.ContainsKey([string]$c.uid)) { [double]$px[[string]$c.uid] } else {
        $s = Get-Ser ([string]$c.asset); [double]$s[$s.Count - 1].c }
      $sm = if ($c.side -eq 'long') { 1.0 } else { -1.0 }
      $u = $sm * [double]$c.lots * ($cur - [double]$c.entry_px_pts) * [double]$c.rub_per_pt
      $c | Add-Member -NotePropertyName cur_px -NotePropertyValue ([math]::Round($cur, 6)) -Force
      $c | Add-Member -NotePropertyName upnl_rub -NotePropertyValue ([math]::Round($u, 2)) -Force
      $unreal += $u
    }
    $sl.equity_mtm = [math]::Round([double]$sl.eq_rub + $unreal, 2)
  }
  $m = $st.sleeves.mom
  $hv = 0.0
  foreach ($h in @($m.holdings)) {
    $cur = if ($px.ContainsKey([string]$h.uid)) { [double]$px[[string]$h.uid] } else { [double]$h.avg_px }
    $h.last_px = [math]::Round($cur, 4)
    $hv += [double]$h.lots * [double]$h.lot_size * $cur
  }
  $m.equity_mtm = [math]::Round([double]$m.cash_rub + $hv + ([double]$m.eq_rub - [double]$LIVE.base_rub) * 0, 2)
  # mom_eq = кэш + акции (реализованное уже в cash)
  $m.eq_rub = $m.equity_mtm
  # профиль: помесячно-аддитивно (как paper)
  $rC = ([double]$st.sleeves.core.equity_mtm / [double]$st.sleeves.core.month_start_eq) - 1
  $rA = ([double]$st.sleeves.setA.equity_mtm / [double]$st.sleeves.setA.month_start_eq) - 1
  $rM = ([double]$m.equity_mtm / [double]$m.month_start_eq) - 1
  $st.profile_eq = [math]::Round([double]$st.profile_month_start * (1 + $rC + $rA + [double]$LIVE.mom_weight * $rM), 2)
  if ([double]$st.profile_eq -gt [double]$st.peak_eq) { $st.peak_eq = [double]$st.profile_eq }
}

function Invoke-Governors {
  # HARD -35% от пика: закрыть всё + HALT_RF_LIVE (решение пользователя; помнить: бэктест-DD 40-44%)
  $dd = 1.0 - [double]$st.profile_eq / [double]$st.peak_eq
  if ($dd -gt 0.90) {
    # санити-гард (урок песочницы 2026-07-17: мусорные котировки дали «DD 25044%»): DD>90% - почти
    # наверняка ошибка данных, а не рынок -> НЕ флэттенить по ней; стоп входов + ручной разбор
    Alert ("DD {0:P0} > 90% - похоже на ошибку данных MTM, флэттен НЕ выполняется, входы остановлены" -f $dd)
    Set-EntriesHalt 'suspicious DD>90% (data error?)'
    return
  }
  if ($dd -ge [double]$LIVE.hard_dd) {
    Alert ("HARD-HALT: DD {0:P1} от пика - закрываю всё и останавливаюсь" -f $dd)
    foreach ($sn in 'core','setA') {
      foreach ($c in @($st.sleeves.$sn.positions)) { Invoke-EmergencyClose $c 'hard-dd' }
    }
    foreach ($h in @($st.sleeves.mom.holdings)) {
      $it = New-Intent 'mom_sell' @{ sleeve = 'mom'; ticker = [string]$h.sym; uid = [string]$h.uid
        side = 'sell'; lots = [int]$h.lots; ctx = [pscustomobject]@{ ref_px = [double]$h.last_px } }
      Save-State
      [void](Post-IntentMarket $it 'sell' ([int]$h.lots))
    }
    Set-Content (Join-Path $Root 'data\HALT_RF_LIVE') "hard-dd $(MsToUtcStr $NowMs)" -Encoding UTF8
    return
  }
  # профиль-день -8% -> entries_halt до завтра
  if ([double]$st.day_start_eq -gt 0) {
    $dl = 1.0 - [double]$st.profile_eq / [double]$st.day_start_eq
    if ($dl -ge [double]$LIVE.profile_day_halt) { Set-EntriesHalt ("profile day -{0:P1}" -f $dl) }
  }
  # ГО-мониторинг (нюанс #12): >60% -> entries_halt; >75% -> LIFO-закрытие
  if ([double]$st.go.budget_rub -gt 0) {
    $goPct = [double]$st.go.used_rub / [double]$st.go.budget_rub
    if ($goPct -gt [double]$LIVE.go_trim_pct) {
      $newest = $null
      foreach ($sn in 'core','setA') {
        foreach ($c in @($st.sleeves.$sn.positions)) { if ($null -eq $newest -or [long]$c.entry_ts -gt [long]$newest.entry_ts) { $newest = $c } }
      }
      if ($null -ne $newest) {
        Alert ("ГО {0:P0} > {1:P0} - LIFO-закрытие $($newest.id)" -f $goPct, [double]$LIVE.go_trim_pct)
        Invoke-EmergencyClose $newest 'go-trim'
      }
    } elseif ($goPct -gt [double]$LIVE.go_cap_pct) {
      Set-EntriesHalt ("ГО {0:P0} > кэпа" -f $goPct)
    }
  }
}

function Save-EquitySnapshot {
  if (($NowMs - [long]$st.watermarks.last_eq_snap) -lt 15 * 60000) { return }
  $st.watermarks.last_eq_snap = $NowMs
  $eqPath = Join-Path $lrfDir 'equity.json'
  $eq = New-Object System.Collections.Generic.List[object]
  foreach ($x in @((Read-JsonFile $eqPath))) { if ($null -ne $x) { $eq.Add($x) } }
  $stockVal = 0.0
  foreach ($h in @($st.sleeves.mom.holdings)) { $stockVal += [double]$h.lots * [double]$h.lot_size * [double]$h.last_px }
  $liq = if ($st.go.PSObject.Properties['account_liquid_rub']) { [double]$st.go.account_liquid_rub } else { $null }
  $cap = if ($st.go.PSObject.Properties['bot_capital_rub']) { [double]$st.go.bot_capital_rub } else { $null }
  $eq.Add([pscustomobject]@{ utc = (MsToUtcStr $NowMs); ts = $NowMs
    total = [double]$st.profile_eq; core = [double]$st.sleeves.core.equity_mtm; setA = [double]$st.sleeves.setA.equity_mtm
    mom = [double]$st.sleeves.mom.equity_mtm; go_used = [double]$st.go.used_rub; stock_val = [math]::Round($stockVal, 0)
    account_liquid = $liq; bot_capital = $cap })
  Write-JsonAtomic $eqPath (ToArr $eq) 4
}

function Invoke-DailyReport {
  if ([string]$st.watermarks.last_report_day -eq $mskToday) { return }
  $st.watermarks.last_report_day = $mskToday
  $ratio = if ([int]$st.stats.fills -gt 0) { [math]::Round([double]$st.stats.orders_posted / [double]$st.stats.fills, 1) } else { 0 }
  $txt = ("RF-LIVE дневной отчёт {0}: eq={1} (день {2:+0.0;-0.0}%), core={3} setA={4} mom={5}, ГО пик {6} ₽, заявки:сделки {7}:1, дрифты D2/D4/D5/D6={8}/{9}/{10}/{11}, qty0-пропуски {12}" -f `
    $mskToday, $st.profile_eq, (100.0 * ([double]$st.profile_eq / [double]$st.day_start_eq - 1)), `
    $st.sleeves.core.equity_mtm, $st.sleeves.setA.equity_mtm, $st.sleeves.mom.equity_mtm, `
    $st.go.peak_day_rub, $ratio, $st.drift.D2, $st.drift.D4, $st.drift.D5, $st.drift.D6, $st.stats.skipped_qty0)
  $script:jr.Add("`r`n## $(MsToUtcStr $mskNowMs) MSK — $txt`r`n")
  try { Send-TgAlert $txt | Out-Null } catch {}
  # фан-аут дневного отчёта второму получателю (только фьючерсы)
  if ($env:TG_CHAT_ID_FUT) { try { Send-TgAlert $txt -Chat $env:TG_CHAT_ID_FUT | Out-Null } catch {} }
}

# ================= RUN: пайплайн тика =================
$lockPath = Join-Path $lrfDir 'engine.lock'
try {
  # lock со stale-takeover (двойной запуск гасится ещё и flock'ом в live_rf_tick.sh)
  if (Test-Path $lockPath) {
    $age = ((Get-Date).ToUniversalTime() - (Get-Item $lockPath).LastWriteTimeUtc).TotalSeconds
    if ($age -lt 110) { Write-LiveLog "tick skipped: lock busy (${age}s)"; return }
    Remove-Item $lockPath -Force
  }
  Set-Content $lockPath "pid=$PID $(MsToUtcStr $NowMs)" -Encoding ASCII

  # 1. kill-файлы
  if ((Test-Path (Join-Path $Root 'data\HALT')) -or (Test-Path (Join-Path $Root 'data\HALT_RF_LIVE'))) {
    Write-LiveLog 'tick: HALT/HALT_RF_LIVE - выход'; return
  }
  if (Test-Path (Join-Path $Root 'data\HALT_RF_CLOSE')) {
    Write-LiveLog 'tick: HALT_RF_CLOSE - аварийное закрытие всего'
    foreach ($sn in 'core','setA') { foreach ($c in @($st.sleeves.$sn.positions)) { Invoke-EmergencyClose $c 'halt-close' } }
    Invoke-IntentPolling
    Save-State
    return
  }
  if (Test-Path (Join-Path $Root 'data\HALT_RF_ENTRIES')) { Set-EntriesHalt 'HALT_RF_ENTRIES file' }

  # 2. выходные: лёгкий тик (сверка раз в ~30 мин, никаких заявок)
  $weekendLight = ((Test-Weekend) -and -not $LIVE.trade_weekends)

  # 3. preflight: маржа/ликвидность; фолбэк MarginAttributes -> GetPortfolio (песочница: 404,
  # prod без маржиналки: то же); полный сбой -> тик прерван, вотермарки не двигаются
  $margin = $null
  $pfPre = $null   # снимок портфеля для расчёта точного капитала (переиспользуем фолбэк-фетч)
  try { $margin = Get-TiMarginAttributes ([string]$st.account_id) } catch {
    try {
      $pfPre = Get-TiPortfolio ([string]$st.account_id)
      $margin = [pscustomobject]@{ liquid = [double](M2D (Get-TiField $pfPre 'total_amount_portfolio')).value }
    } catch {
      Write-LiveLog "preflight: маржа и портфель недоступны: $($_.Exception.Message)"
      $st | Add-Member -NotePropertyName consec_fail -NotePropertyValue ([int]$st.consec_fail + 1) -Force
      if ([int]$st.consec_fail -eq 5) { Alert 'preflight: 5 сбоев подряд' }
      Save-State
      return
    }
  }
  $st | Add-Member -NotePropertyName consec_fail -NotePropertyValue 0 -Force
  Update-GoBudget $margin
  Set-BotCapital $pfPre   # $null если маржа сработала -> функция дотянет GetPortfolio сама

  # 4. сверка (полная, каждый тик - нюансы #3/#4/#13): снимок стоп-заявок -> TP1-sync (ДО D5,
  # иначе усечение лотов опередит объяснение частичного филла) -> reconcile
  $stopIds = Get-BrokerStopIds
  Invoke-Tp1Sync $stopIds
  Invoke-Reconcile $stopIds

  # 5. state machine polling
  Invoke-IntentPolling

  # 6. MTM + governors
  Invoke-Mtm
  Invoke-Governors

  # 7. расписание (MSK), всё идемпотентно через вотермарки
  if (-not $weekendLight) {
    if ($mskHHmm -ge '00:20' -and [string]$st.watermarks.last_daily_day -lt $completedDay) { Invoke-LiveDaily }
    if ((In-Window ([string]$LIVE.entry_from) ([string]$LIVE.entry_till)) -and (Can-PostOrders)) { Invoke-EntryWindow }
    if ((In-Window ([string]$LIVE.roll_from) ([string]$LIVE.roll_till)) -and (Can-PostOrders)) { Invoke-RollWindow }
    if ($mskHHmm -ge [string]$LIVE.mom_from -and $mskHHmm -le '18:00' -and (Can-PostOrders)) { Invoke-MomWindow }
    Invoke-HourlyPass   # частоту гейтит вотермарка last_hour_ts (новых закрытых часовиков нет - выходит сразу)
    if ($mskHHmm -ge [string]$LIVE.report_at) { Invoke-DailyReport }
    # отложенные обновления стопов (после 00:20-хука вне сессии)
    if ($mskHHmm -ge '09:45' -and (Can-PostOrders)) {
      foreach ($sn in 'core','setA') {
        foreach ($c in @($st.sleeves.$sn.positions | Where-Object { $null -ne $_.stop_deferred })) {
          $ns = [double]$c.stop_deferred; $c.stop_deferred = $null
          [void](Replace-CardStop $c $ns)
        }
      }
    }
    Invoke-IntentCleanup   # терминальные интенты окон убираем в этом же тике
  }

  # 8. ops-вотермарка вперёд (операции старше часа уже учтены сверками)
  $script:opsCache = $null
  $st.watermarks.ops_since = (MsToUtc ($NowMs - 3600000)).ToString('yyyy-MM-ddTHH:mm:ssZ')

  # 9. persist + снапшоты + журнал
  Save-EquitySnapshot
  Save-State
  if ($script:jr.Count) { Write-LiveJournal ($script:jr -join '') }
  $evTxt = if ($script:ev.Count) { $script:ev -join '; ' } else { '-' }
  Write-LiveLog ("tick ok: {0} | eq={1} go={2}/{3}" -f $evTxt, $st.profile_eq, $st.go.used_rub, $st.go.budget_rub)
  "RF-LIVE тик: $evTxt | eq $($st.profile_eq)"
} catch {
  # два кадра стека: видно и место броска, и вызывающего (инцидент 2026-07-20: один кадр
  # показывал только Invoke-TInvest, виновный вызов пришлось восстанавливать форензикой)
  $frames = @($_.ScriptStackTrace -split "`n" | Select-Object -First 2) -join ' <- '
  Write-LiveLog ("tick ERROR: " + $_.Exception.Message + ' @ ' + $frames)
  try { Save-State } catch {}
  Write-Warning "RF-LIVE: тик отменён: $($_.Exception.Message)"
} finally {
  if (Test-Path $lockPath) { Remove-Item $lockPath -Force -ErrorAction SilentlyContinue }
}
