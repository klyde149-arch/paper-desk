"""Этап 3: проверка ответа модели и обезличенный снимок."""
import datetime as dt
import re
import unittest

from ai_agent import book, decide, snapshot
from ai_agent import config as C
from ai_agent.tests.fixture import act, enter

NOW = dt.datetime(2026, 10, 7, 0, 25)
PX = {'BR': 100.0, 'NG': 3.0, 'GOLD': 4000.0, 'SILV': 60.0, 'Si': 85000.0, 'CNY': 12.0, 'MIX': 250000.0, 'Eu': 98000.0}


def vctx(state=None, point='main', allowed=C.UNIVERSE, hourly_ok=True, halt=None):
    return {'state': state or book.new_state(), 'point': point, 'allowed': set(allowed), 'halt_files': halt,
            'last_px': dict(PX), 'hourly_ok': {a: hourly_ok for a in C.UNIVERSE}}


def one(resp_actions, **kw):
    ok, bad = decide.validate({'actions': resp_actions}, vctx(**kw))
    return ok, bad


class TestValidate(unittest.TestCase):
    def test_good_enter(self):
        ok, bad = one([enter('BR', stop=97, target=106)])
        self.assertEqual(len(ok), 1, bad)

    def test_stop_wrong_side(self):
        ok, bad = one([enter('BR', stop=101, target=106)])
        self.assertIn('стоп', bad[0]['why'])

    def test_short_levels(self):
        self.assertEqual(len(one([enter('GOLD', side='short', stop=4050, target=3900)])[0]), 1)
        self.assertTrue(one([enter('GOLD', side='short', stop=3950, target=3900)])[1])

    def test_limit_far_and_missing(self):
        self.assertIn('10%', one([enter('BR', order='limit', limit=80, stop=78, target=90)])[1][0]['why'])
        self.assertIn('limit_px', one([enter('BR', order='limit', stop=97, target=106)])[1][0]['why'])

    def test_typo_stop_too_far(self):
        self.assertIn('опечатку', one([enter('BR', stop=50, target=106)])[1][0]['why'])

    def test_required_fields(self):
        e = enter('BR', stop=97, target=106)
        e['setup'] = None
        self.assertIn('setup', one([e])[1][0]['why'])
        e = enter('BR', stop=97, target=106)
        e['invalidation'] = ''
        self.assertIn('invalidation', one([e])[1][0]['why'])
        e = enter('BR', stop=97, target=106, horizon=0)
        self.assertIn('горизонт', one([e])[1][0]['why'])

    def test_group_limit(self):
        s = book.new_state()
        for a in ('Si', 'CNY'):
            book.place_order(s, {'instrument': a, 'side': 'long', 'order': 'market', 'limit_px': None,
                                 'stop_px': PX[a] * 0.97, 'target_px': PX[a] * 1.05, 'horizon_days': 5,
                                 'setup': 'pullback', 'reason': 'x', 'invalidation': 'y', 'decided_at': NOW})
        ok, bad = one([enter('Eu', stop=96000, target=101000)], state=s)
        self.assertIn('рубль', bad[0]['why'])
        # замена своей же заявки лимит не съедает
        ok, bad = one([enter('Si', stop=84000, target=88000)], state=s)
        self.assertEqual(len(ok), 1, bad)

    def test_limits_count_entries_within_one_response(self):
        ok, bad = one([enter('Si', stop=84000, target=88000), enter('CNY', stop=11.8, target=12.5),
                       enter('Eu', stop=96000, target=101000)])
        self.assertEqual([a['instrument'] for a in ok], ['Si', 'CNY'])
        self.assertIn('рубль', bad[0]['why'])
        ok, bad = one([enter('BR', stop=97, target=106), enter('GOLD', stop=3900, target=4200),
                       enter('Si', stop=84000, target=88000), enter('MIX', stop=245000, target=260000)])
        self.assertEqual(len(ok), 3)
        self.assertIn('3', bad[0]['why'])

    def test_take_profit_only_on_main(self):
        s = book.new_state()
        book.place_order(s, {'instrument': 'BR', 'side': 'long', 'order': 'market', 'limit_px': None, 'stop_px': 97.0,
                             'target_px': 110.0, 'horizon_days': 5, 'setup': 'pullback', 'reason': 'x',
                             'invalidation': 'y', 'decided_at': NOW})
        book.process_bar(s, 'BR', {'t': dt.datetime(2026, 10, 7, 7), 'o': 100, 'h': 100, 'l': 100, 'c': 100})
        a = act('BR', 'close', close_kind='take_profit')
        self.assertEqual(len(one([a], state=s, point='main')[0]), 1)
        self.assertIn('прибыль', one([a], state=s, point='eu_open', allowed=('BR',))[1][0]['why'])
        self.assertEqual(len(one([act('BR', 'close', close_kind='idea_broken')], state=s, point='eu_open',
                                 allowed=('BR',))[0]), 1)
        # стоп нельзя отодвинуть
        self.assertIn('отодвигать', one([act('BR', 'modify', stop_px=95.0)], state=s)[1][0]['why'])
        self.assertEqual(len(one([act('BR', 'modify', stop_px=98.0)], state=s)[0]), 1)
        self.assertIn('close', one([act('BR', 'modify', stop_px=101.0)], state=s)[1][0]['why'])

    def test_not_allowed_duplicate_hold_unknown(self):
        ok, bad = one([enter('Si', stop=84000, target=88000)], point='eu_open', allowed=('BR', 'GOLD', 'SILV', 'Eu'))
        self.assertIn('не входит', bad[0]['why'])
        ok, bad = one([enter('BR', stop=97, target=106), enter('BR', stop=96, target=106), act('GOLD', 'hold')])
        self.assertEqual((len(ok), len(bad)), (1, 1))
        self.assertIn('второе', bad[0]['why'])
        ok, bad = one([dict(enter('BR', stop=97, target=106), instrument='XAU')])
        self.assertIn('универсум', bad[0]['why'])

    def test_no_hourly_blocks_entry(self):
        self.assertIn('часовых', one([enter('NG', stop=2.9, target=3.2)], hourly_ok=False)[1][0]['why'])

    def test_halt_blocks_entry(self):
        self.assertIn('HALT', one([enter('BR', stop=97, target=106)], halt='HALT_AGENT_ENTRIES')[1][0]['why'])

    def test_broken_structure(self):
        with self.assertRaises(ValueError):
            decide.validate({'foo': 1}, vctx())
        with self.assertRaises(ValueError):
            decide.validate(['x'], vctx())

    def test_reason_truncated(self):
        e = enter('BR', stop=97, target=106)
        e['reason'] = 'а' * 1000
        self.assertEqual(len(one([e])[0][0]['reason']), 300)

    def test_schema_is_strict_compatible(self):
        """Ограничения structured output Claude: у каждого объекта additionalProperties false, все поля
        в required, без minimum/maximum/minLength/maxLength."""
        def walk(s):
            if isinstance(s, dict):
                for bad in ('minimum', 'maximum', 'minLength', 'maxLength', 'multipleOf'):
                    self.assertNotIn(bad, s)
                if s.get('type') == 'object':
                    self.assertIs(s.get('additionalProperties'), False)
                    self.assertEqual(set(s['required']), set(s['properties']))
                for v in s.values():
                    walk(v)
            elif isinstance(s, list):
                for v in s:
                    walk(v)
        from ai_agent import weekly
        walk(decide.TRADE_SCHEMA)
        walk(weekly.WEEKLY_SCHEMA)


class TestSnapshot(unittest.TestCase):
    FORBIDDEN = ['C3b', 'C2', '₽', 'руб.', 'рублей', '2154036525', 'T-Invest', 'Т-Инвест', 'двойник', 'setA',
                 'secid', 'BRV6', 'GDZ6', 'SiZ6', 'Donchian', 'Дончиан', 'счёт №']

    def _ctx(self, state):
        bars = []
        for i in range(60):
            t = dt.datetime(2026, 8, 1) + dt.timedelta(days=i)
            bars.append({'t': t, 'day': t.strftime('%Y-%m-%d'), 'o': 100, 'h': 101, 'l': 99, 'c': 100.5, 'v': 1000})
        inst = {a: {'daily': bars, 'hourly': [], 'atr': 2.0, 'last_px': PX[a], 'last_px_at': None, 'hourly_ok': True}
                for a in C.UNIVERSE}
        from ai_agent import memory
        rules, _ = memory.load_rules(C.paths()['memory'])
        return {'now': NOW, 'point': 'main', 'allowed': list(C.UNIVERSE), 'event': None, 'instruments': inst,
                'state': state, 'rules_text': rules, 'lessons_text': '### Урок\nне входить в пятницу',
                'calendar': [], 'news': [{'date': '2026-10-06', 'time': '12:00', 'instruments': ['BR'], 'wake': True,
                                          'event': 'ОПЕК+ продлила сокращения', 'source': 'reuters.com'}],
                'journal_digest': '', 'entries_blocked': None}

    def test_no_foreign_data_in_prompt(self):
        s = book.new_state()
        book.place_order(s, {'instrument': 'BR', 'side': 'long', 'order': 'limit', 'limit_px': 99.0, 'stop_px': 97.0,
                             'target_px': 106.0, 'horizon_days': 5, 'setup': 'pullback', 'reason': 'откат',
                             'invalidation': 'ниже 97', 'decided_at': NOW})
        msgs = snapshot.build(self._ctx(s))
        text = msgs[0]['content'] + msgs[1]['content']
        for w in self.FORBIDDEN:
            self.assertNotIn(w, text, w)
        self.assertIsNone(re.search(r'\d{10}', text), 'длинные номера (счёт) в промпте')
        self.assertIn('Самостоятельный трейдер', text)          # правила агента
        self.assertIn('не входить в пятницу', text)              # принятый урок
        self.assertIn('ОПЕК+ продлила сокращения', text)
        self.assertIn('непроверенные сообщения', text)
        self.assertIn('BR лонг лимит 99.00', text)

    def test_price_formatting_by_tick(self):
        self.assertEqual(snapshot.px('Si', 85945.0), '85945')
        self.assertEqual(snapshot.px('NG', 2.9), '2.900')
        self.assertEqual(snapshot.px('GOLD', 4454.7), '4454.7')


if __name__ == '__main__':
    unittest.main()
