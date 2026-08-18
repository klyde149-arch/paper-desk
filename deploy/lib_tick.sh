#!/usr/bin/env bash
# Shared fail-open plumbing for the two VPS live tick entry scripts.
TICK_DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tick_init() {
  cd "$TICK_DEPLOY_DIR/.." || return 1
  # shellcheck disable=SC1091
  . "$TICK_DEPLOY_DIR/git_sync_watch.sh"
  commit_failed=0
  pull_ok=1
}

tick_pull() {
  if ! git pull --rebase --autostash origin main >/dev/null 2>&1; then
    git rebase --abort >/dev/null 2>&1 || true
    echo "WARN: git pull failed - tick continues on local state" >&2
    pull_ok=0
  fi
}

tick_engine() {
  local script="$1" label="$2" state_file="$3" unit="$4"
  pwsh -NoProfile -File "$script"
  engine_rc=$?
  if [ "$engine_rc" -ne 0 ]; then echo "WARN: $script exited rc=$engine_rc" >&2; fi
  engine_watch "$label" "$state_file" "$engine_rc" "$unit"
}

tick_push_retry() {
  if ! git push origin main >/dev/null 2>&1; then
    git fetch origin >/dev/null 2>&1 && git rebase --autostash origin/main >/dev/null 2>&1 && git push origin main >/dev/null 2>&1 \
      || echo "WARN: git push failed - state will retry next tick" >&2
  fi
}

# tick_commit_paths <message> <path> [path...]
tick_commit_paths() {
  local message="$1"; shift
  git add "$@" 2>/dev/null
  if git diff --cached --quiet 2>/dev/null; then return 0; fi
  if ! git -c user.name='live-desk-bot' -c user.email='live-desk-bot@users.noreply.github.com' commit -m "$message" >/dev/null; then
    echo "WARN: live tick commit failed - state remains unpublished" >&2
    commit_failed=1
    return 1
  fi
  tick_push_retry
  return 0
}

tick_finish() {
  local label="$1" state_file="$2" unit="$3"
  git_sync_watch "$label" "$state_file" "$pull_ok" "$unit" "$((1-commit_failed))"
  disk_watch "data/.disk_watch_state"
  actions_watch "data/.actions_watch_state"
}
