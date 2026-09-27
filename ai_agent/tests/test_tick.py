"""Этап 4: тик целиком на синтетическом рынке и мок-модели."""
import datetime as dt
import json
import os
import unittest

from ai_agent import agent, budget, llm, scheduler, events
from ai_agent import config as C
from ai_agent import timeutil as T
from ai_agent.tests.fixture import Env, act, enter, trade_resp

D = dt.date(2026, 10, 7)          # среда; бар вторника 06.10 — последний в рядах


def at(h, m=0, day=D):
    return dt.datetime.combine(day, dt.time(h, m))


class Mock:
    def __init__(self, trade=None, news_text='NONE', fail=False):
        self.trade, self.news_text, self.fail = trade, news_text, fail
        self.calls = []

    def __call__(self, messages, schema_name):
        self.calls.append(schema_name)
        if schema_name == 'news':
            return self.news_text
        if self.fail:
            raise llm.LLMError('таймаут')
        if schema_name == 'trade':
            r = self.trade(messages) if callable(self.trade) else self.trade
            return r or trade_resp()
        return {'review': 'разбор', 'lessons': []}


class Base(unittest.TestCase):
    def setUp(self):
        self.env = Env()
        self.old_mock = llm.MOCK
        self.P = C.paths()

    def tearDown(self):
        llm.MOCK = self.old_mock
        self.env.close()

    def mock(self, **kw):
        m = Mock(**kw)
        llm.MOCK = m
        return m

    def state(self):
        return agent.load_state(self.P['state'])

    def hours(self, a, first, n, px=None, bake=None):
        rows = self.env.flat_hours(a, first, n, px)
        self.env.write_hourly(a, rows, bake or rows[-1][0] + dt.timedelta(hours=1, minutes=10))


class TestMainFlow(Base):
    def test_main_decides_orders_fill_and_journal(self):
        br = self.env.daily('BR')[-1]['c']
        m = self.mock(trade=trade_resp([enter('BR', stop=round(br * 0.97, 2), target=round(br * 1.06, 2))]))
        for a in C.UNIVERSE:
            self.hours(a, at(7, 0, dt.date(2026, 10, 6)), 10, bake=at(0, 10))
        res = agent.tick(at(0, 25))
        self.assertEqual([k for k, _ in res['ran']], ['main:2026-10-06'])
        s = self.state()
        self.assertEqual(len(s['orders']), 1)
        self.assertEqual(s['last_main_day'], '2026-10-06')
        self.assertIn('trade', m.calls)
        dec = [json.loads(x) for x in open(self.P['decisions'], encoding='utf-8')]
        self.assertEqual(dec[0]['id'], 'main:2026-10-06')
        self.assertTrue(os.path.exists(os.path.join(self.P['memory'], 'Журнал', '2026-10-07.md')))
        self.assertTrue(budget.rows(self.P['usage']))
        # повторный тик: разбор не повторяется
        self.assertEqual(agent.tick(at(0, 30))['ran'], [])
        # утренний бар 07:00 исполняет заявку
        self.hours('BR', at(7), 2, px=br, bake=at(9, 10))
        agent.tick(at(9, 15))
        s = self.state()
        self.assertEqual(len(s['positions']), 1)
        self.assertAlmostEqual(s['positions'][0]['entry'], round(br * (1 + C.SLIP), 6))

    def test_crash_after_call_does_not_pay_twice(self):
        m = self.mock(trade=trade_resp([enter('GOLD', stop=3800.0, target=4400.0)]))
        for a in C.UNIVERSE:
            self.hours(a, at(7, 0, dt.date(2026, 10, 6)), 10, bake=at(0, 10))
        before = agent.load_state(self.P['state'])
        agent.write_json(self.P['state'], before)
        agent.tick(at(0, 25))
        self.assertEqual(m.calls.count('trade'), 1)
        # «падение» после вызова модели: состояние откатилось к прежнему, ответ сохранён в calls/
        agent.write_json(self.P['state'], before)
        agent.tick(at(0, 30))
        self.assertEqual(m.calls.count('trade'), 1, 'повторный запуск не должен звать модель')
        self.assertEqual(len(self.state()['orders']), 1)
        self.assertEqual(len([r for r in budget.rows(self.P['usage']) if r.get('kind') == 'trade']), 1)

    def test_model_failure_no_entries_then_alert_after_retries(self):
        self.mock(fail=True)
        for i, t in enumerate((at(0, 25), at(0, 30), at(0, 35))):
            agent.tick(t)
            s = self.state()
            self.assertEqual(s['orders'], [])
            if i < 2:
                self.assertNotIn('main:2026-10-06', s['done'])
        self.assertIn('main:2026-10-06', self.state()['done'])
        log = open(self.P['log'], encoding='utf-8').read()
        self.assertIn('АЛЕРТ', log)

    def test_budget_exhausted_skips_call(self):
        m = self.mock(trade=trade_resp())
        budget.record(self.P['usage'], {'ts': '2026-10-01 00:25', 'cost_usd': 12.49})
        agent.tick(at(0, 25))
        self.assertNotIn('trade', m.calls)
        self.assertIn('бюджет', open(self.P['log'], encoding='utf-8').read())

    def test_halt_file_skips_everything(self):
        m = self.mock(trade=trade_resp())
        os.makedirs(self.P['data'], exist_ok=True)
        open(self.P['halt'], 'w').close()
        self.assertTrue(agent.tick(at(0, 25)).get('halt'))
        self.assertEqual(m.calls, [])

    def test_halt_entries_file_rejects_enter(self):
        self.mock(trade=trade_resp([enter('GOLD', stop=3800.0, target=4400.0)]))
        for a in C.UNIVERSE:
            self.hours(a, at(7, 0, dt.date(2026, 10, 6)), 10, bake=at(0, 10))
        os.makedirs(self.P['data'], exist_ok=True)
        open(self.P['halt_entries'], 'w').close()
        agent.tick(at(0, 25))
        self.assertEqual(self.state()['orders'], [])
        dec = [json.loads(x) for x in open(self.P['decisions'], encoding='utf-8')]
        self.assertIn('HALT', dec[0]['rejected'][0]['why'])


class TestSessionPoints(Base):
    def _done_main(self):
        s = self.state()
        s['last_main_day'] = '2026-10-06'
        agent.write_json(self.P['state'], s)

    def test_eu_open_skipped_when_nothing_to_decide(self):
        m = self.mock(news_text='NONE')
        self._done_main()
        agent.tick(at(10, 6))
        self.assertIn('eu_open:2026-10-07', self.state()['done'])
        self.assertNotIn('trade', m.calls)
        self.assertIn('news', m.calls)

    def test_eu_open_runs_on_high_news(self):
        m = self.mock(news_text='2026-10-07|09:50|BR|Атака дронов на НПЗ в Персидском заливе|reuters.com')
        self._done_main()
        agent.tick(at(10, 6))
        self.assertIn('trade', m.calls)

    def test_evening_runs_when_position_open(self):
        m = self.mock()
        self._done_main()
        s = self.state()
        s['positions'].append({'id': 'A1', 'instrument': 'BR', 'side': 'long', 'setup': 'pullback', 'entry': 100.0,
                               'entry_at': '2026-10-06 07:00', 'entry_day': '2026-10-06', 'qty': 0.1, 'qty_initial': 0.1,
                               'stop': 97.0, 'initial_stop': 97.0, 'stop_src': 'initial', 'target': 106.0, 'best': 100.0,
                               'risk_amt': 0.5, 'entry_fee': 0.0, 'fees': 0.0, 'realized': 0.0, 'rolls': 0,
                               'horizon_days': 5, 'reason': 'x', 'invalidation': 'y', 'order': 'market',
                               'pending_close': None})
        agent.write_json(self.P['state'], s)
        agent.tick(at(23, 36))
        self.assertIn('trade', m.calls)
        self.assertIn('evening:2026-10-07', self.state()['done'])


class TestScheduler(unittest.TestCase):
    def test_week(self):
        cal = events.load(C.paths()['calendar'])
        state = {'done': {}, 'last_main_day': '2026-10-26'}
        daily = {'BR': [{'day': '2026-10-26'}]}
        seen = []
        t = dt.datetime(2026, 10, 27, 0, 0)          # вторник после перехода Европы на зимнее время
        while t < dt.datetime(2026, 11, 1, 0, 0):
            for it in scheduler.due(state, t, daily, cal):
                state['done'][it['key']] = T.fmt(t)
                seen.append((T.fmt(t), it['key']))
            t += dt.timedelta(minutes=5)
        keys = dict((k, v) for v, k in seen)
        self.assertEqual(keys['eu_open:2026-10-27'], '2026-10-27 11:05')      # Лондон уже зимний
        self.assertEqual(keys['us_open:2026-10-27'], '2026-10-27 16:35')      # Нью-Йорк ещё летний
        self.assertEqual(keys['event:fomc:2026-10-28'], '2026-10-28 21:05')
        self.assertEqual(keys['event:eia_crude:2026-10-28'], '2026-10-28 17:35')
        self.assertIn('weekly:2026-W44', keys)
        self.assertNotIn('asia:2026-10-31', keys)                           # суббота
        self.assertEqual(sum(1 for k in keys if k.startswith('asia:')), 4)  # вт-пт

    def test_main_by_new_bar_not_clock(self):
        cal = events.load(C.paths()['calendar'])
        state = {'done': {}, 'last_main_day': '2026-10-09'}
        sat = dt.datetime(2026, 10, 10, 0, 25)
        self.assertEqual(scheduler.due(state, sat, {'BR': [{'day': '2026-10-09'}]}, cal), [])
        mon = dt.datetime(2026, 10, 12, 0, 25)
        due = scheduler.due(state, mon, {'BR': [{'day': '2026-10-09'}, {'day': '2026-10-09'}][:1] + [{'day': '2026-10-10'}]}, cal)
        self.assertEqual(due[0]['key'], 'main:2026-10-10')

    def test_missing_bar_alert(self):
        cal = events.load(C.paths()['calendar'])
        st = {'done': {}}
        self.assertIsNone(scheduler.missing_bar_alert(st, dt.datetime(2026, 10, 8, 1, 55), {'BR': [{'day': '2026-10-06'}]}, cal))
        self.assertIn('2026-10-07', scheduler.missing_bar_alert(st, dt.datetime(2026, 10, 8, 2, 5), {'BR': [{'day': '2026-10-06'}]}, cal))
        self.assertIsNone(scheduler.missing_bar_alert(st, dt.datetime(2026, 10, 8, 2, 10), {'BR': [{'day': '2026-10-06'}]}, cal))
        # понедельник ждёт пятничный бар
        st = {'done': {}}
        self.assertIsNone(scheduler.missing_bar_alert(st, dt.datetime(2026, 10, 12, 2, 5), {'BR': [{'day': '2026-10-09'}]}, cal))
        # 5 ноября ждёт бар 3 ноября: 4 ноября — праздничная сессия
        st = {'done': {}}
        self.assertIsNone(scheduler.missing_bar_alert(st, dt.datetime(2026, 11, 5, 2, 5), {'BR': [{'day': '2026-11-03'}]}, cal))


class TestRollAndFallback(Base):
    def test_roll_rescales_position(self):
        self.mock()
        s = self.state()
        s['last_main_day'] = '2026-10-06'
        s['positions'].append({'id': 'A1', 'instrument': 'NG', 'side': 'long', 'setup': 'pullback', 'entry': 3.0,
                               'entry_at': '2026-10-05 07:00', 'entry_day': '2026-10-05', 'qty': 10.0, 'qty_initial': 10.0,
                               'stop': 2.9, 'initial_stop': 2.9, 'stop_src': 'initial', 'target': 3.3, 'best': 3.0,
                               'risk_amt': 0.5, 'entry_fee': 0.0, 'fees': 0.0, 'realized': 0.0, 'rolls': 0,
                               'horizon_days': 5, 'reason': 'x', 'invalidation': 'y', 'order': 'market', 'pending_close': None})
        agent.write_json(self.P['state'], s)
        agent.tick(at(0, 5))                                  # запомнили ref ряда
        stop0 = self.state()['positions'][0]['stop']          # мог уже подтянуться трейлом
        bars = self.env.daily('NG')
        for b in bars:
            for f in 'ohlc':
                b[f] = round(b[f] * 1.05, 6)
        with open(os.path.join(self.P_series(), 'NG.json'), 'w', encoding='utf-8') as f:
            json.dump(bars, f)
        self.env.write_portfolio(active=dict(self.env_contracts(), NG='NGX6'), fronts=dict(self.env_contracts(), NG='NGV6'))
        res = agent.tick(at(0, 10))
        p = self.state()['positions'][0]
        self.assertAlmostEqual(p['stop'], round(stop0 * 1.05, 6), places=5)
        self.assertEqual(p['rolls'], 1)
        self.assertTrue(any(e['kind'] == 'roll' for e in res['events']))

    def P_series(self):
        return os.environ['AI_AGENT_SERIES_DIR']

    def env_contracts(self):
        from ai_agent.tests.fixture import CONTRACT
        return CONTRACT


if __name__ == '__main__':
    unittest.main()
