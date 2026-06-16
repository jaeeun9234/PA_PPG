#include <Wire.h>
#include "MAX30105.h"
#include <math.h>
#define TCAADDR 0x70

MAX30105 sensor1;
MAX30105 sensor2;

// ===== Sampling =====
const int sampleRate = 200; 
const unsigned long interval_ms = 1000UL / sampleRate;
const uint32_t LOOP_INTERVAL_US = interval_ms * 1000UL;
unsigned long lastTime = 0;

int avail1 = 0;
int avail2 = 0;

// ===== DC / SpO2 parameters =====
const float alpha_dc = 0.002f;
const float beta = 0.01f;

const float SPO2_A = 110.0f;
const float SPO2_B = 25.0f;

const float gamma_R = 0.003f;
const float gamma_spo2 = 0.03f;

const float MIN_DC = 1000.0f;
const float MIN_AC_RMS = 1.5f;

const float MIN_RATIO_IR = 0.0006f;
const float MAX_RATIO_IR = 0.07f;
const float MIN_RATIO_RED = 0.0006f;
const float MAX_RATIO_RED = 0.07f;

const float R_MIN = 0.2f;
const float R_MAX = 2.6f;

const float MAX_R_JUMP = 0.35f;
const uint16_t VALID_STREAK_N = 1;

struct SensorState {
  float red_dc = 0.0f;
  float ir_dc = 0.0f;
  bool dc_initialized = false;

  float red_ac2_ema = 0.0f;
  float ir_ac2_ema = 0.0f;

  float R_ema = NAN;
  float spo2_ema = NAN;

  float R_last_for_jump = NAN;
  float R_last_valid = NAN;
  float spo2_last_valid = NAN;

  uint16_t valid_streak = 0;
  uint8_t invalid_streak = 0;

  float R = NAN;
  float spo2 = NAN;
  int spo2_valid = 0;
};

SensorState s1;
SensorState s2;

void tcaSelect(uint8_t channel) {
  if (channel > 7) return;

  Wire.beginTransmission(TCAADDR);
  Wire.write(1 << channel);
  Wire.endTransmission();
}

static inline float clampf(float x, float lo, float hi) {
  if (x < lo) return lo;
  if (x > hi) return hi;
  return x;
}


void updateSpO2(SensorState &s, long red_raw, long ir_raw) {
  // ===== DC =====
  if (!s.dc_initialized) {
    s.red_dc = (float)red_raw;
    s.ir_dc = (float)ir_raw;
    s.dc_initialized = true;
  } else {
    s.red_dc = (1.0f - alpha_dc) * s.red_dc + alpha_dc * (float)red_raw;
    s.ir_dc = (1.0f - alpha_dc) * s.ir_dc + alpha_dc * (float)ir_raw;
  }

  // ===== AC =====
  float red_ac = (float)red_raw - s.red_dc;
  float ir_ac = (float)ir_raw - s.ir_dc;

  // ===== AC RMS =====
  float red_ac2 = red_ac * red_ac;
  float ir_ac2 = ir_ac * ir_ac;

  s.red_ac2_ema = (1.0f - beta) * s.red_ac2_ema + beta * red_ac2;
  s.ir_ac2_ema = (1.0f - beta) * s.ir_ac2_ema + beta * ir_ac2;

  float red_ac_rms = sqrtf(fmaxf(s.red_ac2_ema, 0.0f));
  float ir_ac_rms = sqrtf(fmaxf(s.ir_ac2_ema, 0.0f));

  bool ok = false;
  float R_tmp = NAN;

  // ===== Validity gate =====
  if (s.red_dc > MIN_DC && s.ir_dc > MIN_DC && red_ac_rms > MIN_AC_RMS && ir_ac_rms > MIN_AC_RMS) {

    float ratio_red = red_ac_rms / s.red_dc;
    float ratio_ir = ir_ac_rms / s.ir_dc;

    bool pi_ok = (ratio_ir >= MIN_RATIO_IR && ratio_ir <= MAX_RATIO_IR && ratio_red >= MIN_RATIO_RED && ratio_red <= MAX_RATIO_RED);

    if (pi_ok && ratio_ir > 1e-8f) {
      R_tmp = ratio_red / ratio_ir;

      bool r_ok = (R_tmp >= R_MIN && R_tmp <= R_MAX);

      if (r_ok) {
        bool jump_ok = true;

        if (!isnan(s.R_last_for_jump)) {
          if (fabsf(R_tmp - s.R_last_for_jump) > MAX_R_JUMP) {
            jump_ok = false;
          }
        }

        if (jump_ok) {
          if (isnan(s.R_ema)) {
            s.R_ema = R_tmp;
          } else {
            s.R_ema = (1.0f - gamma_R) * s.R_ema + gamma_R * R_tmp;
          }

          s.R_last_for_jump = R_tmp;
          s.R = s.R_ema;

          float spo2_raw = SPO2_A - SPO2_B * s.R_ema;
          spo2_raw = clampf(spo2_raw, 0.0f, 100.0f);

          if (isnan(s.spo2_ema)) {
            s.spo2_ema = spo2_raw;
          } else {
            s.spo2_ema = (1.0f - gamma_spo2) * s.spo2_ema + gamma_spo2 * spo2_raw;
          }

          s.spo2 = s.spo2_ema;
          ok = true;
        }
      }
    }
  }

  // ===== valid streak update =====
  if (ok) {
    if (s.valid_streak < 60000) s.valid_streak++;
    s.invalid_streak = 0;
  } else {
    if (s.invalid_streak < 255) s.invalid_streak++;

    if (s.invalid_streak >= 5 && s.valid_streak > 0) {
      s.valid_streak--;
    }

    if (s.invalid_streak >= 50) {
      s.R_last_for_jump = NAN;
    }
  }

  // ===== final spo2_valid =====
  if (s.valid_streak >= VALID_STREAK_N && !isnan(s.spo2)) {
    s.spo2_valid = 1;
    s.spo2_last_valid = s.spo2;
    s.R_last_valid = s.R;
  } else {
    s.spo2_valid = 0;

    if (!isnan(s.spo2_last_valid)) {
      s.spo2 = s.spo2_last_valid;
      s.R = s.R_last_valid;
    } else {
      s.spo2 = NAN;
      s.R = NAN;
    }
  }
}

void setup() {
  Serial.begin(115200);

  // SDA = 21, SCL = 22
  Wire.begin(21, 22);

  tcaSelect(1);

  if (!sensor1.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println("Sensor 1 not found");
    while (1) {}
  }

  tcaSelect(2);

  if (!sensor2.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println("Sensor 2 not found");
    while (1) {}
  }

  tcaSelect(1);
  sensor1.setup(0x3F, 4, 2, sampleRate, 411, 16384);

  tcaSelect(2);
  sensor2.setup(0x3F, 4, 2, sampleRate, 411, 16384);

  Serial.println("t1_us t2_us avail1 avail2 red_raw1 ir_raw1 red_raw2 ir_raw2 spo2_1 spo2_2 spo2_valid1 spo2_valid2");

  lastTime = millis();
}


void loop() {
  //uint32_t loopStart = micros();

  //unsigned long now = millis();

  //if (now - lastTime < interval_ms) return;
  //lastTime += interval_ms;

  static uint32_t nextTick = 0;
  uint32_t now = micros();

  if (nextTick == 0) {
    nextTick = now + LOOP_INTERVAL_US;
    return;
  }

  if ((int32_t)(now - nextTick) < 0) return;

  nextTick = now + LOOP_INTERVAL_US;  


  // ===== Sensor data read =====
  tcaSelect(1);
  uint32_t t1_us = micros();

  sensor1.check();
  avail1 = sensor1.available();

  long red_raw1 = sensor1.getRed();
  long ir_raw1 = sensor1.getIR();

  tcaSelect(2);
  uint32_t t2_us = micros();
  
  sensor2.check();
  avail2 = sensor2.available();

  long red_raw2 = sensor2.getRed();
  long ir_raw2 = sensor2.getIR();

  // ===== SpO2 update =====
  updateSpO2(s1, red_raw1, ir_raw1);
  updateSpO2(s2, red_raw2, ir_raw2);

  // ===== CSV output =====
  Serial.print("$");
  Serial.print(t1_us);
  Serial.print(" ");
  Serial.print(t2_us);
  Serial.print(" ");

  Serial.print(avail1);
  Serial.print(" ");
  Serial.print(avail2);
  Serial.print(" ");

  Serial.print(red_raw1);
  Serial.print(" ");
  Serial.print(ir_raw1);
  Serial.print(" ");
  Serial.print(red_raw2);
  Serial.print(" ");
  Serial.print(ir_raw2);
  Serial.print(" ");

  if (isnan(s1.spo2)) Serial.print("nan");
  else Serial.print(s1.spo2, 2);
  Serial.print(" ");
  if (isnan(s2.spo2)) Serial.print("nan");
  else Serial.print(s2.spo2, 2);
  Serial.print(" ");

  Serial.print(s1.spo2_valid);
  Serial.print(" ");
  Serial.print(s2.spo2_valid);

  Serial.println(";");
}