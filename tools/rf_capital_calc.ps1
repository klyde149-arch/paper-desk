# rf_capital_calc.ps1 - калькулятор капитала для LIVE-контура C3b на фьючерсах FORTS (Т-Инвестиции).
# Без токена: ГО/шаг/стоимость шага - MOEX ISS, ATR14 - непрерывные серии paper-контура (data\rf\series),
# фолбэк - канонические склейки data\moex_fut. Формула ATR идентична rf_engine.ps1 (простое среднее TR14).
# Отвечает на вопрос: сколько целых контрактов даёт риск-бюджет рукавов при заданном капитале,
# и какой минимальный капитал нужен, чтобы каждый инструмент проходил хотя бы на 1 лот.
param(
  [string]$Root = '',
  [double]$Capital = 700000,     # база каждого sleeve-леджера, руб
  [double]$CoreRisk = 0.05,      # C3b: ядро B
  [double]$SetARisk = 0.02,      # C3b: setup A
  [double]$MomWeight = 0.5,      # доля mom_eq в акциях (режет свободный кэш под ГО)
  [double]$ReserveRub = 50000,   # неприкосновенный резерв
  [double]$GoCapPct = 0.60,      # собственный стоп по ГО
  [int]$MaxLev = 3,              # зеркало кэпа плеча paper (MAXLEV)
  [string]$OutDoc = ''           # путь markdown-отчёта; '' = docs\backtests\rf_capital_calc_<yyyy-MM>.md
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'lib_engine.ps1')

$ASSETS = @('BR','NG','GOLD','SILV','Si','RTS','CNY','MIX')

# ---- параметры контрактов с ISS (одним вызовом) ----
$secUrl = 'https://iss.moex.com/iss/engines/futures/markets/forts/securities.json?iss.only=securities&securities.columns=SECID,ASSETCODE,MINSTEP,STEPPRICE,INITIALMARGIN,LASTTRADEDATE,PREVSETTLEPRICE'
$r = Invoke-Iss $secUrl
$mskToday = (Get-Date).ToUniversalTime().AddHours(3).ToString('yyyy-MM-dd')
$rollEdge = (Get-Date).ToUniversalTime().AddHours(3).AddDays(4).ToString('yyyy-MM-dd')
$byAsset = @{}
foreach ($row in @($r.securities.data)) {
  $a = [string]$row[1]
  if ($ASSETS -notcontains $a) { continue }
  $ltd = [string]$row[5]
  if (-not $ltd -or $ltd -lt $mskToday) { continue }
  if (-not $byAsset.ContainsKey($a)) { $byAsset[$a] = New-Object System.Collections.Generic.List[object] }
  $byAsset[$a].Add([pscustomobject]@{
    secid = [string]$row[0]; minstep = [double]$row[2]; stepprice = [double]$row[3]
    go = [double]$row[4]; lasttrade = $ltd; prevsettle = [double]$row[6] })
}

# ---- ATR14 как в rf_engine.ps1 (простое среднее TR за 14 баров) ----
function Calc-ATR14($bars) {
  $n = $bars.Count
  if ($n -lt 15) { return [double]::NaN }
  $i = $n - 1; $sum = 0.0
  for ($k = $i - 13; $k -le $i; $k++) {
    $tr = [double]$bars[$k].h - [double]$bars[$k].l
    $a = [math]::Abs([double]$bars[$k].h - [double]$bars[$k-1].c); if ($a -gt $tr) { $tr = $a }
    $b = [math]::Abs([double]$bars[$k].l - [double]$bars[$k-1].c); if ($b -gt $tr) { $tr = $b }
    $sum += $tr
  }
  return $sum / 14.0
}

$riskCore = $Capital * $CoreRisk
$riskSetA = $Capital * $SetARisk
$rows = New-Object System.Collections.Generic.List[object]
foreach ($a in $ASSETS) {
  if (-not $byAsset.ContainsKey($a)) { Write-Warning "нет контрактов $a на ISS"; continue }
  $chain = @($byAsset[$a] | Sort-Object lasttrade)
  $front = $chain[0]
  # в зоне ролла (<=4 дней до LASTTRADEDATE) live входит сразу в следующий контракт
  if ($front.lasttrade -le $rollEdge -and $chain.Count -gt 1) { $front = $chain[1] }

  $serPath = Join-Path $Root "data\rf\series\$a.json"
  if (-not (Test-Path $serPath)) { $serPath = Join-Path $Root "data\moex_fut\$($a)_1d.json" }
  $rawSer = Read-JsonFile $serPath   # присваивание разворачивает обёртку ConvertFrom-Json (PS 5.1)
  $bars = @($rawSer)
  $atr = Calc-ATR14 $bars
  $px = [double]$bars[$bars.Count-1].c

  $rubPt = $front.stepprice / $front.minstep         # руб за 1 пункт цены
  $notional = $px * $rubPt                            # руб за 1 контракт
  $stopCoreRub = 2.0 * $atr * $rubPt                  # стоп ядра 2xATR14
  $stopSetARub = 1.0 * $atr * $rubPt                  # setA: max(свинг,1xATR) >= 1xATR - оценка сверху по лотам
  $levCap = [math]::Floor($MaxLev * $Capital / $notional)
  $lotsCore = [math]::Min([math]::Floor($riskCore / $stopCoreRub), $levCap)
  $lotsSetA = [math]::Min([math]::Floor($riskSetA / $stopSetARub), $levCap)
  $rows.Add([pscustomobject]@{
    asset = $a; secid = $front.secid; lasttrade = $front.lasttrade
    px = $px; atr = [math]::Round($atr, 4); rubPt = [math]::Round($rubPt, 4)
    notional = [math]::Round($notional); go = [math]::Round($front.go)
    stopCoreRub = [math]::Round($stopCoreRub); stopSetARub = [math]::Round($stopSetARub)
    lotsCore = [int]$lotsCore; lotsSetA = [int]$lotsSetA
    goCore = [math]::Round($lotsCore * $front.go); goSetA = [math]::Round($lotsSetA * $front.go)
    minCapCore = [math]::Round($stopCoreRub / $CoreRisk)   # капитал, при котором ядро даёт >=1 лот
    minCapSetA = [math]::Round($stopSetARub / $SetARisk)
  })
}

# ---- бюджет ГО и худший случай ----
$stockRub = $MomWeight * $Capital
$futBudget = $Capital - $stockRub - $ReserveRub
$goCap = $GoCapPct * $futBudget
$worstCore = @($rows | Sort-Object goCore -Descending | Select-Object -First 3)  # MAXCONC=3
$worstSetA = @($rows | Sort-Object goSetA -Descending | Select-Object -First 2)
$goWorst = ($worstCore | Measure-Object goCore -Sum).Sum + ($worstSetA | Measure-Object goSetA -Sum).Sum

# ---- вывод ----
$inv = [System.Globalization.CultureInfo]::InvariantCulture
function N0([double]$v) { $v.ToString('N0', $inv) }
$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Калькулятор капитала LIVE C3b (фьючерсы FORTS, Т-Инвестиции)")
$md.Add("")
$md.Add(("Дата: {0} MSK · капитал (база каждого рукава): {1} ₽ · риск core {2}% / setA {3}% · MAXLEV {4}" -f $mskToday, (N0 $Capital), ($CoreRisk*100), ($SetARisk*100), $MaxLev))
$md.Add(("Риск-бюджет на сделку: core {0} ₽ · setA {1} ₽. ГО из ISS (INITIALMARGIN), пункты→рубли через STEPPRICE/MINSTEP." -f (N0 $riskCore), (N0 $riskSetA)))
$md.Add("")
$md.Add("| Актив | Фронт | Эксп. | Цена (пт) | ATR14 (пт) | ₽/пт | Нотионал 1К | ГО 1К | Стоп core ₽ | **Лоты core** | Стоп setA ₽ | **Лоты setA** | Мин. кап. core | Мин. кап. setA |")
$md.Add("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
foreach ($x in $rows) {
  $md.Add(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | **{9}** | {10} | **{11}** | {12} | {13} |" -f `
    $x.asset, $x.secid, $x.lasttrade, $x.px.ToString($inv), $x.atr.ToString($inv), $x.rubPt.ToString($inv), `
    (N0 $x.notional), (N0 $x.go), (N0 $x.stopCoreRub), $x.lotsCore, (N0 $x.stopSetARub), $x.lotsSetA, (N0 $x.minCapCore), (N0 $x.minCapSetA)))
}
$md.Add("")
$md.Add("## Бюджет ГО")
$md.Add(("- Акции momentum (~{0}×{1}): ~{2} ₽ · резерв {3} ₽ → фьючерсный бюджет {4} ₽" -f $MomWeight, (N0 $Capital), (N0 $stockRub), (N0 $ReserveRub), (N0 $futBudget)))
$md.Add(("- Кэп ГО {0}%: **{1} ₽**" -f ($GoCapPct*100), (N0 $goCap)))
$md.Add(("- Худший случай (3 самых дорогих core-позиции полным сайзом + 2 setA): **{0} ₽** → {1}" -f (N0 $goWorst), $(if ($goWorst -le $goCap) { 'проходит' } else { 'НЕ помещается — ГО-governor будет резать сайз (это штатно, но фиксируем)' })))
$md.Add(("  - core top-3 по ГО: " + (($worstCore | ForEach-Object { "{0}={1}₽" -f $_.asset, (N0 $_.goCore) }) -join ', ')))
$md.Add("")
$md.Add("## Выводы")
$failCore = @($rows | Where-Object { $_.lotsCore -lt 1 })
$failSetA = @($rows | Where-Object { $_.lotsSetA -lt 1 })
if (-not $failCore.Count) { $md.Add("- Ядро (core): все 8 инструментов проходят на >=1 лот. Универсум сохраняется полностью.") }
else { $md.Add("- Ядро: НЕ проходят: " + (($failCore | ForEach-Object { $_.asset }) -join ', ') + " — требуется решение (мин. капитал в таблице).") }
if (-not $failSetA.Count) { $md.Add("- SetA: все 8 инструментов проходят на >=1 лот (оценка по стопу 1×ATR — реальный стоп может быть шире за счёт свинга, лоты только меньше).") }
else { $md.Add("- SetA: на >=1 лот НЕ проходят: " + (($failSetA | ForEach-Object { $_.asset }) -join ', ') + " — сигналы по ним будут пропускаться с логом SKIP qty0 (штатная целочисленная дивергенция).") }
$md.Add("- Оценка setA — верхняя граница по лотам: фактический стоп = max(свинг-экстремум, 1×ATR) >= 1×ATR.")
$md.Add("- ГО и ATR плавают: пересчитывать перед Phase 3 (боевой микро) и на квартальной валидации.")

$mdText = $md -join "`r`n"
if (-not $OutDoc) { $OutDoc = Join-Path $Root ("docs\backtests\rf_capital_calc_{0}.md" -f (Get-Date).ToUniversalTime().AddHours(3).ToString('yyyy-MM')) }
[System.IO.File]::WriteAllText($OutDoc, $mdText, (New-Object System.Text.UTF8Encoding $false))
Write-Host ("отчёт: " + $OutDoc)
Write-Host ""
$rows | Format-Table asset, secid, px, atr, rubPt, @{n='notional';e={N0 $_.notional}}, @{n='go';e={N0 $_.go}}, @{n='stopCore';e={N0 $_.stopCoreRub}}, lotsCore, lotsSetA, @{n='minCapCore';e={N0 $_.minCapCore}} -AutoSize
Write-Host ("ГО worst-case: {0} ₽ / кэп {1} ₽ ({2})" -f (N0 $goWorst), (N0 $goCap), $(if ($goWorst -le $goCap) { 'OK' } else { 'РЕЖЕТСЯ governor-ом' }))
