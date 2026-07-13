# Live v2 signal scanner. Mirrors backtest.ps1 setup A exactly + v2 gates:
#   BTC trend filter, FlatMode=skip (no entries when BTC 4h == range),
#   ATR cap 3%, funding filter (+/-0.05%/8h), F&G extreme filter, R:R >= 1.5 (TP1=1.5R).
# Decision on the LAST CLOSED 4h bar (classic discipline). Writes data\signals.json.
param(
  # ВНИМАНИЕ: дефолт ниже = универсум LIVE-контура (live_engine.ps1 вызывает сканер БЕЗ -Symbols).
  # Менять только осознанным «live-коммитом» после бэктеста. Бумага (auto_trade.ps1) передаёт свой список явно.
  # 2026-07-13: расширен до 20 (решение пользователя по бэктесту, docs/backtests/backtest_pairs_expansion.md);
  # слабые APT/OP/AAVE отсечены на входе через $EXCLUDED в live_engine.ps1 (live торгует 17 - DOGE).
  [string[]]$Symbols = @('BTC-USDT','ETH-USDT','SOL-USDT','BNB-USDT','XRP-USDT','DOGE-USDT','ADA-USDT','AVAX-USDT','LINK-USDT',
                         'DOT-USDT','LTC-USDT','BCH-USDT','UNI-USDT','ATOM-USDT','NEAR-USDT','OP-USDT','APT-USDT','ARB-USDT','SUI-USDT','AAVE-USDT'),
  [double]$Equity = 10000, [double]$RiskPct = 0.006, [int]$PullbackLookback = 3,
  [string]$OutPath = ''   # куда писать результат; пусто = data/signals.json (paper, как раньше)
)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'
$dir = Split-Path $PSScriptRoot -Parent   # корень проекта (портируемо: локально и в GitHub Actions)
. (Join-Path $PSScriptRoot 'lib_engine.ps1')  # слой данных с фолбэками (Bybit заблокирован с раннеров Actions)

function EMAseries([double[]]$v,[int]$p){ $n=$v.Count;$o=New-Object 'double[]' $n;$k=2.0/($p+1);$s=0.0
  for($i=0;$i -lt $n;$i++){ if($i -lt $p){$s+=$v[$i];$o[$i]=[double]::NaN;if($i -eq $p-1){$o[$i]=$s/$p}}else{$o[$i]=$v[$i]*$k+$o[$i-1]*(1-$k)} } ,$o }
function RSIseries([double[]]$v,[int]$p){ $n=$v.Count;$o=New-Object 'double[]' $n;for($i=0;$i -lt $n;$i++){$o[$i]=[double]::NaN}
  if($n -le $p+1){return ,$o};$g=0.0;$l=0.0
  for($i=1;$i -le $p;$i++){$d=$v[$i]-$v[$i-1];if($d -gt 0){$g+=$d}else{$l-=$d}};$ag=$g/$p;$al=$l/$p
  $o[$p]=if($al -eq 0){100}else{100-100/(1+$ag/$al)}
  for($i=$p+1;$i -lt $n;$i++){$d=$v[$i]-$v[$i-1];$gg=0.0;$ll=0.0;if($d -gt 0){$gg=$d}else{$ll=-$d};$ag=($ag*($p-1)+$gg)/$p;$al=($al*($p-1)+$ll)/$p;$o[$i]=if($al -eq 0){100}else{100-100/(1+$ag/$al)}} ,$o }
function ATRseries([double[]]$h,[double[]]$l,[double[]]$c,[int]$p){ $n=$c.Count;$tr=New-Object 'double[]' $n;$o=New-Object 'double[]' $n
  for($i=0;$i -lt $n;$i++){ if($i -eq 0){$tr[$i]=$h[$i]-$l[$i]}else{$tr[$i]=[math]::Max($h[$i]-$l[$i],[math]::Max([math]::Abs($h[$i]-$c[$i-1]),[math]::Abs($l[$i]-$c[$i-1])))};$o[$i]=[double]::NaN }
  $s=0.0;for($i=0;$i -lt $p;$i++){$s+=$tr[$i]};$o[$p-1]=$s/$p
  for($i=$p;$i -lt $n;$i++){$o[$i]=($o[$i-1]*($p-1)+$tr[$i])/$p} ,$o }

function LoadKlines($sym){
  # через lib_engine: Bybit -> bytick -> BingX; отдаёт ЗАКРЫТЫЕ бары + текущий формирующийся
  # (решение принимается по bars.Count-2 = последний закрытый — семантика сканера не меняется)
  $nowMs = UtcNowMs
  $bars = Get-KlinesRange $sym '240' ($nowMs - [long]410*14400000) $nowMs ($nowMs + 14400000)
  return ,@($bars | ForEach-Object { $_ })
}
function LoadFunding($sym){ Get-FundingLast8h $sym }
# current Fear&Greed
$fng=$null; try{ $fj=Invoke-RestMethod -Uri "https://api.alternative.me/fng/?limit=1" -TimeoutSec 20; $fng=[int]$fj.data[0].value }catch{}

# ---- load all, compute indicators ----
$S=@{}
foreach($sym in $Symbols){
  $bars=LoadKlines $sym
  if($bars.Count -lt 210){ Write-Warning "$sym too few bars"; continue }
  $c=[double[]]($bars|ForEach-Object{$_.c}); $h=[double[]]($bars|ForEach-Object{$_.h}); $l=[double[]]($bars|ForEach-Object{$_.l}); $o=[double[]]($bars|ForEach-Object{$_.o}); $t=[long[]]($bars|ForEach-Object{$_.t})
  $S[$sym]=@{ bars=$bars;o=$o;h=$h;l=$l;c=$c;t=$t
    ema20=(EMAseries $c 20);ema50=(EMAseries $c 50);ema200=(EMAseries $c 200);rsi=(RSIseries $c 14);atr=(ATRseries $h $l $c 14)
    funding=(LoadFunding $sym) }
  Start-Sleep -Milliseconds 80
}

# ---- BTC regime on last CLOSED bar ----
function TrendAt($d,$i){ $c=$d.c[$i];$e20=$d.ema20[$i];$e50=$d.ema50[$i]
  if([double]::IsNaN($e50)){return 'na'}
  if(($c -gt $e50)-and($e20 -gt $e50)){'up'}elseif(($c -lt $e50)-and($e20 -lt $e50)){'down'}else{'range'} }

$btc=$S['BTC-USDT']
$ci=$btc.bars.Count-2   # last CLOSED bar index (last element is the forming bar)
$btcTrend=TrendAt $btc $ci
$flatBlock = ($btcTrend -eq 'range')

$signals=New-Object System.Collections.Generic.List[object]
$watch=New-Object System.Collections.Generic.List[object]

foreach($sym in $Symbols){
  if(-not $S.ContainsKey($sym)){continue}
  $d=$S[$sym]; $i=$d.bars.Count-2   # last closed bar
  $cl=$d.c[$i];$op=$d.o[$i];$e20=$d.ema20[$i];$e50=$d.ema50[$i];$e200=$d.ema200[$i];$rsi=$d.rsi[$i];$atr=$d.atr[$i]
  $atrPct=100*$atr/$cl
  $trend=TrendAt $d $i
  $up=($cl -gt $e50)-and($e20 -gt $e50); $down=($cl -lt $e50)-and($e20 -lt $e50)
  $fund=$d.funding  # fraction per 8h

  # setup A trigger (mirror backtest)
  $touched=$false;$rsiCool=$false;$rsiHot=$false
  for($j=$i-$PullbackLookback;$j -lt $i;$j++){ if($j -ge 0){
    if($up -and $d.l[$j] -le $d.ema20[$j]){$touched=$true}
    if($down -and $d.h[$j] -ge $d.ema20[$j]){$touched=$true}
    if($d.rsi[$j] -le 50){$rsiCool=$true}; if($d.rsi[$j] -ge 50){$rsiHot=$true} } }
  $trigLong = $up -and ($cl -gt $op) -and ($cl -gt $e20) -and (($d.c[$i-1] -le $d.ema20[$i-1]) -or ($d.rsi[$i-1] -le 50))
  $trigShort= $down -and ($cl -lt $op) -and ($cl -lt $e20) -and (($d.c[$i-1] -ge $d.ema20[$i-1]) -or ($d.rsi[$i-1] -ge 50))

  # per-pair setup-A sub-conditions (for watchlist "how close" display)
  $dir0 = if($up){'long'}elseif($down){'down'}else{$null}
  $sub=[ordered]@{
    trendOk = ($up -or $down)
    pullback = $touched
    rsiReset = if($up){$rsiCool}elseif($down){$rsiHot}else{$false}
    triggerBar = if($up){$trigLong}elseif($down){$trigShort}else{$false}
  }

  # gates
  $side=$null; $core=$false
  if($up -and $touched -and $rsiCool -and $trigLong){ $side='long'; $core=$true }
  elseif($down -and $touched -and $rsiHot -and $trigShort){ $side='short'; $core=$true }

  $gBtc = if($side -eq 'long'){ $btcTrend -ne 'down' } elseif($side -eq 'short'){ $btcTrend -ne 'up' } else { $true }
  $gFlat = -not $flatBlock
  $gAtr = $atrPct -le 3.0
  $gFund = if($side -eq 'long'){ ($null -eq $fund) -or ($fund -le 0.0005) } elseif($side -eq 'short'){ ($null -eq $fund) -or ($fund -ge -0.0005) } else { $true }
  $gFng = if($side -eq 'long'){ ($null -eq $fng) -or ($fng -lt 80) } elseif($side -eq 'short'){ ($null -eq $fng) -or ($fng -gt 20) } else { $true }

  $checks=[ordered]@{
    setupA=$core; btcFilter=$gBtc; flatMode=$gFlat; atrCap=$gAtr; funding=$gFund; fearGreed=$gFng
  }
  $pass = $core -and $gBtc -and $gFlat -and $gAtr -and $gFund -and $gFng

  $entry=$stop=$tp1=$rr=$qty=$null; $stopPct=$null
  if($core){
    if($side -eq 'long'){
      $sw=($d.l[[math]::Max(0,$i-$PullbackLookback)..$i]|Measure-Object -Minimum).Minimum
      $stopDist=[math]::Max($cl-$sw,$atr); $entry=$cl; $stop=$cl-$stopDist; $tp1=$cl+1.5*$stopDist
    } else {
      $sw=($d.h[[math]::Max(0,$i-$PullbackLookback)..$i]|Measure-Object -Maximum).Maximum
      $stopDist=[math]::Max($sw-$cl,$atr); $entry=$cl; $stop=$cl+$stopDist; $tp1=$cl-1.5*$stopDist
    }
    $stopPct=[math]::Round(100*$stopDist/$cl,2); $rr=1.5
    $qty=[math]::Round(($Equity*$RiskPct)/$stopDist,4)
  }

  # distance of price to the EMA20-50 pullback zone (context)
  $zLo=[math]::Min($e20,$e50);$zHi=[math]::Max($e20,$e50)
  $distZonePct = if($cl -ge $zLo -and $cl -le $zHi){0}elseif($cl -gt $zHi){[math]::Round(100*($cl-$zHi)/$cl,2)}else{[math]::Round(100*($cl-$zLo)/$cl,2)}

  $rec=[ordered]@{
    symbol=$sym; side=$side; trend=$trend; dir=$dir0; price=[math]::Round($cl,6)
    ema20=[math]::Round($e20,6); ema50=[math]::Round($e50,6); ema200=[math]::Round($e200,6)
    rsi=[math]::Round($rsi,1); atrPct=[math]::Round($atrPct,2); funding8h=$fund; barTime=$d.t[$i]
    distZonePct=$distZonePct; sub=$sub
    checks=$checks; pass=$pass
    entry=if($entry){[math]::Round($entry,6)}else{$null}; stop=if($stop){[math]::Round($stop,6)}else{$null}
    tp1=if($tp1){[math]::Round($tp1,6)}else{$null}; stopPct=$stopPct; rr=$rr; qty=$qty
    riskUsd=[math]::Round($Equity*$RiskPct,2)
  }
  if($pass){ $signals.Add($rec) } else { $watch.Add($rec) }
}

$out=[ordered]@{
  scannedUtc=(Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')
  strategy='v2'; btcTrend=$btcTrend; flatBlockAll=$flatBlock; fng=$fng
  closedBarUtc=[DateTimeOffset]::FromUnixTimeMilliseconds([long]$btc.t[$ci]).UtcDateTime.ToString('yyyy-MM-dd HH:mm')
  signals=[object[]]@($signals|ForEach-Object{$_}); watch=[object[]]@($watch|ForEach-Object{$_})
}
$sigPath = if ($OutPath) { $OutPath } else { Join-Path $dir 'data/signals.json' }
$out | ConvertTo-Json -Depth 6 | Out-File $sigPath -Encoding utf8

"=== v2 SIGNAL SCAN $($out.scannedUtc) UTC (closed 4h bar $($out.closedBarUtc)) ==="
"BTC 4h regime: $btcTrend  |  FlatMode blocks all entries: $flatBlock  |  F&G: $fng"
""
if($signals.Count){ "SIGNALS (all gates passed):"; $signals | ForEach-Object { "  {0} {1}  entry {2}  stop {3} ({4}%)  tp1 {5}  R:R {6}" -f $_.symbol,$_.side.ToUpper(),$_.entry,$_.stop,$_.stopPct,$_.tp1,$_.rr } }
else { "SIGNALS: none passed all v2 gates." }
""
"WATCHLIST (setup A core / why blocked):"
$watch | Where-Object { $_.checks.setupA } | ForEach-Object {
  $fail=@(); $_.checks.GetEnumerator() | ForEach-Object { if(-not $_.Value){$fail+=$_.Key} }
  "  {0} {1} core-setup YES, blocked by: {2}" -f $_.symbol,$_.side,($fail -join ', ')
}
"  (pairs with no core setup A: {0})" -f (@($watch | Where-Object { -not $_.checks.setupA }).Count)