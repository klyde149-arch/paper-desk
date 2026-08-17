import path from 'node:path';
import { ageMin, downsample, normalizeCandles, num, pct, readJson, round, utcDay, winStats } from './util.js';

/**
 * Адаптер крипто-контура (Bybit, engine v2-combo-live). Отдаёт РОВНО ту же структуру, что и
 * rf-data.js: терминал в кабинете один, и он не должен знать, какой контур перед ним.
 *
 * Отличия контура, из-за которых нужен отдельный адаптер:
 *  - суммы в долларах, объём позиции в монетах, а не в лотах;
 *  - гарантийного обеспечения нет вовсе — вместо него показываем риск в открытых сделках;
 *  - свечи лежат в общем каталоге data/ как <SYM>_4h.json объектами и с BOM.
 */

const CURVE_POINTS = 300;
const CANDLE_BARS = 120;

/** BCH-USDT -> BCH_USDT_4h.json */
const candleFile = (symbol) => `${String(symbol ?? '').replace(/-/g, '_')}_4h.json`;

/**
 * База дня. Движок фиксирует day_start_equity_usd на первом тике суток UTC; если штамп
 * отстал от календаря, берём последнюю точку эквити до начала сегодняшнего дня — иначе
 * «за сегодня» посчитается от чужого дня. Тот же приём, что в RF-адаптере.
 */
function resolveDayStart(portfolio, curve) {
  const stamped = num(portfolio?.day_start_equity_usd);
  const today = utcDay();
  if (portfolio?.day_start_date_utc === today && stamped > 0) return { base: stamped, source: 'day_start' };
  const todayStartMs = Date.parse(`${today}T00:00:00Z`);
  const before = curve.filter(([ts]) => ts < todayStartMs);
  if (before.length) return { base: before.at(-1)[1], source: 'prev_day_close' };
  return { base: stamped > 0 ? stamped : null, source: 'day_start_stale' };
}

function positionsOf(portfolio, candlesDir) {
  return (portfolio?.open_trades ?? [])
    .filter((p) => p && p.status !== 'closed')
    .map((p) => {
      const entry = num(p.entry_price);
      const upnl = num(p.cur_upnl_usd);
      const qty = num(p.qty);
      // Текущей цены в состоянии нет — восстанавливаем её из плавающего результата:
      // upnl = (cur - entry) * qty для лонга и (entry - cur) * qty для шорта.
      const cur =
        entry !== null && upnl !== null && qty > 0
          ? round(p.side === 'short' ? entry - upnl / qty : entry + upnl / qty, 8)
          : null;
      return {
        id: p.id,
        sleeve: '',
        asset: p.symbol,
        secid: String(p.symbol ?? '').replace('-USDT', ''),
        title: p.symbol,
        side: p.side,
        lots: qty,
        entry,
        stop: num(p.stop),
        tp1: p.tp1_done ? null : num(p.tp1),
        cur,
        notional: round(p.notional_usd, 2),
        upnl: round(upnl),
        // Доходность позиции, а не изменение цены: у шорта рост цены — убыток.
        pctChg: entry && cur ? round(((p.side === 'short' ? entry / cur : cur / entry) - 1) * 100) : null,
        risk: round(p.risk_usd, 2),
        entryDay: String(p.entry_utc ?? '').slice(0, 10),
        entryTs: num(p.entry_ts),
        candles: normalizeCandles(readJson(path.join(candlesDir, candleFile(p.symbol)), []), CANDLE_BARS)
      };
    });
}

const closedTradesOf = (rows) =>
  rows
    .filter(Boolean)
    .map((t) => ({
      id: t.id,
      asset: t.sym,
      secid: String(t.sym ?? '').replace('-USDT', ''),
      title: t.sym,
      side: t.side,
      entryDay: t.entryDay,
      entry: num(t.entry),
      exitDay: t.exitDay,
      exitPx: num(t.exitPx),
      exitReason: t.exitReason ?? '',
      pnl: round(t.pnlUsd),
      rMultiple: round(t.rMultiple),
      // Фандинг — такой же вычет из результата, как комиссия; в одну графу.
      fees: round((num(t.fees) ?? 0) + (num(t.funding) ?? 0))
    }))
    .sort((a, b) => String(b.exitDay ?? '').localeCompare(String(a.exitDay ?? '')));

const openPositionCount = (portfolio) =>
  (portfolio?.open_trades ?? []).filter((p) => p && p.status !== 'closed').length;

/** Minimal read-only DTO for the portfolio selector; it deliberately skips trades and candles. */
export function readCryptoOverview({ dataDir, currency = 'USD' }) {
  const portfolio = readJson(path.join(dataDir, 'portfolio.json'));
  if (!portfolio) throw new Error(`Не читается ${path.join(dataDir, 'portfolio.json')}`);

  const curve = (readJson(path.join(dataDir, 'live_equity.json'), []) ?? [])
    .filter((r) => r && num(r.ts) !== null && num(r.eq) > 0)
    .map((r) => [num(r.ts), num(r.eq)]);
  const capital = num(portfolio.equity_usd);
  const { base: dayBase } = resolveDayStart(portfolio, curve);

  return {
    currency,
    summary: {
      capital: round(capital),
      todayAmt: dayBase !== null && capital !== null ? round(capital - dayBase) : null,
      todayPct: round(pct(capital, dayBase)),
      openPositions: openPositionCount(portfolio),
      entriesHalt: Boolean(portfolio.trading_halted) || Boolean(portfolio.entries_halt_reason),
      haltReason: portfolio.entries_halt_reason ?? '',
      dataAgeMin: curve.length ? ageMin(curve.at(-1)[0]) : null
    }
  };
}

export function readCryptoDashboard({ dataDir, candlesDir, currency = 'USD' }) {
  const portfolio = readJson(path.join(dataDir, 'portfolio.json'));
  if (!portfolio) throw new Error(`Не читается ${path.join(dataDir, 'portfolio.json')}`);

  const eqRows = readJson(path.join(dataDir, 'live_equity.json'), []) ?? [];
  const tradeRows = readJson(path.join(dataDir, 'live_trades.json'), []) ?? [];

  const curve = eqRows.filter((r) => r && num(r.ts) !== null && num(r.eq) > 0).map((r) => [num(r.ts), num(r.eq)]);

  const capital = num(portfolio.equity_usd);
  const peak = num(portfolio.peak_equity_usd);
  const { base: dayBase, source: dayBaseSource } = resolveDayStart(portfolio, curve);

  // У этого контура нет аналога base_rub: базой «за всё время» берём первую точку эквити.
  // Пополнения счёта здесь не отслеживаются — так и подписываем, не выдавая занос за прибыль.
  const baseAmt = curve.length ? curve[0][1] : null;

  const closedTrades = closedTradesOf(tradeRows);
  const { wins, losses, winRate } = winStats(closedTrades, 'pnl');
  const positions = positionsOf(portfolio, candlesDir ?? dataDir);
  const riskOpen = positions.reduce((sum, p) => sum + (num(p.risk) ?? 0), 0);

  return {
    currency,
    candleTf: '4ч',
    summary: {
      capital: round(capital),
      peak: round(peak),
      drawdownPct: round(pct(capital, peak)),

      todayAmt: dayBase !== null && capital !== null ? round(capital - dayBase) : null,
      todayPct: round(pct(capital, dayBase)),
      dayBase: round(dayBase),
      dayBaseSource,

      allTimePct: round(pct(capital, baseAmt)),
      allTimeAmt: capital !== null && baseAmt !== null ? round(capital - baseAmt) : null,
      allTimeNote: 'от первой точки эквити; пополнения не отслеживаются',

      openPositions: positions.length,
      tradesPnl: round(closedTrades.reduce((sum, t) => sum + (num(t.pnl) ?? 0), 0)),
      fees: round(closedTrades.reduce((sum, t) => sum + (num(t.fees) ?? 0), 0)),
      winRate,
      wins,
      losses,

      mode: String(portfolio.mode ?? '').toLowerCase() === 'live' ? 'prod' : portfolio.mode ?? '',
      entriesHalt: Boolean(portfolio.trading_halted) || Boolean(portfolio.entries_halt_reason),
      haltReason: portfolio.entries_halt_reason ?? '',
      extraStat: {
        label: 'Риск в сделках',
        // Формат ru-RU, как и остальные суммы: «3,18 $», а не «3.18 $».
        value: positions.length
          ? `${new Intl.NumberFormat('ru-RU', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(riskOpen)} $`
          : '—'
      },
      // Свежесть — по последней точке эквити: отдельного watermark у этого движка нет.
      dataAgeMin: curve.length ? ageMin(curve.at(-1)[0]) : null
    },
    positions,
    closedTrades,
    equity: downsample(curve, CURVE_POINTS),
    equityBase: baseAmt
  };
}
