import crypto from 'node:crypto';

/**
 * Validates Telegram WebApp initData according to Telegram's HMAC-SHA-256 scheme.
 * Returns the parsed launch parameters on success and throws on invalid input.
 */
export function validateInitData(initData, botToken, maxAgeSeconds = 86400) {
  if (!initData || !botToken) throw new Error('Missing Telegram credentials');

  const params = new URLSearchParams(initData);
  const receivedHash = params.get('hash');
  const authDate = Number(params.get('auth_date'));
  params.delete('hash');

  if (!receivedHash || !Number.isFinite(authDate)) throw new Error('Malformed initData');
  if (Math.abs(Date.now() / 1000 - authDate) > maxAgeSeconds) {
    throw new Error('initData has expired');
  }

  const dataCheckString = [...params.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, value]) => `${key}=${value}`)
    .join('\n');
  const secretKey = crypto.createHmac('sha256', 'WebAppData').update(botToken).digest();
  const calculatedHash = crypto.createHmac('sha256', secretKey).update(dataCheckString).digest('hex');

  const expected = Buffer.from(calculatedHash, 'hex');
  const actual = Buffer.from(receivedHash, 'hex');
  if (expected.length !== actual.length || !crypto.timingSafeEqual(expected, actual)) {
    throw new Error('Invalid initData signature');
  }

  const userJson = params.get('user');
  return { ...Object.fromEntries(params), user: userJson ? JSON.parse(userJson) : null };
}
