# test_live_rf.ps1 - тест-раннер LIVE-контура Т-Инвестиций (C3b): юнит-тесты конвертеров/сайзинга
# + сценарная матрица state machine / reconcile / governors на mock-транспорте (без сети и токена).
# Запуск: powershell -File tools\test_live_rf.ps1 [-Only converters|sizing|report|vizdto|risklib|scenarios]
# Сценарии: LRF_ONLY=<regex> - только совпадающие по имени функции; LRF_TEST_SHELL=pwsh (или путь к
# pwsh.exe) - дочерние тики движка в PowerShell 7, как на VPS.
# Каждый сценарий: чистый data-каталог + mock-сценарий + прогон N тиков live_rf_engine с -NowMs + assert'ы.
param(
  [string]$Only = ''   # '' = всё; 'converters' | 'sizing' | 'report' | 'vizdto' | 'risklib' | 'scenarios'
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
  # ConvertTo-TiMs: ISO-строка (PS 5.1) и [datetime] из ConvertFrom-Json pwsh 7 - одно и то же время
  # при любой культуре (до фикса на ru-RU под pwsh 7 операции брокера молча пропускались)
  $msIso = ConvertTo-TiMs '2026-07-15T07:05:30Z'
  Check 'TiMs: ISO Z -> UTC мс' ($msIso -eq ([DateTimeOffset]::new(2026, 7, 15, 7, 5, 30, [TimeSpan]::Zero)).ToUnixTimeMilliseconds())
  Check 'TiMs: [datetime] Utc = та же мс' ((ConvertTo-TiMs ([datetime]::SpecifyKind([datetime]'2026-07-15 07:05:30', 'Utc'))) -eq $msIso)
  Check 'TiMs: [datetime] без пояса трактуется как UTC' ((ConvertTo-TiMs ([datetime]::SpecifyKind([datetime]'2026-07-15 07:05:30', 'Unspecified'))) -eq $msIso)
  Check 'TiMs: JSON-дата в этом PowerShell = та же мс' ((ConvertTo-TiMs ('{"d":"2026-07-15T07:05:30Z"}' | ConvertFrom-Json).d) -eq $msIso)
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

  # направление заявки - только buy|sell. Без защиты вызов ушёл бы в dryrun-транспорт и вернул
  # «успех» (исключения нет -> проверка краснеет): так потерянный stop_replace (side=long/short)
  # превращался у брокера в рыночную продажу всего объёма (исправлено 2026-09-11)
  foreach ($bad in @('long','short','')) {
    $msg = ''; try { Post-TiMarketOrder 'acc' 'uid' $bad 1 'k' | Out-Null } catch { $msg = [string]$_.Exception.Message }
    Check "Direction market '$bad' -> TINVEST_BAD_DIRECTION" ($msg -match '^TINVEST_BAD_DIRECTION')
    $msg = ''; try { Post-TiStopOrder 'acc' 'uid' $bad 1 ([decimal]1) 'stop_loss' | Out-Null } catch { $msg = [string]$_.Exception.Message }
    Check "Direction stop '$bad' -> TINVEST_BAD_DIRECTION" ($msg -match '^TINVEST_BAD_DIRECTION')
  }
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

# ================= 3.5 DTO открытых позиций: две ветки build_vizdata должны совпадать =================
# report/trades.html читает у позиции pnlPctGo (процент на ГО), goRub и brokerPnl. build_vizdata
# собирает этот DTO ДВАЖДЫ: из презентационного снапшота и, когда снапшота нет, напрямую из
# portfolio.json (в live_rf_tick.sh выпечка снапшота падает мягко, одним WARN - фолбэк реально
# достижим). Ветки писались руками и разъехались: в фолбэке этих трёх полей не было вовсе, и
# дашборд в этом режиме терял и процент, и ГО, а в upnl клал брокерское число ПО КОНТРАКТУ под
# тултипом «P&L этой позиции» - двойной счёт закрытых лотов (CRU6 27.08). Тест сверяет наборы
# ключей: любая новая колонка, добавленная в одну ветку и забытая в другой, красит сборку.
function Test-VizDtoMirror {
  Write-Host "== DTO позиций: снапшот против фолбэка (build_vizdata) =="
  $src = Join-Path $PSScriptRoot 'build_vizdata.ps1'
  $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$errs)
  Check 'build_vizdata.ps1 парсится' (0 -eq @($errs).Count)
  # оба DTO опознаём по ключу reconcileSinceTs - он есть только в них
  $all = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
  $dto = @($all | Where-Object { @($_.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text }) -contains 'reconcileSinceTs' })
  Check 'найдены ровно две ветки сборки позиции' ($dto.Count -eq 2)
  if ($dto.Count -ne 2) { return }
  $keys = @($dto | ForEach-Object { ,(@($_.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text }) | Sort-Object) })
  $diff = @(Compare-Object $keys[0] $keys[1] | ForEach-Object { $_.InputObject })
  Check "наборы ключей совпадают$(if ($diff.Count) { ' (разошлись: ' + ($diff -join ', ') + ')' })" ($diff.Count -eq 0)
  foreach ($k in 'pnlPctGo', 'goRub', 'brokerPnl', 'upnl') {
    Check "обе ветки отдают $k" (($keys[0] -contains $k) -and ($keys[1] -contains $k))
  }
}

# ================= 5. риск-политика: чистая библиотека lib_rf_risk.ps1 =================
# Библиотека без сети и состояния, поэтому проверяется напрямую, без движка и мок-транспорта.
function Test-RiskLib {
  Write-Host "== риск-политика (lib_rf_risk) =="
  . (Join-Path $PSScriptRoot 'lib_rf_risk.ps1')

  # --- конфигурация
  $good = [pscustomobject]@{ schema_version = 1; policy_id = 'rf-early-exit-v1'; mode = 'shadow'; apply_to = 'new_entries'
    capital_source = 'broker_verified'
    core = [pscustomobject]@{ stop_cap_pct = 0.02; risk_pct = 0.005 }
    setA = [pscustomobject]@{ stop_cap_pct = $null; risk_pct = 0.005 }
    futures_open_risk_cap_pct = 0.03; fx_same_direction_cap_pct = 0.015; daily_entry_loss_halt_pct = 0.02
    sizing_rule = 'min_original_and_capped_same_budget'; quote_max_age_sec = 60; capital_max_age_sec = 180 }
  $goodJson = $good | ConvertTo-Json -Depth 5
  $r = Resolve-RfRiskPolicy $good
  Check 'policy: пример ТЗ валиден' ($r.ok -and $r.mode -eq 'shadow' -and $r.policy_id -eq 'rf-early-exit-v1')
  Check 'policy: модель расходов по умолчанию с источником' ($r.p.cost.fee_pct_side -eq [decimal]'0.00045' -and [string]$r.p.cost.source)
  Check 'policy: хеш - 64 hex' ($r.hash -match '^[0-9a-f]{64}$')
  $r2 = Resolve-RfRiskPolicy (ConvertFrom-Json $goodJson)   # как из config.json: типы чисел PS 5.1/7 другие
  Check 'policy: хеш стабилен после JSON-круга' ($r2.ok -and $r2.hash -eq $r.hash)
  $pilot = ConvertFrom-Json $goodJson; $pilot.mode = 'pilot'
  Check 'policy: режим не входит в хеш параметров' ((Resolve-RfRiskPolicy $pilot).hash -eq $r.hash)
  $other = ConvertFrom-Json $goodJson; $other.core.stop_cap_pct = 0.025
  Check 'policy: другой параметр - другой хеш' ((Resolve-RfRiskPolicy $other).hash -ne $r.hash)
  Check 'policy: нет блока -> off' ((Resolve-RfRiskPolicy $null).mode -eq 'off')
  Check 'policy: mode off -> off' ((Resolve-RfRiskPolicy (ConvertFrom-Json '{"mode":"off"}')).mode -eq 'off')
  # каждая ошибка обязана давать invalid: движок остановит входы, а НЕ вернётся молча к риску 5%
  $bad = @(
    @{ n = 'неизвестный режим';           f = { param($x) $x.mode = 'pilott' } },
    @{ n = 'версия схемы 2';              f = { param($x) $x.schema_version = 2 } },
    @{ n = 'число строкой';               f = { param($x) $x.core.risk_pct = '0.005' } },
    @{ n = 'risk_pct 0.5 (50%)';          f = { param($x) $x.core.risk_pct = 0.5 } },
    @{ n = 'отрицательный потолок';       f = { param($x) $x.futures_open_risk_cap_pct = -0.03 } },
    @{ n = 'валютный потолок больше общего'; f = { param($x) $x.fx_same_direction_cap_pct = 0.05 } },
    @{ n = 'капитал не брокерский';       f = { param($x) $x.capital_source = 'virtual' } },
    @{ n = 'чужое правило объёма';        f = { param($x) $x.sizing_rule = 'capped_only' } },
    @{ n = 'дробный возраст котировки';   f = { param($x) $x.quote_max_age_sec = 60.5 } },
    @{ n = 'нет блока core';              f = { param($x) [void]$x.PSObject.Properties.Remove('core') } },
    @{ n = 'модель расходов без источника'; f = { param($x) $x | Add-Member -NotePropertyName cost -NotePropertyValue ([pscustomobject]@{ fee_pct_side = 0.0004; stop_slip_pct = 0.0005 }) } }
  )
  foreach ($b in $bad) {
    $x = ConvertFrom-Json $goodJson
    & $b.f $x
    $rb = Resolve-RfRiskPolicy $x
    Check "policy invalid: $($b.n)" (-not $rb.ok -and $rb.mode -eq 'invalid' -and [string]$rb.error)
  }

  # --- капитал
  $c = Get-RfRiskCapital 1600000 1000000 1060000 180
  Check 'capital: свежий снимок' ($c.ok -and $c.rub -eq [decimal]1600000 -and $c.age_sec -eq 60)
  Check 'capital: устаревший снимок (200 с)' (-not (Get-RfRiskCapital 1600000 1000000 1200000 180).ok)
  Check 'capital: ноль' (-not (Get-RfRiskCapital 0 1000000 1000000 180).ok)
  Check 'capital: отрицательный' (-not (Get-RfRiskCapital -5 1000000 1000000 180).ok)
  Check 'capital: не посчитан' (-not (Get-RfRiskCapital $null 1000000 1000000 180).ok)

  # --- стоп
  $e = Get-RfEffectiveStop 'long' 101.63 95.763393 0.02 0.01
  Check 'stop long: предел 2% ближе исходного, округление вверх (99.5974 -> 99.60)' ($e.valid -and $e.capped -and $e.stop -eq [decimal]'99.60')
  $e = Get-RfEffectiveStop 'long' 100 99 0.02 0.01
  Check 'stop long: исходный ближе - остаётся исходный' ($e.valid -and -not $e.capped -and $e.stop -eq [decimal]99)
  $e = Get-RfEffectiveStop 'short' 3.005 3.2 0.02 0.001
  Check 'stop short: предел, округление вниз (3.0651 -> 3.065)' ($e.valid -and $e.capped -and $e.stop -eq [decimal]'3.065')
  $e = Get-RfEffectiveStop 'short' 100 101 0.02 0.01
  Check 'stop short: исходный ближе' ($e.valid -and -not $e.capped -and $e.stop -eq [decimal]101)
  $e = Get-RfEffectiveStop 'long' 100 95.001 $null 0.01
  Check 'stop без предела (setA): округление лонга к входу (95.001 -> 95.01)' ($e.valid -and $e.stop -eq [decimal]'95.01')
  Check 'stop: на входе после округления -> невалиден' (-not (Get-RfEffectiveStop 'long' 1.00 0.999 0.02 0.01).valid)
  Check 'stop: шаг 0 -> невалиден' (-not (Get-RfEffectiveStop 'long' 100 95 0.02 0).valid)
  $threw = $false; try { [void](Get-RfEffectiveStop 'up' 100 95 0.02 0.01) } catch { $threw = $true }
  Check 'stop: неизвестная сторона -> исключение, а не молчаливый шорт' $threw
  # свойство (сетка с фиксированным seed): округление никогда не расширяет стоп и не выводит его за 2%
  $rng = New-Object System.Random 20260911
  $ticks = @([decimal]'0.001', [decimal]'0.01', [decimal]'0.1', [decimal]'1', [decimal]'0.05')
  $bad1 = 0; $n1 = 0
  for ($k = 0; $k -lt 400; $k++) {
    $tick = $ticks[$k % 5]
    $px = [decimal][math]::Round(50 + $rng.NextDouble() * 5000, 3)
    $side = if ($k % 2) { 'long' } else { 'short' }
    $sv = if ($side -eq 'long') { $px * [decimal](1 - 0.005 - $rng.NextDouble() * 0.08) } else { $px * [decimal](1 + 0.005 + $rng.NextDouble() * 0.08) }
    $x = Get-RfEffectiveStop $side $px $sv 0.02 $tick
    if (-not $x.valid) { continue }
    $n1++
    if ($side -eq 'long' -and ($x.stop -lt $x.raw -or $x.stop -lt $px * [decimal]'0.98')) { $bad1++ }
    if ($side -eq 'short' -and ($x.stop -gt $x.raw -or $x.stop -gt $px * [decimal]'1.02')) { $bad1++ }
  }
  Check "stop свойство: $n1 случаев - округление не расширило стоп и не вывело за 2%" ($n1 -gt 300 -and $bad1 -eq 0)

  # --- объём (BR: вход 101.63, 2xATR = 6.176608, 864.73 ₽/пункт, бюджет 0.5% от 1.6 млн = 8000)
  $cost = Get-RfCostPerLot 101.63 864.73 0.00045 0.0005
  Check 'cost: две комиссии + проскальзывание стопа' ([math]::Abs([double]$cost - 101.63 * 864.73 * (2 * 0.00045 + 0.0005)) -lt 0.01)
  Check 'cost: открытая позиция - только выход' ([math]::Abs([double](Get-RfCostPerLot 101.63 864.73 0.00045 0.0005 -ExitOnly) - 101.63 * 864.73 * (0.00045 + 0.0005)) -lt 0.01)
  $sz = Get-RfEntrySize 8000 6.176608 2.0326 864.73 $cost ([ordered]@{})
  Check 'size: q_reference считается от ИСХОДНОГО стопа' ($sz.q_reference -eq [int][math]::Floor(8000 / (6.176608 * 864.73 + [double]$cost)))
  Check 'size: предел не увеличил объём (q_final = q_reference при q_capped больше)' ($sz.q_final -eq $sz.q_reference -and $sz.q_capped -gt $sz.q_reference)
  $sz0 = Get-RfEntrySize 3000 6.176608 2.0326 864.73 $cost ([ordered]@{})
  Check 'size: q_reference=0 -> пропуск, даже если q_capped > 0' ($sz0.q_final -eq 0 -and $sz0.q_capped -gt 0 -and $sz0.reason -eq 'q_reference=0')
  $szc = Get-RfEntrySize 80000 6.176608 2.0326 864.73 $cost ([ordered]@{ maxlev = 20; override = 5; go = 9 })
  Check 'size: прочие кэпы режут объём (override=5)' ($szc.q_final -eq 5 -and $szc.binding -eq 'override')
  Check 'size: расходы съедают бюджет -> 0' ((Get-RfEntrySize 100 1 0.5 1000 150 ([ordered]@{})).q_final -eq 0)
  Check 'size: дорогой одиночный контракт -> 0' ((Get-RfEntrySize 8000 300 300 86.887 100 ([ordered]@{})).q_final -eq 0)
  $grow = 0
  for ($k = 0; $k -lt 300; $k++) {
    $B = [decimal](1000 + $rng.Next(1, 200000)); $dS = [decimal](0.5 + $rng.NextDouble() * 20)
    $rp = [decimal](1 + $rng.NextDouble() * 1000); $c0 = [decimal]($rng.NextDouble() * 50)
    $q1 = (Get-RfEntrySize $B $dS $dS $rp $c0 ([ordered]@{})).q_final
    $q2 = (Get-RfEntrySize $B $dS ($dS * [decimal]'0.3') $rp $c0 ([ordered]@{})).q_final
    if ($q2 -gt $q1) { $grow++ }
  }
  Check 'size свойство: 300 случаев - сужение стопа не увеличило объём' ($grow -eq 0)

  # --- риск позиции
  $pr = Get-RfPositionRisk 'long' 15 101.63 95.763393 102.36 864.73 50
  Check 'risk long: R_entry = q*pv*(entry-stop)' ([math]::Abs([double]$pr.r_entry - 15 * 864.73 * (101.63 - 95.763393)) -lt 0.01)
  Check 'risk long: R_charge = max(R_entry, R_mark) + выход' ($pr.r_mark -gt $pr.r_entry -and [math]::Abs([double]($pr.r_charge - $pr.r_mark) - 750) -lt 0.001)
  $ps = Get-RfPositionRisk 'short' 10 100 102 99 10 0
  Check 'risk short: q*pv*(stop-entry) и отдача от метки' ($ps.r_entry -eq [decimal]200 -and $ps.r_mark -eq [decimal]300)
  $pn = Get-RfPositionRisk 'long' 1 100 95 $null 10 0
  Check 'risk: нет котировки -> метка = вход' ($pn.mark -eq [decimal]100 -and $pn.r_mark -eq $pn.r_entry)
  Check 'risk: рынок за стопом -> mark_beyond_stop' ([bool](Get-RfPositionRisk 'long' 1 100 95 94 10 0).mark_beyond_stop)
  $pp = Get-RfPositionRisk 'long' 1 100 102 110 10 0
  Check 'risk: стоп в плюсе -> R_entry 0, R_mark = отдача прибыли' ($pp.r_entry -eq 0 -and $pp.r_mark -eq [decimal]80)

  # --- открытый риск
  $items = @(
    [pscustomobject]@{ kind = 'card'; id = 'L1'; asset = 'Si'; side = 'long'; r_charge = [decimal]10000; unknown = $false; reason = '' },
    [pscustomobject]@{ kind = 'card'; id = 'L2'; asset = 'CNY'; side = 'long'; r_charge = [decimal]5000; unknown = $false; reason = '' },
    [pscustomobject]@{ kind = 'intent'; id = 'i3'; asset = 'Eu'; side = 'short'; r_charge = [decimal]7000; unknown = $false; reason = '' },
    [pscustomobject]@{ kind = 'card'; id = 'L4'; asset = 'BR'; side = 'long'; r_charge = [decimal]20000; unknown = $false; reason = '' })
  $op = Get-RfOpenRisk $items $null
  Check 'open: сумма по двум рукавам и ожидающим заявкам' ($op.total -eq [decimal]42000)
  Check 'open: валюты лонг = Si+CNY, шорт Eu отдельно (без взаимозачёта)' ($op.fx_long -eq [decimal]15000 -and $op.fx_short -eq [decimal]7000)
  $op2 = Get-RfOpenRisk (@($items) + @([pscustomobject]@{ kind = 'card'; id = 'L5'; asset = 'NG'; side = 'long'; r_charge = $null; unknown = $true; reason = 'карантин' })) $null
  Check 'open: неизвестный риск виден' (@($op2.unknown).Count -eq 1 -and [string]@($op2.unknown)[0] -like '*карантин*')

  # --- дневной P&L бота
  $base = [pscustomobject]@{ vm_by_uid = @{ 'u-br' = [decimal]1000; 'u-ng' = [decimal]-500 }; mom_eq = [decimal]350000; base_ms = 1000; e_base = [decimal]1600000 }
  # BR держим (1000 -> -9000), NG закрыт днём (маржа закрытия -3000), новый CNY (+200), акции -1000, комиссии 300;
  # запись о марже, закрытой ДО базы (u-old), в дневной результат не входит
  $now = [pscustomobject]@{ vm_by_uid = @{ 'u-br' = [decimal]-9000; 'u-cny' = [decimal]200 }
    settle_items = @([pscustomobject]@{ uid = 'u-ng'; rub = [decimal]-3000; ts = 2000 }, [pscustomobject]@{ uid = 'u-old'; rub = [decimal]-99999; ts = 500 })
    mom_eq = [decimal]349000; fees_since_base = [decimal]300 }
  $dp = Get-RfDayPnl $base $now
  Check 'day: фьючерсы = (-9000-1000) + (-3000+500) + 200 = -12300' ($dp.ok -and $dp.fut -eq [decimal]-12300)
  Check 'day: итог = фьючерсы + акции - комиссии = -13600' ($dp.pnl -eq [decimal]-13600 -and $dp.loss -eq [decimal]13600)
  $gone = [pscustomobject]@{ vm_by_uid = @{ 'u-br' = [decimal]-9000 }; settle_items = @(); mom_eq = [decimal]350000; fees_since_base = 0 }
  $dg = Get-RfDayPnl $base $gone
  Check 'day: позиция с базы исчезла без записи о марже -> не проверено' (-not $dg.ok -and $dg.reason -like '*u-ng*')
  Check 'day: нет базы -> не проверено' (-not (Get-RfDayPnl $null $now).ok)
  $flat = [pscustomobject]@{ vm_by_uid = @{ 'u-br' = [decimal]1000; 'u-ng' = [decimal]-500 }; settle_items = @(); mom_eq = [decimal]350000; fees_since_base = 0 }
  Check 'day: без движения позиций результат 0 (рубли и бумаги пользователя в формулу не входят)' ((Get-RfDayPnl $base $flat).pnl -eq 0)
  $baseR = [pscustomobject]@{ vm_by_uid = @{ 'u-q6' = [decimal]2000 }; mom_eq = 0; base_ms = 1000; e_base = [decimal]1000000 }
  $nowR = [pscustomobject]@{ vm_by_uid = @{ 'u-u6' = [decimal]-100 }; settle_items = @([pscustomobject]@{ uid = 'u-q6'; rub = [decimal]2500; ts = 1500 }); mom_eq = 0; fees_since_base = [decimal]40 }
  Check 'day: ролл - старый контракт по марже закрытия, новый с нуля (500-100-40)' ((Get-RfDayPnl $baseR $nowR).pnl -eq [decimal]360)
  $seq = [pscustomobject]@{ vm_by_uid = @{}; settle_items = @(
      [pscustomobject]@{ uid = 'u-br'; rub = [decimal]-20000; ts = 1200 }, [pscustomobject]@{ uid = 'u-ng'; rub = [decimal]-15000; ts = 1300 }, [pscustomobject]@{ uid = 'u-si'; rub = [decimal]-4000; ts = 1400 })
    mom_eq = [decimal]350000; fees_since_base = 0 }
  Check 'day: последовательные стопы копятся (перевход не обнуляет)' ((Get-RfDayPnl $base $seq).pnl -eq [decimal](-21000 - 14500 - 4000))

  # --- решение по входу (капитал 1.6 млн: общий потолок 3% = 48 000, валютный 1.5% = 24 000, дневной 2% = 32 000)
  $P = $r.p
  $cap = [pscustomobject]@{ ok = $true; rub = [decimal]1600000; reason = '' }
  $dayOk = [pscustomobject]@{ ok = $true; loss = [decimal]0; e_base = [decimal]1600000; reason = '' }
  $empty = Get-RfOpenRisk @() $null
  $new = [pscustomobject]@{ sleeve = 'core'; asset = 'BR'; side = 'long'; q_final = 5; q_reference = 5; charge_per_lot = [decimal]5000 }
  $t = Test-RfEntryRisk $P $cap $empty $new $dayOk
  Check 'entry: разрешён в пределах бюджетов' ($t.allow -and $t.q_final -eq 5 -and $t.budgets.total_cap_rub -eq [decimal]48000 -and $t.budgets.trade_rub -eq [decimal]8000)
  $busy = Get-RfOpenRisk @([pscustomobject]@{ kind = 'card'; id = 'L1'; asset = 'NG'; side = 'long'; r_charge = [decimal]30000; unknown = $false; reason = '' }) $null
  $t2 = Test-RfEntryRisk $P $cap $busy $new $dayOk
  Check 'entry: общий бюджет режет объём 5 -> 3' ($t2.allow -and $t2.q_final -eq 3 -and $t2.binding -eq 'общий бюджет')
  $over = Get-RfOpenRisk @([pscustomobject]@{ kind = 'card'; id = 'L1'; asset = 'BR'; side = 'long'; r_charge = [decimal]134000; unknown = $false; reason = '' }) $null
  $t3 = Test-RfEntryRisk $P $cap $over $new $dayOk
  Check 'entry: старые позиции выше потолка -> вход отменён (старые не закрываются)' (-not $t3.allow -and $t3.kind -eq 'hard' -and ($t3.reasons -join ' ') -like '*бюджет исчерпан*')
  $fxo = Get-RfOpenRisk @([pscustomobject]@{ kind = 'card'; id = 'L1'; asset = 'Si'; side = 'long'; r_charge = [decimal]20000; unknown = $false; reason = '' }) $null
  $cnyL = [pscustomobject]@{ sleeve = 'core'; asset = 'CNY'; side = 'long'; q_final = 2; q_reference = 2; charge_per_lot = [decimal]5000 }
  $euS = [pscustomobject]@{ sleeve = 'core'; asset = 'Eu'; side = 'short'; q_final = 2; q_reference = 2; charge_per_lot = [decimal]5000 }
  Check 'entry: валютная группа (лонг рубль-слабость) исчерпана' (-not (Test-RfEntryRisk $P $cap $fxo $cnyL $dayOk).allow)
  Check 'entry: шорт Eu - другая группа, лонг Si не зачитывается' ((Test-RfEntryRisk $P $cap $fxo $euS $dayOk).allow)
  $t5 = Test-RfEntryRisk $P $cap $op2 $new $dayOk
  Check 'entry: неизвестный риск -> ждать' (-not $t5.allow -and $t5.kind -eq 'wait')
  $t6 = Test-RfEntryRisk $P $cap $empty $new ([pscustomobject]@{ ok = $true; loss = [decimal]32000; e_base = [decimal]1600000; reason = '' })
  Check 'entry: дневной предел 2% -> вход отменён' (-not $t6.allow -and $t6.kind -eq 'hard' -and ($t6.reasons -join ' ') -like '*дневной предел*')
  Check 'entry: дневной результат не проверен -> ждать' ((Test-RfEntryRisk $P $cap $empty $new ([pscustomobject]@{ ok = $false; reason = 'нет базы' })).kind -eq 'wait')
  Check 'entry: капитал устарел -> ждать' ((Test-RfEntryRisk $P ([pscustomobject]@{ ok = $false; reason = 'устарел' }) $empty $new $dayOk).kind -eq 'wait')
  Check 'entry: q_reference=0 -> вход отменён' ((Test-RfEntryRisk $P $cap $empty ([pscustomobject]@{ sleeve = 'core'; asset = 'BR'; side = 'long'; q_final = 0; q_reference = 0; charge_per_lot = [decimal]5000 }) $dayOk).kind -eq 'hard')

  # --- виртуальная ветка (часовой бар)
  $vb = Test-RfVirtualBar 'long' 99.6 ([pscustomobject]@{ o = 100; h = 101; l = 99.5; c = 100 }) 0.0005
  Check 'virtual: касание стопа - исполнение по стопу' ($vb.hit -and -not $vb.gap -and $vb.fill -eq ([decimal]'99.6' * [decimal]'0.9995'))
  $vg = Test-RfVirtualBar 'long' 99.6 ([pscustomobject]@{ o = 98; h = 99; l = 97; c = 98 }) 0.0005
  Check 'virtual: гэп - исполнение по худшему (открытие)' ($vg.hit -and $vg.gap -and $vg.fill -eq ([decimal]98 * [decimal]'0.9995'))
  Check 'virtual: шорт без касания' (-not (Test-RfVirtualBar 'short' 102 ([pscustomobject]@{ o = 100; h = 101; l = 99; c = 100 }) 0).hit)
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
if (-not $Only -or $Only -eq 'vizdto') { Test-VizDtoMirror }
if (-not $Only -or $Only -eq 'risklib') { Test-RiskLib }
if (-not $Only -or $Only -eq 'scenarios') { Test-Scenarios }

Write-Host ""
Write-Host ("итого: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail) { $script:failed | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }; exit 1 }
exit 0
