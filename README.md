# safeS
동물병원에서 수술 시 발생하는 HL7(Health Level Seven) 의료 메시지를 수집하고 처리하는 시스템

![image.png](attachment:ef6ebd8c-9968-413d-baa8-80aee98a6bbb:image.png)

| **구분** | **deploy_hl7_service.bat (배치 스크립트)** | **hl7_server.py (파이썬 스크립트)** |
| --- | --- | --- |
| **주 역할** | **자동 배포 및 서비스 관리(백그라운드 자동 실행)** | **HL7 통신 및 데이터 처리 엔진** |
| **주요 기능** | 환경 구축(Python 설치), 의존성 설치, 윈도우 서비스 등록, 방화벽 설정  | TCP 서버(HL7 수신), FastAPI(제어 API), Kafka 데이터 전송  |
| **작동 시점** | 최초 설치 시 또는 서버 재설정 시  | 서버 운영 중 실시간(백그라운드 실행)  |
