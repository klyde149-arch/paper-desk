"""Действия ассистента: ручное закрытие paper-сделок (Фаза 2 из README_ASSISTANT).

Единственное действие — закрыть существующую фьючерсную позицию бумажного
контура (C2/C3b, зеркально в обоих профилях). Инструментов открытия позиций
или изменения стопов не существует в принципе.

Безопасность по дизайну:
  * Токен подтверждения генерит КОД (secrets.token_hex), модели он не
    возвращается и в текст чата не попадает — живёт только в PENDING_FILE и
    в callback_data кнопок. Модель физически не может подтвердить сама.
  * При config.DRY_ACTIONS заявка пишется в песочницу STATE_DIR/sandbox
    вместо data/rf — полный прогон UX без эффекта.
  * Каждая створка (propose/confirm/cancel/expired) — строка в AUDIT_FILE.

Транспорт: заявка -> data/rf/manual_close_req.json (пишет ТОЛЬКО ассистент),
её коммитит ближайший live_rf_tick.sh, push триггерит Actions-тик, движок
rf_engine.ps1 закрывает по рынку и пишет data/rf/manual_close_res.json
(пишет ТОЛЬКО движок). Идемпотентность — реестр req_id в res-файле.
"""
import calendar
import json
import os
import secrets
import subprocess
import time

from . import config

# Замок git-операций RF-тика (deploy/live-rf-tick.service берёт его через flock).
# Мгновенный пуш заявки обязан взять ТОТ ЖЕ замок, чтобы не драться за git-индекс.
RF_TICK_LOCK = '/run/lock/live-rf-tick.lock'

ASSET_RU = {
    'BR': 'нефть Brent', 'NG': 'газ', 'GOLD': 'золото', 'SILV': 'серебро',
    'Si': 'доллар-рубль', 'RTS': 'индекс RTS', 'CNY': 'юань', 'MIX': 'индекс МосБиржи',
}
SLEEVE_RU = {'core': 'ядро', 'setA': 'сетап A'}
SIDE_RU = {'long': 'лонг', 'short': 'шорт'}
ASSETS = tuple(ASSET_RU)
PROFILES = ('c2', 'c3b')


def _read_json(path):
    try:
        with open(path, 'r', encoding='utf-8-sig') as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _write_json_atomic(path, obj):
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def audit(event, **kw):
    try:
        line = '%s|%s|%s\n' % (
            time.strftime('%Y-%m-%d %H:%M:%SZ', time.gmtime()), event,
            json.dumps(kw, ensure_ascii=False, sort_keys=True))
        os.makedirs(os.path.dirname(config.AUDIT_FILE), exist_ok=True)
        with open(config.AUDIT_FILE, 'a', encoding='utf-8') as f:
            f.write(line)
    except OSError:
        pass  # аудит не должен ронять действие


# ---------------------------------------------------------------------------
# позиции бумажного фьючерсного контура (C2/C3b)
# ---------------------------------------------------------------------------

def list_paper_positions():
    """Открытые фьючерсные позиции бумаги, зеркальные C2/C3b слиты в одну запись.

    Возвращает [{asset, sleeve, side, secid, entry, entry_day, stop, cur, r,
                 ids: {C2: 'R7', C3b: 'R8'}, display}]
    """
    merged = {}
    for prof in PROFILES:
        p = _read_json(os.path.join(config.REPO, 'data', 'rf', '%s_portfolio.json' % prof))
        if not p:
            continue
        label = 'C2' if prof == 'c2' else 'C3b'
        sleeves = (p.get('sleeves') or {})
        for sleeve in ('core', 'setA'):
            for pos in ((sleeves.get(sleeve) or {}).get('positions') or []):
                if not pos:
                    continue
                key = (pos.get('asset'), sleeve)
                m = merged.setdefault(key, {
                    'asset': pos.get('asset'), 'sleeve': sleeve,
                    'side': pos.get('side'), 'secid': pos.get('secid'),
                    'entry': pos.get('entry'), 'entry_day': pos.get('entry_day'),
                    'stop': pos.get('stop'), 'cur': pos.get('cur'), 'r': None,
                    'ids': {},
                })
                m['ids'][label] = pos.get('id')
                # R одинаков в обоих профилях (одна сделка, разный размер) — берём где есть
                try:
                    risk = float(pos.get('risk_usd') or 0)
                    if risk > 0 and pos.get('upnl') is not None:
                        m['r'] = round(float(pos['upnl']) / risk, 2)
                except (TypeError, ValueError):
                    pass
    out = []
    for m in merged.values():
        m['display'] = _display(m)
        out.append(m)
    out.sort(key=lambda x: (x['asset'] or '', x['sleeve']))
    return out


def _display(m):
    side = SIDE_RU.get(m.get('side'), m.get('side') or '?')
    asset = ASSET_RU.get(m.get('asset'), m.get('asset') or '?')
    sleeve = SLEEVE_RU.get(m.get('sleeve'), m.get('sleeve') or '?')
    r = m.get('r')
    rtxt = ('%+.2fR' % r) if isinstance(r, (int, float)) else '?R'
    return '%s %s (%s), вход %s, сейчас %s' % (side, asset, sleeve, m.get('entry'), rtxt)


def find_position(asset, sleeve=None):
    """Найти позицию по активу (и рукаву). -> (позиция|None, ошибка|None)."""
    hits = [m for m in list_paper_positions() if m['asset'] == asset]
    if not hits:
        return None, 'нет открытой бумажной позиции по %s' % ASSET_RU.get(asset, asset)
    if sleeve:
        hits = [m for m in hits if m['sleeve'] == sleeve]
        if not hits:
            return None, 'нет позиции %s в рукаве %s' % (asset, sleeve)
    if len(hits) > 1:
        return None, ('позиция %s есть в нескольких рукавах: %s — уточни какой'
                      % (asset, ', '.join(sorted(m['sleeve'] for m in hits))))
    return hits[0], None


# ---------------------------------------------------------------------------
# pending-подтверждения (PENDING_FILE, TTL)
# ---------------------------------------------------------------------------

def _load_pending():
    return _read_json(config.PENDING_FILE) or {}


def _save_pending(p):
    _write_json_atomic(config.PENDING_FILE, p)


def _prune_pending(p):
    now = time.time()
    return {k: v for k, v in p.items()
            if now - float(v.get('created') or 0) <= config.CONFIRM_TTL_SEC}


def create_pending(chat_id, asset, sleeve, note=''):
    """Создать pending-подтверждение. -> (token, display) | (None, ошибка)."""
    pos, err = find_position(asset, sleeve)
    if err:
        return None, err
    token = secrets.token_hex(8)
    p = _prune_pending(_load_pending())
    # старый неподтверждённый запрос по тому же активу вытесняется — жив последний
    p = {k: v for k, v in p.items()
         if not (v.get('asset') == asset and v.get('sleeve') == pos['sleeve'])}
    p[token] = {'action': 'close_paper', 'asset': asset, 'sleeve': pos['sleeve'],
                'chat_id': str(chat_id), 'note': str(note or '')[:200],
                'display': pos['display'], 'created': time.time()}
    _save_pending(p)
    audit('propose', chat=str(chat_id), asset=asset, sleeve=pos['sleeve'],
          dry=config.DRY_ACTIONS)
    return token, pos['display']


def cancel_pending(token, chat_id):
    p = _load_pending()
    v = p.get(token)
    if v and v.get('chat_id') == str(chat_id):
        p.pop(token, None)
        _save_pending(p)
        audit('cancel', chat=str(chat_id), asset=v.get('asset'), sleeve=v.get('sleeve'))
        return True
    return False


def req_file_path():
    if config.DRY_ACTIONS:
        return os.path.join(config.ACTIONS_SANDBOX, 'manual_close_req.json')
    return config.MANUAL_CLOSE_REQ


def confirm_pending(token, chat_id):
    """Подтвердить: записать заявку в req-файл. -> {'ok': bool, 'msg': str}."""
    p = _load_pending()
    v = p.get(token)
    if not v or v.get('chat_id') != str(chat_id):
        return {'ok': False, 'msg': 'Подтверждение устарело или уже обработано.'}
    if time.time() - float(v.get('created') or 0) > config.CONFIRM_TTL_SEC:
        p.pop(token, None)
        _save_pending(p)
        audit('expired', chat=str(chat_id), asset=v.get('asset'))
        return {'ok': False, 'msg': 'Подтверждение протухло (%d с). Запроси закрытие заново.'
                                    % config.CONFIRM_TTL_SEC}
    # revalidate: позиция могла закрыться стопом, пока пользователь думал
    pos, err = find_position(v['asset'], v['sleeve'])
    if err:
        p.pop(token, None)
        _save_pending(p)
        return {'ok': False, 'msg': 'Уже неактуально: %s.' % err}

    path = req_file_path()
    req = _read_json(path) or {'schema': 1, 'requests': []}
    reqs = [r for r in (req.get('requests') or []) if r]
    # чистка: исполненные и совсем старые (>48ч) записи не копим
    done = _processed_req_ids()
    cutoff = time.time() - 48 * 3600
    keep = []
    for r in reqs:
        if r.get('req_id') in done:
            continue
        try:
            ts = calendar.timegm(time.strptime(r.get('requested_utc', ''), '%Y-%m-%d %H:%M'))
        except (ValueError, OverflowError):
            ts = 0
        if ts < cutoff:
            continue
        keep.append(r)
    if any(r.get('req_id') == token for r in keep):
        pass  # повторное нажатие — та же заявка уже в очереди, это no-op
    elif any(r.get('asset') == v['asset'] and r.get('sleeve') == v['sleeve']
             and r.get('contour') == 'paper' for r in keep):
        p.pop(token, None)
        _save_pending(p)
        return {'ok': False, 'msg': 'Заявка на закрытие %s уже в очереди — жду исполнения.'
                                    % ASSET_RU.get(v['asset'], v['asset'])}
    else:
        keep.append({'req_id': token, 'contour': 'paper',
                     'asset': v['asset'], 'sleeve': v['sleeve'],
                     'requested_utc': time.strftime('%Y-%m-%d %H:%M', time.gmtime()),
                     'chat_id': str(chat_id), 'note': v.get('note') or ''})
    req['requests'] = keep
    # порядок важен: сначала заявка на диск, потом pop pending — падение между
    # шагами упрётся в дедуп req_id, а не в двойное закрытие
    _write_json_atomic(path, req)
    p.pop(token, None)
    _save_pending(p)
    pushed = False if config.DRY_ACTIONS else push_request_now()
    audit('confirm', chat=str(chat_id), asset=v['asset'], sleeve=v['sleeve'],
          req_id=token, dry=config.DRY_ACTIONS, pushed=pushed)
    if config.DRY_ACTIONS:
        eta = ' [DRY: песочница, движок её не увидит]'
    elif pushed:
        eta = ' Заявка уже отправлена в обработку, обычно это 1-3 минуты.'
    else:
        eta = ' Заявку отправит ближайший тик (до минуты), исполнение обычно 2-4 минуты.'
    return {'ok': True, 'msg': 'Заявка принята: закрою %s в C2 и C3b по рынку.%s '
                               'Пришлю цену исполнения.'
                               % (v.get('display') or v['asset'], eta),
            'display': v.get('display')}


def push_request_now():
    """Мгновенный коммит+пуш заявки, не дожидаясь минутного тика.

    Ускорение, а не гарантия: при ЛЮБОЙ неудаче (замок занят, сеть, rebase)
    молча отступаем — fast-path в live_rf_tick.sh допушит файл в течение
    минуты, страховочный контур не отключён. Linux-only (на Windows-тестах
    и в DRY пуш не нужен). Возвращает True, если заявка уже в origin.
    """
    if os.name == 'nt':
        return False
    try:
        import fcntl
    except ImportError:
        return False

    def git(*argv, **kw):
        timeout = kw.get('timeout', 25)
        return subprocess.run(['git', '-C', config.REPO] + list(argv),
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=timeout)

    rel = 'data/rf/manual_close_req.json'
    lock = None
    try:
        lock = open(RF_TICK_LOCK, 'a')
        # до ~10 с ждём замок RF-тика; занят дольше — не блокируем callback бота
        for _ in range(20):
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                time.sleep(0.5)
        else:
            return False
        git('add', rel)
        if git('diff', '--cached', '--quiet').returncode == 0:
            return True  # нечего пушить: файл уже уехал (например, тиком)
        if git('-c', 'user.name=live-desk-bot',
               '-c', 'user.email=live-desk-bot@users.noreply.github.com',
               'commit', '-m', 'manual-close request (instant push)').returncode != 0:
            return False
        if git('push', 'origin', 'main', timeout=40).returncode == 0:
            return True
        # origin успел уйти вперёд - одна попытка rebase
        if (git('fetch', 'origin', timeout=40).returncode == 0
                and git('rebase', 'origin/main').returncode == 0
                and git('push', 'origin', 'main', timeout=40).returncode == 0):
            return True
        git('rebase', '--abort')
        return False
    except Exception:
        return False
    finally:
        if lock is not None:
            try:
                lock.close()  # close снимает flock
            except OSError:
                pass


def _processed_req_ids():
    res = _read_json(config.MANUAL_CLOSE_RES) or {}
    return {r.get('req_id') for r in (res.get('results') or []) if r}


# ---------------------------------------------------------------------------
# вотчер результатов исполнения (res-файл приезжает git pull'ом)
# ---------------------------------------------------------------------------

def watch_results():
    """Новые (ещё не объявленные) результаты исполнения. -> [{chat_id, text}]."""
    res = _read_json(config.MANUAL_CLOSE_RES) or {}
    results = [r for r in (res.get('results') or []) if r and r.get('req_id')]
    if not results:
        return []
    ann = _read_json(config.ANNOUNCED_FILE)
    if ann is None:
        # первый запуск: всё, что уже в res-файле, — древняя история, не спамим
        _write_json_atomic(config.ANNOUNCED_FILE,
                           {'req_ids': sorted(r['req_id'] for r in results)})
        return []
    seen = set(ann.get('req_ids') or [])
    fresh = [r for r in results if r['req_id'] not in seen]
    if not fresh:
        return []
    out = []
    for r in fresh:
        out.append({'chat_id': str(r.get('chat_id') or ''), 'text': _format_result(r)})
        seen.add(r['req_id'])
    # держим хвост, чтобы файл не рос вечно (в res-файле движок хранит 200)
    _write_json_atomic(config.ANNOUNCED_FILE, {'req_ids': sorted(seen)[-500:]})
    return out


def _format_result(r):
    st = r.get('status')
    if st == 'done':
        lines = ['Исполнено: ручное закрытие по рынку.']
        for c in (r.get('closed') or []):
            side = SIDE_RU.get(c.get('side'), c.get('side') or '?')
            asset = ASSET_RU.get(c.get('asset'), c.get('asset') or '?')
            rm = c.get('r')
            rtxt = (' (%+.2fR)' % rm) if isinstance(rm, (int, float)) else ''
            lines.append('%s: %s закрыт %s %s @ %s, P&L %+0.2f$%s'
                         % (c.get('profile'), c.get('id'), side, asset,
                            c.get('px'), float(c.get('pnl') or 0), rtxt))
        return '\n'.join(lines)
    if st == 'not-found':
        return 'Заявка на закрытие снята: %s.' % (r.get('note') or 'позиции уже нет')
    if st == 'expired':
        return 'Заявка на закрытие протухла и не исполнена: %s.' % (r.get('note') or '')
    return 'Заявка на закрытие: статус %s. %s' % (st, r.get('note') or '')


# ---------------------------------------------------------------------------
# меню позиций с кнопками
# ---------------------------------------------------------------------------

def build_positions_menu():
    """-> (text, inline_keyboard | None) для /позиции."""
    pos = list_paper_positions()
    if not pos:
        return 'Открытых бумажных фьючерсных позиций нет.', None
    lines = ['Открытые позиции (бумага, C2+C3b):']
    kb = []
    for m in pos:
        lines.append('• ' + m['display'])
        kb.append([{'text': 'Закрыть: %s %s (%s)'
                            % (SIDE_RU.get(m['side'], '?'),
                               ASSET_RU.get(m['asset'], m['asset']),
                               SLEEVE_RU.get(m['sleeve'], m['sleeve'])),
                    'callback_data': 'mc:sel:%s:%s' % (m['asset'], m['sleeve'])}])
    lines.append('')
    lines.append('Кнопка запросит подтверждение; закрытие — по рынку, обычно за '
                 '1-3 минуты, в обоих профилях C2 и C3b.')
    return '\n'.join(lines), kb
