"""История диалога по chat_id.

Тонкое место: обрезать историю можно ТОЛЬКО по границам ходов. Если выбросить
assistant-сообщение с tool_calls, но оставить парные tool-сообщения (или наоборот),
OpenAI-совместимый API отдаёт 400 на осиротевший tool_call_id. Отдельный тест на это.
"""
import json
import os
import time

from . import config


def _path(chat_id):
    safe = ''.join(c if (c.isalnum() or c in '-_') else '_' for c in str(chat_id))
    return os.path.join(config.SESSIONS_DIR, safe + '.json')


def _atomic_write(path, obj):
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(obj, f, ensure_ascii=False)
    os.replace(tmp, path)


def load(chat_id):
    """Вернуть историю сообщений. Протухшая по TTL сессия начинается с нуля."""
    p = _path(chat_id)
    try:
        with open(p, 'r', encoding='utf-8') as f:
            d = json.load(f)
    except (OSError, ValueError):
        return []
    if time.time() - float(d.get('updated_ts') or 0) > config.SESSION_TTL_MIN * 60:
        return []
    return d.get('messages') or []


def save(chat_id, messages):
    config.ensure_state_dirs()
    try:
        _atomic_write(_path(chat_id), {'updated_ts': time.time(), 'messages': messages})
    except OSError as e:
        print('WARN: не удалось сохранить сессию %s: %s' % (chat_id, e), flush=True)


def reset(chat_id):
    try:
        os.remove(_path(chat_id))
    except OSError:
        pass


def collapse_tool_outputs(messages):
    """Схлопнуть сырые выводы инструментов в заглушки.

    Сырой JSON инструмента нужен модели только внутри текущего хода; в истории он
    крупнейший пожиратель контекста. Оставляем след, чтобы модель помнила, что
    именно уже смотрела.
    """
    out = []
    for m in messages:
        if m.get('role') == 'tool' and isinstance(m.get('content'), str) \
                and not m['content'].startswith('[инструмент '):
            name = m.get('name') or '?'
            ok = '"error"' not in m['content'][:200]
            out.append(dict(m, content='[инструмент %s → %s, %d симв. вывода]'
                                       % (name, 'ok' if ok else 'ошибка', len(m['content']))))
        else:
            out.append(m)
    return out


def trim(messages):
    """Оставить последние ходы, не разрывая связку tool_calls ↔ tool.

    Ход начинается с сообщения role=user. Режем только по этим границам.
    """
    starts = [i for i, m in enumerate(messages) if m.get('role') == 'user']
    if not starts:
        return messages

    # 1) по числу ходов
    if len(starts) > config.MAX_HISTORY_TURNS:
        messages = messages[starts[-config.MAX_HISTORY_TURNS]:]
        starts = [i for i, m in enumerate(messages) if m.get('role') == 'user']

    # 2) по объёму — выбрасываем целые ходы с начала, пока не влезем
    def size(msgs):
        return sum(len(json.dumps(m, ensure_ascii=False, default=str)) for m in msgs)

    while size(messages) > config.MAX_HISTORY_CHARS and len(starts) > 1:
        messages = messages[starts[1]:]
        starts = [i for i, m in enumerate(messages) if m.get('role') == 'user']

    return messages
