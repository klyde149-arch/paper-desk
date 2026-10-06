"""Схема ответа модели и смысловая проверка решений (дизайн §7, §10, §15).

Схема идёт в OpenRouter как structured output (strict). Ограничения Claude на схему: без
minimum/maximum/minLength, у каждого объекта additionalProperties: false, поля «необязательные»
через null. Всё, что схема выразить не может, проверяет validate(): универсум, сторона стопа,
рамки §6, правила точки. Невалидное действие отбрасывается с причиной, остальные применяются.
"""
from . import book
from . import config as C

REGIME = ['trend', 'range', 'unclear']
SETUPS = ['pullback', 'early_breakout', 'catalyst']
CLOSE_KINDS = ['idea_broken', 'pre_event', 'take_profit']
TAGS = ['event_tighten']
GROUPS = ('rub', 'metals', 'energy', 'index')
MAX_TEXT = 300
MAX_SKIP_TEXT = 200


def _nullable(schema):
    return {'anyOf': [schema, {'type': 'null'}]}


def _enum(values):
    return {'type': 'string', 'enum': list(values)}


TRADE_SCHEMA = {
    'type': 'object',
    'additionalProperties': False,
    'required': ['regime', 'summary', 'actions', 'skips'],
    'properties': {
        'regime': {
            'type': 'object', 'additionalProperties': False,
            'required': ['rub', 'metals', 'energy', 'index'],
            'properties': {g: _enum(REGIME) for g in GROUPS},
        },
        'summary': {'type': 'string', 'description': 'Картина рынка одной-двумя фразами, до 300 символов'},
        'actions': {
            'type': 'array',
            'items': {
                'type': 'object', 'additionalProperties': False,
                'required': ['instrument', 'action', 'side', 'order', 'limit_px', 'stop_px', 'target_px',
                             'horizon_days', 'setup', 'close_kind', 'tag', 'reason', 'invalidation'],
                'properties': {
                    'instrument': _enum(C.UNIVERSE),
                    'action': _enum(['enter', 'cancel', 'modify', 'close', 'hold']),
                    'side': _nullable(_enum(['long', 'short'])),
                    'order': _nullable(_enum(['market', 'limit'])),
                    'limit_px': _nullable({'type': 'number'}),
                    'stop_px': _nullable({'type': 'number'}),
                    'target_px': _nullable({'type': 'number'}),
                    'horizon_days': _nullable({'type': 'integer'}),
                    'setup': _nullable(_enum(SETUPS)),
                    'close_kind': _nullable(_enum(CLOSE_KINDS)),
                    'tag': _nullable(_enum(TAGS)),
                    'reason': {'type': 'string'},
                    'invalidation': _nullable({'type': 'string'}),
                },
            },
        },
        'skips': {
            'type': 'array',
            'description': 'Отказы войти по трендовой группе без позиции и заявки: инструмент, сторона тренда, причина',
            'items': {
                'type': 'object', 'additionalProperties': False,
                'required': ['instrument', 'side', 'reason'],
                'properties': {
                    'instrument': _enum(C.UNIVERSE),
                    'side': _enum(['long', 'short']),
                    'reason': {'type': 'string'},
                },
            },
        },
    },
}


def _txt(s, n=MAX_TEXT):
    s = ' '.join(str(s or '').split())
    return s[:n]


def _ticks(asset, a, b):
    return abs(a - b) / C.TICK[asset]


def validate(resp, ctx):
    """resp — разобранный JSON модели. ctx: point ('main'|...), allowed (set инструментов точки),
    state, last_px {asset: цена}, hourly_ok {asset: bool}, halt_files (str|None).
    -> (принятые действия, отказы [{instrument, action, why}]). Структура сломана -> ValueError."""
    if not isinstance(resp, dict) or not isinstance(resp.get('actions'), list):
        raise ValueError('ответ не по схеме: нет actions')
    state, point = ctx['state'], ctx['point']
    ok, bad, seen = [], [], set()
    # теневой рукав: лимиты 3/2 считают и входы, уже принятые из ЭТОГО ЖЕ ответа
    # (найдено сухим прогоном: пять входов в одном ответе проходили проверку по отдельности)
    shadow = {'positions': state['positions'], 'orders': list(state['orders']), 'halt': state.get('halt')}

    def reject(a, why):
        bad.append({'instrument': a.get('instrument'), 'action': a.get('action'), 'why': why})

    for a in resp['actions']:
        if not isinstance(a, dict):
            bad.append({'instrument': None, 'action': None, 'why': 'действие не объект'})
            continue
        inst, act = a.get('instrument'), a.get('action')
        if inst not in C.UNIVERSE:
            reject(a, 'инструмент вне универсума')
            continue
        if inst in seen:
            reject(a, 'второе действие по тому же инструменту')
            continue
        seen.add(inst)
        if act == 'hold':
            continue
        if inst not in ctx['allowed']:
            reject(a, 'инструмент не входит в эту проверку')
            continue
        a = dict(a)
        # event_tighten имеет смысл только у подтяжки стопа позиции; в остальных действиях — шум
        a['tag'] = a.get('tag') if act == 'modify' and a.get('tag') in TAGS else None
        a['reason'] = _txt(a.get('reason'))
        a['invalidation'] = _txt(a.get('invalidation')) or None
        if not a['reason']:
            reject(a, 'нет причины')
            continue
        px = ctx['last_px'].get(inst)
        why = None
        if act == 'enter':
            why = _check_enter(a, shadow, px, ctx)
            if not why:
                shadow['orders'] = [o for o in shadow['orders'] if o['instrument'] != inst] + [{'instrument': inst}]
        elif act == 'cancel':
            if not any(o['instrument'] == inst for o in state['orders']):
                why = 'нет заявки для отмены'
        elif act == 'modify':
            why = _check_modify(a, state, px)
        elif act == 'close':
            if book.position(state, inst) is None:
                why = 'нет позиции для закрытия'
            elif a.get('close_kind') not in CLOSE_KINDS:
                why = 'не указан close_kind'
            elif point != 'main' and a['close_kind'] == 'take_profit':
                why = 'фиксировать прибыль на дневных точках нельзя'
        else:
            why = 'неизвестное действие %r' % act
        if why:
            reject(a, why)
        else:
            ok.append(a)
    return ok, bad


def clean_skips(resp):
    """Отказы войти из ответа модели: только инструменты универсума, по одному на инструмент."""
    out, seen = [], set()
    rows = resp.get('skips') if isinstance(resp, dict) else None
    for x in rows if isinstance(rows, list) else []:
        if not isinstance(x, dict) or x.get('instrument') not in C.UNIVERSE or x['instrument'] in seen:
            continue
        reason = _txt(x.get('reason'), MAX_SKIP_TEXT)
        if not reason:
            continue
        seen.add(x['instrument'])
        out.append({'instrument': x['instrument'], 'side': x.get('side') if x.get('side') in ('long', 'short') else None,
                    'reason': reason})
    return out


def silent_skips(regime, state, skips, allowed, hourly_ok, entries_blocked=None, accepted=()):
    """Группы, отмеченные trend, где после решения нет ни позиции, ни заявки и нет строки-отказа
    (правило «тренд нельзя пропустить молча»). accepted — уже проверенные действия этого ответа:
    вход занимает группу, снятие заявки её освобождает. Не считаются группы, где войти было
    невозможно: входы запрещены, ни один инструмент группы не входит в проверку или без часовых данных."""
    if entries_blocked or not isinstance(regime, dict):
        return []
    insts = {p['instrument'] for p in state['positions']} | {o['instrument'] for o in state['orders']}
    for a in accepted:
        if a['action'] == 'enter':
            insts.add(a['instrument'])
        elif a['action'] == 'cancel' and book.position(state, a['instrument']) is None:
            insts.discard(a['instrument'])
    busy = {C.GROUP[a] for a in insts}
    excused = {C.GROUP[x['instrument']] for x in skips}
    out = []
    for g in GROUPS:
        if regime.get(g) != 'trend' or g in busy or g in excused:
            continue
        if any(C.GROUP[a] == g and a in allowed and hourly_ok.get(a) for a in C.UNIVERSE):
            out.append(g)
    return out


def _levels_ok(inst, side, ref, stop, target):
    sm = 1 if side == 'long' else -1
    if stop is None or target is None:
        return 'нужны стоп и цель'
    if sm * (ref - stop) <= 0:
        return 'стоп %s не с той стороны от цены %s' % (stop, ref)
    if sm * (target - ref) <= 0:
        return 'цель %s не с той стороны от цены %s' % (target, ref)
    if _ticks(inst, ref, stop) < 2:
        return 'стоп ближе двух шагов цены'
    if abs(ref - stop) / ref > C.MAX_STOP_FRAC:
        return 'стоп дальше %d%% от цены — похоже на опечатку' % round(C.MAX_STOP_FRAC * 100)
    return None


def _check_enter(a, state, px, ctx):
    inst = a['instrument']
    if not ctx['hourly_ok'].get(inst, False):
        return 'нет часовых данных по активному контракту — вход невозможен'
    if px is None:
        return 'нет последней цены'
    if a.get('side') not in ('long', 'short') or a.get('order') not in ('market', 'limit'):
        return 'нужны side и order'
    if a.get('setup') not in SETUPS:
        return 'нужен тип входа (setup)'
    if not a.get('invalidation'):
        return 'нужно invalidation — что сломает идею'
    h = a.get('horizon_days')
    if not isinstance(h, int) or not 1 <= h <= C.MAX_HORIZON_DAYS:
        return 'горизонт должен быть от 1 до %d дней' % C.MAX_HORIZON_DAYS
    ref = px
    if a['order'] == 'limit':
        lp = a.get('limit_px')
        if lp is None:
            return 'лимитка без limit_px'
        if abs(lp - px) / px > C.MAX_LIMIT_FRAC:
            return 'лимитка дальше %d%% от цены' % round(C.MAX_LIMIT_FRAC * 100)
        ref = lp
    why = _levels_ok(inst, a['side'], ref, a.get('stop_px'), a.get('target_px'))
    if why:
        return why
    existing = next((o for o in state['orders'] if o['instrument'] == inst), None)
    ok, why = book.can_open(state, inst, exclude_order=existing, halt_files=ctx.get('halt_files'))
    return None if ok else why


def _check_modify(a, state, px):
    inst = a['instrument']
    p = book.position(state, inst)
    if p is not None:
        if a.get('stop_px') is None and a.get('target_px') is None:
            return 'modify без новых уровней'
        sm = 1 if p['side'] == 'long' else -1
        st = a.get('stop_px')
        if st is not None:
            if sm * (st - p['stop']) < 0:
                return 'стоп отодвигать нельзя (сейчас %s)' % p['stop']
            if px is not None and sm * (px - st) <= 0:
                return 'новый стоп за текущей ценой — для выхода используйте close'
        tg = a.get('target_px')
        if tg is not None and px is not None and sm * (tg - px) <= 0:
            return 'цель не с той стороны от цены'
        return None
    o = next((o for o in state['orders'] if o['instrument'] == inst), None)
    if o is None:
        return 'нет ни позиции, ни заявки'
    lp = a.get('limit_px') if a.get('limit_px') is not None else o.get('limit_px')
    ref = lp if o['order'] == 'limit' else px
    if ref is None:
        return 'нет цены для проверки уровней'
    stop = a.get('stop_px') if a.get('stop_px') is not None else o['stop_px']
    target = a.get('target_px') if a.get('target_px') is not None else o['target_px']
    return _levels_ok(inst, o['side'], ref, stop, target)


def apply(state, actions, decided_at, decision_id, memory_version, point):
    """Применить уже проверенные действия к рукаву. -> события."""
    ev = []
    for a in actions:
        inst, act = a['instrument'], a['action']
        if act == 'enter':
            ev += book.place_order(state, {
                'instrument': inst, 'side': a['side'], 'order': a['order'],
                'limit_px': a.get('limit_px') if a['order'] == 'limit' else None,
                'stop_px': float(a['stop_px']), 'target_px': float(a['target_px']),
                'horizon_days': a['horizon_days'], 'setup': a['setup'], 'reason': a['reason'],
                'invalidation': a['invalidation'], 'decided_at': decided_at,
                'decision_id': decision_id, 'memory_version': memory_version, 'point': point})
        elif act == 'cancel':
            ev += book.cancel_order(state, inst, 'решение агента: ' + a['reason'])
        elif act == 'modify':
            if book.position(state, inst) is not None:
                ev += book.modify_position(state, inst, a.get('stop_px'), a.get('target_px'), decision_id,
                                           tag=a.get('tag'), at=decided_at)
            else:
                o = next(o for o in state['orders'] if o['instrument'] == inst)
                for f in ('limit_px', 'stop_px', 'target_px'):
                    if a.get(f) is not None and (f != 'limit_px' or o['order'] == 'limit'):
                        o[f] = float(a[f])
                ev.append({'kind': 'order_modified', 'instrument': inst, 'order_id': o['id']})
        elif act == 'close':
            ev += book.request_close(state, inst, a['close_kind'], a['reason'], decided_at, decision_id)
    return ev
