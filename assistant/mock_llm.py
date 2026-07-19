"""Офлайновая заглушка модели: ASSISTANT_LLM_MOCK=1.

Проигрывает реалистичный сценарий tool-use, чтобы прогнать весь цикл без ключа,
без сети и без денег. Используется в тестах и при отладке инструментов.
"""
import json


def _call(idx, name, args):
    return {
        'id': 'mock_call_%d' % idx,
        'type': 'function',
        'function': {'name': name, 'arguments': json.dumps(args, ensure_ascii=False)},
        '_args': args,
    }


def mock_chat(messages, tools=None):
    """Первый заход — просим инструменты, второй — отвечаем текстом."""
    already = [m for m in messages if m.get('role') == 'tool']
    usage = {'prompt_tokens': 100, 'completion_tokens': 50, 'model': 'mock'}

    if tools and not already:
        user = ''
        for m in reversed(messages):
            if m.get('role') == 'user':
                user = (m.get('content') or '').lower()
                break
        if 'вход' in user or 'сигнал' in user:
            calls = [_call(1, 'get_signals', {'contour': 'crypto', 'only_failed': True, 'limit': 5})]
        elif 'лог' in user:
            calls = [_call(1, 'tail_log', {'source': 'rf_tick', 'lines': 20})]
        else:
            calls = [_call(1, 'get_state', {'contour': 'all'})]
        return {'role': 'assistant', 'content': None, 'tool_calls': calls}, usage

    return ({'role': 'assistant',
             'content': 'MOCK-ответ: цикл отработал, инструменты вызваны и вернули данные.'},
            usage)
