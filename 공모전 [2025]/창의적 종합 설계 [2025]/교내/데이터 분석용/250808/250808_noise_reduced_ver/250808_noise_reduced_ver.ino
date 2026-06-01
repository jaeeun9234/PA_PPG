#include <Arduino.h>

// ===== 설정 =====
const int sensorPin1 = 34;
const int sensorPin2 = 35;
const int windowSize = 100;       // DC 제거용 이동 평균
#define PEAK_WINDOW 10           // 동적 threshold 계산용
float thresholdOffset = 60;      // threshold 보정값 (필요시 조정)
int delayMs = 10;                // 100Hz 샘플링
const int MIN_PROMINENCE = 40;   // 피크 돌출도 기준 (스케일 따라 조정)
const int MIN_WIDTH_SAMPLES = 6; // 최소 폭 (100Hz에서 60bpm 근처)

// 동시성(합의) 창
const int COINC_WINDOW_MS = 120; // 양측 피크가 이 시간 내에 발생해야 한 쌍으로 인정

// ===== 센서 구조체 =====
struct PPGSensor {
  int pin;

  // DC 제거 버퍼
  int buffer[windowSize];
  int indexBuffer;

  // 미디언(3점)
  float m3[3];
  int m3idx;

  // Savitzky–Golay(5점)
  float sg5[5];
  int sgIdx;
  int sgFill;

  // 동적 threshold 계산 버퍼
  float peakBuffer[PEAK_WINDOW];
  int peakIndex;

  // BPM 이동평균
  float bpmBuffer[5];
  int bpmIndex;

  // 상태
  bool isPeak;
  unsigned long lastPeakTime;
  float bpm;
  unsigned long overThresholdStart;
  float recentMin; // prominence 계산용
  int widthCounter;
};

// 파형/피크 분리 출력용
struct SensorOutput {
  float displayValue; // 파형 표시용 (SG-5)
  float peakValue;    // 피크 검출용 (미디언)
};

PPGSensor sensor1, sensor2;

// ===== 프로토타입 =====
void initSensor(PPGSensor &s, int pin);
int  readStableADC(int pin);
float median3(PPGSensor &s, float x);
float sg5_quadratic(PPGSensor &s, float x);
bool detectPeak(PPGSensor &s, float input, unsigned long now);
SensorOutput processSensor(PPGSensor &s);
void matchPeaks(bool peak1, bool peak2, unsigned long now);

// ===== deltaTime 매칭용 전역 =====
long pending1 = -1;      // sensor1 보류 타임스탬프 (ms)
long pending2 = -1;      // sensor2 보류 타임스탬프 (ms)
float deltaTime = 0.0f;  // 마지막 매칭 결과(ms), sensor1→sensor2 양수, sensor2→sensor1 음수

// ===== 초기화 =====
void initSensor(PPGSensor &s, int pin) {
  s.pin = pin;
  s.indexBuffer = 0;
  s.m3idx = 0;
  s.sgIdx = 0;
  s.sgFill = 0;
  s.peakIndex = 0;
  s.bpmIndex = 0;
  s.isPeak = false;
  s.lastPeakTime = 0;
  s.bpm = 0;
  s.overThresholdStart = 0;
  s.recentMin = 1e9f;  // 큰 값으로 시작
  s.widthCounter = 0;

  for (int i = 0; i < windowSize; i++) s.buffer[i] = 0;
  for (int i = 0; i < 3; i++) s.m3[i] = 0;
  for (int i = 0; i < 5; i++) { s.sg5[i] = 0; s.bpmBuffer[i] = 0; }
  for (int i = 0; i < PEAK_WINDOW; i++) s.peakBuffer[i] = 0;
}

// ===== ADC 튐 억제 (트림 평균) =====
int readStableADC(int pin) {
  int v0 = analogRead(pin);
  int v1 = analogRead(pin);
  int v2 = analogRead(pin);
  int v3 = analogRead(pin);
  int mn = min(min(v0, v1), min(v2, v3));
  int mx = max(max(v0, v1), max(v2, v3));
  int sum = v0 + v1 + v2 + v3 - mn - mx;
  return sum / 2;
}

// ===== 미디언 필터 (3점) =====
float median3(PPGSensor &s, float x) {
  s.m3[s.m3idx] = x;
  s.m3idx = (s.m3idx + 1) % 3;
  float a = s.m3[0], b = s.m3[1], c = s.m3[2];
  if ((a <= b && b <= c) || (c <= b && b <= a)) return b;
  if ((b <= a && a <= c) || (c <= a && a <= b)) return a;
  return c;
}

// ===== Savitzky–Golay (5점, 2차) =====
float sg5_quadratic(PPGSensor &s, float x) {
  s.sg5[s.sgIdx] = x;
  s.sgIdx = (s.sgIdx + 1) % 5;
  if (s.sgFill < 5) { s.sgFill++; return x; }
  int i0 = (s.sgIdx + 3) % 5;
  int i1 = (s.sgIdx + 4) % 5;
  int i2 = (s.sgIdx + 0) % 5;
  int i3 = (s.sgIdx + 1) % 5;
  int i4 = (s.sgIdx + 2) % 5;
  float y = (-3*s.sg5[i0] + 12*s.sg5[i1] + 17*s.sg5[i2] + 12*s.sg5[i3] - 3*s.sg5[i4]) / 35.0f;
  return y;
}

// ===== 피크 탐지 + BPM 계산 =====
bool detectPeak(PPGSensor &s, float input, unsigned long now) {
  const int minInterval = 333;  // ms
  const int peakHoldTime = 30;  // ms

  // 동적 threshold
  s.peakBuffer[s.peakIndex] = input;
  s.peakIndex = (s.peakIndex + 1) % PEAK_WINDOW;
  float peakSum = 0;
  for (int i = 0; i < PEAK_WINDOW; i++) peakSum += s.peakBuffer[i];
  float dynamicThreshold = peakSum / PEAK_WINDOW + thresholdOffset;

  // prominence용 최저값 추적
  if (!s.isPeak) s.recentMin = min(s.recentMin, input);

  if (!s.isPeak) {
    if (input > dynamicThreshold) {
      if (s.overThresholdStart == 0) s.overThresholdStart = now;
      s.widthCounter++;
      if ((now - s.overThresholdStart > peakHoldTime) &&
          (now - s.lastPeakTime > minInterval) &&
          (input - s.recentMin >= MIN_PROMINENCE) &&
          (s.widthCounter >= MIN_WIDTH_SAMPLES)) {

        s.isPeak = true;
        s.widthCounter = 0;

        if (s.lastPeakTime > 0) {
          float interval = (now - s.lastPeakTime) / 1000.0f;
          float currentBPM = 60.0f / interval;
          if (currentBPM > 30 && currentBPM < 180) {
            s.bpmBuffer[s.bpmIndex] = currentBPM;
            s.bpmIndex = (s.bpmIndex + 1) % 5;
            float bpmSum = 0;
            for (int i = 0; i < 5; i++) bpmSum += s.bpmBuffer[i];
            s.bpm = bpmSum / 5.0f;
          }
        }
        s.lastPeakTime = now;
        s.recentMin = input;
        return true;
      }
    } else {
      s.overThresholdStart = 0;
      s.widthCounter = 0;
      s.recentMin = input;
    }
  } else if (input < dynamicThreshold) {
    s.isPeak = false;
    s.overThresholdStart = 0;
  }

  return false;
}

// ===== 센서 처리 =====
SensorOutput processSensor(PPGSensor &s) {
  int rawValue = readStableADC(s.pin);

  // DC 제거
  s.buffer[s.indexBuffer] = rawValue;
  s.indexBuffer = (s.indexBuffer + 1) % windowSize;
  int sum = 0;
  for (int i = 0; i < windowSize; i++) sum += s.buffer[i];
  float mean = sum / (float)windowSize;
  float detrend = rawValue - mean;

  // 1단계: 미디언 필터
  float denoised = median3(s, detrend);

  // 2단계: 표시용 스무딩(SG-5)
  float displaySmooth = sg5_quadratic(s, denoised);

  // 3단계: 피크 입력(반응 빠르게) = 미디언 출력
  float peakInput = denoised;

  SensorOutput out;
  out.displayValue = displaySmooth;
  out.peakValue = peakInput;
  return out;
}

// ===== 양측 피크 매칭 (대기-매칭) =====
void matchPeaks(bool peak1, bool peak2, unsigned long now) {
  // 오래된 보류는 만료
  if (pending1 >= 0 && (long)(now - pending1) > COINC_WINDOW_MS) pending1 = -1;
  if (pending2 >= 0 && (long)(now - pending2) > COINC_WINDOW_MS) pending2 = -1;

  // 센서1 피크
  if (peak1) {
    if (pending2 >= 0 && (long)(now - pending2) <= COINC_WINDOW_MS) {
      // sensor2가 먼저, 그 뒤 sensor1 → 음수
      deltaTime = - (float)(now - pending2);
      pending1 = -1; pending2 = -1;
    } else {
      pending1 = (long)now;
    }
  }

  // 센서2 피크
  if (peak2) {
    if (pending1 >= 0 && (long)(now - pending1) <= COINC_WINDOW_MS) {
      // sensor1이 먼저, 그 뒤 sensor2 → 양수
      deltaTime = (float)(now - pending1);
      pending1 = -1; pending2 = -1;
    } else {
      pending2 = (long)now;
    }
  }
}

void setup() {
  Serial.begin(115200);
  analogReadResolution(12);
  initSensor(sensor1, sensorPin1);
  initSensor(sensor2, sensorPin2);
}

void loop() {
  unsigned long now = millis();

  // 센서 처리
  SensorOutput out1 = processSensor(sensor1);
  SensorOutput out2 = processSensor(sensor2);

  // 피크 검출
  bool peak1 = detectPeak(sensor1, out1.peakValue, now);
  bool peak2 = detectPeak(sensor2, out2.peakValue, now);

  // 동시성 매칭으로 deltaTime 계산
  matchPeaks(peak1, peak2, now);

  // 출력: 표시용 값 + BPM + deltaTime(ms)
  Serial.print(out1.displayValue); Serial.print(",");
  Serial.print(sensor1.bpm);       Serial.print(",");
  Serial.print(out2.displayValue); Serial.print(",");
  Serial.print(sensor2.bpm);       Serial.print(",");
  Serial.println(deltaTime);

  delay(delayMs);
}
