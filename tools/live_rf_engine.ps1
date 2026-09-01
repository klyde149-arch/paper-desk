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
  [switch]$DryRun,         # форс dryrun поверх TINVEST_MODE
  [switch]$ReportNow       # разово собрать и отправить вечерний отчёт с текущими числами и выйти (без сохранения состояния)
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'lib_engine.ps1')
. (Join-Path $PSScriptRoot 'lib_rf_signals.ps1')
. (Join-Path $PSScriptRoot 'lib_tinvest.ps1')
. (Join-Path $PSScriptRoot 'lib_msg_ru.ps1')
$namesRu = Get-RuNames $Root
$alertsLib = Join-Path $PSScriptRoot 'lib_alerts.ps1'
if (Test-Path $alertsLib) { . $alertsLib } else { function Send-TgAlert([string]$Text, [string]$Chat = '') { $false } }

# ================= конфиг live-контура =================
$LIVE = [ordered]@{
  base_rub          = 700000.0   # база каждого sleeve-леджера (решение пользователя 2026-07-15)
  core_risk         = 0.05       # C3b ядро
  seta_risk         = 0.02       # C3b setup A
  mom_weight        = 0.5        # mom покупает на 0.5 x mom_eq
  go_cap_pct        = 0.60       # свой стоп по ГО: вход запрещён выше (боевой нюанс #6)
  go_trim_pct       = 0.75       # выше - LIFO-закрытие последней позиции
  reserve_rub       = 50000.0    # неприкосновенный резерв вне ГО-бюджета
  margin_disabled   = $false     # маржиналка на счёте отключена -> не звать GetMarginAttributes
  long_only         = @('VTBR','SBRF')   # активы, по которым разрешён ТОЛЬКО лонг (см. Test-SideAllowed)
  profile_day_halt  = 0.08       # доп. предохранитель: профиль-день -8% -> entries_halt до завтра
  hard_dd           = 0.35       # АВАРИЙНЫЙ СТОП: -35% от пика -> закрыть всё + HALT_RF_LIVE (решение пользователя)
  max_orders_day    = 20         # предохранитель флуда (нюанс #11: сделки:заявки не хуже 1:10)
  max_attempts      = 3          # лимит попыток state machine на intent
  fee_est           = 0.00025    # тариф Т-Инвест фьючерсы: 0.025% за сторону (уточнено пользователем 2026-08-13)
  # ЕТС-2026 (боевой факт 2026-07-17): торги с 06:00-07:00 MSK (утренняя сессия), paper входит по
  # open ПЕРВОГО часовика дня -> live-вход с самого утра; TradingStatus-гейт держит интент до
  # реального открытия инструмента, окно широкое (до 10:15) на случай позднего старта.
  entry_from = '06:01'; entry_till = '10:15'   # окно входов/выходов «на открытии» (MSK)
  roll_from  = '06:05'; roll_till  = '18:00'   # окно роллов
  mom_from   = '06:10'                          # mom-ребаланс
  report_at  = '23:55'                          # вечерний отчёт (МСК) - после закрытия вечерней сессии FORTS (~23:50)
  whitelist  = @()               # Phase 3: @('CNY','NG'); пусто = весь универсум
  max_lots_override = 0          # Phase 3: 1 (0 = без лимита)
  mom_enabled = $true            # Phase 3: $false
  trade_weekends = $false        # выходные внебиржевые сессии НЕ торгуем (нюанс #8)
  emulate_stops = $false         # sandbox: StopOrders нет -> бот-сайд эмуляция по LastPrices
  auto_rebase = $null            # { enabled, drift_pct, max_step_pct } - включается через config.json (решение 2026-08-13)
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
$script:DirectSleeveAccess = ([string]$env:LIVE_RF_DIRECT_SLEEVE_ACCESS -eq '1')
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
function Alert([string]$Text, [switch]$Client) {
  $script:ev.Add("ALERT $Text")
  [void](Send-RfTelegram "Фьючерсы: $Text")
  # Фан-аут клиенту (TG_CHAT_ID_FUT) - ТОЛЬКО события по его деньгам: входы, выходы,
  # аварийные остановки. Техническая диагностика (роллы, дрифт, состояния заявок, суточные
  # проверки) остаётся у владельца. Дефолт НЕ клиентский нарочно: забытая пометка -Client
  # даёт недосказанность, а забытое исключение дало бы утечку технической кухни клиенту.
  if ($Client -and $env:TG_CHAT_ID_FUT) { [void](Send-RfTelegram "Фьючерсы: $Text" -Chat $env:TG_CHAT_ID_FUT) }
}
function Send-RfTelegram([string]$Text, [string]$Chat = '') {
  $ok = $false
  try { $ok = if ($Chat) { Send-TgAlert $Text -Chat $Chat } else { Send-TgAlert $Text } }
  catch { $script:TgLastError = 'exception' }
  if ($ok -ne $true) {
    $why = if ($script:TgLastError) { [string]$script:TgLastError } else { 'unknown' }
    Write-LiveLog "tg fail: $why"
  }
  return $ok
}
function SleeveRu([string]$s) { switch ($s) { 'core' { 'ядро' } 'setA' { 'сетап А' } 'mom' { 'портфель акций' } default { $s } } }
function RfName($Card) { RuName $namesRu 'fut' ([string]$Card.asset) ([string]$Card.secid) }
function AssetName([string]$Asset, [string]$Secid = '') { if ($Asset) { RuName $namesRu 'fut' $Asset $Secid } elseif ($Secid) { $Secid } else { '?' } }
function RfReasonRu([string]$Reason) {
  switch -Wildcard ($Reason) {
    'be*'        { return 'стоп на цене входа (без убытка)' }
    'stop*'      { return 'сработала стоп-заявка' }
    'tp*'        { return 'достигнута цель' }
    'exit*'      { return 'закрытие по сигналу стратегии' }
    'go-trim'    { return 'закрытие из-за нехватки обеспечения' }
    'hard-dd'    { return 'аварийная остановка -35%' }
    'emergency*' { return 'аварийное закрытие' }
    'stop-after-entry-fail' { return 'аварийное закрытие (не удалось выставить стоп)' }
    'manual-ext' { return 'закрыто вне бота (стоп-заявка не срабатывала)' }
    'manual*'    { return 'закрыто вручную' }
    default      { return $Reason }
  }
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
    Alert "новые входы приостановлены ($Reason). Открытые позиции продолжают вестись как обычно."
  } elseif ([string]$st.entries_halt.reason -like 'ГО *' -and $Reason -like 'ГО *' -and [string]$st.entries_halt.reason -ne $Reason) {
    # тот же ГО-халт, но процент уехал: освежаем текст, не трогая since и без повторного алерта.
    # ВАЖНО: обновляем ТОЛЬКО внутри одной категории - иначе ГО-причина могла бы затереть,
    # например, дрифт-халт D4, и Clear-EntriesHalt снял бы его, пока расхождение ещё живо.
    $st.entries_halt.reason = $Reason
  }
}
# снятие халта: применять только к своей категории причин (см. Set-EntriesHalt). Дрифт-халты
# снимаются в Invoke-Reconcile, дневные - в дневном хуке.
function Clear-EntriesHalt([string]$Why) {
  if (-not $st.entries_halt.active) { return }
  Write-LiveLog "entries_halt снят: $Why (было: '$($st.entries_halt.reason)')"
  $st.entries_halt.active = $false; $st.entries_halt.reason = ''; $st.entries_halt.since = ''
  Alert "новые входы возобновлены ($Why)."
}

# цена филла ЗА ЕДИНИЦУ из ответа PostOrder/GetOrderState. Боевые факты:
# executed_order_price = ИТОГО в РУБЛЯХ за все лоты (песочница 2026-07-17) - это цена
#   ИСПОЛНЕНИЯ, единственное поле ответа, отражающее реальную сделку;
# initial_order_price_pt = пункты ЗА 1 ЛОТ, а НЕ сумма (прод 2026-07-21, инцидент L00008:
#   BR 6 лот, поле=88.99, деление на лоты записало вход 14.83 -> фантом +497%, стоп 7.9).
#   Но это цена ПОДАННОЙ заявки: у рыночной заявки MOEX она идёт с защитной полосой
#   (~0.2% в сторону сделки), а не по факту сделки.
# ПОРЯДОК КАНДИДАТОВ (инцидент 2026-08-04): сначала исполненная цена, потом поданная.
# Раньше первым стоял initial_order_price_pt и всегда выигрывал - расхождение 0.2%
# проходит сквозь 30%-ые ворота незаметно. Итог: три записанных входа подряд легли ВНЕ
# диапазона рынка и всегда в худшую сторону (Si 81794 при максимуме за 30 дней 81650,
# CNY 12.111 при 12.089, GOLD-шорт 4037.9 при минимуме дня 4041.3); стоп считается от
# входа, поэтому был на ~10% теснее задуманных 2xATR, а P&L нёс фантомный минус.
# Семантика полей уже дважды расходилась с ожиданием, поэтому слепо не верим ни одной
# трактовке: кандидаты проверяются лестницей против референса (ref_px сигнала ->
# рублёвый пересчёт -> карточка), берётся первый в пределах 30%; ни одного = не
# распарсилось ($null -> референс). Окончательная истина - операции брокера, см.
# Confirm-EntryPx: цена сделки подтверждается по ним и карточка чинится сама.
function Get-FillPxPerUnit($It, $Resp, [int]$Lots) {
  if ($Lots -le 0 -or $null -eq $Resp) { return $null }
  $isShare = ([string]$It.kind -like 'mom_*')
  try {
    $inst = Get-Inst ([string]$It.ticker) $(if ($isShare) { 'share' } else { 'fut' })
    $totRub = 0.0
    try { $totRub = [double](M2D (Get-TiField $Resp 'executed_order_price')).value } catch {}
    if ($isShare) {
      if ($totRub -gt 0) { return [math]::Round($totRub / $Lots / [double]$inst.lot, 6) }
      return $null
    }
    $ptRaw = 0.0
    try { $ptRaw = [double](Q2D (Get-TiField $Resp 'initial_order_price_pt')) } catch {}
    $rubPx = if ($totRub -gt 0 -and [double]$inst.rub_per_pt -gt 0) { $totRub / $Lots / [double]$inst.rub_per_pt } else { 0.0 }
    # референс: цена сигнала (entry) -> рублёвый пересчёт -> карточка (exit/roll)
    $ref = 0.0
    if ($null -ne $It.ctx -and $It.ctx.PSObject.Properties['ref_px'] -and [double]$It.ctx.ref_px -gt 0) { $ref = [double]$It.ctx.ref_px }
    if ($ref -le 0 -and $rubPx -gt 0) { $ref = $rubPx }
    if ($ref -le 0 -and $null -ne $It.ctx -and $It.ctx.PSObject.Properties['card_id']) {
      $rc = Find-Card ([string]$It.ctx.card_id)
      if ($null -ne $rc) {
        if ($rc.PSObject.Properties['cur_px'] -and [double]$rc.cur_px -gt 0) { $ref = [double]$rc.cur_px }
        elseif ([double]$rc.entry_px_pts -gt 0) { $ref = [double]$rc.entry_px_pts }
      }
    }
    if ($ref -le 0) { return $null }
    # расхождение «исполнено vs подано» — то самое, что скрывалось за 30%-ыми воротами.
    # Пишем в лог всегда: если брокер однажды поменяет семантику, это будет видно сразу.
    if ($rubPx -gt 0 -and $ptRaw -gt 0 -and [math]::Abs($ptRaw / $rubPx - 1) -gt 0.0005) {
      Write-LiveLog ("fill $($It.id) $($It.ticker): исполнено $([math]::Round($rubPx,6)) vs подано $([math]::Round($ptRaw,6)) (расх. $([math]::Round(100*($ptRaw/$rubPx-1),3))%) - берём исполненную")
    }
    # лестница: исполненная цена (из рублей) -> pt за 1 лот (прод) -> pt/лоты (если поле вдруг сумма)
    foreach ($x in @($rubPx, $ptRaw, $(if ($ptRaw -gt 0) { $ptRaw / $Lots } else { 0.0 }))) {
      if ($x -gt 0 -and [math]::Abs($x / $ref - 1) -le 0.30) { return [math]::Round($x, 6) }
    }
    return $null
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
      Alert ("брокер отклонил заявку по {0}: {1}." -f (AssetName ([string]$It.asset) ([string]$It.ticker)), $emsg)
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
function Get-SleeveRef([string]$Name) {
  if (-not $script:DirectSleeveAccess) { return $st.sleeves.$Name }
  # Canary path for the staged refactor: preserve the legacy null result for an unknown sleeve.
  $prop = $st.sleeves.PSObject.Properties[$Name]
  if ($null -eq $prop) { return $null }
  return $prop.Value
}
# Стоп-маркет не исполняется ЛУЧШЕ своего триггера: лонг срабатывает при падении до уровня и
# заливается по биду (на уровне или хуже), шорт - зеркально. Значит выход строго лучше стопа
# карточки = закрытие пришло НЕ от стоп-заявки (руками в приложении, брокером, чем угодно).
# Допуск 0.1% съедает округление стопа к min_price_increment и расхождение после уточнения
# цены входа по операциям (живую стоп-заявку бот намеренно не двигает, см. Invoke-ConfirmEntryPx).
function Test-StopCouldFire($Card, [double]$FillPx) {
  $sp = [double]$Card.stop_px_pts
  if ($sp -le 0) { return $true }              # стопа нет - судить не по чему, не выдумываем
  $sm = if ([string]$Card.side -eq 'long') { 1.0 } else { -1.0 }
  $tol = 0.001 * [math]::Abs($sp)
  return (($sm * ($FillPx - $sp)) -le $tol)
}
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
    exitReason = $Reason; stopPx = [math]::Round([double]$Card.stop_px_pts, 6); pnlRub = $net
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
  if ($Reason -ne 'roll') {
    $holdD = ($NowMs - [long]$Card.entry_ts) / 3600000.0
    $rM = if ([double]$Card.risk_rub -gt 0) { $net / [double]$Card.risk_rub } else { $null }
    $rTailC = if ($null -ne $rM) { " — это $((('{0:0.##}' -f [math]::Abs($rM)).Replace('.',','))) изначального риска" } else { '' }
    Alert -Client (
      ("закрыта позиция {0} — {1}, была {2} {3} {4} по {5}." -f $Card.id, (RfName $Card), (RuSide $Card.side 'noun'), [int]$Card.lots_initial, (RuLots ([int]$Card.lots_initial)), (Fmt-Px ([double]$Card.entry_px_pts))) +
      ("`nРезультат: {0} ({1}){2}." -f (Fmt-Money $net '₽' 0 -Sign), (RfReasonRu $Reason), $rTailC) +
      ("`nВыход по {0}, позиция держалась {1}." -f (Fmt-Px ([double]$ExitPx)), (RuHoldRu $holdD)) +
      ("`nКапитал бота: {0}." -f (Fmt-Money ([double]$st.profile_eq) '₽' 0)))
  }
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
  Alert ("по позиции {0} ({1}) пропал стоп у брокера, не удалось выставить заново — попытка {2} из 2 (код D6). Если не удастся, позиция будет закрыта принудительно." -f $Card.id, (RfName $Card), [int]$Card.d6_fails)
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
    Alert ("не удалось переставить стоп по позиции {0} ({1}) — позиция закрывается по рынку для безопасности." -f $Card.id, (RfName $Card))
    Invoke-EmergencyClose $Card 'stop-replace-fail'
  }
  return $ok
}
function Invoke-EmergencyClose($Card, [string]$Why) {
  # аварийное закрытие: cancel стопа + market в обратную сторону (write-ahead)
  $script:ev.Add("EMERGENCY CLOSE $($Card.id) $($Card.asset) ($Why)")
  Alert -Client ("аварийное закрытие позиции {0} ({1}). Причина: {2}." -f $Card.id, (RfName $Card), (RfReasonRu $Why))
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
    # сессия funding-инструмента != сессия фьючерса: металлы CETS открываются в 10:00 MSK,
    # FORTS - в 07:00. Заявка в закрытый рынок = 400 (инцидент 2026-07-20: продажа серебра
    # в 07:00 под вход BR). Не торгуется - интент входа ждёт следующего тика.
    if (-not (Test-InstrumentTrading $uid)) { Write-LiveLog "funding: $($inst.ticker) сейчас не торгуется - пропуск"; continue }
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
    Alert ("не хватает свободных рублей для «{0}»: нужно около {1}, свободно {2}. Продайте доллары вручную в приложении брокера — программный обмен валюты недоступен." -f $Why, (Fmt-Money ([math]::Round($NeedRub, 0)) '₽' 0), (Fmt-Money ([math]::Round($free, 0)) '₽' 0))
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
    # снапшот РЕАЛЬНОГО счёта для терминала (readonly-данные, обновляется каждый тик).
    # ПУСТОЙ/БИТЫЙ снимок (liquid<=0, транзиентный глюк брокера - инцидент 2026-07-23) НЕ затираем:
    # реальный счёт всегда >0; иначе в кривую капитала попадёт нулевая точка (фантомная просадка).
    if ($liquid -gt 0) {
      $st.go | Add-Member -NotePropertyName account_liquid_rub -NotePropertyValue ([math]::Round($liquid, 2)) -Force
    } else {
      Write-LiveLog 'Update-GoBudget: снимок счёта пустой (liquid<=0) - account_liquid_rub не обновлён (несём прошлое)'
    }
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
  # бот работает «свободными деньгами»: бюджет от РЕАЛЬНОГО капитала бота (bot_capital_rub, Set-BotCapital
  # прошлого тика - на первом тике после деплоя ещё не посчитан, тогда фолбэк на base_rub), а не от
  # статичной базы 2026-07-15 (решение пользователя 2026-08-12: потолок ГО должен расти вместе со счётом,
  # иначе после ~2 месяцев роста капитала бот всё ещё торговал бы на стартовые 700k).
  $realCapForGo = if ($st.go.PSObject.Properties['bot_capital_rub'] -and [double]$st.go.bot_capital_rub -gt 0) { [double]$st.go.bot_capital_rub } else { [double]$LIVE.base_rub }
  $st.go.budget_rub = [math]::Round($realCapForGo - $stockVal - [double]$LIVE.reserve_rub, 2)
  if ([double]$st.go.used_rub -gt [double]$st.go.peak_day_rub) { $st.go.peak_day_rub = [double]$st.go.used_rub }
}
# Восстановить реальный исторический пик bot_capital из equity.json (вызывается один раз,
# при первом тике после деплоя этого кода - дальше пик просто растёт монотонно, как peak_day_rub).
# ПОЧЕМУ не с нуля: пик 2026-08-06 руками сверен по data/live_rf/equity.json (поле bot_capital -
# реальная брокерская var_margin, НЕ наш расчёт по цене входа, поэтому не подвержен багам класса
# L00008): первая точка 768793.33 (17.07 20:01), гладкий рост без единого скачка до истинного
# максимума 824650.96 (23.07 18:06 - бумажный пик по нефти L00008 BR, который потом растаял до
# +1508.67 при закрытии 27.07). Обнулять эту историю - терять реальную просадку бота.
function Get-CapitalPeakSeed {
  $eqPath = Join-Path $lrfDir 'equity.json'
  $best = 0.0
  foreach ($r in @(Read-JsonFile $eqPath)) {
    if ($null -eq $r -or -not $r.PSObject.Properties['bot_capital'] -or $null -eq $r.bot_capital) { continue }
    $liq = if ($r.PSObject.Properties['account_liquid']) { $r.account_liquid } else { $null }
    if ($null -eq $liq -or [double]$liq -le 0) { continue }   # тот же фильтр битых снимков, что и build_vizdata.ps1
    $v = [double]$r.bot_capital
    if ($v -gt $best) { $best = $v }
  }
  return $best
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
  $t = Get-TiField $Pf 'total_amount_portfolio';  if ($null -ne $t) { $totRub = [double](M2D $t).value }
  # ПУСТОЙ/БИТЫЙ снимок портфеля: total_amount_portfolio<=0 - брокер вернул нулевой счёт
  # (транзиентный глюк, инцидент 2026-07-23). Реальный счёт всегда >0. Мусорный bot_capital
  # (напр. 21k вместо 796k) рисует фантомную просадку ~97% в кривой капитала -> НЕ затираем,
  # несём последнее валидное значение bot_capital_rub/capital_breakdown.
  if ($totRub -le 0) {
    Write-LiveLog 'Set-BotCapital: снимок портфеля пустой (total_amount_portfolio<=0) - bot_capital не обновлён (несём прошлое)'
    return
  }
  # фьючерсы: вклад в капитал = ВАРИАЦИОННАЯ МАРЖА, НЕ total_amount_futures (инцидент 2026-07-21:
  # total_amount_futures = НОМИНАЛ позиции ~416k, но эти деньги не приходят на счёт - капитал бота
  # «вырастал» на номинал при каждом входе; сам брокер в total_amount_portfolio номинал не считает).
  # Приоритет: var_margin позиций (боевой факт: несведённая вариационка) -> Σ upnl карточек (sandbox/mock).
  $gotVm = $false
  # ---- ДОСЛОВНЫЙ снимок брокера (без единой арифметической операции) ----
  # ЗАЧЕМ: каждое число, которое мы пересчитываем сами, - это ещё один шанс разойтись с
  # приложением Т-Инвестиций, и такие расхождения уже стоили инцидентов (L00008 2026-07-21,
  # двойной счёт вариационки 2026-09-01). Что брокер прислал - то и кладём; отчётные
  # поверхности (дашборд, Mini App, вечерний отчёт) показывают ИМЕННО это, а не наш пересчёт.
  # Новых вызовов API нет: $Pf уже получен preflight-ом главного цикла.
  $brokerPnl = [pscustomobject]@{}
  $brkPos = New-Object System.Collections.Generic.List[object]
  foreach ($p in @($Pf.positions)) {
    if ($null -eq $p) { continue }
    $itype = [string](Get-TiField $p 'instrument_type')
    $puid = [string](Get-TiField $p 'instrument_uid')
    # строка снимка пишется по ВСЕМ типам инструментов, не только по фьючерсам: серебро
    # (funding-пул) приходит как currency и нужно для сверки состава капитала.
    $brkPos.Add([pscustomobject]@{
      uid = $puid; type = $itype
      ticker = [string](Get-TiField $p 'ticker'); figi = [string](Get-TiField $p 'figi')
      lots = (TiNum $p 'quantity_lots' 4); qty = (TiNum $p 'quantity' 4)
      avg_px = (TiNum $p 'average_position_price' 6); cur_px = (TiNum $p 'current_price' 6)
      expected_yield = (TiNum $p 'expected_yield' 2)
      var_margin = (TiNum $p 'var_margin' 2); var_margin_settled = (TiNum $p 'var_margin_settled' 2)
    })
    if ($itype -ne 'futures') { continue }
    $vm = Get-TiField $p 'var_margin'
    if ($null -ne $vm) { $futRub += [double](M2D $vm).value; $gotVm = $true }
    # брокерский P&L по инструменту (expected_yield = накопленная вариационка с момента, когда
    # позиция по контракту была нулевой; включает уже закрытые внутри контракта лоты - сверено
    # по childOperations варьмаржи 2026-09-01) - заменяет наш внутренний upnl_rub везде, где
    # отчёт/дашборд показывают P&L конкретной позиции. Ключ - instrument_uid: если инструмент
    # держат оба рукава (редкий кейс, MAXPOS=3), делить по лотам - Get-CardPnlMap.
    $ey = Get-TiField $p 'expected_yield'
    if ($puid -and $null -ne $ey) {
      $brokerPnl | Add-Member -NotePropertyName $puid -NotePropertyValue ([math]::Round([double](M2D $ey).value, 2)) -Force
    }
  }
  $st | Add-Member -NotePropertyName broker_pnl_by_uid -NotePropertyValue $brokerPnl -Force
  $st | Add-Member -NotePropertyName broker -NotePropertyValue ([pscustomobject]@{
    captured_ms = $NowMs
    totals = [pscustomobject]@{
      portfolio  = (TiNum $Pf 'total_amount_portfolio' 2)
      currencies = (TiNum $Pf 'total_amount_currencies' 2)
      shares     = (TiNum $Pf 'total_amount_shares' 2)
      bonds      = (TiNum $Pf 'total_amount_bonds' 2)
      etf        = (TiNum $Pf 'total_amount_etf' 2)
      # НОМИНАЛ позиций, а не деньги: брокер сам не кладёт его в total_amount_portfolio.
      # Хранится только как memo для сверки (инцидент 2026-07-21).
      futures_nominal = (TiNum $Pf 'total_amount_futures' 2)
    }
    expected_yield_pct  = (TiNum $Pf 'expected_yield' 4)
    daily_yield_rub     = (TiNum $Pf 'daily_yield' 2)
    daily_yield_rel_pct = (TiNum $Pf 'daily_yield_relative' 4)
    positions = (ToArr $brkPos)
  }) -Force
  if (-not $gotVm) {
    foreach ($sn in 'core','setA') {
      foreach ($cc in @($st.sleeves.$sn.positions)) {
        if ($cc.PSObject.Properties['upnl_rub']) { $futRub += [double]$cc.upnl_rub }
      }
    }
  }
  $momRub = 0.0
  foreach ($h in @($st.sleeves.mom.holdings)) { $momRub += [double]$h.lots * [double]$h.lot_size * [double]$h.last_px }
  $cap = [math]::Round($curRub + $futRub + $momRub, 2)
  if ($cap -le 0 -and $totRub -gt 0) { $cap = [math]::Round($totRub, 2) }   # sandbox/фолбэк: нет разбивки -> весь портфель
  # ТЕНЕВОЙ капитал по модели «счёт брокера»: валюты + акции бота, БЕЗ вариационки.
  # Вариационка уже ВНУТРИ total_amount_currencies - сверено на боевом счёте 2026-09-01:
  # рубли 1 249 607,14 + серебро 319 050,00 = 1 568 657,14 = total_amount_currencies =
  # total_amount_portfolio (места для маржи нет), а daily_yield счёта = Σ var_margin позиций
  # + переоценка валют. Прибавляя её сверху, $cap завышал капитал на всю вариационку.
  # Пока это число НЕ участвует в торговле (ГО-бюджет и губернаторы по-прежнему на $cap) -
  # только отчётность; переключение модели - отдельный этап с ребейзом пика и day_start_eq.
  $capAcct = [math]::Round($curRub + $momRub, 2)
  if ($capAcct -le 0 -and $totRub -gt 0) { $capAcct = [math]::Round($totRub, 2) }
  $st.go | Add-Member -NotePropertyName bot_capital_account_rub -NotePropertyValue $capAcct -Force
  # чужие бумаги = тотал - валюты - акции бота. Вариационку НЕ вычитаем: её нет в тотале
  # отдельной строкой, и вычитание давало структурно отрицательный остаток (боевой факт до
  # 2026-09-01: user_assets = -96 972, дашборд обходил это костылём на своей стороне).
  $userRub = [math]::Round($totRub - $curRub - $momRub, 2)
  if ($userRub -lt 0) {
    Write-LiveLog "Set-BotCapital: user_assets=$userRub < 0 (акции бота больше акций на счёте?) - зажато в 0"
    $userRub = 0.0
  }
  $st.go | Add-Member -NotePropertyName bot_capital_rub -NotePropertyValue $cap -Force
  if (-not $st.go.PSObject.Properties['capital_peak_rub']) {
    $seed = Get-CapitalPeakSeed
    $st.go | Add-Member -NotePropertyName capital_peak_rub -NotePropertyValue ([math]::Max($seed, $cap)) -Force
    Write-LiveLog "Set-BotCapital: capital_peak_rub восстановлен из истории = $($st.go.capital_peak_rub)"
  } elseif ($cap -gt [double]$st.go.capital_peak_rub) {
    $st.go.capital_peak_rub = $cap
  }
  # futures здесь - MEMO (вариационная маржа за сегодня), а НЕ слагаемое капитала: она уже
  # внутри currencies. Тождество, которое обязано сходиться:
  # currencies + mom_shares + user_assets = portfolio_total.
  $st | Add-Member -NotePropertyName capital_breakdown -NotePropertyValue ([pscustomobject]@{
    currencies = [math]::Round($curRub, 2); futures = [math]::Round($futRub, 2)
    mom_shares = [math]::Round($momRub, 2); user_assets = $userRub; portfolio_total = [math]::Round($totRub, 2)
    capital_account = $capAcct; capital_legacy = $cap; model = 'legacy'
  }) -Force
}
# ================= брокерский леджер: реальные комиссии и вариационка =================
# ЗАЧЕМ. Два числа в отчётности были нашими оценками, а не фактом:
#  1) комиссии - леджер списывает LIVE.fee_est = 0,025%/сторону, факт по счёту ~0,043%
#     (21 684 ₽ против 8 362 ₽ за 17.07-01.09) - и реализованный P&L завышен на разницу;
#  2) «результат за всё время» считался от profile_eq (бумажная блендовая модель) и к этому
#     счёту отношения не имел вовсе.
# ЧТО СЧИТАЕМ. Итог бота = накопленная СВЕДЁННАЯ вариационка (операции клиринга) + текущая
# несведённая (var_margin позиций) - комиссии. Сверено поштучно на боевом счёте 2026-09-01:
# 60 379,99 + 99 844,00 - 21 684,47 = 138 539,52 ₽.
# ПОЧЕМУ НЕ «realized + brokerPnl открытых»: expected_yield брокера накапливается по КОНТРАКТУ
# с момента, когда позиция по нему была нулевой, поэтому у контракта, который бот переоткрывал
# внутри дня (CRU6/EuU6 27.08), он включает P&L уже закрытых сделок - те же деньги во второй
# раз пришли бы из trades.json (+84 тыс. лишних).
# Комиссии на СВОИ бумаги пользователя (продажи ПЛЗЛ/Сбера/облигаций/USD) в fees_rub не идут -
# бот их не платил; они лежат отдельно в fees_other_rub, чтобы ничего не терялось молча.
$script:BROKER_LEDGER_ID = 'v1-2026-09'
$script:BROKER_LEDGER_FROM = '23:00'   # после вечернего клиринга FORTS, до отчёта в 23:55
$script:FEE_OPS = @('OPERATION_TYPE_BROKER_FEE','OPERATION_TYPE_EXCHANGE_FEE',
  'OPERATION_TYPE_SERVICE_FEE','OPERATION_TYPE_MARGIN_FEE')

function Get-OpsWindowed([long]$FromMs, [long]$ToMs) {
  # GetOperations ограничивает длину диапазона - идём окнами по 31 дню.
  $out = New-Object System.Collections.Generic.List[object]
  $step = 31L * 24 * 3600 * 1000
  $a = $FromMs
  while ($a -lt $ToMs) {
    $b = [math]::Min($a + $step, $ToMs)
    $ops = Get-TiOperations ([string]$st.account_id) ((MsToUtc $a).ToString('yyyy-MM-ddTHH:mm:ssZ')) ((MsToUtc $b).ToString('yyyy-MM-ddTHH:mm:ssZ'))
    foreach ($o in @($ops)) { if ($null -ne $o) { $out.Add($o) } }
    $a = $b
  }
  return $out
}

function Invoke-BrokerLedger {
  if ($mode -eq 'dryrun') { return }
  # Вечернее окно: до клиринга сводить нечего, а лишний вызов в торговые часы не нужен.
  if ($mskHHmm -lt $script:BROKER_LEDGER_FROM) { return }
  # Раз в календарный день МСК (в т.ч. для разового бэкфилла - иначе он бы шёл каждый тик).
  if ([string]$st.watermarks.broker_ledger_day -eq $mskToday) { return }
  $lg = if ($st.PSObject.Properties['broker_ledger']) { $st.broker_ledger } else { $null }
  $full = ($null -eq $lg -or [string]$lg.backfill_id -ne $script:BROKER_LEDGER_ID)
  $fromMs = 0L
  if ($full) {
    # с запуска контура минус неделя запаса; при нечитаемой дате - фиксированный старт
    try { $fromMs = ([datetimeoffset]::new([datetime]::ParseExact([string]$st.meta.created, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture), [timespan]::Zero)).ToUnixTimeMilliseconds() - 7L*24*3600*1000 }
    catch { $fromMs = ([datetimeoffset]::Parse('2026-07-01T00:00:00Z')).ToUnixTimeMilliseconds() }
  } else {
    # инкремент с перекрытием в 2 суток - дедуп по id операции защищает от повтора
    $fromMs = [long]$lg.until_ms - 2L*24*3600*1000
  }
  $ops = $null
  try { $ops = Get-OpsWindowed $fromMs $NowMs }
  catch { Write-LiveLog "broker-ledger: операции недоступны: $($_.Exception.Message)"; return }

  $seen = New-Object System.Collections.Generic.List[string]
  $vm = 0.0; $fee = 0.0; $feeOther = 0.0
  $byType = [pscustomobject]@{}
  if (-not $full) {
    $vm = [double]$lg.varmargin_rub; $fee = [double]$lg.fees_rub; $feeOther = [double]$lg.fees_other_rub
    if ($lg.PSObject.Properties['fees_by_type'] -and $null -ne $lg.fees_by_type) { $byType = $lg.fees_by_type }
    foreach ($id in @($lg.op_ids)) { if ($id) { $seen.Add([string]$id) } }
  }
  $added = 0
  foreach ($o in $ops) {
    $oid = [string](Get-TiField $o 'id')
    if ($oid -and $seen.Contains($oid)) { continue }
    $t = [string](Get-TiField $o 'operation_type')
    $pay = [double](M2D (Get-TiField $o 'payment')).value
    $itype = [string](Get-TiField $o 'instrument_type')
    if ($t -like '*VARMARGIN*') { $vm += $pay }
    elseif ($script:FEE_OPS -contains $t) {
      # комиссия бота = фьючерсы (его эксклюзив) + обслуживание счёта без инструмента
      if ($itype -eq 'futures' -or -not $itype) { $fee += $pay } else { $feeOther += $pay }
      $prev = if ($byType.PSObject.Properties[$t]) { [double]$byType.$t } else { 0.0 }
      $byType | Add-Member -NotePropertyName $t -NotePropertyValue ([math]::Round($prev + $pay, 2)) -Force
    }
    else { continue }
    if ($oid) { $seen.Add($oid) }
    $added++
  }
  # кольцо id: хватает на окно перекрытия с большим запасом
  $keep = if ($seen.Count -gt 800) { @($seen)[($seen.Count - 800)..($seen.Count - 1)] } else { @($seen) }
  $st | Add-Member -NotePropertyName broker_ledger -NotePropertyValue ([pscustomobject]@{
    backfill_id = $script:BROKER_LEDGER_ID; first_ms = $fromMs; until_ms = $NowMs
    varmargin_rub = [math]::Round($vm, 2)      # сведённая на клирингах, знак как у брокера
    fees_rub = [math]::Round($fee, 2)          # отрицательные: это списания
    fees_other_rub = [math]::Round($feeOther, 2)
    fees_by_type = $byType; op_ids = (ToArr $keep); updated_ms = $NowMs
  }) -Force
  $st.watermarks | Add-Member -NotePropertyName broker_ledger_day -NotePropertyValue $mskToday -Force
  if ($full) { Write-LiveLog "broker-ledger: бэкфилл, операций учтено $added, вариационка $([math]::Round($vm,2)), комиссии $([math]::Round($fee,2))" }
  elseif ($added) { Write-LiveLog "broker-ledger: +$added операций, вариационка $([math]::Round($vm,2)), комиссии $([math]::Round($fee,2))" }
}

# Общий хелпер ребейза виртуального леджера рукава на новую базу капитала (ручной и авто- пути).
# ЗАЧЕМ: eq_rub рукава растёт только на СВОЁМ P&L, а реальный капитал счёта - ещё и на пополнениях,
# поэтому со временем леджер отстаёт и заложенный риск размывается (к 2026-08-12 core рисковал 3.4%
# реального капитала вместо положенных 5%).
# month_start_eq/day_start_eq масштабируются тем же множителем, что и eq_rub: доходности рукава -
# это отношения к ним, и без синхронного сдвига отчёт с profile_eq показали бы фантомный скачок.
# Открытые позиции НЕ трогаем - они набирались по старому масштабу и должны дожить как есть.
function Set-SleeveBase([string]$Sn, [double]$Target, [string]$Reason) {
  $sl = $st.sleeves.$Sn
  $old = [double]$sl.eq_rub
  if ($Target -le 0 -or $old -le 0) { return $null }
  $k = $Target / $old
  $sl.eq_rub = [math]::Round($Target, 2)
  $sl.month_start_eq = [math]::Round([double]$sl.month_start_eq * $k, 2)
  $sl.day_start_eq = [math]::Round([double]$sl.day_start_eq * $k, 2)
  Write-LiveLog ("sleeve rebase [{0}] ({1}): eq_rub {2} -> {3} (x{4}), базы доходности сдвинуты тем же множителем" -f $Sn, $Reason, [math]::Round($old, 2), $sl.eq_rub, [math]::Round($k, 4))
  return ("{0} {1} -> {2}" -f $Sn, (Fmt-Money $old '₽' 0), (Fmt-Money ([double]$sl.eq_rub) '₽' 0))
}

# Разовый ручной ребейз (конфиг + вотермарка = ровно один раз). Аварийный рычаг, работает и при
# выключенном авто-ребейзе - им же выставляли базу вручную 2026-08-12.
function Invoke-SleeveRebase {
  $rb = $LIVE.sleeve_rebase
  if ($null -eq $rb) { return }
  $id = [string]$rb.id
  if (-not $id -or [string]$st.watermarks.sleeve_rebase_id -eq $id) { return }
  $done = @()
  foreach ($sn in 'core','setA') {
    if (-not $rb.PSObject.Properties[$sn]) { continue }
    $d = Set-SleeveBase $sn ([double]$rb.$sn) 'вручную'
    if ($d) { $done += $d }
  }
  $st.watermarks | Add-Member -NotePropertyName sleeve_rebase_id -NotePropertyValue $id -Force
  Save-State
  if ($done.Count) {
    Alert ("размер сделок пересчитан на новую базу капитала: {0}. Риск на сделку вырастет пропорционально; открытые позиции не тронуты." -f ($done -join '; '))
  }
}

# Авто-ребейз (решение пользователя 2026-08-13): периодически подтягивает eq_rub рукава к реальному
# капиталу счёта, чтобы риск на сделку не размывался при росте капитала и не завышался при просадке -
# та же fixed-fractional модель, что в бэктесте. Выключен по умолчанию ($LIVE.auto_rebase = $null),
# включается через data\live_rf\config.json. Срабатывает не чаще раза в календарный день и только
# когда обе руки без открытых позиций - bot_capital_rub включает var_margin открытых фьючерсов
# (плавающий P&L), при пустых руках futures-компонента = 0 и база чистая.
function Invoke-AutoRebase {
  $ar = $LIVE.auto_rebase
  if ($null -eq $ar -or -not [bool]$ar.enabled) { return }
  if ([string]$st.watermarks.auto_rebase_day -eq $mskToday) { return }
  if (-not $st.go.PSObject.Properties['bot_capital_rub']) { return }
  $cap = [double]$st.go.bot_capital_rub
  if ($cap -le 0) { Write-LiveLog 'auto-rebase: капитал неизвестен (битый снимок) - пропуск'; return }
  $open = @($st.sleeves.core.positions).Count + @($st.sleeves.setA.positions).Count
  if ($open -gt 0) { Write-LiveLog "auto-rebase: отложен, открытых позиций $open"; return }
  $drift = if ($ar.PSObject.Properties['drift_pct'] -and [double]$ar.drift_pct -gt 0) { [double]$ar.drift_pct } else { 0.05 }
  $maxStep = if ($ar.PSObject.Properties['max_step_pct'] -and [double]$ar.max_step_pct -gt 0) { [double]$ar.max_step_pct } else { 0.30 }
  $done = @()
  foreach ($sn in 'core','setA') {
    $old = [double]$st.sleeves.$sn.eq_rub
    if ($old -le 0) { continue }
    if ([math]::Abs($cap / $old - 1) -lt $drift) { continue }
    $target = [math]::Min([math]::Max($cap, $old * (1 - $maxStep)), $old * (1 + $maxStep))
    $d = Set-SleeveBase $sn $target 'авто'
    if ($d) { $done += $d }
  }
  if ($done.Count) {
    $st.watermarks | Add-Member -NotePropertyName auto_rebase_day -NotePropertyValue $mskToday -Force
    Save-State
    Alert ("авто-ребейз базы сделок на реальный капитал: {0}" -f ($done -join '; '))
  }
}
function Test-GoAllows([double]$AddGoRub) {
  return (([double]$st.go.used_rub + $AddGoRub) -le ([double]$LIVE.go_cap_pct * [double]$st.go.budget_rub))
}
# long-only активы (боевой факт 2026-08-27, инциденты i00041/i00042 по VBU6): VTBR и SBRF - это
# ПОСТАВОЧНЫЕ фьючерсы на акции. На экспирации шорт по такому контракту превращается в продажу
# самих акций ("с вашего счета будет продан базовый актив", справка Т-Банка), которых на счёте
# нет, - брокеру пришлось бы открыть непокрытый шорт по бумаге. Маржинальная торговля на счёте
# выключена, поэтому T-Invest отбивает заявку ещё на постановке: PostOrder -> HTTP 400,
# 30051 "Account margin status is disabled". Лонг ограничения не имеет: там на экспирации бумаги
# покупаются за рубли, заём не нужен.
# Гейт живёт ЗДЕСЬ, а не в lib_rf_signals.ps1, сознательно: это свойство боевого СЧЁТА, а не
# стратегии. lib_rf_signals - ОБЩЕЕ сигнальное ядро paper-контура (rf_engine.ps1) и live;
# правка там молча изменила бы и paper, и бэктест, а они должны продолжать считать обе стороны -
# иначе бенчмарк перестанет быть сравнимым с live.
function Test-SideAllowed([string]$Asset, [string]$Side) {
  if ($Side -eq 'long' -or $Side -eq 'buy') { return $true }
  return (@($LIVE.long_only) -notcontains $Asset)
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
  if (@($pf.positions).Count -eq 0) {
    # ПУСТОЙ/БИТЫЙ снимок портфеля (тот же класс глюка, что инцидент 2026-07-23, см.
    # Set-BotCapital): на реальном счету всегда есть хотя бы валютная строка позиций (рубли).
    # Раньше "нет позиций вообще" тут читалось как "все карточки закрылись" - ложный D4 на живой
    # позиции (инцидент 2026-07-27, L00011: разовый битый ответ GetPortfolio с пустым positions ->
    # карантин на 3 дня без авто-снятия). Решение по дрифту откладываем до следующего тика вместо
    # того, чтобы решать его по заведомо неполному ответу.
    Write-LiveLog 'reconcile: снимок портфеля пуст (positions=0) - сверка отложена'
    return
  }
  $driftHaltThisTick = $false
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
      Alert "на счёте обнаружена фьючерсная позиция ($($brokerFut[$uid]) лотов), которую бот не открывал (расхождение D2) — она закрывается по рынку. Пожалуйста, не торгуйте фьючерсами вручную на этом счёте."
      $dir = if ([double]$brokerFut[$uid] -gt 0) { 'sell' } else { 'buy' }
      $it = New-Intent 'emergency_close' @{ uid = $uid; ticker = $uid; side = $dir; lots = [int][math]::Abs([double]$brokerFut[$uid])
        ctx = [pscustomobject]@{ card_id = ''; why = 'D2 foreign position' } }
      Save-State
      [void](Post-IntentMarket $it $dir ([int][math]::Abs([double]$brokerFut[$uid])))
      $driftHaltThisTick = $true
      Set-EntriesHalt 'D2 foreign futures position'
    }
  }
  # D4/D5 по карточкам
  foreach ($sn in 'core','setA') {
    foreach ($c in @($st.sleeves.$sn.positions)) {
      # миграция: карточки, открытые до появления d4_fails, поля не имеют - прямое присвоение
      # на отсутствующий NoteProperty кидает исключение (в отличие от чтения, которое даёт $null)
      if (-not $c.PSObject.Properties['d4_fails']) { $c | Add-Member -NotePropertyName d4_fails -NotePropertyValue 0 -Force }
      $sm = if ($c.side -eq 'long') { 1.0 } else { -1.0 }
      $real = if ($brokerFut.ContainsKey([string]$c.uid)) { [double]$brokerFut[[string]$c.uid] } else { 0.0 }
      $want = $sm * [double]$c.lots
      if ($real -eq 0.0) {
        # D4: карточки нет в непустом снимке брокера. Для этого редкого случая нельзя
        # ограничиваться часовым вотермарком: ручное закрытие могло произойти раньше,
        # пока API/тик были недоступны. Ищем с момента входа именно здесь, а не на
        # каждом обычном тике/TP1.
        $op = $null
        try { $op = Find-FillOperation ([string]$c.uid) $(if ($c.side -eq 'long') { 'sell' } else { 'buy' }) ([int]$c.lots) ([long]$c.entry_ts) 1 -FullHistory }
        catch {
          # operations недоступны: НЕ кварантинить по отсутствию данных - проверка на следующем тике
          Write-LiveLog "D4 $($c.id): operations недоступны ($($_.Exception.Message)) - проверка отложена"
          continue
        }
        if ($null -ne $op) {
          $px = [double](M2D $op.price).value
          $fee = [math]::Abs([double]$c.lots) * $px * [double]$c.rub_per_pt * [double]$LIVE.fee_est
          # два независимых признака: (1) наша стоп-заявка ЖИВА у брокера, а позиции нет - значит
          # закрыл не стоп; (2) цена выхода лучше стопа - стоп физически не мог так исполниться.
          $stopAlive = [bool]([string]$c.stop_order_id -and $stopIds.ContainsKey([string]$c.stop_order_id))
          $extClose = $stopAlive -or -not (Test-StopCouldFire $c $px)
          if ($extClose) {
            # осиротевшая стоп-заявка без позиции откроет обратную -> D2 -> аварийное закрытие + halt
            if ($stopAlive -and -not $LIVE.emulate_stops) {
              try { Cancel-TiStopOrder ([string]$st.account_id) ([string]$c.stop_order_id) | Out-Null }
              catch { Write-LiveLog "D4 $($c.id): не удалось снять осиротевшую стоп-заявку: $($_.Exception.Message)" }
            }
            Alert ("позиция {0} ({1}) закрыта не ботом — стоп-заявка не срабатывала. Учтено как внешнее закрытие; при сравнении с бэктестом такие сделки исключаются." -f $c.id, (RfName $c))
          }
          Close-CardLedger $c $px $(if ($extClose) { 'manual-ext' } else { 'stop' }) $fee
        } else {
          # ОДНОКРАТНОЕ real=0 подтверждаем ещё одним тиком (инцидент 2026-07-27: разовый битый
          # снимок GetPortfolio без строки фьючерса дал ложный D4 на живой позиции L00011 - карантин
          # провисел 3 дня без авто-снятия) - карантиним только на 2-й подряд тик без объяснения.
          $c.d4_fails = [int]$c.d4_fails + 1
          $c | Add-Member -NotePropertyName reconcile_status -NotePropertyValue 'broker-absent' -Force
          if (-not $c.PSObject.Properties['reconcile_since_ts'] -or [long]$c.reconcile_since_ts -le 0) {
            $c | Add-Member -NotePropertyName reconcile_since_ts -NotePropertyValue $NowMs -Force
          }
          if ([int]$c.d4_fails -lt 2) {
            Write-LiveLog "D4 $($c.id): нет позиции и нет операции закрытия (попытка $($c.d4_fails) из 2) - отмечено как требующее сверки"
            continue
          }
          $st.drift.D4 = [int]$st.drift.D4 + 1; $st.drift.last = "D4 $($c.id)"
          Alert ("по позиции {0} ({1}) у брокера нет ни позиции, ни сделки о закрытии (расхождение D4) — позиция отправлена в карантин, новые входы приостановлены. Пожалуйста, проверьте счёт вручную." -f $c.id, (RfName $c))
          $c.quarantine = $true
          $c.reconcile_status = 'broker-absent-unresolved'
          $driftHaltThisTick = $true
          Set-EntriesHalt "D4 $($c.id)"
        }
        continue
      }
      if ($c.quarantine) {
        # расхождение больше не подтверждается (real == want) - карточка возвращается под присмотр
        # бота, D6-сторож стопа снова активен.
        $c.quarantine = $false
        Alert ("расхождение по позиции {0} ({1}) больше не подтверждается - карантин снят, бот возобновляет обычный присмотр." -f $c.id, (RfName $c))
      }
      $c.d4_fails = 0
      if ($c.PSObject.Properties['reconcile_status']) { $c.reconcile_status = '' }
      if ($c.PSObject.Properties['reconcile_since_ts']) { $c.reconcile_since_ts = 0 }
      if ([math]::Abs($real - $want) -gt 0.0001) {
        $explain = @($st.pending_intents | Where-Object { $_.uid -eq $c.uid -and $_.state -in @('POSTED','PARTIAL','LOST') }).Count
        if (-not $explain) {
          # частичный fill TP1-заявки? проверяем операции, иначе усечь к брокеру
          $st.drift.D5 = [int]$st.drift.D5 + 1; $st.drift.last = "D5 $($c.id) real=$real want=$want"
          $newLots = [int][math]::Abs($real)
          Alert ("количество лотов по позиции {0} ({1}) приведено в соответствие с брокером: {2} -> {3} (расхождение D5)." -f $c.id, (RfName $c), [int]$c.lots, $newLots)
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
      Alert "в портфеле акций не хватает бумаг $($h.sym): по учёту бота $botLots, реально у брокера $realShares — учёт приведён к факту."
      $h.lots = [int][math]::Max(0, $realShares)
    }
  }
  $st.sleeves.mom.holdings = ToArr (@($st.sleeves.mom.holdings) | Where-Object { [int]$_.lots -gt 0 })
  # авто-снятие дрифт-халта (паритет с крипто-движком, live_engine.ps1 D2/D4/D5/D6): если в этом
  # тике новых дрифт-халтов не поднималось и ни одна карточка не в карантине - причина 'D*' устарела
  # (расхождение само рассосалось, ручного вмешательства не требуется) - снимаем автоматически.
  $anyQuarantine = @((@($st.sleeves.core.positions) + @($st.sleeves.setA.positions)) | Where-Object { $_.quarantine }).Count -gt 0
  if ($st.entries_halt.active -and [string]$st.entries_halt.reason -like 'D*' -and -not $anyQuarantine -and -not $driftHaltThisTick) {
    Write-LiveLog "reconcile: дрифт-халт '$($st.entries_halt.reason)' снят - расхождение больше не подтверждается"
    $st.entries_halt.active = $false; $st.entries_halt.reason = ''
  }
}

# поиск исполнившейся операции по инструменту (подтверждение стоп-заявок и adopt LOST)
# Кэш раздельный по началу окна: D4 может запросить историю с входа, не раздувая
# обычный часовой запрос для TP1 и потерянных интентов.
$script:opsCache = @{}
function Get-OpsSince([long]$FromMs = 0) {
  $to = (MsToUtc $NowMs).ToString('yyyy-MM-ddTHH:mm:ssZ')
  # НЕ кастовать ops_since через [string]: pwsh 7 грузит полный ISO из JSON как [datetime],
  # и [string] даёт культурный формат -> API 400 code 3 (инцидент 2026-07-20). Нормализация в либе.
  $from = if ($FromMs -gt 0) {
    (MsToUtc ([math]::Max([long]0, $FromMs - 60000))).ToString('yyyy-MM-ddTHH:mm:ssZ')
  } else {
    ConvertTo-TiIso $st.watermarks.ops_since
  }
  if ($script:opsCache.ContainsKey($from)) { return $script:opsCache[$from] }
  $script:opsCache[$from] = @(Get-TiOperations ([string]$st.account_id) $from $to)
  return $script:opsCache[$from]
}
function Find-FillOperation([string]$Uid, [string]$Dir, [int]$Lots, [long]$SinceMs = 0, [double]$LotSize = 1, [switch]$FullHistory) {
  # СТРОГИЙ матчинг (боевой урок 2026-07-17: слабый uid+dir подхватывал СТАРЫЕ операции -> ложные филлы):
  # инструмент + направление + время (не раньше SinceMs-60с) + количество (лоты или штуки = лоты x лот)
  $want = if ($Dir -eq 'buy') { 'BUY' } else { 'SELL' }
  $ops = if ($FullHistory) { Get-OpsSince $SinceMs } else { Get-OpsSince }
  foreach ($op in $ops) {
    if ($null -eq $op) { continue }
    $ouid = [string](Get-TiField $op 'instrument_uid')
    $otype = ([string](Get-TiField $op 'operation_type')).ToUpperInvariant()
    $opDir = if ($otype -match '(?:^|_)BUY$') { 'BUY' } elseif ($otype -match '(?:^|_)SELL$') { 'SELL' } else { '' }
    if ($ouid -ne $Uid -or $opDir -ne $want) { continue }
    if ($SinceMs -gt 0) {
      try {
        $od = [DateTimeOffset]::Parse([string](Get-TiField $op 'date')).ToUnixTimeMilliseconds()
        if ($od -lt ($SinceMs - 60000)) { continue }
      } catch { continue }
    }
    if ($Lots -gt 0) {
      $q = 0.0
      try {
        $rawQ = Get-TiField $op 'quantity'
        if ($rawQ -is [string] -or $rawQ -is [ValueType]) { $q = [double]$rawQ }
        else { $q = [double](Q2D $rawQ) }
      } catch {}
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
        Alert ("не удалось переоткрыть позицию при переходе на новый контракт ({0}) — позиция закрыта. Пожалуйста, проверьте счёт вручную." -f (AssetName ([string]$it.asset) ([string]$it.ticker)))
        Close-CardLedger $card ([double]$card.roll_close_px) 'roll-fail' 0.0
      }
    } elseif ([string]$it.kind -in @('emergency_close','exit')) {
      Alert ("заявка на закрытие ({0}) не исполнилась (состояние {1}) — возможно, позиция всё ещё открыта. Пожалуйста, проверьте счёт у брокера вручную." -f (AssetName ([string]$it.asset) ([string]$it.ticker)), [string]$it.state)
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
          Alert ("заявка по {0} висит без исполнения более 3 минут — отменяю её и сверяюсь с брокером." -f (AssetName ([string]$it.asset) ([string]$it.ticker)))
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
        Alert ("заявка по {0} не исполнилась после {1} попыток и была отменена." -f (AssetName ([string]$it.asset) ([string]$it.ticker)), [int]$it.attempts)
      }
    }
    if ([string]$it.state -eq 'PARTIAL') {
      # добор остатка новым ключом (тот же intent, суффикс fill{n})
      $rest = [int]$it.lots - [int]$it.filled_lots
      if ($rest -le 0) { Set-IntentState $it 'FILLED' }
      elseif ([int]$it.attempts -ge [int]$LIVE.max_attempts) {
        Set-IntentState $it 'FILLED' 'partial: max attempts, работаем с filled_lots'
        $it.lots = [int]$it.filled_lots   # карточка строится по фактически набранному
        Alert ("заявка по {0} исполнилась только частично — работаем с {1} {2}." -f (AssetName ([string]$it.asset) ([string]$it.ticker)), [int]$it.filled_lots, (RuLots ([int]$it.filled_lots)))
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
        d6_fails = 0; d4_fails = 0; quarantine = $false; stop_deferred = $null; last_stop_update = ''
        lat_sp = $lat.sp; lat_pf = $lat.pf
      }
      $sl.positions = ToArr (@($sl.positions) + $card)
      $st.stats.fills = [int]$st.stats.fills + 1
      $script:ev.Add("ENTRY [$($It.sleeve)] $($card.id) $($It.asset) $sideName $([int]$It.filled_lots) лот @$px")
      $script:jr.Add(("`r`n## {0} MSK — RF-LIVE [{1}]: ВХОД {2} {3} {4} {5} лот @{6}, стоп {7}, риск {8} ₽`r`n" -f (MsToUtcStr $mskNowMs), $It.sleeve, $card.id, $It.asset, $sideName.ToUpper(), [int]$It.filled_lots, $px, $card.stop_px_pts, $card.risk_rub))
      $notionalE = [int]$card.lots_initial * [double]$card.entry_px_pts * [double]$card.rub_per_pt
      Alert -Client (
        ("открыта позиция {0} — {1}, {2}, {3} {4} по {5} (стратегия «{6}»)." -f $card.id, (RfName $card), (RuSide $card.side 'noun'), [int]$card.lots, (RuLots ([int]$card.lots)), (Fmt-Px ([double]$card.entry_px_pts)), (SleeveRu ([string]$card.sleeve))) +
        ("`nОбъём позиции: {0}, риск сделки: {1}." -f (Fmt-Money $notionalE '₽' 0), (Fmt-Money ([double]$card.risk_rub) '₽' 0)) +
        ("`nСтоп-заявка выставляется у брокера: {0}." -f (Fmt-Px ([double]$card.stop_px_pts))))
      # НЕМЕДЛЕННО стоп-заявка (инвариант #2); TP1 для setA при lots >= 2
      if (-not (Post-CardStop $card)) {
        Alert ("не удалось выставить стоп сразу после входа {0} ({1}) — позиция закрывается по рынку для безопасности." -f $card.id, (RfName $card))
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
    Alert ("после перехода на новый контракт не удалось выставить стоп по позиции {0} ({1}) — позиция закрывается по рынку для безопасности." -f $Card.id, (RfName $Card))
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
  if ($null -eq $st.active) { $st.active = [pscustomobject]@{} }
  # досев новых активов (не только первичная инициализация - канон вырос 8 -> 12 2026-08-12,
  # а этот блок раньше срабатывал ровно один раз за всю жизнь state и новые активы никогда не
  # получали secid: цикл роллов ниже видел $curActive='' и вечно падал в "roll deferred" по
  # пустому секиду, вход в новый актив не мог состояться никогда - инцидент, см. журнал).
  foreach ($a in $ASSETS) {
    if (-not $st.active.PSObject.Properties[$a]) {
      $st.active | Add-Member -NotePropertyName $a -NotePropertyValue $frontsRec[$a].secid
    }
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
  Invoke-DailyReadinessCheck
  $st.watermarks.last_daily_day = $completedDay
}

function Invoke-DailyReadinessCheck {
  # Проактивный суточный гейт по всему канону $ASSETS - раньше это был ручной прогон на VPS
  # (tinvest_universe_gate.ps1 для торгуемости, rf_capital_calc.ps1 для худшего случая ГО),
  # который для расширения 2026-08-12 так и не был доведён до конца и задокументирован. Get-Inst
  # уже сам вызывает Assert-Tradeable и кэширует ГО на 24ч, но лениво - только когда актив реально
  # трогает сигнал/ролл/вход; для "спящего" актива это никогда не происходит. Здесь - раз в сутки,
  # для всех сразу, с алертом при проблеме. НЕ меняет сайзинг/governors на входе - Test-GoAllows и
  # поштучный Assert-Tradeable при постановке заявки (см. ниже) остаются последним словом на
  # реальных деньгах, это только ранняя видимость поверх них.
  $failed = New-Object System.Collections.Generic.List[string]
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($a in $ASSETS) {
    $secid = [string]$st.active.$a
    $inst = $null
    try { $inst = Get-Inst $secid 'fut' } catch { $failed.Add("$a ($secid): $($_.Exception.Message)"); continue }
    $s = Get-Ser $a
    if ($s.Count -lt 15) { continue }   # мало истории для ATR - не считаем в худшем случае, это не сбой гейта
    $atr = Ser-ATR14 $s ($s.Count - 1)
    if ([double]::IsNaN($atr) -or $atr -le 0) { continue }
    $notional = [double]$s[$s.Count - 1].c * [double]$inst.rub_per_pt
    if ($notional -le 0) { continue }
    $goPerLot = [math]::Max([double]$inst.go_buy, [double]$inst.go_sell)
    $riskCore = [double]$st.sleeves.core.eq_rub * [double]$LIVE.core_risk
    $riskSetA = [double]$st.sleeves.setA.eq_rub * [double]$LIVE.seta_risk
    $stopCoreRub = [double]$ATR_STOP_CORE * $atr * [double]$inst.rub_per_pt
    $stopSetARub = [double]$ATR_STOP_A * $atr * [double]$inst.rub_per_pt
    $levCapCore = [math]::Floor([double]$MAXLEV * [double]$st.sleeves.core.eq_rub / $notional)
    $levCapSetA = [math]::Floor([double]$MAXLEV * [double]$st.sleeves.setA.eq_rub / $notional)
    $lotsCore = [math]::Max(0, [math]::Min([math]::Floor($riskCore / $stopCoreRub), $levCapCore))
    $lotsSetA = [math]::Max(0, [math]::Min([math]::Floor($riskSetA / $stopSetARub), $levCapSetA))
    $rows.Add([pscustomobject]@{ asset = $a; goCore = $lotsCore * $goPerLot; goSetA = $lotsSetA * $goPerLot })
  }
  # худший случай: топ-MAXCONC самых дорогих по ГО позиций одновременно в core и в setA
  # (та же логика, что rf_capital_calc.ps1 goWorst - здесь на живых данных счёта и брокера)
  $worstCore = Get-TopNSum $rows.ToArray() 'goCore' $MAXCONC
  $worstSetA = Get-TopNSum $rows.ToArray() 'goSetA' $MAXCONC
  $goWorst = [math]::Round($worstCore + $worstSetA, 2)
  $goCap = [math]::Round([double]$LIVE.go_cap_pct * [double]$st.go.budget_rub, 2)
  $fits = $goWorst -le $goCap
  $rd = [pscustomobject]@{
    day = $completedDay; checked_n = $rows.Count; total_n = @($ASSETS).Count
    failed = @($failed); go_worst_rub = $goWorst; go_cap_rub = $goCap; fits = $fits
  }
  $st | Add-Member -NotePropertyName readiness -NotePropertyValue $rd -Force
  if ($failed.Count -gt 0) {
    Alert ("суточная проверка готовности: {0} инструмент(ов) недоступны у брокера - {1}." -f $failed.Count, ($failed -join '; '))
  }
  if (-not $fits) {
    Alert ("суточная проверка ГО: худший случай (все {0} слота ядра + {0} setA заполнены одновременно) - {1}, кэп {2}. Реальные заявки governor режет штатно, это заблаговременное предупреждение." -f $MAXCONC, (Fmt-Money $goWorst '₽' 0), (Fmt-Money $goCap '₽' 0))
  }
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
    $st.day_start_date = $D
    # реальный капитал (не блендовый profile_eq) - governors с 2026-08-07 считают от него же,
    # что и вечерний отчёт (см. Invoke-Governors); bot_capital_rub уже свежий - Set-BotCapital
    # выполняется раньше в этом же тике (шаг 3 главного цикла, до Invoke-Mtm/Invoke-LiveDaily).
    # Если Set-BotCapital его не посчитал (dryrun, либо первый снимок портфеля битый) - не топить
    # день нулём, нести прошлое значение (тот же принцип, что в Set-BotCapital при пустом снимке).
    if ($st.go.PSObject.Properties['bot_capital_rub'] -and [double]$st.go.bot_capital_rub -gt 0) {
      $st.day_start_eq = [double]$st.go.bot_capital_rub
    }
    $st.sleeves.core.day_start_eq = [double]$st.sleeves.core.eq_rub
    $st.sleeves.setA.day_start_eq = [double]$st.sleeves.setA.eq_rub
    $st.sleeves.core.halt_day = $null; $st.sleeves.setA.halt_day = $null
    if ($st.entries_halt.active -and [string]$st.entries_halt.reason -like 'day -*') {
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
    if ([string]$dsig.side -ne '' -and -not (Test-SideAllowed $a ([string]$dsig.side))) {
      $script:ev.Add("SKIP long-only [core] $a $($dsig.side) @close $cl")
    } elseif ([string]$dsig.side -ne '') {
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
    if ($null -ne $asig -and -not (Test-SideAllowed $a ([string]$asig.side))) {
      $script:ev.Add("SKIP long-only [setA] $a $($asig.side) @close $cl")
    } elseif ($null -ne $asig) {
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
  # exits первыми (освобождают ГО), затем entries - халт (в т.ч. дрифт-халт D2/D4) должен
  # останавливать ТОЛЬКО входы: свой же алерт обещает "открытые позиции продолжают вестись как
  # обычно", а выход по сигналу стратегии (trail-ema20) - это pending exit-intent, который раньше
  # застревал наравне со входами (инцидент 2026-07-27, entries_halt D4 L00011 держал халт 3 дня).
  foreach ($it in @($st.pending_intents | Where-Object { $_.kind -eq 'exit' -and $_.state -eq 'INTENT' })) {
    if (-not (Test-InstrumentTrading ([string]$it.uid))) { continue }   # ждём открытия торгов
    Save-State
    [void](Post-IntentMarket $it ([string]$it.side) ([int]$it.lots))
  }
  if ($st.entries_halt.active) { return }
  foreach ($it in @($st.pending_intents | Where-Object { $_.kind -eq 'entry' -and $_.state -eq 'INTENT' })) {
    if ([string]$it.created_day -ge $mskToday) { continue }   # вход на открытии СЛЕДУЮЩЕЙ сессии (как paper)
    Invoke-EntryIntentPost $it
  }
}

# сайзинг (пункты -> рубли, боевой нюанс #1) + кэп MAXLEV + предиктивный ГО-чек + постановка одного
# entry-интента. Вынесено из Invoke-EntryWindow, чтобы тот же путь могла переиспользовать вечерняя
# same-day проверка (Invoke-EveningConfirm) - единая точка сайзинга/ГО-чека/постановки, не дублирование.
function Invoke-EntryIntentPost($it) {
  $sl = Get-SleeveRef ([string]$it.sleeve)
  if ([string]$sl.halt_day -eq $mskToday) { Set-IntentState $it 'CANCELLED' 'sleeve halt'; return }
  # страховка на реальных деньгах: интент мог быть создан ДО появления гейта (восстановлен из
  # state) или прийти по будущему пути в обход сигнальных проверок - брокер такой шорт отобьёт
  if (-not (Test-SideAllowed ([string]$it.asset) ([string]$it.side))) {
    Set-IntentState $it 'CANCELLED' 'long-only'
    $script:ev.Add("SKIP long-only [$($it.sleeve)] $($it.asset) $($it.side)")
    return
  }
  $secid = [string]$st.active.$([string]$it.asset)
  $inst = $null
  try { $inst = Get-Inst $secid 'fut' } catch { Set-IntentState $it 'CANCELLED' "инструмент: $($_.Exception.Message)"; Alert ("вход по {0} отменён: {1}." -f (AssetName ([string]$it.asset) $secid), $_.Exception.Message); return }
  # не входить в контракт с <=4 дней до last_trade_date (нюанс #7)
  if ($inst.last_trade_date -and ((([datetime]$inst.last_trade_date) - ([datetime]$mskToday)).TotalDays -le 4)) {
    $nx = [string]$st.fronts.$([string]$it.asset).next
    if ($nx) { $secid = $nx; $inst = Get-Inst $secid 'fut' } else { Set-IntentState $it 'CANCELLED' 'фронт в зоне экспирации'; return }
  }
  $it.ticker = $secid; $it.uid = [string]$inst.uid
  if (-not (Test-InstrumentTrading ([string]$inst.uid))) { return }   # утро: торги ещё не открылись - интент ждёт
  $s = Get-Ser ([string]$it.asset)
  # ctx.ref_px уже несёт цену, по которой сигнал был признан валидным (дневное закрытие для
  # обычного пути, живая вечерняя цена для same-day пути) - предпочитаем её хвосту серии, который
  # для same-day интента вечером ещё НЕ содержит сегодняшний бар (появится только в 00:20-хуке).
  # Для обычного пути к моменту исполнения (следующая сессия) это то же самое значение.
  $refPx = if ([double]$it.ctx.ref_px -gt 0) { [double]$it.ctx.ref_px } else { [double]$s[$s.Count - 1].c }
  $stopDist = [double]$it.ctx.stop_dist
  if ([string]$it.sleeve -eq 'setA') {
    $sm = if ($it.side -eq 'buy') { 1.0 } else { -1.0 }
    $stopDist = [math]::Max($sm * ($refPx - [double]$it.ctx.swing), [double]$ATR_STOP_A * [double]$it.ctx.atr)
  }
  if ($stopDist -le 0) { Set-IntentState $it 'CANCELLED' 'stopDist<=0'; return }
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
    return
  }
  # предиктивный ГО-чек (нюанс #6)
  $goPer = if ($it.side -eq 'buy') { [double]$inst.go_buy } else { [double]$inst.go_sell }
  while ($lots -ge 1 -and -not (Test-GoAllows ($lots * $goPer))) { $lots-- }
  if ($lots -lt 1) {
    Set-IntentState $it 'CANCELLED' 'go-cap'
    $script:ev.Add("SKIP go-cap [$($it.sleeve)] $($it.asset): used=$($st.go.used_rub) budget=$($st.go.budget_rub)")
    return
  }
  $it.lots = [int]$lots
  $it.ctx | Add-Member -NotePropertyName risk_rub -NotePropertyValue ([math]::Round($riskRub, 2)) -Force
  $it.ctx | Add-Member -NotePropertyName stop_dist -NotePropertyValue ([math]::Round($stopDist, 6)) -Force
  $it.ctx.ref_px = $refPx
  # рубли под ГО: при нехватке продаётся funding (серебро); не вышло - интент ждёт следующего тика
  if (-not (Ensure-RubFunding ($lots * $goPer + 1500.0) "вход $($it.asset) $lots лот")) { return }
  Save-State
  [void](Post-IntentMarket $it ([string]$it.side) ([int]$lots))
}

function Invoke-EveningConfirm {
  # Путь A (2026-08). Бэктестер, на котором посчитан весь опубликованный эдж рукава B, всегда
  # исполнял брейкаут-вход по цене ЗАКРЫТИЯ ТОГО ЖЕ дня (tools/backtest.ps1: $entry=$cl) - живой
  # контур ждёт открытия СЛЕДУЮЩЕЙ сессии, задокументированный разрыв ("форвард измерит эту
  # утечку", live_tinvest_design.md). Здесь разрыв частично закрывается: незадолго до ночного
  # клиринга (23:48) цена уже практически финальна - пересчитываем Donchian-канал ЯДРА (setup A
  # намеренно не входит: её триггер зависит от цены ОТКРЫТИЯ дня, которую этот тик не знает
  # надёжно - отдельная задача) против неё, и если брейкаут подтверждён - входим сегодня, а не
  # ждём до завтра. Канал по-прежнему считается ТОЛЬКО на завершённых дневных барах (без
  # изменений) - меняется момент подтверждения, не сама стратегия (см. отдельный walk-forward
  # Пути B, docs/backtests/intraday_confirm_2026-08.md - ВНУТРИЧАСОВОЕ подтверждение отклонено;
  # этот путь другой: не раньше почти-закрытия, а не в любой момент дня).
  #
  # Анти-дублирование с 00:20-хуком - специально БЕЗ отдельного маркера: $has/$busy-гейты в
  # Invoke-LiveDayHook уже проверяют и открытые позиции, и pending_intents в состояниях
  # INTENT/POSTED/PARTIAL/LOST для той же пары актив+рукав - раз интент отсюда либо исполнился
  # (появилась карточка), либо всё ещё висит в одном из этих состояний, хук сегодняшней ночью
  # сам увидит "уже есть" и не создаст дубль. Если интент был CANCELLED (qty0/go-cap/ошибка
  # инструмента) - он намеренно НЕ считается «занятым», и хук получает честный второй шанс на
  # официально финализированной цене.
  if ($st.entries_halt.active) { return }
  if ([string]$st.watermarks.evening_confirm_day -eq $mskToday) { return }
  $st.watermarks | Add-Member -NotePropertyName evening_confirm_day -NotePropertyValue $mskToday -Force
  foreach ($a in $ASSETS) {
    if (@($LIVE.whitelist).Count -and $LIVE.whitelist -notcontains $a) { continue }
    try {
      $slC = $st.sleeves.core
      if ([string]$slC.halt_day -eq $mskToday) { continue }
      $busy = @($slC.positions).Count + @($st.pending_intents | Where-Object { $_.kind -eq 'entry' -and $_.sleeve -eq 'core' -and $_.state -in @('INTENT','POSTED','PARTIAL','LOST') }).Count
      $has = @($slC.positions | Where-Object { $_.asset -eq $a }).Count + @($st.pending_intents | Where-Object { $_.kind -eq 'entry' -and $_.sleeve -eq 'core' -and $_.asset -eq $a -and $_.state -in @('INTENT','POSTED','PARTIAL','LOST') }).Count
      if ($busy -ge $MAXCONC -or $has) { continue }
      $secid = [string]$st.active.$a
      if (-not $secid) { continue }
      $s = Get-Ser $a
      if ($s.Count -lt ($BRK_N + 1)) { continue }
      # серия обязана заканчиваться НЕ позже вчерашнего и не отставать больше чем на выходные/
      # праздники (>4 дн - подозрение на застрявшую серию, инцидент 2026-08-12/13 "слепые пять";
      # молча не считаем, обычный путь 00:20-хука разберётся сам)
      $lastDay = SerDay $s[$s.Count - 1]
      if ($lastDay -ge $mskToday) { continue }
      if ((([datetime]$mskToday) - ([datetime]$lastDay)).TotalDays -gt 4) { continue }
      $atr = Ser-ATR14 $s ($s.Count - 1)
      if ([double]::IsNaN($atr) -or $atr -le 0) { continue }
      $inst = $null
      try { $inst = Get-Inst $secid 'fut' } catch { continue }
      $px = $null
      foreach ($lp in (Get-TiLastPrices @([string]$inst.uid))) { if ($null -ne $lp) { $px = [double](Q2D $lp.price) } }
      if (-not $px -or $px -le 0) { continue }
      # временная копия серии только для этого вызова - Get-Ser отдаёт ссылку на общий кэш,
      # мутировать его синтетическим баром нельзя (настоящий бар допишет Update-DailySeries
      # ночью). h/l синтетического бара не участвуют в сравнении (Get-DonchianSide берёт канал
      # из баров ДО текущего индекса), только .c
      $tmp = New-Object System.Collections.Generic.List[object]
      $tmp.AddRange($s)
      $tmp.Add([pscustomobject]@{ t = 0; o = $px; h = $px; l = $px; c = $px })
      $key = "c3b_$a"
      $ra = if ($st.rearm.PSObject.Properties[$key]) { $st.rearm.$key } else { $null }
      $dsig = Get-DonchianSide $tmp ($tmp.Count - 1) $ra
      if ([string]$dsig.side -eq '') { continue }
      if (-not (Test-SideAllowed $a ([string]$dsig.side))) {
        $script:ev.Add("SKIP long-only [core] $a $($dsig.side) @evening $px (same-day)")
        continue
      }
      $dir = if ($dsig.side -eq 'long') { 'buy' } else { 'sell' }
      $it = New-Intent 'entry' @{ sleeve = 'core'; asset = $a; side = $dir; created_day = $mskToday
        t_signal = $NowMs
        ctx = [pscustomobject]@{ stop_dist = [math]::Round([double]$ATR_STOP_CORE * $atr, 6); atr = [math]::Round($atr, 6)
          risk_pct = [double]$LIVE.core_risk; ref_px = $px
          note = "evening donchian $px vs [$([math]::Round([double]$dsig.lo,4)) / $([math]::Round([double]$dsig.hi,4))]" } }
      $script:ev.Add("SIGNAL [core] $a $($dsig.side) @evening $px (same-day)")
      Invoke-EntryIntentPost $it
    } catch { Write-LiveLog "evening-confirm ${a}: $($_.Exception.Message)" }
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
      Alert -Client ("позиция {0} ({1}) дошла до первой цели {2} — закрыта половина ({3} {4}) с прибылью {5}, стоп остатка переведён на цену входа. Хуже нуля позиция уже не закроется." -f $c.id, (RfName $c), (Fmt-Px $px), [int]$half, (RuLots ([int]$half)), (Fmt-Money ([math]::Round($pnl,0)) '₽' 0 -Sign))
    } else {
      $c.tp1_order_id = ''   # заявка исчезла без операции - перевыставим при следующем reconcile? нет: алерт
      Alert "заявка на первую цель по позиции $($c.id) ($(RfName $c)) исчезла, но исполнение не найдено — пожалуйста, проверьте позицию у брокера вручную."
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
  # Брокерский P&L в разрезе КАРТОЧЕК - единственный писатель этой раскладки.
  # Почему здесь, а не в Set-BotCapital: к шагу 6 главного цикла карточки уже прошли сверку,
  # TP1 и закрытия, поэтому лоты актуальны на момент сохранения состояния. Снапшот и
  # build_vizdata читают готовую карту вместо собственных копий того же деления (до
  # 2026-09-01 логика жила в трёх местах и давала на одну позицию три разных числа).
  $openAll = New-Object System.Collections.Generic.List[object]
  foreach ($sn in 'core','setA') { foreach ($c in @($st.sleeves.$sn.positions)) { if ($null -ne $c) { $openAll.Add($c) } } }
  $bpc = [pscustomobject]@{}
  foreach ($kv in (Get-CardPnlMap $openAll).GetEnumerator()) {
    $bpc | Add-Member -NotePropertyName ([string]$kv.Key) -NotePropertyValue ([math]::Round([double]$kv.Value, 2)) -Force
  }
  $st | Add-Member -NotePropertyName broker_pnl_by_card -NotePropertyValue $bpc -Force
}

function Invoke-Governors {
  # HARD -35% от пика: закрыть всё + HALT_RF_LIVE (решение пользователя; помнить: бэктест-DD 40-44%)
  # с 2026-08-07 считаем от реального капитала брокера (bot_capital_rub/capital_peak_rub из
  # Set-BotCapital), а не от блендовой paper-модели (profile_eq/peak_eq) - тот же источник,
  # что и вечерний отчёт с 06.08 (a21d81456); капитал/пик уже свежие на этот тик (шаг 3 цикла).
  # Set-BotCapital в dryrun вообще не пишет эти поля (ранний return), а на самом первом тике
  # прод-жизни может не успеть, если первый снимок портфеля битый (total_amount_portfolio<=0) -
  # в обоих случаях НЕ считаем dd от отсутствующих/нулевых чисел (0/0 = NaN тихо гасит все
  # сравнения ниже, но лучше явно пропустить тик, чем полагаться на NaN-семантику).
  $capNow = if ($st.go.PSObject.Properties['bot_capital_rub']) { [double]$st.go.bot_capital_rub } else { 0.0 }
  $capPeak = if ($st.go.PSObject.Properties['capital_peak_rub']) { [double]$st.go.capital_peak_rub } else { 0.0 }
  if ($capNow -gt 0 -and $capPeak -gt 0) {
    $dd = 1.0 - $capNow / $capPeak
    if ($dd -gt 0.90) {
      # санити-гард (урок песочницы 2026-07-17: мусорные котировки дали «DD 25044%»): DD>90% - почти
      # наверняка ошибка данных, а не рынок -> НЕ флэттенить по ней; стоп входов + ручной разбор
      Alert ("расчётная просадка {0:P0} — это похоже на ошибку в котировках, а не реальный убыток. Автоматическое закрытие НЕ выполняется, новые входы остановлены до ручной проверки." -f $dd)
      Set-EntriesHalt 'suspicious DD>90% (data error?)'
      return
    }
    if ($dd -ge [double]$LIVE.hard_dd) {
      Alert -Client ("АВАРИЙНАЯ ОСТАНОВКА — просадка достигла {0:P1} от максимума капитала. Все позиции закрываются по рынку, торговля остановлена до ручного разбора." -f $dd)
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
  }
  # день -8% (от реального капитала на старт дня, day_start_eq repoint см. Invoke-LiveDayHook) -> entries_halt до завтра
  if ($capNow -gt 0 -and [double]$st.day_start_eq -gt 0) {
    $dl = 1.0 - $capNow / [double]$st.day_start_eq
    if ($dl -ge [double]$LIVE.profile_day_halt) { Set-EntriesHalt ("day -{0:P1}" -f $dl) }
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
        Alert -Client ("гарантийное обеспечение занято на {0:P0} (порог {1:P0}) — закрываю последнюю открытую позицию {2} ({3}), чтобы освободить обеспечение." -f $goPct, [double]$LIVE.go_trim_pct, $newest.id, (RfName $newest))
        Invoke-EmergencyClose $newest 'go-trim'
      }
    } elseif ($goPct -gt [double]$LIVE.go_cap_pct) {
      Set-EntriesHalt ("ГО {0:P0} > кэпа" -f $goPct)
    } elseif ([string]$st.entries_halt.reason -like 'ГО *') {
      # ГО вернулось под кэп - свой же халт снимаем сами. Инцидент 2026-08-07: ветки снятия не
      # существовало, halt «ГО 72 % > кэпа» провисел 3 дня при фактических 19 %, боевой контур
      # пропустил сигналы GOLD/SILV/RTS (бумажный двойник их взял) - RTS с 2026-08-12 выведен из
      # универсума, пример исторический.
      Clear-EntriesHalt ("ГО {0:P0}, кэп {1:P0}" -f $goPct, [double]$LIVE.go_cap_pct)
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
  # Обе модели капитала в одной строке: bot_capital - историческая (с вариационкой сверху),
  # bot_capital_account - по счёту брокера. Плюс сама вариационка за тик. Благодаря этим двум
  # колонкам точка перехода на новую модель будет опознаваема прямо в данных, а старые строки
  # (где колонок нет) остаются читаемыми - все потребители переносят их отсутствие.
  $capAcct = if ($st.go.PSObject.Properties['bot_capital_account_rub']) { [double]$st.go.bot_capital_account_rub } else { $null }
  $vmRub = if ($st.PSObject.Properties['capital_breakdown'] -and $null -ne $st.capital_breakdown.futures) { [double]$st.capital_breakdown.futures } else { $null }
  $eq.Add([pscustomobject]@{ utc = (MsToUtcStr $NowMs); ts = $NowMs
    total = [double]$st.profile_eq; core = [double]$st.sleeves.core.equity_mtm; setA = [double]$st.sleeves.setA.equity_mtm
    mom = [double]$st.sleeves.mom.equity_mtm; go_used = [double]$st.go.used_rub; stock_val = [math]::Round($stockVal, 0)
    account_liquid = $liq; bot_capital = $cap; bot_capital_account = $capAcct; var_margin = $vmRub })
  Write-JsonAtomic $eqPath (ToArr $eq) 4
}

# Брокерский P&L каждой открытой карточки (expected_yield по uid из Set-BotCapital), поделенный
# пропорционально лотам, если инструмент одновременно держат оба рукава. Fallback на внутренний
# upnl_rub там, где брокерских данных нет (dryrun/sandbox, либо uid выпал из снимка на этом тике).
function Get-CardPnlMap($OpenCards) {
  $map = @{}
  $haveBroker = $st.PSObject.Properties['broker_pnl_by_uid']
  $byUid = @{}
  foreach ($c in $OpenCards) {
    $u = [string]$c.uid
    if (-not $byUid.ContainsKey($u)) { $byUid[$u] = New-Object System.Collections.Generic.List[object] }
    $byUid[$u].Add($c)
  }
  foreach ($u in $byUid.Keys) {
    $cards = $byUid[$u]
    $prop = if ($haveBroker) { $st.broker_pnl_by_uid.PSObject.Properties[$u] } else { $null }
    if ($null -ne $prop) {
      $total = [double]$prop.Value
      $lotsSum = 0.0; foreach ($c in $cards) { $lotsSum += [double]$c.lots }
      foreach ($c in $cards) {
        $share = if ($lotsSum -gt 0) { [double]$c.lots / $lotsSum } else { 1.0 / $cards.Count }
        $map[[string]$c.id] = $total * $share
      }
    } else {
      foreach ($c in $cards) {
        $map[[string]$c.id] = if ($c.PSObject.Properties['upnl_rub']) { [double]$c.upnl_rub } else { 0.0 }
      }
    }
  }
  return $map
}

# ================= ИИ-проверка готового отчёта (Gemma/Qwen через OpenRouter) =================
# НЕ формулирует и не пересчитывает отчёт - только сверяет уже готовый текст с уже готовыми
# числами по жёсткому чек-листу (без права придумывать свои критерии). Вызывается ПОСЛЕ того,
# как основной отчёт уже ушёл в Telegram (см. Invoke-DailyReport) - любой сбой здесь (нет ключа,
# сеть, таймаут, битый JSON) молча логируется и ни на что не влияет: отчёт никогда не зависит
# от этого шага. Модель отдельная от Python-ассистента (тот на DeepSeek/Gemini для тул-коллинга,
# см. assistant/config.py) - тут своя пара, по умолчанию Gemma с фолбэком на Qwen.
$script:OPENROUTER_URL = 'https://openrouter.ai/api/v1/chat/completions'
$script:REPORT_VERIFY_PROMPT = @'
Проверь готовый отчёт трейдинг-бота СТРОГО по пунктам ниже. Ты НЕ пересчитываешь и не переписываешь
цифры отчёта - только сверяешь текст с приложенными фактами (JSON).
1. peak_rub >= capital_rub (иначе просадка не может быть отрицательной - формат сломан).
2. Сумма positions[].day_pnl (по всем открытым позициям) + сумма closed[].pnl примерно равна
   capital_day_delta (допуск на комиссии/округление - до нескольких тысяч рублей, не больше).
   ИСКЛЮЧЕНИЕ: если capital_day_source = "broker" - это дневная доходность ВСЕГО счёта от
   брокера, в неё входит ещё и переоценка валют и металлов, которой нет в positions[].
   В этом случае расхождение ожидаемо и ошибкой НЕ считается: проверь только, что знак
   совпадает с суммой позиций либо что разница объяснима переоценкой валютного остатка.
3. Все числовые поля из фактов присутствуют в тексте и не NaN/пустые/null.
4. В тексте есть все секции: капитал, открытые позиции, закрытые сделки, по стратегиям, ГО, статус входов.
5. Ненулевые drift (D2/D4/D5/D6) - это ожидаемое, штатно отображаемое состояние, а НЕ ошибка отчёта
   сама по себе; сверяй только что цифры в тексте совпадают с фактами.
Ответь СТРОГО одним словом OK, если всё сошлось. Если нет - одной короткой строкой на русском:
что именно разошлось и почему. Не пиши ничего кроме этого - ни цифр отчёта, ни пояснений сверх сути.
'@
function Invoke-ReportVerify([string]$ReportText, $Facts) {
  try {
    $key = $env:OPENROUTER_API_KEY
    if (-not $key) { return }
    $model   = if ($env:RF_VERIFY_MODEL)          { $env:RF_VERIFY_MODEL }          else { 'google/gemma-3-27b-it' }
    $modelFb = if ($env:RF_VERIFY_MODEL_FALLBACK) { $env:RF_VERIFY_MODEL_FALLBACK } else { 'qwen/qwen-2.5-72b-instruct' }
    $headers = @{ Authorization = "Bearer $key"; 'Content-Type' = 'application/json' }
    $userMsg = "ФАКТЫ:`n$($Facts | ConvertTo-Json -Depth 6 -Compress)`n`nТЕКСТ ОТЧЁТА:`n$ReportText"
    $answer = $null
    foreach ($mdl in @($model, $modelFb)) {
      $body = @{ model = $mdl; temperature = 0; max_tokens = 300
        messages = @(@{ role = 'system'; content = $script:REPORT_VERIFY_PROMPT }, @{ role = 'user'; content = $userMsg }) }
      try {
        $resp = Invoke-RestMethod -Uri $script:OPENROUTER_URL -Method Post -Headers $headers `
          -Body ($body | ConvertTo-Json -Depth 8) -TimeoutSec 20
        $answer = [string]$resp.choices[0].message.content
        break
      } catch { Write-LiveLog "Invoke-ReportVerify: $mdl недоступна ($($_.Exception.Message))" }
    }
    if ($null -eq $answer) { return }
    $answer = $answer.Trim()
    if ($answer -and $answer -ne 'OK' -and $answer -ne 'ОК') {
      # только владельцу: это внутренняя проверка качества текста, а не событие по счёту
      $warn = "⚠️ Проверка вечернего отчёта: $answer"
      [void](Send-TgAlert $warn)
    } else {
      # успех молчит в Telegram нарочно (не спамить) - но должен быть виден в логе тика,
      # иначе "ничего не пришло" неотличимо от "проверка вообще не запускалась"
      Write-LiveLog 'Invoke-ReportVerify: OK'
    }
  } catch { Write-LiveLog "Invoke-ReportVerify: пропущено ($($_.Exception.Message))" }
}

function Invoke-DailyReport([switch]$Preview) {
  # $Preview=true (для -ReportNow): собрать и отправить, НО не двигать вотермарку/базу.
  if (-not $Preview -and [string]$st.watermarks.last_report_day -eq $mskToday) { return }

  # реальный, сверенный с брокером капитал (Set-BotCapital); profile_eq/peak_eq остаются
  # НЕТРОНУТЫМИ и продолжают питать Invoke-Governors - тут только то, что видит пользователь.
  # Капитал = счёт у брокера (bot_capital_account_rub, без двойного счёта вариационки).
  # Дашборд и Mini App показывают то же число - одна цифра на всех поверхностях.
  $capNow = if ($st.go.PSObject.Properties['bot_capital_account_rub'] -and $null -ne $st.go.bot_capital_account_rub) { [double]$st.go.bot_capital_account_rub }
            elseif ($st.go.PSObject.Properties['bot_capital_rub']) { [double]$st.go.bot_capital_rub }
            else { [double]$st.profile_eq }
  $peakNow = if ($st.go.PSObject.Properties['capital_peak_rub']) { [double]$st.go.capital_peak_rub } else { $capNow }
  # Пик копился на СТАРОЙ шкале (капитал + вариационка), поэтому просадка от него к новому
  # капиталу - арифметика двух разных линеек; до ребейза пика её не печатаем.
  $peakStale = ($st.go.PSObject.Properties['bot_capital_account_rub'] -and $null -ne $st.go.bot_capital_account_rub -and
    $null -ne $st.capital_breakdown -and [string]$st.capital_breakdown.model -eq 'legacy')

  $baseTs = if ($st.PSObject.Properties['report_base'] -and $st.report_base.PSObject.Properties['ts']) { [long]$st.report_base.ts } else { 0 }
  $baseCap = if ($baseTs -gt 0 -and $st.report_base.PSObject.Properties['bot_capital_rub']) { [double]$st.report_base.bot_capital_rub } else { $capNow }
  $hasPosBase = { param($id) $baseTs -gt 0 -and $st.report_base.positions.PSObject.Properties[$id] }

  $L = New-Object System.Collections.Generic.List[string]
  $L.Add("Фьючерсы — вечерний отчёт за $((MsToUtc $mskNowMs).ToString('dd.MM.yyyy'))")
  $L.Add('')
  $L.Add("Капитал бота: $(Fmt-Money $capNow '₽' 0)")
  $hoursTail = if ($baseTs -gt 0 -and ($NowMs - $baseTs) -gt 26 * 3600000) { " (за последние $([math]::Round(($NowMs - $baseTs)/3600000.0)) ч — прошлый отчёт не отправлялся)" } else { '' }
  # «За сутки» - число САМОГО брокера (daily_yield), то же, что в приложении и на дашборде.
  # Свой расчёт «капитал минус база отчёта» оставлен фолбэком: он сидит на report_base, который
  # штамповался в старой шкале капитала, и после перехода на счёт брокера дал бы фантомный скачок.
  $brk = if ($st.PSObject.Properties['broker']) { $st.broker } else { $null }
  $dayFromBroker = ($null -ne $brk -and $null -ne $brk.daily_yield_rub)
  if ($dayFromBroker) {
    $dpl = [double]$brk.daily_yield_rub
    $dplPct = if ($null -ne $brk.daily_yield_rel_pct) { [double]$brk.daily_yield_rel_pct } else { 0 }
    $L.Add("За сутки: $(Fmt-Money $dpl '₽' 0 -Sign) ($(Fmt-Pct $dplPct)) — по данным брокера")
  } else {
    $dpl = $capNow - $baseCap
    $dplPct = if ($baseCap -gt 0) { 100.0 * $dpl / $baseCap } else { 0 }
    $L.Add("За сутки: $(Fmt-Money $dpl '₽' 0 -Sign) ($(Fmt-Pct $dplPct)$hoursTail)")
  }
  if ($peakStale) { $L.Add('От максимума капитала: пик пересчитывается под новую модель капитала.') }
  else { $L.Add("От максимума капитала: $(Fmt-DdFromPeak $peakNow $capNow)") }
  # Фактические комиссии брокера рядом с оценкой в леджере: тариф в сделках занижен (0,025%
  # за сторону против ~0,043% по факту), и без этой строки реализованный P&L выглядит лучше.
  if ($st.PSObject.Properties['broker_ledger'] -and $null -ne $st.broker_ledger -and $null -ne $st.broker_ledger.fees_rub) {
    $L.Add("Комиссии брокера с запуска: $(Fmt-Money ([math]::Abs([double]$st.broker_ledger.fees_rub)) '₽' 0) (в сделках учтена оценка $(Fmt-Money ([double]$st.stats.fees_rub) '₽' 0))")
  }
  if (Test-Weekend) { $L.Add('Биржа закрыта (выходной) — позиции без изменений.') }
  $L.Add('')

  $open = @()
  foreach ($sn in 'core','setA') { foreach ($c in @($st.sleeves.$sn.positions)) { if ($null -ne $c) { $open += $c } } }
  $open = @($open | Sort-Object { [string]$_.asset })
  $pnlMap = Get-CardPnlMap $open
  $L.Add("Открытые позиции: $($open.Count)")
  $idx = 0
  $factPositions = New-Object System.Collections.Generic.List[object]
  foreach ($c in $open) {
    $idx++
    $nm = Cap (RfName $c)
    $L.Add("$idx) $nm — $(RuSide $c.side 'past') $([int]$c.lots) $(RuLots ([int]$c.lots)) по $(Fmt-Px ([double]$c.entry_px_pts)), стратегия «$(SleeveRu ([string]$c.sleeve))»")
    $upnl = if ($pnlMap.ContainsKey([string]$c.id)) { [double]$pnlMap[[string]$c.id] } else { 0.0 }
    $since = $upnl + [double]$c.realized_rub
    # База процента - ЗАДЕЙСТВОВАННОЕ ГО (решение пользователя 2026-09-01), а не номинал
    # контракта: номинал у фьючерса в разы больше вложенных денег, и процент от него занижал
    # результат до нечитаемых долей (+0,13% рядом с +36 680 ₽). Дашборд считает так же.
    # Фолбэк на номинал - для карточек без go_per_lot: лучше процент по старой базе, чем 0%
    # вместо результата (в PS без StrictMode отсутствующее поле дало бы тихий ноль).
    $goPos = if ($null -ne $c.go_per_lot) { [int]$c.lots * [double]$c.go_per_lot } else { 0.0 }
    $pctBase = if ($goPos -gt 0) { $goPos } else { [int]$c.lots_initial * [double]$c.entry_px_pts * [double]$c.rub_per_pt }
    $soPct = if ($pctBase -gt 0) { 100.0 * $since / $pctBase } else { 0 }
    $openTag = if ([string]$c.entry_day -eq $mskToday) { 'сегодня' } else { [datetime]::ParseExact([string]$c.entry_day, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture).ToString('dd.MM') }
    $dayVal = $since
    if (& $hasPosBase ([string]$c.id)) {
      $day = $since - [double]$st.report_base.positions.([string]$c.id)
      $dayVal = $day
      $dayPct = if ($pctBase -gt 0) { 100.0 * $day / $pctBase } else { 0 }
      $L.Add("   за сутки: $(Fmt-Money $day '₽' 0 -Sign) ($(Fmt-Pct $dayPct)$hoursTail) · с открытия ($openTag): $(Fmt-Money $since '₽' 0 -Sign) ($(Fmt-Pct $soPct))")
    } else {
      $L.Add("   с открытия ($openTag): $(Fmt-Money $since '₽' 0 -Sign) ($(Fmt-Pct $soPct))")
    }
    $factPositions.Add([pscustomobject]@{ asset = [string]$c.asset; day_pnl = [math]::Round($dayVal, 2); since_open_pnl = [math]::Round($since, 2) })
  }
  $L.Add('')

  # закрытые за окно (от прошлого отчёта; без базы - за сегодня по МСК)
  $closed = @()
  foreach ($x in @(Read-JsonFile (Join-Path $lrfDir 'trades.json'))) {
    if ($null -eq $x) { continue }
    $inWin = if ($baseTs -gt 0) { (UtcStrToMs ([string]$x.exitUtc)) -ge $baseTs } else { [string]$x.exitDay -eq $mskToday }
    if ($inWin) { $closed += $x }
  }
  $factClosed = New-Object System.Collections.Generic.List[object]
  if ($closed.Count -eq 0) { $L.Add('Закрытых сделок за сутки: нет') }
  else {
    $L.Add("Закрытых сделок за сутки: $($closed.Count)")
    foreach ($x in $closed) {
      $nmC = Cap (RuName $namesRu 'fut' ([string]$x.asset) ([string]$x.secid))
      $L.Add("• ${nmC}: $(Fmt-Money ([double]$x.pnlRub) '₽' 0 -Sign), $(RfReasonRu ([string]$x.exitReason))")
      $factClosed.Add([pscustomobject]@{ asset = [string]$x.asset; pnl = [math]::Round([double]$x.pnlRub, 2) })
    }
  }
  $L.Add('')

  $L.Add("По стратегиям: ядро $(Fmt-Money ([double]$st.sleeves.core.equity_mtm) '₽' 0) · сетап А $(Fmt-Money ([double]$st.sleeves.setA.equity_mtm) '₽' 0) · портфель акций $(Fmt-Money ([double]$st.sleeves.mom.equity_mtm) '₽' 0)")
  if ([double]$st.go.budget_rub -gt 0) {
    $L.Add("Гарантийное обеспечение (ГО): занято $(Fmt-Money ([double]$st.go.used_rub) '₽' 0) из $(Fmt-Money ([double]$st.go.budget_rub) '₽' 0)")
  }
  # Служебные строчки отчёта (суточная проверка, расхождения с брокером) помечаются по ИНДЕКСУ
  # в $L и вырезаются из клиентской версии ниже. Именно по индексу, а не по тексту: в $L есть
  # пустые строки-разделители, сравнение по значению вырезало бы чужие строки.
  $opsIdx = New-Object System.Collections.Generic.HashSet[int]
  if ($st.PSObject.Properties['readiness']) {
    $rdy = $st.readiness
    if (@($rdy.failed).Count -eq 0 -and [bool]$rdy.fits) {
      $L.Add("Готовность инструментов: $($rdy.checked_n)/$($rdy.total_n) торгуются, худший случай ГО $(Fmt-Money ([double]$rdy.go_worst_rub) '₽' 0) укладывается в кэп $(Fmt-Money ([double]$rdy.go_cap_rub) '₽' 0).")
    } else {
      # Перечисляем ТОЛЬКО те проверки, что реально не сошлись. Раньше строка печатала обе
      # безусловно, и при чистом брокере выдавала «недоступно у брокера: 0» - нулевой счётчик
      # рядом со словом «проблема» читался как отдельная авария (вопрос пользователя 2026-08-26).
      # Превышение худшего случая ГО - штатное состояние (канон шире кэпа), поэтому без «ВНИМАНИЕ».
      $why = New-Object System.Collections.Generic.List[string]
      if (@($rdy.failed).Count -gt 0) {
        $why.Add("недоступны у брокера: $(@($rdy.failed).Count) из $($rdy.total_n) (см. алерт)")
      }
      if (-not [bool]$rdy.fits) {
        $why.Add(("худший случай ГО {0} превышает кэп {1} — это если бы все {2}+{2} слота заполнились разом; на реальные заявки не влияет, их режет governor" -f (Fmt-Money ([double]$rdy.go_worst_rub) '₽' 0), (Fmt-Money ([double]$rdy.go_cap_rub) '₽' 0), $MAXCONC))
      }
      $L.Add("Суточная проверка готовности: $($why -join '; ').")
    }
    [void]$opsIdx.Add($L.Count - 1)
  }
  $dsum = [int]$st.drift.D2 + [int]$st.drift.D4 + [int]$st.drift.D5 + [int]$st.drift.D6
  if ($dsum -eq 0) { $L.Add("Расхождений с брокером нет (D2/D4/D5/D6 = $($st.drift.D2)/$($st.drift.D4)/$($st.drift.D5)/$($st.drift.D6))") }
  else { $L.Add("Внимание, расхождения с брокером: D2/D4/D5/D6 = $($st.drift.D2)/$($st.drift.D4)/$($st.drift.D5)/$($st.drift.D6)") }
  [void]$opsIdx.Add($L.Count - 1)
  if ($st.entries_halt.active) { $L.Add("Новые входы остановлены: $([string]$st.entries_halt.reason)") }
  else { $L.Add('Входы разрешены, торговля идёт штатно.') }
  if ($open.Count -gt 0) { $L.Add('Проценты по позициям — от задействованного ГО (вложенной маржи), P&L — по данным брокера.') }

  $txt = ($L -join "`n")
  # Клиентская версия - тот же отчёт без служебных строк ($opsIdx). Деньги (капитал, P&L,
  # позиции, сделки, ГО занято, статус входов) остаются; техническая диагностика - нет.
  $clientLines = Get-ClientLines $L $opsIdx
  $txtClient = ($clientLines -join "`n")
  $script:jr.Add("`r`n## $(MsToUtcStr $mskNowMs) MSK — вечерний отчёт`r`n$txt`r`n")
  try { Send-TgAlert $txt | Out-Null } catch {}
  if ($env:TG_CHAT_ID_FUT) { try { Send-TgAlert $txtClient -Chat $env:TG_CHAT_ID_FUT | Out-Null } catch {} }

  # ИИ-проверка ПОСЛЕ отправки: сверка уже готового текста с фактами, никогда не блокирует
  # и не задерживает сам отчёт (см. Invoke-ReportVerify - fail-open по конструкции).
  $facts = [pscustomobject]@{
    capital_rub = $capNow; peak_rub = $peakNow; capital_day_delta = $dpl
    capital_day_source = $(if ($dayFromBroker) { 'broker' } else { 'report_base' })
    positions = $factPositions; closed = $factClosed
    drift = $st.drift
  }
  Invoke-ReportVerify $txt $facts

  if (-not $Preview) {
    $st.watermarks.last_report_day = $mskToday
    # пересъём базы «за сутки»: одно число на позицию = её суммарный брокерский P&L сейчас
    $posBase = [pscustomobject]@{}
    foreach ($c in $open) {
      $upnl = if ($pnlMap.ContainsKey([string]$c.id)) { [double]$pnlMap[[string]$c.id] } else { 0.0 }
      $posBase | Add-Member -NotePropertyName ([string]$c.id) -NotePropertyValue ([math]::Round($upnl + [double]$c.realized_rub, 2)) -Force
    }
    $rb = [pscustomobject]@{ day = $mskToday; ts = $NowMs; profile_eq = [double]$st.profile_eq
      bot_capital_rub = $capNow; positions = $posBase }
    if ($st.PSObject.Properties['report_base']) { $st.report_base = $rb } else { $st | Add-Member -NotePropertyName report_base -NotePropertyValue $rb }
  }
}

# ================= подтверждение цены входа по операциям брокера =================
# Ответ PostOrder — не истина в последней инстанции: поле «подано» дважды маскировалось под
# «исполнено» (L00008 2026-07-21, протектив-полоса рыночной заявки 2026-08-04). Истина —
# операции брокера, и движок уже верит им при закрытии по стопу, TP1 и adopt. Здесь та же
# проверка применяется ко ВХОДУ.
#
# Почему это не всплывало само: Invoke-Reconcile сравнивает ЛОТЫ, а не цены. Расхождение
# в 0.2% не даёт ни одного дрифта и тихо живёт в P&L, в стопе (он считается от входа) и в
# статистике контура.
#
# Окно операций запрашивается ЯВНО от времени сделки: кэш Get-OpsSince скользит на час, и
# к моменту проверки вход из него уже мог выпасть. Одна карточка — один успешный запрос.
$ENTRY_PX_MAX_TRIES = 20      # после стольких безуспешных попыток перестаём дёргать API
$ENTRY_PX_MAX_AGE_MS = 259200000   # 3 суток: дальше операции запрашивать бессмысленно

function Confirm-EntryPx($C) {
  if ($C.PSObject.Properties['entry_px_ok'] -and $C.entry_px_ok) { return }
  $ageMs = $NowMs - [long]$C.entry_ts
  $tries = if ($C.PSObject.Properties['entry_px_tries']) { [int]$C.entry_px_tries } else { 0 }
  if ($ageMs -gt $ENTRY_PX_MAX_AGE_MS -or $tries -ge $ENTRY_PX_MAX_TRIES) {
    $C | Add-Member -NotePropertyName entry_px_ok -NotePropertyValue $true -Force   # сдаёмся молча
    return
  }
  $C | Add-Member -NotePropertyName entry_px_tries -NotePropertyValue ($tries + 1) -Force

  $want = if ([string]$C.side -eq 'long') { 'OPERATION_TYPE_BUY' } else { 'OPERATION_TYPE_SELL' }
  $ops = @()
  try {
    $ops = @(Get-TiOperations ([string]$st.account_id) `
        ((MsToUtc ([long]$C.entry_ts - 300000)).ToString('yyyy-MM-ddTHH:mm:ssZ')) `
        ((MsToUtc $NowMs).ToString('yyyy-MM-ddTHH:mm:ssZ')))
  } catch {
    # операции недоступны — не сдаёмся, попробуем следующим тиком (как adopt/D4)
    Write-LiveLog "entry-px $($C.id): operations недоступны ($($_.Exception.Message)) - проверка отложена"
    return
  }
  # СТРОГИЙ матчинг, как в Find-FillOperation: инструмент + направление + количество
  $op = $null
  foreach ($o in $ops) {
    if ($null -eq $o) { continue }
    if ([string](Get-TiField $o 'instrument_uid') -ne [string]$C.uid) { continue }
    if ([string](Get-TiField $o 'operation_type') -ne $want) { continue }
    $q = 0.0
    try { $q = [double][string](Get-TiField $o 'quantity') } catch {}
    if ($q -ne [int]$C.lots_initial) { continue }
    $op = $o; break
  }
  if ($null -eq $op) { return }   # ещё не проросла в операции — следующий тик

  $real = 0.0
  try { $real = [double](M2D $op.price).value } catch {}
  $old = [double]$C.entry_px_pts
  # тот же 30%-ый предохранитель, что в лестнице: мусорную цену в карточку не пускаем
  if ($real -le 0 -or $old -le 0 -or [math]::Abs($real / $old - 1) -gt 0.30) {
    Write-LiveLog "entry-px $($C.id): операция даёт $real против $old - вне ворот, игнор"
    $C | Add-Member -NotePropertyName entry_px_ok -NotePropertyValue $true -Force
    return
  }
  $C | Add-Member -NotePropertyName entry_px_ok -NotePropertyValue $true -Force
  if ([math]::Abs($real - $old) -lt 1e-9) { return }   # совпало — тихо

  # чиним всё, что считается ОТ цены входа
  $lots0 = [int]$C.lots_initial
  $newFee = [math]::Round($lots0 * $real * [double]$C.rub_per_pt * [double]$LIVE.fee_est, 2)
  $sl = Get-SleeveRef ([string]$C.sleeve)
  $sl.eq_rub = [double]$sl.eq_rub - ($newFee - [double]$C.fees_rub)
  $C.fees_rub = $newFee
  if ([math]::Abs([double]$C.mfe_pts - $old) -lt 1e-9) { $C.mfe_pts = [math]::Round($real, 6) }
  $C.entry_px_pts = [math]::Round($real, 6)
  if ($C.PSObject.Properties['tp1_px_pts'] -and $null -ne $C.tp1_px_pts -and -not $C.tp1_done) {
    $C.tp1_px_pts = [math]::Round($real + ([double]$C.tp1_px_pts - $old), 6)
  }
  # Стоп-заявку у брокера НЕ трогаем: двигать живую защиту на реальных деньгах — отдельное
  # решение пользователя. Считаем, каким он должен был быть, и говорим об этом вслух;
  # дневной трейл-хук всё равно приведёт его к правилу.
  $sm = if ([string]$C.side -eq 'long') { 1.0 } else { -1.0 }
  $wantStop = [math]::Round($real - $sm * 2.0 * [double]$C.atr_entry, 6)
  $msg = ("цена входа {0} уточнена по операциям брокера: {1} -> {2} (в ответе на заявку была цена ПОДАННОЙ заявки, а не сделки). Комиссия пересчитана. Стоп у брокера остался {3}; по правилу 2xATR от реальной цены он должен быть {4} — живую стоп-заявку бот не двигает, это решение за вами." -f `
      $C.id, $old, [double]$C.entry_px_pts, [double]$C.stop_px_pts, $wantStop)
  $script:ev.Add("ENTRY-PX FIX $($C.id): $old -> $($C.entry_px_pts)")
  $script:jr.Add(("`r`n## {0} MSK — RF-LIVE: {1}`r`n" -f (MsToUtcStr $mskNowMs), $msg))
  Alert $msg
}

function Invoke-ConfirmEntryPx {
  foreach ($sn in 'core', 'setA') {
    foreach ($c in @((Get-SleeveRef $sn).positions)) {
      if ($null -eq $c) { continue }
      try { Confirm-EntryPx $c } catch { Write-LiveLog "entry-px $($c.id): $($_.Exception.Message)" }
    }
  }
}

# ================= живость брокера: алерты о потере связи =================
# Закрывает дыры, вскрытые инцидентом 2026-08-03 (TLS-цепочка Минцифры): алерт стрелял
# ровно один раз (consec_fail -eq 5), о восстановлении не сообщал, при затяжном сбое
# молчал, а отозванный токен давал ровно тот же текст «до восстановления связи» - хотя
# сам он не восстановится никогда. Образец поведения - deploy/git_sync_watch.sh.
$BROKER_ALERT_AFTER = 5    # неудачных preflight подряд до первого алерта
$BROKER_REPEAT_MIN = 60    # период напоминаний, пока связи нет

function Note-BrokerFail([string]$ErrText) {
  $n = [int]$st.consec_fail + 1
  $st | Add-Member -NotePropertyName consec_fail -NotePropertyValue $n -Force
  if (-not $st.PSObject.Properties['fail_since_ms'] -or [long]$st.fail_since_ms -le 0) {
    $st | Add-Member -NotePropertyName fail_since_ms -NotePropertyValue $NowMs -Force
  }
  if ($n -lt $BROKER_ALERT_AFTER) { return }
  $lastMsg = if ($st.PSObject.Properties['fail_alert_ms']) { [long]$st.fail_alert_ms } else { 0 }
  $due = ($lastMsg -le 0) -or ((($NowMs - $lastMsg) / 60000.0) -ge $BROKER_REPEAT_MIN)
  if (-not $due) { return }
  $downMin = [int][math]::Floor(($NowMs - [long]$st.fail_since_ms) / 60000.0)
  $nw = Plural $n 'проверка' 'проверки' 'проверок'
  $mw = Plural $downMin 'минута' 'минуты' 'минут'
  # 401/403 от gateway - это «ключ», а не «сеть»: ждать восстановления бессмысленно
  if ($ErrText -match 'TINVEST_HTTP_40[13]') {
    Alert ("брокер отклоняет авторизацию ({0} {1} подряд, {2} {3}). Это НЕ сетевой сбой: токен отозван или просрочен, сам он не восстановится - нужно заменить TINVEST_TOKEN в /etc/trading-live.env. Торговый цикл приостановлен, открытые позиции и стоп-заявки у брокера продолжают действовать." -f $n, $nw, $downMin, $mw)
  } else {
    Alert ("брокер Т-Инвест не отвечает уже {0} {1} подряд ({2} {3}) — торговый цикл приостановлен до восстановления связи. Открытые позиции и стоп-заявки у брокера продолжают действовать." -f $n, $nw, $downMin, $mw)
  }
  $st | Add-Member -NotePropertyName fail_alert_ms -NotePropertyValue $NowMs -Force
}

function Note-BrokerOk {
  $alerted = $st.PSObject.Properties['fail_alert_ms'] -and [long]$st.fail_alert_ms -gt 0
  if ($alerted) {
    $downMin = [int][math]::Floor(($NowMs - [long]$st.fail_since_ms) / 60000.0)
    Alert ("связь с брокером восстановлена, торговый цикл продолжен (простой был около {0} {1})." -f $downMin, (Plural $downMin 'минута' 'минуты' 'минут'))
  }
  $st | Add-Member -NotePropertyName consec_fail -NotePropertyValue 0 -Force
  $st | Add-Member -NotePropertyName fail_since_ms -NotePropertyValue 0 -Force
  $st | Add-Member -NotePropertyName fail_alert_ms -NotePropertyValue 0 -Force
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
  elseif ([string]$st.entries_halt.reason -eq 'HALT_RF_ENTRIES file') { Clear-EntriesHalt 'kill-файл HALT_RF_ENTRIES удалён' }

  # 2. выходные: лёгкий тик (сверка раз в ~30 мин, никаких заявок)
  $weekendLight = ((Test-Weekend) -and -not $LIVE.trade_weekends)

  # 3. preflight: маржа/ликвидность; фолбэк MarginAttributes -> GetPortfolio (песочница: 404,
  # prod без маржиналки: то же); полный сбой -> тик прерван, вотермарки не двигаются
  $margin = $null
  $pfPre = $null   # снимок портфеля для расчёта точного капитала (переиспользуем фолбэк-фетч)
  # margin_disabled (config.json): на боевом счёте маржиналка ОТКЛЮЧЕНА, GetMarginAttributes всегда
  # отдаёт 400 - не тратим на него вызов каждый тик (боевой факт, подтверждён latency_log 2026-08-18).
  # Путь фолбэка тот же, что и при ошибке маржи: портфель -> total_amount_portfolio.
  if (-not [bool]$LIVE.margin_disabled) {
    try { $margin = Get-TiMarginAttributes ([string]$st.account_id) } catch { $margin = $null }
  }
  if ($null -eq $margin) {
    try {
      $pfPre = Get-TiPortfolio ([string]$st.account_id)
      $margin = [pscustomobject]@{ liquid = [double](M2D (Get-TiField $pfPre 'total_amount_portfolio')).value }
    } catch {
      Write-LiveLog "preflight: маржа и портфель недоступны: $($_.Exception.Message)"
      Note-BrokerFail ([string]$_.Exception.Message)
      Save-State
      return
    }
  }
  Note-BrokerOk   # сброс счётчика + «связь восстановлена», если алерт уже уходил
  Update-GoBudget $margin
  Set-BotCapital $pfPre   # $null если маржа сработала -> функция дотянет GetPortfolio сама

  # -ReportNow: пересчитать MTM, отправить вечерний отчёт с текущими числами и выйти БЕЗ сохранения
  # (никаких сверок/заявок/губернаторов; вотермарка и база не двигаются - плановый отчёт в 21:00 всё равно уйдёт)
  if ($ReportNow) {
    Invoke-Mtm
    Invoke-DailyReport -Preview
    Write-LiveLog 'ReportNow: вечерний отчёт отправлен (состояние не сохранялось)'
    return
  }

  # 3b. разовый ручной ребейз рукавов на новую базу капитала (конфиг + вотермарка = ровно один раз)
  Invoke-SleeveRebase
  # 3c. авто-ребейз (выключен по умолчанию, см. Invoke-AutoRebase)
  Invoke-AutoRebase

  # 4. сверка (полная, каждый тик - нюансы #3/#4/#13): снимок стоп-заявок -> TP1-sync (ДО D5,
  # иначе усечение лотов опередит объяснение частичного филла) -> reconcile
  $stopIds = Get-BrokerStopIds
  Invoke-Tp1Sync $stopIds
  Invoke-Reconcile $stopIds

  # 5. state machine polling
  Invoke-IntentPolling

  # 5b. цена входа по операциям брокера - СТРОГО до MTM: переоценка и governors должны
  # считать от реальной цены сделки, а не от цены поданной заявки (инцидент 2026-08-04)
  Invoke-ConfirmEntryPx

  # 6. MTM + governors
  Invoke-Mtm
  Invoke-Governors

  # 6b. брокерский леджер (реальные комиссии + сведённая вариационка) - ПОСЛЕ всей торговой
  # логики и только в вечернем окне.
  # ПОЧЕМУ так поздно: это отчётность, и она не имеет права тратить вызовы к брокеру раньше
  # state machine. Стоял в preflight - и на сценарии adopt-ops-fail съедал тот самый
  # GetOperations, который движок держит для adopt: LOST-интент «усыновлялся» по чужому
  # ответу вместо того, чтобы остаться LOST (риск двойного филла). Отчётность идёт последней.
  # ПОЧЕМУ вечером: вариационка сводится на вечернем клиринге (~19:00-21:00 MSK), раньше
  # читать нечего; к 23:55 вечерний отчёт получает уже свежие числа.
  Invoke-BrokerLedger

  # 7. расписание (MSK), всё идемпотентно через вотермарки
  if (-not $weekendLight) {
    if ($mskHHmm -ge '00:20' -and [string]$st.watermarks.last_daily_day -lt $completedDay) { Invoke-LiveDaily }
    if ((In-Window ([string]$LIVE.entry_from) ([string]$LIVE.entry_till)) -and (Can-PostOrders)) { Invoke-EntryWindow }
    if ((In-Window ([string]$LIVE.roll_from) ([string]$LIVE.roll_till)) -and (Can-PostOrders)) { Invoke-RollWindow }
    if ($mskHHmm -ge [string]$LIVE.mom_from -and $mskHHmm -le '18:00' -and (Can-PostOrders)) { Invoke-MomWindow }
    # Путь A (2026-08): вечерняя проверка почти-финальной цены ядра, узкое окно ДО ночного
    # клиринга ($CLEARING начинается в 23:48) - см. Invoke-EveningConfirm
    if ((In-Window '23:35' '23:47') -and (Can-PostOrders)) { Invoke-EveningConfirm }
    Invoke-HourlyPass   # частоту гейтит вотермарка last_hour_ts (новых закрытых часовиков нет - выходит сразу)
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
    # второй проход: карточка, родившаяся в окне входов ВЫШЕ, до шага 5b ещё не существовала.
    # Флаг entry_px_ok делает проход no-op для всех уже подтверждённых, поэтому лишний вызов
    # стоит один запрос операций на свежий вход - зато цена чинится сразу, а не через минуту.
    Invoke-ConfirmEntryPx
  }

  # вечерний отчёт 21:00 МСК - и в будни, и в выходные (MTM уже пересчитан в шаге 6)
  if ($mskHHmm -ge [string]$LIVE.report_at) { Invoke-DailyReport }

  # 8. ops-вотермарка вперёд (операции старше часа уже учтены сверками)
  $script:opsCache = @{}
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
