%% plot_ppg_csv.m
clear; clc; close all;

%% ===== 0) 파일 지정 =====
fname = "data_20260506.csv"; 

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


cycles = parsePhaseCycles(t, phase, trial_id);
cycle = parsePhase(t_trial, phase);

% ---- Prahl extinction coefficients (1/(M·cm)) ----
eps_HHb_660  = 3226.56;
eps_HbO2_660 = 319.6;
eps_HHb_880  = 726.44;
eps_HbO2_880 = 1154;

%% ===== 4.5) Fs 자동 추정 =====
dt = diff(t);
Fs = 1/median(dt);                  
fprintf("Fs ~= %.2f Hz\n", Fs);
disp([min(dt) median(dt) max(dt)]);  


winSec = 5.0;          % 5초 윈도우
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


%% ===== Peak-based AC amplitude =====

% 최소 peak 간격: 심박 기준
minPeakDist = round(0.4 * Fs);   % 0.4초 = 최대 약 150 BPM
minProm_IR  = std(ir_ac_bp, 'omitnan') * 0.3;
minProm_RED = std(red_ac_bp, 'omitnan') * 0.3;

% IR peak / trough detection
[pk_ir, loc_pk_ir] = findpeaks(ir_ac_bp, ...
    'MinPeakDistance', minPeakDist, ...
    'MinPeakProminence', minProm_IR);

[tr_ir_neg, loc_tr_ir] = findpeaks(-ir_ac_bp, ...
    'MinPeakDistance', minPeakDist, ...
    'MinPeakProminence', minProm_IR);

tr_ir = -tr_ir_neg;

% RED peak / trough detection
[pk_red, loc_pk_red] = findpeaks(red_ac_bp, ...
    'MinPeakDistance', minPeakDist, ...
    'MinPeakProminence', minProm_RED);

[tr_red_neg, loc_tr_red] = findpeaks(-red_ac_bp, ...
    'MinPeakDistance', minPeakDist, ...
    'MinPeakProminence', minProm_RED);

tr_red = -tr_red_neg;

% ===== IR pulse amplitude =====
AC_IR_pulse = nan(size(pk_ir));
t_IR_pulse  = nan(size(pk_ir));

for k = 1:length(loc_pk_ir)
    prev_tr_idx = find(loc_tr_ir < loc_pk_ir(k), 1, 'last');

    if isempty(prev_tr_idx)
        continue;
    end

    AC_IR_pulse(k) = pk_ir(k) - tr_ir(prev_tr_idx);
    t_IR_pulse(k)  = t(loc_pk_ir(k));
end

% ===== RED pulse amplitude =====
AC_RED_pulse = nan(size(pk_red));
t_RED_pulse  = nan(size(pk_red));

for k = 1:length(loc_pk_red)
    prev_tr_idx = find(loc_tr_red < loc_pk_red(k), 1, 'last');

    if isempty(prev_tr_idx)
        continue;
    end

    AC_RED_pulse(k) = pk_red(k) - tr_red(prev_tr_idx);
    t_RED_pulse(k)  = t(loc_pk_red(k));
end

% NaN 제거 후 interpolation

valid_ir = isfinite(t_IR_pulse) & isfinite(AC_IR_pulse);
valid_red = isfinite(t_RED_pulse) & isfinite(AC_RED_pulse);

AC_IR_amp = interp1(t_IR_pulse(valid_ir), ...
                    AC_IR_pulse(valid_ir), ...
                    t, 'linear', NaN);

AC_RED_amp = interp1(t_RED_pulse(valid_red), ...
                     AC_RED_pulse(valid_red), ...
                     t, 'linear', NaN);

% DC
DC_IR  = movmean(ir_dc, W, 'omitnan');
DC_RED = movmean(red_dc, W, 'omitnan');

% PI
PI_IR  = 100 * (AC_IR_amp  ./ DC_IR);
PI_RED = 100 * (AC_RED_amp ./ DC_RED);


%% ===== 8) Plot 4: OD_red, OD_ir =====
OD_red_dc = red_dc ./ DC_red0;
OD_ir_dc = ir_dc ./ DC_ir0;

OD_red_dc = -log10(OD_red_dc);
OD_ir_dc = -log10(OD_ir_dc);

%% ===== 9) MBLL: OD -> ΔHbO2, ΔHHb (relative) [DC] =====
ln10 = log(10);

dA_660 = -log10(red_dc(mask) ./ DC_red0);
dA_880 = -log10(ir_dc(mask)  ./ DC_ir0);

bad = ~isfinite(dA_660) | ~isfinite(dA_880);
dA_660(bad) = NaN;
dA_880(bad) = NaN;

dA_660 = fillmissing(dA_660, "linear", "EndValues","nearest");
dA_880 = fillmissing(dA_880, "linear", "EndValues","nearest");


% d*DPF -> 1
k = 1.0;

% ε 행렬 (HHb 먼저, HbO2 다음!)
E = [eps_HHb_660,  eps_HbO2_660;
     eps_HHb_880,  eps_HbO2_880];


invE = inv(E);

X = invE * [dA_660.'; dA_880.'] / k;   % 2 x N

dHHb  = X(1,:).';
dHbO2 = X(2,:).';
dHbT  = dHbO2 + dHHb;

%% MBLL (AC : RMS 기준)
% % 1) mask 적용해서 안정화 구간만 사용
% % DA_660 = -log((red_ac(mask) ./ max(red_dc(mask), 1)));
% % DA_880 = -log((ir_ac(mask)  ./ max(ir_dc(mask),  1)));
% 
% ac_rms_red = sqrt(movmean(red_ac.^2, W));
% ac_rms_ir  = sqrt(movmean(ir_ac.^2,  W));
% 
% DA_660 = -log(ac_rms_red(mask) ./ max(red_dc(mask), 1));
% DA_880 = -log(ac_rms_ir(mask)  ./ max(ir_dc(mask),  1));
% 
% 
% bad = ~isfinite(DA_660) | ~isfinite(DA_880);
% DA_660(bad) = NaN;
% DA_880(bad) = NaN;
% DA_660 = fillmissing(DA_660, "linear", "EndValues","nearest");
% DA_880 = fillmissing(DA_880, "linear", "EndValues","nearest");
% 
% 
% DA_660 = medfilt1(DA_660, 5);
% DA_880 = medfilt1(DA_880, 5);
% 
% 
% Y = (E \ [DA_660.'; DA_880.']).';   % [HHb, HbO2]
% 
% DHHb  = Y(:,1);
% DHbO2 = Y(:,2);
% DtHb  = DHbO2 + DHHb;

%% MBLL (AC : amplitude 기준)
amp0_IR = mean(AC_IR_amp(t0_idx), 'omitnan');
amp0_RED = mean(AC_RED_amp(t0_idx), 'omitnan');

% DA_660, DA_880 식 검토 필요 <--------
% DA_660 = -log(AC_RED_amp(mask) ./ amp0_RED);
% DA_880 = -log(AC_IR_amp(mask) ./ amp0_IR);
DA_660 = AC_RED_amp(mask) ./ amp0_RED;
DA_880 = AC_IR_amp(mask) ./ amp0_IR;

bad = ~isfinite(DA_660) | ~isfinite(DA_880);
DA_660(bad) = NaN;
DA_880(bad) = NaN;
DA_660 = fillmissing(DA_660, "linear", "EndValues","nearest");
DA_880 = fillmissing(DA_880, "linear", "EndValues","nearest");


DA_660 = medfilt1(DA_660, 5);
DA_880 = medfilt1(DA_880, 5);


Y = (E \ [DA_660.'; DA_880.']).';   % [HHb, HbO2]

DHHb  = Y(:,1);
DHbO2 = Y(:,2);
DtHb  = DHbO2 + DHHb;


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


%%
% reference baseline values
StO2_0 = 0.70;   % assumed baseline tissue saturation
tHb_0  = 5e-5;    % arbitrary reference total Hb scale
HbO2_0 = StO2_0*tHb_0;

sto2_ref = (HbO2_0 + dHbO2) ./ (tHb_0 + dHbT);
sto2_ref = sto2_ref*100;

%% ===== 5) Plot 1: RED(raw, dc, ac) =====
figure;

subplot(2,1,1);
plot(tt, red_raw(mask)); hold on;
plot(tt, red_dc(mask), Linewidth = 1.2);
drawPhaseCycles(cycles);
grid on;
xlabel("Time (s)");
title("RED: raw & dc & ac");
legend("red\_raw","red\_dc", "Location", "best");

subplot(2,1,2);
plot(tt, red_ac_bp(mask));
drawPhaseCycles(cycles);
grid on;
xlabel("Time (s)");
legend("red\_ac (bandpass : 0.7 - 4)");
linkaxes(findall(gcf,'Type','axes'),'x');


%% ===== 6) Plot 2: IR(raw, dc, ac) =====
figure;

subplot(2,1,1);
plot(tt, ir_raw(mask)); hold on;
plot(tt, ir_dc(mask), LineWidth=1.2);
drawPhaseCycles(cycles);
grid on;
xlabel("Time (s)");
title("IR: raw & dc & ac");
legend("ir\_raw","ir\_dc", "Location", "best");

subplot(2,1,2);
plot(tt, ir_ac(mask));
drawPhaseCycles(cycles);
grid on;
xlabel("Time (s)");
legend("ir\_ac (bandpass : 0.7 - 4)");
linkaxes(findall(gcf,'Type','axes'),'x');

%% red_ac FFT
x = red_ac;
valid = isfinite(x) & isfinite(tt);
t_use = tt(valid);

[t_use, ia] = unique(t_use, 'stable');
x = x(ia);

Fs = 1/mean(diff(t_use));
tu = (t_use(1):1/Fs:t_use(end)).';
xu = interp1(t_use, x, tu, 'linear', 'extrap');

xu = xu - mean(xu);

N = numel(xu);
ac_fft = fft(xu);
half = floor(N/2);
f = (0:half-1)*Fs / N;
mag = abs(ac_fft(1:half)) / N;

band = (f>=0.7) & (f<=4);

figure;
plot(f(band), mag(band));
%plot(f, mag);
grid on;
xlabel("frequency(Hz)"); ylabel("Magnitude [dB]");
title("red\_ac FFT");



%% 
trials = unique(trial_id);
t_common = linspace(min(t_trial), max(t_trial), 1000);

%% red
red_raw_mat = nan(length(t_common), length(trials));
red_dc_mat = nan(length(t_common), length(trials));

for i = 1:length(trials)
    tr = trials(i);
    tr_mask = (trial_id == tr);

    t_tr = t_trial(tr_mask);
    red_raw_tr = red_raw(tr_mask);
    red_dc_tr = red_dc(tr_mask);

    red_raw_mat(:, i) = interp1(t_tr, red_raw_tr, t_common, 'linear', NaN);
    red_dc_mat(:, i) = interp1(t_tr, red_dc_tr, t_common, 'linear', NaN);
end

red_raw_mean = mean(red_raw_mat, 2, 'omitnan');
red_dc_mean = mean(red_dc_mat, 2, 'omitnan');

red_raw_std = std(red_raw_mat, 0, 2, 'omitnan');
red_dc_std = std(red_dc_mat, 0, 2, 'omitnan');

figure; hold on;

fill([t_common fliplr(t_common)], ...
    [red_raw_mean'+red_raw_std' fliplr(red_raw_mean'-red_raw_std')], ...
    [0.8 0.8 1], 'EdgeColor', 'none');

fill([t_common fliplr(t_common)], ...
    [red_dc_mean'+red_dc_std' fliplr(red_dc_mean'-red_dc_std')], ...
    [1 0.8 0.8], 'EdgeColor', 'none');

plot(t_common, red_raw_mean, 'b', 'LineWidth', 2);
plot(t_common, red_dc_mean, 'r', 'LineWidth', 2);

drawPhase(cycle);

grid on; xlabel("Time (s)"); legend("red(raw)", "red(dc)");


%% ir 
ir_raw_mat = nan(length(t_common), length(trials));
ir_dc_mat = nan(length(t_common), length(trials));

for i = 1:length(trials)
    tr = trials(i);
    tr_mask = (trial_id == tr);

    t_tr = t_trial(tr_mask);
    ir_raw_tr = ir_raw(tr_mask);
    ir_dc_tr = ir_dc(tr_mask);

    ir_raw_mat(:, i) = interp1(t_tr, ir_raw_tr, t_common, 'linear', NaN);
    ir_dc_mat(:, i) = interp1(t_tr, ir_dc_tr, t_common, 'linear', NaN);
end

ir_raw_mean = mean(ir_raw_mat, 2, 'omitnan');
ir_dc_mean = mean(ir_dc_mat, 2, 'omitnan');

ir_raw_std = std(ir_raw_mat, 0, 2, 'omitnan');
ir_dc_std = std(ir_dc_mat, 0, 2, 'omitnan');

figure; hold on;

fill([t_common fliplr(t_common)], ...
    [ir_raw_mean'+ir_raw_std' fliplr(ir_raw_mean'-ir_raw_std')], ...
    [0.8 0.8 1], 'EdgeColor', 'none');

fill([t_common fliplr(t_common)], ...
    [ir_dc_mean'+ir_dc_std' fliplr(ir_dc_mean'-ir_dc_std')], ...
    [1 0.8 0.8], 'EdgeColor', 'none');

plot(t_common, ir_raw_mean, 'b', 'LineWidth', 2);
plot(t_common, ir_dc_mean, 'r', 'LineWidth', 2);

drawPhase(cycle);

grid on; xlabel("Time (s)"); legend("ir(raw)", "ir(dc)");


%% spo2
spo2_mat = nan(length(t_common), length(trials));
sto2_mat = nan(length(t_common), length(trials));

for i = 1:length(trials)
    tr = trials(i);
    tr_mask = (trial_id == tr);

    t_tr = t_trial(tr_mask);
    spo2_tr = SpO2_est(tr_mask);
    sto2_tr = sto2_ref(tr_mask);

    spo2_mat(:, i) = interp1(t_tr, spo2_tr, t_common, 'linear', NaN);
    sto2_mat(:, i) = interp1(t_tr, sto2_tr, t_common, 'linear', NaN);
end

spo2_mean = mean(spo2_mat, 2, 'omitnan');
spo2_std = std(spo2_mat, 0, 2, 'omitnan');

sto2_mean = mean(sto2_mat, 2, 'omitnan');
sto2_std = std(sto2_mat, 0, 2, 'omitnan');


figure; hold on;

fill([t_common fliplr(t_common)], ...
    [spo2_mean'+spo2_std' fliplr(spo2_mean'-spo2_std')], ...
    [0.8 0.8 1], 'EdgeColor', 'none');

fill([t_common fliplr(t_common)], ...
    [sto2_mean'+sto2_std' fliplr(sto2_mean'-sto2_std')], ...
    [1 0.8 0.8], 'EdgeColor', 'none');

plot(t_common, spo2_mean, 'b', 'LineWidth', 2);
plot(t_common, sto2_mean, 'r', 'LineWidth', 2);

% xlim([0 210])
% 
% set(gca, 'Position', [0 0 1 1])
% set(gcf, 'Units', 'centimeters')
% set(gcf, 'Position', [5 5 9.52 5])


drawPhase(cycle);
grid on;
xlabel("Time (s)"); ylabel("spo2 & sto2"); ylim([0 100]); title("spo2 & sto2"); 
legend("SpO2", "StO2");

%% PI (IR)
PI_mat_ir = nan(length(t_common), length(trials));

for i = 1:length(trials)
    tr = trials(i);

    tr_mask = (trial_id == tr);

    t_tr = t_trial(tr_mask);
    PI_IR_tr = PI_IR(tr_mask);

    % NaN 제거
    % valid = isfinite(t_tr) & isfinite(PI_tr);
    % t_tr = t_tr(valid);
    % PI_tr = PI_tr(valid);

    PI_mat_ir(:, i) = interp1(t_tr, PI_IR_tr, t_common, 'linear', NaN);
end

PI_IR_mean = mean(PI_mat_ir, 2, 'omitnan');
PI_IR_std  = std(PI_mat_ir, 0, 2, 'omitnan');


figure; hold on;

fill([t_common fliplr(t_common)], ...
     [PI_IR_mean'+PI_IR_std' fliplr(PI_IR_mean'-PI_IR_std')], ...
     [0.8 0.8 1], 'EdgeColor', 'none');
plot(t_common, PI_IR_mean, 'b', 'LineWidth', 2);

% xlim([0 210])
% 
% set(gca, 'Position', [0 0 1 1])
% set(gcf, 'Units', 'centimeters')
% set(gcf, 'Position', [5 5 9.52 4.73])

drawPhase(cycle);

grid on; xlabel("Time (s)"); ylabel("PI");
title("PI (IR)");

%% PI (RED)
PI_mat_red = nan(length(t_common), length(trials));

for i = 1:length(trials)
    tr = trials(i);

    tr_mask = (trial_id == tr);

    t_tr = t_trial(tr_mask);
    PI_RED_tr = PI_RED(tr_mask);

    % NaN 제거
    % valid = isfinite(t_tr) & isfinite(PI_tr);
    % t_tr = t_tr(valid);
    % PI_tr = PI_tr(valid);

    PI_mat_red(:, i) = interp1(t_tr, PI_RED_tr, t_common, 'linear', NaN);
end

PI_RED_mean = mean(PI_mat_red, 2, 'omitnan');
PI_RED_std  = std(PI_mat_red, 0, 2, 'omitnan');


figure; hold on;

fill([t_common fliplr(t_common)], ...
     [PI_RED_mean'+PI_RED_std' fliplr(PI_RED_mean'-PI_RED_std')], ...
     [0.8 0.8 1], 'EdgeColor', 'none');
plot(t_common, PI_RED_mean, 'b', 'LineWidth', 2);

drawPhase(cycle);
grid on; 
xlabel("Time (s)"); ylabel("PI"); title("PI (RED)");

%% OD
OD_red_mat = nan(length(t_common), length(trials));
OD_ir_mat =nan(length(t_common), length(trials));

for i = 1:length(trials)
    tr = trials(i);

    tr_mask = (trial_id == tr);

    t_tr = t_trial(tr_mask);
    OD_red_tr = OD_red_dc(tr_mask);
    OD_ir_tr = OD_ir_dc(tr_mask);

    OD_red_mat(:, i) = interp1(t_tr, OD_red_tr, t_common, 'linear', NaN);
    OD_ir_mat(:, i) = interp1(t_tr, OD_ir_tr, t_common, 'linear', NaN);
end

OD_red_mean = mean(OD_red_mat, 2, 'omitnan');
OD_red_std  = std(OD_red_mat, 0, 2, 'omitnan');

OD_ir_mean = mean(OD_ir_mat, 2, 'omitnan');
OD_ir_std = std(OD_ir_mat, 0, 2, 'omitnan');


figure; hold on;

fill([t_common fliplr(t_common)], ...
     [OD_red_mean'+OD_red_std' fliplr(OD_red_mean'-OD_red_std')], ...
     [0.8 0.8 1], 'EdgeColor', 'none');

fill([t_common fliplr(t_common)], ...
     [OD_ir_mean'+OD_ir_std' fliplr(OD_ir_mean'-OD_ir_std')], ...
     [1 0.8 0.8], 'EdgeColor', 'none');

plot(t_common, OD_red_mean, 'b', 'LineWidth', 2);
plot(t_common, OD_ir_mean, 'r', 'LineWidth', 2);

drawPhase(cycle);

grid on; xlabel("Time (s)"); ylabel("otpical density"); title("optical density"); legend("OD(red)", "OD(ir)", "Location", "best");


%% HbO2, HHb, tHb [DC]
HHb_dc_mat = nan(length(t_common), length(trials));
HbO2_dc_mat = nan(length(t_common), length(trials));
tHb_dc_mat = nan(length(t_common), length(trials));

for i = 1:length(trials)
    tr = trials(i);

    tr_mask = (trial_id == tr);

    t_tr = t_trial(tr_mask);
    HHb_dc_tr = dHHb(tr_mask);
    HbO2_dc_tr = dHbO2(tr_mask);
    tHb_dc_tr = dHbT(tr_mask);

    HHb_dc_mat(:, i) = interp1(t_tr, HHb_dc_tr, t_common, 'linear', NaN);
    HbO2_dc_mat(:, i) = interp1(t_tr, HbO2_dc_tr, t_common, 'linear', NaN);
    tHb_dc_mat(:, i) = interp1(t_tr, tHb_dc_tr, t_common, 'linear', NaN);
end

HHb_dc_mean = mean(HHb_dc_mat, 2, 'omitnan');
HbO2_dc_mean = mean(HbO2_dc_mat, 2, 'omitnan');
tHb_dc_mean = mean(tHb_dc_mat, 2, 'omitnan');

HHb_dc_std = std(HHb_dc_mat, 0, 2, 'omitnan');
HbO2_dc_std = std(HbO2_dc_mat, 0, 2, 'omitnan');
tHb_dc_std = std(tHb_dc_mat, 0, 2, 'omitnan');


figure; hold on;

fill([t_common fliplr(t_common)], ...
     [HHb_dc_mean'+HHb_dc_std' fliplr(HHb_dc_mean'-HHb_dc_std')], ...
     [0.5 0.5 1], 'EdgeColor', 'none');

fill([t_common fliplr(t_common)], ...
     [HbO2_dc_mean'+HbO2_dc_std' fliplr(HbO2_dc_mean'-HbO2_dc_std')], ...
     [1 0.5 0.5], 'EdgeColor', 'none');


fill([t_common fliplr(t_common)], ...
     [tHb_dc_mean'+tHb_dc_std' fliplr(tHb_dc_mean'-tHb_dc_std')], ...
     [1 1 0], 'EdgeColor', 'none', 'FaceAlpha', 0.3);

plot(t_common, HHb_dc_mean, 'b', 'LineWidth', 2);
plot(t_common, HbO2_dc_mean, 'r', 'LineWidth', 2);
plot(t_common, tHb_dc_mean, 'Color', [1 0.8 0], 'LineWidth', 2);

% xlim([0 210])
% 
% set(gca, 'Position', [0 0 1 1])
% set(gcf, 'Units', 'centimeters')
% set(gcf, 'Position', [5 5 9.52 4.5])

drawPhase(cycle);
grid on; 
xlabel("Time (s)"); title("HbO2, HHb, tHb [DC]");
legend("HHb", "HbO2", "tHb", "Location", "best"); 

%% HbO2, HHb, tHb [AC]
HHb_ac_mat = nan(length(t_common), length(trials));
HbO2_ac_mat = nan(length(t_common), length(trials));
tHb_ac_mat = nan(length(t_common), length(trials));

for i = 1:length(trials)
    tr = trials(i);

    tr_mask = (trial_id == tr);

    t_tr = t_trial(tr_mask);
    HHb_ac_tr = DHHb(tr_mask);
    HbO2_ac_tr = DHbO2(tr_mask);
    tHb_ac_tr = DtHb(tr_mask);

    HHb_ac_mat(:, i) = interp1(t_tr, HHb_ac_tr, t_common, 'linear', NaN);
    HbO2_ac_mat(:, i) = interp1(t_tr, HbO2_ac_tr, t_common, 'linear', NaN);
    tHb_ac_mat(:, i) = interp1(t_tr, tHb_ac_tr, t_common, 'linear', NaN);
end

HHb_ac_mean = mean(HHb_ac_mat, 2, 'omitnan');
HbO2_ac_mean = mean(HbO2_ac_mat, 2, 'omitnan');
tHb_ac_mean = mean(tHb_ac_mat, 2, 'omitnan');

HHb_ac_std = std(HHb_ac_mat, 0, 2, 'omitnan');
HbO2_ac_std = std(HbO2_ac_mat, 0, 2, 'omitnan');
tHb_ac_std = std(tHb_ac_mat, 0, 2, 'omitnan');


figure; hold on;


fill([t_common fliplr(t_common)], ...
     [HHb_ac_mean'+HHb_ac_std' fliplr(HHb_ac_mean'-HHb_ac_std')], ...
     [0.5 0.5 1], 'EdgeColor', 'none');

fill([t_common fliplr(t_common)], ...
     [HbO2_ac_mean'+HbO2_ac_std' fliplr(HbO2_ac_mean'-HbO2_ac_std')], ...
     [1 0.5 0.5], 'EdgeColor', 'none');


fill([t_common fliplr(t_common)], ...
     [tHb_ac_mean'+tHb_ac_std' fliplr(tHb_ac_mean'-tHb_ac_std')], ...
     [1 1 0], 'EdgeColor', 'none', 'FaceAlpha', 0.3);

plot(t_common, HHb_ac_mean, 'b', 'LineWidth', 2);
plot(t_common, HbO2_ac_mean, 'r', 'LineWidth', 2);
plot(t_common, tHb_ac_mean, 'Color', [1 0.8 0], 'LineWidth', 2);

% xlim([0 210])
% 
% set(gca, 'Position', [0 0 1 1])
% set(gcf, 'Units', 'centimeters')
% set(gcf, 'Position', [5 5 9.52 5])

drawPhase(cycle);
grid on; 
xlabel("Time (s)"); title("HbO2, HHb, tHb [AC]"); 
legend("HHb", "HbO2", "tHb", "Location", "best");  


%% HbO2, HHb, tHb [AC+DC]
HHb_r_mat = nan(length(t_common), length(trials));
HbO2_r_mat = nan(length(t_common), length(trials));
tHb_r_mat = nan(length(t_common), length(trials));

for i = 1:length(trials)
    tr = trials(i);

    tr_mask = (trial_id == tr);

    t_tr = t_trial(tr_mask);
    HHb_r_tr = dHHB(tr_mask);
    HbO2_r_tr = dHBO2(tr_mask);
    tHb_r_tr = dTHB(tr_mask);

    HHb_r_mat(:, i) = interp1(t_tr, HHb_r_tr, t_common, 'linear', NaN);
    HbO2_r_mat(:, i) = interp1(t_tr, HbO2_r_tr, t_common, 'linear', NaN);
    tHb_r_mat(:, i) = interp1(t_tr, tHb_r_tr, t_common, 'linear', NaN);
end

HHb_r_mean = mean(HHb_r_mat, 2, 'omitnan');
HbO2_r_mean = mean(HbO2_r_mat, 2, 'omitnan');
tHb_r_mean = mean(tHb_r_mat, 2, 'omitnan');

HHb_r_std = std(HHb_r_mat, 0, 2, 'omitnan');
HbO2_r_std = std(HbO2_r_mat, 0, 2, 'omitnan');
tHb_r_std = std(tHb_r_mat, 0, 2, 'omitnan');


figure; hold on;

fill([t_common fliplr(t_common)], ...
     [HHb_r_mean'+HHb_r_std' fliplr(HHb_r_mean'-HHb_r_std')], ...
     [0.5 0.5 1], 'EdgeColor', 'none');

fill([t_common fliplr(t_common)], ...
     [HbO2_r_mean'+HbO2_r_std' fliplr(HbO2_r_mean'-HbO2_r_std')], ...
     [1 0.5 0.5], 'EdgeColor', 'none');


fill([t_common fliplr(t_common)], ...
     [tHb_r_mean'+tHb_r_std' fliplr(tHb_r_mean'-tHb_r_std')], ...
     [1 1 0], 'EdgeColor', 'none', 'FaceAlpha', 0.3);

plot(t_common, HHb_r_mean, 'b', 'LineWidth', 2);
plot(t_common, HbO2_r_mean, 'r', 'LineWidth', 2);
plot(t_common, tHb_r_mean, 'Color', [1 0.8 0], 'LineWidth', 2);

% xlim([0 210])
% 
% set(gca, 'Position', [0 0 1 1])
% set(gcf, 'Units', 'centimeters')
% set(gcf, 'Position', [5 5 9.52 4.5])


drawPhase(cycle);
grid on; 
xlabel("Time (s)"); title("HbO2, HHb, tHb [AC+DC]"); legend("HHb", "HbO2", "tHb", "Location", "best"); 