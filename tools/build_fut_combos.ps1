# Builds data\moex_fut\combos.json for the trades.html futures tab:
# portfolio combos (C0/C1/C2/C3b) as monthly series + KPIs, and the sleeve walk-forward table.
# Sources: data\fut_runs\*_monthly.json (sleeve artifacts) + data\moex\bt_monthly_mom63_full.json.
$ErrorActionPreference = 'Stop'
$dir = 'C:\Users\klyde\trading-sim'
$futOut = Join-Path $dir 'data\fut_runs'
$moex = Join-Path $dir 'data\moex'

function LoadM([string]$path) {
  $h = @{}
  foreach ($x in ((Get-Content $path -Raw | ConvertFrom-Json) | ForEach-Object { $_ })) { $h[$x.month] = [double]$x.ret_pct }
  return $h
}
$B2 = LoadM "$futOut\Bfull_r2_monthly.json"; $B3 = LoadM "$futOut\Bfull_r3_monthly.json"; $B5 = LoadM "$futOut\Bfull_r5_monthly.json"
$A1 = LoadM "$futOut\Afull_r1_monthly.json"; $A2 = LoadM "$futOut\Afull_r2_monthly.json"; $MM = LoadM "$moex\bt_monthly_mom63_full.json"
$months = @($B2.Keys + $MM.Keys | Sort-Object -Unique)
function G($h, $mn) { if ($h.ContainsKey($mn)) { return $h[$mn] } return 0.0 }

function BuildCombo([string]$id, [string]$label, [string]$desc, [scriptblock]$f) {
  $eq = 100.0; $peak = 100.0; $dd = 0.0; $best = 0.0; $worst = 0.0; $pos = 0
  $ser = New-Object System.Collections.Generic.List[object]
  $yr = [ordered]@{}
  foreach ($mn in $months) {
    $r = [double](& $f $mn)
    if ($r -gt $best) { $best = $r }; if ($r -lt $worst) { $worst = $r }; if ($r -gt 0) { $pos++ }
    $eq *= (1 + $r / 100)
    if ($eq -gt $peak) { $peak = $eq }
    $d = ($peak - $eq) / $peak * 100; if ($d -gt $dd) { $dd = $d }
    $y = $mn.Substring(0, 4); if (-not $yr.Contains($y)) { $yr[$y] = 1.0 }; $yr[$y] *= (1 + $r / 100)
    $ser.Add([pscustomobject]@{ m = $mn; r = [math]::Round($r, 2); eq = [math]::Round($eq, 1) })
  }
  $years = [ordered]@{}
  foreach ($y in $yr.Keys) { $years[$y] = [math]::Round(100 * ($yr[$y] - 1), 0) }
  [pscustomobject]@{
    id = $id; label = $label; desc = $desc
    mo = [math]::Round(100 * ([math]::Pow($eq / 100, 1.0 / $months.Count) - 1), 2)
    total = [math]::Round($eq - 100, 0); ddMo = [math]::Round($dd, 1)
    posMonths = $pos; nMonths = $months.Count
    best = [math]::Round($best, 1); worst = [math]::Round($worst, 1)
    years = $years; series = $ser.ToArray()
  }
}

$combos = @(
  (BuildCombo 'C0' 'C0 · ядро соло' 'брейкаут @2%' { param($mn) (G $B2 $mn) }),
  (BuildCombo 'C1' 'C1 · умеренный' 'брейкаут @2% + setup A @1% + 0.3×momentum' { param($mn) (G $B2 $mn) + (G $A1 $mn) + 0.3 * (G $MM $mn) }),
  (BuildCombo 'C2' 'C2 · агрессивный' 'брейкаут @3% + setup A @1% + 0.3×momentum' { param($mn) (G $B3 $mn) + (G $A1 $mn) + 0.3 * (G $MM $mn) }),
  (BuildCombo 'C3b' 'C3b · целевой 5–10%' 'брейкаут @5% + setup A @2% + 0.5×momentum' { param($mn) (G $B5 $mn) + (G $A2 $mn) + 0.5 * (G $MM $mn) })
)

# sleeve walk-forward table (numbers from the research log, docs\strategy\strategy_moex_fut.md)
$wf = @(
  [pscustomobject]@{ sleeve = 'Donchian-брейкаут · фьючерсы @1%'; is = '0.55%/мес · PF 1.45'; oos1 = '1.14%/мес · PF 1.86'; oos2 = '2.08%/мес · PF 2.99'; verdict = 'ЯДРО — прошёл 3/3, эдж рос'; ok = $true },
  [pscustomobject]@{ sleeve = 'Setup A (откат к EMA) · фьючерсы @1%'; is = '0.76%/мес · PF 1.69'; oos1 = '0.79%/мес · PF 1.60'; oos2 = '−0.38%/мес · PF 0.77'; verdict = 'сателлит — 2/3, умер в 2025–26'; ok = $false },
  [pscustomobject]@{ sleeve = 'Momentum top4/63д · акции'; is = '1.94%/мес'; oos1 = '0.48%/мес'; oos2 = '−0.44%/мес'; verdict = 'сателлит — работает только в бычьем рынке'; ok = $false },
  [pscustomobject]@{ sleeve = 'Donchian-брейкаут · акции @2% (лонг)'; is = '1.47%/мес · PF 1.79'; oos1 = '−1.61%/мес · PF 0.54'; oos2 = '−1.06%/мес · PF 0.65'; verdict = 'ОТВЕРГНУТ — красивый IS, провал вне выборки'; ok = $false },
  [pscustomobject]@{ sleeve = 'Setup A · акции (эксп. №8)'; is = '−2.2% за 3 года · PF 0.94'; oos1 = '—'; oos2 = 'PF 0.66'; verdict = 'ОТВЕРГНУТ — издержки съедают 65% стопа'; ok = $false },
  [pscustomobject]@{ sleeve = 'Часовики (оба сетапа) · фьючерсы'; is = '—'; oos1 = 'PF 0.89 / 0.97'; oos2 = '—'; verdict = 'ОТВЕРГНУТ — интрадей РФ не платит'; ok = $false }
)

$out = [pscustomobject]@{
  updatedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')
  combos = $combos
  wf = $wf
}
$path = Join-Path $dir 'data\moex_fut\combos.json'
$out | ConvertTo-Json -Depth 6 | Out-File $path -Encoding utf8
"combos.json written: $((Get-Item $path).Length) bytes, $($months.Count) months, $($combos.Count) combos"
