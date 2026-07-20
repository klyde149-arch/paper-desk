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


class TestMarketContext(unittest.TestCase):
    """Регресс: в воскресенье модель принимала норму за аварию и слала копать логи."""

    def test_context_in_snapshot(self):
        s = snapshot.build()
        self.assertIn('MSK', s)
        self.assertTrue(any(d in s for d in snapshot._DAYS), 'нет дня недели')

    def test_weekend_says_norm(self):
        import time as _t
        real = snapshot.time.gmtime
        try:
            # воскресенье 2026-07-19 12:00 MSK
            snapshot.time.gmtime = lambda *a: _t.strptime('2026-07-19 12:00', '%Y-%m-%d %H:%M')
            ctx = snapshot.market_context()
            self.assertIn('ЗАКРЫТА', ctx)
            self.assertIn('НОРМА', ctx)
        finally:
            snapshot.time.gmtime = real

    def test_weekday_says_trading(self):
        import time as _t
        real = snapshot.time.gmtime
        try:
            # среда 2026-07-15 12:00 MSK
            snapshot.time.gmtime = lambda *a: _t.strptime('2026-07-15 12:00', '%Y-%m-%d %H:%M')
            self.assertIn('идут торги', snapshot.market_context())
        finally:
            snapshot.time.gmtime = real


class TestStripMarkdown(unittest.TestCase):
    """Telegram шлётся без parse_mode — разметка видна как мусор."""

    def test_bold(self):
        self.assertEqual(agent.strip_markdown('**Вывод:** всё ок'), 'Вывод: всё ок')

    def test_headers_and_code(self):
        self.assertEqual(agent.strip_markdown('### Итог\n`data/HALT`'), 'Итог\ndata/HALT')

    def test_keeps_plain_text(self):
        txt = 'риск 0.6% на сделку, стоп 2*ATR'
        self.assertEqual(agent.strip_markdown(txt), txt)

    def test_none_safe(self):
        self.assertIsNone(agent.strip_markdown(None))


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


class TestManualClose(unittest.TestCase):
    """Ручное закрытие paper-сделок: pending/TTL/дедуп/идемпотентность/вотчер."""

    def setUp(self):
        import shutil
        from assistant import actions
        self.actions = actions
        self.shutil = shutil
        self.tmp = tempfile.mkdtemp(prefix='ta-mc-')
        rf = os.path.join(self.tmp, 'data', 'rf')
        os.makedirs(rf)

        def portfolio(pid, rid, risk, upnl):
            return {'sleeves': {
                'core': {'positions': [{
                    'id': rid, 'asset': 'RTS', 'secid': 'RIU6', 'side': 'short',
                    'entry': 83794.9, 'entry_day': '2026-07-16', 'stop': 86552.9,
                    'cur': 81920.0, 'risk_usd': risk, 'upnl': upnl}]},
                'setA': {'positions': []}}}
        for pid, rid, risk, upnl in (('c2', 'R7', 300.0, 75.0), ('c3b', 'R8', 500.0, 125.0)):
            with open(os.path.join(rf, '%s_portfolio.json' % pid), 'w', encoding='utf-8') as f:
                json.dump(portfolio(pid, rid, risk, upnl), f)

        self._saved = {k: getattr(config, k) for k in (
            'REPO', 'MANUAL_CLOSE_REQ', 'MANUAL_CLOSE_RES', 'ANNOUNCED_FILE',
            'PENDING_FILE', 'AUDIT_FILE', 'DRY_ACTIONS')}
        config.REPO = self.tmp
        config.MANUAL_CLOSE_REQ = os.path.join(rf, 'manual_close_req.json')
        config.MANUAL_CLOSE_RES = os.path.join(rf, 'manual_close_res.json')
        config.ANNOUNCED_FILE = os.path.join(self.tmp, 'announced.json')
        config.PENDING_FILE = os.path.join(self.tmp, 'pending.json')
        config.AUDIT_FILE = os.path.join(self.tmp, 'audit.log')
        config.DRY_ACTIONS = False  # req-файл и так во временной папке

    def tearDown(self):
        for k, v in self._saved.items():
            setattr(config, k, v)
        self.shutil.rmtree(self.tmp, ignore_errors=True)

    def _req_ids(self):
        p = config.MANUAL_CLOSE_REQ
        if not os.path.exists(p):
            return []
        with open(p, 'r', encoding='utf-8-sig') as f:
            return [r['req_id'] for r in json.load(f).get('requests', [])]

    def test_positions_merged_mirror(self):
        pos = self.actions.list_paper_positions()
        self.assertEqual(len(pos), 1)
        self.assertEqual(pos[0]['ids'], {'C2': 'R7', 'C3b': 'R8'})
        self.assertIn('шорт', pos[0]['display'])
        self.assertEqual(pos[0]['r'], 0.25)

    def test_confirm_writes_request_once(self):
        token, disp = self.actions.create_pending('42', 'RTS', None, 'закрой ртс')
        self.assertIsNotNone(token, disp)
        r = self.actions.confirm_pending(token, '42')
        self.assertTrue(r['ok'], r['msg'])
        self.assertEqual(self._req_ids(), [token])
        # повторный confirm того же токена: pending уже снят, заявка не дублируется
        r2 = self.actions.confirm_pending(token, '42')
        self.assertFalse(r2['ok'])
        self.assertEqual(self._req_ids(), [token])

    def test_second_request_same_asset_rejected(self):
        t1, _ = self.actions.create_pending('42', 'RTS', None)
        self.actions.confirm_pending(t1, '42')
        t2, _ = self.actions.create_pending('42', 'RTS', None)
        r = self.actions.confirm_pending(t2, '42')
        self.assertFalse(r['ok'])
        self.assertIn('очеред', r['msg'])
        self.assertEqual(self._req_ids(), [t1])

    def test_pending_ttl(self):
        token, _ = self.actions.create_pending('42', 'RTS', None)
        p = self.actions._load_pending()
        p[token]['created'] = p[token]['created'] - config.CONFIRM_TTL_SEC - 5
        self.actions._save_pending(p)
        r = self.actions.confirm_pending(token, '42')
        self.assertFalse(r['ok'])
        self.assertEqual(self._req_ids(), [])

    def test_foreign_chat_cannot_confirm(self):
        token, _ = self.actions.create_pending('42', 'RTS', None)
        r = self.actions.confirm_pending(token, '999')
        self.assertFalse(r['ok'])
        self.assertEqual(self._req_ids(), [])

    def test_no_position_no_pending(self):
        token, err = self.actions.create_pending('42', 'GOLD', None)
        self.assertIsNone(token)
        self.assertIn('нет открытой', err)

    def test_watch_results_seed_then_announce_once(self):
        res = {'schema': 1, 'results': [
            {'req_id': 'old1', 'status': 'done', 'chat_id': '42', 'closed': []}]}
        with open(config.MANUAL_CLOSE_RES, 'w', encoding='utf-8') as f:
            json.dump(res, f)
        # первый вызов после деплоя — молчаливый посев, без спама стариной
        self.assertEqual(self.actions.watch_results(), [])
        res['results'].append({
            'req_id': 'new2', 'status': 'done', 'chat_id': '42',
            'closed': [{'profile': 'C2', 'id': 'R7', 'asset': 'RTS', 'side': 'short',
                        'px': 81944.5, 'pnl': 74.65, 'r': 0.25}]})
        with open(config.MANUAL_CLOSE_RES, 'w', encoding='utf-8') as f:
            json.dump(res, f)
        out = self.actions.watch_results()
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]['chat_id'], '42')
        self.assertIn('R7', out[0]['text'])
        self.assertIn('+0.25R', out[0]['text'])
        self.assertEqual(self.actions.watch_results(), [])

    def test_dry_actions_sandbox(self):
        config.DRY_ACTIONS = True
        config.ACTIONS_SANDBOX = os.path.join(self.tmp, 'sandbox')
        token, _ = self.actions.create_pending('42', 'RTS', None)
        r = self.actions.confirm_pending(token, '42')
        self.assertTrue(r['ok'], r['msg'])
        self.assertIn('DRY', r['msg'])
        self.assertEqual(self._req_ids(), [], 'DRY-заявка попала в боевой файл!')
        sandbox = os.path.join(config.ACTIONS_SANDBOX, 'manual_close_req.json')
        self.assertTrue(os.path.exists(sandbox))


if __name__ == '__main__':
    config.ensure_state_dirs()
    unittest.main(verbosity=2)
