"""Календарь запретов входа для tools/backtest_rf_queue.ps1 -BlackoutFile.

Для каждого события из data/events/rf_events_2020_2026.json и каждого символа группы берёт
ПОСЛЕДНИЙ торговый день символа строго до даты события: вход на его закрытии проносит свежую
позицию через решение (решения ЦБ 13:30 и ФРС 21:00/22:00 МСК публикуются до закрытия вечерней
сессии, поэтому вход в сам день решения уже знает результат). Предрегистрация гипотез:
docs/backtests/rf_calendar_filter_2026-09.md.

Пример:
  python tools/build_rf_event_blackout.py --group cbr_key_rate --symbols Si,CNY,Eu,MIX,SBRF,VTBR --out data/events/blackout_H1.json
"""
import argparse
import bisect
import datetime as dt
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def trading_days(data_dir, sym):
    with open(os.path.join(data_dir, f"{sym}_1d.json"), encoding="utf-8-sig") as f:
        bars = json.load(f)
    return sorted({dt.datetime.fromtimestamp(b["t"] / 1000, dt.timezone.utc).date() for b in bars})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--events", default=os.path.join(ROOT, "data", "events", "rf_events_2020_2026.json"))
    ap.add_argument("--group", required=True, help="ключ группы в файле событий: cbr_key_rate | fomc")
    ap.add_argument("--symbols", required=True, help="через запятую")
    ap.add_argument("--data-dir", default=os.path.join(ROOT, "data", "moex_fut"))
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    with open(a.events, encoding="utf-8") as f:
        events = [dt.date.fromisoformat(d) for d in json.load(f)[a.group]["dates"]]
    out = {"_about": f"группа {a.group}: последний торговый день символа строго до даты решения"}
    for sym in a.symbols.split(","):
        days = trading_days(a.data_dir, sym)
        blocked = []
        for e in events:
            k = bisect.bisect_left(days, e) - 1          # индекс последнего дня < e
            if k < 0 or (e - days[k]).days > 7:          # нет истории или разрыв торгов (например, март 2022)
                continue
            blocked.append(days[k].isoformat())
        out[sym] = sorted(set(blocked))
        print(f"{sym}: {len(out[sym])} запрещённых дней")
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
