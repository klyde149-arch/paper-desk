# test_live_rf.ps1 - тест-раннер LIVE-контура Т-Инвестиций (C3b): юнит-тесты конвертеров/сайзинга
# + сценарная матрица state machine / reconcile / governors на mock-транспорте (без сети и токена).
# Запуск: powershell -File tools\test_live_rf.ps1 [-Only converters|sizing|scenarios]
# Каждый сценарий: чистый data-каталог + mock-сценарий + прогон N тиков live_rf_engine с -NowMs + assert'ы.
param(
  [string]$Only = ''   # '' = всё; 'converters' | 'sizing' | 'scenarios' | имя сценария
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

  Check 'OrderKey формат' ((New-TiOrderKey 'i0231' 'entry') -eq 'LRF-i0231-entry')
  Check 'OrderKey <=36 симв' ((New-TiOrderKey 'i999999' 'stopreplace9').Length -le 36)
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
}

# ================= 3. сценарная матрица (движок на mock-транспорте) =================
# заполняется вместе с live_rf_engine.ps1 (см. Invoke-Scenario ниже)
function Test-Scenarios {
  Write-Host "== сценарии state machine (движок + mock) =="
  $runner = Join-Path $PSScriptRoot 'test_live_rf_scenarios.ps1'
  if (Test-Path $runner) { . $runner } else { Write-Host '  (сценарии ещё не подключены)' }
}

if (-not $Only -or $Only -eq 'converters') { Test-Converters }
if (-not $Only -or $Only -eq 'sizing') { Test-Sizing }
if (-not $Only -or $Only -eq 'scenarios') { Test-Scenarios }

Write-Host ""
Write-Host ("итого: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail) { $script:failed | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }; exit 1 }
exit 0
