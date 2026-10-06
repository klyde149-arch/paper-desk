"""Бумажный рукав агента: заявки, исполнения, стопы, цели, трейл, роллы, учёт в R.

Учёт повторяет бумажного двойника C3b (tools/rf_engine.ps1, Rf-CloseFill / Invoke-RfRoll): капитал —
реализованный (без переоценки открытых позиций), риск = капитал x 0,5% на момент входа,
количество дробное = риск / расстояние до стопа (номинал не выше 3 x капитал),
R = чистый результат с комиссиями / риск. Рублей нет — капитал это индекс, старт 100 (§15).

Исполнение без заглядывания в будущее: заявка работает только на барах, начавшихся не раньше
момента решения. Рынок — open бара ± проскальзывание. Лимитка — только при проходе уровня на
шаг цены, по min(open, L) для покупки. Стоп и цель в одном баре — стоп. Стоп на гэпе — по open.
На баре входа проверяется только стоп (консервативно), цель — со следующего бара.

Функции меняют state на месте и возвращают список событий для журнала и Telegram.
"""
import datetime as dt

from . import config as C
from . import timeutil as T

R6 = 6


def new_state():
    return {
        'version': 1,
        'equity': C.START_EQUITY,
        'next_id': 1,
        'orders': [],
        'positions': [],
        'trades': [],
        'halt': None,           # стоп-кран: {'reason', 'since'}
        'last_bar': {},         # asset -> ts (мс) последнего обработанного часового бара
        'series_ref': {},       # asset -> [ts, close] последнего дневного бара (детектор ролла)
        'fallback_day': {},     # asset -> последний день, обработанный по дневному бару
        'trail_day': {},        # asset -> день последнего пересчёта трейла
    }


def _sm(side):
    return 1.0 if side == 'long' else -1.0


def _id(state, prefix):
    n = state['next_id']
    state['next_id'] = n + 1
    return '%s%d' % (prefix, n)


def order_valid_until(decided_at):
    """Заявка «на день»: до ближайших 23:50 МСК, отстоящих от решения хотя бы на 4 часа
    (решение 00:20 -> этот же день, решение 23:35 -> следующий день)."""
    end = decided_at.replace(hour=23, minute=50, second=0, microsecond=0)
    if end - decided_at < dt.timedelta(hours=4):
        end += dt.timedelta(days=1)
    return end


# ---------------------------------------------------------------- лимиты

def exposure(state, exclude_order=None):
    """Позиции + висящие заявки на вход: всего и по группам."""
    insts = [p['instrument'] for p in state['positions']]
    insts += [o['instrument'] for o in state['orders'] if o is not exclude_order]
    by_group = {}
    for a in insts:
        g = C.GROUP[a]
        by_group[g] = by_group.get(g, 0) + 1
    return len(insts), by_group


def can_open(state, instrument, exclude_order=None, halt_files=None):
    """-> (True, '') | (False, причина). Риск-рамки §6 — модель их не обходит."""
    if state.get('halt'):
        return False, 'стоп-кран: %s' % state['halt']['reason']
    if halt_files:
        return False, halt_files
    if any(p['instrument'] == instrument for p in state['positions']):
        return False, 'по %s уже есть позиция' % instrument
    total, by_group = exposure(state, exclude_order)
    if total >= C.MAX_POSITIONS:
        return False, 'лимит %d позиций (с заявками на вход)' % C.MAX_POSITIONS
    g = C.GROUP[instrument]
    if by_group.get(g, 0) >= C.MAX_PER_GROUP:
        return False, 'лимит %d в группе «%s»' % (C.MAX_PER_GROUP, C.GROUP_RU[g])
    return True, ''


# ---------------------------------------------------------------- заявки и позиции

def place_order(state, order):
    """order: instrument, side, order(market|limit), limit_px, stop_px, target_px, horizon_days,
    setup, reason, invalidation, decided_at (datetime), decision_id, memory_version, point.
    Прежняя заявка по тому же инструменту заменяется. Лимиты проверяет вызывающий (decide)."""
    ev = []
    for o in [o for o in state['orders'] if o['instrument'] == order['instrument']]:
        state['orders'].remove(o)
        ev.append({'kind': 'replace', 'instrument': o['instrument'], 'order_id': o['id']})
    o = dict(order)
    o['id'] = _id(state, 'O')
    o['decided_at'] = T.fmt(order['decided_at'])
    o['valid_until'] = T.fmt(order_valid_until(order['decided_at']))
    state['orders'].append(o)
    ev.append({'kind': 'order', 'instrument': o['instrument'], 'order_id': o['id'], 'side': o['side'],
               'order': o['order'], 'limit_px': o.get('limit_px'), 'stop_px': o['stop_px'],
               'target_px': o['target_px'], 'setup': o['setup'], 'reason': o['reason']})
    return ev


def cancel_order(state, instrument, why):
    ev = []
    for o in [o for o in state['orders'] if o['instrument'] == instrument]:
        state['orders'].remove(o)
        ev.append({'kind': 'cancel', 'instrument': instrument, 'order_id': o['id'], 'why': why})
    return ev


def position(state, instrument):
    for p in state['positions']:
        if p['instrument'] == instrument:
            return p
    return None


def modify_position(state, instrument, stop_px=None, target_px=None, decision_id=None, tag=None, at=None):
    """Стоп только подтягивается (дальше от цены не отодвигается — молча не принимается).
    tag='event_tighten' — подтяжка перед событием: прежний стоп запоминается, чтобы после выхода
    сравнить результат с тем, что дал бы старый стоп (report.tighten_review)."""
    p = position(state, instrument)
    ev = []
    if p is None:
        return ev
    sm = _sm(p['side'])
    if stop_px is not None:
        stop_px = round(float(stop_px), R6)
        if sm * (stop_px - p['stop']) > 0:
            ev.append({'kind': 'stop_moved', 'instrument': instrument, 'from': p['stop'], 'to': stop_px, 'tag': tag})
            if tag == 'event_tighten':
                p.setdefault('tightens', []).append({'at': T.fmt(at) if at else None, 'from': p['stop'], 'to': stop_px,
                                                     'decision_id': decision_id})
            p['stop'] = stop_px
            p['stop_src'] = 'agent'
        elif stop_px != p['stop']:
            ev.append({'kind': 'refused', 'instrument': instrument,
                       'why': 'стоп %s дальше текущего %s — отодвигать нельзя' % (stop_px, p['stop'])})
    if target_px is not None and float(target_px) != p.get('target'):
        ev.append({'kind': 'target_moved', 'instrument': instrument, 'from': p.get('target'), 'to': float(target_px)})
        p['target'] = round(float(target_px), R6)
    return ev


def request_close(state, instrument, close_kind, reason, decided_at, decision_id=None):
    p = position(state, instrument)
    if p is None:
        return []
    p['pending_close'] = {'close_kind': close_kind, 'reason': reason, 'decided_at': T.fmt(decided_at),
                          'decision_id': decision_id}
    return [{'kind': 'close_requested', 'instrument': instrument, 'close_kind': close_kind, 'reason': reason}]


# ---------------------------------------------------------------- исполнение

def _open(state, o, fill, at):
    eq = state['equity']
    sm = _sm(o['side'])
    dist = sm * (fill - o['stop_px'])
    if dist <= 0:
        return None
    risk = eq * C.RISK_PCT
    qty = risk / dist
    if qty * fill > C.MAX_LEV * eq:
        qty = C.MAX_LEV * eq / fill
    fee = qty * fill * C.FEE
    state['equity'] = eq - fee
    p = {
        'id': _id(state, 'A'), 'instrument': o['instrument'], 'side': o['side'], 'setup': o['setup'],
        'entry': round(fill, R6), 'entry_at': T.fmt(at), 'entry_day': at.strftime('%Y-%m-%d'),
        'qty': round(qty, 9), 'qty_initial': round(qty, 9),
        'stop': round(o['stop_px'], R6), 'initial_stop': round(o['stop_px'], R6), 'stop_src': 'initial',
        'target': round(o['target_px'], R6), 'best': round(fill, R6),
        'risk_amt': round(risk, 9), 'entry_fee': fee, 'fees': 0.0, 'realized': 0.0, 'rolls': 0,
        'horizon_days': o.get('horizon_days'), 'reason': o.get('reason'), 'invalidation': o.get('invalidation'),
        'order': o['order'], 'decision_id': o.get('decision_id'), 'memory_version': o.get('memory_version'),
        'pending_close': None,
    }
    state['positions'].append(p)
    return p


def close_position(state, p, px, at, reason):
    sm = _sm(p['side'])
    gross = sm * p['qty'] * (px - p['entry'])
    fee = p['qty'] * px * C.FEE
    state['equity'] += gross - fee
    p['realized'] += gross - fee
    p['fees'] += fee
    net = p['realized'] - p['entry_fee']
    r = net / p['risk_amt'] if p['risk_amt'] > 0 else 0.0
    entry_day = dt.date.fromisoformat(p['entry_day'])
    tr = {
        'id': p['id'], 'instrument': p['instrument'], 'side': p['side'], 'setup': p['setup'],
        'entry_at': p['entry_at'], 'entry_day': p['entry_day'], 'entry': p['entry'],
        'initial_stop': p['initial_stop'], 'exit_at': T.fmt(at), 'exit_px': round(px, R6),
        'exit_reason': reason, 'r': round(r, 3), 'net': net, 'risk_amt': p['risk_amt'],   # net без округления: на нём сходится учёт
        'fees': round(p['fees'] + p['entry_fee'], 6), 'rolls': p['rolls'],
        'days_held': (at.date() - entry_day).days, 'horizon_days': p.get('horizon_days'),
        'reason': p.get('reason'), 'invalidation': p.get('invalidation'),
        'decision_id': p.get('decision_id'), 'memory_version': p.get('memory_version'),
        'close_reason': (p.get('pending_close') or {}).get('reason'),
        'target': p.get('target'), 'tightens': p.get('tightens') or [],
    }
    state['positions'].remove(p)
    state['trades'].append(tr)
    ev = [{'kind': 'exit', 'instrument': p['instrument'], 'trade': tr}]
    ev += check_halt(state, at)
    return ev


def check_halt(state, at):
    if state.get('halt'):
        return []
    # после снятия стоп-крана владельцем (reset-halt) считаются только сделки после сброса
    total = sum(t['r'] for t in state['trades'][state.get('halt_reset_trades', 0):])
    if total < C.HALT_SUM_R:
        state['halt'] = {'reason': 'сумма сделок %.2fR ниже %.0fR' % (total, C.HALT_SUM_R), 'since': T.fmt(at)}
        ev = [{'kind': 'halt', 'reason': state['halt']['reason']}]
        for o in list(state['orders']):
            ev += cancel_order(state, o['instrument'], 'стоп-кран')
        return ev
    return []


def _stop_fill(p, bar):
    """-> цена исполнения стопа на баре или None. Гэп за стоп — по open."""
    if p['side'] == 'long':
        if bar['l'] > p['stop']:
            return None
        base = min(bar['o'], p['stop'])
    else:
        if bar['h'] < p['stop']:
            return None
        base = max(bar['o'], p['stop'])
    return base * (1 - _sm(p['side']) * C.STOP_SLIP)


def _target_fill(p, bar, tick):
    t = p.get('target')
    if not t:
        return None
    if p['side'] == 'long':
        return max(bar['o'], t) if bar['h'] >= t + tick else None
    return min(bar['o'], t) if bar['l'] <= t - tick else None


def _limit_fill(o, bar, tick):
    L = o['limit_px']
    if o['side'] == 'long':
        return min(bar['o'], L) if bar['l'] <= L - tick else None
    return max(bar['o'], L) if bar['h'] >= L + tick else None


def _stop_reason(p):
    return {'trail': 'trail', 'agent': 'stop_moved'}.get(p.get('stop_src'), 'stop')


def process_bar(state, asset, bar, halt_files=None):
    """Один завершённый часовой бар инструмента. bar: {'t': datetime начала, o, h, l, c}."""
    ev = []
    t = bar['t']
    tick = C.TICK[asset]
    # 1. заявки на вход
    for o in [o for o in state['orders'] if o['instrument'] == asset]:
        if t < T.parse_msk(o['decided_at']):
            continue                                  # бар начался до решения — не заглядываем
        if t >= T.parse_msk(o['valid_until']):
            state['orders'].remove(o)
            ev.append({'kind': 'expire', 'instrument': asset, 'order_id': o['id']})
            continue
        fill = bar['o'] * (1 + _sm(o['side']) * C.SLIP) if o['order'] == 'market' else _limit_fill(o, bar, tick)
        if fill is None:
            continue
        ok, why = can_open(state, asset, exclude_order=o, halt_files=halt_files)
        state['orders'].remove(o)
        if not ok:
            ev.append({'kind': 'cancel', 'instrument': asset, 'order_id': o['id'], 'why': why})
            continue
        p = _open(state, o, fill, t)
        if p is None:
            ev.append({'kind': 'cancel', 'instrument': asset, 'order_id': o['id'],
                       'why': 'цена исполнения %s уже за стопом %s' % (round(fill, R6), o['stop_px'])})
            continue
        ev.append({'kind': 'fill', 'instrument': asset, 'position': dict(p)})
        sf = _stop_fill(p, bar)                       # на баре входа — только стоп
        if sf is not None:
            ev += close_position(state, p, sf, t, 'stop')
        else:
            p['best'] = round(max(p['best'], bar['h']) if p['side'] == 'long' else min(p['best'], bar['l']), R6)
    # 2. открытые позиции (вошедшие раньше этого бара)
    for p in [p for p in state['positions'] if p['instrument'] == asset]:
        if T.parse_msk(p['entry_at']) >= t:
            continue
        pc = p.get('pending_close')
        if pc and t >= T.parse_msk(pc['decided_at']):
            ev += close_position(state, p, bar['o'] * (1 - _sm(p['side']) * C.SLIP), t, 'close:' + pc['close_kind'])
            continue
        sf = _stop_fill(p, bar)
        if sf is not None:
            ev += close_position(state, p, sf, t, _stop_reason(p))
            continue
        tf = _target_fill(p, bar, tick)
        if tf is not None:
            ev += close_position(state, p, tf, t, 'target')
            continue
        p['best'] = round(max(p['best'], bar['h']) if p['side'] == 'long' else min(p['best'], bar['l']), R6)
    state['last_bar'][asset] = T.msk_to_ms(t)
    return ev


def process_daily_fallback(state, asset, bar):
    """Нет годных часовых свечей (фронт != активный контракт): позиции ведутся по дневному бару,
    консервативно (стоп раньше цели), новых входов по инструменту нет — заявки снимаются."""
    ev = cancel_order(state, asset, 'нет часовых данных по активному контракту')
    day = bar['day']
    for p in [p for p in state['positions'] if p['instrument'] == asset]:
        if day <= p['entry_day']:
            continue                                  # дневной бар дня входа содержит цены до входа
        at = bar['t'] + dt.timedelta(hours=23, minutes=50)
        pc = p.get('pending_close')
        if pc and T.parse_msk(pc['decided_at']).date() < bar['t'].date():
            ev += close_position(state, p, bar['o'] * (1 - _sm(p['side']) * C.SLIP), bar['t'], 'close:' + pc['close_kind'])
            continue
        sf = _stop_fill(p, bar)
        if sf is not None:
            ev += close_position(state, p, sf, at, _stop_reason(p))
            continue
        tf = _target_fill(p, bar, C.TICK[asset])
        if tf is not None:
            ev += close_position(state, p, tf, at, 'target')
            continue
        p['best'] = round(max(p['best'], bar['h']) if p['side'] == 'long' else min(p['best'], bar['l']), R6)
    state['fallback_day'][asset] = day
    # часовые бары этого дня уже учтены дневным — не обрабатывать их повторно
    end_ms = T.msk_to_ms(bar['t'] + dt.timedelta(hours=23))
    state['last_bar'][asset] = max(state['last_bar'].get(asset, 0), end_ms)
    return ev


def expire_orders(state, now):
    ev = []
    for o in list(state['orders']):
        if now >= T.parse_msk(o['valid_until']):
            state['orders'].remove(o)
            ev.append({'kind': 'expire', 'instrument': o['instrument'], 'order_id': o['id']})
    return ev


def apply_trail(state, asset, atr, day):
    """Страховочный трейл 3 x ATR(14) от лучшей цены; только подтягивает; не в день входа."""
    ev = []
    if atr is None:
        return ev
    for p in [p for p in state['positions'] if p['instrument'] == asset]:
        if p['entry_day'] >= day:
            continue
        sm = _sm(p['side'])
        ns = round(p['best'] - sm * C.ATR_TRAIL * atr, R6)
        if sm * (ns - p['stop']) > 0:
            ev.append({'kind': 'trail', 'instrument': asset, 'from': p['stop'], 'to': ns})
            p['stop'] = ns
            p['stop_src'] = 'trail'
    state['trail_day'][asset] = day
    return ev


def apply_roll(state, asset, k, px_old, at):
    """Ролл: ряд пересчитан коэффициентом k = new/old. Старая нога закрывается по px_old,
    новая открывается по px_old x k — обе с проскальзыванием и комиссией, как Invoke-RfRoll."""
    ev = []
    for p in [p for p in state['positions'] if p['instrument'] == asset]:
        sm = _sm(p['side'])
        fill_old = px_old * (1 - sm * C.SLIP)
        gross = sm * p['qty'] * (fill_old - p['entry'])
        fee_c = p['qty'] * fill_old * C.FEE
        qty_new = p['qty'] / k
        fill_new = px_old * k * (1 + sm * C.SLIP)
        fee_o = qty_new * fill_new * C.FEE
        state['equity'] += gross - fee_c - fee_o
        p['realized'] += gross - fee_c - fee_o
        p['fees'] += fee_c + fee_o
        p['entry'] = round(fill_new, R6)
        p['qty'] = round(qty_new, 9)
        for f in ('stop', 'initial_stop', 'target', 'best'):
            if p.get(f):
                p[f] = round(p[f] * k, R6)
        p['rolls'] += 1
        ev.append({'kind': 'roll', 'instrument': asset, 'k': k})
    for o in [o for o in state['orders'] if o['instrument'] == asset]:
        for f in ('limit_px', 'stop_px', 'target_px'):
            if o.get(f):
                o[f] = round(o[f] * k, R6)
        ev.append({'kind': 'roll_order', 'instrument': asset, 'k': k})
    return ev


def open_r(p, px):
    """Текущий результат открытой позиции в R (с уже уплаченными и будущей комиссией)."""
    sm = _sm(p['side'])
    net = p['realized'] + sm * p['qty'] * (px - p['entry']) - p['entry_fee'] - p['qty'] * px * C.FEE
    return net / p['risk_amt'] if p['risk_amt'] > 0 else 0.0


def closed_sum_r(state):
    return sum(t['r'] for t in state['trades'])
