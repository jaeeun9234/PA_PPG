%% plot_ppg_csv.m
clear; clc; close all;

%% ===== 0) 파일 지정 =====
fname = "data_20260319_1721.csv";  

% ===== 1) CSV 읽기 =====
T = readtable(fname);

% 컬럼명 확인용(필요시)
%disp(T.Properties.VariableNames)

% ===== 2) 시간축 =====
t = T.t_ms / 1000;   % sec


% ===== 3) 데이터 추출 =====
red_raw = T.red_raw;
red_dc  = T.red_dc;
red_ac  = T.red_ac;

ir_raw  = T.ir_raw;
ir_dc   = T.ir_dc;
ir_ac   = T.ir_ac;

OD_red = T.OD_red;
OD_ir  = T.OD_ir;

phase = T.phase;
SPO2 = T.spo2;

R = T.R;

% phase 변화 지점
idx_change = find(diff(phase) ~= 0) + 1;

t_change = t(idx_change);
phase_change = phase(idx_change);

T0 = t(find(phase == 0, 1, 'first'));   % occlusion start
T1 = t(find(phase == 1, 2, 'first'));   % 최고 압력 도달 
T2 = t(find(phase == 2, 3, 'first'));   % recovery start 
T3 = t(find(phase == 3, 1, 'first'));

t_baseline_idx = (phase == 0) & (t >= 10) & (t <= 30);

% ---- Prahl extinction coefficients (1/(M·cm)) ----
eps_HHb_660  = 3226.56;
eps_HbO2_660 = 319.6;
eps_HHb_880  = 726.44;
eps_HbO2_880 = 1154;

%% ===== 4.5) Fs 자동 추정 (중요!!) =====
dt = diff(t);
Fs = 1/median(dt);                  % 실제 Fs (~100Hz)
fprintf("Fs ~= %.2f Hz\n", Fs);
disp([min(dt) median(dt) max(dt)]);  


winSec = 2.0;          % 2초 윈도우 (대략 2~3 박동 포함)
W = round(winSec*Fs);

% MBLL 식에서 안정화 구간만 데이터 뽑을 경우 사용
t0 = 30;                    
mask = t >= t0;
tt = t(mask);


%% AC [bpf]
red_ac = fillmissing(red_ac, 'linear');
ir_ac = fillmissing(ir_ac, 'linear');

red_ac_bp = bandpass(red_ac, [0.7 4], Fs);
ir_ac_bp = bandpass(ir_ac, [0.7 4], Fs);

%% MBLL (AC, DC 분리 X)
ln10 = log(10);

red0 = mean(red_raw(t_baseline_idx), 'omitnan');
ir0 = mean(ir_raw(t_baseline_idx), 'omitnan');

dA_660 = -log(red_raw(mask) / red0);
dA_880 = -log(ir_raw(mask)  / ir0);

bad = ~isfinite(dA_660) | ~isfinite(dA_880);
dA_660(bad) = NaN;
dA_880(bad) = NaN;

dA_660 = fillmissing(dA_660, "linear", "EndValues","nearest");
dA_880 = fillmissing(dA_880, "linear", "EndValues","nearest");

dA_660 = medfilt1(dA_660, 5);
dA_880 = medfilt1(dA_880, 5);

k = 1.0;

E = [eps_HHb_660,  eps_HbO2_660;
     eps_HHb_880,  eps_HbO2_880];

invE = inv(E);

dC = (invE \ [dA_660.'; dA_880.']).' / k;

dHHb  = dC(:,1);
dHbO2 = dC(:,2);
dHbT  = dHbO2 + dHHb;

%% plotting
figure;
plot(tt, dHbO2, LineWidth = 1.2); hold on;
plot(tt, dHHb, LineWidth = 1.2); hold on;
plot(tt, dHbT, LineWidth = 1.2);
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');
grid on;
xlabel("Time (s)");
title("HbO_2, HHb, tHb [AC + DC]");
legend("HbO_2","HHb","tHb", "Location", "best");


%% pulse oximetry -> spo2 
spo2_A = 107;
spo2_B = 17;
spo2 = spo2_A - spo2_B * R;

figure;
plot(t, spo2, 'LineWidth', 1.0);
xline(T1,'k--'); xline(T2,'k--'); xline(T3,'k--');
grid on;
xlabel("Time (s)"); ylabel("SpO2 (%)");
ylim([0 100]);
title("SpO_2");

%% baseline 95% 기준 plot
idx_base = (phase == 0);
base_mean = mean(spo2(idx_base), 'omitnan');
scale = 95 / base_mean;

spo2_scaled = spo2*scale;
spo2_scaled = min(max(spo2_scaled, 0), 100);

figure;
plot(t, spo2_scaled);
xline(T1,'k--'); xline(T2,'k--'); xline(T3,'k--');
grid on;
