"""Что было бы, если бы (миссия, правила v0.2): упущенное и подтяжки стопа перед событиями.

Считает код по дневным барам рядов, модель только читает итог в недельном разборе.

Упущенное — неисполненные заявки на вход и явные отказы (skips). Гипотетический вход по рынку:
решение главного разбора (ночью) — по open того же торгового дня; решение дневной проверки —
по close этого дня, ведение со следующего. Дальше стоп агента и его цель; в одном баре стоп и
цель — стоп (консервативно). У отказа нет уровней: стоп = 1 ATR(14) от входа, цели нет, окно
SKIP_WINDOW баров. Результат в R от расстояния до стопа, без комиссий. Повторы одной идеи
(тот же инструмент и сторона, пока окно прежней не закрылось) считаются один раз — иначе шесть
переставленных лимиток по золоту дали бы шесть «упущенных» трендов вместо одного.

Подтяжка перед событием (tag event_tighten) — после выхода позиция ведётся дальше со стопом,
который стоял до первой такой подтяжки, и прежней целью, до конца горизонта. Сравнение валовое
(без комиссий) с фактическим выходом в тех же единицах.

Ролл: ряды пересчитываются коэффициентом при смене контракта, а уровни в решениях остаются в старых
единицах. Решение хранит последний дневной бар ряда (closes); уровни умножаются на
k = close того же дня в текущем ряду / сохранённый close. У решений без отметки (до 2026-10-06)
пересчёта нет — строка помечается «≈». Подтяжки (tighten_review) считаются вскоре после выхода,
ролл между выходом и разбором их исказит — это редкость, не исправляется.
"""
from . import market
from . import timeutil as T

SKIP_WINDOW = 5
MAIN_HOUR_MAX = 6          # решение до 06:00 МСК — успевает к открытию торгового дня


def _sm(side):
    return 1.0 if side == 'long' else -1.0


def _start(bars, at):
    """-> (индекс первого бара ведения, цена входа) или None."""
    d = T.parse_msk(at)
    day = d.date().isoformat()
    if d.hour < MAIN_HOUR_MAX:
        i = next((k for k, b in enumerate(bars) if b['day'] >= day), None)
        return None if i is None else (i, bars[i]['o'])
    i = next((k for k, b in enumerate(bars) if b['day'] == day), None)
    if i is not None:
        return i + 1, bars[i]['c']
    i = next((k for k, b in enumerate(bars) if b['day'] > day), None)
    return None if i is None else (i, bars[i]['o'])


def simulate(bars, i0, side, ref, stop, target, window, unit=None):
    """Ведение гипотетической позиции с бара i0 не дольше window баров. unit — 1R в цене
    (по умолчанию расстояние от входа до стопа). -> {r, mfe, outcome: stop|target|horizon|open, bars}."""
    sm = _sm(side)
    unit = unit or sm * (ref - stop)
    if unit <= 0:
        return None
    mfe = 0.0
    last = None
    n = 0
    for b in bars[i0:i0 + window]:
        n += 1
        last = b
        adverse = b['l'] if sm > 0 else b['h']
        favor = b['h'] if sm > 0 else b['l']
        if sm * (adverse - stop) <= 0:
            return {'r': round(sm * (stop - ref) / unit, 2), 'mfe': round(mfe, 2), 'outcome': 'stop', 'bars': n}
        mfe = max(mfe, sm * (favor - ref) / unit)
        if target is not None and sm * (favor - target) >= 0:
            return {'r': round(sm * (target - ref) / unit, 2), 'mfe': round(mfe, 2), 'outcome': 'target', 'bars': n}
    if last is None:
        return {'r': 0.0, 'mfe': 0.0, 'outcome': 'open', 'bars': 0}
    return {'r': round(sm * (last['c'] - ref) / unit, 2), 'mfe': round(mfe, 2),
            'outcome': 'horizon' if n >= window else 'open', 'bars': n}


def _bars(series_dir, inst, cache):
    if inst not in cache:
        cache[inst] = market.load_daily(series_dir, inst, tail=market.DAILY_TAIL)
    return cache[inst]


def candidates(decisions, state, since):
    """Неисполненные входы и явные отказы с момента since. Заявка, по которой есть сделка или
    позиция с тем же решением, или которая ещё висит, — не упущена."""
    used = {(t.get('decision_id'), t['instrument']) for t in state['trades']}
    used |= {(p.get('decision_id'), p['instrument']) for p in state['positions']}
    used |= {(o.get('decision_id'), o['instrument']) for o in state['orders']}
    out = []
    for d in decisions:
        if d.get('at', '') < since:
            continue
        for a in d.get('accepted') or []:
            if a.get('action') != 'enter' or (d['id'], a['instrument']) in used:
                continue
            out.append({'kind': 'order', 'at': d['at'], 'instrument': a['instrument'], 'side': a['side'],
                        'close_ref': (d.get('closes') or {}).get(a['instrument']),
                        'stop': a.get('stop_px'), 'target': a.get('target_px'),
                        'window': int(a.get('horizon_days') or SKIP_WINDOW), 'setup': a.get('setup'),
                        'reason': a.get('reason')})
        for x in d.get('skips') or []:
            if x.get('side') in ('long', 'short'):
                out.append({'kind': 'skip', 'at': d['at'], 'instrument': x['instrument'], 'side': x['side'],
                            'close_ref': (d.get('closes') or {}).get(x['instrument']),
                            'stop': None, 'target': None, 'window': SKIP_WINDOW, 'setup': None,
                            'reason': x.get('reason')})
    out.sort(key=lambda c: c['at'])
    return out


def _roll_k(bars, close_ref):
    """-> (k, approx). k переводит уровни решения в единицы текущего ряда."""
    if not close_ref:
        return 1.0, True
    day, close = close_ref
    b = next((b for b in bars if b['day'] == day), None)
    if b is None or not close:
        return 1.0, True
    return b['c'] / float(close), False


def missed(decisions, state, series_dir, since):
    cache, rows, open_until = {}, [], {}
    for c in candidates(decisions, state, since):
        bars = _bars(series_dir, c['instrument'], cache)
        st = _start(bars, c['at']) if bars else None
        if st is None:
            continue
        i0, ref = st
        key = (c['instrument'], c['side'])
        if key in open_until and i0 <= open_until[key]:
            continue                        # та же идея ещё в окне прежней заявки
        k, approx = _roll_k(bars, c.get('close_ref'))
        if c['kind'] == 'order' and approx:
            c = dict(c, approx=True)
        stop = c['stop'] * k if c['stop'] is not None else None
        target = c['target'] * k if c['target'] is not None else None
        if stop is None:
            atr = market.atr14(bars, max(i0 - 1, 0))
            if not atr:
                continue
            stop = ref - _sm(c['side']) * atr
        res = simulate(bars, i0, c['side'], ref, stop, target, c['window'])
        if res is None:
            continue                        # цена уже за стопом заявки — входа по рынку не было бы
        open_until[key] = i0 + max(res['bars'], 1) - 1    # закрылась по стопу/цели — дальше новая идея
        rows.append(dict(c, ref=ref, stop=stop, target=target, **res))
    return rows


def tighten_review(trades, series_dir):
    """Сделки с подтяжкой перед событием: факт против старого стопа."""
    cache, rows = {}, []
    for t in trades:
        tz = t.get('tightens') or []
        if not tz:
            continue
        sm = _sm(t['side'])
        unit = sm * (t['entry'] - t['initial_stop'])
        if unit <= 0:
            continue
        actual = round(sm * (t['exit_px'] - t['entry']) / unit, 2)
        row = {'id': t['id'], 'instrument': t['instrument'], 'side': t['side'], 'exit_at': t['exit_at'],
               'exit_reason': t['exit_reason'], 'old_stop': tz[0]['from'], 'new_stop': tz[-1]['to'],
               'actual_r': actual, 'old_r': None, 'outcome': None}
        bars = _bars(series_dir, t['instrument'], cache)
        exit_day = t['exit_at'][:10]
        i0 = next((k for k, b in enumerate(bars) if b['day'] >= exit_day), None)
        if i0 is not None:
            left = max(1, int(t.get('horizon_days') or SKIP_WINDOW)
                       - sum(1 for b in bars if t['entry_day'] <= b['day'] < exit_day))
            res = simulate(bars, i0, t['side'], t['entry'], tz[0]['from'], t.get('target'), left, unit=unit)
            row['old_r'], row['outcome'] = res['r'], res['outcome']
        rows.append(row)
    return rows


OUTCOME_RU = {'stop': 'стоп', 'target': 'цель', 'horizon': 'конец горизонта', 'open': 'окно ещё открыто'}


def missed_md(rows):
    if not rows:
        return 'Неисполненных заявок и отказов с направлением нет.'
    out = ['| Когда | Что | Инструмент | Сторона | Итог, R | Лучшее, R | Чем кончилось |', '|---|---|---|---|---|---|---|']
    for r in rows:
        out.append('| %s | %s | %s | %s | %+.2f | %+.2f | %s |' % (
            r['at'], 'заявка' if r['kind'] == 'order' else 'отказ', r['instrument'] + (' ≈' if r.get('approx') else ''),
            'лонг' if r['side'] == 'long' else 'шорт', r['r'], r['mfe'], OUTCOME_RU.get(r['outcome'], r['outcome'])))
    out.append('')
    out.append('Сумма: %+.2fR по %d упущенным идеям (вход по рынку, стоп и цель агента; у отказа стоп 1 ATR).'
               % (sum(r['r'] for r in rows), len(rows)))
    if any(r.get('approx') for r in rows):
        out.append('≈ — уровни без отметки ряда: если был ролл контракта, строка неточна.')
    return '\n'.join(out)


def tighten_md(rows):
    if not rows:
        return 'Подтяжек перед событиями (event_tighten) в закрытых сделках нет.'
    out = []
    for r in rows:
        if r['old_r'] is None:
            out.append('- %s %s: факт %+.2fR, со старым стопом — нет баров для сравнения' % (r['id'], r['instrument'], r['actual_r']))
            continue
        d = r['actual_r'] - r['old_r']
        out.append('- %s %s: стоп %s → %s, факт %+.2fR, со старым стопом %+.2fR (%s) — подтяжка %s %.2fR'
                   % (r['id'], r['instrument'], r['old_stop'], r['new_stop'], r['actual_r'], r['old_r'],
                      OUTCOME_RU.get(r['outcome'], r['outcome']), 'принесла' if d >= 0 else 'стоила', abs(d)))
    s = [r for r in rows if r['old_r'] is not None]
    if s:
        out.append('Итого подтяжки: %+.2fR против старого стопа.' % sum(r['actual_r'] - r['old_r'] for r in s))
    return '\n'.join(out)
