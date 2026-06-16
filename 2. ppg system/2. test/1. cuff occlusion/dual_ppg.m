%% plot_ppg_combined.m
clear; clc; close all;

%% ===== 0) 파일 지정 =====
% fname = "data_20260416_1307.csv";
fname = "data_occlusion_20260601.csv";
T = readtable(fname);

%% ===== 1) 시간축 / 기본 데이터 =====
t1 = T.t1_us / 1000000;
t2 = T.t2_us / 1000000;
t_trial = T.t_trial_ms / 1000;
trial_id = T.trial_id;
phase = T.phase;

t0_idx = (t_trial >= 3.0) & (t_trial < 3.5);
t0_idx2 = (t_trial >= 3.0) & (t_trial < 30);    %

red_raw1 = T.red_raw1;
ir_raw1  = T.ir_raw1;

red_raw2 = T.red_raw2;
ir_raw2 = T.ir_raw2;

% red_dc = T.red_dc;
% ir_dc  = T.ir_dc;
% 
% red_ac = T.red_ac;
% ir_ac  = T.ir_ac;

%% ===== 2) Fs 추정 =====
dt = diff(t);
Fs = 1 / median(dt);
fprintf("Fs ~= %.2f Hz\n", Fs);

%% ===== 3) phase 정보 =====
winSec = 5.0;          % 5초 윈도우
W = round(winSec*Fs);

% MBLL 식에서 안정화 구간만 데이터 뽑을 경우 사용
t0 = 30;                    
mask = t >= t0;
tt = t(mask);

% phase 변화 지점
idx_change = find(diff(phase) ~= 0) + 1;

t_change = t(idx_change);
phase_change = phase(idx_change);

idx_base = (phase == 0);

cycles = parsePhaseCycles(t, phase, trial_id);
cycle = parsePhase(t_trial, phase);

% MBLL 관련
eps_HHb_660  = 3226.56;
eps_HbO2_660 = 319.6;
eps_HHb_880  = 726.44;
eps_HbO2_880 = 1154;

%% ===== 4) Hampel + spike 제거 =====
N = 20; nsigma = 2.5;
red_raw1 = hampel(red_raw1, N, nsigma);
ir_raw1  = hampel(ir_raw1,  N, nsigma);

red_raw2 = hampel(red_raw2, N, nsigma);
ir_raw2 = hampel(ir_raw2, N, nsigma);

alpha_dc = 0.02;

red_dc1 = zeros(size(red_raw1));
ir_dc1  = zeros(size(ir_raw1));
red_dc2 = zeros(size(red_raw2));
ir_dc2 = zeros(size(ir_raw2));

red_dc1(1) = red_raw1(1);
ir_dc1(1)  = ir_raw1(1);
red_dc2(1) = red_raw2(1);
ir_dc2(1) = ir_raw2(1);

for i = 2:length(red_raw1)
    red_dc1(i) = (1-alpha_dc)*red_dc1(i-1) + alpha_dc*red_raw1(i);
    ir_dc1(i)  = (1-alpha_dc)*ir_dc1(i-1)  + alpha_dc*ir_raw1(i);
end

for i = 2:length(red_raw2)
    red_dc2(i) = (1-alpha_dc)*red_dc2(i-1) + alpha_dc*red_raw2(i);
    ir_dc2(i) = (1-alpha_dc)*ir_dc2(i-1) + alpha_dc*ir_raw2(i);
end

red_ac1 = red_raw1 - red_dc1;
ir_ac1  = ir_raw1  - ir_dc1;
red_ac2 = red_raw2 - red_dc2;
ir_ac2 = ir_raw2 - ir_dc2;

winSpike = round(0.8 * Fs);
kSpike = 4;

red_raw1 = removeLocalSpike(red_raw1, winSpike, kSpike);
ir_raw1 = removeLocalSpike(ir_raw1,  winSpike, kSpike);

red_ac1 = removeLocalSpike(red_ac1, winSpike, kSpike);
ir_ac1  = removeLocalSpike(ir_ac1,  winSpike, kSpike);

red_ac1 = fillmissing(red_ac1, 'linear');
ir_ac1  = fillmissing(ir_ac1,  'linear');

red_raw2 = removeLocalSpike(red_raw2, winSpike, kSpike);
ir_raw2 = removeLocalSpike(ir_raw2,  winSpike, kSpike);

red_ac2 = removeLocalSpike(red_ac2, winSpike, kSpike);
ir_ac2  = removeLocalSpike(ir_ac2,  winSpike, kSpike);

red_ac2 = fillmissing(red_ac2, 'linear');
ir_ac2  = fillmissing(ir_ac2,  'linear');

bp_low = 0.7; bp_high = 4;

red_ac1_bp = bandpass(red_ac1, [bp_low bp_high], Fs);
ir_ac1_bp  = bandpass(ir_ac1,  [bp_low bp_high], Fs);

red_ac2_bp = bandpass(red_ac2, [bp_low bp_high], Fs);
ir_ac2_bp = bandpass(ir_ac2, [bp_low bp_high], Fs);

%%
DC1_red0 = mean(red_dc1(t0_idx), 'omitnan');
DC1_ir0  = mean(ir_dc1(t0_idx),  'omitnan');
RAW1_red0 = mean(red_raw1(t0_idx), 'omitnan');
RAW1_ir0 = mean(ir_raw1(t0_idx), 'omitnan');

DC2_red0 = mean(red_dc2(t0_idx), 'omitnan');
DC2_ir0 = mean(ir_dc2(t0_idx), 'omitnan');
RAW2_red0 = mean(red_raw2(t0_idx), 'omitnan');
RAW2_ir0 = mean(ir_raw2(t0_idx), 'omitnan');

%% SpO2_sensor1
W_SpO2 = round(Fs * 5);

AC_red_rms = nan(size(red_ac1_bp));
AC_ir_rms  = nan(size(ir_ac1_bp));

for i = W_SpO2:length(red_ac1_bp)
    seg_red = red_ac_bp(i-W_SpO2+1:i);
    seg_ir  = ir_ac_bp(i-W_SpO2+1:i);

    AC_red_rms(i) = sqrt(mean(seg_red.^2, 'omitnan'));
    AC_ir_rms(i)  = sqrt(mean(seg_ir.^2,  'omitnan'));
end

DC_red_SpO2 = movmean(red_dc, W_SpO2, 'omitnan');
DC_ir_SpO2  = movmean(ir_dc,  W_SpO2, 'omitnan');

ratio_red = AC_red_rms ./ DC_red_SpO2;
ratio_ir  = AC_ir_rms  ./ DC_ir_SpO2;

R = ratio_red ./ ratio_ir;

R(~isfinite(R)) = NaN;
R(R <= 0) = NaN;
R(R < 0.3 | R > 2.0) = NaN;

R_s = movmean(R, round(Fs*5), 'omitnan');

SpO2_est = 110 - 25 * R_s;
SpO2_est(SpO2_est > 100) = 100;
SpO2_est(SpO2_est < 0) = 0;


%% PI 계산_sensor1
W_PI = round(Fs * 5);

% IR PI
ir_max = movmax(ir_ac, W_PI, 'omitnan');
ir_min = movmin(ir_ac, W_PI, 'omitnan');

AC_amp_IR = ir_max - ir_min;
DC_mean_IR = movmean(ir_dc, W_PI, 'omitnan');

PI_IR = 100 * (AC_amp_IR ./ DC_mean_IR);

% RED PI
red_max = movmax(red_ac, W_PI, 'omitnan');
red_min = movmin(red_ac, W_PI, 'omitnan');

AC_amp_RED = red_max - red_min;
DC_mean_RED = movmean(red_dc, W_PI, 'omitnan');

PI_RED = 100 * (AC_amp_RED ./ DC_mean_RED);

%% MBLL (DC)_sensor1
dA_660 = -log10(red_dc ./ DC_red0);
dA_880 = -log10(ir_dc  ./ DC_ir0);

bad = ~isfinite(dA_660) | ~isfinite(dA_880);
dA_660(bad) = NaN;
dA_880(bad) = NaN;

dA_660 = fillmissing(dA_660, "linear", "EndValues", "nearest");
dA_880 = fillmissing(dA_880, "linear", "EndValues", "nearest");

E = [eps_HHb_660,  eps_HbO2_660;
     eps_HHb_880,  eps_HbO2_880];

X = inv(E) * [dA_660.'; dA_880.'];

dHHb  = X(1,:).';
dHbO2 = X(2,:).';
dHbT  = dHbO2 + dHHb;

%% ===== StO2 계산 =====
StO2_0 = 0.70;
tHb_0  = 7e-5;
HbO2_0 = StO2_0 * tHb_0;

StO2_est = (HbO2_0 + dHbO2) ./ (tHb_0 + dHbT);
StO2_est = StO2_est * 100;

StO2_est(~isfinite(StO2_est)) = NaN;
StO2_est = min(max(StO2_est, 0), 100);

%% occlusion 구간 FFT [AC]
bp_low_bpm = bp_low * 60;
bp_high_bpm = bp_high * 60;

occlusion_start = 50;
occlusion_end = 140;

t_trial = t_trial(:);
red_ac_bp = red_ac_bp(:);

mask_t_o = (t_trial >= occlusion_start & t_trial <= occlusion_end);

x = red_ac_bp(mask_t_o);
x = x(isfinite(x));

xu = x - mean(x, 'omitnan');

N = numel(xu);
ac_fft_red = fft(xu);
half = floor(N/2);

f_o = (0:half-1)*Fs / N;

mag_occlusion = abs(ac_fft_red(1:half)) / N;

mag_norm_occlusion = mag_occlusion / max(mag_occlusion);

f_o_ac_bpm = f_o*60;

band_o_ac_bpm = (f_o_ac_bpm <=bp_high_bpm);

figure;
plot(f_o_ac_bpm(band_o_ac_bpm), mag_occlusion(band_o_ac_bpm));
%xlabel("bpm"); ylabel("Magnitude");
title("AC FFT (occlusion)");


%% release 이후 FFT [AC]
release_start = 150;
release_end = 200;

t_trial = t_trial(:);
red_ac_bp = red_ac_bp(:);

mask_t_r = (t_trial >= release_start & t_trial <= release_end);

x = red_ac_bp(mask_t_r);

x = x(isfinite(x));

xu = x - mean(x, 'omitnan');

N = numel(xu);
ac_fft_red = fft(xu);
half = floor(N/2);

f_r = (0:half-1)*Fs / N;
mag_release = abs(ac_fft_red(1:half)) / N;

mag_norm_release = mag_release / max(mag_release);

f_r_ac_bpm = f_r*60;

band_r_ac_bpm = (f_r_ac_bpm <=bp_high_bpm);
% band = (f_r >= bp_low & f_r <= bp_high);

figure;
plot(f_r_ac_bpm(band_r_ac_bpm), mag_release(band_r_ac_bpm));
%xlabel("bpm"); ylabel("Magnitude");
title("AC FFT (release)");


%% occlusion, release 같이 plot [AC]
max_ref = max([mag_occlusion(:); mag_release(:)]);

mag_occlusion_total = mag_occlusion / max_ref;
mag_release_total = mag_release / max_ref;

figure;
plot(f_o_ac_bpm(band_o_ac_bpm), mag_occlusion_total(band_o_ac_bpm), "LineWidth", 1.38); hold on;
plot(f_r_ac_bpm(band_r_ac_bpm), mag_release_total(band_r_ac_bpm), "LineWidth", 1.38);
title("AC FFT (occlusion, release)");
ylabel("Magnitude (normalized)"); 
xlim([30 180]);
% ylim([0 1]);
legend("occlusion", "release");

%% occlusion 이후 FFT [DC]
t_trial = t_trial(:);
red_dc = red_dc(:);

mask_t_o = (t_trial >= occlusion_start & t_trial <= occlusion_end);

y = red_dc(mask_t_o);
y = y(isfinite(y));

yu = y - mean(y, 'omitnan');

N = numel(yu);
dc_fft_red = fft(yu);
half = floor(N/2);

f_o_dc = (0:half-1)*Fs / N;

mag_occlusion = abs(dc_fft_red(1:half)) / N;

mag_norm_occlusion = mag_occlusion / max(mag_occlusion);

f_o_dc_bpm = f_o_dc*60;

band_o_dc_bpm = (f_o_dc_bpm <=bp_low_bpm);

figure;
plot(f_o_dc_bpm(band_o_dc_bpm), mag_occlusion(band_o_dc_bpm));
%xlabel("bpm"); ylabel("Magnitude");
title("DC FFT (occlusion)");

%% release 이후 FFT [DC]
t_trial = t_trial(:);
red_dc = red_dc(:);

mask_t_r = (t_trial >= release_start & t_trial <= release_end);

y = red_dc(mask_t_r);

y = y(isfinite(y));

yu = y - mean(y, 'omitnan');

N = numel(yu);
dc_fft_red = fft(yu);
half = floor(N/2);

f_r_dc = (0:half-1)*Fs / N;
mag_release = abs(dc_fft_red(1:half)) / N;

mag_norm_release = mag_release / max(mag_release);

f_r_dc_bpm = f_r_dc*60;

band_r_dc_bpm = (f_r_dc_bpm <=bp_low_bpm);

figure;
plot(f_r_dc_bpm(band_r_dc_bpm), mag_release(band_r_dc_bpm));
%xlabel("bpm"); ylabel("Magnitude");
title("DC FFT (release)");

%% occlusion, release 같이 plot [DC]
max_ref = max([mag_occlusion(:); mag_release(:)]);

mag_occlusion_total = mag_occlusion / max_ref;
mag_release_total = mag_release / max_ref;

figure;
plot(f_o_dc_bpm(band_o_dc_bpm), mag_occlusion_total(band_o_dc_bpm), "LineWidth", 1.38); hold on;
plot(f_r_dc_bpm(band_r_dc_bpm), mag_release_total(band_r_dc_bpm), "LineWidth", 1.38);
title("DC FFT (occlusion, release)");
ylabel("Magnitude (normalized)"); 
% ylim([0 1]);
legend("occlusion", "release");

%% mean ± std plot
trials = unique(trial_id);
t_common = linspace(min(t_trial), max(t_trial), 1000);


%% SpO2 & StO2
spo2_mat = nan(length(t_common), length(trials));
sto2_mat = nan(length(t_common), length(trials));

for i = 1:length(trials)
    tr = trials(i);
    tr_mask = trial_id == tr;

    t_tr = t_trial(tr_mask);
    spo2_tr = SpO2_est(tr_mask);
    sto2_tr = StO2_est(tr_mask);

    spo2_mat(:, i) = interp1(t_tr, spo2_tr, t_common, 'linear', NaN);
    sto2_mat(:, i) = interp1(t_tr, sto2_tr, t_common, 'linear', NaN);
end

spo2_mean = mean(spo2_mat, 2, 'omitnan');
spo2_std  = std(spo2_mat, 0, 2, 'omitnan');

sto2_mean = mean(sto2_mat, 2, 'omitnan');
sto2_std  = std(sto2_mat, 0, 2, 'omitnan');

figure; hold on;

fill([t_common fliplr(t_common)], ...
    [spo2_mean' + spo2_std' fliplr(spo2_mean' - spo2_std')], ...
    [1 0.8 0.8], 'EdgeColor', 'none');

fill([t_common fliplr(t_common)], ...
    [sto2_mean' + sto2_std' fliplr(sto2_mean' - sto2_std')], ...
    [0.8 1 0.8], 'EdgeColor', 'none');

plot(t_common, spo2_mean, 'r', 'LineWidth', 1.38);
plot(t_common, sto2_mean, 'g', 'LineWidth', 1.38);

% xlim([0 210]);

% drawPhase(cycle);
% grid on;
xlabel("Time (s)");
ylabel("SpO2 / StO2 (%)");
ylim([0 100]);
title("SpO2 & StO2");
% legend("SpO2 ± std", "StO2 ± std", "SpO2 mean", "StO2 mean", ...
%        "Location", "best");

% set(gca, 'Position', [0 0 1 1])
% set(gcf, 'Units', 'centimeters')
% set(gcf, 'Position', [5 5 9.52 5])


%% PI IR / RED
PI_ir_mat  = nan(length(t_common), length(trials));
PI_red_mat = nan(length(t_common), length(trials));

for i = 1:length(trials)
    tr = trials(i);
    tr_mask = trial_id == tr;

    t_tr = t_trial(tr_mask);
    PI_ir_tr = PI_IR(tr_mask);
    PI_red_tr = PI_RED(tr_mask);

    valid_ir = isfinite(t_tr) & isfinite(PI_ir_tr);
    valid_red = isfinite(t_tr) & isfinite(PI_red_tr);

    PI_ir_mat(:, i) = interp1(t_tr(valid_ir), PI_ir_tr(valid_ir), ...
                              t_common, 'linear', NaN);

    PI_red_mat(:, i) = interp1(t_tr(valid_red), PI_red_tr(valid_red), ...
                               t_common, 'linear', NaN);
end

PI_IR_mean = mean(PI_ir_mat, 2, 'omitnan');
PI_IR_std  = std(PI_ir_mat, 0, 2, 'omitnan');

PI_RED_mean = mean(PI_red_mat, 2, 'omitnan');
PI_RED_std  = std(PI_red_mat, 0, 2, 'omitnan');


% baseline 시작점 0으로 수정
PI_IR_base = PI_IR_mean(1);
PI_IR_mean = PI_IR_mean - PI_IR_base;

PI_RED_base = PI_RED_mean(1);
PI_RED_mean = PI_RED_mean - PI_RED_base;

%% PI (IR)
figure; hold on;

fill([t_common fliplr(t_common)], ...
     [PI_IR_mean' + PI_IR_std' fliplr(PI_IR_mean' - PI_IR_std')], ...
     [0.8 1 0.8], 'EdgeColor', 'none');

plot(t_common, PI_IR_mean, 'g', 'LineWidth', 1.38);

% xlim([0 210]);

% drawPhase(cycle);
% grid on;
xlabel("Time (s)");
ylabel("PI (%)");
title("PI (IR)");
% legend("PI IR ± std", "PI IR mean", "Location", "best");

% set(gca, 'Position', [0 0 1 1])
% set(gcf, 'Units', 'centimeters')
% set(gcf, 'Position', [5 5 9.52 5.5])

%% PI(RED)
figure; hold on;

fill([t_common fliplr(t_common)], ...
     [PI_RED_mean' + PI_RED_std' fliplr(PI_RED_mean' - PI_RED_std')], ...
     [1 0.8 0.8], 'EdgeColor', 'none');

plot(t_common, PI_RED_mean, 'r', 'LineWidth', 1.38);

% xlim([0 210]);

% drawPhase(cycle);
% grid on;
xlabel("Time (s)");
ylabel("PI (%)");
title("PI (RED)");
% legend("PI RED ± std", "PI RED mean", "Location", "best");

% set(gca, 'Position', [0 0 1 1])
% set(gcf, 'Units', 'centimeters')
% set(gcf, 'Position', [5 5 9.52 5.5])


%% HbO2, HHb, tHb [DC]
HHb_mat  = nan(length(t_common), length(trials));
HbO2_mat = nan(length(t_common), length(trials));
tHb_mat  = nan(length(t_common), length(trials));

for i = 1:length(trials)
    tr = trials(i);
    tr_mask = trial_id == tr;

    t_tr = t_trial(tr_mask);

    HHb_mat(:, i)  = interp1(t_tr, dHHb(tr_mask),  t_common, 'linear', NaN);
    HbO2_mat(:, i) = interp1(t_tr, dHbO2(tr_mask), t_common, 'linear', NaN);
    tHb_mat(:, i)  = interp1(t_tr, dHbT(tr_mask),  t_common, 'linear', NaN);
end

HHb_mean  = mean(HHb_mat, 2, 'omitnan');
HbO2_mean = mean(HbO2_mat, 2, 'omitnan');
tHb_mean  = mean(tHb_mat, 2, 'omitnan');

HHb_std  = std(HHb_mat, 0, 2, 'omitnan');
HbO2_std = std(HbO2_mat, 0, 2, 'omitnan');
tHb_std  = std(tHb_mat, 0, 2, 'omitnan');

figure; hold on;

fill([t_common fliplr(t_common)], ...
     [HHb_mean' + HHb_std' fliplr(HHb_mean' - HHb_std')], ...
     [0.5 0.5 1], 'EdgeColor', 'none');

fill([t_common fliplr(t_common)], ...
     [HbO2_mean' + HbO2_std' fliplr(HbO2_mean' - HbO2_std')], ...
     [1 0.5 0.5], 'EdgeColor', 'none');

% fill([t_common fliplr(t_common)], ...
%      [tHb_mean' + tHb_std' fliplr(tHb_mean' - tHb_std')], ...
%      [1 1 0], 'EdgeColor', 'none', 'FaceAlpha', 0.3);

plot(t_common, HHb_mean, 'b', 'LineWidth', 1.38);
plot(t_common, HbO2_mean, 'r', 'LineWidth', 1.38);
% plot(t_common, tHb_mean, 'Color', [1 0.8 0], 'LineWidth', 2);

% xlim([0 210]);

% drawPhase(cycle);
% grid on;
xlabel("Time (s)");
% title("HbO2, HHb, tHb [DC]");
% legend("HHb ± std", "HbO2 ± std", "tHb ± std", ...
%        "HHb mean", "HbO2 mean", "tHb mean", ...
%        "Location", "best");
title("HbO2, Hb [DC]");

 
% set(gca, 'Position', [0 0 1 1])
% set(gcf, 'Units', 'centimeters')
% set(gcf, 'Position', [5 5 9.52 4.5])
