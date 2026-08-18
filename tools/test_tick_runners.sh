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

# --- deploy/live_rf_tick.sh: публикация состояния не стоит в очереди за выпечкой свечей ---
# Инцидент 2026-08-18: полная выпечка (~180 вызовов брокера) шла ДО tick_commit_paths внутри
# одного юнита с TimeoutStartSec=110. Брокерские свечные ответы замедлились вдвое, три марки
# подряд были убиты по таймауту ДО коммита - 63 минуты без публикации при живом движке.
# Тест фиксирует контракт: в тике полной выпечки нет вовсе (она живёт в rf-bake.timer),
# а на 15-минутной марке коммит состояния случается.
cat > "$WORK/bin/date" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "+%M" ]; then echo "${FAKE_MINUTE:-07}"; exit 0; fi
done
if [ -x /usr/bin/date ]; then exec /usr/bin/date "$@"; else exec /bin/date "$@"; fi
EOF
chmod +x "$WORK/bin/date"

# GIT_STAGED=1 - в индексе есть что публиковать; DISK_WARN_PCT=101 - не будить disk_watch
# на диске машины, где гоняются тесты.
export GIT_STAGED=1 GIT_FAIL_COMMIT=0 GIT_PUSH_FAIL_ONCE=0 DISK_WARN_PCT=101

TICK_TEST_LOG="$WORK/mark" FAKE_MINUTE=30 bash "$ROOT/deploy/live_rf_tick.sh" >/dev/null 2>&1
check 'на 15-минутной марке состояние публикуется' 1 "$(grep -c ' commit -m ' "$WORK/mark")"
check 'публикация доходит до origin'               1 "$(grep -c '^git push origin main$' "$WORK/mark")"
check 'полной выпечки свечей в тике больше нет'    0 "$(grep -c 'bake_rf_candles\.ps1$' "$WORK/mark")"
check 'дешёвый снапшот остался поминутным'         1 "$(grep -c 'bake_rf_candles\.ps1 -SnapshotOnly$' "$WORK/mark")"

TICK_TEST_LOG="$WORK/plain" FAKE_MINUTE=07 bash "$ROOT/deploy/live_rf_tick.sh" >/dev/null 2>&1
check 'вне марки тик ничего не коммитит' 0 "$(grep -c ' commit -m ' "$WORK/plain")"

if [ "$fail" -ne 0 ]; then echo "итого: pass=$pass fail=$fail"; exit 1; fi
echo "итого: pass=$pass fail=$fail"
