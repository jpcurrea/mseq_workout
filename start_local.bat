@echo off
setlocal

set API_FILE=flutter_app\lib\services\api_service.dart
set AUTH_FILE=flutter_app\lib\services\auth_service.dart
set PROD_URL=https://workout-backend-h6pd.onrender.com
set LOCAL_URL=http://localhost:8000

echo ============================================
echo  Workout App -- Local Dev Startup
echo ============================================
echo.

:: ── 1. Switch Flutter to local backend ──────────────────────────────────────
echo [1/4] Switching Flutter to local backend ...
powershell -NoProfile -Command ^
  "(Get-Content '%API_FILE%') -replace [regex]::Escape('%PROD_URL%'), '%LOCAL_URL%' | Set-Content '%API_FILE%'"
if errorlevel 1 (
  echo ERROR: Failed to update api_service.dart - aborting.
  pause
  exit /b 1
)
powershell -NoProfile -Command ^
  "(Get-Content '%AUTH_FILE%') -replace [regex]::Escape('%PROD_URL%'), '%LOCAL_URL%' | Set-Content '%AUTH_FILE%'"
if errorlevel 1 (
  echo ERROR: Failed to update auth_service.dart - aborting.
  pause
  exit /b 1
)
echo       Done.
echo.

:: ── 2. Start backend in its own window ──────────────────────────────────────
echo [2/4] Starting backend (new window)...
start "Workout Backend" cmd /k "set FRONTEND_URL=http://localhost:8080&&set BACKEND_URL=http://localhost:8000&&cd backend&&call ..\.venv\Scripts\activate.bat&&python main.py"
echo       Backend window launched.
echo.

:: ── 3. Start Flutter web in its own window ──────────────────────────────────
echo [3/4] Starting Flutter web frontend (new window)...
start "Workout Frontend" cmd /k "cd flutter_app && flutter run -d web-server --web-port 8080"
echo       Frontend window launched  ^(will be at http://localhost:8080^)
echo.

:: ── 4. Wait for user to signal shutdown ─────────────────────────────────────
echo [4/4] Both servers are running.
echo       Press ENTER here when you want to shut everything down.
echo.
pause > nul
echo.
echo Shutting down...

:: Kill the named cmd windows we opened
taskkill /FI "WINDOWTITLE eq Workout Backend*" /F /T > nul 2>&1
taskkill /FI "WINDOWTITLE eq Workout Frontend*" /F /T > nul 2>&1

:: ── 5. Restore production URL ────────────────────────────────────────────────
echo Restoring production URLs in api_service.dart and auth_service.dart ...
powershell -NoProfile -Command ^
  "(Get-Content '%API_FILE%') -replace [regex]::Escape('%LOCAL_URL%'), '%PROD_URL%' | Set-Content '%API_FILE%'"
powershell -NoProfile -Command ^
  "(Get-Content '%AUTH_FILE%') -replace [regex]::Escape('%LOCAL_URL%'), '%PROD_URL%' | Set-Content '%AUTH_FILE%'"
echo Done.
echo.
echo All clean. Goodbye!
pause
endlocal
