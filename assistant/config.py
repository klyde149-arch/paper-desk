"""Конфигурация ассистента: пути, env, лимиты.

Всё через stdlib — ассистент доезжает на VPS обычным `git pull` внутри тика,
без pip/venv. Никаких зависимостей.
"""
import os

# --- пути -------------------------------------------------------------------
# assistant/ лежит в корне репо, поэтому REPO = родитель этого каталога.
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Состояние ассистента живёт ВНЕ рабочего дерева репо: тик делает
# `git pull --rebase --autostash` каждую минуту, и лишние файлы в дереве
# создают конфликты. На VPS каталог создаёт systemd через StateDirectory=.
STATE_DIR = os.environ.get('ASSISTANT_STATE_DIR') or (
    '/var/lib/trading-assistant' if os.name != 'nt'
    else os.path.join(os.environ.get('LOCALAPPDATA', REPO), 'trading-assistant')
)
SESSIONS_DIR = os.path.join(STATE_DIR, 'sessions')
PENDING_FILE = os.path.join(STATE_DIR, 'pending.json')
BUDGET_FILE = os.path.join(STATE_DIR, 'budget.json')
OFFSET_FILE = os.path.join(STATE_DIR, 'tg_offset')
AUDIT_FILE = os.path.join(STATE_DIR, 'actions_audit.log')

PROMPTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'prompts')


def ensure_state_dirs():
    for d in (STATE_DIR, SESSIONS_DIR):
        try:
            os.makedirs(d, exist_ok=True)
        except OSError:
            pass


# --- модель -----------------------------------------------------------------
OPENROUTER_URL = 'https://openrouter.ai/api/v1/chat/completions'
API_KEY = os.environ.get('OPENROUTER_API_KEY', '')
MODEL = os.environ.get('ASSISTANT_MODEL', 'deepseek/deepseek-chat')
MODEL_FALLBACK = os.environ.get('ASSISTANT_MODEL_FALLBACK', 'google/gemini-2.0-flash-001')
LLM_MOCK = os.environ.get('ASSISTANT_LLM_MOCK', '') == '1'

MAX_TOOL_ROUNDS = 6          # защита от зацикливания на дешёвых моделях
MAX_TOKENS = 900
LLM_TIMEOUT = 60             # секунд на один вызов модели
TURN_WALL_CLOCK = 120        # секунд на весь ход (модель + инструменты)

# --- телеграм ---------------------------------------------------------------
TG_TOKEN = os.environ.get('TG_BOT_TOKEN', '')
# Whitelist операторов. Дефолт — основной чат. TG_CHAT_ID_FUT сознательно НЕ
# включаем: это второй человек, получатель алертов, а не оператор бота.
_allowed = os.environ.get('ASSISTANT_TG_ALLOWED_CHATS') or os.environ.get('TG_CHAT_ID', '')
ALLOWED_CHATS = {c.strip() for c in _allowed.split(',') if c.strip()}

TG_POLL_TIMEOUT = 50         # long-polling: Telegram держит соединение
TG_MSG_LIMIT = 4000          # лимит Telegram ~4096, режем с запасом
MAX_INCOMING_CHARS = 2000    # длинные простыни не пускаем в модель

# --- память -----------------------------------------------------------------
SESSION_TTL_MIN = int(os.environ.get('ASSISTANT_SESSION_TTL_MIN', '120'))
MAX_HISTORY_TURNS = 12
MAX_HISTORY_CHARS = 12000

# --- лимиты вывода инструментов ---------------------------------------------
TOOL_OUTPUT_CAP = 6000       # символов на один результат
TURN_OUTPUT_CAP = 20000      # символов на все результаты одного хода

# --- бюджет -----------------------------------------------------------------
DAILY_TOKENS = int(os.environ.get('ASSISTANT_DAILY_TOKENS', '300000'))
DAILY_CALLS = int(os.environ.get('ASSISTANT_DAILY_CALLS', '300'))
RATE_MSGS = 20               # сообщений
RATE_WINDOW_SEC = 600        # за окно

# --- действия ---------------------------------------------------------------
# Пока 1 — kill-switch пишет в песочницу вместо data/. Снимать только после
# успешного kill-drill (см. deploy/README_ASSISTANT.md).
DRY_ACTIONS = os.environ.get('ASSISTANT_DRY_ACTIONS', '1') == '1'
CONFIRM_TTL_SEC = 180
