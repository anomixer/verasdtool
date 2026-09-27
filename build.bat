@echo off
setlocal

where node >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Node.js not found on PATH.
  exit /b 1
)

set "TARGET=%~1"
if "%TARGET%"=="" set "TARGET=all"
if /I "%TARGET%"=="verasdedit" goto edit
if /I "%TARGET%"=="verasdformat" goto format
if /I "%TARGET%"=="fat32" goto fat32
if /I "%TARGET%"=="prodos" goto prodos
if /I "%TARGET%"=="all" goto all

echo Usage: build.bat [verasdedit^|verasdformat^|fat32^|prodos^|all]
exit /b 1

:edit
node src\verasdedit\verasdedit.mjs
exit /b %ERRORLEVEL%

:format
node src\verasdformat\verasdformat.mjs
exit /b %ERRORLEVEL%

:fat32
node src\verasd-fat32\fat32-build.mjs
exit /b %ERRORLEVEL%

:prodos
node src\verasd-prodos\verasd.mjs
exit /b %ERRORLEVEL%

:all
node src\verasdedit\verasdedit.mjs
if errorlevel 1 exit /b 1
node src\verasdformat\verasdformat.mjs
if errorlevel 1 exit /b 1
node src\verasd-fat32\fat32-build.mjs
if errorlevel 1 exit /b 1
node src\verasd-prodos\verasd.mjs
exit /b %ERRORLEVEL%
