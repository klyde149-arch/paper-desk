import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { readCryptoDashboard, readCryptoOverview } from './crypto-data.js';
import { readRfDashboard, readRfOverview } from './rf-data.js';
import { dashboardV2, portfoliosV2 } from './api-v2.js';
import { mskDay, utcDay } from './util.js';

const dashboardKeys = ['candleTf', 'closedTrades', 'currency', 'equity', 'equityBase', 'positions', 'summary'];
const summaryKeys = ['allTimeAmt', 'allTimeNote', 'allTimePct', 'capital', 'dataAgeMin', 'dayBase', 'dayBaseSource',
  'drawdownPct', 'entriesHalt', 'extraStat', 'fees', 'haltReason', 'losses', 'mode', 'openPositions', 'peak',
  'todayAmt', 'todayPct', 'tradesPnl', 'winRate', 'wins'];
const positionKeys = ['asset', 'candles', 'cur', 'entry', 'entryDay', 'entryTs', 'id', 'lots', 'notional', 'pctChg',
  'risk', 'secid', 'side', 'sleeve', 'stop', 'title', 'tp1', 'upnl'];
const tradeKeys = ['asset', 'entry', 'entryDay', 'exitDay', 'exitPx', 'exitReason', 'fees', 'id', 'pnl', 'rMultiple',
  'secid', 'side', 'title'];
const v2SummaryKeys = ['allTimeAmt', 'allTimeNote', 'allTimePct', 'capital', 'dataAgeMin', 'dayBase', 'entriesHalt',
  'extraStat', 'fees', 'haltReason', 'mode', 'todayAmt', 'todayPct', 'tradesPnl', 'winRate', 'wins'];
const v2PositionKeys = ['candles', 'cur', 'entry', 'entryTs', 'id', 'lots', 'pctChg', 'secid', 'side', 'stop', 'title', 'tp1', 'upnl'];
const v2TradeKeys = ['entry', 'entryDay', 'exitDay', 'exitPx', 'exitReason', 'id', 'pnl', 'rMultiple', 'secid', 'side'];

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(value), 'utf8');
}

function assertDashboardContract(dashboard, currency, candleTf) {
  assert.deepEqual(Object.keys(dashboard).sort(), dashboardKeys);
  assert.equal(dashboard.currency, currency);
  assert.equal(dashboard.candleTf, candleTf);
  assert.deepEqual(Object.keys(dashboard.summary).sort(), summaryKeys);
  assert.equal(dashboard.positions.length, 1);
  assert.equal(dashboard.closedTrades.length, 1);
  assert.deepEqual(Object.keys(dashboard.positions[0]).sort(), positionKeys);
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
  assertDashboardContract(dashboard, 'RUB', '1ч');
  assert.deepEqual(overview, overviewProjection(dashboard));
  assert.equal(dashboard.summary.capital, 105000);
  assert.equal(dashboard.summary.todayAmt, 5000);
  assert.equal(dashboard.summary.dayBaseSource, 'day_start_eq');
  assert.equal(dashboard.positions[0].title, 'Natural Gas');
  const v2 = dashboardV2(dashboard, { id: 'rf', label: 'RF' }, true);
  assertV2Contract(v2);
  assert.equal(v2.portfolio.id, 'rf');
  assert.equal(v2.summary.peak, undefined);
  assert.equal(v2.positions[0].asset, undefined);
  assert.equal(v2.closedTrades[0].fees, undefined);
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

  assert.deepEqual(reads.sort(), ['equity.json', 'live_equity.json', 'portfolio.json', 'portfolio.json']);
});
