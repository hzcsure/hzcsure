@echo off
cd /d "%~dp0"
echo === Push t-box to github.com/hzcsure/hzcsure ===
echo.

REM Check if remote exists
git remote -v 2>nul | findstr "origin" >nul
if %errorlevel% neq 0 (
    echo Adding remote...
    git remote add origin https://github.com/hzcsure/hzcsure.git
)

REM If you use a proxy, uncomment and edit:
REM git config http.proxy socks5h://127.0.0.1:1080
REM git config https.proxy socks5h://127.0.0.1:1080

echo Pushing to GitHub...
git push -u origin master

if %errorlevel% neq 0 (
    echo.
    echo PUSH FAILED. Try:
    echo   1. Set proxy:  git config http.proxy socks5h://YOUR_PROXY:PORT
    echo   2. Use token:  git remote set-url origin https://TOKEN@github.com/hzcsure/hzcsure.git
    echo   3. Use SSH:    git remote set-url origin git@github.com:hzcsure/hzcsure.git
) else (
    echo.
    echo Done! Check Actions tab:
    echo   https://github.com/hzcsure/hzcsure/actions
)

pause
