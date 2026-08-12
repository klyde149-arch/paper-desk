# tinvest_universe_gate.ps1 - Этап 0 расширения универсума 2026-08: гейт торгуемости у брокера.
# ТОЛЬКО ЧТЕНИЕ: FutureBy / GetFuturesMargin. Ни одного мутирующего вызова, торговлю не трогает.
#
# Зачем отдельный скрипт, а не tinvest_selftest.ps1: тот ходит по каноническому $ASSETS из
# lib_rf_signals.ps1, а кандидаты попадут в канон только после того, как пройдут бэктесты.
# Здесь список задаётся явно параметром.
#
# ЗАПУСКАТЬ НА VPS. С машины разработчика хост T-Invest недоступен (Russian CA ->
# "Could not establish trust relationship"), падает даже контрольный BRU6 - это не про инструмент.
#   pwsh -File tools/tinvest_universe_gate.ps1
#   pwsh -File tools/tinvest_universe_gate.ps1 -Assets Eu,ED -IncludeNext
#
# Инструмент проходит гейт, когда api_trade_available_flag / buy / sell = true и ₽/пункт выводится.
# for_qual_investor_flag не роняет гейт сам по себе, но выносится в итог отдельной строкой:
# без квал-статуса такой инструмент в реал не пойдёт (docs/strategy/live_tinvest_design.md, риск #269).
param(
  [string[]]$Assets = @('Eu','ED','PLT','PLD','UCNY','COCOA','COFFEE','COPPER'),
  [string[]]$Control = @('BR'),          # контроль: заведомо торгуемый инструмент, ловит сетевые/токенные проблемы
  [string]$Root = '',
  [switch]$IncludeNext,                  # проверять и следующий контракт после фронта (нужно для роллов)
  [switch]$Sandbox
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'lib_engine.ps1')
. (Join-Path $PSScriptRoot 'lib_tinvest.ps1')

$mode = if ($Sandbox) { 'sandbox' } else { 'prod' }
# DataDir пустой намеренно: гейт не пишет НИЧЕГО (ни лога задержек, ни dryrun-лога).
# Иначе запуск от root создал бы файлы с чужим владельцем, и следующий тик от trader
# не смог бы в них писать - ровно тот класс поломок, что уронил бота на 27 часов в августе.
Initialize-TInvest '' $mode
$all = @($Control) + @($Assets)
Write-Host "== гейт торгуемости (mode=$mode, host=$($script:TI.base)) =="
Write-Host ("активы: {0}   [контроль: {1}]" -f ($Assets -join ','), ($Control -join ','))
if (-not $script:TI.token) { throw 'TINVEST_TOKEN не задан - гейт не может отработать' }

# ---- спецификации из ISS: перекрёстная сверка ₽/пункт (боевой нюанс №1 - цены в ПУНКТАХ) ----
$issSpec = @{}
try {
  $r = Invoke-Iss 'https://iss.moex.com/iss/engines/futures/markets/forts/securities.json?iss.only=securities&securities.columns=SECID,MINSTEP,STEPPRICE,INITIALMARGIN'
  foreach ($row in @($r.securities.data)) {
    $ms = [double]$row[1]; $sp = [double]$row[2]
    if ($ms -gt 0) { $issSpec[[string]$row[0]] = @{ rubPt = $sp / $ms; go = [double]$row[3] } }
  }
} catch { Write-Warning "ISS-спецификации недоступны, сверка ₽/пункт пропущена: $($_.Exception.Message)" }

$fronts = Get-FutFronts $all
$take = if ($IncludeNext) { 2 } else { 1 }
$results = New-Object System.Collections.Generic.List[object]

foreach ($a in $all) {
  if (-not $fronts.ContainsKey($a) -or @($fronts[$a]).Count -eq 0) {
    Write-Warning "$a : на FORTS нет живого контракта - проверьте код актива (ASSETCODE)"
    $results.Add([pscustomobject]@{ asset=$a; secid=''; verdict='НЕТ ФРОНТА'; qual=$null; note='ISS не отдал контракт' })
    continue
  }
  foreach ($c in @($fronts[$a] | Select-Object -First $take)) {
    try {
      $i = Get-TiInstrument $c.secid 'fut'
      $api  = Get-TiField $i 'api_trade_available_flag'
      $buy  = Get-TiField $i 'buy_available_flag'
      $sell = Get-TiField $i 'sell_available_flag'
      $qual = Get-TiField $i 'for_qual_investor_flag'
      $cls  = Get-TiField $i 'class_code'
      $inc  = Q2D (Get-TiField $i 'min_price_increment')

      # ₽/пункт: min_price_increment_amount живёт в GetFuturesMargin, не в FutureBy
      $mg = Get-TiFuturesMargin ([string]$i.uid)
      $amt = Q2D (Get-TiField $mg 'min_price_increment_amount')
      $goB = (M2D (Get-TiField $mg 'initial_margin_on_buy')).value
      $goS = (M2D (Get-TiField $mg 'initial_margin_on_sell')).value
      $rubPt = if ($inc -gt 0 -and $amt -gt 0) { $amt / $inc } else { 0 }

      $spec = $issSpec[[string]$c.secid]
      $cross = 'нет ISS'
      if ($null -ne $spec -and $rubPt -gt 0) {
        $d = [math]::Abs($rubPt - $spec.rubPt) / $spec.rubPt
        $cross = if ($d -lt 0.01) { 'ok' } else { ('РАСХОЖДЕНИЕ ISS={0}' -f [math]::Round($spec.rubPt, 4)) }
      }

      $ok = ($api -eq $true) -and ($buy -eq $true) -and ($sell -eq $true) -and ($rubPt -gt 0) -and ($cls -eq 'SPBFUT')
      $verdict = if ($ok) { 'PASS' } else { 'FAIL' }
      $results.Add([pscustomobject]@{ asset=$a; secid=[string]$c.secid; verdict=$verdict; qual=$qual
                                      note=$(if ($ok) { $cross } else { "api=$api buy=$buy sell=$sell class=$cls" }) })

      Write-Host ("  {0,-7} {1,-6} {2,-4} api={3,-5} buy={4,-5} sell={5,-5} qual={6,-5} lot={7,-3} шаг={8} ₽/пт={9,-10} ГО={10}/{11} [{12}]" -f `
        $a, $c.secid, $verdict, $api, $buy, $sell, $qual, $i.lot, $inc,
        $(if ($rubPt -gt 0) { [math]::Round($rubPt, 4) } else { '?' }), $goB, $goS, $cross)
    } catch {
      Write-Warning "  $a $($c.secid): $($_.Exception.Message)"
      $results.Add([pscustomobject]@{ asset=$a; secid=[string]$c.secid; verdict='ОШИБКА'; qual=$null; note=$_.Exception.Message })
    }
  }
}

# ---- итог ----
Write-Host "`n== итог =="
$ctrl = @($results | Where-Object { $Control -contains $_.asset })
if (@($ctrl | Where-Object { $_.verdict -ne 'PASS' }).Count -gt 0) {
  Write-Warning 'КОНТРОЛЬНЫЙ инструмент не прошёл гейт - проблема в сети/токене, а не в новых активах. Результатам ниже верить нельзя.'
}
$cand = @($results | Where-Object { $Assets -contains $_.asset })
$pass = @($cand | Where-Object { $_.verdict -eq 'PASS' })
$fail = @($cand | Where-Object { $_.verdict -ne 'PASS' })
$qualOnly = @($pass | Where-Object { $_.qual -eq $true })

Write-Host ("прошли:     {0}" -f $(if (@($pass).Count) { (@($pass.asset | Sort-Object -Unique) -join ', ') } else { '(нет)' }))
Write-Host ("не прошли:  {0}" -f $(if (@($fail).Count) { (@($fail | ForEach-Object { "$($_.asset) ($($_.note))" }) -join '; ') } else { '(нет)' }))
if (@($qualOnly).Count) {
  Write-Warning ("требуют КВАЛ-СТАТУСА: {0} - без него в реал не идут" -f (@($qualOnly.asset | Sort-Object -Unique) -join ', '))
}
Write-Host "`nРезультат внести в docs/backtests/universe_expansion_2026-08.md. Не прошедшие гейт активы в бэктест не берём."
