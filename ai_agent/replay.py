"""Сухой прогон движка на мок-модели (этап 8). Это проверка движка, НЕ бэктест стратегии.

Берёт ряды и часовые свечи из репо, открывает их постепенно в симулированном времени (дневной
бар — после 00:15 следующего дня, часовой — после конца часа) и гоняет тик раз в 10 минут.
Мок-модель принимает случайные, но допустимые решения (иногда — заведомо кривые). После
каждого тика проверяются инварианты:
- позиций и заявок на вход не больше 3, в группе не больше 2;
- стоп ни разу не отодвинут от цены;
- вход исполнен не раньше решения, которое его породило;
- капитал = 100 + закрытые сделки + открытые позиции (учёт сходится);
- повторный тик в то же время ничего не меняет.

  python -m ai_agent replay --days 20 --seed 7
"""
import bisect
import datetime as dt
import json
import os
import random
import re
import shutil
import tempfile

from . import agent, book, llm
from . import config as C
from . import timeutil as T

STEP = dt.timedelta(minutes=10)


class Replay:
    def __init__(self, days, seed, src_series=None, src_candles=None):
        self.rng = random.Random(seed)
        self.src_series = src_series or os.path.join(C.ROOT, 'data', 'live_rf', 'series')
        self.src_candles = src_candles or os.path.join(C.ROOT, 'data', 'live_rf', 'candles')
        self.series = {a: json.load(open(os.path.join(self.src_series, a + '.json'), encoding='utf-8-sig'))
                       for a in C.UNIVERSE}
        self.candles = {a: json.load(open(os.path.join(self.src_candles, a + '_1h.json'), encoding='utf-8-sig'))
                        for a in C.UNIVERSE}
        self.ser_days = {a: [T.ms_to_msk(b['t']).date().isoformat() for b in self.series[a]] for a in C.UNIVERSE}
        self.hr_end = {a: [T.ms_to_msk(r[0]) + dt.timedelta(hours=1) for r in self.candles[a]] for a in C.UNIVERSE}
        last = min(T.ms_to_msk(max(r[0] for r in c)) for c in self.candles.values()).date()
        first = max(T.ms_to_msk(min(r[0] for r in c)) for c in self.candles.values()).date()
        start = max(first + dt.timedelta(days=3), last - dt.timedelta(days=int(days * 7 / 5) + 1))
        self.t0 = dt.datetime.combine(start, dt.time(0, 0))
        self.t1 = dt.datetime.combine(last, dt.time(23, 50))
        self.dir = tempfile.mkdtemp(prefix='ai-replay-')
        self.env = {'AI_AGENT_DATA_DIR': os.path.join(self.dir, 'data'),
                    'AI_AGENT_MEMORY_DIR': os.path.join(self.dir, 'memory'),
                    'AI_AGENT_SERIES_DIR': os.path.join(self.dir, 'series'),
                    'AI_AGENT_CANDLES_DIR': os.path.join(self.dir, 'candles'),
                    'AI_AGENT_RF_PORTFOLIO': os.path.join(self.dir, 'portfolio.json'),
                    'AI_AGENT_TWIN_TRADES': os.path.join(self.dir, 'none.json'),
                    'AI_AGENT_LLM_MOCK': '1'}
        self.saved_env = {k: os.environ.get(k) for k in list(self.env) + ['TG_BOT_TOKEN']}
        self.written = {}
        self.stops = {}
        self.violations = []
        self.stats = {'ticks': 0, 'calls': 0, 'actions': 0, 'invalid_sent': 0}

    # ---------------------------------------------------------------- окружение
    def __enter__(self):
        for k, v in self.env.items():
            os.environ[k] = v
        os.environ.pop('TG_BOT_TOKEN', None)
        for d in ('data', 'memory', 'series', 'candles'):
            os.makedirs(os.path.join(self.dir, d), exist_ok=True)
        shutil.copy(os.path.join(C.ROOT, 'agent_memory', 'Правила агента.md'), os.path.join(self.dir, 'memory'))
        with open(self.env['AI_AGENT_RF_PORTFOLIO'], 'w', encoding='utf-8') as f:
            json.dump({'active': {a: a + 'X' for a in C.UNIVERSE}, 'fronts': {a: {'secid': a + 'X'} for a in C.UNIVERSE}}, f)
        self.old_mock = llm.MOCK
        llm.MOCK = self.mock
        return self

    def __exit__(self, *exc):
        llm.MOCK = self.old_mock
        for k, v in self.saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.dir, ignore_errors=True)

    def expose(self, now):
        """Открыть данные, известные к моменту now: дневной бар D — с D+1 00:15, часовой — после конца часа."""
        cut_day = (now - dt.timedelta(minutes=15, days=1)).strftime('%Y-%m-%d')
        for a in C.UNIVERSE:
            ns, nh = bisect.bisect_right(self.ser_days[a], cut_day), bisect.bisect_right(self.hr_end[a], now)
            key = (ns, nh)
            if self.written.get(a) == key:
                continue
            self.written[a] = key
            ser, hr = self.series[a][:ns], self.candles[a][:nh]
            with open(os.path.join(self.dir, 'series', a + '.json'), 'w', encoding='utf-8') as f:
                json.dump(ser, f)
            p = os.path.join(self.dir, 'candles', a + '_1h.json')
            with open(p, 'w', encoding='utf-8') as f:
                json.dump(hr[-500:], f)
            ts = (now - dt.timedelta(hours=T.MSK_UTC_HOURS) - T.EPOCH).total_seconds()
            os.utime(p, (ts, ts))

    # ---------------------------------------------------------------- мок-модель
    def mock(self, messages, schema_name):
        if schema_name == 'news':
            return 'NONE'
        if schema_name == 'weekly':
            return {'review': 'прогон', 'lessons': []}
        self.stats['calls'] += 1
        user = messages[1]['content']
        point_main = 'Главный разбор' in user
        info = {}
        for m in re.finditer(r'### (\w+) — .*?\nШаг цены [\d.]+\. ATR\(14, дневной\) ([\d.—]+)\. Последняя цена ([\d.—]+)', user):
            try:
                info[m.group(1)] = (float(m.group(2)), float(m.group(3)))
            except ValueError:
                pass
        allowed = re.search(r'Инструменты этой проверки: ([^.]+)\.', user).group(1).split(', ')
        state = agent.load_state(C.paths()['state'])
        held = {p['instrument']: p for p in state['positions']}
        acts = []
        for a in allowed:
            if a not in info:
                continue
            atr, px = info[a]
            r = self.rng.random()
            if a in held:
                p = held[a]
                sm = 1 if p['side'] == 'long' else -1
                if r < 0.15:
                    acts.append(self._act(a, 'close', close_kind='take_profit' if point_main else 'idea_broken'))
                elif r < 0.45:
                    acts.append(self._act(a, 'modify', stop_px=round(p['stop'] + sm * 0.3 * atr, 6)))
                elif r < 0.5:
                    self.stats['invalid_sent'] += 1          # попытка отодвинуть стоп — движок обязан отказать
                    acts.append(self._act(a, 'modify', stop_px=round(p['stop'] - sm * atr, 6)))
            elif r < 0.25:
                side = self.rng.choice(['long', 'short'])
                sm = 1 if side == 'long' else -1
                kind = self.rng.choice(['market', 'limit'])
                ref = px if kind == 'market' else round(px - sm * 0.3 * atr, 6)
                bad = self.rng.random() < 0.1
                if bad:
                    self.stats['invalid_sent'] += 1          # стоп не с той стороны
                acts.append(self._act(a, 'enter', side=side, order=kind, limit_px=ref if kind == 'limit' else None,
                                      stop_px=round(ref + (1 if bad else -1) * sm * 1.5 * atr, 6),
                                      target_px=round(ref + sm * 3 * atr, 6), horizon_days=self.rng.randint(2, 10),
                                      setup=self.rng.choice(['pullback', 'early_breakout', 'catalyst']),
                                      invalidation='уход за стоп'))
        self.stats['actions'] += len(acts)
        return {'regime': {'rub': 'unclear', 'metals': 'unclear', 'energy': 'unclear', 'index': 'unclear'},
                'summary': 'прогон', 'actions': acts}

    @staticmethod
    def _act(inst, action, **kw):
        a = {'instrument': inst, 'action': action, 'side': None, 'order': None, 'limit_px': None, 'stop_px': None,
             'target_px': None, 'horizon_days': None, 'setup': None, 'close_kind': None, 'reason': 'прогон',
             'invalidation': None}
        a.update(kw)
        return a

    # ---------------------------------------------------------------- инварианты
    def check(self, now):
        P = C.paths()
        s = agent.load_state(P['state'])
        total, groups = book.exposure(s)
        if total > C.MAX_POSITIONS or any(v > C.MAX_PER_GROUP for v in groups.values()):
            self.violations.append('%s: лимиты %d %s' % (T.fmt(now), total, groups))
        for p in s['positions']:
            sm = 1 if p['side'] == 'long' else -1
            prev = self.stops.get(p['id'])
            if prev is not None and sm * (p['stop'] - prev) < -1e-9:
                self.violations.append('%s: стоп %s отодвинут %s -> %s' % (T.fmt(now), p['id'], prev, p['stop']))
            self.stops[p['id']] = p['stop']
            dec_at = p.get('decision_id', '').split(':', 1)
            if p.get('entry_at') and self._decision_at(p.get('decision_id')) > p['entry_at']:
                self.violations.append('%s: вход %s раньше решения' % (T.fmt(now), p['id']))
        eq = C.START_EQUITY + sum(t['net'] for t in s['trades']) + sum(p['realized'] - p['entry_fee'] for p in s['positions'])
        if abs(eq - s['equity']) > 1e-6:
            self.violations.append('%s: учёт не сходится %.9f != %.9f' % (T.fmt(now), eq, s['equity']))

    def _decision_at(self, did):
        if not hasattr(self, '_dec'):
            self._dec = {}
        if did not in self._dec:
            for d in agent.read_decisions(C.paths()['decisions']):
                self._dec[d['id']] = d['at']
        return self._dec.get(did, '')

    def run(self):
        now = self.t0
        while now <= self.t1:
            self.expose(now)
            agent.tick(now)
            self.stats['ticks'] += 1
            self.check(now)
            now += STEP
        # повторный тик в то же время — состояние не меняется
        P = C.paths()
        before = open(P['state'], encoding='utf-8').read()
        agent.tick(now - STEP)
        after = open(P['state'], encoding='utf-8').read()
        if before != after:
            self.violations.append('повторный тик изменил состояние')
        s = agent.load_state(P['state'])
        self.stats.update({'trades': len(s['trades']), 'sum_r': round(book.closed_sum_r(s), 2),
                           'open': len(s['positions']), 'equity': round(s['equity'], 3),
                           'rejected': sum(len(d.get('rejected') or []) for d in agent.read_decisions(P['decisions'])),
                           'from': T.fmt(self.t0), 'to': T.fmt(self.t1),
                           'exits': sorted({t['exit_reason'] for t in s['trades']})})
        return self.stats, self.violations


def main(days=20, seed=7):
    with Replay(days, seed) as r:
        stats, bad = r.run()
    print(json.dumps(stats, ensure_ascii=False, indent=1))
    if bad:
        print('НАРУШЕНИЯ (%d):' % len(bad))
        for v in bad[:30]:
            print(' -', v)
        return 1
    print('инварианты соблюдены')
    return 0
