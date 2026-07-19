"""Вычистка секретов из любого текста, который уходит модели или пользователю.

Два слоя:
  1) Литеральная замена ФАКТИЧЕСКИХ значений из окружения — почти стопроцентная
     защита, включая случай, когда токен выплюнул в лог упавший скрипт.
  2) Регексп-паттерны на случай ключа, которого нет в нашем окружении.

Применяется и к результату каждого инструмента, и к финальному ответу модели.
"""
import os
import re

REDACTED = '<REDACTED>'

# Переменные, значения которых недопустимы в выводе ни при каких условиях.
_SECRET_ENV = (
    'TG_BOT_TOKEN', 'OPENROUTER_API_KEY',
    'BYBIT_API_KEY', 'BYBIT_API_SECRET',
    'TINVEST_TOKEN', 'TINVEST_TOKEN_TRADE', 'TINVEST_SANDBOX_TOKEN',
    'GEMINI_API_KEY', 'DEEPSEEK_API_KEY',
)

_PATTERNS = [
    re.compile(r'sk-or-v1-[A-Za-z0-9]{20,}'),        # OpenRouter
    re.compile(r'\b\d{8,10}:AA[\w-]{30,}'),          # Telegram bot token
    re.compile(r'\bt\.[A-Za-z0-9_-]{40,}'),          # T-Invest
    re.compile(r'\bAIza[0-9A-Za-z_-]{30,}'),         # Google
    re.compile(r'\bsk-[A-Za-z0-9]{32,}'),            # OpenAI-подобные
]


def _literals():
    """Фактические значения секретов из env. Короче 8 символов — игнорируем,
    иначе рискуем вырезать осмысленный текст."""
    out = []
    for name in _SECRET_ENV:
        v = os.environ.get(name, '')
        if v and len(v) >= 8:
            out.append(v)
    # длинные сначала, чтобы не оставить хвост от вложенного значения
    return sorted(set(out), key=len, reverse=True)


def scrub(text):
    """Вернуть text без секретов. Никогда не бросает исключение."""
    if not text:
        return text
    try:
        s = str(text)
        for lit in _literals():
            if lit in s:
                s = s.replace(lit, REDACTED)
        for pat in _PATTERNS:
            s = pat.sub(REDACTED, s)
        return s
    except Exception:
        # Лучше отдать заглушку, чем рискнуть протечкой при странном вводе.
        return '<scrub failed>'
