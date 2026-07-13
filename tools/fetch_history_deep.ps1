# Deep history fetcher: Bybit v5 linear perp klines (4h) + funding history, paginated to listing date.
# Output schema matches BingX cache: data\deep\SYM_4h.json = [{t,o,h,l,c,v}], SYM_funding.json = [{t,r}]
param(
  [string[]]$Symbols = @('BTC-USDT','ETH-USDT','SOL-USDT','BNB-USDT','XRP-USDT','DOGE-USDT','ADA-USDT','AVAX-USDT','LINK-USDT',
                         'DOT-USDT','LTC-USDT','BCH-USDT','UNI-USDT','ATOM-USDT','NEAR-USDT','OP-USDT','APT-USDT','ARB-USDT','SUI-USDT','TON-USDT'),
  [string]$Interval = '240',        # bybit interval: 240 = 4h
  [switch]$SkipFunding
)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'
$dir = 'C:\Users\klyde\trading-sim\data\deep'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

foreach ($sym in $Symbols) {
  $bsym = $sym.Replace('-','')
  # ---- klines, paginate back ----
  $all = @{}
  $end = $null
  $page = 0
  while ($true) {
    $u = "https://api.bybit.com/v5/market/kline?category=linear&symbol=$bsym&interval=$Interval&limit=1000"
    if ($end) { $u += "&end=$end" }
    try { $r = Invoke-RestMethod -Uri $u -TimeoutSec 30 } catch { Write-Warning "$sym kline page $page failed: $_"; Start-Sleep -Seconds 2; continue }
    if ($r.retCode -ne 0) { Write-Warning "$sym kline error: $($r.retMsg)"; break }
    $list = @($r.result.list)
    if ($list.Count -eq 0) { break }
    foreach ($k in $list) { $all[[long]$k[0]] = $k }
    $oldest = ($list | ForEach-Object { [long]$_[0] } | Measure-Object -Minimum).Minimum
    $end = $oldest - 1
    $page++
    if ($list.Count -lt 1000) { break }   # reached listing start
    Start-Sleep -Milliseconds 120
  }
  $ordered = $all.Keys | Sort-Object | ForEach-Object {
    $k = $all[$_]
    [pscustomobject]@{ t=[long]$k[0]; o=[double]$k[1]; h=[double]$k[2]; l=[double]$k[3]; c=[double]$k[4]; v=[double]$k[5] }
  }
  $ordered | ConvertTo-Json -Depth 3 -Compress | Out-File (Join-Path $dir "$($sym.Replace('-','_'))_4h.json") -Encoding utf8
  $first = [DateTimeOffset]::FromUnixTimeMilliseconds($ordered[0].t).UtcDateTime.ToString('yyyy-MM-dd')
  $last  = [DateTimeOffset]::FromUnixTimeMilliseconds($ordered[-1].t).UtcDateTime.ToString('yyyy-MM-dd')
  "{0,-10} {1,6} bars  {2} -> {3}  ({4} pages)" -f $sym, $ordered.Count, $first, $last, $page

  # ---- funding history, paginate back ----
  if (-not $SkipFunding) {
    $fall = @{}
    $fend = $null
    $fpage = 0
    while ($true) {
      $u = "https://api.bybit.com/v5/market/funding/history?category=linear&symbol=$bsym&limit=200"
      if ($fend) { $u += "&endTime=$fend" }
      try { $r = Invoke-RestMethod -Uri $u -TimeoutSec 30 } catch { Write-Warning "$sym funding page $fpage failed: $_"; Start-Sleep -Seconds 2; continue }
      if ($r.retCode -ne 0) { Write-Warning "$sym funding error: $($r.retMsg)"; break }
      $list = @($r.result.list)
      if ($list.Count -eq 0) { break }
      foreach ($f in $list) { $fall[[long]$f.fundingRateTimestamp] = [double]$f.fundingRate }
      $oldest = ($list | ForEach-Object { [long]$_.fundingRateTimestamp } | Measure-Object -Minimum).Minimum
      $fend = $oldest - 1
      $fpage++
      if ($list.Count -lt 200) { break }
      Start-Sleep -Milliseconds 120
    }
    $ford = $fall.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ t=[long]$_; r=$fall[$_] } }
    $ford | ConvertTo-Json -Depth 2 -Compress | Out-File (Join-Path $dir "$($sym.Replace('-','_'))_funding.json") -Encoding utf8
    "{0,-10} {1,6} funding records ({2} pages)" -f $sym, $ford.Count, $fpage
  }
}
"DONE deep fetch"
