# Деплой Mini App (трейдинг-кабинет) на VPS

Кабинет — это `telegram-mini-app/`: Express отдаёт API и собранный SPA, все цифры читаются из
`data/live_rf/*` и `data/live_real/*`. **Единственный писатель состояния — движок**, кабинет
только читает.

> **СТАТУС: контур ОСТАНОВЛЕН по решению владельца 2026-08-17.** Развёрнут и проверен в тот же
> день, затем погашен: `mini-app`, `mini-app-tunnel`, `mini-app-url-watch.timer` — все
> `disabled`, `MINI_APP_URL` убран из окружения ассистента, кнопка меню бота возвращена в
> `commands`. Бот работает точно как до кабинета. Код и юниты остались в репо и **инертны**:
> кнопка в `/start` появляется только при заданном `MINI_APP_URL`. Как поднять обратно — ниже;
> на хосте уже лежат собранный `dist/`, `node_modules`, `.env` и `portfolios.json`, так что
> нужен только `systemctl enable --now`.

## Схема

```
Telegram ──https──> cloudflared (туннель) ──http──> 127.0.0.1:3011 (mini-app.service)
                                                          │ читает
                                                          ↓
                                              data/live_rf, data/live_real
```

Наружу процесс НЕ смотрит: `HOST=127.0.0.1` (по умолчанию в коде), а `ufw` на хосте держит
`deny incoming` для всего, кроме 22/tcp. Публичный HTTPS даёт только туннель — открывать 443
не требуется.

## Ключевое правило: второй поллер убьёт ассистента

`getUpdates` держит `assistant/bot.py` (`trading-assistant.service`). Два процесса с
`getUpdates` на одном токене несовместимы — Telegram отдаёт 409. Поэтому сервер кабинета
`bot.launch()` не вызывает и не должен. `npm run set-menu-button` безопасен: это единичный
REST-вызов `setChatMenuButton`, как `sendMessage` из торговых тиков.

## Что уже стоит на хосте

| Что | Где |
|---|---|
| код | `/home/trader/paper-desk/telegram-mini-app` (приезжает обычным `git pull` в тике) |
| сервис | `mini-app.service` (из `deploy/mini-app.service`), `User=trader`, порт 3011 |
| туннель | `mini-app-tunnel.service` — **временный** quick-туннель, см. ниже |
| `.env` | рядом с кодом, `600 trader`, в git-игноре. Токен — тот же бот, что у ассистента |
| `portfolios.json` | там же, `600 trader`, в игноре. `admins` = telegram id владельца |
| sqlite | `telegram-mini-app/data/mini-app.sqlite` — только пользователи и журнал доступа |
| `MINI_APP_URL` | `/etc/trading-assistant.env` (`640 root:trader`) — включает кнопку в `/start` |

Node.js на хосте уже был (v22). `npm ci` ставится с dev-зависимостями и **не** прунится:
`vite` нужен для пересборки после любой правки фронтенда, а 64 МБ на 14 ГБ свободных не жмут.

## Развернуть с нуля

```bash
cd /home/trader/paper-desk/telegram-mini-app
sudo -u trader npm ci
sudo -u trader npm run test:contracts     # 4 pass
sudo -u trader npm run build              # dist/
# .env и portfolios.json - по образцам .env.example / portfolios.example.json, chmod 600
cp ../deploy/mini-app.service /etc/systemd/system/ && systemctl daemon-reload
systemctl enable --now mini-app
curl -s localhost:3011/api/health          # {"ok":true}
```

`chmod +x` руками **не делать** — бит исполнения живёт в коммите, ручной chmod создаёт вечную
mode-диффу, которая роняет `git pull --rebase --autostash` в тике (инцидент 2026-08-11, контур
молчал 27 часов). Подробности в `README_RF.md`.

## Обновить после правки кода

```bash
cd /home/trader/paper-desk && sudo -u trader git pull   # или дождаться тика
cd telegram-mini-app && sudo -u trader npm run build    # только если менялся фронтенд
systemctl restart mini-app
```

## Туннель: временный сейчас, постоянный потом

Сейчас работает **quick-туннель** (TryCloudflare): аккаунт и домен не нужны, но **URL
случайный и меняется при каждом перезапуске `cloudflared`**. Адрес прописан в трёх местах —
`WEB_APP_URL` в `.env`, `MINI_APP_URL` в окружении ассистента и нижняя кнопка меню, — и после
смены все три ведут в никуда МОЛЧА: бот отвечает как обычно, кнопка просто не открывается.

Поэтому руками ничего обновлять не надо: этим занимается **сторож**
`mini-app-url-watch.timer` (раз в 2 минуты, `deploy/mini_app_url_watch.sh`). При смене адреса
он переписывает оба конфига, переставляет кнопку меню, перезапускает ассистента и присылает
новую ссылку в Telegram; если адрес прежний — молчит и ничего не трогает. Проверено боем
2026-08-17: от подмены адреса до полностью починенных кнопок прошла одна секунда.

```bash
systemctl start mini-app-url-watch.service     # прогнать проверку немедленно
journalctl -u mini-app-url-watch -n 20         # что он делал
```

**Постоянный URL** требует одноразовой авторизации владельца в браузере:

```bash
cloudflared tunnel login                      # откроет браузер, выбрать домен в Cloudflare
cloudflared tunnel create paper-desk-miniapp
cloudflared tunnel route dns paper-desk-miniapp cabinet.<домен>
# ~/.cloudflared/config.yml: ingress -> service: http://127.0.0.1:3011
cloudflared service install                   # вместо mini-app-tunnel.service
systemctl disable --now mini-app-tunnel
```

Дальше — тот же блок обновления URL, но уже навсегда, и `set-menu-button` больше повторять
не придётся.

## Доступ

Проверка подписи `initData` (HMAC-SHA-256, `server/telegram-auth.js`) доказывает, что запрос
пришёл из Telegram, но не что пришёл владелец счёта. Поэтому сверху стоит жёсткий список
`ALLOWED_TELEGRAM_IDS`, и `DEV_ALLOW_UNSAFE_AUTH=false` в проде. **Пустой список впускает
любого, кто открыл приложение** — для боевого счёта так нельзя. Отказы пишутся в `access_log`.

Второй получатель фьючерсных отчётов (`TG_CHAT_ID_FUT`) — это **клиент**, в кабинет он НЕ
допущен: чтобы дать ему только фьючерсы, его id добавляется в `owners` портфеля `rf` в
`portfolios.json` (тогда сводки он не увидит и о существовании чужих портфелей не узнает).
В Telegram он получает урезанный поток — без технической диагностики (суточная проверка
готовности, расхождения `D2/D4/D5/D6`, служебные алерты); см. «Два потока в Telegram»
в `deploy/README_RF.md`.

## Проверка после деплоя

```bash
curl -s localhost:3011/api/health                       # {"ok":true}
curl -s -o /dev/null -w '%{http_code}\n' localhost:3011/api/v2/dashboard   # 401 без подписи
ss -tlnp | grep 3011                                    # ТОЛЬКО 127.0.0.1
sudo -u trader git -C /home/trader/paper-desk status --porcelain   # без .env/dist/node_modules
systemctl is-active mini-app mini-app-tunnel trading-assistant
journalctl -u trading-assistant -n 20 | grep -i 409     # пусто = второго поллера нет
```

## Откат

```bash
systemctl disable --now mini-app mini-app-tunnel
sed -i '/^MINI_APP_URL=/d' /etc/trading-assistant.env
systemctl restart trading-assistant
```

Ассистент возвращается к прежнему `/start` без кнопки; торговые контуры кабинет не трогает
вообще. Нижнюю кнопку меню, если она мешает, снимает
`setChatMenuButton` с `{"type":"default"}`.
