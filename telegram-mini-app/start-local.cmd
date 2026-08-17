@echo off
setlocal
cd /d "%~dp0"

set "DEV_ALLOW_UNSAFE_AUTH=true"
set "PORT=3030"

echo.
echo Building the Telegram Mini App...
call npm run build
if errorlevel 1 (
  echo.
  echo Build failed. Fix the error above, then run this file again.
  pause
  exit /b 1
)

echo.
echo Mini App is ready at: http://localhost:3030
echo Press Ctrl+C to stop the local server.
echo.
call npm start
