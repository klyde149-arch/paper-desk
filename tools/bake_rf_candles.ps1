# bake_rf_candles.ps1 - печёт свечи T-Invest в data/live_rf/candles/<CODE>_<tf>.json.
# ТОЛЬКО на VPS: токен T-Invest есть лишь там; build_vizdata (GitHub Actions/локально) и браузер
# токена не имеют. Вызывается из deploy/live_rf_tick.sh на 15-минутных марках (перед git add).
# Формат файла: массивы [t,o,h,l,c,v], t = MSK-как-UTC ms (Get-TiCandles уже сдвигает +3ч).
# Потребители: build_vizdata.ps1 (мини-графики позиций) и report/chart.html (большой график),
# оба предпочитают эти файлы с фолбэком на MOEX ISS. Только чтение - торговлю не трогает.
param([string]$Root = '', [switch]$SnapshotOnly, [int]$TimeBudgetSec = 240)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'lib_engine.ps1')
. (Join-Path $PSScriptRoot 'lib_tinvest.ps1')
. (Join-Path $PSScriptRoot 'lib_msg_ru.ps1')

$lrfDir = Join-Path $Root 'data\live_rf'
$mode = if ($env:TINVEST_MODE) { $env:TINVEST_MODE } else { 'prod' }
Initialize-TInvest $lrfDir $mode

$outDir = Join-Path $lrfDir 'candles'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force $outDir | Out-Null }

# Универсум графиков = фьючерсы (коды активов, как в chart.html SYMS) + 12 momentum-акций TQBR.
# ВНИМАНИЕ: это СОБСТВЕННАЯ копия списка, файл не дот-сорсит lib_rf_signals.ps1 -
# при правке $ASSETS в каноне синхронизировать здесь вручную (2026-08: 8 -> 12).
$ASSETS = @('BR', 'NG', 'GOLD', 'SILV', 'Si', 'CNY', 'MIX', 'Eu', 'COCOA', 'VTBR', 'PLD', 'SBRF')
$TICKERS = @('SBER', 'GAZP', 'LKOH', 'ROSN', 'NVTK', 'GMKN', 'TATN', 'MGNT', 'CHMF', 'PLZL', 'YDEX')

# фронт-контракты (секиды) из portfolio.json
$fronts = @{}
$pfPath = Join-Path $lrfDir 'portfolio.json'
if (Test-Path $pfPath) {
  try {
    $pf = Get-Content $pfPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($pf.PSObject.Properties['fronts']) {
      foreach ($a in $pf.fronts.PSObject.Properties.Name) { $fronts[$a] = [string]$pf.fronts.$a.secid }
    }
  } catch { Write-Host "bake_rf_candles: portfolio.json нечитаем: $($_.Exception.Message)" }
}

# Единый read-model для ассистента, Mini App и статического отчёта. Он строится ПОСЛЕ
# торгового тика и никогда не участвует в принятии заявок; ошибка здесь не ломает движок.
function Pct($Now, $Base) {
  if ($null -eq $Now -or $null -eq $Base -or [double]$Base -le 0) { return $null }
  return [math]::Round((([double]$Now / [double]$Base) - 1) * 100, 2)
}
function Build-RfPresentationSnapshot($State) {
  $eqRows = @()
  $eqPath = Join-Path $lrfDir 'equity.json'
  if (Test-Path $eqPath) { try { $eqRows = @((Get-Content $eqPath -Raw -Encoding UTF8 | ConvertFrom-Json) | Where-Object { $null -ne $_ }) } catch { throw "equity.json: $($_.Exception.Message)" } }
  $trades = @()
  $trPath = Join-Path $lrfDir 'trades.json'
  if (Test-Path $trPath) { try { $trades = @((Get-Content $trPath -Raw -Encoding UTF8 | ConvertFrom-Json) | Where-Object { $null -ne $_ }) } catch { throw "trades.json: $($_.Exception.Message)" } }

  $capCurve = @($eqRows | Where-Object { $_.PSObject.Properties['bot_capital'] -and $_.PSObject.Properties['account_liquid'] -and $null -ne $_.bot_capital -and [double]$_.account_liquid -gt 0 } | ForEach-Object { ,@([long]$_.ts, [double]$_.bot_capital) })
  $curve = @($eqRows | Where-Object { $_.PSObject.Properties['total'] -and $null -ne $_.total -and [double]$_.total -gt 0 } | ForEach-Object { ,@([long]$_.ts, [double]$_.total) })
  $capital = if ($State.go.PSObject.Properties['bot_capital_rub'] -and $null -ne $State.go.bot_capital_rub) { [double]$State.go.bot_capital_rub } else { [double]$State.profile_eq }
  $peak = if ($State.go.PSObject.Properties['capital_peak_rub'] -and $null -ne $State.go.capital_peak_rub) { [double]$State.go.capital_peak_rub } else { [double]$State.peak_eq }
  $today = (Get-Date).ToUniversalTime().AddHours(3).ToString('yyyy-MM-dd')
  $dayBase = $null; $daySource = 'day_start_eq_stale'
  if ([string]$State.day_start_date -eq $today -and [double]$State.day_start_eq -gt 0) { $dayBase = [double]$State.day_start_eq; $daySource = 'day_start_eq' }
  else {
    $start = [datetimeoffset]::Parse("${today}T00:00:00+03:00").ToUnixTimeMilliseconds()
    $before = @($capCurve | Where-Object { [long]$_[0] -lt $start })
    if ($before.Count) { $dayBase = [double]$before[-1][1]; $daySource = 'prev_day_close' }
    elseif ([double]$State.day_start_eq -gt 0) { $dayBase = [double]$State.day_start_eq }
  }
  $names = Get-RuNames $Root
  $positions = @()
  foreach ($sn in 'core','setA') {
    foreach ($p in @($State.sleeves.$sn.positions | Where-Object { $null -ne $_ })) {
      $entry = [double]$p.entry_px_pts; $cur = if ($null -ne $p.cur_px) { [double]$p.cur_px } else { $null }
      $ratio = if ($p.side -eq 'short' -and $null -ne $cur -and $cur -ne 0) { $entry / $cur } else { if ($null -ne $cur -and $entry -ne 0) { $cur / $entry } else { $null } }
      $pct = if ($null -ne $ratio) { [math]::Round((($ratio - 1) * 100), 2) } else { $null }
      $positions += [pscustomobject]@{ id=$p.id; sleeve=$sn; asset=$p.asset; secid=$p.secid; title=(RuName $names 'fut' ([string]$p.asset) ([string]$p.secid)); side=$p.side; lots=$p.lots; entry=$entry; stop=$p.stop_px_pts; tp1=$p.tp1_px_pts; cur=$cur; upnl=$p.upnl_rub; risk=$p.risk_rub; entryDay=$p.entry_day; entryTs=$p.entry_ts; rolls=$p.rolls; rubPerPt=$p.rub_per_pt; notional=[math]::Round([double]$p.lots*$entry*[double]$p.rub_per_pt,0); pctChg=$pct; reconcileStatus=$p.reconcile_status; reconcileSinceTs=$p.reconcile_since_ts }
    }
  }
  # sleeve/lots нужны дашборду (колонка «Рукав» в «Закрытых сделках»); Mini App лишние поля игнорирует.
  $closed = @($trades | ForEach-Object { [pscustomobject]@{ id=$_.id; sleeve=$_.sleeve; asset=$_.asset; secid=$_.secid; title=(RuName $names 'fut' ([string]$_.asset) ([string]$_.secid)); side=$_.side; lots=$_.lots; entryDay=$_.entryDay; entry=$_.entry; exitDay=$_.exitDay; exitPx=$_.exitPx; exitReason=$_.exitReason; pnl=$_.pnlRub; rMultiple=$_.rMultiple; fees=$_.feesRub } })
  $wins = @($closed | Where-Object { [double]$_.pnl -gt 0 }).Count
  $holdings = @($State.sleeves.mom.holdings | Where-Object { $null -ne $_ } | ForEach-Object { [pscustomobject]@{ sym=$_.sym; lots=$_.lots; lotSize=$_.lot_size; avg=$_.avg_px; last=$_.last_px } })
  return [ordered]@{
    schema=1; generatedAtMs=(UtcNowMs); sourceAtMs=$State.watermarks.last_eq_snap
    summary=[ordered]@{ mode=$State.mode; accountId=$State.account_id; capital=$capital; peak=$peak; drawdownPct=(Pct $capital $peak); dayBase=$dayBase; dayBaseSource=$daySource; todayAmt=$(if($null -ne $dayBase){[math]::Round($capital-$dayBase,2)}else{$null}); todayPct=(Pct $capital $dayBase); allTimePct=(Pct $State.profile_eq $State.meta.base_rub); allTimeAmt=[math]::Round([double]$State.profile_eq-[double]$State.meta.base_rub,2); allTimeNote='пополнения счёта не учтены'; openPositions=$positions.Count; tradesPnl=[math]::Round(($closed | Measure-Object pnl -Sum).Sum,2); fees=[math]::Round(($closed | Measure-Object fees -Sum).Sum,2); winRate=$(if($closed.Count){[math]::Round(100*$wins/$closed.Count,1)}else{$null}); wins=$wins; losses=$closed.Count-$wins; entriesHalt=[bool]$State.entries_halt.active; haltReason=$State.entries_halt.reason; goUsed=$State.go.used_rub; goBudget=$State.go.budget_rub; accountLiquid=$State.go.account_liquid_rub; lastDailyDay=$State.watermarks.last_daily_day }
    operational=[ordered]@{ go=$State.go; drift=$State.drift; stats=$State.stats; capitalBreakdown=$State.capital_breakdown; active=$State.active; consecFail=$State.consec_fail }
    sleeves=[ordered]@{ core=[ordered]@{equity=$State.sleeves.core.equity_mtm; dayPct=(Pct $State.sleeves.core.equity_mtm $State.sleeves.core.day_start_eq)}; setA=[ordered]@{equity=$State.sleeves.setA.equity_mtm; dayPct=(Pct $State.sleeves.setA.equity_mtm $State.sleeves.setA.day_start_eq)}; mom=[ordered]@{equity=$State.sleeves.mom.equity_mtm; dayPct=(Pct $State.sleeves.mom.equity_mtm $State.sleeves.mom.day_start_eq)} }
    positions=$positions; holdings=$holdings; closedTrades=$closed; equity=$curve; capitalCurve=$capCurve
  }
}
if ($pf) {
  try { Write-JsonAtomic (Join-Path $Root 'data\rf_presentation_snapshot.json') (Build-RfPresentationSnapshot $pf) 12; Write-Host 'rf presentation snapshot: готово' }
  catch { Write-Warning "rf presentation snapshot: $($_.Exception.Message)" }
}
if ($SnapshotOnly) { return }
if (-not $script:TI.token) { Write-Host 'bake_rf_candles: нет токена T-Invest - свечи пропущены'; return }
if ($TimeBudgetSec -le 0) { Write-Host 'bake_rf_candles: TimeBudgetSec=0 - свечи пропущены'; return }

# Бюджет времени. Обход 23 инструментов - это ~180 вызовов GetCandles/FutureBy, и его цена
# целиком зависит от того, как быстро сегодня отвечает брокер: обычно 40-75 с, но 2026-08-18
# с 17:15 до 17:47 UTC свечные ответы замедлились вдвое и выпечка перевалила за 100 с. Тогда
# она жила внутри торгового тика и убивала его по TimeoutStartSec=110 ДО git-коммита - час без
# публикации состояния. Выпечка вынесена в свой юнит (deploy/rf-bake.*), но бюджет нужен и там:
# без него медленный прогон наезжает на следующий и flock -n глотает очередной запуск.
# Исчерпание бюджета - штатный исход, а не ошибка: записанное остаётся валидным (каждый файл
# пишется целиком), недостающее доберёт следующий прогон через 15 минут.
$script:bakeSw = [Diagnostics.Stopwatch]::StartNew()
function Test-BudgetLeft([string]$Next) {
  if ($script:bakeSw.Elapsed.TotalSeconds -lt $TimeBudgetSec) { return $true }
  Write-Host ("bake_rf_candles: бюджет {0} с исчерпан перед {1} - остальное доберёт следующий прогон" -f $TimeBudgetSec, $Next)
  return $false
}

# ТФ дашборда для РФ = 1h и 1D (chart.html поддерживает только их для fut/moex).
# Окна ограничены, чтобы влезть в лимиты диапазона GetCandles и не раздувать git.
$TFS = @(
  @{ id = '1h'; iv = 'CANDLE_INTERVAL_HOUR'; days = 30;  win = 7 },
  @{ id = '1D'; iv = 'CANDLE_INTERVAL_DAY';  days = 365; win = 300 }
)

$uidCache = @{}
function Resolve-Uid([string]$Code, [string]$Kind) {
  $key = "$Kind|$Code"
  if ($uidCache.ContainsKey($key)) { return $uidCache[$key] }
  $u = ''
  try { $i = Get-TiInstrument $Code $Kind; $u = [string]$i.uid } catch { Write-Host "  uid $Code ($Kind): $($_.Exception.Message)" }
  $uidCache[$key] = $u
  return $u
}

function Get-CandlesWindowed([string]$Uid, [string]$Iv, [int]$Days, [int]$Win) {
  $rows = New-Object System.Collections.Generic.List[object]
  $nowU = (Get-Date).ToUniversalTime()
  $from = $nowU.AddDays(-$Days)
  while ($from -lt $nowU) {
    $to = $from.AddDays($Win); if ($to -gt $nowU) { $to = $nowU }
    $fi = $from.ToString('yyyy-MM-ddTHH:mm:ssZ'); $ti = $to.ToString('yyyy-MM-ddTHH:mm:ssZ')
    try { foreach ($c in (Get-TiCandles $Uid $Iv $fi $ti)) { $rows.Add($c) } }
    catch { Write-Host "  окно $fi..${ti}: $($_.Exception.Message)" }
    $from = $to
  }
  return $rows
}

function Save-CodeCandles([string]$Code, [string]$Uid) {
  if (-not $Uid) { Write-Host "  ${Code}: нет uid - пропуск"; return }
  foreach ($tf in $TFS) {
    $rows = Get-CandlesWindowed $Uid $tf.iv $tf.days $tf.win
    if (-not $rows.Count) { continue }
    # dedup по t (окна могут перекрываться на границе) + сортировка
    $seen = @{}
    $arr = @($rows | Sort-Object t | Where-Object { if ($seen.ContainsKey($_.t)) { $false } else { $seen[$_.t] = $true; $true } } |
      ForEach-Object { , @([long]$_.t, [double]$_.o, [double]$_.h, [double]$_.l, [double]$_.c, [double]$_.v) })
    if (-not $arr.Count) { continue }
    $json = ConvertTo-Json -InputObject $arr -Depth 4 -Compress
    $fp = Join-Path $outDir ("{0}_{1}.json" -f $Code, $tf.id)
    $old = if (Test-Path $fp) { [IO.File]::ReadAllText($fp) } else { '' }
    if ($old -ne $json) {
      [IO.File]::WriteAllText($fp, $json, (New-Object System.Text.UTF8Encoding($false)))
      Write-Host ("  {0}_{1}: {2} свечей" -f $Code, $tf.id, $arr.Count)
    }
    Start-Sleep -Milliseconds 80   # мягкий троттлинг под лимиты
  }
}

foreach ($a in $ASSETS) {
  if (-not (Test-BudgetLeft $a)) { break }
  $secid = if ($fronts.ContainsKey($a)) { $fronts[$a] } else { '' }
  if (-not $secid) { Write-Host "  ${a}: нет фронта в portfolio.json - пропуск"; continue }
  # Страховка от коллизии имён: если код фьючерса совпадёт с тикером momentum-акции, свечи
  # разного масштаба (пункты против рублей) ушли бы в один файл. Сейчас пересечений нет -
  # акция VTBR выведена из $TICKERS ровно поэтому, - но проверка оставлена на будущее.
  if ($TICKERS -contains $a) { throw "bake_rf_candles: код фьючерса '$a' совпадает с momentum-тикером - свечи затрут друг друга" }
  Save-CodeCandles $a (Resolve-Uid $secid 'fut')
}
foreach ($t in $TICKERS) {
  if (-not (Test-BudgetLeft $t)) { break }
  Save-CodeCandles $t (Resolve-Uid $t 'share')
}

Write-Host ('bake_rf_candles: готово за {0:n1} с' -f $script:bakeSw.Elapsed.TotalSeconds)
