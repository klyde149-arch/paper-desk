"""Календарь событий агента: data/events/agent_calendar_2026_27.json.

Время события хранится по поясу источника (MSK | NY | LON), в московское переводится здесь —
поэтому переходы на зимнее время 25.10 и 01.11 не требуют правки файла.
"""
import datetime as dt

from . import market
from . import timeutil as T

CHECK_DELAY = dt.timedelta(minutes=5)     # проверка через 5 минут после события (§5)
CHECK_WINDOW = dt.timedelta(minutes=60)   # опоздали больше чем на час — проверка уже не нужна
COVERAGE_WARN_DAYS = 14


def load(path):
    raw = market.read_json(path, {}) or {}
    evs = []
    for e in raw.get('events') or []:
        day = dt.date.fromisoformat(e['date'])
        x = dict(e)
        x['msk'] = T.to_msk(day, e['time'], e.get('tz', 'MSK'))
        x['key'] = '%s:%s' % (e['kind'], e['date'])
        evs.append(x)
    evs.sort(key=lambda x: x['msk'])
    return {
        'events': evs,
        'covered_through': raw.get('covered_through'),
        'closed': set(raw.get('moex_closed') or []),
        'short': set(raw.get('moex_short') or []),
    }


def window(cal, now, days=7, back_hours=24):
    """События за последние back_hours и на days вперёд — для снимка агента."""
    lo, hi = now - dt.timedelta(hours=back_hours), now + dt.timedelta(days=days)
    return [e for e in cal['events'] if lo <= e['msk'] <= hi]


def due_checks(cal, now, done_keys):
    return [e for e in cal['events']
            if e['msk'] + CHECK_DELAY <= now < e['msk'] + CHECK_WINDOW and e['key'] not in done_keys]


def coverage_warning(cal, now):
    ct = cal.get('covered_through')
    if not ct:
        return 'в календаре нет covered_through'
    left = (dt.date.fromisoformat(ct) - now.date()).days
    if left < COVERAGE_WARN_DAYS:
        return 'календарь событий покрыт только до %s (осталось %d дн.) — дополнить' % (ct, left)
    return None


def is_trading_weekday(cal, day):
    """Будний день с обычным дневным баром в ряду."""
    s = day.isoformat()
    return day.weekday() < 5 and s not in cal['closed'] and s not in cal['short']
