#include <Wire.h>
#include "MAX30105.h"
#include <math.h>

MAX30105 sensor;

// ===== Sampling =====
const int sampleRate = 200;                      // 200 Hz
const unsigned long interval_ms = 1000UL / sampleRate;  // 5 ms
unsigned long lastTime = 0;

// ===== Phase =====
int phase = 0; // 0 baseline, 1 VO, 2 AO, 3 release

// ===== DC separation (EMA) =====
const float alpha_dc = 0.002f;  // DC 추정 EMA (느린 baseline)
float red_dc = 0.0f, ir_dc = 0.0f;

// ===== Baseline for OD =====
float red_dc0 = 0.0f, ir_dc0 = 0.0f;
bool baselineCaptured = false;

// ===== SpO2 estimation (EMA for AC^2 and DC mean) =====
const float beta = 0.01f;      // SpO2용 smoothing 강도(0.01 ≈ 1초급)

float red_ac2_ema = 0.0f, ir_ac2_ema = 0.0f;

// SpO2 calibration (실험용 근사)
const float SPO2_A = 110.0f;
const float SPO2_B = 25.0f;

static inline float clampf(float x, float lo, float hi) {
  if (x < lo) return lo;
  if (x > hi) return hi;
  return x;
}


// baseline DC를 10초-30초 평균으로 캡처
static bool baselineCollecting = false;
static uint32_t I0_START_MS = 10000;
static uint32_t I0_END_MS = 30000;


static bool collectingI0 = false;
static double red0_sum = 0.0, ir0_sum = 0.0;
static uint32_t i0_n = 0;


void setup() {
  Serial.begin(115200);
  Wire.begin();

  if (!sensor.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println("Sensor not found");
    while (1) {}
  }

  sensor.setup(0x3F, 1, 2, 200, 411, 16384);

  Serial.println("t_ms,phase,red_raw,ir_raw,red_dc,ir_dc,red_ac,ir_ac,OD_red,OD_ir,R,spo2,spo2_valid");
  lastTime = millis();
}

void loop() {
  // ===== phase 변경 (시리얼 입력) =====
  // b=baseline, v=VO, a=AO, r=release
  if (Serial.available()) {
    char c = Serial.read();
    if      (c == 'b') phase = 0;
    else if (c == 'v') phase = 1;
    else if (c == 'a') phase = 2;
    else if (c == 'r') phase = 3;
  }

  unsigned long now = millis();
  if (now - lastTime < interval_ms) return;
  lastTime += interval_ms;

  long red_raw = sensor.getRed();
  long ir_raw  = sensor.getIR();

  // ===== DC (EMA) =====
  red_dc = (1.0f - alpha_dc) * red_dc + alpha_dc * (float)red_raw;
  ir_dc  = (1.0f - alpha_dc) * ir_dc  + alpha_dc * (float)ir_raw;

  // ===== AC =====
  float red_ac = (float)red_raw - red_dc;
  float ir_ac  = (float)ir_raw  - ir_dc;

  // ===== Baseline capture for OD =====
  if (!baselineCaptured && phase == 0) {
  if (now >= I0_START_MS && now < I0_END_MS) {
    collectingI0 = true;
    if (red_dc > 1.0f && ir_dc > 1.0f) {
      red0_sum += (double)red_dc;
      ir0_sum  += (double)ir_dc;
      i0_n++;
    }
  }

  // finalize at end of window
  if (collectingI0 && now >= I0_END_MS) {
    if (i0_n > 0) {
      red_dc0 = (float)(red0_sum / (double)i0_n);
      ir_dc0  = (float)(ir0_sum  / (double)i0_n);
      baselineCaptured = true;
    }
    collectingI0 = false;
  }
}

  // ===== OD =====
  float OD_red = 0.0f, OD_ir = 0.0f;
  if (baselineCaptured) {
    float red_dc_safe = fmaxf(red_dc, 1.0f);
    float ir_dc_safe  = fmaxf(ir_dc,  1.0f);
    float red0_safe   = fmaxf(red_dc0, 1.0f);
    float ir0_safe    = fmaxf(ir_dc0,  1.0f);

    // OD = -ln(I/I0) = ln(I0/I)
    OD_red = -logf(red_dc_safe / red0_safe);
    OD_ir  = -logf(ir_dc_safe  / ir0_safe);
  }

  // ===== SpO2-related EMAs =====
  // AC^2 EMA (RMS용), DC EMA(평균용)
  float red_ac2 = red_ac * red_ac;
  float ir_ac2  = ir_ac  * ir_ac;

  red_ac2_ema = (1.0f - beta) * red_ac2_ema + beta * red_ac2;
  ir_ac2_ema  = (1.0f - beta) * ir_ac2_ema  + beta * ir_ac2;

  float red_ac_rms = sqrtf(fmaxf(red_ac2_ema, 0.0f));
  float ir_ac_rms  = sqrtf(fmaxf(ir_ac2_ema,  0.0f));

  // ===== R, SpO2 =====
  float R = NAN;
  float spo2 = NAN;
  int spo2_valid = 0;

  // 유효성 체크
  const float MIN_DC = 1000.0f;     
  const float MIN_AC_RMS = 5.0f;   

  if (red_dc > MIN_DC && ir_dc > MIN_DC &&
      red_ac_rms > MIN_AC_RMS && ir_ac_rms > MIN_AC_RMS) {

    float ratio_red = red_ac_rms / red_dc;
    float ratio_ir  = ir_ac_rms  / ir_dc;

    if (ratio_ir > 1e-8f) {
      R = ratio_red / ratio_ir;
      spo2 = SPO2_A - SPO2_B * R;
      spo2 = clampf(spo2, 0.0f, 100.0f);
      spo2_valid = 1;
    }   // !!spo2_valid = 1 조건 수정!!
  }

  // ===== CSV 출력 =====
  Serial.print("$");
  Serial.print(now);      Serial.print(" ");
  Serial.print(phase);    Serial.print(" ");
  Serial.print(red_raw);  Serial.print(" ");
  Serial.print(ir_raw);   Serial.print(" ");
  Serial.print(red_dc,2); Serial.print(" ");
  Serial.print(ir_dc,2);  Serial.print(" ");
  Serial.print(red_ac,2); Serial.print(" ");
  Serial.print(ir_ac,2);  Serial.print(" ");
  Serial.print(OD_red,6); Serial.print(" ");
  Serial.print(OD_ir,6);  Serial.print(" ");
  if (isnan(R))    Serial.print("nan"); else Serial.print(R,6);
  Serial.print(" ");
  if (isnan(spo2)) Serial.print("nan"); else Serial.print(spo2,2);
  Serial.print(" ");
  Serial.print(spo2_valid);
  Serial.println(";");

}
