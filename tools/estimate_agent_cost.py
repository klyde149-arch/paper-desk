"""Оценка расхода ИИ-агента (docs/strategy/rf_ai_agent_design_2026-09.md §3, §7).

Считает токены и деньги за торговый день по расписанию агента и сколько дней хватит бюджета.
Цены по умолчанию сверены с OpenRouter 26.09.2026; --fetch берёт свежие из публичного
https://openrouter.ai/api/v1/models (ключ не нужен).

Допущения (не измерены — уточнить по первым 5 дням работы): ~2,7 символа на токен для числовых
баров; 5 000 токенов правил; выход на рассуждение 6 000 (medium) / 1 500 (low). Вызовы идут с
интервалом в часы, кэш промпта не доживает — весь вход считается по полной цене.

Пример:
  python tools/estimate_agent_cost.py --budget 12.5 --fetch
"""
import argparse
import json
import urllib.request

DEFAULT_PRICES = {  # $ за 1 токен / за поиск
    "anthropic/claude-opus-5.5": {"in": 4e-6, "out": 20e-6},
    "perplexity/sonar": {"in": 1e-6, "out": 1e-6, "search": 0.005},
}
TOK_PER_INSTR = 817 + 300   # 60 дневных баров цифрами + позиция/заявки по инструменту


def fetch_prices(model):
    with urllib.request.urlopen("https://openrouter.ai/api/v1/models", timeout=30) as r:
        data = {m["id"]: m.get("pricing", {}) for m in json.load(r)["data"]}
    out = {}
    for mid in (model, "perplexity/sonar"):
        p = data[mid]
        out[mid] = {"in": float(p["prompt"]), "out": float(p["completion"])}
        if p.get("web_search"):
            out[mid]["search"] = float(p["web_search"])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="anthropic/claude-opus-5.5")
    ap.add_argument("--instruments", type=int, default=8)
    ap.add_argument("--budget", type=float, default=12.5)
    ap.add_argument("--days-per-month", type=int, default=22)
    ap.add_argument("--fetch", action="store_true", help="взять текущие цены с OpenRouter")
    a = ap.parse_args()

    prices = fetch_prices(a.model) if a.fetch else {a.model: DEFAULT_PRICES[a.model], **DEFAULT_PRICES}
    m, s = prices[a.model], prices["perplexity/sonar"]
    search = s["search"] + 500 * s["in"] + 800 * s["out"]          # запрос ~500 токенов, ответ ~800

    def call(tin, tout, searches=0):
        return tin * m["in"] + tout * m["out"] + searches * search, tin + tout

    n = a.instruments
    main_in = 5000 + n * TOK_PER_INSTR + 2000 + 1500               # правила + бары + новости + память
    # (название, (стоимость, токены), вызовов в торговый день)
    parts = [
        ("00:20 главный разбор (medium)", call(main_in, 3000 + 375 * n, 6), 1.0),
        ("06:01 утро/Азия (low)", call(10000, 1500, 2), 1.0),
        ("23:35 вечер (low)", call(10000, 1500, 1), 1.0),
        ("открытия Европы и США (~60% не пропущены)", call(9800, 1500, 1), 2 * 0.6),
        ("после событий (~2 в неделю)", call(8000, 1500, 1), 0.4),
        ("недельный разбор (medium)", call(25000, 6000), 1 / 5),
    ]
    print(f"Модель {a.model}: вход ${m['in'] * 1e6:.2f}/1M, выход ${m['out'] * 1e6:.2f}/1M; "
          f"поиск Perplexity ≈ ${search:.4f}; инструментов {n}\n")
    print(f"{'компонент':44s} {'$/день':>8s} {'токенов/день':>13s}")
    tot_cost = tot_tok = 0.0
    for name, (cost, tok), k in parts:
        tot_cost += cost * k
        tot_tok += tok * k
        print(f"{name:44s} {cost * k:8.3f} {tok * k:13,.0f}")
    print(f"{'ИТОГО':44s} {tot_cost:8.3f} {tot_tok:13,.0f}\n")
    days = a.budget / tot_cost
    print(f"Бюджет ${a.budget}: ~{days:.0f} торговых дней (~{days / a.days_per_month:.1f} мес); "
          f"в месяц ~${tot_cost * a.days_per_month:.1f}, ~{tot_tok * a.days_per_month / 1e6:.1f} млн токенов")


if __name__ == "__main__":
    main()
