# Очистка диска на VPS — установка и ручной runbook

Контекст инцидента 2026-08-07: диск на VPS переполнился, оба боевых контура (Bybit и
Т-Инвест) молча встали — git не мог писать объекты, движки не могли сохранить состояние.
Ничего не следило за диском, поэтому проблему увидели только по факту остановки торговли.

Решение — два независимых слоя:
1. **`disk_watch()`** в `deploy/git_sync_watch.sh`, вызывается из обоих тиков каждую
   минуту — Telegram-алерт заранее, до того как диск реально кончится.
2. **`vps_cleanup.sh`** + `vps-cleanup.timer` — ежедневная регламентная уборка ночью.

Оба никогда не роняют тик/себя: любая ошибка только логируется, код возврата всегда 0.

## Установка (один раз, на VPS)

```bash
cd /home/trader/paper-desk
git pull
chmod +x deploy/vps_cleanup.sh
sudo cp deploy/vps-cleanup.service deploy/vps-cleanup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vps-cleanup.timer
systemctl list-timers vps-cleanup --no-pager   # проверить следующий запуск (04:10 МСК)
```

`disk_watch` ничего дополнительно ставить не надо — он уже дот-сорсится в
`live_tick.sh`/`live_rf_tick.sh` через `git_sync_watch.sh`, начнёт работать со следующего
тика после `git pull`.

Постоянный потолок journald, чтобы он не разрастался между запусками таймера:
```bash
sudo tee -a /etc/systemd/journald.conf >/dev/null <<'EOF'
SystemMaxUse=200M
MaxRetentionSec=2week
EOF
sudo systemctl restart systemd-journald
```

Переменные (необязательные, в `/etc/trading-live.env`):
`JOURNAL_KEEP`, `JOURNAL_DAYS`, `REPORT_MIN_FREED_MB`, `DISK_WARN_PCT`,
`DISK_ALERT_REPEAT_MIN` — значения по умолчанию см. в шапках `vps_cleanup.sh` и
`git_sync_watch.sh`.

## Проверка после установки

```bash
sudo DRY_RUN=1 /home/trader/paper-desk/deploy/vps_cleanup.sh          # план, без изменений
sudo systemctl start vps-cleanup.service
journalctl -u vps-cleanup -n 60 --no-pager                            # шаги + итог "освобождено N МБ"
du -sh /home/trader/paper-desk/.git
sudo -u trader git -C /home/trader/paper-desk fsck --no-dangling      # репо цело
journalctl -u live-tick -u live-rf-tick --since "15 min ago"          # тики не пострадали
```

## Что уборка чистит автоматически

- journald: `--vacuum-size`/`--vacuum-time` (по умолчанию 200 МБ / 14 дней).
- Кэш apt (`apt-get clean`) — **не** `autoremove` (это меняет набор пакетов на боевом
  хосте, только руками).
- Ротированные логи `/var/log/*.gz`, `*.N` старше 30 дней.
- `~/.cache` пользователя `trader` (распакованные бандлы pwsh/.NET) — файлы, к которым
  не обращались 14+ дней. `/tmp`/`/var/tmp` не трогает — это зона
  `systemd-tmpfiles-clean.timer`.
- Обслуживание git-репозитория `paper-desk`: `reflog expire` → `repack -a -d` →
  `prune-packed` → `prune`. **История не переписывается** — коммиты не удаляются, только
  упаковываются плотнее и вычищается недостижимый мусор. `gc.auto=0` выставляется, чтобы
  автоматический `gc` не срабатывал внутри `git pull` в тике и не съедал его 110-секундный
  бюджет (`live-rf-tick.service`) — весь repack теперь только здесь, по расписанию.

## Ручной runbook — «диск переполнен прямо сейчас»

Порядок важен: сначала измерить, чтобы не гадать, что именно съело место.

```bash
df -h /
sudo du -xh --max-depth=1 / 2>/dev/null | sort -h | tail -15
sudo du -sh /home/trader/paper-desk/.git /root/* /home/* 2>/dev/null | sort -h | tail -15
journalctl --disk-usage
```

Быстрое безопасное освобождение места (не требует остановки контуров):
```bash
sudo journalctl --vacuum-size=200M
sudo apt-get clean && sudo apt-get autoremove -y
sudo find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' \) -mtime +14 -delete
```

**Старые проекты — самый крупный разовый выигрыш (~2.5 ГБ), но необратимо, поэтому
руками и только после проверки.** По `vps/VPS_INVENTORY.md`: `freqtrade` (2.3 ГБ) не
запущен, `openclaw_bingx_disabled`/`.openclaw` — советники без биржевого исполнения.
Перед удалением:
```bash
systemctl status openclaw.service openclaw_bingx_disabled 2>/dev/null
crontab -l; sudo crontab -l          # у старого бота был @reboot main.py
```
Если процессы не активны — ценное из них уже сохранено локально в `vps/` (стратегии,
мета бэктестов, зашифрованные секреты), на VPS они больше не нужны:
```bash
sudo rm -rf /root/freqtrade /root/openclaw_bingx_disabled /root/.openclaw
```

Разовый repack репозитория (после того как место уже освободилось — repack сам требует
свободного места под новый пак):
```bash
sudo -u trader git -C /home/trader/paper-desk -c pack.threads=1 -c pack.windowMemory=64m repack -a -d
sudo -u trader git -C /home/trader/paper-desk fsck --no-dangling
```

## Если `.git` снова разрастётся

История не переписывается по решению пользователя — прирост ~4–5 МБ/сут после repack
сохраняется (два контура пушат состояние каждые 15 мин). Дешёвый рычаг, если понадобится
без переписывания истории: печь свечи (`bake_rf_candles.ps1`) не каждые 15 мин, а раз в
час — суточный прирост `.git` падает примерно вчетверо. Радикальный вариант (переписывает
рабочую копию, не историю на GitHub) — shallow-переклон: остановить оба таймера,
`git clone --depth=1`, перенести локальные runtime-файлы (`.env`, `.git_sync_state` и
т.п.), подменить каталог. Делать только руками, по явному решению.
