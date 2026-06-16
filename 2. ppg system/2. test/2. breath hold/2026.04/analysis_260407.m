%% plot_ppg_csv.m
clear; clc; close all;

%% ===== 0) 파일 지정 =====
fname = "data_20260409_1414.csv";  

% ===== 1) CSV 읽기 =====
T = readtable(fname);

% 컬럼명 확인용(필요시)
%disp(T.Properties.VariableNames)

% ===== 2) 시간축 =====
t = T.t_ms / 1000;   % sec
t_trial = T.t_trial_ms / 1000;
t0_idx = (t_trial >= 3.0) & (t_trial < 3.5);

trial_id = T.trial_id;
phase = T.phase;

% ===== 3) 데이터 추출 =====
red_raw = T.red_raw;
red_dc  = T.red_dc;
red_ac  = T.red_ac;

ir_raw  = T.ir_raw;
ir_dc   = T.ir_dc;
ir_ac   = T.ir_ac;

spo2 = T.spo2;

DC_red0 = mean(T.red_dc(t0_idx), 'omitnan');
DC_ir0 = mean(T.ir_dc(t0_idx), 'omitnan');
RAW_red0 = mean(T.red_raw(t0_idx), 'omitnan');
RAW_ir0 = mean(T.ir_raw(t0_idx), 'omitnan');

% phase 변화 지점
idx_change = find(diff(phase) ~= 0) + 1;

t_change = t(idx_change);
phase_change = phase(idx_change);

idx_base = (phase == 0);


phases = parsePhaseBreathHold(t_trial, phase);

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


%% AC [bpf]
red_ac = fillmissing(red_ac, 'linear');
ir_ac = fillmissing(ir_ac, 'linear');

red_ac_bp = bandpass(red_ac, [0.7 4], Fs);
ir_ac_bp = bandpass(ir_ac, [0.7 4], Fs);


%% ===== 5) Plot 1: RED(raw, dc, ac) =====
figure;

subplot(2,1,1);
plot(t_trial, red_raw); hold on;
plot(t_trial, red_dc, Linewidth = 1.2);
drawPhaseBreathHold(phases);
grid on;
xlabel("Time (s)");
title("RED: raw & dc & ac");
legend("red\_raw","red\_dc", "Location", "best");

subplot(2,1,2);
plot(t_trial, red_ac_bp);
drawPhaseBreathHold(phases);
grid on;
xlabel("Time (s)");
legend("red\_ac (bandpass : 0.7 - 4)");
linkaxes(findall(gcf,'Type','axes'),'x');


%% ===== 6) Plot 2: IR(raw, dc, ac) =====
figure;

subplot(2,1,1);
plot(t_trial, ir_raw); hold on;
plot(t_trial, ir_dc, LineWidth=1.2);
drawPhaseBreathHold(phases);
grid on;
xlabel("Time (s)");
title("IR: raw & dc & ac");
legend("ir\_raw","ir\_dc", "Location", "best");

subplot(2,1,2);
plot(t_trial, ir_ac);
drawPhaseBreathHold(phases);
grid on;
xlabel("Time (s)");
legend("ir\_ac (bandpass : 0.7 - 4)");
linkaxes(findall(gcf,'Type','axes'),'x');



%% ===== 5) Sliding RMS 기반 AC 계산 =====
AC_red_rms = nan(size(red_ac_bp));
AC_ir_rms  = nan(size(ir_ac_bp));

for i = W:length(red_ac_bp)
    seg_red = red_ac_bp(i-W+1:i);
    seg_ir  = ir_ac_bp(i-W+1:i);

    AC_red_rms(i) = sqrt(mean(seg_red.^2, 'omitnan'));
    AC_ir_rms(i)  = sqrt(mean(seg_ir.^2,  'omitnan'));
end

DC_red = movmean(red_dc, W, 'omitnan');
DC_ir  = movmean(ir_dc,  W, 'omitnan');

ratio_red = AC_red_rms ./ DC_red;
ratio_ir  = AC_ir_rms  ./ DC_ir;

R = ratio_red ./ ratio_ir;

R(~isfinite(R)) = NaN;
R(R <= 0) = NaN;

R(R < 0.2 | R > 2.6) = NaN;

R_s = movmean(R, round(Fs*2), 'omitnan');   % 2초 smoothing


SpO2_est = 110 - 25 * R_s;

SpO2_est(SpO2_est > 100) = 100;
SpO2_est(SpO2_est < 0) = 0;


figure;
plot(t_trial, SpO2_est, 'LineWidth', 1.2);
xlabel('Time (s)');
ylabel('SpO2 (%)');
title('SpO2');
drawPhaseBreathHold(phases);
ylim([80 100]);  
grid on;

%% arduino / matlab spo2 비교용
figure;
plot(t_trial, spo2, 'LineWidth', 1.2); hold on;
plot(t_trial, SpO2_est, 'LineWidth', 1.2); grid on;
drawPhaseBreathHold(phases);
legend('arduino', 'matlab', 'Location', 'best');
xlabel('Time (s)');
ylabel('SpO_2 (%)');
title('spo2 비교용');
ylim([0 100]);

%% ===== 8) Plot 4: OD_red, OD_ir =====
OD_red_dc = red_dc ./ DC_red0;
OD_ir_dc = ir_dc ./ DC_ir0;

OD_red_dc = -log10(OD_red_dc);
OD_ir_dc = -log10(OD_ir_dc);

figure;
plot(t_trial, OD_red_dc); hold on;
plot(t_trial, OD_ir_dc);
drawPhaseBreathHold(phases);
grid on;
xlabel("Time (s)");
ylabel("Optical Density (relative)");
title("OD: red & ir");
legend("OD\_red","OD\_ir", "Location", "best");

%% ===== 9) MBLL: OD -> ΔHbO2, ΔHHb (relative) =====

ln10 = log(10);

dA_660 = -log10(red_dc ./ DC_red0);
dA_880 = -log10(ir_dc  ./ DC_ir0);

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
plot(t_trial, dHbO2, "r", LineWidth = 1.2); hold on;
plot(t_trial, dHHb, "b", LineWidth = 1.2); hold on;
plot(t_trial, dHbT, 'Color', [0.85 0.65 0.1], LineWidth = 1.2);
drawPhaseBreathHold(phases);
grid on;
xlabel("Time (s)");
title("HbO_2, HHb, tHb [DC]");
legend("HbO_2","HHb","tHb", "Location", "best");


%%
% reference baseline values
StO2_0 = 0.70;   % assumed baseline tissue saturation
tHb_0  = 5e-5;    % arbitrary reference total Hb scale
HbO2_0 = StO2_0*tHb_0;

sto2_ref = (HbO2_0 + dHbO2) ./ (tHb_0 + dHbT);
sto2_ref = sto2_ref*100;

figure;
plot(t_trial, sto2_ref, 'LineWidth', 1.2);
grid on;
title('SO2')
xlabel('Time (s)');
ylabel('Approx. StO2 (%)');
drawPhaseBreathHold(phases);

%% spo2, sto2 plot
figure;
plot(t_trial, SpO2_est, 'LineWidth', 1.2); hold on;
plot(t_trial, sto2_ref, 'LineWidth', 1.2);
drawPhaseBreathHold(phases);
grid on; legend('SpO_2', 'StO_2', 'Location', 'best');
ylim([0 100]);
title('SpO_2 & StO_2');

%% ===== 11) Oxygenation index (HbDiff) =====
HbDiff = dHbO2 - dHHb;

figure;
plot(t_trial, HbDiff);
drawPhaseBreathHold(phases); grid on;
xlabel("Time (s)");
title("HbDiff = HbO2 - HHb");

%% ===== 12) TOI-like normalized index =====
thr = 0.05 * max(abs(dHbT));     % threshold (조절 가능)
validT = abs(dHbT) > thr;

TOI_rel = nan(size(dHbT));
TOI_rel(validT) = 50 + 50 * (HbDiff(validT) ./ dHbT(validT));

figure;
plot(t_trial, TOI_rel, LineWidth = 1.2);
drawPhaseBreathHold(phases); grid on;
xlabel("Time (s)");
ylabel("Index (%)");
title("TOI-like index (relative, masked)");


%% Perfusion Index
ac_rms = sqrt(movmean(ir_ac.^2, W));

dc_mean = movmean(ir_dc, W);

% PI (%)
PI = 100 * (ac_rms ./ dc_mean);

figure;
plot(t_trial, PI);
drawPhaseBreathHold(phases);
grid on;
xlabel("Time (s)");
ylabel("PI (%)");
title("Perfusion Index (IR) - AC(rms) / DC(mean)");

%%
ac_rms = sqrt(movmean(red_ac.^2, W));

dc_mean = movmean(red_dc, W);

% PI (%)
PI = 100 * (ac_rms ./ dc_mean);

figure;
plot(t_trial, PI);
drawPhaseBreathHold(phases);
grid on;
xlabel("Time (s)");
ylabel("PI (%)");
title("Perfusion Index (RED) - AC(rms) / DC(mean)");

%% AC 기준 HHb, HbO2, tHb
% 1) mask 적용해서 안정화 구간만 사용
DA_660 = -(red_ac ./ max(red_dc, 1));
DA_880 = -(ir_ac  ./ max(ir_dc,  1));

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
plot(t_trial, DHbO2, "r"); hold on;
plot(t_trial, DHHb, "b");
drawPhaseBreathHold(phases);
grid on;
xlabel("Time (s)");
title("HbO_2, HHb [AC]");
legend("HbO_2", "HHb", "Location", "best");

subplot(2,1,2);
plot(t_trial, DtHb, 'Color', [0.85 0.65 0.1]);
drawPhaseBreathHold(phases);
grid on;
xlabel("Time (s)");
title("tHb [AC]");
legend("tHb", "Location", "best");
linkaxes(findall(gcf,'Type','axes'),'x');

%% 3개 동시 plot
figure;
plot(t_trial, DHbO2, "r"); hold on;
plot(t_trial, DHHb, "b"); hold on;
plot(t_trial, DtHb, 'Color', [0.85 0.65 0.1]);
drawPhaseBreathHold(phases);
grid on;
xlabel("Time (s)");
title("HbO_2, HHb, tHb [AC]");
legend("HbO_2", "HHb", "tHb", "Location", "best");



%% FFT [AC]
% ---- NaN/Inf 제거 ----
x = DtHb;
valid1 = isfinite(x) & isfinite(t_trial);
x = x(valid1);
t_use1 = t_trial(valid1);

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


%% 노이즈 확인용 plot
figure; 
subplot(2,2,1); plot(t_trial, ir_dc); grid on; title("IR DC (masked)");
subplot(2,2,3); plot(t_trial, ir_ac); grid on; title("IR AC (masked)");
subplot(2,2,2); plot(t_trial, red_dc); grid on; title("RED DC (masked)");
subplot(2,2,4); plot(t_trial, red_ac); grid on; title("RED AC (masked)");


%% 변화량 plot
ymin = min([dHbO2(:); DHbO2(:); dHHb(:); DHHb(:); dHbT(:); DtHb(:)]);
ymax = max([dHbO2(:); DHbO2(:); dHHb(:); DHHb(:); dHbT(:); DtHb(:)]);

figure;
plot(t_trial, dHbO2, "LineWidth",  1.2); hold on; plot(t_trial, DHbO2); 
drawPhaseBreathHold(phases);
title("HbO_2  [DC/AC]"); legend("HbO_2 [DC]", "HbO_2 [AC]", "Location", "best");
ylim([ymin ymax]);
grid on;

figure;
plot(t_trial, dHHb, "LineWidth", 1.2); hold on; plot(t_trial, DHHb); 
drawPhaseBreathHold(phases);
title("HHb [DC/AC]"); legend("HHb [DC] ", "HHb [AC]", "Location", "best");
ylim([ymin ymax]);
grid on;

figure;
plot(t_trial, dHbT, "LineWidth", 1.2); hold on; plot(t_trial, DtHb); 
drawPhaseBreathHold(phases);
title("tHb  [DC/AC]"); legend("tHb [DC] ", "tHb [AC]", "Location", "best");
ylim([ymin ymax]);
grid on;

%% MBLL (AC, DC 분리 X)
da_660 = -log(red_raw / RAW_red0);
da_880 = -log(ir_raw  / RAW_ir0);

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
plot(t_trial, dHBO2, "r", LineWidth = 1.2); hold on;
plot(t_trial, dHHB, "b", LineWidth = 1.2); hold on;
plot(t_trial, dTHB, 'Color', [0.85 0.65 0.1], LineWidth = 1.2);
drawPhaseBreathHold(phases);
grid on;
xlabel("Time (s)");
title("HbO_2, HHb, tHb [AC + DC]");
legend("HbO_2","HHb","tHb", "Location", "best");

%% 아날로그 노이즈 관련 확인용 plot
% t1 = 240;
% win = 20;
% seg = (t >= (t1-win)) & (t <= (t1+win));
% 
% TT = t(seg);
% red_raw_s = red_raw(seg);
% ir_raw_s = ir_raw(seg);
% red_dc_s = red_dc(seg);
% ir_dc_s = ir_dc(seg);
% red_ac_s = red_ac(seg);
% ir_ac_s = ir_ac(seg);
% 
% bp = [0.7 4.0];
% red_ac_bp1 = bandpass(red_ac_s, bp, Fs);
% ir_ac_bp1 = bandpass(ir_ac_s, bp, Fs);
% 
% figure;
% subplot(3,1,1);
% plot(TT, red_raw_s); hold on;
% plot(TT, ir_raw_s);
% grid on;
% title(sprintf("RAW around %.1fs (\\pm %ds)", t1, win));
% legend("red\_raw", "ir\_raw", "Location", "best");
% 
% subplot(3,1,2);
% plot(TT, red_dc_s); hold on;
% plot(TT, ir_dc_s); 
% grid on;
% title("DC around target window");
% legend("red\_dc", "ir\_dc", "Location", "best");
% 
% subplot(3,1,3);
% plot(TT, red_ac_bp1); hold on;
% plot(TT, ir_ac_bp1); 
% grid on;
% title(sprintf("AC bandpass %.1f - %.1f Hz", bp(1), bp(2)));
% legend("red\_ac\_bp", "ir\_ac\_bp", "Location", "best");
