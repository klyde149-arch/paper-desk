# Builds report\vizdata.js for trades.html.
# PS 5.1 gotcha: arrays deserialized by ConvertFrom-Json re-serialize as {value,Count}
# unless re-enumerated into a fresh object[] - hence the @( | ForEach-Object { $_ }) wrappers.
param([switch]$SkipLive, [switch]$NoDeploy)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'
$dir = Split-Path $PSScriptRoot -Parent   # портируемо: локально и в GitHub Actions
. (Join-Path $PSScriptRoot 'lib_engine.ps1')  # Get-Klines (Bybit + фолбэки)

$syms = @('BTC-USDT','ETH-USDT','SOL-USDT','BNB-USDT','XRP-USDT','DOGE-USDT','ADA-USDT','AVAX-USDT','LINK-USDT',
          'DOT-USDT','LTC-USDT','BCH-USDT','UNI-USDT','ATOM-USDT','NEAR-USDT','OP-USDT','APT-USDT','ARB-USDT','SUI-USDT','AAVE-USDT')
$prices = [ordered]@{}
foreach ($s in $syms) {
  $bars = Get-Content (Join-Path $dir "data\$($s.Replace('-','_'))_4h.json") -Raw | ConvertFrom-Json
  $prices[$s] = [ordered]@{
    t = [object[]]@($bars | ForEach-Object { [long]$_.t })
    c = [object[]]@($bars | ForEach-Object { [double]$_.c })
  }
}

$tradesRaw = Get-Content (Join-Path $dir 'data\bt_trades.json') -Raw | ConvertFrom-Json
$trades = [object[]]@($tradesRaw | ForEach-Object { $_ })

$eqRaw = Get-Content (Join-Path $dir 'data\bt_equity.json') -Raw | ConvertFrom-Json
$equity = [object[]]@($eqRaw | ForEach-Object { ,[object[]]@([long]$_.ts, [double]$_.equity) })

# MOEX (optional, present after part 2)
$moex = $null
$moexDir = Join-Path $dir 'data\moex'
if (Test-Path (Join-Path $moexDir 'bt_trades_moex.json')) {
  $mp = [ordered]@{}
  Get-ChildItem $moexDir -Filter '*_1d.json' | ForEach-Object {
    $tk = $_.BaseName -replace '_1d$',''
    $bars = Get-Content $_.FullName -Raw | ConvertFrom-Json
    $mp[$tk] = [ordered]@{
      t = [object[]]@($bars | ForEach-Object { [long]$_.t })
      c = [object[]]@($bars | ForEach-Object { [double]$_.c })
    }
  }
  $mtRaw = Get-Content (Join-Path $moexDir 'bt_trades_moex.json') -Raw | ConvertFrom-Json
  $meRaw = Get-Content (Join-Path $moexDir 'bt_equity_moex.json') -Raw | ConvertFrom-Json
  $moex = [ordered]@{
    prices = $mp
    trades = [object[]]@($mtRaw | ForEach-Object { $_ })
    equity = [object[]]@($meRaw | ForEach-Object { ,[object[]]@([long]$_.ts, [double]$_.equity) })
  }
}

# MOEX FORTS futures (optional, present after the futures research of 2026-07)
$moexFut = $null
$futDir = Join-Path $dir 'data\moex_fut'
if (Test-Path (Join-Path $futDir 'bt_trades_fut.json')) {
  $ftRaw = Get-Content (Join-Path $futDir 'bt_trades_fut.json') -Raw | ConvertFrom-Json
  # only traded symbols + the index (extra downloaded assets would clutter the explorer)
  $futSyms = @(($ftRaw | ForEach-Object { $_.sym }) | Sort-Object -Unique) + @('IMOEX')
  $fp = [ordered]@{}
  Get-ChildItem $futDir -Filter '*_1d.json' | Where-Object { $futSyms -contains ($_.BaseName -replace '_1d$','') } | ForEach-Object {
    $tk = $_.BaseName -replace '_1d$',''
    $bars = Get-Content $_.FullName -Raw | ConvertFrom-Json
    $fp[$tk] = [ordered]@{
      t = [object[]]@($bars | ForEach-Object { [long]$_.t })
      c = [object[]]@($bars | ForEach-Object { [double]$_.c })
    }
  }
  $feRaw = Get-Content (Join-Path $futDir 'bt_equity_fut.json') -Raw | ConvertFrom-Json
  $fmRaw = Get-Content (Join-Path $futDir 'bt_monthly_fut.json') -Raw | ConvertFrom-Json
  $moexFut = [ordered]@{
    prices = $fp
    trades = [object[]]@($ftRaw | ForEach-Object { $_ })
    equity = [object[]]@($feRaw | ForEach-Object { ,[object[]]@([long]$_.ts, [double]$_.equity) })
    monthly = [object[]]@($fmRaw | ForEach-Object { $_ })
  }
  # portfolio combos + walk-forward table (built by tools\build_fut_combos.ps1)
  $combosPath = Join-Path $futDir 'combos.json'
  if (Test-Path $combosPath) {
    $cRaw = Get-Content $combosPath -Raw | ConvertFrom-Json
    $moexFut.combos = [object[]]@($cRaw.combos | ForEach-Object {
      $c = $_
      [ordered]@{ id=$c.id; label=$c.label; desc=$c.desc; mo=$c.mo; total=$c.total; ddMo=$c.ddMo
        posMonths=$c.posMonths; nMonths=$c.nMonths; best=$c.best; worst=$c.worst; years=$c.years
        series = [object[]]@($c.series | ForEach-Object { ,[object[]]@([string]$_.m, [double]$_.r, [double]$_.eq) }) }
    })
    $moexFut.wf = [object[]]@($cRaw.wf | ForEach-Object { $_ })
  }
}

# stock-market strategy (momentum sleeve) for the MOEX tab
$momStocks = $null
if (Test-Path (Join-Path $moexDir 'bt_equity_mom63_full.json')) {
  $mmE = Get-Content (Join-Path $moexDir 'bt_equity_mom63_full.json') -Raw | ConvertFrom-Json
  $mmM = Get-Content (Join-Path $moexDir 'bt_monthly_mom63_full.json') -Raw | ConvertFrom-Json
  $mmT = Get-Content (Join-Path $moexDir 'bt_trades_mom63_full.json') -Raw | ConvertFrom-Json
  $momStocks = [ordered]@{
    equity = [object[]]@($mmE | ForEach-Object { ,[object[]]@([long]$_.ts, [double]$_.equity) })
    monthly = [object[]]@($mmM | ForEach-Object { $_ })
    actions = [object[]]@($mmT | ForEach-Object { $_ })
  }
}

# live positions: 1h candles per open position symbol
$pf = Get-Content (Join-Path $dir 'portfolio.json') -Raw -Encoding UTF8 | ConvertFrom-Json  # UTF8 explicitly: file may lack BOM (russian thesis text)
$livePositions = [object[]]@()
if (-not $SkipLive) {
  $livePositions = [object[]]@($pf.open_positions | ForEach-Object {
    $p = $_
    $k1 = [object[]]@()
    try {
      # Bybit (движок торгует по Bybit) с фолбэком на bytick/BingX внутри Get-Klines
      $nowK = UtcNowMs
      $bars = Get-Klines $p.symbol '60' ($nowK - 170*3600000) $nowK $nowK
      $k1 = [object[]]@($bars | ForEach-Object { ,[object[]]@([long]$_.t, [double]$_.o, [double]$_.h, [double]$_.l, [double]$_.c) })
    } catch { Write-Warning "candles failed for $($p.symbol): $_" }
    $feesP = if ($p.PSObject.Properties['fees_usd']) { [math]::Round([double]$p.fees_usd, 2) } else { $null }
    $fundP = if ($p.PSObject.Properties['funding_usd']) { [math]::Round([double]$p.funding_usd, 2) } else { $null }
    $tp1d  = if ($p.PSObject.Properties['tp1_done']) { [bool]$p.tp1_done } else { $false }
    [ordered]@{
      id = $p.id; symbol = $p.symbol; side = $p.side; qty = $p.qty; entry = $p.entry_price
      stop = $p.stop; tp1 = $p.tp1; entryUtc = $p.entry_utc; riskUsd = $p.risk_usd
      notional = $p.notional_usd; plan = $p.runner_plan; candles1h = $k1
      fees = $feesP; funding = $fundP; tp1Done = $tp1d
      thesis = $p.thesis
    }
  })
}

# ---- live actual performance (from portfolio.json) + equity log ----
$liveStartEq = [double]$pf.meta.start_balance_usd
$liveEqNow   = [double]$pf.equity_usd
$liveStartDate = '2026-07-08'   # first position entry / sim start
$daysLive = [math]::Round(([datetime]$pf.last_check_utc - [datetime]$liveStartDate).TotalDays, 1)
# append to equity log, deduped by last_check_utc
$leLog = @()
$lePath = Join-Path $dir 'data\live_equity.json'
if (Test-Path $lePath) { $leLog = @((Get-Content $lePath -Raw | ConvertFrom-Json) | ForEach-Object { $_ }) }
$lastUtc = if ($leLog.Count) { $leLog[-1].utc } else { $null }
if ($lastUtc -ne $pf.last_check_utc) {
  $tsNow = [long]([DateTimeOffset]::new([datetime]::SpecifyKind([datetime]$pf.last_check_utc,'Utc'))).ToUnixTimeMilliseconds()
  $leLog += [pscustomobject]@{ utc=$pf.last_check_utc; ts=$tsNow; eq=$liveEqNow }
  $leLog | ConvertTo-Json -Depth 3 | Out-File $lePath -Encoding utf8
}
$liveActual = [ordered]@{
  startEq = $liveStartEq; equityNow = $liveEqNow
  retPct = [math]::Round(100*($liveEqNow/$liveStartEq - 1), 2)
  startDate = $liveStartDate; days = $daysLive
  closedTrades = [int]$pf.stats.closed_trades; wins = [int]$pf.stats.wins; losses = [int]$pf.stats.losses
  realizedPnl = [double]$pf.stats.realized_pnl_usd
  unrealized = [math]::Round($liveEqNow - [double]$pf.balance_usd, 2)
  openPositions = @($pf.open_positions).Count
  fees = [double]$pf.stats.total_fees_usd; funding = [double]$pf.stats.total_funding_usd
  curve = [object[]]@($leLog | ForEach-Object { ,[object[]]@([long]$_.ts, [double]$_.eq) })
}

# ---- РЕАЛ: живой счёт Bybit (data\live_real\*, пишет VPS-бот; все файлы опциональны) ----
$realLive = $null
$rlDir = Join-Path $dir 'data\live_real'
$rlPf  = Join-Path $rlDir 'portfolio.json'
if (Test-Path $rlPf) {
  $rp = Get-Content $rlPf -Raw -Encoding UTF8 | ConvertFrom-Json
  $rCurve = [object[]]@()
  if (Test-Path (Join-Path $rlDir 'live_equity.json')) {
    $rCurve = [object[]]@((Get-Content (Join-Path $rlDir 'live_equity.json') -Raw -Encoding UTF8 | ConvertFrom-Json) |
      ForEach-Object { ,[object[]]@([long]$_.ts, [double]$_.eq) })
  }
  $rClosed = [object[]]@()
  if (Test-Path (Join-Path $rlDir 'live_trades.json')) {
    $rClosed = [object[]]@((Get-Content (Join-Path $rlDir 'live_trades.json') -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { $_ })
  }
  $rOpen = [object[]]@()
  if (-not $SkipLive) {
    $rOpen = [object[]]@(@($rp.open_trades) | Where-Object { $null -ne $_ } | ForEach-Object {
      $p = $_
      $k1 = [object[]]@()
      try {
        $nowK = UtcNowMs
        $bars = Get-Klines $p.symbol '60' ($nowK - 170*3600000) $nowK $nowK
        $k1 = [object[]]@($bars | ForEach-Object { ,[object[]]@([long]$_.t, [double]$_.o, [double]$_.h, [double]$_.l, [double]$_.c) })
      } catch { Write-Warning "real candles failed for $($p.symbol): $_" }
      # поле-в-поле как $livePositions выше — трейдс-панель рендерит обе вкладки одним кодом
      [ordered]@{
        id = $p.id; symbol = $p.symbol; side = $p.side; qty = $p.qty; entry = $p.entry_price
        stop = $p.stop; tp1 = $p.tp1; entryUtc = $p.entry_utc; riskUsd = $p.risk_usd
        notional = $p.notional_usd; plan = $null; candles1h = $k1
        fees = [math]::Round([double]$p.fees_usd, 2); funding = [math]::Round([double]$p.funding_usd, 2)
        tp1Done = [bool]$p.tp1_done; status = [string]$p.status
        thesis = $p.thesis
      }
    })
  }
  # startEq = первая точка equity-лога (не депозит $100: лог начат при запуске live-контура;
  # если захочется отсчёт от депозита — заменить на константу здесь)
  $realLive = [ordered]@{
    equityNow = [double]$rp.equity_usd
    startEq   = $(if ($rCurve.Count) { [double]$rCurve[0][1] } else { [double]$rp.equity_usd })
    peak      = [double]$rp.peak_equity_usd
    dayStartEq = [double]$rp.day_start_equity_usd
    dayStartDate = [string]$rp.day_start_date_utc
    halted = [bool]$rp.trading_halted
    haltReason = [string]$rp.entries_halt_reason
    lastTickUtc = [string]$rp.auto.last_tick_utc
    pendingIntents = @($rp.pending_intents).Count
    openTrades = $rOpen
    closed = $rClosed
    curve = $rCurve
  }
}

# ---- ЧЕЛЛЕНДЖ: бумажный контур $1000/30 дней (challenge\portfolio.json; S4-пробой/свип) ----
# Форма = как $realLive (панель «Челлендж» рендерится тем же кодом, что «Реал»).
# Отличия: closed_trades лежат inline в snake_case -> маппим в camelCase контракт фронта;
# лога эквити нет -> кривую восстанавливаем из закрытых сделок (Σpnl сходится в equity_usd до цента).
$challenge = $null
$chPath = Join-Path $dir 'challenge\portfolio.json'
if (Test-Path $chPath) {
  $cp = Get-Content $chPath -Raw -Encoding UTF8 | ConvertFrom-Json

  # закрытые сделки: snake_case -> camelCase, как ждёт журнал buildLiveInto
  $chClosed = [object[]]@(@($cp.closed_trades) | Where-Object { $null -ne $_ } | ForEach-Object {
    [ordered]@{
      id = $_.id; sym = $_.symbol; side = $_.side
      entryDay = $_.entry_utc; entry = [double]$_.entry
      exitDay = $_.exit_utc; exitPx = [double]$_.exit
      exitReason = $_.reason
      fees = [math]::Round([double]$_.fees_usd, 2); funding = [math]::Round([double]$_.funding_usd, 2)
      rMultiple = $_.r_multiple; pnlUsd = [double]$_.pnl_usd
      legs = @()
    }
  })

  # открытая позиция (одиночная, max_positions=1; сейчас обычно null)
  $chOpen = [object[]]@()
  if (-not $SkipLive -and $null -ne $cp.open_position -and $cp.open_position.symbol) {
    $op = $cp.open_position
    $k1 = [object[]]@()
    try {
      $nowK = UtcNowMs
      $bars = Get-Klines $op.symbol '60' ($nowK - 170*3600000) $nowK $nowK
      $k1 = [object[]]@($bars | ForEach-Object { ,[object[]]@([long]$_.t, [double]$_.o, [double]$_.h, [double]$_.l, [double]$_.c) })
    } catch { Write-Warning "challenge candles failed for $($op.symbol): $_" }
    $chOpen = [object[]]@([ordered]@{
      id = $op.id; symbol = $op.symbol; side = $op.side; qty = [double]$op.qty
      entry = [double]$op.entry_price; stop = [double]$op.stop; tp1 = [double]$op.tp
      entryUtc = $op.entry_utc; riskUsd = [double]$op.risk_usd; notional = [double]$op.notional_usd
      plan = $null; candles1h = $k1
      fees = [math]::Round([double]$op.entry_fee_usd, 2); funding = [math]::Round([double]$op.funding_accrued_usd, 2)
      tp1Done = $false; status = 'open'; thesis = $op.thesis
    })
  }

  # кривая эквити: реконструкция из закрытых сделок (лога нет).
  # Каждая точка — object[] пара [ts,eq]; .Add() кладёт её как один элемент,
  # .ToArray() отдаёт результат без разворачивания пар пайплайном.
  $chCurve = New-Object System.Collections.Generic.List[object]
  $run = [double]$cp.meta.start_balance_usd
  $chCurve.Add([object[]]@((UtcStrToMs (([string]$cp.challenge.start_date_utc) + ' 00:00')), [math]::Round($run, 2)))
  foreach ($t in @($cp.closed_trades | Where-Object { $null -ne $_ } | Sort-Object { UtcStrToMs $_.exit_utc })) {
    $run += [double]$t.pnl_usd
    $chCurve.Add([object[]]@((UtcStrToMs $t.exit_utc), [math]::Round($run, 2)))
  }
  $chCurve.Add([object[]]@((UtcStrToMs ([string]$cp.last_check_utc)), [double]$cp.equity_usd))

  $challenge = [ordered]@{
    equityNow = [double]$cp.equity_usd; startEq = [double]$cp.meta.start_balance_usd
    peak = [double]$cp.peak_equity_usd; dayStartEq = [double]$cp.day_start_equity_usd
    dayStartDate = [string]$cp.day_start_date_utc
    dayNumber = [int]$cp.challenge.day_number; termDays = [int]$cp.meta.term_days
    failed = [bool]$cp.challenge.failed; completed = [bool]$cp.challenge.completed
    strategy = [string]$cp.meta.strategy; lastTickUtc = [string]$cp.last_check_utc
    trades = [int]$cp.stats.trades; wins = [int]$cp.stats.wins; losses = [int]$cp.stats.losses
    realizedPnl = [double]$cp.stats.realized_pnl_usd
    fees = [double]$cp.stats.total_fees_usd; funding = [double]$cp.stats.total_funding_usd
    openTrades = $chOpen; closed = $chClosed
    curve = $chCurve.ToArray()
  }
}

# ---- живой форвард-тест РФ: профили C2/C3b (data\rf\*, optional) ----
$rfLive = $null
$rfDir2 = Join-Path $dir 'data\rf'
if (Test-Path (Join-Path $rfDir2 'c2_portfolio.json')) {
  $rfProfiles = [ordered]@{}
  $futKlineCache = @{}   # secid -> candles1h [[t,o,h,l,c],...]; c2/c3b часто держат одни и те же контракты
  foreach ($prof in 'c2', 'c3b') {
    $pp = Get-Content (Join-Path $rfDir2 "$($prof)_portfolio.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $poss = @()
    foreach ($slName in 'core', 'setA') {
      foreach ($x in @($pp.sleeves.$slName.positions)) {
        if ($null -eq $x) { continue }
        # часовые свечи ISS по контракту позиции — тот же сырой масштаб, что и entry/stop/tp1
        # (RF-движок входит по Get-IssCandles 'fut' $secid 60), чтобы drawLiveChart нарисовал уровни как у крипты
        $fk = @()
        if ($x.secid) {
          if ($futKlineCache.ContainsKey([string]$x.secid)) { $fk = $futKlineCache[[string]$x.secid] }
          else {
            try {
              $fromDay = ([datetime]$x.entry_day).AddDays(-3).ToString('yyyy-MM-dd')  # окно включает бар входа
              $fbars = Get-IssCandles 'fut' ([string]$x.secid) 60 $fromDay
              $fk = [object[]]@($fbars | ForEach-Object { ,[object[]]@([long]$_.t, [double]$_.o, [double]$_.h, [double]$_.l, [double]$_.c) })
            } catch { Write-Warning "fut candles failed for $($x.secid): $_" }
            $futKlineCache[[string]$x.secid] = $fk
          }
        }
        $poss += [ordered]@{ sleeve = $slName; id = $x.id; asset = $x.asset; secid = $x.secid; side = $x.side
          qty = $x.qty; entry = $x.entry; stop = $x.stop; tp1 = $x.tp1; entryDay = $x.entry_day; risk = $x.risk_usd
          entryTs = $(if ($x.PSObject.Properties['entry_ts']) { [long]$x.entry_ts } else { $null })
          candles1h = $fk
          cur  = $(if ($x.PSObject.Properties['cur'])  { [double]$x.cur }  else { $null })
          upnl = $(if ($x.PSObject.Properties['upnl']) { [double]$x.upnl } else { $null }) }
      }
    }
    $hold = @()
    foreach ($h in @($pp.sleeves.mom.holdings)) { if ($null -ne $h) { $hold += [ordered]@{ sym = $h.sym; qty = $h.qty; entry = $h.entry; entryDay = $h.entry_day } } }
    $pend = @()
    foreach ($slName in 'core', 'setA') {
      foreach ($x in @($pp.sleeves.$slName.pending)) { if ($null -ne $x) { $pend += [ordered]@{ sleeve = $slName; kind = $x.kind; asset = $x.asset; side = $x.side; created = $x.created_day } } }
    }
    foreach ($x in @($pp.sleeves.mom.pending)) { if ($null -ne $x) { $pend += [ordered]@{ sleeve = 'mom'; kind = 'rebalance'; asset = (@($x.target) -join '+'); side = 'long'; created = $x.created_day } } }
    $coreEq = if ($pp.sleeves.core.PSObject.Properties['equity_mtm'] -and [double]$pp.sleeves.core.equity_mtm -gt 0) { [double]$pp.sleeves.core.equity_mtm } else { [double]$pp.sleeves.core.equity }
    $setAEq = if ($pp.sleeves.setA.PSObject.Properties['equity_mtm'] -and [double]$pp.sleeves.setA.equity_mtm -gt 0) { [double]$pp.sleeves.setA.equity_mtm } else { [double]$pp.sleeves.setA.equity }
    $rfProfiles[$prof] = [ordered]@{
      label = $pp.meta.profile; coreRisk = $pp.meta.core_risk; setaRisk = $pp.meta.seta_risk; momWeight = $pp.meta.mom_weight
      eq = [double]$pp.profile_eq; dayStartEq = [double]$pp.day_start_eq; dayStartDate = $pp.day_start_date
      peak = [double]$pp.peak_eq
      coreEq = $coreEq; setAEq = $setAEq; momEq = [double]$pp.sleeves.mom.equity; momCash = [double]$pp.sleeves.mom.cash
      positions = [object[]]@($poss); holdings = [object[]]@($hold); pending = [object[]]@($pend)
      stats = $pp.stats
    }
  }
  $rfTrades = @()
  $rtPath = Join-Path $rfDir2 'rf_trades.json'
  if (Test-Path $rtPath) { $rfTrades = [object[]]@((Get-Content $rtPath -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { $_ }) }
  $rfCurve = @()
  $rePath = Join-Path $rfDir2 'rf_equity.json'
  if (Test-Path $rePath) {
    $rfCurve = [object[]]@((Get-Content $rePath -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object {
      $mom = if ($_.PSObject.Properties['mom']) { [double]$_.mom } else { $null }
      $f2  = if ($_.PSObject.Properties['futC2']) { [double]$_.futC2 } else { $null }
      $f3  = if ($_.PSObject.Properties['futC3b']) { [double]$_.futC3b } else { $null }
      ,[object[]]@([long]$_.ts, [double]$_.c2, [double]$_.c3b, $mom, $f2, $f3)
    })
  }
  $rfShared = Get-Content (Join-Path $rfDir2 'shared.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $rfStartMs = $null
  try {
    $c2m = (Get-Content (Join-Path $rfDir2 'c2_portfolio.json') -Raw -Encoding UTF8 | ConvertFrom-Json).meta.created
    if ($c2m) { $rfStartMs = [long]([DateTimeOffset]([datetime]::SpecifyKind([datetime]::Parse([string]$c2m), 'Utc'))).ToUnixTimeMilliseconds() }
  } catch {}
  $rfLive = [ordered]@{
    profiles = $rfProfiles
    trades = $rfTrades
    curve = $rfCurve
    startTs = $rfStartMs
    fronts = $rfShared.fronts
    lastDailyDay = $rfShared.last_daily_day
    lastTickUtc = $rfShared.last_tick_utc
  }
}

# ---- РЕАЛ РФ: живой счёт Т-Инвестиций, контур C3b (data\live_rf\*, пишет VPS-бот; опционально) ----
$rfReal = $null
$lrDir = Join-Path $dir 'data\live_rf'
$lrPf = Join-Path $lrDir 'portfolio.json'
if (Test-Path $lrPf) {
  $lp = Get-Content $lrPf -Raw -Encoding UTF8 | ConvertFrom-Json
  $lrCurve = [object[]]@()
  $lrCapCurve = [object[]]@()   # кривая ТОЧНОГО капитала бота (колонка bot_capital, есть не во всех строках)
  if (Test-Path (Join-Path $lrDir 'equity.json')) {
    $eqRows = @((Get-Content (Join-Path $lrDir 'equity.json') -Raw -Encoding UTF8 | ConvertFrom-Json) | Where-Object { $null -ne $_ })
    $lrCurve = [object[]]@($eqRows | ForEach-Object { ,[object[]]@([long]$_.ts, [double]$_.total) })
    $lrCapCurve = [object[]]@($eqRows | Where-Object { $_.PSObject.Properties['bot_capital'] -and $null -ne $_.bot_capital } |
      ForEach-Object { ,[object[]]@([long]$_.ts, [double]$_.bot_capital) })
  }
  $lrClosed = [object[]]@()
  if (Test-Path (Join-Path $lrDir 'trades.json')) {
    $lrClosed = [object[]]@((Get-Content (Join-Path $lrDir 'trades.json') -Raw -Encoding UTF8 | ConvertFrom-Json) | Where-Object { $null -ne $_ })
  }
  $lrCandDir = Join-Path $lrDir 'candles'
  $lrPos = [object[]]@()
  foreach ($snName in 'core','setA') {
    $lrPos += [object[]]@(@($lp.sleeves.$snName.positions) | Where-Object { $null -ne $_ } | ForEach-Object {
      $asset = [string]$_.asset; $secid = [string]$_.secid
      $rpp = [double]$_.rub_per_pt
      $notional = [math]::Round([double]$_.lots * [double]$_.entry_px_pts * $rpp, 0)
      $pct = $(if ($null -ne $_.cur_px -and [double]$_.entry_px_pts -ne 0) { [math]::Round(([double]$_.cur_px / [double]$_.entry_px_pts - 1) * 100, 2) } else { $null })
      # часовые свечи: сперва испечённый T-Invest файл (VPS), иначе фолбэк на MOEX ISS
      $c1h = [object[]]@()
      $cf = Join-Path $lrCandDir ("{0}_1h.json" -f $asset)
      if (Test-Path $cf) { try { $c1h = [object[]]@((Get-Content $cf -Raw -Encoding UTF8 | ConvertFrom-Json)) } catch {} }
      elseif ($secid) {
        try {
          $fromDay = ([datetime]$_.entry_day).AddDays(-3).ToString('yyyy-MM-dd')
          $c1h = [object[]]@((Get-IssCandles 'fut' $secid 60 $fromDay) | ForEach-Object { ,[object[]]@([long]$_.t, [double]$_.o, [double]$_.h, [double]$_.l, [double]$_.c) })
        } catch { Write-Warning "rfReal candles $secid`: $_" }
      }
      [ordered]@{ id = $_.id; sleeve = $snName; asset = $_.asset; secid = $_.secid; side = $_.side
        lots = $_.lots; entry = $_.entry_px_pts; stop = $_.stop_px_pts; tp1 = $_.tp1_px_pts
        cur = $_.cur_px; upnl = $_.upnl_rub; riskRub = $_.risk_rub; entryDay = $_.entry_day; entryTs = $_.entry_ts
        rolls = $_.rolls; rubPerPt = $rpp; notional = $notional; pctChg = $pct; candles1h = $c1h } })
  }
  $lrHold = [object[]]@(@($lp.sleeves.mom.holdings) | Where-Object { $null -ne $_ } | ForEach-Object {
    [ordered]@{ sym = $_.sym; lots = $_.lots; lotSize = $_.lot_size; avg = $_.avg_px; last = $_.last_px } })
  $rfReal = [ordered]@{
    mode = [string]$lp.mode
    equityNow = [double]$lp.profile_eq
    startEq = [double]$lp.meta.base_rub
    peak = [double]$lp.peak_eq
    dayStartEq = [double]$lp.day_start_eq
    entriesHalt = [bool]$lp.entries_halt.active
    haltReason = [string]$lp.entries_halt.reason
    goUsed = [double]$lp.go.used_rub
    goBudget = [double]$lp.go.budget_rub
    accountLiquid = $(if ($lp.go.PSObject.Properties['account_liquid_rub']) { [double]$lp.go.account_liquid_rub } else { $null })
    capitalNow = $(if ($lp.go.PSObject.Properties['bot_capital_rub']) { [double]$lp.go.bot_capital_rub } else { [double]$lp.profile_eq })
    capitalBreakdown = $(if ($lp.PSObject.Properties['capital_breakdown']) { $lp.capital_breakdown } else { $null })
    drift = $lp.drift
    sleeves = [ordered]@{ core = [double]$lp.sleeves.core.equity_mtm; setA = [double]$lp.sleeves.setA.equity_mtm; mom = [double]$lp.sleeves.mom.equity_mtm }
    positions = $lrPos
    holdings = $lrHold
    closed = $lrClosed
    curve = $lrCurve
    capitalCurve = $lrCapCurve
    lastDailyDay = [string]$lp.watermarks.last_daily_day
    stats = $lp.stats
  }
}

# ---- live v2 signal scan (data\signals.json, optional) ----
$signals = $null
$sigPath = Join-Path $dir 'data\signals.json'
if (Test-Path $sigPath) {
  $signals = Get-Content $sigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

# ---- strategy comparison pack: v1 canonical + v2 research runs (data\v2) ----
function Get-DailyEquity($equity) {
  # downsample per-bar equity to last point per day -> [[ts,eq],...]
  $out = New-Object System.Collections.Generic.List[object]
  $curDay = $null; $last = $null
  foreach ($p in $equity) {
    if ($p.day -ne $curDay) { if ($null -ne $last) { $out.Add((,[object[]]@([long]$last.ts, [double]$last.equity))) }; $curDay = $p.day }
    $last = $p
  }
  if ($null -ne $last) { $out.Add((,[object[]]@([long]$last.ts, [double]$last.equity))) }
  return [object[]]@($out | ForEach-Object { $_ })
}
function Get-StratStats($trades, $equity, $monthly) {
  $w=@($trades|Where-Object{$_.pnlUsd -gt 0}); $l=@($trades|Where-Object{$_.pnlUsd -le 0})
  $gw=($w|Measure-Object pnlUsd -Sum).Sum; if($null -eq $gw){$gw=0.0}
  $gl=[math]::Abs(($l|Measure-Object pnlUsd -Sum).Sum); if($null -eq $gl -or $gl -eq 0){$gl=0.0001}
  $e0=[double]$equity[0].equity; $e1=[double]$equity[-1].equity
  $peak=0.0;$dd=0.0
  foreach($p in $equity){ if($p.equity -gt $peak){$peak=[double]$p.equity}; $d=($peak-$p.equity)/$peak; if($d -gt $dd){$dd=$d} }
  $mo=([datetime]$equity[-1].day - [datetime]$equity[0].day).TotalDays/30.44
  $mret=@($monthly | Where-Object {$_.ret_pct -ne 0})
  [ordered]@{
    trades=$trades.Count; winRate=[math]::Round(100*$w.Count/[math]::Max(1,$trades.Count),1)
    pf=[math]::Round($gw/$gl,2); retPct=[math]::Round(100*($e1/$e0-1),1)
    moGeo=[math]::Round(100*([math]::Pow($e1/$e0,1/[math]::Max(1,$mo))-1),2)
    maxDD=[math]::Round(100*$dd,1)
    avgWin=[math]::Round((($w|Measure-Object pnlUsd -Average).Average),0)
    avgLoss=[math]::Round((($l|Measure-Object pnlUsd -Average).Average),0)
    bestMo=($mret|Measure-Object ret_pct -Maximum).Maximum
    worstMo=($mret|Measure-Object ret_pct -Minimum).Minimum
    posMoPct=[math]::Round(100*@($mret|Where-Object{$_.ret_pct -gt 0}).Count/[math]::Max(1,$mret.Count),0)
    months=[math]::Round($mo,1); fromDay=$equity[0].day; toDay=$equity[-1].day
  }
}
function Get-Periods($trades, $equity) {
  $wins = @(
    @{n='bear';    a=[datetime]'2021-11-01'; b=[datetime]'2023-01-31'},
    @{n='recover'; a=[datetime]'2023-02-01'; b=[datetime]'2024-12-31'},
    @{n='bull';    a=[datetime]'2025-01-01'; b=[datetime]'2026-07-08'}
  )
  $res=[ordered]@{}
  foreach($wd in $wins){
    $seg=@($equity | Where-Object { $d=[datetime]$_.day; $d -ge $wd.a -and $d -le $wd.b })
    if($seg.Count -lt 2){ continue }
    $peak=0.0;$dd=0.0
    foreach($p in $seg){ if($p.equity -gt $peak){$peak=[double]$p.equity}; $d=($peak-$p.equity)/$peak; if($d -gt $dd){$dd=$d} }
    $tr=@($trades | Where-Object { $_.exitDay -ne 'EOD' -and [datetime]$_.exitDay -ge $wd.a -and [datetime]$_.exitDay -le $wd.b })
    $gw=($tr|Where-Object{$_.pnlUsd -gt 0}|Measure-Object pnlUsd -Sum).Sum; if($null -eq $gw){$gw=0.0}
    $gl=[math]::Abs(($tr|Where-Object{$_.pnlUsd -le 0}|Measure-Object pnlUsd -Sum).Sum); if($null -eq $gl -or $gl -eq 0){$gl=0.0001}
    $res[$wd.n]=[ordered]@{ ret=[math]::Round(100*($seg[-1].equity/$seg[0].equity-1),1); pf=[math]::Round($gw/$gl,2); dd=[math]::Round(100*$dd,1); trades=$tr.Count }
  }
  return $res
}
function Get-Yearly($equity) {
  # yearly % return from the equity curve: base = last equity of prior year (start equity for the first year)
  $byYear = $equity | Group-Object { ([datetime]$_.day).Year } | Sort-Object Name
  $rows = New-Object System.Collections.Generic.List[object]
  $prevEnd = [double]$equity[0].equity
  # first year's base = value at the very first point minus its own move already included -> use start-of-series equity
  $startEq = [double]$equity[0].equity
  $first = $true
  foreach ($g in $byYear) {
    $endEq = [double]$g.Group[-1].equity
    $base = if ($first) { $startEq } else { $prevEnd }
    $ret = [math]::Round(100*($endEq/$base - 1), 1)
    # drawdown within the year
    $peak=0.0;$dd=0.0
    foreach($p in $g.Group){ if($p.equity -gt $peak){$peak=[double]$p.equity}; $d=($peak-$p.equity)/$peak; if($d -gt $dd){$dd=$d} }
    $rows.Add([ordered]@{ year=[int]$g.Name; retPct=$ret; endEq=[math]::Round($endEq,0); maxDD=[math]::Round(100*$dd,1) })
    $prevEnd = $endEq; $first = $false
  }
  return [object[]]@($rows | ForEach-Object { $_ })
}
function TrimTrades($trades) {
  [object[]]@($trades | ForEach-Object { [ordered]@{ sym=$_.sym; side=$_.side; entryTs=$_.entryTs; exitTs=$_.exitTs; entry=$_.entry; exitPx=$_.exitPx; exitReason=$_.exitReason; pnlUsd=$_.pnlUsd; entryDay=$_.entryDay; exitDay=$_.exitDay } })
}

$v2dir = Join-Path $dir 'data\v2'
$strategies = [object[]]@()
$stratDefs = @(
  @{ id='v1';         label='v1 · канон · 16.4 мес';            cfg='риск 1% · 3 позиции · фильтр BTC + ATR-кэп';                 src=$null;                     prices='main' },
  @{ id='deep-base';  label='v1 · длинная история 6.2 г';       cfg='те же правила · Bybit 2020–2026 · реальный период цикла';    src='base';                    prices='deep' },
  @{ id='deep-combo'; label='v2 · комбо 1%/3поз ★ ДЕЙСТВУЮЩАЯ'; cfg='риск 1% · 3 позиции · флэт-skip + фандинг-фильтр · этим торгует бот с 2026-07-10'; src='combo-skip-fund-filter';  prices='deep' },
  @{ id='live-base';  label='v1 · конс. конфиг · 6.2 г';        cfg='риск 0.5% · 2 позиции · реальный фандинг';                   src='live-base-deep';          prices='deep' },
  @{ id='live-combo'; label='v2 · консервативный профиль';      cfg='0.5% · 2 поз. + флэт-skip + фандинг-фильтр (запасной, тише)'; src='live-combo-deep';         prices='deep' }
)
foreach ($sd in $stratDefs) {
  if ($null -eq $sd.src) {
    $sTr = $trades
    $sEq = [object[]]@($eqRaw | ForEach-Object { $_ })
    $sMo = [object[]]@((Get-Content (Join-Path $dir 'data\bt_monthly.json') -Raw | ConvertFrom-Json) | ForEach-Object { $_ })
  } else {
    $tp = Join-Path $v2dir "$($sd.src)_trades.json"
    if (-not (Test-Path $tp)) { Write-Warning "no v2 artifacts for $($sd.id)"; continue }
    $sTr = [object[]]@((Get-Content $tp -Raw | ConvertFrom-Json) | ForEach-Object { $_ })
    $sEq = [object[]]@((Get-Content (Join-Path $v2dir "$($sd.src)_equity.json") -Raw | ConvertFrom-Json) | ForEach-Object { $_ })
    $sMo = [object[]]@((Get-Content (Join-Path $v2dir "$($sd.src)_monthly.json") -Raw | ConvertFrom-Json) | ForEach-Object { $_ })
  }
  # trim flat equity head before the first trade (data starts earlier than trading - months/moGeo would be diluted)
  $firstTs = ($sTr | ForEach-Object { [long]$_.entryTs } | Measure-Object -Minimum).Minimum
  if ($firstTs) { $sEq = [object[]]@($sEq | Where-Object { [long]$_.ts -ge ($firstTs - 86400000) }) }
  $per = if ($sd.prices -eq 'deep') { Get-Periods $sTr $sEq } else { $null }
  $strategies += ,([ordered]@{
    id=$sd.id; label=$sd.label; cfg=$sd.cfg; prices=$sd.prices
    stats=(Get-StratStats $sTr $sEq $sMo)
    periods=$per
    yearly=(Get-Yearly $sEq)
    equity=(Get-DailyEquity $sEq)
    trades=(TrimTrades $sTr)
  })
}

# deep daily close prices for the deep-strategy trade explorer
$deepPrices = $null
$deepDir = Join-Path $dir 'data\deep'
if (Test-Path $deepDir) {
  $deepPrices = [ordered]@{}
  foreach ($s in $syms) {
    $fp = Join-Path $deepDir "$($s.Replace('-','_'))_4h.json"
    if (-not (Test-Path $fp)) { continue }
    $bars = (Get-Content $fp -Raw | ConvertFrom-Json) | ForEach-Object { $_ }
    $dt = New-Object System.Collections.Generic.List[object]
    $dc = New-Object System.Collections.Generic.List[object]
    $curDay=$null; $lastB=$null
    foreach ($b in $bars) {
      $dday = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$b.t).UtcDateTime.Date
      if ($dday -ne $curDay) { if ($null -ne $lastB) { $dt.Add([long]$lastB.t); $dc.Add([double]$lastB.c) }; $curDay=$dday }
      $lastB = $b
    }
    if ($null -ne $lastB) { $dt.Add([long]$lastB.t); $dc.Add([double]$lastB.c) }
    $deepPrices[$s] = [ordered]@{ t=[object[]]@($dt | ForEach-Object {$_}); c=[object[]]@($dc | ForEach-Object {$_}) }
  }
}

# failed-trades archive (loss classification, optional)
$failed = $null
$failedPath = Join-Path $dir 'data\failed_trades.json'
if (Test-Path $failedPath) {
  $fRaw = Get-Content $failedPath -Raw | ConvertFrom-Json
  $failed = [object[]]@($fRaw | ForEach-Object { $_ })
}

# closed live trades ledger (actual paper-account trades, wins & losses)
$liveClosed = $null
$ltPath = Join-Path $dir 'data\live_trades.json'
if (Test-Path $ltPath) {
  $ltRaw = Get-Content $ltPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $liveClosed = [object[]]@($ltRaw | ForEach-Object { $_ })
}

# ---- прибыль по дням (живой счёт): дневные ведра из лога эквити + закрытых сделок ----
# pnl дня = equity на конец дня - equity на конец предыдущего дня (включая нереализованное);
# realized/fees/funding/W-L - по сделкам, закрытым в этот день. Сегодняшний день - "живой"
# (база = day_start_equity_usd из portfolio.json, значение = текущий equity).
$liveDaily = [object[]]@()
if ($leLog.Count) {
  $dayLast = [ordered]@{}   # 'yyyy-MM-dd' -> последняя точка эквити дня
  foreach ($pt in $leLog) {
    $d = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$pt.ts).UtcDateTime.ToString('yyyy-MM-dd')
    $dayLast[$d] = [double]$pt.eq
  }
  $tradesByDay = @{}
  foreach ($t in @($liveClosed)) {
    if ($null -eq $t) { continue }
    $d = [string]$t.exitDay
    if (-not $tradesByDay.ContainsKey($d)) { $tradesByDay[$d] = @{ pnl=0.0; fees=0.0; fund=0.0; w=0; l=0 } }
    $g = $tradesByDay[$d]
    $g.pnl += [double]$t.pnlUsd; $g.fees += [double]$t.fees; $g.fund += [double]$t.funding
    if ([double]$t.pnlUsd -gt 0) { $g.w++ } else { $g.l++ }
  }
  $allDays = @(@($dayLast.Keys) + @($tradesByDay.Keys) | Sort-Object -Unique)
  $today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
  $rows = New-Object System.Collections.Generic.List[object]
  $prevEq = $liveStartEq
  foreach ($d in $allDays) {
    $eq1 = if ($dayLast.Contains($d)) { [double]$dayLast[$d] } else { $prevEq }
    if ($d -eq $today) {
      # живой день: база - зафиксированный старт дня из portfolio.json, значение - текущий equity
      $base = [double]$pf.day_start_equity_usd
      if ([string]$pf.day_start_date_utc -ne $today) { $base = $prevEq }
      $eq0 = $base; $eq1 = $liveEqNow
    } else { $eq0 = $prevEq }
    $tr = if ($tradesByDay.ContainsKey($d)) { $tradesByDay[$d] } else { $null }
    $rows.Add([ordered]@{
      d = $d
      eq0 = [math]::Round($eq0, 2); eq1 = [math]::Round($eq1, 2)
      pnl = [math]::Round($eq1 - $eq0, 2)
      pnlPct = if ($eq0 -gt 0) { [math]::Round(100.0 * ($eq1 - $eq0) / $eq0, 2) } else { 0 }
      realized = if ($tr) { [math]::Round($tr.pnl, 2) } else { 0 }
      fees = if ($tr) { [math]::Round($tr.fees, 2) } else { 0 }
      funding = if ($tr) { [math]::Round($tr.fund, 2) } else { 0 }
      w = if ($tr) { $tr.w } else { 0 }
      l = if ($tr) { $tr.l } else { 0 }
      live = ($d -eq $today)
    })
    $prevEq = $eq1
  }
  $liveDaily = [object[]]@($rows | ForEach-Object { $_ })
}

$viz = [ordered]@{
  generatedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')
  equityNow = $pf.equity_usd
  balanceNow = $pf.balance_usd
  prices = $prices
  trades = $trades
  equity = $equity
  moex   = $moex
  moexFut = $moexFut
  momStocks = $momStocks
  livePositions = $livePositions
  liveClosed = $liveClosed
  liveDaily = $liveDaily
  rfLive = $rfLive
  rfReal = $rfReal
  failedTrades = $failed
  strategies = $strategies
  deepPrices = $deepPrices
  signals = $signals
  liveActual = $liveActual
  realLive = $realLive
  challenge = $challenge
}
$json = $viz | ConvertTo-Json -Depth 8 -Compress
$out = Join-Path $dir 'report\vizdata.js'
[IO.File]::WriteAllText($out, "const VIZ = $json;", (New-Object System.Text.UTF8Encoding($false)))

# копия испечённых свечей T-Invest под report/ (браузер и Pages-артефакт видят ТОЛЬКО report/;
# фетч ../data/... даёт 404). chart.html читает report/rf_candles/<CODE>_<tf>.json с ISS-фолбэком.
# Это build-артефакт как vizdata.js -> gitignored.
$rfCandSrc = Join-Path $dir 'data\live_rf\candles'
$rfCandDst = Join-Path $dir 'report\rf_candles'
if (Test-Path $rfCandSrc) {
  if (-not (Test-Path $rfCandDst)) { New-Item -ItemType Directory -Force $rfCandDst | Out-Null }
  Copy-Item (Join-Path $rfCandSrc '*.json') $rfCandDst -Force -ErrorAction SilentlyContinue
  "  rf_candles -> report/ ({0} файлов)" -f @(Get-ChildItem $rfCandDst -Filter *.json -ErrorAction SilentlyContinue).Count
}

# sanity checks
$txt = [IO.File]::ReadAllText($out)
$ok1 = $txt.Contains('"trades":[')
$ok2 = -not $txt.Contains('"value":[{"sym"')
"written {0:N0} KB | trades-is-array={1} | no-wrapper={2}" -f ((Get-Item $out).Length/1KB), $ok1, $ok2
if (-not ($ok1 -and $ok2)) { throw "vizdata.js still malformed!" }

# cache-bust: stamp a version query on every <script src="vizdata.js"> so browsers
# refetch the 3MB payload after each rebuild instead of serving a stale cached copy.
$ver = [long]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
foreach ($html in @('report\trades.html', 'report\chart.html', 'report\charts.html')) {
  $hp = Join-Path $dir $html
  if (-not (Test-Path $hp)) { continue }
  $h = [IO.File]::ReadAllText($hp)
  $new = [regex]::Replace($h, 'vizdata\.js(\?v=\d+)?', "vizdata.js?v=$ver")
  if ($new -ne $h) { [IO.File]::WriteAllText($hp, $new, (New-Object System.Text.UTF8Encoding($false))); "  cache-bust $html -> ?v=$ver" }
}
# маркер билда для авто-обновления страницы: trades.html опрашивает build.json без кэша и,
# увидев v больше своего ?v=, показывает баннер «обновить» / сам перезагружается минуя кэш.
[IO.File]::WriteAllText((Join-Path $dir 'report\build.json'), "{""v"":$ver}", (New-Object System.Text.UTF8Encoding($false)))

# auto-publish to GitHub Pages so the hosted dashboard reflects every data change
# automatically (no manual deploy step). Failures (offline/auth) only warn - the
# local sim and terminal must never break because a push could not go out.
if (-not $NoDeploy) {
  $deploy = Join-Path $PSScriptRoot 'deploy_site.ps1'
  if (Test-Path $deploy) {
    try { & $deploy } catch { Write-Warning "auto-deploy skipped: $($_.Exception.Message)" }
  }
}
