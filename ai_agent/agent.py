"""Оркестратор агента: один тик диспетчера (раз в 5 минут) и запуск точек решений.

Порядок тика:
1. рынок: ряды, часовые свечи, контракты;
2. рукав догоняет рынок: ролл, новые завершённые часовые бары (или дневной бар в запасном
   режиме), трейл по новому дневному бару, истечение заявок;
3. наступившие точки: проверка «есть ли что решать» -> снимок -> бюджет -> модель (ответ
   сохраняется сразу, повторный запуск его переиспользует и не платит) -> проверка ->
   решение пишется в decisions.jsonl ДО применения -> применение -> журнал и Telegram;
4. состояние пишется атомарно (tmp + os.replace), вместе с отметками выполненных точек.
"""
import datetime as dt
import json
import os
import re

from . import book, budget, decide, events, llm, market, memory, news, report, scheduler, snapshot, tg
from . import config as C
from . import timeutil as T
from .points import POINTS

EQUITY_EVERY = dt.timedelta(hours=6)
MAX_ATTEMPTS = {'main': 3}
STALE_HOURLY = dt.timedelta(days=4)


# ------------------------------------------------------------------ файлы

def load_state(path):
    s = market.read_json(path)
    if not s:
        s = book.new_state()
    s.setdefault('done', {})
    s.setdefault('attempts', {})
    return s


def write_json(path, obj, indent=1):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(obj, f, ensure_ascii=False, indent=indent, default=str)
        f.write('\n')
    os.replace(tmp, path)


def append_jsonl(path, row):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'a', encoding='utf-8', newline='\n') as f:
        f.write(json.dumps(row, ensure_ascii=False, default=str) + '\n')


def read_decisions(path):
    rows, seen = [], {}
    for r in budget.rows(path):
        seen[r.get('id')] = r            # повтор после падения — последняя запись с тем же id
    rows = list(seen.values())
    rows.sort(key=lambda r: r.get('at', ''))
    return rows


class Ctx:
    def __init__(self, now, dry=False):
        self.now = now
        self.dry = dry
        self.P = C.paths()
        self.cal = events.load(self.P['calendar'])
        self.logs = []

    def log(self, msg):
        line = '%s %s' % (T.fmt(self.now), msg)
        self.logs.append(line)
        if not self.dry:
            os.makedirs(self.P['data'], exist_ok=True)
            with open(self.P['log'], 'a', encoding='utf-8', newline='\n') as f:
                f.write(line + '\n')

    def alert(self, msg):
        self.log('АЛЕРТ ' + msg)
        if not self.dry:
            tg.send('⚠️ Агент: ' + msg)

    def halt_files(self):
        if os.path.exists(self.P['halt']):
            return 'выключатель HALT_AGENT'
        if os.path.exists(self.P['halt_entries']):
            return 'выключатель HALT_AGENT_ENTRIES'
        return None


# ------------------------------------------------------------------ рынок

def load_market(P, now):
    cons = market.contracts(P['rf_portfolio'])
    out = {}
    for a in C.UNIVERSE:
        daily = market.load_daily(P['series'], a, tail=market.DAILY_TAIL)
        hb, asof = market.load_hourly(P['candles'], a)
        hc = market.complete_hourly(hb, now, asof)
        ok = market.hourly_usable(cons.get(a)) and bool(hc) and now - hc[-1]['t'] < STALE_HOURLY
        d = {'daily': daily, 'hourly': hc if ok else [], 'hourly_ok': ok, 'contract': cons.get(a),
             'atr': market.atr14(daily, len(daily) - 1) if daily else None}
        if ok:
            d['last_px'], d['last_px_at'] = hc[-1]['c'], hc[-1]['t'] + market.HOUR
        elif daily:
            d['last_px'], d['last_px_at'] = daily[-1]['c'], None
        else:
            d['last_px'], d['last_px_at'] = None, None
        out[a] = d
    return out


def advance(state, mkt, now, halt_files=None):
    """Рукав догоняет рынок. -> события."""
    ev = []
    for a in C.UNIVERSE:
        m = mkt[a]
        daily = m['daily']
        k = market.rescale_factor(state['series_ref'].get(a), daily)
        if k:
            ev += book.apply_roll(state, a, k, float(state['series_ref'][a][1]), now)
        if daily:
            state['series_ref'][a] = market.series_ref(daily)
        busy = any(p['instrument'] == a for p in state['positions']) or any(o['instrument'] == a for o in state['orders'])
        if m['hourly_ok']:
            last = state['last_bar'].get(a)
            if last is None:
                state['last_bar'][a] = m['hourly'][-1]['ts']    # первый запуск: историю не проигрываем
            else:
                for b in m['hourly']:
                    if b['ts'] > last:
                        ev += book.process_bar(state, a, b, halt_files)
        elif busy and daily:
            ev += book.cancel_order(state, a, 'нет часовых данных по активному контракту')
            last_h = state['last_bar'].get(a)
            last_h_day = T.ms_to_msk(last_h).strftime('%Y-%m-%d') if last_h else ''
            for b in daily:
                if b['day'] > state['fallback_day'].get(a, '') and b['day'] >= last_h_day:
                    ev += book.process_daily_fallback(state, a, b)
        if daily and any(p['instrument'] == a for p in state['positions']):
            day = daily[-1]['day']
            if day > state['trail_day'].get(a, ''):
                ev += book.apply_trail(state, a, m['atr'], day)
    ev += book.expire_orders(state, now)
    return ev


# ------------------------------------------------------------------ точки

def _call_path(P, now, key):
    return os.path.join(P['calls'], now.strftime('%Y-%m-%d'), re.sub(r'[^0-9A-Za-z_.-]+', '_', key) + '.json')


def _busy(state, allowed):
    return (any(p['instrument'] in allowed for p in state['positions'])
            or any(o['instrument'] in allowed for o in state['orders']))


def _entries_blocked(state, cx):
    if state.get('halt'):
        return 'стоп-кран: ' + state['halt']['reason']
    return cx.halt_files()


def build_messages(state, item, mkt, cx, news_items):
    point = item['point']
    pdef = POINTS[point]
    now = cx.now
    allowed = list(item['event']['instruments']) if item.get('event') else list(pdef['instruments'])
    rules, _ = memory.load_rules(cx.P['memory'])
    lessons_text, used, left = memory.accepted_lessons(cx.P['memory'])
    mv = memory.version(rules, lessons_text)
    inst = {}
    for a in allowed:
        m = mkt[a]
        inst[a] = {'daily': m['daily'][-pdef['daily']:], 'hourly': m['hourly'][-pdef['hourly']:] if pdef['hourly'] else [],
                   'atr': m['atr'], 'last_px': m['last_px'], 'last_px_at': m['last_px_at'], 'hourly_ok': m['hourly_ok']}
    ctx = {'now': now, 'point': point, 'allowed': allowed, 'event': item.get('event'), 'instruments': inst,
           'state': state, 'rules_text': rules, 'lessons_text': lessons_text,
           'calendar': events.window(cx.cal, now), 'news': news_items,
           'journal_digest': snapshot.journal_digest(state['trades'], read_decisions(cx.P['decisions'])),
           'entries_blocked': _entries_blocked(state, cx), 'mission': mission_stats(state, cx.P['series'])}
    return snapshot.build(ctx), allowed, mv, left


def mission_stats(state, series_dir):
    """Показатели миссии по всем закрытым сделкам — агент видит их в каждом вызове."""
    try:
        s = report._stats(state['trades'], 'r', 'instrument', 'entry_day', series_dir, {})
    except Exception:
        return None
    return {'n': s['n'], 'avg_win': s['avg_win'], 'late_share': s['late_share']}


def run_trade_point(state, item, mkt, cx):
    """-> события. Отметку done ставит вызывающий по результату."""
    point, key, now = item['point'], item['key'], cx.now
    pdef = POINTS[point]
    allowed = list(item['event']['instruments']) if item.get('event') else list(pdef['instruments'])
    cpath = _call_path(cx.P, now, key)
    cached = market.read_json(cpath)
    news_items = (cached or {}).get('news')
    if cached is None:
        if point != 'main':
            high_event = bool(item.get('event')) and item['event']['importance'] == 'high'
            if not _busy(state, allowed) and not high_event:
                if _entries_blocked(state, cx):
                    return 'skip', 'нечего вести, входы запрещены', []
                news_items = news.fetch(pdef['news_groups'], now, cx.P['usage'],
                                        event=item.get('event'), log=cx.log)
                if not news.wakes(news_items, allowed, now):
                    return 'skip', 'нечего решать: нет позиций, заявок и важных новостей', []
        if news_items is None:
            news_items = news.fetch(pdef['news_groups'], now, cx.P['usage'], event=item.get('event'), log=cx.log)
    messages, allowed, mv, left = build_messages(state, item, mkt, cx, news_items)
    if left:
        cx.alert('принятые уроки не помещаются в %d токенов: %s — перенести старые в Уроки/Архив'
                 % (memory.LESSON_TOKENS, ', '.join(x['file'] for x in left)))
    effort = pdef['effort']
    if cached is None:
        in_tok = budget.est_tokens(messages[0]['content'] + messages[1]['content'])
        worst = budget.worst_case(C.MODEL, in_tok, C.MAX_TOKENS[effort])
        ok, why = budget.check(cx.P['usage'], now.strftime('%Y-%m-%d'), worst)
        if not ok:
            return 'skip', why, [{'kind': 'budget', 'why': why}]
        try:
            r = llm.call_structured(messages, 'trade', decide.TRADE_SCHEMA, effort, C.MAX_TOKENS[effort])
        except llm.LLMError as e:
            return 'error', str(e), []
        cost = budget.cost_of(C.MODEL, r['usage'])
        cached = {'key': key, 'at': T.fmt(now), 'point': point, 'model': r['model'], 'effort': effort,
                  'memory_version': mv, 'news': news_items, 'messages': messages, 'raw': r['raw'],
                  'data': r['data'], 'usage': r['usage'], 'cost_usd': cost, 'finish': r['finish']}
        write_json(cpath, cached, indent=None)
        details = r['usage'].get('completion_tokens_details') or {}
        budget.record(cx.P['usage'], {'ts': T.fmt(now), 'kind': 'trade', 'key': key, 'model': r['model'],
                                      'effort': effort, 'prompt_tokens': r['usage'].get('prompt_tokens'),
                                      'completion_tokens': r['usage'].get('completion_tokens'),
                                      'reasoning_tokens': details.get('reasoning_tokens'),
                                      'cost_usd': round(cost, 6), 'est_in_tokens': in_tok})
    halt = _entries_blocked(state, cx)
    vctx = {'state': state, 'point': point, 'allowed': set(allowed), 'halt_files': halt,
            'last_px': {a: mkt[a]['last_px'] for a in C.UNIVERSE},
            'hourly_ok': {a: mkt[a]['hourly_ok'] for a in C.UNIVERSE}}
    try:
        accepted, rejected = decide.validate(cached['data'], vctx)
    except ValueError as e:
        return 'error', 'ответ модели не прошёл схему: %s' % e, []
    skips = decide.clean_skips(cached['data'])
    silent = decide.silent_skips(cached['data'].get('regime'), state, skips, set(allowed), vctx['hourly_ok'],
                                 entries_blocked=halt, accepted=accepted)
    decision = {'id': key, 'at': T.fmt(now), 'point': point, 'memory_version': cached.get('memory_version', mv),
                'regime': cached['data'].get('regime'), 'summary': ' '.join(str(cached['data'].get('summary') or '').split())[:300],
                'accepted': accepted, 'rejected': rejected, 'skips': skips, 'silent_skips': silent,
                # последний дневной бар ряда на момент решения: после ролла ряд пересчитывается,
                # по этой отметке review.missed переводит уровни заявок в новые единицы
                'closes': {a: [mkt[a]['daily'][-1]['day'], mkt[a]['daily'][-1]['c']] for a in C.UNIVERSE if mkt[a]['daily']},
                'cost_usd': cached.get('cost_usd')}
    if cx.dry:
        return 'dry', decision, []
    append_jsonl(cx.P['decisions'], decision)          # write-ahead: решение записано до применения
    ev = decide.apply(state, accepted, now, key, decision['memory_version'], point)
    label = POINTS[point]['label'] + (': ' + item['event']['title'] if item.get('event') else '')
    memory.journal_append(cx.P['memory'], now.strftime('%Y-%m-%d'), report.journal_entry(T.fmt(now), label, decision, ev))
    msg = report.point_message(label, decision, ev)
    if point == 'main':
        total, today = budget.spent(cx.P['usage'], now.strftime('%Y-%m-%d'))
        msg += '\nРасход: сегодня $%.2f, всего $%.2f из $%.2f' % (today, total, C.budget()['total_usd'])
    tg.send(msg)
    return 'ok', decision, ev


def run_item(state, item, mkt, cx):
    key, point = item['key'], item['point']
    if point == 'weekly':
        from . import weekly
        status, info = weekly.run(state, cx)
        if status != 'error':
            send_compare(state, cx, key.split(':', 1)[1])
    else:
        status, info, _ = run_trade_point(state, item, mkt, cx)
    if status == 'error':
        n = state['attempts'].get(key, 0) + 1
        state['attempts'][key] = n
        cx.log('%s: сбой %d — %s' % (key, n, info))
        if n < MAX_ATTEMPTS.get(point, 2):
            return status
        cx.alert('%s: модель недоступна (%s). Новых входов нет, стопы и трейл работают.' % (key, info))
    elif status == 'skip':
        cx.log('%s: пропуск — %s' % (key, info))
        if 'бюджет' in info or 'потолок' in info:
            akey = 'budget_alert:%s' % cx.now.strftime('%Y-%m-%d')
            if akey not in state['done']:
                state['done'][akey] = T.fmt(cx.now)
                cx.alert(info + '. Новых входов нет, позиции ведёт код.')
    else:
        cx.log('%s: выполнено' % key)
    state['done'][key] = T.fmt(cx.now)
    state['attempts'].pop(key, None)
    if point == 'main':
        state['last_main_day'] = item['bar_day']
    return status


def send_compare(state, cx, week):
    """Недельное сравнение с двойником C3b — только владельцу, вне памяти агента (§9)."""
    try:
        twin = market.read_json(cx.P['twin_trades'], []) or []
        c = report.compare(state['trades'], twin, cx.P['series'], state.get('started_at', '')[:10])
        costs = (budget.spent(cx.P['usage'])[0], C.budget()['total_usd'])
        os.makedirs(cx.P['reports'], exist_ok=True)
        with open(os.path.join(cx.P['reports'], 'week_%s.md' % week), 'w', encoding='utf-8', newline='\n') as f:
            f.write(report.compare_md(c, week, costs))
        tg.send(report.compare_tg(c, week, costs))
    except Exception as e:
        cx.log('сравнение с двойником не собрано: %s' % e)


def _prune_done(state, now):
    lim = (now - dt.timedelta(days=21)).strftime('%Y-%m-%d')
    for k in list(state['done']):
        if str(state['done'][k])[:10] < lim:
            del state['done'][k]


def mark_to_market(state, mkt, now):
    """Read-only presentation mark for the paper sleeve.

    ``state['equity']`` is deliberately realized accounting.  For the dashboard we add the
    gross move of every currently open leg; entry and roll fees are already present in realized
    equity, so adding them again would double-count costs.  A missing/stale hourly quote makes
    the aggregate MTM unknown rather than silently marking the position at its entry price.
    """
    marks, missing = {}, []
    gross_open = 0.0
    open_net = 0.0
    for p in state['positions']:
        asset = p['instrument']
        md = mkt.get(asset) or {}
        price = md.get('last_px') if md.get('hourly_ok') else None
        price_at = md.get('last_px_at')
        if price is None or price_at is None:
            missing.append(asset)
            marks[asset] = {'ok': False, 'price': None, 'price_ts': None,
                            'quote_age_min': None, 'pnl': None, 'gross': None, 'r': None}
            continue
        side = 1.0 if p['side'] == 'long' else -1.0
        gross = side * float(p['qty']) * (float(price) - float(p['entry']))
        # p.realized contains roll P&L/costs; entry_fee was charged directly to state equity.
        pnl = float(p.get('realized') or 0.0) + gross - float(p.get('entry_fee') or 0.0)
        risk = float(p.get('risk_amt') or 0.0)
        age = max(0.0, (now - price_at).total_seconds() / 60.0)
        marks[asset] = {
            'ok': True,
            'price': round(float(price), 6),
            'price_ts': T.msk_to_ms(price_at - dt.timedelta(hours=T.MSK_UTC_HOURS)),
            'quote_age_min': round(age, 1),
            'pnl': round(pnl, 9),
            'gross': round(gross, 9),
            'r': round(pnl / risk, 4) if risk > 0 else None,
        }
        gross_open += gross
        open_net += pnl
    complete = not missing
    return {
        'equity_realized': round(float(state['equity']), 9),
        'equity_mtm': round(float(state['equity']) + gross_open, 9) if complete else None,
        'open_pnl': round(open_net, 9) if complete else None,
        'marks': marks,
        'missing': missing,
    }


def write_heartbeat(P, state, now, mark, status='live', reason=None):
    utc_now = now - dt.timedelta(hours=T.MSK_UTC_HOURS)
    row = {
        'schema': 1,
        'ts': T.msk_to_ms(utc_now),
        'at': T.fmt(now),
        'status': status,
        'reason': reason,
        'equity_realized': mark.get('equity_realized'),
        'equity_mtm': mark.get('equity_mtm'),
        'open_pnl': mark.get('open_pnl'),
        'positions': len(state['positions']),
        'orders': len(state['orders']),
        'trades': len(state['trades']),
        'sum_r': round(book.closed_sum_r(state), 3),
        'marks': mark.get('marks') or {},
        'missing_quotes': mark.get('missing') or [],
    }
    write_json(P['heartbeat'], row, indent=None)
    return row


def write_equity(P, state, now, force, mark=None):
    path = os.path.join(P['data'], 'equity.json')
    eq = market.read_json(path, []) or []
    last = T.ms_to_msk(eq[-1]['ts']) if eq else None     # ts здесь настоящее UTC -> наивное UTC
    utc_now = now - dt.timedelta(hours=T.MSK_UTC_HOURS)
    if not force and last and utc_now - last < EQUITY_EVERY:
        return False
    # ts — настоящее UTC в мс, как в data/live_rf/equity.json (его читает tools/live_watch.ps1)
    mark = mark or {'equity_mtm': float(state['equity']), 'open_pnl': 0.0}
    eq.append({'ts': T.msk_to_ms(utc_now), 'equity': round(state['equity'], 4),
               'equity_mtm': round(mark['equity_mtm'], 4) if mark.get('equity_mtm') is not None else None,
               'open_pnl': round(mark['open_pnl'], 4) if mark.get('open_pnl') is not None else None,
               'positions': len(state['positions']), 'orders': len(state['orders']),
               'sum_r': round(book.closed_sum_r(state), 3)})
    write_json(path, eq[-3000:], indent=None)
    return True


def tick(now=None, only=None):
    """Один проход диспетчера. only — выполнить только эти точки (для ручного запуска)."""
    now = now or T.msk_now()
    cx = Ctx(now)
    if os.path.exists(cx.P['halt']):
        state = load_state(cx.P['state'])
        mark = {'equity_realized': round(float(state['equity']), 9), 'equity_mtm': None,
                'open_pnl': None, 'marks': {}, 'missing': [p['instrument'] for p in state['positions']]}
        write_heartbeat(cx.P, state, now, mark, status='halt', reason='выключатель HALT_AGENT')
        cx.log('HALT_AGENT: тик пропущен целиком')
        return {'halt': True}
    state = load_state(cx.P['state'])
    state.setdefault('started_at', T.fmt(now))
    mkt = load_market(cx.P, now)
    ev = advance(state, mkt, now, cx.halt_files())
    if ev:
        msg = report.events_message(ev)
        if msg:
            tg.send(msg)
            memory.journal_append(cx.P['memory'], now.strftime('%Y-%m-%d'),
                                  '## %s — исполнение\n\n' % T.fmt(now) + '\n'.join('- ' + x for x in msg.split('\n')[1:]))
    from . import weekly
    for lid, new, title in weekly.apply_inbox(cx, state):
        cx.log('урок %s: %s' % (lid, new))
        tg.send('📚 Урок %s «%s»: %s. Агент учтёт его со следующего вызова.' % (lid, title, new))
    daily = {a: mkt[a]['daily'] for a in C.UNIVERSE}
    miss = scheduler.missing_bar_alert(state, now, daily, cx.cal)
    if miss:
        cx.alert(miss)
    cov = events.coverage_warning(cx.cal, now)
    if cov and 'calendar_alert:%s' % now.strftime('%Y-%m-%d') not in state['done'] and now.hour >= 9:
        state['done']['calendar_alert:%s' % now.strftime('%Y-%m-%d')] = T.fmt(now)
        if now.weekday() == 0:
            cx.alert(cov)
    ran = []
    for item in scheduler.due(state, now, daily, cx.cal):
        if only and item['point'] not in only:
            continue
        ran.append((item['key'], run_item(state, item, mkt, cx)))
    _prune_done(state, now)
    write_json(cx.P['state'], state)
    if state['trades']:
        write_json(cx.P['trades'], state['trades'])
    mark = mark_to_market(state, mkt, now)
    if state.get('halt'):
        hb_status, hb_reason = 'halt', state['halt'].get('reason')
    elif os.path.exists(cx.P['halt_entries']):
        hb_status, hb_reason = 'entries_halt', 'выключатель HALT_AGENT_ENTRIES'
    elif mark['missing']:
        hb_status, hb_reason = 'stale_quotes', 'нет свежих часовых котировок: ' + ', '.join(mark['missing'])
    else:
        hb_status, hb_reason = 'live', None
    write_heartbeat(cx.P, state, now, mark, status=hb_status, reason=hb_reason)
    write_equity(cx.P, state, now, force=bool(ev or ran), mark=mark)
    return {'events': ev, 'ran': ran, 'logs': cx.logs}


def run_dry(point, now=None):
    """Ручной вызов точки без применения и без записи состояния (этап 9: замер на живой модели).
    Сохраняет вызов в calls/ и расход в usage.jsonl — деньги тратятся по-настоящему."""
    now = now or T.msk_now()
    cx = Ctx(now)
    state = load_state(cx.P['state'])
    mkt = load_market(cx.P, now)
    advance(state, mkt, now)
    day = scheduler.latest_daily_day({a: mkt[a]['daily'] for a in C.UNIVERSE})
    item = {'point': point, 'key': 'dry-%s:%s' % (point, T.fmt(now).replace(' ', 'T')), 'bar_day': day}
    cx.dry = True
    status, info, _ = run_trade_point(state, item, mkt, cx)
    return status, info, cx.logs
