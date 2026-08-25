@echo off
REM ============================================================
REM  upload_whl.bat — 将 whl\ 目录下的 *.whl 上传到私有 PyPI
REM
REM  用法:
REM    cd <仓库根目录> && upload_whl.bat
REM
REM  前置:
REM    pip install twine
REM
REM  说明:
REM    - 凭证运行时输入,不会落盘 / 不会进 Git
REM    - --skip-existing: 同版本已存在时跳过,不报错
REM    - --trusted-host: 私有库为 HTTP 时必需
REM    - 默认跳过非 .whl 文件(.tar.gz 源码包会被忽略)
REM
REM  更安全版(密码不回显):
REM    for /f "delims=" %%p in ('powershell -NoProfile -Command ^
REM      "$p = Read-Host 'PyPI Password' -AsSecureString; ^
REM       $BSTR=[System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($p); ^
REM       [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)") ^
REM    do set "PYPI_PASS=%%p"
REM ============================================================

setlocal
cd /d "%~dp0"

REM === 配置 ===
set "PYPI_URL=http://47.109.26.162:12306"
set "PYPI_HOST=47.109.26.162"

REM === 前置检查 ===
where twine >nul 2>nul
if errorlevel 1 (
    echo [ERROR] 未检测到 twine,请先执行: pip install twine
    exit /b 1
)

if not exist "whl" (
    echo [ERROR] whl\ 目录不存在,请先 mkdir whl 并放入 *.whl
    exit /b 1
)

dir /b "whl\*.whl" >nul 2>nul
if errorlevel 1 (
    echo [INFO] whl\ 下未发现 .whl 文件,无需上传
    exit /b 0
)

REM === 凭证输入 ===
echo 即将上传 whl\*.whl 至 %PYPI_URL%
echo.
set /p "PYPI_USER=PyPI 用户名: "
set /p "PYPI_PASS=PyPI 密码: "

REM === 逐个上传 ===
echo.
for %%f in ("whl\*.whl") do (
    echo === 上传: %%~nxf ===
    twine upload ^
        --repository-url "%PYPI_URL%" ^
        --username "%PYPI_USER%" ^
        --password "%PYPI_PASS%" ^
        --trusted-host "%PYPI_HOST%" ^
        --skip-existing ^
        "%%f"
    if errorlevel 1 (
        echo [FAIL] %%~nxf
    ) else (
        echo [OK]   %%~nxf
    )
    echo.
)

REM === 清理内存中的凭证 ===
set "PYPI_USER="
set "PYPI_PASS="

echo 上传完成。
endlocal