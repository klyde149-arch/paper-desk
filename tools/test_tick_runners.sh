#!/usr/bin/env bash
# Isolated contract tests for deploy/lib_tick.sh. No real git, broker or Telegram calls.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
export TICK_TEST_LOG="$WORK/calls"

cat > "$WORK/bin/git" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >> "$TICK_TEST_LOG"
case " $* " in
  *' diff '*) [ "${GIT_STAGED:-0}" = 1 ] && exit 1 || exit 0 ;;
  *' commit '*) [ "${GIT_FAIL_COMMIT:-0}" = 1 ] && exit 1 || exit 0 ;;
  *' push '*)
    if [ "${GIT_PUSH_FAIL_ONCE:-0}" = 1 ] && [ ! -f "${TICK_TEST_LOG}.pushed" ]; then touch "${TICK_TEST_LOG}.pushed"; exit 1; fi
    exit 0 ;;
  *' rev-list '*) echo 0; exit 0 ;;
esac
exit 0
EOF
cat > "$WORK/bin/pwsh" <<'EOF'
#!/usr/bin/env bash
echo "pwsh $*" >> "$TICK_TEST_LOG"
exit 0
EOF
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo -n 200
EOF
chmod +x "$WORK/bin/git" "$WORK/bin/pwsh" "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1"; fi; }

# shellcheck disable=SC1091
. "$ROOT/deploy/lib_tick.sh"
tick_init
tick_pull
tick_engine tools/fake.ps1 test "$WORK/engine_state" unit-test
tick_finish test "$WORK/sync_state" unit-test
check 'pull is shared' 1 "$(grep -c '^git pull --rebase --autostash origin main$' "$TICK_TEST_LOG")"
check 'engine is shared' 1 "$(grep -c '^pwsh -NoProfile -File tools/fake.ps1$' "$TICK_TEST_LOG")"

export GIT_STAGED=1 GIT_FAIL_COMMIT=1
tick_commit_paths 'failure test' data/live_real >/dev/null 2>&1 || true
check 'commit failure reaches watchdog state' 1 "$commit_failed"

commit_failed=0
export GIT_FAIL_COMMIT=0 GIT_PUSH_FAIL_ONCE=1
tick_commit_paths 'race test' data/live_real
check 'push race retries with autostash' 1 "$(grep -c '^git rebase --autostash origin/main$' "$TICK_TEST_LOG")"

if [ "$fail" -ne 0 ]; then echo "итого: pass=$pass fail=$fail"; exit 1; fi
echo "итого: pass=$pass fail=$fail"
