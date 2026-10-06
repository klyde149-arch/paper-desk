"""Недельный разбор и предложения уроков (дизайн §8, §15).

Суббота: агент разбирает СВОИ сделки и решения недели (ни слова о других стратегиях) и
предлагает не больше двух уроков, каждый — минимум с тремя конкретными случаями, которые код
сверяет с реальными сделками и решениями. Урок без трёх подтверждённых случаев отбрасывается.
Уроки уходят владельцу кнопками; нажатие ловит ассистент и пишет data/ai_agent/inbox/,
статус в файле урока меняет apply_inbox() на ближайшем тике.
"""
import datetime as dt
import json
import os
import re

from . import budget, llm, memory, report, review, tg
from . import config as C
from . import timeutil as T

ENTRY_TYPES = ['pullback', 'early_breakout', 'catalyst', 'общий']
MAX_LESSONS = 2
MIN_CASES = 3

WEEKLY_SCHEMA = {
    'type': 'object', 'additionalProperties': False, 'required': ['review', 'lessons'],
    'properties': {
        'review': {'type': 'string', 'description': 'самопроверка недели, до 2500 символов, markdown'},
        'lessons': {'type': 'array', 'items': {
            'type': 'object', 'additionalProperties': False,
            'required': ['title', 'entry_type', 'observation', 'cases', 'proposal'],
            'properties': {
                'title': {'type': 'string'},
                'entry_type': {'type': 'string', 'enum': ENTRY_TYPES},
                'observation': {'type': 'string'},
                'cases': {'type': 'array', 'items': {
                    'type': 'object', 'additionalProperties': False,
                    'required': ['date', 'instrument', 'decision', 'result_r'],
                    'properties': {'date': {'type': 'string'}, 'instrument': {'type': 'string', 'enum': list(C.UNIVERSE)},
                                   'decision': {'type': 'string'},
                                   'result_r': {'anyOf': [{'type': 'number'}, {'type': 'null'}]}}}},
                'proposal': {'type': 'string'},
            }}},
    },
}

INSTRUCTIONS = """## Недельный разбор

Разберите свои сделки и решения за неделю: что сработало, что нет, где вы отступили от правил.
Предложите не больше двух уроков — только если видите повторяющийся паттерн. Каждый урок: короткое
название, тип входа, наблюдение, минимум три конкретных случая (дата, инструмент, решение, результат
в R) из списка ниже, предложение, что менять в поведении. Уроки не могут менять риск-рамки. Нет
паттерна — lessons пустой, это нормально. Ответ — только JSON по схеме."""


def _cut(s, n):
    return ' '.join(str(s or '').split())[:n]


def week_bounds(now):
    start = (now - dt.timedelta(days=now.weekday())).replace(hour=0, minute=0, second=0, microsecond=0)
    return start - dt.timedelta(days=7) if now.weekday() < 5 else start, now


def _known_cases(trades, decisions):
    known = set()
    for t in trades:
        known.add((t['entry_day'], t['instrument']))
        known.add((t['exit_at'][:10], t['instrument']))
    for d in decisions:
        for a in d.get('accepted') or []:
            known.add((d['at'][:10], a['instrument']))
    return known


def validate_lessons(lessons, trades, decisions):
    known = _known_cases(trades, decisions)
    ok, bad = [], []
    for x in (lessons or [])[:MAX_LESSONS]:
        cases = [c for c in x.get('cases') or [] if (str(c.get('date', ''))[:10], c.get('instrument')) in known]
        if len(cases) < MIN_CASES:
            bad.append('«%s»: подтверждено случаев %d из %d' % (_cut(x.get('title'), 80), len(cases), MIN_CASES))
            continue
        ok.append({'title': _cut(x.get('title'), 80), 'entry_type': x.get('entry_type') if x.get('entry_type') in ENTRY_TYPES else 'общий',
                   'observation': _cut(x.get('observation'), 600), 'proposal': _cut(x.get('proposal'), 600),
                   'cases': [{'date': str(c['date'])[:10], 'instrument': c['instrument'], 'decision': _cut(c.get('decision'), 200),
                              'result_r': c.get('result_r')} for c in cases]})
    if len(lessons or []) > MAX_LESSONS:
        bad.append('предложено %d уроков, взяты первые %d' % (len(lessons), MAX_LESSONS))
    return ok, bad


def stats_md(trades):
    if not trades:
        return 'Закрытых сделок за неделю нет.'
    out = ['Закрыто сделок: %d, сумма %+.2fR.' % (len(trades), sum(t['r'] for t in trades))]
    for s in ('pullback', 'early_breakout', 'catalyst'):
        ts = [t for t in trades if t['setup'] == s]
        if ts:
            out.append('- %s: %d сделок, %+.2fR' % (s, len(ts), sum(t['r'] for t in ts)))
    return '\n'.join(out)


def mission_md(ms, miss, silent):
    late = '—' if ms['late_share'] is None else '%d%%' % round(ms['late_share'] * 100)
    avg = '—' if ms['avg_win'] is None else '%+.2fR' % ms['avg_win']
    out = ['- Средняя прибыльная сделка (все сделки с запуска): %s, цель не ниже +1,5R.' % avg,
           '- Входы после уже прошедшего движения (ER20 ≥ 0,5): %s, не больше 20%%.' % late,
           '- Упущенные идеи за неделю: %d, сумма %+.2fR (ошибка того же веса, что выбитый стоп).'
           % (len(miss), sum(r['r'] for r in miss)),
           '- Тренд пропущен молча (без входа и без причины): %d раз.' % len(silent)]
    out += ['  - ' + x for x in silent]
    return chr(10).join(out)


def lesson_md(lesson_id, x, day, week):
    cases = '\n'.join('- %s, %s, %s, %s' % (c['date'], c['instrument'], c['decision'],
                                             '%+.2fR' % c['result_r'] if isinstance(c['result_r'], (int, float)) else 'в работе')
                      for c in x['cases'])
    return ('---\nid: %s\nstatus: предложен\nпредложен: %s\nнеделя: %s\nтип_входа: %s\n---\n\n# %s\n\n'
            '**Что заметил.** %s\n\n**Случаи:**\n%s\n\n**Что предлагаю менять в поведении.** %s\n'
            % (lesson_id, day, week, x['entry_type'], x['title'], x['observation'], cases, x['proposal']))


def _slug(s):
    return re.sub(r'[^0-9A-Za-zА-Яа-яЁё _-]+', '', s).strip()[:60] or 'урок'


def run(state, cx):
    from .agent import read_decisions, write_json
    now = cx.now
    lo, hi = week_bounds(now)
    lo_s = T.fmt(lo)
    trades = [t for t in state['trades'] if t['exit_at'] >= lo_s]
    decisions = [d for d in read_decisions(cx.P['decisions']) if d.get('at', '') >= lo_s]
    y, w, _ = now.date().isocalendar()
    week = '%d-W%02d' % (y, w)
    if not trades and not any(d.get('accepted') for d in decisions):
        return 'skip', 'за неделю нет ни сделок, ни решений — разбирать нечего'
    miss = review.missed(decisions, state, cx.P['series'], lo_s)
    tight = review.tighten_review(trades, cx.P['series'])
    silent = ['%s %s: %s' % (d['at'], d.get('point'), ', '.join(C.GROUP_RU[g] for g in d['silent_skips']))
              for d in decisions if d.get('silent_skips')]
    ms = report._stats(state['trades'], 'r', 'instrument', 'entry_day', cx.P['series'], {})
    mission = mission_md(ms, miss, silent)
    rules, _ = memory.load_rules(cx.P['memory'])
    lessons_text, _, _ = memory.accepted_lessons(cx.P['memory'])
    system = rules + '\n\n## Принятые уроки\n\n' + (lessons_text or 'Пока нет.') + '\n\n' + INSTRUCTIONS
    lines = ['# Неделя %s (с %s по %s МСК)' % (week, T.fmt(lo), T.fmt(hi)), '', '## Закрытые сделки']
    for t in trades:
        lines.append('%s %s %s %s: вход %s %s, выход %s %s (%s), %+.2fR, держали %d дн. из %s. Идея: %s. Сломается: %s'
                     % (t['id'], t['instrument'], t['side'], t['setup'], t['entry_at'], t['entry'], t['exit_at'],
                        t['exit_px'], t['exit_reason'], t['r'], t['days_held'], t.get('horizon_days'),
                        t.get('reason'), t.get('invalidation')))
    lines += ['', '## Открытые позиции']
    lines += ['%s %s %s, вход %s %s, стоп %s' % (p['instrument'], p['side'], p['setup'], p['entry_at'], p['entry'], p['stop'])
              for p in state['positions']] or ['нет']
    lines += ['', '## Оценка по миссии (считает код)', mission,
              '', '## Упущенное: что дали бы неисполненные заявки и отказы', review.missed_md(miss),
              '', '## Подтяжки стопа перед событиями (event_tighten)', review.tighten_md(tight)]
    lines += ['', '## Решения недели']
    for d in decisions:
        for a in d.get('accepted') or []:
            lines.append('%s %s: %s %s — %s' % (d['at'], d['point'], a['action'], a['instrument'], a.get('reason', '')))
        for r in d.get('rejected') or []:
            lines.append('%s %s: ОТКЛОНЕНО движком %s %s — %s' % (d['at'], d['point'], r.get('action'), r.get('instrument'), r['why']))
    messages = [{'role': 'system', 'content': system}, {'role': 'user', 'content': '\n'.join(lines)}]

    cpath = os.path.join(cx.P['calls'], now.strftime('%Y-%m-%d'), 'weekly_%s.json' % week)
    from .market import read_json
    cached = read_json(cpath)
    if cached is None:
        worst = budget.worst_case(C.MODEL, budget.est_tokens(system + messages[1]['content']), C.MAX_TOKENS['medium'])
        ok, why = budget.check(cx.P['usage'], now.strftime('%Y-%m-%d'), worst)
        if not ok:
            return 'skip', why
        try:
            r = llm.call_structured(messages, 'weekly', WEEKLY_SCHEMA, 'medium', C.MAX_TOKENS['medium'])
        except llm.LLMError as e:
            return 'error', str(e)
        cost = budget.cost_of(C.MODEL, r['usage'])
        cached = {'key': 'weekly:' + week, 'at': T.fmt(now), 'messages': messages, 'raw': r['raw'],
                  'data': r['data'], 'usage': r['usage'], 'cost_usd': cost}
        write_json(cpath, cached, indent=None)
        budget.record(cx.P['usage'], {'ts': T.fmt(now), 'kind': 'weekly', 'key': 'weekly:' + week, 'model': r['model'],
                                      'prompt_tokens': r['usage'].get('prompt_tokens'),
                                      'completion_tokens': r['usage'].get('completion_tokens'), 'cost_usd': round(cost, 6)})
    data = cached['data'] if isinstance(cached.get('data'), dict) else {}
    ok_lessons, bad = validate_lessons(data.get('lessons'), state['trades'], read_decisions(cx.P['decisions']))

    rdir = os.path.join(cx.P['memory'], memory.REVIEWS_DIR)
    os.makedirs(rdir, exist_ok=True)
    with open(os.path.join(rdir, 'Неделя %s.md' % week), 'w', encoding='utf-8', newline='\n') as f:
        f.write('# Неделя %s\n\n## Цифры (считает код)\n\n%s\n\n%s\n\n### Упущенное\n\n%s\n\n'
                '### Подтяжки перед событиями\n\n%s\n\n## Самопроверка агента\n\n%s\n'
                % (week, stats_md(trades), mission, review.missed_md(miss), review.tighten_md(tight),
                   str(data.get('review') or '').strip()[:4000]))
        if bad:
            f.write('\n## Отброшенные предложения\n\n' + '\n'.join('- ' + b for b in bad) + '\n')
    ldir = os.path.join(cx.P['memory'], memory.LESSONS_DIR)
    os.makedirs(ldir, exist_ok=True)
    day = now.strftime('%Y-%m-%d')
    for i, x in enumerate(ok_lessons, 1):
        lid = 'L%d%02d%d' % (y, w, i)
        path = os.path.join(ldir, '%s %s.md' % (day, _slug(x['title'])))
        with open(path, 'w', encoding='utf-8', newline='\n') as f:
            f.write(lesson_md(lid, x, day, week))
        tg.send('📚 Урок %s (предложен агентом)\n%s\n\nЧто заметил: %s\nПредлагает: %s\nСлучаи:\n%s' % (
            lid, x['title'], x['observation'], x['proposal'],
            '\n'.join('• %s %s: %s' % (c['date'], c['instrument'], c['decision']) for c in x['cases'])),
            keyboard=[[{'text': '✅ Принять', 'callback_data': 'al:acc:' + lid},
                       {'text': '✖ Отклонить', 'callback_data': 'al:rej:' + lid}]])
    tg.send('🤖 Агент: недельный разбор %s готов (%s). Упущено идей: %d (%+.2fR), молчаливых пропусков тренда: %d. '
            'Предложений уроков: %d%s.'
            % (week, stats_md(trades).split('\n')[0], len(miss), sum(r['r'] for r in miss), len(silent), len(ok_lessons),
               ' — ждут решения кнопками выше' if ok_lessons else ''))
    return 'ok', {'lessons': len(ok_lessons), 'dropped': bad}


def apply_inbox(cx, state):
    """Решения владельца по урокам: строки {id, decision: accept|reject, at} от ассистента.
    Меняем status только у урока со status: предложен. -> список применённых."""
    path = cx.P['inbox']
    rows = budget.rows(path)
    done = set(state.setdefault('inbox_done', []))
    applied = []
    for r in rows:
        rid = '%s|%s|%s' % (r.get('id'), r.get('decision'), r.get('at'))
        if rid in done or r.get('decision') not in ('accept', 'reject'):
            continue
        done.add(rid)
        new = 'принят' if r['decision'] == 'accept' else 'отклонён'
        for x in memory.lessons(cx.P['memory']):
            if x['meta'].get('id') == r.get('id') and x['status'] == 'предложен':
                with open(x['path'], encoding='utf-8') as f:
                    text = f.read()
                text = text.replace('status: предложен', 'status: %s\n%s: %s' % (new, new, str(r.get('at', ''))[:10]), 1)
                with open(x['path'], 'w', encoding='utf-8', newline='\n') as f:
                    f.write(text)
                applied.append((r['id'], new, x['title']))
    state['inbox_done'] = sorted(done)[-500:]
    return applied
