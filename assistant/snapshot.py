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
    return (('+' if float(v) >= 0 else '') + _fmt_num(v) + '%').replace('.', ',')


def _money(v, dec=0):
    """Деньги с разрядкой пробелами и запятой-десятичной: 734429 -> '734 429', 1250.4 -> '1 250,40'."""
    if v is None:
        return '?'
    try:
        f = float(v)
    except Exception:
        return str(v)
    neg = f < 0
    s = ('%0.*f' % (dec, abs(f)))
    parts = s.split('.')
    grouped = ''
    for i, ch in enumerate(reversed(parts[0])):
        if i and i % 3 == 0:
            grouped = ' ' + grouped
        grouped = ch + grouped
    body = grouped + (',' + parts[1] if dec > 0 else '')
    return ('-' if neg else '') + body


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
            halt = (rf.get('стоп_входов') or {})
            drift = (rf.get('дрифты') or {})
            halt_txt = ('новые входы остановлены (%s)' % halt.get('reason')) if halt.get('active') else 'входы разрешены'
            d2, d4, d5, d6 = drift.get('D2'), drift.get('D4'), drift.get('D5'), drift.get('D6')
            # D2/D4/D5 — реальные расхождения (требуют внимания); D6 — перевзвод стопа (самовосстановление)
            drift_txt = ('расхождений с брокером нет' if not any((d2, d4, d5))
                         else 'внимание, расхождения с брокером') + (' (D2/D4/D5/D6 = %s/%s/%s/%s)' % (d2, d4, d5, d6))
            lines.append(
                'Фьючерсы (Т-Инвест, режим %s): капитал бота %s ₽, за день %s, от максимума %s, '
                'открыто позиций %s, гарантийное обеспечение (ГО) занято %s из %s ₽, %s, %s, '
                'сбоев связи подряд %s, данные обновлены %s мин назад'
                % (rf.get('режим'), _money(rf.get('капитал_руб')),
                   _sign(rf.get('день_pct')), _sign(rf.get('просадка_от_пика_pct')),
                   rf.get('позиций_всего'),
                   _money((rf.get('ГО') or {}).get('used_rub')),
                   _money((rf.get('ГО') or {}).get('budget_rub')),
                   halt_txt, drift_txt,
                   rf.get('consec_fail'), age if age is not None else '?'))
    except Exception as e:
        lines.append('RF: снапшот не собрался (%s)' % e)

    try:
        cr = T._crypto_digest()
        if 'error' in cr:
            lines.append('Крипта (Bybit): %s' % cr['error'])
        else:
            halted = cr.get('торговля_остановлена')
            trade_txt = ('торговля остановлена (%s)' % (cr.get('причина_стопа_входов') or 'см. kill-файлы')) if halted else 'торговля идёт'
            lines.append(
                'Крипта (Bybit): капитал %s $, за день %s, от максимума %s, '
                'открыто позиций %s (%s), %s, последний тик %s мин назад'
                % (_money(cr.get('капитал_usd'), 2), _sign(cr.get('день_pct')),
                   _sign(cr.get('просадка_от_пика_pct')), len(cr.get('позиции') or []),
                   ', '.join(p.get('символ') or '?' for p in (cr.get('позиции') or [])) or '—',
                   trade_txt,
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
