#!/usr/bin/env bash
# Bybit entry point; all shared transport/watchdog mechanics live in lib_tick.sh.
set -u
source "$(dirname "$0")/lib_tick.sh"
tick_init || exit 0
tick_pull
tick_engine "tools/live_engine.ps1" "Крипта (Bybit)" "data/live_real/.engine_watch_state" "live-tick"

minute=$(date -u +%M)
push_due=0
if [ -f data/live_real/.push_now ]; then push_due=1; rm -f data/live_real/.push_now; fi
if [ $((10#$minute % 15)) -eq 0 ]; then push_due=1; fi
if [ "$push_due" -eq 1 ]; then
  paths=(data/live_real)
  [ -f journal_live.md ] && paths+=(journal_live.md)
  tick_commit_paths "live tick $(date -u '+%Y-%m-%d %H:%M') UTC" "${paths[@]}" || true
fi

tick_finish "Крипта (Bybit)" "data/live_real/.git_sync_state" "live-tick"
exit 0
