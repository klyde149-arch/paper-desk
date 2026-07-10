# challenge\tools\fetch.ps1 - standalone data fetcher for the 30-day challenge.
# Bybit v5 public API (no keys): linear perp klines (1h + 4h) and funding history.
# Written from scratch; no dependency on the main sim's tools.
param(
    [string[]]$Symbols = @('BTC-USDT','ETH-USDT','SOL-USDT','BNB-USDT','XRP-USDT','DOGE-USDT','ADA-USDT','AVAX-USDT','LINK-USDT'),
    [string]$OutDir = '',
    [long]$FromMs = 1577836800000,   # 2020-01-01 UTC
    [switch]$Skip1h,
    [switch]$Skip4h,
    [switch]$SkipFunding
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Web.Extensions
$JS = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$JS.MaxJsonLength = [int]::MaxValue

if (-not $OutDir) { $OutDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'data' }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

function Invoke-Api([string]$url) {
    for ($try = 1; $try -le 5; $try++) {
        try {
            $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 30
            if ($resp.retCode -eq 0) { return $resp }
            Write-Host "  api retCode=$($resp.retCode) msg=$($resp.retMsg) (try $try)"
        } catch {
            Write-Host "  http error: $($_.Exception.Message) (try $try)"
        }
        Start-Sleep -Seconds (2 * $try)
    }
    throw "API failed after 5 tries: $url"
}

function Fetch-Klines([string]$sym, [string]$interval, [long]$fromMs) {
    # paginate backwards: end=cursor, list returned newest-first
    $bybitSym = $sym.Replace('-','')
    $stepMs = [long]$interval * 60000
    $nowMs = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $cursor = $nowMs
    while ($true) {
        $url = "https://api.bybit.com/v5/market/kline?category=linear&symbol=$bybitSym&interval=$interval&limit=1000&end=$cursor"
        $resp = Invoke-Api $url
        $list = @($resp.result.list)
        if ($list.Count -eq 0) { break }
        $minTs = [long]::MaxValue
        foreach ($k in $list) {
            $ts = [long]$k[0]
            if ($ts -lt $minTs) { $minTs = $ts }
            # keep only CLOSED bars (drop the forming one)
            if ($ts -ge $fromMs -and ($ts + $stepMs) -le $nowMs) {
                $rows.Add(@{ t = $ts; o = [double]$k[1]; h = [double]$k[2]; l = [double]$k[3]; c = [double]$k[4]; v = [double]$k[5] })
            }
        }
        if ($minTs -le $fromMs) { break }
        $cursor = $minTs - 1
        Start-Sleep -Milliseconds 120
    }
    # sort ascending by t, dedupe
    $sorted = $rows | Sort-Object { $_.t }
    $out = New-Object 'System.Collections.Generic.List[object]'
    $prev = -1L
    foreach ($r in $sorted) {
        if ($r.t -ne $prev) { $out.Add($r); $prev = $r.t }
    }
    return $out
}

function Fetch-Funding([string]$sym, [long]$fromMs) {
    $bybitSym = $sym.Replace('-','')
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $cursor = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    while ($true) {
        $url = "https://api.bybit.com/v5/market/funding/history?category=linear&symbol=$bybitSym&limit=200&endTime=$cursor"
        $resp = Invoke-Api $url
        $list = @($resp.result.list)
        if ($list.Count -eq 0) { break }
        $minTs = [long]::MaxValue
        foreach ($f in $list) {
            $ts = [long]$f.fundingRateTimestamp
            if ($ts -lt $minTs) { $minTs = $ts }
            if ($ts -ge $fromMs) {
                $rows.Add(@{ t = $ts; r = [double]$f.fundingRate })
            }
        }
        if ($minTs -le $fromMs) { break }
        $cursor = $minTs - 1
        Start-Sleep -Milliseconds 120
    }
    $sorted = $rows | Sort-Object { $_.t }
    $out = New-Object 'System.Collections.Generic.List[object]'
    $prev = -1L
    foreach ($r in $sorted) {
        if ($r.t -ne $prev) { $out.Add($r); $prev = $r.t }
    }
    return $out
}

function Save-Json([object]$data, [string]$path) {
    # manual JSON build: avoids PSObject-wrapper issues and is fast on 50k+ rows
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $sb = New-Object System.Text.StringBuilder (4 * 1024 * 1024)
    [void]$sb.Append('[')
    $firstRow = $true
    foreach ($r in $data) {
        if (-not $firstRow) { [void]$sb.Append(',') }
        $firstRow = $false
        if ($r.ContainsKey('o')) {
            [void]$sb.Append('{"t":').Append(([long]$r.t).ToString($inv))
            [void]$sb.Append(',"o":').Append(([double]$r.o).ToString('R', $inv))
            [void]$sb.Append(',"h":').Append(([double]$r.h).ToString('R', $inv))
            [void]$sb.Append(',"l":').Append(([double]$r.l).ToString('R', $inv))
            [void]$sb.Append(',"c":').Append(([double]$r.c).ToString('R', $inv))
            [void]$sb.Append(',"v":').Append(([double]$r.v).ToString('R', $inv)).Append('}')
        } else {
            [void]$sb.Append('{"t":').Append(([long]$r.t).ToString($inv))
            [void]$sb.Append(',"r":').Append(([double]$r.r).ToString('R', $inv)).Append('}')
        }
    }
    [void]$sb.Append(']')
    [System.IO.File]::WriteAllText($path, $sb.ToString(), [System.Text.Encoding]::UTF8)
}

function Report-Series([string]$label, [object]$rows, [long]$stepMs) {
    $n = $rows.Count
    if ($n -eq 0) { Write-Host "  $label : EMPTY"; return }
    $first = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$rows[0].t).ToString('yyyy-MM-dd')
    $last  = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$rows[$n-1].t).ToString('yyyy-MM-dd HH:mm')
    $gaps = 0
    if ($stepMs -gt 0) {
        for ($i = 1; $i -lt $n; $i++) {
            if (([long]$rows[$i].t - [long]$rows[$i-1].t) -ne $stepMs) { $gaps++ }
        }
    }
    Write-Host ("  {0}: {1} rows, {2} -> {3}, gaps={4}" -f $label, $n, $first, $last, $gaps)
}

$sw = [Diagnostics.Stopwatch]::StartNew()
foreach ($sym in $Symbols) {
    $fileBase = $sym.Replace('-','_')
    Write-Host "=== $sym ==="
    if (-not $Skip1h) {
        $k1 = Fetch-Klines $sym '60' $FromMs
        Save-Json $k1 (Join-Path $OutDir "${fileBase}_1h.json")
        Report-Series '1h' $k1 3600000
    }
    if (-not $Skip4h) {
        $k4 = Fetch-Klines $sym '240' $FromMs
        Save-Json $k4 (Join-Path $OutDir "${fileBase}_4h.json")
        Report-Series '4h' $k4 14400000
    }
    if (-not $SkipFunding) {
        $fu = Fetch-Funding $sym $FromMs
        Save-Json $fu (Join-Path $OutDir "${fileBase}_funding.json")
        Report-Series 'funding' $fu 0
    }
}
Write-Host ("DONE in {0:n1}s" -f $sw.Elapsed.TotalSeconds)
