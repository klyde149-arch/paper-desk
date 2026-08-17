#!/usr/bin/env bash
# mini_app_url_watch.sh - сторож адреса Mini App.
#
# ЗАЧЕМ. Кабинет отдаётся наружу бесплатным quick-туннелем TryCloudflare: аккаунт и домен не
# нужны, но адрес случайный и МЕНЯЕТСЯ при каждом перезапуске cloudflared (ребут, обновление,
# обрыв связи). Адрес прописан в трёх местах - WEB_APP_URL в .env кабинета, MINI_APP_URL в
# окружении ассистента и нижняя кнопка меню у бота. После смены все три указывают в никуда,
# причём МОЛЧА: бот отвечает как обычно, кнопка просто не открывается. Это ровно тот класс
# тихой поломки, на котором проект уже горел трижды (немой дашборд 17.07, потерянный бит
# исполнения 11.08, слепые пять 13.08), поэтому лечим не инструкцией в README, а сторожем.
#
# Ставится таймером раз в 2 минуты. Если адрес не менялся - молчит и ничего не трогает.
# Торговых контуров не касается вообще: правит только конфиги кабинета и ассистента.

set -uo pipefail

ROOT=/home/trader/paper-desk
APP=$ROOT/telegram-mini-app
ENV_ASSISTANT=/etc/trading-assistant.env
LIVE_ENV=/etc/trading-live.env

log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }

# Текущий адрес, который опубликовал туннель. Берём последнюю строку журнала: при рестарте
# cloudflared печатает новый адрес, старые остаются выше.
new_url=$(journalctl -u mini-app-tunnel --no-pager -o cat 2>/dev/null \
  | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1)

if [ -z "$new_url" ]; then
  log "WARN: туннель не опубликовал адрес - выходим, ничего не меняя"
  exit 0
fi

cur_url=$(grep -oP '^WEB_APP_URL=\K.*' "$APP/.env" 2>/dev/null)

if [ "$new_url" = "$cur_url" ]; then
  exit 0   # штатный случай: адрес прежний
fi

log "адрес сменился: '$cur_url' -> '$new_url' - обновляем кнопки"

# 1) .env кабинета (нужен set-menu-button; сам сервер WEB_APP_URL не читает)
sudo -u trader sed -i "s|^WEB_APP_URL=.*|WEB_APP_URL=$new_url|" "$APP/.env" \
  || { log "ERR: не смогли записать WEB_APP_URL"; exit 1; }

# 2) окружение ассистента - кнопка в /start
if grep -q '^MINI_APP_URL=' "$ENV_ASSISTANT" 2>/dev/null; then
  sed -i "s|^MINI_APP_URL=.*|MINI_APP_URL=$new_url|" "$ENV_ASSISTANT"
else
  echo "MINI_APP_URL=$new_url" >> "$ENV_ASSISTANT"
fi
chown root:trader "$ENV_ASSISTANT"; chmod 640 "$ENV_ASSISTANT"

# 3) нижняя кнопка меню у бота. Одиночный REST-вызов setChatMenuButton: поллинг он не
# поднимает и ассистенту не мешает (два getUpdates на одном токене дали бы 409).
if (cd "$APP" && sudo -u trader npm run --silent set-menu-button >/dev/null 2>&1); then
  log "кнопка меню переставлена"
else
  log "WARN: set-menu-button не удался - кнопка меню осталась старой"
fi

# 4) ассистент читает MINI_APP_URL из окружения при старте
systemctl restart trading-assistant && log "ассистент перезапущен" \
  || log "ERR: не смогли перезапустить ассистента"

# 5) сказать владельцу вслух: адрес поменялся, старые ссылки мертвы
if [ -r "$LIVE_ENV" ]; then
  # shellcheck disable=SC1090
  set -a; . "$LIVE_ENV"; set +a
  if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
    curl -s --max-time 15 -o /dev/null \
      --data-urlencode "chat_id=${TG_CHAT_ID}" \
      --data-urlencode "disable_web_page_preview=true" \
      --data-urlencode "text=Кабинет сменил адрес (перезапустился туннель). Новый: ${new_url} — кнопка в /start и нижняя кнопка меню уже обновлены." \
      "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      && log "владелец уведомлён в Telegram"
  fi
fi

log "готово"
