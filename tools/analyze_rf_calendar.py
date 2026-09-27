"""Оценка календарного фильтра C3b по предрегистрированным критериям.

Разбиение: dev = январь–август, резерв = сентябрь–декабрь каждого года; сделка относится к окну
по дню входа. Резерв считается ТОЛЬКО с флагом --final (вскрывать один раз, после dev).
Критерии: docs/backtests/rf_calendar_filter_2026-09.md §1.

Пример:
  python tools/analyze_rf_calendar.py --label H1 --base data/moex_fut/btq_trades_calf_pre.json \
    --var data/moex_fut/btq_trades_calf_H1.json --blocked data/moex_fut/btq_blackout_calf_H1.json \
    --base2 data/moex_fut/btq_trades_calf_base_x2.json --var2 data/moex_fut/btq_trades_calf_H1_x2.json
"""
import argparse
import json

YEARS = range(2020, 2027)


def load(p):
    with open(p, encoding="utf-8-sig") as f:
        d = json.load(f)
    return d if isinstance(d, list) else [d]


def in_win(day, reserve):
    m = int(day[5:7])
    return (m >= 9) if reserve else (m <= 8)


def stats(trades, reserve, year=None):
    g = [t for t in trades if in_win(t["entryDay"], reserve) and (year is None or int(t["entryDay"][:4]) == year)]
    rs = [t["pnlUsd"] / t["riskUsd"] for t in g if t.get("riskUsd", 0) > 0]
    win = sum(r for r in rs if r > 0)
    loss = -sum(r for r in rs if r <= 0)
    return {"n": len(g), "R": sum(rs), "pf": (win / loss) if loss > 0 else float("inf")}


def table(base, var, reserve):
    rows, deltas = [], {}
    for y in YEARS:
        b, v = stats(base, reserve, y), stats(var, reserve, y)
        if b["n"] == 0 and v["n"] == 0:
            continue
        deltas[y] = v["R"] - b["R"]
        rows.append(f"| {y} | {b['n']} | {b['R']:+.2f} | {v['n']} | {v['R']:+.2f} | {deltas[y]:+.2f} |")
    b, v = stats(base, reserve), stats(var, reserve)
    rows.append(f"| **всего** | {b['n']} | {b['R']:+.2f} (PF {b['pf']:.2f}) | {v['n']} | {v['R']:+.2f} (PF {v['pf']:.2f}) | **{v['R'] - b['R']:+.2f}** |")
    return rows, deltas, v["R"] - b["R"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--base", required=True)
    ap.add_argument("--var", required=True)
    ap.add_argument("--blocked", required=True)
    ap.add_argument("--base2", help="база при удвоенных расходах")
    ap.add_argument("--var2", help="вариант при удвоенных расходах")
    ap.add_argument("--final", action="store_true", help="ОДИН РАЗ: вскрыть резерв сентябрь–декабрь")
    a = ap.parse_args()

    base, var = load(a.base), load(a.var)
    blocked = [b for b in load(a.blocked) if b]
    hdr = ["| Год | База, сделок | База, R | Фильтр, сделок | Фильтр, R | ΔR |", "|---|---|---|---|---|---|"]

    print(f"## {a.label}: dev (январь–август)\n")
    rows, deltas, d_dev = table(base, var, reserve=False)
    print("\n".join(hdr + rows))
    blk_dev = [b for b in blocked if in_win(b["day"], False)]
    blk_res = [b for b in blocked if in_win(b["day"], True)]
    print(f"\nПогашено входов: dev {len(blk_dev)}, резерв {len(blk_res)} (по символам dev: "
          + ", ".join(f"{s} {sum(1 for b in blk_dev if b['sym'] == s)}" for s in sorted({b['sym'] for b in blk_dev})) + ")")

    best = max(deltas.values()) if deltas else 0.0
    nonneg = sum(1 for d in deltas.values() if d >= 0)
    c = {
        "1. погашено на dev ≥ 10": len(blk_dev) >= 10,
        "2. ΔR dev > 0": d_dev > 0,
        f"3. ΔR ≥ 0 в ≥ 4 из {len(deltas)} лет (факт {nonneg})": nonneg >= 4,
        f"4. без лучшего года ΔR > 0 (факт {d_dev - best:+.2f})": d_dev - best > 0,
    }
    if a.base2 and a.var2:
        _, _, d2 = table(load(a.base2), load(a.var2), reserve=False)
        c[f"5. при удвоенных расходах ΔR dev > 0 (факт {d2:+.2f})"] = d2 > 0
    else:
        c["5. при удвоенных расходах — не посчитано"] = False
    print("\nКритерии dev:")
    for k, ok in c.items():
        print(f"- {'ДА ' if ok else 'НЕТ'} {k}")
    passed = all(c.values())
    print(f"\n**Итог dev: {'ПРОШЁЛ' if passed else 'НЕ ПРОШЁЛ'}**")

    if a.final:
        print(f"\n## {a.label}: резерв (сентябрь–декабрь), вскрыт один раз\n")
        rows, _, d_res = table(base, var, reserve=True)
        print("\n".join(hdr + rows))
        print(f"\n**Резерв: ΔR {d_res:+.2f} → {'принять' if d_res >= 0 else 'отклонить'}**")


if __name__ == "__main__":
    main()
