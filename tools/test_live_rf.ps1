# test_live_rf.ps1 - тест-раннер LIVE-контура Т-Инвестиций (C3b): юнит-тесты конвертеров/сайзинга
# + сценарная матрица state machine / reconcile / governors на mock-транспорте (без сети и токена).
# Запуск: powershell -File tools\test_live_rf.ps1 [-Only converters|sizing|report|scenarios]
# Каждый сценарий: чистый data-каталог + mock-сценарий + прогон N тиков live_rf_engine с -NowMs + assert'ы.
param(
  [string]$Only = ''   # '' = всё; 'converters' | 'sizing' | 'report' | 'scenarios' | имя сценария
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'lib_engine.ps1')
. (Join-Path $PSScriptRoot 'lib_tinvest.ps1')

$script:pass = 0; $script:fail = 0; $script:failed = @()
function Check([string]$Name, [bool]$Cond) {
  if ($Cond) { $script:pass++; Write-Host ("  ok   " + $Name) }
  else { $script:fail++; $script:failed += $Name; Write-Host ("  FAIL " + $Name) -ForegroundColor Red }
}

# ================= 1. конвертеры Quotation/MoneyValue и пункты->рубли =================
function Test-Converters {
  Write-Host "== конвертеры =="
  Check 'Q2D 82.41' ((Q2D ([pscustomobject]@{units='82';nano=410000000})) -eq [decimal]82.41)
  Check 'Q2D -0.5 (units=0, nano<0)' ((Q2D ([pscustomobject]@{units='0';nano=-500000000})) -eq [decimal]-0.5)
  Check 'Q2D -1.25' ((Q2D ([pscustomobject]@{units='-1';nano=-250000000})) -eq [decimal]-1.25)
  Check 'Q2D 1e-9' ((Q2D ([pscustomobject]@{units='0';nano=1})) -eq [decimal]0.000000001)
  Check 'Q2D null->0' ((Q2D $null) -eq [decimal]0)
  # ConvertTo-TiIso: pwsh 7 грузит полный ISO из JSON как [datetime] - каст в [string] давал
  # культурный формат и API 400 (инцидент 2026-07-20); строки проходят как есть
  Check 'TiIso: [datetime] -> ISO Z' ((ConvertTo-TiIso ([datetime]::SpecifyKind([datetime]'2026-07-20 02:59:33', 'Utc'))) -eq '2026-07-20T02:59:33Z')
  Check 'TiIso: строка как есть' ((ConvertTo-TiIso '2026-07-20T02:59:33Z') -eq '2026-07-20T02:59:33Z')
  foreach ($v in @([decimal]85.55, [decimal]-1.25, [decimal]0.001, [decimal]215650, [decimal]-0.5, [decimal]12.336)) {
    $q = D2Q $v; $back = Q2D ([pscustomobject]$q)
    Check "D2Q roundtrip $v" ($back -eq $v)
  }
  $q = D2Q ([decimal]-1.25)
  Check 'D2Q знак: units=-1, nano=-250000000' ($q.units -eq '-1' -and $q.nano -eq -250000000)
  $q = D2Q ([decimal]215650)
  Check 'D2Q int64 как строка' ($q.units -is [string] -and $q.units -eq '215650')

  # параметры реальных контрактов (снимок ISS 2026-07-15)
  $br = [pscustomobject]@{ ticker='BRQ6'; min_price_increment=[pscustomobject]@{units='0';nano=10000000}; min_price_increment_amount=[pscustomobject]@{units='7';nano=749120000} }
  $rts = [pscustomobject]@{ ticker='RIU6'; min_price_increment=[pscustomobject]@{units='10';nano=0}; min_price_increment_amount=[pscustomobject]@{units='15';nano=498240000} }
  $si = [pscustomobject]@{ ticker='SiU6'; min_price_increment=[pscustomobject]@{units='1';nano=0}; min_price_increment_amount=[pscustomobject]@{units='1';nano=0} }
  $cny = [pscustomobject]@{ ticker='CRU6'; min_price_increment=[pscustomobject]@{units='0';nano=1000000}; min_price_increment_amount=[pscustomobject]@{units='1';nano=0} }
  $gold = [pscustomobject]@{ ticker='GDU6'; min_price_increment=[pscustomobject]@{units='0';nano=100000000}; min_price_increment_amount=[pscustomobject]@{units='7';nano=749120000} }
  Check 'RubPerPoint BR 774.912'   ([math]::Abs((Get-RubPerPoint $br)  - [decimal]774.912) -lt 0.0001)
  Check 'RubPerPoint RTS 1.549824' ([math]::Abs((Get-RubPerPoint $rts) - [decimal]1.549824) -lt 0.000001)
  Check 'RubPerPoint Si 1'         ((Get-RubPerPoint $si) -eq [decimal]1)
  Check 'RubPerPoint CNY 1000'     ((Get-RubPerPoint $cny) -eq [decimal]1000)
  Check 'RubPerPoint GOLD 77.4912' ([math]::Abs((Get-RubPerPoint $gold) - [decimal]77.4912) -lt 0.0001)
  Check 'PtsToRub BR 6.4776пт=5019.57р' ([math]::Abs((Convert-PtsToRub ([decimal]6.4776) $br) - [decimal]5019.57) -lt 0.01)
  Check 'RoundInc BR 85.5549->85.55' ((Round-ToIncrement ([decimal]85.5549) $br) -eq [decimal]85.55)
  Check 'RoundInc RTS 85794->85790'  ((Round-ToIncrement ([decimal]85794) $rts) -eq [decimal]85790)
  Check 'RoundInc CNY 11.6864->11.686' ((Round-ToIncrement ([decimal]11.6864) $cny) -eq [decimal]11.686)

  $k1 = New-TiOrderKey 'i0231' 'entry'; $k2 = New-TiOrderKey 'i0231' 'entry'; $k3 = New-TiOrderKey 'i0231' 'fill1'
  $guidOk = $false; try { [void][guid]::Parse($k1); $guidOk = $true } catch {}
  Check 'OrderKey: валидный UUID (требование API)' $guidOk
  Check 'OrderKey: детерминированный (тот же intent -> тот же UUID)' ($k1 -eq $k2)
  Check 'OrderKey: разные ноги -> разные UUID' ($k1 -ne $k3)
  Check 'phase FILL'    ((ConvertTo-TiOrderPhase 'EXECUTION_REPORT_STATUS_FILL') -eq 'FILLED')
  Check 'phase PARTIAL' ((ConvertTo-TiOrderPhase 'EXECUTION_REPORT_STATUS_PARTIALLYFILL') -eq 'PARTIAL')
  Check 'phase REJECTED'((ConvertTo-TiOrderPhase 'EXECUTION_REPORT_STATUS_REJECTED') -eq 'REJECTED')
  Check 'phase NEW'     ((ConvertTo-TiOrderPhase 'EXECUTION_REPORT_STATUS_NEW') -eq 'POSTED')
  Check 'phase CANCELLED' ((ConvertTo-TiOrderPhase 'EXECUTION_REPORT_STATUS_CANCELLED') -eq 'CANCELLED')

  # Assert-Tradeable
  $good = [pscustomobject]@{ ticker='NGQ6'; class_code='SPBFUT'; api_trade_available_flag=$true }
  $badf = [pscustomobject]@{ ticker='NGQ6'; class_code='SPBFUT'; api_trade_available_flag=$false }
  $badc = [pscustomobject]@{ ticker='NGQ6'; class_code='FORTS';  api_trade_available_flag=$true }
  Check 'Tradeable ok' (Assert-Tradeable $good 'fut')
  $threw = $false; try { Assert-Tradeable $badf 'fut' | Out-Null } catch { $threw = $true }
  Check 'Tradeable flag=false -> throw' $threw
  $threw = $false; try { Assert-Tradeable $badc 'fut' | Out-Null } catch { $threw = $true }
  Check 'Tradeable class!=SPBFUT -> throw' $threw
}

# ================= 2. сайзинг: пункты->рубли, целые лоты, кэпы =================
function Test-Sizing {
  Write-Host "== сайзинг =="
  . (Join-Path $PSScriptRoot 'lib_rf_signals.ps1')
  # табличные кейсы: riskRub / (stopDist_pts * rubPt) с floor + кэп MAXLEV и ГО
  # Get-LiveFutLots определён в live_rf_engine.ps1 (дот-сорсится ниже в сценарной секции através движка);
  # здесь проверяем формулу напрямую - эталонные значения посчитаны вручную.
  $cases = @(
    # asset, riskRub, stopPts, rubPt, price, sleeveEq, expLots
    @{ n='BR core 35000/(6.4776*774.912)=6';   risk=35000; stop=6.4776;   rubPt=774.912;  px=85.82;  eq=700000; exp=6 }
    @{ n='NG core 35000/(0.229*7749.12)=19';   risk=35000; stop=0.229;    rubPt=7749.12;  px=2.928;  eq=700000; exp=19 }
    @{ n='GOLD core 35000/(179.86*77.49)=2';   risk=35000; stop=179.8572; rubPt=77.4912;  px=4072.8; eq=700000; exp=2 }
    @{ n='CNY core 35000/(0.5228*1000)=66';    risk=35000; stop=0.5228;   rubPt=1000;     px=11.686; eq=700000; exp=66 }
    @{ n='MIX setA 14000/(7905.36*1)=1';       risk=14000; stop=7905.3571;rubPt=1;        px=215650; eq=700000; exp=1 }
    @{ n='qty0: слишком дорогой стоп -> 0';    risk=14000; stop=179.8572; rubPt=774.912;  px=4072.8; eq=700000; exp=0 }
    @{ n='кэп MAXLEV: дешёвый стоп CNY';       risk=35000; stop=0.05;     rubPt=1000;     px=11.686; eq=700000; exp=179 }
    # 35000/(0.05*1000)=700 лотов, но нотионал 700*11686=8.18M > 3*700k -> floor(2.1M/11686)=179
  )
  foreach ($c in $cases) {
    $stopRub = [decimal]$c.stop * [decimal]$c.rubPt
    $lots = [math]::Floor([decimal]$c.risk / $stopRub)
    $notionalPerLot = [decimal]$c.px * [decimal]$c.rubPt
    $levCap = [math]::Floor(($MAXLEV * [decimal]$c.eq) / $notionalPerLot)
    if ($lots -gt $levCap) { $lots = $levCap }
    Check $c.n ($lots -eq $c.exp)
  }

  # Get-TopNSum (lib_engine.ps1): худший случай ГО в Invoke-DailyReadinessCheck - сумма топ-N
  # самых дорогих по марже позиций, как если бы все слоты рукава заполнились одновременно.
  $rows = @(
    [pscustomobject]@{ asset='A'; v=10 }, [pscustomobject]@{ asset='B'; v=30 }
    [pscustomobject]@{ asset='C'; v=20 }, [pscustomobject]@{ asset='D'; v=5 } )
  Check 'TopNSum top2 из 4х (30+20)' ((Get-TopNSum $rows 'v' 2) -eq 50)
  Check 'TopNSum N больше числа строк - суммирует все' ((Get-TopNSum $rows 'v' 10) -eq 65)
  Check 'TopNSum N=0 -> 0' ((Get-TopNSum $rows 'v' 0) -eq 0)
  Check 'TopNSum пустой список -> 0' ((Get-TopNSum @() 'v' 3) -eq 0)
  $rowsTie = @([pscustomobject]@{ v=10 }, [pscustomobject]@{ v=10 }, [pscustomobject]@{ v=10 })
  Check 'TopNSum одинаковые значения (топ-2 из трёх десяток)' ((Get-TopNSum $rowsTie 'v' 2) -eq 20)
  # тот же MAXCONC (3), что реально использует Invoke-DailyReadinessCheck для рукавов core/setA
  $goCore = @(
    [pscustomobject]@{ asset='BR'; goCore=12000 }, [pscustomobject]@{ asset='NG'; goCore=45000 }
    [pscustomobject]@{ asset='GOLD'; goCore=38000 }, [pscustomobject]@{ asset='Si'; goCore=9000 }
    [pscustomobject]@{ asset='CNY'; goCore=41000 } )
  Check 'TopNSum худший случай core (MAXCONC=3): 45000+41000+38000=124000' ((Get-TopNSum $goCore 'goCore' $MAXCONC) -eq 124000)
}

# ================= 3. отчёт: владелец vs клиент =================
function Test-Report {
  Write-Host "== отчёт: два потока (владелец / клиент) =="

  # Get-ClientLines (lib_engine.ps1): клиентская версия вечернего отчёта - тот же список строк
  # за вычетом служебных, помеченных по индексу. Владельцу уходит полный текст.
  $L = New-Object System.Collections.Generic.List[string]
  $opsIdx = New-Object System.Collections.Generic.HashSet[int]
  $L.Add('Капитал бота: 1 566 303 ₽')
  $L.Add('')                                   # разделитель: НЕ служебная строка, должен выжить
  $L.Add('Открытые позиции: 1')
  $L.Add('Гарантийное обеспечение (ГО): занято 183 543 ₽ из 1 512 278 ₽')
  $L.Add('Суточная проверка готовности: худший случай ГО 1 518 814 ₽ превышает кэп 1 139 522 ₽.')
  [void]$opsIdx.Add($L.Count - 1)
  $L.Add('Внимание, расхождения с брокером: D2/D4/D5/D6 = 0/1/0/3')
  [void]$opsIdx.Add($L.Count - 1)
  $L.Add('Входы разрешены, торговля идёт штатно.')

  $txt = ($L -join "`n")
  $txtClient = ((Get-ClientLines $L $opsIdx) -join "`n")

  Check 'клиент: без строки суточной проверки' (-not $txtClient.Contains('Суточная проверка готовности'))
  Check 'клиент: без расхождений D2/D4/D5/D6' (-not $txtClient.Contains('D2/D4/D5/D6'))
  Check 'клиент: капитал на месте' ($txtClient.Contains('Капитал бота: 1 566 303 ₽'))
  Check 'клиент: ГО занято/бюджет на месте' ($txtClient.Contains('занято 183 543 ₽ из 1 512 278 ₽'))
  Check 'клиент: статус входов на месте' ($txtClient.Contains('Входы разрешены'))
  Check 'клиент: пустой разделитель не съеден' (($txtClient -split "`n").Count -eq $L.Count - 2)
  Check 'владелец: суточная проверка на месте' ($txt.Contains('Суточная проверка готовности'))
  Check 'владелец: расхождения на месте' ($txt.Contains('D2/D4/D5/D6'))
  Check 'владелец: текст не урезан' (($txt -split "`n").Count -eq $L.Count)

  # вырожденные входы
  Check 'Get-ClientLines: пустой opsIdx -> текст как есть' (
    ((Get-ClientLines $L (New-Object System.Collections.Generic.HashSet[int])) -join "`n") -eq $txt)
  Check 'Get-ClientLines: $null opsIdx -> текст как есть' (((Get-ClientLines $L $null) -join "`n") -eq $txt)
  # вызывать ТАК ЖЕ, как движок: с присваиванием. Get-ClientLines возвращает , $arr - унарная
  # запятая держит форму массива для 0/1 строки (как ToArr), но инлайновый @(Get-ClientLines ...)
  # увидел бы из-за неё один элемент - пустой массив, а не пустой результат.
  $emptyRes = Get-ClientLines (New-Object System.Collections.Generic.List[string]) $opsIdx
  Check 'Get-ClientLines: пустой список -> пусто' (@($emptyRes).Count -eq 0)
  $nullRes = Get-ClientLines $null $opsIdx
  Check 'Get-ClientLines: $null список -> пусто (не одна пустая строка)' (@($nullRes).Count -eq 0)
  $oneRes = Get-ClientLines @('одна строка') $null
  Check 'Get-ClientLines: одна строка остаётся массивом' ($oneRes -is [array] -and @($oneRes).Count -eq 1)

  # формулировка суточной проверки (Invoke-DailyReadinessCheck -> Invoke-DailyReport): перечисляем
  # ТОЛЬКО реально провалившиеся проверки. Раньше при чистом брокере в текст лез «недоступно у
  # брокера: 0» - нулевой счётчик рядом со словом «проблема» читался как отдельная авария.
  function Build-ReadinessWhy($Rdy, [int]$MaxConc) {
    $why = New-Object System.Collections.Generic.List[string]
    if (@($Rdy.failed).Count -gt 0) { $why.Add("недоступны у брокера: $(@($Rdy.failed).Count) из $($Rdy.total_n) (см. алерт)") }
    if (-not [bool]$Rdy.fits) { $why.Add("худший случай ГО превышает кэп ($MaxConc+$MaxConc слота)") }
    return ($why -join '; ')
  }
  # боевой снимок 2026-08-24: брокер чист, не сходится только ёмкость ГО
  $rdyGo = [pscustomobject]@{ failed = @(); total_n = 12; fits = $false }
  $whyGo = Build-ReadinessWhy $rdyGo 3
  Check 'причины: только ГО, без «недоступно: 0»' (-not $whyGo.Contains('недоступн'))
  Check 'причины: ГО названо' ($whyGo.Contains('худший случай ГО'))
  # брокер отвалился, ГО в норме
  $rdyBr = [pscustomobject]@{ failed = @('NG (NGQ6): 404'); total_n = 12; fits = $true }
  $whyBr = Build-ReadinessWhy $rdyBr 3
  Check 'причины: только брокер' ($whyBr.Contains('недоступны у брокера: 1 из 12') -and -not $whyBr.Contains('худший случай'))
  # обе разом
  $rdyBoth = [pscustomobject]@{ failed = @('NG (NGQ6): 404', 'BR (BRQ6): 404'); total_n = 12; fits = $false }
  $whyBoth = Build-ReadinessWhy $rdyBoth 3
  Check 'причины: обе через «; »' ($whyBoth.Contains('недоступны у брокера: 2 из 12 (см. алерт); худший случай ГО'))
}

# ================= 4. сценарная матрица (движок на mock-транспорте) =================
# заполняется вместе с live_rf_engine.ps1 (см. Invoke-Scenario ниже)
function Test-Scenarios {
  Write-Host "== сценарии state machine (движок + mock) =="
  $runner = Join-Path $PSScriptRoot 'test_live_rf_scenarios.ps1'
  if (Test-Path $runner) { . $runner } else { Write-Host '  (сценарии ещё не подключены)' }
}

if (-not $Only -or $Only -eq 'converters') { Test-Converters }
if (-not $Only -or $Only -eq 'sizing') { Test-Sizing }
if (-not $Only -or $Only -eq 'report') { Test-Report }
if (-not $Only -or $Only -eq 'scenarios') { Test-Scenarios }

Write-Host ""
Write-Host ("итого: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail) { $script:failed | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }; exit 1 }
exit 0
