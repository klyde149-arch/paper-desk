"""Слой Telegram Bot API: long-polling + отправка.

Важно: sendMessage от торговых тиков (tools/lib_alerts.ps1) и getUpdates отсюда
сосуществуют штатно. Несовместимы только ДВА процесса с getUpdates на одном
токене — Telegram отдаёт 409 Conflict. Поэтому демон запускается под flock,
а 409 обрабатывается громко и с бэкоффом (см. bot.py).
"""
import json
import urllib.error
import urllib.parse
import urllib.request

from . import config
from .scrub import scrub

API = 'https://api.telegram.org/bot%s/%s'


class TgConflict(Exception):
    """409: кто-то ещё поллит этот же токен."""


def _call(method, params, timeout=30):
    url = API % (config.TG_TOKEN, method)
    data = urllib.parse.urlencode(
        {k: (json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list)) else v)
         for k, v in params.items() if v is not None}
    ).encode('utf-8')
    req = urllib.request.Request(url, data=data, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        if e.code == 409:
            raise TgConflict('409: другой процесс уже поллит этот токен')
        body = ''
        try:
            body = e.read().decode('utf-8', 'replace')[:200]
        except Exception:
            pass
        raise RuntimeError('telegram %s -> HTTP %s %s' % (method, e.code, body))


def get_updates(offset, timeout=None):
    to = config.TG_POLL_TIMEOUT if timeout is None else timeout
    r = _call('getUpdates', {
        'offset': offset,
        'timeout': to,
        'allowed_updates': ['message', 'callback_query'],
    }, timeout=to + 15)
    return r.get('result') or []


def send(chat_id, text, keyboard=None):
    """Отправить текст, порезав на куски по лимиту Telegram.

    parse_mode сознательно НЕ используем: тексты содержат `_`, `*`, `.` из
    символов и путей, а падать на экранировании MarkdownV2 недопустимо.
    Возвращает message_id последнего куска (или None).
    """
    text = scrub(text) or '(пусто)'
    chunks = _split(text, config.TG_MSG_LIMIT)
    last = None
    for i, ch in enumerate(chunks):
        params = {'chat_id': chat_id, 'text': ch, 'disable_web_page_preview': 'true'}
        # клавиатуру вешаем только на последний кусок
        if keyboard and i == len(chunks) - 1:
            params['reply_markup'] = {'inline_keyboard': keyboard}
        try:
            r = _call('sendMessage', params)
            last = (r.get('result') or {}).get('message_id')
        except Exception as e:
            print('WARN: sendMessage failed: %s' % e, flush=True)
    return last


def send_typing(chat_id):
    try:
        _call('sendChatAction', {'chat_id': chat_id, 'action': 'typing'}, timeout=10)
    except Exception:
        pass  # индикатор набора — не повод ронять ход


def answer_callback(cb_id, text=''):
    try:
        _call('answerCallbackQuery', {'callback_query_id': cb_id, 'text': text[:190]}, timeout=10)
    except Exception:
        pass


def edit_text(chat_id, message_id, text):
    try:
        _call('editMessageText', {
            'chat_id': chat_id, 'message_id': message_id,
            'text': scrub(text)[:config.TG_MSG_LIMIT],
        }, timeout=15)
    except Exception:
        pass


def _split(text, limit):
    """Резать по границам строк, длинные строки — жёстко."""
    if len(text) <= limit:
        return [text]
    out, cur = [], ''
    for line in text.split('\n'):
        while len(line) > limit:
            if cur:
                out.append(cur)
                cur = ''
            out.append(line[:limit])
            line = line[limit:]
        if len(cur) + len(line) + 1 > limit:
            out.append(cur)
            cur = line
        else:
            cur = (cur + '\n' + line) if cur else line
    if cur:
        out.append(cur)
    return out
