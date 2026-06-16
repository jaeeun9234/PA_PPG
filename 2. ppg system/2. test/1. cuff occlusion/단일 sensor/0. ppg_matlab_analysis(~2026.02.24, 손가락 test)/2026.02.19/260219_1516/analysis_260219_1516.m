%% plot_ppg_csv.m
clear; clc; close all;

% ===== 0) 파일 지정 =====
fname = "data_260219_1516.csv";  

% ===== 1) CSV 읽기 =====
T = readtable(fname);

% 컬럼명 확인용(필요시)
disp(T.Properties.VariableNames)

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

spo2 = T.spo2;

% ===== 4) NaN 처리(선택) =====
% spo2_valid 컬럼이 있으면 valid만 쓰고 싶을 때:
if any(strcmp(T.Properties.VariableNames, "spo2_valid"))
    v = T.spo2_valid == 1;
else
    v = ~isnan(spo2);
end

%%
% ===== 5) Plot 1: RED(raw, dc, ac) =====
figure;
plot(t, red_raw); hold on;
plot(t, red_dc);
plot(t, red_ac);
grid on;
xlabel("Time (s)");
ylabel("Counts");
title("RED: raw / dc / ac");
legend("red\_raw","red\_dc","red\_ac");

%%
% ===== 6) Plot 2: IR(raw, dc, ac) =====
figure;
plot(t, ir_raw); hold on;
plot(t, ir_dc);
plot(t, ir_ac);
grid on;
xlabel("Time (s)");
ylabel("Counts");
title("IR: raw / dc / ac");
legend("ir\_raw","ir\_dc","ir\_ac");

%%
% ===== 7) Plot 3: SpO2 =====
figure;
plot(t(v), spo2(v));
grid on;
xlabel("Time (s)");
ylabel("SpO2 (%)");
title("SpO2 (valid only)");
ylim([0 100]);

%%
% ===== 8) Plot 4: OD_red, OD_ir =====
figure;
plot(t, OD_red); hold on;
plot(t, OD_ir);
grid on;
xlabel("Time (s)");
ylabel("Optical Density (relative)");
title("OD: red / ir");
legend("OD\_red","OD\_ir");

%% ===== 9) MBLL: OD -> ΔHbO2, ΔHHb (relative) =====

% ---- 안정화 구간만 사용 ----
t0 = 20;                     % 초반 20초 제거 (필요시 조정)
mask = t >= t0;

tt = t(mask);
dA_660 = OD_red(mask);       % 660nm
dA_880 = OD_ir(mask);        % 880nm

% ---- Prahl extinction coefficients (1/(M·cm)) ----
eps_HHb_660  = 3226.56;
eps_HbO2_660 = 319.6;
eps_HHb_880  = 726.44;
eps_HbO2_880 = 1154;

% d*DPF는 모르면 1로 둔다 (상대값만 의미)
k = 1.0;

% ε 행렬 (HHb 먼저, HbO2 다음!)
E = [eps_HHb_660,  eps_HbO2_660;
     eps_HHb_880,  eps_HbO2_880];

% 역행렬 계산
invE = inv(E);

% MBLL 계산
X = invE * [dA_660.'; dA_880.'] / k;   % 2 x N

dHHb  = X(1,:).';
dHbO2 = X(2,:).';
dHbT  = dHbO2 + dHHb;

%% ===== 10) ΔHbO2 / ΔHHb / ΔHbT 확인 =====
figure;
plot(tt, dHbO2); hold on;
plot(tt, dHHb);
plot(tt, dHbT);
grid on;
xlabel("Time (s)");
ylabel("Relative concentration (a.u.)");
title("\DeltaHbO2, \DeltaHHb, \DeltaHbT (relative)");
legend("\DeltaHbO2","\DeltaHHb","\DeltaHbT");

%% ===== 11) Oxygenation index (HbDiff) =====
HbDiff = dHbO2 - dHHb;

figure;
plot(tt, HbDiff);
grid on;
xlabel("Time (s)");
ylabel("a.u.");
title("HbDiff = \DeltaHbO2 - \DeltaHHb");

%% ===== 12) TOI-like normalized index =====
thr = 0.05 * max(abs(dHbT));     % threshold (조절 가능)
validT = abs(dHbT) > thr;

TOI_rel = nan(size(dHbT));
TOI_rel(validT) = 50 + 50 * (HbDiff(validT) ./ dHbT(validT));

figure;
plot(tt, TOI_rel);
grid on;
xlabel("Time (s)");
ylabel("Index (%)");
title("TOI-like index (relative, masked)");
ylim([0 100]);

%% ===== 13) 값 확인용 출력 =====
disp("dHbT stats:");
disp([min(dHbT) max(dHbT) mean(abs(dHbT))]);

disp("mean values:");
disp([mean(dHbO2) mean(dHHb) mean(dHbT)]);