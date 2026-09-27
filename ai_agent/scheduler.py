"""Какие точки решений наступили (дизайн §5, §15). Диспетчер вызывается раз в 5 минут.

Главный разбор — по появлению нового дневного бара в рядах, а не по часам: боевой движок
в выходные ряды не докатывает, бар пятницы появляется в понедельник после 00:20.
Сессионные точки — по времени бирж (Лондон 08:05, Нью-Йорк 09:35), только по будням. Точка
считается выполненной по ключу в state['done']; окно запуска ограничено, чтобы после простоя
не догонять устаревшие проверки.
"""
import datetime as dt

from . import events
from . import timeutil as T

WINDOW = dt.timedelta(minutes=55)
MAIN_ALERT_AT = dt.time(2, 0)


def latest_daily_day(daily_by_asset):
    days = [b[-1]['day'] for b in daily_by_asset.values() if b]
    return max(days) if days else None


def due(state, now, daily_by_asset, cal):
    """-> список {'point', 'key', 'event'?, 'bar_day'?} по порядку выполнения."""
    done = state.setdefault('done', {})
    out = []
    day = latest_daily_day(daily_by_asset)
    if day and day > (state.get('last_main_day') or '') and now.time() >= dt.time(0, 20):
        out.append({'point': 'main', 'key': 'main:%s' % day, 'bar_day': day})
    wd = now.weekday() < 5
    d = now.date()
    fixed = []
    if wd:
        fixed.append(('asia', dt.datetime.combine(d, dt.time(6, 1))))
        fixed.append(('eu_open', T.to_msk(d, '08:05', 'LON')))
        fixed.append(('us_open', T.to_msk(d, '09:35', 'NY')))
        fixed.append(('evening', dt.datetime.combine(d, dt.time(23, 35))))
    for name, at in fixed:
        key = '%s:%s' % (name, d.isoformat())
        if at <= now < at + WINDOW and key not in done:
            out.append({'point': name, 'key': key})
    for e in events.due_checks(cal, now, {k.split('event:', 1)[1] for k in done if k.startswith('event:')}):
        out.append({'point': 'event', 'key': 'event:' + e['key'], 'event': e})
    if now.weekday() == 5 and now.time() >= dt.time(12, 0):
        y, w, _ = d.isocalendar()
        key = 'weekly:%d-W%02d' % (y, w)
        if key not in done:
            out.append({'point': 'weekly', 'key': key})
    return out


def missing_bar_alert(state, now, daily_by_asset, cal):
    """В будний день к 02:00 должен быть бар прошлого торгового дня. -> текст алерта или None."""
    if now.time() < MAIN_ALERT_AT or now.weekday() >= 5:
        return None
    key = 'bar_alert:%s' % now.date().isoformat()
    if key in state.setdefault('done', {}):
        return None
    exp = T.prev_weekday(now.date())
    while not events.is_trading_weekday(cal, exp):
        exp = T.prev_weekday(exp)
    day = latest_daily_day(daily_by_asset)
    if day and day >= exp.isoformat():
        return None
    state['done'][key] = T.fmt(now)
    return ('дневной бар за %s не появился в рядах к 02:00 (последний %s) — главный разбор ждёт; '
            'проверить боевой движок (Invoke-LiveDaily)' % (exp.isoformat(), day))
