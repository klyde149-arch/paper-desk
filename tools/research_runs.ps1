# Research runner: execute backtest.ps1 configs, scrape summary metrics into one table.
# NOTE: each run overwrites data/bt_*.json - re-run the canonical config after research!
param([string]$Set = 'flat', [string]$Period = 'IS', [double]$ComboExt = 0, [double]$ComboRsi = 0)
$ErrorActionPreference = 'Stop'
$bt = 'C:\Users\klyde\trading-sim\tools\backtest.ps1'

function RunCfg([string]$name, [hashtable]$p) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $out = & $bt @p | Out-String
  $sw.Stop()
  $g = { param($rx) $m=[regex]::Match($out,$rx); if($m.Success){$m.Groups[1].Value}else{''} }
  [pscustomobject]@{
    cfg     = $name
    trades  = (& $g 'Trades\s*:\s*(\d+)')
    ret_pct = (& $g 'Total return\s*:\s*([-\d\.,]+)')
    moGeo   = (& $g 'Monthly \(geo avg\)\s*:\s*([-\d\.,]+)')
    PF      = (& $g 'Profit factor\s*:\s*([\d\.,]+|inf)')
    maxDD   = (& $g 'Max drawdown\s*:\s*([\d\.,]+)')
    WR      = (& $g 'Win rate\s*:\s*([\d\.,]+)')
    oct25   = (& $g '2025-10\s+([-\d,\.]+)')
    jul25   = (& $g '2025-07\s+([-\d,\.]+)')
    mar26   = (& $g '2026-03\s+([-\d,\.]+)')
    jun26   = (& $g '2026-06\s+([-\d,\.]+)')
    sec     = [math]::Round($sw.Elapsed.TotalSeconds,0)
  }
}

$common = @{ BtcFilter = $true; MaxAtrPct = 3.0 }
$rows = @()

switch ($Set) {
  'flat' {
    $rows += RunCfg 'base(full)'      ($common.Clone())
    $rows += RunCfg 'flat-skip'       ($common.Clone() + @{ FlatMode='skip' })
    $rows += RunCfg 'flat-halfrisk'   ($common.Clone() + @{ FlatMode='halfrisk' })
    $rows += RunCfg 'flat-deeprsi'    ($common.Clone() + @{ FlatMode='deeprsi' })
  }
  'wf' {
    # walk-forward: P1 = 2025-02-24..2025-10-31, P2 = 2025-11-01..2026-07-08
    $rows += RunCfg 'base-P1'      ($common.Clone() + @{ ToDate='2025-10-31' })
    $rows += RunCfg 'base-P2'      ($common.Clone() + @{ FromDate='2025-11-01' })
    $rows += RunCfg 'skip-P1'      ($common.Clone() + @{ FlatMode='skip'; ToDate='2025-10-31' })
    $rows += RunCfg 'skip-P2'      ($common.Clone() + @{ FlatMode='skip'; FromDate='2025-11-01' })
    $rows += RunCfg 'halfrisk-P1'  ($common.Clone() + @{ FlatMode='halfrisk'; ToDate='2025-10-31' })
    $rows += RunCfg 'halfrisk-P2'  ($common.Clone() + @{ FlatMode='halfrisk'; FromDate='2025-11-01' })
  }
  'coins' {
    $all = @('BTC-USDT','ETH-USDT','SOL-USDT','BNB-USDT','XRP-USDT','DOGE-USDT','ADA-USDT','AVAX-USDT','LINK-USDT')
    $rows += RunCfg 'port-noDOGE'   ($common.Clone() + @{ Symbols = @($all | Where-Object {$_ -ne 'DOGE-USDT'}) })
    $rows += RunCfg 'port-noBNB'    ($common.Clone() + @{ Symbols = @($all | Where-Object {$_ -ne 'BNB-USDT'}) })
    $rows += RunCfg 'port-noBoth'   ($common.Clone() + @{ Symbols = @($all | Where-Object {$_ -notin 'DOGE-USDT','BNB-USDT'}) })
    $rows += RunCfg 'port-noBoth+skip' ($common.Clone() + @{ Symbols = @($all | Where-Object {$_ -notin 'DOGE-USDT','BNB-USDT'}); FlatMode='skip' })
  }
  'solo' {
    foreach ($sym in 'BNB-USDT','DOGE-USDT') {
      $s = @{ Symbols=@($sym) }
      $rows += RunCfg "$sym-base"      ($common.Clone() + $s)
      $rows += RunCfg "$sym-gap0.4"    ($common.Clone() + $s + @{ TrendGapPctMin=0.4 })
      $rows += RunCfg "$sym-slope0.3"  ($common.Clone() + $s + @{ SlopePctMin=0.3 })
      $rows += RunCfg "$sym-flatskip"  ($common.Clone() + $s + @{ FlatMode='skip' })
    }
  }
  'v2' {
    # v2 research on deep Bybit history (2020/21 -> 2026, incl. 2022 bear).
    # One full-period run per config; per-subperiod metrics computed later from saved artifacts.
    $deep = 'C:\Users\klyde\trading-sim\data\deep'
    $v2out = 'C:\Users\klyde\trading-sim\data\v2'
    if (-not (Test-Path $v2out)) { New-Item -ItemType Directory -Path $v2out | Out-Null }
    if (-not (Test-Path (Join-Path $deep 'fng.json'))) { Copy-Item 'C:\Users\klyde\trading-sim\data\fng.json' (Join-Path $deep 'fng.json') }
    $dcommon = @{ BtcFilter = $true; MaxAtrPct = 3.0; DataDir = $deep }
    $cfgs = @(
      @{n='base';       p=@{}},
      @{n='flat-skip';  p=@{FlatMode='skip'}},
      @{n='flat-half';  p=@{FlatMode='halfrisk'}},
      @{n='early-exit'; p=@{EarlyExit=$true}},
      @{n='slope0.3';   p=@{SlopePctMin=0.3}},
      @{n='tp1.2';      p=@{RewardR=1.2}},
      @{n='tp2.0';      p=@{RewardR=2.0}},
      @{n='fund-real';  p=@{FundingDir=$deep}},
      @{n='fund-filter';p=@{FundingDir=$deep; FundingFilter=$true}},
      @{n='rangeV2';    p=@{RangeV2=$true}}
    )
    foreach ($c in $cfgs) {
      $rows += RunCfg "v2-$($c.n)" ($dcommon.Clone() + $c.p)
      # backtest writes artifacts into its DataDir - stash per config for subperiod analysis
      foreach ($f in 'bt_trades','bt_equity','bt_monthly') {
        $src = Join-Path $deep "$f.json"
        if (Test-Path $src) { Copy-Item $src (Join-Path $v2out "$($c.n)_$($f.Substring(3)).json") -Force }
      }
    }
  }
  'antichase' {
    # Anti-chase walk-forward grid on deep history (protocol: docs\backtests\anti_chase_walkforward.md).
    # Live-analog gates (BtcFilter + ATR cap 3 + flat-skip + real funding + funding filter) + one knob per run.
    # Selection happens ONLY on dev windows via tools\analyze_wf_years.ps1; wf_base doubles as the
    # bit-for-bit regression run for the new default-off params (reference: wf_base0, pre-edit code).
    $deep = 'C:\Users\klyde\trading-sim\data\deep'
    $v2out = 'C:\Users\klyde\trading-sim\data\v2'
    if (-not (Test-Path $v2out)) { New-Item -ItemType Directory -Path $v2out | Out-Null }
    if (-not (Test-Path (Join-Path $deep 'fng.json'))) { Copy-Item 'C:\Users\klyde\trading-sim\data\fng.json' (Join-Path $deep 'fng.json') }
    $dcommon = @{ BtcFilter = $true; MaxAtrPct = 3.0; DataDir = $deep; FlatMode = 'skip'; FundingDir = $deep; FundingFilter = $true }
    $cfgs = @(
      @{n='base';    p=@{}},
      @{n='ext1.0';  p=@{MaxExtAtr=1.0}},
      @{n='ext1.25'; p=@{MaxExtAtr=1.25}},
      @{n='ext1.5';  p=@{MaxExtAtr=1.5}},
      @{n='rsi60';   p=@{RsiMaxLong=60}},
      @{n='rsi65';   p=@{RsiMaxLong=65}}
    )
    foreach ($c in $cfgs) {
      $rows += RunCfg "wf-$($c.n)" ($dcommon.Clone() + $c.p)
      foreach ($f in 'bt_trades','bt_equity','bt_monthly') {
        $src = Join-Path $deep "$f.json"
        if (Test-Path $src) { Copy-Item $src (Join-Path $v2out "wf_$($c.n)_$($f.Substring(3)).json") -Force }
      }
    }
  }
  'antichase-combo' {
    # ONE combo run after dev selection: -ComboExt X and/or -ComboRsi Y; stashed as wf_combo_*.
    $deep = 'C:\Users\klyde\trading-sim\data\deep'
    $v2out = 'C:\Users\klyde\trading-sim\data\v2'
    $p = @{ BtcFilter = $true; MaxAtrPct = 3.0; DataDir = $deep; FlatMode = 'skip'; FundingDir = $deep; FundingFilter = $true }
    if ($ComboExt -gt 0) { $p.MaxExtAtr = $ComboExt }
    if ($ComboRsi -gt 0) { $p.RsiMaxLong = $ComboRsi }
    $rows += RunCfg "wf-combo(ext=$ComboExt,rsi=$ComboRsi)" $p
    foreach ($f in 'bt_trades','bt_equity','bt_monthly') {
      $src = Join-Path $deep "$f.json"
      if (Test-Path $src) { Copy-Item $src (Join-Path $v2out "wf_combo_$($f.Substring(3)).json") -Force }
    }
  }
  'fut' {
    # MOEX FORTS futures research. -Period IS (2020..2023, param selection ONLY here),
    # OOS1 (2024), OOS2 (2025..2026-07, one-shot final), full.
    $futDir = 'C:\Users\klyde\trading-sim\data\moex_fut'
    $futOut = 'C:\Users\klyde\trading-sim\data\fut_runs'
    if (-not (Test-Path $futOut)) { New-Item -ItemType Directory -Path $futOut | Out-Null }
    $win = switch ($Period) {
      'IS'   { @{ ToDate='2023-12-31' } }
      'OOS1' { @{ FromDate='2024-01-01'; ToDate='2024-12-31' } }
      'OOS2' { @{ FromDate='2025-01-01' } }
      'full' { @{} }
    }
    $fcommon = @{ Symbols=@('BR','NG','GOLD','SILV','Si','RTS','CNY','MIX'); DataDir=$futDir; FileSuffix='_1d'
                  IndexSymbol='IMOEX'; NoFng=$true; FundingPerBar=0; FeePct=0.0001; MaxLev=3; WarmupBars=60 } + $win
    $cfgs = @(
      @{n='A-base';     p=@{}},
      @{n='A-imoex';    p=@{BtcFilter=$true}},
      @{n='A-stop15';   p=@{AtrStopMult=1.5}},
      @{n='A-stop2';    p=@{AtrStopMult=2.0}},
      @{n='A-early';    p=@{EarlyExit=$true}},
      @{n='A-atrcap3';  p=@{MaxAtrPct=3.0}},
      @{n='B20-trail2'; p=@{Breakout=$true; BreakoutN=20; AtrTrailMult=2.0; AtrStopMult=2.0}},
      @{n='B20-trail3'; p=@{Breakout=$true; BreakoutN=20; AtrTrailMult=3.0; AtrStopMult=2.0}},
      @{n='B55-trail3'; p=@{Breakout=$true; BreakoutN=55; AtrTrailMult=3.0; AtrStopMult=2.0}},
      @{n='B55-trail4'; p=@{Breakout=$true; BreakoutN=55; AtrTrailMult=4.0; AtrStopMult=2.0}},
      @{n='B20-tp';     p=@{Breakout=$true; BreakoutN=20; AtrStopMult=2.0}},
      @{n='B55-tp';     p=@{Breakout=$true; BreakoutN=55; AtrStopMult=2.0}}
    )
    foreach ($c in $cfgs) {
      $rows += RunCfg "fut-$($c.n)-$Period" ($fcommon.Clone() + $c.p)
      foreach ($f in 'bt_trades','bt_equity','bt_monthly') {
        $src = Join-Path $futDir "$f.json"
        if (Test-Path $src) { Copy-Item $src (Join-Path $futOut "$($c.n)_$Period`_$($f.Substring(3)).json") -Force }
      }
    }
  }
  'futre' {
    # Re-entry-after-correction research on the frozen B20-trail3 core (2026-07-10).
    # Same windows/base as 'fut'; baseline saved as B20-trail3r (refreshed data) to keep old artifacts.
    $futDir = 'C:\Users\klyde\trading-sim\data\moex_fut'
    $futOut = 'C:\Users\klyde\trading-sim\data\fut_runs'
    if (-not (Test-Path $futOut)) { New-Item -ItemType Directory -Path $futOut | Out-Null }
    $win = switch ($Period) {
      'IS'   { @{ ToDate='2023-12-31' } }
      'OOS1' { @{ FromDate='2024-01-01'; ToDate='2024-12-31' } }
      'OOS2' { @{ FromDate='2025-01-01' } }
      'full' { @{} }
    }
    $fcommon = @{ Symbols=@('BR','NG','GOLD','SILV','Si','RTS','CNY','MIX'); DataDir=$futDir; FileSuffix='_1d'
                  IndexSymbol='IMOEX'; NoFng=$true; FundingPerBar=0; FeePct=0.0001; MaxLev=3; WarmupBars=60 } + $win
    $bo = @{ Breakout=$true; BreakoutN=20; AtrTrailMult=3.0; AtrStopMult=2.0 }
    $cfgs = @(
      @{n='B20-trail3r';          p=$bo.Clone()},
      @{n='B20-rearm10x10';       p=$bo.Clone() + @{ReArmN=10; ReArmBars=10}},
      @{n='B20-rearm10x15';       p=$bo.Clone() + @{ReArmN=10; ReArmBars=15}},
      @{n='B20-rearm12x20';       p=$bo.Clone() + @{ReArmN=12; ReArmBars=20}},
      @{n='B20-max4';             p=$bo.Clone() + @{MaxConcurrent=4}},
      @{n='B20-rearm10x15-max4';  p=$bo.Clone() + @{ReArmN=10; ReArmBars=15; MaxConcurrent=4}}
    )
    foreach ($c in $cfgs) {
      $rows += RunCfg "futre-$($c.n)-$Period" ($fcommon.Clone() + $c.p)
      foreach ($f in 'bt_trades','bt_equity','bt_monthly') {
        $src = Join-Path $futDir "$f.json"
        if (Test-Path $src) { Copy-Item $src (Join-Path $futOut "$($c.n)_$Period`_$($f.Substring(3)).json") -Force }
      }
    }
  }
  'solo-wf' {
    # walk-forward for per-coin winners (params passed via env-style args below)
    foreach ($sym in 'BNB-USDT','DOGE-USDT') {
      $s = @{ Symbols=@($sym) }
      foreach ($per in @(@{n='P1'; d=@{ToDate='2025-10-31'}}, @{n='P2'; d=@{FromDate='2025-11-01'}})) {
        $rows += RunCfg "$sym-base-$($per.n)"     ($common.Clone() + $s + $per.d)
        $rows += RunCfg "$sym-gap0.4-$($per.n)"   ($common.Clone() + $s + $per.d + @{ TrendGapPctMin=0.4 })
        $rows += RunCfg "$sym-slope0.3-$($per.n)" ($common.Clone() + $s + $per.d + @{ SlopePctMin=0.3 })
        $rows += RunCfg "$sym-flatskip-$($per.n)" ($common.Clone() + $s + $per.d + @{ FlatMode='skip' })
      }
    }
  }
}

$rows | Format-Table -AutoSize | Out-String
