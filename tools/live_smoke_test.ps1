# live_smoke_test.ps1 - supervised smoke test of the signed Bybit layer. ASCII only (runs on PS 5.1 too).
# Without switches: read-only checks (server time, wallet, instruments, sizing table).
# -PlaceOrder: min-lot round-trip on $TestSymbol - market entry with SL, then reduce-only market close.
#   Costs cents in fees; verifies the ENTIRE order path (signing, SL attach, reduceOnly, executions).
# Env required: BYBIT_API_KEY, BYBIT_API_SECRET.
param(
  [switch]$PlaceOrder,
  [string]$TestSymbol = 'ETH-USDT',
  [string]$Root = ''
)
$ErrorActionPreference = 'Stop'
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'lib_engine.ps1')
. (Join-Path $PSScriptRoot 'lib_bybit_live.ps1')

$SYMBOLS = @('BTC-USDT','ETH-USDT','SOL-USDT','BNB-USDT','XRP-USDT','DOGE-USDT','ADA-USDT','AVAX-USDT','LINK-USDT')
$RISKPCT = 0.01   # mirror auto_trade.ps1
$ASSUMED_STOP_PCT = 0.02

'=== BYBIT LIVE SMOKE TEST ==='
$off = Sync-BybitTime
"server time offset: $off ms $(if ([math]::Abs($off) -gt 2000) { '  <-- WARNING: fix clock sync (chrony)!' })"

$w = Get-WalletEquity
"wallet (UNIFIED): totalEquity=$($w.totalEquity) USDT, available=$($w.availableUsd)"
$equity = [double]$w.totalEquity

''
'--- positions / open orders ---'
$pos = Get-PositionsLive
if ($pos.Count) { $pos | ForEach-Object { "  POS $($_.symbol) $($_.side) size=$($_.size) avg=$($_.avgPrice) SL='$($_.stopLoss)'" } } else { '  no open positions' }
$ord = Get-OpenOrdersLive
if (@($ord).Count) { @($ord) | ForEach-Object { "  ORD $($_.symbol) $($_.side) $($_.orderType) qty=$($_.qty) px=$($_.price) link=$($_.orderLinkId)" } } else { '  no open orders' }

''
'--- instruments / tradeability at current equity (risk 1%, assumed stop 2%) ---'
$instCache = Join-Path $Root 'data/live_real/instruments.json'
[void][IO.Directory]::CreateDirectory((Join-Path $Root 'data/live_real'))
$inst = Get-InstrumentsInfo $SYMBOLS $instCache
$tickers = Get-TickersAll $SYMBOLS
"{0,-10} {1,12} {2,10} {3,10} {4,12} {5,14} {6}" -f 'symbol','price','qtyStep','minQty','minNotional','computedQty','verdict'
foreach ($s in $SYMBOLS) {
  if (-not $tickers.ContainsKey($s)) { "{0,-10} no ticker" -f $s; continue }
  $px = [double]$tickers[$s]
  $i = $inst[$s]
  $stopDist = $px * $ASSUMED_STOP_PCT
  $riskUsd = $equity * $RISKPCT
  $qty = $riskUsd / $stopDist
  $qtyStr = Format-FloorToStep $qty $i.qtyStep
  $qtyF = [double]::Parse($qtyStr, [Globalization.CultureInfo]::InvariantCulture)
  $minQ = [double]::Parse($i.minOrderQty, [Globalization.CultureInfo]::InvariantCulture)
  $verdict = if ($qtyF -ge 2 * $minQ -and ($qtyF * $px) -ge $i.minNotional) { 'OK' }
             elseif (($minQ * 2 * $stopDist) -le 1.5 * $riskUsd) { 'ROUND-UP' }
             else { 'SKIP (minlot)' }
  "{0,-10} {1,12} {2,10} {3,10} {4,12} {5,14} {6}" -f $s, $px, $i.qtyStep, $i.minOrderQty, $i.minNotional, $qtyStr, $verdict
}

if (-not $PlaceOrder) {
  ''
  'Read-only checks done. Re-run with -PlaceOrder for the min-lot round-trip test.'
  return
}

''
"=== ROUND-TRIP TEST: $TestSymbol min lot ==="
$i = $inst[$TestSymbol]
$px = [double]$tickers[$TestSymbol]
$qtyStr = $i.minOrderQty
$slStr = Format-RoundToTick ($px * 0.98) $i.tickSize
$stamp = UtcNowMs
$linkE = "SMOKE$stamp-entry"
$linkC = "SMOKE$stamp-close"
"entry: market BUY $qtyStr $TestSymbol (~$([math]::Round([double]::Parse($qtyStr,[Globalization.CultureInfo]::InvariantCulture)*$px,2)) USDT) with SL $slStr"

try { [void](Set-LeverageSafe $TestSymbol 5) } catch { "set-leverage: $($_.Exception.Message)" }
$r = Place-MarketEntry $TestSymbol 'long' $qtyStr $slStr $linkE
if (-not $r.ok) { throw "entry FAILED: retCode=$($r.retCode) $($r.retMsg)" }
"entry placed: orderId=$($r.orderId) dup=$($r.dup)"
Start-Sleep -Seconds 3

$pos2 = Get-PositionsLive
$mine = @($pos2 | Where-Object { $_.symbol -eq ($TestSymbol.Replace('-','')) })
if ($mine.Count) { "position: size=$($mine[0].size) avg=$($mine[0].avgPrice) SL='$($mine[0].stopLoss)' $(if ("$($mine[0].stopLoss)" -eq '') { '<-- WARNING: SL NOT ATTACHED' })" }
else { 'WARNING: position not visible yet' }

"closing (reduce-only market)..."
$sizeStr = if ($mine.Count) { ([double]$mine[0].size).ToString([Globalization.CultureInfo]::InvariantCulture) } else { $qtyStr }
$rc = Close-PositionMarket $TestSymbol 'long' $sizeStr $linkC
if (-not $rc.ok) { throw "close FAILED: retCode=$($rc.retCode) $($rc.retMsg)" }
"close placed (alreadyFlat=$($rc.alreadyFlat))"
Start-Sleep -Seconds 3

'--- executions of this test ---'
$ex = Get-ExecutionsSince ($stamp - 5000)
foreach ($e in $ex) {
  if ("$($e.orderLinkId)" -like "SMOKE$stamp*") {
    "  $($e.execType) $($e.symbol) $($e.side) qty=$($e.execQty) px=$($e.execPrice) fee=$($e.execFee) link=$($e.orderLinkId)"
  }
}
$pos3 = Get-PositionsLive
$left = @($pos3 | Where-Object { $_.symbol -eq ($TestSymbol.Replace('-','')) })
if ($left.Count) { "WARNING: position still open: size=$($left[0].size) - close it manually!" } else { 'position flat - round trip OK' }
$w2 = Get-WalletEquity
"wallet after: totalEquity=$($w2.totalEquity) USDT (delta $([math]::Round([double]$w2.totalEquity - $equity, 4)))"
'=== SMOKE TEST DONE ==='
