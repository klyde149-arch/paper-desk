"""Терминальный клиент. Запускается на VPS (обычно через ssh из tools/ask.ps1).

    python3 -m assistant.cli --stdin        # вопрос приходит на stdin (так зовёт ask.ps1)
    python3 -m assistant.cli --repl         # интерактивный режим
    python3 -m assistant.cli "вопрос"       # одним аргументом
    python3 -m assistant.cli --snapshot     # только состояние, без модели и без денег

Вопрос идёт через stdin, а не argv: тройное экранирование PowerShell → ssh → bash
на кириллице с кавычками — гарантированный источник багов.
"""
import getpass
import os
import sys

# Позволяет запускать и как `python3 assistant/cli.py`, и как `-m assistant.cli`.
if __package__ in (None, ''):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    __package__ = 'assistant'

from . import agent, config, memory, snapshot  # noqa: E402


def _force_utf8():
    """Windows-консоль по умолчанию cp1251 и падает на '₽'. На VPS это no-op."""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding='utf-8', errors='replace')
        except (AttributeError, ValueError):
            pass


def _chat_id():
    try:
        return 'cli:' + (getpass.getuser() or 'local')
    except Exception:
        return 'cli:local'


def _ask(text, verbose=True):
    on_progress = (lambda s: print(s, file=sys.stderr, flush=True)) if verbose else None
    try:
        answer, meta = agent.run_turn(_chat_id(), text, on_progress=on_progress)
    except Exception as e:
        print('Ошибка: %s' % e, file=sys.stderr)
        print('\nСырое состояние (без модели):\n' + snapshot.build())
        return 1
    print(answer)
    if verbose:
        print('\n[%s | %s токенов | %s с | %s]'
              % (meta['модель'], meta['токены'], meta['секунд'],
                 ', '.join(meta['инструменты']) or 'без инструментов'),
              file=sys.stderr)
    return 0


def main(argv):
    _force_utf8()
    config.ensure_state_dirs()
    args = list(argv[1:])

    if '--snapshot' in args:
        print(snapshot.build())
        return 0

    if '--reset' in args:
        memory.reset(_chat_id())
        print('История диалога очищена.')
        return 0

    quiet = '--quiet' in args
    if quiet:
        args.remove('--quiet')

    if '--repl' in args:
        print('Ассистент paper-desk. Пустая строка или "выход" — закончить, '
              '"сброс" — очистить контекст.\n')
        print(snapshot.build() + '\n')
        while True:
            try:
                q = input('> ').strip()
            except (EOFError, KeyboardInterrupt):
                print()
                return 0
            if not q or q.lower() in ('выход', 'exit', 'quit'):
                return 0
            if q.lower() in ('сброс', 'reset', '/new'):
                memory.reset(_chat_id())
                print('Контекст очищен.\n')
                continue
            _ask(q, verbose=not quiet)
            print()

    if '--stdin' in args:
        text = sys.stdin.read().strip()
    else:
        text = ' '.join(a for a in args if not a.startswith('--')).strip()

    if not text:
        print('Нечего спрашивать. Пример: ask.ps1 "что с ботом"', file=sys.stderr)
        return 2
    if len(text) > config.MAX_INCOMING_CHARS:
        print('Вопрос длиннее %d символов.' % config.MAX_INCOMING_CHARS, file=sys.stderr)
        return 2
    return _ask(text, verbose=not quiet)


if __name__ == '__main__':
    sys.exit(main(sys.argv))
