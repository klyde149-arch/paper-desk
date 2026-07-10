# trading-sim — paper-trading симуляция

Симуляция торговли криптой (и исследования рынка РФ). **Только виртуальные деньги, публичные API без ключей.** Начато 2026-07-08.

## Структура

```
trading-sim/
├── portfolio.json        # СОСТОЯНИЕ: счёт, позиции, карточки тезисов (читает build_vizdata.ps1 — не перемещать)
├── journal.md            # СОСТОЯНИЕ: журнал всех итераций — при старте сессии читать хвост
│
├── docs/                 # документация (правила, отчёты исследований)
│   ├── strategy.md               # действующий регламент (сетап A, риск, лимиты)
│   ├── strategy_v2_proposal.md   # предложение v2 — ждёт решения пользователя
│   ├── strategy_moex_fut.md      # стратегия «Рынок РФ v1» (фьючерсы FORTS)
│   ├── backtest_report.md        # бэктест v1 (16.4 мес)
│   ├── backtest_v2_report.md     # бэктест v2 (5.3 года, data\deep)
│   └── archive/
│       └── strategy_v1_archive.md
│
├── tools/                # скрипты PowerShell (analyze, backtest, scan_signals, fetch_*, build_vizdata, deploy_site…)
│
├── data/                 # данные и артефакты бэктестов (пишутся скриптами — руками не трогать)
│   ├── *.json            # 4h-свечи Bybit (16 мес) + канонический бэктест v1 + signals.json
│   ├── deep/             # история 2020→2026 с фандингом + прогоны v2 live-конфига
│   ├── v2/               # исследовательские прогоны v2 (FlatMode, фандинг-фильтр…)
│   ├── moex/             # акции MOEX (1d/1h) + momentum-прогоны
│   ├── moex_fut/         # фьючерсы FORTS (склейки, роллы, meta) + combos.json
│   └── fut_runs/         # walk-forward-прогоны по фьючерсам (IS/OOS1/OOS2)
│
├── report/               # ОТДЕЛЬНЫЙ GIT-РЕПО → GitHub Pages (klyde149-arch/paper-desk)
│   │                     #   https://klyde149-arch.github.io/paper-desk/
│   ├── trades.html       # дашборд-терминал
│   ├── chart.html        # график с индикаторами
│   ├── vizdata.js        # данные дашборда (генерирует tools\build_vizdata.ps1)
│   └── …                 # публикуется ТОЛЬКО эта папка (журнал/портфель/tools — нет)
│
└── challenge/            # ЧЕЛЛЕНДЖ «30 дней» — автономный контур, ноль зависимостей от tools\
    ├── portfolio.json    # отдельный счёт $1,000
    ├── strategy.md       # замороженная система S4 (менять нельзя)
    ├── report.md
    ├── tools/            # свои fetch/backtest/analyze/research/scan
    └── data/             # свои данные Bybit 1h/4h/funding 2020→
```

## Цикл итерации (каждые 45–60 мин)

1. `tools\analyze.ps1` → проверка позиций по 1h → фандинг → лимиты
2. `tools\scan_signals.ps1` (сканер setup A + ворота v2 → data\signals.json)
3. Челлендж: `challenge\tools\scan.ps1 -Setup S4 -BreakN 24 -ExitMode tp2r -RiskPct 0.10 -LevTarget 15`
4. Обновить `portfolio.json` / `journal.md` → `tools\build_vizdata.ps1` → `tools\deploy_site.ps1`

Локальный терминал: `tools\start_terminal.ps1 -Launch` → http://localhost:8377/

Подробности и договорённости — в памяти Claude (`trading-sim-project.md`) и в `docs\strategy.md`.
