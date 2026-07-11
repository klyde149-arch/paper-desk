# auto_trade.ps1 - автономный тик-движок paper-trading (v2 «комбо»), 24/7.
# Запускается каждые ~15 мин (GitHub Actions / вручную). Делает ВСЁ, что раньше делал агент:
#   1) реплей закрытых 1m-свечей с прошлого тика: стопы/TP1 ПО КАСАНИЮ, фандинг на 8h-слотах,
#      трейл раннера по закрытию 4h за EMA20, лимиты −5%/−16%/−35% (профиль 1%/3поз), роллы UTC-дня;
#   2) автовходы на свежезакрытом 4h-баре через scan_signals.ps1 (все ворота v2);
#   3) персист portfolio.json / data\live_trades.json / data\live_equity.json / journal.md;
#   4) отдельный контур челленджа (challenge\, замороженные правила S4).
# Fail-safe: любой сбой API => тик отменяется целиком, вотермарки не двигаются, позиции не трогаются.
# Килл-свитч: файл data\HALT. Правила: docs\strategy\strategy.md (v2). Кодировка файла: UTF-8 c BOM (кириллица).
param(
  [switch]$Cloud,          # запуск в GitHub Actions (сейчас только маркер для лога)
  [switch]$DryRun,         # посчитать и напечатать, НИЧЕГО не записывать
  [string]$SimNow = '',    # 'yyyy-MM-dd HH:mm' UTC - подмена часов (тесты/реплей)
  [string]$Root = '',      # корень проекта (по умолчанию - родитель папки tools)
  [switch]$SkipChallenge,
  [switch]$SkipRf,         # пропустить контур рынка РФ (C2/C3b)
  [switch]$SkipViz,
  [switch]$Force           # игнорировать lock-файл
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'lib_engine.ps1')

# ---- константы (docs\strategy\strategy.md v2, комиссии Bybit) ----
$FEE      = 0.00055   # тейкер за сторону (включая TP1 - консервативно)
$SLIP     = 0.0003    # слиппедж рыночных входов/выходов
$STOPSLIP = 0.0005    # доп. слиппедж на стопах
$RISKPCT  = 0.01      # риск на сделку 1% (решение пользователя 2026-07-10: самый прибыльный профиль, PF 1.38)
$MAXPOS   = 3         # 3 слота улучшают PF (1.29->1.38): третий подбирает сигналы, которые раньше терялись
$MAXLEV   = 5
$TPR      = 1.5       # TP1 = 1.5R (закрыть 50%)
$MIN=[long]60000; $H1=[long]3600000; $H4=[long]14400000; $SLOT8=[long]28800000
$EXCLUDED = @('DOGE-USDT')

# ---- челлендж (challenge\strategy.md - ЗАМОРОЖЕНО, менять нельзя) ----
$CH_FEE=0.0005; $CH_SLIP=0.0003; $CH_STOPSLIP=0.0005; $CH_RISK=0.10; $CH_LEV=15
$CH_MMR=0.005; $CH_LIQSAFE=0.8; $CH_MARGINCAP=0.9; $CH_HOLD_MS=[long]48*$H1

$haltPath = Join-Path $Root 'data\HALT'
if (Test-Path $haltPath) { Write-TickLog $Root 'skip: HALT file present'; 'HALT активен - тик пропущен'; return }

$lock = $null
if (-not $DryRun) {
  $lock = Acquire-EngineLock $Root -Force:$Force
  if ($null -eq $lock) { Write-TickLog $Root 'skip: locked'; 'другой тик уже выполняется - пропуск'; return }
}

$nowMs = if ($SimNow) { UtcStrToMs $SimNow } else { UtcNowMs }
$nowStr = MsToUtcStr $nowMs
$sw = [Diagnostics.Stopwatch]::StartNew()

$script:events        = New-Object System.Collections.Generic.List[string]
$script:journalBlocks = New-Object System.Collections.Generic.List[string]
$script:closedTrades  = New-Object System.Collections.Generic.List[object]
$script:pf = $null

# ================= helpers (main contour) =================

function Ensure-Prop($obj, [string]$name, $default) {
  if (-not $obj.PSObject.Properties[$name]) { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $default }
}

function New-AutoState([long]$initTs1m, [long]$init4h, [int]$nextId) {
  [pscustomobject]@{
    schema = 1; engine = 'v2-combo'
    last_1m_ts = $initTs1m; last_4h_ts = $init4h
    halt_day_utc = $null; soft_dd = $false
    next_trade_id = $nextId; ticks_since_viz = 0
    last_daily_summary_day = ''; last_tick_utc = ''
  }
}

# закрыть часть позиции: правит баланс/комиссии/ноги, возвращает gross-P&L ноги
function Add-Leg($p, [string]$part, [double]$qty, [double]$px, [long]$ts) {
  $sideMul = if ($p.side -eq 'long') { 1.0 } else { -1.0 }
  $gross = $sideMul * $qty * ($px - [double]$p.entry_price)
  $fee = $qty * $px * $FEE
  $script:pf.balance_usd = [double]$script:pf.balance_usd + $gross - $fee
  $p.fees_usd = [double]$p.fees_usd + $fee
  $leg = [pscustomobject]@{ part=$part; qty=[math]::Round($qty,6); price=[math]::Round($px,6); utc=(MsToUtcStr $ts); pnl=[math]::Round($gross,2) }
  $p.legs = ToArr (@($p.legs) + $leg)
  return $gross
}

# полное закрытие: нога + карточка в леджер + статистика + журнал
function Close-Trade($p, [double]$px, [long]$ts, [string]$part, [string]$reason) {
  [void](Add-Leg $p $part ([double]$p.qty) $px $ts)
  $legs = @($p.legs)
  $grossSum = 0.0; $qtySum = 0.0; $pxWeighted = 0.0
  foreach ($lg in $legs) { $grossSum += [double]$lg.pnl; $qtySum += [double]$lg.qty; $pxWeighted += [double]$lg.qty * [double]$lg.price }
  $exitAvg = if ($qtySum -gt 0) { $pxWeighted / $qtySum } else { $px }
  $fees = [double]$p.fees_usd            # вход + все выходы
  $funding = [double]$p.funding_usd      # cost-signed: >0 = заплачено
  $net = [math]::Round($grossSum - $fees - $funding, 2)
  $risk = [double]$p.risk_usd
  $rec = [pscustomobject]@{
    id = $p.id; sym = $p.symbol; side = $p.side
    result = if ($net -gt 0) { 'win' } else { 'loss' }
    entryUtc = $p.entry_utc; entryDay = ($p.entry_utc -split ' ')[0]; entryTs = [long]$p.entry_ts
    entry = [double]$p.entry_price; qty = [double]$p.qty_initial
    exitUtc = (MsToUtcStr $ts); exitDay = (MsToUtcDay $ts); exitTs = $ts
    exitPx = [math]::Round($exitAvg, 6); exitReason = $reason
    legs = ToArr $legs
    pnlUsd = $net
    rMultiple = if ($risk -gt 0) { [math]::Round($net / $risk, 2) } else { $null }
    riskUsd = $risk
    fees = [math]::Round($fees, 2); funding = [math]::Round($funding, 2)
    mfePx = [double]$p.mfe_px; maePx = [double]$p.mae_px
    thesis = $p.thesis
  }
  $script:closedTrades.Add($rec)
  $st = $script:pf.stats
  $st.closed_trades = [int]$st.closed_trades + 1
  if ($net -gt 0) { $st.wins = [int]$st.wins + 1 } else { $st.losses = [int]$st.losses + 1 }
  $st.total_fees_usd = [math]::Round([double]$st.total_fees_usd + $fees, 2)
  $st.total_funding_usd = [math]::Round([double]$st.total_funding_usd + $funding, 2)
  $st.realized_pnl_usd = [math]::Round([double]$st.realized_pnl_usd + $net, 2)
  $resTxt = if ($net -gt 0) { 'ПРИБЫЛЬ' } else { 'УБЫТОК' }
  $script:events.Add("EXIT $($p.id) $($p.symbol) $reason $net USD")
  $script:journalBlocks.Add(("`r`n## {0} UTC — АВТО: закрыта {1} {2} {3} — {4} {5:+0.00;-0.00}$ ({6})`r`n" -f (MsToUtcStr $ts), $p.id, $p.symbol, $p.side.ToUpper(), $resTxt, $net, $reason) +
    ("Вход {0} → средний выход {1}; R = {2}; комиссии {3}$, фандинг {4}$. Ноги: {5}.`r`n" -f $p.entry_price, [math]::Round($exitAvg,6), $rec.rMultiple, [math]::Round($fees,2), [math]::Round($funding,2), (@($legs | ForEach-Object { "$($_.part) $($_.qty)@$($_.price)" }) -join ', ')))
}

# ================= MAIN =================
try {
  $pfPath = Join-Path $Root 'portfolio.json'
  $script:pf = Read-JsonFile $pfPath
  if ($null -eq $script:pf) { throw 'portfolio.json не найден' }
  $pf = $script:pf

  # --- init auto-state / поля позиций (первый запуск) ---
  $positions = New-Object System.Collections.Generic.List[object]
  foreach ($p in @($pf.open_positions)) {
    Ensure-Prop $p 'qty_initial' ([double]$p.qty)
    Ensure-Prop $p 'stop0' ([double]$p.stop)
    Ensure-Prop $p 'tp1_done' $false
    Ensure-Prop $p 'entry_ts' (UtcStrToMs ([string]$p.entry_utc))
    Ensure-Prop $p 'fees_usd' 0.0     # накопленные комиссии сделки (вход+выходы)
    Ensure-Prop $p 'funding_usd' 0.0  # cost-signed фандинг
    Ensure-Prop $p 'legs' @()
    Ensure-Prop $p 'mfe_px' ([double]$p.entry_price)
    Ensure-Prop $p 'mae_px' ([double]$p.entry_price)
    $positions.Add($p)
  }
  if (-not $pf.PSObject.Properties['auto']) {
    $maxId = 1
    $ltRaw = Read-JsonFile (Join-Path $Root 'data\live_trades.json')
    foreach ($t in @($ltRaw)) { if ($t -and $t.id -match '^T(\d+)$') { $n = [int]$Matches[1]; if ($n -ge $maxId) { $maxId = $n } } }
    foreach ($p in $positions) { if ($p.id -match '^T(\d+)$') { $n = [int]$Matches[1]; if ($n -ge $maxId) { $maxId = $n } } }
    $initTs = if ($positions.Count) { UtcStrToMs ([string]$pf.last_check_utc) } else { (FloorTo $nowMs $MIN) - $MIN }
    $pf | Add-Member -NotePropertyName auto -NotePropertyValue (New-AutoState $initTs ((FloorTo $nowMs $H4) - 2*$H4) ($maxId + 1))
    Write-TickLog $Root "auto-state initialized (last_1m_ts=$initTs)"
  }
  Ensure-Prop $pf.auto 'halt_day_utc' $null
  Ensure-Prop $pf.auto 'soft_dd' $false
  Ensure-Prop $pf.auto 'last_daily_summary_day' ''

  $lastClosed1m = (FloorTo $nowMs $MIN) - $MIN
  $mgmtOk = $true
  $lastPx = @{}   # последняя известная цена по символу (для MTM)

  # ---------- 1. МЕНЕДЖМЕНТ: реплей 1m-свечей ----------
  if ($positions.Count -gt 0) {
    $startMs = [long]$pf.auto.last_1m_ts + $MIN
    if ($startMs -le $lastClosed1m) {
      $syms = @($positions | ForEach-Object { $_.symbol } | Sort-Object -Unique)
      $cmap = @{}; $fmap = @{}; $e4 = @{}
      $processedUpTo = $lastClosed1m
      try {
        foreach ($sym in $syms) {
          $k = Get-Klines $sym '1' $startMs ($lastClosed1m + $MIN) $nowMs
          if ($k.Count -eq 0) { throw "нет 1m-свечей $sym" }
          $m = @{}; foreach ($b in $k) { $m[[long]$b.t] = $b }
          $cmap[$sym] = $m
          $lastSymTs = [long]$k[$k.Count - 1].t
          if ($lastSymTs -lt $processedUpTo) { $processedUpTo = $lastSymTs }  # фид отстаёт - обработаем до общего минимума
          $fmap[$sym] = Get-FundingMap $sym ($startMs - $SLOT8) $nowMs
          # 4h-серия для трейла EMA20 (закрытые бары)
          $k4 = Get-Klines $sym '240' ($nowMs - 420 * $H4) $nowMs $nowMs
          if ($k4.Count -ge 30) {
            $c4 = [double[]]@($k4 | ForEach-Object { $_.c })
            $ema = EMAseries $c4 20
            $eh = @{}
            for ($i = 0; $i -lt $k4.Count; $i++) { $eh[[long]$k4[$i].t] = $ema[$i] }
            $e4[$sym] = $eh
          } else { $e4[$sym] = @{} }
        }
      } catch {
        $mgmtOk = $false
        Write-TickLog $Root "MGMT ABORT (данные недоступны): $($_.Exception.Message)"
        Write-Warning "менеджмент отменён (fail-safe): $($_.Exception.Message)"
      }

      if ($mgmtOk -and $processedUpTo -ge $startMs) {
        $lastMtm = [double]$pf.equity_usd
        for ($ts = $startMs; $ts -le $processedUpTo; $ts += $MIN) {
          # --- ролл UTC-дня ---
          $tsDay = MsToUtcDay $ts
          if ($tsDay -ne [string]$pf.day_start_date_utc) {
            $prevDay = [string]$pf.day_start_date_utc
            if ($pf.auto.last_daily_summary_day -ne $prevDay) {
              $dpl = $lastMtm - [double]$pf.day_start_equity_usd
              $dplPct = if ([double]$pf.day_start_equity_usd -gt 0) { 100.0 * $dpl / [double]$pf.day_start_equity_usd } else { 0 }
              $script:journalBlocks.Add(("`r`n## {0} 00:00 UTC — авто-сводка дня {1}: equity {2}$, P&L дня {3:+0.00;-0.00}$ ({4:+0.00;-0.00}%), позиций {5}`r`n" -f $tsDay, $prevDay, [math]::Round($lastMtm,2), $dpl, $dplPct, $positions.Count))
              $pf.auto.last_daily_summary_day = $prevDay
            }
            $pf.day_start_equity_usd = [math]::Round($lastMtm, 2)
            $pf.day_start_date_utc = $tsDay
            $pf.auto.halt_day_utc = $null
          }

          # --- позиции ---
          foreach ($p in $positions.ToArray()) {
            $sym = $p.symbol
            if (-not $cmap[$sym].ContainsKey($ts)) { continue }
            $b = $cmap[$sym][$ts]
            if (($ts + $MIN) -le [long]$p.entry_ts) { continue }   # свеча целиком до входа
            $lastPx[$sym] = [double]$b.c
            $sideMul = if ($p.side -eq 'long') { 1.0 } else { -1.0 }

            # 1) фандинг на 8h-границе (по цене open, реальная ставка)
            if (($ts % $SLOT8) -eq 0 -and $ts -ge [long]$p.entry_ts) {
              $rate = Get-FundingRateAt $fmap[$sym] $ts 0.0001
              $pay = [double]$p.qty * [double]$b.o * $rate
              if ($p.side -eq 'long') { $pf.balance_usd = [double]$pf.balance_usd - $pay; $p.funding_usd = [double]$p.funding_usd + $pay }
              else { $pf.balance_usd = [double]$pf.balance_usd + $pay; $p.funding_usd = [double]$p.funding_usd - $pay }
            }

            # 2) СТОП по касанию (приоритет; gap-aware)
            $stop = [double]$p.stop
            $hitStop = if ($p.side -eq 'long') { [double]$b.l -le $stop } else { [double]$b.h -ge $stop }
            if ($hitStop) {
              $base = if ($p.side -eq 'long') { if ([double]$b.o -lt $stop) { [double]$b.o } else { $stop } }
                      else { if ([double]$b.o -gt $stop) { [double]$b.o } else { $stop } }
              $fill = $base * (1 - $sideMul * $STOPSLIP)
              $reason = if ($p.tp1_done) { 'be-stop' } else { 'stop' }
              $part = if ($p.tp1_done) { 'runner-be' } else { 'stop' }
              Close-Trade $p $fill $ts $part $reason
              [void]$positions.Remove($p)
              continue
            }

            # 3) TP1 по касанию (лимит по цене уровня, комиссия тейкера - консервативно)
            if (-not $p.tp1_done) {
              $tp1 = [double]$p.tp1
              $hitTp = if ($p.side -eq 'long') { [double]$b.h -ge $tp1 } else { [double]$b.l -le $tp1 }
              if ($hitTp) {
                $half = [double]$p.qty_initial * 0.5
                if ($half -gt [double]$p.qty) { $half = [double]$p.qty }
                [void](Add-Leg $p 'TP1' $half $tp1 $ts)
                $p.qty = [math]::Round([double]$p.qty - $half, 6)
                $p.tp1_done = $true
                $p.stop = [double]$p.entry_price   # безубыток
                $script:events.Add("TP1 $($p.id) $($p.symbol)")
                $script:journalBlocks.Add(("`r`n## {0} UTC — АВТО: TP1 по {1} {2} — закрыто 50% @{3}, стоп в БУ {4}`r`n" -f (MsToUtcStr $ts), $p.id, $p.symbol, $tp1, $p.entry_price))
              }
            }

            # 4) трейл раннера: закрытие 4h-бара за EMA20 (правило стратегии)
            if ($p.tp1_done -and ((($ts + $MIN) % $H4) -eq 0)) {
              $ob = $ts + $MIN - $H4
              if ($e4[$sym].ContainsKey($ob)) {
                $e20 = [double]$e4[$sym][$ob]
                if (-not [double]::IsNaN($e20)) {
                  $c4 = [double]$b.c
                  $brk = if ($p.side -eq 'long') { $c4 -lt $e20 } else { $c4 -gt $e20 }
                  if ($brk) {
                    $fill = $c4 * (1 - $sideMul * $SLIP)
                    Close-Trade $p $fill $ts 'runner' 'trail-ema20'
                    [void]$positions.Remove($p)
                    continue
                  }
                }
              }
            }

            # 5) MFE/MAE
            if ($p.side -eq 'long') {
              if ([double]$b.h -gt [double]$p.mfe_px) { $p.mfe_px = [double]$b.h }
              if ([double]$b.l -lt [double]$p.mae_px) { $p.mae_px = [double]$b.l }
            } else {
              if ([double]$b.l -lt [double]$p.mfe_px) { $p.mfe_px = [double]$b.l }
              if ([double]$b.h -gt [double]$p.mae_px) { $p.mae_px = [double]$b.h }
            }
          }

          # --- MTM + лимиты (по закрытиям минуты) ---
          $mtm = [double]$pf.balance_usd
          foreach ($p in $positions) {
            $px = if ($lastPx.ContainsKey($p.symbol)) { [double]$lastPx[$p.symbol] } else { [double]$p.entry_price }
            $sm = if ($p.side -eq 'long') { 1.0 } else { -1.0 }
            $mtm += $sm * [double]$p.qty * ($px - [double]$p.entry_price)
          }
          $lastMtm = $mtm
          if ($mtm -gt [double]$pf.peak_equity_usd) { $pf.peak_equity_usd = [math]::Round($mtm, 2) }
          $dd = ([double]$pf.peak_equity_usd - $mtm) / [double]$pf.peak_equity_usd
          if ($dd -ge 0.35 -and $positions.Count -gt 0) {   # хард-стоп −35% (профиль 1%/3поз, историч. DD ~34%)
            foreach ($p in $positions.ToArray()) {
              $px = if ($lastPx.ContainsKey($p.symbol)) { [double]$lastPx[$p.symbol] } else { [double]$p.entry_price }
              $sm = if ($p.side -eq 'long') { 1.0 } else { -1.0 }
              Close-Trade $p ($px * (1 - $sm * $SLIP)) $ts 'hard-halt' 'hard-halt-35pct'
              [void]$positions.Remove($p)
            }
            $pf.trading_halted = $true
            $script:events.Add('HARD-HALT −35% от пика')
            $script:journalBlocks.Add(("`r`n## {0} UTC — АВТО: ЖЁСТКАЯ ОСТАНОВКА −35% от пика. Все позиции закрыты, торговля остановлена до решения пользователя.`r`n" -f (MsToUtcStr $ts)))
            $pf.auto.last_1m_ts = $ts
            break
          }
          if ($dd -ge 0.16) {
            if (-not $pf.auto.soft_dd) { $pf.auto.soft_dd = $true; $script:events.Add('SOFT-DD −16%: риск x0.5'); $script:journalBlocks.Add(("`r`n## {0} UTC — АВТО: просадка ≥16% от пика — риск новых входов снижен вдвое (0.5%).`r`n" -f (MsToUtcStr $ts))) }
          } elseif ($dd -lt 0.12 -and $pf.auto.soft_dd) {
            $pf.auto.soft_dd = $false
            $script:events.Add('SOFT-DD снят (<6%)')
          }
          $dayBase = [double]$pf.day_start_equity_usd
          if ($dayBase -gt 0 -and (($mtm - $dayBase) / $dayBase) -le -0.05 -and $pf.auto.halt_day_utc -ne $tsDay) {
            $pf.auto.halt_day_utc = $tsDay
            $script:events.Add("DAY-HALT −5% ($tsDay)")
            $script:journalBlocks.Add(("`r`n## {0} UTC — АВТО: дневной лимит −5% достигнут — новые входы заблокированы до следующего UTC-дня.`r`n" -f (MsToUtcStr $ts)))
          }
          $pf.auto.last_1m_ts = $ts
        }
        $pf.equity_usd = [math]::Round($lastMtm, 2)
      }
    }
  } else {
    # позиций нет: ролл дня по часам + сдвиг вотермарка
    $todayNow = MsToUtcDay $nowMs
    if ($todayNow -ne [string]$pf.day_start_date_utc) {
      $prevDay = [string]$pf.day_start_date_utc
      if ($pf.auto.last_daily_summary_day -ne $prevDay) {
        $dpl = [double]$pf.equity_usd - [double]$pf.day_start_equity_usd
        $dplPct = if ([double]$pf.day_start_equity_usd -gt 0) { 100.0 * $dpl / [double]$pf.day_start_equity_usd } else { 0 }
        $script:journalBlocks.Add(("`r`n## {0} UTC — авто-сводка дня {1}: equity {2}$, P&L дня {3:+0.00;-0.00}$ ({4:+0.00;-0.00}%), позиций 0`r`n" -f $nowStr, $prevDay, [math]::Round([double]$pf.equity_usd,2), $dpl, $dplPct))
        $pf.auto.last_daily_summary_day = $prevDay
      }
      $pf.day_start_equity_usd = [math]::Round([double]$pf.equity_usd, 2)
      $pf.day_start_date_utc = $todayNow
      $pf.auto.halt_day_utc = $null
    }
    $pf.auto.last_1m_ts = $lastClosed1m
    $pf.equity_usd = [math]::Round([double]$pf.balance_usd, 2)
  }

  # ---------- 2. ВХОДЫ: свежезакрытый 4h-бар + сканер v2 ----------
  $closed4h = (FloorTo $nowMs $H4) - $H4
  $todayUtc = MsToUtcDay $nowMs
  if ($mgmtOk -and [long]$pf.auto.last_4h_ts -lt $closed4h) {
    if ($pf.trading_halted -or $pf.auto.halt_day_utc -eq $todayUtc) {
      $pf.auto.last_4h_ts = $closed4h   # бар «потреблён» без входов (халт)
    } else {
      $riskMult = if ($pf.auto.soft_dd) { 0.5 } else { 1.0 }
      $scanOk = $true
      try {
        & (Join-Path $PSScriptRoot 'scan_signals.ps1') -Equity ([math]::Round([double]$pf.equity_usd,2)) -RiskPct ($RISKPCT * $riskMult) | Out-Null
      } catch { $scanOk = $false; Write-TickLog $Root "scanner failed: $($_.Exception.Message)" }
      $sig = if ($scanOk) { Read-JsonFile (Join-Path $Root 'data\signals.json') } else { $null }
      if ($sig -and $sig.closedBarUtc -and ((UtcStrToMs ([string]$sig.closedBarUtc)) -eq $closed4h)) {
        $pf.auto.last_4h_ts = $closed4h
        $sigList = @($sig.signals)
        if ($sigList.Count -gt 0) {
          $tickers = Get-TickersAll (@($sigList | ForEach-Object { $_.symbol }))
          foreach ($s in $sigList) {
            if ($positions.Count -ge $MAXPOS) { break }
            if ($EXCLUDED -contains $s.symbol) { continue }
            if (@($positions | Where-Object { $_.symbol -eq $s.symbol }).Count) { continue }
            if (-not $tickers.ContainsKey($s.symbol)) { continue }
            $sideMul = if ($s.side -eq 'long') { 1.0 } else { -1.0 }
            $fill = [double]$tickers[$s.symbol] * (1 + $sideMul * $SLIP)
            $sigDist = [math]::Abs([double]$s.entry - [double]$s.stop)
            if ([math]::Abs($fill - [double]$s.entry) -gt 0.5 * $sigDist) {
              Write-TickLog $Root "entry skipped (stale price) $($s.symbol): fill=$fill sigEntry=$($s.entry)"
              continue
            }
            $stop = [double]$s.stop
            $stopDist = $sideMul * ($fill - $stop)
            if ($stopDist -le 0) { continue }
            $riskUsd = [math]::Round([double]$pf.equity_usd * $RISKPCT * $riskMult, 2)
            $qty = $riskUsd / $stopDist
            $maxNotional = $MAXLEV * [double]$pf.equity_usd
            if (($qty * $fill) -gt $maxNotional) { $qty = $maxNotional / $fill }
            $qty = [math]::Round($qty, 4)
            if ($qty -le 0) { continue }
            $tp1 = $fill + $sideMul * $TPR * $stopDist
            $entryFee = $qty * $fill * $FEE
            $pf.balance_usd = [double]$pf.balance_usd - $entryFee
            $id = "T$($pf.auto.next_trade_id)"; $pf.auto.next_trade_id = [int]$pf.auto.next_trade_id + 1
            $thesis = [pscustomobject]@{
              setup = 'A — трендовый откат (АВТОВХОД v2, все 6 ворот пройдены)'
              regime = "BTC 4h $($sig.btcTrend); $($s.symbol) 4h $($s.trend); F&G $($sig.fng)"
              structure = "откат к зоне EMA20–50 4h, триггер-бар на закрытии $($sig.closedBarUtc) UTC"
              indicators = "RSI $($s.rsi), ATR $($s.atrPct)% (кэп 3%), фандинг $($s.funding8h)/8ч"
              trigger = 'закрытый 4h-бар: возврат за EMA20 после отката (сетап A)'
              riskPlan = "вход ~$([math]::Round($fill,6)), стоп $stop ($($s.stopPct)%), TP1 $([math]::Round($tp1,6)) = 1.5R (закрыть 50%), затем БУ + трейл EMA20 4h; риск `$$riskUsd"
              invalidation = 'касание стопа (по 1m); слом структуры отменяет раннер по закрытию 4h за EMA20'
              checks = $s.checks
            }
            $pos = [pscustomobject]@{
              id = $id; symbol = $s.symbol; side = $s.side
              qty = $qty; qty_initial = $qty
              entry_price = [math]::Round($fill, 6)
              stop = $stop; stop0 = $stop
              tp1 = [math]::Round($tp1, 6)
              entry_utc = $nowStr; entry_ts = $nowMs
              risk_usd = $riskUsd
              notional_usd = [math]::Round($qty * $fill, 2)
              runner_plan = 'TP1 1.5R закрыть 50% → стоп в БУ → трейл: выход по закрытию 4h за EMA20'
              tp1_done = $false; fees_usd = $entryFee; funding_usd = 0.0
              legs = @(); mfe_px = [math]::Round($fill, 6); mae_px = [math]::Round($fill, 6)
              thesis = $thesis
            }
            $positions.Add($pos)
            $script:events.Add("ENTRY $id $($s.symbol) $($s.side)")
            $script:journalBlocks.Add(("`r`n## {0} UTC — АВТО: ВХОД {1} {2} {3} @{4}`r`n" -f $nowStr, $id, $s.symbol, $s.side.ToUpper(), [math]::Round($fill,6)) +
              ("Сетап A (v2, авто): стоп {0} ({1}%), TP1 {2} (1.5R), qty {3}, номинал {4}$, риск {5}$ (x{6}), комиссия входа {7}$. Режим: BTC {8}, F&G {9}.`r`n" -f $stop, $s.stopPct, [math]::Round($tp1,6), $qty, [math]::Round($qty*$fill,2), $riskUsd, $riskMult, [math]::Round($entryFee,2), $sig.btcTrend, $sig.fng))
          }
        }
      } elseif ($scanOk) {
        Write-TickLog $Root "scanner bar mismatch: want $(MsToUtcStr $closed4h), got $($sig.closedBarUtc) - retry next tick"
      }
    }
  }

  # ---------- 3. MTM по тикерам (для дашборда) ----------
  if ($positions.Count -gt 0) {
    try {
      $tk = Get-TickersAll (@($positions | ForEach-Object { $_.symbol }))
      $mtm = [double]$pf.balance_usd
      foreach ($p in $positions) {
        $px = if ($tk.ContainsKey($p.symbol)) { [double]$tk[$p.symbol] } elseif ($lastPx.ContainsKey($p.symbol)) { [double]$lastPx[$p.symbol] } else { [double]$p.entry_price }
        $sm = if ($p.side -eq 'long') { 1.0 } else { -1.0 }
        $mtm += $sm * [double]$p.qty * ($px - [double]$p.entry_price)
      }
      $pf.equity_usd = [math]::Round($mtm, 2)
      if ($mtm -gt [double]$pf.peak_equity_usd) { $pf.peak_equity_usd = [math]::Round($mtm, 2) }
    } catch { Write-Warning "tickers MTM failed: $($_.Exception.Message)" }
  } else {
    $pf.equity_usd = [math]::Round([double]$pf.balance_usd, 2)
  }

  # ---------- 4. ПЕРСИСТ ----------
  $pf.open_positions = ToArr $positions
  $pf.balance_usd = [math]::Round([double]$pf.balance_usd, 2)
  $pf.last_check_utc = $nowStr
  $doViz = ($script:events.Count -gt 0) -or ([int]$pf.auto.ticks_since_viz -ge 3)
  $pf.auto.ticks_since_viz = if ($doViz) { 0 } else { [int]$pf.auto.ticks_since_viz + 1 }
  $pf.auto.last_tick_utc = $nowStr

  if ($DryRun) {
    "=== DRY RUN $nowStr UTC ==="
    "события: $(if ($script:events.Count) { $script:events -join ' | ' } else { 'нет' })"
    "equity: $($pf.equity_usd)  balance: $($pf.balance_usd)  позиций: $($positions.Count)"
    "закрыто сделок в тике: $($script:closedTrades.Count)"
    Write-TickLog $Root "DRYRUN ok $([math]::Round($sw.Elapsed.TotalSeconds,1))s events=$($script:events.Count)"
  } else {
    # леджер СНАЧАЛА (дедуп по id спасает при повторе), потом атомарно portfolio (вотермарки+баланс вместе)
    if ($script:closedTrades.Count -gt 0) {
      $ltPath = Join-Path $Root 'data\live_trades.json'
      $lt = Read-JsonFile $ltPath
      $ltArr = New-Object System.Collections.Generic.List[object]
      foreach ($t in @($lt)) { if ($null -ne $t) { $ltArr.Add($t) } }
      $have = @{}; foreach ($t in $ltArr) { $have[[string]$t.id] = $true }
      foreach ($rec in $script:closedTrades) { if (-not $have.ContainsKey([string]$rec.id)) { $ltArr.Add($rec) } }
      Write-JsonAtomic $ltPath (ToArr $ltArr) 12
    }
    Write-JsonAtomic $pfPath $pf 12
    # точка эквити (дедуп по utc)
    $lePath = Join-Path $Root 'data\live_equity.json'
    $le = @(); $leRaw = Read-JsonFile $lePath
    if ($leRaw) { $le = @($leRaw | ForEach-Object { $_ }) }
    $lastUtc = if ($le.Count) { [string]$le[-1].utc } else { $null }
    if ($lastUtc -ne $nowStr) {
      $le += [pscustomobject]@{ utc = $nowStr; ts = $nowMs; eq = [double]$pf.equity_usd }
      Write-JsonAtomic $lePath (ToArr $le) 4
    }
    if ($script:journalBlocks.Count -gt 0) { Write-Journal $Root ($script:journalBlocks -join '') }
  }
} catch {
  Write-TickLog $Root ("MAIN ERROR: " + $_.Exception.Message + ' @ ' + $_.ScriptStackTrace.Split("`n")[0])
  Write-Warning "основной контур: тик отменён: $($_.Exception.Message)"
  $doViz = $false
}

# ================= CHALLENGE (замороженные правила S4; сбой не влияет на основной контур) =================
if (-not $SkipChallenge) {
  try {
    $cpPath = Join-Path $Root 'challenge\portfolio.json'
    $cp = Read-JsonFile $cpPath
    if ($null -ne $cp -and -not $cp.challenge.failed -and -not $cp.challenge.completed) {
      $chEvents = New-Object System.Collections.Generic.List[string]
      $chJournal = New-Object System.Collections.Generic.List[string]
      if (-not $cp.PSObject.Properties['auto']) {
        $initTs = if ($cp.open_position -and $cp.open_position.symbol) { UtcStrToMs ([string]$cp.last_check_utc) } else { (FloorTo $nowMs $MIN) - $MIN }
        $cp | Add-Member -NotePropertyName auto -NotePropertyValue ([pscustomobject]@{ schema=1; last_1m_ts=[long]$initTs; last_scan_1h_ts=[long]((FloorTo $nowMs $H1) - $H1); paused_day_utc=$null })
      }
      Ensure-Prop $cp.auto 'paused_day_utc' $null

      $chLastClosed1m = (FloorTo $nowMs $MIN) - $MIN
      $chOk = $true

      # --- день/ролл (по часам и по свечам одинаково: считаем от start_date) ---
      function ChDayNum([string]$day) {
        $sd = [datetime]::ParseExact([string]$cp.challenge.start_date_utc, 'yyyy-MM-dd', $null)
        $dd = [datetime]::ParseExact($day, 'yyyy-MM-dd', $null)
        [int](($dd - $sd).TotalDays) + 1
      }

      $cpos = if ($cp.open_position -and $cp.open_position.symbol) { $cp.open_position } else { $null }
      if ($null -ne $cpos) {
        Ensure-Prop $cpos 'entry_ts' (UtcStrToMs ([string]$cpos.entry_utc))
        $holdUntil = UtcStrToMs ([string]$cpos.max_hold_until_utc)
        $startMs = [long]$cp.auto.last_1m_ts + $MIN
        if ($startMs -le $chLastClosed1m) {
          $sym = [string]$cpos.symbol
          $k = @(); $fm = @{}
          try {
            $k = Get-Klines $sym '1' $startMs ($chLastClosed1m + $MIN) $nowMs
            if ($k.Count -eq 0) { throw "нет 1m-свечей $sym (челлендж)" }
            $fm = Get-FundingMap $sym ($startMs - $SLOT8) $nowMs
          } catch { $chOk = $false; Write-TickLog $Root "CH MGMT ABORT: $($_.Exception.Message)" }
          if ($chOk) {
            $sm = if ($cpos.side -eq 'long') { 1.0 } else { -1.0 }
            $entry = [double]$cpos.entry_price; $qty = [double]$cpos.qty
            foreach ($b in $k) {
              $ts = [long]$b.t
              # ролл дня
              $tsDay = MsToUtcDay $ts
              if ($tsDay -ne [string]$cp.day_start_date_utc) {
                $dn = ChDayNum $tsDay
                $cp.challenge.day_number = $dn
                $cp.day_start_date_utc = $tsDay
                $cp.day_start_equity_usd = [math]::Round([double]$cp.equity_usd, 2)
                if ($cp.challenge.pause_next_day) { $cp.auto.paused_day_utc = $tsDay; $cp.challenge.pause_next_day = $false }
                $chJournal.Add(("`r`n## {0} 00:00 UTC — Челлендж — день {1}/30: equity {2}$ (старт 1000$)`r`n" -f $tsDay, $dn, [math]::Round([double]$cp.equity_usd,2)))
                if ($dn -gt 30) { $cp.challenge.completed = $true; $chEvents.Add('CHALLENGE COMPLETED (30 дней)') }
              }
              if (($ts + $MIN) -le [long]$cpos.entry_ts) { continue }
              # фандинг (challenge-конвенция: fund >0 = получено, добавляется к P&L на выходе)
              if (($ts % $SLOT8) -eq 0 -and $ts -ge [long]$cpos.entry_ts) {
                $rate = Get-FundingRateAt $fm $ts 0.0001
                $cpos.funding_accrued_usd = [math]::Round([double]$cpos.funding_accrued_usd + (-$sm) * $qty * [double]$b.o * $rate, 4)
              }
              # выходы (порядок замороженного бэктеста)
              $exitPx = 0.0; $reason = ''
              $o=[double]$b.o; $h=[double]$b.h; $l=[double]$b.l; $c=[double]$b.c
              if ($sm -gt 0) {
                if ($o -le [double]$cpos.liq_price) { $reason = 'liquidation'; $exitPx = [double]$cpos.liq_price }
                elseif ($o -le [double]$cpos.stop) { $exitPx = $o * (1 - $CH_STOPSLIP); $reason = 'stop-gap' }
                elseif ($l -le [double]$cpos.stop) { $exitPx = [double]$cpos.stop * (1 - $CH_STOPSLIP); $reason = 'stop' }
                elseif ($h -ge [double]$cpos.tp) { $exitPx = [double]$cpos.tp * (1 - $CH_SLIP); $reason = 'tp' }
                elseif (($ts + $MIN) -ge $holdUntil) { $exitPx = $c * (1 - $CH_SLIP); $reason = 'time' }
              } else {
                if ($o -ge [double]$cpos.liq_price) { $reason = 'liquidation'; $exitPx = [double]$cpos.liq_price }
                elseif ($o -ge [double]$cpos.stop) { $exitPx = $o * (1 + $CH_STOPSLIP); $reason = 'stop-gap' }
                elseif ($h -ge [double]$cpos.stop) { $exitPx = [double]$cpos.stop * (1 + $CH_STOPSLIP); $reason = 'stop' }
                elseif ($l -le [double]$cpos.tp) { $exitPx = [double]$cpos.tp * (1 + $CH_SLIP); $reason = 'tp' }
                elseif (($ts + $MIN) -ge $holdUntil) { $exitPx = $c * (1 + $CH_SLIP); $reason = 'time' }
              }
              # пол челленджа: MTM <= 500 => принудительное закрытие и провал
              $mtmC = [double]$cp.balance_usd + $sm * $qty * ($c - $entry) + [double]$cpos.funding_accrued_usd
              if ($reason -eq '' -and $mtmC -le [double]$cp.meta.challenge_stop_equity_usd) {
                $exitPx = $c * (1 - $sm * $CH_SLIP); $reason = 'challenge-stop'
              }
              if ($reason -ne '') {
                $exitFee = if ($reason -eq 'liquidation') { 0.0 } else { $qty * $exitPx * $CH_FEE }
                $gross = $sm * $qty * ($exitPx - $entry)
                $fund = [double]$cpos.funding_accrued_usd
                $cp.balance_usd = [math]::Round([double]$cp.balance_usd + $gross - $exitFee + $fund, 2)
                $net = [math]::Round($gross - $exitFee + $fund - 0, 2)   # entry fee уже вычтена из баланса при входе
                $netTrade = [math]::Round($net - [double]$cpos.entry_fee_usd, 2)  # для карточки: полный эффект сделки
                $rec = [pscustomobject]@{
                  id = $cpos.id; symbol = $sym; side = $cpos.side
                  entry_utc = $cpos.entry_utc; entry = $entry; qty = $qty
                  exit_utc = (MsToUtcStr $ts); exit = [math]::Round($exitPx, 6)
                  reason = $reason; bars_held_h = [math]::Round(($ts + $MIN - [long]$cpos.entry_ts) / 3600000.0, 1)
                  pnl_usd = $netTrade
                  fees_usd = [math]::Round([double]$cpos.entry_fee_usd + $exitFee, 2)
                  funding_usd = [math]::Round($fund, 2)
                  r_multiple = if ([double]$cpos.risk_usd -gt 0) { [math]::Round($netTrade / [double]$cpos.risk_usd, 2) } else { $null }
                  thesis = $cpos.thesis
                }
                $cp.closed_trades = ToArr (@($cp.closed_trades) + $rec)
                $st = $cp.stats
                $st.trades = [int]$st.trades + 1
                if ($netTrade -gt 0) { $st.wins = [int]$st.wins + 1 } else { $st.losses = [int]$st.losses + 1 }
                $st.total_fees_usd = [math]::Round([double]$st.total_fees_usd + $exitFee, 2)
                $st.total_funding_usd = [math]::Round([double]$st.total_funding_usd + $fund, 2)
                $st.realized_pnl_usd = [math]::Round([double]$st.realized_pnl_usd + $netTrade, 2)
                if ($reason -in @('stop','stop-gap','liquidation','challenge-stop')) {
                  $cp.challenge.consecutive_stop_losses = [int]$cp.challenge.consecutive_stop_losses + 1
                  if ([int]$cp.challenge.consecutive_stop_losses -ge 3) { $cp.challenge.pause_next_day = $true; $chEvents.Add('3 стопа подряд → день паузы') }
                } elseif ($netTrade -gt 0) { $cp.challenge.consecutive_stop_losses = 0 }
                $chEvents.Add("CH EXIT $($cpos.id) $sym $reason $netTrade USD")
                $chJournal.Add(("`r`n## {0} UTC — Челлендж АВТО: закрыта {1} {2} {3} — {4:+0.00;-0.00}$ ({5}), комиссии {6}$, фандинг {7:+0.00;-0.00}$`r`n" -f (MsToUtcStr $ts), $cpos.id, $sym, $cpos.side.ToUpper(), $netTrade, $reason, $rec.fees_usd, $fund))
                if ($reason -eq 'challenge-stop' -or ([double]$cp.balance_usd) -le [double]$cp.meta.challenge_stop_equity_usd) {
                  $cp.challenge.failed = $true
                  $chEvents.Add('CHALLENGE FAILED (equity <= $500)')
                  $chJournal.Add(("`r`n## {0} UTC — ЧЕЛЛЕНДЖ ПРОВАЛЕН: equity ≤ 500$. Торговля остановлена, ждёт пост-мортема и решения пользователя.`r`n" -f (MsToUtcStr $ts)))
                }
                $cp.open_position = $null
                $cpos = $null
                $cp.auto.last_1m_ts = $ts
                break
              }
              $cp.equity_usd = [math]::Round($mtmC, 2)
              if ($mtmC -gt [double]$cp.peak_equity_usd) { $cp.peak_equity_usd = [math]::Round($mtmC, 2) }
              $cp.auto.last_1m_ts = $ts
            }
            if ($null -ne $cpos) { $cp.auto.last_1m_ts = [long]$k[$k.Count-1].t }
            else { $cp.equity_usd = [double]$cp.balance_usd }
          }
        }
      } else {
        # позиции нет: ролл дня по часам
        $todayNow = MsToUtcDay $nowMs
        if ($todayNow -ne [string]$cp.day_start_date_utc) {
          $dn = ChDayNum $todayNow
          $cp.challenge.day_number = $dn
          $cp.day_start_date_utc = $todayNow
          $cp.day_start_equity_usd = [math]::Round([double]$cp.equity_usd, 2)
          if ($cp.challenge.pause_next_day) { $cp.auto.paused_day_utc = $todayNow; $cp.challenge.pause_next_day = $false }
          $chJournal.Add(("`r`n## {0} UTC — Челлендж — день {1}/30: equity {2}$ (старт 1000$)`r`n" -f $nowStr, $dn, [math]::Round([double]$cp.equity_usd,2)))
          if ($dn -gt 30) { $cp.challenge.completed = $true; $chEvents.Add('CHALLENGE COMPLETED (30 дней)') }
        }
        $cp.auto.last_1m_ts = $chLastClosed1m
        $cp.equity_usd = [math]::Round([double]$cp.balance_usd, 2)
      }

      # персист менеджмента ДО сканера (сканер читает challenge\portfolio.json с диска)
      $cp.last_check_utc = $nowStr
      if (-not $DryRun) { Write-JsonAtomic $cpPath $cp 12 }

      # --- вход (1 сделка / UTC-день, лучший скоринг S4) ---
      $todayUtc2 = MsToUtcDay $nowMs
      $chClosed1h = (FloorTo $nowMs $H1) - $H1
      $canEnter = $chOk -and (-not $DryRun) -and (-not $cp.challenge.failed) -and (-not $cp.challenge.completed) -and
                  ($null -eq $cp.open_position -or -not $cp.open_position.symbol) -and
                  ([string]$cp.last_entry_day_utc -ne $todayUtc2) -and
                  ([string]$cp.auto.paused_day_utc -ne $todayUtc2) -and
                  ([long]$cp.auto.last_scan_1h_ts -lt $chClosed1h)
      if ($canEnter) {
        $scanPath = Join-Path $Root 'challenge\tools\scan.ps1'
        $sigPath = Join-Path $Root 'challenge\data\signal.json'
        $scanOk = $true
        try { & $scanPath -Setup S4 -BreakN 24 -ExitMode tp2r -RiskPct $CH_RISK -LevTarget $CH_LEV | Out-Null }
        catch { $scanOk = $false; Write-TickLog $Root "CH scanner failed: $($_.Exception.Message)" }
        if ($scanOk) {
          $cp.auto.last_scan_1h_ts = $chClosed1h
          $csig = Read-JsonFile $sigPath
          if ($csig -and $csig.pick -and $csig.pick.symbol) {
            $pick = $csig.pick
            $tk = Get-TickersAll (@([string]$pick.symbol))
            if ($tk.ContainsKey([string]$pick.symbol)) {
              $sm = if ($pick.side -eq 'long') { 1.0 } else { -1.0 }
              $fill = [double]$tk[[string]$pick.symbol] * (1 + $sm * $CH_SLIP)
              $pickDist = [math]::Abs([double]$pick.entry - [double]$pick.stop)
              if ([math]::Abs($fill - [double]$pick.entry) -le 0.5 * $pickDist) {
                $stopDist = $pickDist   # ATR-дистанция от скана
                $stop = $fill - $sm * $stopDist
                $tp = $fill + $sm * 2.0 * $stopDist
                $stopPct = $stopDist / $fill
                $lev = $CH_LEV; $levMax = $CH_LIQSAFE / ($stopPct + $CH_MMR); if ($levMax -lt $lev) { $lev = $levMax }
                $qty = [double]$cp.equity_usd * $CH_RISK / $stopDist
                $margin = $qty * $fill / $lev
                if ($margin -gt $CH_MARGINCAP * [double]$cp.equity_usd) {
                  $qty = $CH_MARGINCAP * [double]$cp.equity_usd * $lev / $fill
                  $margin = $qty * $fill / $lev
                }
                $liq = $fill * (1 - $sm * (1.0 / $lev - $CH_MMR))
                $fee = $qty * $fill * $CH_FEE
                $cp.balance_usd = [math]::Round([double]$cp.balance_usd - $fee, 2)
                $cid = "C$(@($cp.closed_trades).Count + 1)"   # C1 уже закрыт к моменту нового входа (1 позиция за раз)
                $newPos = [pscustomobject]@{
                  id = $cid; symbol = [string]$pick.symbol; side = [string]$pick.side
                  entry_utc = $nowStr; signal_bar_utc = (MsToUtcStr $chClosed1h); entry_ts = $nowMs
                  entry_price = [math]::Round($fill, 6); qty = [math]::Round($qty, 2)
                  notional_usd = [math]::Round($qty * $fill, 2); margin_usd = [math]::Round($margin, 2)
                  leverage_effective = [math]::Round($lev, 2)
                  stop = [math]::Round($stop, 6); tp = [math]::Round($tp, 6); liq_price = [math]::Round($liq, 6)
                  risk_usd = [math]::Round($qty * $stopDist, 2)
                  risk_pct_equity = [math]::Round(100.0 * $qty * $stopDist / [double]$cp.equity_usd, 1)
                  max_hold_until_utc = (MsToUtcStr ($nowMs + $CH_HOLD_MS))
                  entry_fee_usd = [math]::Round($fee, 2); funding_accrued_usd = 0.0
                  score = $pick.score
                  thesis = [pscustomobject]@{
                    setup = "S4 свип-возврат N24 (АВТОВХОД): лучший скоринг дня $($pick.score) из 9 пар"
                    riskPlan = "риск $([math]::Round($qty*$stopDist,2))$ (10% эквити), стоп $([math]::Round($stop,6)) (2×ATR 1h), тейк $([math]::Round($tp,6)) (2R), тайм-стоп 48ч, плечо $([math]::Round($lev,1))x, ликвидация $([math]::Round($liq,6))"
                    invalidation = 'закрепление за стопом = вынос был истинным пробоем; или 48ч без движения'
                  }
                }
                $cp.open_position = $newPos
                $cp.last_entry_day_utc = $todayUtc2
                $chEvents.Add("CH ENTRY $cid $($pick.symbol) $($pick.side)")
                $chJournal.Add(("`r`n## {0} UTC — Челлендж АВТО: ВХОД {1} {2} {3} @{4}, стоп {5}, тейк {6} (2R), плечо {7}x, риск {8}$`r`n" -f $nowStr, $cid, $pick.symbol, $pick.side.ToUpper(), [math]::Round($fill,6), [math]::Round($stop,6), [math]::Round($tp,6), [math]::Round($lev,1), [math]::Round($qty*$stopDist,2)))
              } else { Write-TickLog $Root "CH entry skipped (stale price) $($pick.symbol)" }
            }
          } elseif ($csig) {
            Write-TickLog $Root "CH no trade: $($csig.noTradeReason)"
          }
        }
      } elseif (-not $DryRun -and $chOk -and [long]$cp.auto.last_scan_1h_ts -lt $chClosed1h -and ($cp.challenge.failed -or $cp.challenge.completed -or ([string]$cp.last_entry_day_utc -eq $todayUtc2) -or ([string]$cp.auto.paused_day_utc -eq $todayUtc2))) {
        $cp.auto.last_scan_1h_ts = $chClosed1h   # бар потреблён без скана (нет права на вход)
      }

      if (-not $DryRun) {
        Write-JsonAtomic $cpPath $cp 12
        if ($chJournal.Count -gt 0) { Write-Journal $Root ($chJournal -join '') }
      }
      foreach ($e in $chEvents) { $script:events.Add($e) }
      if ($chEvents.Count -gt 0) { $doViz = $true }
    }
  } catch {
    Write-TickLog $Root ("CHALLENGE ERROR: " + $_.Exception.Message)
    Write-Warning "челлендж-контур: пропущен: $($_.Exception.Message)"
  }
}

# ================= РЫНОК РФ: живой форвард-тест C2/C3b (сбой не влияет на крипту) =================
if (-not $SkipRf -and -not $DryRun) {
  try {
    $rfOut = (& (Join-Path $PSScriptRoot 'rf_engine.ps1') -Root $Root -NowMs $nowMs) | Out-String
    if ($rfOut -and ($rfOut -notmatch 'события: -')) { $doViz = $true }   # были RF-события - обновить дашборд
    if ($rfOut) { $rfOut.Trim() }
  } catch {
    Write-TickLog $Root ("RF SECTION ERROR: " + $_.Exception.Message)
    Write-Warning "контур РФ: пропущен: $($_.Exception.Message)"
  }
}

# ================= VIZ =================
if ($doViz -and -not $SkipViz -and -not $DryRun) {
  try { & (Join-Path $PSScriptRoot 'build_vizdata.ps1') -NoDeploy | Out-Null }
  catch { Write-Warning "vizdata rebuild failed: $($_.Exception.Message)"; Write-TickLog $Root "viz failed: $($_.Exception.Message)" }
}

$mode = if ($DryRun) { 'DRYRUN' } elseif ($Cloud) { 'cloud' } else { 'local' }
$evTxt = if ($script:events.Count) { ($script:events -join '; ') } else { '-' }
$eqTxt = if ($null -ne $script:pf) { "$($script:pf.equity_usd)" } else { '?' }
$posTxt = if ($null -ne $script:pf) { "$(@($script:pf.open_positions).Count)" } else { '?' }
Write-TickLog $Root ("ok [{0}] {1}s events: {2} | eq={3} pos={4}" -f $mode, [math]::Round($sw.Elapsed.TotalSeconds,1), $evTxt, $eqTxt, $posTxt)
"тик завершён [$mode] за $([math]::Round($sw.Elapsed.TotalSeconds,1))с | события: $evTxt | equity $eqTxt$ | позиций $posTxt"

if (-not $DryRun) { Release-EngineLock $lock }
