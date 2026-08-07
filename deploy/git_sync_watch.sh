# git_sync_watch.sh - tick-side watchdogs for the VPS host. Three independent guards live
# here: git_sync_watch (state stops PUBLISHING to GitHub), disk_watch (disk fills up) and
# actions_watch (GitHub Actions itself stops running). Dot-sourced by live_tick.sh /
# live_rf_tick.sh. Pure bash + curl.
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
# Incident 2026-08-07 (disk): the VPS disk filled up and silently stopped both contours
# (git could not write objects, the engine could not persist portfolio.json). Nothing was
# watching disk usage, so it was discovered only once trading had already stopped.
# disk_watch() closes that gap the same way: a state-machine watchdog called every tick.
#
# Incident 2026-08-06/07 (actions): GitHub Actions' tick.yml got stuck - jobs 'waiting'
# behind the github-pages environment approval gate, then queued behind each other via
# concurrency - and stopped producing runs for 17.5h. The VPS host and both live engines
# were perfectly healthy throughout: git_sync_watch/disk_watch saw nothing wrong, because
# the fault was entirely on GitHub's side. Paper trading was silently halted (its only
# tick lives in Actions) and the public dashboard (report/vizdata.js, rebuilt only by
# Actions) froze - including the "Фьючерсы -> Реал" tab, even though RF-live itself kept
# trading fine on the VPS. actions_watch() closes that blind spot: it watches Actions'
# own heartbeat from the VPS side, the one vantage point that isn't Actions itself.
#
# Env (from /etc/trading-live.env via systemd EnvironmentFile):
#   TG_BOT_TOKEN, TG_CHAT_ID     - Telegram creds (empty -> alerts are silent no-ops)
#   TG_CHAT_ID_FUT               - second recipient, fanned out by actions_watch too:
#                                   it also freezes the futures real-money dashboard tab
#   GIT_ALERT_AFTER_MIN=30       - minutes of stalled publication before the first alert
#   GIT_ALERT_REPEAT_MIN=120     - minutes between reminder alerts while still stalled
#   DISK_WARN_PCT=85             - % used on / that first triggers a disk alert
#   DISK_ALERT_REPEAT_MIN=180    - minutes between reminder alerts while still over threshold
#   ACTIONS_ALERT_AFTER_MIN=60   - minutes of Actions silence before the first alert
#   ACTIONS_ALERT_REPEAT_MIN=120 - minutes between reminder alerts while still silent

# Send one Telegram message. Mirror of Send-TgAlert in tools/lib_alerts.ps1.
# Never throws, never blocks the tick (|| true, bounded timeout, silent on missing creds).
# chat - optional override (defaults to TG_CHAT_ID); lets a caller fan out to a second
# recipient (TG_CHAT_ID_FUT), same convention as Send-TgAlert -Chat in lib_alerts.ps1.
tg_alert() {
  local chat="${2:-${TG_CHAT_ID:-}}"
  [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "$chat" ] || return 0
  curl -sS --max-time 15 \
    --data-urlencode "chat_id=${chat}" \
    --data-urlencode "text=$1" \
    --data-urlencode "disable_web_page_preview=true" \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" >/dev/null 2>&1 || true
  return 0
}

# Fan-out helper: default chat + TG_CHAT_ID_FUT if set. Both freeze together when
# Actions stops (paper AND the futures real-money tab both go stale), so both hear it.
tg_alert_all() {
  tg_alert "$1"
  [ -n "${TG_CHAT_ID_FUT:-}" ] && tg_alert "$1" "$TG_CHAT_ID_FUT"
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

# disk_watch <state_file>
#   state_file - ONE shared gitignored file (not per-contour: both tick call this on the
#                same host disk, and a shared state avoids a duplicate alert per contour)
#
# Same state-machine shape as git_sync_watch: warn once past DISK_WARN_PCT, remind every
# DISK_ALERT_REPEAT_MIN while still over, announce recovery once back under threshold.
disk_watch() {
  local state_file="$1"
  local warn="${DISK_WARN_PCT:-85}" repeat="${DISK_ALERT_REPEAT_MIN:-180}"
  local now used_pct avail_h healthy
  now=$(date -u +%s)

  # df -P for portable single-line output; second data line, 5th field is "Use%" (e.g. "87%").
  used_pct=$(df -P / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}') || used_pct=100
  case "$used_pct" in ''|*[!0-9]*) used_pct=100 ;; esac
  avail_h=$(df -h / 2>/dev/null | awk 'NR==2 {print $4}')
  [ -n "$avail_h" ] || avail_h='?'

  healthy=1
  [ "$used_pct" -ge "$warn" ] && healthy=0

  local BAD_SINCE='' ALERTED=0 LAST_MSG=0
  if [ -f "$state_file" ]; then
    # shellcheck disable=SC1090
    . "$state_file" 2>/dev/null || { BAD_SINCE=''; ALERTED=0; LAST_MSG=0; }
  fi

  if [ "$healthy" = "1" ]; then
    if [ -n "$BAD_SINCE" ]; then
      if [ "$ALERTED" = "1" ]; then
        tg_alert "VPS: диск в норме (занято ${used_pct}%, свободно ${avail_h})."
      fi
      rm -f "$state_file" 2>/dev/null || true
    fi
    return 0
  fi

  if [ -z "$BAD_SINCE" ]; then
    BAD_SINCE=$now
  fi

  if [ "$ALERTED" != "1" ]; then
    tg_alert "VPS: диск занят ${used_pct}% (свободно ${avail_h}). Торговля пока идёт, но при 100% встанут git и запись состояния. Проверь: sudo systemctl start vps-cleanup.service"
    ALERTED=1
    LAST_MSG=$now
  else
    if [ $(( (now - LAST_MSG) / 60 )) -ge "$repeat" ]; then
      tg_alert "VPS: диск всё ещё занят ${used_pct}% (свободно ${avail_h})."
      LAST_MSG=$now
    fi
  fi

  {
    echo "BAD_SINCE=$BAD_SINCE"
    echo "ALERTED=$ALERTED"
    echo "LAST_MSG=$LAST_MSG"
  } > "${state_file}.tmp" 2>/dev/null && mv -f "${state_file}.tmp" "$state_file" 2>/dev/null || true
  return 0
}

# actions_watch <state_file>
#   state_file - ONE shared gitignored file (not per-contour: GitHub Actions publishing
#                is a single thing to watch, and it's the only side that runs there - see
#                header comment for the 2026-08-06/07 incident this closes)
#
# Signal: age of the newest point's "utc" field in data/live_equity.json, written ONLY by
# GitHub Actions (tools/auto_trade.ps1 via .github/workflows/tick.yml) every ~15 min. Stale
# past ACTIONS_ALERT_AFTER_MIN means Actions itself has stopped producing runs - a failure
# this VPS cannot see any other way, since git_sync_watch only checks OUR OWN publication
# and disk_watch only checks OUR OWN disk. Same state-machine shape as those two: warn once
# past the threshold, remind every ACTIONS_ALERT_REPEAT_MIN while still stale, announce
# recovery once fresh again. Fans out to both Telegram recipients (tg_alert_all): a stuck
# Actions freezes the paper dashboard AND the futures real-money tab at once.
actions_watch() {
  local state_file="$1"
  local after="${ACTIONS_ALERT_AFTER_MIN:-60}" repeat="${ACTIONS_ALERT_REPEAT_MIN:-120}"
  local now last_utc last_ts age_min healthy

  now=$(date -u +%s)
  # last "utc" field in the array, e.g. "2026-08-06 15:58" (space-separated, always UTC).
  last_utc=$(grep -o '"utc":[[:space:]]*"[^"]*"' data/live_equity.json 2>/dev/null | tail -1 | sed -E 's/.*"([^"]*)"$/\1/')
  last_ts=''
  [ -n "$last_utc" ] && last_ts=$(date -u -d "$last_utc" +%s 2>/dev/null)

  healthy=0
  if [ -n "$last_ts" ]; then
    age_min=$(( (now - last_ts) / 60 ))
    [ "$age_min" -lt "$after" ] && healthy=1
  fi
  [ -n "$last_utc" ] || last_utc='неизвестно'

  local BAD_SINCE='' ALERTED=0 LAST_MSG=0
  if [ -f "$state_file" ]; then
    # shellcheck disable=SC1090
    . "$state_file" 2>/dev/null || { BAD_SINCE=''; ALERTED=0; LAST_MSG=0; }
  fi

  if [ "$healthy" = "1" ]; then
    if [ -n "$BAD_SINCE" ]; then
      if [ "$ALERTED" = "1" ]; then
        tg_alert_all "GitHub Actions: тик снова публикует данные (последняя точка ${last_utc} UTC). Бумажная торговля и дашборд восстановлены."
      fi
      rm -f "$state_file" 2>/dev/null || true
    fi
    return 0
  fi

  if [ -z "$BAD_SINCE" ]; then
    BAD_SINCE=$now
  fi
  local elapsed_min=$(( (now - BAD_SINCE) / 60 ))

  if [ "$ALERTED" != "1" ]; then
    tg_alert_all "GitHub Actions: тик не публикует данные уже больше ${elapsed_min} мин (последняя точка ${last_utc} UTC). Бумажная торговля и дашборд, вероятно, встали - боевые контуры на VPS это не затрагивает. Проверь https://github.com/klyde149-arch/paper-desk/actions (частая причина - завис approval у окружения github-pages)."
    ALERTED=1
    LAST_MSG=$now
  else
    if [ $(( (now - LAST_MSG) / 60 )) -ge "$repeat" ]; then
      tg_alert_all "GitHub Actions: тик всё ещё не публикует данные (${elapsed_min} мин, последняя точка ${last_utc} UTC)."
      LAST_MSG=$now
    fi
  fi

  {
    echo "BAD_SINCE=$BAD_SINCE"
    echo "ALERTED=$ALERTED"
    echo "LAST_MSG=$LAST_MSG"
  } > "${state_file}.tmp" 2>/dev/null && mv -f "${state_file}.tmp" "$state_file" 2>/dev/null || true
  return 0
}
