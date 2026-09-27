"""Время агента.

Внутри всё — наивное datetime в московском времени. Так же устроены ряды боевого контура: поле t
(мс) при чтении как UTC даёт московские часы («MSK-as-UTC»), см. tools/lib_tinvest.ps1.

Переходы на зимнее время считаются своими правилами, без zoneinfo: на Windows база часовых
поясов есть не везде, а правила ЕС и США стабильны. Перевод происходит ночью, поэтому для
событий и открытий бирж (днём по местному времени) достаточно точности до даты.
"""
import datetime as dt

EPOCH = dt.datetime(1970, 1, 1)
MSK_UTC_HOURS = 3


def ms_to_msk(ms):
    return EPOCH + dt.timedelta(milliseconds=int(ms))


def msk_to_ms(d):
    return int((d - EPOCH).total_seconds() * 1000)


def msk_now():
    return dt.datetime.now(dt.timezone.utc).replace(tzinfo=None) + dt.timedelta(hours=MSK_UTC_HOURS)


def parse_msk(s):
    """'2026-09-28 10:05' | '2026-09-28T10:05:00' -> datetime."""
    return dt.datetime.fromisoformat(s.replace(' ', 'T'))


def fmt(d):
    return d.strftime('%Y-%m-%d %H:%M')


def _sundays(y, m):
    d = dt.date(y, m, 1)
    d += dt.timedelta(days=(6 - d.weekday()) % 7)
    out = []
    while d.month == m:
        out.append(d)
        d += dt.timedelta(days=7)
    return out


def uk_summer(day):
    """Лондон на летнем времени: с последнего воскресенья марта до последнего воскресенья октября."""
    return _sundays(day.year, 3)[-1] <= day < _sundays(day.year, 10)[-1]


def us_summer(day):
    """Нью-Йорк на летнем времени: со второго воскресенья марта до первого воскресенья ноября."""
    return _sundays(day.year, 3)[1] <= day < _sundays(day.year, 11)[0]


def to_msk(day, hhmm, tz):
    """Местное время биржи/ведомства -> московское. tz: MSK | LON | NY."""
    h, m = (int(x) for x in hhmm.split(':'))
    local = dt.datetime(day.year, day.month, day.day, h, m)
    if tz == 'MSK':
        return local
    if tz == 'LON':
        utc = local - dt.timedelta(hours=1 if uk_summer(day) else 0)
    elif tz == 'NY':
        utc = local + dt.timedelta(hours=4 if us_summer(day) else 5)
    else:
        raise ValueError('неизвестный пояс %r' % tz)
    return utc + dt.timedelta(hours=MSK_UTC_HOURS)


def prev_weekday(day):
    d = day - dt.timedelta(days=1)
    while d.weekday() >= 5:
        d -= dt.timedelta(days=1)
    return d
