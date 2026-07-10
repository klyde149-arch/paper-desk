# Classify every losing backtest trade into exactly one failure category.
# Input : data/bt_trades.json (enriched log from backtest.ps1)
# Output: data/failed_trades.json (losers + category + explanation) + console summary tables.
# Categories (priority order): chop-whipsaw > btc-drag > regime-flip > near-miss > instant-fail > slow-fade.
param(
  [string]$TradesPath = 'C:\Users\klyde\trading-sim\data\bt_trades.json',
  [string]$OutPath    = 'C:\Users\klyde\trading-sim\data\failed_trades.json',
  [string]$DataDir    = 'C:\Users\klyde\trading-sim\data',
  [string]$FileSuffix = '_4h',
  [int]$ChopDays      = 7,     # max gap (days) between consecutive losses on same symbol to call it chop
  [double]$InstantR   = 0.3,   # MFE below this (R) = signal failed immediately
  [double]$NearMissR  = 1.0    # MFE above this (R) but TP1 not taken = near-miss
)
$ErrorActionPreference = 'Stop'

function EMAseries([double[]]$v, [int]$p) {
  $n = $v.Count; $out = New-Object 'double[]' $n
  $k = 2.0 / ($p + 1); $sum = 0.0
  for ($i = 0; $i -lt $n; $i++) {
    if ($i -lt $p) { $sum += $v[$i]; $out[$i] = [double]::NaN; if ($i -eq $p-1){ $out[$i] = $sum/$p } }
    else { $out[$i] = $v[$i]*$k + $out[$i-1]*(1-$k) }
  }
  return $out
}

$trades = @((Get-Content $TradesPath -Raw | ConvertFrom-Json) | ForEach-Object {$_})  # PS5.1: unwrap array-in-array
if ($trades.Count -eq 0) { throw "no trades in $TradesPath" }

# ---- load candles for asset-regime-at-exit checks ----
$S = @{}
foreach ($sym in ($trades | Select-Object -ExpandProperty sym -Unique)) {
  $path = Join-Path $DataDir "$($sym.Replace('-','_'))$FileSuffix.json"
  if (-not (Test-Path $path)) { Write-Warning "no data $sym - regime-flip check skipped for it"; continue }
  $bars = Get-Content $path -Raw | ConvertFrom-Json
  $c=[double[]]($bars.c); $t=[long[]]($bars.t)
  $idx=@{}; for ($i=0;$i -lt $t.Count;$i++){ $idx[$t[$i]] = $i }
  $S[$sym] = @{ c=$c; ema20=EMAseries $c 20; ema50=EMAseries $c 50; idx=$idx }
}

# asset regime at a given ts: up / down / range / unknown
function AssetRegimeAt([string]$sym, [long]$ts) {
  if (-not $S.ContainsKey($sym)) { return 'unknown' }
  $d = $S[$sym]
  if (-not $d.idx.ContainsKey($ts)) { return 'unknown' }
  $i = $d.idx[$ts]
  $cl=$d.c[$i]; $e20=$d.ema20[$i]; $e50=$d.ema50[$i]
  if ([double]::IsNaN($e50)) { return 'unknown' }
  if (($cl -gt $e50) -and ($e20 -gt $e50)) { return 'up' }
  if (($cl -lt $e50) -and ($e20 -lt $e50)) { return 'down' }
  return 'range'
}

# ---- classification ----
$chopMs = [long]$ChopDays * 86400000
$prevBySym = @{}   # sym -> previous trade (chronological)
$losers = New-Object System.Collections.Generic.List[object]

foreach ($tr in ($trades | Sort-Object {[long]$_.entryTs})) {
  $sym = $tr.sym
  $isLoss = ($tr.pnlUsd -le 0)
  $cat = $null; $why = $null

  if ($isLoss) {
    $prev = $prevBySym[$sym]
    $assetExit = AssetRegimeAt $sym ([long]$tr.exitTs)

    if ($null -ne $prev -and $prev.pnlUsd -le 0 -and (([long]$tr.entryTs - [long]$prev.exitTs) -le $chopMs)) {
      $cat = 'chop-whipsaw'
      $why = "Повторный убыточный вход по $sym через $([math]::Round(([long]$tr.entryTs-[long]$prev.exitTs)/86400000.0,1)) дн. после предыдущего стопа — пила во флэте, тренд-логика мелет диапазон."
    }
    elseif (($tr.side -eq 'long' -and $tr.btcTrendExit -eq 'down') -or ($tr.side -eq 'short' -and $tr.btcTrendExit -eq 'up')) {
      $cat = 'btc-drag'
      $why = "BTC сменил режим с '$($tr.btcTrendEntry)' на '$($tr.btcTrendExit)' за время сделки — весь рынок пошёл против позиции и утянул актив."
    }
    elseif (($tr.side -eq 'long' -and $assetExit -ne 'up') -or ($tr.side -eq 'short' -and $assetExit -ne 'down')) {
      $cat = 'regime-flip'
      $why = "Тренд 4h самого актива сломался к моменту стопа (режим на выходе: $assetExit) — вход пришёлся на конец тренда."
    }
    elseif ($tr.mfeR -ge $NearMissR -and -not $tr.tp1done) {
      $cat = 'near-miss'
      $why = "Цена прошла $($tr.mfeR)R в плюс, но TP1 (1.5R) не взят — профит был и не зафиксирован, затем стоп."
    }
    elseif ($tr.mfeR -lt $InstantR) {
      $cat = 'instant-fail'
      $why = "MFE всего $($tr.mfeR)R — сигнал не сработал сразу: ложный возврат над EMA20, продолжения не было."
    }
    else {
      $cat = 'slow-fade'
      $why = "Небольшой ход в плюс ($($tr.mfeR)R < 1R), затем медленный слив в стоп — откат так и не превратился в продолжение тренда."
    }

    $rec = $tr | Select-Object *
    $rec | Add-Member -NotePropertyName category  -NotePropertyValue $cat
    $rec | Add-Member -NotePropertyName explain   -NotePropertyValue $why
    $rec | Add-Member -NotePropertyName assetTrendExit -NotePropertyValue $assetExit
    $rec | Add-Member -NotePropertyName pnlR -NotePropertyValue $(if($tr.riskUsd -gt 0){[math]::Round($tr.pnlUsd/$tr.riskUsd,2)}else{$null})
    $losers.Add($rec)
  }
  $prevBySym[$sym] = $tr
}

# ---- integrity check ----
$lossSumLog = [math]::Round((($trades | Where-Object {$_.pnlUsd -le 0} | Measure-Object pnlUsd -Sum).Sum),2)
$lossSumCat = [math]::Round((($losers | Measure-Object pnlUsd -Sum).Sum),2)
if ($lossSumLog -ne $lossSumCat) { throw "integrity fail: log=$lossSumLog classified=$lossSumCat" }

# ---- save archive ----
@($losers | ForEach-Object {$_}) | ConvertTo-Json -Depth 4 | Out-File $OutPath -Encoding utf8

# ---- summaries ----
"===== LOSS CLASSIFICATION ($($losers.Count) losers, $lossSumCat USD; source: $(Split-Path $TradesPath -Leaf)) ====="
"by category:"
$losers | Group-Object category | ForEach-Object {
  [pscustomobject]@{ category=$_.Name; n=$_.Count; sharePct=[math]::Round(100*$_.Count/$losers.Count,1)
    lossUsd=[math]::Round(($_.Group|Measure-Object pnlUsd -Sum).Sum,2)
    avgUsd=[math]::Round(($_.Group|Measure-Object pnlUsd -Average).Average,2)
    avgMfeR=[math]::Round(($_.Group|Measure-Object mfeR -Average).Average,2)
    avgBars=[math]::Round(($_.Group|Measure-Object barsHeld -Average).Average,1) }
} | Sort-Object lossUsd | Format-Table -AutoSize | Out-String

"by symbol x category (count):"
$syms = $losers | Select-Object -ExpandProperty sym -Unique | Sort-Object
$symRows = foreach ($s in $syms) {
  $g = @($losers | Where-Object {$_.sym -eq $s})
  $row = [ordered]@{ sym=$s; total=$g.Count; lossUsd=[math]::Round(($g|Measure-Object pnlUsd -Sum).Sum,0) }
  foreach ($c in 'chop-whipsaw','btc-drag','regime-flip','near-miss','instant-fail','slow-fade') {
    $row[$c] = @($g | Where-Object {$_.category -eq $c}).Count
  }
  [pscustomobject]$row
}
$symRows | Format-Table -AutoSize | Out-String

"by BTC regime at ENTRY (all trades - edge by regime):"
$trades | Group-Object btcTrendEntry | ForEach-Object {
  $w = @($_.Group | Where-Object {$_.pnlUsd -gt 0}); $l = @($_.Group | Where-Object {$_.pnlUsd -le 0})
  $gw = ($w | Measure-Object pnlUsd -Sum).Sum; if($null -eq $gw){$gw=0}
  $gl = [math]::Abs(($l | Measure-Object pnlUsd -Sum).Sum); if($null -eq $gl -or $gl -eq 0){$gl=0.0001}
  [pscustomobject]@{ btcAtEntry=$_.Name; trades=$_.Count; winRate=[math]::Round(100*$w.Count/$_.Count,1)
    netUsd=[math]::Round(($_.Group|Measure-Object pnlUsd -Sum).Sum,2); PF=[math]::Round($gw/$gl,2) }
} | Format-Table -AutoSize | Out-String

"losses by month:"
$losers | Group-Object {$_.exitDay.Substring(0,7)} | Sort-Object Name | ForEach-Object {
  [pscustomobject]@{ month=$_.Name; n=$_.Count; lossUsd=[math]::Round(($_.Group|Measure-Object pnlUsd -Sum).Sum,2)
    topCat=($_.Group | Group-Object category | Sort-Object Count -Descending | Select-Object -First 1).Name }
} | Format-Table -AutoSize | Out-String

"context: losers vs winners (averages):"
$w2 = @($trades | Where-Object {$_.pnlUsd -gt 0}); $l2 = @($trades | Where-Object {$_.pnlUsd -le 0})
$ctxRows = foreach ($f in 'atrPct','rsiEntry','distEma20Pct','distEma50Pct','stopDistPct','barsHeld','mfeR') {
  [pscustomobject]@{ metric=$f
    losers=[math]::Round(($l2|Measure-Object $f -Average).Average,2)
    winners=[math]::Round(($w2|Measure-Object $f -Average).Average,2) }
}
$ctxRows | Format-Table -AutoSize | Out-String
"archive saved: $OutPath"
