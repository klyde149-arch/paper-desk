# git_sync_watch.sh - detect when a VPS tick stops PUBLISHING state to GitHub, and
# alert to Telegram. Dot-sourced by live_tick.sh / live_rf_tick.sh. Pure bash + curl.
#
# Philosophy mirror of the tick scripts: this NEVER fails the tick. Every path is
# guarded and returns 0; a broken alert must not affect trading. Trading safety does
# not depend on git, and observability of git must not depend on trading either.
#
# Health of a tick = (git pull succeeded) AND (local HEAD is not ahead of origin/main).
# This single signal catches both failure modes that make the dashboard go stale:
#   - stuck pull  -> pull_ok=0                       -> unhealthy
#   - stuck push  -> local commits pile up, ahead>0  -> unhealthy
# In a normal tick nothing is committed between the 15-min push marks, so HEAD does
# not move and ahead==0 -> healthy (no false alarms while waiting to publish).
#
# Env (from /etc/trading-live.env via systemd EnvironmentFile):
#   TG_BOT_TOKEN, TG_CHAT_ID   - Telegram creds (empty -> alerts are silent no-ops)
#   GIT_ALERT_AFTER_MIN=30     - minutes of stalled publication before the first alert
#   GIT_ALERT_REPEAT_MIN=120   - minutes between reminder alerts while still stalled

# Send one Telegram message. Mirror of Send-TgAlert in tools/lib_alerts.ps1.
# Never throws, never blocks the tick (|| true, bounded timeout, silent on missing creds).
tg_alert() {
  [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ] || return 0
  curl -sS --max-time 15 \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=$1" \
    --data-urlencode "disable_web_page_preview=true" \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" >/dev/null 2>&1 || true
  return 0
}

# git_sync_watch <label> <state_file> <pull_ok:0|1> [unit]
#   label      - human tag for the alert text, e.g. "LIVE Bybit"
#   state_file - gitignored file under the contour's data dir; holds the fault timer
#   pull_ok    - 1 if `git pull` succeeded this tick, 0 otherwise
#   unit       - systemd unit for the "journalctl -u" hint (default: live-tick)
git_sync_watch() {
  local label="$1" state_file="$2" pull_ok="$3" unit="${4:-live-tick}"
  local after="${GIT_ALERT_AFTER_MIN:-30}" repeat="${GIT_ALERT_REPEAT_MIN:-120}"
  local now ahead healthy
  now=$(date -u +%s)

  # HEAD ahead of origin/main? (origin/main is fresh after a successful pull's fetch.)
  # On any git error, treat as ahead (999) so we fail toward "unhealthy", never hide a fault.
  ahead=$(git rev-list --count origin/main..HEAD 2>/dev/null) || ahead=999
  case "$ahead" in ''|*[!0-9]*) ahead=999 ;; esac

  healthy=0
  [ "$pull_ok" = "1" ] && [ "$ahead" = "0" ] && healthy=1

  # Load prior fault state (KEY=VALUE lines). Absent file => no fault in progress.
  local BAD_SINCE='' ALERTED=0 LAST_MSG=0
  if [ -f "$state_file" ]; then
    # shellcheck disable=SC1090
    . "$state_file" 2>/dev/null || { BAD_SINCE=''; ALERTED=0; LAST_MSG=0; }
  fi

  if [ "$healthy" = "1" ]; then
    if [ -n "$BAD_SINCE" ]; then
      if [ "$ALERTED" = "1" ]; then
        local mins=$(( (now - BAD_SINCE) / 60 ))
        tg_alert "$label: публикация данных на дашборд восстановлена, данные снова актуальны (простой был около ${mins} мин)."
      fi
      rm -f "$state_file" 2>/dev/null || true
    fi
    return 0
  fi

  # Unhealthy: start or continue the fault timer.
  if [ -z "$BAD_SINCE" ]; then
    BAD_SINCE=$now
  fi
  local elapsed_min=$(( (now - BAD_SINCE) / 60 ))

  if [ "$ALERTED" != "1" ]; then
    if [ "$elapsed_min" -ge "$after" ]; then
      tg_alert "$label: данные не публикуются на дашборд уже больше ${elapsed_min} мин. Дашборд устарел, но торговля идёт на локальном состоянии (защитные стоп-заявки стоят на бирже). Диагностика: journalctl -u ${unit}."
      ALERTED=1
      LAST_MSG=$now
    fi
  else
    if [ $(( (now - LAST_MSG) / 60 )) -ge "$repeat" ]; then
      tg_alert "$label: данные всё ещё не публикуются на дашборд (${elapsed_min} мин)."
      LAST_MSG=$now
    fi
  fi

  # Persist fault state atomically (tmp + mv) so a torn read next tick can't corrupt it.
  {
    echo "BAD_SINCE=$BAD_SINCE"
    echo "ALERTED=$ALERTED"
    echo "LAST_MSG=$LAST_MSG"
  } > "${state_file}.tmp" 2>/dev/null && mv -f "${state_file}.tmp" "$state_file" 2>/dev/null || true
  return 0
}
