"""Синтетический рынок и память во временной папке — для тестов тика без реальных файлов."""
import datetime as dt
import json
import os
import shutil
import tempfile

from ai_agent import config as C
from ai_agent import timeutil as T

BASE = {'BR': 100.0, 'NG': 3.0, 'GOLD': 4000.0, 'SILV': 60.0, 'Si': 85000.0, 'CNY': 12.0, 'MIX': 250000.0, 'Eu': 98000.0}
CONTRACT = {'BR': 'BRV6', 'NG': 'NGV6', 'GOLD': 'GDZ6', 'SILV': 'SVZ6', 'Si': 'SiZ6', 'CNY': 'CRZ6', 'MIX': 'MXZ6', 'Eu': 'EuZ6'}
LAST_DAY = dt.date(2026, 10, 6)      # вторник: главный разбор в ночь на среду


def _snap(a, x):
    t = C.TICK[a]
    return round(round(x / t) * t, 6)


def weekdays_back(last, n):
    out, d = [], last
    while len(out) < n:
        if d.weekday() < 5:
            out.append(d)
        d -= dt.timedelta(days=1)
    return out[::-1]


class Env:
    def __init__(self, last_day=LAST_DAY, hourly_days=2):
        self.dir = tempfile.mkdtemp(prefix='ai-agent-')
        self.P = {k: os.path.join(self.dir, k) for k in ('data', 'memory', 'series', 'candles')}
        for p in self.P.values():
            os.makedirs(p, exist_ok=True)
        self.portfolio = os.path.join(self.dir, 'portfolio.json')
        self.old_env = {}
        self._set_env()
        src = os.path.join(C.ROOT, 'agent_memory')
        shutil.copy(os.path.join(src, 'Правила агента.md'), self.P['memory'])
        os.makedirs(os.path.join(self.P['memory'], 'Уроки'), exist_ok=True)
        self.write_portfolio()
        self.last_day = last_day
        for a in C.UNIVERSE:
            self.write_daily(a, weekdays_back(last_day, 80))
            self.write_hourly(a, [], bake=None)

    def _set_env(self):
        env = {'AI_AGENT_DATA_DIR': self.P['data'], 'AI_AGENT_MEMORY_DIR': self.P['memory'],
               'AI_AGENT_SERIES_DIR': self.P['series'], 'AI_AGENT_CANDLES_DIR': self.P['candles'],
               'AI_AGENT_RF_PORTFOLIO': os.path.join(self.dir, 'portfolio.json'),
               'AI_AGENT_TWIN_TRADES': os.path.join(self.dir, 'rf_trades.json')}
        for k, v in env.items():
            self.old_env[k] = os.environ.get(k)
            os.environ[k] = v

    def close(self):
        for k, v in self.old_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.dir, ignore_errors=True)

    def write_portfolio(self, active=None, fronts=None):
        active = active or dict(CONTRACT)
        fronts = fronts or dict(CONTRACT)
        with open(self.portfolio, 'w', encoding='utf-8-sig') as f:
            json.dump({'active': active, 'fronts': {a: {'secid': s} for a, s in fronts.items()}}, f)

    def write_daily(self, a, days, drift=0.001):
        bars, px = [], BASE[a]
        for i, d in enumerate(days):
            o = px
            c = px * (1 + drift * (1 if i % 3 else -1))
            h, l = max(o, c) * 1.004, min(o, c) * 0.996
            bars.append({'t': T.msk_to_ms(dt.datetime.combine(d, dt.time())), 'o': _snap(a, o), 'h': _snap(a, h),
                         'l': _snap(a, l), 'c': _snap(a, c), 'v': 1000})
            px = c
        with open(os.path.join(self.P['series'], a + '.json'), 'w', encoding='utf-8-sig') as f:
            json.dump(bars, f)
        return bars

    def daily(self, a):
        with open(os.path.join(self.P['series'], a + '.json'), encoding='utf-8-sig') as f:
            return json.load(f)

    def append_daily(self, a, bar):
        b = self.daily(a) + [bar]
        with open(os.path.join(self.P['series'], a + '.json'), 'w', encoding='utf-8-sig') as f:
            json.dump(b, f)

    def write_hourly(self, a, rows, bake):
        """rows: [(datetime начала, o, h, l, c)]; bake — когда файл «испечён» (MSK) -> mtime."""
        p = os.path.join(self.P['candles'], a + '_1h.json')
        with open(p, 'w', encoding='utf-8') as f:
            json.dump([[T.msk_to_ms(t), o, h, l, c, 100] for t, o, h, l, c in rows], f)
        if bake is not None:
            ts = (bake - dt.timedelta(hours=T.MSK_UTC_HOURS) - T.EPOCH).total_seconds()
            os.utime(p, (ts, ts))

    def flat_hours(self, a, start, n, px=None):
        px = px if px is not None else self.daily(a)[-1]['c']
        return [(start + dt.timedelta(hours=i), px, px, px, px) for i in range(n)]


def trade_resp(actions=(), summary='тест', skips=()):
    return {'regime': {'rub': 'range', 'metals': 'trend', 'energy': 'trend', 'index': 'unclear'},
            'summary': summary, 'actions': list(actions), 'skips': list(skips)}


def enter(inst, side='long', order='market', limit=None, stop=None, target=None, setup='pullback', horizon=5):
    return {'instrument': inst, 'action': 'enter', 'side': side, 'order': order, 'limit_px': limit,
            'stop_px': stop, 'target_px': target, 'horizon_days': horizon, 'setup': setup, 'close_kind': None,
            'tag': None, 'reason': 'тестовый вход', 'invalidation': 'уход ниже стопа'}


def act(inst, action, **kw):
    base = {'instrument': inst, 'action': action, 'side': None, 'order': None, 'limit_px': None, 'stop_px': None,
            'target_px': None, 'horizon_days': None, 'setup': None, 'close_kind': None, 'tag': None, 'reason': 'тест',
            'invalidation': None}
    base.update(kw)
    return base
