#!/usr/bin/env bash
# live_tick.sh - one LIVE tick under systemd timer (flock is applied by the unit).
# Philosophy: exchange safety NEVER depends on git. A failed pull/push only delays
# state publication; the engine always runs against local state (authoritative for live_real).
set -u
cd "$(dirname "$0")/.."

# 1) pull: receive HALT/HALT_CLOSE files and paper-side updates; never block the tick
if ! git pull --rebase --autostash origin main >/dev/null 2>&1; then
  git rebase --abort >/dev/null 2>&1 || true
  echo "WARN: git pull failed - tick continues on local state" >&2
fi

# 2) the engine (DryRun is controlled by LIVE_DRYRUN in /etc/trading-live.env)
pwsh -NoProfile -File tools/live_engine.ps1
rc=$?
if [ $rc -ne 0 ]; then echo "WARN: live_engine exited rc=$rc" >&2; fi

# 3) push policy: immediately on events (.push_now), otherwise on 15-minute marks
minute=$(date -u +%M)
push_due=0
if [ -f data/live_real/.push_now ]; then push_due=1; rm -f data/live_real/.push_now; fi
if [ $((10#$minute % 15)) -eq 0 ]; then push_due=1; fi

if [ "$push_due" -eq 1 ]; then
  # explicit paths ONLY - never 'git add data' (paper files belong to Actions)
  git add data/live_real journal_live.md 2>/dev/null
  if ! git diff --cached --quiet 2>/dev/null; then
    git -c user.name='live-desk-bot' -c user.email='live-desk-bot@users.noreply.github.com' \
      commit -m "live tick $(date -u '+%Y-%m-%d %H:%M') UTC" >/dev/null
    if ! git push origin main >/dev/null 2>&1; then
      git fetch origin >/dev/null 2>&1 && git rebase origin/main >/dev/null 2>&1 && git push origin main >/dev/null 2>&1 \
        || echo "WARN: git push failed - state will retry next tick" >&2
    fi
  fi
fi
exit 0
