# lib_bybit_live.ps1 - signed Bybit v5 API layer for the LIVE (real-money) executor.
# Dot-source this file. PS 5.1 and PS 7 compatible. ASCII only.
# Keys come from env: BYBIT_API_KEY / BYBIT_API_SECRET (never stored in the repo).
# Every function talks to api.bybit.com with api.bytick.com as signed-mirror fallback.
# Money-safety invariants:
#   - the key must be created trade-only (no withdraw/transfer) and IP-whitelisted;
#   - qty/price are always passed as invariant-culture strings floored to the
#     instrument's step (never scientific notation);
#   - "already done" retCodes (110043 leverage, 34040 trading-stop, 110017 reduce-only
#     on a flat position) are treated as success so retries stay idempotent.

$script:LiveBases = @('https://api.bybit.com', 'https://api.bytick.com')
$script:LiveBaseGood = $null
$script:LiveRecvWindow = '5000'
$script:LiveTimeOffsetMs = [long]0   # serverTime - localTime

function Get-LiveApiKey {
  if (-not $env:BYBIT_API_KEY -or -not $env:BYBIT_API_SECRET) { throw 'BYBIT_API_KEY / BYBIT_API_SECRET are not set in the environment' }
  return @{ key = $env:BYBIT_API_KEY; secret = $env:BYBIT_API_SECRET }
}

# ---------- time sync ----------
function Sync-BybitTime {
  foreach ($b in $script:LiveBases) {
    try {
      $r = Invoke-RestMethod -Uri "$b/v5/market/time" -TimeoutSec 15
      if ([int]$r.retCode -eq 0) {
        $srvMs = [long]$r.result.timeSecond * 1000L
        $script:LiveTimeOffsetMs = $srvMs - (UtcNowMs)
        return $script:LiveTimeOffsetMs
      }
    } catch {}
  }
  throw 'bybit server time unreachable on all bases'
}

# ---------- signing ----------
function Get-BybitSignature([string]$Secret, [string]$Payload) {
  $hmac = New-Object System.Security.Cryptography.HMACSHA256
  $hmac.Key = [Text.Encoding]::UTF8.GetBytes($Secret)
  $hash = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Payload))
  $sb = New-Object System.Text.StringBuilder
  foreach ($byte in $hash) { [void]$sb.Append($byte.ToString('x2')) }
  return $sb.ToString()
}

# Core signed call. Returns the raw response object (caller checks retCode).
# Throws only when every base fails at the transport level.
# $Query: raw query string WITHOUT '?', exactly as sent (it is what gets signed).
# $BodyJson: raw JSON string, exactly as sent (it is what gets signed).
function Invoke-BybitSigned {
  param(
    [ValidateSet('GET','POST')][string]$Method,
    [string]$Path,
    [string]$Query = '',
    [string]$BodyJson = ''
  )
  $creds = Get-LiveApiKey
  $bases = @()
  if ($script:LiveBaseGood) { $bases += $script:LiveBaseGood }
  $bases += @($script:LiveBases | Where-Object { $_ -ne $script:LiveBaseGood })
  $last = $null
  foreach ($b in $bases) {
    for ($attempt = 1; $attempt -le 2; $attempt++) {
      $ts = [string]((UtcNowMs) + $script:LiveTimeOffsetMs)
      $payload = if ($Method -eq 'GET') { "$ts$($creds.key)$($script:LiveRecvWindow)$Query" } else { "$ts$($creds.key)$($script:LiveRecvWindow)$BodyJson" }
      $headers = @{
        'X-BAPI-API-KEY'     = $creds.key
        'X-BAPI-TIMESTAMP'   = $ts
        'X-BAPI-RECV-WINDOW' = $script:LiveRecvWindow
        'X-BAPI-SIGN'        = (Get-BybitSignature $creds.secret $payload)
      }
      try {
        $r = $null
        if ($Method -eq 'GET') {
          $u = if ($Query) { "$b$Path`?$Query" } else { "$b$Path" }
          $r = Invoke-RestMethod -Uri $u -Method Get -Headers $headers -TimeoutSec 20
        } else {
          $r = Invoke-RestMethod -Uri "$b$Path" -Method Post -Headers $headers -Body $BodyJson -ContentType 'application/json' -TimeoutSec 20
        }
        if ([int]$r.retCode -eq 10002 -and $attempt -eq 1) {
          # timestamp outside recv_window: resync clock offset and retry once on the same base
          try { [void](Sync-BybitTime) } catch {}
          continue
        }
        $script:LiveBaseGood = $b
        return $r
      } catch {
        $last = $_
        break   # transport error: next base (no same-base retry to keep order calls single-shot)
      }
    }
  }
  throw "bybit signed API unreachable on all bases: $last"
}

function Assert-BybitRet($R, [int[]]$OkCodes = @(0), [string]$What = 'call') {
  if ($OkCodes -notcontains [int]$R.retCode) { throw "bybit $What failed: retCode=$($R.retCode) $($R.retMsg)" }
  return $R
}

# ---------- number formatting (culture-safe, step-aware) ----------
function Get-StepDecimals([string]$StepStr) {
  $s = $StepStr.TrimEnd('0')
  $i = $s.IndexOf('.')
  if ($i -lt 0) { return 0 }
  return ($s.Length - $i - 1)
}
# Floor a value to the instrument step; returns the API-ready string.
function Format-FloorToStep([double]$Value, [string]$StepStr) {
  $step = [double]::Parse($StepStr, [Globalization.CultureInfo]::InvariantCulture)
  if ($step -le 0) { throw "bad step '$StepStr'" }
  $n = [math]::Floor($Value / $step + 1e-9)
  $v = $n * $step
  $dec = Get-StepDecimals $StepStr
  $out = $v.ToString("F$dec", [Globalization.CultureInfo]::InvariantCulture)
  if ($out.Contains('.')) { $out = $out.TrimEnd('0').TrimEnd('.') }
  if (-not $out) { $out = '0' }
  return $out
}
# Round a price to the nearest tick; returns the API-ready string.
function Format-RoundToTick([double]$Value, [string]$TickStr) {
  $tick = [double]::Parse($TickStr, [Globalization.CultureInfo]::InvariantCulture)
  if ($tick -le 0) { throw "bad tick '$TickStr'" }
  $n = [math]::Round($Value / $tick, 0, [MidpointRounding]::AwayFromZero)
  $v = $n * $tick
  $dec = Get-StepDecimals $TickStr
  $out = $v.ToString("F$dec", [Globalization.CultureInfo]::InvariantCulture)
  if ($out.Contains('.')) { $out = $out.TrimEnd('0').TrimEnd('.') }
  if (-not $out) { $out = '0' }
  return $out
}

# ---------- account / market info ----------
function Get-WalletEquity {
  $r = Assert-BybitRet (Invoke-BybitSigned GET '/v5/account/wallet-balance' 'accountType=UNIFIED') @(0) 'wallet-balance'
  $acc = @($r.result.list)[0]
  if ($null -eq $acc) { throw 'wallet-balance: empty account list' }
  return [pscustomobject]@{
    totalEquity    = [double]$acc.totalEquity
    availableUsd   = if ("$($acc.totalAvailableBalance)" -ne '') { [double]$acc.totalAvailableBalance } else { $null }
  }
}

# sym ('ETH-USDT') -> filters; cached to $CachePath for 24h
function Get-InstrumentsInfo([string[]]$Syms, [string]$CachePath = '') {
  $cache = $null
  if ($CachePath -and (Test-Path $CachePath)) {
    try {
      $cache = Get-Content $CachePath -Raw -Encoding UTF8 | ConvertFrom-Json
      $ageH = ((UtcNowMs) - [long]$cache.fetchedMs) / 3600000.0
      $haveAll = $true
      foreach ($s in $Syms) { if (-not $cache.map.PSObject.Properties[$s]) { $haveAll = $false; break } }
      if ($ageH -lt 24 -and $haveAll) {
        $out = @{}
        foreach ($s in $Syms) { $out[$s] = $cache.map.$s }
        return $out
      }
    } catch {}
  }
  $out = @{}
  foreach ($s in $Syms) {
    $bs = $s.Replace('-', '')
    $r = Assert-BybitRet (Invoke-BybitSigned GET '/v5/market/instruments-info' "category=linear&symbol=$bs") @(0) "instruments-info $s"
    $row = @($r.result.list)[0]
    if ($null -eq $row) { throw "instruments-info: no data for $s" }
    $out[$s] = [pscustomobject]@{
      symbol      = $s
      qtyStep     = [string]$row.lotSizeFilter.qtyStep
      minOrderQty = [string]$row.lotSizeFilter.minOrderQty
      minNotional = if ("$($row.lotSizeFilter.minNotionalValue)" -ne '') { [double]$row.lotSizeFilter.minNotionalValue } else { 5.0 }
      tickSize    = [string]$row.priceFilter.tickSize
      maxLeverage = [double]$row.leverageFilter.maxLeverage
    }
    Start-Sleep -Milliseconds 60
  }
  if ($CachePath) {
    $map = [ordered]@{}
    foreach ($k in $out.Keys) { $map[$k] = $out[$k] }
    $obj = [pscustomobject]@{ fetchedMs = (UtcNowMs); map = [pscustomobject]$map }
    try { Write-JsonAtomic $CachePath $obj 6 } catch {}
  }
  return $out
}

# ---------- positions / orders / executions (read) ----------
function Get-PositionsLive {
  $r = Assert-BybitRet (Invoke-BybitSigned GET '/v5/position/list' 'category=linear&settleCoin=USDT') @(0) 'position/list'
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($p in @($r.result.list)) {
    if ([double]$p.size -le 0) { continue }
    $out.Add([pscustomobject]@{
      symbol    = $p.symbol            # exchange form, e.g. ETHUSDT
      side      = [string]$p.side      # Buy / Sell
      size      = [double]$p.size
      avgPrice  = [double]$p.avgPrice
      stopLoss  = [string]$p.stopLoss  # '' when no SL is attached!
      takeProfit= [string]$p.takeProfit
      liqPrice  = [string]$p.liqPrice
      unrealPnl = if ("$($p.unrealisedPnl)" -ne '') { [double]$p.unrealisedPnl } else { 0.0 }
    })
  }
  return ,$out.ToArray()
}

function Get-OpenOrdersLive {
  $r = Assert-BybitRet (Invoke-BybitSigned GET '/v5/order/realtime' 'category=linear&settleCoin=USDT') @(0) 'order/realtime'
  return ,@($r.result.list)
}

# executions (fills + funding) since $StartMs, ascending by execTime; cursor-paginated
function Get-ExecutionsSince([long]$StartMs) {
  $all = New-Object System.Collections.Generic.List[object]
  $cursor = ''
  $guard = 0
  while ($true) {
    $guard++; if ($guard -gt 40) { throw 'execution/list pagination runaway' }
    $q = "category=linear&startTime=$StartMs&limit=100"
    if ($cursor) { $q += "&cursor=$([uri]::EscapeDataString($cursor))" }
    $r = Assert-BybitRet (Invoke-BybitSigned GET '/v5/execution/list' $q) @(0) 'execution/list'
    foreach ($e in @($r.result.list)) { $all.Add($e) }
    $cursor = [string]$r.result.nextPageCursor
    if (-not $cursor) { break }
    Start-Sleep -Milliseconds 60
  }
  $sorted = @($all.ToArray() | Sort-Object { [long]$_.execTime })
  return ,$sorted
}

# order lookup by our idempotency id: realtime first, then history (crash recovery)
function Get-OrderByLinkId([string]$LinkId) {
  $r = Invoke-BybitSigned GET '/v5/order/realtime' "category=linear&orderLinkId=$LinkId"
  if ([int]$r.retCode -eq 0) {
    $row = @($r.result.list)[0]
    if ($null -ne $row) { return $row }
  }
  $r = Invoke-BybitSigned GET '/v5/order/history' "category=linear&orderLinkId=$LinkId"
  if ([int]$r.retCode -eq 0) {
    $row = @($r.result.list)[0]
    if ($null -ne $row) { return $row }
  }
  return $null
}

# ---------- orders (write) ----------
# 110043 = leverage not modified -> success
function Set-LeverageSafe([string]$Sym, [double]$Lev) {
  $bs = $Sym.Replace('-', '')
  $levStr = $Lev.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
  $body = ConvertTo-Json -Compress -InputObject ([ordered]@{
    category = 'linear'; symbol = $bs; buyLeverage = $levStr; sellLeverage = $levStr
  })
  $r = Invoke-BybitSigned POST '/v5/position/set-leverage' -BodyJson $body
  [void](Assert-BybitRet $r @(0, 110043) "set-leverage $Sym")
  return $true
}

# Market entry with attached Full-mode SL (covers the whole position even after partial closes).
# Returns @{ok; dup; orderId; raw}. Duplicate orderLinkId is reported as dup (idempotent retry).
function Place-MarketEntry([string]$Sym, [string]$Side, [string]$QtyStr, [string]$SlPriceStr, [string]$LinkId) {
  $bs = $Sym.Replace('-', '')
  $bySide = if ($Side -eq 'long') { 'Buy' } else { 'Sell' }
  $body = ConvertTo-Json -Compress -InputObject ([ordered]@{
    category = 'linear'; symbol = $bs; side = $bySide; orderType = 'Market'
    qty = $QtyStr; positionIdx = 0; timeInForce = 'IOC'
    stopLoss = $SlPriceStr; tpslMode = 'Full'; slTriggerBy = 'LastPrice'; slOrderType = 'Market'
    orderLinkId = $LinkId
  })
  $r = Invoke-BybitSigned POST '/v5/order/create' -BodyJson $body
  $code = [int]$r.retCode
  if ($code -eq 0) { return @{ ok = $true; dup = $false; orderId = [string]$r.result.orderId; raw = $r } }
  if ($code -eq 110072 -or "$($r.retMsg)" -match 'duplicat') { return @{ ok = $true; dup = $true; orderId = ''; raw = $r } }
  return @{ ok = $false; dup = $false; orderId = ''; retCode = $code; retMsg = [string]$r.retMsg; raw = $r }
}

# TP1: reduce-only GTC limit for half the position (maker fee; never opens exposure)
function Place-Tp1Limit([string]$Sym, [string]$PosSide, [string]$QtyStr, [string]$PriceStr, [string]$LinkId) {
  $bs = $Sym.Replace('-', '')
  $bySide = if ($PosSide -eq 'long') { 'Sell' } else { 'Buy' }   # opposite of the position
  $body = ConvertTo-Json -Compress -InputObject ([ordered]@{
    category = 'linear'; symbol = $bs; side = $bySide; orderType = 'Limit'
    qty = $QtyStr; price = $PriceStr; positionIdx = 0; timeInForce = 'GTC'
    reduceOnly = $true; orderLinkId = $LinkId
  })
  $r = Invoke-BybitSigned POST '/v5/order/create' -BodyJson $body
  $code = [int]$r.retCode
  if ($code -eq 0) { return @{ ok = $true; dup = $false; orderId = [string]$r.result.orderId; raw = $r } }
  if ($code -eq 110072 -or "$($r.retMsg)" -match 'duplicat') { return @{ ok = $true; dup = $true; orderId = ''; raw = $r } }
  return @{ ok = $false; dup = $false; orderId = ''; retCode = $code; retMsg = [string]$r.retMsg; raw = $r }
}

# Amend the position's Full-mode SL (breakeven move, manual trail). 34040 = not modified -> ok.
function Set-StopLossPrice([string]$Sym, [string]$SlPriceStr) {
  $bs = $Sym.Replace('-', '')
  $body = ConvertTo-Json -Compress -InputObject ([ordered]@{
    category = 'linear'; symbol = $bs; positionIdx = 0
    tpslMode = 'Full'; stopLoss = $SlPriceStr; slTriggerBy = 'LastPrice'
  })
  $r = Invoke-BybitSigned POST '/v5/position/trading-stop' -BodyJson $body
  [void](Assert-BybitRet $r @(0, 34040) "trading-stop $Sym")
  return $true
}

# Market close (reduce-only). 110017 (qty exceeds / position is zero) = already flat -> ok.
function Close-PositionMarket([string]$Sym, [string]$PosSide, [string]$QtyStr, [string]$LinkId) {
  $bs = $Sym.Replace('-', '')
  $bySide = if ($PosSide -eq 'long') { 'Sell' } else { 'Buy' }
  $body = ConvertTo-Json -Compress -InputObject ([ordered]@{
    category = 'linear'; symbol = $bs; side = $bySide; orderType = 'Market'
    qty = $QtyStr; positionIdx = 0; timeInForce = 'IOC'
    reduceOnly = $true; orderLinkId = $LinkId
  })
  $r = Invoke-BybitSigned POST '/v5/order/create' -BodyJson $body
  $code = [int]$r.retCode
  if ($code -eq 0) { return @{ ok = $true; alreadyFlat = $false } }
  if ($code -eq 110017) { return @{ ok = $true; alreadyFlat = $true } }
  if ($code -eq 110072 -or "$($r.retMsg)" -match 'duplicat') { return @{ ok = $true; alreadyFlat = $false; dup = $true } }
  return @{ ok = $false; retCode = $code; retMsg = [string]$r.retMsg }
}

function Cancel-AllOrders {
  $body = ConvertTo-Json -Compress -InputObject ([ordered]@{ category = 'linear'; settleCoin = 'USDT' })
  $r = Invoke-BybitSigned POST '/v5/order/cancel-all' -BodyJson $body
  [void](Assert-BybitRet $r @(0) 'cancel-all')
  return $true
}

function Cancel-OrderByLinkId([string]$Sym, [string]$LinkId) {
  $bs = $Sym.Replace('-', '')
  $body = ConvertTo-Json -Compress -InputObject ([ordered]@{ category = 'linear'; symbol = $bs; orderLinkId = $LinkId })
  $r = Invoke-BybitSigned POST '/v5/order/cancel' -BodyJson $body
  # 110001 order not exists / already filled-cancelled -> treat as done
  [void](Assert-BybitRet $r @(0, 110001) "cancel $LinkId")
  return $true
}
