# lib_alerts.ps1 - Telegram alerts for the live executor. Dot-source. Messages are UTF-8 (Cyrillic ok).
# Env: TG_BOT_TOKEN, TG_CHAT_ID. An alert failure must NEVER block trading:
# every path is try/catch and returns $false instead of throwing.
# Optional -Chat overrides the default TG_CHAT_ID (used to fan-out RF-LIVE futures
# alerts to a second recipient via TG_CHAT_ID_FUT; crypto keeps the no-arg default).

function Send-TgAlert([string]$Text, [string]$Chat = '') {
  $tok = $env:TG_BOT_TOKEN
  $chat = if ($Chat) { $Chat } else { $env:TG_CHAT_ID }
  if (-not $tok -or -not $chat) { return $false }
  try {
    $body = @{ chat_id = $chat; text = $Text; disable_web_page_preview = 'true' }
    Invoke-RestMethod -Uri "https://api.telegram.org/bot$tok/sendMessage" -Method Post -Body $body -TimeoutSec 15 | Out-Null
    return $true
  } catch {
    Write-Warning "tg alert failed: $($_.Exception.Message)"
    return $false
  }
}
