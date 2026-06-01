@echo off
setlocal enableextensions enabledelayedexpansion
:: ================================================
:: HeartSync Analyzer (Scale-Fixed, Local) - Robust
:: ================================================

:: UTF-8 콘솔(선택)
chcp 65001 >nul

echo [HeartSync Analyzer] 분석을 시작합니다...
echo.

:: 스크립트 기준 경로
set "SCRIPT_DIR=%~dp0"

:: 우선 현재 폴더로 이동
cd /d "%SCRIPT_DIR%"

:: --------------------------------
:: 1) 실행할 파이썬 파일 찾기
:: --------------------------------
set "PYSCRIPT=analyze_heartsync_scalefix.py"
set "RUNFILE="

if exist "%SCRIPT_DIR%%PYSCRIPT%" (
  set "RUNFILE=%SCRIPT_DIR%%PYSCRIPT%"
) else if exist "%SCRIPT_DIR%..\%PYSCRIPT%" (
  set "RUNFILE=%SCRIPT_DIR%..\%PYSCRIPT%"
)

if not defined RUNFILE (
  echo ❌ 분석 스크립트를 찾을 수 없습니다.
  echo    찾은 위치:
  echo    - %SCRIPT_DIR%%PYSCRIPT%
  echo    - %SCRIPT_DIR%..\%PYSCRIPT%
  echo    위 경로 중 한 곳에 파일을 두거나, 파일명을 확인하세요.
  goto :END_FAIL
)

:: --------------------------------
:: 2) CSV 파일 찾기
::    (현재 폴더 → 상위 폴더 순)
:: --------------------------------
set "CSV=beats_metrics.csv"
set "CSVPATH="

if exist "%SCRIPT_DIR%%CSV%" (
  set "CSVPATH=%SCRIPT_DIR%%CSV%"
) else if exist "%SCRIPT_DIR%..\%CSV%" (
  set "CSVPATH=%SCRIPT_DIR%..\%CSV%"
)

if not defined CSVPATH (
  echo ❌ CSV 파일을 찾을 수 없습니다: beats_metrics.csv
  echo    현재 폴더 또는 상위 폴더에 두고 다시 실행하세요.
  goto :END_FAIL
)

:: --------------------------------
:: 3) Python 실행 파일 결정 (py -3 → python)
:: --------------------------------
set "PYEXE="
where py >nul 2>nul && set "PYEXE=py -3"
if not defined PYEXE (
  where python >nul 2>nul && set "PYEXE=python"
)

if not defined PYEXE (
  echo ❌ Python 실행 파일을 찾지 못했습니다.
  echo    - Windows Store 설치: Microsoft Store 에서 Python 설치
  echo    - 또는 python.org 에서 설치 후 PATH 추가
  goto :END_FAIL
)

:: --------------------------------
:: 4) 실행 (CSV는 현재 폴더에서 읽도록 작업폴더 이동)
:: --------------------------------
:: CSV가 상위 폴더에 있을 경우, 그 폴더로 이동하여 실행
for %%F in ("%CSVPATH%") do set "CSV_DIR=%%~dpF"
cd /d "%CSV_DIR%"

echo [INFO] 사용 Python: %PYEXE%
echo [INFO] 분석 스크립트: "%RUNFILE%"
echo [INFO] CSV 위치      : "%CSVPATH%"
echo.

%PYEXE% "%RUNFILE%"
set "RC=%ERRORLEVEL%"

echo.

:: --------------------------------
:: 5) 성공/실패 판정 + 결과 확인
:: --------------------------------
if not "%RC%"=="0" (
  echo ❌ 분석 중 오류가 발생했습니다. (ERRORLEVEL=%RC%)
  goto :END_FAIL
)

:: 결과 파일 존재 확인(요약 CSV)
for /f "delims=" %%G in ('dir /b /a:-d "summary_stats_*_ScaleFix.csv" 2^>nul') do (
  set "FOUND=1"
  goto :FOUND_RESULT
)

:FOUND_RESULT
if not defined FOUND (
  echo ⚠️  실행은 완료되었지만 결과 요약 CSV를 찾지 못했습니다.
  echo     데이터가 비어 있거나, 스크립트 내부 예외가 있었을 수 있습니다.
  goto :END_FAIL
)

echo ✅ 분석이 완료되었습니다.
echo 결과 파일이 현재 폴더에 저장되었습니다.
goto :END_OK

:END_FAIL
echo.
echo [종료] 문제를 확인한 뒤 다시 실행하세요.
pause
exit /b 1

:END_OK
echo.
pause
exit /b 0
