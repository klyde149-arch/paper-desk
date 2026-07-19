"""Офлайн-тесты ассистента: без сети, без ключа, без денег.

    python assistant/tests/run_all.py

Проверяют то, что при поломке даёт молчаливый и дорогой сбой: побег из репо,
протечку секретов, осиротевший tool_call_id, BOM в JSON от PowerShell 5.1.
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

os.environ.setdefault('ASSISTANT_STATE_DIR', os.path.join(tempfile.gettempdir(), 'ta-tests'))
os.environ['ASSISTANT_LLM_MOCK'] = '1'
# Фейковые секреты — проверяем, что скраббер вырежет их фактические значения.
os.environ['TG_BOT_TOKEN'] = '123456789:AAFAKEfaketokenfaketokenfaketoken123'
os.environ['OPENROUTER_API_KEY'] = 'sk-or-v1-' + 'f' * 40
os.environ['TINVEST_TOKEN'] = 't.' + 'z' * 50

from assistant import agent, config, memory, scrub, snapshot  # noqa: E402
from assistant import tools_impl as T  # noqa: E402


class TestContainment(unittest.TestCase):
    """read_repo_file не должен выпускать модель за пределы репо и к секретам."""

    def test_parent_escape(self):
        r = T.read_repo_file('../../etc/passwd')
        self.assertIn('error', r)

    def test_absolute_path(self):
        r = T.read_repo_file('/etc/trading-live.env')
        self.assertIn('error', r)

    def test_secrets_dir(self):
        r = T.read_repo_file('.secrets/tinvest.env.ps1')
        self.assertIn('error', r)

    def test_env_suffix(self):
        r = T.read_repo_file('deploy/trading-live.env.example')
        # .example не оканчивается на .env, но имя в denylist не попадает —
        # важно, что сам trading-live.env закрыт:
        r2 = T.read_repo_file('deploy/../trading-live.env')
        self.assertIn('error', r2)

    def test_vps_bundle_closed(self):
        r = T.read_repo_file('vps/VPS_INVENTORY.md')
        self.assertIn('error', r)

    def test_git_dir_closed(self):
        r = T.read_repo_file('.git/config')
        self.assertIn('error', r)

    def test_normal_file_allowed(self):
        r = T.read_repo_file('README.md', max_bytes=500)
        self.assertNotIn('error', r)
        self.assertIn('содержимое', r['data'])


class TestScrub(unittest.TestCase):
    def test_literal_env_values(self):
        text = 'токен=%s ключ=%s' % (os.environ['TG_BOT_TOKEN'], os.environ['OPENROUTER_API_KEY'])
        out = scrub.scrub(text)
        self.assertNotIn(os.environ['TG_BOT_TOKEN'], out)
        self.assertNotIn(os.environ['OPENROUTER_API_KEY'], out)
        self.assertIn('<REDACTED>', out)

    def test_pattern_unknown_key(self):
        """Ключ, которого нет в нашем окружении, ловится паттерном."""
        out = scrub.scrub('утечка sk-or-v1-' + 'a' * 40)
        self.assertNotIn('a' * 40, out)

    def test_tinvest_token(self):
        out = scrub.scrub('t.' + 'z' * 50)
        self.assertEqual(out.strip(), '<REDACTED>')

    def test_no_crash_on_none(self):
        self.assertIsNone(scrub.scrub(None))

    def test_dispatch_scrubs(self):
        """Скраббер применяется к выводу ЛЮБОГО инструмента, не только вручную."""
        out = T.dispatch('read_repo_file', {'path': 'README.md', 'max_bytes': 300})
        self.assertNotIn(os.environ['OPENROUTER_API_KEY'], out)


class TestJsonEncoding(unittest.TestCase):
    """Файлы от PS 5.1 идут с BOM, от VPS — без. Обе ветки обязаны читаться."""

    def _write(self, encoding):
        fd, path = tempfile.mkstemp(suffix='.json')
        os.close(fd)
        with open(path, 'w', encoding=encoding) as f:
            json.dump({'equity_usd': 123.45, 'открытые': []}, f, ensure_ascii=False)
        return path

    def test_with_bom(self):
        p = self._write('utf-8-sig')
        try:
            self.assertEqual(T.read_json(p)['equity_usd'], 123.45)
        finally:
            os.remove(p)

    def test_without_bom(self):
        p = self._write('utf-8')
        try:
            self.assertEqual(T.read_json(p)['equity_usd'], 123.45)
        finally:
            os.remove(p)

    def test_missing_file(self):
        self.assertIsNone(T.read_json('/nope/nope.json'))

    def test_corrupt_file_raises_clean(self):
        """Тик может писать в момент чтения — нужна внятная ошибка, не трейсбек."""
        fd, p = tempfile.mkstemp(suffix='.json')
        os.close(fd)
        with open(p, 'w', encoding='utf-8') as f:
            f.write('{"обрыв": ')
        try:
            with self.assertRaises(RuntimeError):
                T.read_json(p)
        finally:
            os.remove(p)


class TestHistoryTrim(unittest.TestCase):
    """Осиротевший tool_call_id => 400 от API. Резать только по границам ходов."""

    def _turn(self, i, with_tools=True):
        msgs = [{'role': 'user', 'content': 'вопрос %d' % i}]
        if with_tools:
            msgs.append({'role': 'assistant', 'content': None, 'tool_calls': [
                {'id': 'call_%d' % i, 'type': 'function',
                 'function': {'name': 'get_state', 'arguments': '{}'}}]})
            msgs.append({'role': 'tool', 'tool_call_id': 'call_%d' % i,
                         'name': 'get_state', 'content': 'x' * 3000})
        msgs.append({'role': 'assistant', 'content': 'ответ %d' % i})
        return msgs

    def _assert_no_orphans(self, msgs):
        ids = set()
        for m in msgs:
            for c in (m.get('tool_calls') or []):
                ids.add(c['id'])
        for m in msgs:
            if m.get('role') == 'tool':
                self.assertIn(m['tool_call_id'], ids,
                              'осиротевший tool_call_id: %s' % m['tool_call_id'])

    def test_trim_by_turns(self):
        msgs = []
        for i in range(config.MAX_HISTORY_TURNS + 6):
            msgs += self._turn(i)
        out = memory.trim(msgs)
        self._assert_no_orphans(out)
        starts = [m for m in out if m.get('role') == 'user']
        self.assertLessEqual(len(starts), config.MAX_HISTORY_TURNS)

    def test_trim_by_size(self):
        msgs = []
        for i in range(5):
            msgs += self._turn(i)
        out = memory.trim(msgs)
        self._assert_no_orphans(out)

    def test_collapse_keeps_pairing(self):
        msgs = self._turn(1)
        out = memory.collapse_tool_outputs(msgs)
        self._assert_no_orphans(out)
        tool = [m for m in out if m['role'] == 'tool'][0]
        self.assertTrue(tool['content'].startswith('[инструмент '))
        self.assertLess(len(tool['content']), 200)


class TestToolsSmoke(unittest.TestCase):
    def test_all_registered_tools_have_schema(self):
        names = {s['function']['name'] for s in T.SCHEMAS}
        self.assertEqual(names, set(T.REGISTRY), 'схемы и реестр разошлись')

    def test_dispatch_unknown_tool(self):
        out = T.dispatch('нет_такого', {})
        self.assertIn('нет такого инструмента', out)

    def test_dispatch_bad_args(self):
        """Дешёвые модели шлют мусор в аргументах — падать нельзя."""
        out = T.dispatch('get_state', {'выдуманный_аргумент': 1})
        self.assertIn('error', out)

    def test_enum_guarded(self):
        self.assertIn('error', T.tail_log('/etc/passwd'))
        self.assertIn('error', T.journalctl_tail('sshd'))
        self.assertIn('error', T.systemctl_status('nginx'))

    def test_output_capped(self):
        out = T.dispatch('read_repo_file', {'path': 'journal.md', 'max_bytes': 20000})
        self.assertLessEqual(len(out), config.TOOL_OUTPUT_CAP + 400)

    def test_snapshot_never_raises(self):
        s = snapshot.build()
        self.assertIn('СНАПШОТ', s)
        self.assertLess(len(s), 3000)


class TestKeyValidation(unittest.TestCase):
    """Регресс: placeholder с кириллицей давал невнятный 'latin-1 codec' из urllib."""

    def test_cyrillic_placeholder(self):
        from assistant import llm
        with self.assertRaises(llm.LLMError) as cm:
            llm._check_key('sk-or-v1-ВСТАВЬ_СЮДА_СВОЙ_КЛЮЧ')
        self.assertIn('заглушка', str(cm.exception))

    def test_empty_key(self):
        from assistant import llm
        with self.assertRaises(llm.LLMError):
            llm._check_key('')

    def test_wrong_prefix(self):
        from assistant import llm
        with self.assertRaises(llm.LLMError):
            llm._check_key('my-secret-key-that-is-long-enough-but-wrong')

    def test_valid_key_passes(self):
        from assistant import llm
        llm._check_key('sk-or-v1-' + 'a' * 64)  # не должно бросить


class TestAgentLoop(unittest.TestCase):
    """Полный цикл на мок-модели: без ключа, без сети, без денег."""

    def test_turn_with_tool_call(self):
        memory.reset('test:chat')
        answer, meta = agent.run_turn('test:chat', 'почему не было входов')
        self.assertIn('MOCK', answer)
        self.assertIn('get_signals', meta['инструменты'])

    def test_args_survive_to_dispatch(self):
        """Регресс: поверхностная копия сообщения стирала _args до вызова."""
        memory.reset('test:args')
        seen = []
        agent.run_turn('test:args', 'почему не было входов',
                       on_progress=lambda s: seen.append(s))
        self.assertTrue(any('only_failed' in s for s in seen),
                        'аргументы инструмента потерялись: %s' % seen)

    def test_history_persisted_and_valid(self):
        memory.reset('test:hist')
        agent.run_turn('test:hist', 'что с ботом')
        h = memory.load('test:hist')
        self.assertTrue(h)
        ids = {c['id'] for m in h for c in (m.get('tool_calls') or [])}
        for m in h:
            if m.get('role') == 'tool':
                self.assertIn(m['tool_call_id'], ids)


if __name__ == '__main__':
    config.ensure_state_dirs()
    unittest.main(verbosity=2)
