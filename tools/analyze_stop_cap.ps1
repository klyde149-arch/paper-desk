# analyze_stop_cap.ps1 - разбор пары «база / предел стопа» для доклада о риск-политике.
# Вход: выгрузки tools\backtest_rf_queue.ps1 - базовая (btq_trades*.json) и переигранная
# (btq_replay*.json, режим -ReplayTrades). Считает метрики ТЗ §12 и ложные ранние выбивания.
# Ничего не решает и никуда не пишет, кроме stdout и (по желанию) JSON: это измеритель.
param(
  [Parameter(Mandatory = $true)][string]$Baseline,
  [Parameter(Mandatory = $true)][string]$Replay,
  [string]$DataDir = 'C:\Users\klyde\trading-sim\data\moex_fut',
  [string]$FileSuffix = '_1d',
  [int]$FalseHorizonBars = 3,      # горизонт ложного выбивания зафиксирован паспортом: 3 торговых дня
  [string]$OutJson = '',
  [string]$Title = ''
)
$ErrorActionPreference = 'Stop'

function Read-Rows([string]$Path) {
  if (-not (Test-Path $Path)) { throw "нет файла: $Path" }
  return @((Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json) | Where-Object { $null -ne $_ })
}
function Med($v) {
  $s = @($v | Sort-Object)
  if (-not $s.Count) { return 0.0 }
  if ($s.Count % 2) { return [double]$s[[int](($s.Count - 1) / 2)] }
  return ([double]$s[$s.Count / 2 - 1] + [double]$s[$s.Count / 2]) / 2
}
function Stat-Set([string]$Name, $Pnls) {
  $arr = @($Pnls | ForEach-Object { [double]$_ })
  $gains = @($arr | Where-Object { $_ -gt 0 })
  $losses = @($arr | Where-Object { $_ -lt 0 })
  $sumG = if ($gains.Count) { ($gains | Measure-Object -Sum).Sum } else { 0.0 }
  $sumL = if ($losses.Count) { ($losses | Measure-Object -Sum).Sum } else { 0.0 }
  return [ordered]@{
    name = $Name; n = $arr.Count
    net = [math]::Round(($arr | Measure-Object -Sum).Sum, 2)
    wins = $gains.Count; losses = $losses.Count
    win_rate_pct = $(if ($arr.Count) { [math]::Round(100.0 * $gains.Count / $arr.Count, 1) } else { 0 })
    sum_gains = [math]::Round($sumG, 2); sum_losses = [math]::Round($sumL, 2)
    profit_factor = $(if ($sumL -ne 0) { [math]::Round($sumG / [math]::Abs($sumL), 2) } else { $null })
    avg_win = $(if ($gains.Count) { [math]::Round($sumG / $gains.Count, 2) } else { 0.0 })
    med_win = [math]::Round((Med $gains), 2)
    avg_loss = $(if ($losses.Count) { [math]::Round($sumL / $losses.Count, 2) } else { 0.0 })
    med_loss = [math]::Round((Med $losses), 2)
    worst = $(if ($arr.Count) { [math]::Round(($arr | Measure-Object -Minimum).Minimum, 2) } else { 0.0 })
    best = $(if ($arr.Count) { [math]::Round(($arr | Measure-Object -Maximum).Maximum, 2) } else { 0.0 })
  }
}

$base = Read-Rows $Baseline
$rep = Read-Rows $Replay
$sB = Stat-Set 'base' @($base | ForEach-Object { $_.pnlUsd })
$sR = Stat-Set 'capped' @($rep | ForEach-Object { $_.pnlUsd })

# Что предел сделал с отдельными сделками. Решающая цифра - сделки, которые база довела до
# ПРИБЫЛИ, а предел выбил: именно ими политика платит за меньшие убытки.
$capped = @($rep | Where-Object { [bool]$_.stopCapped })
$fired = @($rep | Where-Object { [string]$_.exitReason -eq 'stop-cap' })
$killedWinners = @($fired | Where-Object { [double]$_.basePnlUsd -gt 0 })
$lostProfit = 0.0
foreach ($k in $killedWinners) { $lostProfit += ([double]$k.basePnlUsd - [double]$k.pnlUsd) }
$savedLosses = @($fired | Where-Object { [double]$_.basePnlUsd -le 0 })
$savedRub = 0.0
foreach ($k in $savedLosses) { $savedRub += ([double]$k.pnlUsd - [double]$k.basePnlUsd) }

# Ложные ранние выбивания. Жёсткая трактовка «цена вернулась в пользу позиции»: в течение
# $FalseHorizonBars торговых дней после выбивания цена ушла ЗА цену входа, то есть сделка снова
# была бы в плюсе. Мягкая - вернулась хотя бы за уровень предела (стоп бы не сработал, если
# подождать). Обе считаем и печатаем: они отвечают на разные вопросы.
$bars = @{}
foreach ($sym in @($rep | ForEach-Object { [string]$_.sym } | Sort-Object -Unique)) {
  $p = Join-Path $DataDir ($sym.Replace('-', '_') + $FileSuffix + '.json')
  if (Test-Path $p) {
    $b = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
    # дни строим из $b.t (миллисекунды): поля d в свечных файлах нет, есть только t/o/h/l/c
    $bars[$sym] = [ordered]@{
      d = @($b.t | ForEach-Object { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$_).UtcDateTime.ToString('yyyy-MM-dd') })
      h = @($b.h); l = @($b.l)
    }
  }
}
$falseHard = 0; $falseSoft = 0; $checked = 0
foreach ($r in $fired) {
  $sym = [string]$r.sym
  if (-not $bars.ContainsKey($sym)) { continue }
  $days = @($bars[$sym].d)
  $i = [array]::IndexOf($days, [string]$r.exitDay)
  if ($i -lt 0) { continue }
  $checked++
  $hi = $null; $lo = $null
  $last = [math]::Min($i + $FalseHorizonBars, $days.Count - 1)
  for ($k = $i + 1; $k -le $last; $k++) {
    $h = [double]$bars[$sym].h[$k]; $l = [double]$bars[$sym].l[$k]
    if ($null -eq $hi -or $h -gt $hi) { $hi = $h }
    if ($null -eq $lo -or $l -lt $lo) { $lo = $l }
  }
  if ($null -eq $hi) { continue }
  $entry = [double]$r.entry; $stopUsed = [double]$r.stopUsed
  if ([string]$r.side -eq 'long') {
    if ($hi -ge $entry) { $falseHard++ }
    if ($hi -gt $stopUsed) { $falseSoft++ }
  } else {
    if ($lo -le $entry) { $falseHard++ }
    if ($lo -lt $stopUsed) { $falseSoft++ }
  }
}

# Вклад по активам: вывод не должен опираться на один инструмент.
$bySym = @{}
foreach ($r in $rep) {
  $k = [string]$r.sym
  if (-not $bySym.ContainsKey($k)) { $bySym[$k] = [ordered]@{ sym = $k; n = 0; base = 0.0; cap = 0.0 } }
  $bySym[$k].n++
  $bySym[$k].base += [double]$r.basePnlUsd
  $bySym[$k].cap += [double]$r.pnlUsd
}

# Устойчивость к одной сделке: результат без крупнейшей прибыли базы.
$netBaseNoTop = $sB.net; $netCapNoTop = $sR.net
if ($base.Count) {
  $maxBase = @($base | Sort-Object { [double]$_.pnlUsd } -Descending)[0]
  $netBaseNoTop = [math]::Round($sB.net - [double]$maxBase.pnlUsd, 2)
  $twin = @($rep | Where-Object { [string]$_.sym -eq [string]$maxBase.sym -and [string]$_.entryDay -eq [string]$maxBase.entryDay })
  if ($twin.Count) { $netCapNoTop = [math]::Round($sR.net - [double]$twin[0].pnlUsd, 2) }
}

$res = [ordered]@{
  title = $Title; baseline_file = $Baseline; replay_file = $Replay
  baseline = $sB; capped = $sR
  delta_net = [math]::Round($sR.net - $sB.net, 2)
  delta_net_pct = $(if ($sB.net -ne 0) { [math]::Round(100.0 * ($sR.net - $sB.net) / [math]::Abs($sB.net), 1) } else { $null })
  trades_capped = $capped.Count; trades_cap_fired = $fired.Count
  killed_winners = $killedWinners.Count; lost_profit = [math]::Round($lostProfit, 2)
  saved_loss_trades = $savedLosses.Count; saved_loss_rub = [math]::Round($savedRub, 2)
  false_horizon_bars = $FalseHorizonBars; false_checked = $checked
  false_back_above_entry = $falseHard; false_back_above_stop = $falseSoft
  net_without_top_trade_base = $netBaseNoTop; net_without_top_trade_cap = $netCapNoTop
  by_symbol = @(@($bySym.Keys | Sort-Object) | ForEach-Object {
      $v = $bySym[$_]
      [ordered]@{ sym = $v.sym; n = $v.n; base = [math]::Round($v.base, 2); cap = [math]::Round($v.cap, 2)
        delta = [math]::Round($v.cap - $v.base, 2) }
    })
}

if ($Title) { Write-Host ''; Write-Host ('===== ' + $Title + ' =====') }
Write-Host ("сделок: база {0}, переиграно {1}" -f $sB.n, $sR.n)
Write-Host ("результат: база {0:N2} -> предел {1:N2} (разница {2:N2}, {3}%)" -f $sB.net, $sR.net, $res.delta_net, $res.delta_net_pct)
Write-Host ("profit factor: {0} -> {1}; доля прибыльных: {2}% -> {3}%" -f $sB.profit_factor, $sR.profit_factor, $sB.win_rate_pct, $sR.win_rate_pct)
Write-Host ("средний проигрыш: {0:N2} -> {1:N2}; медианный: {2:N2} -> {3:N2}" -f $sB.avg_loss, $sR.avg_loss, $sB.med_loss, $sR.med_loss)
Write-Host ("худшая сделка: {0:N2} -> {1:N2}; сумма убытков: {2:N2} -> {3:N2}" -f $sB.worst, $sR.worst, $sB.sum_losses, $sR.sum_losses)
Write-Host ("средний выигрыш: {0:N2} -> {1:N2}; сумма прибылей: {2:N2} -> {3:N2}" -f $sB.avg_win, $sR.avg_win, $sB.sum_gains, $sR.sum_gains)
Write-Host ("предел сузил стоп: {0}; выбил раньше базы: {1}" -f $res.trades_capped, $res.trades_cap_fired)
Write-Host ("из них база довела до прибыли: {0} сделок, упущено {1:N2}" -f $res.killed_winners, $res.lost_profit)
Write-Host ("на убыточных по базе сэкономлено: {0} сделок, {1:N2}" -f $res.saved_loss_trades, $res.saved_loss_rub)
Write-Host ("ложные выбивания ({0} дн.): вернулась за вход {1} из {2}; за уровень предела {3}" -f $FalseHorizonBars, $res.false_back_above_entry, $res.false_checked, $res.false_back_above_stop)
Write-Host ("без крупнейшей сделки базы: база {0:N2} -> предел {1:N2}" -f $res.net_without_top_trade_base, $res.net_without_top_trade_cap)
if ($OutJson) {
  $res | ConvertTo-Json -Depth 6 | Out-File $OutJson -Encoding utf8
  Write-Host ("JSON: {0}" -f $OutJson)
}
