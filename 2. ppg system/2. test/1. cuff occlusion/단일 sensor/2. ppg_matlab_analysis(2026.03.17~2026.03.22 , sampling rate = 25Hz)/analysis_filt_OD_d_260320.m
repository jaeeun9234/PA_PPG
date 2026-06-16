%% plot_ppg_csv.m
clear; clc; close all;

%% ===== 0) 파일 지정 =====
fname = "data_20260320_1631.csv";  

% ===== 1) CSV 읽기 =====
T = readtable(fname);

% 컬럼명 확인용(필요시)
%disp(T.Properties.VariableNames)

% ===== 2) 시간축 =====
t = T.t_ms / 1000;   % sec
t0_idx = (t >= 3.0) & (t < 3.5);

% ===== 3) 데이터 추출 =====
red_raw = T.red_raw;
red_dc  = T.red_dc;
red_ac  = T.red_ac;

ir_raw  = T.ir_raw;
ir_dc   = T.ir_dc;
ir_ac   = T.ir_ac;


spo2 = T.spo2;

phase = T.phase;

DC_red0 = mean(T.red_dc(t0_idx), 'omitnan');
DC_ir0 = mean(T.ir_dc(t0_idx), 'omitnan');
RAW_red0 = mean(T.red_raw(t0_idx), 'omitnan');
RAW_ir0 = mean(T.ir_raw(t0_idx), 'omitnan');

% phase 변화 지점
idx_change = find(diff(phase) ~= 0) + 1;

t_change = t(idx_change);
phase_change = phase(idx_change);

idx_base = (phase == 0);


T0 = t(find(phase == 0, 1, 'first'));   % occlusion start
T1 = t(find(phase == 1, 1, 'first'));   % 최고 압력 도달 
T2 = t(find(phase == 2, 1, 'first'));   % recovery start 
T3 = t(find(phase == 3, 1, 'first'));

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


%% ===== 5) Plot 1: RED(raw, dc, ac) =====
figure;

subplot(2,1,1);
plot(tt, red_raw(mask)); hold on;
plot(tt, red_dc(mask), Linewidth = 1.2);
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');
grid on;
xlabel("Time (s)");
title("RED: raw & dc & ac");
legend("red\_raw","red\_dc", "Location", "best");

subplot(2,1,2);
plot(tt, red_ac_bp(mask));
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');
grid on;
xlabel("Time (s)");
legend("red\_ac (bandpass : 0.7 - 4)");
linkaxes(findall(gcf,'Type','axes'),'x');


%% ===== 6) Plot 2: IR(raw, dc, ac) =====
figure;

subplot(2,1,1);
plot(tt, ir_raw(mask)); hold on;
plot(tt, ir_dc(mask), LineWidth=1.2);
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');
grid on;
xlabel("Time (s)");
title("IR: raw & dc & ac");
legend("ir\_raw","ir\_dc", "Location", "best");

subplot(2,1,2);
plot(tt, ir_ac(mask));
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');
grid on;
xlabel("Time (s)");
legend("ir\_ac (bandpass : 0.7 - 4)");
linkaxes(findall(gcf,'Type','axes'),'x');

%% ===== 7) Plot 3: SpO2 (arduino => calibration 식 : 110 - 25*R) ===== 
figure;
idx = T.spo2_valid == 1;
plot(t, spo2, "LineWidth", 1.2);
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');

grid on;
xlabel("Time (s)");
ylabel("SpO2 (%)");
title("SpO2 (artery)");
ylim([0 100]);


%% ===== 8) Plot 4: OD_red, OD_ir =====
OD_red_dc = red_dc ./ DC_red0;
OD_ir_dc = ir_dc ./ DC_ir0;

figure;
plot(tt, OD_red_dc(mask)); hold on;
plot(tt, OD_ir_dc(mask));
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');
grid on;
xlabel("Time (s)");
ylabel("Optical Density (relative)");
title("OD: red & ir");
legend("OD\_red","OD\_ir", "Location", "best");

%% ===== 9) MBLL: OD -> ΔHbO2, ΔHHb (relative) =====

ln10 = log(10);

%dA_660 = OD_red_dc(mask)/ln10;       % 660nm
%dA_880 = OD_ir_dc(mask)/ln10;        % 880nm

dA_660 = -log10(red_dc(mask) ./ DC_red0);
dA_880 = -log10(ir_dc(mask)  ./ DC_ir0);

bad = ~isfinite(dA_660) | ~isfinite(dA_880);
dA_660(bad) = NaN;
dA_880(bad) = NaN;

% NaN을 보간해서 필터가 먹게 만들기(가장 무난)
dA_660 = fillmissing(dA_660, "linear", "EndValues","nearest");
dA_880 = fillmissing(dA_880, "linear", "EndValues","nearest");


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
plot(tt, dHbO2, LineWidth = 1.2); hold on;
plot(tt, dHHb, LineWidth = 1.2); hold on;
plot(tt, dHbT, LineWidth = 1.2);
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');
grid on;
xlabel("Time (s)");
title("HbO_2, HHb, tHb [DC]");
legend("HbO_2","HHb","tHb", "Location", "best");


%% envelope
dHbO2_env = envelope(abs(dHbO2), 100);
dHHb_env = envelope(abs(dHHb), 100);
dHbT_env = envelope(abs(dHbT), 100);


%% so2 plot
so2 = dHbO2 ./ dHbT;
so2_s = movmean(so2, round(2*Fs), 'omitnan');

figure;
plot(tt, so2);
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');
grid on;
title("HbO_2 / tHb [DC]");
legend("SO2");


%% ===== 11) Oxygenation index (HbDiff) =====
HbDiff = dHbO2 - dHHb;

figure;
plot(tt, HbDiff);
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');
grid on;
xlabel("Time (s)");
title("HbDiff = HbO2 - HHb");

%% ===== 12) TOI-like normalized index =====
thr = 0.05 * max(abs(dHbT));     % threshold (조절 가능)
validT = abs(dHbT) > thr;

TOI_rel = nan(size(dHbT));
TOI_rel(validT) = 50 + 50 * (HbDiff(validT) ./ dHbT(validT));

figure;
plot(tt, TOI_rel, LineWidth = 1.2);
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');
grid on;
xlabel("Time (s)");
ylabel("Index (%)");
title("TOI-like index (relative, masked)");


%% Perfusion Index
ac_rms = sqrt(movmean(ir_ac.^2, W));

dc_mean = movmean(ir_dc, W);

% PI (%)
PI = 100 * (ac_rms ./ dc_mean);

figure;
plot(tt, PI(mask));
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');
grid on;
xlabel("Time (s)");
ylabel("PI (%)");
title("Perfusion Index (IR) - AC(rms) / DC(mean)");

%% AC 기준 HHb, HbO2, tHb
% 1) mask 적용해서 안정화 구간만 사용
DA_660 = -(red_ac(mask) ./ max(red_dc(mask), 1));
DA_880 = -(ir_ac(mask)  ./ max(ir_dc(mask),  1));

% 2) NaN/Inf 방지(안 넣을 경우 bandpass에서 에러 발생 가능)
bad = ~isfinite(DA_660) | ~isfinite(DA_880);
DA_660(bad) = NaN;
DA_880(bad) = NaN;
DA_660 = fillmissing(DA_660, "linear", "EndValues","nearest");
DA_880 = fillmissing(DA_880, "linear", "EndValues","nearest");

% 3) 스파이크 완화 -> bandpass
DA_660 = medfilt1(DA_660, 5);
DA_880 = medfilt1(DA_880, 5);

% 5) MBLL
Y = (E \ [DA_660.'; DA_880.']).';   % [HHb, HbO2]

DHHb  = Y(:,1);
DHbO2 = Y(:,2);
DtHb  = DHbO2 + DHHb;


%% 2개로 나눠 plot
figure;
subplot(2,1,1);
plot(tt, DHbO2); hold on;
plot(tt, DHHb);
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');
grid on;
xlabel("Time (s)");
title("HbO_2, HHb [AC]");
legend("HbO_2", "HHb", "Location", "best");

subplot(2,1,2);
plot(tt, DtHb);
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');
grid on;
xlabel("Time (s)");
title("tHb [AC]");
legend("tHb", "Location", "best");
linkaxes(findall(gcf,'Type','axes'),'x');


%% FFT [AC]
% ---- NaN/Inf 제거 ----
x = DtHb;
valid1 = isfinite(x) & isfinite(tt);
x = x(valid1);
t_use1 = tt(valid1);

% 중복 시간 제거
[t_use1u, ia] = unique(t_use1, 'stable');
x = x(ia);

Fs = 1/mean(diff(t_use1u));
tu = (t_use1u(1):1/Fs:t_use1u(end)).';
xu = interp1(t_use1u, x, tu, 'linear', 'extrap');

xu = xu - mean(xu);

N = numel(xu);
X = fft(xu);
half = floor(N/2);
f = (0:half-1)*(Fs/N);
mag = abs(X(1:half))/N;

band = (f>=0.7) & (f<=5);

figure;
plot(f(band), mag(band));
grid on;
xlabel("Frequency (Hz)");
ylabel("Magnitude");
title("FFT of \DeltatHb [AC] (0.7–5 Hz)");

%% FFT [DC]
y = dHbT;
valid2 = isfinite(y) & isfinite(tt);
y = y(valid2);
t_use = tt(valid2);

% 중복 시간 제거
[t_use_u, ia] = unique(t_use, 'stable');
y = y(ia);

Fs = 1/mean(diff(t_use_u));
tu = (t_use_u(1):1/Fs:t_use_u(end)).';
xu = interp1(t_use_u, y, tu, 'linear', 'extrap');

xu = xu - mean(xu);

N = numel(xu);
X = fft(xu);
half = floor(N/2);
f = (0:half-1)*(Fs/N);
mag = abs(X(1:half))/N;

band = (f>=0) & (f<=0.7);

figure;
plot(f(band), mag(band));
grid on;
xlabel("Frequency (Hz)");
ylabel("Magnitude");
title("FFT of \DeltatHb [DC] (0–0.7 Hz)");

%% 노이즈 확인용 plot
figure; 
subplot(2,2,1); plot(tt, ir_dc(mask)); grid on; title("IR DC (masked)");
subplot(2,2,3); plot(tt, ir_ac(mask)); grid on; title("IR AC (masked)");
subplot(2,2,2); plot(tt, red_dc(mask)); grid on; title("RED DC (masked)");
subplot(2,2,4); plot(tt, red_ac(mask)); grid on; title("RED AC (masked)");


%% 변화량 plot
ymin = min([dHbO2(:); DHbO2(:); dHHb(:); DHHb(:); dHbT(:); DtHb(:)]);
ymax = max([dHbO2(:); DHbO2(:); dHHb(:); DHHb(:); dHbT(:); DtHb(:)]);

figure;
plot(tt, dHbO2, "Color", [1 0 0 1], "LineWidth",  1.2); hold on; plot(tt, DHbO2, "Color", [0 0 1 0.5]); 
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');
title("HbO_2  [DC/AC]"); legend("HbO_2 [DC]", "HbO_2 [AC]", "Location", "best");
ylim([ymin ymax]);
grid on;

figure;
plot(tt, dHHb, "Color", [1 0 0 1], "LineWidth", 1.2); hold on; plot(tt, DHHb, "Color", [0 0 1 0.5]); 
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');
title("HHb [DC/AC]"); legend("HHb [DC] ", "HHb [AC]", "Location", "best");
ylim([ymin ymax]);
grid on;

figure;
plot(tt, dHbT, "Color", [1 0 0 1], "LineWidth", 1.2); hold on; plot(tt, DtHb, "Color", [0 0 1 0.5]); 
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');
title("tHb  [DC/AC]"); legend("tHb [DC] ", "tHb [AC]", "Location", "best");
ylim([ymin ymax]);
grid on;

%% MBLL (AC, DC 분리 X)
da_660 = -log(red_raw(mask) / RAW_red0);
da_880 = -log(ir_raw(mask)  / RAW_ir0);

da_660 = da_660 / ln10;
da_880 = da_880 / ln10;

bad = ~isfinite(da_660) | ~isfinite(da_880);
da_660(bad) = NaN;
da_880(bad) = NaN;

da_660 = fillmissing(da_660, "linear", "EndValues","nearest");
da_880 = fillmissing(da_880, "linear", "EndValues","nearest");

da_660 = medfilt1(da_660, 5);
da_880 = medfilt1(da_880, 5);

k = 1.0;

E = [eps_HHb_660,  eps_HbO2_660;
     eps_HHb_880,  eps_HbO2_880];

Z = (E \ [da_660.'; da_880.']).' / k;

dHHB  = Z(:,1);
dHBO2 = Z(:,2);
dTHB  = dHBO2 + dHHB;

%% plotting
figure;
plot(tt, dHBO2, LineWidth = 1.2); hold on;
plot(tt, dHHB, LineWidth = 1.2); hold on;
plot(tt, dTHB, LineWidth = 1.2);
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');
grid on;
xlabel("Time (s)");
title("HbO_2, HHb, tHb [AC + DC]");
legend("HbO_2","HHb","tHb", "Location", "best");

%% 아날로그 노이즈 관련 확인용 plot
t1 = 240;
win = 20;
seg = (t >= (t1-win)) & (t <= (t1+win));

TT = t(seg);
red_raw_s = red_raw(seg);
ir_raw_s = ir_raw(seg);
red_dc_s = red_dc(seg);
ir_dc_s = ir_dc(seg);
red_ac_s = red_ac(seg);
ir_ac_s = ir_ac(seg);

bp = [0.7 4.0];
red_ac_bp1 = bandpass(red_ac_s, bp, Fs);
ir_ac_bp1 = bandpass(ir_ac_s, bp, Fs);

figure;
subplot(3,1,1);
plot(TT, red_raw_s); hold on;
plot(TT, ir_raw_s);
grid on;
title(sprintf("RAW around %.1fs (\\pm %ds)", t1, win));
legend("red\_raw", "ir\_raw", "Location", "best");

subplot(3,1,2);
plot(TT, red_dc_s); hold on;
plot(TT, ir_dc_s); 
grid on;
title("DC around target window");
legend("red\_dc", "ir\_dc", "Location", "best");

subplot(3,1,3);
plot(TT, red_ac_bp1); hold on;
plot(TT, ir_ac_bp1); 
grid on;
title(sprintf("AC bandpass %.1f - %.1f Hz", bp(1), bp(2)));
legend("red\_ac\_bp", "ir\_ac\_bp", "Location", "best");
