# sandbox_drill.ps1 - функциональная матрица LIVE-контура против ЖИВОЙ песочницы T-Invest.
# НЕ ждёт сигналов: инжектит интенты/карточки в состояние отдельного корня и гонит тики движка
# с подставным -NowMs (окна сессии), но с РЕАЛЬНЫМИ вызовами API песочницы (PostOrder/GetOrderState/
# GetOperations/GetPortfolio). Закрывает чек-лист этапа C плана запуска и вопрос №1 реестра
# (идемпотентность order_id). Требует заполненный .secrets\tinvest.env.ps1 (TINVEST_SANDBOX_TOKEN).
# Запуск: powershell -File tools\sandbox_drill.ps1            # весь чек-лист
#         powershell -File tools\sandbox_drill.ps1 -Step entry # один шаг
param(
  [string]$Root = '',            # песочный корень состояния; '' = %TEMP%\lrf_sandbox_drill
  [string]$Step = '',            # '' = все: entry,stop,tp1,be,roll,mom,reject,idem,kill,crash,d2
  [switch]$Fresh,                # пересоздать корень и песочный счёт заново
  [switch]$KeepAccount           # не закрывать песочный счёт в конце
)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'lib_engine.ps1')
. (Join-Path $PSScriptRoot 'lib_rf_signals.ps1')
. (Join-Path $PSScriptRoot 'lib_tinvest.ps1')
$secretsPath = Join-Path $Repo '.secrets\tinvest.env.ps1'
if (Test-Path $secretsPath) { . $secretsPath }
if (-not $env:TINVEST_SANDBOX_TOKEN) { throw 'нет TINVEST_SANDBOX_TOKEN (.secrets\tinvest.env.ps1)' }
if (-not $Root) { $Root = Join-Path $env:TEMP 'lrf_sandbox_drill' }
$ENGINE = Join-Path $PSScriptRoot 'live_rf_engine.ps1'
$lrf = Join-Path $Root 'data\live_rf'

$script:res = New-Object System.Collections.Generic.List[object]
function Note([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $script:res.Add([pscustomobject]@{ step = $Name; ok = $Ok; detail = $Detail })
  $mark = if ($Ok) { 'PASS' } else { 'FAIL' }
  Write-Host ("[{0}] {1} {2}" -f $mark, $Name, $Detail) -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
}

# ================= песочный счёт =================
Initialize-TInvest $lrf 'sandbox'
Resolve-TiSandboxBase
$drillMeta = Join-Path $Root 'drill.json'
$acc = $null
if (-not $Fresh -and (Test-Path $drillMeta)) { $acc = (Read-JsonFile $drillMeta).account_id }
if (-not $acc) {
  $existing = @(Get-TiSandboxAccounts)
  foreach ($a in $existing) { try { Close-TiSandboxAccount ([string]$a.id) | Out-Null } catch {} }
  $acc = Open-TiSandboxAccount 'rf-live-drill'
  Invoke-TiSandboxPayIn $acc ([decimal]700000) | Out-Null
  Write-Host "песочный счёт: $acc (пополнен 700 000 ₽)"
}
$env:TINVEST_ACCOUNT_ID = $acc
$script:TI.accountId = $acc

# ================= инструменты (реальные фронты из ISS + uid из API) =================
$fronts = Get-FutFronts @('NG','CNY')
$ngFront = $fronts['NG'][0]; $ngNext = $fronts['NG'][1]; $cnyFront = $fronts['CNY'][0]
Write-Host "фронты: NG=$($ngFront.secid) (next $($ngNext.secid)), CNY=$($cnyFront.secid)"
$inst = @{}
foreach ($t in @(@($ngFront.secid, $ngNext.secid, $cnyFront.secid) | ForEach-Object { @{ k = $_; kind = 'fut' } }) + @(@{ k = 'SBER'; kind = 'share' })) {
  $i = Get-TiInstrument ([string]$t.k) ([string]$t.kind)
  $rec = @{ uid = [string]$i.uid; lot = [int]$i.lot; kind = [string]$t.kind }
  if ($t.kind -eq 'fut') {
    $m = Get-TiFuturesMargin ([string]$i.uid)
    $amt = $m.min_price_increment_amount; if ($null -eq $amt -and $m.PSObject.Properties['minPriceIncrementAmount']) { $amt = $m.minPriceIncrementAmount }
    $incQ = Q2D $i.min_price_increment
    $rec.rubPt = if ($incQ -gt 0) { [double]((Q2D $amt) / $incQ) } else { 0.0 }
  }
  $inst[[string]$t.k] = $rec
}
$ngUid = $inst[$ngFront.secid].uid
$lastPx = @{}
foreach ($lp in (Get-TiLastPrices @($ngUid, $inst[$cnyFront.secid].uid, $inst['SBER'].uid))) {
  $u = if ($lp.PSObject.Properties['instrumentUid']) { [string]$lp.instrumentUid } else { [string]$lp.instrument_uid }
  $lastPx[$u] = [double](Q2D $lp.price)
}
$ngPx = $lastPx[$ngUid]
Write-Host ("last: NG={0} CNY={1} SBER={2}" -f $ngPx, $lastPx[$inst[$cnyFront.secid].uid], $lastPx[$inst['SBER'].uid])

# ================= корень состояния =================
$mskNowReal = (Get-Date).ToUniversalTime().AddHours(3)
$today = $mskNowReal.ToString('yyyy-MM-dd')
$yday = $mskNowReal.AddDays(-1).ToString('yyyy-MM-dd')
function D2Ms([string]$s) { UtcStrToMs $s }
function TickAt([string]$hhmm) {
  # тик с подставным временем «сегодня hh:mm MSK»; API-вызовы реальные (sandbox)
  $nowMs = (UtcStrToMs "$today $hhmm") - $MSK
  $env:TINVEST_MODE = 'sandbox'; $env:TINVEST_MOCK_DIR = $null
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -Command ". '$ENGINE' -Root '$Root' -NowMs $nowMs" 2>&1
  return ($out | Out-String)
}
function Get-St { Read-JsonFile (Join-Path $lrf 'portfolio.json') }
function Set-St($s) { Write-JsonAtomic (Join-Path $lrf 'portfolio.json') $s 14 }
function Get-Dtrades { ,@(@((Read-JsonFile (Join-Path $lrf 'trades.json'))) | Where-Object { $null -ne $_ }) }

function New-DrillState {
  # состояние «спокойного дня» с реальными фронтами/uid; вотермарки так, что daily-хук не бежит
  [pscustomobject]@{
    schema = 1; mode = 'sandbox'; account_id = $acc
    meta = [pscustomobject]@{ profile = 'C3b-live'; created = "$yday 00:00"; base_rub = 700000.0
      core_risk = 0.05; seta_risk = 0.02; mom_weight = 0.5 }
    sleeves = [pscustomobject]@{
      core = [pscustomobject]@{ eq_rub = 700000.0; month_start_eq = 700000.0; day_start_eq = 700000.0
        halt_day = $null; positions = @(); equity_mtm = 700000.0 }
      setA = [pscustomobject]@{ eq_rub = 700000.0; month_start_eq = 700000.0; day_start_eq = 700000.0
        halt_day = $null; positions = @(); equity_mtm = 700000.0 }
      mom = [pscustomobject]@{ eq_rub = 350000.0; month_start_eq = 350000.0; cash_rub = 350000.0
        holdings = @(); last_rebalance_month = ''; equity_mtm = 350000.0 } }
    profile_eq = 700000.0; profile_month_start = 700000.0; cur_month = $today.Substring(0,7)
    day_start_eq = 700000.0; day_start_date = $today; peak_eq = 700000.0
    watermarks = [pscustomobject]@{ last_daily_day = (Get-RfCompletedDay ([long]((D2Ms "$today 12:00"))))
      last_hour_ts = (D2Ms "$today 09:00"); ops_since = ((Get-Date).ToUniversalTime().AddHours(-2).ToString('yyyy-MM-ddTHH:mm:ssZ'))
      last_eq_snap = [long]0; last_report_day = ''; orders_day = $today; orders_day_n = 0 }
    fronts = [pscustomobject]@{
      NG  = [pscustomobject]@{ secid = $ngFront.secid; lasttrade = $ngFront.lasttrade; next = $ngNext.secid; next_lasttrade = $ngNext.lasttrade }
      CNY = [pscustomobject]@{ secid = $cnyFront.secid; lasttrade = $cnyFront.lasttrade; next = $null; next_lasttrade = $null } }
    active = [pscustomobject]@{ NG = $ngFront.secid; CNY = $cnyFront.secid }
    rearm = [pscustomobject]@{}
    entries_halt = [pscustomobject]@{ active = $false; reason = ''; since = '' }
    go = [pscustomobject]@{ used_rub = 0.0; budget_rub = 0.0; peak_day_rub = 0.0 }
    drift = [pscustomobject]@{ D2 = 0; D4 = 0; D5 = 0; D6 = 0; stocks_deficit = 0; last = '' }
    pending_intents = @(); next_intent_id = 1
    stats = [pscustomobject]@{ trades = 0; wins = 0; losses = 0; fees_rub = 0.0; realized_rub = 0.0
      orders_posted = 0; fills = 0; skipped_qty0 = 0; signal_mismatch = 0 }
    consec_fail = 0
  }
}
function Reset-DrillRoot {
  if (Test-Path $Root) { Remove-Item $Root -Recurse -Force }
  New-Item -ItemType Directory -Force (Join-Path $lrf 'series') | Out-Null
  foreach ($a in @('NG','CNY') + @('SBER','GAZP','IMOEX')) {
    $src = Join-Path $Repo "data\rf\series\$a.json"
    if (Test-Path $src) { Copy-Item $src (Join-Path $lrf "series\$a.json") -Force }
  }
  # trade_weekends=true: дрилл можно гонять в любой день; emulate_stops: в песочнице нет StopOrders
  Write-JsonAtomic (Join-Path $lrf 'config.json') ([pscustomobject]@{ emulate_stops = $true; trade_weekends = $true }) 3
  Set-St (New-DrillState)
  Write-JsonAtomic $drillMeta ([pscustomobject]@{ account_id = $acc; created = (Get-Date).ToUniversalTime().ToString('u') }) 3
}
function New-DrillIntent($s, [string]$Kind, [string]$Sleeve, [string]$Asset, [string]$Ticker, [string]$Uid, [string]$Side, [int]$Lots, $Ctx) {
  $id = 'i{0:d5}' -f [int]$s.next_intent_id
  $s.next_intent_id = [int]$s.next_intent_id + 1
  $it = [pscustomobject]@{
    id = $id; kind = $Kind; sleeve = $Sleeve; asset = $Asset; ticker = $Ticker; uid = $Uid
    side = $Side; lots = $Lots; filled_lots = 0; avg_fill_px = $null
    order_key = "LRF-$id-$($Kind -replace '_','')"; broker_order_id = ''
    state = 'INTENT'; attempts = 0
    t_signal = (D2Ms "$yday 23:50"); t_post = [long]0; t_ack = [long]0; t_fill = [long]0
    created_day = $yday; state_ts = (D2Ms "$today 00:25"); last_error = ''
    ctx = $Ctx
  }
  $s.pending_intents = ToArr (@($s.pending_intents) + $it)
  return $it
}
function New-DrillCard($s, [string]$Sleeve, [string]$Asset, [string]$Secid, [string]$Uid, [string]$Side, [int]$Lots, [double]$Entry, [double]$Stop, [double]$RubPt, $Tp1 = $null) {
  $card = [pscustomobject]@{
    id = "Ldrill$($s.next_intent_id)"; sleeve = $Sleeve; asset = $Asset; secid = $Secid; uid = $Uid; figi = 'F'
    side = $Side; lots = $Lots; lots_initial = $Lots
    entry_px_pts = $Entry; entry_day = $yday; entry_ts = (D2Ms "$yday 10:01")
    stop_px_pts = $Stop; stop_order_id = ''; stop_lots = $Lots
    tp1_px_pts = $Tp1; tp1_order_id = ''; tp1_done = $false; be_moved = $false
    mfe_pts = $Entry; atr_entry = 0.1
    risk_rub = 10000.0; rub_per_pt = $RubPt; go_per_lot = 6000.0
    rolls = 0; fees_rub = 0.0; realized_rub = 0.0
    d6_fails = 0; quarantine = $false; stop_deferred = $null; last_stop_update = ''
    lat_sp = 0; lat_pf = 0
  }
  $s.next_intent_id = [int]$s.next_intent_id + 1
  $s.sleeves.$Sleeve.positions = ToArr (@($s.sleeves.$Sleeve.positions) + $card)
  return $card
}
function Flatten-Sandbox {
  # прибрать все позиции песочного счёта маркетами (гигиена между шагами)
  try {
    $pf = Get-TiPortfolio $acc
    foreach ($p in @($pf.positions)) {
      if ($null -eq $p) { continue }
      $uid = if ($p.PSObject.Properties['instrumentUid']) { [string]$p.instrumentUid } else { [string]$p.instrument_uid }
      $lots = [double](Q2D $p.quantityLots)
      if ($lots -eq 0 -and $p.PSObject.Properties['quantity_lots']) { $lots = [double](Q2D $p.quantity_lots) }
      if ([math]::Abs($lots) -lt 1) { continue }
      $dir = if ($lots -gt 0) { 'sell' } else { 'buy' }
      Post-TiMarketOrder $acc $uid $dir ([int][math]::Abs($lots)) ("FLAT-" + [guid]::NewGuid().ToString('N').Substring(0,12)) | Out-Null
    }
  } catch { Write-Warning "flatten: $($_.Exception.Message)" }
}

$ngRubPt = [double]$inst[$ngFront.secid].rubPt
$stopDist = [math]::Round($ngPx * 0.02, 4)   # синтетический стоп ~2% цены (маленький реальный риск)

# ================= ШАГИ =================
function Drill-Entry {
  Reset-DrillRoot
  $s = Get-St
  [void](New-DrillIntent $s 'entry' 'core' 'NG' '' '' 'buy' 0 ([pscustomobject]@{
    stop_dist = $stopDist; atr = $stopDist/2; risk_pct = 0.01; ref_px = $ngPx; note = 'drill' }))
  Set-St $s
  [void](TickAt '10:05'); [void](TickAt '10:06')
  $s = Get-St
  $pos = @($s.sleeves.core.positions)
  Note 'entry: реальный market-филл -> карточка' ($pos.Count -eq 1) $(if ($pos.Count) { "lots=$($pos[0].lots) entry=$($pos[0].entry_px_pts)" } else { 'нет карточки' })
  if ($pos.Count) { Note 'entry: цена филла разумна (±5% от last)' ([math]::Abs([double]$pos[0].entry_px_pts - $ngPx) / $ngPx -lt 0.05) "fill=$($pos[0].entry_px_pts) vs last=$ngPx" }
  Note 'entry: интентов не осталось' (@($s.pending_intents).Count -eq 0)
}
function Drill-Stop {
  # стоп-эмуляция: форс-касание (для лонга стоп ВЫШЕ рынка всегда «тронут» часовиком)
  $s = Get-St
  $pos = @($s.sleeves.core.positions)
  if (-not $pos.Count) { Note 'stop: нет позиции после entry' $false; return }
  $pos[0].stop_px_pts = [math]::Round($ngPx * 1.5, 4)
  $s.watermarks.last_hour_ts = (D2Ms "$today 09:00")   # заставить hourly-pass пройти свежие часовики
  Set-St $s
  [void](TickAt '12:16'); [void](TickAt '12:17')
  $s = Get-St
  $tr = Get-Dtrades
  Note 'stop-emu: позиция закрыта реальным market' (@($s.sleeves.core.positions).Count -eq 0 -and $tr.Count -ge 1) $(if ($tr.Count) { "exit=$($tr[-1].exitPx) reason=$($tr[-1].exitReason)" })
}
function Drill-Tp1 {
  $s = Get-St
  $card = New-DrillCard $s 'setA' 'NG' $ngFront.secid $ngUid 'long' 2 $ngPx ([math]::Round($ngPx*0.9,4)) $ngRubPt ([math]::Round($ngPx*0.95,4))
  # tp1 НИЖЕ рынка у лонга -> h>=tp1 всегда: форс-срабатывание TP1-эмуляции
  $s.watermarks.last_hour_ts = (D2Ms "$today 09:00")
  Set-St $s
  # песочному счёту нужна реальная позиция 2 лота, чтобы продажа половины была честной
  Post-TiMarketOrder $acc $ngUid 'buy' 2 ("SEED-" + [guid]::NewGuid().ToString('N').Substring(0,10)) | Out-Null
  [void](TickAt '13:16'); [void](TickAt '13:17')
  $s = Get-St
  $c = @($s.sleeves.setA.positions | Where-Object { $_.id -eq $card.id })
  Note 'tp1-emu: половина закрыта, tp1_done, стоп в БУ' ($c.Count -eq 1 -and [int]$c[0].lots -eq 1 -and [bool]$c[0].tp1_done -and [math]::Abs([double]$c[0].stop_px_pts - $ngPx) -lt 1e-6) $(if ($c.Count) { "lots=$($c[0].lots) tp1_done=$($c[0].tp1_done) stop=$($c[0].stop_px_pts)" })
  # прибрать: снять карточку из состояния и позицию с песочного счёта
  $s.sleeves.setA.positions = ToArr (@($s.sleeves.setA.positions) | Where-Object { $_.id -ne $card.id })
  Set-St $s
  Flatten-Sandbox
}
function Drill-Be {
  $s = Get-St
  $card = New-DrillCard $s 'setA' 'NG' $ngFront.secid $ngUid 'long' 1 $ngPx ([math]::Round($ngPx*0.9,4)) $ngRubPt ([math]::Round($ngPx*0.95,4))
  $s.watermarks.last_hour_ts = (D2Ms "$today 09:00")
  Set-St $s
  [void](TickAt '14:16')
  $s = Get-St
  $c = @($s.sleeves.setA.positions | Where-Object { $_.id -eq $card.id })
  Note 'BE lots==1: перенос стопа в безубыток без заявок' ($c.Count -eq 1 -and [bool]$c[0].be_moved -and [math]::Abs([double]$c[0].stop_px_pts - $ngPx) -lt 1e-6) $(if ($c.Count) { "be=$($c[0].be_moved) stop=$($c[0].stop_px_pts)" })
  $s.sleeves.setA.positions = ToArr (@($s.sleeves.setA.positions) | Where-Object { $_.id -ne $card.id })
  Set-St $s
}
function Drill-Roll {
  $s = Get-St
  $card = New-DrillCard $s 'core' 'NG' $ngFront.secid $ngUid 'long' 1 $ngPx ([math]::Round($ngPx*0.9,4)) $ngRubPt
  $card | Add-Member -NotePropertyName roll_signal_to -NotePropertyValue $ngNext.secid -Force
  Set-St $s
  Post-TiMarketOrder $acc $ngUid 'buy' 1 ("SEED-" + [guid]::NewGuid().ToString('N').Substring(0,10)) | Out-Null
  [void](TickAt '15:00'); [void](TickAt '15:01')
  $s = Get-St
  $c = @($s.sleeves.core.positions | Where-Object { $_.asset -eq 'NG' })
  Note 'roll: реальное закрытие фронта + открытие next' ($c.Count -eq 1 -and [string]$c[0].secid -eq $ngNext.secid -and [int]$c[0].rolls -eq 1) $(if ($c.Count) { "secid=$($c[0].secid) rolls=$($c[0].rolls)" })
  $s.sleeves.core.positions = ToArr (@($s.sleeves.core.positions) | Where-Object { $_.asset -ne 'NG' })
  Set-St $s
  Flatten-Sandbox
}
function Drill-Mom {
  $s = Get-St
  $s.sleeves.mom | Add-Member -NotePropertyName reb_target -NotePropertyValue ([pscustomobject]@{
    day = $yday; gate = $true; target = @('SBER'); done = $false }) -Force
  Set-St $s
  [void](TickAt '10:12'); [void](TickAt '10:13')
  $s = Get-St
  $h = @($s.sleeves.mom.holdings | Where-Object { $_.sym -eq 'SBER' })
  Note 'mom: реальная покупка SBER (equal-split бюджета)' ($h.Count -eq 1 -and [int]$h[0].lots -ge 1) $(if ($h.Count) { "lots=$($h[0].lots) @$($h[0].avg_px)" })
  # ребаланс-2: гейт закрыт -> распродажа bot-лотов
  $s = Get-St
  $s.sleeves.mom | Add-Member -NotePropertyName reb_target -NotePropertyValue ([pscustomobject]@{
    day = $today; gate = $false; target = @(); done = $false }) -Force
  Set-St $s
  [void](TickAt '10:14'); [void](TickAt '10:15')
  $s = Get-St
  Note 'mom: гейт-off -> реальная распродажа в кэш' (@($s.sleeves.mom.holdings).Count -eq 0) "cash=$([math]::Round([double]$s.sleeves.mom.cash_rub,0))"
}
function Drill-Reject {
  # брокерский reject: гигантская заявка (не хватит песочных денег) НАПРЯМУЮ - фиксируем формат ошибки
  $r = $null; $err = ''
  try { $r = Post-TiMarketOrder $acc $ngUid 'buy' 1000000 ("REJ-" + [guid]::NewGuid().ToString('N').Substring(0,10)) }
  catch { $err = $_.Exception.Message }
  $status = if ($null -ne $r -and $r.PSObject.Properties['executionReportStatus']) { [string]$r.executionReportStatus } else { '' }
  $rejected = ($err -match 'TINVEST_HTTP' ) -or ($status -like '*REJECTED*')
  Note 'reject: брокер отклоняет гигантскую заявку' $rejected "status='$status' err='$($err.Substring(0, [math]::Min(120, $err.Length)))'"
}
function Drill-Idem {
  # вопрос №1 реестра: повтор PostOrder с ТЕМ ЖЕ orderId не создаёт дубль
  $key = "IDEM-" + [guid]::NewGuid().ToString('N').Substring(0,10)
  $r1 = Post-TiMarketOrder $acc $ngUid 'buy' 1 $key
  Start-Sleep -Seconds 1
  $r2 = $null; $err2 = ''
  try { $r2 = Post-TiMarketOrder $acc $ngUid 'buy' 1 $key } catch { $err2 = $_.Exception.Message }
  $id1 = [string]$r1.orderId
  $id2 = if ($null -ne $r2) { [string]$r2.orderId } else { '' }
  $pf = Get-TiPortfolio $acc
  $ngLots = 0.0
  foreach ($p in @($pf.positions)) {
    $uid = if ($p.PSObject.Properties['instrumentUid']) { [string]$p.instrumentUid } else { [string]$p.instrument_uid }
    if ($uid -eq $ngUid) { $ngLots = [double](Q2D $p.quantityLots) }
  }
  # идемпотентность = позиция 1 лот (не 2), независимо от формы второго ответа
  Note 'idempotency: повтор order_id НЕ создал дубль' ($ngLots -eq 1) "id1=$id1 id2=$id2 err2='$($err2.Substring(0,[math]::Min(80,$err2.Length)))' lots=$ngLots"
  Flatten-Sandbox
}
function Drill-Kill {
  $s = Get-St
  [void](New-DrillIntent $s 'entry' 'core' 'CNY' '' '' 'buy' 0 ([pscustomobject]@{
    stop_dist = 0.2; atr = 0.1; risk_pct = 0.01; ref_px = $lastPx[$inst[$cnyFront.secid].uid]; note = 'drill' }))
  Set-St $s
  New-Item -ItemType Directory -Force (Join-Path $Root 'data') | Out-Null
  Set-Content (Join-Path $Root 'data\HALT_RF_ENTRIES') 'drill' -Encoding ASCII
  [void](TickAt '10:07')
  $s = Get-St
  Note 'kill: HALT_RF_ENTRIES блокирует вход' (@($s.sleeves.core.positions | Where-Object { $_.asset -eq 'CNY' }).Count -eq 0)
  Remove-Item (Join-Path $Root 'data\HALT_RF_ENTRIES') -Force
  # HALT_RF_CLOSE: реальная позиция + карточка -> флэттен
  $s = Get-St
  $s.entries_halt.active = $false; $s.entries_halt.reason = ''
  $s.pending_intents = @()
  $card = New-DrillCard $s 'core' 'NG' $ngFront.secid $ngUid 'long' 1 $ngPx ([math]::Round($ngPx*0.9,4)) $ngRubPt
  Set-St $s
  Post-TiMarketOrder $acc $ngUid 'buy' 1 ("SEED-" + [guid]::NewGuid().ToString('N').Substring(0,10)) | Out-Null
  Set-Content (Join-Path $Root 'data\HALT_RF_CLOSE') 'drill' -Encoding ASCII
  [void](TickAt '16:00')
  $s = Get-St
  Note 'kill: HALT_RF_CLOSE закрыл всё реальным market' (@($s.sleeves.core.positions).Count -eq 0)
  Remove-Item (Join-Path $Root 'data\HALT_RF_CLOSE') -Force
  Set-Content (Join-Path $Root 'data\HALT_RF_LIVE') 'drill' -Encoding ASCII
  $out = TickAt '16:05'
  Note 'kill: HALT_RF_LIVE - тик не работает' ($out -notmatch 'tick ok')
  Remove-Item (Join-Path $Root 'data\HALT_RF_LIVE') -Force
  Flatten-Sandbox
}
function Drill-Crash {
  # краш-рекавери: «заявка ушла, ответ потерян» - ставим РЕАЛЬНУЮ заявку с ключом интента вручную,
  # интент оставляем POSTED без broker_id -> тик должен сделать LOST -> adopt по реальной операции
  $s = Get-St
  $s.entries_halt.active = $false; $s.entries_halt.reason = ''
  $it = New-DrillIntent $s 'entry' 'core' 'NG' $ngFront.secid $ngUid 'buy' 1 ([pscustomobject]@{
    stop_dist = $stopDist; atr = $stopDist/2; risk_pct = 0.01; ref_px = $ngPx; risk_rub = 7000; note = 'drill-crash' })
  $it.state = 'POSTED'; $it.attempts = 1; $it.t_post = (D2Ms "$today 10:05")
  Set-St $s
  Post-TiMarketOrder $acc $ngUid 'buy' 1 ([string]$it.order_key) | Out-Null   # «потерянная» заявка реально ушла
  Start-Sleep -Seconds 2
  [void](TickAt '10:08'); [void](TickAt '10:09')
  $s = Get-St
  $pos = @($s.sleeves.core.positions | Where-Object { $_.asset -eq 'NG' })
  Note 'crash: adopt по реальной операции (без дубля заявки)' ($pos.Count -eq 1 -and [int]$pos[0].lots -eq 1) $(if ($pos.Count) { "entry=$($pos[0].entry_px_pts)" })
  $s.sleeves.core.positions = ToArr (@($s.sleeves.core.positions) | Where-Object { $_.asset -ne 'NG' })
  Set-St $s
  Flatten-Sandbox
}
function Drill-D2 {
  # чужая позиция на счёте (заявка мимо движка) -> D2 -> реальное аварийное закрытие
  Post-TiMarketOrder $acc $inst[$cnyFront.secid].uid 'buy' 1 ("ALIEN-" + [guid]::NewGuid().ToString('N').Substring(0,10)) | Out-Null
  Start-Sleep -Seconds 2
  [void](TickAt '17:00'); [void](TickAt '17:01')
  $s = Get-St
  $pf = Get-TiPortfolio $acc
  $cnyLots = 0.0
  foreach ($p in @($pf.positions)) {
    $uid = if ($p.PSObject.Properties['instrumentUid']) { [string]$p.instrumentUid } else { [string]$p.instrument_uid }
    if ($uid -eq $inst[$cnyFront.secid].uid) { $cnyLots = [double](Q2D $p.quantityLots) }
  }
  Note 'D2: чужая позиция найдена и реально закрыта' ([int]$s.drift.D2 -ge 1 -and $cnyLots -eq 0) "D2=$($s.drift.D2) cnyLots=$cnyLots"
}

# ================= запуск =================
if ($Fresh -or -not (Test-Path (Join-Path $lrf 'portfolio.json'))) { Reset-DrillRoot }
$all = @(
  @{ n = 'entry';  f = ${function:Drill-Entry} },  @{ n = 'stop'; f = ${function:Drill-Stop} },
  @{ n = 'tp1';    f = ${function:Drill-Tp1} },    @{ n = 'be';   f = ${function:Drill-Be} },
  @{ n = 'roll';   f = ${function:Drill-Roll} },   @{ n = 'mom';  f = ${function:Drill-Mom} },
  @{ n = 'reject'; f = ${function:Drill-Reject} }, @{ n = 'idem'; f = ${function:Drill-Idem} },
  @{ n = 'kill';   f = ${function:Drill-Kill} },   @{ n = 'crash';f = ${function:Drill-Crash} },
  @{ n = 'd2';     f = ${function:Drill-D2} }
)
foreach ($d in $all) {
  if ($Step -and $d.n -ne $Step) { continue }
  Write-Host "`n=== drill: $($d.n) ===" -ForegroundColor Cyan
  try { & $d.f } catch { Note "$($d.n): EXCEPTION" $false $_.Exception.Message }
}

# итог + отчёт
$fails = @($script:res | Where-Object { -not $_.ok })
Write-Host ("`nитого: PASS={0} FAIL={1}" -f (@($script:res | Where-Object { $_.ok }).Count), $fails.Count) -ForegroundColor $(if ($fails.Count) { 'Red' } else { 'Green' })
$md = @("# Sandbox drill $((Get-Date).ToString('yyyy-MM-dd HH:mm')) (счёт $acc)", '')
foreach ($x in $script:res) { $md += ("- [{0}] {1} {2}" -f $(if ($x.ok) { 'x' } else { ' ' }), $x.step, $x.detail) }
[IO.File]::WriteAllText((Join-Path $Root 'drill_report.md'), ($md -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "отчёт: $(Join-Path $Root 'drill_report.md')"
Flatten-Sandbox
if (-not $KeepAccount -and -not $Step) {
  # счёт оставляем к следующему прогону; закрыть вручную: Close-TiSandboxAccount
}
if ($fails.Count) { exit 1 } else { exit 0 }
