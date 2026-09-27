"""Тексты для Telegram и журнала — их пишет код, не модель (дизайн §10).

В сообщения о сделках подставляется reason из ответа агента. Сравнение с двойником C3b — только
в недельном отчёте для владельца (weekly_compare), в память агента оно не попадает.
"""
from . import config as C
from .snapshot import SIDE_RU, px

REASON_RU = {'stop': 'стоп', 'trail': 'страховочный трейл', 'stop_moved': 'подтянутый стоп', 'target': 'цель',
             'close:idea_broken': 'идея сломана', 'close:pre_event': 'перед событием',
             'close:take_profit': 'фиксация прибыли'}


def event_line(e):
    k, a = e['kind'], e.get('instrument')
    if k == 'order':
        lvl = 'лимит %s' % px(a, e['limit_px']) if e['order'] == 'limit' else 'по рынку'
        return '📝 %s %s %s, стоп %s, цель %s (%s). %s' % (a, SIDE_RU[e['side']], lvl, px(a, e['stop_px']),
                                                         px(a, e['target_px']), e['setup'], e['reason'])
    if k == 'fill':
        p = e['position']
        return '✅ Вход %s %s по %s, стоп %s, цель %s (%s)' % (a, SIDE_RU[p['side']], px(a, p['entry']),
                                                          px(a, p['stop']), px(a, p['target']), p['setup'])
    if k == 'exit':
        t = e['trade']
        return '🏁 Выход %s %s по %s — %s, %+.2fR' % (a, SIDE_RU[t['side']], px(a, t['exit_px']),
                                                    REASON_RU.get(t['exit_reason'], t['exit_reason']), t['r'])
    if k == 'trail':
        return '↗ Трейл %s: стоп %s → %s' % (a, px(a, e['from']), px(a, e['to']))
    if k == 'stop_moved':
        return '↗ Стоп %s: %s → %s' % (a, px(a, e['from']), px(a, e['to']))
    if k == 'target_moved':
        return '🎯 Цель %s: %s → %s' % (a, px(a, e['from']), px(a, e['to']))
    if k == 'close_requested':
        return '✋ Закрываю %s (%s): %s' % (a, REASON_RU.get('close:' + e['close_kind'], e['close_kind']), e['reason'])
    if k in ('cancel', 'expire'):
        return '✖ Заявка %s %s%s' % (a, 'снята' if k == 'cancel' else 'истекла',
                                     (': ' + e['why']) if e.get('why') else '')
    if k == 'refused':
        return '⛔ %s: %s' % (a, e['why'])
    if k == 'roll':
        return '🔁 Ролл %s: уровни пересчитаны (x%.5f)' % (a, e['k'])
    if k == 'halt':
        return '🛑 СТОП-КРАН: %s. Новые входы остановлены до разбора с владельцем.' % e['reason']
    return None


def point_message(point_label, decision, events_list):
    lines = ['🤖 Агент — %s' % point_label]
    if decision.get('summary'):
        lines.append(decision['summary'])
    for e in events_list:
        s = event_line(e)
        if s:
            lines.append(s)
    for r in decision.get('rejected') or []:
        lines.append('⛔ Отклонено %s %s: %s' % (r.get('action'), r.get('instrument'), r['why']))
    if len(lines) == 2 and not decision.get('rejected'):
        lines.append('Без изменений.')
    if decision.get('cost_usd') is not None:
        lines.append('Стоимость вызова $%.3f' % decision['cost_usd'])
    return '\n'.join(lines)


def journal_entry(at, point_label, decision, events_list):
    out = ['## %s — %s' % (at, point_label), '',
           'Версия памяти `%s`. Режим: %s.' % (decision.get('memory_version'),
                                                ', '.join('%s %s' % (k, v) for k, v in (decision.get('regime') or {}).items()) or '—')]
    if decision.get('summary'):
        out.append('Картина: %s' % decision['summary'])
    for a in decision.get('accepted') or []:
        out.append('- **%s %s**%s: %s%s' % (a['action'], a['instrument'],
                                            ' (%s)' % a['setup'] if a.get('setup') else '', a.get('reason', ''),
                                            (' Сломается, если: %s' % a['invalidation']) if a.get('invalidation') else ''))
    for r in decision.get('rejected') or []:
        out.append('- отклонено %s %s — %s' % (r.get('action'), r.get('instrument'), r['why']))
    for e in events_list:
        s = event_line(e)
        if s:
            out.append('- ' + s)
    return '\n'.join(out)


def events_message(events_list):
    lines = [s for s in (event_line(e) for e in events_list) if s]
    return ('🤖 Агент\n' + '\n'.join(lines)) if lines else ''
