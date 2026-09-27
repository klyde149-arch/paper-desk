"""Этап 2: бумажный рукав — исполнение, стопы, трейл, роллы, рамки, R."""
import datetime as dt
import unittest

from ai_agent import book
from ai_agent import config as C

DEC = dt.datetime(2026, 10, 5, 0, 20)     # главный разбор


def bar(h_msk, o, h, l, c, day=DEC.date()):
    return {'t': dt.datetime.combine(day, dt.time(h_msk)), 'o': o, 'h': h, 'l': l, 'c': c}


def order(inst='BR', side='long', kind='market', limit=None, stop=95.0, target=110.0, at=DEC, setup='pullback'):
    return {'instrument': inst, 'side': side, 'order': kind, 'limit_px': limit, 'stop_px': stop,
            'target_px': target, 'horizon_days': 10, 'setup': setup, 'reason': 'тест',
            'invalidation': 'ниже 95', 'decided_at': at, 'decision_id': 'D1', 'memory_version': 'm0'}


class TestFills(unittest.TestCase):
    def setUp(self):
        self.s = book.new_state()

    def test_market_fills_at_first_bar_after_decision_with_slippage(self):
        book.place_order(self.s, order(at=dt.datetime(2026, 10, 5, 10, 5)))
        book.process_bar(self.s, 'BR', bar(10, 100, 101, 99.5, 100.5))    # начался до решения
        self.assertEqual(self.s['positions'], [])
        ev = book.process_bar(self.s, 'BR', bar(11, 100, 101, 99.5, 100.5))
        p = self.s['positions'][0]
        self.assertAlmostEqual(p['entry'], 100 * (1 + C.SLIP))
        self.assertEqual(ev[0]['kind'], 'fill')
        # риск ровно 0,5% капитала, комиссия списана
        self.assertAlmostEqual(p['qty'] * (p['entry'] - 95.0), C.START_EQUITY * C.RISK_PCT, places=6)
        self.assertAlmostEqual(self.s['equity'], C.START_EQUITY - p['qty'] * p['entry'] * C.FEE)

    def test_limit_touch_does_not_fill_through_one_tick_does(self):
        book.place_order(self.s, order(kind='limit', limit=98.0))
        book.process_bar(self.s, 'BR', bar(7, 99, 99.5, 98.0, 99))          # касание
        self.assertEqual(self.s['positions'], [])
        book.process_bar(self.s, 'BR', bar(8, 99, 99.5, 97.99, 99))         # проход на шаг 0.01
        self.assertAlmostEqual(self.s['positions'][0]['entry'], 98.0)

    def test_limit_gap_fills_at_better_open(self):
        book.place_order(self.s, order(kind='limit', limit=98.0))
        book.process_bar(self.s, 'BR', bar(7, 97.5, 97.8, 97.2, 97.6))
        self.assertAlmostEqual(self.s['positions'][0]['entry'], 97.5)

    def test_order_expires_end_of_day(self):
        book.place_order(self.s, order(kind='limit', limit=90.0))
        self.assertEqual(self.s['orders'][0]['valid_until'], '2026-10-05 23:50')
        ev = book.expire_orders(self.s, dt.datetime(2026, 10, 5, 23, 55))
        self.assertEqual([e['kind'] for e in ev], ['expire'])
        self.assertEqual(self.s['orders'], [])

    def test_evening_order_valid_next_day(self):
        self.assertEqual(book.order_valid_until(dt.datetime(2026, 10, 5, 23, 35)),
                         dt.datetime(2026, 10, 6, 23, 50))

    def test_replace_order_same_instrument(self):
        book.place_order(self.s, order(kind='limit', limit=98.0))
        ev = book.place_order(self.s, order(kind='limit', limit=97.0))
        self.assertEqual(len(self.s['orders']), 1)
        self.assertEqual(self.s['orders'][0]['limit_px'], 97.0)
        self.assertEqual(ev[0]['kind'], 'replace')

    def test_open_beyond_stop_cancels(self):
        book.place_order(self.s, order(stop=95.0))
        ev = book.process_bar(self.s, 'BR', bar(7, 94.0, 94.5, 93.0, 94))
        self.assertEqual(self.s['positions'], [])
        self.assertEqual(ev[-1]['kind'], 'cancel')

    def test_leverage_cap(self):
        book.place_order(self.s, order(stop=99.9))               # стоп 0,1% -> номинал 5x -> срез до 3x
        book.process_bar(self.s, 'BR', bar(7, 100, 100.05, 99.95, 100))
        p = self.s['positions'][0]
        self.assertLessEqual(p['qty'] * p['entry'], C.MAX_LEV * C.START_EQUITY + 1e-6)


class TestExits(unittest.TestCase):
    def setUp(self):
        self.s = book.new_state()
        book.place_order(self.s, order())
        book.process_bar(self.s, 'BR', bar(7, 100, 100.5, 99.5, 100))
        self.p = self.s['positions'][0]

    def test_stop_on_entry_bar(self):
        s = book.new_state()
        book.place_order(s, order())
        ev = book.process_bar(s, 'BR', bar(7, 100, 100.5, 94.0, 96))
        self.assertEqual(s['positions'], [])
        self.assertEqual(ev[-1]['trade']['exit_reason'], 'stop')

    def test_target_not_on_entry_bar(self):
        s = book.new_state()
        book.place_order(s, order(target=100.2))
        book.process_bar(s, 'BR', bar(7, 100, 101, 99.8, 100.9))
        self.assertEqual(len(s['positions']), 1)

    def test_stop_and_target_same_bar_is_stop(self):
        ev = book.process_bar(self.s, 'BR', bar(8, 100, 111, 94, 100))
        self.assertEqual(ev[-1]['trade']['exit_reason'], 'stop')

    def test_gap_stop_fills_at_open(self):
        ev = book.process_bar(self.s, 'BR', bar(8, 93, 93.5, 92, 93))
        t = ev[-1]['trade']
        self.assertAlmostEqual(t['exit_px'], round(93 * (1 - C.STOP_SLIP), 6))
        self.assertLess(t['r'], -1.0)

    def test_stop_r_about_minus_one(self):
        ev = book.process_bar(self.s, 'BR', bar(8, 99, 99, 94.5, 95))
        r = ev[-1]['trade']['r']
        self.assertLess(r, -1.0)
        self.assertGreater(r, -1.1)

    def test_target_needs_one_tick_through(self):
        book.process_bar(self.s, 'BR', bar(8, 105, 110.0, 104, 109))       # касание цели
        self.assertEqual(len(self.s['positions']), 1)
        ev = book.process_bar(self.s, 'BR', bar(9, 109, 110.01, 108, 109))
        t = ev[-1]['trade']
        self.assertEqual(t['exit_reason'], 'target')
        self.assertAlmostEqual(t['exit_px'], 110.0)
        self.assertGreater(t['r'], 1.9)

    def test_stop_only_tightens(self):
        ev = book.modify_position(self.s, 'BR', stop_px=93.0)
        self.assertEqual(self.p['stop'], 95.0)
        self.assertEqual(ev[0]['kind'], 'refused')
        book.modify_position(self.s, 'BR', stop_px=97.0)
        self.assertEqual(self.p['stop'], 97.0)
        self.assertEqual(self.p['stop_src'], 'agent')

    def test_trail_only_tightens_and_skips_entry_day(self):
        self.p['best'] = 108.0
        book.apply_trail(self.s, 'BR', 1.0, DEC.strftime('%Y-%m-%d'))
        self.assertEqual(self.p['stop'], 95.0)                               # день входа
        book.apply_trail(self.s, 'BR', 1.0, '2026-10-06')
        self.assertAlmostEqual(self.p['stop'], 105.0)
        book.apply_trail(self.s, 'BR', 5.0, '2026-10-07')                    # ATR вырос — не отодвигаем
        self.assertAlmostEqual(self.p['stop'], 105.0)
        ev = book.process_bar(self.s, 'BR', bar(8, 106, 106, 104.9, 105, dt.date(2026, 10, 7)))
        self.assertEqual(ev[-1]['trade']['exit_reason'], 'trail')

    def test_pending_close_after_decision(self):
        book.request_close(self.s, 'BR', 'idea_broken', 'пробили 98', dt.datetime(2026, 10, 5, 10, 5))
        book.process_bar(self.s, 'BR', bar(10, 101, 101, 100, 100.5))
        self.assertEqual(len(self.s['positions']), 1)
        ev = book.process_bar(self.s, 'BR', bar(11, 101, 101, 100, 100.5))
        self.assertEqual(ev[-1]['trade']['exit_reason'], 'close:idea_broken')

    def test_roll_preserves_r(self):
        s2 = book.new_state()
        book.place_order(s2, order())
        book.process_bar(s2, 'BR', bar(7, 100, 100.5, 99.5, 100))
        # одинаковое движение +5 до и после ролла с коэффициентом 1.03
        book.apply_roll(self.s, 'BR', 1.03, 100.0, DEC)
        p = self.s['positions'][0]
        self.assertAlmostEqual(p['stop'], round(95.0 * 1.03, 6))
        ev1 = book.close_position(self.s, p, 105 * 1.03, DEC, 'test')
        ev2 = book.close_position(s2, s2['positions'][0], 105, DEC, 'test')
        r_roll, r_plain = ev1[0]['trade']['r'], ev2[0]['trade']['r']
        self.assertLess(r_roll, r_plain)                  # издержки ролла
        self.assertAlmostEqual(r_roll, r_plain, delta=0.05)


class TestLimits(unittest.TestCase):
    def test_max_positions_counts_orders(self):
        s = book.new_state()
        for a in ('BR', 'GOLD', 'Si'):
            book.place_order(s, order(inst=a))
        ok, why = book.can_open(s, 'MIX')
        self.assertFalse(ok)
        self.assertIn('3', why)

    def test_group_limit(self):
        s = book.new_state()
        book.place_order(s, order(inst='Si'))
        book.place_order(s, order(inst='CNY'))
        ok, why = book.can_open(s, 'Eu')
        self.assertFalse(ok)
        self.assertIn('рубль', why)

    def test_recheck_at_fill(self):
        s = book.new_state()
        for a in ('Si', 'CNY'):
            book.place_order(s, order(inst=a, stop=80000, target=90000))
            book.process_bar(s, a, bar(7, 85000, 85100, 84900, 85000))
        # заявку по Eu поставили в обход проверки — при исполнении её должен снять движок
        book.place_order(s, order(inst='Eu', stop=95000, target=110000))
        ev = book.process_bar(s, 'Eu', bar(8, 100000, 100100, 99900, 100000))
        self.assertEqual(ev[-1]['kind'], 'cancel')
        self.assertEqual(len(s['positions']), 2)

    def test_halt_below_minus_5r(self):
        s = book.new_state()
        s['trades'] = [{'r': -1.0}] * 4
        book.place_order(s, order(inst='GOLD'))
        s['trades'].append({'r': -1.2})
        ev = book.check_halt(s, DEC)
        self.assertEqual(ev[0]['kind'], 'halt')
        self.assertEqual(s['orders'], [])
        self.assertFalse(book.can_open(s, 'BR')[0])

    def test_halt_file_blocks(self):
        self.assertFalse(book.can_open(book.new_state(), 'BR', halt_files='HALT_AGENT_ENTRIES')[0])


class TestFallback(unittest.TestCase):
    def test_daily_fallback_stop_and_cancel_orders(self):
        s = book.new_state()
        book.place_order(s, order(inst='NG', stop=2.8, target=3.3))
        book.process_bar(s, 'NG', bar(7, 3.0, 3.01, 2.99, 3.0))
        book.place_order(s, order(inst='NG', kind='limit', limit=2.9, stop=2.7, target=3.3))
        d = {'t': dt.datetime(2026, 10, 6), 'day': '2026-10-06', 'o': 2.95, 'h': 3.0, 'l': 2.75, 'c': 2.8}
        ev = book.process_daily_fallback(s, 'NG', d)
        kinds = [e['kind'] for e in ev]
        self.assertIn('cancel', kinds)
        self.assertIn('exit', kinds)
        self.assertEqual(s['orders'], [])
        self.assertGreaterEqual(s['last_bar']['NG'], 0)

    def test_fallback_skips_entry_day(self):
        s = book.new_state()
        book.place_order(s, order(inst='NG', stop=2.8, target=3.3))
        book.process_bar(s, 'NG', bar(7, 3.0, 3.01, 2.99, 3.0))
        d = {'t': dt.datetime(2026, 10, 5), 'day': '2026-10-05', 'o': 3.0, 'h': 3.0, 'l': 2.5, 'c': 2.6}
        book.process_daily_fallback(s, 'NG', d)
        self.assertEqual(len(s['positions']), 1)


if __name__ == '__main__':
    unittest.main()
