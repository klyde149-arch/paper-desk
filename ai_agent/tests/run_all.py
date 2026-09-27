"""Офлайн-тесты ИИ-агента: без сети, без ключа, без денег.

    python ai_agent/tests/run_all.py

Все пути агента уводятся во временную папку, модель — мок (AI_AGENT_LLM_MOCK=1).
"""
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))

os.environ['AI_AGENT_LLM_MOCK'] = '1'
os.environ['AI_AGENT_DATA_DIR'] = os.path.join(tempfile.gettempdir(), 'ai-agent-tests', 'data')
os.environ['OPENROUTER_API_KEY'] = 'sk-or-v1-' + 'f' * 64
os.environ.pop('TG_BOT_TOKEN', None)   # тесты никогда не шлют в Telegram

if __name__ == '__main__':
    suite = unittest.defaultTestLoader.discover(HERE, pattern='test_*.py', top_level_dir=os.path.dirname(os.path.dirname(HERE)))
    res = unittest.TextTestRunner(verbosity=1).run(suite)
    sys.exit(0 if res.wasSuccessful() else 1)
