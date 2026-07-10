# Cross-sectional momentum backtest on MOEX cash equities (long-only, monthly rebalance).
# Rank tickers by trailing return (LookbackDays, optionally skipping the most recent SkipDays),
# hold TopK names with positive momentum, only while IMOEX close > EMA(IndexEma).
# Costs: CostPct per side on actual turnover. Price-return only (dividends NOT included -
# understates RU equity returns by roughly the dividend yield; note this in reports).
# Outputs into DataDir: bt_equity_{OutTag}.json, bt_monthly_{OutTag}.json, bt_trades_{OutTag}.json
param(
  [string[]]$Tickers = @('SBER','GAZP','LKOH','ROSN','NVTK','GMKN','TATN','MGNT','VTBR','CHMF','PLZL','YDEX'),
  [string]$DataDir = 'C:\Users\klyde\trading-sim\data\moex',
  [double]$StartEquity = 10000,
  [int]$TopK = 3,
  [int]$LookbackDays = 126,   # ~6 months of trading days
  [int]$SkipDays = 0,         # classic 12-1 style: score window ends N days back
  [double]$CostPct = 0.0013,  # commission 0.08% + slippage 0.05% per side
  [string]$IndexSymbol = 'IMOEX',
  [int]$IndexEma = 200,       # regime gate: invested only when index close > this EMA
  [double]$JumpGuardPct = 40, # exclude ticker when any |1d move| in the window exceeds this % (splits/halts, e.g. VTBR 5000:1)
  [string]$FromDate = '',
  [string]$ToDate = '',
  [string]$OutTag = 'mom',
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'

function EMAseries([double[]]$v, [int]$p) {
  $r = New-Object double[] $v.Count
  $k = 2.0 / ($p + 1); $ema = [double]::NaN
  for ($i = 0; $i -lt $v.Count; $i++) {
    if ($i -eq $p - 1) { $s = 0.0; for ($j = 0; $j -lt $p; $j++) { $s += $v[$j] }; $ema = $s / $p }
    elseif ($i -ge $p) { $ema = $v[$i] * $k + $ema * (1 - $k) }
    $r[$i] = $ema
  }
  return $r
}

# ---- load ----
$S = @{}
foreach ($sym in ($Tickers + $IndexSymbol)) {
  $path = Join-Path $DataDir "$sym`_1d.json"
  if (-not (Test-Path $path)) { Write-Warning "no data $sym"; continue }
  $bars = Get-Content $path -Raw | ConvertFrom-Json
  $t = [long[]]($bars.t); $c = [double[]]($bars.c)
  $idx = @{}; for ($i = 0; $i -lt $t.Count; $i++) { $idx[$t[$i]] = $i }
  $S[$sym] = @{ t = $t; c = $c; idx = $idx }
}
if (-not $S.ContainsKey($IndexSymbol)) { throw "index $IndexSymbol not loaded" }
$S[$IndexSymbol].ema = EMAseries $S[$IndexSymbol].c $IndexEma

# ---- timeline = index trading days ----
$timeline = $S[$IndexSymbol].t
if ($FromDate) { $fm = [long]([DateTimeOffset]::new([datetime]::SpecifyKind([datetime]$FromDate,'Utc'))).ToUnixTimeMilliseconds(); $timeline = @($timeline | Where-Object { $_ -ge $fm }) }
if ($ToDate)   { $tm = [long]([DateTimeOffset]::new([datetime]::SpecifyKind([datetime]$ToDate,'Utc'))).ToUnixTimeMilliseconds();   $timeline = @($timeline | Where-Object { $_ -le $tm }) }

# ---- state ----
$cash = $StartEquity
$hold = @{}   # sym -> @{qty; lastPx}
$actions = New-Object System.Collections.Generic.List[object]
$curve = New-Object System.Collections.Generic.List[object]
$costPaid = 0.0
$prevMonth = ''

foreach ($ts in $timeline) {
  $day = [DateTimeOffset]::FromUnixTimeMilliseconds($ts).UtcDateTime.ToString('yyyy-MM-dd')
  $month = $day.Substring(0, 7)

  # mark holdings to market
  foreach ($sym in @($hold.Keys)) {
    if ($S[$sym].idx.ContainsKey($ts)) { $hold[$sym].lastPx = $S[$sym].c[$S[$sym].idx[$ts]] }
  }

  # ---- monthly rebalance on the first trading day of each month ----
  if ($month -ne $prevMonth) {
    $prevMonth = $month
    $ii = $S[$IndexSymbol].idx[$ts]
    $gateOn = $false
    if (-not [double]::IsNaN($S[$IndexSymbol].ema[$ii])) { $gateOn = ($S[$IndexSymbol].c[$ii] -gt $S[$IndexSymbol].ema[$ii]) }

    $target = @()
    if ($gateOn) {
      $scored = @()
      foreach ($sym in $Tickers) {
        if (-not $S.ContainsKey($sym)) { continue }
        if (-not $S[$sym].idx.ContainsKey($ts)) { continue }   # must trade today to be executable
        $i = $S[$sym].idx[$ts]
        $iEnd = $i - $SkipDays; $iBeg = $iEnd - $LookbackDays
        if ($iBeg -lt 1) { continue }
        $bad = $false
        for ($j = $iBeg + 1; $j -le $i; $j++) {
          $ret = [math]::Abs($S[$sym].c[$j] / $S[$sym].c[$j - 1] - 1) * 100
          if ($ret -gt $JumpGuardPct) { $bad = $true; break }
        }
        if ($bad) { continue }
        $score = $S[$sym].c[$iEnd] / $S[$sym].c[$iBeg] - 1
        if ($score -le 0) { continue }   # absolute momentum: positive trailing return only
        $scored += [pscustomobject]@{ sym = $sym; score = $score }
      }
      $target = @($scored | Sort-Object score -Descending | Select-Object -First $TopK | ForEach-Object { $_.sym })
    }

    # sell holdings that leave the target
    foreach ($sym in @($hold.Keys)) {
      if ($target -contains $sym) { continue }
      if (-not $S[$sym].idx.ContainsKey($ts)) { continue }   # cannot trade today, keep
      $px = $S[$sym].c[$S[$sym].idx[$ts]]
      $gross = $hold[$sym].qty * $px
      $fee = $gross * $CostPct; $costPaid += $fee
      $cash += $gross - $fee
      $actions.Add([pscustomobject]@{ day = $day; action = 'sell'; sym = $sym; px = $px; qty = [math]::Round($hold[$sym].qty,4); value = [math]::Round($gross,2) })
      $hold.Remove($sym)
    }
    # buy new names with equal split of available cash
    $newNames = @($target | Where-Object { -not $hold.ContainsKey($_) })
    if ($newNames.Count -gt 0 -and $cash -gt 1) {
      $spendPer = $cash / $newNames.Count
      foreach ($sym in $newNames) {
        $px = $S[$sym].c[$S[$sym].idx[$ts]]
        $fee = $spendPer * $CostPct; $costPaid += $fee
        $qty = ($spendPer - $fee) / $px
        $cash -= $spendPer
        $hold[$sym] = @{ qty = $qty; lastPx = $px }
        $actions.Add([pscustomobject]@{ day = $day; action = 'buy'; sym = $sym; px = $px; qty = [math]::Round($qty,4); value = [math]::Round($spendPer,2) })
      }
    }
  }

  $eq = $cash
  foreach ($sym in $hold.Keys) { $eq += $hold[$sym].qty * $hold[$sym].lastPx }
  $curve.Add([pscustomobject]@{ day = $day; ts = $ts; equity = [math]::Round($eq, 2) })
}

# ---- metrics ----
$finalEq = $curve[$curve.Count - 1].equity
$peak = 0.0; $maxDD = 0.0
foreach ($p in $curve) { if ($p.equity -gt $peak) { $peak = $p.equity }; $dd = ($peak - $p.equity) / $peak; if ($dd -gt $maxDD) { $maxDD = $dd } }
$monthly = New-Object System.Collections.Generic.List[object]
$mStartEq = $StartEquity; $curM = ''; $lastEq = $StartEquity
foreach ($p in $curve) {
  $m = $p.day.Substring(0, 7)
  if ($m -ne $curM) { if ($curM -ne '') { $monthly.Add([pscustomobject]@{ month = $curM; ret_pct = [math]::Round(100 * ($lastEq / $mStartEq - 1), 2); equity = $lastEq }) }; $curM = $m; $mStartEq = $lastEq }
  $lastEq = $p.equity
}
$monthly.Add([pscustomobject]@{ month = $curM; ret_pct = [math]::Round(100 * ($lastEq / $mStartEq - 1), 2); equity = $lastEq })
$nM = $monthly.Count
$moGeo = 0.0
if ($nM -gt 0 -and $finalEq -gt 0) { $moGeo = [math]::Round(100 * ([math]::Pow($finalEq / $StartEquity, 1.0 / $nM) - 1), 2) }

ConvertTo-Json -InputObject $curve.ToArray() -Depth 3 -Compress | Out-File (Join-Path $DataDir "bt_equity_$OutTag.json") -Encoding utf8
ConvertTo-Json -InputObject $monthly.ToArray() -Depth 3 | Out-File (Join-Path $DataDir "bt_monthly_$OutTag.json") -Encoding utf8
ConvertTo-Json -InputObject $actions.ToArray() -Depth 3 | Out-File (Join-Path $DataDir "bt_trades_$OutTag.json") -Encoding utf8

if (-not $Quiet) {
  Write-Host ('=' * 60)
  Write-Host ("Momentum top{0} lb{1}d skip{2}d gate EMA{3} | {4} -> {5}" -f $TopK, $LookbackDays, $SkipDays, $IndexEma, $curve[0].day, $curve[$curve.Count-1].day)
  Write-Host ("Final equity : {0}  ({1} %total, {2} %/mo geo, {3} months)" -f $finalEq, [math]::Round(100*($finalEq/$StartEquity-1),1), $moGeo, $nM)
  Write-Host ("Max drawdown : {0} %" -f [math]::Round(100*$maxDD,1))
  Write-Host ("Rebalance actions: {0} | costs paid: {1}" -f $actions.Count, [math]::Round($costPaid,2))
  $yrs = $monthly | Group-Object { $_.month.Substring(0,4) }
  foreach ($y in $yrs) {
    $eqStart = if ($y.Name -eq $monthly[0].month.Substring(0,4)) { $StartEquity } else { ($monthly | Where-Object { $_.month.Substring(0,4) -lt $y.Name } | Select-Object -Last 1).equity }
    $eqEnd = ($y.Group | Select-Object -Last 1).equity
    Write-Host ("  {0}: {1} %" -f $y.Name, [math]::Round(100*($eqEnd/$eqStart-1),1))
  }
}
