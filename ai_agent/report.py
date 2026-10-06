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
        return '↗ Стоп %s: %s → %s%s' % (a, px(a, e['from']), px(a, e['to']),
                                         ' (перед событием)' if e.get('tag') == 'event_tighten' else '')
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
    for x in decision.get('skips') or []:
        lines.append('⏭ Пропуск %s%s: %s' % (x['instrument'], ' ' + SIDE_RU[x['side']] if x.get('side') else '', x['reason']))
    if decision.get('silent_skips'):
        lines.append('⚠️ Тренд без входа и без причины: %s' % ', '.join(C.GROUP_RU[g] for g in decision['silent_skips']))
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
    for x in decision.get('skips') or []:
        out.append('- пропуск %s%s — %s' % (x['instrument'], ' ' + SIDE_RU[x['side']] if x.get('side') else '', x['reason']))
    if decision.get('silent_skips'):
        out.append('- **тренд пропущен молча**: %s' % ', '.join(C.GROUP_RU[g] for g in decision['silent_skips']))
    for e in events_list:
        s = event_line(e)
        if s:
            out.append('- ' + s)
    return '\n'.join(out)


def events_message(events_list):
    lines = [s for s in (event_line(e) for e in events_list) if s]
    return ('🤖 Агент\n' + '\n'.join(lines)) if lines else ''


# ---------------------------------------------------------------- сравнение с двойником C3b (§9)
# Только для владельца: файл в data/ai_agent/reports/, в agent_memory/ и в промпт не попадает.

ER_LATE = 0.5          # «вход после прямолинейного движения» — ER20 >= 0,5 на день перед входом
ER_LATE_MAX = 0.20     # порог: таких входов не больше 20%
AVG_WIN_MIN = 1.5      # средняя прибыльная не меньше +1,5R


def entry_er(series_dir, inst, entry_day, cache):
    from . import market
    if inst not in cache:
        cache[inst] = market.load_daily(series_dir, inst)
    bars = cache[inst]
    i = next((k for k in range(len(bars) - 1, -1, -1) if bars[k]['day'] < entry_day), -1)
    return market.er(bars, i) if i >= 0 else None


def _stats(rows, r_key, inst_key, day_key, series_dir, cache):
    rs = [x[r_key] for x in rows if isinstance(x.get(r_key), (int, float))]
    wins = [r for r in rs if r > 0]
    ers = [entry_er(series_dir, x[inst_key], x[day_key], cache) for x in rows]
    ers = [e for e in ers if e is not None]
    return {'n': len(rs), 'sum_r': sum(rs), 'win_rate': len(wins) / len(rs) if rs else None,
            'avg_win': sum(wins) / len(wins) if wins else None,
            'late_share': sum(1 for e in ers if e >= ER_LATE) / len(ers) if ers else None}


def compare(agent_trades, twin_rows, series_dir, since):
    cache = {}
    twin = [t for t in twin_rows if t.get('profile') == 'C3b' and t.get('sym') in C.UNIVERSE
            and str(t.get('entryDay', '')) >= since]
    out = {'since': since,
           'agent': _stats(agent_trades, 'r', 'instrument', 'entry_day', series_dir, cache),
           'twin_all': _stats(twin, 'rMultiple', 'sym', 'entryDay', series_dir, cache),
           'twin_core': _stats([t for t in twin if t.get('sleeve') == 'core'], 'rMultiple', 'sym', 'entryDay',
                               series_dir, cache),
           'by_setup': {}}
    for s in ('pullback', 'early_breakout', 'catalyst'):
        ts = [t for t in agent_trades if t['setup'] == s]
        out['by_setup'][s] = {'n': len(ts), 'sum_r': sum(t['r'] for t in ts)}
    return out


def _f(x, fmt):
    return '—' if x is None else fmt % x


def _pct(x):
    return '—' if x is None else '%d%%' % round(x * 100)


def compare_md(c, week, costs):
    a, ta, tc = c['agent'], c['twin_all'], c['twin_core']
    rows = [('Закрытых сделок', '%d' % a['n'], '%d' % ta['n'], '%d' % tc['n'], ''),
            ('Сумма R', '%+.2f' % a['sum_r'], '%+.2f' % ta['sum_r'], '%+.2f' % tc['sum_r'], 'агент выше двойника'),
            ('Доля прибыльных', _pct(a['win_rate']), _pct(ta['win_rate']), _pct(tc['win_rate']), ''),
            ('Средняя прибыльная, R', _f(a['avg_win'], '%+.2f'), _f(ta['avg_win'], '%+.2f'), _f(tc['avg_win'], '%+.2f'),
             'не меньше +%.1f' % AVG_WIN_MIN),
            ('Входы после прямого движения (ER20 ≥ 0,5)', _pct(a['late_share']),
             _pct(ta['late_share']), _pct(tc['late_share']), 'не больше %d%%' % round(ER_LATE_MAX * 100))]
    lines = ['# Агент против двойника C3b — неделя %s' % week, '',
             'С %s, 8 инструментов агента. Двойник — бумажный C3b (data/rf/rf_trades.json): «всё» — ядро и '
             'сетап A, «ядро» — только ядро. Агент эти цифры не видит.' % c['since'], '',
             '| Показатель | Агент | Двойник, всё | Двойник, ядро | Порог |', '|---|---|---|---|---|']
    lines += ['| %s | %s | %s | %s | %s |' % r for r in rows]
    lines += ['', '## Агент по типам входа', '', '| Тип | Сделок | Сумма R |', '|---|---|---|']
    lines += ['| %s | %d | %+.2f |' % (s, v['n'], v['sum_r']) for s, v in c['by_setup'].items()]
    lines += ['', 'Расход на модели: всего $%.2f из $%.2f.' % costs, '',
              'Для вывода нужно около 30 закрытых сделок (протокол rf_research_protocol_2026-09-21.md); до '
              'этого цифры — проверка адекватности, не вердикт.']
    return '\n'.join(lines) + '\n'


def compare_tg(c, week, costs):
    a, t = c['agent'], c['twin_all']
    return ('📊 Агент против двойника C3b, неделя %s (с %s)\n'
            'Агент: %d сделок, %+.2fR, средняя прибыльная %s, поздних входов %s\n'
            'Двойник: %d сделок, %+.2fR, средняя прибыльная %s, поздних входов %s\n'
            'Расход $%.2f из $%.2f. Для вердикта нужно ~30 сделок.'
            % (week, c['since'], a['n'], a['sum_r'], _f(a['avg_win'], '%+.2fR'), _pct(a['late_share']),
               t['n'], t['sum_r'], _f(t['avg_win'], '%+.2fR'), _pct(t['late_share']), costs[0], costs[1]))
