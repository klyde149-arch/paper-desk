"""Рыночные данные агента — только чтение файлов боевого контура.

Дневные бары: data/live_rf/series/<A>.json, [{t,o,h,l,c,v}], t = 00:00 торговой даты (MSK-as-UTC).
При ролле боевой движок пересчитывает ВСЮ историю ряда коэффициентом new/old (Invoke-SeriesRollRescale),
поэтому последний сегмент всегда в сырых ценах активного контракта, а старые бары меняются.

Часовые бары: data/live_rf/candles/<A>_1h.json, [[t,o,h,l,c,v]], скользящие 30 дней по ФРОНТАЛЬНОМУ
контракту (tools/bake_rf_candles.ps1). Вокруг ролла фронт и активный контракт расходятся — тогда
часовые бары к ряду не подходят (§15).

JSON от PowerShell 5.1 бывает с BOM — читаем utf-8-sig.
"""
import datetime as dt
import json
import os

from . import timeutil as T

HOUR = dt.timedelta(hours=1)


def read_json(path, default=None):
    try:
        with open(path, encoding='utf-8-sig') as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def _bar(t_ms, o, h, l, c, v):
    t = T.ms_to_msk(t_ms)
    return {'ts': int(t_ms), 't': t, 'day': t.strftime('%Y-%m-%d'),
            'o': float(o), 'h': float(h), 'l': float(l), 'c': float(c), 'v': float(v or 0)}


def load_daily(series_dir, asset):
    raw = read_json(os.path.join(series_dir, asset + '.json'), []) or []
    return [_bar(b['t'], b['o'], b['h'], b['l'], b['c'], b.get('v')) for b in raw if b]


def load_hourly(candles_dir, asset):
    """-> (бары, asof). asof — когда файл испечён: бар считается завершённым, только если
    он закончился не позже asof (последний бар в файле может быть ещё формирующимся)."""
    path = os.path.join(candles_dir, asset + '_1h.json')
    raw = read_json(path, []) or []
    bars = [_bar(*r[:6]) for r in raw if r and len(r) >= 5]
    try:
        asof = dt.datetime(1970, 1, 1) + dt.timedelta(seconds=os.path.getmtime(path),
                                                      hours=T.MSK_UTC_HOURS)
    except OSError:
        asof = None
    return bars, asof


def complete_hourly(bars, now, asof):
    limit = now if asof is None else min(now, asof)
    return [b for b in bars if b['t'] + HOUR <= limit]


def contracts(rf_portfolio_path):
    """{asset: {'active': secid, 'front': secid}} из data/live_rf/portfolio.json (только метаданные)."""
    pf = read_json(rf_portfolio_path, {}) or {}
    out = {}
    for a, v in (pf.get('active') or {}).items():
        out.setdefault(a, {})['active'] = v.get('secid') if isinstance(v, dict) else v
    for a, v in (pf.get('fronts') or {}).items():
        out.setdefault(a, {})['front'] = v.get('secid') if isinstance(v, dict) else v
    return out


def hourly_usable(contract):
    """Часовые свечи испечены по фронту; годятся, только если фронт = активный контракт ряда."""
    return bool(contract) and bool(contract.get('active')) and contract.get('active') == contract.get('front')


def atr14(bars, i):
    """Простая средняя TR за 14 баров, как Ser-ATR14 (tools/lib_rf_signals.ps1)."""
    if i < 14:
        return None
    s = 0.0
    for k in range(i - 13, i + 1):
        h, l, pc = bars[k]['h'], bars[k]['l'], bars[k - 1]['c']
        s += max(h - l, abs(h - pc), abs(l - pc))
    return s / 14.0


def er(bars, i, n=20):
    """Efficiency Ratio, как er() в strategy_lab/aug_sep_review_20260917/entry_audit.py."""
    if i < n:
        return None
    den = sum(abs(bars[k]['c'] - bars[k - 1]['c']) for k in range(i - n + 1, i + 1))
    return abs(bars[i]['c'] - bars[i - n]['c']) / den if den else 0.0


def index_of_day(bars, day):
    for i in range(len(bars) - 1, -1, -1):
        if bars[i]['day'] == day:
            return i
        if bars[i]['day'] < day:
            return -1
    return -1


def rescale_factor(ref, bars):
    """ref = [ts, close] последнего бара, виденного на прошлом тике. Если тот же бар теперь другой —
    ряд пересчитан при ролле, возвращаем коэффициент new/old. Иначе None."""
    if not ref:
        return None
    ts, c_old = int(ref[0]), float(ref[1])
    for b in reversed(bars):
        if b['ts'] == ts:
            if c_old and abs(b['c'] / c_old - 1.0) > 1e-7:
                return b['c'] / c_old
            return None
        if b['ts'] < ts:
            break
    return None


def series_ref(bars):
    return [bars[-1]['ts'], bars[-1]['c']] if bars else None
