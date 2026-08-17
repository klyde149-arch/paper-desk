const pick = (source, keys) => Object.fromEntries(keys.map((key) => [key, source[key]]));

const SUMMARY_KEYS = [
  'capital', 'todayAmt', 'todayPct', 'dayBase', 'allTimePct', 'allTimeAmt', 'allTimeNote',
  'tradesPnl', 'fees', 'winRate', 'wins', 'mode', 'entriesHalt', 'haltReason', 'extraStat', 'dataAgeMin'
];
const POSITION_KEYS = ['id', 'secid', 'title', 'side', 'lots', 'entry', 'stop', 'tp1', 'cur', 'upnl', 'pctChg', 'entryTs', 'candles'];
const CLOSED_TRADE_KEYS = ['id', 'secid', 'side', 'entryDay', 'entry', 'exitDay', 'exitPx', 'exitReason', 'pnl', 'rMultiple'];
const PORTFOLIO_ROW_KEYS = ['id', 'label', 'currency', 'capital', 'todayAmt', 'todayPct', 'openPositions', 'status', 'dataAgeMin'];

/**
 * Versioned, client-focused DTO. v1 remains untouched for external consumers.
 * Do not put broker/raw state or Telegram user data into this response.
 */
export function dashboardV2(data, portfolio, canSwitch) {
  return {
    portfolio: pick(portfolio, ['id', 'label']),
    canSwitch: Boolean(canSwitch),
    currency: data.currency,
    candleTf: data.candleTf,
    summary: pick(data.summary, SUMMARY_KEYS),
    positions: (data.positions ?? []).map((position) => pick(position, POSITION_KEYS)),
    closedTrades: (data.closedTrades ?? []).map((trade) => pick(trade, CLOSED_TRADE_KEYS)),
    equity: data.equity ?? [],
    equityBase: data.equityBase
  };
}

export function portfoliosV2(rows) {
  return { portfolios: rows.map((row) => pick(row, PORTFOLIO_ROW_KEYS)) };
}
