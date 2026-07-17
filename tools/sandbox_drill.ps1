# sandbox_drill.ps1 - функциональная матрица LIVE-контура против ЖИВОЙ песочницы T-Invest.
# Работает в РЕАЛЬНОМ времени (симуляция времени ломает GetOperations и adopt-окна - боевой урок
# 2026-07-17), поэтому запускать в торговые часы будней (~06:10-23:30 MSK). Окна движка расширены
# через config.json дрилл-корня. КАЖДЫЙ шаг изолирован: свежий state + flatten песочницы + чистка
# kill-файлов (иначе позиции шагов протекают в reconcile соседей). Требует .secrets (sandbox-токен).
# Запуск: powershell -File tools\sandbox_drill.ps1 [-Step entry|stop|tp1|be|roll|mom|reject|idem|kill|crash|d2]
param(
  [string]$Root = '',
  [string]$Step = '',
  [switch]$KeepAccount
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

$mskNow = (Get-Date).ToUniversalTime().AddHours(3)
$today = $mskNow.ToString('yyyy-MM-dd')
$yday = $mskNow.AddDays(-1).ToString('yyyy-MM-dd')
$hhmm = $mskNow.ToString('HH:mm')
if ($mskNow.DayOfWeek -in @([DayOfWeek]::Saturday, [DayOfWeek]::Sunday) -or $hhmm -lt '06:10' -or $hhmm -gt '23:30') {
  throw "дрилл гоняется в торговые часы будней (сейчас $hhmm MSK, $($mskNow.DayOfWeek))"
}

$script:res = New-Object System.Collections.Generic.List[object]
function Note([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $script:res.Add([pscustomobject]@{ step = $Name; ok = $Ok; detail = $Detail })
  $mark = if ($Ok) { 'PASS' } else { 'FAIL' }
  Write-Host ("[{0}] {1} {2}" -f $mark, $Name, $Detail) -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
}

# ================= песочный счёт =================
Initialize-TInvest $lrf 'sandbox'
Resolve-TiSandboxBase
$existing = @(Get-TiSandboxAccounts)
$acc = if ($existing.Count) { [string]$existing[0].id } else { $null }
if (-not $acc) {
  $acc = Open-TiSandboxAccount 'rf-live-drill'
  Invoke-TiSandboxPayIn $acc ([decimal]700000) | Out-Null
  Write-Host "песочный счёт создан: $acc (+700 000 ₽)"
} else { Write-Host "песочный счёт: $acc" }
$env:TINVEST_ACCOUNT_ID = $acc
$script:TI.accountId = $acc

# ================= инструменты (реальные фронты из ISS + uid из API) =================
$fronts = Get-FutFronts @('NG','CNY')
$ngFront = $fronts['NG'][0]; $ngNext = $fronts['NG'][1]; $cnyFront = $fronts['CNY'][0]
$inst = @{}
foreach ($t in @(@{k=$ngFront.secid;kind='fut'}, @{k=$ngNext.secid;kind='fut'}, @{k=$cnyFront.secid;kind='fut'}, @{k='SBER';kind='share'})) {
  $i = Get-TiInstrument ([string]$t.k) ([string]$t.kind)
  $rec = @{ uid = [string]$i.uid; lot = [int]$i.lot; kind = [string]$t.kind }
  if ($t.kind -eq 'fut') {
    $m = Get-TiFuturesMargin ([string]$i.uid)
    $incQ = Q2D (Get-TiField $i 'min_price_increment')
    $rec.rubPt = if ($incQ -gt 0) { [double]((Q2D (Get-TiField $m 'min_price_increment_amount')) / $incQ) } else { 0.0 }
    $rec.go = [double](M2D (Get-TiField $m 'initial_margin_on_buy')).value
  }
  $inst[[string]$t.k] = $rec
}
$ngUid = $inst[$ngFront.secid].uid
$lastPx = @{}
foreach ($lp in (Get-TiLastPrices @($ngUid, $inst[$cnyFront.secid].uid, $inst['SBER'].uid))) {
  $u = [string](Get-TiField $lp 'instrument_uid')
  $lastPx[$u] = [double](Q2D $lp.price)
}
$ngPx = $lastPx[$ngUid]
$ngRubPt = [double]$inst[$ngFront.secid].rubPt
$stopDist = [math]::Round($ngPx * 0.02, 4)
# минимум дня по часовикам ISS: стоп-эмуляция гоняет ВСЮ историю дня - уровни BE/стопов для
# tp1/be-шагов ставим НИЖЕ дневного лоу, чтобы история дня их не задевала
$dayLow = $ngPx
try {
  $hb = @(Get-IssCandles 'fut' $ngFront.secid 60 $today)
  if ($hb.Count) { $dayLow = ($hb | ForEach-Object { [double]$_.l } | Measure-Object -Minimum).Minimum }
} catch {}
Write-Host ("фронты: NG={0} (next {1}), CNY={2} | last NG={3} SBER={4}" -f $ngFront.secid, $ngNext.secid, $cnyFront.secid, $ngPx, $lastPx[$inst['SBER'].uid])

# ================= состояние / изоляция шагов =================
function Get-St { Read-JsonFile (Join-Path $lrf 'portfolio.json') }
function Set-St($s) { Write-JsonAtomic (Join-Path $lrf 'portfolio.json') $s 14 }
function Get-Dtrades { ,@(@((Read-JsonFile (Join-Path $lrf 'trades.json'))) | Where-Object { $null -ne $_ }) }
function Run-DrillTick {
  # дочерний движок конфигурируется ТОЛЬКО через env - обязателен sandbox-режим (иначе dryrun/prod!)
  $env:TINVEST_MODE = 'sandbox'; $env:TINVEST_MOCK_DIR = $null; $env:TINVEST_ACCOUNT_ID = $acc
  & powershell -NoProfile -ExecutionPolicy Bypass -Command ". '$ENGINE' -Root '$Root'" 2>&1 | Out-String
}

function Flatten-Sandbox {
  # прибрать инструментальные позиции песочницы (валюта тоже приходит «позицией» - скип)
  try {
    $pf = Get-TiPortfolio $acc
    foreach ($p in @($pf.positions)) {
      if ($null -eq $p) { continue }
      $itype = [string](Get-TiField $p 'instrument_type')
      if ($itype -notin @('futures','share')) { continue }
      $uid = [string](Get-TiField $p 'instrument_uid')
      $lots = [double](Q2D (Get-TiField $p 'quantity_lots'))
      if ([math]::Abs($lots) -lt 1) { continue }
      $dir = if ($lots -gt 0) { 'sell' } else { 'buy' }
      try { Post-TiMarketOrder $acc $uid $dir ([int][math]::Abs($lots)) ([guid]::NewGuid().ToString()) | Out-Null }
      catch { Write-Warning "flatten $uid : $($_.Exception.Message)" }
      Start-Sleep -Seconds 1
    }
  } catch { Write-Warning "flatten: $($_.Exception.Message)" }
}

function New-DrillState {
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
    watermarks = [pscustomobject]@{ last_daily_day = (Get-RfCompletedDay ([long]((UtcStrToMs "$today 12:00"))))
      last_hour_ts = (UtcStrToMs "$today 06:00")
      ops_since = ((Get-Date).ToUniversalTime().AddHours(-2).ToString('yyyy-MM-ddTHH:mm:ssZ'))
      last_eq_snap = [long]0; last_report_day = $today; orders_day = $today; orders_day_n = 0 }
    fronts = [pscustomobject]@{
      NG  = [pscustomobject]@{ secid = $ngFront.secid; lasttrade = $ngFront.lasttrade; next = $ngNext.secid; next_lasttrade = $ngNext.lasttrade }
      CNY = [pscustomobject]@{ secid = $cnyFront.secid; lasttrade = $cnyFront.lasttrade; next = $null; next_lasttrade = $null } }
    active = [pscustomobject]@{ NG = $ngFront.secid; CNY = $cnyFront.secid }
    rearm = [pscustomobject]@{}
    entries_halt = [pscustomobject]@{ active = $false; reason = ''; since = '' }
    go = [pscustomobject]@{ used_rub = 0.0; budget_rub = 0.0; peak_day_rub = 0.0 }
    drift = [pscustomobject]@{ D2 = 0; D4 = 0; D5 = 0; D6 = 0; stocks_deficit = 0; last = '' }
    pending_intents = @(); next_intent_id = 1
    run_key = ([guid]::NewGuid().ToString('N'))   # соль ключей: каждый шаг дрилла = свой набор order_id
    stats = [pscustomobject]@{ trades = 0; wins = 0; losses = 0; fees_rub = 0.0; realized_rub = 0.0
      orders_posted = 0; fills = 0; skipped_qty0 = 0; signal_mismatch = 0 }
    consec_fail = 0
  }
}

function Reset-DrillStep {
  # изоляция шага: чистый state + kill-файлы прочь + песочница флэт
  if (-not (Test-Path (Join-Path $lrf 'series'))) { New-Item -ItemType Directory -Force (Join-Path $lrf 'series') | Out-Null }
  foreach ($a in @('NG','CNY','SBER','GAZP','IMOEX')) {
    $src = Join-Path $Repo "data\rf\series\$a.json"
    $dst = Join-Path $lrf "series\$a.json"
    if ((Test-Path $src) -and -not (Test-Path $dst)) { Copy-Item $src $dst -Force }
  }
  # окна расширены: дрилл в реальном времени в любой торговый час; отчёт задвинут в конец дня
  Write-JsonAtomic (Join-Path $lrf 'config.json') ([pscustomobject]@{
    emulate_stops = $true; trade_weekends = $false
    entry_from = '06:01'; entry_till = '23:40'; roll_from = '06:05'; roll_till = '23:40'
    mom_from = '06:10'; report_at = '23:46' }) 3
  foreach ($k in 'HALT_RF_ENTRIES','HALT_RF_CLOSE','HALT_RF_LIVE') {
    $p = Join-Path $Root "data\$k"; if (Test-Path $p) { Remove-Item $p -Force }
  }
  Remove-Item (Join-Path $lrf 'trades.json') -Force -ErrorAction SilentlyContinue
  Set-St (New-DrillState)
  Flatten-Sandbox
  Start-Sleep -Seconds 2
}

function New-DrillIntent($s, [string]$Kind, [string]$Sleeve, [string]$Asset, [string]$Ticker, [string]$Uid, [string]$Side, [int]$Lots, $Ctx) {
  $id = 'i{0:d5}' -f [int]$s.next_intent_id
  $s.next_intent_id = [int]$s.next_intent_id + 1
  $it = [pscustomobject]@{
    id = $id; kind = $Kind; sleeve = $Sleeve; asset = $Asset; ticker = $Ticker; uid = $Uid
    side = $Side; lots = $Lots; filled_lots = 0; avg_fill_px = $null
    order_key = (New-TiOrderKey "$($s.run_key)|$id" ($Kind -replace '_','')); broker_order_id = ''
    state = 'INTENT'; attempts = 0
    t_signal = (UtcStrToMs "$yday 23:50"); t_post = [long]0; t_ack = [long]0; t_fill = [long]0
    created_day = $yday; state_ts = (UtcStrToMs "$today 00:25"); last_error = ''
    ctx = $Ctx
  }
  $s.pending_intents = ToArr (@($s.pending_intents) + $it)
  return $it
}
function New-DrillCard($s, [string]$Sleeve, [int]$Lots, [double]$Stop, $Tp1 = $null) {
  $card = [pscustomobject]@{
    id = "Ldrill$($s.next_intent_id)"; sleeve = $Sleeve; asset = 'NG'; secid = $ngFront.secid; uid = $ngUid; figi = 'F'
    side = 'long'; lots = $Lots; lots_initial = $Lots
    entry_px_pts = $ngPx; entry_day = $yday; entry_ts = (UtcStrToMs "$yday 10:01")
    stop_px_pts = $Stop; stop_order_id = ''; stop_lots = $Lots
    tp1_px_pts = $Tp1; tp1_order_id = ''; tp1_done = $false; be_moved = $false
    mfe_pts = $ngPx; atr_entry = [math]::Round($stopDist/2, 5)
    risk_rub = 7000.0; rub_per_pt = $ngRubPt; go_per_lot = [double]$inst[$ngFront.secid].go
    rolls = 0; fees_rub = 0.0; realized_rub = 0.0
    d6_fails = 0; quarantine = $false; stop_deferred = $null; last_stop_update = ''
    lat_sp = 0; lat_pf = 0
  }
  $s.next_intent_id = [int]$s.next_intent_id + 1
  $s.sleeves.$Sleeve.positions = ToArr (@($s.sleeves.$Sleeve.positions) + $card)
  return $card
}
function Seed-RealPosition([string]$Uid, [int]$Lots) {
  Post-TiMarketOrder $acc $Uid 'buy' $Lots ([guid]::NewGuid().ToString()) | Out-Null
  Start-Sleep -Seconds 2
}
function Get-RealLots([string]$Uid) {
  $pf = Get-TiPortfolio $acc
  foreach ($p in @($pf.positions)) {
    if ($null -eq $p) { continue }
    if ([string](Get-TiField $p 'instrument_uid') -eq $Uid) { return [double](Q2D (Get-TiField $p 'quantity_lots')) }
  }
  return 0.0
}

# ================= ШАГИ (каждый самодостаточен) =================
function Drill-Entry {
  Reset-DrillStep
  $s = Get-St
  [void](New-DrillIntent $s 'entry' 'core' 'NG' '' '' 'buy' 0 ([pscustomobject]@{
    stop_dist = $stopDist; atr = $stopDist/2; risk_pct = 0.01; ref_px = $ngPx; note = 'drill' }))
  Set-St $s
  [void](Run-DrillTick); Start-Sleep 2; [void](Run-DrillTick)
  $s = Get-St
  $pos = @($s.sleeves.core.positions)
  Note 'entry: реальный market-филл -> карточка' ($pos.Count -eq 1) $(if ($pos.Count) { "lots=$($pos[0].lots) entry=$($pos[0].entry_px_pts)" } else { 'нет карточки' })
  if ($pos.Count) {
    Note 'entry: цена филла разумна (±5% от last)' ([math]::Abs([double]$pos[0].entry_px_pts - $ngPx) / $ngPx -lt 0.05) "fill=$($pos[0].entry_px_pts) vs last=$ngPx"
    Note 'entry: реальная позиция на счёте = карточке' ((Get-RealLots $ngUid) -eq [double]$pos[0].lots)
  }
  Note 'entry: интентов не осталось' (@($s.pending_intents).Count -eq 0)
}
function Drill-Stop {
  Reset-DrillStep
  $s = Get-St
  [void](New-DrillCard $s 'core' 1 ([math]::Round($ngPx * 1.5, 4)))   # long, стоп ВЫШЕ рынка -> форс-касание часовиком
  Set-St $s
  Seed-RealPosition $ngUid 1
  [void](Run-DrillTick); Start-Sleep 2; [void](Run-DrillTick)
  $s = Get-St
  $tr = Get-Dtrades
  Note 'stop-emu: позиция закрыта реальным market' (@($s.sleeves.core.positions).Count -eq 0 -and $tr.Count -ge 1) $(if ($tr.Count) { "exit=$($tr[-1].exitPx) reason=$($tr[-1].exitReason)" })
  Note 'stop-emu: счёт песочницы флэт' ((Get-RealLots $ngUid) -eq 0)
}
function Drill-Tp1 {
  Reset-DrillStep
  $s = Get-St
  # entry НИЖЕ дневного лоу: BE-стоп после TP1 (=entry) не заденется историей дня
  $ent = [math]::Round($dayLow * 0.99, 4)
  $card = New-DrillCard $s 'setA' 2 ([math]::Round($dayLow*0.9,4)) ([math]::Round($dayLow*0.995,4))
  $card.entry_px_pts = $ent; $card.mfe_pts = $ent
  Set-St $s
  Seed-RealPosition $ngUid 2
  [void](Run-DrillTick); Start-Sleep 2; [void](Run-DrillTick)
  $s = Get-St
  $c = @($s.sleeves.setA.positions | Where-Object { $_.id -eq $card.id })
  Note 'tp1-emu: половина закрыта, tp1_done, стоп в БУ' ($c.Count -eq 1 -and [int]$c[0].lots -eq 1 -and [bool]$c[0].tp1_done -and [math]::Abs([double]$c[0].stop_px_pts - $ent) -lt 1e-6) $(if ($c.Count) { "lots=$($c[0].lots) tp1_done=$($c[0].tp1_done) stop=$($c[0].stop_px_pts)" })
  Note 'tp1-emu: на счёте остался 1 лот' ((Get-RealLots $ngUid) -eq 1)
}
function Drill-Be {
  Reset-DrillStep
  $s = Get-St
  $ent = [math]::Round($dayLow * 0.99, 4)
  $card = New-DrillCard $s 'setA' 1 ([math]::Round($dayLow*0.9,4)) ([math]::Round($dayLow*0.995,4))
  $card.entry_px_pts = $ent; $card.mfe_pts = $ent
  Set-St $s
  Seed-RealPosition $ngUid 1
  [void](Run-DrillTick)
  $s = Get-St
  $c = @($s.sleeves.setA.positions | Where-Object { $_.id -eq $card.id })
  Note 'BE lots==1: стоп в безубыток без заявок' ($c.Count -eq 1 -and [bool]$c[0].be_moved -and [math]::Abs([double]$c[0].stop_px_pts - $ent) -lt 1e-6) $(if ($c.Count) { "be=$($c[0].be_moved) stop=$($c[0].stop_px_pts)" })
}
function Drill-Roll {
  Reset-DrillStep
  $s = Get-St
  $card = New-DrillCard $s 'core' 1 ([math]::Round($ngPx*0.9,4))
  $card | Add-Member -NotePropertyName roll_signal_to -NotePropertyValue $ngNext.secid -Force
  Set-St $s
  Seed-RealPosition $ngUid 1
  [void](Run-DrillTick); Start-Sleep 2; [void](Run-DrillTick)
  $s = Get-St
  $c = @($s.sleeves.core.positions | Where-Object { $_.asset -eq 'NG' })
  Note 'roll: закрытие фронта + реальное открытие next' ($c.Count -eq 1 -and [string]$c[0].secid -eq $ngNext.secid -and [int]$c[0].rolls -eq 1) $(if ($c.Count) { "secid=$($c[0].secid) rolls=$($c[0].rolls)" })
  Note 'roll: на счёте next-контракт' ((Get-RealLots $inst[$ngNext.secid].uid) -ge 1)
}
function Drill-Mom {
  Reset-DrillStep
  $s = Get-St
  $s.sleeves.mom | Add-Member -NotePropertyName reb_target -NotePropertyValue ([pscustomobject]@{
    day = $yday; gate = $true; target = @('SBER'); done = $false }) -Force
  Set-St $s
  [void](Run-DrillTick); Start-Sleep 2; [void](Run-DrillTick)
  $s = Get-St
  $h = @($s.sleeves.mom.holdings | Where-Object { $_.sym -eq 'SBER' })
  Note 'mom: реальная покупка SBER' ($h.Count -eq 1 -and [int]$h[0].lots -ge 1) $(if ($h.Count) { "lots=$($h[0].lots) @$($h[0].avg_px)" })
  $s = Get-St
  $s.sleeves.mom | Add-Member -NotePropertyName reb_target -NotePropertyValue ([pscustomobject]@{
    day = $today; gate = $false; target = @(); done = $false }) -Force
  Set-St $s
  [void](Run-DrillTick); Start-Sleep 2; [void](Run-DrillTick)
  $s = Get-St
  Note 'mom: гейт-off -> реальная распродажа в кэш' (@($s.sleeves.mom.holdings).Count -eq 0) "cash=$([math]::Round([double]$s.sleeves.mom.cash_rub,0))"
}
function Drill-Reject {
  Reset-DrillStep
  $r = $null; $err = ''
  try { $r = Post-TiMarketOrder $acc $ngUid 'buy' 1000000 ([guid]::NewGuid().ToString()) }
  catch { $err = $_.Exception.Message }
  $status = if ($null -ne $r -and $r.PSObject.Properties['executionReportStatus']) { [string]$r.executionReportStatus } else { '' }
  Note 'reject: брокер отклоняет гигантскую заявку' (($err -match 'TINVEST_HTTP') -or ($status -like '*REJECTED*')) "err='$($err.Substring(0,[math]::Min(90,$err.Length)))'"
}
function Drill-Idem {
  Reset-DrillStep
  $key = [guid]::NewGuid().ToString()
  $null = Post-TiMarketOrder $acc $ngUid 'buy' 1 $key
  Start-Sleep -Seconds 2
  $err2 = ''
  try { $null = Post-TiMarketOrder $acc $ngUid 'buy' 1 $key } catch { $err2 = $_.Exception.Message }
  $lots = Get-RealLots $ngUid
  Note 'idempotency: повтор order_id НЕ создал дубль (вопрос №1 ЗАКРЫТ)' ($lots -eq 1) "lots=$lots dup='$($err2.Substring(0,[math]::Min(60,$err2.Length)))'"
}
function Drill-Kill {
  Reset-DrillStep
  $s = Get-St
  [void](New-DrillIntent $s 'entry' 'core' 'NG' '' '' 'buy' 0 ([pscustomobject]@{
    stop_dist = $stopDist; atr = $stopDist/2; risk_pct = 0.01; ref_px = $ngPx; note = 'drill' }))
  Set-St $s
  New-Item -ItemType Directory -Force (Join-Path $Root 'data') | Out-Null
  Set-Content (Join-Path $Root 'data\HALT_RF_ENTRIES') 'drill' -Encoding ASCII
  [void](Run-DrillTick)
  $s = Get-St
  Note 'kill: HALT_RF_ENTRIES блокирует вход' (@($s.sleeves.core.positions).Count -eq 0 -and (Get-RealLots $ngUid) -eq 0)
  # HALT_RF_CLOSE
  Reset-DrillStep
  $s = Get-St
  [void](New-DrillCard $s 'core' 1 ([math]::Round($ngPx*0.9,4)))
  Set-St $s
  Seed-RealPosition $ngUid 1
  Set-Content (Join-Path $Root 'data\HALT_RF_CLOSE') 'drill' -Encoding ASCII
  [void](Run-DrillTick)
  $s = Get-St
  Note 'kill: HALT_RF_CLOSE закрыл всё реальным market' (@($s.sleeves.core.positions).Count -eq 0 -and (Get-RealLots $ngUid) -eq 0)
  Remove-Item (Join-Path $Root 'data\HALT_RF_CLOSE') -Force
  Set-Content (Join-Path $Root 'data\HALT_RF_LIVE') 'drill' -Encoding ASCII
  $out = Run-DrillTick
  Note 'kill: HALT_RF_LIVE - тик не работает' ($out -notmatch 'tick ok')
  Remove-Item (Join-Path $Root 'data\HALT_RF_LIVE') -Force
}
function Drill-Crash {
  Reset-DrillStep
  $s = Get-St
  $it = New-DrillIntent $s 'entry' 'core' 'NG' $ngFront.secid $ngUid 'buy' 1 ([pscustomobject]@{
    stop_dist = [math]::Round($ngPx * 0.5, 4); atr = $stopDist/2; risk_pct = 0.01; ref_px = $ngPx; risk_rub = 7000; note = 'drill-crash' })
  # широкий стоп: карточка после adopt не должна закрыться стоп-эмуляцией по истории дня
  $it.state = 'POSTED'; $it.attempts = 1
  $it.t_post = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
  Set-St $s
  # «заявка ушла, ответ потерян»: реальная заявка тем же order_key вручную
  Post-TiMarketOrder $acc $ngUid 'buy' 1 ([string]$it.order_key) | Out-Null
  Start-Sleep -Seconds 3
  [void](Run-DrillTick); Start-Sleep 2; [void](Run-DrillTick)
  $s = Get-St
  $pos = @($s.sleeves.core.positions | Where-Object { $_.asset -eq 'NG' })
  Note 'crash: adopt по реальной операции, без дубля' ($pos.Count -eq 1 -and [int]$pos[0].lots -eq 1 -and (Get-RealLots $ngUid) -eq 1) $(if ($pos.Count) { "entry=$($pos[0].entry_px_pts)" })
}
function Drill-D2 {
  Reset-DrillStep
  $cnyUid = $inst[$cnyFront.secid].uid
  Post-TiMarketOrder $acc $cnyUid 'buy' 1 ([guid]::NewGuid().ToString()) | Out-Null
  Start-Sleep -Seconds 2
  [void](Run-DrillTick); Start-Sleep 2; [void](Run-DrillTick)
  $s = Get-St
  Note 'D2: чужая позиция найдена и реально закрыта' ([int]$s.drift.D2 -ge 1 -and (Get-RealLots $cnyUid) -eq 0) "D2=$($s.drift.D2)"
}

# ================= запуск =================
$all = @(
  @{ n='entry'; f=${function:Drill-Entry} }, @{ n='stop'; f=${function:Drill-Stop} },
  @{ n='tp1'; f=${function:Drill-Tp1} }, @{ n='be'; f=${function:Drill-Be} },
  @{ n='roll'; f=${function:Drill-Roll} }, @{ n='mom'; f=${function:Drill-Mom} },
  @{ n='reject'; f=${function:Drill-Reject} }, @{ n='idem'; f=${function:Drill-Idem} },
  @{ n='kill'; f=${function:Drill-Kill} }, @{ n='crash'; f=${function:Drill-Crash} },
  @{ n='d2'; f=${function:Drill-D2} }
)
foreach ($d in $all) {
  if ($Step -and $d.n -ne $Step) { continue }
  Write-Host "`n=== drill: $($d.n) ===" -ForegroundColor Cyan
  try { & $d.f } catch { Note "$($d.n): EXCEPTION" $false $_.Exception.Message }
  Start-Sleep -Seconds 2
}

$fails = @($script:res | Where-Object { -not $_.ok })
Write-Host ("`nитого: PASS={0} FAIL={1}" -f (@($script:res | Where-Object { $_.ok }).Count), $fails.Count) -ForegroundColor $(if ($fails.Count) { 'Red' } else { 'Green' })
$md = @("# Sandbox drill $((Get-Date).ToString('yyyy-MM-dd HH:mm')) (счёт $acc)", '')
foreach ($x in $script:res) { $md += ("- [{0}] {1} {2}" -f $(if ($x.ok) { 'x' } else { ' ' }), $x.step, $x.detail) }
[IO.File]::WriteAllText((Join-Path $Root 'drill_report.md'), ($md -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "отчёт: $(Join-Path $Root 'drill_report.md')"
Flatten-Sandbox
if ($fails.Count) { exit 1 } else { exit 0 }
