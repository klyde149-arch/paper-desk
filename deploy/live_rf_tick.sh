#!/usr/bin/env bash
# live_rf_tick.sh - one RF-LIVE tick (T-Invest, C3b) under systemd timer (flock is applied by the unit).
# Philosophy (same as live_tick.sh): broker safety NEVER depends on git. A failed pull/push only
# delays state publication; the engine always runs against local state (authoritative for live_rf).
set -u
cd "$(dirname "$0")/.."
. "$(dirname "$0")/git_sync_watch.sh"

# 1) pull: receive HALT/HALT_RF_* files and paper-side updates; never block the tick
commit_failed=0
pull_ok=1
if ! git pull --rebase --autostash origin main >/dev/null 2>&1; then
  git rebase --abort >/dev/null 2>&1 || true
  echo "WARN: git pull failed - tick continues on local state" >&2
  pull_ok=0
fi

# 2) the engine (mode is controlled by TINVEST_MODE in /etc/trading-live.env: dryrun|sandbox|prod)
pwsh -NoProfile -File tools/live_rf_engine.ps1
engine_rc=$?
if [ $engine_rc -ne 0 ]; then echo "WARN: live_rf_engine exited rc=$engine_rc" >&2; fi
# Немедленный сигнал вместо ожидания, пока внешний live_watch.ps1 заметит несвежие снимки
# (до часа). Тик по-прежнему не роняем - меняется только наблюдаемость.
engine_watch "Фьючерсы (Т-Инвест)" "data/live_rf/.engine_watch_state" "$engine_rc" "live-rf-tick"

# 2b) manual-close fast-path: заявка оператора из TG-ассистента не должна ждать
# 15-минутной отметки. Файл пишет ТОЛЬКО ассистент на этой VPS, движок Actions его
# не модифицирует - конфликтов по нему не бывает. Push триггерит tick.yml (on: push).
if [ -n "$(git status --porcelain -- data/rf/manual_close_req.json 2>/dev/null)" ]; then
  git add data/rf/manual_close_req.json
  if git -c user.name='live-desk-bot' -c user.email='live-desk-bot@users.noreply.github.com' \
      commit -m "manual-close request $(date -u '+%Y-%m-%d %H:%M') UTC" >/dev/null 2>&1; then
    if ! git push origin main >/dev/null 2>&1; then
      git fetch origin >/dev/null 2>&1 && git rebase origin/main >/dev/null 2>&1 && git push origin main >/dev/null 2>&1 \
        || echo "WARN: manual-close push failed - retry next tick" >&2
    fi
  fi
fi

# 3) push policy: on 15-minute marks; explicit paths ONLY - never 'git add data'
# (paper files belong to Actions, data/live_real belongs to the Bybit contour)
minute=$(date -u +%M)
if [ $((10#$minute % 15)) -eq 0 ]; then
  # bake T-Invest candles for the dashboard charts (readonly; never fails the tick)
  pwsh -NoProfile -File tools/bake_rf_candles.ps1 >/dev/null 2>&1 || echo "WARN: bake_rf_candles failed" >&2
  git add data/live_rf 2>/dev/null
  [ -f journal_live_rf.md ] && git add journal_live_rf.md
  if ! git diff --cached --quiet 2>/dev/null; then
    if ! git -c user.name='live-desk-bot' -c user.email='live-desk-bot@users.noreply.github.com' \
        commit -m "rf-live tick $(date -u '+%Y-%m-%d %H:%M') UTC" >/dev/null; then
      # Провал коммита нельзя молчать: следующий push будет no-op с кодом 0, ahead=0, и
      # git_sync_watch объявит контур здоровым при грязных неопубликованных файлах.
      echo "WARN: rf-live commit failed - состояние осталось незакоммиченным" >&2
      commit_failed=1
    fi
    if ! git push origin main >/dev/null 2>&1; then
      git fetch origin >/dev/null 2>&1 && git rebase origin/main >/dev/null 2>&1 && git push origin main >/dev/null 2>&1 \
        || echo "WARN: git push failed - state will retry next tick" >&2
    fi
  fi
fi

# 4) publication watchdog: alert to Telegram if our state stops reaching GitHub.
# Never fails the tick; state timer is gitignored and local to this VPS.
git_sync_watch "Фьючерсы (Т-Инвест)" "data/live_rf/.git_sync_state" "$pull_ok" "live-rf-tick" "$((1-commit_failed))"

# 5) disk watchdog: state file is shared with live_tick.sh (same host disk); the two
# ticks are offset by 30s (this one runs on :30) so writes never collide.
disk_watch "data/.disk_watch_state"

# 6) Actions-liveness watchdog: state file is shared with live_tick.sh (one thing to
# watch - GitHub Actions - same 30s offset avoids a write collision).
actions_watch "data/.actions_watch_state"
exit 0
