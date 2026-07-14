# Walk-forward year-window metrics for anti-chase research from stashed artifacts in data\v2\wf_*.
# Protocol (docs\backtests\anti_chase_walkforward.md): every calendar year's available span is split
# dev|reserve at DevFrac (default 70/30). Reserve windows are the held-out final check - they are
# NOT printed unless -Final is passed. Trades attribute to a window by ENTRY day (filters act at entry).
param(
  [string]$V2Dir   = 'C:\Users\klyde\trading-sim\data\v2',
  [string]$Prefix  = 'wf_',
  [string]$BaseCfg = 'base',
  [double]$DevFrac = 0.7,
  [switch]$Final      # ONE-SHOT: also compute the 30% reserve windows
)
$ErrorActionPreference = 'Stop'

# ---- configs from stashed artifacts ----
$cfgs = Get-ChildItem $V2Dir -Filter "$Prefix*_trades.json" | ForEach-Object {
  $_.BaseName -replace "^$([regex]::Escape($Prefix))",'' -replace '_trades$',''
}
if ($cfgs -notcontains $BaseCfg) { throw "base config '$Prefix$BaseCfg' not found in $V2Dir" }
$cfgs = @($BaseCfg) + @($cfgs | Where-Object { $_ -ne $BaseCfg })

# ---- global span from the BASE equity curve; year windows split dev|reserve at DevFrac ----
$eq = (Get-Content (Join-Path $V2Dir "$Prefix${BaseCfg}_equity.json") -Raw | ConvertFrom-Json) | ForEach-Object {$_}
$firstDay = [datetime]$eq[0].day; $lastDay = [datetime]$eq[-1].day
$wins = @()
for ($y = $firstDay.Year; $y -le $lastDay.Year; $y++) {
  $ws = [datetime]"$y-01-01"; if ($ws -lt $firstDay) { $ws = $firstDay }
  $we = [datetime]"$y-12-31"; if ($we -gt $lastDay)  { $we = $lastDay }
  $devEnd = $ws.AddDays([math]::Floor($DevFrac * ($we - $ws).TotalDays))
  $wins += @{ y=$y; devA=$ws; devB=$devEnd; resA=$devEnd.AddDays(1); resB=$we }
}

function WindowStats($trades, [datetime]$a, [datetime]$b) {
  $g = @($trades | Where-Object { $d=[datetime]$_.entryDay; $d -ge $a -and $d -le $b })
  if ($g.Count -eq 0) { return $null }
  $rs = @($g | Where-Object { $_.riskUsd -gt 0 } | ForEach-Object { $_.pnlUsd / $_.riskUsd })
  $w  = @($rs | Where-Object { $_ -gt 0 })
  $sw = ($w | Measure-Object -Sum).Sum; if ($null -eq $sw) { $sw = 0.0 }
  $sl = [math]::Abs((($rs | Where-Object { $_ -le 0 }) | Measure-Object -Sum).Sum)
  $pf = if ($sl -gt 0) { [math]::Round($sw/$sl,2) } else { 'inf' }
  [pscustomobject]@{
    n=$g.Count
    long=@($g | Where-Object {$_.side -eq 'long'}).Count
    WR=[math]::Round(100.0*$w.Count/[math]::Max(1,$rs.Count),1)
    sumR=[math]::Round(($rs | Measure-Object -Sum).Sum,1)
    PF=$pf
  }
}

$T = @{}
foreach ($c in $cfgs) { $T[$c] = (Get-Content (Join-Path $V2Dir "$Prefix${c}_trades.json") -Raw | ConvertFrom-Json) | ForEach-Object {$_} }

foreach ($mode in @('dev') + $(if ($Final) { @('reserve') } else { @() })) {
  $frac = if ($mode -eq 'dev') { [int](100*$DevFrac) } else { [int](100*(1-$DevFrac)) }
  Write-Output ''
  $lbl = if ($mode -eq 'dev') { "first $frac%" } else { "last $frac%" }
  Write-Output ("################ {0} windows ({1} of each year) ################" -f $mode.ToUpper(), $lbl)
  $summary = @{}
  foreach ($w in $wins) {
    if ($mode -eq 'dev') { $a=$w.devA; $b=$w.devB } else { $a=$w.resA; $b=$w.resB }
    if ($b -lt $a) { continue }
    $base = WindowStats $T[$BaseCfg] $a $b
    Write-Output ("--- {0}  [{1} .. {2}] ---" -f $w.y, $a.ToString('yyyy-MM-dd'), $b.ToString('yyyy-MM-dd'))
    $rows = foreach ($c in $cfgs) {
      $s = WindowStats $T[$c] $a $b
      if ($null -eq $s) { continue }
      $dR = ''; $dN = ''
      if ($c -ne $BaseCfg -and $null -ne $base) {
        $dR = [math]::Round($s.sumR - $base.sumR,1); $dN = $s.n - $base.n
        if (-not $summary.ContainsKey($c)) { $summary[$c] = @{ yrs=0; better=0; dR=0.0; dN=0 } }
        $summary[$c].yrs++; $summary[$c].dR += $dR; $summary[$c].dN += $dN
        if ($dR -gt 0) { $summary[$c].better++ }
      }
      [pscustomobject]@{ cfg=$c; n=$s.n; long=$s.long; WR=$s.WR; sumR=$s.sumR; PF=$s.PF; dSumR=$dR; dN=$dN }
    }
    $rows | Format-Table -AutoSize | Out-String
  }
  Write-Output ("=== {0} SUMMARY vs {1} (years better / years with data, total dSumR, total dN) ===" -f $mode.ToUpper(), $BaseCfg)
  foreach ($c in ($summary.Keys | Sort-Object)) {
    $s = $summary[$c]
    Write-Output ("{0,-10} better {1}/{2} years  dSumR={3,7}  dTrades={4,5}" -f $c,$s.better,$s.yrs,[math]::Round($s.dR,1),$s.dN)
  }
}
if (-not $Final) { Write-Output ''; Write-Output '(reserve windows hidden - run with -Final ONCE after the combo is chosen)' }
