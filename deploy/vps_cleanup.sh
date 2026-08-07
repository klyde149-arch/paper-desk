#!/usr/bin/env bash
# vps_cleanup.sh - scheduled disk housekeeping for the trading VPS (systemd timer,
# NOT the tick path - see deploy/vps-cleanup.timer). Runs as root; the git maintenance
# step drops to the trader user so repo ownership never drifts.
#
# Incident 2026-08-07: the disk filled up and silently stopped both live contours (git
# could not write objects, the engine could not persist portfolio.json/equity.json).
# This script is the regular-maintenance half of the fix; deploy/git_sync_watch.sh's
# disk_watch() (called every tick) is the early-warning half.
#
# Philosophy mirror of the tick scripts: housekeeping must never fight trading for
# resources or break the repo. Every step is guarded (`|| true`-style), a failed step
# only skips its own cleanup and gets reported, never aborts the run. Only a fixed
# whitelist of paths is touched - no `find / -delete`, nothing under data/live_*,
# .secrets/, or /etc/trading-live.env. Anything irreversible (removing old projects,
# apt autoremove) is a MANUAL runbook step in deploy/README_CLEANUP.md, not here.
#
# Env (from /etc/trading-live.env via systemd EnvironmentFile):
#   TG_BOT_TOKEN, TG_CHAT_ID   - Telegram creds (empty -> report is a silent no-op)
#   JOURNAL_KEEP=200M          - journald --vacuum-size cap
#   JOURNAL_DAYS=14d           - journald --vacuum-time cap
#   REPORT_MIN_FREED_MB=200    - only message Telegram if we freed at least this much
#   DISK_WARN_PCT=85           - also message Telegram if usage is still >= this after cleanup
# CLI:
#   DRY_RUN=1 ./vps_cleanup.sh - print what each step would do; touch nothing
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"
REPO_DIR=/home/trader/paper-desk
GIT_USER=trader
DRY_RUN="${DRY_RUN:-0}"
JOURNAL_KEEP="${JOURNAL_KEEP:-200M}"
JOURNAL_DAYS="${JOURNAL_DAYS:-14d}"
REPORT_MIN_FREED_MB="${REPORT_MIN_FREED_MB:-200}"
DISK_WARN_PCT="${DISK_WARN_PCT:-85}"

# Reuse the Telegram sender + disk-percent helper already used by the tick watchdogs;
# no second implementation of either.
# shellcheck disable=SC1091
. "$(dirname "$0")/git_sync_watch.sh" 2>/dev/null || tg_alert() { :; }

log() { echo "$(date -u '+%Y-%m-%d %H:%M:%S')Z $*"; }
run() {
  # run <description> -- <command...>   (steps into $DRY_RUN automatically)
  local desc="$1"; shift
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: would run: $desc ($*)"
    return 0
  fi
  log "$desc"
  "$@" 2>&1 || log "WARN: step failed: $desc"
}

avail_kb() { df -P / 2>/dev/null | awk 'NR==2 {print $4}'; }
used_pct() { df -P / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}'; }

before_kb=$(avail_kb); [ -n "$before_kb" ] || before_kb=0
log "vps_cleanup start (DRY_RUN=$DRY_RUN); free before: $((before_kb/1024)) MB"

# 1) journald - bound both size and age so it can never creep back up unattended.
run "journald vacuum (size=$JOURNAL_KEEP, time=$JOURNAL_DAYS)" \
  journalctl --vacuum-size="$JOURNAL_KEEP" --vacuum-time="$JOURNAL_DAYS"

# 2) apt cache only - NOT autoremove (that changes the installed package set on a
# production host; that stays a manual, reviewed step in README_CLEANUP.md).
if command -v apt-get >/dev/null 2>&1; then
  run "apt-get clean" apt-get clean
fi

# 3) rotated logs older than 30 days (compressed/numbered rotations only, never the
# live *.log a service is currently writing).
if [ "$DRY_RUN" = "1" ]; then
  n=$(find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' \) -mtime +30 2>/dev/null | wc -l)
  log "DRY_RUN: would delete $n rotated /var/log file(s) older than 30 days"
else
  run "prune rotated /var/log (>30d)" \
    find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' \) -mtime +30 -delete
fi

# 4) trader's own cache (pwsh/.NET unpacked bundles etc.) - files untouched >14 days.
# /tmp and /var/tmp are left to systemd-tmpfiles-clean.timer; we don't duplicate that.
CACHE_DIR=/home/trader/.cache
if [ -d "$CACHE_DIR" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    n=$(find "$CACHE_DIR" -type f -atime +14 2>/dev/null | wc -l)
    log "DRY_RUN: would delete $n stale file(s) under $CACHE_DIR (atime >14d)"
  else
    run "prune stale files under $CACHE_DIR (atime >14d)" \
      find "$CACHE_DIR" -type f -atime +14 -delete
    run "prune now-empty dirs under $CACHE_DIR" \
      find "$CACHE_DIR" -mindepth 1 -type d -empty -delete
  fi
fi

# 5) repo maintenance - bounded resources (this box is small), never --aggressive
# (too slow/heavy for a nightly run on a live trading host). gc.auto=0 is set so the
# tick's own `git pull`/`git push` never triggers an unbounded gc inside its 110s budget
# (deploy/live-rf-tick.service TimeoutStartSec) - this timer is the only place gc runs.
if [ -d "$REPO_DIR/.git" ]; then
  run "git config gc.auto 0" sudo -u "$GIT_USER" git -C "$REPO_DIR" config gc.auto 0
  gitc() { sudo -u "$GIT_USER" timeout 600 git -C "$REPO_DIR" \
    -c pack.threads=1 -c pack.windowMemory=64m "$@"; }
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: would run git reflog expire / repack -a -d / prune-packed / prune on $REPO_DIR"
  else
    run "git reflog expire" gitc reflog expire --expire=14.days --expire-unreachable=3.days --all
    run "git repack" gitc repack -a -d --depth=50 --window=50
    run "git prune-packed" gitc prune-packed
    run "git prune" gitc prune --expire=3.days.ago
  fi
fi

after_kb=$(avail_kb); [ -n "$after_kb" ] || after_kb=$before_kb
freed_mb=$(( (after_kb - before_kb) / 1024 ))
pct=$(used_pct); [ -n "$pct" ] || pct='?'
avail_h=$(df -h / 2>/dev/null | awk 'NR==2 {print $4}')

log "vps_cleanup done; freed ~${freed_mb} MB; disk now ${pct}% used, ${avail_h} free"

if [ "$DRY_RUN" != "1" ]; then
  if [ "$freed_mb" -ge "$REPORT_MIN_FREED_MB" ] 2>/dev/null; then
    tg_alert "VPS-уборка: освобождено ~${freed_mb} МБ, диск занят ${pct}%, свободно ${avail_h}."
  elif [ "$pct" != '?' ] && [ "$pct" -ge "$DISK_WARN_PCT" ] 2>/dev/null; then
    tg_alert "VPS-уборка прошла, но диск всё ещё занят ${pct}% (свободно ${avail_h}) - освобождено только ~${freed_mb} МБ. Нужна ручная проверка (см. deploy/README_CLEANUP.md)."
  fi
fi

exit 0
