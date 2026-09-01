# test_commit_state.ps1 - тесты tools\commit_state.ps1 на черновых репозиториях.
# Запуск: powershell -File tools\test_commit_state.ps1
#
# Смысл: ветка «гонка проиграна» в проде наступает случайно (17.08 - 8 раз за 2 часа), и
# ждать её, чтобы проверить фикс, нельзя. Здесь гонка ставится руками: второй клон пушит
# первым, наш клон получает отказ.
#
# КЛЮЧЕВАЯ ДЕТАЛЬ: скрипт вызывается ДОЧЕРНИМ процессом `$PSHOST -File`, ровно как
# в воркфлоу, и проверяется именно $LASTEXITCODE. Иначе тест не поймал бы исходный баг -
# он был не в логике, а в коде возврата шага.

param(
  # Чем подменить проверяемый скрипт. Нужен, чтобы доказать, что тест ловит именно тот баг:
  # подсунешь старую инлайн-логику из tick.yml - кейс 3 обязан упасть.
  [string]$ScriptUnderTest = ''
)

# 'Continue', а не 'Stop': PS 5.1 оборачивает stderr нативной команды в ErrorRecord
# (NativeCommandError), а git пишет туда обычный прогресс - под 'Stop' безобидный
# `git clone` роняет весь тест.
$ErrorActionPreference = 'Continue'
$Script = if ($ScriptUnderTest) { $ScriptUnderTest } else { Join-Path $PSScriptRoot 'commit_state.ps1' }

# The script under test runs on the SAME PowerShell host as this test. 'powershell.exe' does
# not exist on Linux and -ExecutionPolicy is a Windows-only switch, so hardcoding them pinned
# this suite to Windows. On Windows $PSHOST is still powershell.exe, i.e. the production shape
# from tick.yml / manual-close.yml is preserved exactly where it matters.
$IsWinHost = ($null -eq $IsWindows) -or $IsWindows
$PSHOST = (Get-Process -Id $PID).Path
$PSHOST_ARGS = if ($IsWinHost) { @('-NoProfile', '-ExecutionPolicy', 'Bypass') } else { @('-NoProfile') }

$script:pass = 0; $script:fail = 0; $script:failed = @()
function Check([string]$Name, [bool]$Cond) {
  if ($Cond) { $script:pass++; Write-Host ("  ok   " + $Name) }
  else { $script:fail++; $script:failed += $Name; Write-Host ("  FAIL " + $Name) -ForegroundColor Red }
}

# Тихий git. Две грабли разом:
#   - имя НЕ 'Git': функции в PowerShell регистронезависимы, и такая обёртка перехватила бы
#     собственный вызов git (call depth overflow);
#   - НИЧЕГО не возвращает: `return $LASTEXITCODE` подмешивал нули в выхлоп New-Scene, и
#     вместо объекта сцены вызывающий получал массив (0,0,...,object) с пустым .Work.
# Кому нужен код возврата - читает $LASTEXITCODE сразу после вызова.
function gitq { & git @args 2>&1 | Out-Null }

# ПРЕДОХРАНИТЕЛЬ. Тест пишет файлы и делает git add/commit/push, поэтому обязан доказать,
# что находится внутри черновой сцены, а не в боевом дереве. Аудит 2026-08-17 показал, как
# это стреляет: результат `git clone` не проверялся, а Push-Location при
# $ErrorActionPreference='Continue' не прерывает выполнение - при неудачном клоне тест
# продолжал работу В РАБОЧЕМ РЕПОЗИТОРИИ и доходил до `git push origin main` с боевыми
# кредами. Проверяем факт, а не намерение: где реально лежит корень текущего репо.
function Assert-InScene([string]$Expected) {
  $top = (& git rev-parse --show-toplevel 2>$null)
  $a = try { (Resolve-Path -LiteralPath $top -ErrorAction Stop).Path } catch { '' }
  $b = try { (Resolve-Path -LiteralPath $Expected -ErrorAction Stop).Path } catch { '' }
  if (-not $a -or -not $b -or $a.TrimEnd('\','/') -ne $b.TrimEnd('\','/')) {
    throw "ПРЕДОХРАНИТЕЛЬ: ожидали работать в '$Expected', а находимся в '$top'. Тест остановлен до любой записи."
  }
}

# Черновая сцена: bare-remote + наш клон + клон «второго писателя».
function New-Scene {
  $dir = Join-Path ([IO.Path]::GetTempPath()) ("cs_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $remote = Join-Path $dir 'remote.git'; $work = Join-Path $dir 'work'; $other = Join-Path $dir 'other'
  New-Item -ItemType Directory -Path $dir | Out-Null
  gitq init --bare -b main $remote
  if ($LASTEXITCODE -ne 0) { throw "не удалось создать bare-remote '$remote' (код $LASTEXITCODE)" }
  gitq clone $remote $work
  if ($LASTEXITCODE -ne 0) { throw "не удалось склонировать сцену в '$work' (код $LASTEXITCODE)" }
  if (-not (Test-Path -LiteralPath (Join-Path $work '.git'))) { throw "клон '$work' не появился" }

  Push-Location $work -ErrorAction Stop
  try {
    Assert-InScene $work        # только после этого - любая запись
    gitq config user.name 'seed'; gitq config user.email 'seed@example.com'
    Set-Content -Path 'portfolio.json' -Value '{"seed":1}' -Encoding utf8
    New-Item -ItemType Directory -Path 'data' | Out-Null
    Set-Content -Path 'data/state.json' -Value '{"seed":1}' -Encoding utf8
    Set-Content -Path 'journal.md' -Value "seed`n" -Encoding utf8
    # Отслеживаемый файл ВНЕ -Path: копия report/chart.html из прода, который build_vizdata
    # переписывает каждым прогоном, а Commit state не коммитит. Нужен сценарию 12.
    Set-Content -Path 'report_chart.html' -Value '<html>?v=111</html>' -Encoding utf8
    gitq add -A; gitq commit -q -m seed; gitq push -q origin main
  } finally { Pop-Location }

  gitq clone $remote $other
  if ($LASTEXITCODE -ne 0) { throw "не удалось склонировать второго писателя в '$other' (код $LASTEXITCODE)" }
  return [pscustomobject]@{ Dir = $dir; Remote = $remote; Work = $work; Other = $other }
}

# Записать файл внутри сцены, предварительно доказав, что мы в ней.
function Set-SceneFile([string]$SceneWork, [string]$RelPath, [string]$Content) {
  Push-Location $SceneWork -ErrorAction Stop
  try {
    Assert-InScene $SceneWork
    Set-Content -Path $RelPath -Value $Content -Encoding utf8
  } finally { Pop-Location }
}

# Действия «второго писателя» - тоже под предохранителем.
function Invoke-OtherWriter([string]$OtherDir, [string]$RelPath, [string]$Content, [string]$Message) {
  Push-Location $OtherDir -ErrorAction Stop
  try {
    Assert-InScene $OtherDir
    gitq config user.name 'other'; gitq config user.email 'other@example.com'
    Set-Content -Path $RelPath -Value $Content -Encoding utf8
    gitq add -A; gitq commit -q -m $Message; gitq push -q origin main
  } finally { Pop-Location }
}

# Вызов ровно как в Actions: дочерний `$PSHOST -File`, наружу отдаём его код.
function Invoke-CommitState([string]$WorkDir, [string[]]$Paths, [string]$Label, [switch]$SkipSceneCheck) {
  Push-Location $WorkDir -ErrorAction Stop
  try {
    # SkipSceneCheck нужен единственному сценарию «каталог вообще не git-репо»: там
    # rev-parse обязан провалиться, и это как раз проверяемое поведение.
    if (-not $SkipSceneCheck) { Assert-InScene $WorkDir }
    $joined = $Paths -join ','
    $out = & $PSHOST @PSHOST_ARGS -File $Script `
      -Path $joined -Label $Label -NoDelay 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
  } finally { Pop-Location }
}

# Поставить в bare-remote pre-receive хук, который отказывает и печатает заданный текст.
# Нужен для сценария второго аудита: текст хука попадает в stderr пуша, и классификатор,
# который разбирает текст, принимал "Updates were rejected by policy" за гонку.
function Set-RejectHook([string]$Remote, [string]$Message) {
  $hooks = Join-Path $Remote 'hooks'
  if (-not (Test-Path $hooks)) { New-Item -ItemType Directory -Path $hooks | Out-Null }
  $hook = Join-Path $hooks 'pre-receive'
  # LF и без BOM: это shell-скрипт, git запускает его через sh даже на Windows.
  $body = "#!/bin/sh`necho '$Message' >&2`nexit 1`n"
  [IO.File]::WriteAllText($hook, $body, (New-Object System.Text.UTF8Encoding($false)))
  # Linux git silently ignores a hook without the execute bit: the push would then SUCCEED and
  # the scenario would prove nothing instead of failing loudly. No-op on Windows.
  if (-not $IsWinHost) { & chmod '+x' $hook | Out-Null }
  return $hook
}

# Заголовок последнего локального коммита в сцене. Отдельной функцией, потому что
# try/finally - это инструкция, её нельзя вписать выражением в аргумент Check.
function Get-SceneLastCommit([string]$SceneWork) {
  Push-Location $SceneWork -ErrorAction Stop
  try { return (& git log --oneline -1 2>&1 | Out-String) } finally { Pop-Location }
}

function Remote-Log([string]$Remote) {
  $prev = $LASTEXITCODE
  $log = & git --git-dir=$Remote log --oneline main 2>&1
  $null = $prev
  return ($log -join "`n")
}

$scenes = @()
try {
  # ---- 1. чистый пуш: конкурентов нет ----
  Write-Host '== 1. чистый пуш =='
  $s = New-Scene; $scenes += $s
  Set-SceneFile $s.Work 'portfolio.json' '{"tick":1}'
  $r = Invoke-CommitState $s.Work @('portfolio.json', 'journal.md', 'data') 'tick'
  Check 'чистый пуш: exit 0' ($r.Code -eq 0)
  Check 'чистый пуш: коммит на remote' ((Remote-Log $s.Remote) -match 'tick \d{4}-\d{2}-\d{2}')

  # ---- 2. гонка выиграна: чужой коммит в ДРУГОЙ файл, rebase сходится ----
  Write-Host '== 2. гонка выиграна (rebase сходится) =='
  $s = New-Scene; $scenes += $s
  Invoke-OtherWriter $s.Other 'journal.md' "other wins`n" 'other tick'
  Set-SceneFile $s.Work 'portfolio.json' '{"tick":2}'
  $r = Invoke-CommitState $s.Work @('portfolio.json', 'journal.md', 'data') 'tick'
  Check 'гонка выиграна: exit 0' ($r.Code -eq 0)
  Check 'гонка выиграна: был отбой пуша' ($r.Text -match '\[race-detected\]')
  $log = Remote-Log $s.Remote
  Check 'гонка выиграна: на remote ОБА коммита' (($log -match 'other tick') -and ($log -match 'tick \d{4}'))

  # ---- 3. гонка проиграна: конфликт в ТОТ ЖЕ файл. Это регрессия на сам баг ----
  Write-Host '== 3. гонка проиграна (конфликт, rebase не сходится) =='
  $s = New-Scene; $scenes += $s
  Invoke-OtherWriter $s.Other 'portfolio.json' '{"other":99}' 'other conflicting'
  Set-SceneFile $s.Work 'portfolio.json' '{"tick":3}'
  $r = Invoke-CommitState $s.Work @('portfolio.json', 'journal.md', 'data') 'tick'
  Check 'гонка проиграна: exit 0 (ран НЕ краснеет)' ($r.Code -eq 0)
  # Ищем СВОЙ маркер, а не слово 'abort': git сам подсказывает «run git rebase --abort»,
  # и прежняя проверка проходила даже на старой логике, где abort вообще не звался (аудит).
  Check 'гонка проиграна: rebase прерван (свой маркер)' ($r.Text -match '\[rebase-aborted\]')
  Check 'гонка проиграна: обещан повтор' ($r.Text -match 'state will retry next tick')
  Check 'гонка проиграна: чужой коммит на remote цел' ((Remote-Log $s.Remote) -match 'other conflicting')
  Push-Location $s.Work -ErrorAction Stop
  $mid = (& git status --porcelain 2>&1 | Out-String)
  Pop-Location
  Check 'гонка проиграна: дерево не осталось в середине rebase' ($mid -notmatch '^(UU|AA|both)')

  # ---- 4. нечего коммитить ----
  Write-Host '== 4. состояние не изменилось =='
  $s = New-Scene; $scenes += $s
  $r = Invoke-CommitState $s.Work @('portfolio.json', 'journal.md', 'data') 'tick'
  Check 'нет изменений: exit 0' ($r.Code -eq 0)
  Check 'нет изменений: сказано вслух' ($r.Text -match 'state unchanged')
  Check 'нет изменений: пустого коммита нет' ((Remote-Log $s.Remote) -notmatch 'tick \d{4}')

  # ---- 5. настоящая поломка слышна: не git-репо ----
  Write-Host '== 5. настоящая поломка (не git-репо) =='
  $bare = Join-Path ([IO.Path]::GetTempPath()) ("cs_none_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $bare | Out-Null
  $scenes += [pscustomobject]@{ Dir = $bare }
  $r = Invoke-CommitState $bare @('portfolio.json') 'tick' -SkipSceneCheck
  Check 'не репо: exit НЕ 0' ($r.Code -ne 0)

  # ---- 6. manual-close пишет свой префикс ----
  Write-Host '== 6. префикс manual-close =='
  $s = New-Scene; $scenes += $s
  Set-SceneFile $s.Work 'data/state.json' '{"closed":1}'
  $r = Invoke-CommitState $s.Work @('data', 'journal.md') 'manual-close'
  Check 'manual-close: exit 0' ($r.Code -eq 0)
  Check 'manual-close: формат сообщения сохранён' ((Remote-Log $s.Remote) -match 'manual-close \d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC')

  # ---- 7-9. ОТКАЗ ПУБЛИКАЦИИ - не гонка, ран обязан краснеть ----
  # Этих сценариев не было, и поэтому проскочила дыра, найденная аудитом 2026-08-17:
  # старая версия считала гонкой любой ненулевой код пуша и отдавала 0, то есть тик был
  # зелёным, пока состояние молча не публиковалось.
  $broken = @(
    @{ n = '7. remote удалён';            act = { param($w) Push-Location $w -ErrorAction Stop; try { Assert-InScene $w; gitq remote remove origin } finally { Pop-Location } } },
    @{ n = '8. remote в никуда';          act = { param($w) Push-Location $w -ErrorAction Stop; try { Assert-InScene $w; gitq remote set-url origin (Join-Path ([IO.Path]::GetTempPath()) ('нет_такого_' + [guid]::NewGuid().ToString('N'))) } finally { Pop-Location } } },
    @{ n = '9. remote не репозиторий';    act = { param($w)
        $notRepo = Join-Path ([IO.Path]::GetTempPath()) ('cs_notrepo_' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $notRepo | Out-Null
        Push-Location $w -ErrorAction Stop; try { Assert-InScene $w; gitq remote set-url origin $notRepo } finally { Pop-Location } } }
  )
  foreach ($case in $broken) {
    Write-Host ("== {0} (ожидаем exit 1) ==" -f $case.n)
    $s = New-Scene; $scenes += $s
    & $case.act $s.Work
    Set-SceneFile $s.Work 'portfolio.json' ('{"tick":"' + $case.n + '"}')
    $r = Invoke-CommitState $s.Work @('portfolio.json', 'journal.md', 'data') 'tick'
    Check ("{0}: exit НЕ 0 (отказ публикации слышен)" -f $case.n) ($r.Code -ne 0)
    Check ("{0}: НЕ выдан за гонку" -f $case.n) ($r.Text -notmatch 'state will retry next tick')
    Check ("{0}: коммит всё же создан локально" -f $case.n) ((Get-SceneLastCommit $s.Work) -match 'tick \d{4}')
  }

  # ---- 10. hook-отказ с текстом-ловушкой: дословный сценарий второго аудита ----
  # pre-receive печатает "Updates were rejected by policy". Классификатор по тексту принимал
  # это за гонку и отдавал 0, хотя публикация запрещена НАВСЕГДА. Ждём exit 1.
  Write-Host '== 10. hook отказывает текстом "Updates were rejected by policy" =='
  $s = New-Scene; $scenes += $s
  Set-RejectHook $s.Remote 'Updates were rejected by policy' | Out-Null
  Set-SceneFile $s.Work 'portfolio.json' '{"tick":10}'
  $r = Invoke-CommitState $s.Work @('portfolio.json', 'journal.md', 'data') 'tick'
  Check 'hook-ловушка: exit НЕ 0' ($r.Code -ne 0)
  Check 'hook-ловушка: НЕ выдан за гонку' ($r.Text -notmatch 'state will retry next tick')
  Check 'hook-ловушка: на remote нашего коммита нет' ((Remote-Log $s.Remote) -notmatch 'tick \d{4}')

  # ---- 11. hook-отказ обычным текстом ----
  Write-Host '== 11. hook отказывает обычным текстом =='
  $s = New-Scene; $scenes += $s
  Set-RejectHook $s.Remote 'push denied by branch policy' | Out-Null
  Set-SceneFile $s.Work 'portfolio.json' '{"tick":11}'
  $r = Invoke-CommitState $s.Work @('portfolio.json', 'journal.md', 'data') 'tick'
  Check 'hook обычный: exit НЕ 0' ($r.Code -ne 0)
  Check 'hook обычный: на remote нашего коммита нет' ((Remote-Log $s.Remote) -notmatch 'tick \d{4}')

  # ---- 12. ГОНКА ПРИ ГРЯЗНОМ ОТСЛЕЖИВАЕМОМ ФАЙЛЕ - точная копия прода ----
  # build_vizdata.ps1 каждый прогон переписывает отслеживаемый report/chart.html, а Commit
  # state его не коммитит. Без --autostash rebase падает с "cannot rebase: You have unstaged
  # changes", и повтор после гонки не публикует НИЧЕГО, отдавая при этом 0. Поэтому здесь
  # мало проверить код возврата - требуем, чтобы коммит реально оказался на remote.
  Write-Host '== 12. гонка + незакоммиченный отслеживаемый файл (как в проде) =='
  $s = New-Scene; $scenes += $s
  Invoke-OtherWriter $s.Other 'journal.md' "other moved`n" 'other tick'
  Set-SceneFile $s.Work 'report_chart.html' '<html>?v=222</html>'   # грязный, вне -Path
  Set-SceneFile $s.Work 'portfolio.json' '{"tick":12}'
  $r = Invoke-CommitState $s.Work @('portfolio.json', 'journal.md', 'data') 'tick'
  Check 'грязное дерево: exit 0' ($r.Code -eq 0)
  Check 'грязное дерево: СОСТОЯНИЕ РЕАЛЬНО ОПУБЛИКОВАНО' ((Remote-Log $s.Remote) -match 'tick \d{4}')
  Check 'грязное дерево: чужой коммит цел' ((Remote-Log $s.Remote) -match 'other tick')
  Check 'грязное дерево: rebase НЕ срывался' ($r.Text -notmatch '\[rebase-aborted\]')
}
catch {
  # Сорванный харнесс - это НЕ успех. Без этого блока падение на подготовке сцены давало
  # "pass=0 fail=0" и exit 0, то есть тест, не выполнивший ни одной проверки, выдавал себя
  # за зелёный. Ровно та же тихая слепота, против которой написан сам commit_state.ps1.
  Write-Host ("СБОЙ ХАРНЕССА: " + $_.Exception.Message) -ForegroundColor Red
  foreach ($s in $scenes) {
    if ($s.Dir -and (Test-Path $s.Dir)) { Remove-Item $s.Dir -Recurse -Force -ErrorAction SilentlyContinue }
  }
  exit 1
}
finally {
  foreach ($s in $scenes) {
    if ($s.Dir -and (Test-Path $s.Dir)) { Remove-Item $s.Dir -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

Write-Host ''
# Второй рубеж: даже без исключения ноль выполненных проверок означает, что тест ничего
# не проверил, и молчать об этом нельзя.
if (($script:pass + $script:fail) -eq 0) {
  Write-Host 'СБОЙ ХАРНЕССА: не выполнено НИ ОДНОЙ проверки' -ForegroundColor Red
  exit 1
}
if ($script:fail) { Write-Host ("итого: pass=$($script:pass) fail=$($script:fail)") -ForegroundColor Red; $script:failed | ForEach-Object { Write-Host "  - $_" } ; exit 1 }
Write-Host ("итого: pass=$($script:pass) fail=$($script:fail)")
exit 0
