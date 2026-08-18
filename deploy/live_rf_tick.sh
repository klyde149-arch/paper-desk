#!/usr/bin/env bash
# T-Invest RF entry point; all shared transport/watchdog mechanics live in lib_tick.sh.
set -u
source "$(dirname "$0")/lib_tick.sh"
tick_init || exit 0
tick_pull
tick_engine "tools/live_rf_engine.ps1" "Фьючерсы (Т-Инвест)" "data/live_rf/.engine_watch_state" "live-rf-tick"

# Snapshot is presentation data, never part of the money path: it reads state files that the
# engine has already written, makes no broker calls, and costs ~2s. Full candle baking is NOT
# here - it lives in rf-bake.timer, see the commit block below for why.
pwsh -NoProfile -File tools/bake_rf_candles.ps1 -SnapshotOnly >/dev/null 2>&1 || echo "WARN: rf presentation snapshot failed" >&2

if [ -n "$(git status --porcelain -- data/rf/manual_close_req.json 2>/dev/null)" ]; then
  tick_commit_paths "manual-close request $(date -u '+%Y-%m-%d %H:%M') UTC" data/rf/manual_close_req.json || true
fi

# Publishing the state IS the money path: until this commit lands on origin, the dashboard,
# the Mini App and the external watchdog (tools/live_watch.ps1, runs in Actions) all see a
# frozen contour and cannot tell a stale push from a dead engine.
#
# Nothing slow may stand in front of this block. Incident 2026-08-18: the full candle bake used
# to run here, right before the commit; broker candle latency doubled between 17:15 and 17:47
# UTC, the bake blew the unit's TimeoutStartSec=110, systemd SIGTERMed the tick three marks in
# a row - and the engine, which had been trading and writing equity snapshots the whole hour,
# was declared "не выходит на связь" for 63 minutes. The bake now runs in its own unit
# (deploy/rf-bake.{service,timer}) and only writes files under data/live_rf/candles; this block
# picks them up on the next mark, so baking still costs zero extra git writers.
minute=$(date -u +%M)
if [ $((10#$minute % 15)) -eq 0 ]; then
  paths=(data/live_rf data/rf_presentation_snapshot.json)
  [ -f journal_live_rf.md ] && paths+=(journal_live_rf.md)
  tick_commit_paths "rf-live tick $(date -u '+%Y-%m-%d %H:%M') UTC" "${paths[@]}" || true
fi

tick_finish "Фьючерсы (Т-Инвест)" "data/live_rf/.git_sync_state" "live-rf-tick"
exit 0
