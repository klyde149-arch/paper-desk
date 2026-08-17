import 'dotenv/config';
import { Telegraf } from 'telegraf';

const { BOT_TOKEN, WEB_APP_URL } = process.env;
if (!BOT_TOKEN || !WEB_APP_URL) {
  throw new Error('BOT_TOKEN and WEB_APP_URL must be set in .env');
}
if (!WEB_APP_URL.startsWith('https://')) {
  throw new Error('WEB_APP_URL must use HTTPS for Telegram Mini Apps');
}

const bot = new Telegraf(BOT_TOKEN);
await bot.telegram.setChatMenuButton({
  menuButton: { type: 'web_app', text: 'Открыть приложение', web_app: { url: WEB_APP_URL } }
});
console.log('Menu button has been set.');
