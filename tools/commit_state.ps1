# commit_state.ps1 - коммит состояния бота в main, терпимый к гонке пушей.
#
# Писателей в main трое: paper-тик в GitHub Actions (этот скрипт), а также `live tick` и
# `rf-live tick` с VPS. Все ходят около :00/:15/:30/:45, поэтому отбитый пуш - штатное
# событие, а не поломка: состояние пересчитывается каждым тиком заново, и потерянный
# коммит доедет следующим. Идиома взята с VPS (deploy/live_rf_tick.sh): push, при отказе
# fetch+rebase и повтор, при повторном отказе - предупреждение и выход БЕЗ ошибки.
#
# ЗАЧЕМ ОТДЕЛЬНЫМ СКРИПТОМ (инцидент 2026-08-17). Раньше этот блок жил инлайном в
# tick.yml и manual-close.yml, дословно продублированный, и был там единственным
# инлайн-шагом - все остальные вызывают tools\*.ps1. В PowerShell идиома VPS не
# работает: GitHub для `shell: powershell` дописывает в конец скрипта
# `exit $LASTEXITCODE`, поэтому провалившийся пуш всё равно красил джобу, несмотря на
# напечатанное "state will retry next tick". А так как джоба deploy объявлена через
# `needs: tick`, каждая гонка ЕЩЁ И пропускала публикацию Pages - дашборд молча старел.
# 17.08 таких ранов было 8 за 2 часа при полностью успешном торговом тике.
#
# Отсюда правило кодов возврата:
#   0 - состояние закоммичено ЛИБО пуш отбит ИМЕННО ГОНКОЙ (норма, повтор следующим тиком);
#   1 - всё остальное: не git-репо, отказ коммита, недоступный remote, отказ авторизации,
#       незнакомый отказ пуша. Такое глушить нельзя.
# Наблюдаемость не должна ломать торговлю, но и настоящая поломка не должна прятаться за
# терпимостью к гонке. Внешний аудит 2026-08-17 поймал вторую ошибку: первая версия считала
# гонкой ЛЮБОЙ ненулевой код пуша, то есть протухшие креды или битый remote давали зелёный
# тик при том, что состояние молча не публиковалось. Классификация - в Test-RaceRejection.

[CmdletBinding()]
param(
  # Что коммитим, через запятую: paper-тик отдаёт portfolio.json,journal.md,data;
  # manual-close - data,journal.md. ИМЕННО строка, а не [string[]]: при запуске через
  # `powershell.exe -File` аргументы приходят литеральными строками, и "a,b,c" связался бы
  # с массивом одним элементом - git получал бы такой pathspec целиком и падал с кодом 128.
  [Parameter(Mandatory = $true)][string]$Path,
  # префикс сообщения коммита: 'tick' | 'manual-close'. Формат "<label> <stamp> UTC" менять
  # нельзя - по нему грепают историю (журналы, дашборд, разборы инцидентов).
  [Parameter(Mandatory = $true)][string]$Label,
  [int]$Tries = 3,          # попыток пуша, считая первую
  [switch]$NoDelay          # без паузы между попытками (тесты)
)

# Коды git проверяем руками, поэтому не даём PowerShell вмешиваться в поток.
$ErrorActionPreference = 'Continue'

# Предусловие: без него сломанный checkout выглядел бы как "нечего коммитить" и молча
# давал бы зелёный ран - ровно тот класс тихой слепоты, который уже стоил нам суток простоя.
$null = git rev-parse --git-dir 2>&1
if ($LASTEXITCODE -ne 0) {
  Write-Error 'рабочий каталог не является git-репозиторием - состояние коммитить некуда'
  exit 1
}

git config user.name 'paper-desk-bot'
git config user.email 'bot@users.noreply.github.com'

$paths = @($Path -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $paths) { Write-Error "-Path пуст после разбора: '$Path'"; exit 1 }

git add -- $paths
if ($LASTEXITCODE -ne 0) {
  # Часть путей могла не появиться - не повод ронять тик: что попало в индекс, то и уедет.
  Write-Warning "git add вернул $LASTEXITCODE - продолжаем по фактическому индексу"
}

$staged = git diff --cached --name-only
if (-not $staged) { Write-Host 'state unchanged - nothing to commit'; exit 0 }

$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')
git commit -q -m "$Label $stamp UTC"
if ($LASTEXITCODE -ne 0) {
  # Индекс не пуст, а коммит не вышел - это не гонка, а поломка: пусть ран краснеет.
  Write-Error "git commit провалился с кодом $LASTEXITCODE - состояние НЕ закоммичено"
  exit 1
}

# Гонка определяется ФАКТОМ, а не текстом. Второй аудит 2026-08-17 показал, почему список
# английских фраз не годится: он искал 'Updates were rejected' во всём stderr, а туда попадает
# произвольный текст удалённого pre-receive хука. Хук с сообщением "Updates were rejected by
# policy" - постоянный запрет публикации - выдавался за гонку и давал exit 0.
#
# Признак гонки ровно один: пока мы работали, remote уехал вперёд. Это проверяется сравнением
# origin/main до и после fetch и неуязвимо к чужому тексту, локали раннера и любым будущим
# формулировкам git.
function Get-RemoteHead {
  $sha = (git rev-parse --verify --quiet origin/main 2>$null | Out-String).Trim()
  return $sha
}

for ($try = 1; $try -le $Tries; $try++) {
  $remoteBefore = Get-RemoteHead

  git push -q origin main
  if ($LASTEXITCODE -eq 0) { Write-Host "state pushed (attempt $try)"; exit 0 }
  $pushCode = $LASTEXITCODE

  git fetch origin main
  if ($LASTEXITCODE -ne 0) {
    # Не смогли даже вычитать remote - гонки быть не может по определению: связность/доступ.
    Write-Error "[fetch-failed] git fetch вернул $LASTEXITCODE - до remote не достучаться, это не гонка"
    exit 1
  }

  $remoteAfter = Get-RemoteHead
  if ($remoteAfter -eq $remoteBefore) {
    # Remote не двигался, значит мы не отставали - пуш отбили по другой причине:
    # хук, protected branch, права. Это отказ публикации, ран обязан покраснеть.
    Write-Error "[push-failed-hard] пуш отбит (код $pushCode), но origin/main не сдвинулся ($remoteAfter) - это не гонка, а отказ публикации"
    exit 1
  }

  Write-Warning "[race-detected] push отбит гонкой (попытка $try из $Tries): origin/main уехал $remoteBefore -> $remoteAfter"
  if (-not $NoDelay) {
    # Джиттер, чтобы два писателя не повторяли попытку в лок-степе.
    Start-Sleep -Milliseconds (Get-Random -Minimum 500 -Maximum 2500)
  }

  # --autostash ОБЯЗАТЕЛЕН, а не украшение: build_vizdata.ps1 на каждом прогоне переписывает
  # отслеживаемые report/chart.html и report/charts.html (cache-bust ?v=<timestamp>), а этот
  # шаг их не коммитит. Без autostash rebase гарантированно падает с "cannot rebase: You have
  # unstaged changes", и повтор после гонки не работает НИКОГДА - именно это нашёл второй
  # аудит. Тот же приём стоит на VPS: git pull --rebase --autostash в deploy/live_rf_tick.sh.
  git rebase --autostash origin/main
  if ($LASTEXITCODE -ne 0) {
    # Незавершённый rebase оставляет дерево в середине операции - пушить оттуда нельзя.
    git rebase --abort 2>$null
    # Маркер в ASCII и своими словами: подсказку git'а "run git rebase --abort" тест ловил
    # как ложно-положительную (первый аудит), теперь проверяется именно эта строка.
    Write-Warning '[rebase-aborted] rebase не сошёлся - состояние уедет следующим тиком'
    break
  }
}

Write-Warning 'push failed - state will retry next tick'
exit 0
