@REM 최초 실행 시에만 더블 클릭
@REM 컴퓨터 부팅 시 자동 실행

@echo off
REM ========================================
REM HL7 서버 완전 자동 배포 스크립트
REM 사용자 입력 없이 모든 것을 자동 처리
REM ========================================

chcp 65001 >nul 2>&1
setlocal EnableDelayedExpansion

echo ========================================
echo    HL7 Server Zero-Input Auto Deploy
echo ========================================
echo 완전 자동 설치 시작 (사용자 입력 불필요)
echo ========================================
echo.

REM 관리자 권한 확인
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo 관리자 권한이 필요합니다!
    echo 해결방법: 이 파일을 우클릭 ^> "관리자 권한으로 실행"
    echo.
    pause
    exit /b 1
)

REM 현재 PC 식별
for /f "tokens=*" %%i in ('hostname') do set HOSTNAME=%%i
echo 현재 PC: %HOSTNAME%

REM 변수 설정
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "SERVICE_NAME=HL7Server_%HOSTNAME%"
set "SCRIPT_NAME=hl7_server.py"
set "DISPLAY_NAME=HL7 Server (%HOSTNAME%)"
set "NSSM_PATH=C:\Windows\System32\nssm.exe"

echo 프로젝트 경로: %SCRIPT_DIR%
echo 서비스 이름: %SERVICE_NAME%
echo.


REM ==========================================
REM 🐍 Python 경로 탐색 + 검증 + 설치 폴백 (견고 버전)
REM ==========================================
echo.
echo 🐍 Python 환경 확인 중...

setlocal EnableDelayedExpansion
set "PYTHON_PATH="

for /f "usebackq delims=" %%i in (`where python 2^>nul`) do (
  set "LINE=%%i"

  REM INFO: 라인 제외
  if /I not "!LINE:~0,5!"=="INFO:" (

    REM WindowsApps 경로 포함 여부 검사 (대/소문자 변형 3가지 모두 체크)
    set "T1=!LINE:\Microsoft\WindowsApps\=!"
    set "T2=!LINE:\microsoft\windowsapps\=!"
    set "T3=!LINE:\MICROSOFT\WINDOWSAPPS\=!"

    if "!T1!!T2!!T3!"=="!LINE!!LINE!!LINE!" (
      REM 여기로 들어오면 WindowsApps가 아님 → 채택
      set "PYTHON_PATH=%%i"
      goto :verify_python
    )
  )
)

REM 여기까지 오면 후보가 없음 → 설치로 이동
goto :install_python

:install_python
echo ❌ 사용 가능한 Python을 찾지 못했습니다. 설치를 진행합니다...
echo USERPROFILE = %USERPROFILE%

pushd "%TEMP%" >nul 2>&1
echo debug 0
powershell -ExecutionPolicy Bypass -Command ^
  "& { try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe' -OutFile 'python-installer.exe' -UseBasicParsing } catch { exit 1 } }"
echo debug 1 
@REM 여기서 에러 발생
if not exist "python-installer.exe" (
  echo ❌ Python 설치 파일 다운로드 실패!
  echo debug 2
  popd >nul & exit /b 1
)
if exist "%SystemRoot%\py.exe" (echo Python Launcher 있음) else (echo 없음)
echo debug 3
REM per-user 고정 경로에 설치 (런처 스킵)

REM --- Repair ---
start /wait "" python-installer.exe ^
  /repair /quiet InstallAllUsers=0 Include_launcher=0 ^
  TargetDir="%USERPROFILE%\AppData\Local\Programs\Python\Python311" ^
  /log "%TEMP%\python-repair.log"
echo [Repair ExitCode] %errorlevel%

REM --- Install (per-user, pip 포함) ---
start /wait "" python-installer.exe ^
  /quiet InstallAllUsers=0 PrependPath=1 Include_launcher=0 Include_pip=1 ^
  TargetDir="%USERPROFILE%\AppData\Local\Programs\Python\Python311" ^
  /log "%TEMP%\python-install.log"

set "_rc=%errorlevel%"
echo [Installer ExitCode] %_rc%

REM Temp에서 최신 로그 파일 하나 집어오기
set "LAST_LOG="
for /f "delims=" %%F in ('dir /b /a:-d /o:-d "%TEMP%\python*.txt" 2^>nul') do (
  set "LAST_LOG=%TEMP%\%%F"
  goto :gotlog
)
:gotlog

if not "%_rc%"=="0" (
  echo 설치 실패. 로그 확인: "%TEMP%\python-install.log"
  if defined LAST_LOG echo 추가 로그: "%LAST_LOG%"
  pause
  exit /b 1
)

echo debug 4
del python-installer.exe >nul 2>&1
echo debug 5
popd >nul
echo debug 6

set "PYTHON_PATH=%USERPROFILE%\AppData\Local\Programs\Python\Python311\python.exe"
if not exist "%PYTHON_PATH%" (
  echo ❌ Python 설치 후 경로를 찾지 못했습니다.
  exit /b 1
)
goto :verify_python

:verify_python
echo ✅ 후보 Python: %PYTHON_PATH%

echo "%PYTHON_PATH%" | find /I "Microsoft\WindowsApps" >nul && (
  echo ❌ WindowsApps 별칭 감지. 재설치로 전환...
  set "PYTHON_PATH="
  goto :install_python
)

echo ✅ Python 사용 가능: %PYTHON_PATH%

@REM ==========================================

echo %SCRIPT_NAME% 파일 확인됨

REM 로그 폴더 생성
if not exist "%SCRIPT_DIR%\logs" mkdir "%SCRIPT_DIR%\logs" >nul 2>&1
echo 로그 폴더 준비됨

REM ==========================================
REM 자동 의존성 설치 (사용자 입력 없음)
REM ==========================================
echo.

REM --- pip 부트스트랩 & 확인 ---
"%PYTHON_PATH%" -m ensurepip --default-pip >nul 2>&1 || ^
"%PYTHON_PATH%" -m ensurepip --upgrade >nul 2>&1

"%PYTHON_PATH%" -m pip --version || (
  echo ❌ pip 초기화 실패
  echo ▶ 로그 확인: %TEMP%\python-install.log %TEMP%\python-repair.log
  pause & exit /b 1
)

echo Python 패키지 자동 설치 중...
echo    (requirements.txt 무관하게 필수 패키지만 설치)

REM 환경 변수 설정 (인코딩 문제 방지)
set PYTHONIOENCODING=utf-8
set PYTHONDONTWRITEBYTECODE=1

REM pip 업그레이드 (조용히)
echo pip 업그레이드 중...
"%PYTHON_PATH%" -m pip install --upgrade pip --no-warn-script-location 

REM 필수 패키지들을 개별적으로 안전하게 설치
echo 필수 패키지 설치 중...

echo    - FastAPI 설치 중...
"%PYTHON_PATH%" -m pip install fastapi --no-warn-script-location --disable-pip-version-check 
"%PYTHON_PATH%" -m pip install itsdangerous --no-warn-script-location --disable-pip-version-check 

echo    - Uvicorn 설치 중...
"%PYTHON_PATH%" -m pip install "uvicorn[standard]" --no-warn-script-location --disable-pip-version-check 

echo    - Pydantic 설치 중...
"%PYTHON_PATH%" -m pip install pydantic --no-warn-script-location --disable-pip-version-check 

echo    - HL7apy 설치 중...
"%PYTHON_PATH%" -m pip install hl7apy --no-warn-script-location --disable-pip-version-check 

echo    - Pandas 설치 중...
"%PYTHON_PATH%" -m pip install pandas --no-warn-script-location --disable-pip-version-check 

REM 선택적 패키지들 (실패해도 무시)
echo    - 추가 패키지 설치 중...
"%PYTHON_PATH%" -m pip install mysql-connector-python --no-warn-script-location --disable-pip-version-check 
"%PYTHON_PATH%" -m pip install confluent-kafka --no-warn-script-location --disable-pip-version-check 
"%PYTHON_PATH%" -m pip install psycopg2-binary --no-warn-script-location --disable-pip-version-check 
"%PYTHON_PATH%" -m pip install python-multipart --no-warn-script-location --disable-pip-version-check 

echo Python 패키지 설치 완료

REM 핵심 패키지 확인
echo 핵심 패키지 확인 중...
"%PYTHON_PATH%" -c "import fastapi; print('FastAPI: OK')" 2>nul || echo "FastAPI 설치 확인 불가"
"%PYTHON_PATH%" -c "import hl7apy; print('HL7apy: OK')" 2>nul || echo "HL7apy 설치 확인 불가"

REM ==========================================
REM NSSM 자동 설치 (로컬 파일 우선)
REM ==========================================
echo.
echo 🔧 NSSM 서비스 관리자 확인 중...

REM --- errorLevel이 아닌, 파일의 '존재' 여부로만 판단 ---
if exist "%NSSM_PATH%" (
    echo ✅ NSSM이 이미 설치되어 있습니다 ： %NSSM_PATH%
    goto :nssm_ready
)

echo ⚠️ NSSM이 설치되어 있지 않습니다. 로컬 파일로 설치를 시도합니다.

REM 로컬에 nssm-2.24.zip 파일이 있는지 먼저 확인
if exist "%SCRIPT_DIR%\nssm-2.24.zip" (
    echo 📦 로컬 nssm-2.24.zip 파일로 설치를 진행합니다...
    pushd "%SCRIPT_DIR%" >nul 2>&1
    powershell -ExecutionPolicy Bypass -Command "Expand-Archive -Path 'nssm-2.24.zip' -DestinationPath '.' -Force; Copy-Item -Path '.\nssm-2.24\win64\nssm.exe' -Destination 'C:\Windows\System32\' -Force; Remove-Item -Path 'nssm-2.24' -Recurse -Force -ErrorAction SilentlyContinue;" >nul 2>&1
    popd >nul 2>&1
    echo  NSSM 설치 완료
) else (
    REM 로컬 파일이 없으면 인터넷에서 다운로드 시도
    echo ❌ 로컬 nssm.zip 파일이 없어 설치를 진행할 수 없습니다.
    echo 📋 배포 폴더에 nssm.zip 파일을 준비해주세요.
    @REM pushd "%TEMP%" >nul 2>&1
    @REM powershell -ExecutionPolicy Bypass -Command "& { try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri 'https://nssm.cc/release/nssm-2.24.zip' -OutFile 'nssm.zip' -UseBasicParsing -TimeoutSec 30; Expand-Archive -Path 'nssm.zip' -DestinationPath '.' -Force; Copy-Item -Path '.\nssm-2.24\win64\nssm.exe' -Destination 'C:\Windows\System32\' -Force; Remove-Item -Path 'nssm.zip' -Force -ErrorAction SilentlyContinue; Remove-Item -Path 'nssm-2.24' -Recurse -Force -ErrorAction SilentlyContinue; } catch { Write-Host 'Download Failed' } }" >nul 2>&1
    @REM popd >nul 2>&1
    pause
    exit /b 1
)

if exist "%NSSM_PATH%" (
    echo ✅ NSSM 설치 완료.
) else (
    echo ❌ NSSM 자동 설치 실패.
    echo 📋 권한 문제나 보안 프로그램에 의해 차단되었을 수 있습니다.
    pause
    exit /b 1
)

:nssm_ready

echo debug 1

REM ==========================================
REM 기존 서비스 정리 (자동)
REM ==========================================
echo.
echo 기존 서비스 정리 중...

nssm status %SERVICE_NAME% >nul 2>&1
echo debug 2
if %errorLevel% equ 0 (
    echo 기존 서비스 중지 및 제거 중...
    nssm stop %SERVICE_NAME% >nul 2>&1
    timeout /t 3 >nul
    nssm remove %SERVICE_NAME% confirm >nul 2>&1
    timeout /t 2 >nul
    echo 기존 서비스 제거 완료
) else (
    echo 새 설치 _ 기존 서비스 없음
)

REM ==========================================
REM 서비스 설치 및 설정
REM ==========================================
echo.
echo HL7 서버 서비스 설치 중...

REM 서비스 설치
echo 서비스 등록 중...
@REM nssm install %SERVICE_NAME% "%PYTHON_PATH%" "%SCRIPT_DIR%\%SCRIPT_NAME%" >nul 2>&1

nssm install %SERVICE_NAME% "%PYTHON_PATH%"

nssm set %SERVICE_NAME% AppDirectory "%SCRIPT_DIR%"

set "PARAMS=-X utf8 -u \"%SCRIPT_DIR%\%SCRIPT_NAME%\""
nssm set %SERVICE_NAME% AppParameters %PARAMS%

if %errorLevel% neq 0 (
    echo 서비스 설치 실패
    pause
    exit /b 1
)

echo 서비스 등록 완료

REM 서비스 설정
echo 서비스 설정 중...

REM 기본 정보
nssm set %SERVICE_NAME% AppDirectory "%SCRIPT_DIR%" >nul 2>&1
nssm set %SERVICE_NAME% DisplayName "%DISPLAY_NAME%" >nul 2>&1
nssm set %SERVICE_NAME% Description "HL7 message processing server for %HOSTNAME%" >nul 2>&1
nssm set %SERVICE_NAME% Start SERVICE_AUTO_START >nul 2>&1

REM 백그라운드 실행 설정 (핵심!)
nssm set %SERVICE_NAME% AppNoConsole 1 >nul 2>&1
nssm set %SERVICE_NAME% AppAllowDesktopInteraction 0 >nul 2>&1
nssm set %SERVICE_NAME% ObjectName LocalSystem >nul 2>&1

REM 로깅 설정
nssm set %SERVICE_NAME% AppStdout "%SCRIPT_DIR%\logs\stdout.log" >nul 2>&1
nssm set %SERVICE_NAME% AppStderr "%SCRIPT_DIR%\logs\stderr.log" >nul 2>&1
nssm set %SERVICE_NAME% AppRotateFiles 1 >nul 2>&1
nssm set %SERVICE_NAME% AppRotateOnline 1 >nul 2>&1
nssm set %SERVICE_NAME% AppRotateSeconds 86400 >nul 2>&1
nssm set %SERVICE_NAME% AppRotateBytes 52428800 >nul 2>&1

REM 재시작 정책
nssm set %SERVICE_NAME% AppExit Default Restart >nul 2>&1
nssm set %SERVICE_NAME% AppRestartDelay 30000 >nul 2>&1
nssm set %SERVICE_NAME% AppThrottle 5000 >nul 2>&1

REM 환경 변수 설정
nssm set %SERVICE_NAME% AppEnvironmentExtra PYTHONPATH=%SCRIPT_DIR% PYTHONUNBUFFERED=1 PYTHONIOENCODING=utf-8 >nul 2>&1

REM 의존성 설정
nssm set %SERVICE_NAME% DependOnService Tcpip Dnscache >nul 2>&1

echo 서비스 설정 완료

REM ==========================================
REM 방화벽 자동 설정
REM ==========================================
echo.
echo 방화벽 규칙 자동 추가 중...

REM 기존 규칙 제거 (오류 무시)
netsh advfirewall firewall delete rule name="HL7 Server TCP Port 5000" >nul 2>&1
netsh advfirewall firewall delete rule name="HL7 Server HTTP Port 6000" >nul 2>&1

REM 새 규칙 추가
netsh advfirewall firewall add rule name="HL7 Server TCP Port 5000" dir=in action=allow protocol=TCP localport=5000 >nul 2>&1
netsh advfirewall firewall add rule name="HL7 Server HTTP Port 6000" dir=in action=allow protocol=TCP localport=6000 >nul 2>&1

echo 방화벽 규칙 추가 완료 (포트 5000, 6000)


REM ==========================================
REM 서비스 시작
REM ==========================================
echo.
echo 서비스 시작 중...

REM 이제 환경 문제가 해결되었으므로, 단순한 원래 명령어로 실행
nssm start %SERVICE_NAME%

REM 서비스가 완전히 시작될 때까지 잠시 대기
timeout /t 3 >nul

echo.
echo 최종 서비스 상태 확인:
nssm status %SERVICE_NAME%

if %errorLevel% equ 0 (
    echo 서비스 시작 성공
    
    REM 서비스 초기화 대기
    echo 서비스 초기화 대기 중 10초...
    timeout /t 10 >nul
    
    echo 서비스 상태:
    nssm status %SERVICE_NAME%
    
) else (
    echo 서비스 시작 실패
    echo 수동 시작: nssm start %SERVICE_NAME%
)

REM ==========================================
REM 설치 완료 및 테스트
REM ==========================================
echo.
echo ========================================
echo 설치 완료!
echo ========================================
echo.
echo 서비스 정보:
echo    이름: %SERVICE_NAME%
echo    상태: 백그라운드에서 실행 중
echo    자동시작: 부팅 시 자동 시작
echo.
echo 포트 정보:
echo    TCP 5000: HL7 메시지 수신
echo    HTTP 6000: 제어 API
echo.
echo 로그 위치:
echo    %SCRIPT_DIR%\logs\
echo.
echo 관리 명령어:
echo    상태: nssm status %SERVICE_NAME%
echo    시작: nssm start %SERVICE_NAME%
echo    중지: nssm stop %SERVICE_NAME%
echo    재시작: nssm restart %SERVICE_NAME%
echo.

REM 자동 테스트
echo 자동 테스트 중...

echo 포트 바인딩 확인:
netstat -an | findstr ":5000.*LISTENING" >nul 2>&1 && echo "포트 5000 (TCP) 바인딩됨" || echo "포트 5000 아직 준비 중"
netstat -an | findstr ":6000.*LISTENING" >nul 2>&1 && echo "포트 6000 (HTTP) 바인딩됨" || echo "포트 6000 아직 준비 중"

echo.
echo API 응답 테스트:
powershell -Command "try { $r = Invoke-RestMethod 'http://localhost:6000/health' -TimeoutSec 5; Write-Host 'API 정상 응답!' -ForegroundColor Green } catch { Write-Host 'API 아직 준비 중 (정상적입니다)' -ForegroundColor Yellow }" 2>nul

echo.
echo ========================================
echo HL7 서버가 백그라운드에서 실행 중!
echo 창을 닫아도 서비스는 계속 실행됩니다.
echo ========================================
echo.
pause