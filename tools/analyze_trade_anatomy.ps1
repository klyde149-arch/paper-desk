# Trade-anatomy diagnostic for setup-A journals (paper contour research, 2026-07).
# Enriches every backtest trade with entry-context measures the journal lacks (trigger-bar size,
# trend age, BTC momentum) and slices dev-only expectancy by FIXED, pre-registered bins.
# Candidate criteria are hard-coded below and printed as PASS/FAIL - no post-hoc thresholds.
# Reserve (last 30% of each year) is never touched here; any resulting rule goes through the
# standard walk-forward protocol (docs\backtests\anti_chase_walkforward.md) afterwards.
param(
  [string]$TradesPath = 'C:\Users\klyde\trading-sim\data\v2\cur_paper19_trades.json',
  [string]$EquityPath = 'C:\Users\klyde\trading-sim\data\v2\cur_paper19_equity.json',
  [string]$DataDir    = 'C:\Users\klyde\trading-sim\data\deep',
  [string]$FileSuffix = '_4h',
  [string]$IndexSymbol = 'BTC-USDT',
  [double]$DevFrac    = 0.7,
  [int]$MinBinN       = 30,   # min pooled-dev n for a bin to be eligible as worst bin
  [int]$MinYearN      = 5,    # min bin n in a year for that year to vote on stability
  [string]$ReportPath = '',
  [string]$EnrichedOut = ''   # optional: dump enriched dev trades as JSON for manual spot-checks
)
$ErrorActionPreference = 'Stop'

# ---- indicators: verbatim copies from tools\backtest.ps1 (do not edit independently) ----
function EMAseries([double[]]$v, [int]$p) {
  $n = $v.Count; $out = New-Object 'double[]' $n
  $k = 2.0 / ($p + 1); $sum = 0.0
  for ($i = 0; $i -lt $n; $i++) {
    if ($i -lt $p) { $sum += $v[$i]; $out[$i] = [double]::NaN; if ($i -eq $p-1){ $out[$i] = $sum/$p } }
    else { $out[$i] = $v[$i]*$k + $out[$i-1]*(1-$k) }
  }
  return $out
}
function ATRseries([double[]]$h,[double[]]$l,[double[]]$c,[int]$p){
  $n=$c.Count; $tr=New-Object 'double[]' $n; $out=New-Object 'double[]' $n
  for($i=0;$i -lt $n;$i++){
    if($i -eq 0){$tr[$i]=$h[$i]-$l[$i]}
    else{ $tr[$i]=[math]::Max($h[$i]-$l[$i],[math]::Max([math]::Abs($h[$i]-$c[$i-1]),[math]::Abs($l[$i]-$c[$i-1]))) }
    $out[$i]=[double]::NaN
  }
  $sum=0.0
  for($i=0;$i -lt $p;$i++){$sum+=$tr[$i]}
  $out[$p-1]=$sum/$p
  for($i=$p;$i -lt $n;$i++){ $out[$i]=($out[$i-1]*($p-1)+$tr[$i])/$p }
  return $out
}

$BAR_MS = 14400000  # 4h

# ---- load journal + equity span ----
$trades = (Get-Content $TradesPath -Raw | ConvertFrom-Json) | ForEach-Object {$_}
$eq = (Get-Content $EquityPath -Raw | ConvertFrom-Json) | ForEach-Object {$_}
$firstDay = [datetime]$eq[0].day; $lastDay = [datetime]$eq[-1].day

# ---- year windows: dev = first DevFrac of each calendar year (same as analyze_wf_years.ps1) ----
$wins = @()
for ($y = $firstDay.Year; $y -le $lastDay.Year; $y++) {
  $ws = [datetime]"$y-01-01"; if ($ws -lt $firstDay) { $ws = $firstDay }
  $we = [datetime]"$y-12-31"; if ($we -gt $lastDay)  { $we = $lastDay }
  $devEnd = $ws.AddDays([math]::Floor($DevFrac * ($we - $ws).TotalDays))
  $wins += @{ y=$y; devA=$ws; devB=$devEnd }
}

# ---- symbol series (traded syms + index) ----
$S = @{}
$loadList = @($trades | ForEach-Object { $_.sym } | Sort-Object -Unique)
if ($loadList -notcontains $IndexSymbol) { $loadList += $IndexSymbol }
foreach ($sym in $loadList) {
  $path = Join-Path $DataDir "$($sym.Replace('-','_'))$FileSuffix.json"
  if (-not (Test-Path $path)) { throw "no candle data for $sym ($path)" }
  $bars = Get-Content $path -Raw | ConvertFrom-Json
  $o=[double[]]($bars.o); $h=[double[]]($bars.h); $l=[double[]]($bars.l); $c=[double[]]($bars.c); $t=[long[]]($bars.t)
  $n = $t.Count
  $e20 = EMAseries $c 20; $e50 = EMAseries $c 50; $atr = ATRseries $h $l $c 14
  # trend series: same rule as backtest.ps1 (close vs EMA50, EMA20 vs EMA50); age = consecutive bars in state
  $trend = New-Object 'string[]' $n
  $age = New-Object 'int[]' $n
  for ($i=0; $i -lt $n; $i++) {
    if ([double]::IsNaN($e50[$i])) { $trend[$i] = 'na' }
    elseif ($c[$i] -gt $e50[$i] -and $e20[$i] -gt $e50[$i]) { $trend[$i] = 'up' }
    elseif ($c[$i] -lt $e50[$i] -and $e20[$i] -lt $e50[$i]) { $trend[$i] = 'down' }
    else { $trend[$i] = 'range' }
    if ($i -gt 0 -and $trend[$i] -eq $trend[$i-1]) { $age[$i] = $age[$i-1] + 1 } else { $age[$i] = 1 }
  }
  $idx = @{}
  for ($i=0; $i -lt $n; $i++) { $idx[$t[$i]] = $i }
  $S[$sym] = @{ t=$t; o=$o; h=$h; l=$l; c=$c; ema20=$e20; ema50=$e50; atr=$atr; trend=$trend; age=$age; idx=$idx }
}
$btc = $S[$IndexSymbol]

# index of the bar at-or-before timestamp (fallback when exact key is absent due to series gaps)
function BtcIdxAt([long]$ts) {
  if ($btc.idx.ContainsKey($ts)) { return $btc.idx[$ts] }
  $lo = 0; $hi = $btc.t.Count - 1; $ans = -1
  while ($lo -le $hi) {
    $mid = [int](($lo + $hi) / 2)
    if ($btc.t[$mid] -le $ts) { $ans = $mid; $lo = $mid + 1 } else { $hi = $mid - 1 }
  }
  return $ans
}

# ---- enrich with mandatory cross-checks ----
$cnt = @{ unmatched=0; entryMismatch=0; atrMismatch=0; setupFail=0; trendSideFail=0; btcFallback=0; btcGap=0; eod=0 }
$enriched = New-Object System.Collections.Generic.List[object]
foreach ($tr in $trades) {
  $sy = $S[$tr.sym]
  $ets = [long]$tr.entryTs
  if (-not $sy.idx.ContainsKey($ets)) { $cnt.unmatched++; Write-Warning "unmatched entryTs $($tr.sym) $($tr.entryDay)"; continue }
  $i = $sy.idx[$ets]
  # cross-check 1: journal entry price must equal the trigger bar close (setup A enters at close)
  if ([math]::Abs([double]$tr.entry - $sy.c[$i]) / [double]$tr.entry -gt 1e-6) { $cnt.entryMismatch++; continue }
  # cross-check 2: stored atrPct must match recomputed ATR on the same bar
  if ([math]::Abs([double]$tr.atrPct - [math]::Round(100*$sy.atr[$i]/$sy.c[$i],3)) -gt 0.002) { $cnt.atrMismatch++; continue }
  # cross-check 3: setup-A trigger-bar predicate
  $okSetup = $false
  if ($tr.side -eq 'long')  { $okSetup = ($sy.c[$i] -gt $sy.o[$i]) -and ($sy.c[$i] -gt $sy.ema20[$i]) }
  else                      { $okSetup = ($sy.c[$i] -lt $sy.o[$i]) -and ($sy.c[$i] -lt $sy.ema20[$i]) }
  if (-not $okSetup) { $cnt.setupFail++; Write-Warning "setup predicate fail $($tr.sym) $($tr.entryDay) $($tr.side)"; continue }
  # cross-check 4: recomputed symbol trend must match trade side
  $needTrend = 'up'; if ($tr.side -eq 'short') { $needTrend = 'down' }
  if ($sy.trend[$i] -ne $needTrend) { $cnt.trendSideFail++; Write-Warning "trend/side fail $($tr.sym) $($tr.entryDay)"; continue }

  $j = BtcIdxAt $ets
  if ($j -lt 0) { throw "no BTC bar at/before $($tr.entryDay)" }
  if (-not $btc.idx.ContainsKey($ets)) { $cnt.btcFallback++ }
  $mom3 = $null; $mom5 = $null; $dd5 = $null
  if ($j -ge 30) {
    # continuity guard: with gaps in the 4h series, "18 bars" would no longer be 3 days
    if (($btc.t[$j] - $btc.t[$j-18]) -ne (18 * $BAR_MS) -or ($btc.t[$j] - $btc.t[$j-30]) -ne (30 * $BAR_MS)) { $cnt.btcGap++ }
    $mom3 = [math]::Round(100*($btc.c[$j]/$btc.c[$j-18] - 1), 2)
    $mom5 = [math]::Round(100*($btc.c[$j]/$btc.c[$j-30] - 1), 2)
    $mx = $btc.h[$j-30]
    for ($k=$j-29; $k -le $j; $k++) { if ($btc.h[$k] -gt $mx) { $mx = $btc.h[$k] } }
    $dd5 = [math]::Round(100*($btc.c[$j] - $mx)/$mx, 2)
  }

  $isEod = ($tr.exitReason -eq 'eod-close')
  if ($isEod) { $cnt.eod++ }
  $r = $null
  if ([double]$tr.riskUsd -gt 0) { $r = [double]$tr.pnlUsd / [double]$tr.riskUsd }
  $rsiDir = $null
  if ($null -ne $tr.rsiEntry) { if ($tr.side -eq 'long') { $rsiDir = [double]$tr.rsiEntry } else { $rsiDir = 100.0 - [double]$tr.rsiEntry } }
  $distDir = $null
  if ($null -ne $tr.distEma20Pct) { if ($tr.side -eq 'long') { $distDir = [double]$tr.distEma20Pct } else { $distDir = -[double]$tr.distEma20Pct } }
  $fg = $null
  if ($null -ne $tr.fgEntry) { $fg = [double]$tr.fgEntry }

  $enriched.Add([pscustomobject]@{
    sym=$tr.sym; side=$tr.side; entryDay=$tr.entryDay; year=[int]$tr.entryDay.Substring(0,4)
    R=$r; mfeR=$tr.mfeR; maeR=$tr.maeR; eod=$isEod
    triggerBarAtr=[math]::Round(($sy.h[$i]-$sy.l[$i])/$sy.atr[$i],3)
    trendAgeBars=$sy.age[$i]
    btcMom3d=$mom3; btcMom5d=$mom5; btcDD5d=$dd5
    atrPct=$tr.atrPct; stopDistPct=$tr.stopDistPct
    fgEntry=$fg; rsiDir=$rsiDir; distE20Dir=$distDir
  })
}

Write-Output ("cross-checks: unmatched={0} entryMismatch={1} atrMismatch={2} setupFail={3} trendSideFail={4} btcFallback={5} btcGap={6} eod-close={7}" -f `
  $cnt.unmatched,$cnt.entryMismatch,$cnt.atrMismatch,$cnt.setupFail,$cnt.trendSideFail,$cnt.btcFallback,$cnt.btcGap,$cnt.eod)
if (($cnt.unmatched + $cnt.entryMismatch + $cnt.atrMismatch + $cnt.setupFail + $cnt.trendSideFail) -gt 0) {
  throw 'mandatory cross-checks failed - enrichment is not trustworthy, aborting'
}

# ---- dev-only view ----
$dev = New-Object System.Collections.Generic.List[object]
foreach ($e in $enriched) {
  $d = [datetime]$e.entryDay
  foreach ($w in $wins) { if ($d -ge $w.devA -and $d -le $w.devB) { $dev.Add($e); break } }
}
Write-Output ("trades: journal={0} enriched={1} dev={2} (DevFrac={3})" -f $trades.Count, $enriched.Count, $dev.Count, $DevFrac)

# ---- aggregate check vs analyze_wf_years.ps1 (must match its DEV tables exactly) ----
Write-Output ''
Write-Output '=== dev aggregates per year (compare with analyze_wf_years.ps1 DEV windows) ==='
$aggRows = foreach ($w in $wins) {
  $g = @($dev | Where-Object { $d=[datetime]$_.entryDay; $d -ge $w.devA -and $d -le $w.devB })
  if ($g.Count -eq 0) { continue }
  $rs = @($g | Where-Object { $null -ne $_.R } | ForEach-Object { $_.R })
  [pscustomobject]@{ year=$w.y; n=$g.Count; long=@($g | Where-Object {$_.side -eq 'long'}).Count
    sumR=[math]::Round(($rs | Measure-Object -Sum).Sum,1) }
}
$aggRows | Format-Table -AutoSize | Out-String | Write-Output

# ---- bin machinery (formulas mirror WindowStats in analyze_wf_years.ps1) ----
function BinStats($rows) {
  $rs = @($rows | Where-Object { $null -ne $_.R } | ForEach-Object { $_.R })
  if ($rs.Count -eq 0) { return $null }
  $w  = @($rs | Where-Object { $_ -gt 0 })
  $sw = ($w | Measure-Object -Sum).Sum; if ($null -eq $sw) { $sw = 0.0 }
  $sl = [math]::Abs((($rs | Where-Object { $_ -le 0 }) | Measure-Object -Sum).Sum)
  $pf = if ($sl -gt 0) { [math]::Round($sw/$sl,2) } else { 'inf' }
  [pscustomobject]@{
    n=$rs.Count
    WR=[math]::Round(100.0*$w.Count/$rs.Count,1)
    avgR=[math]::Round((($rs | Measure-Object -Average).Average),3)
    sumR=[math]::Round(($rs | Measure-Object -Sum).Sum,1)
    PF=$pf
  }
}
function BinLabel([int]$k, [double[]]$edges) {
  if ($k -eq 0) { return "<$($edges[0])" }
  if ($k -eq $edges.Count) { return ">=$($edges[$edges.Count-1])" }
  return "$($edges[$k-1])-$($edges[$k])"
}
function BinIndex([double]$v, [double[]]$edges) {
  for ($k=0; $k -lt $edges.Count; $k++) { if ($v -lt $edges[$k]) { return $k } }
  return $edges.Count
}

# ---- dimensions: FIXED bins, registered before the first run (domain-chosen, not data-peeked) ----
$DIMS = @(
  @{ name='triggerBarAtr'; edges=[double[]]@(0.8,1.2,1.6,2.0); candidate=$true;  note='H1: trigger-bar range in ATR (chase)' }
  @{ name='distE20Dir';    edges=[double[]]@(0.5,1.0,2.0,4.0); candidate=$true;  note='H1: entry extension from EMA20, trend-signed %' }
  @{ name='trendAgeBars';  edges=[double[]]@(7,19,43,91);      candidate=$true;  note='H2: bars in current trend state (7=1d+, 43=1w+)' }
  @{ name='btcMom3d';      edges=[double[]]@(-3,0,3,6);        candidate=$true;  note='H3: BTC close change over 3d, %' }
  @{ name='btcMom5d';      edges=[double[]]@(-5,0,5,10);       candidate=$true;  note='H3: BTC close change over 5d, %' }
  @{ name='btcDD5d';       edges=[double[]]@(-6,-3,-1);        candidate=$true;  note='H3: BTC drawdown from 5d high, % (<=0)' }
  @{ name='atrPct';        edges=[double[]]@(1,1.5,2,2.5);     candidate=$true;  note='volatility at entry (gate caps at 3)' }
  @{ name='stopDistPct';   edges=[double[]]@(2,3,4,6);         candidate=$true;  note='stop width, % of entry' }
  @{ name='fgEntry';       edges=[double[]]@(25,45,55,75);     candidate=$true;  note='Fear&Greed at entry (null = missing)' }
  @{ name='rsiDir';        edges=[double[]]@(45,55,60,65);     candidate=$true;  note='RSI at entry, trend-signed (short mirrored)' }
  @{ name='mfeR';          edges=[double[]]@(0.25,0.5,1.0,1.5); candidate=$false; note='DESCRIPTIVE outcome, not knowable at entry' }
)

# ---- candidate criteria (pre-registered; see plan/report) ----
# 1) worst bin: pooled-dev n>=MinBinN and avgR<0
# 2) yearly stability: sumR<0 in >=2/3 of voting years (year votes at n>=MinYearN), >=3 voting years
# 3) removing the bin lifts dev sumR by >= max(5R, 10% of |dev sumR|)
# 4) removing the bin drops <=30% of dev trades
# 5) worst bin is an extreme bin of the scale (else likely noise)

$mdLines = New-Object System.Collections.Generic.List[string]
[void]$mdLines.Add('# Trade anatomy - paper contour (cur_paper19), dev windows only')
[void]$mdLines.Add('')
[void]$mdLines.Add("Generated: 2026-07-20 UTC. Journal: ``$TradesPath`` ($($trades.Count) trades; dev=$($dev.Count) @ DevFrac=$DevFrac).")
[void]$mdLines.Add("Cross-checks: unmatched=$($cnt.unmatched) entryMismatch=$($cnt.entryMismatch) atrMismatch=$($cnt.atrMismatch) setupFail=$($cnt.setupFail) trendSideFail=$($cnt.trendSideFail) btcFallback=$($cnt.btcFallback) btcGap=$($cnt.btcGap) eod-close=$($cnt.eod) (included, flagged).")
[void]$mdLines.Add('')
[void]$mdLines.Add('Pre-registered candidate criteria (fixed before first run): (1) worst bin n>=30 & avgR<0; (2) sumR<0 in >=2/3 voting years (vote at n>=5), >=3 voting years; (3) hypothetical removal lifts dev sumR by >= max(5R, 10%); (4) removal cuts <=30% of dev trades; (5) worst bin is an extreme bin. ~11 dims x 3 sides => multiple-comparisons risk; criterion 2 is the main guard. Any PASS goes to standard walk-forward next (reserve untouched).')
[void]$mdLines.Add('')

$checklist = New-Object System.Collections.Generic.List[object]
foreach ($dim in $DIMS) {
  $name = $dim.name; $edges = $dim.edges
  Write-Output ('================ {0}  ({1}) ================' -f $name, $dim.note)
  [void]$mdLines.Add('## ' + $name + ' - ' + $dim.note)
  [void]$mdLines.Add('')
  foreach ($sideSel in @('all','long','short')) {
    $rows = $dev
    if ($sideSel -ne 'all') { $rows = @($dev | Where-Object { $_.side -eq $sideSel }) }
    # bucket
    $buckets = @{}
    $nullRows = New-Object System.Collections.Generic.List[object]
    foreach ($e in $rows) {
      $v = $e.$name
      if ($null -eq $v) { $nullRows.Add($e); continue }
      $k = BinIndex ([double]$v) $edges
      if (-not $buckets.ContainsKey($k)) { $buckets[$k] = New-Object System.Collections.Generic.List[object] }
      $buckets[$k].Add($e)
    }
    $tblRows = @()
    for ($k=0; $k -le $edges.Count; $k++) {
      if (-not $buckets.ContainsKey($k)) { continue }
      $st = BinStats $buckets[$k]
      if ($null -eq $st) { continue }
      $tblRows += [pscustomobject]@{ side=$sideSel; bin=(BinLabel $k $edges); n=$st.n; WR=$st.WR; avgR=$st.avgR; sumR=$st.sumR; PF=$st.PF; k=$k }
    }
    if ($nullRows.Count -gt 0) {
      $st = BinStats $nullRows
      if ($null -ne $st) { $tblRows += [pscustomobject]@{ side=$sideSel; bin='null'; n=$st.n; WR=$st.WR; avgR=$st.avgR; sumR=$st.sumR; PF=$st.PF; k=-1 } }
    }
    $tblRows | Format-Table side,bin,n,WR,avgR,sumR,PF -AutoSize | Out-String | Write-Output
    [void]$mdLines.Add("### $sideSel")
    [void]$mdLines.Add('')
    [void]$mdLines.Add('| bin | n | WR% | avgR | sumR | PF |')
    [void]$mdLines.Add('|---|---|---|---|---|---|')
    foreach ($r in $tblRows) { [void]$mdLines.Add("| $($r.bin) | $($r.n) | $($r.WR) | $($r.avgR) | $($r.sumR) | $($r.PF) |") }
    [void]$mdLines.Add('')

    # ---- worst bin + criteria checklist (numeric bins only) ----
    if (-not $dim.candidate) { continue }
    $elig = @($tblRows | Where-Object { $_.k -ge 0 -and $_.n -ge $MinBinN })
    if ($elig.Count -eq 0) { continue }
    $worst = $elig | Sort-Object avgR | Select-Object -First 1
    $wRows = $buckets[[int]$worst.k]
    # yearly stability
    $yr = @($wRows | Group-Object year | Sort-Object Name)
    $yrRows = @(); $voting = 0; $against = 0
    foreach ($gy in $yr) {
      $st = BinStats $gy.Group
      if ($null -eq $st) { continue }
      $vote = ''
      if ($st.n -ge $MinYearN) { $voting++; if ($st.sumR -lt 0) { $against++; $vote = 'NEG' } else { $vote = 'pos' } }
      $yrRows += [pscustomobject]@{ year=$gy.Name; n=$st.n; WR=$st.WR; avgR=$st.avgR; sumR=$st.sumR; vote=$vote }
    }
    $allStats = BinStats $rows
    $c1 = ($worst.n -ge $MinBinN) -and ($worst.avgR -lt 0)
    $c2 = ($voting -ge 3) -and ($against * 3 -ge $voting * 2)
    $without = [math]::Round($allStats.sumR - $worst.sumR, 1)
    $lift = [math]::Round($without - $allStats.sumR, 1)   # = -worst.sumR
    $need = [math]::Max(5.0, [math]::Round(0.10 * [math]::Abs($allStats.sumR),1))
    $c3 = ($lift -ge $need)
    $cut = [math]::Round(100.0 * $worst.n / [math]::Max(1,$allStats.n), 1)
    $c4 = ($cut -le 30)
    $c5 = ($worst.k -eq 0) -or ($worst.k -eq $edges.Count)
    $pass = $c1 -and $c2 -and $c3 -and $c4 -and $c5
    $verdict = if ($pass) { 'CANDIDATE' } else { 'no' }
    $line = ('worst[{0}/{1}] bin={2} n={3} avgR={4} | C1 avgR<0:{5} C2 years {6}/{7} NEG:{8} C3 lift {9}R vs need {10}:{11} C4 cut {12}%:{13} C5 extreme:{14} => {15}' -f `
      $name,$sideSel,$worst.bin,$worst.n,$worst.avgR,$c1,$against,$voting,$c2,$lift,$need,$c3,$cut,$c4,$c5,$verdict)
    Write-Output $line
    if ($yrRows.Count -gt 0) { $yrRows | Format-Table -AutoSize | Out-String | Write-Output }
    [void]$mdLines.Add('Worst bin (' + $sideSel + '): `' + $worst.bin + '` n=' + $worst.n + ' avgR=' + $worst.avgR + ' -> C1=' + $c1 + ' C2=' + $against + '/' + $voting + ' neg=' + $c2 + ' C3 lift=' + $lift + 'R (need ' + $need + ')=' + $c3 + ' C4 cut=' + $cut + '%=' + $c4 + ' C5 extreme=' + $c5 + ' => **' + $verdict + '**')
    [void]$mdLines.Add('')
    if ($yrRows.Count -gt 0) {
      [void]$mdLines.Add('| year | n | WR% | avgR | sumR | vote |')
      [void]$mdLines.Add('|---|---|---|---|---|---|')
      foreach ($r in $yrRows) { [void]$mdLines.Add("| $($r.year) | $($r.n) | $($r.WR) | $($r.avgR) | $($r.sumR) | $($r.vote) |") }
      [void]$mdLines.Add('')
    }
    $checklist.Add([pscustomobject]@{ dim=$name; side=$sideSel; worstBin=$worst.bin; n=$worst.n; avgR=$worst.avgR; liftR=$lift; cutPct=$cut; yearsNeg="$against/$voting"; verdict=$verdict })
  }
}

Write-Output ''
Write-Output '################ CANDIDATE CHECKLIST (pre-registered criteria) ################'
$checklist | Sort-Object @{e={$_.verdict}; Descending=$false}, dim | Format-Table -AutoSize | Out-String | Write-Output
[void]$mdLines.Add('## Candidate checklist')
[void]$mdLines.Add('')
[void]$mdLines.Add('| dim | side | worst bin | n | avgR | liftR | cut% | yearsNeg | verdict |')
[void]$mdLines.Add('|---|---|---|---|---|---|---|---|---|')
foreach ($r in ($checklist | Sort-Object dim, side)) {
  [void]$mdLines.Add("| $($r.dim) | $($r.side) | $($r.worstBin) | $($r.n) | $($r.avgR) | $($r.liftR) | $($r.cutPct) | $($r.yearsNeg) | $($r.verdict) |")
}
[void]$mdLines.Add('')
[void]$mdLines.Add('## Conclusions')
[void]$mdLines.Add('')
[void]$mdLines.Add('_(filled in manually after studying the tables; candidates go to walk-forward one at a time)_')

if ($ReportPath) {
  $mdLines -join "`r`n" | Out-File -FilePath $ReportPath -Encoding utf8
  Write-Output "report written: $ReportPath"
}
if ($EnrichedOut) {
  $dev | ConvertTo-Json -Depth 4 | Out-File -FilePath $EnrichedOut -Encoding utf8
  Write-Output "enriched dev trades dumped: $EnrichedOut"
}
