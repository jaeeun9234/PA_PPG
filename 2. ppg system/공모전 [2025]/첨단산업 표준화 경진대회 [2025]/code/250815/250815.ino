#include <Arduino.h>

#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
#include <BLE2902.h>

// ===== BLE UUID (원하는 값으로 정의; 안드로이드와 동일하게 사용) =====
#define SERVICE_UUID     "5ba7a52c-c3fe-46eb-8ade-0dacbd466278"
#define CHAR_STREAM_UUID "5dde726d-4cf3-4e2f-ab24-323caa359b78"

BLEServer*        g_server   = nullptr;
BLEService*       g_service  = nullptr;
BLECharacteristic* g_stream  = nullptr;
bool g_centralConnected = false;

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) override { g_centralConnected = true; }
  void onDisconnect(BLEServer* pServer) override {
    g_centralConnected = false;
    // 재광고
    BLEDevice::startAdvertising();
  }
};

// ===== 설정 =====
const int sensorPin1 = 34;
const int sensorPin2 = 35;
const int windowSize = 20;   // DC 성분 제거용 이동 평균 크기
const int SMOOTH_WINDOW = 5;   // 데이터 부드럽게 만드는 스무딩 크기
#define PEAK_WINDOW 10   // 피크 검출 시 사용하는 동적 임계값 계산용 윈도우 크기
float thresholdOffset = 60;   // 임계값에 더해주는 값 (민감도 조절)
int delayMs = 10;  // 100Hz 샘플링 속도

// ===== 센서 구조체 정의 =====
struct PPGSensor {
  int pin;
  int buffer[windowSize];   // DC 제거용 버퍼
  int indexBuffer;

  float smoothBuffer[SMOOTH_WINDOW];   // 스무딩 버퍼
  int smoothIndex;

  float peakBuffer[PEAK_WINDOW];   // 피크 검출용 버퍼
  int peakIndex;

  float bpmBuffer[5];   // BPM 평균값 저장용 버퍼
  int bpmIndex;

  bool isPeak;   // 현재 피크 상태인지 여부
  unsigned long lastPeakTime;
  float bpm;   // 현재 BPM
  unsigned long overThresholdStart;   // 임계값 초과 지속 시간 기록

  float lastSmoothed;
};

PPGSensor sensor1, sensor2;

// ===== 초기화 함수 =====
void initSensor(PPGSensor &s, int pin) {
  s.pin = pin;
  s.indexBuffer = 0;
  s.smoothIndex = 0;
  s.peakIndex = 0;
  s.bpmIndex = 0;
  s.isPeak = false;
  s.lastPeakTime = 0;
  s.bpm = 0;
  s.overThresholdStart = 0;

  for (int i = 0; i < windowSize; i++) s.buffer[i] = 0;
  for (int i = 0; i < SMOOTH_WINDOW; i++) s.smoothBuffer[i] = 0;
  for (int i = 0; i < PEAK_WINDOW; i++) s.peakBuffer[i] = 0;
  for (int i = 0; i < 5; i++) s.bpmBuffer[i] = 0;
}

// ===== 이동평균 스무딩 =====
float movingAverage(PPGSensor &s, float input) {
  s.smoothBuffer[s.smoothIndex] = input;
  s.smoothIndex = (s.smoothIndex + 1) % SMOOTH_WINDOW;

  float sum = 0;
  for (int i = 0; i < SMOOTH_WINDOW; i++) sum += s.smoothBuffer[i];
  return sum / SMOOTH_WINDOW;
}

// ===== 센서 필터 처리 (ADC 동시 읽기 지원) =====
void processSensorsTogether(PPGSensor &s1, PPGSensor &s2) {
  // ADC 변환 시간 최소화를 위해 연속 읽기
  int raw1 = analogRead(s1.pin);
  int raw2 = analogRead(s2.pin);

  // DC 제거
  s1.buffer[s1.indexBuffer] = raw1;
  s1.indexBuffer = (s1.indexBuffer + 1) % windowSize;

  s2.buffer[s2.indexBuffer] = raw2;
  s2.indexBuffer = (s2.indexBuffer + 1) % windowSize;

  int sum1 = 0, sum2 = 0;
  for (int i = 0; i < windowSize; i++) {
    sum1 += s1.buffer[i];
    sum2 += s2.buffer[i];
  }
  float mean1 = sum1 / (float)windowSize;
  float mean2 = sum2 / (float)windowSize;

  // 필터링 + 스무딩
  float filtered1 = raw1 - mean1;
  float filtered2 = raw2 - mean2;

  s1.lastSmoothed = movingAverage(s1, filtered1);
  s2.lastSmoothed = movingAverage(s2, filtered2);
}

// ===== 피크 탐지 + BPM 계산 =====
bool detectPeak(PPGSensor &s, float smoothed, unsigned long now) {
  const int minInterval = 333;
  const int peakHoldTime = 30;

  // 동적 임계값 계산
  s.peakBuffer[s.peakIndex] = smoothed;
  s.peakIndex = (s.peakIndex + 1) % PEAK_WINDOW;
  float peakSum = 0;
  for (int i = 0; i < PEAK_WINDOW; i++) peakSum += s.peakBuffer[i];
  float dynamicThreshold = peakSum / PEAK_WINDOW + thresholdOffset;

  if (!s.isPeak) {
    if (smoothed > dynamicThreshold) {
      if (s.overThresholdStart == 0) s.overThresholdStart = now;
      if (now - s.overThresholdStart > peakHoldTime && (now - s.lastPeakTime > minInterval)) {
        s.isPeak = true;
        if (s.lastPeakTime > 0) {
          float interval = (now - s.lastPeakTime) / 1000.0;
          float currentBPM = 60.0 / interval;
          if (currentBPM > 30 && currentBPM < 180) {
            s.bpmBuffer[s.bpmIndex] = currentBPM;
            s.bpmIndex = (s.bpmIndex + 1) % 5;
            float bpmSum = 0;
            for (int i = 0; i < 5; i++) bpmSum += s.bpmBuffer[i];
            s.bpm = bpmSum / 5;
          }
        }
        s.lastPeakTime = now;
        return true;
      }
    } else {
      s.overThresholdStart = 0;
    }
  } else if (smoothed < dynamicThreshold) {
    s.isPeak = false;
    s.overThresholdStart = 0;
  }

  return false;
}

// ===== 피크 시간차 계산용 변수 =====
int baseSensor = 0;  // 1 또는 2
unsigned long baseTime = 0;
bool waitingForOpposite = false;
float deltaTime = 0;

void setup() {
  // 1) 시리얼 + 센서 초기화
  Serial.begin(115200);
  initSensor(sensor1, sensorPin1);
  initSensor(sensor2, sensorPin2);

  // 2) BLE 초기화 + 이름 설정
  BLEDevice::init("HeartSync");   // 스캔에 뜨는 기기 이름

  // 3) 서버/서비스/특성 생성
  g_server = BLEDevice::createServer();
  g_server->setCallbacks(new ServerCallbacks());

  g_service = g_server->createService(SERVICE_UUID);

  g_stream = g_service->createCharacteristic(
    CHAR_STREAM_UUID,
    BLECharacteristic::PROPERTY_NOTIFY
  );

  // 4) CCCD(Notify ON/OFF 스위치) 추가
  g_stream->addDescriptor(new BLE2902());

  // 5) 서비스 시작
  g_service->start();

  // 6) 광고 구성(이름 + 서비스 UUID 노출 권장)
  BLEAdvertising* adv = BLEDevice::getAdvertising();

  BLEAdvertisementData advData;
  advData.setName("HeartSync");
  advData.setCompleteServices(BLEUUID(SERVICE_UUID));
  adv->setAdvertisementData(advData);

  BLEAdvertisementData scanData;
  scanData.setName("HeartSync");
  adv->setScanResponseData(scanData);

  adv->setScanResponse(true);

  // 7) 광고 시작
  BLEDevice::startAdvertising();
}

void loop() {
  unsigned long now = millis();

  // 두 센서 동시에 읽기
  processSensorsTogether(sensor1, sensor2);

  bool peak1 = detectPeak(sensor1, sensor1.lastSmoothed, now);
  bool peak2 = detectPeak(sensor2, sensor2.lastSmoothed, now);

  float bpm1 = sensor1.bpm;
  float bpm2 = sensor2.bpm;

  // ===== 센서 간 피크 시간차 계산 (양방향 감지 포함) =====
  if (peak1 && baseSensor == 2 && waitingForOpposite) {
    deltaTime = -1.0 * (now - baseTime);
    baseSensor = 0;
    waitingForOpposite = false;
  } else if (peak2 && baseSensor == 1 && waitingForOpposite) {
    deltaTime = (now - baseTime);
    baseSensor = 0;
    waitingForOpposite = false;
  } else if (peak1 && baseSensor == 0) {
    baseSensor = 1;
    baseTime = now;
    waitingForOpposite = true;
  } else if (peak2 && baseSensor == 0) {
    baseSensor = 2;
    baseTime = now;
    waitingForOpposite = true;
  }

  // 출력
  Serial.print(sensor1.lastSmoothed); Serial.print(",");
  Serial.print(bpm1);                 Serial.print(",");
  Serial.print(sensor2.lastSmoothed); Serial.print(",");
  Serial.print(bpm2);                 Serial.print(",");
  Serial.println(deltaTime);

  if (g_centralConnected) {
    char line[96];
    snprintf(line, sizeof(line), "%.2f,%.2f,%.2f,%.2f,%.2f",
            sensor1.lastSmoothed, bpm1, sensor2.lastSmoothed, bpm2, deltaTime);
    g_stream->setValue((uint8_t*)line, strlen(line));
    g_stream->notify();
  }

  delay(delayMs);
}