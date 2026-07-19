# ask.ps1 - терминальный клиент AI-ассистента paper-desk.
#
# Тонкая обёртка над ssh: вся логика и все ключи живут на VPS. На ноуте не
# хранится ни OpenRouter-ключ, ни токен Telegram, и видны ЖИВЫЕ логи, которых
# в git-репо нет вообще (они в .gitignore).
#
#   .\tools\ask.ps1 "что с ботом"
#   .\tools\ask.ps1 -Interactive
#   .\tools\ask.ps1 -Snapshot                 # состояние без модели, бесплатно
#   .\tools\ask.ps1 -Logs rf -Lines 80        # сырой хвост лога, без модели
#
# Адрес VPS берётся из $env:ASSISTANT_VPS ("trader@1.2.3.4") или из
# tools/ask.config.json: { "vps": "trader@host", "key": "C:\\path\\to\\id_ed25519" }

[CmdletBinding()]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Question,
  [switch]$Interactive,
  [switch]$Snapshot,
  [ValidateSet('rf', 'crypto', 'assistant')]
  [string]$Logs,
  [int]$Lines = 60,
  [switch]$Reset
)

$ErrorActionPreference = 'Stop'
# Консоль Windows по умолчанию cp1251 и рвёт кириллицу с VPS.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$OutputEncoding = [Text.UTF8Encoding]::new()

$RepoRoot = Split-Path -Parent $PSScriptRoot
$RemoteDir = '/home/trader/paper-desk'

# --- адрес VPS ---------------------------------------------------------------
$vps = $env:ASSISTANT_VPS
$key = $env:ASSISTANT_VPS_KEY
$cfgPath = Join-Path $PSScriptRoot 'ask.config.json'
if (-not $vps -and (Test-Path $cfgPath)) {
  $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $vps = $cfg.vps
  if ($cfg.PSObject.Properties.Name -contains 'key') { $key = $cfg.key }
}
if (-not $vps) {
  Write-Error @'
Не задан адрес VPS. Любой из вариантов:
  $env:ASSISTANT_VPS = "trader@1.2.3.4"
или файл tools\ask.config.json (он в .gitignore):
  { "vps": "trader@1.2.3.4", "key": "C:\\Users\\klyde\\.ssh\\id_ed25519" }
'@
}

$sshArgs = @('-o', 'ConnectTimeout=10', '-o', 'BatchMode=yes')
if ($key) { $sshArgs += @('-i', $key) }

function Invoke-Remote {
  param([string]$RemoteCmd, [string]$StdinText)
  $full = $sshArgs + @($vps, $RemoteCmd)
  if ($null -ne $StdinText) {
    # Вопрос идёт через stdin, а не в argv: тройное экранирование
    # PowerShell -> ssh -> bash на кириллице с кавычками неизбежно ломается.
    $StdinText | & ssh @full
  } else {
    & ssh @full
  }
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "ssh вернул код $LASTEXITCODE"
  }
}

# --- быстрые пути без модели -------------------------------------------------
if ($Logs) {
  $path = switch ($Logs) {
    'rf'     { "$RemoteDir/data/live_rf/tick_log.txt" }
    'crypto' { "$RemoteDir/data/live_real/tick_log.txt" }
    'assistant' { $null }
  }
  if ($Logs -eq 'assistant') {
    Invoke-Remote "journalctl -u trading-assistant -n $Lines --no-pager -o short-iso"
  } else {
    Invoke-Remote "tail -n $Lines '$path'"
  }
  return
}

$py = "cd $RemoteDir && LC_ALL=C.UTF-8 python3 -m assistant.cli"

if ($Snapshot) { Invoke-Remote "$py --snapshot"; return }
if ($Reset)    { Invoke-Remote "$py --reset";    return }

if ($Interactive) {
  # -t нужен для нормального REPL с приглашением ввода
  & ssh @($sshArgs + @('-t', $vps, "$py --repl"))
  return
}

$q = ($Question -join ' ').Trim()
if (-not $q) {
  Write-Host 'Использование: .\tools\ask.ps1 "что с ботом"' -ForegroundColor Yellow
  Write-Host '               .\tools\ask.ps1 -Interactive'
  Write-Host '               .\tools\ask.ps1 -Snapshot'
  Write-Host '               .\tools\ask.ps1 -Logs rf -Lines 80'
  return
}

Invoke-Remote "$py --stdin" $q
