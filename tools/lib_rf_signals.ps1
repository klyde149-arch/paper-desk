# lib_rf_signals.ps1 - сигнальное ядро стратегий рынка РФ (C2/C3b): ОБЩИЙ код paper-контура
# (rf_engine.ps1) и live-контура Т-Инвестиций (live_rf_engine.ps1). Вынесено из rf_engine.ps1
# 2026-07-15 механически (byte-identical поведение, защищено golden-replay-тестом).
# Требования к вызывающему: (1) заранее дот-сорснут lib_engine.ps1; (2) переменная $serDir
# (каталог непрерывных серий) определена до первого вызова Get-Ser/Save-Ser.
# Здесь ТОЛЬКО чистые функции сигналов/серий - никакого портфельного состояния ($profState/$shared),
# никаких комиссий и модели исполнения: они у каждого движка свои.

# ---- константы стратегии (эталон: tools\backtest.ps1 futures-набор + backtest_momentum.ps1) ----
# НЕ МЕНЯТЬ без walk-forward-протокола (docs\backtests\, правило пользователя).
$ATR_STOP_CORE = 2.0; $ATR_TRAIL = 3.0; $BRK_N = 20; $REARM_N = 10; $REARM_BARS = 15
$ATR_STOP_A = 1.0; $TPR = 1.5; $PBLOOK = 3; $RSI_TH = 50
$MAXCONC = 3; $MAXLEV = 3
$HALT_PCT = 0.06    # DailyLossHalt: репродукция Bfull_r3 показала - 0.06 (замороженный док) ближе к опубликованным C-цифрам
$MOM_LOOKBACK = 63; $MOM_SKIP = 21; $MOM_TOPK = 4; $MOM_JUMP = 40.0; $IMOEX_EMA = 200
$ASSETS = @('BR','NG','GOLD','SILV','Si','RTS','CNY','MIX')
$TICKERS = @('SBER','GAZP','LKOH','ROSN','NVTK','GMKN','TATN','MGNT','VTBR','CHMF','PLZL','YDEX')
$H1 = [long]3600000; $DAY = [long]86400000; $MSK = [long]10800000

# дневной бар даты D финален, когда MSK-время >= D+1 00:15 (23:50 закрытие + запас на задержку ISS)
function Get-RfCompletedDay([long]$MskNowMs) { MsToUtcDay ($MskNowMs - 15 * 60000 - $DAY) }

# ---- series io: {t,o,h,l,c,v}[] ----
$script:SER = @{}
function Get-Ser([string]$Name) {
  if (-not $script:SER.ContainsKey($Name)) {
    $raw = Read-JsonFile (Join-Path $serDir "$Name.json")
    $script:SER[$Name] = New-Object System.Collections.Generic.List[object]
    foreach ($b in @($raw)) { if ($null -ne $b) { $script:SER[$Name].Add($b) } }
  }
  return ,$script:SER[$Name]   # запятая: иначе return разворачивает List в фикс-массив (RemoveAt/Add ломаются)
}
function Save-Ser([string]$Name) {
  if ($script:SER.ContainsKey($Name)) { Write-JsonAtomic (Join-Path $serDir "$Name.json") (ToArr $script:SER[$Name]) 4 }
}
function SerDay($bar) { MsToUtcDay ([long]$bar.t) }

# докатать дневную серию до последнего завершённого дня: срез частичных хвостов + append закрытых баров ISS
function Update-DailySeries([string]$Name, [string]$Kind, [string]$Secid, [string]$CompletedDay) {
  $s = Get-Ser $Name
  # выбросить хвостовые ЧАСТИЧНЫЕ бары (день ещё не завершён на момент прежнего фетча)
  while ($s.Count -gt 0 -and (SerDay $s[$s.Count - 1]) -gt $CompletedDay) { $s.RemoveAt($s.Count - 1) }
  $lastDay = SerDay $s[$s.Count - 1]
  if ($lastDay -ge $CompletedDay) { return }
  $k = Get-IssCandles $Kind $Secid 24 ((MsToUtc ((UtcStrToMs "$lastDay 00:00") + $DAY)).ToString('yyyy-MM-dd'))
  foreach ($b in $k) {
    $d = SerDay $b
    if ($d -le $lastDay -or $d -gt $CompletedDay) { continue }
    $s.Add([pscustomobject]@{ t = [long]$b.t; o = [double]$b.o; h = [double]$b.h; l = [double]$b.l; c = [double]$b.c; v = [double]$b.v })
  }
  Save-Ser $Name
}

# рескейл непрерывной серии при ролле фронта: история * ratio (якорь = новый контракт)
function Invoke-SeriesRollRescale([string]$Name, [double]$Ratio) {
  $s = Get-Ser $Name
  for ($j = 0; $j -lt $s.Count; $j++) {
    $s[$j].o = [double]$s[$j].o * $Ratio; $s[$j].h = [double]$s[$j].h * $Ratio
    $s[$j].l = [double]$s[$j].l * $Ratio; $s[$j].c = [double]$s[$j].c * $Ratio
  }
  Save-Ser $Name
}

# ---- indicators on a series (List[object]) ----
function Ser-ATR14([System.Collections.Generic.List[object]]$s, [int]$i) {
  if ($i -lt 14) { return [double]::NaN }
  $sum = 0.0
  for ($k = $i - 13; $k -le $i; $k++) {
    $tr = [double]$s[$k].h - [double]$s[$k].l
    $a = [math]::Abs([double]$s[$k].h - [double]$s[$k-1].c); if ($a -gt $tr) { $tr = $a }
    $b = [math]::Abs([double]$s[$k].l - [double]$s[$k-1].c); if ($b -gt $tr) { $tr = $b }
    $sum += $tr
  }
  return $sum / 14.0   # простая средняя TR14 - для живого трейла достаточна (Wilder-сглаживание даёт <2% разницы уровня)
}
function Ser-EMA([System.Collections.Generic.List[object]]$s, [int]$p, [int]$i) {
  if ($i -lt $p - 1) { return [double]::NaN }
  $k = 2.0 / ($p + 1); $e = 0.0
  for ($j = 0; $j -lt $p; $j++) { $e += [double]$s[$j].c }
  $e = $e / $p
  for ($j = $p; $j -le $i; $j++) { $e = [double]$s[$j].c * $k + $e * (1 - $k) }
  return $e
}
function Ser-RSI14([System.Collections.Generic.List[object]]$s, [int]$i) {
  if ($i -lt 15) { return [double]::NaN }
  $g = 0.0; $l = 0.0
  for ($j = 1; $j -le 14; $j++) { $d = [double]$s[$j].c - [double]$s[$j-1].c; if ($d -gt 0) { $g += $d } else { $l -= $d } }
  $ag = $g / 14.0; $al = $l / 14.0
  for ($j = 15; $j -le $i; $j++) {
    $d = [double]$s[$j].c - [double]$s[$j-1].c
    $gg = 0.0; $ll = 0.0; if ($d -gt 0) { $gg = $d } else { $ll = -$d }
    $ag = ($ag * 13 + $gg) / 14.0; $al = ($al * 13 + $ll) / 14.0
  }
  if ($al -eq 0) { return 100.0 }
  return 100.0 - 100.0 / (1.0 + $ag / $al)
}
function Ser-IdxOfDay([System.Collections.Generic.List[object]]$s, [string]$day) {
  for ($i = $s.Count - 1; $i -ge 0; $i--) { $d = SerDay $s[$i]; if ($d -eq $day) { return $i }; if ($d -lt $day) { return -1 } }
  return -1
}

# ---- сигналы ----

# ядро B: Donchian-брейкаут по close за канал [i-BRK_N .. i-1] + re-arm (укороченный канал REARM_N
# в сторону недавнего выхода, окно REARM_BARS баров). $rearm: $null | объект {exit_day; dir} этого профиля.
# результат: @{ side=''|'long'|'short'; hi; lo } (hi/lo - границы фактически применённого канала, для note)
function Get-DonchianSide([System.Collections.Generic.List[object]]$s, [int]$i, $rearm) {
  $cl = [double]$s[$i].c
  $hiN = -1e18; $loN = 1e18
  for ($k2 = $i - $BRK_N; $k2 -le $i - 1; $k2++) {
    if ([double]$s[$k2].h -gt $hiN) { $hiN = [double]$s[$k2].h }
    if ([double]$s[$k2].l -lt $loN) { $loN = [double]$s[$k2].l }
  }
  $chHi = $hiN; $chLo = $loN
  if ($null -ne $rearm) {
    $exIdx = Ser-IdxOfDay $s ([string]$rearm.exit_day)
    if ($exIdx -ge 0 -and ($i - $exIdx) -ge 1 -and ($i - $exIdx) -le $REARM_BARS -and $i -gt ($REARM_N + 1)) {
      if ($rearm.dir -eq 'long') { $h2 = -1e18; for ($k2 = $i - $REARM_N; $k2 -le $i - 1; $k2++) { if ([double]$s[$k2].h -gt $h2) { $h2 = [double]$s[$k2].h } }; $chHi = $h2 }
      else { $l2 = 1e18; for ($k2 = $i - $REARM_N; $k2 -le $i - 1; $k2++) { if ([double]$s[$k2].l -lt $l2) { $l2 = [double]$s[$k2].l } }; $chLo = $l2 }
    }
  }
  $side = ''
  if ($cl -gt $chHi) { $side = 'long' } elseif ($cl -lt $chLo) { $side = 'short' }
  return @{ side = $side; hi = $chHi; lo = $chLo }
}

# setup A: тренд EMA20/EMA50 + откат-касание EMA20 за PBLOOK баров + RSI-сброс через порог + триггер-бар.
# результат: $null | @{ side; swing } (swing - экстремум последних PBLOOK+1 баров, стоп-база)
function Get-SetupASignal([System.Collections.Generic.List[object]]$s, [int]$i) {
  $cl = [double]$s[$i].c
  $e20d = Ser-EMA $s 20 $i; $e50d = Ser-EMA $s 50 $i; $rsiD = Ser-RSI14 $s $i
  if ([double]::IsNaN($e20d) -or [double]::IsNaN($e50d) -or [double]::IsNaN($rsiD)) { return $null }
  $up = ($cl -gt $e50d) -and ($e20d -gt $e50d)
  $dn = ($cl -lt $e50d) -and ($e20d -lt $e50d)
  $touched = $false; $rsiCool = $false; $rsiHot = $false
  for ($j = $i - $PBLOOK; $j -lt $i; $j++) {
    if ($j -lt 0) { continue }
    $e20j = Ser-EMA $s 20 $j
    if ([double]::IsNaN($e20j)) { continue }
    if ($up -and [double]$s[$j].l -le $e20j) { $touched = $true }
    if ($dn -and [double]$s[$j].h -ge $e20j) { $touched = $true }
    $rsij = Ser-RSI14 $s $j
    if (-not [double]::IsNaN($rsij)) { if ($rsij -le $RSI_TH) { $rsiCool = $true }; if ($rsij -ge $RSI_TH) { $rsiHot = $true } }
  }
  $e20prev = Ser-EMA $s 20 ($i - 1); $rsiPrev = Ser-RSI14 $s ($i - 1)
  $op = [double]$s[$i].o
  $trigL = $up -and ($cl -gt $op) -and ($cl -gt $e20d) -and (([double]$s[$i-1].c -le $e20prev) -or ($rsiPrev -le $RSI_TH))
  $trigS = $dn -and ($cl -lt $op) -and ($cl -lt $e20d) -and (([double]$s[$i-1].c -ge $e20prev) -or ($rsiPrev -ge $RSI_TH))
  $sideA = ''
  if ($up -and $touched -and $rsiCool -and $trigL) { $sideA = 'long' }
  elseif ($dn -and $touched -and $rsiHot -and $trigS) { $sideA = 'short' }
  if ($sideA -eq '') { return $null }
  # свинг-стоп: экстремум последних PBLOOK+1 баров
  $sw = if ($sideA -eq 'long') { $m = 1e18; for ($j = [math]::Max(0, $i - $PBLOOK); $j -le $i; $j++) { if ([double]$s[$j].l -lt $m) { $m = [double]$s[$j].l } }; $m }
        else { $m = -1e18; for ($j = [math]::Max(0, $i - $PBLOOK); $j -le $i; $j++) { if ([double]$s[$j].h -gt $m) { $m = [double]$s[$j].h } }; $m }
  return @{ side = $sideA; swing = $sw }
}

# трейл-люстра ядра: новый стоп (только подтягивается) или $null
function Get-ChandelierStop([string]$Side, [double]$Mfe, [double]$Stop, [double]$Atr) {
  if ([double]::IsNaN($Atr)) { return $null }
  if ($Side -eq 'long') { $ns = $Mfe - $ATR_TRAIL * $Atr; if ($ns -gt $Stop) { return [math]::Round($ns, 6) } }
  else { $ns = $Mfe + $ATR_TRAIL * $Atr; if ($ns -lt $Stop) { return [math]::Round($ns, 6) } }
  return $null
}

# трейл-выход сетапа A после TP1: закрытие бара за EMA20 против позиции
function Test-SetAEma20Exit([System.Collections.Generic.List[object]]$s, [int]$i, [string]$Side) {
  $e20 = Ser-EMA $s 20 $i
  if ([double]::IsNaN($e20)) { return $false }
  if ($Side -eq 'long') { return ([double]$s[$i].c -lt $e20) } else { return ([double]$s[$i].c -gt $e20) }
}

# momentum: гейт IMOEX>EMA200 + скоринг 63/21 только положительных с guard сплитов; топ-K.
# Детект "1-й торговый день месяца" остаётся у вызывающего (нужен prev-бар IMOEX).
# результат: $null (нет бара IMOEX на D) | @{ gate; target[] }
function Get-MomentumTarget([string]$D) {
  $ix = Get-Ser 'IMOEX'
  $ii = Ser-IdxOfDay $ix $D
  if ($ii -lt 0) { return $null }
  $gate = $false
  $ema200 = Ser-EMA $ix $IMOEX_EMA $ii
  if (-not [double]::IsNaN($ema200)) { $gate = ([double]$ix[$ii].c -gt $ema200) }
  # скоринг: доходность за 63 дня, заканчивая 21 день назад; только положительные; guard сплитов
  $scored = New-Object System.Collections.Generic.List[object]
  foreach ($t in $TICKERS) {
    $ss = Get-Ser $t
    $ti = Ser-IdxOfDay $ss $D
    if ($ti -lt 0) { continue }
    $iEnd = $ti - $MOM_SKIP; $iBeg = $iEnd - $MOM_LOOKBACK
    if ($iBeg -lt 1) { continue }
    $jump = $false
    for ($j = $iBeg; $j -le $ti; $j++) {
      $chg = [math]::Abs(100.0 * ([double]$ss[$j].c / [double]$ss[$j-1].c - 1))
      if ($chg -gt $MOM_JUMP) { $jump = $true; break }
    }
    if ($jump) { continue }
    $score = [double]$ss[$iEnd].c / [double]$ss[$iBeg].c - 1
    if ($score -le 0) { continue }
    $scored.Add([pscustomobject]@{ sym = $t; score = $score })
  }
  $target = @()
  if ($gate) { $target = @($scored | Sort-Object score -Descending | Select-Object -First $MOM_TOPK | ForEach-Object { $_.sym }) }
  return @{ gate = $gate; target = $target }
}
