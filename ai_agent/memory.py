"""Память агента в agent_memory/ (дизайн §8, §15): правила, уроки, журнал, версия памяти.

Правила правит только владелец. Уроки: агент предлагает (status: предложен), владелец принимает
кнопкой в Telegram; агент читает только принятые, не больше ~2000 токенов. Файлы на «_» —
служебные, агент их не читает. Версия памяти — хэш правил и принятых уроков: пишется в каждое
решение, чтобы потом видеть, помог урок или навредил.
"""
import datetime as dt
import hashlib
import os
import re

from . import budget

RULES_FILE = 'Правила агента.md'
LESSONS_DIR = 'Уроки'
JOURNAL_DIR = 'Журнал'
REVIEWS_DIR = 'Разборы'
LESSON_TOKENS = 2000


def split_frontmatter(text):
    meta, body = {}, text
    if text.startswith('---'):
        end = text.find('\n---', 3)
        if end > 0:
            for line in text[3:end].splitlines():
                if ':' in line:
                    k, v = line.split(':', 1)
                    meta[k.strip()] = v.strip()
            body = text[end + 4:].lstrip('\n')
    return meta, body


def _read(path):
    try:
        with open(path, encoding='utf-8-sig') as f:
            return f.read()
    except OSError:
        return ''


def load_rules(mem_dir):
    meta, body = split_frontmatter(_read(os.path.join(mem_dir, RULES_FILE)))
    # цитата-пометка для владельца («> Черновик ... Правит только владелец») модели не нужна
    lines = [ln for ln in body.splitlines() if not ln.startswith('>')]
    return '\n'.join(lines).strip(), meta


def lessons(mem_dir):
    d = os.path.join(mem_dir, LESSONS_DIR)
    out = []
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return out
    for n in names:
        p = os.path.join(d, n)
        if n.startswith('_') or not n.endswith('.md') or not os.path.isfile(p):
            continue
        text = _read(p)
        meta, body = split_frontmatter(text)
        m = re.search(r'^#\s+(.+)$', body, re.M)
        out.append({'file': n, 'path': p, 'meta': meta, 'title': m.group(1).strip() if m else n[:-3],
                    'body': body.strip(), 'status': meta.get('status', '')})
    return out


def accepted_lessons(mem_dir, max_tokens=LESSON_TOKENS):
    """-> (текст для промпта, принятые уроки в промпте, не поместились). Новее — важнее."""
    acc = [x for x in lessons(mem_dir) if x['status'] == 'принят']
    acc.sort(key=lambda x: x['meta'].get('принят') or x['meta'].get('предложен') or '', reverse=True)
    used, left, text = [], [], ''
    for x in acc:
        chunk = '### %s\n%s\n\n' % (x['title'], x['body'])
        if budget.est_tokens(text + chunk) <= max_tokens:
            text += chunk
            used.append(x)
        else:
            left.append(x)
    return text.strip(), used, left


def version(rules_text, lessons_text):
    h = hashlib.sha256((rules_text + '\n\x00\n' + lessons_text).encode('utf-8')).hexdigest()
    return h[:12]


def journal_append(mem_dir, day, text):
    d = os.path.join(mem_dir, JOURNAL_DIR)
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, '%s.md' % day)
    new = not os.path.exists(p)
    with open(p, 'a', encoding='utf-8', newline='\n') as f:
        if new:
            f.write('# Журнал агента %s\n\nЗаписи делает код по ответам агента.\n' % day)
        f.write('\n' + text.rstrip() + '\n')
    return p


def iso_week(day):
    y, w, _ = (day if isinstance(day, dt.date) else dt.date.fromisoformat(day)).isocalendar()
    return y, w
