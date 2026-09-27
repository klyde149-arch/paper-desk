"""Отправка в Telegram владельцу (TG_CHAT_ID). Клиенту агент не пишет.

Только sendMessage: обновления бота читает один процесс — ассистент (assistant/bot.py), второй
получил бы 409. Нажатия кнопок уроков тоже ловит он. Ошибки не бросаются: возвращаем False и
пишем причину в last_error (без токена в тексте).
"""
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

from . import config as C

LIMIT = 4000
last_error = ''


def _split(text):
    parts, cur = [], ''
    for line in text.split('\n'):
        while len(line) > LIMIT:
            parts.append(line[:LIMIT])
            line = line[LIMIT:]
        if len(cur) + len(line) + 1 > LIMIT:
            parts.append(cur)
            cur = ''
        cur = cur + '\n' + line if cur else line
    if cur:
        parts.append(cur)
    return parts


def send(text, keyboard=None):
    global last_error
    s = C.secrets()
    if not s['tg_token'] or not s['tg_chat']:
        last_error = 'нет TG_BOT_TOKEN / TG_CHAT_ID'
        if not C.llm_mock():
            print('TG НЕ ДОСТАВЛЕНО (%s)' % last_error, file=sys.stderr)
        return False
    ok = True
    chunks = _split(text)
    for i, chunk in enumerate(chunks):
        params = {'chat_id': s['tg_chat'], 'text': chunk, 'disable_web_page_preview': 'true'}
        if keyboard and i == len(chunks) - 1:
            params['reply_markup'] = json.dumps({'inline_keyboard': keyboard}, ensure_ascii=False)
        url = 'https://api.telegram.org/bot%s/sendMessage' % s['tg_token']
        try:
            req = urllib.request.Request(url, data=urllib.parse.urlencode(params).encode('utf-8'), method='POST')
            with urllib.request.urlopen(req, timeout=15) as r:
                ok = ok and bool(json.loads(r.read().decode('utf-8')).get('ok'))
        except urllib.error.HTTPError as e:
            last_error = 'HTTP %s' % e.code      # 401 — токен, 404 — мусор в URL/токене
            ok = False
        except Exception as e:
            last_error = type(e).__name__
            ok = False
    if not ok:
        # доставку проверяем, а не только отправку (урок 2026-08-11): отказ виден в journalctl -u ai-agent
        print('TG НЕ ДОСТАВЛЕНО (%s): %s' % (last_error, text[:120].replace('
', ' ')), file=sys.stderr)
    return ok
