import path from 'node:path';
import { ageMin, downsample, mskDay, normalizeCandles, num, pct, readJson, round, winStats } from './util.js';

/**
 * Адаптер контура RF (T-Invest C3b, фьючерсы MOEX). Читает состояние, которое пишет
 * tools/live_rf_engine.ps1. Только чтение: движок — единственный писатель.
 *
 * Здесь же собраны все ловушки этих данных. Каждая проверена по коду движка или по самим
 * рядам; без них цифры в кабинете соврут.
 */

const CURVE_POINTS = 300;
const CANDLE_BARS = 120;

/**
 * База дня. `day_start_eq` движок фиксирует на первом тике торгового дня, поэтому в выходные
 * и до открытия ЕТС дата отстаёт от календарной. Если дата не сегодняшняя — базой берём
 * последнюю точку предыдущего дня, иначе «за сегодня» покажет чужой день.
 */
function resolveDayStart(portfolio, curve) {
  const stamped = num(portfolio?.day_start_eq);
  const today = mskDay();
  if (portfolio?.day_start_date === today && stamped > 0) return { base: stamped, source: 'day_start_eq' };
  const todayStartMs = Date.parse(`${today}T00:00:00Z`) - 3 * 3600000;
  const before = curve.filter(([ts]) => ts < todayStartMs);
  if (before.length) return { base: before.at(-1)[1], source: 'prev_day_close' };
  return { base: stamped > 0 ? stamped : null, source: 'day_start_eq_stale' };
}

/**
 * Кривая капитала бота. Точки, где T-Invest вернул пустой портфель (account_liquid <= 0),
 * схлопывают bot_capital в мусор и рисуют фантомную просадку ~97%.
 * Фильтр повторяет tools/build_vizdata.ps1.
 */
const capitalCurve = (rows) =>
  rows
    .filter((r) => r && num(r.bot_capital) !== null && num(r.account_liquid) > 0)
    .map((r) => [num(r.ts), num(r.bot_capital)]);

/** Кривая доходности стратегии: profile_eq не видит пополнений счёта (live_rf_engine.ps1:1990). */
const profileCurve = (rows) =>
  rows.filter((r) => r && num(r.ts) !== null && num(r.total) > 0).map((r) => [num(r.ts), num(r.total)]);

function positionsOf(portfolio, names, dataDir) {
  const out = [];
  for (const sleeve of ['core', 'setA']) {
    for (const p of portfolio?.sleeves?.[sleeve]?.positions ?? []) {
      if (!p) continue;
      const entry = num(p.entry_px_pts);
      const cur = num(p.cur_px);
      const rubPerPt = num(p.rub_per_pt) ?? 0;
      out.push({
        id: p.id,
        sleeve,
        asset: p.asset,
        secid: p.secid,
        title: names[p.asset] ?? p.asset,
        side: p.side,
        lots: num(p.lots),
        entry,
        stop: num(p.stop_px_pts),
        // tp1 у части позиций отсутствует: ядро ведёт их шандельером без фиксированного тейка
        tp1: num(p.tp1_px_pts),
        cur,
        // сумма позиции нигде не хранится — считаем так же, как дашборд
        notional: entry !== null ? round(num(p.lots) * entry * rubPerPt, 0) : null,
        upnl: round(p.upnl_rub),
        // Доходность ПОЗИЦИИ, а не изменение цены: у шорта рост цены — убыток, и без учёта
        // стороны рядом с красным P&L вставал зелёный «+0,30 %».
        pctChg: entry && cur ? round(((p.side === 'short' ? entry / cur : cur / entry) - 1) * 100) : null,
        risk: round(p.risk_rub, 0),
        entryDay: p.entry_day,
        entryTs: num(p.entry_ts),
        candles: normalizeCandles(readJson(path.join(dataDir, 'candles', `${p.asset}_1h.json`), []), CANDLE_BARS)
      });
    }
  }
  return out;
}

const closedTradesOf = (rows, names) =>
  rows
    .filter(Boolean)
    .map((t) => ({
      id: t.id,
      asset: t.asset,
      secid: t.secid,
      title: names[t.asset] ?? t.asset,
      side: t.side,
      entryDay: t.entryDay,
      entry: num(t.entry),
      exitDay: t.exitDay,
      exitPx: num(t.exitPx),
      exitReason: t.exitReason ?? '',
      pnl: round(t.pnlRub),
      rMultiple: round(t.rMultiple),
      fees: round(t.feesRub)
    }))
    .sort((a, b) => String(b.exitDay ?? '').localeCompare(String(a.exitDay ?? '')));

const openPositionCount = (portfolio) =>
  ['core', 'setA'].reduce((count, sleeve) => count + (portfolio?.sleeves?.[sleeve]?.positions ?? []).filter(Boolean).length, 0);

/** Minimal read-only DTO for the portfolio selector; it deliberately skips trades, names, and candles. */
export function readRfOverview({ dataDir, currency = 'RUB' }) {
  const portfolio = readJson(path.join(dataDir, 'portfolio.json'));
  if (!portfolio) throw new Error(`Не читается ${path.join(dataDir, 'portfolio.json')}`);

  const capCurve = capitalCurve(readJson(path.join(dataDir, 'equity.json'), []) ?? []);
  const capital = num(portfolio.go?.bot_capital_rub) ?? num(portfolio.profile_eq);
  const { base: dayBase } = resolveDayStart(portfolio, capCurve);

  return {
    currency,
    summary: {
      capital: round(capital),
      todayAmt: dayBase !== null && capital !== null ? round(capital - dayBase) : null,
      todayPct: round(pct(capital, dayBase)),
      openPositions: openPositionCount(portfolio),
      entriesHalt: Boolean(portfolio.entries_halt?.active),
      haltReason: portfolio.entries_halt?.reason ?? '',
      dataAgeMin: ageMin(portfolio.watermarks?.last_eq_snap)
    }
  };
}

export function readRfDashboard({ dataDir, namesPath, currency = 'RUB' }) {
  const portfolio = readJson(path.join(dataDir, 'portfolio.json'));
  if (!portfolio) throw new Error(`Не читается ${path.join(dataDir, 'portfolio.json')}`);

  const equityRows = readJson(path.join(dataDir, 'equity.json'), []) ?? [];
  const tradeRows = readJson(path.join(dataDir, 'trades.json'), []) ?? [];
  const names = readJson(namesPath, {})?.fut ?? {};

  const capCurve = capitalCurve(equityRows);
  const stratCurve = profileCurve(equityRows);

  // Капитал — реальный, сверенный с брокером (Set-BotCapital), а не блендовый profile_eq.
  const capital = num(portfolio.go?.bot_capital_rub) ?? num(portfolio.profile_eq);
  const peak = num(portfolio.go?.capital_peak_rub) ?? num(portfolio.peak_eq);

  const { base: dayBase, source: dayBaseSource } = resolveDayStart(portfolio, capCurve);

  // «За всё время» — доходность стратегии, а не рост счёта: bot_capital растёт и на пополнениях
  // (12.08.2026 серия прыгнула +23,9% за один снимок — это занос денег, не прибыль).
  const baseAmt = num(portfolio.meta?.base_rub);
  const profileEq = num(portfolio.profile_eq);

  const closedTrades = closedTradesOf(tradeRows, names);
  const { wins, losses, winRate } = winStats(closedTrades, 'pnl');
  const positions = positionsOf(portfolio, names, dataDir);
  const goUsed = num(portfolio.go?.used_rub);
  const goBudget = num(portfolio.go?.budget_rub);

  return {
    currency,
    candleTf: '1ч',
    summary: {
      capital: round(capital),
      peak: round(peak),
      drawdownPct: round(pct(capital, peak)),

      todayAmt: dayBase !== null && capital !== null ? round(capital - dayBase) : null,
      todayPct: round(pct(capital, dayBase)),
      dayBase: round(dayBase),
      dayBaseSource,

      allTimePct: round(pct(profileEq, baseAmt)),
      allTimeAmt: profileEq !== null && baseAmt !== null ? round(profileEq - baseAmt) : null,
      allTimeNote: 'пополнения счёта не учтены',

      openPositions: positions.length,
      tradesPnl: round(closedTrades.reduce((sum, t) => sum + (num(t.pnl) ?? 0), 0)),
      fees: round(closedTrades.reduce((sum, t) => sum + (num(t.fees) ?? 0), 0)),
      winRate,
      wins,
      losses,

      mode: portfolio.mode ?? '',
      entriesHalt: Boolean(portfolio.entries_halt?.active),
      haltReason: portfolio.entries_halt?.reason ?? '',
      extraStat: {
        label: 'ГО занято',
        value: goUsed !== null && goBudget > 0 ? `${Math.round((goUsed / goBudget) * 100)}%` : '—'
      },
      dataAgeMin: ageMin(portfolio.watermarks?.last_eq_snap)
    },
    positions,
    closedTrades,
    equity: downsample(stratCurve, CURVE_POINTS),
    equityBase: baseAmt
  };
}
