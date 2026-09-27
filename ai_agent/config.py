"""Настройки агента: универсум, риск-рамки, издержки, модель, пути.

Риск-рамки здесь, а не в правилах агента: модель их не видит как настраиваемые и изменить не может
(дизайн §6). Издержки — как у бумажного двойника C3b (tools/rf_engine.ps1), иначе сравнение нечестное.
Пути и секреты читаются из окружения при каждом вызове paths()/secrets(), чтобы тесты могли
подменять их без перезагрузки модуля.
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

UNIVERSE = ('BR', 'NG', 'GOLD', 'SILV', 'Si', 'CNY', 'MIX', 'Eu')
GROUP = {'BR': 'energy', 'NG': 'energy', 'GOLD': 'metals', 'SILV': 'metals',
         'Si': 'rub', 'CNY': 'rub', 'Eu': 'rub', 'MIX': 'index'}
GROUP_RU = {'rub': 'рубль', 'metals': 'металлы', 'energy': 'энергия', 'index': 'индекс'}
NAME_RU = {'BR': 'нефть Brent', 'NG': 'природный газ', 'GOLD': 'золото', 'SILV': 'серебро',
           'Si': 'доллар/рубль', 'CNY': 'юань/рубль', 'Eu': 'евро/рубль', 'MIX': 'индекс Мосбиржи'}
# шаг цены (справочник T-Invest, снимок 2026-09-20); меняется крайне редко
TICK = {'BR': 0.01, 'NG': 0.001, 'GOLD': 0.1, 'SILV': 0.01,
        'Si': 1.0, 'CNY': 0.001, 'MIX': 25.0, 'Eu': 1.0}

# ---- риск-рамки (§6) ----
RISK_PCT = 0.005          # 0,5% капитала рукава на сделку
MAX_POSITIONS = 3         # позиции + висящие заявки на вход
MAX_PER_GROUP = 2
HALT_SUM_R = -5.0         # стоп-кран: сумма закрытых сделок ниже -5R
MAX_LEV = 3.0             # номинал позиции <= 3 x капитал, как $MAXLEV RF-двойника
ATR_TRAIL = 3.0           # страховочный трейл 3 x ATR(14) от лучшей цены
MAX_STOP_FRAC = 0.15      # защита от опечатки: стоп дальше 15% от цены — отказ
MAX_LIMIT_FRAC = 0.10     # лимитка дальше 10% от последней цены — отказ
MAX_HORIZON_DAYS = 60

# ---- издержки бумаги (как у двойника C3b) ----
FEE = 0.0001
SLIP = 0.0003
STOP_SLIP = 0.0005

# ---- модель и бюджет (§3) ----
MODEL = 'anthropic/claude-opus-5.5'
NEWS_MODEL = 'perplexity/sonar'
PRICE_IN = {MODEL: 4e-6, NEWS_MODEL: 1e-6}      # $ за токен, OpenRouter 27.09.2026
PRICE_OUT = {MODEL: 20e-6, NEWS_MODEL: 1e-6}
SEARCH_USD = 0.005
OPENROUTER_URL = 'https://openrouter.ai/api/v1/chat/completions'
LLM_TIMEOUT = 300         # рассуждение на medium идёт минутами
MAX_TOKENS = {'medium': 16000, 'low': 6000}

START_EQUITY = 100.0      # индекс капитала рукава; рублей в учёте нет (§15)


def _env(name, default=''):
    return os.environ.get(name, default)


def paths():
    data = _env('AI_AGENT_DATA_DIR', os.path.join(ROOT, 'data', 'ai_agent'))
    return {
        'root': ROOT,
        'data': data,
        'state': os.path.join(data, 'state.json'),
        'decisions': os.path.join(data, 'decisions.jsonl'),
        'trades': os.path.join(data, 'trades.json'),
        'usage': os.path.join(data, 'usage.jsonl'),
        'calls': os.path.join(data, 'calls'),
        'reports': os.path.join(data, 'reports'),
        'inbox': os.path.join(data, 'inbox', 'lesson_decisions.jsonl'),
        'heartbeat': os.path.join(data, 'heartbeat.json'),
        'log': os.path.join(data, 'agent_log.txt'),
        'halt': os.path.join(data, 'HALT_AGENT'),
        'halt_entries': os.path.join(data, 'HALT_AGENT_ENTRIES'),
        'memory': _env('AI_AGENT_MEMORY_DIR', os.path.join(ROOT, 'agent_memory')),
        'series': _env('AI_AGENT_SERIES_DIR', os.path.join(ROOT, 'data', 'live_rf', 'series')),
        'candles': _env('AI_AGENT_CANDLES_DIR', os.path.join(ROOT, 'data', 'live_rf', 'candles')),
        'rf_portfolio': _env('AI_AGENT_RF_PORTFOLIO',
                             os.path.join(ROOT, 'data', 'live_rf', 'portfolio.json')),
        'twin_trades': _env('AI_AGENT_TWIN_TRADES', os.path.join(ROOT, 'data', 'rf', 'rf_trades.json')),
        'calendar': _env('AI_AGENT_CALENDAR',
                         os.path.join(ROOT, 'data', 'events', 'agent_calendar_2026_27.json')),
    }


def secrets():
    return {
        'openrouter': _env('AI_AGENT_OPENROUTER_KEY'),   # своя переменная: OPENROUTER_API_KEY в trading-live.env — ключ боевого движка
        'tg_token': _env('TG_BOT_TOKEN'),
        'tg_chat': _env('TG_CHAT_ID'),       # только владелец; клиенту агент не пишет
    }


def budget():
    return {
        'total_usd': float(_env('AI_AGENT_BUDGET_USD', '12.5')),
        'daily_usd': float(_env('AI_AGENT_DAILY_CAP_USD', '1.0')),
    }


def llm_mock():
    return _env('AI_AGENT_LLM_MOCK') == '1'
