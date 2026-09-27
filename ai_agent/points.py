"""Точки решений (дизайн §5): что агент видит и насколько глубоко думает."""
from . import config as C

POINTS = {
    'main': {'label': 'Главный разбор: закрылся дневной бар', 'effort': 'medium',
             'instruments': C.UNIVERSE, 'daily': 60, 'hourly': 0, 'news_groups': ['rub', 'metals', 'energy', 'index', 'macro']},
    'asia': {'label': 'Утро 06:01 МСК: ночные новости и гэп, подтверждение или отмена заявок', 'effort': 'low',
             'instruments': C.UNIVERSE, 'daily': 20, 'hourly': 24, 'news_groups': ['overnight']},
    'eu_open': {'label': 'Открытие Европы', 'effort': 'low',
                'instruments': ('BR', 'GOLD', 'SILV', 'Eu'), 'daily': 20, 'hourly': 24, 'news_groups': ['europe']},
    'us_open': {'label': 'Открытие США', 'effort': 'low',
                'instruments': ('BR', 'NG', 'GOLD', 'SILV'), 'daily': 20, 'hourly': 24, 'news_groups': ['us']},
    'evening': {'label': 'Вечер 23:35 МСК: ведение позиций перед закрытием и событиями', 'effort': 'low',
                'instruments': C.UNIVERSE, 'daily': 20, 'hourly': 24, 'news_groups': ['overnight']},
    'event': {'label': 'Проверка после события', 'effort': 'low',
              'instruments': (), 'daily': 20, 'hourly': 24, 'news_groups': ['event']},
}

# на дневных точках прибыль не фиксируется (§6): только урезать риск при сломанной идее / перед событием
INTRADAY_NOTE = ('Это дневная проверка: фиксировать прибыль нельзя (close_kind take_profit запрещён). '
                 'Можно подтянуть стоп, закрыть позицию при сломанной идее (idea_broken) или перед '
                 'известным событием (pre_event), отменить или изменить заявку, открыть новую сделку.')
MAIN_NOTE = ('Это главный разбор: можно всё — входы, ведение, выходы, в том числе фиксация прибыли '
             '(take_profit), если идея исчерпана.')
