import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { createRoot } from 'react-dom/client';
import './styles.css';

const telegram = window.Telegram?.WebApp;

const dec2 = new Intl.NumberFormat('ru-RU', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const has = (v) => v !== null && v !== undefined && Number.isFinite(Number(v));
const dirOf = (v) => (has(v) ? (v >= 0 ? 'up' : 'down') : 'flat');

/**
 * Деньги считаются в валюте портфеля: рубли у фьючерсов, доллары у крипты. Крипто-суммы
 * мелкие (десятки долларов), поэтому там обязательны копейки, а у рублей они только шумят.
 */
function makeFmt(currency) {
  const sym = currency === 'USD' ? '$' : '₽';
  const dec = currency === 'USD' ? 2 : 0;
  const n = new Intl.NumberFormat('ru-RU', { minimumFractionDigits: dec, maximumFractionDigits: dec });
  const n2 = new Intl.NumberFormat('ru-RU', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return {
    sym,
    money: (v) => (has(v) ? `${n.format(v)} ${sym}` : '—'),
    money2: (v) => (has(v) ? `${n2.format(v)} ${sym}` : '—'),
    signMoney: (v) => (has(v) ? `${v >= 0 ? '+' : '−'}${n.format(Math.abs(v))} ${sym}` : '—')
  };
}

const signPct = (v) => (has(v) ? `${v >= 0 ? '+' : '−'}${dec2.format(Math.abs(v))}%` : '—');

/** Цены разной шкалы: нефть ~83, юань ~12,6, ARB ~0,078. */
function pts(v) {
  if (!has(v)) return '—';
  const a = Math.abs(v);
  const d = a >= 1000 ? 0 : a >= 100 ? 2 : a >= 10 ? 3 : a >= 1 ? 4 : 5;
  return new Intl.NumberFormat('ru-RU', { minimumFractionDigits: d, maximumFractionDigits: d }).format(v);
}

const tick = (secid) => String(secid ?? '').toUpperCase();
const hhmm = (ts) => new Date(ts).toLocaleString('ru-RU', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });
const dmy = (ts) => new Date(ts).toLocaleDateString('ru-RU', { day: '2-digit', month: '2-digit' });
const press = () => telegram?.HapticFeedback?.selectionChanged?.();

/* ---------------- свечной график позиции ---------------- */

/**
 * Часовые (фьючерсы) или четырёхчасовые (крипта) свечи с уровнями сделки. Зона риска между
 * входом и стопом, зона прибыли до цели, пунктирные уровни, маркер входа, шкала цены справа.
 * Всё на SVG и без анимации: график виден сразу, даже если таймлайн анимаций замер.
 */
function Candles({ position, tf, candles, error }) {
  const k = candles ?? [];

  const g = useMemo(() => {
    if (k.length < 2) return null;
    const W = 340;
    const H = 232;
    const m = { t: 10, r: 42, b: 18, l: 6 };
    const iw = W - m.l - m.r;
    const ih = H - m.t - m.b;

    const marks = [position.stop, position.entry, position.tp1].filter(has);
    let lo = Math.min(...k.map((c) => c[3]), ...marks);
    let hi = Math.max(...k.map((c) => c[2]), ...marks);
    const pad = (hi - lo) * 0.06 || 1;
    lo -= pad;
    hi += pad;

    const t0 = k[0][0];
    const t1 = k.at(-1)[0];
    return {
      W, H, m, iw, lo, hi, t0, t1,
      X: (ts) => m.l + ((ts - t0) / (t1 - t0 || 1)) * iw,
      Y: (v) => m.t + ih - ((v - lo) / (hi - lo || 1)) * ih,
      bw: Math.max(1.4, (iw / k.length) * 0.62),
      last: k.at(-1)
    };
  }, [k, position.stop, position.entry, position.tp1]);

  if (error) return <div className="none">Свечи сейчас недоступны. Терминал продолжает работать.</div>;
  if (!g) return <div className="none">Свечей по этому инструменту нет — движок ещё не испёк файл.</div>;

  const { W, H, m, iw, Y, X, bw } = g;

  // Подпись уровня лежит внутри поля с чёрной обводкой: поверх свечей она обязана читаться,
  // а справа для неё нет места — там шкала цены. Совпавшие уровни (стоп переставлен в
  // безубыток — тогда вход равен стопу) разводим по вертикали, иначе одна подпись
  // полностью закрывает другую и уровень выглядит отсутствующим.
  const taken = [];
  const lvl = (v, color, label) => {
    if (!has(v)) return null;
    let y = Y(v) - 4;
    while (taken.some((t) => Math.abs(t - y) < 10)) y -= 10;
    taken.push(y);
    return (
      <g key={label}>
        <line x1={m.l} x2={m.l + iw} y1={Y(v)} y2={Y(v)} stroke={color} strokeWidth="1" strokeDasharray="5 4" />
        <text x={m.l + 4} y={y} fill={color} fontSize="8.5" fontWeight="700" letterSpacing=".06em" stroke="#000" strokeWidth="2.5" paintOrder="stroke">
          {label} {pts(v)}
        </text>
      </g>
    );
  };

  // Зона риска от входа до стопа, зона прибыли до цели. Без цели зоны прибыли нет вовсе.
  const zone = (a, b, fill) => {
    if (!has(a) || !has(b)) return null;
    const y1 = Math.min(Y(a), Y(b));
    return <rect x={m.l} y={y1} width={iw} height={Math.max(0, Math.abs(Y(a) - Y(b)))} fill={fill} />;
  };

  const entryX = has(position.entryTs) && position.entryTs >= g.t0 ? X(position.entryTs) : null;

  return (
    <>
      <div className="chart">
        <svg viewBox={`0 0 ${W} ${H}`} role="img">
          <title>
            {tick(position.secid)}: свечи {tf}, вход {pts(position.entry)}, стоп {pts(position.stop)}
          </title>
          {zone(position.entry, position.stop, 'rgba(255,69,58,.13)')}
          {zone(position.entry, position.tp1, 'rgba(37,211,102,.13)')}

          {[0, 0.25, 0.5, 0.75, 1].map((f) => {
            const v = g.lo + (g.hi - g.lo) * f;
            return (
              <g key={f}>
                <line x1={m.l} x2={m.l + iw} y1={Y(v)} y2={Y(v)} stroke="rgba(255,176,0,.10)" strokeWidth="1" />
                <text x={m.l + iw + 5} y={Y(v) + 3.5} fill="#b57d00" fontSize="8.5">{pts(v)}</text>
              </g>
            );
          })}

          {k.map((c) => {
            const col = c[4] >= c[1] ? '#25d366' : '#ff453a';
            const x = X(c[0]);
            const yO = Y(c[1]);
            const yC = Y(c[4]);
            return (
              <g key={c[0]}>
                <line x1={x} x2={x} y1={Y(c[2])} y2={Y(c[3])} stroke={col} strokeWidth="1" />
                <rect x={x - bw / 2} y={Math.min(yO, yC)} width={bw} height={Math.max(1, Math.abs(yC - yO))} fill={col} />
              </g>
            );
          })}

          {lvl(position.tp1, '#25d366', 'ЦЕЛЬ')}
          {lvl(position.entry, '#ffb000', 'ВХОД')}
          {lvl(position.stop, '#ff453a', 'СТОП')}

          {entryX !== null && has(position.entry) && (
            <polygon points={`${entryX},${Y(position.entry) - 9} ${entryX - 5},${Y(position.entry) - 18} ${entryX + 5},${Y(position.entry) - 18}`} fill="#ffb000" />
          )}
        </svg>
      </div>
      <div className="chart-note">
        <span>{hhmm(g.t0)}</span>
        <span>{k.length} БАРОВ · {tf} · ПОСЛ. {pts(g.last[4])}</span>
        <span>{hhmm(g.t1)}</span>
      </div>
    </>
  );
}

/* ---------------- кривая доходности ---------------- */

function Equity({ points, base, allTimePct, fmt }) {
  const g = useMemo(() => {
    if (points.length < 2) return null;
    const W = 340;
    const H = 96;
    const vals = points.map(([, v]) => v);
    const lo = Math.min(...vals, base ?? Infinity);
    const hi = Math.max(...vals, base ?? -Infinity);
    const span = hi - lo || 1;
    const Y = (v) => 6 + (H - 12) * (1 - (v - lo) / span);
    return {
      W, H,
      line: points.map(([, v], i) => `${((i / (points.length - 1)) * W).toFixed(1)},${Y(v).toFixed(1)}`).join(' '),
      baseY: has(base) ? Y(base) : null,
      up: vals.at(-1) >= (base ?? vals[0])
    };
  }, [points, base]);

  if (!g) return null;

  return (
    <section className="sec">
      <div className="sec-head">
        <span className="lbl">Доходность стратегии</span>
        <span className={`r ${dirOf(allTimePct)}`}>{signPct(allTimePct)}</span>
      </div>
      <div className="chart">
        <svg className="flat" viewBox={`0 0 ${g.W} ${g.H}`} preserveAspectRatio="none" role="img">
          <title>Кривая доходности</title>
          {g.baseY !== null && <line x1="0" x2={g.W} y1={g.baseY} y2={g.baseY} stroke="rgba(255,176,0,.28)" strokeWidth="1" strokeDasharray="4 4" />}
          <polyline points={g.line} fill="none" stroke={g.up ? '#25d366' : '#ff453a'} strokeWidth="1.4" strokeLinejoin="round" vectorEffect="non-scaling-stroke" />
        </svg>
      </div>
      <div className="chart-note">
        <span>{dmy(points[0][0])}</span>
        <span>БАЗА {fmt.money(base)}</span>
        <span>{dmy(points.at(-1)[0])}</span>
      </div>
    </section>
  );
}

/* ---------------- сводка по портфелям (только у кого их больше одного) ---------------- */

function Overview({ rows, onOpen, onReload, loading }) {
  // Лампа в шапке показывает худшее состояние: зелёная только когда все контуры живы.
  const bad = rows.filter((p) => p.status !== 'live').length;
  return (
    <main className="term">
      <div className="cmd">
        <span>ПОРТФЕЛИ <span className="go">&lt;GO&gt;</span></span>
        <span className={`state ${bad ? 'bad' : ''}`}>
          <i className="led" />
          {bad ? `${bad} ИЗ ${rows.length} МОЛЧАТ` : `${rows.length} ШТ. LIVE`}
        </span>
      </div>

      <section className="sec">
        <table className="grid">
          <thead>
            <tr>
              <th>Портфель</th>
              <th>Капитал</th>
              <th>За сегодня</th>
              <th>Поз.</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((p) => {
              const f = makeFmt(p.currency);
              return (
                <tr key={p.id} className="pick" onClick={() => { press(); onOpen(p.id); }}>
                  <td>
                    <span className="sym">{p.label}</span>
                    <span className={`sub ${p.status === 'live' ? 'up' : 'down'}`}>
                      {p.status === 'error' ? 'ОШИБКА' : p.status === 'stale' ? `НЕТ СВЯЗИ ${p.dataAgeMin}М` : p.status === 'halt' ? 'ПАУЗА' : 'LIVE'}
                    </span>
                  </td>
                  <td>{f.money(p.capital)}</td>
                  <td className={dirOf(p.todayAmt)}>
                    {f.signMoney(p.todayAmt)}
                    <span className="sub">{signPct(p.todayPct)}</span>
                  </td>
                  <td>{has(p.openPositions) ? p.openPositions : '—'}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </section>

      <div className="bottom">
        <button type="button" className="key" onClick={onReload} disabled={loading}>
          {loading ? 'Чтение…' : 'Обновить'}
        </button>
        <span className="ts">тап по строке — открыть терминал</span>
      </div>
    </main>
  );
}

/* ---------------- терминал портфеля ---------------- */

function Terminal({ data, onBack, onReload, loading, initData }) {
  const [reg, setReg] = useState('day');
  const [pick, setPick] = useState(null);
  const [candles, setCandles] = useState([]);
  const [candleError, setCandleError] = useState(false);

  const { summary: s, positions = [], closedTrades = [], equity = [], equityBase, portfolio, canSwitch, candleTf } = data;
  const fmt = useMemo(() => makeFmt(data.currency), [data.currency]);
  const stale = has(s.dataAgeMin) && s.dataAgeMin > 45;
  const sel = positions.find((p) => p.id === pick) ?? positions[0] ?? null;

  useEffect(() => {
    const abort = new AbortController();
    setCandles([]);
    setCandleError(false);
    if (!sel?.id || !portfolio?.id) return () => abort.abort();
    fetch(`/api/candles?portfolio=${encodeURIComponent(portfolio.id)}&position=${encodeURIComponent(sel.id)}`, {
      signal: abort.signal,
      headers: { 'X-Telegram-Init-Data': initData }
    })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
      .then((d) => { if (!abort.signal.aborted) setCandles(Array.isArray(d.candles) ? d.candles : []); })
      .catch((e) => { if (!abort.signal.aborted && e.name !== 'AbortError') setCandleError(true); });
    return () => abort.abort();
  }, [portfolio?.id, sel?.id, initData]);

  const regs = {
    day: { v: fmt.signMoney(s.todayAmt), p: signPct(s.todayPct), of: s.todayAmt, cap: `БАЗА ДНЯ ${fmt.money(s.dayBase)}` },
    trades: { v: fmt.signMoney(s.tradesPnl), p: `${closedTrades.length} СД.`, of: s.tradesPnl, cap: `КОМИССИЙ ${fmt.money2(s.fees)}` },
    all: { v: signPct(s.allTimePct), p: fmt.money(s.allTimeAmt), of: s.allTimePct, cap: (s.allTimeNote ?? '').toUpperCase() }
  };
  const r = regs[reg];

  return (
    <main className="term">
      <div className="cmd">
        <span>
          {portfolio.label} <span className="go">&lt;GO&gt;</span> · {s.mode === 'prod' ? 'РЕАЛ' : (s.mode || '—').toUpperCase()}
        </span>
        <span className={`state ${stale || s.entriesHalt ? 'bad' : ''}`}>
          <i className="led" />
          {stale ? `STALE ${s.dataAgeMin}M` : s.entriesHalt ? 'HALT' : 'LIVE'}
        </span>
      </div>

      {(s.entriesHalt || stale) && (
        <div className="warn" role="status">
          <span className="bang">!!</span>
          <div>
            {s.entriesHalt && (
              <>
                <b>Новые входы остановлены.</b> {s.haltReason || 'Причина — в логах движка.'}
                {stale && <br />}
              </>
            )}
            {stale && (
              <>
                <b>Данные устарели на {s.dataAgeMin} мин.</b> Движок пишет их каждые 15 минут — возможно, он замолчал.
              </>
            )}
          </div>
        </div>
      )}

      {positions.length > 0 && (
        <div className="tape" role="group" aria-label="Открытые позиции">
          {positions.map((p) => (
            <button key={p.id} type="button" aria-pressed={sel?.id === p.id} onClick={() => { press(); setPick(p.id); }}>
              <span className="sym">{tick(p.secid)}</span>
              <span className="px">{pts(p.cur)}</span>
              <span className={`ch ${dirOf(p.pctChg)}`}>{signPct(p.pctChg)}</span>
            </button>
          ))}
        </div>
      )}

      <section className="sec">
        <div className="tot">
          <div className="keys" role="tablist" aria-label="Регистр итога">
            {[['day', 'F1 День'], ['trades', 'F2 Сделки'], ['all', 'F3 Всё время']].map(([id, label]) => (
              <button key={id} type="button" role="tab" aria-selected={reg === id} onClick={() => { press(); setReg(id); }}>
                {label}
              </button>
            ))}
          </div>

          <div className="row1">
            <span className={`big ${dirOf(r.of)}`}>{r.v}</span>
            <span className={`pc ${dirOf(r.of)}`}>{r.p}</span>
          </div>
          <div className="cap">{r.cap}</div>

          <div className="stats">
            <div>
              <div className="lbl">Капитал</div>
              <div className="v">{fmt.money(s.capital)}</div>
            </div>
            <div>
              <div className="lbl">{s.extraStat?.label ?? '—'}</div>
              <div className="v">{s.extraStat?.value ?? '—'}</div>
            </div>
            <div>
              <div className="lbl">Винрейт</div>
              <div className="v">{has(s.winRate) ? `${Math.round(s.winRate)}%` : '—'}</div>
            </div>
          </div>
        </div>
      </section>

      {sel && (
        <section className="sec">
          <div className="sec-head">
            <span className="lbl">{tick(sel.secid)} · {sel.title}</span>
            <span className={`r ${dirOf(sel.upnl)}`}>{fmt.signMoney(sel.upnl)}</span>
          </div>
          <Candles position={sel} tf={candleTf ?? '1ч'} candles={candles} error={candleError} />
        </section>
      )}

      <section className="sec">
        <div className="sec-head">
          <span className="lbl">Позиции</span>
          <span className="r">{positions.length} откр.</span>
        </div>
        {positions.length ? (
          <table className="grid">
            <thead>
              <tr>
                <th>Тикер</th>
                <th>Объём</th>
                <th>Вход</th>
                <th>Тек.</th>
                <th>P&amp;L</th>
                <th>%</th>
              </tr>
            </thead>
            <tbody>
              {positions.map((p) => (
                <tr key={p.id} className={`pick ${sel?.id === p.id ? 'on' : ''}`} onClick={() => { press(); setPick(p.id); }}>
                  <td>
                    <span className="sym">{tick(p.secid)}</span>
                    <span className={`sub side ${p.side === 'long' ? 'up' : 'down'}`}>{p.side === 'long' ? 'ЛОНГ' : 'ШОРТ'}</span>
                  </td>
                  <td>{pts(p.lots)}</td>
                  <td>{pts(p.entry)}</td>
                  <td>{pts(p.cur)}</td>
                  <td className={dirOf(p.upnl)}>{fmt.signMoney(p.upnl)}</td>
                  <td className={dirOf(p.pctChg)}>{signPct(p.pctChg)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : (
          <div className="none">
            <b>Позиций нет</b>
            Движок ждёт сигнала. Это норма, а не сбой.
          </div>
        )}
      </section>

      <Equity points={equity} base={equityBase} allTimePct={s.allTimePct} fmt={fmt} />

      <section className="sec">
        <div className="sec-head">
          <span className="lbl">Закрытые сделки</span>
          <span className="r">{s.wins}/{closedTrades.length} · {has(s.winRate) ? `${Math.round(s.winRate)}%` : '—'}</span>
        </div>
        {closedTrades.length ? (
          <>
            <p className="prose">
              Итог <b className={dirOf(s.tradesPnl)}>{fmt.signMoney(s.tradesPnl)}</b>, комиссий {fmt.money2(s.fees)}.
              Таблица шире экрана — листайте вбок.
            </p>
            <div className="scroll">
              <table className="grid">
                <thead>
                  <tr>
                    <th>Тикер</th>
                    <th>Вход</th>
                    <th>Выход</th>
                    <th>Цена вх.</th>
                    <th>Цена вых.</th>
                    <th>Причина</th>
                    <th>R</th>
                    <th>P&amp;L</th>
                  </tr>
                </thead>
                <tbody>
                  {closedTrades.map((t) => (
                    <tr key={t.id}>
                      <td>
                        <span className="sym">{tick(t.secid)}</span>
                        <span className={`sub side ${t.side === 'long' ? 'up' : 'down'}`}>{t.side === 'long' ? 'ЛОНГ' : 'ШОРТ'}</span>
                      </td>
                      <td>{t.entryDay}</td>
                      <td>{t.exitDay}</td>
                      <td>{pts(t.entry)}</td>
                      <td>{pts(t.exitPx)}</td>
                      <td className="dim">{t.exitReason || '—'}</td>
                      <td className={dirOf(t.rMultiple)}>
                        {has(t.rMultiple) ? `${t.rMultiple >= 0 ? '+' : '−'}${dec2.format(Math.abs(t.rMultiple))}R` : '—'}
                      </td>
                      <td className={dirOf(t.pnl)}>{fmt.signMoney(t.pnl)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </>
        ) : (
          <div className="none">
            <b>Сделок нет</b>
            Каждая закрытая сделка попадёт сюда — и прибыльная, и убыточная.
          </div>
        )}
      </section>

      <div className="bottom">
        {/* Клавиши возврата нет у владельца одного портфеля: он не должен догадываться об остальных. */}
        {canSwitch && (
          <button type="button" className="key" onClick={onBack}>
            ESC ← Все
          </button>
        )}
        <button type="button" className="key" onClick={onReload} disabled={loading}>
          {loading ? 'Чтение…' : 'Обновить'}
        </button>
        <span className="ts">{has(s.dataAgeMin) ? `снимок ${s.dataAgeMin} мин назад` : 'без отметки'}</span>
      </div>
    </main>
  );
}

/* ---------------- приложение ---------------- */

function Boot({ title, body, action, onAction }) {
  return (
    <main className="boot">
      <h1>{title}<span className="caret">_</span></h1>
      <p>{body}</p>
      {action && <button type="button" className="key" onClick={onAction}>{action}</button>}
    </main>
  );
}

function App() {
  const [list, setList] = useState(null);
  const [open, setOpen] = useState(null); // id открытого портфеля
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const [version, setVersion] = useState(0);

  const reload = useCallback(() => setVersion((v) => v + 1), []);

  useEffect(() => {
    telegram?.ready();
    telegram?.expand();
    document.documentElement.dataset.theme = 'dark';
    telegram?.setHeaderColor?.('#000000');
  }, []);

  const headers = { 'X-Telegram-Init-Data': telegram?.initData ?? '' };

  const explain = (r) => {
    if (r.status === 401) return 'Сессия Telegram истекла. Закройте терминал и откройте снова.';
    if (r.status === 403) return 'У этого аккаунта нет доступа.';
    if (r.status === 503) return 'Движок перезаписывает состояние. Повторите через минуту.';
    return 'Нет связи с сервером.';
  };

  // Список портфелей: он же решает, показывать сводку или сразу терминал.
  useEffect(() => {
    const abort = new AbortController();
    setError('');
    setLoading(true);
    fetch('/api/v2/portfolios', { signal: abort.signal, headers })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(explain(r)))))
      .then((d) => {
        if (abort.signal.aborted) return;
        setList(d.portfolios);
        setOpen((cur) => cur ?? (d.portfolios.length === 1 ? d.portfolios[0].id : null));
        setLoading(false);
      })
      .catch((e) => {
        if (!abort.signal.aborted && e.name !== 'AbortError') { setError(e.message); setLoading(false); }
      });
    return () => abort.abort();
  }, [version]);

  useEffect(() => {
    if (!open) { setData(null); return undefined; }
    const abort = new AbortController();
    setError('');
    setLoading(true);
    fetch(`/api/v2/dashboard?portfolio=${encodeURIComponent(open)}`, { signal: abort.signal, headers })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(explain(r)))))
      .then((d) => { if (!abort.signal.aborted) { setData(d); setLoading(false); } })
      .catch((e) => {
        if (!abort.signal.aborted && e.name !== 'AbortError') { setError(e.message); setLoading(false); }
      });
    return () => abort.abort();
  }, [open, version]);

  if (error) return <Boot title="Ошибка терминала" body={error} action="Повторить" onAction={reload} />;
  if (!list) return <Boot title="Подключение" body="Читаем список портфелей…" />;
  if (!list.length) return <Boot title="Нет доступа" body="Для этого аккаунта не заведено ни одного портфеля." />;

  if (!open) return <Overview rows={list} onOpen={setOpen} onReload={reload} loading={loading} />;
  if (!data) return <Boot title="Подключение" body="Читаем состояние контура…" />;

  return (
    <Terminal
      key={`${open}:${version}`}
      data={data}
      loading={loading}
      initData={telegram?.initData ?? ''}
      onReload={reload}
      onBack={() => { press(); setOpen(null); }}
    />
  );
}

createRoot(document.getElementById('root')).render(<App />);
