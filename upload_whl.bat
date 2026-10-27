@echo off
REM ============================================================
REM  upload_whl.bat - upload *.whl files from whl\ to a private PyPI
REM
REM  Usage:   upload_whl.bat            (run from repo root)
REM  Prereq:  pip install twine
REM  Notes:
REM    - Credentials are prompted at runtime (never written to disk)
REM    - --skip-existing: silently skip wheels whose version already exists
REM    - --trusted-host: required for HTTP-only private indexes
REM    - Only *.whl files are picked up; .tar.gz source dists are ignored
REM
REM  This file MUST keep LF line endings (.gitattributes enforces this).
REM    CRLF breaks parsing under cmd.exe on Windows.
REM ============================================================

setlocal
cd /d "%~dp0"

set "PYPI_URL=http://47.109.26.162:12306"
set "PYPI_HOST=47.109.26.162"

REM --- Prereq checks ---
where twine >nul 2>nul
if errorlevel 1 (
    echo [ERROR] twine not found. Run:  pip install twine
    exit /b 1
)

if not exist "whl" (
    echo [ERROR] whl\ directory not found. Create it and put *.whl files inside.
    exit /b 1
)

dir /b "whl\*.whl" >nul 2>nul
if errorlevel 1 (
    echo [INFO] No .whl files under whl\. Nothing to do.
    exit /b 0
)

REM --- Credential prompt ---
echo About to upload whl\*.whl to %PYPI_URL%
echo.
set /p "PYPI_USER=PyPI username: "
set /p "PYPI_PASS=PyPI password: "

REM --- Upload each wheel ---
echo.
for %%f in ("whl\*.whl") do (
    echo === Uploading: %%~nxf ===
    twine upload --repository-url "%PYPI_URL%" --username "%PYPI_USER%" --password "%PYPI_PASS%" --trusted-host "%PYPI_HOST%" --skip-existing "%%f"
    if errorlevel 1 (echo [FAIL] %%~nxf) else (echo [OK]   %%~nxf)
    echo.
)

REM --- Wipe credentials from process memory ---
set "PYPI_USER="
set "PYPI_PASS="

echo Done.
endlocal