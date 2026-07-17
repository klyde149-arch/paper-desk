# Деплой LIVE-исполнителя на VPS (Ubuntu 24.04)

Runbook перевода main-контура v2-комбо на реальные деньги Bybit (~100$).
Ключи — **только торговля, без вывода/переводов, с IP-whitelist**. Paper-контуры
остаются на GitHub Actions и не трогаются; VPS коммитит только `data/live_real/*`
и `journal_live.md`.

## Фаза 0 — гейты и подготовка

### 0.1 Гео-гейт (go/no-go, первый шаг)
```bash
curl -s https://api.bybit.com/v5/market/time && echo OK-bybit
curl -s https://api.bytick.com/v5/market/time && echo OK-bytick
```
Оба недоступны → этот VPS не годится (меняем регион), дальше не идти.

### 0.2 Bybit (в приложении/на сайте, руками)
1. Убедиться, что ~100$ лежат в **Unified Trading Account** (не в Funding — при
   необходимости сделать внутренний перевод руками).
2. Режим позиций: **one-way** (Positions → Settings) для USDT-перпов.
3. API → Create New Key → System-generated:
   - Read-Write, **только** «Contract — Orders» и «Contract — Positions»;
   - **НЕ включать** Withdraw / Transfer / SubMember / Wallet-Transfer;
   - **IP restriction: only trusted IPs** → вписать статический IP VPS
     (`curl ifconfig.me` на VPS). Это же снимает 90-дневное истечение ключа.
4. Сохранить key/secret — попадут в `/etc/trading-live.env` (шаг 0.5).

### 0.3 Чистка VPS от старых ботов
```bash
sudo systemctl disable --now openclaw.service
crontab -l                     # убрать @reboot main.py и 4h signal_tracker старого бота
sudo crontab -l                # проверить и root-crontab
# мёртвый ALOR_REFRESH_TOKEN: удалить из /root/openclaw_bingx_disabled/.env, если жив
```

### 0.4 Базовая установка
```bash
# PowerShell 7 (репозиторий Microsoft для Ubuntu 24.04)
wget -q https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb && sudo apt update && sudo apt install -y powershell git chrony
sudo systemctl enable --now chrony
chronyc tracking   # offset должен быть <0.1s — критично для подписи запросов

sudo useradd -m -s /bin/bash trader
sudo -u trader ssh-keygen -t ed25519 -f /home/trader/.ssh/id_ed25519 -N ''
sudo cat /home/trader/.ssh/id_ed25519.pub
# → GitHub: repo paper-desk → Settings → Deploy keys → Add key (Allow write access!)
sudo -u trader git clone git@github.com:<user>/paper-desk.git /home/trader/paper-desk
```

### 0.5 Секреты
Локально (Windows) расшифровать телеграм-токен из бандла:
```
openssl enc -d -aes-256-cbc -pbkdf2 -in vps/secrets/vps_secrets.enc -out vps/secrets/secrets.txt
```
На VPS:
```bash
sudo cp /home/trader/paper-desk/deploy/trading-live.env.example /etc/trading-live.env
sudo nano /etc/trading-live.env    # вписать BYBIT_*, TG_*, LIVE_DRYRUN=1
sudo chown root:root /etc/trading-live.env && sudo chmod 600 /etc/trading-live.env
```

## Фаза 1 — установка юнитов
```bash
cd /home/trader/paper-desk
chmod +x deploy/live_tick.sh
sudo cp deploy/live-tick.service deploy/live-tick.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now live-tick.timer
journalctl -u live-tick -f        # смотреть тики; лог движка: data/live_real/tick_log.txt
```

## Фаза 2 — смоук и go-live

1. **DryRun** (LIVE_DRYRUN=1, по умолчанию): дать поработать несколько часов, охватив
   минимум одно закрытие 4h-бара (00/04/08/12/16/20 UTC). Проверить: тики «ok [DRYRUN]»
   в tick_log, Telegram-алерты приходят, сканер пишет `data/live_real/signals.json`.
2. **Смоук-ордер** (под присмотром, стоит центы):
   ```bash
   sudo systemctl stop live-tick.timer
   set -a; source /etc/trading-live.env; set +a
   pwsh -NoProfile -File tools/live_smoke_test.ps1              # read-only проверки
   pwsh -NoProfile -File tools/live_smoke_test.ps1 -PlaceOrder  # min-lot round-trip ETH
   ```
   Убедиться: позиция появилась С прикреплённым SL, закрылась reduce-only, executions видны.
3. **Go-live**:
   ```bash
   sudo sed -i 's/LIVE_DRYRUN=1/LIVE_DRYRUN=0/' /etc/trading-live.env
   sudo systemctl start live-tick.timer
   ```
4. **Тест недели 1 (намеренный)**: при открытой позиции сделать `sudo reboot` —
   стоп должен остаться на бирже, после подъёма reconcile должен досчитать книгу.

## Управление

| Действие | Как |
|---|---|
| Стоп всего (глобально, и paper тоже) | закоммитить файл `data/HALT` |
| Стоп только live-входов (позиции ведутся) | файл `data/HALT_LIVE` (можно локально на VPS: `touch data/HALT_LIVE`) |
| Флэттен всего немедленно | файл `data/HALT_CLOSE` → следующий тик отменит ордера и закроет позиции маркетом |
| Ручная остановка тиков | `sudo systemctl stop live-tick.timer` |
| Аварийно с телефона | приложение Bybit → закрыть позиции руками (ключ бота этому не мешает) |
| Снять халт после HALT_CLOSE / −35% | остановить таймер → удалить файл HALT_CLOSE → в `data/live_real/portfolio.json` выставить `"trading_halted": false` и `"entries_halt_reason": ""` → запустить таймер |
| Алерт «дашборд онемел» | `deploy/git_sync_watch.sh` шлёт в Telegram, если состояние перестало доходить до GitHub (застрявший `git pull`/`push`) дольше `GIT_ALERT_AFTER_MIN` (деф. 30 мин); при восстановлении — «восстановлено». Заглушить: пустые `TG_*` в `/etc/trading-live.env`. Пороги: `GIT_ALERT_AFTER_MIN` / `GIT_ALERT_REPEAT_MIN`. Торговлю НЕ трогает (тик всегда `exit 0`), состояние-таймер `data/live_real/.git_sync_state` — local-only (gitignored). |

## Гейт масштабирования

Довносить деньги только после **≥4 недель**: ноль необъяснённых дрифтов (D2/D4/D5 в
tick_log), live-vs-paper медиана расхождения ≤ ±0.2R, все пути выхода отработали
(stop, TP1→БУ, трейл).
