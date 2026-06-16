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

static bool slideRefInitialized = false;
static float red_ref = 0.0f, ir_ref = 0.0f;

const float alpha_ref = 0.0005f;

static bool firstDcCaptured = false;
static float red_dc_init = 0.0f;
static float ir_dc_init = 0.0f;


void setup() {
  Serial.begin(115200);
  Wire.begin(21, 22);

  if (!sensor.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println("Sensor not found");
    while (1) {}
  }

  sensor.setup(0x3F, 4, 2, 200, 411, 16384);

  // NOTE: Python logger expects "$ ... ;" lines, so keep data lines in that format.
  // This header line does NOT start with '$' so your parser will ignore it.
  //("t_ms,phase,red_raw,ir_raw,red_dc,ir_dc,red_ac,ir_ac,OD_red,OD_ir,R,spo2,spo2_valid");
  Serial.println("t_ms,phase,red_raw,ir_raw,red_dc,ir_dc,red_dc_init,ir_dc_init,red_ac,ir_ac,OD_red,OD_ir,OD_red_slide,OD_ir_slide,R,spo2,spo2_valid");

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

  // ===== First DC capture =====
  if (!firstDcCaptured && millis() > 3000 && red_dc > 1.0f && ir_dc > 1.0f) {
    red_dc_init = red_dc;
    ir_dc_init  = ir_dc;
    firstDcCaptured = true;
  }

  // ===== Sliding reference update =====
  if (!slideRefInitialized) {
    red_ref = red_dc;
    ir_ref  = ir_dc;
    slideRefInitialized = true;
  } else {
    red_ref = (1.0f - alpha_ref) * red_ref + alpha_ref * red_dc;
    ir_ref  = (1.0f - alpha_ref) * ir_ref  + alpha_ref * ir_dc;
  }

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
  float OD_red_slide = 0.0f, OD_ir_slide = 0.0f;

  float red_dc_safe = fmaxf(red_dc, 1.0f);
  float ir_dc_safe  = fmaxf(ir_dc,  1.0f);

  if (baselineCaptured) {
    float red0_safe   = fmaxf(red_dc0, 1.0f);
    float ir0_safe    = fmaxf(ir_dc0,  1.0f);

    // OD = -ln(I/I0) = ln(I0/I)
    OD_red = -logf(red_dc_safe / red0_safe);
    OD_ir  = -logf(ir_dc_safe  / ir0_safe);
  }

  // sliding reference OD
  if (slideRefInitialized) {
    float red_ref_safe = fmaxf(red_ref, 1.0f);
    float ir_ref_safe  = fmaxf(ir_ref,  1.0f);

    OD_red_slide = -logf(red_dc_safe / red_ref_safe);
    OD_ir_slide  = -logf(ir_dc_safe  / ir_ref_safe);
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

  static float R_ema = NAN;
  const float gamma_R = 0.003f; 
  static float spo2_ema = NAN;
  const float gamma_spo2 = 0.03f; 

  // 기본 DC/AC 게이트
  const float MIN_DC = 1000.0f;
  const float MIN_AC_RMS = 1.5f;

  // PI(=AC/DC) 범위 게이트
  const float MIN_RATIO_IR  = 0.0006f;
  const float MAX_RATIO_IR  = 0.07f;
  const float MIN_RATIO_RED = 0.0006f;
  const float MAX_RATIO_RED = 0.07f;

  // R 범위 게이트
  const float R_MIN = 0.2f;
  const float R_MAX = 2.6f;

  // 연속 통과(200 Hz 기준)
  static uint16_t valid_streak = 0;
  const uint16_t VALID_STREAK_N = 10; 

  // 점프 제한
  static float spo2_last_valid = NAN;
  static float R_last_for_jump = NAN;
  static float R_last_valid = NAN;
  const float MAX_R_JUMP = 0.35f;

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

        bool jump_ok = true;
        if (!isnan(R_last_for_jump)) {
          if (fabsf(R_tmp - R_last_for_jump) > MAX_R_JUMP) jump_ok = false;
        }

        if (jump_ok) {
          if (isnan(R_ema)) R_ema = R_tmp;
          else R_ema = (1.0f - gamma_R) * R_ema + gamma_R * R_tmp;

          R = R_ema;
          R_last_for_jump = R_tmp;

          float spo2_raw = SPO2_A - SPO2_B * R_ema;
          spo2_raw = clampf(spo2_raw, 0.0f, 100.0f);

          if (isnan(spo2_ema)) spo2_ema = spo2_raw;
          else spo2_ema = (1.0f - gamma_spo2) * spo2_ema + gamma_spo2 * spo2_raw;

          spo2 = spo2_ema;

          ok = true;
        }
      }
    }
  }

  static uint8_t invalid_streak = 0;

  if (ok) {
    if (valid_streak < 60000) valid_streak++;
    invalid_streak = 0;
  } else {
    if (invalid_streak < 255) invalid_streak++;
    if (invalid_streak >= 5 && valid_streak > 0) valid_streak--;

    if (invalid_streak >= 50){
      R_last_for_jump = NAN;
    }
  }

  if (valid_streak >= VALID_STREAK_N && !isnan(spo2)) {
    spo2_valid = 1;
    spo2_last_valid = spo2;
    R_last_valid = R;
  } else {
    spo2_valid = 0;
    if (!isnan(spo2_last_valid)){
      spo2 = spo2_last_valid;
      R = R_last_valid;
    } else{
      spo2 = NAN;
      R = NAN;
    }
  }

  // ===== CSV 출력 =====
  Serial.print("$");
  Serial.print(now);      Serial.print(" ");
  Serial.print(phase);    Serial.print(" ");
  Serial.print(red_raw);  Serial.print(" ");
  Serial.print(ir_raw);   Serial.print(" ");
  Serial.print(red_dc, 2); Serial.print(" ");
  Serial.print(ir_dc, 2);  Serial.print(" ");
  Serial.print(red_dc_init, 2); Serial.print(" ");
  Serial.print(ir_dc_init, 2);  Serial.print(" ");
  Serial.print(red_ac, 2); Serial.print(" ");
  Serial.print(ir_ac, 2);  Serial.print(" ");
  Serial.print(OD_red, 6); Serial.print(" ");
  Serial.print(OD_ir, 6);  Serial.print(" ");
  Serial.print(OD_red_slide, 6); Serial.print(" ");
  Serial.print(OD_ir_slide, 6);  Serial.print(" ");
  if (isnan(R))    Serial.print("nan"); else Serial.print(R, 6);
  Serial.print(" ");
  if (isnan(spo2)) Serial.print("nan"); else Serial.print(spo2, 2);
  Serial.print(" ");
  Serial.print(spo2_valid);
  Serial.println(";");
}