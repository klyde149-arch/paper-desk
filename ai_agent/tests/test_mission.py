"""Правила v0.2: отказы (skips), молчаливый пропуск тренда, event_tighten, упущенное."""
import datetime as dt
import json
import os
import tempfile
import unittest

from ai_agent import book, decide, review
from ai_agent import config as C
from ai_agent import timeutil as T
from ai_agent.tests.fixture import act, enter
from ai_agent.tests.test_decide_snapshot import vctx

TREND_METALS = {'rub': 'range', 'metals': 'trend', 'energy': 'range', 'index': 'range'}
OK_ALL = {a: True for a in C.UNIVERSE}


def _bar(day, o, h, l, c):
    return {'t': T.msk_to_ms(dt.datetime.combine(dt.date.fromisoformat(day), dt.time())),
            'o': o, 'h': h, 'l': l, 'c': c, 'v': 1}


def _write_series(d, asset, rows):
    with open(os.path.join(d, asset + '.json'), 'w', encoding='utf-8-sig') as f:
        json.dump([_bar(*r) for r in rows], f)


class TestSkips(unittest.TestCase):
    def test_clean_skips(self):
        resp = {'skips': [{'instrument': 'GOLD', 'side': 'short', 'reason': '  R/R  хуже 1:2 '},
                          {'instrument': 'GOLD', 'side': 'short', 'reason': 'дубль'},
                          {'instrument': 'XXX', 'side': 'long', 'reason': 'чужой'},
                          {'instrument': 'BR', 'side': 'long', 'reason': ''}]}
        self.assertEqual(decide.clean_skips(resp), [{'instrument': 'GOLD', 'side': 'short', 'reason': 'R/R хуже 1:2'}])
        self.assertEqual(decide.clean_skips({'actions': []}), [])      # старый ответ без skips

    def test_silent_trend(self):
        st = book.new_state()
        allowed = set(C.UNIVERSE)
        self.assertEqual(decide.silent_skips(TREND_METALS, st, [], allowed, OK_ALL), ['metals'])
        skip = [{'instrument': 'SILV', 'side': 'short', 'reason': 'стоп > 2 ATR'}]
        self.assertEqual(decide.silent_skips(TREND_METALS, st, skip, allowed, OK_ALL), [])
        acc = [enter('GOLD', side='short', stop=4100, target=3800)]
        self.assertEqual(decide.silent_skips(TREND_METALS, st, [], allowed, OK_ALL, accepted=acc), [])

    def test_silent_not_counted_when_entry_impossible(self):
        st = book.new_state()
        no_metals = dict(OK_ALL, GOLD=False, SILV=False)
        self.assertEqual(decide.silent_skips(TREND_METALS, st, [], set(C.UNIVERSE), no_metals), [])
        self.assertEqual(decide.silent_skips(TREND_METALS, st, [], {'BR', 'Si'}, OK_ALL), [])
        self.assertEqual(decide.silent_skips(TREND_METALS, st, [], set(C.UNIVERSE), OK_ALL, entries_blocked='HALT'), [])

    def test_cancel_frees_group(self):
        st = book.new_state()
        st['orders'].append({'instrument': 'GOLD', 'id': 'O1'})
        self.assertEqual(decide.silent_skips(TREND_METALS, st, [], set(C.UNIVERSE), OK_ALL), [])
        acc = [act('GOLD', 'cancel')]
        self.assertEqual(decide.silent_skips(TREND_METALS, st, [], set(C.UNIVERSE), OK_ALL, accepted=acc), ['metals'])


class TestEventTighten(unittest.TestCase):
    def _state_with_short(self):
        st = book.new_state()
        o = {'instrument': 'Eu', 'side': 'short', 'order': 'market', 'stop_px': 98000.0, 'target_px': 94000.0,
             'setup': 'early_breakout', 'horizon_days': 5}
        book._open(st, o, 97000.0, dt.datetime(2026, 9, 30, 10, 0))
        return st

    def test_tag_only_on_modify(self):
        st = self._state_with_short()
        # vctx: последняя цена Eu 98000, исходный стоп шорта 98000 — подтягиваем выше цены нельзя,
        # поэтому позиция с более широким стопом
        book.position(st, 'Eu')['stop'] = 99500.0
        ok, bad = decide.validate({'actions': [act('Eu', 'modify', stop_px=99000, tag='event_tighten')]},
                                  vctx(state=st, point='asia'))
        self.assertEqual(ok[0]['tag'], 'event_tighten', bad)
        e = enter('BR', stop=97, target=106)
        e['tag'] = 'event_tighten'
        ok, _ = decide.validate({'actions': [e]}, vctx())
        self.assertIsNone(ok[0]['tag'])

    def test_tighten_recorded_and_reaches_trade(self):
        st = self._state_with_short()
        at = dt.datetime(2026, 10, 2, 10, 5)
        ev = book.modify_position(st, 'Eu', 97300, None, 'eu_open:2026-10-02', tag='event_tighten', at=at)
        self.assertEqual(ev[0]['tag'], 'event_tighten')
        book.modify_position(st, 'Eu', 97200, None, 'x')                 # без пометки — не в списке
        p = book.position(st, 'Eu')
        self.assertEqual(p['tightens'], [{'at': '2026-10-02 10:05', 'from': 98000.0, 'to': 97300.0,
                                          'decision_id': 'eu_open:2026-10-02'}])
        book.close_position(st, p, 97200.0, dt.datetime(2026, 10, 2, 16, 0), 'stop_moved')
        tr = st['trades'][-1]
        self.assertEqual(tr['tightens'][0]['from'], 98000.0)
        self.assertEqual(tr['target'], 94000.0)


class TestReview(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix='ai-agent-review-')

    def test_simulate(self):
        bars = [_bar('2026-10-01', 100, 101, 99, 100), _bar('2026-10-02', 100, 104, 99.5, 103)]
        for b in bars:
            b['day'] = T.ms_to_msk(b['t']).date().isoformat()
        r = review.simulate(bars, 0, 'long', 100, 98, 104, 5)
        self.assertEqual((r['outcome'], r['r']), ('target', 2.0))
        r = review.simulate(bars, 0, 'short', 100, 102, 90, 5)
        self.assertEqual((r['outcome'], r['r']), ('stop', -1.0))
        r = review.simulate(bars, 0, 'long', 100, 98, None, 2)
        self.assertEqual((r['outcome'], r['r'], r['mfe']), ('horizon', 1.5, 2.0))
        self.assertIsNone(review.simulate(bars, 0, 'long', 100, 101, None, 2))   # стоп за ценой

    def test_missed_counts_repeated_idea_once(self):
        # золото падает, шорт-лимитки на откат каждый день не исполняются
        rows = [('2026-09-%02d' % d, 4400 - 10 * i, 4405 - 10 * i, 4380 - 10 * i, 4390 - 10 * i)
                for i, d in enumerate(range(1, 30))]
        rows += [('2026-09-30', 4120, 4130, 4090, 4100), ('2026-10-01', 4100, 4110, 4050, 4060),
                 ('2026-10-02', 4060, 4070, 4000, 4010)]
        _write_series(self.dir, 'GOLD', rows)
        dec = [{'id': 'main:2026-09-29', 'at': '2026-09-30 00:20', 'accepted': [
                    dict(enter('GOLD', side='short', order='limit', limit=4200, stop=4250, target=3900), horizon_days=5)]},
               {'id': 'main:2026-09-30', 'at': '2026-10-01 00:20', 'accepted': [
                    dict(enter('GOLD', side='short', order='limit', limit=4180, stop=4240, target=3900), horizon_days=5)]},
               {'id': 'main:2026-10-01', 'at': '2026-10-02 00:20', 'accepted': [],
                'skips': [{'instrument': 'GOLD', 'side': 'short', 'reason': 'далеко от уровня'}]}]
        out = review.missed(dec, book.new_state(), self.dir, '2026-09-28')
        self.assertEqual(len(out), 1, out)                   # одна идея, а не три
        m = out[0]
        self.assertEqual((m['kind'], m['ref'], m['outcome']), ('order', 4120, 'open'))
        self.assertAlmostEqual(m['r'], (4120 - 4010) / (4250 - 4120), places=2)
        self.assertIn('Сумма', review.missed_md(out))

    def test_filled_order_not_missed(self):
        _write_series(self.dir, 'Eu', [('2026-09-30', 97000, 97500, 96500, 96800)])
        dec = [{'id': 'main:2026-09-29', 'at': '2026-09-30 00:20', 'accepted': [
            enter('Eu', side='short', order='limit', limit=97100, stop=98000, target=94800)]}]
        st = book.new_state()
        st['trades'].append({'decision_id': 'main:2026-09-29', 'instrument': 'Eu'})
        self.assertEqual(review.missed(dec, st, self.dir, '2026-09-28'), [])

    def test_tighten_review(self):
        _write_series(self.dir, 'Si', [('2026-10-01', 84700, 84900, 84200, 84300),
                                       ('2026-10-02', 84300, 85200, 84200, 85100),
                                       ('2026-10-05', 85100, 85600, 85000, 85500)])
        tr = {'id': 'A9', 'instrument': 'Si', 'side': 'short', 'entry': 84700, 'initial_stop': 85450,
              'entry_day': '2026-10-01', 'exit_at': '2026-10-02 16:00', 'exit_px': 85142.55,
              'exit_reason': 'stop_moved', 'horizon_days': 5, 'target': 82600,
              'tightens': [{'at': '2026-10-02 00:20', 'from': 85450, 'to': 85100}]}
        out = review.tighten_review([tr], self.dir)
        self.assertEqual(out[0]['outcome'], 'stop')           # 05.10 high 85600 задел старый стоп
        self.assertEqual(out[0]['old_r'], -1.0)
        self.assertAlmostEqual(out[0]['actual_r'], -0.59, places=2)
        self.assertIn('принесла', review.tighten_md(out))


if __name__ == '__main__':
    unittest.main()
