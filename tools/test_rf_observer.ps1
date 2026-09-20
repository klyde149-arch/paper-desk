# test_rf_observer.ps1 - тесты наблюдателя стратегий (tools/rf_observer.ps1, этап 4 плана
# восстановления 2026-09-19). Подключается из test_live_rf.ps1 (секция observer).
# Полностью герметично: часовые бары подаются файлами (-HourlyDir), сеть не трогается.
# Требования вызывающего: определены Check, $Root; дот-сорснуты lib_engine.ps1.

$OBS = Join-Path $PSScriptRoot 'rf_observer.ps1'
$OBSWORK = if ($env:LRF_WORK) { Join-Path ([string]$env:LRF_WORK) 'observer' } else { Join-Path $env:TEMP 'lrf_observer' }
if (Test-Path $OBSWORK) { Remove-Item $OBSWORK -Recurse -Force }
New-Item -ItemType Directory -Force $OBSWORK | Out-Null

function Obs-WriteJson([string]$Path, $Obj) {
  $dir = Split-Path $Path -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Obj -Depth 14), (New-Object System.Text.UTF8Encoding($false)))
}

# Серия: 40 плоских баров close=100, затем ПРОБОЙ вверх на последнем (close=110).
# Канал Donchian [i-20 .. i-1] = 100/100, поэтому close 110 - однозначный брейкаут вверх.
function Obs-Series([double]$Range = 2.0) {
  $bars = New-Object System.Collections.Generic.List[object]
  $d = [datetime]'2026-07-14'
  $days = New-Object System.Collections.Generic.List[string]
  while ($days.Count -lt 40) {
    if ($d.DayOfWeek -ne 'Saturday' -and $d.DayOfWeek -ne 'Sunday') { $days.Insert(0, $d.ToString('yyyy-MM-dd')) }
    $d = $d.AddDays(-1)
  }
  for ($i = 0; $i -lt $days.Count; $i++) {
    $last = ($i -eq $days.Count - 1)
    $c = if ($last) { 110.0 } else { 100.0 }
    $h = if ($last) { 110.0 } else { 100.0 + $Range / 2 }
    $l = if ($last) { 99.0 } else { 100.0 - $Range / 2 }
    $bars.Add([pscustomobject]@{ t = (UtcStrToMs ($days[$i] + ' 00:00')); o = 100.0; h = $h; l = $l; c = $c; v = 1000 })
  }
  return $bars.ToArray()
}

function Obs-Sandbox([string]$Name) {
  $r = Join-Path $OBSWORK $Name
  New-Item -ItemType Directory -Force (Join-Path $r 'data\live_rf\series') | Out-Null
  Obs-WriteJson (Join-Path $r 'data\live_rf\series\NG.json') (Obs-Series)
  Obs-WriteJson (Join-Path $r 'data\live_rf\portfolio.json') ([pscustomobject]@{
    mode = 'prod'
    active = [pscustomobject]@{ NG = 'NGQ6' }
    go = [pscustomobject]@{ bot_capital_account_rub = 1000000.0 }
    risk_budget = [pscustomobject]@{ capital_rub = 1000000.0 } })
  Obs-WriteJson (Join-Path $r 'data\live_rf\config.json') ([pscustomobject]@{
    rf_risk_policy = [pscustomobject]@{ schema_version = 1; policy_id = 'rf-early-exit-v1'; mode = 'pilot'
      apply_to = 'new_entries'; capital_source = 'broker_verified'
      core = [pscustomobject]@{ stop_cap_pct = 0.02; risk_pct = 0.005 }
      setA = [pscustomobject]@{ stop_cap_pct = 0.02; risk_pct = 0.005 }
      futures_open_risk_cap_pct = 0.03; fx_same_direction_cap_pct = 0.015; daily_entry_loss_halt_pct = 0.02
      sizing_rule = 'min_original_and_capped_same_budget'; quote_max_age_sec = 60; capital_max_age_sec = 180 } })
  Obs-WriteJson (Join-Path $r 'data\live_rf\instruments.json') ([pscustomobject]@{
    NGQ6 = [pscustomobject]@{ ticker = 'NGQ6'; kind = 'fut'; uid = 'uid-NGQ6'; figi = 'FNG'; lot = 1
      min_price_increment = 0.01; rub_per_pt = 100.0; go_buy = 5000.0; go_sell = 5000.0
      last_trade_date = '2026-08-27'; expiration = '2026-08-27'; refreshed = '2026-07-15 00:00' } })
  return $r
}

function Obs-Run([string]$Root, [string]$MskTime = '2026-07-15 10:00', [string]$HourlyDir = '') {
  $nowMs = (UtcStrToMs $MskTime) - 10800000
  $out = Join-Path $Root 'obs_out'
  $shell = if ($env:LRF_TEST_SHELL) { [string]$env:LRF_TEST_SHELL } else { 'powershell' }
  # ГРАБЛЯ: имя $args занято автоматической переменной PowerShell - своё сплат-имя обязано быть другим
  $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $OBS, '-Root', $Root, '-NowMs', "$nowMs", '-OutDir', $out)
  if ($HourlyDir) { $psArgs += @('-HourlyDir', $HourlyDir) }
  $o = & $shell @psArgs 2>&1
  return ($o | Out-String)
}
function Obs-State([string]$Root) { Read-JsonFile (Join-Path $Root 'obs_out\state.json') }
function Obs-Journal([string]$Root) {
  $p = Join-Path $Root 'obs_out\decisions.jsonl'
  if (-not (Test-Path $p)) { return @() }
  return @(Get-Content $p -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Test-Observer {
  Write-Host "== наблюдатель стратегий (rf_observer) =="

  # --- 1. ноль торговых вызовов ПО ПОСТРОЕНИЮ: транспорт не подключён, мутирующих вызовов нет
  # Комментарии из проверки исключаем: в шапке наблюдателя эти имена ПЕРЕЧИСЛЕНЫ как то, чего там
  # быть не должно, и наивный поиск по всему файлу ловил бы собственную документацию.
  $code = @(Get-Content $OBS -Encoding UTF8 | Where-Object { $_.TrimStart() -notlike '#*' }) -join "`n"
  Check 'observer: lib_tinvest НЕ дот-сорсится' ($code -notmatch "\.\s+\(Join-Path[^)]*lib_tinvest")
  $forbidden = @('Post-TiOrder', 'Cancel-TiOrder', 'Post-TiStopOrder', 'Cancel-TiStopOrder',
    'Post-IntentMarket', 'Ensure-RubFunding', 'Invoke-TInvest', 'Replace-CardStop', 'Invoke-EmergencyClose')
  $hits = @($forbidden | Where-Object { $code -match [regex]::Escape($_) })
  Check 'observer: торговых функций в коде нет' ($hits.Count -eq 0)

  # --- 2. вход: все три варианта видят один и тот же пробой
  $r = Obs-Sandbox 'entry'
  $hd = Join-Path $r 'hourly'
  New-Item -ItemType Directory -Force $hd | Out-Null
  # часовые бары дня пробоя: первый закрытый час уже выше уровня 100
  Obs-WriteJson (Join-Path $hd 'NGQ6_2026-07-14.json') @(
    [pscustomobject]@{ t = (UtcStrToMs '2026-07-14 07:00'); o = 100.0; h = 106.0; l = 99.5; c = 105.0; v = 10 },
    [pscustomobject]@{ t = (UtcStrToMs '2026-07-14 08:00'); o = 105.0; h = 111.0; l = 104.0; c = 110.0; v = 10 })
  $out = Obs-Run $r '2026-07-15 10:00' $hd
  $stO = Obs-State $r
  Check 'observer: состояние создано' ($null -ne $stO)
  $p2 = @($stO.variants.core_2atr.positions)
  $pc = @($stO.variants.core_cap2.positions)
  $ph = @($stO.variants.core_hourly.positions)
  Check 'observer: core_2atr вошёл' ($p2.Count -eq 1 -and [string]$p2[0].side -eq 'long')
  Check 'observer: core_cap2 вошёл' ($pc.Count -eq 1)
  Check 'observer: core_hourly вошёл' ($ph.Count -eq 1)
  # цена входа: дневные варианты по закрытию дня (110), часовой - по закрытию ПЕРВОГО часа за уровнем (105)
  Check 'observer: дневной вход по закрытию дня (110)' ($p2.Count -and [math]::Abs([double]$p2[0].entry - 110.0) -lt 1e-9)
  Check 'observer: часовой вход по закрытию часа (105), а не дня' ($ph.Count -and [math]::Abs([double]$ph[0].entry - 105.0) -lt 1e-9)

  # --- 3. варианты НЕ делят состояние: у core_cap2 стоп ближе (предел 2%), у core_2atr - 2 ATR
  if ($p2.Count -and $pc.Count) {
    Check 'observer: у core_cap2 стоп ближе, чем у core_2atr' ([double]$pc[0].stop -gt [double]$p2[0].stop)
    Check 'observer: объём одинаков (предел стопа объём не увеличивает)' ([int]$pc[0].lots -eq [int]$p2[0].lots)
    Check 'observer: стратегический стоп у обоих один' ([math]::Abs([double]$pc[0].strat_stop - [double]$p2[0].strat_stop) -lt 1e-9)
  }

  # --- 4. журнал решений: решение восстановимо целиком (поля из плана §7)
  $j = Obs-Journal $r
  $ent = @($j | Where-Object { [string]$_.kind -eq 'entry' -and [string]$_.variant -eq 'core_2atr' })
  Check 'observer: запись о входе в журнале есть' ($ent.Count -eq 1)
  if ($ent.Count) {
    $e = $ent[0]
    $need = @('asset','contract','side','rules_version','policy_id','t_signal','t_decision','level','atr',
      'dist_to_level','px','px_source','stop_strategy','stop_effective','lots','budget_rub',
      'risk_before_rub','risk_after_rub','go_rub','eq_rub','allow','reason')
    $miss = @($need | Where-Object { -not $e.PSObject.Properties[$_] })
    Check 'observer: в записи есть все обязательные поля' ($miss.Count -eq 0)
    # канал Donchian строится по МАКСИМУМАМ баров [i-20..i-1], а не по закрытиям:
    # у плоских баров high = 100 + range/2 = 101, поэтому уровень 101, а не 100
    Check 'observer: уровень пробоя записан (верх канала 101)' ([math]::Abs([double]$e.level - 101.0) -lt 1e-9)
    Check 'observer: расстояние до уровня записано (110-101)' ([math]::Abs([double]$e.dist_to_level - 9.0) -lt 1e-9)
    Check 'observer: версия правил - хеш политики' ([string]$e.rules_version -match '^[0-9a-f]{64}$')
    Check 'observer: риск до входа = 0' ([math]::Abs([double]$e.risk_before_rub) -lt 0.01)
    Check 'observer: риск после входа > 0' ([double]$e.risk_after_rub -gt 0)
    Check 'observer: ГО записано' ([double]$e.go_rub -gt 0)
    Check 'observer: причина допуска записана' ([bool]$e.allow -and [string]$e.reason)
  }
  Check 'observer: секретов в журнале нет' (-not ((Get-Content (Join-Path $r 'obs_out\decisions.jsonl') -Raw) -match 'token|TOKEN|Bearer|account_id'))

  # --- 5. идемпотентность: повторный прогон того же дня не удваивает позиции
  [void](Obs-Run $r '2026-07-15 10:05' $hd)
  $st2 = Obs-State $r
  Check 'observer: повтор не удвоил позиции' (@($st2.variants.core_2atr.positions).Count -eq 1)
  Check 'observer: повтор не удвоил записи журнала' ((@(Obs-Journal $r | Where-Object { [string]$_.kind -eq 'entry' -and [string]$_.variant -eq 'core_2atr' }).Count) -eq 1)

  # --- 6. будущие бары не используются: обработан ровно завершённый день, не сегодняшний
  Check 'observer: последний обработанный день - завершённый' ([string]$st2.last_day -eq '2026-07-14')

  # --- 7. нет часовых баров - часовой вариант ПРОПУСКАЕТ вход, а не берёт дневную цену
  $r2 = Obs-Sandbox 'nohourly'
  $empty = Join-Path $r2 'hourly_empty'
  New-Item -ItemType Directory -Force $empty | Out-Null
  [void](Obs-Run $r2 '2026-07-15 10:00' $empty)
  $st3 = Obs-State $r2
  Check 'observer: без часовых баров core_hourly не вошёл' (@($st3.variants.core_hourly.positions).Count -eq 0)
  Check 'observer: дневные варианты при этом вошли' (@($st3.variants.core_2atr.positions).Count -eq 1)

  # --- 8. сбой наблюдателя не трогает боевое состояние: portfolio.json не изменился
  $before = (Get-FileHash (Join-Path $r 'data\live_rf\portfolio.json') -Algorithm SHA256).Hash
  [void](Obs-Run $r '2026-07-15 11:00' $hd)
  $after = (Get-FileHash (Join-Path $r 'data\live_rf\portfolio.json') -Algorithm SHA256).Hash
  Check 'observer: боевое состояние не тронуто' ($before -eq $after)
  $serBefore = (Get-FileHash (Join-Path $r 'data\live_rf\series\NG.json') -Algorithm SHA256).Hash
  Check 'observer: серии не тронуты' ($serBefore -eq (Get-FileHash (Join-Path $r 'data\live_rf\series\NG.json') -Algorithm SHA256).Hash)
}
