import fs from 'node:fs';

/** Общее для адаптеров контуров: чтение файлов движка и арифметика показателей. */

// Последний удачный разбор каждого файла. Движки переписывают JSON не атомарно, и чтение
// может попасть в момент записи — тогда отдаём предыдущее валидное состояние, а не роняем
// весь кабинет из-за одной оборванной строки.
const lastGood = new Map();

/**
 * Часть файлов записана с BOM (крипто-свечи в data/*_4h.json). JSON.parse на BOM бросает
 * исключение, и без среза оно ушло бы в catch — свечи молча оказались бы пустыми.
 */
export function readJson(filePath, fallback = null) {
  try {
    const text = fs.readFileSync(filePath, 'utf8').replace(/^﻿/, '');
    const parsed = JSON.parse(text);
    lastGood.set(filePath, parsed);
    return parsed;
  } catch {
    return lastGood.get(filePath) ?? fallback;
  }
}

// null/undefined/'' -> null, а не 0: Number(null) === 0, и без явной проверки отсутствующий
// тейк отрисовался бы ценой «0».
export const num = (value) => {
  if (value === null || value === undefined || value === '') return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
};

export const pct = (now, base) => (num(now) !== null && num(base) > 0 ? (num(now) / num(base) - 1) * 100 : null);
export const round = (value, digits = 2) => (num(value) === null ? null : Number(num(value).toFixed(digits)));

/** Дата в таймзоне MOEX (MSK = UTC+3) — RF-движок ведёт торговый день именно по ней. */
export const mskDay = (ms = Date.now()) => new Date(ms + 3 * 3600000).toISOString().slice(0, 10);
export const utcDay = (ms = Date.now()) => new Date(ms).toISOString().slice(0, 10);

/** Равномерное прореживание ряда до ~limit точек с обязательным сохранением последней. */
export function downsample(rows, limit) {
  if (rows.length <= limit) return rows;
  const step = (rows.length - 1) / (limit - 1);
  const out = [];
  for (let i = 0; i < limit; i += 1) out.push(rows[Math.round(i * step)]);
  if (out.at(-1) !== rows.at(-1)) out[out.length - 1] = rows.at(-1);
  return out;
}

/**
 * Свечи к одной форме [ts, o, h, l, c]. RF-движок пишет массивы, крипто-конвейер — объекты
 * {t,o,h,l,c,v}; график в кабинете один, значит и вход у него должен быть один.
 */
export function normalizeCandles(rows, limit) {
  if (!Array.isArray(rows)) return [];
  const out = [];
  for (const c of rows.slice(-limit)) {
    if (Array.isArray(c) && c.length >= 5) {
      const [t, o, h, l, cl] = c.map(num);
      if (t !== null && o !== null && h !== null && l !== null && cl !== null) out.push([t, o, h, l, cl]);
    } else if (c && typeof c === 'object') {
      const t = num(c.t ?? c.ts);
      const o = num(c.o);
      const h = num(c.h);
      const l = num(c.l);
      const cl = num(c.c);
      if (t !== null && o !== null && h !== null && l !== null && cl !== null) out.push([t, o, h, l, cl]);
    }
  }
  return out;
}

/** Возраст снимка в минутах — по нему кабинет говорит «данные устарели». */
export const ageMin = (ms) => (num(ms) ? Math.max(0, Math.round((Date.now() - num(ms)) / 60000)) : null);

export const winStats = (trades, pnlKey) => {
  const wins = trades.filter((t) => num(t[pnlKey]) > 0).length;
  return { wins, losses: trades.length - wins, winRate: trades.length ? round((wins / trades.length) * 100, 1) : null };
};
