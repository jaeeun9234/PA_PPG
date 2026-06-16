#include <Wire.h>
#include "MAX30105.h"
#include <math.h>

MAX30105 sensor;

// ===== Sampling =====
const int sampleRate = 200;                             // 200 Hz
const unsigned long interval_ms = 1000UL / sampleRate;  // 5 ms
unsigned long lastTime = 0;

// ===== Phase =====
int phase = 0; 

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

// ===== trial 기준 시간 =====
unsigned long trial_start_ms = 0;
bool trial_started = false;

const unsigned long I0_START = 3000;
const unsigned long I0_END = 3500;

bool baselineCaptured = false;
double red0_sum = 0.0;
double ir0_sum  = 0.0;
uint32_t i0_n = 0;
float red_dc0 = NAN;
float ir_dc0  = NAN;

// trial reset 함수
void resetTrialState(unsigned long now_ms) {
  trial_start_ms = now_ms;
  trial_started = true;

  baselineCaptured = false;
  red0_sum = 0.0;
  ir0_sum  = 0.0;
  i0_n = 0;

  red_dc0 = NAN;
  ir_dc0  = NAN;
}


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
  Serial.println("t_ms,red_raw,ir_raw,red_dc,ir_dc,red_ac,ir_ac,R,spo2,spo2_valid");

  lastTime = millis();
}

void loop() {

  while (Serial.available() > 0) {
    char c = Serial.read();
    if (c == '0') {
      resetTrialState(millis());
    }
  }
  unsigned long now = millis();
  unsigned long rel = 0;
  if (trial_started) {
    rel = now - trial_start_ms;
  }

  if (now - lastTime < interval_ms) return;
  lastTime += interval_ms;

  long red_raw = sensor.getRed();
  long ir_raw  = sensor.getIR();

  static bool dc_initialized = false;

  // ===== DC =====
  if (!dc_initialized) {
    red_dc = (float)red_raw;
    ir_dc  = (float)ir_raw;
    dc_initialized = true;
  } else {
    red_dc = (1.0f - alpha_dc) * red_dc + alpha_dc * (float)red_raw;
    ir_dc  = (1.0f - alpha_dc) * ir_dc  + alpha_dc * (float)ir_raw;
  }

  // ===== trial baseline dc0 capture =====
  if (trial_started && !baselineCaptured) {
    if (rel >= I0_START && rel < I0_END) {
      red0_sum += red_dc;
      ir0_sum  += ir_dc;
      i0_n++;
    }

    if (rel >= I0_END) {
      if (i0_n > 0) {
        red_dc0 = (float)(red0_sum / (double)i0_n);
        ir_dc0  = (float)(ir0_sum  / (double)i0_n);
        baselineCaptured = true;
      }
    }
  }


  // ===== AC =====
  float red_ac = (float)red_raw - red_dc;
  float ir_ac  = (float)ir_raw  - ir_dc;


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
  Serial.print(red_raw);  Serial.print(" ");
  Serial.print(ir_raw);   Serial.print(" ");
  Serial.print(red_dc, 2); Serial.print(" ");
  Serial.print(ir_dc, 2);  Serial.print(" ");
  Serial.print(red_ac, 2); Serial.print(" ");
  Serial.print(ir_ac, 2);  Serial.print(" ");
  if (isnan(R))    Serial.print("nan"); else Serial.print(R, 6);
  Serial.print(" ");
  if (isnan(spo2)) Serial.print("nan"); else Serial.print(spo2, 2);
  Serial.print(" ");
  Serial.print(spo2_valid);
  Serial.println(";");
}