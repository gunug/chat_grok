@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

rem move to this script's folder
cd /d "%~dp0"

title Chat Grok Server

echo.
echo  ========================================
echo    Chat Grok  -  xAI Grok chatbot
echo  ========================================
echo.
echo  [info] folder : %CD%

rem ---- check Node.js ----
where node >nul 2>nul
if errorlevel 1 (
  echo.
  echo  [ERROR] Node.js not found. Install from https://nodejs.org
  goto :END
)
for /f "delims=" %%v in ('node --version') do echo  [info] node   : %%v

rem ---- check server.js exists ----
if not exist "server.js" (
  echo.
  echo  [ERROR] server.js not found in this folder.
  goto :END
)

rem ---- install dependencies (first run) ----
if not exist "node_modules" (
  echo.
  echo  [setup] running npm install ...
  call npm install
  if errorlevel 1 (
    echo.
    echo  [ERROR] npm install failed. See messages above.
    goto :END
  )
)

rem ---- check .env ----
if not exist ".env" (
  echo.
  echo  [WARN] .env not found. Copy .env.example to .env and set XAI_API_KEY.
)

rem ---- read PORT from .env (default 3000) ----
set "PORT=3000"
if exist ".env" (
  for /f "usebackq tokens=1,* delims==" %%a in (".env") do (
    if /i "%%a"=="PORT" set "PORT=%%b"
  )
)

echo.
echo  [info] url    : http://localhost:%PORT%  (busy port -^> auto next port)
echo  [info] stop   : press Ctrl+C in this window
echo.

rem ---- let the server open the browser at the port it actually binds ----
set "OPEN_BROWSER=1"

rem ---- run server; output shown live in this window ----
echo  ---------- server output ----------
node server.js 2>&1
set "EXITCODE=%ERRORLEVEL%"

echo.
echo  -----------------------------------
echo  [info] server stopped (exit code %EXITCODE%).

:END
echo.
echo  Press any key to close this window...
pause >nul
endlocal
