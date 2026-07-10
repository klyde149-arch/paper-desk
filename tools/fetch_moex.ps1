# Downloads daily candles from MOEX ISS (no key needed) into data\moex\<TICKER>_1d.json
param(
  [string[]]$Tickers = @('SBER','GAZP','LKOH','ROSN','NVTK','GMKN','TATN','MGNT','VTBR','CHMF','PLZL','YDEX'),
  [string]$From = '2023-07-01',
  [string]$Till = '2026-07-08',
  [int]$Interval = 24   # 24=daily, 60=hourly
)
$sfx = if ($Interval -eq 60) { '_1h' } else { '_1d' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'
$dir = 'C:\Users\klyde\trading-sim\data\moex'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

function Get-MoexCandles([string]$urlBase) {
  $all = @(); $start = 0
  while ($true) {
    $r = Invoke-RestMethod -Uri "$urlBase&start=$start" -TimeoutSec 30
    $rows = $r.candles.data
    if (-not $rows -or $rows.Count -eq 0) { break }
    $all += $rows
    if ($rows.Count -lt 500) { break }
    $start += $rows.Count
    Start-Sleep -Milliseconds 200
  }
  return $all
}

function Save-Candles([object[]]$rows, [string]$name) {
  # ISS columns: open,close,high,low,value,volume,begin,end
  $bars = foreach ($row in $rows) {
    $dt = [datetime]::SpecifyKind([datetime]::Parse($row[6]), 'Utc')
    [pscustomobject]@{
      t = [long]([DateTimeOffset]$dt).ToUnixTimeMilliseconds()
      o = [double]$row[0]; h = [double]$row[2]; l = [double]$row[3]; c = [double]$row[1]
      v = [double]$row[5]
    }
  }
  $bars = @($bars | Sort-Object t)
  $bars | ConvertTo-Json -Depth 3 | Out-File (Join-Path $dir "$($name)$sfx.json") -Encoding utf8
  $f = [DateTimeOffset]::FromUnixTimeMilliseconds($bars[0].t).UtcDateTime.ToString('yyyy-MM-dd')
  $l = [DateTimeOffset]::FromUnixTimeMilliseconds($bars[-1].t).UtcDateTime.ToString('yyyy-MM-dd')
  "{0,-6} {1,4} bars  {2} -> {3}" -f $name, $bars.Count, $f, $l
}

foreach ($tk in $Tickers) {
  try {
    $u = "https://iss.moex.com/iss/engines/stock/markets/shares/boards/TQBR/securities/$tk/candles.json?interval=$Interval&from=$From&till=$Till"
    $rows = Get-MoexCandles $u
    if ($rows.Count -eq 0) { Write-Warning "$tk : no data"; continue }
    Save-Candles $rows $tk
  } catch { Write-Warning "$tk failed: $_" }
  Start-Sleep -Milliseconds 250
}
# IMOEX index (regime filter, not traded)
try {
  $u = "https://iss.moex.com/iss/engines/stock/markets/index/boards/SNDX/securities/IMOEX/candles.json?interval=$Interval&from=$From&till=$Till"
  $rows = Get-MoexCandles $u
  Save-Candles $rows 'IMOEX'
} catch { Write-Warning "IMOEX failed: $_" }
