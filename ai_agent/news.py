"""Новости через perplexity/sonar (дизайн §10, §15).

Sonar не умеет structured output, поэтому отвечает строками фиксированного формата, а код
разбирает их и выбрасывает всё, что не прошло проверку: перечисления, дата и время, длина события
до 120 символов, домен источника. Строки, похожие на попытку дать модели указания, отбрасываются.
Торговая модель видит только прошедшие проверку поля — и с пометкой «непроверенные сообщения».
"""
import datetime as dt
import re

from . import budget, llm
from . import config as C
from . import timeutil as T

INSTRUMENTS = set(C.UNIVERSE) | {'ALL'}
DIRECTIONS = {'up', 'down', 'mixed', 'none'}
IMPORTANCE = {'high', 'medium', 'low'}
EVENT_MAX = 120
PER_GROUP = 8
FRESH_DAYS = 2
MAX_TOKENS = 700

SUSPICIOUS = re.compile(r'(ignore|disregard|instruction|system|assistant|prompt|json|'
                        r'игнорир|инструкц|указани|промпт|систем\w* сообщ)', re.I)
DOMAIN = re.compile(r'^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$')

TOPICS = {
    'rub': 'курс рубля к доллару, юаню и евро; решения и заявления Банка России; ключевая ставка; инфляция '
           'в России; операции Минфина с валютой; санкции (инструменты Si, CNY, Eu)',
    'metals': 'золото и серебро: цены, спрос, ФРС, доллар, геополитика (GOLD, SILV)',
    'energy': 'нефть Brent и природный газ Henry Hub: ОПЕК+, запасы EIA, добыча, геополитика, погода (BR, NG)',
    'index': 'российский фондовый рынок и индекс Мосбиржи: крупные эмитенты, дивиденды, геополитика (MIX)',
    'macro': 'экономика США и мира: инфляция, занятость, ФРС, доходности облигаций, доллар (GOLD, SILV, BR, Eu)',
    'overnight': 'главные события за ночь для нефти, газа, золота, серебра, курса рубля и российского рынка '
                 '(BR, NG, GOLD, SILV, Si, CNY, Eu, MIX)',
    'europe': 'события утра в Европе: нефть Brent, золото, серебро, евро (BR, GOLD, SILV, Eu)',
    'us': 'события открытия торгов в США: нефть, газ, золото, серебро, данные по экономике США (BR, NG, GOLD, SILV)',
}

SYSTEM = ('Ты собираешь свежие рыночные новости. Отвечай ТОЛЬКО строками формата\n'
          'ГГГГ-ММ-ДД|ЧЧ:ММ|ИНСТРУМЕНТ|НАПРАВЛЕНИЕ|ВАЖНОСТЬ|СОБЫТИЕ|ДОМЕН\n'
          'ИНСТРУМЕНТ — один из BR NG GOLD SILV Si CNY Eu MIX ALL. НАПРАВЛЕНИЕ — up, down, mixed или none '
          '(вероятное влияние на цену инструмента). ВАЖНОСТЬ — high, medium или low. СОБЫТИЕ — факт без '
          'оценок, до 120 символов, без символа |. ДОМЕН — сайт источника, например reuters.com. Время '
          'московское. Не больше 8 строк, самые важные первыми. Если свежих новостей нет — ответь NONE.')


def query_for(group, now, event=None):
    if group == 'event' and event:
        return ('Каков результат события «%s» (%s МСК) и первая реакция рынка? Инструменты: %s.'
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
        if len(parts) != 7:
            dropped += 1
            continue
        d, tm, inst, dirn, imp, ev, dom = parts
        dirn, imp, dom = dirn.lower(), imp.lower(), dom.lower().removeprefix('www.')
        try:
            day = dt.date.fromisoformat(d)
            dt.time.fromisoformat(tm)
        except ValueError:
            dropped += 1
            continue
        ev = ' '.join(ev.split())
        if (inst not in INSTRUMENTS or dirn not in DIRECTIONS or imp not in IMPORTANCE
                or not ev or len(ev) > EVENT_MAX or SUSPICIOUS.search(ev) or not DOMAIN.match(dom)
                or any(c in ev for c in '<>{}`')
                or not (now.date() - dt.timedelta(days=FRESH_DAYS) <= day <= now.date())):
            dropped += 1
            continue
        k = (inst, ev[:40].lower())
        if k in seen:
            continue
        seen.add(k)
        out.append({'date': d, 'time': tm, 'instrument': inst, 'direction': dirn, 'importance': imp,
                    'event': ev, 'source': dom})
        if len(out) >= PER_GROUP:
            break
    return out, dropped


def fetch(groups, now, usage_path, event=None, log=None):
    """Запрос по каждой группе. Сбой одной группы не мешает остальным. -> список новостей."""
    items = []
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
        items += got
    return items


def has_high(items, instruments):
    s = set(instruments) | {'ALL'}
    return any(x['importance'] == 'high' and x['instrument'] in s for x in items)
