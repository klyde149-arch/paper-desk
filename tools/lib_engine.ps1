# lib_engine.ps1 - shared helpers for the autonomous tick engine (auto_trade.ps1).
# Dot-source this file. PS 5.1 compatible. ASCII only (no BOM needed).
# Data layer: Bybit v5 primary, api.bytick.com mirror, BingX as last-resort fallback
# (GitHub Actions runners sit on US Azure IPs which api.bybit.com may geo-block).

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:BybitBases = @('https://api.bybit.com', 'https://api.bytick.com')
$script:BybitBaseGood = $null   # remembered working base for this process

# ---------- time ----------
function UtcNowMs { [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) }
function FloorTo([long]$ms, [long]$step) { $ms - ($ms % $step) }
function MsToUtc([long]$ms) { [DateTimeOffset]::FromUnixTimeMilliseconds($ms).UtcDateTime }
function MsToUtcStr([long]$ms) { (MsToUtc $ms).ToString('yyyy-MM-dd HH:mm') }
function MsToUtcDay([long]$ms) { (MsToUtc $ms).ToString('yyyy-MM-dd') }
function UtcStrToMs([string]$s) {
  $dt = [datetime]::SpecifyKind([datetime]::ParseExact($s, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture), 'Utc')
  [long]([DateTimeOffset]$dt).ToUnixTimeMilliseconds()
}

# ---------- HTTP with retry ----------
function Invoke-Http([string]$Url, [int]$Retries = 2, [int]$TimeoutSec = 25) {
  $last = $null
  for ($a = 0; $a -le $Retries; $a++) {
    try { return Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec $TimeoutSec }
    catch { $last = $_; if ($a -lt $Retries) { Start-Sleep -Seconds (1 + $a) } }
  }
  throw $last
}

function Invoke-Bybit([string]$PathAndQuery) {
  # try remembered-good base first, then the rest
  $bases = @()
  if ($script:BybitBaseGood) { $bases += $script:BybitBaseGood }
  $bases += @($script:BybitBases | Where-Object { $_ -ne $script:BybitBaseGood })
  $last = $null
  foreach ($b in $bases) {
    try {
      $r = Invoke-Http ($b + $PathAndQuery) 1 25
      if ($null -ne $r.retCode -and [int]$r.retCode -ne 0) { throw "retCode=$($r.retCode) $($r.retMsg)" }
      $script:BybitBaseGood = $b
      return $r
    } catch { $last = $_ }
  }
  throw "bybit unreachable on all bases: $last"
}

# ---------- klines (normalized: objects t,o,h,l,c,v ; CLOSED bars only; ascending) ----------
# interval: minutes as Bybit code ('1','60','240'). $StartMs inclusive, $EndMs exclusive-ish.
function Get-Klines([string]$Sym, [string]$Interval, [long]$StartMs, [long]$EndMs, [long]$NowMs) {
  $stepMs = [long]$Interval * 60000L
  $rows = $null
  try { $rows = Get-KlinesBybit $Sym $Interval $StartMs $EndMs }
  catch {
    Write-Warning "bybit klines failed for $Sym ($($_.Exception.Message)); trying BingX"
    $rows = Get-KlinesBingx $Sym $Interval $StartMs $EndMs
  }
  # closed bars only, in range, ascending
  $out = @($rows | Where-Object { ($_.t + $stepMs) -le $NowMs -and $_.t -ge $StartMs -and $_.t -lt $EndMs } | Sort-Object t)
  return ,$out
}

function Get-KlinesBybit([string]$Sym, [string]$Interval, [long]$StartMs, [long]$EndMs) {
  $bs = $Sym.Replace('-', '')
  $all = New-Object System.Collections.Generic.List[object]
  $cursorEnd = $EndMs
  $guard = 0
  while ($cursorEnd -gt $StartMs) {
    $guard++; if ($guard -gt 400) { throw "kline pagination runaway $Sym" }
    $u = "/v5/market/kline?category=linear&symbol=$bs&interval=$Interval&start=$StartMs&end=$cursorEnd&limit=1000"
    $r = Invoke-Bybit $u
    $list = @($r.result.list)
    if (-not $list -or $list.Count -eq 0) { break }
    $minTs = [long]::MaxValue
    foreach ($k in $list) {
      $ts = [long]$k[0]
      if ($ts -lt $minTs) { $minTs = $ts }
      $all.Add([pscustomobject]@{ t = $ts; o = [double]$k[1]; h = [double]$k[2]; l = [double]$k[3]; c = [double]$k[4]; v = [double]$k[5] })
    }
    if ($minTs -le $StartMs) { break }
    $cursorEnd = $minTs - 1
    Start-Sleep -Milliseconds 60
  }
  return ,$all.ToArray()   # PS 5.1: @($genericList) кидает "Argument types do not match"
}

function Get-KlinesBingx([string]$Sym, [string]$Interval, [long]$StartMs, [long]$EndMs) {
  $iv = switch ($Interval) { '1' { '1m' } '60' { '1h' } '240' { '4h' } default { throw "bingx interval map missing for $Interval" } }
  $all = New-Object System.Collections.Generic.List[object]
  $cursorEnd = $EndMs
  $guard = 0
  while ($cursorEnd -gt $StartMs) {
    $guard++; if ($guard -gt 400) { throw "bingx kline pagination runaway $Sym" }
    $u = "https://open-api.bingx.com/openApi/swap/v3/quote/klines?symbol=$Sym&interval=$iv&limit=1000&startTime=$StartMs&endTime=$cursorEnd"
    $r = Invoke-Http $u
    if ([int]$r.code -ne 0) { throw "bingx code=$($r.code)" }
    $list = @($r.data)
    if (-not $list -or $list.Count -eq 0) { break }
    $minTs = [long]::MaxValue
    foreach ($k in $list) {
      $ts = [long]$k.time
      if ($ts -lt $minTs) { $minTs = $ts }
      $all.Add([pscustomobject]@{ t = $ts; o = [double]$k.open; h = [double]$k.high; l = [double]$k.low; c = [double]$k.close; v = [double]$k.volume })
    }
    if ($minTs -le $StartMs) { break }
    $cursorEnd = $minTs - 1
    Start-Sleep -Milliseconds 80
  }
  return ,$all.ToArray()
}

# ---------- funding history map: 8h-slot ts(ms) -> rate (fraction per 8h) ----------
function Get-FundingMap([string]$Sym, [long]$StartMs, [long]$EndMs) {
  $bs = $Sym.Replace('-', '')
  $map = @{}
  try {
    $cursorEnd = $EndMs
    $guard = 0
    while ($cursorEnd -gt $StartMs) {
      $guard++; if ($guard -gt 60) { break }
      $u = "/v5/market/funding/history?category=linear&symbol=$bs&startTime=$StartMs&endTime=$cursorEnd&limit=200"
      $r = Invoke-Bybit $u
      $list = @($r.result.list)
      if (-not $list -or $list.Count -eq 0) { break }
      $minTs = [long]::MaxValue
      foreach ($f in $list) {
        $ts = [long]$f.fundingRateTimestamp
        if ($ts -lt $minTs) { $minTs = $ts }
        $map[$ts] = [double]$f.fundingRate
      }
      if ($minTs -le $StartMs) { break }
      $cursorEnd = $minTs - 1
      Start-Sleep -Milliseconds 60
    }
  } catch {
    # BingX fallback: funding rate history
    try {
      $u = "https://open-api.bingx.com/openApi/swap/v2/quote/fundingRate?symbol=$Sym&limit=500"
      $r = Invoke-Http $u
      foreach ($f in @($r.data)) {
        $ts = [long]$f.fundingTime
        if ($ts -ge $StartMs -and $ts -le $EndMs) { $map[$ts] = [double]$f.fundingRate }
      }
    } catch { Write-Warning "funding history unavailable for $Sym ($($_.Exception.Message)) - default rate will be used" }
  }
  return $map
}

# rate at slot: exact match, else latest earlier entry, else default
function Get-FundingRateAt([hashtable]$Map, [long]$SlotTs, [double]$Default = 0.0001) {
  if ($Map.ContainsKey($SlotTs)) { return [double]$Map[$SlotTs] }
  $best = [long]-1
  foreach ($k in $Map.Keys) { if ([long]$k -le $SlotTs -and [long]$k -gt $best) { $best = [long]$k } }
  if ($best -ge 0) { return [double]$Map[$best] }
  return $Default
}

# ---------- bulk tickers: sym -> lastPrice ----------
function Get-TickersAll([string[]]$Syms) {
  $want = @{}
  foreach ($s in $Syms) { $want[$s.Replace('-', '')] = $s }
  $out = @{}
  try {
    $r = Invoke-Bybit "/v5/market/tickers?category=linear"
    foreach ($t in @($r.result.list)) {
      if ($want.ContainsKey($t.symbol)) { $out[$want[$t.symbol]] = [double]$t.lastPrice }
    }
  } catch {
    Write-Warning "bybit tickers failed ($($_.Exception.Message)); trying BingX per-symbol"
    foreach ($s in $Syms) {
      try {
        $r = Invoke-Http "https://open-api.bingx.com/openApi/swap/v2/quote/ticker?symbol=$s"
        if ([int]$r.code -eq 0) { $out[$s] = [double]$r.data.lastPrice }
      } catch {}
    }
  }
  return $out
}

# ---------- indicators (EXACT copies of scan_signals.ps1 - trail must match the scanner) ----------
function EMAseries([double[]]$v, [int]$p) {
  $n = $v.Count; $o = New-Object 'double[]' $n; $k = 2.0 / ($p + 1); $s = 0.0
  for ($i = 0; $i -lt $n; $i++) {
    if ($i -lt $p) { $s += $v[$i]; $o[$i] = [double]::NaN; if ($i -eq $p - 1) { $o[$i] = $s / $p } }
    else { $o[$i] = $v[$i] * $k + $o[$i - 1] * (1 - $k) }
  }
  ,$o
}

# ---------- JSON io ----------
function Read-JsonFile([string]$Path) {
  if (-not (Test-Path $Path)) { return $null }
  Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}
function ToArr($x) {
  # PS 5.1: return из функции разворачивает массив из 0/1 элементов в скаляр -
  # унарная запятая сохраняет форму массива (иначе legs/open_positions из 1 элемента
  # сериализуются объектом вместо [..]).
  $a = [object[]]@($x | ForEach-Object { $_ })
  return ,$a
}
function Write-JsonAtomic([string]$Path, $Obj, [int]$Depth = 10) {
  $tmp = "$Path.tmp"
  # -InputObject (не пайплайн!): пайплайн разворачивает массив из 1 элемента в объект
  $json = ConvertTo-Json -InputObject $Obj -Depth $Depth
  # Out-File utf8 in PS5.1 writes BOM; readers here use -Encoding UTF8 which tolerates it
  $json | Out-File $tmp -Encoding utf8
  Move-Item -Force $tmp $Path
}

# ---------- journal / tick log ----------
function Write-Journal([string]$Root, [string]$Text) {
  $p = Join-Path $Root 'journal.md'
  [IO.File]::AppendAllText($p, $Text, (New-Object System.Text.UTF8Encoding($false)))
}
function Write-TickLog([string]$Root, [string]$Line) {
  $p = Join-Path $Root 'data\auto_trade_log.txt'
  $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
  [IO.File]::AppendAllText($p, "$stamp`Z $Line`r`n", (New-Object System.Text.UTF8Encoding($false)))
  try {
    $fi = Get-Item $p
    if ($fi.Length -gt 500KB) {
      $txt = [IO.File]::ReadAllText($p)
      $keep = $txt.Substring([int]($txt.Length / 2))
      $nl = $keep.IndexOf("`n")
      if ($nl -ge 0) { $keep = $keep.Substring($nl + 1) }
      [IO.File]::WriteAllText($p, $keep, (New-Object System.Text.UTF8Encoding($false)))
    }
  } catch {}
}

# ---------- lock ----------
function Acquire-EngineLock([string]$Root, [switch]$Force) {
  $lock = Join-Path $Root 'data\auto_trade.lock'
  if ($Force -and (Test-Path $lock)) { Remove-Item $lock -Force -ErrorAction SilentlyContinue }
  try {
    $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $w = New-Object IO.StreamWriter($fs); $w.WriteLine("pid=$PID utc=$((Get-Date).ToUniversalTime().ToString('u'))"); $w.Flush()
    return @{ stream = $fs; writer = $w; path = $lock }
  } catch [System.IO.IOException] {
    $fi = Get-Item $lock -ErrorAction SilentlyContinue
    if ($fi -and ((Get-Date) - $fi.LastWriteTime).TotalMinutes -gt 10) {
      Remove-Item $lock -Force -ErrorAction SilentlyContinue
      try {
        $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $w = New-Object IO.StreamWriter($fs); $w.WriteLine("pid=$PID stale-takeover"); $w.Flush()
        return @{ stream = $fs; writer = $w; path = $lock }
      } catch { return $null }
    }
    return $null
  }
}
function Release-EngineLock($Lock) {
  if ($null -eq $Lock) { return }
  try { $Lock.writer.Dispose(); $Lock.stream.Dispose() } catch {}
  try { Remove-Item $Lock.path -Force -ErrorAction SilentlyContinue } catch {}
}
