"""CLI агента.

  python3 -m ai_agent tick                      один проход диспетчера (его зовёт ai-agent.timer)
  python3 -m ai_agent run --point main --dry    вызвать точку на живой модели БЕЗ применения (тратит деньги)
  python3 -m ai_agent status                    состояние рукава и расход
  python3 -m ai_agent reset-halt                снять стоп-кран −5R после разбора с владельцем
  python3 -m ai_agent replay --days 20          сухой прогон движка на мок-модели (см. replay.py)
"""
import argparse
import json
import sys

from . import agent, book, budget
from . import config as C
from . import timeutil as T


def main(argv=None):
    ap = argparse.ArgumentParser(prog='ai_agent')
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('tick')
    r = sub.add_parser('run')
    r.add_argument('--point', required=True, choices=['main', 'asia', 'eu_open', 'us_open', 'evening'])
    r.add_argument('--dry', action='store_true', required=True, help='только без применения')
    sub.add_parser('status')
    sub.add_parser('reset-halt')
    rp = sub.add_parser('replay')
    rp.add_argument('--days', type=int, default=20)
    rp.add_argument('--seed', type=int, default=7)
    a = ap.parse_args(argv)

    if a.cmd == 'tick':
        res = agent.tick()
        for line in res.get('logs', []):
            print(line)
        return 0
    if a.cmd == 'run':
        status, info, logs = agent.run_dry(a.point)
        for line in logs:
            print(line)
        print(status)
        print(json.dumps(info, ensure_ascii=False, indent=1, default=str))
        return 0 if status == 'dry' else 1
    if a.cmd == 'status':
        P = C.paths()
        s = agent.load_state(P['state'])
        total, today = budget.spent(P['usage'], T.msk_now().strftime('%Y-%m-%d'))
        print('капитал %.3f, позиций %d, заявок %d, сделок %d, сумма %+.2fR, стоп-кран: %s'
              % (s['equity'], len(s['positions']), len(s['orders']), len(s['trades']),
                 book.closed_sum_r(s), s.get('halt')))
        print('расход: всего $%.3f из $%.2f, сегодня $%.3f' % (total, C.budget()['total_usd'], today))
        return 0
    if a.cmd == 'reset-halt':
        P = C.paths()
        s = agent.load_state(P['state'])
        print('было:', s.get('halt'))
        s['halt'] = None
        s['halt_reset_at'] = T.fmt(T.msk_now())
        s['halt_reset_trades'] = len(s['trades'])
        agent.write_json(P['state'], s)
        return 0
    if a.cmd == 'replay':
        from . import replay
        return replay.main(a.days, a.seed)
    return 2


if __name__ == '__main__':
    sys.exit(main())
