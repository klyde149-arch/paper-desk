import fs from 'node:fs';
import path from 'node:path';

/**
 * Реестр портфелей и единственная точка решения о доступе.
 *
 * Правило, ради которого всё это существует: владелец портфеля видит только свой счёт и не
 * должен даже догадываться о существовании остальных. Поэтому решение принимается здесь и
 * ТОЛЬКО по telegram id из проверенной подписи — параметр запроса ничего не решает.
 */

const KINDS = new Set(['rf', 'crypto']);

function fail(message) {
  throw new Error(`portfolios.json: ${message}`);
}

/**
 * Загрузка и валидация. Битый или пустой реестр — громкая ошибка на старте, а не молчаливый
 * доступ: кабинет показывает реальные деньги, и «пусто = пускаем всех» здесь недопустимо.
 */
export function loadPortfolios(configPath, rootDir) {
  let raw;
  try {
    raw = JSON.parse(fs.readFileSync(configPath, 'utf8').replace(/^﻿/, ''));
  } catch (error) {
    fail(`не читается (${configPath}): ${error.message}`);
  }

  const admins = (raw.admins ?? []).map(String).map((s) => s.trim()).filter(Boolean);
  const list = Array.isArray(raw.portfolios) ? raw.portfolios : fail('нет массива portfolios');
  if (!list.length) fail('список портфелей пуст');

  const seen = new Set();
  const portfolios = list.map((p, i) => {
    const id = String(p.id ?? '').trim();
    if (!id) fail(`портфель #${i + 1} без id`);
    if (seen.has(id)) fail(`повторяющийся id «${id}»`);
    seen.add(id);
    if (!KINDS.has(p.kind)) fail(`портфель «${id}»: неизвестный kind «${p.kind}»`);
    if (!p.dataDir) fail(`портфель «${id}»: не указан dataDir`);

    const dataDir = path.resolve(rootDir, p.dataDir);
    if (!fs.existsSync(dataDir)) fail(`портфель «${id}»: каталога данных нет — ${dataDir}`);

    return {
      id,
      label: String(p.label ?? id),
      kind: p.kind,
      currency: p.currency ?? (p.kind === 'rf' ? 'RUB' : 'USD'),
      dataDir,
      candlesDir: p.candlesDir ? path.resolve(rootDir, p.candlesDir) : null,
      owners: (p.owners ?? []).map(String).map((s) => s.trim()).filter(Boolean)
    };
  });

  if (!admins.length && !portfolios.some((p) => p.owners.length)) {
    fail('не задан ни один admin и ни один owner — в кабинет никто не сможет войти');
  }

  return new Registry(admins, portfolios);
}

class Registry {
  constructor(admins, portfolios) {
    this.admins = new Set(admins);
    this.portfolios = portfolios;
  }

  isAdmin(telegramId) {
    return this.admins.has(String(telegramId));
  }

  /** Портфели, доступные этому telegram id. Пустой массив = доступа нет вовсе. */
  visibleFor(telegramId) {
    const id = String(telegramId);
    if (this.isAdmin(id)) return this.portfolios;
    return this.portfolios.filter((p) => p.owners.includes(id));
  }

  /**
   * Портфель по id, но только если он виден этому пользователю. Для чужого и для
   * несуществующего возвращается одно и то же (null) — чтобы по разнице ответов нельзя
   * было выяснить, какие портфели вообще есть в системе.
   */
  resolve(telegramId, portfolioId) {
    const visible = this.visibleFor(telegramId);
    if (!visible.length) return null;
    if (!portfolioId) return visible[0];
    return visible.find((p) => p.id === String(portfolioId)) ?? null;
  }
}
