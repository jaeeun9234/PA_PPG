#include <Wire.h>
#include "MAX30105.h"
#include <math.h>

MAX30105 sensor;

// ===== Sampling =====
const int sampleRate = 200;                             // 200 Hz
const unsigned long interval_ms = 1000UL / sampleRate;  // 5 ms
unsigned long lastTime = 0;

// ===== Phase =====
int phase = 0; // 0 baseline, 1 VO, 2 AO, 3 release

// ===== DC separation (EMA) =====
const float alpha_dc = 0.002f;  // DC 추정 EMA (느린 baseline)
float red_dc = 0.0f, ir_dc = 0.0f;

// ===== SpO2 estimation (EMA for AC^2) =====
const float beta = 0.01f;       // SpO2용 smoothing 강도(0.01 ≈ 1초급)
float red_ac2_ema = 0.0f, ir_ac2_ema = 0.0f;

// SpO2 calibration (실험용 근사)
const float SPO2_A = 110.0f;
const float SPO2_B = 25.0f;

static inline float clampf(float x, float lo, float hi) {
  if (x < lo) return lo;
  if (x > hi) return hi;
  return x;
}

// ===== Baseline capture for OD =====
static bool baselineCaptured = false;
static bool collectingI0 = false;

static bool phase0_started = false;
static uint32_t phase0_start_ms = 0;

static double red0_sum = 0.0, ir0_sum = 0.0;
static uint32_t i0_n = 0;

static float red_dc0 = 0.0f, ir_dc0 = 0.0f;

void setup() {
  Serial.begin(115200);
  Wire.begin();

  if (!sensor.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println("Sensor not found");
    while (1) {}
  }

  sensor.setup(0x3F, 1, 2, 200, 411, 16384);

  // NOTE: Python logger expects "$ ... ;" lines, so keep data lines in that format.
  // This header line does NOT start with '$' so your parser will ignore it.
  Serial.println("t_ms,phase,red_raw,ir_raw,red_dc,ir_dc,red_ac,ir_ac,OD_red,OD_ir,R,spo2,spo2_valid");

  lastTime = millis();
}

void loop() {
  // ===== phase 변경 (시리얼 입력: '0'~'3') =====
  // non-blocking: 들어온 문자를 전부 처리해서 버퍼 쌓임 방지
  while (Serial.available() > 0) {
    char c = (char)Serial.read();
    if      (c == '0') phase = 0;
    else if (c == '1') phase = 1;
    else if (c == '2') phase = 2;
    else if (c == '3') phase = 3;
    // '\n', '\r' 등은 무시
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

  // ===== Baseline capture for OD (phase 0 entry 기준 +10~+30s) =====
  const unsigned long I0_START_REL_MS = 10000UL; // phase0 진입 후 10s
  const unsigned long I0_END_REL_MS   = 30000UL; // phase0 진입 후 30s

  if (!baselineCaptured) {

    // phase 0 진입 순간: 타이머 시작 + 누적 초기화(재시도 가능)
    if (phase == 0 && !phase0_started) {
      phase0_started = true;
      phase0_start_ms = now;

      collectingI0 = false;
      red0_sum = 0.0;
      ir0_sum  = 0.0;
      i0_n = 0;
    }

    // phase 0에서 벗어나면 reset → 다음에 다시 0으로 들어올 때 재시도
    if (phase != 0) {
      phase0_started = false;
      collectingI0 = false;
    }

    if (phase == 0 && phase0_started) {
      unsigned long rel = now - phase0_start_ms;

      if (rel >= I0_START_REL_MS && rel < I0_END_REL_MS) {
        collectingI0 = true;
        if (red_dc > 1.0f && ir_dc > 1.0f) {
          red0_sum += (double)red_dc;
          ir0_sum  += (double)ir_dc;
          i0_n++;
        }
      }

      // finalize
      if (collectingI0 && rel >= I0_END_REL_MS) {
        if (i0_n > 0) {
          red_dc0 = (float)(red0_sum / (double)i0_n);
          ir_dc0  = (float)(ir0_sum  / (double)i0_n);
          baselineCaptured = true;
        }
        collectingI0 = false;
      }
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

  // ===== SpO2-related EMAs (RMS용) =====
  float red_ac2 = red_ac * red_ac;
  float ir_ac2  = ir_ac  * ir_ac;

  red_ac2_ema = (1.0f - beta) * red_ac2_ema + beta * red_ac2;
  ir_ac2_ema  = (1.0f - beta) * ir_ac2_ema  + beta * ir_ac2;

  float red_ac_rms = sqrtf(fmaxf(red_ac2_ema, 0.0f));
  float ir_ac_rms  = sqrtf(fmaxf(ir_ac2_ema,  0.0f));

  // ===== R, SpO2 (improved validity) =====
  float R = NAN;
  float spo2 = NAN;
  int spo2_valid = 0;

  // 기본 DC/AC 게이트
  const float MIN_DC = 1000.0f;
  const float MIN_AC_RMS = 4.0f;

  // PI(=AC/DC) 범위 게이트
  const float MIN_RATIO_IR  = 0.003f;
  const float MAX_RATIO_IR  = 0.050f;
  const float MIN_RATIO_RED = 0.003f;
  const float MAX_RATIO_RED = 0.050f;

  // R 범위 게이트
  const float R_MIN = 0.2f;
  const float R_MAX = 2.0f;

  // 연속 통과(200 Hz 기준)
  static uint16_t valid_streak = 0;
  const uint16_t VALID_STREAK_N = 100; 

  // 점프 제한
  static float spo2_last_for_jump = NAN;
  static float spo2_last_valid = NAN;
  const float MAX_SPO2_JUMP = 8.0f;

  bool ok = false;

  if (red_dc > MIN_DC && ir_dc > MIN_DC &&
      red_ac_rms > MIN_AC_RMS && ir_ac_rms > MIN_AC_RMS) {

    float ratio_red = red_ac_rms / red_dc;
    float ratio_ir  = ir_ac_rms  / ir_dc;

    bool pi_ok = (ratio_ir  >= MIN_RATIO_IR  && ratio_ir  <= MAX_RATIO_IR &&
                  ratio_red >= MIN_RATIO_RED && ratio_red <= MAX_RATIO_RED);

    if (pi_ok && ratio_ir > 1e-8f) {
      float R_tmp = ratio_red / ratio_ir;
      bool r_ok = (R_tmp >= R_MIN && R_tmp <= R_MAX);

      if (r_ok) {
        float spo2_tmp = SPO2_A - SPO2_B * R_tmp;
        spo2_tmp = clampf(spo2_tmp, 0.0f, 100.0f);

        bool jump_ok = true;
        if (!isnan(spo2_last_for_jump)) {
          if (fabsf(spo2_tmp - spo2_last_for_jump) > MAX_SPO2_JUMP) jump_ok = false;
        }

        if (jump_ok) {
          R = R_tmp;
          spo2 = spo2_tmp;
          ok = true;
          spo2_last_for_jump = spo2_tmp;   
        }
      }
    }
  }

  if (ir_ac_rms > red_ac_rms * 10){
    spo2_valid = 0;
  }

  if (ok) {
    if (valid_streak < 60000) valid_streak++;
  } else {
    if (valid_streak > 0) valid_streak--;
  }

  if (valid_streak >= VALID_STREAK_N && !isnan(spo2)) {
    spo2_valid = 1;
    spo2_last_valid = spo2;
  } else {
    spo2_valid = 0;
    // (선택) invalid면 spo2를 nan으로 고정해서 출력 깔끔하게
    // spo2 = NAN;
  }

  // ===== CSV 출력 =====
  Serial.print("$");
  Serial.print(now);      Serial.print(" ");
  Serial.print(phase);    Serial.print(" ");
  Serial.print(red_raw);  Serial.print(" ");
  Serial.print(ir_raw);   Serial.print(" ");
  Serial.print(red_dc, 2); Serial.print(" ");
  Serial.print(ir_dc, 2);  Serial.print(" ");
  Serial.print(red_ac, 2); Serial.print(" ");
  Serial.print(ir_ac, 2);  Serial.print(" ");
  Serial.print(OD_red, 6); Serial.print(" ");
  Serial.print(OD_ir, 6);  Serial.print(" ");
  if (isnan(R))    Serial.print("nan"); else Serial.print(R, 6);
  Serial.print(" ");
  if (isnan(spo2)) Serial.print("nan"); else Serial.print(spo2, 2);
  Serial.print(" ");
  Serial.print(spo2_valid);
  Serial.println(";");
}