# trading-sim / paper-desk — полный свод проекта

Единый справочник по всей системе: контуры, код, стратегии, данные, предохранители,
тесты, история инцидентов. Составлен 2026-09-01 по состоянию `main`.

**Нерешённые задачи вынесены в отдельный файл — [BACKLOG.md](BACKLOG.md).** Здесь описано,
как система устроена; там — что в ней открыто и требует решения.

Правило чтения: этот файл — канон описания. Если он расходится с `README.md`,
`docs/overview.md` или отдельным runbook'ом, верить надо коду, а расхождение чинить здесь.

---

## 1. Что это и где живёт

Автономный 24/7 торговый бот на два рынка: криптовалютные бессрочные фьючерсы Bybit и
российские фьючерсы FORTS + акции MOEX через Т-Инвестиции. Часть контуров бумажные
(форвард-тест на виртуальных деньгах), два торгуют реальными деньгами.

**Одна система под тремя именами:**

| Где | Имя | Путь |
|---|---|---|
| Ноутбук (dev) | `trading-sim` | `C:\Users\klyde\trading-sim` |
| GitHub | `paper-desk` | `github.com/klyde149-arch/paper-desk` (публичный) |
| VPS (прод) | `paper-desk` | `/home/trader/paper-desk` |

Дашборд: **https://klyde149-arch.github.io/paper-desk/** (GitHub Pages, артефакт = `report/`).

Роль агент-сессий (Claude) — анализ, исследования и доработки. Ручное ведение торгового
цикла упразднено 2026-07-10: им занимается автоматика.

---

## 2. Контуры

Семь контуров, из них два торгуют реальными деньгами, два бумажные, три остановлены.

| Контур | Статус | Где исполняется | Движок | Универсум | Деньги | Состояние в git |
|---|---|---|---|---|---|---|
| PAPER крипта (бенчмарк) | **работает** | GitHub Actions `tick.yml` | `tools/auto_trade.ps1` | 19 пар (список 20, минус DOGE) | виртуальные $10 000 | `portfolio.json`, `data/live_*.json`, `journal.md` |
| PAPER РФ C2/C3b | **работает** | внутри paper-тика | `tools/rf_engine.ps1` | 12 фьючерсов + 11 акций | виртуальные, $10k × 2 счёта | `data/rf/` |
| **Bybit LIVE** | **работает** | VPS, таймер `live-tick` (:00) | `tools/live_engine.ps1` | 16 пар (−XRP/APT/OP/AAVE) | **реальные, ~$103** | `data/live_real/`, `journal_live.md` |
| **RF LIVE (₽)** | **работает** | VPS, таймер `live-rf-tick` (:30) | `tools/live_rf_engine.ps1` | те же 12 фьюч + 11 акций | **реальные, счёт Т-Инвестиций 2154036525, счёт ≈1.57 млн ₽** (см. «Как считается капитал») | `data/live_rf/`, `journal_live_rf.md` |
| AI-ассистент | **работает** | VPS, `trading-assistant.service` | `python3 -m assistant.bot` | — | read-only + закрытие paper-позиций по подтверждению | `data/rf/manual_close_req.json` |
| Челлендж «30 дней» | **отключён 2026-08-07** | был внутри paper-тика | секция в `auto_trade.ps1` за `$CHALLENGE_ENABLED=$false` | $1000, замороженная система S4, плечо 15x | виртуальные | `challenge/` (заморожено) |
| Telegram Mini App | **остановлен 2026-08-17** | был на VPS | `telegram-mini-app/server/index.js` | — | read-only кабинет | код в репо, юниты `disabled` |

### Как считается капитал RF-контура

**Капитал = `total_amount_portfolio` брокера.** Никаких надбавок.

Вариационная маржа по фьючерсам **уже внутри** `total_amount_currencies` — сверено на боевом
счёте 2026-09-01: рубли 1 249 607,14 + серебро 319 050,00 = 1 568 657,14 =
`total_amount_currencies` = `total_amount_portfolio`, места для маржи там нет; а `daily_yield`
счёта = Σ `var_margin` позиций + переоценка валют. До 2026-09-01 `Set-BotCapital` прибавлял её
сверху и завышал капитал на всю вариационку (1 665 629 вместо 1 568 657). Подпись бага лежала
в самом состоянии: `capital_breakdown.user_assets = −96 972` — отрицательные чужие активы.

Тождество, которое обязано сходиться:
`currencies + mom_shares + user_assets = portfolio_total`. Поле `capital_breakdown.futures` —
**memo** (вариационка за сегодня), а не слагаемое.

`Set-BotCapital` пишет обе модели: `go.bot_capital_rub` (историческая, с вариационкой сверху —
на ней по-прежнему живут ГО-бюджет и губернаторы) и `go.bot_capital_account_rub` (счёт
брокера). Отчётность — дашборд, Mini App, вечерний TG-отчёт — показывает вторую. Переключение
торговых расчётов на неё вместе с ребейзом `capital_peak_rub` — отдельный этап.

**Счёт ≠ доход бота.** За 01.07–02.09 пополнений деньгами **не было**: счёт вырос
768 793 → 1 568 657 потому, что 17.08 были проданы собственные бумаги пользователя
(ПЛЗЛ 208 321 + Сбер 168 089 + МГКЛ 92 700 + облигации 212 325 + USD 501 609 +
дивиденды/купоны 30 749 ≈ 1,21 млн ₽), и выручка легла в рублёвый остаток.
**Это осознанное решение пользователя (2026-08-17/18), а не инцидент** — бюджет RF расширен
намеренно; не поднимать повторно как проблему. Технически важно другое: допущение «чужие
бумаги не попадают в `total_amount_currencies`» верно, пока бумаги держат, и перестаёт
работать, как только их продали, — поэтому состав капитала теперь сверяется тождеством выше.
Серебро `SLVRUB_TOM` — законный капитал бота: это `funding`-пул, бот сам продаёт его под ГО.
Поэтому рост кривой капитала **не является** доходностью бота; результат бота считается
отдельно (см. ниже).

**Результат бота** = сведённая на клирингах вариационка + текущая несведённая − фактические
комиссии. Считает `Invoke-BrokerLedger` по `GetOperations` (раз в сутки, в вечернем окне
после 23:00 MSK, состояние `broker_ledger`). Сверено 2026-09-01:
60 379,99 + 99 844,00 − 21 684,47 = **138 539,52 ₽**.
Складывать «закрытые сделки + `expected_yield` открытых» **нельзя**: `expected_yield` копится
по КОНТРАКТУ с момента, когда позиция по нему была нулевой, и у переоткрытого внутри дня
контракта (CRU6/EuU6 27.08) уже содержит P&L сделок из `trades.json` — те же ~84 тыс. ₽
посчитались бы дважды.

**Комиссии.** `LIVE.fee_est = 0,025%` за сторону — оценка, по которой леджер списывает деньги
в сделках. Факт по счёту за 17.07–01.09: **21 684 ₽** против оценочных 8 362 ₽ (эффективная
ставка ~0,043%/сторону). Отчётность показывает факт, ледждер сделок задним числом НЕ
переписывается (это обнулило бы `eq_rub` рукавов и все R-мультипликаторы).

**P&L позиции.** Главная цифра — брокерская (`expected_yield`), та же, что в приложении
Т-Инвестиций и в вечернем отчёте; наш `upnl_rub` (переоценка сейчас открытых лотов от цены
входа) идёт рядом вторым, подписанным числом. Процент считается **от задействованного ГО**
(`lots × go_per_lot`), а не от движения цены и не от номинала контракта.

### Правило двух писателей

Каждый путь состояния имеет ровно одного писателя. Нарушение = потеря состояния.

| Путь | Единственный писатель |
|---|---|
| `portfolio.json`, `journal.md`, `data/` (кроме live_*) | GitHub Actions (`tick.yml`) |
| `data/live_real/*`, `journal_live.md` | Bybit-таймер на VPS |
| `data/live_rf/*`, `data/rf_presentation_snapshot.json`, `journal_live_rf.md` | RF-таймер на VPS |
| `docs/`, `tools/`, `deploy/`, `report/*.html` | локальная сессия (ноут) |

**Локальные тики руками не запускать**, пока крутится облако/VPS. Для отладки — `-DryRun`
или сначала закоммитить `data/HALT`.

---

## 3. Топология и поток данных

```
Ноут (dev, Claude-сессии)
   │  git push main  (tools/deploy_site.ps1)
   ▼
GitHub main ──► Actions tick.yml (4,19,34,49 * * * *)
   │              ├─ live_watch.ps1      внешний сторож живости обоих боевых контуров
   │              ├─ auto_trade.ps1      paper-тик крипты → внутри вызывает rf_engine.ps1
   │              ├─ build_vizdata.ps1   → report/vizdata.js
   │              ├─ upload-pages-artifact (report/)
   │              └─ commit_state.ps1    коммит состояния обратно в main
   │                                     затем ОТДЕЛЬНАЯ job deploy → Pages
   │
   └──► VPS (Ubuntu 24.04, user trader) — git pull каждую минуту
          ├─ live-tick.timer      :00  → deploy/live_tick.sh    → tools/live_engine.ps1
          ├─ live-rf-tick.timer   :30  → deploy/live_rf_tick.sh → tools/live_rf_engine.ps1
          ├─ rf-bake.timer   :10,25,40,55 → tools/bake_rf_candles.ps1 (свечи для графиков)
          ├─ vps-cleanup.timer  01:10 UTC → deploy/vps_cleanup.sh (от root)
          └─ trading-assistant.service    → python3 -m assistant.bot (long-polling TG)
                      VPS пушит обратно ТОЛЬКО свои пути состояния
```

Два боевых таймера стоят в противофазе (`:00` и `:30`) специально: они делят один
git `index.lock` в общем рабочем дереве.

---

## 4. Расписание (единая таблица)

| Что | Когда | Где задано |
|---|---|---|
| Paper-тик + дашборд | cron `4,19,34,49 * * * *` | `.github/workflows/tick.yml:16` |
| Ручное закрытие paper-сделки | push в `data/rf/manual_close_req.json` | `.github/workflows/manual-close.yml` |
| Bybit LIVE тик | `OnCalendar=*-*-* *:*:00` | `deploy/live-tick.timer:5` |
| RF LIVE тик | `OnCalendar=*-*-* *:*:30` | `deploy/live-rf-tick.timer:7` |
| Выпечка свечей РФ | `OnCalendar=*-*-* *:10,25,40,55:00` | `deploy/rf-bake.timer:11` |
| Очистка диска VPS | `OnCalendar=*-*-* 01:10:00 UTC` (04:10 MSK, после клиринга) | `deploy/vps-cleanup.timer:7` |
| Слежение за URL Mini App | `OnUnitActiveSec=2min` — **disabled** | `deploy/mini-app-url-watch.timer:7` |
| Резервный диспетчер тика | локальная задача Windows | `tools/trigger_tick.ps1` |

Минуты `4,19,34,49` выбраны намеренно: на `0/15/30/45` GitHub перегружен и часто
пропускает или задерживает cron.

**Внутренние окна RF-контура (MSK):** входы 06:01–10:15 · роллы 06:05–18:00 ·
momentum-ребаланс с 06:10 · вечернее подтверждение 23:35–23:47 · отчёт 23:55 ·
ночной клиринг ЕТС 23:48–00:32 (торговля не идёт).

---

## 5. Карта кода

Весь торговый код — PowerShell в `tools/` (43 файла `.ps1` + 2 `.sh`). В корне репозитория скриптов нет.

### 5.1 Движки

| Файл | Что делает |
|---|---|
| `tools/auto_trade.ps1` | Paper-тик крипты v2 «комбо», 24/7 через Actions: реплей закрытых 1m-свечей (стопы/TP1 по касанию, gap-aware), фандинг на 8h-слотах, трейл раннера по EMA20 4h, лимиты риска, роллы UTC-дня; на свежезакрытом 4h-баре — сканер и автовход. Затем вызывает `rf_engine.ps1` и `build_vizdata.ps1`. |
| `tools/live_engine.ps1` | **Боевой исполнитель Bybit UTA** (linear USDT perp). Биржа — источник истины: книга восстанавливается из `/v5/execution/list`, а не из симуляции. Write-ahead интенты, стоп всегда на бирже. Пишет только `data/live_real/*` и `journal_live.md`. |
| `tools/rf_engine.ps1` | Бумажный форвард-тест рынка РФ: профили **C2** и **C3b**, по три рукава каждый (ядро Donchian / сетап A / momentum-акции), $10k на рукав. |
| `tools/live_rf_engine.ps1` | **Боевой C3b на Т-Инвестициях** (FORTS + TQBR). Сигналы байт-в-байт как на бумаге; отличается только исполнением: целые лоты, рубли, брокерские стоп-заявки, виртуальные леджеры рукавов поверх одного счёта. Самый большой файл репозитория (~2650 строк). |

### 5.2 Библиотеки (дот-сорсятся движками)

| Файл | Что даёт |
|---|---|
| `tools/lib_engine.ps1` | Общая плита: время/мс, HTTP с ретраями, `Get-Klines` (Bybit → bytick → BingX), карты фандинга, доступ к MOEX ISS, `Get-FutFronts`, EMA, атомарная запись JSON, журнал, лок движка. |
| `tools/lib_bybit_live.ps1` | Подписанный слой Bybit v5: синхронизация времени, HMAC, инструменты, позиции, исполнения, рыночный вход с прикреплённым стопом, TP1-лимитка, reduce-only закрытие. |
| `tools/lib_tinvest.ps1` | Клиент T-Invest API v2 через REST-gateway. Режимы `prod`/`sandbox`/`dryrun` и mock-транспорт (`TINVEST_MOCK_DIR`). **Мутирующие вызовы никогда не ретраятся вслепую** — возвращают `{__lost=$true}` для машины состояний. |
| `tools/lib_rf_signals.ps1` | **Сигнальное ядро C2/C3b, общее для бумаги и боя.** Только чистые функции и канонические константы стратегии (см. §7). |
| `tools/lib_alerts.ps1` | Telegram-алерты (`Send-TgAlert`, фан-аут в `TG_CHAT_ID_FUT`). ASCII-only, без BOM, никогда не бросает исключений. |
| `tools/lib_msg_ru.ps1` | Русские формулировки для сообщений: тикер в название, деньги, проценты, склонения. |

### 5.3 Бэктест и исследования

| Файл | Что делает |
|---|---|
| `tools/backtest.ps1` | Главный портфельный бэктестер (~50 параметров — каждая ручка стратегии). |
| `tools/backtest_rf_queue.ps1` | Бэктест одного рукава РФ и эксперимент «очередь заблокированных сигналов» (`-QueueMode`), кластерные лимиты, реальные комиссии по инструментам, флаг `-LongOnly`. |
| `tools/backtest_momentum.ps1` | Кросс-секционный momentum по акциям MOEX (лонг-онли, месячный ребаланс, гейт IMOEX выше EMA200). |
| `tools/research_runs.ps1` | Драйвер именованных наборов конфигов (`flat`, `wf`, `coins`, `antichase`, `current`, `anatomy`, `fut`) со сводной таблицей метрик. |
| `tools/search_slots_universe.ps1` | Поиск «состав корзины на число слотов» для C3b. Только исследование, канонический `$ASSETS` не трогает. |
| `tools/build_fut_combos.ps1` | Собирает `data/moex_fut/combos.json` (комбо C0/C1/C2/C3b, KPI, walk-forward) для вкладки фьючерсов. |
| `tools/rf_capital_calc.ps1` | Калькулятор капитала боевого C3b: ГО, шаг и стоимость шага из ISS, ATR14 из серий — сколько целых контрактов покупает риск-бюджет. |
| `tools/analyze.ps1` | EMA и RSI по символам в JSON. |
| `tools/analyze_losses.ps1` | Классификация каждой убыточной сделки в одну категорию отказа в `data/failed_trades.json`. |
| `tools/analyze_trade_anatomy.ps1` | Диагностика анатомии сделок: контекст входа, срезы по преднастроенным бинам, PASS/FAIL. Источник anatomy-фильтров. |
| `tools/analyze_v2_periods.ps1` | Метрики по подпериодам (медведь, восстановление, бык). |
| `tools/analyze_wf_years.ps1` | Walk-forward по годам, split 70/30; резерв печатается только с `-Final`. |

### 5.4 Загрузка данных

| Файл | Источник и результат |
|---|---|
| `tools/fetch_history.ps1` | BingX 4h в `data/<SYM>_4h.json` |
| `tools/fetch_history_deep.ps1` | Bybit v5 4h и фандинг до листинга в `data/deep/` |
| `tools/fetch_moex.ps1` | MOEX ISS дневки и часовики в `data/moex/` |
| `tools/fetch_moex_futures.ps1` | FORTS и непрерывные склейки с ratio-корректировкой и аудитом роллов в `data/moex_fut/` |
| `tools/bake_rf_candles.ps1` | **Только на VPS** (нужен токен): брокерские свечи в `data/live_rf/candles/`. Есть `-SnapshotOnly` и `-TimeBudgetSec`. |

### 5.5 Отчёт и публикация

| Файл | Что делает |
|---|---|
| `tools/build_vizdata.ps1` | **Сборщик данных дашборда.** Читает всё состояние и артефакты, пишет `report/vizdata.js` (`const VIZ = {...}`), копирует свечи в `report/rf_candles/`, кэш-бастит статические страницы, пишет `report/build.json`. |
| `tools/commit_state.ps1` | Коммит состояния бота, устойчивый к гонке. Exit 0 при успехе **или настоящей гонке пуша**; exit 1 на всём остальном (`Test-RaceRejection`). Общий для `tick.yml` и `manual-close.yml`. |
| `tools/deploy_site.ps1` | Пуш локальных изменений в GitHub (публикация дальше автоматически через `tick.yml`). |
| `tools/start_terminal.ps1` | Локальный статический сервер `report/` на `http://localhost:8377/`. |
| `tools/trigger_tick.ps1` | Резервный диспетчер: дёргает workflow через GitHub API, если cron задержался. |
| `tools/ask.ps1` | Терминальный клиент AI-ассистента (тонкая обёртка ssh; вся логика и ключи на VPS). |

### 5.6 Сторожа и обслуживание

| Файл | Что делает |
|---|---|
| `tools/live_watch.ps1` | **Внешний сторож живости обоих боевых контуров.** Живёт в GitHub Actions, а не на VPS — единственная точка обзора, переживающая смерть хоста. Сигнал = возраст последнего снапшота эквити; тишина дольше 60 мин даёт Telegram, дальше напоминания раз в 2 ч и отдельное сообщение о восстановлении. |
| `tools/live_smoke_test.ps1` | Надзорный смоук подписанного слоя Bybit. По умолчанию read-only; `-PlaceOrder` делает круг на минимальном лоте. |
| `tools/tinvest_selftest.ps1` | Проба и аудит T-Invest readonly-токеном: доступность, счета, весь универсум (uid, лот, шаг, ГО, расписания), латентность. |
| `tools/tinvest_universe_gate.ps1` | Гейт торгуемости для расширения универсума. Read-only, **обязательно с VPS**: хост T-Invest недоступен с ноутбука из-за корня УЦ Минцифры. |
| `tools/sandbox_drill.ps1` | Функциональная матрица боевого контура против живой песочницы T-Invest: `entry`, `stop`, `tp1`, `be`, `roll`, `mom`, `reject`, `idem`, `kill`, `crash`, `d2`. |

### 5.7 Прочие деревья

| Каталог | Что это |
|---|---|
| `assistant/` | AI-ассистент: Python 3, **только stdlib** (на VPS нет pip и venv). `bot.py`, `agent.py`, `tools_impl.py`, `actions.py`, `memory.py`, `scrub.py`, `llm.py`, промпты в `prompts/`. |
| `challenge/` | Автономный контур «30 дней»: свои `tools/` и `data/`, зависимостей от `tools/` нет. Заморожен. |
| `telegram-mini-app/` | Express и Vite/React кабинет. Остановлен, код инертен. |
| `strategy_lab/` | **Gitignored.** Самостоятельная Python-лаборатория (8671 бэктест): `run_all.py`, `data_fetch`, `strategies`, `backtest`, `robustness`, `xs_momentum`. С торговой системой не связана ничем. |
| `vps/` | **Gitignored целиком.** Справочный бандл с прежнего VPS (чужой бот OpenClaw v3, стратегии freqtrade, зашифрованные секреты). В публичный репозиторий попасть не должен. |
| `backups/` | **Gitignored.** Локальные git-бандлы и патчи, сотни МБ. |

---

## 6. VPS: юниты и шелл-обвязка

Всё в `deploy/`. Пользователь `trader`, кроме отмеченных как root.

### Шелл-скрипты

| Файл | Роль |
|---|---|
| `deploy/lib_tick.sh` | Общая fail-open плита обоих тиков: `tick_init`, `tick_pull`, `tick_engine`, `tick_push_retry`, `tick_commit_paths`, `tick_finish`. |
| `deploy/live_tick.sh` | Вход Bybit: pull, движок, на 15-минутных отметках или по флагу `.push_now` коммит `data/live_real` и `journal_live.md`, затем сторожа. |
| `deploy/live_rf_tick.sh` | Вход РФ: pull, движок, дешёвый снапшот презентации (`bake_rf_candles.ps1 -SnapshotOnly`), коммит заявки на ручное закрытие, если есть, на 15-минутных отметках публикация состояния, затем сторожа. Полная выпечка свечей вынесена в отдельный таймер (инцидент 2026-08-18). |
| `deploy/git_sync_watch.sh` | Три тик-сторожа и отправка в Telegram: `git_sync_watch` (состояние перестало публиковаться), `engine_watch` (движок вернул rc не 0), `disk_watch` (диск заполняется), `actions_watch` (сам GitHub Actions замолчал). Никогда не роняет тик. |
| `deploy/tick_alert.sh` | Обработчик `OnFailure=`: сообщает про единственный отказ, который ни один внутритиковый сторож увидеть не может — когда systemd убивает тик целиком по `TimeoutStartSec`. |
| `deploy/vps_cleanup.sh` | **root**, ночью: vacuum journald, apt clean, ротированные логи старше 30 дней, `~/.cache` старше 14 дней, ограниченный `git reflog expire`, `repack`, `prune`. Только по белому списку, поддерживает `DRY_RUN=1`. |
| `deploy/mini_app_url_watch.sh` | **root**, следил за URL быстрого туннеля Mini App. Мёртв по построению: читает journalctl отключённого юнита. |

### systemd

| Юнит | Тип | Примечание |
|---|---|---|
| `live-tick.service` и `.timer` | oneshot с `flock`, `TimeoutStartSec=110`, `OnFailure=tick-alert@` | каждую минуту в `:00` |
| `live-rf-tick.service` и `.timer` | то же | каждую минуту в `:30` |
| `rf-bake.service` и `.timer` | oneshot, `TimeoutStartSec=300` | только пишет файлы, git не трогает |
| `tick-alert@.service` | шаблон | подключается как `OnFailure=tick-alert@%%n.service` |
| `vps-cleanup.service` и `.timer` | oneshot от **root**, `Nice=10`, `IOSchedulingClass=idle` | |
| `trading-assistant.service` | simple, `Restart=always`, `ProtectSystem=full`, `MemoryMax=300M`, `CPUQuota=40%` | |
| `mini-app.service` | simple | **disabled** |
| `mini-app-url-watch.service` и `.timer` | oneshot от root | **disabled** |
| `mini-app-tunnel.service` | — | **в репозитории отсутствует**, см. BACKLOG |

---

## 7. Стратегии и параметры

### 7.1 Крипта v2 «комбо» (действует с 2026-07-10)

Регламент: `docs/strategy/strategy.md`. Сканер: `tools/scan_signals.ps1`, решение по **последнему
закрытому 4h-бару**.

Гейты входа (`scan_signals.ps1`):

| Гейт | Условие |
|---|---|
| `setupA` | тренд + касание отката + сброс RSI + триггерный бар |
| `btcFilter` | лонгам нужен `btcTrend != down`, шортам `!= up` |
| `flatMode` | вход запрещён, когда режим BTC 4h = range |
| `atrCap` | `atrPct <= 3.0` |
| `funding` | лонг при `fund <= +0.0005`, шорт при `fund >= -0.0005` |
| `fearGreed` | лонг блокируется при F&G >= 80, шорт при F&G <= 20 |
| `btcMom5d` | **только бумага**: лонги блокируются при импульсе BTC за 5 дней (30 баров 4h) >= +10% |
| `atrCapLong` | **только бумага**: лонги блокируются при `atrPct > 2.5` |

Управление позицией: риск 1% на сделку, не более 3 позиций, плечо до 5, TP1 = 1.5R (закрыть 50%),
затем перевод в безубыток и трейл раннера по закрытию 4h за EMA20. Комиссии Bybit: тейкер 0.055%
за сторону, слиппедж 0.03%, на стопах дополнительно 0.05%.

**Anatomy-фильтры (`-AnatomyFilters`) — только бумага.** Прошли walk-forward 2026-07-21
(PF 1.23 в 1.30, maxDD 34.7% в 28.6%), обоснование в `docs/backtests/trade_anatomy_paper_2026-07.md`.
`auto_trade.ps1` передаёт этот свитч, `live_engine.ps1` — нет. Перенос в реал требует отдельного
решения пользователя и до сих пор не сделан.

**Ловушка универсума.** Дефолт параметра `-Symbols` в `scan_signals.ps1` — это **live**-универсум,
потому что `live_engine.ps1` вызывает сканер без `-Symbols`. Бумага (`auto_trade.ps1`) передаёт свой
список явно. Итог:

| Контур | Список | Исключения | Торгуется |
|---|---|---|---|
| Бумага | 20 пар (`auto_trade.ps1:$SYMBOLS`) | `DOGE-USDT` | **19 пар** |
| Реал | те же 20 (дефолт сканера) | `XRP`, `APT`, `OP`, `AAVE` | **16 пар** |

### 7.2 Рынок РФ: профили C2 и C3b

Регламент: `docs/strategy/strategy_moex_fut.md`, боевой дизайн: `docs/strategy/live_tinvest_design.md`.

Три рукава, решения по дневным барам MOEX, входы по открытию следующей сессии, стопы по касанию
через часовики, платные роллы фронт-контрактов:

| Рукав | Правило | Функции в `lib_rf_signals.ps1` |
|---|---|---|
| Ядро (core) | Пробой Donchian-20 с re-arm 10 на 15, стоп 2×ATR14, трейл-шандельер 3×ATR | `Get-DonchianSide`, `Get-ChandelierStop` |
| Сетап A (setA) | Дневной трендовый откат к EMA20, стоп max(свинг, 1×ATR), TP1 1.5R (50%), безубыток, трейл EMA20 | `Get-SetupASignal`, `Test-SetAEma20Exit` |
| Momentum-акции | Топ-4 по импульсу 63 дня со скипом 21, гейт IMOEX выше EMA200, месячный ребаланс | `Get-MomentumTarget` |

Риск по профилям: **C2** = ядро 3% / setA 1% / mom 0.3 · **C3b** = ядро 5% / setA 2% / mom 0.5.
Боевой контур торгует **только C3b**.

### 7.3 Канонический блок констант

`tools/lib_rf_signals.ps1:11-28` — помечен «НЕ МЕНЯТЬ без walk-forward-протокола»:

```
$ATR_STOP_CORE=2.0  $ATR_TRAIL=3.0  $BRK_N=20  $REARM_N=10  $REARM_BARS=15
$ATR_STOP_A=1.0     $TPR=1.5        $PBLOOK=3  $RSI_TH=50
$MAXCONC=3          $MAXLEV=3       $HALT_PCT=0.06
$MOM_LOOKBACK=63    $MOM_SKIP=21    $MOM_TOPK=4  $MOM_JUMP=40.0  $IMOEX_EMA=200
$ASSETS  = BR, NG, GOLD, SILV, Si, CNY, MIX, Eu, COCOA, VTBR, PLD, SBRF     # 12 фьючерсов
$TICKERS = SBER, GAZP, LKOH, ROSN, NVTK, GMKN, TATN, MGNT, CHMF, PLZL, YDEX # 11 акций
```

**Места дублирования — править только синхронно:**

| Файл | Что продублировано | Защита |
|---|---|---|
| `tools/auto_trade.ps1:24-33` | крипто-константы | комментарий-зеркало |
| `tools/live_engine.ps1:31-46` | те же крипто-константы | явно: «MUST mirror tools/auto_trade.ps1:24-33» |
| `tools/bake_rf_candles.ps1:24-25` | собственная копия `$ASSETS` и `$TICKERS` | **только предупреждение в комментарии, автоматической сверки нет** |

Оговорка по универсуму РФ записана прямо в коде: расширение 8 в 12 (2026-08-12, RTS выведен,
добавлены Eu, COCOA, VTBR, PLD, SBRF) на бэктесте показало себя **хуже** прежней восьмёрки
(резерв 2.11%/мес против 5.14%, полный период 4.91% против 5.90%, просадка выше в обоих срезах).
Принято сознательным решением пользователя. Разбор: `docs/backtests/slots_universe_search_2026-08.md`
(но его цифры больше не воспроизводятся — см. BACKLOG).

Акция VTBR выведена из momentum-пула по технической причине: код фьючерса ВТБ совпадает с тикером
акции, а серии цен лежат в одном файле по имени — фьючерс в пунктах и акция в рублях затирали бы
друг друга.

### 7.4 Боевой конфиг RF (`$LIVE` в `live_rf_engine.ps1:29-60`)

| Ключ | Значение | Смысл |
|---|---|---|
| `base_rub` | 700 000 | база леджера рукава; **для core/setA переопределена ребейзом** |
| `core_risk` / `seta_risk` | 0.05 / 0.02 | риск C3b |
| `mom_weight` | 0.5 | momentum покупает на 0.5 от своего эквити |
| `go_cap_pct` / `go_trim_pct` | 0.60 / 0.75 → **переопределены в config.json на 0.75 / 0.90** | выше кэпа вход запрещён, выше trim идёт LIFO-закрытие |
| `reserve_rub` | 50 000 | неприкосновенный резерв вне бюджета ГО |
| `long_only` | `VTBR`, `SBRF` | по этим активам разрешён только лонг (`Test-SideAllowed`) |
| `profile_day_halt` | 0.08 | день −8% даёт `entries_halt` до завтра |
| `hard_dd` | 0.35 | −35% от пика: закрыть всё и поставить `HALT_RF_LIVE` |
| `max_orders_day` | 20 | предохранитель флуда заявок |
| `fee_est` | 0.00025 | тариф Т-Инвест по фьючерсам, 0.025% за сторону (уточнено 2026-08-13) |
| `trade_weekends` | `$false` | выходные внебиржевые сессии не торгуются |
| `margin_disabled` | `$false` → **`true` в config.json** | маржиналка на счёте отключена, `GetMarginAttributes` не зовётся |

**Гейт long-only намеренно НЕ в `lib_rf_signals.ps1`**: это свойство боевого счёта, а не стратегии.
Бумага и бэктест продолжают считать обе стороны, иначе бенчмарк перестанет быть сравнимым.
Причина ограничения: VTBR и SBRF — единственные **поставочные** фьючерсы в каноне, шорт в них
к экспирации превращается в продажу базовых акций, а маржинальная торговля на счёте выключена
(живые отказы брокера `i00041` 26.08 и `i00042` 27.08).

---

## 8. Данные и состояние

`data/` пишется скриптами — руками не трогать. Ключевое правило — «два писателя» из §2.

| Путь | Содержимое | Писатель |
|---|---|---|
| `portfolio.json` (корень) | счёт бумажной крипты, открытые позиции, карточки тезисов | Actions |
| `journal.md` / `journal_live.md` / `journal_live_rf.md` | append-only журналы событий (бумага / Bybit / РФ) | соответствующий контур |
| `data/*_USDT_4h.json` | кэш 4h-свечей 20 пар | `fetch_history.ps1` (вручную) |
| `data/deep/` | глубокая история 2020→2026 с фандингом | вручную |
| `data/v2/`, `data/fut_runs/`, `data/fut_wf*/` | исследовательские прогоны | вручную |
| `data/moex/`, `data/moex_fut/` | акции MOEX и фьючерсы FORTS (склейки, роллы, meta, combos) | вручную |
| `data/rf/` | состояние бумажных C2/C3b: `c2_portfolio.json`, `c3b_portfolio.json`, `rf_equity.json`, `rf_trades.json`, `shared.json`, `series/` | Actions |
| `data/live_real/` | боевой Bybit: `portfolio.json`, `live_trades.json`, `live_equity.json` | Bybit-VPS |
| `data/live_rf/` | боевой РФ: `portfolio.json` (в т.ч. `broker` — дословный снимок брокера, `broker_ledger` — комиссии и вариационка по операциям, `broker_pnl_by_card`), `equity.json` (колонки `bot_capital`, `bot_capital_account`, `var_margin`), `trades.json`, `config.json`, `candles/`, `series/` | RF-VPS |
| `data/rf_presentation_snapshot.json` | снимок для дашборда и Mini App | RF-VPS |

### `data/live_rf/config.json` — единственный способ править боевой конфиг

Переопределяет любой ключ `$LIVE`. Правки состояния идут **только через него**: VPS
перезаписывает `portfolio.json` своим.

```json
{ "base_rub": 700000,
  "funding": ["d6240afe-4e9c-49b6-8835-629f431c8506"],
  "sleeve_rebase": { "id": "2026-08-12-full-capital", "core": 1106481, "setA": 1106481 },
  "go_cap_pct": 0.75, "go_trim_pct": 0.90,
  "auto_rebase": { "enabled": true, "drift_pct": 0.05, "max_step_pct": 0.30 },
  "margin_disabled": true }
```

Размер сделки задаёт `eq_rub` рукава, а **не** потолок ГО и **не** `base_rub`.

### `data/rf/shared.json` — общее состояние контура РФ

`fronts` (текущий и следующий фронт-контракт по каждому активу с датами последних торгов),
`active` (актив в активный SECID), `rearm` (память re-arm Donchian по каждому профилю и активу),
`next_trade_id`, водяные знаки времени.

### Что gitignored и почему

`report/vizdata.js` и `report/build.json` — артефакты сборки, пересоздаются каждым тиком.
`report/rf_candles/` — копия под `report/` для страниц графиков (оригинал в `data/live_rf/candles`
коммитится). Логи, локи, кэши инструментов и состояния сторожей — локальные для хоста
(`tick_log.txt`, `engine.lock`, `.engine_watch_state`, `.disk_watch_state`, `.actions_watch_state`).
`.secrets/`, `trading-live.env`, `vps/`, `backups/`, `strategy_lab/` — не должны попадать в
публичный репозиторий. `.gitattributes` содержит `* -text`: конверсия EOL выключена, потому что
PS 5.1 чувствителен к BOM и CRLF, а диффы JSON-состояния должны быть стабильны.

---

## 9. Дашборд

`report/trades.html` — единая самодостаточная страница: HTML, инлайн-CSS с токенами светлой и
тёмной темы, три инлайн-скрипта (баннер ошибок, загрузчик, около 1400 строк логики). Внешних
CSS и JS нет.

**Два ортогональных ряда вкладок дают шесть панелей:**

| | Бумага | Реал | Бэктест |
|---|---|---|---|
| **Крипта** (Bybit, автобот 24/7) | `#pane-crypto-live` | `#pane-crypto-real` | `#pane-crypto-bt` |
| **Фьючерсы** (MOEX, брейкаут и сателлиты) | `#pane-fut-live` | `#pane-fut-real` | `#pane-fut-bt` |

Ряд стратегий `#stratRow` строится в рантайме.

Прочие страницы: `chart.html` (полноэкранный график с EMA/SMA/BB/VWAP/Ichimoku/PSAR и рисованием),
`charts.html` (мультиграфик), `backtest.html`, `index.html` (редирект на `trades.html`).

**Поток данных:** `tools/build_vizdata.ps1` читает состояние и артефакты → `report/vizdata.js`
(верхнеуровневые ключи `VIZ`: `generatedUtc`, `equityNow`, `prices`, `trades`, `equity`, `moexFut`,
`livePositions`, `liveClosed`, `liveDaily`, `rfLive`, `rfReal`, `failedTrades`, `strategies`,
`deepPrices`, `signals`, `liveActual`, `realLive`) → `upload-pages-artifact` от каталога `report/`
→ отдельная job `deploy-pages`. Клиент сначала тянет `build.json` с `cache: no-store`, потом
подключает `vizdata.js?v=<версия>`, и дальше опрашивает `build.json`, чтобы показать баннер
обновления.

Локальный просмотр: `tools/start_terminal.ps1 -Launch` → `http://localhost:8377/`.

---

## 10. Предохранители и алертинг

### Kill-файлы (коммит в main; действуют на ближайшем тике)

| Файл | Действие |
|---|---|
| `data/HALT` | глобальный: все тики выходят сразу, позиции не трогаются |
| `data/HALT_LIVE` | Bybit: без новых входов |
| `data/HALT_CLOSE` | Bybit: принудительное закрытие всего |
| `data/HALT_RF_LIVE` | РФ: без новых входов |
| `data/HALT_RF_CLOSE` | РФ: принудительное закрытие всего |
| `data/HALT_RF_ENTRIES` | РФ: точечная блокировка входов |

### Автоматические стопы

- Bybit (`live_engine.ps1:638`, `:656`, `:660`): дневной лимит −5% от эквити на старт суток (блокирует входы
  до следующих UTC-суток), мягкая просадка −16% от пика (риск новых сделок ×0.5, снимается при
  возврате выше −12%), **hard-halt −35% от пика** (флэттен по рынку + `trading_halted`).
- РФ: профиль-день −8% ставит `entries_halt` до завтра (снимается новым днём автоматически);
  **hard-halt −35% от пика** закрывает всё и ставит `HALT_RF_LIVE`.
- ГО: выше `go_cap_pct` вход запрещён, выше `go_trim_pct` идёт LIFO-закрытие последней позиции.
- При нехватке ГО лоты урезаются в цикле, пока заявка не пройдёт governor.

### Пять сторожей

| Сторож | Где живёт | Что видит | Слепая зона |
|---|---|---|---|
| `tools/live_watch.ps1` | **GitHub Actions** | возраст снапшота эквити обоих боевых контуров | падение самого Actions |
| `git_sync_watch` | внутри тика на VPS | состояние перестало публиковаться | смерть хоста |
| `engine_watch` | внутри тика на VPS | движок вернул rc не 0 | смерть хоста |
| `disk_watch` | внутри тика на VPS | диск заполняется | смерть хоста |
| `actions_watch` | внутри тика на VPS | GitHub Actions замолчал | смерть хоста |
| `tick_alert@` | systemd `OnFailure=` | systemd убил тик целиком по таймауту | — |

Ключевой урок серии августовских инцидентов: **сторож внутри тика умирает вместе с тиком**.
Поэтому `live_watch.ps1` вынесен в Actions — это единственная проверка, переживающая смерть VPS.
Второй урок (12.08): проверять надо **доставку** алерта, а не факт детекта. Диагностика Telegram:
401 = неверный токен, 404 = мусор в URL (обычно хвостовой перевод строки при вставке секрета).

### AI-ассистент

Читает всё, пишет почти ничего. Единственное действие записи — закрытие **бумажной** позиции
через подтверждение в Telegram (`reason=manual-tg`, заявка в `data/rf/manual_close_req.json`,
которую подхватывает workflow `manual-close.yml`). Гейтится флагом `ASSISTANT_DRY_ACTIONS`.

---

## 11. Тесты

Восемь наборов. **Общего раннера нет, в CI не гоняется ни один** — запускаются вручную.

| Набор | Как запустить | Что покрывает |
|---|---|---|
| `tools/test_live_rf.ps1` | `powershell -File tools\test_live_rf.ps1 [-Only converters\|sizing\|report\|scenarios]` | Конвертеры (`Q2D`/`D2Q`, `ConvertTo-TiIso` с регрессией pwsh 7), сайзинг (пункты в рубли, целые лоты, кэпы, худший случай ГО), отчёты (поток владельца против клиентского), затем делегирует сценарии |
| `tools/test_live_rf_scenarios.ps1` | через файл выше, самостоятельно не запускается | **66 сценариев** против движка на mock-транспорте, без сети и токена. Каждый: чистый корень, фикстуры, очередь mock, тики движка в дочернем процессе, проверки JSON. Группы: вход/отказ/потеря-adopt/repost/qty0, матрица кэпа и трима ГО, hard-DD, дневной халт, дрифты D2/D4/D5/D6, дефицит и профицит акций, клиринг, выходные, kill-файлы, флуд, TP1-синк, роллы, momentum-ребаланс, восстановление после краха, фандинг, dryrun e2e, цена входа, ребейз рукавов, вечернее подтверждение, авто-ребейз, маржиналка, long-only |
| `tools/test_commit_state.ps1` | `powershell -File tools\test_commit_state.ps1` | `commit_state.ps1` на одноразовых репозиториях с подстроенной гонкой пуша. Отдельно проверяет, что **настоящие** отказы (протухшие креды, битый remote) остаются громкими, а не маскируются под гонку. Скрипт зовётся дочерним процессом, проверяется `$LASTEXITCODE` — исходный баг был именно в коде возврата |
| `tools/test_tinvest_mock_contract.ps1` | `powershell -File tools\test_tinvest_mock_contract.ps1` | Контракт формата mock-лога JSONL (`body` остаётся JSON-строкой внутри записи) |
| `tools/test_git_sync_watch.sh` | `bash tools/test_git_sync_watch.sh` | **Доставка** алертов, не детект: `curl` подменён заглушкой с заданными HTTP-кодами (200 успех, 401/404/000 отказ, без токена — тихий no-op). `ALERTED` обязан остаться 0 на недоставленном алерте |
| `tools/test_tick_runners.sh` | `bash tools/test_tick_runners.sh` | Контракт `deploy/lib_tick.sh` с подменёнными `git`, `pwsh`, `curl`, `date`: общий pull, вызов движка, отказ коммита доходит до сторожа, ретрай гонки с `--autostash`, публикация на 15-минутных отметках, **полной выпечки свечей в тике больше нет**, дешёвый снапшот остаётся ежеминутным |
| `assistant/tests/run_all.py` | `python -m assistant.tests.run_all` | 11 классов офлайн: сдерживание путей (побег из корня, `.secrets`, `vps/`, `.git`), вычистка секретов, кодировки и BOM от PS 5.1, обрезка истории, схемы инструментов, контекст рынка, валидация ключей, цикл агента, ручное закрытие (TTL, чужой чат не может подтвердить, DRY-песочница) |
| `telegram-mini-app/server/contracts.test.js` | `npm --prefix telegram-mini-app run test:contracts` | 5 контрактов DTO дашборда РФ и крипты, предпочтение снапшота презентации, отсутствие внутренних ошибок в строках портфеля |

### Надзорные проверки (нужны реальные креды, в набор не входят)

`tools/live_smoke_test.ps1` (`-PlaceOrder` тратит реальные центы), `tools/sandbox_drill.ps1`
(живая песочница T-Invest, только в торговые часы), `tools/tinvest_selftest.ps1`,
`tools/tinvest_universe_gate.ps1`.

### Релиз-гейт (`.refactor-plan.md`)

1. Просмотреть коммиты по одному.
2. Прогнать `python -m assistant.tests.run_all` и `tools/test_live_rf.ps1` в изолированном окружении.
3. **Не использовать реальный тик, ордер на testnet или деплой как способ проверки рефакторинга.**

---

## 12. Секреты и конфигурация

Значений здесь нет и быть не должно — только имена и места.

| Где | Что лежит |
|---|---|
| `/etc/trading-live.env` на VPS (0600 root) | `BYBIT_API_KEY`, `BYBIT_API_SECRET`, `TG_BOT_TOKEN`, `TG_CHAT_ID`, `TG_CHAT_ID_FUT`, `LIVE_DRYRUN`, `TINVEST_TOKEN`, `TINVEST_ACCOUNT_ID`, `TINVEST_MODE`, `TINVEST_SANDBOX_TOKEN`, пороги сторожей |
| `/etc/trading-assistant.env` на VPS | `OPENROUTER_API_KEY`, список разрешённых Telegram-ID, `ASSISTANT_DRY_ACTIONS`, `MINI_APP_URL` (сейчас снят) |
| GitHub → Settings → Secrets | `TG_BOT_TOKEN`, `TG_CHAT_ID`, `TG_CHAT_ID_FUT` — нужны сторожу `live_watch.ps1`; без них он молчит |
| `.secrets/tinvest.env.ps1` (локально, gitignored) | токены T-Invest для локальных проб и дрилла |
| `tools/ask.config.json` (локально, gitignored) | адрес и ключ VPS для терминального клиента ассистента |
| `telegram-mini-app/.env` (gitignored) | `BOT_TOKEN`, `WEB_APP_URL`, `ALLOWED_TELEGRAM_IDS` и прочее |

Ключи Bybit — **trade-only без права вывода**, с белым списком IP.
Корень УЦ Минцифры для T-Invest закреплён по SHA-256 (см. `RESTORE.md`).
Второй long-polling на том же `BOT_TOKEN` даёт 409 и убивает ассистента — поэтому Mini App и бот
не могут работать на одном токене одновременно.

---

## 13. Карта документации

| Файл | Статус | О чём |
|---|---|---|
| `docs/PROJECT.md` | **канон** | этот файл |
| `docs/BACKLOG.md` | **канон** | нерешённые задачи |
| `README.md` | точка входа | что это, команды, правила сессии |
| `docs/overview.md` | точка входа | короткий обзор архитектуры |
| `RESTORE.md` | канон | аварийное восстановление с нуля, 14 разделов |
| `.refactor-plan.md` | канон | отложенные высокорисковые рефакторинги и релиз-гейт |
| `docs/strategy/strategy.md` | **действующий регламент** | крипта v2 «комбо» |
| `docs/strategy/strategy_moex_fut.md` | **действующий регламент** | РФ v1; таблицы внутри описывают прежнюю восьмёрку, есть врезка об этом |
| `docs/strategy/live_tinvest_design.md` | **действующий дизайн** | боевой C3b, реестр вопросов, разборы инцидентов |
| `docs/strategy/strategy_v2_proposal.md` | история | предложение v2, принято 2026-07-10 |
| `docs/archive/strategy_v1_archive.md` | архив | замороженный регламент v1 |
| `deploy/README.md` | runbook | деплой Bybit LIVE |
| `deploy/README_RF.md` | runbook | RF-LIVE, фазы запуска, аварийные процедуры |
| `deploy/README_ASSISTANT.md` | runbook | ассистент; содержит незакрытую «Фазу 2» |
| `deploy/README_CLEANUP.md` | runbook | очистка диска VPS |
| `deploy/README_MINIAPP.md` | runbook | Mini App; контур остановлен |
| `challenge/report.md` | архив | пост-мортем челленджа; **утверждение «остаётся в тике» устарело** |

### Бэктесты (`docs/backtests/`)

| Файл | Вердикт |
|---|---|
| `backtest_current_strategy_2026-07.md` | **канон текущего боевого конфига крипты** |
| `backtest_report.md`, `backtest_v2_report.md`, `backtest_pairs_expansion.md` | исторические обоснования v1 и v2 |
| `trade_anatomy_paper_2026-07.md` | принято, внедрено **только на бумагу** |
| `anti_chase_walkforward.md` | **отклонено** walk-forward'ом |
| `intraday_confirm_2026-08.md` | **отклонено на IS**, резерв не вскрывался |
| `clamped_trail_rf_core_2026-08.md` | **отказ на этапе A'**, испытание не потрачено |
| `universe_expansion_2026-08.md` | **отклонено на dev** (8 в 16) |
| `slots_universe_search_2026-08.md` | **принято** (n=12, слоты 3+3); цифры больше не воспроизводятся |
| `long_only_vtbr_sbrf_2026-08.md` | ограничение брокера эдж не ухудшает, а улучшает |
| `rf_capital_calc_*.md` | таблицы сайзинга; актуальна версия `_pool25` |

**Правило пользователя:** изменения правил бота — только через walk-forward по годам
(dev 70% / резерв 30%, добавления по одному, финал на резерве один раз, критерий фиксируется
до вскрытия).

---

## 14. Хронология инцидентов

У всех восьми одна форма: **отказ был не в торговой логике, а в том, что её вход тихо остался
без данных.** Ни один не потерял деньги напрямую — теряли время работы контура и достоверность
статистики.

| Дата | Что случилось | Чем закрыто |
|---|---|---|
| 2026-07-27 | Ложный D4-карантин на живой позиции L00011: карантин и `entries_halt` висели трое суток без авто-снятия | `f933eb49f`, `6fa953f52` — снимаются автоматически, когда расхождение перестаёт подтверждаться |
| 2026-08-03 | Т-Инвест переключил цепочку TLS на корень Минцифры: каждый тик падал на преflight около часа. Отдельно кончилась подписка VPS — оба боевых контура молчали 6 ч 45 мин **без единого алерта**, потому что весь алертинг жил внутри тика | Корень закреплён по SHA-256; внедрён внешний сторож `tools/live_watch.ps1` в `tick.yml`; `Note-BrokerFail`/`Note-BrokerOk` и симметричные `Note-ApiFail`/`Note-ApiOk` |
| 2026-08-04 | Цена входа бралась из **поданной** заявки, а не из исполненной (`initial_order_price_pt` против `executed_order_price`): портились P&L, дистанция стопа и статистика. `Invoke-Reconcile` сверяет лоты, а не цены | `56a40eacd` — лестница кандидатов, сначала исполненная цена. Регрессии `entry-px-exec` и `entry-px-repair`. **Остаточный эффект не устранён — см. BACKLOG** |
| 2026-08-07 | Заполнился диск VPS; отдельно гейт одобрения github-pages замёрз внутри job `tick`, а concurrency-группа держала весь ран — бумажная торговля стояла 17.5 ч | `fab0f985d` — публикация вынесена в отдельную job со своей группой; `disk_watch` и `vps-cleanup.timer` |
| 2026-08-11 | `deploy/live_rf_tick.sh` лежал в git как 100644; ручной `chmod` на VPS ронял autostash — RF-контур молчал 27 ч (1618 провалов юнита). Сторож **детектил**, но алерты уходили в никуда | `c7e61d2de` — бит исполнения несётся в коммите; секреты TG в Actions заведены, доставка подтверждена боем 12.08 |
| 2026-08-11 | Ветка D4 писала `exitReason='stop'` безусловно — внешнее закрытие считалось стопом | `36d972c2d` — появился `manual-ext` |
| 2026-08-12/13 | `Invoke-LiveDaily` засеивал `$st.active` только когда он `$null`: пять активов, добавленных 12.08, никогда не получили SECID и **месяц молча не торговались**. Тот же баг на бумаге, поэтому бенчмарк тоже врал. Цена: Eu +8.9%, PLD +8.0% мимо | `d1222ecda` — досев на каждом дневном хуке; добавлена `Invoke-DailyReadinessCheck` |
| 2026-08-17 | Гонка пуша краснила тик и пропускала публикацию Pages. Внешний аудит нашёл в самом фиксе две дыры: отказ публикации выдавался за гонку, а тест мог писать в боевой репозиторий | `bd75cda49`, `472a74eae`, `9b4496ebe` — логика вынесена в `commit_state.ps1` с явным контрактом кодов возврата и тестом на гонку |

---

## 15. Куда смотреть дальше

- **[BACKLOG.md](BACKLOG.md)** — что открыто и требует решения.
- `RESTORE.md` — подъём системы с нуля.
- `docs/strategy/` — действующие регламенты.
- `docs/backtests/` — обоснования решений.
- `deploy/README*.md` — runbook'и боевых контуров.
- Журналы (`journal.md`, `journal_live.md`, `journal_live_rf.md`) — фактическая летопись.
  Технический долг в этом проекте пишется прозой именно туда, а не маркерами `TODO` в коде.
