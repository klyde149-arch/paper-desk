#!/usr/bin/env bash
# test_git_sync_watch.sh - тесты доставки алертов и сторожа падений движка.
# Запуск (локально, git-bash или Linux): bash tools/test_git_sync_watch.sh
#
# ЗАЧЕМ. Инцидент 11-12.08: сторож ДЕТЕКТИЛ простой, но алерты уходили в никуда, и 27 часов
# молчания никто не заметил. Урок «проверять надо ДОСТАВКУ, а не детект» до tg_alert доведён
# не был - она делала `curl ... || true` и всегда возвращала 0, после чего вызывающий ставил
# ALERTED=1. То есть при протухшем токене сторож считал, что предупредил, и больше не пытался.
# Здесь curl подменяется заглушкой, чтобы проверить именно это поведение, а не «код написан».

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0; failed=()

check() { # check <имя> <ожидание> <факт>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1";
  else fail=$((fail+1)); failed+=("$1"); echo "  FAIL $1 (ожидали '$2', получили '$3')"; fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Заглушка curl: печатает код из CURL_FAKE_CODE, как настоящий с -w '%{http_code}'.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo -n "${CURL_FAKE_CODE:-200}"
exit 0
EOF
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"

# shellcheck disable=SC1090
. "$ROOT/deploy/git_sync_watch.sh"

export TG_BOT_TOKEN='test-token'
export TG_CHAT_ID='123'

echo "== доставка алертов =="
CURL_FAKE_CODE=200 tg_alert "проверка" >/dev/null 2>&1; check "HTTP 200 -> успех" "0" "$?"
CURL_FAKE_CODE=401 tg_alert "проверка" >/dev/null 2>&1; check "HTTP 401 (протухший токен) -> провал" "1" "$?"
CURL_FAKE_CODE=404 tg_alert "проверка" >/dev/null 2>&1; check "HTTP 404 (мусор в URL) -> провал" "1" "$?"
CURL_FAKE_CODE=000 tg_alert "проверка" >/dev/null 2>&1; check "сеть недоступна -> провал" "1" "$?"

# Без кредов - тихий no-op с успехом (инвариант, который менять нельзя).
( unset TG_BOT_TOKEN; tg_alert "проверка" >/dev/null 2>&1 ); check "нет токена -> тихий no-op" "0" "$?"

echo "== ALERTED не выставляется при недоставленном алерте =="
STATE="$WORK/engine_state"
# Движок упал, но алерт не доставлен: тревога НЕ должна быть помечена как отправленная,
# иначе следующий тик промолчит и падение останется незамеченным навсегда.
rm -f "$STATE"
CURL_FAKE_CODE=401 engine_watch "тест" "$STATE" "7" "unit-test" >/dev/null 2>&1
# grep -c при нуле совпадений печатает 0 И возвращает 1, поэтому `|| echo 0` дописывал
# второй ноль и сравнение ломалось. Берём вывод как есть, пустой (нет файла) -> 0.
got=$(grep -c '^ALERTED=1' "$STATE" 2>/dev/null || true); got=${got:-0}
check "недоставленный алерт -> ALERTED=0 (повторим позже)" "0" "$got"

rm -f "$STATE"
CURL_FAKE_CODE=200 engine_watch "тест" "$STATE" "7" "unit-test" >/dev/null 2>&1
# grep -c при нуле совпадений печатает 0 И возвращает 1, поэтому `|| echo 0` дописывал
# второй ноль и сравнение ломалось. Берём вывод как есть, пустой (нет файла) -> 0.
got=$(grep -c '^ALERTED=1' "$STATE" 2>/dev/null || true); got=${got:-0}
check "доставленный алерт -> ALERTED=1" "1" "$got"

echo "== engine_watch: жизненный цикл =="
# rc=0 при отсутствии аварии - файла состояния быть не должно
rm -f "$STATE"
CURL_FAKE_CODE=200 engine_watch "тест" "$STATE" "0" "unit-test" >/dev/null 2>&1
check "движок жив -> состояния нет" "0" "$([ -f "$STATE" ] && echo 1 || echo 0)"

# восстановление: была авария, движок ожил - файл убирается
CURL_FAKE_CODE=200 engine_watch "тест" "$STATE" "7" "unit-test" >/dev/null 2>&1
CURL_FAKE_CODE=200 engine_watch "тест" "$STATE" "0" "unit-test" >/dev/null 2>&1
check "движок ожил -> состояние снято" "0" "$([ -f "$STATE" ] && echo 1 || echo 0)"

# сторож никогда не роняет тик, даже когда всё плохо
CURL_FAKE_CODE=500 engine_watch "тест" "$STATE" "9" "unit-test" >/dev/null 2>&1
check "сторож не роняет тик" "0" "$?"

echo "== git_sync_watch учитывает провал коммита =="
# Пятый аргумент commit_ok=0 обязан сделать контур нездоровым даже при pull_ok=1 и ahead=0.
REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main . >/dev/null 2>&1
git config user.email t@e.com; git config user.name t
echo x > a.txt; git add a.txt; git commit -qm seed >/dev/null 2>&1
git remote add origin "$REPO" >/dev/null 2>&1
git update-ref refs/remotes/origin/main HEAD
SYNC="$WORK/sync_state"
rm -f "$SYNC"
GIT_ALERT_AFTER_MIN=0 CURL_FAKE_CODE=200 git_sync_watch "тест" "$SYNC" "1" "unit-test" "0" >/dev/null 2>&1
check "commit_ok=0 -> авария зафиксирована" "1" "$([ -f "$SYNC" ] && echo 1 || echo 0)"
rm -f "$SYNC"
GIT_ALERT_AFTER_MIN=0 CURL_FAKE_CODE=200 git_sync_watch "тест" "$SYNC" "1" "unit-test" "1" >/dev/null 2>&1
check "commit_ok=1 -> контур здоров" "0" "$([ -f "$SYNC" ] && echo 1 || echo 0)"
cd "$ROOT"

echo ""
if [ "$fail" -ne 0 ]; then
  echo "итого: pass=$pass fail=$fail"
  for f in "${failed[@]}"; do echo "  - $f"; done
  exit 1
fi
if [ "$pass" -eq 0 ]; then echo "СБОЙ ХАРНЕССА: ни одной проверки не выполнено"; exit 1; fi
echo "итого: pass=$pass fail=$fail"
exit 0
