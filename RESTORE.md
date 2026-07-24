# RESTORE — подъём trading-sim с нуля

Что делать, если умер ноут, умер VPS, пропал GitHub-аккаунт — или всё сразу.
Здесь торгуются **реальные деньги** (Bybit ~$100 + Т-Инвестиции, счёт `2154036525`),
поэтому документ начинается не с восстановления, а с **защиты капитала**.

Порядок разделов = порядок действий. Сначала прочти раздел 0 целиком, только потом восстанавливай.

Актуально на 2026-07-24. Правь этот файл каждый раз, когда меняешь состав системы, ключи,
таймеры или капитал.

Секретов в этом документе нет — только имена переменных и пути к их источникам.

---

## 0. АВАРИЯ — триаж (сначала прочти это)

Пока система лежит, деньги остаются на рынке. Первым делом — не восстановить, а **защитить**.

**Шаг 1. Понять, что умерло.** Ноут (dev)? VPS (боевые контуры)? GitHub (код + paper + публикация)?
От этого зависит, что вообще под угрозой:
- Умер **только ноут** — боевые контуры на VPS живут сами, ничего срочного; восстанавливай ноут спокойно.
- Умер **VPS** — боевые контуры не тикают: см. шаг 2, это срочно.
- Умер **GitHub** — VPS не может `git pull`, но торгует на локальном состоянии; paper-бот и дашборд стоят.

**Шаг 2. Защита капитала. Приоритет: РФ первым, Bybit вторым.**

Почему такой порядок — РФ-контур операционно хрупче: фьючерсы FORTS имеют **экспирацию** (нужен
ролл фронт-контракта), рублей на счёте почти нет (бот перед сделкой продаёт USD/серебро —
**авто-финансирование**), стоп трейлится/перевзводится движком. Пока VPS мёртв, **ничего из этого
не происходит**.

- **РФ (Т-Инвестиции), счёт `2154036525`** — открыть приложение Т-Инвестиций и по **каждой**
  открытой позиции проверить, стоит ли **живая стоп-заявка**.
  - В проде (`emulate_stops = false`, текущий `config.json`) стопы стоят **реальной заявкой у
    брокера** и переживают смерть VPS. Но защита **не абсолютна** — позиция может оказаться
    голой, если её застало в один из моментов: только что вошла (стоп ещё не выставлен);
    идёт перевзвод/трейл (cancel→post, «голое окно» в секунды); стоп отложен вне сессии/клиринга
    (батч в 09:45 MSK); идёт ролл (нога 1 = снять стоп + market); или конфиг когда-то был с
    `emulate_stops:true` (песочница).
  - **Любую позицию без живого стопа — закрыть руками или выставить стоп-заявку из приложения.**
  - Помни: пока VPS лежит, **нет трейла/BE, нет ролла (риск экспирации фьючерса), нет
    авто-финансирования, нет mom-ребаланса.** Если авария затягивается — веди эти позиции руками
    или закрой их до восстановления.
- **Bybit (~$100)** — стоп всегда стоит **на бирже** (Full-mode SL), перпы без экспирации.
  Контур терпит смерть VPS лучше. Проверить позиции стоит, но это второй приоритет.

**Шаг 3. Не поднимай VPS «как был».** Прямой перезапуск = торговля на устаревшем состоянии и
риск двух писателей (см. раздел 6). Восстановление боевых контуров — **только** через раздел 6
(остановленный старт → reconcile → снятие HALT по одному).

---

## 1. Топология системы

Один VPS + GitHub Actions + ноут (dev). Пять «контуров», три из них — на VPS.

| Контур | Где исполняется | Точка входа | Движок | Универсум | Пишет в git (пути) |
|---|---|---|---|---|---|
| PAPER крипта (бенчмарк) | GitHub Actions `tick.yml` | — | `tools\auto_trade.ps1 -Cloud` | 19 пар (`auto_trade.ps1`, −DOGE) | `portfolio.json`, `journal.md`, `data`, `challenge\portfolio.json` |
| PAPER РФ C2/C3b | внутри paper-тика | — | `tools\rf_engine.ps1` | 8 фьюч + 12 акций | `data\rf\*` |
| **Bybit LIVE (реал)** | VPS таймер `live-tick` (:00) | `deploy\live_tick.sh` | `tools\live_engine.ps1` | 16 пар (−XRP/APT/OP/AAVE) | `data\live_real\*`, `journal_live.md` |
| **RF LIVE (реал ₽)** | VPS таймер `live-rf-tick` (:30) | `deploy\live_rf_tick.sh` | `tools\live_rf_engine.ps1` | 8 фьюч + 12 акций | `data\live_rf\*`, `journal_live_rf.md` |
| AI-ассистент (read-only) | VPS `trading-assistant.service` | — | `python3 -m assistant.bot` | — | `data\rf\manual_close_req.json` (только закрытие paper) |

**Потоки:**
- Ноут (dev) → `git push` main → GitHub Actions гоняет paper-тик каждые ~15 мин и публикует Pages.
- VPS → `git pull` main каждый тик → крутит два таймера (`:00` Bybit, `:30` РФ — намеренно
  **в антифазе**, чтобы не драться за `index.lock`) + ассистента → пушит **только свои** пути
  состояния (явные `git add`, никогда `git add data` целиком).

**Правило «двух писателей быть не должно»:** paper-состояние пишет только Actions, `data\live_real`
— только Bybit-VPS, `data\live_rf` — только RF-VPS. Локальные тики руками не запускать, пока
работает облако/VPS.

VPS: Ubuntu 24.04, пользователь `trader`, репозиторий склонирован в `/home/trader/paper-desk`
(**на VPS имя `paper-desk`, не `trading-sim`**).

---

## 2. Что должно быть на руках

| Источник | Что там |
|---|---|
| GitHub `klyde149-arch/paper-desk` | весь код, `docs\`, `deploy\`, `report\`, и состояние в git (`portfolio.json`, `journal*.md`, `data\live_real`, `data\live_rf`, `data\rf`) |
| Бандл `vps\secrets\vps_secrets.enc` | AES-256-шифрованные ключи (исходник TG-токена/чата и пр.); локальный, в git не лежит |
| `.secrets\tinvest.env.ps1` | локальные T-Invest токены для dev-прогонов с ноута |
| Подписка Claude Max | для агент-сессий (анализ/доработки) |
| **Резервные коды 2FA** | **где лежат** коды Bybit 2FA и Т-Банк/Т-Инвестиции 2FA — без них не войти в биржу/брокера, а значит не увидеть позиции и не перевыпустить ключи. (Значения — в менеджере паролей/сейфе, НЕ здесь.) |

Если бандла секретов нет — ключи перевыпускаются:
- **Bybit:** новый API-ключ, **trade-only, без вывода средств, с IP-whitelist** нового VPS.
- **T-Invest:** токены по фазам — readonly → sandbox → полный (trade).
- **Telegram:** bot token + chat id (основной `TG_CHAT_ID` и фьючерсный `TG_CHAT_ID_FUT`).
- **OpenRouter:** ключ для ассистента.

Полный список имён переменных — в `deploy\trading-live.env.example`.

---

## 3. GitHub-сторона

`tick.yml` **не использует ни одного пользовательского секрета** (`secrets.*`): пуш и публикация
Pages идут через встроенный `GITHUB_TOKEN` (в workflow объявлены `permissions: contents: write`,
`pages: write`, `id-token: write`). Поэтому paper-бот **не требует Actions-секретов** — но
«поднимается сам» только при восстановленных GitHub-настройках:

- Репозиторий `klyde149-arch/paper-desk` восстановлен + есть доступ к аккаунту (логин, **2FA/recovery**).
- **Actions включены**; права workflow — **read and write**.
- **Pages: `Source = GitHub Actions`**; окружение `github-pages` существует; `report\.nojekyll` на месте.
- **Deploy-keys** (Settings → Deploy keys): именно по SSH deploy-key VPS пушит своё состояние.
  При DR старый ключ **отозвать** (раздел 6), новый — завести для нового VPS.

Идентичности коммитов (важно для проверки «кто пишет»): paper-тик коммитит как **`paper-desk-bot`**,
VPS-тики — как **`live-desk-bot`**.

---

## 4. Репозиторий

На ноут и на VPS:

```powershell
git clone https://github.com/klyde149-arch/paper-desk.git   # ноут: куда удобно
# VPS:
git clone git@github.com:klyde149-arch/paper-desk.git /home/trader/paper-desk
```

Проверка «на месте»: `README.md`, `docs\`, `deploy\`, `tools\`, `report\`, `challenge\`.

---

## 5. Секреты и конфиг (не в git — воссоздать руками)

**Красная линия:** реальных ключей в дереве репозитория быть НЕ должно. Живут они только на VPS
(`/etc/*.env`, root:root 600) и локально на ноуте (`.secrets\`).

| Файл (где) | Переменные (имена) |
|---|---|
| `/etc/trading-live.env` (VPS; шаблон `deploy\trading-live.env.example`) | `BYBIT_API_KEY`, `BYBIT_API_SECRET`, `TG_BOT_TOKEN`, `TG_CHAT_ID`, `TG_CHAT_ID_FUT`, `LIVE_DRYRUN`, `TINVEST_TOKEN`, `TINVEST_ACCOUNT_ID`, `TINVEST_MODE`, `TINVEST_SANDBOX_TOKEN` |
| `/etc/trading-assistant.env` (VPS) | `OPENROUTER_API_KEY`, `ASSISTANT_MODEL`, `ASSISTANT_MODEL_FALLBACK`, `ASSISTANT_TG_ALLOWED_CHATS`, `ASSISTANT_DRY_ACTIONS`, `ASSISTANT_DAILY_*` |
| `.secrets\tinvest.env.ps1` (ноут, gitignored) | те же `$env:TINVEST_*` для локальных прогонов |
| `tools\ask.config.json` (ноут, gitignored) | `vps`, `key` — ssh-доступ к VPS для `tools\ask.ps1` |
| `~/.ssh/id_ed25519` (VPS) | GitHub deploy-key с write-доступом к `paper-desk` |

Расшифровка бандла: `vps\secrets\vps_secrets.enc` (AES-256-CBC) — процедура в `vps\README.md` (локальный).

**Ловушка капитала.** `git clone` восстанавливает `data\live_rf\config.json` со значением
`"base_rub": 700000` — то есть **полный рабочий капитал сразу**. После DR перед снятием HALT по
РФ его нужно **понизить** (раздел 8).

---

## 6. Подъём VPS: остановленный старт → reconcile → снятие HALT по одному

Именно в этом порядке. Прямой запуск таймеров без сверки = торговля на устаревшем состоянии.

1. **Отрезать старого писателя.** В GitHub Settings → Deploy keys **отозвать старый ключ**.
   Убедиться, что старый VPS больше не пушит:
   ```bash
   git log --format='%an %ci' -- data/live_real data/live_rf | head
   ```
   После снятия старого хоста свежих коммитов `live-desk-bot` быть не должно. Иначе два живых
   писателя шлют ордера параллельно.

2. **Базовая настройка VPS.** По `deploy\README.md`: PowerShell 7, chrony (синхронизация часов —
   критично для подписи Bybit), пользователь `trader`, новый deploy-key. Затем `git clone`
   (раздел 4) и секреты (раздел 5).

3. **Заглушить контуры ДО запуска.** Закоммитить в main пустые файлы:
   ```bash
   : > data/HALT_LIVE ; : > data/HALT_RF_LIVE
   git add data/HALT_LIVE data/HALT_RF_LIVE && git commit -m "DR: halt live contours" && git push
   ```

4. **Установить и включить юниты — контуры поднимутся в остановленном виде** (тикают только
   reconcile/лог, без торговли; открытые позиции живут на брокерских/биржевых стопах):
   ```bash
   sudo cp deploy/live-tick.service deploy/live-tick.timer /etc/systemd/system/
   sudo cp deploy/live-rf-tick.service deploy/live-rf-tick.timer /etc/systemd/system/
   sudo cp deploy/trading-assistant.service /etc/systemd/system/
   chmod +x deploy/*.sh
   sudo systemctl daemon-reload
   sudo systemctl enable --now live-tick.timer live-rf-tick.timer trading-assistant
   ```

5. **Kill-drill — убедиться, что HALT реально останавливает тик, ДО того как на него полагаться.**
   `tools\sandbox_drill.ps1` прогоняет все 4 РФ-файла (`HALT`, `HALT_RF_LIVE`, `HALT_RF_CLOSE`,
   `HALT_RF_ENTRIES`); отдельно проверить Bybit (`HALT_LIVE`, `HALT_CLOSE`). Коммит файла в main
   → следующий `git pull` на VPS его доставит.

6. **Reconcile.** Сверить **фактические** позиции на бирже и у брокера с журналами и состоянием:
   - Bybit: `journal_live.md`, `data\live_real\portfolio.json` ↔ факт на бирже (`/v5/position/list`).
   - РФ: `journal_live_rf.md`, `data\live_rf\portfolio.json` ↔ факт в Т-Инвестициях.
   Разрешить все дрифты. **Ручные изменения из триажа (раздел 0) движок увидит как дрифт** —
   учесть это при сверке, до включения торговли.

7. **Снимать HALT по одному контуру.** Сначала один (например РФ — с пониженным `base_rub`,
   раздел 8), дождаться **чистого тика и сверки**, только потом второй. Не снимать оба разом.

Аварийная остановка в любой момент: `sudo systemctl stop live-tick.timer live-rf-tick.timer`.

---

## 7. Bybit-live контур

Ранбук: `deploy\README.md`. Суть:
- Ключи **trade-only + IP-whitelist**; в `/etc/trading-live.env`.
- Гейт `LIVE_DRYRUN`: `1` = DryRun (ордера логируются «WOULD PLACE», не ставятся), `0` = реал.
  При go-live сначала прожить DryRun, потом переключить.
- Универсум — 16 пар: полный список из 20 в `tools\live_engine.ps1`, `$EXCLUDED = XRP-USDT,
  APT-USDT, OP-USDT, AAVE-USDT`. Константы движка обязаны зеркалить `auto_trade.ps1`.
- Стоп всегда на бирже (Full-mode SL); биржа — источник истины (`/v5/execution/list`).
- Килл: `data\HALT` (глобально), `data\HALT_LIVE` (без новых входов), `data\HALT_CLOSE`
  (закрыть всё рыночными и остановиться).
- Смоук: `tools\live_smoke_test.ps1` (read-only; `-PlaceOrder` — round-trip минимальным лотом).

---

## 8. RF-live контур (Т-Инвестиции)

Ранбуки: `deploy\README_RF.md` (операционный, фазы) + `docs\strategy\live_tinvest_design.md` (дизайн-канон).

- Счёт `2154036525`; режим из `TINVEST_MODE` (`dryrun` | `sandbox` | `prod`).
- Универсум (общий с paper, `tools\lib_rf_signals.ps1`): 8 фьючерсов FORTS
  (`BR, NG, GOLD, SILV, Si, RTS, CNY, MIX`) + 12 акций TQBR
  (`SBER, GAZP, LKOH, ROSN, NVTK, GMKN, TATN, MGNT, VTBR, CHMF, PLZL, YDEX`).
- Стопы у брокера (`emulate_stops = false` в проде); `hard_dd = 0.35` (просадка −35% от пика сама
  пишет `data\HALT_RF_LIVE`).
- Килл-файлы (4): `data\HALT` / `data\HALT_RF_LIVE` (движок не тикает, позиции на брокерских стопах),
  `data\HALT_RF_ENTRIES` (только блок входов), `data\HALT_RF_CLOSE` (закрыть всё рыночными).
- Оверрайды без правки кода — `data\live_rf\config.json` (shallow-override `$LIVE`): ключи
  `base_rub`, `hard_dd`, `whitelist`, `max_lots_override`, `mom_enabled`, `emulate_stops`, риски
  плеч и окна времени MSK.

**После DR (обязательно):** `config.json` из git = `base_rub 700000`. Перед снятием HALT по РФ
**понизить на первые сутки** (например `{ "base_rub": 175000 }`), дождаться чистого тика и сверки,
затем вернуть штатный рамп (175k → 350k → 700k по `deploy\README_RF.md`, Phase 4).

Смоук: `tools\tinvest_selftest.ps1` (аудит счёта/8 фьюч/12 акций/клирингов/латентности),
`tools\sandbox_drill.ps1` (полный цикл + kill-drill в песочнице).

---

## 9. AI-ассистент

Ранбук: `deploy\README_ASSISTANT.md`. Демон `trading-assistant.service` (python3, только stdlib,
long-polling Telegram). Ключ — `OPENROUTER_API_KEY` в `/etc/trading-assistant.env`.
**Только чтение**, единственное действие записи — закрытие **paper** РФ-позиции (пишет
`data\rf\manual_close_req.json` → срабатывает `manual-close.yml`). Живые контуры (Bybit/T-Invest)
трогать не может. Клиент с ноута — `tools\ask.ps1` (по ssh).

---

## 10. Paper-контур (GitHub Actions)

`.github\workflows\tick.yml` — cron `4,19,34,49 * * * *` (непопулярные минуты) + `workflow_dispatch`
+ push в main. `runs-on: windows-latest`. Шаги: probe эндпоинтов → `auto_trade.ps1 -Cloud -SkipViz`
→ `build_vizdata.ps1 -NoDeploy` → commit (`paper-desk-bot`) `portfolio.json journal.md data
challenge/portfolio.json` → Pages artifact = `report\`.
`.github\workflows\manual-close.yml` — лёгкий обработчик ручных закрытий paper.

**Секретов не требует**, но зависит от GitHub-настроек (раздел 3). Килл — `data\HALT`.
Проверка: `workflow_dispatch` → зелёный прогон, Pages обновился.

---

## 11. Дашборд

`tools\build_vizdata.ps1` → `report\vizdata.js` (**gitignored**, пересобирается каждый тик).
`tools\bake_rf_candles.ps1` (**только VPS**, нужен T-Invest токен) печёт свечи в
`data\live_rf\candles\*` (коммитятся) → `build_vizdata.ps1` зеркалит их в `report\rf_candles\`
(gitignored), потому что браузер/Pages видит только `report\`. Публикация — `tick.yml` (Pages).
Локальный превью: `tools\start_terminal.ps1` → http://localhost:8377/
(публичный — https://klyde149-arch.github.io/paper-desk/).

---

## 12. Канон / источники правды

| Что | Где |
|---|---|
| Правила paper-стратегии | `docs\strategy\strategy.md` |
| Перф прод-конфига (1.65%/мес, PF 1.26, maxDD 30%) | `docs\backtests\backtest_current_strategy_2026-07.md` |
| РФ-эдж + портфели C2/C3b | `docs\strategy\strategy_moex_fut.md` |
| RF-live дизайн (Т-Инвестиции) | `docs\strategy\live_tinvest_design.md` |
| Карта репозитория | `README.md` (структура, строки 18–67) |
| **Точные универсумы** | **в коде**, не в доках: `tools\auto_trade.ps1` (paper 19), `tools\live_engine.ps1` (Bybit 16), `tools\lib_rf_signals.ps1` (РФ 8+12) |

---

## 13. Финальная смоук-проверка

| Тест | Ожидание |
|---|---|
| `git clone` | `README.md`, `docs\`, `deploy\` на месте |
| `timedatectl` (VPS) | `System clock synchronized: yes` — **расхождение часов тихо ломает подпись Bybit** |
| `tick.yml` (workflow_dispatch) | зелёный прогон, Pages обновился |
| `systemctl status live-tick.timer live-rf-tick.timer trading-assistant` | все `active` |
| `tools\live_smoke_test.ps1` | read-only проверки OK |
| `tinvest_selftest.ps1` (с токеном) | счета + 8 фьючерсов + 12 акций OK |
| Дашборд, вкладки «Реал» / «Фьючерсы→Реал» | показывают свежий капитал |
| Тестовый TG-алерт | доходит на оба (`TG_CHAT_ID` и `TG_CHAT_ID_FUT`) |

(Kill-drill здесь НЕ повторяем — он в разделе 6, до go-live.)

---

## 14. Красные линии / чего этот документ не покрывает

- **Реальные деньги:** перед prod — DryRun/sandbox; фазовый рамп капитала; **пониженный `base_rub`
  на первые сутки после DR**.
- **Двух писателей избегать:** одно состояние — один писатель (Actions / Bybit-VPS / RF-VPS).
- **Правки и деплои trading-sim — только с одобрения пользователя** (красная линия).
- **Локально-only, вне git:** `strategy_lab\`, `vps\` (целиком), `.secrets\` — из GitHub НЕ
  восстанавливаются; нужны из локальных бэкапов.
- Пошаговая настройка VPS с нуля (провижининг, chrony, создание ключей) — в `deploy\README.md` и
  `deploy\README_RF.md`; здесь только порядок и точки входа.
