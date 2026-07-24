"""Демон Telegram: long-polling + агент.

Запускается под systemd (deploy/trading-assistant.service) с flock, потому что
ДВА процесса getUpdates на одном токене несовместимы — Telegram отдаёт 409.
Исходящие алерты торговых тиков (tools/lib_alerts.ps1) при этом работают как
работали: sendMessage и getUpdates на одном токене сосуществуют штатно.
"""
import json
import os
import sys
import time

if __package__ in (None, ''):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    __package__ = 'assistant'

from . import actions, agent, config, memory, snapshot, tg  # noqa: E402

_rate = {}          # chat_id -> [timestamps]
_START_TS = time.time()
_res_mtime = [0.0]  # mtime res-файла ручных закрытий (вотчер)

HELP = """Я ассистент paper-desk. Спрашивай обычным текстом, по-русски.

Примеры:
  что с ботом
  почему не было входов сегодня
  закрой позицию по нефти
  покажи логи rf за последний час
  всё ли живо на сервере

Команды:
  /статус — состояние обоих контуров без обращения к модели (быстро и бесплатно)
  /позиции — открытые бумажные фьючерсные позиции с кнопками закрытия
  /сброс — очистить контекст диалога
  /помощь — это сообщение"""


def log(msg):
    print('%s %s' % (time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), msg), flush=True)


# --- offset ----------------------------------------------------------------

def load_offset():
    try:
        with open(config.OFFSET_FILE, 'r', encoding='utf-8') as f:
            return int(f.read().strip() or 0)
    except (OSError, ValueError):
        return 0


def save_offset(v):
    try:
        tmp = config.OFFSET_FILE + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            f.write(str(v))
        os.replace(tmp, config.OFFSET_FILE)
    except OSError as e:
        log('WARN: не сохранился offset: %s' % e)


# --- лимиты ----------------------------------------------------------------

def rate_ok(chat_id):
    now = time.time()
    hits = [t for t in _rate.get(chat_id, []) if now - t < config.RATE_WINDOW_SEC]
    if len(hits) >= config.RATE_MSGS:
        _rate[chat_id] = hits
        return False
    hits.append(now)
    _rate[chat_id] = hits
    return True


def _budget():
    try:
        with open(config.BUDGET_FILE, 'r', encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def budget_ok():
    day = time.strftime('%Y-%m-%d', time.gmtime())
    b = _budget().get(day) or {}
    return (b.get('tokens', 0) < config.DAILY_TOKENS
            and b.get('calls', 0) < config.DAILY_CALLS)


def budget_add(tokens):
    day = time.strftime('%Y-%m-%d', time.gmtime())
    b = _budget()
    d = b.get(day) or {'tokens': 0, 'calls': 0}
    d['tokens'] += int(tokens or 0)
    d['calls'] += 1
    b = {day: d}  # держим только текущий день
    try:
        tmp = config.BUDGET_FILE + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump(b, f)
        os.replace(tmp, config.BUDGET_FILE)
    except OSError:
        pass


# --- обработка -------------------------------------------------------------

def handle_message(upd):
    msg = upd.get('message') or {}
    chat_id = str(((msg.get('chat') or {}).get('id')) or '')
    text = (msg.get('text') or '').strip()
    if not chat_id or not text:
        return

    # Молчаливый игнор всех, кто не в whitelist: бот не должен отвечать
    # случайным людям и вообще выдавать своё существование.
    if chat_id not in config.ALLOWED_CHATS:
        log('игнор чужого чата %s' % chat_id)
        return

    # Апдейты старше 5 минут после старта не отыгрываем: после простоя не нужно
    # исполнять очередь трёхчасовой давности.
    if msg.get('date') and time.time() - float(msg['date']) > 300:
        log('пропуск устаревшего сообщения (%.0f с)' % (time.time() - float(msg['date'])))
        return

    low = text.lower().lstrip('/')
    if low in ('помощь', 'help', 'start'):
        tg.send(chat_id, HELP)
        return
    if low in ('сброс', 'new', 'reset'):
        memory.reset(chat_id)
        tg.send(chat_id, 'Контекст очищен.')
        return
    if low in ('статус', 'status'):
        tg.send(chat_id, snapshot.build())
        return
    if low in ('позиции', 'positions'):
        menu, kb = actions.build_positions_menu()
        tg.send(chat_id, menu, keyboard=kb)
        return
    if low == 'reload':
        agent.reload_prompt()
        tg.send(chat_id, 'Промпты перечитаны с диска.')
        return

    if len(text) > config.MAX_INCOMING_CHARS:
        tg.send(chat_id, 'Слишком длинное сообщение (>%d символов).' % config.MAX_INCOMING_CHARS)
        return
    if not rate_ok(chat_id):
        tg.send(chat_id, 'Слишком часто. Подожди пару минут.')
        return
    if not budget_ok():
        tg.send(chat_id, 'Дневной лимит запросов к модели исчерпан. '
                         'Состояние без модели — командой /статус.')
        return

    tg.send_typing(chat_id)
    t0 = time.time()
    try:
        answer, meta = agent.run_turn(chat_id, text)
        budget_add(meta.get('токены'))
        log('ответ chat=%s инстр=%s токенов=%s за %.1fс'
            % (chat_id, ','.join(meta['инструменты']) or '-', meta['токены'], time.time() - t0))
        tg.send(chat_id, answer)
    except Exception as e:
        log('ОШИБКА хода: %s' % e)
        # Даже когда модель недоступна, состояние отдать обязаны.
        tg.send(chat_id, 'Не смог ответить через модель (%s).\n\n%s' % (e, snapshot.build()))


def handle_callback(upd):
    """Кнопки ручного закрытия: mc:sel:<asset>:<sleeve> | mc:ok:<token> | mc:no:<token>."""
    cb = upd.get('callback_query') or {}
    msg = cb.get('message') or {}
    chat_id = str(((msg.get('chat') or {}).get('id')) or '')
    from_id = str(((cb.get('from') or {}).get('id')) or '')
    # авторизация по нажавшему И по чату: чужие клики молча игнорируем
    if chat_id not in config.ALLOWED_CHATS or from_id not in config.ALLOWED_CHATS:
        log('игнор callback из чужого чата %s (from %s)' % (chat_id, from_id))
        return
    data = str(cb.get('data') or '')
    mid = msg.get('message_id')

    if data.startswith('mc:sel:'):
        parts = data.split(':')
        if len(parts) != 4:
            tg.answer_callback(cb.get('id'))
            return
        token, disp = actions.create_pending(chat_id, parts[2], parts[3], note='меню /позиции')
        if token is None:
            tg.answer_callback(cb.get('id'), 'Не получилось')
            tg.send(chat_id, 'Не получилось: %s.' % disp)
            return
        tg.answer_callback(cb.get('id'))
        dry = ' [тестовый режим: заявка уйдёт в песочницу]' if config.DRY_ACTIONS else ''
        tg.send(chat_id,
                'Закрыть %s?\nЗакрытие по рынку в обоих профилях (C2 и C3b), обычно 1-3 минуты.%s'
                % (disp, dry),
                keyboard=[[{'text': '✅ Подтвердить', 'callback_data': 'mc:ok:' + token},
                           {'text': '✖ Отмена', 'callback_data': 'mc:no:' + token}]])
    elif data.startswith('mc:ok:'):
        r = actions.confirm_pending(data[len('mc:ok:'):], chat_id)
        tg.answer_callback(cb.get('id'), 'Принято' if r.get('ok') else 'Не вышло')
        # edit_text заодно убирает кнопки — повторный клик по старому сообщению невозможен
        if mid:
            tg.edit_text(chat_id, mid, r.get('msg') or '')
        else:
            tg.send(chat_id, r.get('msg') or '')
        log('manual-close confirm chat=%s ok=%s' % (chat_id, r.get('ok')))
    elif data.startswith('mc:no:'):
        actions.cancel_pending(data[len('mc:no:'):], chat_id)
        tg.answer_callback(cb.get('id'))
        if mid:
            tg.edit_text(chat_id, mid, 'Отменено.')
    else:
        tg.answer_callback(cb.get('id'))


def check_close_results():
    """Результаты исполнения ручных закрытий приезжают git pull'ом — объявляем новые."""
    try:
        m = os.path.getmtime(config.MANUAL_CLOSE_RES)
    except OSError:
        return
    if m == _res_mtime[0]:
        return
    _res_mtime[0] = m
    try:
        for r in actions.watch_results():
            cid = r.get('chat_id') or ''
            targets = [cid] if cid in config.ALLOWED_CHATS else sorted(config.ALLOWED_CHATS)
            for c in targets:
                tg.send(c, r['text'])
            log('manual-close result -> %s' % ','.join(targets))
    except Exception as e:
        log('ОШИБКА вотчера результатов: %s' % e)


def main():
    if not config.TG_TOKEN:
        log('FATAL: TG_BOT_TOKEN не задан')
        return 1
    if not config.ALLOWED_CHATS:
        log('FATAL: ASSISTANT_TG_ALLOWED_CHATS/TG_CHAT_ID не заданы — некому отвечать')
        return 1

    config.ensure_state_dirs()
    offset = load_offset()
    log('старт: модель=%s чатов_в_whitelist=%d offset=%d dry_actions=%s'
        % (config.MODEL, len(config.ALLOWED_CHATS), offset, config.DRY_ACTIONS))

    backoff = 1
    while True:
        try:
            updates = tg.get_updates(offset)
            backoff = 1
            for upd in updates:
                offset = max(offset, int(upd.get('update_id', 0)) + 1)
                save_offset(offset)
                try:
                    if upd.get('message'):
                        handle_message(upd)
                    elif upd.get('callback_query'):
                        handle_callback(upd)
                except Exception as e:
                    log('ОШИБКА обработки апдейта: %s' % e)
            check_close_results()
        except tg.TgConflict as e:
            # Кто-то ещё поллит этот токен. Горячий цикл здесь недопустим.
            log('КОНФЛИКТ: %s — жду %d с. Проверь, не запущен ли второй экземпляр '
                'или старый бот на том же токене.' % (e, min(backoff * 10, 300)))
            time.sleep(min(backoff * 10, 300))
            backoff = min(backoff * 2, 30)
        except KeyboardInterrupt:
            log('остановка по Ctrl+C')
            return 0
        except Exception as e:
            log('сетевая ошибка: %s — повтор через %d с' % (e, backoff))
            time.sleep(backoff)
            backoff = min(backoff * 2, 60)


if __name__ == '__main__':
    sys.exit(main())
