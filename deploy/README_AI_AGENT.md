# ИИ-агент (бумага): выкладка на VPS

Канон дизайна: `docs/strategy/rf_ai_agent_design_2026-09.md` (§15 — как устроено в коде).
Агент торгует **только бумажный рукав**, к брокеру не обращается, C3b не трогает.

## Что где

| Путь | Что |
|---|---|
| `ai_agent/` | код, только стандартная библиотека Python 3 (на VPS нет pip) |
| `deploy/ai_agent_tick.sh` | обёртка: pull → `python3 -m ai_agent tick` → commit/push `data/ai_agent` и `agent_memory` |
| `deploy/ai-agent.{service,timer}` | раз в 5 минут, на :45 секунде |
| `/etc/ai-agent.env` | ключ агента `AI_AGENT_OPENROUTER_KEY`, бюджет (шаблон `deploy/ai-agent.env.example`) |
| `data/ai_agent/` | `state.json`, `decisions.jsonl`, `trades.json`, `usage.jsonl`, `calls/`, `equity.json`, `reports/`, `inbox/`, `agent_log.txt` |
| `agent_memory/` | правила, уроки, журнал, разборы (Obsidian, только чтение) |

Писатели: `data/ai_agent/` и `agent_memory/{Журнал,Разборы,Уроки}` — только агент;
`data/ai_agent/inbox/` — только ассистент (кнопки уроков); `agent_memory/Правила агента.md` — владелец.

## Установка (только с одобрения владельца)

Код должен быть в `main` — VPS тянет только его.

```bash
# 1. ключ агента = ключ ассистента (решение владельца 28.09), значение на экран не выводится
sudo install -m 0640 -o root -g trader /dev/null /etc/ai-agent.env
sudo sh -c 'grep "^OPENROUTER_API_KEY=" /etc/trading-assistant.env | sed "s/^OPENROUTER_API_KEY=/AI_AGENT_OPENROUTER_KEY=/" > /etc/ai-agent.env'
sudo sh -c 'printf "AI_AGENT_BUDGET_USD=12.5
AI_AGENT_DAILY_CAP_USD=1.0
" >> /etc/ai-agent.env'

# 2. проверка без денег и без сети
cd /home/trader/paper-desk
sudo -u trader python3 ai_agent/tests/run_all.py

# 3. проверка живого вызова: один главный разбор БЕЗ применения (~$0.3)
sudo bash -c 'set -a; . /etc/ai-agent.env; unset TG_BOT_TOKEN; python3 -m ai_agent run --point main --dry'

# 4. юниты
sudo cp deploy/ai-agent.service deploy/ai-agent.timer /etc/systemd/system/
sudo systemd-analyze verify /etc/systemd/system/ai-agent.service
sudo systemctl daemon-reload
sudo systemctl enable --now ai-agent.timer

# 5. ассистент подхватывает кнопки уроков только после перезапуска
sudo systemctl restart trading-assistant
```

Право на исполнение у `deploy/ai_agent_tick.sh` лежит в git (100755). **Никогда не делать `chmod`
на VPS**: локальная смена режима ломает `--autostash` всех тиков (инцидент 2026-08-11).

## Каждый день первой недели

```bash
sudo -u trader python3 -m ai_agent status          # рукав и расход
tail -n 50 data/ai_agent/agent_log.txt
systemctl list-timers ai-agent.timer
```

После 5 торговых дней — пересчитать оценку по факту (`usage.jsonl`: `prompt_tokens`,
`completion_tokens`, `reasoning_tokens`) через `tools/estimate_agent_cost.py`.

## Выключатели

| Что | Как | Эффект |
|---|---|---|
| полная остановка | `touch data/ai_agent/HALT_AGENT` (или `systemctl disable --now ai-agent.timer`) | тик не делает ничего, бумажные стопы тоже стоят |
| без новых входов | `touch data/ai_agent/HALT_AGENT_ENTRIES` | модель вызывается, входы отклоняются, позиции ведутся |
| стоп-кран −5R | сработал сам | входы остановлены до разбора; снять: `python3 -m ai_agent reset-halt` |

Файлы-выключатели создаются на VPS и коммитятся обёрткой вместе с `data/ai_agent`.

## Сторож

`tools/live_watch.ps1` (GitHub Actions) смотрит `data/ai_agent/equity.json`: снапшот пишется при
каждом событии и не реже раза в 6 часов, порог тишины — 8 часов, алерт только владельцу.
