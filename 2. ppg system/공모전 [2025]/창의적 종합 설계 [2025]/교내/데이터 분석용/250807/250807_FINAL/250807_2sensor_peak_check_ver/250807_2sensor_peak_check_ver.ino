#include <Arduino.h>

// ===== 설정 =====
const int sensorPin1 = 34;
const int sensorPin2 = 35;
const int windowSize = 20;
const int SMOOTH_WINDOW = 5;
#define PEAK_WINDOW 10
float thresholdOffset = 60;
int delayMs = 10;  // 100Hz 샘플링

// ===== 센서 구조체 정의 =====
struct PPGSensor {
  int pin;
  int buffer[windowSize];
  int indexBuffer;

  float smoothBuffer[SMOOTH_WINDOW];
  int smoothIndex;

  float peakBuffer[PEAK_WINDOW];
  int peakIndex;

  float bpmBuffer[5];
  int bpmIndex;

  bool isPeak;
  unsigned long lastPeakTime;
  float bpm;
  unsigned long overThresholdStart;
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

// ===== 센서 필터 처리 =====
float processSensor(PPGSensor &s) {
  int rawValue = analogRead(s.pin);

  // DC 제거
  s.buffer[s.indexBuffer] = rawValue;
  s.indexBuffer = (s.indexBuffer + 1) % windowSize;

  int sum = 0;
  for (int i = 0; i < windowSize; i++) sum += s.buffer[i];
  float mean = sum / (float)windowSize;

  // 필터링 + 스무딩
  float filtered = rawValue - mean;
  float smoothed = movingAverage(s, filtered);
  return smoothed;
}

// ===== 피크 시간차 계산용 변수 =====
int baseSensor = 0;  // 1 또는 2
unsigned long baseTime = 0;
bool waitingForOpposite = false;
float deltaTime = 0;

void setup() {
  Serial.begin(115200);
  initSensor(sensor1, sensorPin1);
  initSensor(sensor2, sensorPin2);
}

void loop() {
  unsigned long now = millis();

  // 센서 처리
  float smoothed1 = processSensor(sensor1);
  float smoothed2 = processSensor(sensor2);
  bool peak1 = detectPeak(sensor1, smoothed1, now);
  bool peak2 = detectPeak(sensor2, smoothed2, now);

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

  // ===== 출력 =====
  Serial.print(smoothed1); Serial.print(",");
  Serial.print(bpm1);      Serial.print(",");
  Serial.print(smoothed2); Serial.print(",");
  Serial.print(bpm2);      Serial.print(",");
  Serial.println(deltaTime);  // 마지막은 println

  delay(delayMs);
}
