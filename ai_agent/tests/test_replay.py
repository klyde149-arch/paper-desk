"""Этап 8: короткий сухой прогон движка на реальных рядах из репо (полный — python -m ai_agent replay)."""
import os
import unittest

from ai_agent import config as C
from ai_agent import replay


class TestReplay(unittest.TestCase):
    def test_short_replay_keeps_invariants(self):
        if not os.path.exists(os.path.join(C.ROOT, 'data', 'live_rf', 'candles', 'BR_1h.json')):
            self.skipTest('нет часовых свечей в репо')
        with replay.Replay(1, seed=3) as r:
            stats, bad = r.run()
        self.assertEqual(bad, [])
        self.assertGreater(stats['calls'], 0)


if __name__ == '__main__':
    unittest.main()
