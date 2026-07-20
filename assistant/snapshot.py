"""Живой снапшот состояния — подмешивается в НАЧАЛО КАЖДОГО хода.

Не один раз за сессию: состояние протухает за минуты, а диалог может длиться час.
Стоит ~300 токенов и сам по себе отвечает на «всё живо?» без единого вызова
инструмента — это заметно снижает и латентность, и цену.
"""
import time

from . import tools_impl as T


def _fmt_num(v, suffix=''):
    if v is None:
        return '?'
    try:
        f = float(v)
        return ('%.2f' % f).rstrip('0').rstrip('.') + suffix
    except Exception:
        return str(v) + suffix


def _sign(v):
    if v is None:
        return '?'
    return ('+' if float(v) >= 0 else '') + _fmt_num(v) + '%'


_DAYS = ('понедельник', 'вторник', 'среда', 'четверг', 'пятница', 'суббота', 'воскресенье')


def market_context():
    """Время MSK, день недели и статус сессии МОЕХ — фактом, а не выводом модели.

    Без этой строки модель принимает нормальную тишину выходного дня за аварию
    и отправляет разбираться с логами. Данные всегда сильнее рассуждения.
    """
    msk = time.gmtime(time.time() + 3 * 3600)
    wd = (msk.tm_wday) % 7
    day = _DAYS[wd]
    if wd >= 5:
        session = ('МОЕХ ЗАКРЫТА (выходной). Отсутствие тиков, входов и движения '
                   'капитала в РФ-контуре сейчас — НОРМА, это не авария. '
                   'Крипта на Bybit при этом торгует круглосуточно.')
    elif msk.tm_hour < 6:
        session = ('МОЕХ ещё закрыта: ЕТС стартует в 06:00 MSK, вход бота с 06:01. '
                   'Тишина в РФ-контуре — норма.')
    elif msk.tm_hour >= 24:
        session = 'МОЕХ закрыта (вечер).'
    else:
        session = 'МОЕХ: идут торги, РФ-контур должен тикать.'
    return ('Сейчас %s MSK, %s. %s'
            % (time.strftime('%Y-%m-%d %H:%M', msk), day, session))


def build():
    """Компактный дайджест на ~1000 символов. Никогда не бросает исключение."""
    lines = ['СНАПШОТ СОСТОЯНИЯ на %s UTC (собран автоматически, доверяй ему):'
             % time.strftime('%Y-%m-%d %H:%M', time.gmtime()),
             market_context()]

    try:
        rf = T._rf_digest()
        if 'error' in rf:
            lines.append('RF (T-Invest): %s' % rf['error'])
        else:
            age = rf.get('возраст_снимка_эквити_мин')
            lines.append(
                'RF (T-Invest, %s): капитал %s ₽, день %s, от пика %s, позиций %s, '
                'ГО %s из %s, стоп входов: %s, дрифты D2/D4/D5/D6 = %s/%s/%s/%s, '
                'consec_fail %s, снимок эквити %s мин назад'
                % (rf.get('режим'), _fmt_num(rf.get('капитал_руб')),
                   _sign(rf.get('день_pct')), _sign(rf.get('просадка_от_пика_pct')),
                   rf.get('позиций_всего'),
                   _fmt_num((rf.get('ГО') or {}).get('used_rub')),
                   _fmt_num((rf.get('ГО') or {}).get('budget_rub')),
                   'ДА (%s)' % (rf.get('стоп_входов') or {}).get('reason')
                   if (rf.get('стоп_входов') or {}).get('active') else 'нет',
                   (rf.get('дрифты') or {}).get('D2'), (rf.get('дрифты') or {}).get('D4'),
                   (rf.get('дрифты') or {}).get('D5'), (rf.get('дрифты') or {}).get('D6'),
                   rf.get('consec_fail'), age if age is not None else '?'))
    except Exception as e:
        lines.append('RF: снапшот не собрался (%s)' % e)

    try:
        cr = T._crypto_digest()
        if 'error' in cr:
            lines.append('Крипта (Bybit): %s' % cr['error'])
        else:
            lines.append(
                'Крипта (Bybit): капитал %s $, день %s, от пика %s, позиций %s (%s), '
                'торговля остановлена: %s, последний тик %s мин назад'
                % (_fmt_num(cr.get('капитал_usd')), _sign(cr.get('день_pct')),
                   _sign(cr.get('просадка_от_пика_pct')), len(cr.get('позиции') or []),
                   ', '.join(p.get('символ') or '?' for p in (cr.get('позиции') or [])) or '—',
                   'ДА' if cr.get('торговля_остановлена') else 'нет',
                   cr.get('возраст_последнего_тика_мин') if
                   cr.get('возраст_последнего_тика_мин') is not None else '?'))
    except Exception as e:
        lines.append('Крипта: снапшот не собрался (%s)' % e)

    try:
        halts = T._halt_summary()
        active = [k for k in halts if k in T.HALT_FILES]
        lines.append('Kill-файлы: %s' % (', '.join(active) if active else 'ни одного (оба контура торгуют)'))
    except Exception:
        pass

    lines.append('Если чего-то не хватает — вызывай инструменты, не додумывай.')
    return '\n'.join(lines)
