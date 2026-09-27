"""Этап 6: недельный разбор, уроки, приём решений владельца."""
import datetime as dt
import json
import os
import unittest

from ai_agent import agent, llm, memory, weekly
from ai_agent import config as C
from ai_agent.tests.fixture import Env

SAT = dt.datetime(2026, 10, 10, 12, 5)


def trade(i, inst, day, r, setup='pullback'):
    return {'id': 'A%d' % i, 'instrument': inst, 'side': 'long', 'setup': setup, 'entry_at': day + ' 07:00',
            'entry_day': day, 'entry': 100.0, 'initial_stop': 97.0, 'exit_at': day + ' 15:00', 'exit_px': 97.0,
            'exit_reason': 'stop', 'r': r, 'net': r * 0.5, 'risk_amt': 0.5, 'fees': 0.01, 'rolls': 0, 'days_held': 0,
            'horizon_days': 5, 'reason': 'откат к поддержке', 'invalidation': 'ниже 97'}


LESSON = {'title': 'Не входить на откате в пятницу', 'entry_type': 'pullback',
          'observation': 'Три отката подряд выбило стопом',
          'cases': [{'date': '2026-10-06', 'instrument': 'BR', 'decision': 'вход на откате', 'result_r': -1.0},
                    {'date': '2026-10-07', 'instrument': 'GOLD', 'decision': 'вход на откате', 'result_r': -1.0},
                    {'date': '2026-10-08', 'instrument': 'Si', 'decision': 'вход на откате', 'result_r': -1.0}],
          'proposal': 'Ждать закрытия дня выше уровня'}


class TestWeekly(unittest.TestCase):
    def setUp(self):
        self.env = Env()
        self.P = C.paths()
        self.old = llm.MOCK
        self.calls = []

    def tearDown(self):
        llm.MOCK = self.old
        self.env.close()

    def cx(self, now=SAT):
        return agent.Ctx(now)

    def test_validate_needs_three_real_cases(self):
        trades = [trade(1, 'BR', '2026-10-06', -1), trade(2, 'GOLD', '2026-10-07', -1), trade(3, 'Si', '2026-10-08', -1)]
        ok, bad = weekly.validate_lessons([LESSON], trades, [])
        self.assertEqual(len(ok), 1)
        fake = dict(LESSON, cases=LESSON['cases'][:2] + [{'date': '2026-10-09', 'instrument': 'MIX', 'decision': 'выдумка',
                                                          'result_r': 3.0}])
        ok, bad = weekly.validate_lessons([fake], trades, [])
        self.assertEqual(ok, [])
        self.assertIn('2 из 3', bad[0])
        ok, bad = weekly.validate_lessons([LESSON, LESSON, LESSON], trades, [])
        self.assertEqual(len(ok), 2)

    def test_run_writes_review_and_lesson_then_inbox_accepts(self):
        s = agent.load_state(self.P['state'])
        s['trades'] = [trade(1, 'BR', '2026-10-06', -1), trade(2, 'GOLD', '2026-10-07', -1), trade(3, 'Si', '2026-10-08', -1)]
        llm.MOCK = lambda m, name: (self.calls.append((name, m)) or {'review': 'Три стопа подряд.', 'lessons': [LESSON]})
        status, info = weekly.run(s, self.cx())
        self.assertEqual(status, 'ok', info)
        self.assertEqual(info['lessons'], 1)
        # в разбор агенту не попадают чужие стратегии — только его сделки
        user = self.calls[0][1][1]['content']
        self.assertIn('A1 BR long pullback', user)
        self.assertNotIn('C3b', user)
        rev = os.path.join(self.P['memory'], 'Разборы', 'Неделя 2026-W41.md')
        self.assertIn('сумма -3.00R', open(rev, encoding='utf-8').read())
        les = memory.lessons(self.P['memory'])
        self.assertEqual(len(les), 1)
        self.assertEqual(les[0]['status'], 'предложен')
        self.assertEqual(les[0]['meta']['id'], 'L2026411')
        self.assertEqual(memory.accepted_lessons(self.P['memory'])[0], '')
        # владелец нажал «принять» — ассистент дописал строку в inbox
        os.makedirs(os.path.dirname(self.P['inbox']), exist_ok=True)
        with open(self.P['inbox'], 'w', encoding='utf-8') as f:
            f.write(json.dumps({'id': 'L2026411', 'decision': 'accept', 'at': '2026-10-10 13:00'}) + '\n')
        applied = weekly.apply_inbox(self.cx(), s)
        self.assertEqual(applied[0][:2], ('L2026411', 'принят'))
        self.assertIn('Не входить на откате в пятницу', memory.accepted_lessons(self.P['memory'])[0])
        # повторная обработка того же inbox ничего не меняет
        self.assertEqual(weekly.apply_inbox(self.cx(), s), [])

    def test_reject_is_not_read(self):
        d = os.path.join(self.P['memory'], 'Уроки')
        with open(os.path.join(d, 'x.md'), 'w', encoding='utf-8') as f:
            f.write(weekly.lesson_md('L2026411', dict(LESSON), '2026-10-10', '2026-W41'))
        os.makedirs(os.path.dirname(self.P['inbox']), exist_ok=True)
        with open(self.P['inbox'], 'w', encoding='utf-8') as f:
            f.write(json.dumps({'id': 'L2026411', 'decision': 'reject', 'at': '2026-10-10 13:00'}) + '\n')
        s = agent.load_state(self.P['state'])
        weekly.apply_inbox(self.cx(), s)
        self.assertEqual(memory.lessons(self.P['memory'])[0]['status'], 'отклонён')
        self.assertEqual(memory.accepted_lessons(self.P['memory'])[0], '')

    def test_empty_week_costs_nothing(self):
        llm.MOCK = lambda m, name: self.calls.append(name) or {}
        s = agent.load_state(self.P['state'])
        status, _ = weekly.run(s, self.cx())
        self.assertEqual(status, 'skip')
        self.assertEqual(self.calls, [])

    def test_memory_version_changes_with_lessons(self):
        rules, _ = memory.load_rules(self.P['memory'])
        self.assertNotEqual(memory.version(rules, ''), memory.version(rules, 'урок'))
        self.assertNotIn('Правит только владелец', rules)   # пометка для владельца модели не нужна


if __name__ == '__main__':
    unittest.main()
