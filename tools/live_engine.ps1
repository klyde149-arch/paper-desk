# live_engine.ps1 - LIVE-исполнитель v2 «комбо» на РЕАЛЬНЫЕ деньги (Bybit UTA, linear USDT perp).
# Запускается на VPS под pwsh каждую минуту (systemd timer + flock). Paper-контуры не трогает:
# пишет только data/live_real/* и journal_live.md (непересекающиеся с Actions файлы).
#
# Инварианты безопасности:
#   - стоп ВСЕГДА лежит на бирже (Full-mode SL при входе) - падение бота не оставляет позицию голой;
#   - интент персистится ДО вызова API (write-ahead) - после краша order/history?orderLinkId решает adopt-or-clear;
#   - биржа - источник истины: книга ведётся по /v5/execution/list, не по симуляции;
#   - сбой API => тик прерывается fail-safe, вотермарки не двигаются;
#   - kill-файлы: data/HALT (глобальный), data/HALT_LIVE (без новых входов), data/HALT_CLOSE (флэттен всего).
#
# Сайзинг/ворота ДОЛЖНЫ зеркалить paper: tools/auto_trade.ps1:24-33 (константы) и :388-443 (входы).
param(
  [switch]$DryRun,      # читать всё, ничего не размещать (также env LIVE_DRYRUN=1)
  [string]$Root = ''
)
$ErrorActionPreference = 'Stop'
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'lib_engine.ps1')
. (Join-Path $PSScriptRoot 'lib_bybit_live.ps1')
. (Join-Path $PSScriptRoot 'lib_alerts.ps1')
if ($env:LIVE_DRYRUN -eq '1') { $DryRun = $true }

# ---- константы: MUST mirror tools/auto_trade.ps1:24-33 (менять только синхронно!) ----
$RISKPCT  = 0.01
$MAXPOS   = 3
$MAXLEV   = 5
$TPR      = 1.5
$MIN = [long]60000; $H4 = [long]14400000
$EXCLUDED = @('DOGE-USDT')
$SYMBOLS  = @('BTC-USDT','ETH-USDT','SOL-USDT','BNB-USDT','XRP-USDT','DOGE-USDT','ADA-USDT','AVAX-USDT','LINK-USDT')

# ---- пути ----
$liveDir = Join-Path $Root 'data/live_real'
[void][IO.Directory]::CreateDirectory($liveDir)
$lpPath   = Join-Path $liveDir 'portfolio.json'
$ltPath   = Join-Path $liveDir 'live_trades.json'
$lePath   = Join-Path $liveDir 'live_equity.json'
$instPath = Join-Path $liveDir 'instruments.json'
$logPath  = Join-Path $liveDir 'tick_log.txt'
$pushFlag = Join-Path $liveDir '.push_now'
$jrnPath  = Join-Path $Root 'journal_live.md'

$nowMs = UtcNowMs
$nowStr = MsToUtcStr $nowMs
$sw = [Diagnostics.Stopwatch]::StartNew()
$modeTag = if ($DryRun) { 'DRYRUN' } else { 'LIVE' }

function LLog([string]$Line) {
  $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
  [IO.File]::AppendAllText($logPath, "$stamp`Z $Line`n", (New-Object System.Text.UTF8Encoding($false)))
  try {
    $fi = Get-Item $logPath
    if ($fi.Length -gt 500KB) {
      $txt = [IO.File]::ReadAllText($logPath)
      $keep = $txt.Substring([int]($txt.Length / 2))
      $nl = $keep.IndexOf("`n"); if ($nl -ge 0) { $keep = $keep.Substring($nl + 1) }
      [IO.File]::WriteAllText($logPath, $keep, (New-Object System.Text.UTF8Encoding($false)))
    }
  } catch {}
}
function Bs([string]$Sym) { $Sym.Replace('-', '') }
function Ensure-Prop($Obj, [string]$Name, $Default) {
  if (-not $Obj.PSObject.Properties[$Name]) { $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Default }
}

$script:events = New-Object System.Collections.Generic.List[string]
$script:jblocks = New-Object System.Collections.Generic.List[string]
$script:closedCards = New-Object System.Collections.Generic.List[object]
$script:lp = $null

function Save-State { if ($null -ne $script:lp) { Write-JsonAtomic $lpPath $script:lp 12 } }

function New-LiveState([double]$Equity) {
  [pscustomobject]@{
    schema = 1; engine = 'v2-combo-live'; mode = $modeTag
    equity_usd = $Equity; peak_equity_usd = $Equity
    day_start_equity_usd = $Equity; day_start_date_utc = (MsToUtcDay $nowMs)
    week_start_equity_usd = $Equity; week_start_date_utc = ''
    trading_halted = $false; entries_halt_reason = ''
    open_trades = @(); pending_intents = @()
    auto = [pscustomobject]@{
      last_4h_ts = (FloorTo $nowMs $H4) - 2*$H4
      last_trail_4h_ts = (FloorTo $nowMs $H4) - $H4
      last_exec_ms = $nowMs - 3600000
      seen_exec_ids = @()
      next_trade_id = 1
      halt_day_utc = $null; soft_dd = $false
      consec_api_fail = 0
      leverage_set = @()
      last_tick_utc = ''; last_daily_summary_day = ''
    }
  }
}

# карточка закрытой сделки: поля зеркалят paper (Close-Trade в auto_trade.ps1) + live-метки
function Build-ClosedCard($T, [string]$Reason, [long]$Ts) {
  $legs = @($T.legs)
  $grossSum = 0.0; $qtySum = 0.0; $pxW = 0.0
  foreach ($lg in $legs) { $grossSum += [double]$lg.pnl; $qtySum += [double]$lg.qty; $pxW += [double]$lg.qty * [double]$lg.price }
  $exitAvg = if ($qtySum -gt 0) { $pxW / $qtySum } else { [double]$T.entry_price }
  $fees = [double]$T.fees_usd; $funding = [double]$T.funding_usd
  $net = [math]::Round($grossSum - $fees - $funding, 2)
  $risk = [double]$T.risk_usd
  [pscustomobject]@{
    id = $T.id; sym = $T.symbol; side = $T.side; live = $true
    result = if ($net -gt 0) { 'win' } else { 'loss' }
    entryUtc = $T.entry_utc; entryDay = ([string]$T.entry_utc -split ' ')[0]; entryTs = [long]$T.entry_ts
    entry = [double]$T.entry_price; qty = [double]$T.qty_initial
    exitUtc = (MsToUtcStr $Ts); exitDay = (MsToUtcDay $Ts); exitTs = $Ts
    exitPx = [math]::Round($exitAvg, 6); exitReason = $Reason
    legs = ToArr $legs
    pnlUsd = $net
    rMultiple = if ($risk -gt 0) { [math]::Round($net / $risk, 2) } else { $null }
    riskUsd = $risk
    fees = [math]::Round($fees, 2); funding = [math]::Round($funding, 2)
    thesis = $T.thesis
  }
}

function Add-ExitLeg($T, [string]$Part, [double]$Qty, [double]$Px, [long]$Ts, [double]$Fee) {
  $sideMul = if ($T.side -eq 'long') { 1.0 } else { -1.0 }
  $gross = $sideMul * $Qty * ($Px - [double]$T.entry_price)
  $T.fees_usd = [double]$T.fees_usd + $Fee
  $leg = [pscustomobject]@{ part = $Part; qty = [math]::Round($Qty, 6); price = [math]::Round($Px, 6); utc = (MsToUtcStr $Ts); pnl = [math]::Round($gross, 2) }
  $T.legs = ToArr (@($T.legs) + $leg)
  $T.qty = [math]::Round([double]$T.qty - $Qty, 6)
  if ($T.qty -lt 0) { $T.qty = 0.0 }
}

try {
  # ---------- 0. kill-switches ----------
  if (Test-Path (Join-Path $Root 'data/HALT')) { LLog 'skip: HALT (global)'; return }
  $haltLive  = Test-Path (Join-Path $Root 'data/HALT_LIVE')
  $haltClose = Test-Path (Join-Path $Root 'data/HALT_CLOSE')

  # ---------- 1. preflight: время + кошелёк (одновременно auth/geo-проверка) ----------
  $script:lp = Read-JsonFile $lpPath
  $wallet = $null
  try {
    [void](Sync-BybitTime)
    $wallet = Get-WalletEquity
  } catch {
    if ($null -ne $script:lp) {
      $script:lp.auto.consec_api_fail = [int]$script:lp.auto.consec_api_fail + 1
      if ([int]$script:lp.auto.consec_api_fail -eq 5) { [void](Send-TgAlert "[$modeTag] Bybit API недоступен 5 тиков подряд: $($_.Exception.Message)") }
      Save-State
    }
    LLog "PREFLIGHT FAIL: $($_.Exception.Message)"
    return
  }
  $equity = [math]::Round([double]$wallet.totalEquity, 2)

  if ($null -eq $script:lp) {
    $script:lp = New-LiveState $equity
    LLog "state initialized: equity=$equity mode=$modeTag"
    [void](Send-TgAlert "[$modeTag] live-движок инициализирован. Equity: $equity USDT")
  }
  $lp = $script:lp
  if ([string]$lp.mode -ne $modeTag) {
    [void](Send-TgAlert "[$modeTag] режим переключён: $($lp.mode) -> $modeTag. Equity: $equity USDT")
    $lp.mode = $modeTag
  }
  $lp.auto.consec_api_fail = 0
  # миграция состояния: поля недельного отчёта (могли отсутствовать в ранних версиях)
  Ensure-Prop $lp 'week_start_equity_usd' $equity
  Ensure-Prop $lp 'week_start_date_utc' ''

  $trades = New-Object System.Collections.Generic.List[object]
  foreach ($t in @($lp.open_trades)) { if ($null -ne $t) { $trades.Add($t) } }
  $intents = New-Object System.Collections.Generic.List[object]
  foreach ($i in @($lp.pending_intents)) { if ($null -ne $i) { $intents.Add($i) } }

  # ---------- 2. HALT_CLOSE: флэттен всего ----------
  if ($haltClose -and -not $DryRun) {
    LLog 'HALT_CLOSE: cancel-all + флэттен'
    try { [void](Cancel-AllOrders) } catch { LLog "cancel-all failed: $($_.Exception.Message)" }
    $exPosNow = Get-PositionsLive
    foreach ($p in $exPosNow) {
      $posSide = if ($p.side -eq 'Buy') { 'long' } else { 'short' }
      $qtyStr = $p.size.ToString([Globalization.CultureInfo]::InvariantCulture)
      $r = Close-PositionMarket $p.symbol $posSide $qtyStr "HC$((UtcNowMs))-$($p.symbol)"
      LLog "HALT_CLOSE $($p.symbol): ok=$($r.ok)"
    }
    $lp.trading_halted = $true
    $lp.entries_halt_reason = 'HALT_CLOSE'
    $script:events.Add('HALT_CLOSE: флэттен')
    [void](Send-TgAlert "[$modeTag] HALT_CLOSE: все ордера отменены, позиции закрываются маркетом. Торговля остановлена.")
    # книга закрытий придёт через executions на следующих тиках
  }

  # ---------- 3. reconcile: биржа -> книга ----------
  $exPos = Get-PositionsLive           # только size>0
  $exOrders = Get-OpenOrdersLive
  $sinceMs = [long]$lp.auto.last_exec_ms - 300000
  $floorMs = $nowMs - 6*24*3600000     # окно /v5/execution/list = 7 дней
  if ($sinceMs -lt $floorMs) { $sinceMs = $floorMs }
  $execs = Get-ExecutionsSince $sinceMs

  $seen = New-Object System.Collections.Generic.HashSet[string]
  foreach ($s in @($lp.auto.seen_exec_ids)) { [void]$seen.Add([string]$s) }

  # 3a. интенты, пережившие прошлый тик = краш/неясный результат вызова
  foreach ($it in @($intents.ToArray())) {
    $ord = $null
    try { $ord = Get-OrderByLinkId ([string]$it.linkId) } catch { continue }   # API мигнул - подождём
    $t = $trades | Where-Object { $_.id -eq $it.tradeId } | Select-Object -First 1
    if ($null -ne $ord) {
      # вызов дошёл до биржи: филлы придут через executions; интент снимаем
      [void]$intents.Remove($it)
      $ost = [string]$ord.orderStatus
      if ($it.kind -eq 'entry' -and $t -and ($ost -in @('Rejected','Cancelled')) -and [double]$ord.cumExecQty -eq 0) {
        [void]$trades.Remove($t)
        LLog "entry $($it.tradeId) rejected on exchange ($ost) - карточка снята"
        [void](Send-TgAlert "[$modeTag] Вход $($it.tradeId) отклонён биржей ($ost)")
      }
    } else {
      $ageMin = ($nowMs - [long]$it.ts) / 60000.0
      if ($ageMin -gt 3) {
        # вызов не дошёл до биржи
        [void]$intents.Remove($it)
        if ($it.kind -eq 'entry' -and $t -and [string]$t.status -eq 'pending' -and [double]$t.entry_filled_qty -eq 0) {
          [void]$trades.Remove($t)
          LLog "intent $($it.linkId) не найден на бирже >3мин - вход снят"
          [void](Send-TgAlert "[$modeTag] Интент $($it.linkId) не дошёл до биржи - вход отменён")
        } else {
          LLog "intent $($it.linkId) не найден >3мин - снят (watchdog повторит)"
        }
      }
    }
  }

  # 3b. применяем свежие executions (в порядке времени)
  $maxExecMs = [long]$lp.auto.last_exec_ms
  foreach ($e in $execs) {
    $eid = [string]$e.execId
    if (-not $eid -or $seen.Contains($eid)) { continue }
    [void]$seen.Add($eid)
    $eMs = [long]$e.execTime
    if ($eMs -gt $maxExecMs) { $maxExecMs = $eMs }
    $eSymBs = [string]$e.symbol
    $t = $trades | Where-Object { (Bs $_.symbol) -eq $eSymBs } | Select-Object -First 1

    if ([string]$e.execType -eq 'Funding') {
      if ($t) { $t.funding_usd = [math]::Round([double]$t.funding_usd + [double]$e.execFee, 4) }
      continue
    }
    if ([string]$e.execType -ne 'Trade') { continue }

    $link = [string]$e.orderLinkId
    $fq = [double]$e.execQty; $fp = [double]$e.execPrice; $fee = [double]$e.execFee
    $tByLink = $null
    if ($link -match '^(LT\d+)-') { $tByLink = $trades | Where-Object { $_.id -eq $Matches[1] } | Select-Object -First 1 }

    if ($tByLink -and $link.EndsWith('-entry')) {
      $prevQ = [double]$tByLink.entry_filled_qty
      $newQ = $prevQ + $fq
      $tByLink.entry_price = if ($prevQ -le 0) { $fp } else { ([double]$tByLink.entry_price * $prevQ + $fp * $fq) / $newQ }
      $tByLink.entry_filled_qty = $newQ
      $tByLink.qty = $newQ; $tByLink.qty_initial = $newQ
      $tByLink.fees_usd = [double]$tByLink.fees_usd + $fee
      if ([string]$tByLink.status -ne 'open') {
        $tByLink.status = 'open'
        $script:events.Add("ENTRY FILLED $($tByLink.id) $($tByLink.symbol) @$fp")
        $script:jblocks.Add(("`r`n## {0} UTC — LIVE: ВХОД {1} {2} {3} исполнен @{4}, qty {5}, комиссия {6}$`r`n" -f (MsToUtcStr $eMs), $tByLink.id, $tByLink.symbol, ([string]$tByLink.side).ToUpper(), $fp, $fq, [math]::Round($fee,4)))
        [void](Send-TgAlert (("[$modeTag] ВХОД {0} {1} {2} @{3}" -f $tByLink.id, $tByLink.symbol, ([string]$tByLink.side).ToUpper(), $fp) +
          ("`nqty={0} стоп={1} TP1={2}" -f $fq, $tByLink.stop, $tByLink.tp1) +
          ("`nриск {0}$, номинал {1}$, план: TP1 1.5R (50%) -> БУ -> трейл EMA20 4h" -f $tByLink.risk_usd, $tByLink.notional_usd)))
      }
      continue
    }
    if ($tByLink -and $link.EndsWith('-tp1')) {
      Add-ExitLeg $tByLink 'TP1' $fq $fp $eMs $fee
      $tByLink.tp1_filled_qty = [double]$tByLink.tp1_filled_qty + $fq
      if ([double]$tByLink.tp1_filled_qty -ge 0.999 * [double]$tByLink.tp1_qty -and -not $tByLink.tp1_done) {
        $tByLink.tp1_done = $true
        $script:events.Add("TP1 $($tByLink.id) $($tByLink.symbol)")
        $script:jblocks.Add(("`r`n## {0} UTC — LIVE: TP1 по {1} {2} — закрыто @{3}, стоп будет переведён в БУ`r`n" -f (MsToUtcStr $eMs), $tByLink.id, $tByLink.symbol, $fp))
        [void](Send-TgAlert "[$modeTag] TP1 $($tByLink.id) $($tByLink.symbol) @$fp - стоп в БУ")
      }
      continue
    }
    if ($tByLink -and $link.EndsWith('-close')) {
      Add-ExitLeg $tByLink 'runner' $fq $fp $eMs $fee
      continue
    }
    # филл без нашего linkId: биржевой SL / ручное вмешательство
    if ($t) {
      $oppSide = if ([string]$t.side -eq 'long') { 'Sell' } else { 'Buy' }
      if ([string]$e.side -eq $oppSide) {
        $part = if ($t.tp1_done) { 'runner-be' } else { 'stop' }
        Add-ExitLeg $t $part $fq $fp $eMs $fee
        $t.sl_exec = $true
      } else {
        LLog "DRIFT: неожиданный филл $eSymBs $($e.side) qty=$fq (наращивает нашу позицию?)"
        [void](Send-TgAlert "[$modeTag] ДРИФТ: неожиданный филл $eSymBs $($e.side) qty=$fq - проверь аккаунт")
      }
    }
    # филл по чужому символу без локальной сделки - молчим; позицию поймает D2 ниже
  }
  # ring-буфер seen (последние 400)
  $seenArr = @($seen)
  if ($seenArr.Count -gt 400) { $seenArr = $seenArr[($seenArr.Count-400)..($seenArr.Count-1)] }
  $lp.auto.seen_exec_ids = $seenArr
  $lp.auto.last_exec_ms = $maxExecMs

  # 3c. сверка позиций и закрытие карточек
  $exBySym = @{}
  foreach ($p in $exPos) { $exBySym[$p.symbol] = $p }
  $driftHalt = ''
  foreach ($t in @($trades.ToArray())) {
    $bs = Bs $t.symbol
    $havePos = $exBySym.ContainsKey($bs)
    if ([string]$t.status -eq 'open' -and -not $havePos) {
      if ([double]$t.qty -gt 1e-9 -and @($t.legs).Count -eq 0) {
        # D4: позиция исчезла, executions не видели
        $driftHalt = "D4 $($t.symbol): позиция исчезла без executions"
        LLog "DRIFT D4: $($t.symbol) - оставляю карточку, входы на халт"
        continue
      }
      $reason = if ($t.close_reason) { [string]$t.close_reason }
                elseif ($t.tp1_done) { 'be-stop' } else { 'stop' }
      $card = Build-ClosedCard $t $reason $nowMs
      $script:closedCards.Add($card)
      [void]$trades.Remove($t)
      $resTxt = if ([double]$card.pnlUsd -gt 0) { 'ПРИБЫЛЬ' } else { 'УБЫТОК' }
      $script:events.Add("EXIT $($card.id) $($card.sym) $reason $($card.pnlUsd) USD")
      $script:jblocks.Add(("`r`n## {0} UTC — LIVE: закрыта {1} {2} {3} — {4} {5:+0.00;-0.00}$ ({6})`r`n" -f $nowStr, $card.id, $card.sym, ([string]$card.side).ToUpper(), $resTxt, [double]$card.pnlUsd, $reason) +
        ("Вход {0} → средний выход {1}; R = {2}; комиссии {3}$, фандинг {4}$.`r`n" -f $card.entry, $card.exitPx, $card.rMultiple, $card.fees, $card.funding))
      $holdH = [math]::Round(($nowMs - [long]$card.entryTs) / 3600000.0, 1)
      [void](Send-TgAlert (("[$modeTag] ВЫХОД {0} {1} {2}: {3:+0.00;-0.00}$ ({4}), R={5}" -f $card.id, $card.sym, ([string]$card.side).ToUpper(), [double]$card.pnlUsd, $reason, $card.rMultiple) +
        ("`nвход {0} -> выход {1}, в позиции {2}ч" -f $card.entry, $card.exitPx, $holdH) +
        ("`nкомиссии {0}$, фандинг {1}$, equity {2}$" -f $card.fees, $card.funding, $equity)))
      continue
    }
    if ([string]$t.status -eq 'open' -and $havePos) {
      $exq = [double]$exBySym[$bs].size
      if ([math]::Abs($exq - [double]$t.qty) -gt [math]::Max(1e-9, 0.02 * [double]$t.qty_initial)) {
        $driftHalt = "D5 $($t.symbol): размер бирж=$exq лок=$($t.qty)"
        LLog "DRIFT D5: $driftHalt"
      }
      # D6: позиция без стопа на бирже - единственный случай авто-закрытия
      if ("$($exBySym[$bs].stopLoss)" -eq '') {
        LLog "DRIFT D6: $($t.symbol) без SL на бирже - перевзвожу"
        if (-not $DryRun) {
          $inst = Get-InstrumentsInfo @($t.symbol) $instPath
          $slStr = Format-RoundToTick ([double]$t.stop) $inst[$t.symbol].tickSize
          try {
            [void](Set-StopLossPrice $t.symbol $slStr)
            [void](Send-TgAlert "[$modeTag] D6: $($t.symbol) был без стопа - перевзведён @$slStr")
          } catch {
            LLog "D6 re-arm failed: $($_.Exception.Message) - закрываю маркетом"
            $qtyStr = $exq.ToString([Globalization.CultureInfo]::InvariantCulture)
            [void](Close-PositionMarket $t.symbol ([string]$t.side) $qtyStr "$($t.id)-close")
            $t.close_reason = 'no-sl-emergency'
            [void](Send-TgAlert "[$modeTag] D6: $($t.symbol) без стопа, перевзвод не удался - ЗАКРЫВАЮ МАРКЕТОМ")
          }
        }
      }
    }
    # pending-карточка старше 5 мин без интента и без филлов - мусор после сбоя
    if ([string]$t.status -eq 'pending' -and [double]$t.entry_filled_qty -eq 0) {
      $hasIntent = @($intents | Where-Object { $_.tradeId -eq $t.id }).Count -gt 0
      if (-not $hasIntent -and ($nowMs - [long]$t.entry_ts) -gt 300000) {
        [void]$trades.Remove($t)
        LLog "pending $($t.id) без интента и филлов >5мин - снята"
      }
    }
  }
  # D2: биржевая позиция без локальной карточки
  foreach ($p in $exPos) {
    $known = @($trades | Where-Object { (Bs $_.symbol) -eq $p.symbol }).Count -gt 0
    if (-not $known) {
      $driftHalt = "D2 $($p.symbol): позиция на бирже без карточки (ручная?)"
      LLog "DRIFT D2: $($p.symbol) size=$($p.size) $($p.side)"
      [void](Send-TgAlert "[$modeTag] ДРИФТ D2: на бирже позиция $($p.symbol) $($p.side) $($p.size) без нашей карточки. Входы на халт. Не торгуй руками на этом аккаунте.")
    }
  }
  if ($driftHalt) { $lp.entries_halt_reason = $driftHalt }
  elseif ("$($lp.entries_halt_reason)" -like 'D*') { $lp.entries_halt_reason = ''; LLog 'drift-халт снят (дрифт исчез)' }

  # ---------- 4a. недельный отчёт (первый тик новой ISO-недели, пн 00:00 UTC) ----------
  $todayDate = (MsToUtc $nowMs).Date
  $curMonday = $todayDate.AddDays(-((([int]$todayDate.DayOfWeek) + 6) % 7)).ToString('yyyy-MM-dd')
  if ("$($lp.week_start_date_utc)" -eq '') {
    $lp.week_start_date_utc = $curMonday
    $lp.week_start_equity_usd = $equity
  } elseif ([string]$lp.week_start_date_utc -ne $curMonday) {
    $wStart = [string]$lp.week_start_date_utc
    $wPnl = [math]::Round($equity - [double]$lp.week_start_equity_usd, 2)
    $wPct = if ([double]$lp.week_start_equity_usd -gt 0) { [math]::Round(100.0 * $wPnl / [double]$lp.week_start_equity_usd, 2) } else { 0.0 }
    $wTrades = @()
    foreach ($x in @(Read-JsonFile $ltPath)) {
      if ($null -ne $x -and [string]$x.exitDay -ge $wStart -and [string]$x.exitDay -lt $curMonday) { $wTrades += $x }
    }
    $wWins = @($wTrades | Where-Object { $_.result -eq 'win' }).Count
    $wFees = 0.0; $wFund = 0.0; $wR = 0.0
    foreach ($x in $wTrades) { $wFees += [double]$x.fees; $wFund += [double]$x.funding; if ($null -ne $x.rMultiple) { $wR += [double]$x.rMultiple } }
    $ddNow = if ([double]$lp.peak_equity_usd -gt 0) { [math]::Round(100.0 * ([double]$lp.peak_equity_usd - $equity) / [double]$lp.peak_equity_usd, 1) } else { 0.0 }
    $haltTxt = if ($lp.trading_halted) { 'HALT' } elseif ("$($lp.entries_halt_reason)" -ne '') { [string]$lp.entries_halt_reason } else { 'нет' }
    $wMsg = ("[$modeTag] НЕДЕЛЬНЫЙ ОТЧЁТ {0}..{1}" -f $wStart, $curMonday) +
      ("`nEquity: {0}$ | P&L недели: {1:+0.00;-0.00}$ ({2:+0.00;-0.00}%)" -f $equity, $wPnl, $wPct) +
      ("`nСделок: {0} (W{1}/L{2}), суммарный R: {3:+0.00;-0.00}" -f $wTrades.Count, $wWins, ($wTrades.Count - $wWins), $wR) +
      ("`nКомиссии: {0}$ | фандинг: {1}$" -f [math]::Round($wFees,2), [math]::Round($wFund,2)) +
      ("`nОт пика: -{0}% | халты: {1}" -f $ddNow, $haltTxt)
    [void](Send-TgAlert $wMsg)
    $script:jblocks.Add(("`r`n## {0} UTC — LIVE недельный отчёт {1}..{2}: P&L {3:+0.00;-0.00}$ ({4:+0.00;-0.00}%), сделок {5} (W{6}/L{7}), R {8:+0.00;-0.00}, комиссии {9}$, фандинг {10}$`r`n" -f $nowStr, $wStart, $curMonday, $wPnl, $wPct, $wTrades.Count, $wWins, ($wTrades.Count - $wWins), $wR, [math]::Round($wFees,2), [math]::Round($wFund,2)))
    $script:events.Add('WEEKLY REPORT')
    $lp.week_start_date_utc = $curMonday
    $lp.week_start_equity_usd = $equity
  }

  # ---------- 4. ролл дня + governors на реальном equity ----------
  $todayUtc = MsToUtcDay $nowMs
  if ($todayUtc -ne [string]$lp.day_start_date_utc) {
    $prevDay = [string]$lp.day_start_date_utc
    if ([string]$lp.auto.last_daily_summary_day -ne $prevDay) {
      $dpl = $equity - [double]$lp.day_start_equity_usd
      $dplPct = if ([double]$lp.day_start_equity_usd -gt 0) { 100.0 * $dpl / [double]$lp.day_start_equity_usd } else { 0 }
      $script:jblocks.Add(("`r`n## {0} 00:00 UTC — LIVE сводка дня {1}: equity {2}$, P&L дня {3:+0.00;-0.00}$ ({4:+0.00;-0.00}%), позиций {5}`r`n" -f $todayUtc, $prevDay, $equity, $dpl, $dplPct, $trades.Count))
      [void](Send-TgAlert ("[$modeTag] Сводка дня {0}: equity {1}$, P&L {2:+0.00;-0.00}$ ({3:+0.00;-0.00}%), позиций {4} [heartbeat]" -f $prevDay, $equity, $dpl, $dplPct, $trades.Count))
      $lp.auto.last_daily_summary_day = $prevDay
    }
    $lp.day_start_equity_usd = $equity
    $lp.day_start_date_utc = $todayUtc
    $lp.auto.halt_day_utc = $null
  }
  if ($equity -gt [double]$lp.peak_equity_usd) { $lp.peak_equity_usd = $equity }
  $dd = if ([double]$lp.peak_equity_usd -gt 0) { ([double]$lp.peak_equity_usd - $equity) / [double]$lp.peak_equity_usd } else { 0 }
  if ($dd -ge 0.35 -and $trades.Count -gt 0 -and -not $lp.trading_halted) {
    LLog 'HARD-HALT -35%: флэттен'
    if (-not $DryRun) {
      try { [void](Cancel-AllOrders) } catch {}
      foreach ($t in $trades) {
        $bs = Bs $t.symbol
        if ($exBySym.ContainsKey($bs)) {
          $qtyStr = ([double]$exBySym[$bs].size).ToString([Globalization.CultureInfo]::InvariantCulture)
          $t.close_reason = 'hard-halt-35pct'
          [void](Close-PositionMarket $t.symbol ([string]$t.side) $qtyStr "$($t.id)-close")
        }
      }
    }
    $lp.trading_halted = $true
    $script:events.Add('HARD-HALT -35%')
    $script:jblocks.Add(("`r`n## {0} UTC — LIVE: ЖЁСТКАЯ ОСТАНОВКА −35% от пика. Позиции закрываются, торговля остановлена.`r`n" -f $nowStr))
    [void](Send-TgAlert "[$modeTag] ЖЁСТКАЯ ОСТАНОВКА -35% от пика ($($lp.peak_equity_usd) -> $equity). Всё закрывается.")
  }
  if ($dd -ge 0.16) {
    if (-not $lp.auto.soft_dd) { $lp.auto.soft_dd = $true; $script:events.Add('SOFT-DD -16%: риск x0.5'); [void](Send-TgAlert "[$modeTag] Просадка >=16% от пика - риск новых входов x0.5") }
  } elseif ($dd -lt 0.12 -and $lp.auto.soft_dd) { $lp.auto.soft_dd = $false; $script:events.Add('SOFT-DD снят') }
  $dayBase = [double]$lp.day_start_equity_usd
  if ($dayBase -gt 0 -and (($equity - $dayBase) / $dayBase) -le -0.05 -and [string]$lp.auto.halt_day_utc -ne $todayUtc) {
    $lp.auto.halt_day_utc = $todayUtc
    $script:events.Add("DAY-HALT -5% ($todayUtc)")
    [void](Send-TgAlert "[$modeTag] Дневной лимит -5% достигнут - входы заблокированы до следующего UTC-дня")
  }

  # ---------- 5. менеджмент: БУ после TP1, трейл EMA20-4h, watchdog TP1 ----------
  foreach ($t in $trades) {
    if ([string]$t.status -ne 'open') { continue }
    $bs = Bs $t.symbol
    if (-not $exBySym.ContainsKey($bs)) { continue }
    # 5a. БУ после TP1
    if ($t.tp1_done -and -not $t.be_done) {
      if ($DryRun) { LLog "WOULD move SL to BE: $($t.symbol) @$($t.entry_price)" }
      else {
        $inst = Get-InstrumentsInfo @($t.symbol) $instPath
        $beStr = Format-RoundToTick ([double]$t.entry_price) $inst[$t.symbol].tickSize
        try {
          [void](Set-StopLossPrice $t.symbol $beStr)
          $t.be_done = $true; $t.stop = [double]$beStr
          $script:events.Add("BE $($t.id) $($t.symbol) @$beStr")
          $script:jblocks.Add(("`r`n## {0} UTC — LIVE: стоп {1} {2} переведён в БУ @{3}`r`n" -f $nowStr, $t.id, $t.symbol, $beStr))
        } catch { LLog "BE move failed $($t.symbol): $($_.Exception.Message)" }
      }
    }
    # 5b. watchdog: TP1-ордер должен висеть, пока TP1 не исполнен
    if (-not $t.tp1_done -and [double]$t.tp1_qty -gt 0) {
      $tpLink = "$($t.id)-tp1"
      $tpAlive = @($exOrders | Where-Object { [string]$_.orderLinkId -eq $tpLink }).Count -gt 0
      $tpIntent = @($intents | Where-Object { $_.linkId -eq $tpLink }).Count -gt 0
      if (-not $tpAlive -and -not $tpIntent -and [double]$t.tp1_filled_qty -eq 0) {
        if ($DryRun) { LLog "WOULD re-place TP1: $tpLink" }
        else {
          $inst = Get-InstrumentsInfo @($t.symbol) $instPath
          $qtyStr = Format-FloorToStep ([double]$t.tp1_qty) $inst[$t.symbol].qtyStep
          $pxStr = Format-RoundToTick ([double]$t.tp1) $inst[$t.symbol].tickSize
          $it = [pscustomobject]@{ tradeId = $t.id; kind = 'tp1'; linkId = $tpLink; utc = $nowStr; ts = $nowMs }
          $intents.Add($it); $lp.pending_intents = ToArr $intents; Save-State
          $r = Place-Tp1Limit $t.symbol ([string]$t.side) $qtyStr $pxStr $tpLink
          [void]$intents.Remove($it)
          if ($r.ok) { LLog "TP1 re-placed $tpLink" } else { LLog "TP1 re-place failed ${tpLink}: $($r.retCode) $($r.retMsg)" }
        }
      }
    }
  }
  # 5c. трейл раннера по закрытию 4h за EMA20 (решение раз в 4h-бар)
  $closed4h = (FloorTo $nowMs $H4) - $H4
  if ([long]$lp.auto.last_trail_4h_ts -lt $closed4h) {
    $runners = @($trades | Where-Object { $_.tp1_done -and [string]$_.status -eq 'open' })
    $trailOk = $true
    foreach ($t in $runners) {
      $bs = Bs $t.symbol
      if (-not $exBySym.ContainsKey($bs)) { continue }
      try {
        $k4 = Get-Klines $t.symbol '240' ($nowMs - 420*$H4) $nowMs $nowMs
        if ($k4.Count -lt 30) { continue }
        $c4 = [double[]]@($k4 | ForEach-Object { $_.c })
        $ema = EMAseries $c4 20
        $li = $k4.Count - 1
        if ([long]$k4[$li].t -ne $closed4h) { LLog "trail: $($t.symbol) последний закрытый бар не совпал - отложено"; $trailOk = $false; continue }
        $e20 = [double]$ema[$li]
        if ([double]::IsNaN($e20)) { continue }
        $c = [double]$k4[$li].c
        $brk = if ([string]$t.side -eq 'long') { $c -lt $e20 } else { $c -gt $e20 }
        if ($brk) {
          if ($DryRun) { LLog "WOULD trail-close $($t.id) $($t.symbol): close=$c ema20=$([math]::Round($e20,6))" }
          else {
            $qtyStr = ([double]$exBySym[$bs].size).ToString([Globalization.CultureInfo]::InvariantCulture)
            $t.close_reason = 'trail-ema20'
            $it = [pscustomobject]@{ tradeId = $t.id; kind = 'close'; linkId = "$($t.id)-close"; utc = $nowStr; ts = $nowMs }
            $intents.Add($it); $lp.pending_intents = ToArr $intents; Save-State
            $r = Close-PositionMarket $t.symbol ([string]$t.side) $qtyStr "$($t.id)-close"
            [void]$intents.Remove($it)
            if ($r.ok) {
              $script:events.Add("TRAIL $($t.id) $($t.symbol)")
              $script:jblocks.Add(("`r`n## {0} UTC — LIVE: трейл-выход {1} {2}: закрытие 4h {3} за EMA20 {4}`r`n" -f $nowStr, $t.id, $t.symbol, $c, [math]::Round($e20,6)))
            } else { LLog "trail close failed $($t.id): $($r.retCode) $($r.retMsg)"; $t.close_reason = $null }
          }
        }
      } catch { LLog "trail check failed $($t.symbol): $($_.Exception.Message)"; $trailOk = $false }
    }
    if ($trailOk) { $lp.auto.last_trail_4h_ts = $closed4h }
  }

  # ---------- 6. входы: свежезакрытый 4h-бар + сканер v2 ----------
  # MUST mirror tools/auto_trade.ps1:388-443 (сайзинг/ворота) + лот-политика биржи
  if ([long]$lp.auto.last_4h_ts -lt $closed4h) {
    $entriesBlocked = ''
    if ($lp.trading_halted) { $entriesBlocked = 'trading_halted' }
    elseif ($haltLive) { $entriesBlocked = 'HALT_LIVE' }
    elseif ($haltClose) { $entriesBlocked = 'HALT_CLOSE' }
    elseif ([string]$lp.auto.halt_day_utc -eq $todayUtc) { $entriesBlocked = 'day-halt' }
    elseif ("$($lp.entries_halt_reason)" -ne '') { $entriesBlocked = [string]$lp.entries_halt_reason }
    if ($entriesBlocked) {
      $lp.auto.last_4h_ts = $closed4h
      LLog "entries blocked ($entriesBlocked) - бар потреблён"
    } else {
      $riskMult = if ($lp.auto.soft_dd) { 0.5 } else { 1.0 }
      $scanOk = $true
      $sigPath = Join-Path $liveDir 'signals.json'
      try {
        & (Join-Path $PSScriptRoot 'scan_signals.ps1') -Equity $equity -RiskPct ($RISKPCT * $riskMult) -OutPath $sigPath | Out-Null
      } catch { $scanOk = $false; LLog "scanner failed: $($_.Exception.Message)" }
      $sig = if ($scanOk) { Read-JsonFile $sigPath } else { $null }
      if ($sig -and $sig.closedBarUtc -and ((UtcStrToMs ([string]$sig.closedBarUtc)) -eq $closed4h)) {
        $lp.auto.last_4h_ts = $closed4h
        $sigList = @($sig.signals)
        LLog "scan 4h bar=$($sig.closedBarUtc): pass=$($sigList.Count), btc=$($sig.btcTrend) fng=$($sig.fng) flat=$(if($sig.flatBlockAll){'ON'}else{'off'})"
        if ($sigList.Count -gt 0) {
          $tickers = Get-TickersAll (@($sigList | ForEach-Object { $_.symbol }))
          foreach ($s in $sigList) {
            $openCnt = @($trades | Where-Object { [string]$_.status -in @('pending','open') }).Count
            if ($openCnt -ge $MAXPOS) { break }
            if ($EXCLUDED -contains $s.symbol) { continue }
            if (@($trades | Where-Object { $_.symbol -eq $s.symbol }).Count) { continue }
            if (-not $tickers.ContainsKey($s.symbol)) { continue }
            $sideMul = if ($s.side -eq 'long') { 1.0 } else { -1.0 }
            $fill = [double]$tickers[$s.symbol]
            $sigDist = [math]::Abs([double]$s.entry - [double]$s.stop)
            if ([math]::Abs($fill - [double]$s.entry) -gt 0.5 * $sigDist) {
              LLog "entry skipped (stale price) $($s.symbol): px=$fill sigEntry=$($s.entry)"
              continue
            }
            $stop = [double]$s.stop
            $stopDist = $sideMul * ($fill - $stop)
            if ($stopDist -le 0) { continue }
            $riskUsd = [math]::Round($equity * $RISKPCT * $riskMult, 2)
            $qty = $riskUsd / $stopDist
            $maxNotional = $MAXLEV * $equity
            if (($qty * $fill) -gt $maxNotional) { $qty = $maxNotional / $fill }

            # --- лот-политика биржи ---
            $inst = (Get-InstrumentsInfo @($s.symbol) $instPath)[$s.symbol]
            $qtyStr = Format-FloorToStep $qty $inst.qtyStep
            $qtyF = [double]::Parse($qtyStr, [Globalization.CultureInfo]::InvariantCulture)
            $minQ = [double]::Parse($inst.minOrderQty, [Globalization.CultureInfo]::InvariantCulture)
            $needQty = 2.0 * $minQ   # половина TP1 сама должна быть >= minOrderQty
            if ($qtyF -lt $needQty -or ($qtyF * $fill) -lt $inst.minNotional) {
              $qtyUp = [math]::Max($needQty, $inst.minNotional / $fill)
              $qtyUpStr = Format-FloorToStep ($qtyUp + [double]::Parse($inst.qtyStep,[Globalization.CultureInfo]::InvariantCulture)) $inst.qtyStep
              $qtyUpF = [double]::Parse($qtyUpStr, [Globalization.CultureInfo]::InvariantCulture)
              $risk2 = $qtyUpF * $stopDist
              if ($risk2 -le 1.5 * $riskUsd -and ($qtyUpF * $fill) -le $maxNotional) {
                $qtyStr = $qtyUpStr; $qtyF = $qtyUpF
                LLog "entry $($s.symbol): qty округлён вверх до $qtyStr (риск $([math]::Round($risk2,2))$ <= 1.5x)"
              } else {
                LLog "skipped-minlot $($s.symbol): qty=$qtyF < 2xminQ=$needQty или notional < $($inst.minNotional)"
                $script:jblocks.Add(("`r`n## {0} UTC — LIVE: сигнал {1} {2} пропущен (skipped-minlot: qty {3} при min {4})`r`n" -f $nowStr, $s.symbol, $s.side, $qtyF, $minQ))
                continue
              }
            }
            $halfStr = Format-FloorToStep ($qtyF / 2.0) $inst.qtyStep
            $halfF = [double]::Parse($halfStr, [Globalization.CultureInfo]::InvariantCulture)
            if ($halfF -lt $minQ) { LLog "skipped-minlot $($s.symbol): half=$halfF < minQ=$minQ"; continue }
            $slStr = Format-RoundToTick $stop $inst.tickSize
            $tp1 = $fill + $sideMul * $TPR * $stopDist
            $tp1Str = Format-RoundToTick $tp1 $inst.tickSize
            $realRisk = [math]::Round($qtyF * $stopDist, 2)

            if ($DryRun) {
              LLog "WOULD PLACE: $($s.symbol) $($s.side) qty=$qtyStr sl=$slStr tp1=$tp1Str@$halfStr risk=$realRisk$ notional=$([math]::Round($qtyF*$fill,2))$"
              [void](Send-TgAlert "[DRYRUN] Вход БЫ: $($s.symbol) $($s.side) qty=$qtyStr стоп=$slStr TP1=$tp1Str риск=$realRisk$")
              continue
            }

            # --- плечо (один раз на символ) ---
            if (@($lp.auto.leverage_set) -notcontains $s.symbol) {
              try { [void](Set-LeverageSafe $s.symbol $MAXLEV); $lp.auto.leverage_set = ToArr (@($lp.auto.leverage_set) + $s.symbol) }
              catch { LLog "set-leverage failed $($s.symbol): $($_.Exception.Message)"; continue }
            }

            # --- write-ahead: id + карточка + интент ДО вызова API ---
            $id = "LT$($lp.auto.next_trade_id)"; $lp.auto.next_trade_id = [int]$lp.auto.next_trade_id + 1
            $thesis = [pscustomobject]@{
              setup = 'A — трендовый откат (LIVE v2, все 6 ворот пройдены)'
              regime = "BTC 4h $($sig.btcTrend); $($s.symbol) 4h $($s.trend); F&G $($sig.fng)"
              riskPlan = "вход ~$fill, стоп $slStr ($($s.stopPct)%), TP1 $tp1Str (1.5R, 50%), затем БУ + трейл EMA20 4h; риск `$$realRisk"
              checks = $s.checks
            }
            $t = [pscustomobject]@{
              id = $id; symbol = $s.symbol; side = $s.side; status = 'pending'
              qty = $qtyF; qty_initial = $qtyF; entry_filled_qty = 0.0
              entry_price = $fill; stop = [double]$slStr; stop0 = [double]$slStr
              tp1 = [double]$tp1Str; tp1_qty = $halfF; tp1_filled_qty = 0.0
              tp1_done = $false; be_done = $false; close_reason = $null; sl_exec = $false
              entry_utc = $nowStr; entry_ts = $nowMs
              risk_usd = $realRisk; notional_usd = [math]::Round($qtyF * $fill, 2)
              fees_usd = 0.0; funding_usd = 0.0; legs = @()
              thesis = $thesis
            }
            $trades.Add($t)
            $it = [pscustomobject]@{ tradeId = $id; kind = 'entry'; linkId = "$id-entry"; utc = $nowStr; ts = $nowMs }
            $intents.Add($it)
            $lp.open_trades = ToArr $trades; $lp.pending_intents = ToArr $intents
            Save-State

            $r = Place-MarketEntry $s.symbol ([string]$s.side) $qtyStr $slStr "$id-entry"
            [void]$intents.Remove($it)
            if (-not $r.ok) {
              [void]$trades.Remove($t)
              LLog "entry rejected $($s.symbol): $($r.retCode) $($r.retMsg)"
              [void](Send-TgAlert "[$modeTag] Вход $($s.symbol) отклонён: retCode=$($r.retCode) $($r.retMsg)")
              continue
            }
            $script:events.Add("ENTRY $id $($s.symbol) $($s.side)")
            $script:jblocks.Add(("`r`n## {0} UTC — LIVE: ВХОД {1} {2} {3} (маркет)`r`n" -f $nowStr, $id, $s.symbol, ([string]$s.side).ToUpper()) +
              ("qty {0}, стоп {1} ({2}%), TP1 {3} (1.5R, {4}), риск {5}$, номинал {6}$. Режим: BTC {7}, F&G {8}.`r`n" -f $qtyStr, $slStr, $s.stopPct, $tp1Str, $halfStr, $realRisk, [math]::Round($qtyF*$fill,2), $sig.btcTrend, $sig.fng))

            # --- TP1 reduce-only limit ---
            $it2 = [pscustomobject]@{ tradeId = $id; kind = 'tp1'; linkId = "$id-tp1"; utc = $nowStr; ts = $nowMs }
            $intents.Add($it2)
            $lp.pending_intents = ToArr $intents
            Save-State
            $r2 = Place-Tp1Limit $s.symbol ([string]$s.side) $halfStr $tp1Str "$id-tp1"
            [void]$intents.Remove($it2)
            if (-not $r2.ok) { LLog "TP1 place failed $id ($($r2.retCode) $($r2.retMsg)) - watchdog повторит" }
          }
        }
      } elseif ($scanOk) {
        LLog "scanner bar mismatch: want $(MsToUtcStr $closed4h), got $($sig.closedBarUtc) - retry next tick"
      }
    }
  }

  # ---------- 7. персист ----------
  $lp.open_trades = ToArr $trades
  $lp.pending_intents = ToArr $intents
  $lp.equity_usd = $equity
  $lp.auto.last_tick_utc = $nowStr

  if ($script:closedCards.Count -gt 0) {
    $lt = Read-JsonFile $ltPath
    $ltArr = New-Object System.Collections.Generic.List[object]
    foreach ($x in @($lt)) { if ($null -ne $x) { $ltArr.Add($x) } }
    $have = @{}; foreach ($x in $ltArr) { $have[[string]$x.id] = $true }
    foreach ($c in $script:closedCards) { if (-not $have.ContainsKey([string]$c.id)) { $ltArr.Add($c) } }
    Write-JsonAtomic $ltPath (ToArr $ltArr) 12
  }
  Save-State

  # точка эквити: при событиях или раз в 15 минут
  $minuteOfHour = [int]((MsToUtc $nowMs).Minute)
  if ($script:events.Count -gt 0 -or ($minuteOfHour % 15) -eq 0) {
    $le = @(); $leRaw = Read-JsonFile $lePath
    if ($leRaw) { $le = @($leRaw | ForEach-Object { $_ }) }
    $lastUtc = if ($le.Count) { [string]$le[-1].utc } else { $null }
    if ($lastUtc -ne $nowStr) {
      $le += [pscustomobject]@{ utc = $nowStr; ts = $nowMs; eq = $equity }
      Write-JsonAtomic $lePath (ToArr $le) 4
    }
  }
  if ($script:jblocks.Count -gt 0) {
    [IO.File]::AppendAllText($jrnPath, ($script:jblocks -join ''), (New-Object System.Text.UTF8Encoding($false)))
  }
  if ($script:events.Count -gt 0) {
    [IO.File]::WriteAllText($pushFlag, $nowStr, (New-Object System.Text.UTF8Encoding($false)))
  }
  $evTxt = if ($script:events.Count) { $script:events -join '; ' } else { '-' }
  LLog "ok [$modeTag] $([math]::Round($sw.Elapsed.TotalSeconds,1))s events: $evTxt | eq=$equity pos=$($trades.Count)"
} catch {
  LLog ("TICK ERROR: " + $_.Exception.Message + ' @ ' + ("$($_.ScriptStackTrace)" -split "`n")[0])
  try {
    if ($null -ne $script:lp) {
      $script:lp.auto.consec_api_fail = [int]$script:lp.auto.consec_api_fail + 1
      if ([int]$script:lp.auto.consec_api_fail -eq 5) { [void](Send-TgAlert "[$modeTag] 5 тиков подряд падают: $($_.Exception.Message)") }
      Save-State
    }
  } catch {}
}
