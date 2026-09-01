import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { readCryptoCandles, readCryptoDashboard, readCryptoOverview } from './crypto-data.js';
import { readRfCandles, readRfDashboard, readRfOverview } from './rf-data.js';
import { dashboardV2, portfoliosV2 } from './api-v2.js';
import { mskDay, utcDay } from './util.js';

const dashboardKeys = ['candleTf', 'closedTrades', 'currency', 'equity', 'equityBase', 'positions', 'summary'];
// ЯДРО контракта - обязано совпадать у обоих контуров: на нём держится общий фронт кабинета.
const summaryKeys = ['allTimeAmt', 'allTimeNote', 'allTimePct', 'capital', 'dataAgeMin', 'dayBase', 'dayBaseSource',
  'drawdownPct', 'entriesHalt', 'extraStat', 'fees', 'haltReason', 'losses', 'mode', 'openPositions', 'peak',
  'todayAmt', 'todayPct', 'tradesPnl', 'winRate', 'wins'];
const positionKeys = ['asset', 'cur', 'entry', 'entryDay', 'entryTs', 'id', 'lots', 'notional', 'pctChg',
  'risk', 'secid', 'side', 'sleeve', 'stop', 'title', 'tp1', 'upnl'];
// Поля СВЕРХ ядра, специфичные для контура. Перечислены явно, чтобы новое поле нельзя было
// добавить молча: набор ключей по-прежнему сверяется точно, просто своим для каждого контура.
// У RF это числа, приходящие от брокера дословно (см. tools/live_rf_engine.ps1 Set-BotCapital).
const rfSummaryExtra = ['accountTotal', 'allTimeSource', 'capitalModel', 'feesBrokerRub', 'openPnlBroker',
  'peakStale', 'userAssets'];
const rfPositionExtra = ['brokerPnl', 'brokerVarMargin', 'goRub', 'pnlPctGo'];
const tradeKeys = ['asset', 'entry', 'entryDay', 'exitDay', 'exitPx', 'exitReason', 'fees', 'id', 'pnl', 'rMultiple',
  'secid', 'side', 'title'];
const v2SummaryKeys = ['allTimeAmt', 'allTimeNote', 'allTimePct', 'capital', 'dataAgeMin', 'dayBase', 'entriesHalt',
  'extraStat', 'fees', 'haltReason', 'mode', 'todayAmt', 'todayPct', 'tradesPnl', 'winRate', 'wins'];
const v2PositionKeys = ['cur', 'entry', 'entryTs', 'id', 'lots', 'pctChg', 'secid', 'side', 'stop', 'title', 'tp1', 'upnl'];
const v2TradeKeys = ['entry', 'entryDay', 'exitDay', 'exitPx', 'exitReason', 'id', 'pnl', 'rMultiple', 'secid', 'side'];

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(value), 'utf8');
}

function assertDashboardContract(dashboard, currency, candleTf, extra = {}) {
  const { summary = [], position = [] } = extra;
  assert.deepEqual(Object.keys(dashboard).sort(), dashboardKeys);
  assert.equal(dashboard.currency, currency);
  assert.equal(dashboard.candleTf, candleTf);
  assert.deepEqual(Object.keys(dashboard.summary).sort(), [...summaryKeys, ...summary].sort());
  assert.equal(dashboard.positions.length, 1);
  assert.equal(dashboard.closedTrades.length, 1);
  assert.deepEqual(Object.keys(dashboard.positions[0]).sort(), [...positionKeys, ...position].sort());
  assert.deepEqual(Object.keys(dashboard.closedTrades[0]).sort(), tradeKeys);
  assert.equal(typeof dashboard.summary.dataAgeMin, 'number');
}

const overviewProjection = (dashboard) => ({
  currency: dashboard.currency,
  summary: Object.fromEntries(['capital', 'todayAmt', 'todayPct', 'openPositions', 'entriesHalt', 'haltReason', 'dataAgeMin']
    .map((key) => [key, dashboard.summary[key]]))
});

function assertV2Contract(v2) {
  assert.deepEqual(Object.keys(v2).sort(), ['canSwitch', 'candleTf', 'closedTrades', 'currency', 'equity', 'equityBase', 'portfolio', 'positions', 'summary']);
  assert.deepEqual(Object.keys(v2.summary).sort(), v2SummaryKeys);
  assert.deepEqual(Object.keys(v2.positions[0]).sort(), v2PositionKeys);
  assert.deepEqual(Object.keys(v2.closedTrades[0]).sort(), v2TradeKeys);
}

test('RF dashboard fixture preserves the common DTO contract', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mini-rf-contract-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const now = Date.now();
  const dataDir = path.join(root, 'rf');
  const namesPath = path.join(root, 'names.json');
  writeJson(path.join(dataDir, 'portfolio.json'), {
    mode: 'prod', profile_eq: 800000, peak_eq: 820000, meta: { base_rub: 700000 },
    day_start_eq: 100000, day_start_date: mskDay(now), watermarks: { last_eq_snap: now - 60000 },
    go: { bot_capital_rub: 105000, capital_peak_rub: 110000, used_rub: 20000, budget_rub: 50000 },
    entries_halt: { active: true, reason: 'risk limit' },
    sleeves: { core: { positions: [{ id: 'rf-1', asset: 'NG', secid: 'NGU6', side: 'long', lots: 2,
      entry_px_pts: 2.5, stop_px_pts: 2.2, cur_px: 2.7, tp1_px_pts: 2.9, rub_per_pt: 1000,
      upnl_rub: 400, risk_rub: 600, entry_day: '2026-08-17', entry_ts: now - 3600000 }] }, setA: { positions: [] } }
  });
  writeJson(path.join(dataDir, 'equity.json'), [{ ts: now - 120000, bot_capital: 100000, account_liquid: 100000, total: 750000 }]);
  writeJson(path.join(dataDir, 'trades.json'), [{ id: 'rf-trade', asset: 'NG', secid: 'NGU6', side: 'long', entryDay: '2026-08-16', entry: 2.4, exitDay: '2026-08-17', exitPx: 2.6, exitReason: 'tp', pnlRub: 200, rMultiple: 1, feesRub: 10 }]);
  writeJson(path.join(dataDir, 'candles', 'NG_1h.json'), [[now - 3600000, 2.4, 2.8, 2.3, 2.7]]);
  writeJson(namesPath, { fut: { NG: 'Natural Gas' } });

  const dashboard = readRfDashboard({ dataDir, namesPath, currency: 'RUB' });
  const overview = readRfOverview({ dataDir, currency: 'RUB' });
  assertDashboardContract(dashboard, 'RUB', '1ч', { summary: rfSummaryExtra, position: rfPositionExtra });
  assert.deepEqual(overview, overviewProjection(dashboard));
  assert.equal(dashboard.summary.capital, 105000);
  assert.equal(dashboard.summary.todayAmt, 5000);
  assert.equal(dashboard.summary.dayBaseSource, 'day_start_eq');
  assert.equal(dashboard.positions[0].title, 'Natural Gas');
  assert.deepEqual(readRfCandles({ dataDir, positionId: 'rf-1' }), {
    positionId: 'rf-1', candleTf: '1ч', candles: [[now - 3600000, 2.4, 2.8, 2.3, 2.7]]
  });
  assert.equal(readRfCandles({ dataDir, positionId: 'missing' }), null);
  const v2 = dashboardV2(dashboard, { id: 'rf', label: 'RF' }, true);
  assertV2Contract(v2);
  assert.equal(v2.portfolio.id, 'rf');
  assert.equal(v2.summary.peak, undefined);
  assert.equal(v2.positions[0].asset, undefined);
  assert.equal(v2.closedTrades[0].fees, undefined);
});

test('RF presentation snapshot is preferred and keeps its stale source timestamp', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mini-rf-presentation-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const dataDir = path.join(root, 'live_rf');
  const sourceAtMs = Date.now() - 46 * 60000;
  writeJson(path.join(root, 'rf_presentation_snapshot.json'), {
    schema: 1, sourceAtMs,
    summary: { capital: 123, peak: 130, drawdownPct: -5.38, dayBase: 120, dayBaseSource: 'prev_day_close',
      todayAmt: 3, todayPct: 2.5, allTimePct: 4, allTimeAmt: 5, allTimeNote: 'note', openPositions: 1,
      tradesPnl: 2, fees: 1, winRate: 100, wins: 1, losses: 0, mode: 'prod', entriesHalt: false, haltReason: '', goUsed: 10, goBudget: 20 },
    operational: { go: { used_rub: 10 }, drift: {}, stats: {}, capitalBreakdown: {}, active: {}, consecFail: 0 },
    sleeves: { core: { equity: 100, dayPct: 1 }, setA: { equity: 0, dayPct: 0 }, mom: { equity: 0, dayPct: 0 } },
    positions: [{ id: 'p1', sleeve: 'core', asset: 'NG', secid: 'NG', title: 'Gas', side: 'long', lots: 1, entry: 2, stop: 1, cur: 2.1, upnl: 3, risk: 1, entryDay: '2026-01-01', entryTs: 1 }],
    holdings: [], closedTrades: [], equity: [[1, 100]], capitalCurve: [[1, 100]]
  });
  const dashboard = readRfDashboard({ dataDir, namesPath: path.join(root, 'unused.json'), currency: 'RUB' });
  assert.equal(dashboard.summary.capital, 123);
  assert.equal(dashboard.summary.dayBaseSource, 'prev_day_close');
  assert.ok(dashboard.summary.dataAgeMin >= 46);
  assert.equal(dashboard.positions[0].candles, undefined);
});

test('RF snapshot with a broker block surfaces broker numbers verbatim', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mini-rf-broker-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const dataDir = path.join(root, 'live_rf');
  // Числа взяты с боевого счёта 2154036525 (2026-09-01 16:41 UTC) - если адаптер начнёт
  // что-то пересчитывать сам, тест это поймает: сверять кабинет можно только с приложением.
  writeJson(path.join(root, 'rf_presentation_snapshot.json'), {
    schema: 1, sourceAtMs: Date.now(),
    summary: { capital: 1568657.14, accountTotal: 1568657.14, userAssets: 0, capitalModel: 'legacy',
      peakStale: true, peak: 1723067.14, drawdownPct: null,
      dayBase: 1468093.14, dayBaseSource: 'broker_daily_yield', todayAmt: 100564, todayPct: 6.84,
      allTimePct: 9.69, allTimeAmt: 138539.52, allTimeNote: 'note', allTimeSource: 'broker_ops',
      openPositions: 1, tradesPnl: 106635.21, fees: 8361.64, feesBrokerRub: 21684.47, openPnlBroker: 116733,
      winRate: 66.7, wins: 12, losses: 6, mode: 'prod', entriesHalt: false, haltReason: '', goUsed: 10, goBudget: 20 },
    broker: { totals: { portfolio: 1568657.14 }, daily_yield_rub: 100564, positions: [] },
    operational: { go: {}, drift: {}, stats: {}, capitalBreakdown: {}, active: {}, consecFail: 0 },
    sleeves: { core: { equity: 0, dayPct: 0 }, setA: { equity: 0, dayPct: 0 }, mom: { equity: 0, dayPct: 0 } },
    positions: [{ id: 'L00045', sleeve: 'core', asset: 'Eu', secid: 'EuU6', title: 'евро', side: 'long',
      lots: 28, entry: 100570.36, stop: 98196, cur: 100753, upnl: 3574, risk: 75220, notional: 2815970,
      pctChg: 0.13, brokerPnl: 36680, goRub: 422230, pnlPctGo: 8.69, brokerVarMargin: 29316,
      entryDay: '2026-08-27', entryTs: 1 }],
    holdings: [], closedTrades: [], equity: [[1, 100]], capitalCurve: [[1, 100]]
  });
  const d = readRfDashboard({ dataDir, namesPath: path.join(root, 'unused.json'), currency: 'RUB' });
  assert.equal(d.summary.capital, 1568657.14);
  assert.equal(d.summary.todayAmt, 100564);
  assert.equal(d.summary.todayPct, 6.84);
  assert.equal(d.summary.dayBaseSource, 'broker_daily_yield');
  assert.equal(d.summary.allTimeAmt, 138539.52);
  assert.equal(d.summary.allTimeSource, 'broker_ops');
  assert.equal(d.summary.feesBrokerRub, 21684.47);
  assert.equal(d.summary.userAssets, 0);
  assert.equal(d.summary.peakStale, true);
  assert.equal(d.summary.drawdownPct, null);
  // главная цифра позиции - брокерская, процент - на ГО, а не движение цены
  assert.equal(d.positions[0].brokerPnl, 36680);
  assert.equal(d.positions[0].upnl, 3574);
  assert.equal(d.positions[0].goRub, 422230);
  assert.equal(d.positions[0].pnlPctGo, 8.69);
});

test('RF snapshot without a broker block degrades without crashing', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mini-rf-nobroker-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const dataDir = path.join(root, 'live_rf');
  // Снапшот со СТАРОГО движка: во время деплоя VPS и Actions какое-то время рассинхронны.
  writeJson(path.join(root, 'rf_presentation_snapshot.json'), {
    schema: 1, sourceAtMs: Date.now(),
    summary: { capital: 123, peak: 130, drawdownPct: -5.38, dayBase: 120, dayBaseSource: 'prev_day_close',
      todayAmt: 3, todayPct: 2.5, allTimePct: 4, allTimeAmt: 5, allTimeNote: 'note', openPositions: 1,
      tradesPnl: 2, fees: 1, winRate: 100, wins: 1, losses: 0, mode: 'prod', entriesHalt: false, haltReason: '' },
    operational: { go: {}, drift: {}, stats: {}, capitalBreakdown: {}, active: {}, consecFail: 0 },
    sleeves: { core: { equity: 0, dayPct: 0 }, setA: { equity: 0, dayPct: 0 }, mom: { equity: 0, dayPct: 0 } },
    positions: [{ id: 'p1', sleeve: 'core', asset: 'NG', secid: 'NG', title: 'Gas', side: 'long', lots: 1,
      entry: 2, stop: 1, cur: 2.1, upnl: 3, risk: 1, entryDay: '2026-01-01', entryTs: 1 }],
    holdings: [], closedTrades: [], equity: [[1, 100]], capitalCurve: [[1, 100]]
  });
  const d = readRfDashboard({ dataDir, namesPath: path.join(root, 'unused.json'), currency: 'RUB' });
  // ключи на месте (фронт их читает безусловно), значения - null, а не выдуманные нули
  assert.deepEqual(Object.keys(d.summary).sort(), [...summaryKeys, ...rfSummaryExtra].sort());
  assert.deepEqual(Object.keys(d.positions[0]).sort(), [...positionKeys, ...rfPositionExtra].sort());
  assert.equal(d.summary.accountTotal, null);
  assert.equal(d.summary.feesBrokerRub, null);
  assert.equal(d.summary.peakStale, false);
  assert.equal(d.positions[0].brokerPnl, null);
  assert.equal(d.positions[0].pnlPctGo, null);
  assert.equal(d.summary.capital, 123);
});

test('crypto dashboard fixture preserves the common DTO contract', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mini-crypto-contract-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const now = Date.now();
  const dataDir = path.join(root, 'crypto');
  const candlesDir = path.join(root, 'candles');
  writeJson(path.join(dataDir, 'portfolio.json'), {
    mode: 'live', equity_usd: 1000, peak_equity_usd: 1200, day_start_equity_usd: 900,
    day_start_date_utc: utcDay(now), trading_halted: true, entries_halt_reason: 'daily limit',
    open_trades: [{ id: 'crypto-1', symbol: 'BTC-USDT', side: 'short', qty: 0.1, entry_price: 100000,
      stop: 102000, tp1: 98000, notional_usd: 10000, cur_upnl_usd: 100, risk_usd: 200,
      entry_utc: '2026-08-17T10:00:00Z', entry_ts: now - 3600000 }]
  });
  writeJson(path.join(dataDir, 'live_equity.json'), [{ ts: now - 120000, eq: 800 }, { ts: now - 60000, eq: 1000 }]);
  writeJson(path.join(dataDir, 'live_trades.json'), [{ id: 'crypto-trade', sym: 'BTC-USDT', side: 'short', entryDay: '2026-08-16', entry: 101000, exitDay: '2026-08-17', exitPx: 99000, exitReason: 'tp', pnlUsd: 200, rMultiple: 1, fees: 8, funding: 2 }]);
  writeJson(path.join(candlesDir, 'BTC_USDT_4h.json'), [{ t: now - 14400000, o: 101000, h: 102000, l: 99000, c: 100000 }]);

  const dashboard = readCryptoDashboard({ dataDir, candlesDir, currency: 'USD' });
  const overview = readCryptoOverview({ dataDir, currency: 'USD' });
  assertDashboardContract(dashboard, 'USD', '4ч');
  assert.deepEqual(overview, overviewProjection(dashboard));
  assert.equal(dashboard.summary.capital, 1000);
  assert.equal(dashboard.summary.todayAmt, 100);
  assert.equal(dashboard.summary.dayBaseSource, 'day_start');
  assert.equal(dashboard.positions[0].cur, 99000);
  assert.deepEqual(readCryptoCandles({ dataDir, candlesDir, positionId: 'crypto-1' }), {
    positionId: 'crypto-1', candleTf: '4ч', candles: [[now - 14400000, 101000, 102000, 99000, 100000]]
  });
  assert.equal(readCryptoCandles({ dataDir, candlesDir, positionId: 'missing' }), null);
  assert.equal(dashboard.closedTrades[0].fees, 10);
  assertV2Contract(dashboardV2(dashboard, { id: 'crypto', label: 'Crypto' }, false));
});

test('v2 portfolio rows omit admin and internal error details', () => {
  const v2 = portfoliosV2([{
    id: 'rf', label: 'RF', currency: 'RUB', capital: 100, todayAmt: 2, todayPct: 2,
    openPositions: 1, status: 'error', dataAgeMin: 7, error: 'internal path'
  }]);
  assert.deepEqual(v2, { portfolios: [{
    id: 'rf', label: 'RF', currency: 'RUB', capital: 100, todayAmt: 2, todayPct: 2,
    openPositions: 1, status: 'error', dataAgeMin: 7
  }] });
});

test('overview adapters skip detail-only files', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mini-overview-reads-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const now = Date.now();
  const rfDir = path.join(root, 'rf');
  const cryptoDir = path.join(root, 'crypto');
  writeJson(path.join(rfDir, 'portfolio.json'), {
    profile_eq: 10, watermarks: { last_eq_snap: now }, sleeves: { core: { positions: [] }, setA: { positions: [] } }
  });
  writeJson(path.join(rfDir, 'equity.json'), []);
  writeJson(path.join(cryptoDir, 'portfolio.json'), { equity_usd: 10, open_trades: [] });
  writeJson(path.join(cryptoDir, 'live_equity.json'), []);

  const reads = [];
  const readFileSync = fs.readFileSync;
  fs.readFileSync = (file, ...args) => {
    reads.push(path.basename(String(file)));
    return readFileSync(file, ...args);
  };
  try {
    readRfOverview({ dataDir: rfDir });
    readCryptoOverview({ dataDir: cryptoDir });
  } finally {
    fs.readFileSync = readFileSync;
  }

  assert.deepEqual(reads.sort(), ['equity.json', 'live_equity.json', 'portfolio.json', 'portfolio.json', 'rf_presentation_snapshot.json']);
});
