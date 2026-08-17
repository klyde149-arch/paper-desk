# test_commit_state.ps1 - тесты tools\commit_state.ps1 на черновых репозиториях.
# Запуск: powershell -File tools\test_commit_state.ps1
#
# Смысл: ветка «гонка проиграна» в проде наступает случайно (17.08 - 8 раз за 2 часа), и
# ждать её, чтобы проверить фикс, нельзя. Здесь гонка ставится руками: второй клон пушит
# первым, наш клон получает отказ.
#
# КЛЮЧЕВАЯ ДЕТАЛЬ: скрипт вызывается ДОЧЕРНИМ процессом `powershell.exe -File`, ровно как
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

# Черновая сцена: bare-remote + наш клон + клон «второго писателя».
function New-Scene {
  $dir = Join-Path ([IO.Path]::GetTempPath()) ("cs_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $remote = Join-Path $dir 'remote.git'; $work = Join-Path $dir 'work'; $other = Join-Path $dir 'other'
  New-Item -ItemType Directory -Path $dir | Out-Null
  gitq init --bare -b main $remote
  gitq clone $remote $work
  Push-Location $work
  gitq config user.name 'seed'; gitq config user.email 'seed@example.com'
  Set-Content -Path 'portfolio.json' -Value '{"seed":1}' -Encoding utf8
  New-Item -ItemType Directory -Path 'data' | Out-Null
  Set-Content -Path 'data/state.json' -Value '{"seed":1}' -Encoding utf8
  Set-Content -Path 'journal.md' -Value "seed`n" -Encoding utf8
  gitq add -A; gitq commit -q -m seed; gitq push -q origin main
  Pop-Location
  gitq clone $remote $other
  return [pscustomobject]@{ Dir = $dir; Remote = $remote; Work = $work; Other = $other }
}

# Вызов ровно как в Actions: дочерний powershell.exe -File, наружу отдаём его код.
function Invoke-CommitState([string]$WorkDir, [string[]]$Paths, [string]$Label) {
  Push-Location $WorkDir
  try {
    $joined = $Paths -join ','
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script `
      -Path $joined -Label $Label -NoDelay 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
  } finally { Pop-Location }
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
  Set-Content -Path (Join-Path $s.Work 'portfolio.json') -Value '{"tick":1}' -Encoding utf8
  $r = Invoke-CommitState $s.Work @('portfolio.json', 'journal.md', 'data') 'tick'
  Check 'чистый пуш: exit 0' ($r.Code -eq 0)
  Check 'чистый пуш: коммит на remote' ((Remote-Log $s.Remote) -match 'tick \d{4}-\d{2}-\d{2}')

  # ---- 2. гонка выиграна: чужой коммит в ДРУГОЙ файл, rebase сходится ----
  Write-Host '== 2. гонка выиграна (rebase сходится) =='
  $s = New-Scene; $scenes += $s
  Push-Location $s.Other
  gitq config user.name 'other'; gitq config user.email 'other@example.com'
  Set-Content -Path 'journal.md' -Value "other wins`n" -Encoding utf8
  gitq add -A; gitq commit -q -m 'other tick'; gitq push -q origin main
  Pop-Location
  Set-Content -Path (Join-Path $s.Work 'portfolio.json') -Value '{"tick":2}' -Encoding utf8
  $r = Invoke-CommitState $s.Work @('portfolio.json', 'journal.md', 'data') 'tick'
  Check 'гонка выиграна: exit 0' ($r.Code -eq 0)
  Check 'гонка выиграна: был отбой пуша' ($r.Text -match 'fetch \+ rebase')
  $log = Remote-Log $s.Remote
  Check 'гонка выиграна: на remote ОБА коммита' (($log -match 'other tick') -and ($log -match 'tick \d{4}'))

  # ---- 3. гонка проиграна: конфликт в ТОТ ЖЕ файл. Это регрессия на сам баг ----
  Write-Host '== 3. гонка проиграна (конфликт, rebase не сходится) =='
  $s = New-Scene; $scenes += $s
  Push-Location $s.Other
  gitq config user.name 'other'; gitq config user.email 'other@example.com'
  Set-Content -Path 'portfolio.json' -Value '{"other":99}' -Encoding utf8
  gitq add -A; gitq commit -q -m 'other conflicting'; gitq push -q origin main
  Pop-Location
  Set-Content -Path (Join-Path $s.Work 'portfolio.json') -Value '{"tick":3}' -Encoding utf8
  $r = Invoke-CommitState $s.Work @('portfolio.json', 'journal.md', 'data') 'tick'
  Check 'гонка проиграна: exit 0 (ран НЕ краснеет)' ($r.Code -eq 0)
  Check 'гонка проиграна: rebase прерван' ($r.Text -match 'abort')
  Check 'гонка проиграна: обещан повтор' ($r.Text -match 'state will retry next tick')
  Check 'гонка проиграна: чужой коммит на remote цел' ((Remote-Log $s.Remote) -match 'other conflicting')
  Push-Location $s.Work
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
  $r = Invoke-CommitState $bare @('portfolio.json') 'tick'
  Check 'не репо: exit НЕ 0' ($r.Code -ne 0)

  # ---- 6. manual-close пишет свой префикс ----
  Write-Host '== 6. префикс manual-close =='
  $s = New-Scene; $scenes += $s
  Set-Content -Path (Join-Path $s.Work 'data/state.json') -Value '{"closed":1}' -Encoding utf8
  $r = Invoke-CommitState $s.Work @('data', 'journal.md') 'manual-close'
  Check 'manual-close: exit 0' ($r.Code -eq 0)
  Check 'manual-close: формат сообщения сохранён' ((Remote-Log $s.Remote) -match 'manual-close \d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC')
}
finally {
  foreach ($s in $scenes) {
    if ($s.Dir -and (Test-Path $s.Dir)) { Remove-Item $s.Dir -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

Write-Host ''
if ($script:fail) { Write-Host ("итого: pass=$($script:pass) fail=$($script:fail)") -ForegroundColor Red; $script:failed | ForEach-Object { Write-Host "  - $_" } ; exit 1 }
Write-Host ("итого: pass=$($script:pass) fail=$($script:fail)")
exit 0
