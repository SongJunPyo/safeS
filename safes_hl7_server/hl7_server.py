from http import server
import pandas as pd
import asyncio
import logging
from hl7apy.parser import parse_message
import json
from pydantic import BaseModel
from confluent_kafka import Producer
from fastapi import FastAPI, HTTPException
from collections import deque
import signal
import sys
import time
import traceback
import os

# ✅ 로깅 설정
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler("hl7_server.log", encoding='utf-8'),
        logging.StreamHandler()
    ]
)
logging.info("✅ 서버 시작됨")
class HL7Server:
    # def __init__(self):
    #     self.forwarding_enabled = False
    #     self.db_manager = db_manager.DBManager()
    def __init__(self):
        self.forwarding_enabled = False
        self.db_manager = None  # DB 비활성화
        self.max_retries = 3
        self.retry_delay = 10

    def _init_db_connection(self):
        # """DB 연결 비활성화"""
        # logging.info("ℹ️ DB 연결 비활성화됨 (테스트 모드)")
        # self.db_manager = None
        """DB 연결 초기화 (재시도 로직 포함)"""
        for attempt in range(self.max_retries):
            try:
                logging.info("✅ DB 연결 성공")
                return
            except Exception as e:
                logging.error(f"❌ DB 연결 실패 (시도 {attempt + 1}/{self.max_retries}): {e}")
                if attempt < self.max_retries - 1:
                    logging.info(f"⏳ {self.retry_delay}초 후 재시도...")
                    time.sleep(self.retry_delay)
                else:
                    logging.critical(" DB 연결 실패. 서비스가 불안정할 수 있습니다.")
                    # 서비스는 계속 실행하되, DB 연결은 나중에 재시도
                    self.db_manager = None
                    
        
    async def handle_client_mindray(self, reader, writer):
        peername = writer.get_extra_info('peername')
        self.writer = writer
        logging.info(f"[클라이언트] 연결됨: {peername}")
        buffer = b''
        try:
            while True:
                try:
                    logging.info(f"[클라이언트] {peername} 메시지 수신 대기 중...")
                    chunk = await asyncio.wait_for(reader.read(4096), timeout=30)
                except asyncio.TimeoutError:
                    logging.warning(f"⛔ [클라이언트] {peername} 30초 무응답 — 연결 종료")
                    break
                
                if not chunk:
                    logging.info(f"[클라이언트] {peername} 연결 종료됨")
                    break
                
                # chunk(bytes)를 텍스트로 저장
                try:
                    text = chunk.decode('utf-8') # 또는 'ascii', 'latin-1' 등 필요에 따라 조정
                except UnicodeDecodeError:
                    text = chunk.decode('utf-8', errors='ignore') # 깨지는 문자 무시하고 저장

                with open("log1_250722.txt", "a", encoding='utf-8') as f:
                    f.write(text)

                # 이전에 처리되지 않은 메시지와 현재 chunk를 합침
                buffer += chunk
                
                # MLLP 메시지 파싱 (MSH 세그먼트 기준으로 MLLP 에 감싸져 전달되는 것으로 보임)
                messages, buffer = self.parse_mllp_messages(buffer)

                # 하나의 MSH 세그먼트 기준으로 메시지 분리
                for msg in messages:
                    hl7_text = msg.decode(errors='ignore')
                    self.forward_mindray_hl7text_to_kafka(hl7_text)
                    logging.info(f"▶️ 전송: {hl7_text}")
                    # # 🔹 forwarding_enabled일 때만 전송
                    # #if self.forwarding_enabled:
                    
                    # hl7_dict = self.hl7_to_obxlist(hl7_text)
                    # if hl7_dict is not None:
                    #     self.forward_message_to_kafka(hl7_dict)
                    #     logging.info(f"▶️ 저장 중: {hl7_dict}")
                    #     #self._save_to_db_with_retry(hl7_dict)

        except asyncio.CancelledError:
            logging.info(f"[클라이언트] {peername} Listener cancelled.")
        except ConnectionResetError:
            logging.warning(f"[클라이언트] {peername} 연결 강제 종료됨 (ConnectionResetError)")
        except Exception as e:
            logging.error(f"[클라이언트] {peername} 처리 중 예외 발생: {e}")
        finally:
            try:
                writer.close()
                await writer.wait_closed()
            except Exception as close_err:
                logging.warning(f"[클라이언트] {peername} 종료 중 예외: {close_err}")
            logging.info(f"[클라이언트] {peername} 연결 종료 완료")
            
    async def handle_client_cardiac(self, reader, writer):
        peername = writer.get_extra_info('peername')
        self.writer = writer
        logging.info(f"[클라이언트] 연결됨: {peername}")
        buffer = b''
        try:
            while True:
                try:
                    logging.info(f"[클라이언트] {peername} 메시지 수신 대기 중...")
                    chunk = await asyncio.wait_for(reader.read(4096), timeout=30)
                except asyncio.TimeoutError:
                    logging.warning(f"⛔ [클라이언트] {peername} 30초 무응답 — 연결 종료")
                    break
                
                if not chunk:
                    logging.info(f"[클라이언트] {peername} 연결 종료됨")
                    break
                
                # chunk(bytes)를 텍스트로 저장
                try:
                    text = chunk.decode('utf-8') # 또는 'ascii', 'latin-1' 등 필요에 따라 조정
                except UnicodeDecodeError:
                    text = chunk.decode('utf-8', errors='ignore') # 깨지는 문자 무시하고 저장

                with open("log1_250722.txt", "a", encoding='utf-8') as f:
                    f.write(text)

                # 이전에 처리되지 않은 메시지와 현재 chunk를 합침
                buffer += chunk
                
                # MLLP 메시지 파싱 (MSH 세그먼트 기준으로 MLLP 에 감싸져 전달되는 것으로 보임)
                messages, buffer = self.parse_mllp_messages(buffer)

                # 하나의 MSH 세그먼트 기준으로 메시지 분리
                for msg in messages:
                    hl7_text = msg.decode(errors='ignore')
                    self.forward_cardiac_hl7text_to_kafka(hl7_text)
                    logging.info(f"▶️ 전송: {hl7_text}")
                    # # 🔹 forwarding_enabled일 때만 전송
                    # #if self.forwarding_enabled:
                    
                    # hl7_dict = self.hl7_to_obxlist(hl7_text)
                    # if hl7_dict is not None:
                    #     self.forward_message_to_kafka(hl7_dict)
                    #     logging.info(f"▶️ 저장 중: {hl7_dict}")
                    #     #self._save_to_db_with_retry(hl7_dict)

        except asyncio.CancelledError:
            logging.info(f"[클라이언트] {peername} Listener cancelled.")
        except ConnectionResetError:
            logging.warning(f"[클라이언트] {peername} 연결 강제 종료됨 (ConnectionResetError)")
        except Exception as e:
            logging.error(f"[클라이언트] {peername} 처리 중 예외 발생: {e}")
        finally:
            try:
                writer.close()
                await writer.wait_closed()
            except Exception as close_err:
                logging.warning(f"[클라이언트] {peername} 종료 중 예외: {close_err}")
            logging.info(f"[클라이언트] {peername} 연결 종료 완료")
            
    def _save_to_db_with_retry(self, hl7_dict, max_retries=3):
        # """DB 저장 비활성화"""
        # logging.info("ℹ️ DB 저장 건너뜀 (테스트 모드)")
        """DB 저장 (재시도 로직 포함)"""
        for attempt in range(max_retries):
            try:
                # DB 연결 상태 확인 및 재연결
                if self.db_manager is None:
                    self._init_db_connection()
                
                if self.db_manager is not None:
                    self.forward_message_to_db(hl7_dict)
                    return  # 성공시 리턴
                else:
                    raise Exception("DB 연결 없음")
                
            except Exception as e:
                logging.error(f"DB 저장 실패 (시도 {attempt + 1}/{max_retries}): {e}")
                if attempt < max_retries - 1:
                    # DB 연결 재초기화 시도
                    self.db_manager = None
                    time.sleep(2)  # 2초 대기
                else:
                    logging.error(f" DB 저장 최종 실패: {hl7_dict.get('monitor_serial', 'Unknown')}")


    def start_forwarding(self, surgery_room_id=None, surgery_id=None):
        self.forwarding_enabled = True
        
        if surgery_room_id is None or surgery_id is None:
            logging.info(f"단순 수집 요청")
        else:
            logging.info(f"모니터 연결 요청: {surgery_room_id}, {surgery_id}")
            self.surgery_room_id = surgery_room_id
            self.surgery_id = surgery_id

    def stop_forwarding(self):
        self.forwarding_enabled = False
    
    def sanitize_for_json(self,obj):
        from collections.abc import ValuesView, KeysView, ItemsView

        if isinstance(obj, dict):
            return {k: self.sanitize_for_json(v) for k, v in obj.items()}
        elif isinstance(obj, (list, tuple)):
            return [self.sanitize_for_json(v) for v in obj]
        elif isinstance(obj, (ValuesView, KeysView, ItemsView)):
            return self.sanitize_for_json(list(obj))
        else:
            return obj
    
    def forward_message_to_kafka(self, hl7_dict):
        # 예시: Kafka로 전송
        logging.info(hl7_dict)
        logging.info("▶️ 전송 중:", hl7_dict)
        sanitized = self.sanitize_for_json(hl7_dict)  # dict_values → list
          
        try:
            producer = Producer({'bootstrap.servers': '100.100.89.107:9092'})
            topic_name = f"safes_signal"
            producer.produce(
                topic=topic_name,
                value=json.dumps(sanitized, ensure_ascii=False)
            )
            producer.flush()
            print("✅ Kafka로 메시지 전송 완료")
        except Exception as e:
            print("❌ Kafka 전송 실패:", e)
            raise HTTPException(status_code=500, detail="Failed to send message to Kafka")

    def forward_mindray_hl7text_to_kafka(self, hl7_text):
        logging.info(hl7_text)
        logging.info(f"▶️ 전송 중: {hl7_text}")
        
        try:
            producer = Producer({'bootstrap.servers': '100.100.89.107:9092'})
            topic_name = "mindray_hl7_msg"
            producer.produce(
                topic=topic_name,
                value=hl7_text  # 문자열 그대로 전송
            )
            producer.flush()
            print("✅ Kafka로 메시지 전송 완료")
        except Exception as e:
            print("❌ Kafka 전송 실패:", e)
            raise HTTPException(status_code=500, detail="Failed to send message to Kafka")
    
    def forward_cardiac_hl7text_to_kafka(self, hl7_text):
        logging.info(hl7_text)
        logging.info(f"▶️ 전송 중: {hl7_text}")
        
        try:
            producer = Producer({'bootstrap.servers': '100.100.89.107:9092'})
            topic_name = "cardiac_hl7_msg"
            producer.produce(
                topic=topic_name,
                value=hl7_text  # 문자열 그대로 전송
            )
            producer.flush()
            print("✅ Kafka로 메시지 전송 완료")
        except Exception as e:
            print("❌ Kafka 전송 실패:", e)
            raise HTTPException(status_code=500, detail="Failed to send message to Kafka")
        


    def forward_message_to_db(self, hl7_dict):
        self.db_manager.insert_observation_datas(hl7_dict)
        logging.info("✅ DB로 메시지 전송 완료")
        

    async def run_server(self, port):
        # 비동기 TCP 서버 IP/Port 바인딩
        if port==5000:
            logging.info(f"{port}번 포트로 HL7 서버 시작됨 (Mindray 전용)")
            server = await asyncio.start_server(self.handle_client_mindray, host="0.0.0.0", port=port)
        else:
            logging.info(f"{port}번 포트로 HL7 서버 시작됨 (Cardiac 전용)")
            server = await asyncio.start_server(self.handle_client_cardiac, host="0.0.0.0", port=port)
            
        logging.info(f"✅ HL7 서버 시작됨 (포트 {port})")
        # 클라이언트 연결 유지
        async with server:
            await server.serve_forever()

    def send_ack_response(self, control_id="0"):
        ack = (
            "MSH|^~\\&|009B^00A037009Bxxx^EUI-64|4(RE)|||20250511173000||ACK^R01|"+control_id+"|P|2.6|||AL|NE||UNICODE UTF-8|||IHE_PCD_001^IHE PCD^1.3.6.1.4.1.19376.1.6.1.1.1^ISO|\r"
            "MSA|AR|" + control_id + "|Close|\r"
        )
        wrapped = b'\x0b' + ack.encode('utf-8') + b'\x1c\x0d'

        if hasattr(self, 'writer'):
            self.writer.write(wrapped)
            logging.info("[클라이언트] ACK 전송 완료")
        else:
            logging.warning("[클라이언트] writer가 아직 설정되지 않았습니다.")

    def disconnect(self):
        if hasattr(self, 'writer') and not self.writer.is_closing():
            logging.info("[클라이언트] 직접 연결 종료 처리 중...")
            self.writer.close()
            self.writer.wait_closed()
            logging.info("[클라이언트] 직접 연결 종료 완료")

    def parse_mllp_messages(self, buffer):
        logging.info("parse_mllp_messages")
        MLLP_START = b'\x0b'
        MLLP_END = b'\x1c\x0d'
        messages = []

        while True:
            start = buffer.find(MLLP_START)
            end = buffer.find(MLLP_END)

            # 종료 바이트가 시작 바이트 뒤에 있는 경우만 처리
            if start != -1 and end != -1 and end > start:
                full_message = buffer[start:end+2]
                content = full_message[1:-2]  # 시작/종료 바이트 제거
                messages.append(content)
                buffer = buffer[end + 2:] # 처리된 메시지 이후로 버퍼 축소
            else:
                break # 메시지 경계가 아직 완성되지 않은 경우

        return messages, buffer
                

class Hl7_server_manager:
    def __init__(self):
        self.hl7_server = None
        
    def create_app(self, hl7server):
        from fastapi import FastAPI
        from starlette.middleware.sessions import SessionMiddleware
        from fastapi.middleware.cors import CORSMiddleware

        app = FastAPI()
        self.hl7_server = hl7server

        # 다른 도메인에서 오는 요청을 허용할 수 있도록 설정합니다.
        app.add_middleware(
            CORSMiddleware,
            #allow_origins=["http://15.164.220.68"],     #flutter 웹앱의 주소를 설정하면됨. 나중에  # flutter run -d web-server --web-port= <<여기에 설정된 값으로 하면됨
            allow_origins=["*"], 
            allow_credentials=True,                  # 쿠키를 허용하도록 설정
            allow_methods=["*"],
            allow_headers=["*"],
        )
        
        app.add_middleware(
            SessionMiddleware,
            secret_key="your-secure-secret-key",  # 실제로는 안전한 키를 사용해야 합니다
        )

        class SurgeryInfo(BaseModel):
            surgery_room_id: int
            surgery_id: int

        @app.post("/request_monitor_connection")
        async def request_monitor_connection(data: SurgeryInfo=None):
          
            if not data or not data.surgery_room_id or not data.surgery_id:
                logging.info(f"모니터 연결 요청")
                self.hl7_server.start_forwarding()
                return {"status": "monitor value forwarding started"}
            else:
                logging.info(f"모니터 연결 요청: {data.surgery_room_id}, {data.surgery_id}")
                self.hl7_server.start_forwarding(data.surgery_room_id, data.surgery_id)  # ✅ 전송 트리거
                return {"status": "monitor value forwarding started", "surgery_room_id": data.surgery_room_id, "surgery_id": data.surgery_id}
        
        @app.post("/request_monitor_disconnection")
        async def request_monitor_disconnection():
            self.hl7_server.stop_forwarding()  # ✅ 전송 트리거
            return {"status": "monitor value forwarding stopped"}
        
        @app.get("/health")
        async def health_check():
            return {
                "status": "alive",
                "forwarding_enabled": self.hl7_server.forwarding_enabled if self.hl7_server else False,
                "timestamp": time.time(),
                "mode": "test_mode_no_db"
            }
 
        return app


    async def start_server(self):
        
        logging.info("[HL7 서버] 시작 준비 중...")
        
        hl7server = HL7Server()
        self.app = self.create_app(hl7server)
        logging.info("[HL7 서버] FastAPI 서버 생성")
        
        import uvicorn
        config = uvicorn.Config(app=self.app, host="0.0.0.0", port=6000, log_level="info")
        server = uvicorn.Server(config)

        mindray_port = 5000
        # cardiac_port = 3000 <- 울산 전용
        await asyncio.gather(   # 비동기 작업을 동시에 실행
            hl7server.run_server(mindray_port),          # TCP 서버 실행 (monitor에서 TCP 연결요청오면 hl7 메시지 받는 부분)
            #hl7server.run_server(cardiac_port),
            server.serve()                  # FastAPI 서버 실행 (Safe S에서 연결 요청을 받기 위한 부분)
        )
        
def handle_exception(exc_type, exc_value, exc_traceback):
    if issubclass(exc_type, KeyboardInterrupt):
        sys.__excepthook__(exc_type, exc_value, exc_traceback)
        return
    logging.critical("처리되지 않은 예외 발생", exc_info=(exc_type, exc_value, exc_traceback))

sys.excepthook = handle_exception
   
if __name__ == '__main__':
    try:
        manager = Hl7_server_manager()
        asyncio.run(manager.start_server())
    except KeyboardInterrupt:
        logging.info(" 사용자에 의해 종료됨")
    except Exception as e:
        logging.critical(f" 서버 시작 실패: {e}")
        logging.critical(traceback.format_exc())
        sys.exit(1)