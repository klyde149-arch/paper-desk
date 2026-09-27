"""Этап 1: время, данные, календарь."""
import datetime as dt
import json
import os
import tempfile
import unittest

from ai_agent import config, events, market
from ai_agent import timeutil as T

D = dt.date


def bars_from(rows, start=D(2026, 9, 1)):
    out = []
    for i, (o, h, l, c) in enumerate(rows):
        t = dt.datetime.combine(start + dt.timedelta(days=i), dt.time())
        out.append({'ts': T.msk_to_ms(t), 't': t, 'day': t.strftime('%Y-%m-%d'),
                    'o': o, 'h': h, 'l': l, 'c': c, 'v': 0})
    return out


class TestDst(unittest.TestCase):
    def test_europe_open_shifts_after_oct_25(self):
        self.assertEqual(T.to_msk(D(2026, 10, 23), '08:05', 'LON'), dt.datetime(2026, 10, 23, 10, 5))
        self.assertEqual(T.to_msk(D(2026, 10, 26), '08:05', 'LON'), dt.datetime(2026, 10, 26, 11, 5))

    def test_us_open_shifts_after_nov_1(self):
        # неделя 26-30.10: Европа уже на зимнем, США ещё на летнем
        self.assertEqual(T.to_msk(D(2026, 10, 28), '09:35', 'NY'), dt.datetime(2026, 10, 28, 16, 35))
        self.assertEqual(T.to_msk(D(2026, 11, 2), '09:35', 'NY'), dt.datetime(2026, 11, 2, 17, 35))

    def test_matches_zoneinfo_when_available(self):
        try:
            from zoneinfo import ZoneInfo
            lon, ny = ZoneInfo('Europe/London'), ZoneInfo('America/New_York')
        except Exception:
            self.skipTest('нет базы часовых поясов')
        msk = dt.timezone(dt.timedelta(hours=3))
        d = D(2026, 1, 1)
        while d < D(2028, 1, 1):
            for tz, zi, hhmm in (('LON', lon, '08:05'), ('NY', ny, '09:35'), ('NY', ny, '14:00')):
                h, m = map(int, hhmm.split(':'))
                ref = dt.datetime(d.year, d.month, d.day, h, m, tzinfo=zi).astimezone(msk).replace(tzinfo=None)
                self.assertEqual(T.to_msk(d, hhmm, tz), ref, (d, tz, hhmm))
            d += dt.timedelta(days=1)

    def test_ms_roundtrip_is_msk_as_utc(self):
        # 1787331600000 — первый бар BR_1h.json в репо: 21.08.2026 17:00 МСК
        self.assertEqual(T.ms_to_msk(1787331600000), dt.datetime(2026, 8, 21, 17, 0))
        self.assertEqual(T.msk_to_ms(dt.datetime(2026, 8, 21, 17, 0)), 1787331600000)


class TestIndicators(unittest.TestCase):
    def test_atr14_simple_mean_like_ser_atr14(self):
        rows = [(100, 101, 99, 100)] * 15
        rows[14] = (100, 106, 99, 105)   # TR = max(7, 6, 1) = 7
        b = bars_from(rows)
        self.assertIsNone(market.atr14(b, 13))
        self.assertAlmostEqual(market.atr14(b, 14), (13 * 2 + 7) / 14.0)

    def test_er20(self):
        straight = bars_from([(0, 0, 0, 100 + i) for i in range(21)])
        self.assertAlmostEqual(market.er(straight, 20), 1.0)
        saw = bars_from([(0, 0, 0, 100 + (i % 2)) for i in range(21)])
        self.assertAlmostEqual(market.er(saw, 20), 0.0)
        self.assertIsNone(market.er(saw, 19))

    def test_atr_matches_real_series_by_hand(self):
        b = market.load_daily(config.paths()['series'], 'BR')
        if len(b) < 30:
            self.skipTest('нет ряда BR')
        i = len(b) - 1
        tr = [max(b[k]['h'] - b[k]['l'], abs(b[k]['h'] - b[k - 1]['c']), abs(b[k]['l'] - b[k - 1]['c']))
              for k in range(i - 13, i + 1)]
        self.assertAlmostEqual(market.atr14(b, i), sum(tr) / 14)


class TestSeriesAndCandles(unittest.TestCase):
    def test_rescale_detected_and_ignored_when_unchanged(self):
        b = bars_from([(1, 1, 1, 100), (1, 1, 1, 101)])
        ref = market.series_ref(b)
        self.assertIsNone(market.rescale_factor(ref, b))
        for x in b:
            x['c'] *= 1.02
        self.assertAlmostEqual(market.rescale_factor(ref, b), 1.02)
        # новый бар дописался, пересчёта не было
        b2 = bars_from([(1, 1, 1, 100), (1, 1, 1, 101), (1, 1, 1, 99)])
        self.assertIsNone(market.rescale_factor(ref, b2))

    def test_forming_bar_is_not_complete(self):
        t0 = dt.datetime(2026, 9, 28, 10, 0)
        bars = [{'t': t0}, {'t': t0 + market.HOUR}]
        now = dt.datetime(2026, 9, 28, 11, 40)
        self.assertEqual(len(market.complete_hourly(bars, now, asof=None)), 1)
        # файл испечён в 10:40 — бар 10:00 в нём ещё формировался
        self.assertEqual(len(market.complete_hourly(bars, now, asof=dt.datetime(2026, 9, 28, 10, 40))), 0)

    def test_contracts_and_usable(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, 'portfolio.json')
            with open(p, 'w', encoding='utf-8-sig') as f:   # BOM как у PowerShell 5.1
                json.dump({'active': {'NG': 'NGV6', 'BR': 'BRV6'},
                           'fronts': {'NG': {'secid': 'NGU6'}, 'BR': {'secid': 'BRV6'}}}, f)
            c = market.contracts(p)
        self.assertTrue(market.hourly_usable(c['BR']))
        self.assertFalse(market.hourly_usable(c['NG']))
        self.assertFalse(market.hourly_usable(c.get('GOLD')))


class TestCalendar(unittest.TestCase):
    def setUp(self):
        self.cal = events.load(config.paths()['calendar'])

    def test_real_calendar_loads(self):
        kinds = {e['kind'] for e in self.cal['events']}
        self.assertTrue({'cbr', 'fomc', 'us_cpi', 'us_nfp', 'eia_crude', 'eia_gas'} <= kinds)

    def test_cbr_check_due_five_minutes_after(self):
        e = [x for x in self.cal['events'] if x['key'] == 'cbr:2026-10-23'][0]
        self.assertEqual(e['msk'], dt.datetime(2026, 10, 23, 13, 30))
        self.assertEqual(events.due_checks(self.cal, dt.datetime(2026, 10, 23, 13, 34), set()), [])
        due = events.due_checks(self.cal, dt.datetime(2026, 10, 23, 13, 36), set())
        self.assertEqual([x['key'] for x in due], ['cbr:2026-10-23'])
        self.assertEqual(events.due_checks(self.cal, dt.datetime(2026, 10, 23, 13, 36), {'cbr:2026-10-23'}), [])
        self.assertEqual(events.due_checks(self.cal, dt.datetime(2026, 10, 23, 14, 40), set()), [])

    def test_fomc_msk_time_follows_us_dst(self):
        f = {x['key']: x['msk'] for x in self.cal['events'] if x['kind'] == 'fomc'}
        self.assertEqual(f['fomc:2026-10-28'], dt.datetime(2026, 10, 28, 21, 0))
        self.assertEqual(f['fomc:2026-12-09'], dt.datetime(2026, 12, 9, 22, 0))

    def test_coverage_warning(self):
        self.assertIsNone(events.coverage_warning(self.cal, dt.datetime(2026, 10, 1)))
        self.assertIn('2026-12-31', events.coverage_warning(self.cal, dt.datetime(2026, 12, 20)))

    def test_trading_weekday(self):
        self.assertTrue(events.is_trading_weekday(self.cal, D(2026, 10, 23)))
        self.assertFalse(events.is_trading_weekday(self.cal, D(2026, 10, 24)))
        self.assertFalse(events.is_trading_weekday(self.cal, D(2026, 11, 4)))
        self.assertFalse(events.is_trading_weekday(self.cal, D(2026, 12, 31)))


if __name__ == '__main__':
    unittest.main()
