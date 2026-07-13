# Market analysis for paper trading: fetches BingX klines + Bybit funding, computes EMA/RSI.
# PowerShell 5.1 compatible. Output: JSON array, one object per symbol.
param(
  [string[]]$Symbols = @('BTC-USDT','ETH-USDT','SOL-USDT','BNB-USDT','XRP-USDT','DOGE-USDT','ADA-USDT','AVAX-USDT','LINK-USDT',
                         'DOT-USDT','LTC-USDT','BCH-USDT','UNI-USDT','ATOM-USDT','NEAR-USDT','OP-USDT','APT-USDT','ARB-USDT','SUI-USDT','AAVE-USDT')
)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'

function Get-EMA([double[]]$v, [int]$p) {
  if ($v.Count -lt ($p + 5)) { return $null }
  $k = 2.0 / ($p + 1)
  $ema = ($v[0..($p-1)] | Measure-Object -Average).Average
  for ($i = $p; $i -lt $v.Count; $i++) { $ema = $v[$i] * $k + $ema * (1 - $k) }
  return [math]::Round($ema, 6)
}

function Get-RSI([double[]]$v, [int]$p) {
  if ($v.Count -le ($p + 1)) { return $null }
  $g = 0.0; $l = 0.0
  for ($i = 1; $i -le $p; $i++) {
    $d = $v[$i] - $v[$i-1]
    if ($d -gt 0) { $g += $d } else { $l -= $d }
  }
  $ag = $g / $p; $al = $l / $p
  for ($i = $p + 1; $i -lt $v.Count; $i++) {
    $d = $v[$i] - $v[$i-1]
    $gg = 0.0; $ll = 0.0
    if ($d -gt 0) { $gg = $d } else { $ll = -$d }
    $ag = ($ag * ($p - 1) + $gg) / $p
    $al = ($al * ($p - 1) + $ll) / $p
  }
  if ($al -eq 0) { return 100 }
  return [math]::Round(100 - (100 / (1 + $ag / $al)), 1)
}

function Get-Klines([string]$sym, [string]$interval, [int]$limit) {
  $u = "https://open-api.bingx.com/openApi/swap/v3/quote/klines?symbol=$sym&interval=$interval&limit=$limit"
  $r = Invoke-RestMethod -Uri $u -TimeoutSec 20
  if ($r.code -ne 0) { throw "BingX error for ${sym}: $($r.msg)" }
  return @($r.data | Sort-Object { [long]$_.time })  # oldest first
}

# Bybit funding/OI for all symbols in one call
$fund = @{}
try {
  $by = Invoke-RestMethod -Uri 'https://api.bybit.com/v5/market/tickers?category=linear' -TimeoutSec 20
  foreach ($t in $by.result.list) { $fund[$t.symbol] = $t }
} catch { Write-Warning "Bybit fetch failed: $_" }

$out = @()
foreach ($sym in $Symbols) {
  try {
    $k4 = Get-Klines $sym '4h' 300
    Start-Sleep -Milliseconds 150
    $k1 = Get-Klines $sym '1h' 60
    Start-Sleep -Milliseconds 150

    $c4 = [double[]]@($k4 | ForEach-Object { [double]$_.close })
    $c1 = [double[]]@($k1 | ForEach-Object { [double]$_.close })
    $price = $c1[$c1.Count - 1]

    $ema20 = Get-EMA $c4 20; $ema50 = Get-EMA $c4 50; $ema200 = Get-EMA $c4 200
    $rsi4 = Get-RSI $c4 14;  $rsi1 = Get-RSI $c1 14

    # avg range of last 5 closed 4h candles, as % of price (ATR proxy)
    $last5 = $k4 | Select-Object -Last 6 | Select-Object -First 5
    $atr = ($last5 | ForEach-Object { ([double]$_.high - [double]$_.low) } | Measure-Object -Average).Average
    $atrPct = [math]::Round(100 * $atr / $price, 2)

    # 30d range from 4h candles (180 candles)
    $r30 = $k4 | Select-Object -Last 180
    $hi = ($r30 | ForEach-Object { [double]$_.high } | Measure-Object -Maximum).Maximum
    $lo = ($r30 | ForEach-Object { [double]$_.low }  | Measure-Object -Minimum).Minimum

    $chg24 = $null
    if ($c1.Count -ge 25) { $chg24 = [math]::Round(100 * ($price / $c1[$c1.Count - 25] - 1), 2) }

    $trend = 'range'
    if ($ema20 -and $ema50) {
      if (($price -gt $ema50) -and ($ema20 -gt $ema50)) { $trend = 'up' }
      elseif (($price -lt $ema50) -and ($ema20 -lt $ema50)) { $trend = 'down' }
    }

    $bybitSym = $sym.Replace('-','')
    $fr = $null; $oi = $null
    if ($fund.ContainsKey($bybitSym)) {
      $fr = [math]::Round([double]$fund[$bybitSym].fundingRate * 100, 4)
      $oi = [math]::Round([double]$fund[$bybitSym].openInterestValue / 1e6, 1)
    }

    $out += [pscustomobject]@{
      symbol      = $sym
      price       = $price
      chg24h_pct  = $chg24
      trend_4h    = $trend
      ema20_4h    = $ema20
      ema50_4h    = $ema50
      ema200_4h   = $ema200
      rsi_4h      = $rsi4
      rsi_1h      = $rsi1
      atr5_4h_pct = $atrPct
      hi_30d      = $hi
      lo_30d      = $lo
      dist_hi_pct = [math]::Round(100 * ($hi / $price - 1), 1)
      dist_lo_pct = [math]::Round(100 * (1 - $lo / $price), 1)
      funding_pct_8h = $fr
      oi_musd     = $oi
    }
  } catch { Write-Warning "Failed ${sym}: $_" }
}

[pscustomobject]@{
  utc  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')
  data = $out
} | ConvertTo-Json -Depth 4

# append funding snapshot for future funding-contrarian research
$flog = 'C:\Users\klyde\trading-sim\data\funding_log.csv'
if (-not (Test-Path $flog)) { 'utc,symbol,funding_pct_8h,oi_musd,price' | Out-File $flog -Encoding utf8 }
$nowUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')
foreach ($row in $out) {
  if ($null -ne $row.funding_pct_8h) {
    "$nowUtc,$($row.symbol),$($row.funding_pct_8h),$($row.oi_musd),$($row.price)" | Out-File $flog -Append -Encoding utf8
  }
}
