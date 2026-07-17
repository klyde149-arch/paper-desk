# bake_rf_candles.ps1 - печёт свечи T-Invest в data/live_rf/candles/<CODE>_<tf>.json.
# ТОЛЬКО на VPS: токен T-Invest есть лишь там; build_vizdata (GitHub Actions/локально) и браузер
# токена не имеют. Вызывается из deploy/live_rf_tick.sh на 15-минутных марках (перед git add).
# Формат файла: массивы [t,o,h,l,c,v], t = MSK-как-UTC ms (Get-TiCandles уже сдвигает +3ч).
# Потребители: build_vizdata.ps1 (мини-графики позиций) и report/chart.html (большой график),
# оба предпочитают эти файлы с фолбэком на MOEX ISS. Только чтение - торговлю не трогает.
param([string]$Root = '')
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'lib_engine.ps1')
. (Join-Path $PSScriptRoot 'lib_tinvest.ps1')

$lrfDir = Join-Path $Root 'data\live_rf'
$mode = if ($env:TINVEST_MODE) { $env:TINVEST_MODE } else { 'prod' }
Initialize-TInvest $lrfDir $mode
if (-not $script:TI.token) { Write-Host 'bake_rf_candles: нет токена T-Invest - пропуск'; return }

$outDir = Join-Path $lrfDir 'candles'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force $outDir | Out-Null }

# Универсум графиков = 8 фьючерсов (коды активов, как в chart.html SYMS) + 12 momentum-акций TQBR.
$ASSETS = @('BR', 'NG', 'GOLD', 'SILV', 'Si', 'RTS', 'CNY', 'MIX')
$TICKERS = @('SBER', 'GAZP', 'LKOH', 'ROSN', 'NVTK', 'GMKN', 'TATN', 'MGNT', 'VTBR', 'CHMF', 'PLZL', 'YDEX')

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
  $secid = if ($fronts.ContainsKey($a)) { $fronts[$a] } else { '' }
  if (-not $secid) { Write-Host "  ${a}: нет фронта в portfolio.json - пропуск"; continue }
  Save-CodeCandles $a (Resolve-Uid $secid 'fut')
}
foreach ($t in $TICKERS) { Save-CodeCandles $t (Resolve-Uid $t 'share') }

Write-Host 'bake_rf_candles: готово'
