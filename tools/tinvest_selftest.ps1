# tinvest_selftest.ps1 - Phase 1: probe и аудит T-Invest API (readonly-токен, БЕЗ торговых вызовов).
# Запуск:  powershell -File tools\tinvest_selftest.ps1            # боевой хост, readonly-токен из env
#          powershell -File tools\tinvest_selftest.ps1 -Sandbox   # песочница (TINVEST_SANDBOX_TOKEN)
# Проверяет: доступность хоста (в т.ч. с зарубежного VPS - главный probe), GetAccounts,
# аудит 8 фьючерсов (фронты из ISS) + 12 акций: uid, class_code, api_trade_available_flag,
# лот, шаг, стоимость шага, ГО, last_trade_date vs ISS LASTTRADEDATE, TradingSchedules (клиринги ЕТС),
# латентность unary-вызовов. Закрывает реестр открытых вопросов docs\strategy\live_tinvest_design.md.
param(
  [string]$Root = '',
  [switch]$Sandbox
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'lib_engine.ps1')
. (Join-Path $PSScriptRoot 'lib_rf_signals.ps1')
. (Join-Path $PSScriptRoot 'lib_tinvest.ps1')

$mode = if ($Sandbox) { 'sandbox' } else { 'prod' }
Initialize-TInvest (Join-Path $Root 'data\live_rf') $mode
Write-Host "== T-Invest selftest (mode=$mode, host=$($script:TI.base)) =="
if (-not $script:TI.token) { Write-Warning 'токен не задан (TINVEST_TOKEN / TINVEST_SANDBOX_TOKEN) - только probe хоста'; }

# 1. probe хоста (доступность с этой машины/VPS - открытый вопрос #6)
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
  $null = Invoke-WebRequest -Uri $script:TI.base -Method Head -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
  Write-Host ("probe: хост отвечает ({0} мс)" -f $sw.ElapsedMilliseconds)
} catch {
  $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
  if ($code -gt 0) { Write-Host ("probe: хост отвечает HTTP {0} ({1} мс) - сеть ОК" -f $code, $sw.ElapsedMilliseconds) }
  else { Write-Error ("probe: хост НЕДОСТУПЕН: {0} - если это VPS, нужен план Б (RU VPS / локальный Windows)" -f $_.Exception.Message) }
}
if (-not $script:TI.token) { return }

# 2. счета
$accs = Get-TiAccounts
Write-Host "аккаунты:"; $accs | ForEach-Object { Write-Host ("  {0}  {1}  status={2} access={3}" -f $_.id, $_.name, $_.status, $_.accessLevel) }

# 3. маржинальные атрибуты (нужен TINVEST_ACCOUNT_ID)
if ($script:TI.accountId) {
  try {
    $m = Get-TiMarginAttributes $script:TI.accountId
    Write-Host ("маржа: liquid={0} starting_margin={1}" -f (M2D $m.liquidPortfolio).value, (M2D $m.startingMargin).value)
  } catch { Write-Warning "GetMarginAttributes: $($_.Exception.Message) (поле-маппинг - открытый вопрос)" }
}

# 4. аудит фьючерсов: фронты из ISS -> инструменты в T-Invest
$fronts = Get-FutFronts $ASSETS
Write-Host "`nфьючерсы (фронт + следующий):"
$issLtd = @{}
foreach ($a in $ASSETS) {
  foreach ($c in @($fronts[$a] | Select-Object -First 2)) {
    $issLtd[$c.secid] = $c.lasttrade
    try {
      $i = Get-TiInstrument $c.secid 'fut'
      $flag = if ($i.PSObject.Properties['apiTradeAvailableFlag']) { $i.apiTradeAvailableFlag } else { $i.api_trade_available_flag }
      $ltd = ''
      if ($i.PSObject.Properties['lastTradeDate']) { $ltd = ([string]$i.lastTradeDate).Substring(0,10) }
      elseif ($i.PSObject.Properties['last_trade_date']) { $ltd = ([string]$i.last_trade_date).Substring(0,10) }
      $mg = Get-TiFuturesMargin ([string]$i.uid)
      $goB = (M2D $(if ($mg.PSObject.Properties['initialMarginOnBuy']) { $mg.initialMarginOnBuy } else { $mg.initial_margin_on_buy })).value
      $amt = Q2D $(if ($mg.PSObject.Properties['minPriceIncrementAmount']) { $mg.minPriceIncrementAmount } else { $mg.min_price_increment_amount })
      $inc = Q2D $i.min_price_increment
      $ltdMatch = if ($ltd -eq [string]$c.lasttrade) { 'ok' } else { "РАСХОЖДЕНИЕ ISS=$($c.lasttrade)" }
      Write-Host ("  {0,-6} uid={1} api={2} lot={3} step={4} step₽={5} ₽/пт={6} ГО={7} ltd={8} [{9}]" -f `
        $c.secid, $i.uid, $flag, $i.lot, $inc, $amt, $(if ($inc -gt 0) { [math]::Round($amt/$inc,4) } else { '?' }), $goB, $ltd, $ltdMatch)
      if ($flag -ne $true) { Write-Warning "  $($c.secid): api_trade_available_flag=false!" }
    } catch { Write-Warning "  $($c.secid): $($_.Exception.Message)" }
  }
}

# 5. аудит акций momentum
Write-Host "`nакции TQBR (momentum):"
foreach ($t in $TICKERS) {
  try {
    $i = Get-TiInstrument $t 'share'
    $flag = if ($i.PSObject.Properties['apiTradeAvailableFlag']) { $i.apiTradeAvailableFlag } else { $i.api_trade_available_flag }
    Write-Host ("  {0,-5} uid={1} lot={2} api={3}" -f $t, $i.uid, $i.lot, $flag)
    if ($flag -ne $true) { Write-Warning "  ${t}: api_trade_available_flag=false!" }
  } catch { Write-Warning "  ${t}: $($_.Exception.Message)" }
}

# 6. расписание торгов (клиринги ЕТС-2026 - открытый вопрос #4)
try {
  $from = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddT00:00:00Z')
  $to = (Get-Date).ToUniversalTime().AddDays(6).ToString('yyyy-MM-ddT00:00:00Z')
  $sch = Get-TiTradingSchedules 'FORTS' $from $to
  Write-Host "`nрасписание FORTS (сверить клиринговые окна в live_rf_engine `$CLEARING):"
  foreach ($ex in @($sch.exchanges)) {
    foreach ($d in @($ex.days | Select-Object -First 3)) {
      Write-Host ("  {0} trading={1} start={2} end={3} evening={4}-{5} clearing={6}-{7}" -f `
        ([string]$d.date).Substring(0,10), $d.isTradingDay, $d.startTime, $d.endTime, $d.eveningStartTime, $d.eveningEndTime, $d.clearingStartTime, $d.clearingEndTime)
    }
  }
} catch { Write-Warning "TradingSchedules: $($_.Exception.Message)" }

# 7. латентность (нюанс #10): 10 unary-замеров
$times = @()
foreach ($n in 1..10) { $sw.Restart(); $null = Get-TiAccounts; $times += $sw.ElapsedMilliseconds }
$sorted = $times | Sort-Object
Write-Host ("`nлатентность unary: p50={0}мс p95={1}мс (gate Phase 1: p95 < 2000мс)" -f $sorted[4], $sorted[9])
Write-Host "`nselftest завершён. Результаты внести в реестр открытых вопросов дизайн-дока."
