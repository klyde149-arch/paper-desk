"""Учёт расхода на модели (дизайн §3, §10): журнал usage.jsonl, потолок в день, общий бюджет.

Перед вызовом считается худший случай — весь вход плюс max_tokens выхода по полной цене. Если
с ним дневной потолок ($1) или общий бюджет будет превышен, вызова нет: новых входов нет,
позиции ведёт код (стопы и трейл работают без модели).
"""
import json
import os

from . import config as C

CHARS_PER_TOKEN = 1.4     # замер 28.09 на живом вызове: 26 тыс. символов = 17,2 тыс. токенов (~1,5), берём с запасом


def est_tokens(text):
    return int(len(text) / CHARS_PER_TOKEN) + 1


def rows(path):
    out = []
    try:
        with open(path, encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        out.append(json.loads(line))
                    except ValueError:
                        pass
    except OSError:
        pass
    return out


def spent(path, day=None):
    rs = rows(path)
    total = sum(float(r.get('cost_usd') or 0) for r in rs)
    today = sum(float(r.get('cost_usd') or 0) for r in rs if day and str(r.get('ts', '')).startswith(day))
    return total, today


def worst_case(model, in_tokens, max_out, searches=0):
    return in_tokens * C.PRICE_IN[model] + max_out * C.PRICE_OUT[model] + searches * C.SEARCH_USD


def check(path, day, worst_usd, limits=None):
    """-> (True, '') | (False, причина)."""
    lim = limits or C.budget()
    total, today = spent(path, day)
    if total + worst_usd > lim['total_usd']:
        return False, 'бюджет исчерпан: потрачено $%.2f из $%.2f' % (total, lim['total_usd'])
    if today + worst_usd > lim['daily_usd']:
        return False, 'дневной потолок: сегодня $%.2f, вызов может стоить до $%.2f, потолок $%.2f' % (
            today, worst_usd, lim['daily_usd'])
    return True, ''


def cost_of(model, usage, searches=0):
    """Стоимость вызова: usage.cost от OpenRouter, иначе по токенам и ценам."""
    c = usage.get('cost')
    if isinstance(c, (int, float)) and c > 0:
        return float(c)
    return (float(usage.get('prompt_tokens') or 0) * C.PRICE_IN.get(model, 0)
            + float(usage.get('completion_tokens') or 0) * C.PRICE_OUT.get(model, 0)
            + searches * C.SEARCH_USD)


def record(path, row):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'a', encoding='utf-8') as f:
        f.write(json.dumps(row, ensure_ascii=False) + '\n')
