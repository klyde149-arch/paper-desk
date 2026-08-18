#!/usr/bin/env bash
# T-Invest RF entry point; all shared transport/watchdog mechanics live in lib_tick.sh.
set -u
source "$(dirname "$0")/lib_tick.sh"
tick_init || exit 0
tick_pull
tick_engine "tools/live_rf_engine.ps1" "Фьючерсы (Т-Инвест)" "data/live_rf/.engine_watch_state" "live-rf-tick"

# Snapshot is presentation data, never part of the money path. Full broker candle baking
# remains bounded to the existing 15-minute schedule below.
pwsh -NoProfile -File tools/bake_rf_candles.ps1 -SnapshotOnly >/dev/null 2>&1 || echo "WARN: rf presentation snapshot failed" >&2

if [ -n "$(git status --porcelain -- data/rf/manual_close_req.json 2>/dev/null)" ]; then
  tick_commit_paths "manual-close request $(date -u '+%Y-%m-%d %H:%M') UTC" data/rf/manual_close_req.json || true
fi

minute=$(date -u +%M)
if [ $((10#$minute % 15)) -eq 0 ]; then
  pwsh -NoProfile -File tools/bake_rf_candles.ps1 >/dev/null 2>&1 || echo "WARN: bake_rf_candles failed" >&2
  paths=(data/live_rf data/rf_presentation_snapshot.json)
  [ -f journal_live_rf.md ] && paths+=(journal_live_rf.md)
  tick_commit_paths "rf-live tick $(date -u '+%Y-%m-%d %H:%M') UTC" "${paths[@]}" || true
fi

tick_finish "Фьючерсы (Т-Инвест)" "data/live_rf/.git_sync_state" "live-rf-tick"
exit 0
