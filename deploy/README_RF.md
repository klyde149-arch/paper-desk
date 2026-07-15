# RF-LIVE runbook — запуск C3b на реальном счёте Т-Инвестиций

Контур: `tools/live_rf_engine.ps1` (дизайн: `docs/strategy/live_tinvest_design.md`).
Фазы идут строго по порядку; gate-критерии каждой фазы — в дизайн-доке. Текущая: **Phase 0 выполнена, ждём токены.**

## Phase 1 — readonly-токен (когда пользователь получит токен)
1. В личном кабинете Т-Инвестиций создать **READONLY**-токен (не полный!).
2. Локально: `$env:TINVEST_TOKEN='...'; powershell -File tools\tinvest_selftest.ps1`
   → список счетов (взять `TINVEST_ACCOUNT_ID`), аудит 8 фьючерсов + 12 акций, клиринги, латентность.
3. На VPS: добавить в `/etc/trading-live.env` строки `TINVEST_TOKEN=`, `TINVEST_ACCOUNT_ID=`,
   `TINVEST_MODE=dryrun` (файл уже root:root 600). Прогнать selftest с VPS — **главный probe**:
   если хост недоступен с зарубежного IP → план Б (RU VPS ~200–500 ₽/мес или локальный Windows + Task Scheduler).
4. Установить юниты (НЕ раньше):
   ```
   sudo cp deploy/live-rf-tick.service deploy/live-rf-tick.timer /etc/systemd/system/
   chmod +x deploy/live_rf_tick.sh
   sudo systemctl daemon-reload && sudo systemctl enable --now live-rf-tick.timer
   ```
5. DRYRUN ≥10 торговых дней: движок тикает, сигналы пишутся, заявки — только WOULD CALL
   (`data/live_rf/dryrun_calls.log`). Ежедневно сверять сигналы с paper (`journal.md` vs `journal_live_rf.md`).
6. Закрыть реестр открытых вопросов дизайн-дока (13 пунктов), обновить `$CLEARING` в движке по TradingSchedules.

## Phase 2 — sandbox
1. Токен песочницы → `TINVEST_SANDBOX_TOKEN=`, `TINVEST_MODE=sandbox`; пополнить песочный счёт.
2. `data/live_rf/config.json`: `{ "emulate_stops": true }` (StopOrders в песочнице нет).
3. ≥15 торговых дней: входы/стопы/ролл/mom-ребаланс; kill-drill всех 4 файлов:
   `data/HALT`, `data/HALT_RF_LIVE`, `data/HALT_RF_CLOSE`, `data/HALT_RF_ENTRIES` (создать в main → git pull доставит).

## Phase 3 — боевой микро (~20–50k ₽ задействовано)
1. **Полный** (trade) токен; РЕКОМЕНДАЦИЯ: без вывода средств, если брокер позволяет ограничить.
2. `TINVEST_MODE=prod`; `data/live_rf/config.json`:
   `{ "whitelist": ["CNY","NG"], "max_lots_override": 1, "mom_enabled": false }`
3. Прожить вживую: вход → стоп (в т.ч. ночной гэп) → трейл → BE → ролл → kill-drill → «выдернуть сеть» mid-tick.
4. Сверить комиссии факт (operations) с моделью `fee_est` в движке — поправить.

## Phase 4 — рабочий капитал
`config.json`: `{ "base_rub": 175000 }` → 2 недели → `350000` + `"mom_enabled": true` → 2 недели → `700000`, убрать whitelist/override.
Гейт ступени: дивергенция live vs paper ≤2% сверх объяснимой; пик ГО ≤60%; 0 неразрешённых дрифтов.

## Аварийные процедуры (в любой момент)
- **Стоп входов**: создать `data/HALT_RF_ENTRIES` (позиции живут, стопы у брокера).
- **Полный стоп контура**: `data/HALT_RF_LIVE` (бот не тикает; позиции защищены брокерскими стопами).
- **Закрыть всё немедленно**: `data/HALT_RF_CLOSE` → бот закроет рыночными и остановится.
- Руками: `sudo systemctl stop live-rf-tick.timer`; позиции всегда можно закрыть из приложения Т-Инвестиций
  (после ручных действий НЕ включать бота до сверки: чужие изменения он увидит как дрифт D2/D4/D5).
- Телеграм-алерты идут на каждый дрифт/халт/аварийное закрытие (lib_alerts, тот же бот, что крипта).

## Мониторинг
- Дашборд, вкладка «Фьючерсы»: карточка «РЕАЛ · Т-Инвестиции · C3b» (данные `data/live_rf`, пишет VPS).
- `journal_live_rf.md` — человекочитаемый журнал; `data/live_rf/tick_log.txt` — лог движка;
  `latency_log.csv` — латентность API; дневной отчёт 19:30 MSK в Telegram (P&L, ГО-пик,
  ratio заявки:сделки ≤10:1, дрифты, qty0-пропуски).
- Раз в неделю: сравнить доходность леджеров с paper futC3b/C3b (`data/rf/c3b_portfolio.json`);
  |Δ| > 1.5%/мес сверх объяснимого (лоты/комиссии/слиппедж) — разбор.
