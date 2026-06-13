@echo off
setlocal

set LOCAL_BACKEND=http://localhost:8000
set LOCAL_FRONTEND=http://localhost:8080

echo ============================================
echo  Hub App -- Local Dev Startup
echo ============================================
echo.
echo Backend : %LOCAL_BACKEND%
echo Frontend: %LOCAL_FRONTEND%
echo.
echo No source files are modified. BACKEND_URL is
echo injected at Flutter run-time via --dart-define.
echo.

:: ── 1. Start backend ────────────────────────────────────────────────────────
echo [1/3] Starting backend (new window)...
start "Hub Backend" cmd /k "set FRONTEND_URL=%LOCAL_FRONTEND%&&set BACKEND_URL=%LOCAL_BACKEND%&&cd backend&&call ..\.venv\Scripts\activate.bat&&python main.py"
echo       Backend window launched.
echo.

:: ── 2. Start Flutter web (BACKEND_URL injected via --dart-define) ───────────
echo [2/3] Starting Flutter web frontend (new window)...
start "Hub Frontend" cmd /k "cd flutter_app && flutter run -d web-server --web-port 8080 --dart-define=BACKEND_URL=%LOCAL_BACKEND%"
echo       Frontend window launched (http://localhost:8080)
echo.

:: ── 3. Wait for shutdown ────────────────────────────────────────────────────
echo [3/3] Both servers are running.
echo       Press ENTER here when you want to shut everything down.
echo.
pause > nul
echo.
echo Shutting down...
taskkill /FI "WINDOWTITLE eq Hub Backend*"  /F /T > nul 2>&1
taskkill /FI "WINDOWTITLE eq Hub Frontend*" /F /T > nul 2>&1

echo Done. Source files were never modified.
echo.
pause
endlocal
pause
endlocal
