"""Этап 7: сравнение с двойником C3b и тексты для Telegram."""
import os
import unittest

from ai_agent import market, report
from ai_agent import config as C

ROOT = C.ROOT
SERIES = os.path.join(ROOT, 'data', 'live_rf', 'series')
TWIN = os.path.join(ROOT, 'data', 'rf', 'rf_trades.json')


class TestCompare(unittest.TestCase):
    def test_twin_filter_and_metrics_on_repo_data(self):
        twin = market.read_json(TWIN, [])
        if not twin:
            self.skipTest('нет data/rf/rf_trades.json')
        agent_trades = [
            {'instrument': 'BR', 'entry_day': '2026-09-01', 'setup': 'pullback', 'r': 2.0},
            {'instrument': 'Si', 'entry_day': '2026-09-02', 'setup': 'catalyst', 'r': -1.0},
        ]
        c = report.compare(agent_trades, twin, SERIES, '2026-07-01')
        exp = [t for t in twin if t['profile'] == 'C3b' and t['sym'] in C.UNIVERSE]
        self.assertEqual(c['twin_all']['n'], len([t for t in exp if t.get('rMultiple') is not None]))
        self.assertAlmostEqual(c['twin_all']['sum_r'], sum(t['rMultiple'] for t in exp if t.get('rMultiple') is not None))
        self.assertTrue(all(t['sym'] not in ('SBRF', 'VTBR', 'COCOA') for t in exp))
        self.assertEqual(c['agent']['n'], 2)
        self.assertEqual(c['agent']['avg_win'], 2.0)
        self.assertEqual(c['by_setup']['catalyst'], {'n': 1, 'sum_r': -1.0})
        self.assertIsNotNone(c['agent']['late_share'])
        md = report.compare_md(c, '2026-W41', (1.23, 12.5))
        self.assertIn('| Сумма R | +1.00 |', md)
        self.assertIn('Агент эти цифры не видит', md)
        self.assertIn('поздних входов', report.compare_tg(c, '2026-W41', (1.23, 12.5)))

    def test_entry_er_uses_bar_before_entry(self):
        cache = {}
        bars = market.load_daily(SERIES, 'BR')
        if len(bars) < 30:
            self.skipTest('нет ряда BR')
        day = bars[-1]['day']
        self.assertAlmostEqual(report.entry_er(SERIES, 'BR', day, cache), market.er(bars, len(bars) - 2))

    def test_event_lines(self):
        self.assertIn('СТОП-КРАН', report.event_line({'kind': 'halt', 'reason': 'сумма -5.2R'}))
        t = {'side': 'long', 'exit_px': 97.0, 'exit_reason': 'trail', 'r': 1.4}
        self.assertIn('страховочный трейл, +1.40R', report.event_line({'kind': 'exit', 'instrument': 'BR', 'trade': t}))


if __name__ == '__main__':
    unittest.main()
