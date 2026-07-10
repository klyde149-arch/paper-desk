# Fetch MOEX FORTS futures history and build continuous back-adjusted (ratio) series.
# Assets: BR (Brent), NG (nat gas), GOLD, SILV (silver), Si (USD/RUB), RTS, CNY, MIX.
# Contracts are dated (e.g. BRQ5); this script enumerates them via iss/securities/{SECID},
# fetches candles per contract, rolls RollDaysBefore trading bars before each expiry and
# splices a continuous series with MULTIPLICATIVE (ratio) back-adjustment - the backtest
# engine is %-based, ratio keeps every % relationship intact and prices positive.
# Output (data\moex_fut\):
#   {ASSET}_1d.json / _1h.json   - continuous bars {t,o,h,l,c,v} (t = unix ms, MSK-as-UTC
#                                  like the rest of the project)
#   {ASSET}_contracts.json       - enumeration cache [{secid,lsttrade}]
#   {ASSET}_rolls.json           - roll audit [{date,fromSecid,toSecid,commonDate,closeFrom,closeTo,ratio,adjAppliedToOlder,medValueRubFrom}]
#   {ASSET}_meta.json            - bar counts, date range, median daily value (RUB) last 250 bars
param(
  [string[]]$Assets = @('BR','NG','GOLD','SILV','Si','RTS','CNY','MIX'),
  [string]$FromDaily  = '2020-01-01',
  [string]$FromHourly = '2024-01-01',
  [string]$Till = '2026-07-09',
  [int]$RollDaysBefore = 3,   # roll N trading bars before the contract's last bar
  [switch]$SkipHourly,
  [switch]$RefreshContracts
)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'
$dir = 'C:\Users\klyde\trading-sim\data\moex_fut'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

$prefixMap = @{ BR='BR'; NG='NG'; GOLD='GD'; SILV='SV'; Si='Si'; RTS='RI'; CNY='CR'; MIX='MX'
                SBRF='SR'; GAZR='GZ'; LKOH='LK'; ROSN='RN' }   # single-stock futures
$monthLetters = @('F','G','H','J','K','M','N','Q','U','V','X','Z')

function Invoke-Iss([string]$url) {
  for ($try = 1; $try -le 3; $try++) {
    try { return Invoke-RestMethod -Uri $url -TimeoutSec 30 }
    catch { if ($try -eq 3) { throw }; Start-Sleep -Seconds (2 * $try) }
  }
}

# metadata of any (incl. expired) contract; returns $null when SECID unknown (0 rows, no HTTP error)
function Get-ContractMeta([string]$secid) {
  $r = Invoke-Iss "https://iss.moex.com/iss/securities/$secid.json?iss.only=description"
  $rows = $r.description.data
  if (-not $rows -or $rows.Count -eq 0) { return $null }
  $meta = @{}
  foreach ($row in $rows) { $meta[[string]$row[0]] = $row[2] }
  return $meta
}

function Get-Contracts([string]$asset) {
  $cacheFile = Join-Path $dir "$($asset)_contracts.json"
  if ((Test-Path $cacheFile) -and -not $RefreshContracts) {
    return @((Get-Content $cacheFile -Raw | ConvertFrom-Json) | ForEach-Object { $_ })
  }
  $prefix = $prefixMap[$asset]
  if (-not $prefix) { throw "unknown asset $asset (no SECID prefix mapped)" }
  $yFrom = ([datetime]$FromDaily).Year
  $yTo = ([datetime]$Till).Year + 1
  $found = @()
  for ($y = $yFrom; $y -le $yTo; $y++) {
    $d = $y % 10
    foreach ($m in $monthLetters) {
      $secid = "$prefix$m$d"
      $meta = Get-ContractMeta $secid
      Start-Sleep -Milliseconds 150
      if (-not $meta) { continue }
      if ([string]$meta['ASSETCODE'] -ne $asset) { continue }
      if (-not $meta['LSTTRADE']) { continue }
      $lst = [datetime]$meta['LSTTRADE']
      if ($lst.Year -ne $y) { continue }               # decade-collision guard (BRN6 = 2016 vs 2026)
      if ($lst -lt [datetime]$FromDaily) { continue }
      $found += [pscustomobject]@{ secid = $secid; lsttrade = $lst.ToString('yyyy-MM-dd') }
    }
  }
  $found = @($found | Sort-Object lsttrade | ForEach-Object { $_ })
  ConvertTo-Json -InputObject @($found) -Depth 3 | Out-File $cacheFile -Encoding utf8
  return $found
}

function Get-Candles([string]$secid, [int]$interval, [string]$from, [string]$till) {
  $base = "https://iss.moex.com/iss/engines/futures/markets/forts/securities/$secid/candles.json?interval=$interval&from=$from&till=$till"
  $all = @(); $start = 0
  while ($true) {
    $r = Invoke-Iss "$base&start=$start"
    $rows = $r.candles.data
    if (-not $rows -or $rows.Count -eq 0) { break }
    $all += $rows
    if ($rows.Count -lt 500) { break }
    $start += $rows.Count
    Start-Sleep -Milliseconds 200
  }
  return @($all)
}

# ISS columns: open,close,high,low,value,volume,begin,end ; val kept for liquidity stats
function ConvertTo-Bars($rows) {
  $bars = foreach ($row in $rows) {
    $dt = [datetime]::SpecifyKind([datetime]::Parse($row[6]), 'Utc')
    [pscustomobject]@{
      t = [long]([DateTimeOffset]$dt).ToUnixTimeMilliseconds()
      o = [double]$row[0]; h = [double]$row[2]; l = [double]$row[3]; c = [double]$row[1]
      v = [double]$row[5]   # volume in contracts; ISS 'value' (RUB) is always 0 on FORTS
    }
  }
  return @($bars | Sort-Object t)
}

function Get-Median($vals) {
  $s = @($vals | Sort-Object)
  if ($s.Count -eq 0) { return 0 }
  $m = [int][math]::Floor($s.Count / 2)
  if ($s.Count % 2 -eq 1) { return [double]$s[$m] }
  return ([double]$s[$m - 1] + [double]$s[$m]) / 2
}

function Save-Series($segs, [string]$asset, [string]$sfx, [string]$field) {
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($seg in $segs) {
    $adj = [double]$seg.adj
    foreach ($b in $seg[$field]) {
      $out.Add([pscustomobject]@{
        t = [long]$b.t
        o = [math]::Round($b.o * $adj, 6); h = [math]::Round($b.h * $adj, 6)
        l = [math]::Round($b.l * $adj, 6); c = [math]::Round($b.c * $adj, 6)
        v = [double]$b.v
      })
    }
  }
  ConvertTo-Json -InputObject $out.ToArray() -Depth 3 -Compress | Out-File (Join-Path $dir "$($asset)$sfx.json") -Encoding utf8
  return $out.Count
}

$fromMs = [long]([DateTimeOffset]::new([datetime]::SpecifyKind([datetime]$FromDaily, 'Utc'))).ToUnixTimeMilliseconds()
$tillMs = [long]([DateTimeOffset]::new([datetime]::SpecifyKind(([datetime]$Till).AddDays(1), 'Utc'))).ToUnixTimeMilliseconds()
$fromHourlyDate = ([datetime]$FromHourly).Date

foreach ($asset in $Assets) {
  Write-Host "=== $asset ==="
  $contracts = Get-Contracts $asset
  if ($contracts.Count -eq 0) { Write-Warning "$asset : no contracts found"; continue }
  Write-Host ("{0}: {1} contracts, {2} ({3}) -> {4} ({5})" -f $asset, $contracts.Count,
    $contracts[0].secid, $contracts[0].lsttrade, $contracts[-1].secid, $contracts[-1].lsttrade)

  # ---- sequential splice: fetch daily bars per contract in expiry order, roll, slice ----
  $segs = New-Object System.Collections.Generic.List[object]
  $prevRoll = $fromMs - 1
  $prevBars = $null; $prevSecid = ''; $prevLastClose = 0.0
  foreach ($ct in $contracts) {
    if ($prevRoll -ge ($tillMs - 4 * 86400000)) { break }   # reached the live edge
    $lst = [datetime]$ct.lsttrade
    $fFrom = $lst.AddDays(-200).ToString('yyyy-MM-dd')
    $fTill = $ct.lsttrade
    if ($lst -gt [datetime]$Till) { $fTill = $Till }
    $rows = Get-Candles $ct.secid 24 $fFrom $fTill
    Start-Sleep -Milliseconds 200
    if ($rows.Count -lt ($RollDaysBefore + 2)) { Write-Warning "$($ct.secid): only $($rows.Count) daily bars, skipped"; continue }
    $bars = ConvertTo-Bars $rows
    $rollIdx = $bars.Count - 1 - $RollDaysBefore
    if ($lst -gt [datetime]$Till) { $rollIdx = $bars.Count - 1 }   # live front contract: no roll cut
    if ($rollIdx -lt 0) { $rollIdx = 0 }
    $rollTs = [long]$bars[$rollIdx].t
    if ($rollTs -le $prevRoll) { continue }   # fully overlapped, contributes nothing fresh
    $slice = @($bars | Where-Object { $_.t -gt $prevRoll -and $_.t -le $rollTs })
    if ($slice.Count -eq 0) { continue }

    # splice ratio vs previous contract at the latest common date <= previous roll
    $ratio = $null; $commonTs = $null
    if ($null -ne $prevBars) {
      $curByTs = @{}
      foreach ($b in $bars) { $curByTs[[long]$b.t] = $b }
      for ($j = $prevBars.Count - 1; $j -ge 0; $j--) {
        $bt = [long]$prevBars[$j].t
        if ($bt -le $prevRoll -and $curByTs.ContainsKey($bt)) {
          $commonTs = $bt
          $ratio = [double]$curByTs[$bt].c / [double]$prevBars[$j].c
          break
        }
      }
      if ($null -eq $commonTs) {
        $ratio = [double]$bars[0].c / $prevLastClose
        Write-Warning "$asset $prevSecid->$($ct.secid): no overlapping bar, fallback ratio $([math]::Round($ratio,4))"
      }
    }

    $segs.Add(@{
      secid = $ct.secid; sliceStart = $prevRoll; sliceEnd = $rollTs
      slice = $slice; ratioFromPrev = $ratio; commonTs = $commonTs
      medVal = (Get-Median @($slice | ForEach-Object { $_.v }))
    })
    $prevRoll = $rollTs; $prevBars = $bars; $prevSecid = $ct.secid
    $prevLastClose = [double]$slice[-1].c
  }
  if ($segs.Count -eq 0) { Write-Warning "$asset : no segments built"; continue }

  # ---- cumulative back-adjust factors (newest segment = 1.0) ----
  for ($k = $segs.Count - 1; $k -ge 0; $k--) {
    if ($k -eq $segs.Count - 1) { $segs[$k].adj = 1.0 }
    else { $segs[$k].adj = [double]$segs[$k + 1].adj * [double]$segs[$k + 1].ratioFromPrev }
  }

  # ---- roll audit file ----
  $rolls = @()
  for ($k = 1; $k -lt $segs.Count; $k++) {
    $cd = ''
    if ($null -ne $segs[$k].commonTs) { $cd = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$segs[$k].commonTs).UtcDateTime.ToString('yyyy-MM-dd') }
    $rolls += [pscustomobject]@{
      date = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$segs[$k - 1].sliceEnd).UtcDateTime.ToString('yyyy-MM-dd')
      fromSecid = $segs[$k - 1].secid; toSecid = $segs[$k].secid
      commonDate = $cd
      ratio = [math]::Round([double]$segs[$k].ratioFromPrev, 6)
      adjAppliedToOlder = [math]::Round([double]$segs[$k - 1].adj, 6)
      medVolFrom = [double]$segs[$k - 1].medVal
    }
  }
  ConvertTo-Json -InputObject @($rolls) -Depth 3 | Out-File (Join-Path $dir "$($asset)_rolls.json") -Encoding utf8

  # ---- write daily series ----
  $nD = Save-Series $segs $asset '_1d' 'slice'
  $firstD = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$segs[0].slice[0].t).UtcDateTime.ToString('yyyy-MM-dd')
  $lastD = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$segs[-1].slice[-1].t).UtcDateTime.ToString('yyyy-MM-dd')
  Write-Host ("{0} 1d: {1} bars {2} -> {3}, {4} rolls" -f $asset, $nD, $firstD, $lastD, $rolls.Count)

  # ---- hourly series: same segments, same adj factors ----
  $nH = 0
  if (-not $SkipHourly) {
    $hSegs = New-Object System.Collections.Generic.List[object]
    foreach ($seg in $segs) {
      $endDate = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$seg.sliceEnd).UtcDateTime.Date
      if ($endDate -lt $fromHourlyDate) { continue }
      $startDate = [DateTimeOffset]::FromUnixTimeMilliseconds([long]([math]::Max([long]$seg.sliceStart, 0))).UtcDateTime.Date
      $fFrom = $startDate.AddDays(1)
      if ($fFrom -lt $fromHourlyDate) { $fFrom = $fromHourlyDate }
      if ($fFrom -gt $endDate) { continue }
      $rows = Get-Candles $seg.secid 60 $fFrom.ToString('yyyy-MM-dd') $endDate.ToString('yyyy-MM-dd')
      Start-Sleep -Milliseconds 200
      if ($rows.Count -eq 0) { continue }
      $hb = ConvertTo-Bars $rows
      $hSlice = @($hb | Where-Object {
        $hd = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$_.t).UtcDateTime.Date
        ($hd -gt $startDate) -and ($hd -le $endDate) -and ($hd -ge $fromHourlyDate)
      })
      if ($hSlice.Count -eq 0) { continue }
      $hSegs.Add(@{ adj = $seg.adj; hslice = $hSlice })
    }
    if ($hSegs.Count -gt 0) {
      $nH = Save-Series $hSegs $asset '_1h' 'hslice'
      Write-Host ("{0} 1h: {1} bars over {2} segments" -f $asset, $nH, $hSegs.Count)
    }
  }

  # ---- meta: liquidity = median daily volume (contracts) over the most recent 250 bars ----
  $recentVals = New-Object System.Collections.Generic.List[double]
  for ($k = $segs.Count - 1; $k -ge 0 -and $recentVals.Count -lt 250; $k--) {
    for ($j = $segs[$k].slice.Count - 1; $j -ge 0 -and $recentVals.Count -lt 250; $j--) {
      $recentVals.Add([double]$segs[$k].slice[$j].v)
    }
  }
  $meta = [pscustomobject]@{
    asset = $asset; contracts = $contracts.Count; segments = $segs.Count; rolls = $rolls.Count
    dailyBars = $nD; dailyFrom = $firstD; dailyTo = $lastD; hourlyBars = $nH
    medDailyVol250 = [long](Get-Median $recentVals)
  }
  $meta | ConvertTo-Json -Depth 3 | Out-File (Join-Path $dir "$($asset)_meta.json") -Encoding utf8
}

# index for -IndexSymbol IMOEX: copy from data\moex, trimmed to FromDaily
# (untrimmed 2019 bars would add dead zero-months to the engine's monthly averages)
$srcMoex = 'C:\Users\klyde\trading-sim\data\moex'
foreach ($sfx in @('_1d', '_1h')) {
  $src = Join-Path $srcMoex "IMOEX$sfx.json"
  if (Test-Path $src) {
    $ib = @((Get-Content $src -Raw | ConvertFrom-Json) | Where-Object { [long]$_.t -ge $fromMs })
    ConvertTo-Json -InputObject @($ib) -Depth 3 -Compress | Out-File (Join-Path $dir "IMOEX$sfx.json") -Encoding utf8
  }
}
Write-Host 'done.'
