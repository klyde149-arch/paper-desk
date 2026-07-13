# Downloads paginated 4h history from BingX and caches to data\<symbol>_4h.json
param(
  [string[]]$Symbols = @('BTC-USDT','ETH-USDT','SOL-USDT','BNB-USDT','XRP-USDT','DOGE-USDT','ADA-USDT','AVAX-USDT','LINK-USDT',
                         'DOT-USDT','LTC-USDT','BCH-USDT','UNI-USDT','ATOM-USDT','NEAR-USDT','OP-USDT','APT-USDT','ARB-USDT','SUI-USDT','AAVE-USDT'),
  [int]$Pages = 3,
  [string]$Interval = '4h'
)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'
$dir = 'C:\Users\klyde\trading-sim\data'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

foreach ($sym in $Symbols) {
  $all = @{}
  $endTime = $null
  for ($p = 0; $p -lt $Pages; $p++) {
    $u = "https://open-api.bingx.com/openApi/swap/v3/quote/klines?symbol=$sym&interval=$Interval&limit=1000"
    if ($endTime) { $u += "&endTime=$endTime" }
    $r = Invoke-RestMethod -Uri $u -TimeoutSec 30
    if ($r.code -ne 0) { Write-Warning "$sym page $p error: $($r.msg)"; break }
    if (-not $r.data -or $r.data.Count -eq 0) { break }
    $srt = $r.data | Sort-Object { [long]$_.time }
    foreach ($c in $srt) { $all[[long]$c.time] = $c }
    $endTime = [long]$srt[0].time - 1
    Start-Sleep -Milliseconds 250
  }
  $ordered = $all.Keys | Sort-Object | ForEach-Object {
    $c = $all[$_]
    [pscustomobject]@{ t=[long]$c.time; o=[double]$c.open; h=[double]$c.high; l=[double]$c.low; c=[double]$c.close; v=[double]$c.volume }
  }
  $path = Join-Path $dir "$($sym.Replace('-','_'))_$Interval.json"
  $ordered | ConvertTo-Json -Depth 3 | Out-File -FilePath $path -Encoding utf8
  $first = [DateTimeOffset]::FromUnixTimeMilliseconds($ordered[0].t).UtcDateTime.ToString('yyyy-MM-dd')
  $last  = [DateTimeOffset]::FromUnixTimeMilliseconds($ordered[-1].t).UtcDateTime.ToString('yyyy-MM-dd')
  "{0,-10} {1} bars  {2} -> {3}" -f $sym, $ordered.Count, $first, $last
}

# Fear & Greed full history
try {
  $fng = Invoke-RestMethod -Uri 'https://api.alternative.me/fng/?limit=0' -TimeoutSec 30
  $fmap = $fng.data | ForEach-Object { [pscustomobject]@{ ts=[long]$_.timestamp; v=[int]$_.value } }
  $fmap | ConvertTo-Json -Depth 2 | Out-File -FilePath (Join-Path $dir 'fng.json') -Encoding utf8
  "F&G history: $($fmap.Count) days"
} catch { Write-Warning "F&G fetch failed: $_" }
