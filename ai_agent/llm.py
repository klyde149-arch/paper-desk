"""Клиент OpenRouter для агента (дизайн §3, §10).

Одна модель, без запасных: при сбое торговые данные не должны уйти в чужую модель (цепочку
llm.py Джарвиса не используем). Провайдеры — только те, что не собирают данные
(provider.data_collection = deny), и только поддерживающие все параметры запроса
(require_parameters), иначе structured output мог бы молча не соблюдаться.

Opus 5.5: рассуждение не выключается, его глубину задаёт reasoning.effort; temperature
не передаём (для модели убрана). Отказ модели / обрыв по длине -> LLMError.

Мок (AI_AGENT_LLM_MOCK=1): ответ даёт MOCK(messages, schema_name) — тесты подставляют свою функцию.
"""
import json
import time
import urllib.error
import urllib.request

from . import config as C


class LLMError(Exception):
    pass


def _default_mock(messages, schema_name):
    if schema_name == 'trade':
        return {'regime': {'rub': 'unclear', 'metals': 'unclear', 'energy': 'unclear', 'index': 'unclear'},
                'summary': 'мок: без действий', 'actions': [], 'skips': []}
    if schema_name == 'weekly':
        return {'review': 'мок: разбор недели', 'lessons': []}
    return {}


MOCK = _default_mock


def check_key(key):
    if not key:
        raise LLMError('AI_AGENT_OPENROUTER_KEY не задан (/etc/ai-agent.env)')
    try:
        key.encode('ascii')
    except UnicodeEncodeError:
        raise LLMError('AI_AGENT_OPENROUTER_KEY содержит не-ASCII символы — в env осталась заглушка')
    if not key.startswith('sk-or-') or len(key) < 30:
        raise LLMError('AI_AGENT_OPENROUTER_KEY не похож на ключ OpenRouter (sk-or-v1-...)')


def post(payload, timeout=C.LLM_TIMEOUT, retries=1):
    key = C.secrets()['openrouter']
    check_key(key)
    headers = {'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json',
               'HTTP-Referer': 'https://github.com/paper-desk', 'X-Title': 'paper-desk ai-agent'}
    data = json.dumps(payload).encode('utf-8')
    last = None
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(C.OPENROUTER_URL, data=data, headers=headers, method='POST')
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read().decode('utf-8'))
        except urllib.error.HTTPError as e:
            body = ''
            try:
                body = e.read().decode('utf-8', 'replace')[:300]
            except Exception:
                pass
            last = LLMError('HTTP %s: %s' % (e.code, body))
            if e.code != 429 and e.code < 500:
                break
        except Exception as e:
            last = LLMError('%s: %s' % (type(e).__name__, e))
        time.sleep(3 * (attempt + 1))
    raise last


def parse_json(text):
    s = (text or '').strip()
    if s.startswith('```'):
        s = s.strip('`')
        if s.lower().startswith('json'):
            s = s[4:]
    try:
        return json.loads(s)
    except ValueError:
        i, j = s.find('{'), s.rfind('}')
        if 0 <= i < j:
            return json.loads(s[i:j + 1])
        raise


def call_structured(messages, schema_name, schema, effort, max_tokens):
    """-> {'data': dict, 'usage': dict, 'raw': str, 'finish': str, 'model': str}."""
    if C.llm_mock():
        data = MOCK(messages, schema_name)
        return {'data': data, 'usage': {'prompt_tokens': 0, 'completion_tokens': 0, 'cost': 0.0},
                'raw': json.dumps(data, ensure_ascii=False), 'finish': 'stop', 'model': 'mock'}
    payload = {
        'model': C.MODEL,
        'messages': messages,
        'max_tokens': max_tokens,
        'reasoning': {'effort': effort},
        'response_format': {'type': 'json_schema',
                            'json_schema': {'name': schema_name, 'strict': True, 'schema': schema}},
        'provider': {'require_parameters': True, 'data_collection': 'deny'},
        'usage': {'include': True},
    }
    resp = post(payload)
    choices = resp.get('choices') or []
    if not choices:
        raise LLMError('пустой ответ: ' + json.dumps(resp, ensure_ascii=False)[:300])
    ch = choices[0]
    finish = ch.get('finish_reason') or ''
    raw = (ch.get('message') or {}).get('content') or ''
    usage = resp.get('usage') or {}
    out = {'usage': usage, 'raw': raw, 'finish': finish, 'model': resp.get('model') or C.MODEL}
    if finish in ('length', 'content_filter', 'refusal') or not raw:
        out['error'] = 'модель не закончила ответ: finish=%s' % finish
        raise LLMError(out['error'])
    try:
        out['data'] = parse_json(raw)
    except ValueError:
        raise LLMError('ответ не JSON: ' + raw[:200])
    return out


def call_text(model, messages, max_tokens, search=False):
    """Обычный текстовый вызов (новости через sonar). -> {'text', 'usage', 'citations'}."""
    if C.llm_mock():
        return {'text': MOCK(messages, 'news') or '', 'usage': {'cost': 0.0}, 'citations': []}
    payload = {'model': model, 'messages': messages, 'max_tokens': max_tokens, 'usage': {'include': True},
               'provider': {'data_collection': 'deny'}}
    resp = post(payload, timeout=120)
    choices = resp.get('choices') or []
    text = ((choices[0].get('message') or {}).get('content') or '') if choices else ''
    return {'text': text, 'usage': resp.get('usage') or {}, 'citations': resp.get('citations') or []}
