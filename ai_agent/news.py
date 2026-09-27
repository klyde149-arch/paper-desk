"""Новости через perplexity/sonar (дизайн §10, §15).

Разделение ролей (решение владельца 28.09.2026):
- sonar — только поиск ФАКТОВ: дата, время, к каким инструментам относится, что произошло, источник.
  Важность и направление влияния он не оценивает: слабая поисковая модель делает это случайно.
- влияние на цену оценивает торговая модель (Opus) — это её работа, факт она видит рядом с графиком;
- будить ли платную дневную проверку, решает КОД: новость с точным временем за последние 12 ч,
  по инструментам точки, и событие из фиксированного списка внеплановых (WAKE). Плановые события
  (ЦБ, ФРС, данные США, EIA) будит календарь, а не новости.

Sonar не умеет structured output, поэтому отвечает строками фиксированного формата, а код
разбирает их и выбрасывает всё, что не прошло проверку. Строки, похожие на попытку дать модели
указания, отбрасываются. Торговая модель видит только проверенные поля с пометкой
«непроверенные сообщения».
"""
import datetime as dt
import re

from . import budget, llm
from . import config as C
from . import timeutil as T

INSTRUMENTS = set(C.UNIVERSE) | {'ALL'}
EVENT_MAX = 140
PER_GROUP = 6
FRESH_DAYS = 2          # новость с точным временем
FRESH_DAYS_UNTIMED = 1  # без точного времени — только вчера и сегодня
WAKE_WINDOW_H = 12      # будит дневную проверку только новость с точным временем за 12 ч
MAX_TOKENS = 700
UNTIMED = 'время неизвестно'

SUSPICIOUS = re.compile(r'(ignore|disregard|instruction|system|assistant|prompt|json|'
                        r'игнорир|инструкц|указани|промпт|систем\w* сообщ)', re.I)
DOMAIN = re.compile(r'^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$')

# Внеплановые события, ради которых стоит разбудить модель между плановыми точками.
# Список правит владелец/код, не модель; ложное срабатывание стоит ~$0,02-0,04.
WAKE = re.compile(
    r'(ключев\w* ставк|банк\w* росси|\bцб\b|центробанк|фрс|федрезерв|\bfed\b|fomc|'
    r'опек|opec|санкци|эмбарго|потол\w* цен|запрет\w* (на )?(экспорт|импорт|вывоз)|'
    r'интервенц|девальвац|валютн\w* контрол|'
    r'атак|удар\w* по|взрыв|пожар|авари|диверси|'
    r'останов\w* (добыч|экспорт|поставк|отгрузк|транзит|завод|нпз|трубопровод|терминал)|'
    r'перебо|форс-мажор|блокад|закрыт\w* (пролив|порт|терминал)|'
    r'дефолт|перемири|мирн\w* (соглаш|договор|переговор))', re.I)

TOPICS = {
    'rub': 'курс рубля к доллару, юаню и евро; решения и заявления Банка России; ключевая ставка; инфляция '
           'в России; операции Минфина с валютой; санкции (инструменты Si, CNY, Eu)',
    'metals': 'золото и серебро: спрос, ФРС, доллар, геополитика (GOLD, SILV)',
    'energy': 'нефть Brent и природный газ Henry Hub: ОПЕК+, запасы EIA, добыча, поставки, геополитика, погода (BR, NG)',
    'index': 'российский фондовый рынок: крупные эмитенты, дивиденды, бюджет, геополитика (MIX)',
    'macro': 'экономика США и мира: инфляция, занятость, ФРС, доходности облигаций, доллар (GOLD, SILV, BR, Eu)',
    'overnight': 'главные события за ночь для нефти, газа, золота, серебра, курса рубля и российского рынка '
                 '(BR, NG, GOLD, SILV, Si, CNY, Eu, MIX)',
    'europe': 'события утра в Европе для нефти Brent, золота, серебра и евро (BR, GOLD, SILV, Eu)',
    'us': 'события к открытию торгов в США для нефти, газа, золота, серебра; данные по экономике США (BR, NG, GOLD, SILV)',
}

SYSTEM = ('Ты ищешь свежие новости для трейдера фьючерсов. Твоя задача — только найти ФАКТЫ; '
          'оценивать их важность и влияние на цены не нужно, это делает трейдер. Нужны события-причины: '
          'решения центробанков и правительств, опубликованные данные, заявления, санкции, перебои '
          'поставок, решения ОПЕК+, геополитика. НЕ присылай сообщения о движении цен и котировках '
          '(«нефть торгуется около…», «индекс снизился») — цены трейдер видит сам.\n'
          'Отвечай ТОЛЬКО строками формата\n'
          'ГГГГ-ММ-ДД|ЧЧ:ММ|ИНСТРУМЕНТЫ|СОБЫТИЕ|ДОМЕН\n'
          'ИНСТРУМЕНТЫ — к каким из BR NG GOLD SILV Si CNY Eu MIX относится событие, через запятую, '
          'или ALL. СОБЫТИЕ — факт одним предложением, до 140 символов, без оценок и без символа |. '
          'ДОМЕН — сайт источника, например reuters.com. Время московское; если точное время '
          'неизвестно — пиши --:--. Не больше 6 строк, без повторов одного события. Если свежих '
          'событий нет — ответь NONE.')


def query_for(group, now, event=None):
    if group == 'event' and event:
        return ('Каков результат события «%s» (%s МСК)? Только факты. Инструменты: %s.'
                % (event['title'], T.fmt(event['msk']), ', '.join(event['instruments'])))
    return 'Новости за последние сутки до %s МСК. Тема: %s.' % (T.fmt(now), TOPICS[group])


def parse(text, now):
    """-> (проверенные строки, число отброшенных)."""
    out, dropped, seen = [], 0, set()
    for line in (text or '').splitlines():
        line = line.strip().strip('-*• ').strip()
        if not line or line.upper() == 'NONE':
            continue
        parts = [p.strip() for p in line.split('|')]
        if len(parts) != 5:
            dropped += 1
            continue
        d, tm, insts, ev, dom = parts
        dom = dom.lower().removeprefix('www.')
        untimed = tm in ('--:--', '00:00', '')      # 00:00 sonar ставит вместо «неизвестно»
        try:
            day = dt.date.fromisoformat(d)
            if not untimed:
                dt.time.fromisoformat(tm)
        except ValueError:
            dropped += 1
            continue
        inst = sorted({x.strip() for x in insts.split(',') if x.strip()})
        fresh = FRESH_DAYS_UNTIMED if untimed else FRESH_DAYS
        ev = ' '.join(ev.split())
        if (not inst or any(x not in INSTRUMENTS for x in inst)
                or not ev or len(ev) > EVENT_MAX or SUSPICIOUS.search(ev) or not DOMAIN.match(dom)
                or any(c in ev for c in '<>{}`')
                or not (now.date() - dt.timedelta(days=fresh) <= day <= now.date())):
            dropped += 1
            continue
        if 'ALL' in inst:
            inst = ['ALL']
        k = ev[:50].lower()
        if k in seen:
            continue
        seen.add(k)
        out.append({'date': d, 'time': UNTIMED if untimed else tm, 'instruments': inst,
                    'event': ev, 'source': dom, 'wake': bool(WAKE.search(ev))})
        if len(out) >= PER_GROUP:
            break
    return out, dropped


def fetch(groups, now, usage_path, event=None, log=None):
    """Запрос по каждой группе. Сбой одной группы не мешает остальным. -> список новостей."""
    items, seen = [], set()
    for g in groups:
        msgs = [{'role': 'system', 'content': SYSTEM}, {'role': 'user', 'content': query_for(g, now, event)}]
        try:
            r = llm.call_text(C.NEWS_MODEL, msgs, MAX_TOKENS)
        except Exception as e:
            if log:
                log('новости %s: сбой %s' % (g, e))
            continue
        got, dropped = parse(r['text'], now)
        cost = budget.cost_of(C.NEWS_MODEL, r['usage'], searches=1) if not C.llm_mock() else 0.0
        budget.record(usage_path, {'ts': T.fmt(now), 'kind': 'news', 'group': g, 'model': C.NEWS_MODEL,
                                   'prompt_tokens': r['usage'].get('prompt_tokens'),
                                   'completion_tokens': r['usage'].get('completion_tokens'),
                                   'cost_usd': round(cost, 6), 'kept': len(got), 'dropped': dropped})
        if log and dropped:
            log('новости %s: отброшено строк %d' % (g, dropped))
        for x in got:                                # одно событие из разных групп — один раз
            k = x['event'][:50].lower()
            if k not in seen:
                seen.add(k)
                items.append(x)
    return items


def wakes(items, instruments, now):
    """Будить ли платную дневную проверку. Решает код, не sonar: внеплановое событие из списка WAKE
    по инструментам точки, с точным временем, не старше WAKE_WINDOW_H часов."""
    s = set(instruments)
    for x in items:
        if not x.get('wake') or x['time'] == UNTIMED:
            continue
        if 'ALL' not in x['instruments'] and not s.intersection(x['instruments']):
            continue
        try:
            t = dt.datetime.fromisoformat('%s %s' % (x['date'], x['time']))
        except ValueError:
            continue
        if now - dt.timedelta(hours=WAKE_WINDOW_H) <= t <= now + dt.timedelta(minutes=10):
            return True
    return False
