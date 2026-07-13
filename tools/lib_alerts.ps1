# lib_alerts.ps1 - Telegram alerts for the live executor. Dot-source. ASCII only.
# Env: TG_BOT_TOKEN, TG_CHAT_ID. An alert failure must NEVER block trading:
# every path is try/catch and returns $false instead of throwing.

function Send-TgAlert([string]$Text) {
  $tok = $env:TG_BOT_TOKEN; $chat = $env:TG_CHAT_ID
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
