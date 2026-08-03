@echo off
cd /d "%~dp0"
echo ============================================
echo  Push t-box to github.com/hzcsure/hzcsure
echo ============================================
echo.

git remote -v

echo.
echo Pushing master to GitHub...
git push -u origin master

if %errorlevel% neq 0 (
    echo.
    echo PUSH FAILED.
    echo If behind a firewall, set proxy first:
    echo   git config http.proxy socks5h://127.0.0.1:1080
    echo   git config https.proxy socks5h://127.0.0.1:1080
    echo Then run this script again.
) else (
    echo.
    echo SUCCESS! Check Actions at:
    echo   https://github.com/hzcsure/hzcsure/actions
    echo.
    echo The speed-test workflow will run automatically.
)

pause
