import 'dotenv/config';
import express from 'express';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { dashboardV2, portfoliosV2 } from './api-v2.js';
import { readCryptoCandles, readCryptoDashboard, readCryptoOverview } from './crypto-data.js';
import { logAccess, openDatabase, upsertUser } from './database.js';
import { loadPortfolios } from './portfolios.js';
import { readRfCandles, readRfDashboard, readRfOverview } from './rf-data.js';
import { validateInitData } from './telegram-auth.js';

/**
 * ВАЖНО: этот сервер НЕ поллит Telegram.
 *
 * Боевого бота уже слушает assistant/bot.py (trading-assistant.service на VPS). Два процесса
 * с getUpdates на одном токене несовместимы — Telegram отдаёт 409 и ассистент падает
 * (assistant/tg.py:3-5). Поэтому здесь только HTTP API + статика.
 */

const dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(dirname, '..');
const port = Number(process.env.PORT ?? 3000);
// Слушаем ТОЛЬКО петлю: наружу кабинет отдаёт туннель (cloudflared), а не сам процесс.
// Раньше здесь было app.listen(port) = 0.0.0.0, то есть на боевом хосте кабинет с реальными
// деньгами висел бы в интернете по открытому HTTP, если бы в firewall открыли порт.
const host = process.env.HOST ?? '127.0.0.1';
const allowUnsafeDev = process.env.DEV_ALLOW_UNSAFE_AUTH === 'true';
const botToken = process.env.BOT_TOKEN;
const maxAge = Number(process.env.INIT_DATA_MAX_AGE_SECONDS ?? 86400);
const namesPath = path.resolve(rootDir, process.env.NAMES_RU_PATH ?? '../data/names_ru.json');

const registry = loadPortfolios(
  path.resolve(rootDir, process.env.PORTFOLIOS_PATH ?? './portfolios.json'),
  rootDir
);

// Аварийный тормоз поверх реестра: если список задан, всё вне его отсекается сразу.
const hardAllow = new Set(
  (process.env.ALLOWED_TELEGRAM_IDS ?? '').split(',').map((id) => id.trim()).filter(Boolean)
);

const db = openDatabase(process.env.DATABASE_PATH ?? path.join(rootDir, 'data', 'mini-app.sqlite'));
const app = express();

app.use(express.json());

function requireTelegramUser(req, res, next) {
  const initData = req.get('X-Telegram-Init-Data');
  let user;

  // Локальный обход подменяет ТОЛЬКО личность. Проверку доступа он не пропускает: иначе
  // разграничение портфелей молча отключалось бы вместе с аутентификацией.
  if (allowUnsafeDev && !initData) {
    user = { id: process.env.DEV_AS_TELEGRAM_ID ?? 'local-dev', first_name: 'Локальная разработка' };
  } else {
    try {
      const launch = validateInitData(initData, botToken, maxAge);
      if (!launch.user?.id) throw new Error('Telegram user missing');
      user = launch.user;
    } catch (error) {
      logAccess(db, null, false, `401: ${error.message}`);
      return res.status(401).json({ error: 'Запрос не подтверждён Telegram', details: error.message });
    }
  }

  if (hardAllow.size && !hardAllow.has(String(user.id))) {
    logAccess(db, user, false, '403: не в ALLOWED_TELEGRAM_IDS');
    return res.status(403).json({ error: 'Нет доступа' });
  }

  req.telegramUser = user;
  req.visible = registry.visibleFor(user.id);
  if (!req.visible.length) {
    logAccess(db, user, false, '403: нет ни одного портфеля');
    return res.status(403).json({ error: 'Нет доступа' });
  }

  logAccess(db, user, true, '');
  return next();
}

/** Читает контур нужным адаптером. Оба возвращают одинаковую структуру. */
function readPortfolio(p) {
  if (p.kind === 'crypto') {
    return readCryptoDashboard({ dataDir: p.dataDir, candlesDir: p.candlesDir, currency: p.currency });
  }
  return readRfDashboard({ dataDir: p.dataDir, namesPath, currency: p.currency });
}

function readPortfolioOverview(p) {
  if (p.kind === 'crypto') {
    return readCryptoOverview({ dataDir: p.dataDir, currency: p.currency });
  }
  return readRfOverview({ dataDir: p.dataDir, currency: p.currency });
}

app.get('/api/health', (_req, res) => res.json({ ok: true }));

/** Сводка по доступным портфелям. Чужие сюда не попадают — их для владельца не существует. */
app.get('/api/portfolios', requireTelegramUser, (req, res) => {
  upsertUser(db, req.telegramUser);
  const rows = readPortfolioRows(req.visible);
  res.json({ isAdmin: registry.isAdmin(req.telegramUser.id), portfolios: rows });
});

function readPortfolioRows(portfolios) {
  return portfolios.map((p) => {
    try {
      const d = readPortfolioOverview(p);
      const stale = d.summary.dataAgeMin !== null && d.summary.dataAgeMin > 45;
      return {
        id: p.id,
        label: p.label,
        currency: d.currency,
        capital: d.summary.capital,
        todayAmt: d.summary.todayAmt,
        todayPct: d.summary.todayPct,
        openPositions: d.summary.openPositions,
        status: stale ? 'stale' : d.summary.entriesHalt ? 'halt' : 'live',
        dataAgeMin: d.summary.dataAgeMin
      };
    } catch (error) {
      console.error(`portfolio ${p.id}:`, error.message);
      return { id: p.id, label: p.label, currency: p.currency, status: 'error', error: error.message };
    }
  });
}

app.get('/api/v2/portfolios', requireTelegramUser, (req, res) => {
  upsertUser(db, req.telegramUser);
  res.json(portfoliosV2(readPortfolioRows(req.visible)));
});

app.get('/api/dashboard', requireTelegramUser, (req, res) => {
  upsertUser(db, req.telegramUser);

  // Портфель разрешает реестр по проверенному telegram id. Параметр запроса — лишь пожелание:
  // для чужого и для несуществующего id ответ одинаковый, иначе по разнице можно было бы
  // выяснить, какие портфели вообще есть в системе.
  const p = registry.resolve(req.telegramUser.id, req.query.portfolio);
  if (!p) {
    logAccess(db, req.telegramUser, false, `403: портфель «${req.query.portfolio ?? '-'}» недоступен`);
    return res.status(403).json({ error: 'Портфель недоступен' });
  }

  try {
    const data = readPortfolio(p);
    return res.json({
      user: req.telegramUser,
      portfolio: { id: p.id, label: p.label, currency: p.currency },
      canSwitch: req.visible.length > 1,
      ...data
    });
  } catch (error) {
    console.error(`rf/crypto data (${p.id}):`, error.message);
    return res.status(503).json({ error: 'Состояние контура сейчас недоступно', details: error.message });
  }
});

app.get('/api/v2/dashboard', requireTelegramUser, (req, res) => {
  upsertUser(db, req.telegramUser);
  const p = registry.resolve(req.telegramUser.id, req.query.portfolio);
  if (!p) {
    logAccess(db, req.telegramUser, false, `403: портфель «${req.query.portfolio ?? '-'}» недоступен`);
    return res.status(403).json({ error: 'Портфель недоступен' });
  }

  try {
    return res.json(dashboardV2(readPortfolio(p), p, req.visible.length > 1));
  } catch (error) {
    console.error(`rf/crypto data (${p.id}):`, error.message);
    return res.status(503).json({ error: 'Состояние контура сейчас недоступно' });
  }
});

/** Свечи грузятся отдельно и только для выбранной, уже разрешённой позиции. */
app.get('/api/candles', requireTelegramUser, (req, res) => {
  const portfolioId = String(req.query.portfolio ?? '').trim();
  const positionId = String(req.query.position ?? '').trim();
  if (!portfolioId || !positionId) return res.status(400).json({ error: 'Нужны portfolio и position' });

  const p = registry.resolve(req.telegramUser.id, portfolioId);
  if (!p) return res.status(403).json({ error: 'Портфель недоступен' });

  try {
    const data = p.kind === 'crypto'
      ? readCryptoCandles({ dataDir: p.dataDir, candlesDir: p.candlesDir, positionId })
      : readRfCandles({ dataDir: p.dataDir, positionId });
    if (!data) return res.status(404).json({ error: 'Позиция не найдена' });
    return res.json({ portfolioId: p.id, ...data });
  } catch (error) {
    console.error(`candles (${p.id}/${positionId}):`, error.message);
    return res.status(503).json({ error: 'Свечи сейчас недоступны' });
  }
});

const distPath = path.join(rootDir, 'dist');

// Файлы в assets/ имеют хеш в имени: их можно кэшировать навсегда. index.html — наоборот,
// НИКОГДА: иначе после выката вебвью Telegram продолжит открывать старую сборку.
const noStore = (res) => {
  res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
  res.setHeader('Pragma', 'no-cache');
  res.setHeader('Expires', '0');
};

app.use(
  express.static(distPath, {
    etag: true,
    setHeaders: (res, filePath) => {
      if (filePath.endsWith('index.html')) noStore(res);
      else if (filePath.includes(`${path.sep}assets${path.sep}`)) {
        res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
      }
    }
  })
);

app.get('{*splat}', (_req, res) => {
  noStore(res);
  res.sendFile(path.join(distPath, 'index.html'));
});

app.listen(port, host, () => {
  console.log(`Mini App API: http://${host}:${port}`);
  console.log(`Портфелей в реестре: ${registry.portfolios.length}, админов: ${registry.admins.size}`);
  if (allowUnsafeDev) {
    console.warn('ВНИМАНИЕ: DEV_ALLOW_UNSAFE_AUTH=true — запросы без initData принимаются. Только локально.');
  }
});
