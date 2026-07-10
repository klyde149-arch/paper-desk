# challenge\tools\research.ps1 - staged research runner for the 30-day challenge.
# Stage 1: setup selection on IS (2021-2023), fixed risk 5% / lev 15.
# Stage 2: risk x leverage grid on IS for the chosen setup.
# Stage 3: frozen config, one shot on VAL (2024) and HOLDOUT (2025+, ~30% of history, touched once).
# 'table' prints a combined table from existing artifacts.
param(
    [ValidateSet('1','1b','1c','1d','2','3','table')]
    [string]$Stage = 'table',
    # frozen-setup params used by stages 2 and 3
    [string]$Setup = 'S1',
    [int]$BreakN = 24,
    [string]$ExitMode = 'trail',
    [double]$TrailMult = 3.0,
    # frozen risk params used by stage 3
    [double]$RiskPct = 0.05,
    [double]$LevTarget = 15,
    # optional subset filter (comma list of tags) for parallel invocation
    [string]$Only = ''
)

$ErrorActionPreference = 'Stop'
$toolsDir = $PSScriptRoot
$dataDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'data'
$bt = Join-Path $toolsDir 'backtest.ps1'
$an = Join-Path $toolsDir 'analyze.ps1'

$IS_FROM = '2021-01-01'; $IS_TO = '2023-12-31'
$VAL_FROM = '2024-01-01'; $VAL_TO = '2024-12-31'
$HOLD_FROM = '2025-01-01'; $HOLD_TO = ''

function Get-Configs([string]$stage) {
    $cfgs = @()
    if ($stage -eq '1') {
        foreach ($def in @(
            @{ tag='is_s1n24_tr'; Setup='S1'; BreakN=24; ExitMode='trail' },
            @{ tag='is_s1n24_tp'; Setup='S1'; BreakN=24; ExitMode='tp2r' },
            @{ tag='is_s1n48_tr'; Setup='S1'; BreakN=48; ExitMode='trail' },
            @{ tag='is_s1n48_tp'; Setup='S1'; BreakN=48; ExitMode='tp2r' },
            @{ tag='is_s2_tr';    Setup='S2'; BreakN=24; ExitMode='trail' },
            @{ tag='is_s2_tp';    Setup='S2'; BreakN=24; ExitMode='tp2r' },
            @{ tag='is_s3_tr';    Setup='S3'; BreakN=24; ExitMode='trail' },
            @{ tag='is_s3_tp';    Setup='S3'; BreakN=24; ExitMode='tp2r' }
        )) {
            $cfgs += @{ Tag=$def.tag; Setup=$def.Setup; BreakN=$def.BreakN; ExitMode=$def.ExitMode
                        RiskPct=0.05; LevTarget=15; FromDate=$IS_FROM; ToDate=$IS_TO }
        }
    } elseif ($stage -eq '1b') {
        # design iteration, still IS-only: quality floor (MinScore), rarer breakouts, wider exits
        foreach ($def in @(
            @{ tag='is_b_ms03';    Setup='S1'; BreakN=24; ExitMode='trail'; MinScore=0.3 },
            @{ tag='is_b_ms06';    Setup='S1'; BreakN=24; ExitMode='trail'; MinScore=0.6 },
            @{ tag='is_b_ms10';    Setup='S1'; BreakN=24; ExitMode='trail'; MinScore=1.0 },
            @{ tag='is_b_n96';     Setup='S1'; BreakN=96; ExitMode='trail' },
            @{ tag='is_b_n96tp3';  Setup='S1'; BreakN=96; ExitMode='tp3r' },
            @{ tag='is_b_tr5h72';  Setup='S1'; BreakN=24; ExitMode='trail'; TrailMult=5.0; MaxHoldBars=72 },
            @{ tag='is_b_stop3';   Setup='S1'; BreakN=24; ExitMode='trail'; AtrStopMult=3.0 },
            @{ tag='is_b_lo_tp';   Setup='S1'; BreakN=24; ExitMode='tp2r'; LongOnly=$true },
            @{ tag='is_b_combo';   Setup='S1'; BreakN=96; ExitMode='trail'; TrailMult=5.0; MaxHoldBars=72; MinScore=0.6 },
            @{ tag='is_b_s2ms06';  Setup='S2'; BreakN=24; ExitMode='tp2r'; MinScore=0.6 }
        )) {
            $c = @{ Tag=$def.tag; Setup=$def.Setup; BreakN=$def.BreakN; ExitMode=$def.ExitMode
                    RiskPct=0.05; LevTarget=15; FromDate=$IS_FROM; ToDate=$IS_TO }
            foreach ($k in @('MinScore','TrailMult','MaxHoldBars','AtrStopMult','LongOnly')) {
                if ($def.ContainsKey($k)) { $c[$k] = $def[$k] }
            }
            $cfgs += $c
        }
    } elseif ($stage -eq '1c') {
        # mean-reversion-with-trend family (motivated by Stage 1/1b evidence that breakout-buying loses)
        foreach ($def in @(
            @{ tag='is_c_s4n24tp2'; Setup='S4'; BreakN=24; ExitMode='tp2r' },
            @{ tag='is_c_s4n24tr';  Setup='S4'; BreakN=24; ExitMode='trail' },
            @{ tag='is_c_s4n48tp2'; Setup='S4'; BreakN=48; ExitMode='tp2r' },
            @{ tag='is_c_s4n24tp3'; Setup='S4'; BreakN=24; ExitMode='tp3r' },
            @{ tag='is_c_s5tp2';    Setup='S5'; BreakN=24; ExitMode='tp2r' },
            @{ tag='is_c_s5tr';     Setup='S5'; BreakN=24; ExitMode='trail' },
            @{ tag='is_c_s5tp3';    Setup='S5'; BreakN=24; ExitMode='tp3r' },
            @{ tag='is_c_s4lotp2';  Setup='S4'; BreakN=24; ExitMode='tp2r'; LongOnly=$true }
        )) {
            $c = @{ Tag=$def.tag; Setup=$def.Setup; BreakN=$def.BreakN; ExitMode=$def.ExitMode
                    RiskPct=0.05; LevTarget=15; FromDate=$IS_FROM; ToDate=$IS_TO }
            foreach ($k in @('MinScore','TrailMult','MaxHoldBars','AtrStopMult','LongOnly')) {
                if ($def.ContainsKey($k)) { $c[$k] = $def[$k] }
            }
            $cfgs += $c
        }
    } elseif ($stage -eq '1d') {
        # slow trend-following: rare breakouts, multi-day rides (positions may span days; still max one ENTRY per day)
        foreach ($def in @(
            @{ tag='is_d_n96tr5';   Setup='S1'; BreakN=96;  ExitMode='trail'; TrailMult=5.0; MaxHoldBars=240 },
            @{ tag='is_d_n96tr8';   Setup='S1'; BreakN=96;  ExitMode='trail'; TrailMult=8.0; MaxHoldBars=240 },
            @{ tag='is_d_s4tr5';    Setup='S4'; BreakN=24;  ExitMode='trail'; TrailMult=5.0; MaxHoldBars=240 },
            @{ tag='is_d_n168tr5';  Setup='S1'; BreakN=168; ExitMode='trail'; TrailMult=5.0; MaxHoldBars=240 }
        )) {
            $c = @{ Tag=$def.tag; Setup=$def.Setup; BreakN=$def.BreakN; ExitMode=$def.ExitMode
                    RiskPct=0.05; LevTarget=15; FromDate=$IS_FROM; ToDate=$IS_TO }
            foreach ($k in @('MinScore','TrailMult','MaxHoldBars','AtrStopMult','LongOnly')) {
                if ($def.ContainsKey($k)) { $c[$k] = $def[$k] }
            }
            $cfgs += $c
        }
    } elseif ($stage -eq '2') {
        foreach ($r in @(0.03, 0.05, 0.07, 0.10)) {
            foreach ($lv in @(10, 15, 20, 25)) {
                $rTxt = [int]($r * 100); $lTxt = [int]$lv
                $cfgs += @{ Tag=("is2_r{0}_l{1}" -f $rTxt, $lTxt); Setup=$Setup; BreakN=$BreakN; ExitMode=$ExitMode
                            TrailMult=$TrailMult; RiskPct=$r; LevTarget=$lv; FromDate=$IS_FROM; ToDate=$IS_TO }
            }
        }
    } elseif ($stage -eq '3') {
        $cfgs += @{ Tag='val_frozen';  Setup=$Setup; BreakN=$BreakN; ExitMode=$ExitMode; TrailMult=$TrailMult
                    RiskPct=$RiskPct; LevTarget=$LevTarget; FromDate=$VAL_FROM; ToDate=$VAL_TO }
        $cfgs += @{ Tag='hold_frozen'; Setup=$Setup; BreakN=$BreakN; ExitMode=$ExitMode; TrailMult=$TrailMult
                    RiskPct=$RiskPct; LevTarget=$LevTarget; FromDate=$HOLD_FROM; ToDate=$HOLD_TO }
    }
    return $cfgs
}

function Print-Table {
    $rows = @()
    foreach ($sf in (Get-ChildItem $dataDir -Filter 'bt_*_summary.json' | Sort-Object Name)) {
        $s = Get-Content $sf.FullName -Raw | ConvertFrom-Json
        $tag = $s.tag
        if ($tag -eq 'smoke') { continue }
        $stPath = Join-Path $dataDir "st_${tag}.json"
        $med = ''; $ruin = ''; $p2x = ''; $p10x = ''
        if (Test-Path $stPath) {
            $st = Get-Content $stPath -Raw | ConvertFrom-Json
            $med = $st.historical.median; $ruin = $st.historical.pctRuin
            $p2x = $st.historical.pct2x; $p10x = $st.historical.pct10x
        }
        $rows += [pscustomobject]@{
            tag = $tag; setup = $s.setup; exit = $s.exitMode; N = $s.breakN
            'risk%' = ($s.riskPct * 100); lev = $s.levTarget
            trades = $s.trades; 'tr/d' = $s.tradesPerDay
            'ret%' = $s.totalReturnPct; PF = $s.profitFactor; 'WR%' = $s.winRatePct
            'DD%' = $s.maxDDPct; liq = $s.liquidations
            med30 = $med; '2x%' = $p2x; '10x%' = $p10x; 'ruin%' = $ruin
        }
    }
    $rows | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
}

if ($Stage -eq 'table') { Print-Table; exit 0 }

$configs = Get-Configs $Stage
if ($Only) {
    $names = $Only.Split(',')
    $configs = @($configs | Where-Object { $names -contains $_.Tag })
}

$swTotal = [Diagnostics.Stopwatch]::StartNew()
foreach ($cfg in $configs) {
    $args2 = @{}
    foreach ($k in $cfg.Keys) { $args2[$k] = $cfg[$k] }
    if (-not $args2.ContainsKey('TrailMult')) { $args2['TrailMult'] = $TrailMult }
    Write-Host (">>> {0}" -f $cfg.Tag)
    & $bt @args2 -Quiet
    & $an -Tag $cfg.Tag -Quiet
    $s = Get-Content (Join-Path $dataDir ("bt_{0}_summary.json" -f $cfg.Tag)) -Raw | ConvertFrom-Json
    $st = Get-Content (Join-Path $dataDir ("st_{0}.json" -f $cfg.Tag)) -Raw | ConvertFrom-Json
    Write-Host ("    trades={0} ret={1}% PF={2} DD={3}% liq={4} | med30={5} 2x%={6} ruin%={7} | inv.ok={8}" -f `
        $s.trades, $s.totalReturnPct, $s.profitFactor, $s.maxDDPct, $s.liquidations, `
        $st.historical.median, $st.historical.pct2x, $st.historical.pctRuin, $st.invariants.ok)
}
Write-Host ("Stage {0} done in {1:n1} min" -f $Stage, $swTotal.Elapsed.TotalMinutes)
