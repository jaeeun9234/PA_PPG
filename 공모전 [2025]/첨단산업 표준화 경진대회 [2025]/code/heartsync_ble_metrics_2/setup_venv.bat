@echo off
setlocal
chcp 65001 >NUL

REM 현재 배치파일이 있는 폴더로 이동
pushd "%~dp0"

REM 파이썬 확인
where python >NUL 2>&1 || (echo Python not found & pause & exit /b 1)

REM 가상환경 생성
python -m venv venv || (echo venv create failed & pause & exit /b 1)

REM 가상환경 활성화
call "%~dp0venv\Scripts\activate.bat"

REM 업그레이드 & 패키지 설치
python -m pip install --upgrade pip
pip install bleak numpy

echo.
echo [OK] virtual env ready.
pause
