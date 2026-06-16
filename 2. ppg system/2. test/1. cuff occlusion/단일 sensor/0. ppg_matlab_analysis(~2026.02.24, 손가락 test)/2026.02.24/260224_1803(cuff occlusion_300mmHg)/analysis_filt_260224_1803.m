%% plot_ppg_csv.m
clear; clc; close all;

%% ===== 0) 파일 지정 =====
fname = "data_260224_1803.csv";  

% ===== 1) CSV 읽기 =====
T = readtable(fname);

% 컬럼명 확인용(필요시)
%disp(T.Properties.VariableNames)

% ===== 2) 시간축 =====
t = double(T.t_ms) / 1000;   % sec

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

% NaN/Inf 제거/보간 (bandpass는 NaN/Inf 싫어함)
red_ac(~isfinite(red_ac)) = NaN;
red_ac = fillmissing(red_ac, "linear", "EndValues","nearest");

% ===== 4) NaN 처리(선택) =====
% spo2_valid 컬럼이 있으면 valid만 쓰고 싶을 때:
if any(strcmp(T.Properties.VariableNames, "spo2_valid"))
    v = T.spo2_valid == 1;
else
    v = ~isnan(spo2);
end

%% ===== 4.5) Fs 자동 추정 (중요!!) =====
dt = diff(t);
Fs = 1/median(dt);                  % 실제 Fs (~100Hz)
fprintf("Fs ~= %.2f Hz\n", Fs);
disp([min(dt) median(dt) max(dt)]);  


winSec = 2.0;          % 2초 윈도우 (대략 2~3 박동 포함)
W = round(winSec*Fs);

%% BPF
bp = bandpass(medfilt1(red_ac,5), [0.7 4], Fs);

figure;
plot(t, red_ac); hold on;
plot(t, bp, 'LineWidth', 1.2);
grid on;
legend('red\_ac (raw)', 'red\_ac bandpass 0.5-5Hz');
dt = diff(t);
disp([min(dt) median(dt) max(dt)])

%%
% ===== 5) Plot 1: RED(raw, dc, ac) =====
figure;

subplot(2,1,1);
plot(t, red_raw); hold on;
plot(t, red_dc);
grid on;
xlabel("Time (s)");
%ylabel("Counts");
title("RED: raw & dc & ac");
legend("red\_raw","red\_dc");

subplot(2,1,2);
plot(t, red_ac);
grid on;
xlabel("Time (s)");
ylabel("Counts");
legend("red\_ac");
linkaxes(findall(gcf,'Type','axes'),'x');

%%
% ===== 6) Plot 2: IR(raw, dc, ac) =====
figure;

subplot(2,1,1);
plot(t, ir_raw); hold on;
plot(t, ir_dc);
grid on;
xlabel("Time (s)");
%ylabel("Counts");
title("IR: raw & dc & ac");
legend("ir\_raw","ir\_dc");

subplot(2,1,2);
plot(t, ir_ac);
grid on;
xlabel("Time (s)");
ylabel("Counts");
legend("ir\_ac");
linkaxes(findall(gcf,'Type','axes'),'x');

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
ln10 = log(10);

dA_660 = OD_red(mask)/ln10;       % 660nm
dA_880 = OD_ir(mask)/ln10;        % 880nm

bad = ~isfinite(dA_660) | ~isfinite(dA_880);
dA_660(bad) = NaN;
dA_880(bad) = NaN;

% NaN을 보간해서 필터가 먹게 만들기(가장 무난)
dA_660 = fillmissing(dA_660, "linear", "EndValues","nearest");
dA_880 = fillmissing(dA_880, "linear", "EndValues","nearest");

dA_660 = lowpass(medfilt1(dA_660,5), 0.5, Fs);   % 0.2~0.8Hz 조절
dA_880 = lowpass(medfilt1(dA_880,5), 0.5, Fs);

% offset 제거
dA_660 = dA_660 - mean(dA_660(1:round(5*Fs)), 'omitnan');
dA_880 = dA_880 - mean(dA_880(1:round(5*Fs)), 'omitnan');

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

%% 10.5 ) 
eps_den = 1e-8;                   
den = dHbT;
den(abs(den) < eps_den) = NaN;     

SO2_like = dHbO2 ./ den;         

%SO2_like_clip = SO2_like;
%SO2_like_clip(SO2_like_clip < 0 | SO2_like_clip > 1) = NaN;

% (선택) 스무딩
SO2_like_s = movmean(SO2_like, round(2*Fs), 'omitnan');  % 2초 이동평균

figure;
plot(tt, SO2_like_s);
grid on;
xlabel("Time (s)");
ylabel("\DeltaHbO2 / \Delta(HbO2+HHb) (a.u.)");
title("SO2-like [DC] (from \DeltaHb)");


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

%% Perfusion Index

% AC amplitude: window RMS
ac_rms = sqrt(movmean(ir_ac.^2, W));

% DC level: window mean (혹은 movmean(ir_dc, W))
dc_mean = movmean(ir_dc, W);

% PI (%)
PI = 100 * (ac_rms ./ dc_mean);

figure;
plot(t, PI);
grid on;
xlabel("Time (s)");
ylabel("PI (%)");
title("Perfusion Index (IR) - RMS/Mean");

%% Perfusion Index_60s 이후만 plot
% ===== 60초 이전만 NaN 처리 =====
tCut = 60;

PI_plot = PI;                 % 원본 유지
PI_plot(t < tCut) = NaN;      % 50초 이전만 안 그리기

figure;
plot(t, PI_plot);
grid on;
xlabel("Time (s)");
ylabel("PI (%)");
title("Perfusion Index (IR) - 60s 이후만 표시");

%% AC 기준 HHb, HbO2, tHb
t0 = 20;
mask = t >= t0;
tt = t(mask);

% 1) mask 적용해서 안정화 구간만 사용
DA_660 = -(red_ac(mask) ./ max(red_dc(mask), 1));
DA_880 = -(ir_ac(mask)  ./ max(ir_dc(mask),  1));

% 2) NaN/Inf 방지(필수: bandpass가 싫어함)
bad = ~isfinite(DA_660) | ~isfinite(DA_880);
DA_660(bad) = NaN;
DA_880(bad) = NaN;
DA_660 = fillmissing(DA_660, "linear", "EndValues","nearest");
DA_880 = fillmissing(DA_880, "linear", "EndValues","nearest");

% 3) 스파이크 완화 -> bandpass
DA_660 = medfilt1(DA_660, 5);
DA_880 = medfilt1(DA_880, 5);

DA_660 = bandpass(DA_660, [0.7 4], Fs);
DA_880 = bandpass(DA_880, [0.7 4], Fs);

% 4) offset 제거(마스크 구간 기준)
N0 = round(5*Fs);
DA_660 = DA_660 - mean(DA_660(1:N0), 'omitnan');
DA_880 = DA_880 - mean(DA_880(1:N0), 'omitnan');

% 5) MBLL
dC = (E \ [DA_660.'; DA_880.']).';   % [HHb, HbO2]

DHHb  = dC(:,1);
DHbO2 = dC(:,2);
DtHb  = DHbO2 + DHHb;


%% 2개로 나눠 plot
figure;
subplot(2,1,1);
plot(tt, DHbO2); hold on;
plot(tt, DHHb);
grid on;
xlabel("Time (s)");
ylabel("Relative concentration (a.u.)");
title("\DeltaHbO2, \DeltaHHb [AC]");
legend("\DeltaHbO2", "\DeltaHHb");

subplot(2,1,2);
plot(tt, DtHb);
grid on;
xlabel("Time (s)");
ylabel("Relative concentration (a.u.)");
title("\DeltatHb [AC]");
legend("\DeltatHb");
linkaxes(findall(gcf,'Type','axes'),'x');

%%
% ---- NaN/Inf 제거 ----
x = DtHb;
valid = isfinite(x) & isfinite(tt);
x = x(valid);
t_use = tt(valid);

Fs = 1/mean(diff(t_use));
tu = (t_use(1):1/Fs:t_use(end)).';
xu = interp1(t_use, x, tu, 'linear', 'extrap');

% DC 제거
xu = xu - mean(xu);

N = numel(xu);
X = fft(xu);
half = floor(N/2);
f = (0:half-1)*(Fs/N);
mag = abs(X(1:half))/N;

band = (f>=0) & (f<=2.5);

figure;
plot(f(band), mag(band));
grid on;
xlabel("Frequency (Hz)"); ylabel("Magnitude");
title("FFT of \DeltaHbT (0–2.5 Hz)");

%%
figure; 
subplot(2,1,1); plot(tt, ir_dc(mask)); grid on; title("IR DC (masked)");
subplot(2,1,2); plot(tt, ir_ac(mask)); grid on; title("IR AC (masked)");