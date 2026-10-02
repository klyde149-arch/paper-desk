"""Dashboard projection: MTM is informative only and never mutates trading state."""
import datetime as dt
import unittest

from ai_agent import agent, book


NOW = dt.datetime(2026, 10, 7, 12, 0)


def position(asset, side, entry, qty=1.0, risk=5.0, entry_fee=0.1, realized=0.0):
    return {'instrument': asset, 'side': side, 'entry': entry, 'qty': qty,
            'risk_amt': risk, 'entry_fee': entry_fee, 'realized': realized}


def market(asset, price, age_min=10, ok=True):
    return {asset: {'hourly_ok': ok, 'last_px': price,
                    'last_px_at': NOW - dt.timedelta(minutes=age_min) if ok else None}}


class TestMarkToMarket(unittest.TestCase):
    def test_long_includes_entry_fee_once(self):
        s = book.new_state()
        s['equity'] = 99.9                  # entry fee already charged by the ledger
        s['positions'] = [position('BR', 'long', 100.0)]
        mark = agent.mark_to_market(s, market('BR', 103.0), NOW)
        self.assertAlmostEqual(mark['equity_mtm'], 102.9)
        self.assertAlmostEqual(mark['open_pnl'], 2.9)
        self.assertAlmostEqual(mark['marks']['BR']['r'], 0.58)

    def test_short_and_realized_roll_component(self):
        s = book.new_state()
        s['equity'] = 101.9
        s['positions'] = [position('Si', 'short', 85000.0, qty=0.01, risk=10.0,
                                    entry_fee=0.1, realized=2.0)]
        mark = agent.mark_to_market(s, market('Si', 84800.0, age_min=35), NOW)
        self.assertAlmostEqual(mark['equity_mtm'], 103.9)
        self.assertAlmostEqual(mark['open_pnl'], 3.9)
        self.assertEqual(mark['marks']['Si']['quote_age_min'], 35.0)

    def test_missing_quote_refuses_aggregate_mtm(self):
        s = book.new_state()
        s['positions'] = [position('Eu', 'short', 98000.0)]
        mark = agent.mark_to_market(s, {}, NOW)
        self.assertIsNone(mark['equity_mtm'])
        self.assertIsNone(mark['open_pnl'])
        self.assertEqual(mark['missing'], ['Eu'])
        self.assertFalse(mark['marks']['Eu']['ok'])

    def test_stale_quote_refuses_aggregate_mtm(self):
        s = book.new_state()
        s['positions'] = [position('Eu', 'short', 98000.0)]
        stale = {'Eu': {'hourly_ok': False, 'last_px': 97000.0,
                        'last_px_at': NOW - dt.timedelta(days=5)}}
        mark = agent.mark_to_market(s, stale, NOW)
        self.assertIsNone(mark['equity_mtm'])
        self.assertEqual(mark['missing'], ['Eu'])

    def test_no_positions_equals_realized_equity(self):
        s = book.new_state()
        s['equity'] = 101.25
        mark = agent.mark_to_market(s, {}, NOW)
        self.assertEqual(mark['equity_mtm'], 101.25)
        self.assertEqual(mark['open_pnl'], 0.0)


if __name__ == '__main__':
    unittest.main()
