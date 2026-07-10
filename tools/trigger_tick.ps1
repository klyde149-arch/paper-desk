# trigger_tick.ps1 - backup dispatcher: fires the cloud tick workflow via GitHub API.
# GitHub cron for fresh workflows can lag hours/days; this local scheduled task guarantees
# ticks while the laptop is on. Execution still happens ONLY in the cloud (no dual writers;
# workflow concurrency group serializes runs). Token comes from Git Credential Manager.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
  # git credential fill через Git Bash: пайп из PS 5.1 в git ломает парсинг строк
  $bash = 'C:\Program Files\Git\bin\bash.exe'
  if (-not (Test-Path $bash)) { $bash = 'C:\Program Files (x86)\Git\bin\bash.exe' }
  $tok = & $bash -c "printf 'protocol=https\nhost=github.com\n\n' | git credential fill | grep '^password=' | cut -d= -f2"
  $tok = "$tok".Trim()
  if (-not $tok) { throw 'no token from GCM' }
  $hdr = @{ Authorization = "Bearer $tok"; Accept = 'application/vnd.github+json' }
  # если workflow уже бежит/в очереди - не плодить
  $act = Invoke-RestMethod -Uri 'https://api.github.com/repos/klyde149-arch/paper-desk/actions/runs?status=in_progress&per_page=1' -Headers $hdr -TimeoutSec 20
  $qd  = Invoke-RestMethod -Uri 'https://api.github.com/repos/klyde149-arch/paper-desk/actions/runs?status=queued&per_page=1' -Headers $hdr -TimeoutSec 20
  if ([int]$act.total_count -gt 0 -or [int]$qd.total_count -gt 0) { 'tick already running/queued - skip'; return }
  Invoke-RestMethod -Method Post -Uri 'https://api.github.com/repos/klyde149-arch/paper-desk/actions/workflows/tick.yml/dispatches' `
    -Headers $hdr -Body '{"ref":"main"}' -ContentType 'application/json' -TimeoutSec 20 | Out-Null
  "dispatched $((Get-Date).ToUniversalTime().ToString('HH:mm')) UTC"
} catch {
  "trigger failed: $($_.Exception.Message)"
}
