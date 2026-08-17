import Database from 'better-sqlite3';
import fs from 'node:fs';
import path from 'node:path';

/**
 * SQLite здесь НЕ хранит торговые данные: единственный источник правды по счёту —
 * файлы движка в data/live_rf (см. rf-data.js). База ведёт только доступ к кабинету:
 * кто открывал и кого развернули на пороге.
 */

export function openDatabase(databasePath) {
  const fullPath = path.resolve(databasePath);
  fs.mkdirSync(path.dirname(fullPath), { recursive: true });
  const db = new Database(fullPath);
  db.pragma('journal_mode = WAL');
  db.exec(`
    CREATE TABLE IF NOT EXISTS users (
      telegram_id TEXT PRIMARY KEY,
      username TEXT,
      first_name TEXT,
      first_seen_at TEXT NOT NULL,
      last_seen_at TEXT NOT NULL,
      visits INTEGER NOT NULL DEFAULT 1
    );
    CREATE TABLE IF NOT EXISTS access_log (
      id INTEGER PRIMARY KEY,
      at TEXT NOT NULL,
      telegram_id TEXT,
      username TEXT,
      allowed INTEGER NOT NULL,
      reason TEXT
    );
    CREATE INDEX IF NOT EXISTS access_log_at ON access_log (at DESC);
  `);
  // Снос демо-таблиц ранней версии: в них лежали выдуманные сделки и эквити, которые
  // приложение больше не читает. Оставлять фикцию в базе торгового кабинета нельзя —
  // рано или поздно её примут за настоящие данные.
  db.exec('DROP TABLE IF EXISTS positions; DROP TABLE IF EXISTS closed_trades; DROP TABLE IF EXISTS equity_history;');

  // Дополняем users колонками, которых нет в базах ранней версии: CREATE TABLE IF NOT
  // EXISTS существующую таблицу не трогает, и без этого upsertUser падает на первом же
  // запросе с «no column named first_seen_at».
  const columns = new Set(db.prepare('PRAGMA table_info(users)').all().map((c) => c.name));
  if (!columns.has('first_seen_at')) db.exec("ALTER TABLE users ADD COLUMN first_seen_at TEXT NOT NULL DEFAULT ''");
  if (!columns.has('visits')) db.exec('ALTER TABLE users ADD COLUMN visits INTEGER NOT NULL DEFAULT 1');

  return db;
}

export function upsertUser(db, telegramUser) {
  if (!telegramUser?.id) return;
  const now = new Date().toISOString();
  db.prepare(
    `INSERT INTO users (telegram_id, username, first_name, first_seen_at, last_seen_at, visits)
     VALUES (?, ?, ?, ?, ?, 1)
     ON CONFLICT(telegram_id) DO UPDATE SET
       username = excluded.username,
       first_name = excluded.first_name,
       last_seen_at = excluded.last_seen_at,
       visits = users.visits + 1`
  ).run(String(telegramUser.id), telegramUser.username ?? null, telegramUser.first_name ?? null, now, now);
}

/**
 * Пишем и отказы: кабинет показывает реальный счёт, поэтому чужие попытки входа —
 * это то, о чём владелец должен иметь возможность узнать постфактум.
 */
export function logAccess(db, telegramUser, allowed, reason = '') {
  db.prepare('INSERT INTO access_log (at, telegram_id, username, allowed, reason) VALUES (?, ?, ?, ?, ?)').run(
    new Date().toISOString(),
    telegramUser?.id != null ? String(telegramUser.id) : null,
    telegramUser?.username ?? null,
    allowed ? 1 : 0,
    reason
  );
}
