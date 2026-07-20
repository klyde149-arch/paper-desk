"""Агентный цикл: модель ↔ инструменты.

Формат хода: [system: промпт+глоссарий] [system: снапшот на сейчас] [история] [user]
Снапшот пересобирается каждый ход — состояние протухает за минуты.
"""
import json
import os
import re
import time

from . import config, llm, memory, snapshot
from . import tools_impl as T
from .scrub import scrub

_PROMPT_CACHE = {}

# Модели упорно размечают ответ Markdown'ом вопреки промпту, а Telegram шлётся
# без parse_mode (иначе падает на '_' и '.' в путях и тикерах) — звёздочки видны
# как мусор. Чистим кодом, а не уговорами.
_MD_BOLD = re.compile(r'\*\*(.+?)\*\*', re.S)
_MD_HEAD = re.compile(r'^#{1,6}\s*', re.M)
_MD_CODE = re.compile(r'`([^`]*)`')


def strip_markdown(text):
    if not text:
        return text
    text = _MD_BOLD.sub(r'\1', text)
    text = _MD_CODE.sub(r'\1', text)
    text = _MD_HEAD.sub('', text)
    return text


def load_prompt():
    """Системный промпт + глоссарий. Кэш сбрасывается командой /reload."""
    if 'text' in _PROMPT_CACHE:
        return _PROMPT_CACHE['text']
    parts = []
    for name in ('system_ru.md', 'glossary_ru.md'):
        p = os.path.join(config.PROMPTS_DIR, name)
        try:
            with open(p, 'r', encoding='utf-8') as f:
                parts.append(f.read())
        except OSError as e:
            parts.append('(не удалось прочитать %s: %s)' % (name, e))
    _PROMPT_CACHE['text'] = '\n\n'.join(parts)
    return _PROMPT_CACHE['text']


def reload_prompt():
    _PROMPT_CACHE.clear()
    return load_prompt()


def _tool_stub_message(call, content):
    return {
        'role': 'tool',
        'tool_call_id': call.get('id') or '',
        'name': (call.get('function') or {}).get('name') or '?',
        'content': content,
    }


def run_turn(chat_id, user_text, on_progress=None):
    """Обработать одно сообщение пользователя. Возвращает (ответ, метаданные).

    on_progress — необязательный колбэк (str) для показа хода работы в CLI.
    """
    started = time.time()
    history = memory.load(chat_id)

    messages = [
        {'role': 'system', 'content': load_prompt()},
        {'role': 'system', 'content': snapshot.build()},
    ] + history + [{'role': 'user', 'content': user_text}]

    turn_msgs = [{'role': 'user', 'content': user_text}]
    tools_used = []
    spent_chars = 0
    usage_total = {'prompt_tokens': 0, 'completion_tokens': 0, 'model': ''}

    for rnd in range(config.MAX_TOOL_ROUNDS):
        if time.time() - started > config.TURN_WALL_CLOCK:
            break
        msg, usage = llm.chat(messages, tools=T.SCHEMAS)
        usage_total['prompt_tokens'] += usage.get('prompt_tokens') or 0
        usage_total['completion_tokens'] += usage.get('completion_tokens') or 0
        usage_total['model'] = usage.get('model') or usage_total['model']

        calls = msg.get('tool_calls') or []
        # В историю кладём сообщение без служебного поля _args. Копии обязательно
        # новые: поверхностная копия разделяет те же dict'ы вызовов, и pop('_args')
        # стёр бы аргументы, которые нам ещё предстоит прочитать ниже.
        clean = {k: v for k, v in msg.items() if k != '_args'}
        if calls:
            clean['tool_calls'] = [{k: v for k, v in c.items() if k != '_args'} for c in calls]
        messages.append(clean)
        turn_msgs.append(clean)

        if not calls:
            answer = strip_markdown(scrub((msg.get('content') or '').strip()))
            return _finish(chat_id, history, turn_msgs, answer, tools_used, usage_total, started)

        for call in calls:
            fname = (call.get('function') or {}).get('name') or '?'
            args = call.get('_args') or {}
            if on_progress:
                on_progress('  → %s(%s)' % (fname, json.dumps(args, ensure_ascii=False)))

            if spent_chars >= config.TURN_OUTPUT_CAP:
                out = json.dumps({'error': 'достигнут лимит объёма данных за ход; '
                                           'отвечай по уже полученному'}, ensure_ascii=False)
            else:
                out = T.dispatch(fname, args, ctx={'chat_id': chat_id})
                spent_chars += len(out)
            tools_used.append(fname)
            tmsg = _tool_stub_message(call, out)
            messages.append(tmsg)
            turn_msgs.append(tmsg)

    # Раунды исчерпаны — просим финальный ответ уже без инструментов.
    messages.append({'role': 'system', 'content':
                     'Лимит вызовов инструментов исчерпан. Дай финальный ответ по тому, '
                     'что уже собрано, и честно отметь, чего проверить не удалось.'})
    try:
        msg, usage = llm.chat(messages, tools=None)
        usage_total['completion_tokens'] += usage.get('completion_tokens') or 0
        answer = strip_markdown(scrub((msg.get('content') or '').strip()))
    except Exception as e:
        answer = 'Не удалось завершить разбор: %s\n\n%s' % (e, snapshot.build())
    return _finish(chat_id, history, turn_msgs, answer, tools_used, usage_total, started)


def _finish(chat_id, history, turn_msgs, answer, tools_used, usage, started):
    if not answer:
        answer = 'Модель вернула пустой ответ. Вот сырое состояние:\n\n' + snapshot.build()
    turn_msgs.append({'role': 'assistant', 'content': answer})
    new_history = memory.trim(memory.collapse_tool_outputs(history + turn_msgs))
    memory.save(chat_id, new_history)
    meta = {
        'инструменты': tools_used,
        'модель': usage.get('model'),
        'токены': (usage.get('prompt_tokens') or 0) + (usage.get('completion_tokens') or 0),
        'секунд': round(time.time() - started, 1),
    }
    return answer, meta
