# Per-subperiod metrics for v2 configs from stashed artifacts in data\v2\
# Windows: bear 2021-11-01..2023-01-31, recover 2023-02-01..2024-12-31, bull 2025-01-01..2026-07-08
param([string]$V2Dir = 'C:\Users\klyde\trading-sim\data\v2')
$ErrorActionPreference = 'Stop'
$wins = @(
  @{n='bear';    a=[datetime]'2021-11-01'; b=[datetime]'2023-01-31'},
  @{n='recover'; a=[datetime]'2023-02-01'; b=[datetime]'2024-12-31'},
  @{n='bull';    a=[datetime]'2025-01-01'; b=[datetime]'2026-07-08'}
)
$cfgs = Get-ChildItem $V2Dir -Filter '*_equity.json' | ForEach-Object { $_.BaseName -replace '_equity$','' }
$rows = foreach ($c in $cfgs) {
  $eq = (Get-Content (Join-Path $V2Dir "${c}_equity.json") -Raw | ConvertFrom-Json) | ForEach-Object {$_}
  $tr = (Get-Content (Join-Path $V2Dir "${c}_trades.json") -Raw | ConvertFrom-Json) | ForEach-Object {$_}
  foreach ($w in $wins) {
    $seg = @($eq | Where-Object { $d=[datetime]$_.day; $d -ge $w.a -and $d -le $w.b })
    if ($seg.Count -lt 2) { continue }
    $ret = [math]::Round(100*($seg[-1].equity/$seg[0].equity - 1),1)
    $peak = 0.0; $dd = 0.0
    foreach ($p in $seg) { if ($p.equity -gt $peak){$peak=$p.equity}; $d=($peak-$p.equity)/$peak; if($d -gt $dd){$dd=$d} }
    $seg2 = @($tr | Where-Object { $_.exitDay -ne 'EOD' -and [datetime]$_.exitDay -ge $w.a -and [datetime]$_.exitDay -le $w.b })
    $gw = ($seg2 | Where-Object {$_.pnlUsd -gt 0} | Measure-Object pnlUsd -Sum).Sum; if($null -eq $gw){$gw=0.0}
    $gl = [math]::Abs(($seg2 | Where-Object {$_.pnlUsd -le 0} | Measure-Object pnlUsd -Sum).Sum); if($null -eq $gl -or $gl -eq 0){$gl=0.0001}
    [pscustomobject]@{ cfg=$c; period=$w.n; ret_pct=$ret; maxDD_pct=[math]::Round(100*$dd,1); PF=[math]::Round($gw/$gl,2); trades=$seg2.Count }
  }
}
"per subperiod:"
$rows | Sort-Object cfg, @{e={@('bear','recover','bull').IndexOf($_.period)}} | Format-Table -AutoSize | Out-String
"pivot (PF by period):"
$piv = foreach ($c in ($rows | Select-Object -ExpandProperty cfg -Unique)) {
  $r = @($rows | Where-Object {$_.cfg -eq $c})
  [pscustomobject]@{ cfg=$c
    bear_PF=($r | Where-Object{$_.period -eq 'bear'}).PF;    bear_ret=($r | Where-Object{$_.period -eq 'bear'}).ret_pct
    rec_PF=($r | Where-Object{$_.period -eq 'recover'}).PF;  rec_ret=($r | Where-Object{$_.period -eq 'recover'}).ret_pct
    bull_PF=($r | Where-Object{$_.period -eq 'bull'}).PF;    bull_ret=($r | Where-Object{$_.period -eq 'bull'}).ret_pct }
}
$piv | Format-Table -AutoSize | Out-String
