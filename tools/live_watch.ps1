# live_watch.ps1 - ВНЕШНИЙ сторож живости боевых контуров (Bybit LIVE и RF LIVE).
#
# Зачем отдельно от deploy/git_sync_watch.sh: тот сторож дот-сорсится в сам тик и живёт
# на VPS, поэтому смерть хоста он сообщить не может - некому выполниться. Инцидент
# 2026-08-03: подписка на VPS кончилась в 21:01 UTC, оба контура молчали 6 ч 45 мин,
# ни одного алерта не ушло. Этот скрипт крутится в GitHub Actions (tick.yml), то есть на
# стороне, которая гарантированно жива и видит боевое состояние через git.
#
# Он ловит все три способа ослепнуть разом, потому что смотрит на РЕЗУЛЬТАТ, а не на путь:
#   - мёртвый хост       - снапшоты эквити перестали появляться;
#   - упавший движок     - то же самое (git_sync_watch этот случай НЕ видит: pull_ok=1,
#                          ahead=0, для него всё "healthy");
#   - сломанный git push - состояние не доезжает до нас, что и есть определение проблемы.
#
# Сигнал - время последнего снапшота эквити в состоянии контура. Обновляется каждые ~15 мин
# круглосуточно, включая выходные и ночь (проверено по истории: за всё время работы контуров
# ВСЕ разрывы >45 мин оказывались реальными инцидентами), и замирает при любой поломке.
#
# Философия зеркалит git_sync_watch.sh: сторож НИКОГДА не роняет тик. Каждая ветка под
# try/catch, скрипт всегда завершается успешно. Наблюдаемость не должна ломать торговлю.
#
# Правило двух писателей соблюдено: data/live_watch.json пишет ТОЛЬКО Actions (как и
# остальное paper-состояние), data/live_real и data/live_rf отсюда только читаются.

[CmdletBinding()]
param(
  [string]$Root = '',
  [int]$StaleMin = 60,     # тишина до первого алерта
  [int]$RepeatMin = 120,   # период напоминаний, пока контур молчит
  [long]$NowMs = 0,        # инъекция времени для тестов (0 = сейчас)
  [switch]$DryRun          # печатать вместо отправки в Telegram
)

$ErrorActionPreference = 'Continue'
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'lib_engine.ps1')
. (Join-Path $PSScriptRoot 'lib_alerts.ps1')
. (Join-Path $PSScriptRoot 'lib_msg_ru.ps1')

if (-not $NowMs) { $NowMs = UtcNowMs }
$statePath = Join-Path $Root 'data\live_watch.json'

# Контуры. fanout - второй получатель (у фьючерсов свой адресат, как в live_rf_engine.ps1).
$CONTOURS = @(
  [ordered]@{
    key = 'bybit'; prefix = 'Крипта'; unit = 'live-tick'
    equity = 'data\live_real\live_equity.json'
    guard = 'Защитные стоп-заявки стоят на бирже и продолжают действовать'
    fanout = $false
  },
  [ordered]@{
    key = 'rf'; prefix = 'Фьючерсы'; unit = 'live-rf-tick'
    equity = 'data\live_rf\equity.json'
    guard = 'Стоп-заявки у брокера продолжают действовать'
    fanout = $true
  }
)

function Fmt-Dur([int]$Min) {
  # "45 мин" / "2 ч" / "6 ч 45 мин"
  if ($Min -lt 60) { return ('{0} {1}' -f $Min, (Plural $Min 'минута' 'минуты' 'минут')) }
  $h = [int][math]::Floor($Min / 60); $m = $Min % 60
  $hs = '{0} {1}' -f $h, (Plural $h 'час' 'часа' 'часов')
  if ($m -eq 0) { return $hs }
  return ('{0} {1} {2}' -f $hs, $m, (Plural $m 'минута' 'минуты' 'минут'))
}

function Notify($C, [string]$Text) {
  $msg = '{0}: {1}' -f $C.prefix, $Text
  if ($DryRun) { Write-Host "[DRY] $msg"; return }
  $failed = @()
  try { if (-not (Send-TgAlert $msg)) { $failed += 'основной' } } catch { $failed += 'основной' }
  if ($C.fanout -and $env:TG_CHAT_ID_FUT) {
    try { if (-not (Send-TgAlert $msg -Chat $env:TG_CHAT_ID_FUT)) { $failed += 'фьючерсный' } } catch { $failed += 'фьючерсный' }
  }
  # Немой сторож неотличим от здоровой системы: Send-TgAlert при пустых кредах молча отдаёт $false.
  # Инцидент 2026-08-11 - RF-контур лежал 27 ч, сторож исправно «слал» ~13 алертов в никуда.
  # Аннотация подсвечивает это в логе рана, но кода возврата не меняет: тик ронять нельзя.
  if ($failed.Count) {
    Write-Host ("::error title=live_watch::алерт НЕ доставлен ({0}) - проверьте секреты TG_BOT_TOKEN/TG_CHAT_ID/TG_CHAT_ID_FUT в Settings -> Secrets. Текст: {1}" -f ($failed -join ', '), $msg)
  }
}

# Последний снапшот эквити. Возвращает $null, если файла нет или он пуст/битый -
# это тоже неисправность (файлы под git), но с отдельным текстом.
function Get-LastEquityMs([string]$Path) {
  try {
    if (-not (Test-Path $Path)) { return $null }
    # PS 5.1: ConvertFrom-Json отдаёт массив ОДНИМ объектом - без прогона через
    # Where-Object @() обернёт его целиком и Count станет 1 (идиома из live_rf_engine.ps1)
    $rows = @((Read-JsonFile $Path) | Where-Object { $null -ne $_ })
    if (-not $rows.Count) { return $null }
    $last = $rows[$rows.Count - 1]
    if ($null -eq $last -or -not $last.PSObject.Properties['ts']) { return $null }
    return [long]$last.ts
  } catch {
    Write-Warning "live_watch: не читается $Path : $($_.Exception.Message)"
    return $null
  }
}

# Состояние алертов -> hashtable. Запись есть = сбой в процессе и первый алерт уже ушёл.
$state = @{}
try {
  $raw = Read-JsonFile $statePath
  if ($raw) { foreach ($p in $raw.PSObject.Properties) { $state[$p.Name] = $p.Value } }
} catch { Write-Warning "live_watch: состояние $statePath не прочиталось: $($_.Exception.Message)" }

foreach ($c in $CONTOURS) {
  try {
    $lastMs = Get-LastEquityMs (Join-Path $Root $c.equity)
    # bad_ts - «на каком снапшоте контур замер». Ключ эпизода: новый сбой имеет другой
    # bad_ts и потому пробивает дедупликацию. Потеря файла состояния приводит максимум
    # к повторному алерту - отказ в безопасную сторону (лучше два раза, чем ни разу).
    $hasData = ($null -ne $lastMs)
    $badTs = if ($hasData) { $lastMs } else { 0L }
    $silentMin = if ($hasData) { [int][math]::Floor(($NowMs - $lastMs) / 60000.0) } else { 0 }
    $prev = $state[$c.key]

    if ($hasData -and $silentMin -lt $StaleMin) {
      if ($prev) {
        $downMin = [int][math]::Floor(($NowMs - [long]$prev.bad_ts) / 60000.0)
        Notify $c ('контур снова на связи, данные актуальны. Простой был около {0}.' -f (Fmt-Dur $downMin))
        $state.Remove($c.key)
      }
      Write-Host ("live_watch [{0}]: свежесть {1} мин - норма" -f $c.key, $silentMin)
      continue
    }

    $howLong = if ($hasData) { Fmt-Dur $silentMin } else { 'неизвестно сколько' }

    if ($prev -and [long]$prev.bad_ts -eq $badTs) {
      # тот же эпизод: только напоминания раз в RepeatMin
      $sinceMsg = [int][math]::Floor(($NowMs - [long]$prev.last_msg_ms) / 60000.0)
      if ($sinceMsg -ge $RepeatMin) {
        Notify $c ('контур всё ещё не выходит на связь ({0}).' -f $howLong)
        $prev.last_msg_ms = $NowMs
        $state[$c.key] = $prev
      }
      Write-Host ("live_watch [{0}]: сбой продолжается, тишина {1}" -f $c.key, $howLong)
      continue
    }

    # новый эпизод - первый алерт
    if ($hasData) {
      Notify $c ('боевой контур не выходит на связь уже {0} - последние данные от {1} UTC. {2}, но сопровождения сделок (первая цель, безубыток, трейл) сейчас нет. Проверьте VPS: оплату хостинга и systemctl status {3}.timer' -f $howLong, (MsToUtcStr $lastMs), $c.guard, $c.unit)
    } else {
      Notify $c ('состояние контура недоступно - файл {0} отсутствует или пуст. {1}, но сопровождения сделок сейчас нет. Проверьте репозиторий и VPS: journalctl -u {2}.' -f $c.equity, $c.guard, $c.unit)
    }
    $state[$c.key] = [pscustomobject]@{ bad_ts = $badTs; last_msg_ms = $NowMs }
    Write-Host ("live_watch [{0}]: АЛЕРТ, тишина {1}" -f $c.key, $howLong)
  } catch {
    # сторож не имеет права ронять тик ни при каких обстоятельствах
    Write-Warning "live_watch [$($c.key)]: $($_.Exception.Message)"
  }
}

# DryRun не трогает состояние: иначе прогон «посмотреть» съел бы дедупликацию
# и следующий боевой запуск промолчал бы о реальном сбое.
try {
  if ($DryRun) {
    Write-Host 'live_watch: DryRun - состояние не сохраняется'
  } elseif ($state.Count) {
    Write-JsonAtomic $statePath ([pscustomobject]$state) 5
  } elseif (Test-Path $statePath) {
    Remove-Item $statePath -Force   # здоровая система не оставляет артефакта
  }
} catch { Write-Warning "live_watch: состояние не сохранилось: $($_.Exception.Message)" }

exit 0
