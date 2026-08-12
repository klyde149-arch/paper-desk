# lib_alerts.ps1 - Telegram alerts for the live executor. Dot-source. Messages are UTF-8 (Cyrillic ok).
# Env: TG_BOT_TOKEN, TG_CHAT_ID. An alert failure must NEVER block trading:
# every path is try/catch and returns $false instead of throwing.
# Optional -Chat overrides the default TG_CHAT_ID (used to fan-out RF-LIVE futures
# alerts to a second recipient via TG_CHAT_ID_FUT; crypto keeps the no-arg default).

# NOTE: this file is ASCII-only and carries NO BOM. Do not put Cyrillic here - PS 5.1 (which
# runs live_watch.ps1 in GitHub Actions) would fail to parse a BOM-less UTF-8 file and the
# whole watchdog would die on dot-source. Russian wording belongs in the callers.
#
# After a call, $script:TgLastError holds the reason for a $false, or is empty. Callers need to
# tell "no credentials" from "Telegram rejected the token" from "rejected the chat_id" - during
# the 2026-08-11 incident that distinction cost several rounds of blind guessing.
function Send-TgAlert([string]$Text, [string]$Chat = '') {
  $script:TgLastError = ''
  $tok = $env:TG_BOT_TOKEN
  $chat = if ($Chat) { $Chat } else { $env:TG_CHAT_ID }
  if (-not $tok) { $script:TgLastError = 'TG_BOT_TOKEN is empty'; return $false }
  if (-not $chat) { $script:TgLastError = 'chat_id is empty'; return $false }
  try {
    $body = @{ chat_id = $chat; text = $Text; disable_web_page_preview = 'true' }
    Invoke-RestMethod -Uri "https://api.telegram.org/bot$tok/sendMessage" -Method Post -Body $body -TimeoutSec 15 | Out-Null
    return $true
  } catch {
    # Status code and Telegram's own description ONLY. The full exception text carries the URL,
    # and the URL carries the token - it must not reach any log (Actions masks secrets, the
    # VPS journald does not). 401 = bad token, 400 "chat not found" = bad chat_id.
    $code = ''; $desc = ''
    try { $code = [int]$_.Exception.Response.StatusCode } catch {}
    try { $desc = ([string]$_.ErrorDetails.Message | ConvertFrom-Json).description } catch {}
    $script:TgLastError = if ($code -or $desc) { ('HTTP {0} {1}' -f $code, $desc).Trim() } else { 'network unreachable' }
    Write-Warning "tg alert failed: $script:TgLastError"
    return $false
  }
}
