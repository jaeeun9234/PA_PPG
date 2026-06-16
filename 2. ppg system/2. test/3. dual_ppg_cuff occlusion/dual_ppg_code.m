%% plot_ppg_combined.m
clear; clc; close all;

%% ===== 0) 파일 지정 =====
% fname = "data_20260416_1307.csv";
fname = "data_occlusion_20260601.csv";
T = readtable(fname);

%% ===== 1) 시간축 / 기본 데이터 =====
t = T.t1_us / 1000000;
t_trial = T.t_trial_ms / 1000;
trial_id = T.trial_id;
phase = T.phase;

t0_idx = (t_trial >= 3.0) & (t_trial < 3.5);
t0_idx2 = (t_trial >= 3.0) & (t_trial < 30);  

baseline_start = 0;
baseline_end = 30;

occlusion_start = 120;
occlusion_end = 150;

release_start = 180;
release_end = 210;

red_raw1 = T.red_raw1;
ir_raw1  = T.ir_raw1;

red_raw2 = T.red_raw2;
ir_raw2  = T.ir_raw2;


%% ===== 2) Fs 추정 =====
dt = diff(t_trial);
dt = dt(dt > 0);
Fs = 1 / median(dt);
fprintf("Fs ~= %.2f Hz\n", Fs);

%% ===== 3) phase 정보 =====
winSec = 5.0;          % 5초 윈도우
W = round(winSec*Fs);

% MBLL 식에서 안정화 구간만 데이터 뽑을 경우 사용
t0 = 30;                    
mask = t_trial >= t0;
tt = t_trial(mask);

% phase 변화 지점
idx_change = find(diff(phase) ~= 0) + 1;

t_change = t_trial(idx_change);
phase_change = phase(idx_change);

idx_base = (phase == 0);

cycles = parsePhaseCycles(t_trial, phase, trial_id);
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
ir_raw2  = hampel(ir_raw2,  N, nsigma);

alpha_dc = 0.02;

red_dc1 = zeros(size(red_raw1));
ir_dc1  = zeros(size(ir_raw1));

red_dc2 = zeros(size(red_raw2));
ir_dc2  = zeros(size(ir_raw2));

red_dc1(1) = red_raw1(1);
ir_dc1(1)  = ir_raw1(1);

red_dc2(1) = red_raw2(1);
ir_dc2(1)  = ir_raw2(1);

for i = 2:length(red_raw1)
    red_dc1(i) = (1-alpha_dc)*red_dc1(i-1) + alpha_dc*red_raw1(i);
    ir_dc1(i)  = (1-alpha_dc)*ir_dc1(i-1)  + alpha_dc*ir_raw1(i);
end

for i = 2:length(red_raw2)
    red_dc2(i) = (1-alpha_dc)*red_dc2(i-1) + alpha_dc*red_raw2(i);
    ir_dc2(i)  = (1-alpha_dc)*ir_dc2(i-1)  + alpha_dc*ir_raw2(i);
end

red_ac1 = red_raw1 - red_dc1;
ir_ac1  = ir_raw1  - ir_dc1;

red_ac2 = red_raw2 - red_dc2;
ir_ac2  = ir_raw2  - ir_dc2;

%%
winSpike = round(0.8 * Fs);
kSpike = 4;

red_raw1 = removeLocalSpike(red_raw1, winSpike, kSpike);
ir_raw1  = removeLocalSpike(ir_raw1,  winSpike, kSpike);

red_raw2 = removeLocalSpike(red_raw2, winSpike, kSpike);
ir_raw2  = removeLocalSpike(ir_raw2,  winSpike, kSpike);

red_ac1 = removeLocalSpike(red_ac1, winSpike, kSpike);
ir_ac1  = removeLocalSpike(ir_ac1,  winSpike, kSpike);

red_ac1 = fillmissing(red_ac1, 'linear');
ir_ac1  = fillmissing(ir_ac1,  'linear');

red_ac2 = removeLocalSpike(red_ac2, winSpike, kSpike);
ir_ac2  = removeLocalSpike(ir_ac2,  winSpike, kSpike);

red_ac2 = fillmissing(red_ac2, 'linear');
ir_ac2  = fillmissing(ir_ac2,  'linear');


bp_low = 0.7; bp_high = 4;

red_ac_bp1 = bandpass(red_ac1, [bp_low bp_high], Fs);
ir_ac_bp1  = bandpass(ir_ac1,  [bp_low bp_high], Fs);

red_ac_bp2 = bandpass(red_ac2, [bp_low bp_high], Fs);
ir_ac_bp2  = bandpass(ir_ac2,  [bp_low bp_high], Fs);

%%
DC_red0_1 = mean(red_dc1(t0_idx2), 'omitnan');
DC_ir0_1  = mean(ir_dc1(t0_idx2),  'omitnan');
RAW_red0_1 = mean(red_raw1(t0_idx2), 'omitnan');
RAW_ir0_1 = mean(ir_raw1(t0_idx2), 'omitnan');

DC_red0_2 = mean(red_dc2(t0_idx2), 'omitnan');
DC_ir0_2  = mean(ir_dc2(t0_idx2),  'omitnan');
RAW_red0_2 = mean(red_raw2(t0_idx2), 'omitnan');
RAW_ir0_2 = mean(ir_raw2(t0_idx2), 'omitnan');

%% SpO2
W_SpO2 = round(Fs * 5);

AC_red_rms_1 = nan(size(red_ac_bp1));
AC_ir_rms_1  = nan(size(ir_ac_bp1));

for i = W_SpO2:length(red_ac_bp1)
    seg_red_1 = red_ac_bp1(i-W_SpO2+1:i);
    seg_ir_1  = ir_ac_bp1(i-W_SpO2+1:i);

    AC_red_rms_1(i) = sqrt(mean(seg_red_1.^2, 'omitnan'));
    AC_ir_rms_1(i)  = sqrt(mean(seg_ir_1.^2,  'omitnan'));
end

DC_red_SpO2_1 = movmean(red_dc1, W_SpO2, 'omitnan');
DC_ir_SpO2_1  = movmean(ir_dc1,  W_SpO2, 'omitnan');

ratio_red_1 = AC_red_rms_1 ./ DC_red_SpO2_1;
ratio_ir_1  = AC_ir_rms_1  ./ DC_ir_SpO2_1;

R1 = ratio_red_1 ./ ratio_ir_1;

R1(~isfinite(R1)) = NaN;
R1(R1 <= 0) = NaN;
R1(R1 < 0.3 | R1 > 2.0) = NaN;

R_s_1 = movmean(R1, round(Fs*5), 'omitnan');

SpO2_est_1 = 110 - 25 * R_s_1;
SpO2_est_1(SpO2_est_1 > 100) = 100;
SpO2_est_1(SpO2_est_1 < 0) = 0;


AC_red_rms_2 = nan(size(red_ac_bp2));
AC_ir_rms_2  = nan(size(ir_ac_bp2));

for i = W_SpO2:length(red_ac_bp2)
    seg_red_2 = red_ac_bp2(i-W_SpO2+1:i);
    seg_ir_2  = ir_ac_bp2(i-W_SpO2+1:i);

    AC_red_rms_2(i) = sqrt(mean(seg_red_2.^2, 'omitnan'));
    AC_ir_rms_2(i)  = sqrt(mean(seg_ir_2.^2,  'omitnan'));
end

DC_red_SpO2_2 = movmean(red_dc2, W_SpO2, 'omitnan');
DC_ir_SpO2_2  = movmean(ir_dc2,  W_SpO2, 'omitnan');

ratio_red_2 = AC_red_rms_2 ./ DC_red_SpO2_2;
ratio_ir_2  = AC_ir_rms_2  ./ DC_ir_SpO2_2;

R2 = ratio_red_2 ./ ratio_ir_2;

R2(~isfinite(R2)) = NaN;
R2(R2 <= 0) = NaN;
R2(R2 < 0.3 | R2 > 2.0) = NaN;

R_s_2 = movmean(R2, round(Fs*5), 'omitnan');

SpO2_est_2 = 110 - 25 * R_s_2;
SpO2_est_2(SpO2_est_2 > 100) = 100;
SpO2_est_2(SpO2_est_2 < 0) = 0;


%% PI 계산
W_PI_1 = round(Fs * 5);

% IR PI
ir_max_1 = movmax(ir_ac1, W_PI_1, 'omitnan');
ir_min_1 = movmin(ir_ac1, W_PI_1, 'omitnan');

AC_amp_IR_1 = ir_max_1 - ir_min_1;
DC_mean_IR_1 = movmean(ir_dc1, W_PI_1, 'omitnan');

PI_IR_1 = 100 * (AC_amp_IR_1 ./ DC_mean_IR_1);

% RED PI
red_max_1 = movmax(red_ac1, W_PI_1, 'omitnan');
red_min_1 = movmin(red_ac1, W_PI_1, 'omitnan');

AC_amp_RED_1 = red_max_1 - red_min_1;
DC_mean_RED_1 = movmean(red_dc1, W_PI_1, 'omitnan');

PI_RED_1 = 100 * (AC_amp_RED_1 ./ DC_mean_RED_1);

W_PI_2 = round(Fs * 5);

% IR PI
ir_max_2 = movmax(ir_ac2, W_PI_2, 'omitnan');
ir_min_2 = movmin(ir_ac2, W_PI_2, 'omitnan');

AC_amp_IR_2 = ir_max_2 - ir_min_2;
DC_mean_IR_2 = movmean(ir_dc2, W_PI_2, 'omitnan');

PI_IR_2 = 100 * (AC_amp_IR_2 ./ DC_mean_IR_2);

% RED PI
red_max_2 = movmax(red_ac2, W_PI_2, 'omitnan');
red_min_2 = movmin(red_ac2, W_PI_2, 'omitnan');

AC_amp_RED_2 = red_max_2 - red_min_2;
DC_mean_RED_2 = movmean(red_dc2, W_PI_2, 'omitnan');

PI_RED_2 = 100 * (AC_amp_RED_2 ./ DC_mean_RED_2);

%% MBLL (DC)
dA_660_1 = -log10(red_dc1 ./ DC_red0_1);
dA_880_1 = -log10(ir_dc1  ./ DC_ir0_1);

bad1 = ~isfinite(dA_660_1) | ~isfinite(dA_880_1);
dA_660_1(bad1) = NaN;
dA_880_1(bad1) = NaN;

dA_660_1 = fillmissing(dA_660_1, "linear", "EndValues", "nearest");
dA_880_1 = fillmissing(dA_880_1, "linear", "EndValues", "nearest");

E = [eps_HHb_660,  eps_HbO2_660;
     eps_HHb_880,  eps_HbO2_880];

X1 = inv(E) * [dA_660_1.'; dA_880_1.'];

dHHb_1  = X1(1,:).';
dHbO2_1 = X1(2,:).';
dHbT_1 = dHHb_1 + dHbO2_1;

%% MBLL (DC)
dA_660_2 = -log10(red_dc2 ./ DC_red0_2);
dA_880_2 = -log10(ir_dc2  ./ DC_ir0_2);

bad2 = ~isfinite(dA_660_2) | ~isfinite(dA_880_2);
dA_660_2(bad2) = NaN;
dA_880_2(bad2) = NaN;

dA_660_2 = fillmissing(dA_660_2, "linear", "EndValues", "nearest");
dA_880_2 = fillmissing(dA_880_2, "linear", "EndValues", "nearest");

E = [eps_HHb_660,  eps_HbO2_660;
     eps_HHb_880,  eps_HbO2_880];

X2 = inv(E) * [dA_660_2.'; dA_880_2.'];

dHHb_2  = X2(1,:).';
dHbO2_2 = X2(2,:).';
dHbT_2 = dHHb_2 + dHbO2_2;


%% ===== StO2 계산 =====
StO2_0 = 0.70;
tHb_0  = 7e-5;
HbO2_0 = StO2_0 * tHb_0;

StO2_est_1 = (HbO2_0 + dHbO2_1) ./ (tHb_0 + dHbT_1);
StO2_est_1 = StO2_est_1 * 100;

StO2_est_1(~isfinite(StO2_est_1)) = NaN;
StO2_est_1 = min(max(StO2_est_1, 0), 100);

StO2_est_2 = (HbO2_0 + dHbO2_2) ./ (tHb_0 + dHbT_2);
StO2_est_2 = StO2_est_2 * 100;

StO2_est_2(~isfinite(StO2_est_2)) = NaN;
StO2_est_2 = min(max(StO2_est_2, 0), 100);

%% occlusion 구간 FFT [AC]
bp_low_bpm = bp_low * 60;
bp_high_bpm = bp_high * 60;

t_trial = t_trial(:);
red_ac_bp1 = red_ac_bp1(:);

mask_t_o = (t_trial >= occlusion_start & t_trial <= occlusion_end);

x1_o = red_ac_bp1(mask_t_o);
x1_o = x1_o(isfinite(x1_o));

xu1_o = x1_o - mean(x1_o, 'omitnan');

N = numel(xu1_o);
ac_fft_red1_o = fft(xu1_o);
half = floor(N/2);

f_1_o = (0:half-1)*Fs / N;

mag_occlusion_1 = abs(ac_fft_red1_o(1:half)) / N;

mag_norm_occlusion_1 = mag_occlusion_1 / max(mag_occlusion_1);

f_o_ac_bpm_1 = f_1_o*60;

band_o_ac_bpm_1 = (f_o_ac_bpm_1 <=bp_high_bpm);

% figure;
% plot(f_o_ac_bpm_1(band_o_ac_bpm_1), mag_occlusion_1(band_o_ac_bpm_1));
% %xlabel("bpm"); ylabel("Magnitude");
% title("AC FFT (occlusion) : sensor1");

red_ac_bp2 = red_ac_bp2(:);

mask_t_o = (t_trial >= occlusion_start & t_trial <= occlusion_end);

x2_o = red_ac_bp2(mask_t_o);
x2_o = x2_o(isfinite(x2_o));

xu2_o = x2_o - mean(x2_o, 'omitnan');

N = numel(xu2_o);
ac_fft_red2_o = fft(xu2_o);
half = floor(N/2);

f_2_o = (0:half-1)*Fs / N;

mag_occlusion_2 = abs(ac_fft_red2_o(1:half)) / N;

mag_norm_occlusion_2 = mag_occlusion_2 / max(mag_occlusion_2);

f_o_ac_bpm_2 = f_2_o*60;

band_o_ac_bpm_2 = (f_o_ac_bpm_2 <=bp_high_bpm);

% figure;
% plot(f_o_ac_bpm_2(band_o_ac_bpm_2), mag_occlusion_2(band_o_ac_bpm_2));
% %xlabel("bpm"); ylabel("Magnitude");
% title("AC FFT (occlusion) : sensor2");

%% release 이후 FFT [AC]
t_trial = t_trial(:);
red_ac_bp1 = red_ac_bp1(:);

mask_t_r = (t_trial >= release_start & t_trial <= release_end);

x1_r = red_ac_bp1(mask_t_r);

x1_r = x1_r(isfinite(x1_r));

xu1_r = x1_r - mean(x1_r, 'omitnan');

N = numel(xu1_r);
ac_fft_red1_r = fft(xu1_r);
half = floor(N/2);

f_1_r = (0:half-1)*Fs / N;
mag_release_1 = abs(ac_fft_red1_r(1:half)) / N;

mag_norm_release_1 = mag_release_1 / max(mag_release_1);

f_r_ac_bpm_1 = f_1_r*60;

band_r_ac_bpm_1 = (f_r_ac_bpm_1 <=bp_high_bpm);
% band = (f_r >= bp_low & f_r <= bp_high);

% figure;
% plot(f_r_ac_bpm_1(band_r_ac_bpm_1), mag_release_1(band_r_ac_bpm_1));
% %xlabel("bpm"); ylabel("Magnitude");
% title("AC FFT (release) : sensor1");

red_ac_bp2 = red_ac_bp2(:);

mask_t_r = (t_trial >= release_start & t_trial <= release_end);

x2_r = red_ac_bp2(mask_t_r);

x2_r = x2_r(isfinite(x2_r));

xu2_r = x2_r - mean(x2_r, 'omitnan');

N = numel(xu2_r);
ac_fft_red2r = fft(xu2_r);
half = floor(N/2);

f_2_r = (0:half-1)*Fs / N;
mag_release_2 = abs(ac_fft_red2r(1:half)) / N;

mag_norm_release_2 = mag_release_2 / max(mag_release_2);

f_r_ac_bpm_2 = f_2_r*60;

band_r_ac_bpm_2 = (f_r_ac_bpm_2 <=bp_high_bpm);
% band = (f_r >= bp_low & f_r <= bp_high);

% figure;
% plot(f_r_ac_bpm_2(band_r_ac_bpm_2), mag_release_2(band_r_ac_bpm_2));
% %xlabel("bpm"); ylabel("Magnitude");
% title("AC FFT (release) : sensor2");


%% occlusion, release 같이 plot [AC]
max_ref_1 = max([mag_occlusion_1(:); mag_release_1(:)]);

mag_occlusion_total_1 = mag_occlusion_1 / max_ref_1;
mag_release_total_1 = mag_release_1 / max_ref_1;

figure;
plot(f_o_ac_bpm_1(band_o_ac_bpm_1), mag_occlusion_total_1(band_o_ac_bpm_1), "LineWidth", 1.38); hold on;
plot(f_r_ac_bpm_1(band_r_ac_bpm_1), mag_release_total_1(band_r_ac_bpm_1), "LineWidth", 1.38);
title("AC FFT spectrum : without cuff ");
ylabel("Normalized amplitude"); 
xlim([30 180]);
% ylim([0 1]);
legend("occlusion (2.0 - 2.5 min)", "release (3.0 - 3.5 min)");

%% occlusion, release 같이 plot [AC]
max_ref_2 = max([mag_occlusion_2(:); mag_release_2(:)]);

mag_occlusion_total_2 = mag_occlusion_2 / max_ref_2;
mag_release_total_2 = mag_release_2 / max_ref_2;

figure;
plot(f_o_ac_bpm_2(band_o_ac_bpm_2), mag_occlusion_total_2(band_o_ac_bpm_2), "LineWidth", 1.38); hold on;
plot(f_r_ac_bpm_2(band_r_ac_bpm_2), mag_release_total_2(band_r_ac_bpm_2), "LineWidth", 1.38);
title("AC FFT spectrum : with cuff ");
ylabel("Normalized amplitude"); 
xlim([30 180]);
% ylim([0 1]);
legend("occlusion (2.0 - 2.5 min)", "release (3.0 - 3.5 min)");

%% ========================================================================================================== %%
%% mean ± std plot
trials = unique(trial_id);
nTrial = length(trials);

N_each = zeros(nTrial, 1);

for i = 1:nTrial
    tr = trials(i);
    idx = trial_id == tr;
    N_each(i) = sum(idx);
end

N_common = min(N_each);
idx_ref = find(trial_id == trials(1));
idx_ref = idx_ref(1:N_common);

t_common = t_trial(idx_ref);

fs_m = 1/Fs;
t = ((0:length(t_common)-1)*fs_m) / 60;


%% SpO2 & StO2 (wo cuff)
spo2_mat_1 = nan(N_common, nTrial);
sto2_mat_1 = nan(N_common, nTrial);

for i = 1:nTrial
    tr = trials(i);
    idx = find(trial_id == tr);

    idx = idx(1:N_common);

    spo2_mat_1(:, i) = SpO2_est_1(idx);
    sto2_mat_1(:, i) = StO2_est_1(idx);
end

spo2_mean_1 = mean(spo2_mat_1, 2, 'omitnan');
spo2_std_1  = std(spo2_mat_1, 0, 2, 'omitnan');

sto2_mean_1 = mean(sto2_mat_1, 2, 'omitnan');
sto2_std_1  = std(sto2_mat_1, 0, 2, 'omitnan');


figure; hold on;

fill([t fliplr(t)], ...
    [spo2_mean_1' + spo2_std_1' fliplr(spo2_mean_1' - spo2_std_1')], ...
    [1 0.8 0.8], 'EdgeColor', 'none');

fill([t fliplr(t)], ...
    [sto2_mean_1' + sto2_std_1' fliplr(sto2_mean_1' - sto2_std_1')], ...
    [0.8 0.8 1], 'EdgeColor', 'none');


plot(t, spo2_mean_1, 'r', 'LineWidth', 1.25);
plot(t, sto2_mean_1, 'b', 'LineWidth', 1.25);

xlim([0 3.5]);

xlabel("Time (s)");
ylabel("SpO2 / StO2 (%)");
ylim([50 100]);
title("SpO2 & StO2 : without cuff");


%% SpO2 & StO2 (with cuff)
spo2_mat_2 = nan(N_common, nTrial);
sto2_mat_2 = nan(N_common, nTrial);

for i = 1:length(trials)
    tr = trials(i);
    idx = find(trial_id == tr);

    idx = idx(1:N_common);

    spo2_mat_2(:, i) = SpO2_est_2(idx);
    sto2_mat_2(:, i) = StO2_est_2(idx);
end

spo2_mean_2 = mean(spo2_mat_2, 2, 'omitnan');
spo2_std_2  = std(spo2_mat_2, 0, 2, 'omitnan');

sto2_mean_2 = mean(sto2_mat_2, 2, 'omitnan');
sto2_std_2  = std(sto2_mat_2, 0, 2, 'omitnan');


figure; hold on;

fill([t fliplr(t)], ...
    [spo2_mean_2' + spo2_std_2' fliplr(spo2_mean_2' - spo2_std_2')], ...
    [1 0.8 0.8], 'EdgeColor', 'none');

fill([t fliplr(t)], ...
    [sto2_mean_2' + sto2_std_2' fliplr(sto2_mean_2' - sto2_std_2')], ...
    [0.8 0.8 1], 'EdgeColor', 'none');


plot(t, spo2_mean_2, 'r', 'LineWidth', 1.25);
plot(t, sto2_mean_2, 'b', 'LineWidth', 1.25);

xlim([0 3.5]);

% drawPhase(cycle);
% grid on;
xlabel("Time (s)");
ylabel("SpO2 / StO2 (%)");
ylim([50 100]);
title("SpO2 & StO2 : with cuff");
% legend("SpO2 ± std", "StO2 ± std", "SpO2 mean", "StO2 mean", ...
%        "Location", "best");

% set(gca, 'Position', [0 0 1 1])
% set(gcf, 'Units', 'centimeters')
% set(gcf, 'Position', [5 5 9.52 5])



%% PI IR / RED (wo cuff)
PI_ir_mat_1  = nan(N_common, nTrial);
PI_red_mat_1 = nan(N_common, nTrial);

for i = 1:nTrial
    tr = trials(i);
    idx = find(trial_id == tr);

    idx = idx(1:N_common);

    PI_ir_mat_1(:, i) = PI_IR_1(idx);
    PI_red_mat_1(:, i) = PI_RED_1(idx);
end

PI_IR_mean_1 = mean(PI_ir_mat_1, 2, 'omitnan');
PI_IR_std_1  = std(PI_ir_mat_1, 0, 2, 'omitnan');

PI_RED_mean_1 = mean(PI_red_mat_1, 2, 'omitnan');
PI_RED_std_1  = std(PI_red_mat_1, 0, 2, 'omitnan');


% % baseline 시작점 0으로 수정
% PI_IR_base_1 = PI_IR_mean_1(1);
% PI_IR_mean_1 = PI_IR_mean_1 - PI_IR_base_1;
% 
% PI_RED_base_1 = PI_RED_mean_1(1);
% PI_RED_mean_1 = PI_RED_mean_1 - PI_RED_base_1;

%% PI IR / RED (with cuff)
PI_ir_mat_2  = nan(N_common, nTrial);
PI_red_mat_2 = nan(N_common, nTrial);

for i = 1:length(trials)
    tr = trials(i);
    idx = find(trial_id == tr);
    idx = idx(1:N_common);
    
    PI_ir_mat_2(:, i) = PI_IR_2(idx);
    PI_red_mat_2(:, i) = PI_RED_2(idx);
end

PI_IR_mean_2 = mean(PI_ir_mat_2, 2, 'omitnan');
PI_IR_std_2  = std(PI_ir_mat_2, 0, 2, 'omitnan');

PI_RED_mean_2 = mean(PI_red_mat_2, 2, 'omitnan');
PI_RED_std_2  = std(PI_red_mat_2, 0, 2, 'omitnan');


% % baseline 시작점 0으로 수정
% PI_IR_base_2 = PI_IR_mean_2(1);
% PI_IR_mean_2 = PI_IR_mean_2 - PI_IR_base_2;
% 
% PI_RED_base_2 = PI_RED_mean_2(1);
% PI_RED_mean_2 = PI_RED_mean_2 - PI_RED_base_2;


%% PI (IR) wo cuff
figure; hold on;

fill([t fliplr(t)], ...
     [PI_IR_mean_1' + PI_IR_std_1' fliplr(PI_IR_mean_1' - PI_IR_std_1')], ...
     [0.8 1 0.8], 'EdgeColor', 'none');

plot(t, PI_IR_mean_1, 'g', 'LineWidth', 1.25);

xlim([0 3.5]);

% drawPhase(cycle);
% grid on;
xlabel("Time (min)");
ylabel("PI (%)");
title("PI (IR) : without cuff");
ylim([-4 12]);

%% PI(RED) wo cuff
figure; hold on;

fill([t fliplr(t)], ...
     [PI_RED_mean_1'+PI_RED_std_1' fliplr(PI_RED_mean_1'-PI_RED_std_1')], ...
     [1 0.8 0.8], ...
     'EdgeColor','none', ...
     'FaceAlpha',0.3);

plot(t, PI_RED_mean_1, 'r', 'LineWidth', 1.25);

xlim([0 3.5]);

% drawPhase(cycle);
% grid on;
xlabel("Time (min)");
ylabel("PI (%)");
title("PI (RED) : without cuff");
ylim([-2 10]);


%% PI (IR) with cuff
figure; hold on;

fill([t fliplr(t)], ...
     [PI_IR_mean_2'+PI_IR_std_2' fliplr(PI_IR_mean_2'-PI_IR_std_2')], ...
     [0.8 1 0.8], ...
     'EdgeColor','none', ...
     'FaceAlpha',0.3);
plot(t, PI_IR_mean_2, 'g', 'LineWidth', 1.38);

xlim([0 3.5]);

xlabel("Time (s)");
ylabel("PI (%)");
title("PI (IR) : with cuff");

%% PI(RED) with cuff
figure; hold on;

fill([t fliplr(t)], ...
     [PI_RED_mean_2'+PI_RED_std_2' fliplr(PI_RED_mean_2'-PI_RED_std_2')], ...
     [1 0.8 0.8], ...
     'EdgeColor','none', ...
     'FaceAlpha',0.3);

plot(t, PI_RED_mean_2, 'r', 'LineWidth', 1.38);

xlim([0 3.5]);

xlabel("Time (s)");
ylabel("PI (%)");
title("PI (RED) : with cuff");



%% HbO2, HHb, tHb [DC]
Hb_mat_1  = nan(N_common, nTrial);
HbO2_mat_1 = nan(N_common, nTrial);

for i = 1:nTrial
    tr = trials(i);
    idx = find(trial_id == tr);
    idx = idx(1:N_common);

    Hb_mat_1(:, i) = dHHb_1(idx);
    HbO2_mat_1(:, i) = dHbO2_1(idx);
end

Hb_mean_1  = mean(Hb_mat_1, 2, 'omitnan');
HbO2_mean_1 = mean(HbO2_mat_1, 2, 'omitnan');

Hb_std_1  = std(Hb_mat_1, 0, 2, 'omitnan');
HbO2_std_1 = std(HbO2_mat_1, 0, 2, 'omitnan');

figure; hold on;

fill([t fliplr(t)], ...
     [Hb_mean_1'+Hb_std_1' fliplr(Hb_mean_1'-Hb_std_1')], ...
     [0.8 0.8 1], 'EdgeColor','none', 'FaceAlpha',0.3);

fill([t fliplr(t)], ...
     [HbO2_mean_1'+HbO2_std_1' fliplr(HbO2_mean_1'-HbO2_std_1')], ...
     [1 0.8 0.8], 'EdgeColor','none', 'FaceAlpha',0.3);

plot(t, Hb_mean_1, 'b', 'LineWidth', 1.25);
plot(t, HbO2_mean_1, 'r', 'LineWidth', 1.25);

xlim([0 3.5]);
ylim([-3*1e-5 6*1e-5]);

xlabel("Time (min)");

title("HbO2, Hb [DC] : without cuff");

%% HbO2, HHb, tHb [DC]
Hb_mat_2  = nan(N_common, nTrial);
HbO2_mat_2 = nan(N_common, nTrial);

for i = 1:nTrial
    tr = trials(i);
    idx = find(trial_id == tr);
    idx = idx(1:N_common);

    Hb_mat_2(:, i) = dHHb_2(idx);
    HbO2_mat_2(:, i) = dHbO2_2(idx);
    
end

Hb_mean_2  = mean(Hb_mat_2, 2, 'omitnan');
HbO2_mean_2 = mean(HbO2_mat_2, 2, 'omitnan');

Hb_std_2  = std(Hb_mat_2, 0, 2, 'omitnan');
HbO2_std_2 = std(HbO2_mat_2, 0, 2, 'omitnan');

figure; hold on;

fill([t fliplr(t)], ...
     [Hb_mean_2'+Hb_std_2' fliplr(Hb_mean_2'-Hb_std_2')], ...
     [0.8 0.8 1], 'EdgeColor','none', 'FaceAlpha',0.3);

fill([t fliplr(t)], ...
     [HbO2_mean_2'+HbO2_std_2' fliplr(HbO2_mean_2'-HbO2_std_2')], ...
     [1 0.8 0.8], 'EdgeColor','none', 'FaceAlpha',0.3);

plot(t, Hb_mean_2, 'b', 'LineWidth', 1.25);
plot(t, HbO2_mean_2, 'r', 'LineWidth', 1.25);

xlim([0 3.5]);
% ylim([-3*1e-5 7*1e-5]);
% drawPhase(cycle);
% grid on;
xlabel("Time (s)");
title("HbO2, Hb [DC] : with cuff");

%% ppg PI (wo cuff / with cuff)
figure; hold on;

fill([t fliplr(t)], ...
     [PI_RED_mean_2' + PI_RED_std_2' fliplr(PI_RED_mean_2' - PI_RED_std_2')], ...
     [1 0.8 0.8], 'EdgeColor','none', 'FaceAlpha',0.3);

fill([t fliplr(t)], ...
     [PI_RED_mean_1' + PI_RED_std_1' fliplr(PI_RED_mean_1' - PI_RED_std_1')], ...
     [0.8 0.8 1], 'EdgeColor','none', 'FaceAlpha',0.3);

plot(t, PI_RED_mean_2, 'r', 'LineWidth', 1.25);
plot(t, PI_RED_mean_1, 'b', 'LineWidth', 1.25);

xlim([0 3.5]);

xlabel("Time (min)");
title("PPG PI (with cuff / wo cuff)");

legend("with cuff", "wo cuff", "Location","best");



% %% amplitude box plot => PI box plot
% idx_baseline = (t >= baseline_start) & (t <= baseline_end);
% idx_occlusion = (t >= occlusion_start) & (t <= occlusion_end);
% idx_release = (t >= release_start) & (t <= release_end);
% 
% data_without_cuff = [
%     PI_RED_m1(idx_baseline);
%     PI_RED_m1(idx_occlusion);
%     PI_RED_m1(idx_release);
% ];
% 
% data_with_cuff = [
%     PI_RED_m2(idx_baseline);
%     PI_RED_m2(idx_occlusion);
%     PI_RED_m2(idx_release);
% ];
% 
% phase_with_cuff = [
%     repmat({'Baseline'}, sum(idx_baseline), 1);
%     repmat({'Occlusion'}, sum(idx_occlusion), 1);
%     repmat({'Release'}, sum(idx_release), 1)
% ];
% 
% phase_without_cuff = [
%     repmat({'Baseline'}, sum(idx_baseline), 1);
%     repmat({'Occlusion'}, sum(idx_occlusion), 1);
%     repmat({'Release'}, sum(idx_release), 1)
% ];
% 
% condition_with_cuff = repmat({'With cuff'}, length(data_with_cuff), 1);
% condition_without_cuff = repmat({'Without cuff'}, length(data_without_cuff), 1);
% 
% box_data = [data_with_cuff; data_without_cuff];
% 
% phase_group = [
%     phase_with_cuff;
%     phase_without_cuff;
% ];
% 
% condition_group = [
%     condition_with_cuff;
%     condition_without_cuff;
% ];
% 
% %% p-value 계산 (trial 별 phase 대표값)
% phases = {'Baseline','Occlusion','Release'};
% phase_idx = {idx_baseline, idx_occlusion, idx_release};
% 
% p_values = nan(1,3);
% % 추가
% delta_values = nan(1, 3);
% percent_change = nan(1, 3);
% 
% for i = 1:3
%     idx = phase_idx{i};
% 
%     % With cuff: trial별 phase 평균값 3개
%     x_with = mean(PI_red_mat_2(idx, :), 1, 'omitnan');
% 
%     % Without cuff: trial별 phase 평균값 3개
%     x_wo = mean(PI_red_mat_1(idx, :), 1, 'omitnan');
% 
%     p_values(i) = signrank(x_with, x_wo);
% 
%     diff_phase{i} = x_with - x_wo;
%     median_diff(i) = median(x_with - x_wo, 'omitnan');
% end
% 
% base_with = mean(PI_red_mat_2(idx_baseline, :), 1, 'omitnan');
% occ_with  = mean(PI_red_mat_2(idx_occlusion, :), 1, 'omitnan');
% 
% base_wo = mean(PI_red_mat_1(idx_baseline, :), 1, 'omitnan');
% occ_wo  = mean(PI_red_mat_1(idx_occlusion, :), 1, 'omitnan');
% 
% change_with = (occ_with - base_with) ./ base_with * 100;
% change_wo   = (occ_wo   - base_wo)   ./ base_wo   * 100;
% 
% p_change = signrank(change_with, change_wo);
% 
% data_box = [change_wo(:); change_with(:)];
% 
% group_box = [
%     repmat({'Without cuff'}, numel(change_wo), 1);
%     repmat({'With cuff'},    numel(change_with), 1)
% ];
% 
% figure; hold on;
% 
% boxplot(data_box, group_box);
% 
% ylabel('Change from baseline (%)');
% title(sprintf('Occlusion change from baseline, p = %.3f', p_change));
% grid on;
% 
% %%
% figure;
% boxplot(box_data, {phase_group, condition_group}, ...
%     'FactorSeparator', 1, ...
%     'LabelVerbosity', 'minor', ...
%     'Symbol','');
% 
% 
% ylabel('PPG PI');
% grid off; box off;
% title("PPG PI Comparison by Phase");
% ylim([-1 1]);
% 
% hold on
% 
% x_pairs = [1 2; 3 4; 5 6];
% 
% for i = 1:3
%     ph = phases{i};
% 
%     x_with = box_data(strcmp(phase_group, ph) & strcmp(condition_group,'With cuff'));
%     x_wo   = box_data(strcmp(phase_group, ph) & strcmp(condition_group,'Without cuff'));
% 
%     x_all = [x_with; x_wo];
%     x_all = x_all(isfinite(x_all));
% 
%     ymax = prctile(x_all, 95);   % outlier 제외 느낌
% 
%     y  = ymax + 0.1;   % bracket 위치
%     h  = 0.06;         % bracket 높이
%     yt = y + 0.2;      % p-value text 위치
% 
%     x1 = x_pairs(i,1);
%     x2 = x_pairs(i,2);
% 
%     plot([x1 x1 x2 x2], ...
%          [y y+h y+h y], ...
%          'k','LineWidth',1.2);
% 
%     text(mean([x1 x2]), yt, ...
%         sprintf('p = %.2f', p_values(i)), ...
%         'HorizontalAlignment','center', ...
%         'FontSize', 11);
% end

% copygraphics(gcf, 'ContentType', 'vector');

%% =============================================================== %%
% %% ampRatio mean ± std
% % ampRatio_IR  = AC_amp_IR_1  ./ AC_amp_IR_2;
% ampRatio_RED = AC_amp_RED_1 ./ AC_amp_RED_2;
% 
% % ampRatio_IR(~isfinite(ampRatio_IR)) = NaN;
% ampRatio_RED(~isfinite(ampRatio_RED)) = NaN;
% 
% % ampRatioIR_mat  = nan(length(t_common), length(trials));
% ampRatioRED_mat = nan(length(t_common), length(trials));
% 
% for i = 1:length(trials)
% 
%     tr = trials(i);
%     tr_mask = trial_id == tr;
% 
%     t_tr = t_trial(tr_mask);
% 
%     % ampRatioIR_mat(:,i) = interp1( ...
%     %     t_tr, ...
%     %     ampRatio_IR(tr_mask), ...
%     %     t_common, ...
%     %     'linear', NaN);
% 
%     ampRatioRED_mat(:,i) = interp1( ...
%         t_tr, ...
%         ampRatio_RED(tr_mask), ...
%         t_common, ...
%         'linear', NaN);
% 
% end
% 
% % ampRatioIR_mean  = mean(ampRatioIR_mat ,2,'omitnan');
% % ampRatioIR_std   = std (ampRatioIR_mat ,0,2,'omitnan');
% 
% ampRatioRED_mean = mean(ampRatioRED_mat,2,'omitnan');
% ampRatioRED_std  = std (ampRatioRED_mat,0,2,'omitnan');
% 
% figure; hold on;
% 
% % fill([t_common fliplr(t_common)], ...
% %     [ampRatioIR_mean'+ampRatioIR_std' ...
% %      fliplr(ampRatioIR_mean'-ampRatioIR_std')], ...
% %     [0.8 1 0.8], ...
% %     'EdgeColor','none');
% 
% fill([t_common fliplr(t_common)], ...
%     [ampRatioRED_mean'+ampRatioRED_std' ...
%      fliplr(ampRatioRED_mean'-ampRatioRED_std')], ...
%     [1 0.8 0.8], ...
%     'EdgeColor','none');
% 
% % plot(t_common, ampRatioIR_mean , 'g', 'LineWidth', 1.38);
% plot(t_common, ampRatioRED_mean, 'r', 'LineWidth', 1.38);
% 
% xlim([0 210]);
% 
% xlabel("Time (s)");
% ylabel("Amplitude Ratio (without cuff / with cuff)");
% title("Amplitude Ratio");
% % title("Amplitude Ratio : sensor1 / sensor2");
% % 
% % legend("IR ± std", "RED ± std", ...
% %        "IR mean", "RED mean");


% figure; hold on;
% fill([t; flipud(t)], ...
% [PI_RED_m1+PI_RED_s1; flipud(PI_RED_m1-PI_RED_s1)], ...
% [0.8 0.8 1], 'EdgeColor', 'none', 'FaceAlpha', 0.3);
% fill([t; flipud(t)], ...
% [PI_RED_m2+PI_RED_s2; flipud(PI_RED_m2-PI_RED_s2)], ...
% [1 0.8 0.8], 'EdgeColor', 'none', 'FaceAlpha', 0.3);
% plot(t_common, PI_RED_m1, 'b', 'LineWidth', 1.38);
% plot(t_common, PI_RED_m2, 'r', 'LineWidth', 1.38);
% xlim([0 210]);
% xlabel("Time (s)");
% ylabel("PPG PI [a.u.]");
% title("PPG Perfusion Index");
% % legend("wo cuff", "with cuff", "Location", "best");
% 
% % set(gca, 'Position', [0 0 1 1])
% % set(gcf, 'Units', 'centimeters')
% % set(gcf, 'Position', [15 15 4.5 3.48])
% 
% 
% % copygraphics(gcf, 'ContentType', 'vector');

