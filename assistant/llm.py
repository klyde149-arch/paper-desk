"""Клиент OpenRouter (OpenAI-совместимый chat/completions) на голом urllib.

Дешёвые модели (DeepSeek/Gemini) периодически отдают битый JSON в аргументах
tool_call — поэтому парсинг терпимый, с одной попыткой починки.
"""
import json
import time
import urllib.error
import urllib.request

from . import config


class LLMError(Exception):
    pass


def _post(url, payload, headers, timeout):
    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(url, data=data, headers=headers, method='POST')
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode('utf-8'))


def chat(messages, tools=None, model=None, max_tokens=None):
    """Один вызов модели. Возвращает (message_dict, usage_dict).

    message_dict — как в OpenAI: {role, content, tool_calls?}.
    При 429/5xx на основной модели один раз пробуем фолбэк.
    """
    if config.LLM_MOCK:
        from .mock_llm import mock_chat
        return mock_chat(messages, tools)

    if not config.API_KEY:
        raise LLMError('OPENROUTER_API_KEY не задан')

    headers = {
        'Authorization': 'Bearer ' + config.API_KEY,
        'Content-Type': 'application/json',
        # OpenRouter просит их для атрибуции; на функциональность не влияют.
        'HTTP-Referer': 'https://github.com/paper-desk',
        'X-Title': 'paper-desk assistant',
    }

    candidates = [model or config.MODEL]
    if config.MODEL_FALLBACK and config.MODEL_FALLBACK not in candidates:
        candidates.append(config.MODEL_FALLBACK)

    last_err = None
    for mi, mdl in enumerate(candidates):
        payload = {
            'model': mdl,
            'messages': messages,
            'max_tokens': max_tokens or config.MAX_TOKENS,
            'temperature': 0.2,
        }
        if tools:
            payload['tools'] = tools
            payload['tool_choice'] = 'auto'

        # два захода на сетевые сбои, потом — следующая модель
        for attempt in range(2):
            try:
                resp = _post(config.OPENROUTER_URL, payload, headers, config.LLM_TIMEOUT)
                choices = resp.get('choices') or []
                if not choices:
                    raise LLMError('пустой ответ модели: ' + json.dumps(resp)[:300])
                msg = choices[0].get('message') or {}
                msg.setdefault('role', 'assistant')
                usage = resp.get('usage') or {}
                usage['model'] = mdl
                return _normalize(msg), usage
            except urllib.error.HTTPError as e:
                body = ''
                try:
                    body = e.read().decode('utf-8', 'replace')[:300]
                except Exception:
                    pass
                last_err = LLMError('HTTP %s от %s: %s' % (e.code, mdl, body))
                # 4xx кроме 429 — на фолбэке не починится, но и ретрай не нужен
                if e.code == 429 or e.code >= 500:
                    time.sleep(1.5 * (attempt + 1))
                    continue
                break
            except Exception as e:
                last_err = LLMError('%s: %s' % (mdl, e))
                time.sleep(1.0 * (attempt + 1))
        if mi < len(candidates) - 1:
            continue
    raise last_err or LLMError('модель недоступна')


def _normalize(msg):
    """Привести tool_calls к предсказуемому виду и распарсить arguments.

    В arguments кладём уже словарь (ключ `_args`), сохраняя оригинальную строку —
    она нужна, чтобы вернуть сообщение обратно в историю без изменений.
    """
    calls = msg.get('tool_calls') or []
    for c in calls:
        fn = c.get('function') or {}
        raw = fn.get('arguments')
        c['_args'] = _parse_args(raw)
    return msg


def _parse_args(raw):
    if raw is None or raw == '':
        return {}
    if isinstance(raw, dict):
        return raw
    try:
        v = json.loads(raw)
        return v if isinstance(v, dict) else {}
    except Exception:
        pass
    # Попытка починки: модели любят обрамлять JSON в ```json ... ```
    s = str(raw).strip()
    if s.startswith('```'):
        s = s.strip('`')
        if s.lower().startswith('json'):
            s = s[4:]
        try:
            v = json.loads(s.strip())
            return v if isinstance(v, dict) else {}
        except Exception:
            pass
    # Последний шанс: вырезать первый {...}
    i, j = s.find('{'), s.rfind('}')
    if 0 <= i < j:
        try:
            v = json.loads(s[i:j + 1])
            return v if isinstance(v, dict) else {}
        except Exception:
            pass
    return {}
