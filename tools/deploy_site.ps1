# Пушит локальные изменения проекта в GitHub (repo = klyde149-arch/paper-desk, корень = trading-sim).
# Публикация сайта происходит АВТОМАТИЧЕСКИ: пуш в main триггерит workflow tick.yml,
# который прогоняет тик, пересобирает vizdata и деплоит report\ на GitHub Pages.
# Перед работой в локальной сессии: git pull (облачный бот коммитит состояние каждые ~15 мин).
$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
Push-Location $repo
try {
  git pull --rebase -q origin main 2>&1 | Out-Null
  git add -A 2>&1 | Out-Null
  $changed = git status --porcelain
  if (-not $changed) { "deploy: nothing changed"; return }
  $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')
  git commit -q -m "local session $stamp UTC" 2>&1 | Out-Null
  git push -q origin main 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) { "deploy: pushed ($stamp UTC) -> workflow опубликует Pages" }
  else { "deploy: push FAILED (exit $LASTEXITCODE) - проверь auth/конфликты" }
} finally { Pop-Location }
