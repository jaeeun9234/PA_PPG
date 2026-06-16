%% plot_ppg_combined.m
clear; clc; close all;

%% ===== 0) 파일 지정 =====
% fname = "data_20260416_1307.csv";
fname = "data_20260506.csv";   % PA-finger, PPG-finger
T = readtable(fname);

%% ===== 1) 시간축 / 기본 데이터 =====
t = T.t_ms / 1000;
t_trial = T.t_trial_ms / 1000;
trial_id = T.trial_id;
phase = T.phase;

t0_idx = (t_trial >= 3.0) & (t_trial < 3.5);
t0_idx2 = (t_trial >= 3.0) & (t_trial < 30);    %

red_raw = T.red_raw;
ir_raw  = T.ir_raw;

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
red_raw = hampel(red_raw, N, nsigma);
ir_raw  = hampel(ir_raw,  N, nsigma);

alpha_dc = 0.02;

red_dc = zeros(size(red_raw));
ir_dc  = zeros(size(ir_raw));

red_dc(1) = red_raw(1);
ir_dc(1)  = ir_raw(1);

for i = 2:length(red_raw)
    red_dc(i) = (1-alpha_dc)*red_dc(i-1) + alpha_dc*red_raw(i);
    ir_dc(i)  = (1-alpha_dc)*ir_dc(i-1)  + alpha_dc*ir_raw(i);
end

red_ac = red_raw - red_dc;
ir_ac  = ir_raw  - ir_dc;

winSpike = round(0.8 * Fs);
kSpike = 4;

red_raw = removeLocalSpike(red_raw, winSpike, kSpike);
ir_raw  = removeLocalSpike(ir_raw,  winSpike, kSpike);

red_ac = removeLocalSpike(red_ac, winSpike, kSpike);
ir_ac  = removeLocalSpike(ir_ac,  winSpike, kSpike);

red_ac = fillmissing(red_ac, 'linear');
ir_ac  = fillmissing(ir_ac,  'linear');

bp_low = 0.7; bp_high = 4;

red_ac_bp = bandpass(red_ac, [bp_low bp_high], Fs);
ir_ac_bp  = bandpass(ir_ac,  [bp_low bp_high], Fs);

%%
DC_red0 = mean(red_dc(t0_idx), 'omitnan');
DC_ir0  = mean(ir_dc(t0_idx),  'omitnan');
RAW_red0 = mean(red_raw(t0_idx), 'omitnan');
RAW_ir0 = mean(ir_raw(t0_idx), 'omitnan');

%% SpO2
W_SpO2 = round(Fs * 5);

AC_red_rms = nan(size(red_ac_bp));
AC_ir_rms  = nan(size(ir_ac_bp));

for i = W_SpO2:length(red_ac_bp)
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


%% PI 계산
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

%% MBLL (DC)
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
dHbT = dHHb + dHbO2; 

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

occlusion_start = 120;
occlusion_end = 150;

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
release_start = 180;
release_end = 210;

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
plot(f_o_ac_bpm(band_o_ac_bpm), mag_occlusion_total(band_o_ac_bpm), 'r', "LineWidth", 0.75); hold on;
plot(f_r_ac_bpm(band_r_ac_bpm), mag_release_total(band_r_ac_bpm), 'b', "LineWidth", 0.75);
title("AC FFT (occlusion, release)");
ylabel("Magnitude (normalized)"); 
xlim([30 180]);
% ylim([0 1]);
legend("occlusion", "release");

%%
% %% FFT trial -> mean [AC]
% trials = unique(trial_id);
% nTrial = length(trials);
% 
% N_occ_each = zeros(nTrial, 1);
% N_rel_each = zeros(nTrial, 1);
% 
% for i = 1:nTrial
%     tr = trials(i);
% 
%     idx_occ = (trial_id == tr) & (t_trial >= occlusion_start) & (t_trial <= occlusion_end);
%     idx_rel = (trial_id == tr) & (t_trial >= release_start) & (t_trial <= release_end);
% 
%     N_occ_each(i) = sum(idx_occ);
%     N_rel_each(i) = sum(idx_rel);
% 
% end
% 
% N_fft = min([N_occ_each; N_rel_each]);
% 
% half = floor(N_fft / 2);
% f = (0:half-1) * Fs / N_fft;
% f_bpm = f*60;
% 
% band_bpm = (f_bpm >= bp_low_bpm) & (f_bpm <= bp_high_bpm);
% 
% %%
% mag_occ_mat = nan(half, nTrial);
% mag_rel_mat = nan(half, nTrial);
% 
% for i = 1:nTrial
%     tr = trials(i);
% 
%     x_occ = red_ac_bp(idx_occ);
%     x_occ = x_occ(isfinite(x_occ));
%     x_occ = x_occ(1:N_fft);
% 
%     x_occ = x_occ - mean(x_occ, 'omitnan');
%     mag_occ = abs(x_occ(1:half)) / N_fft;
% 
%     mag_occ_mat(:, i) = mag_occ;
% 
%     x_rel = red_ac_bp(idx_rel);
%     x_rel = x_rel(isfinite(x_rel));
%     x_rel = x_rel(1:N_fft);
% 
%     x_rel = x_rel - mean(x_rel, 'omitnan');
% 
%     mag_rel = abs(x_rel(1:half)) / N_fft;
% 
%     mag_rel_mat(:, i) = mag_rel;
% end
% 
% %% 전체 기준 normalize
% max_ref = max([mag_occ_mat(:); mag_rel_mat(:)], [], 'omitnan');
% 
% mag_occ_mat_norm = mag_occ_mat / max_ref;
% mag_rel_mat_norm = mag_rel_mat / max_ref;
% 
% mag_occ_mean = mean(mag_occ_mat_norm, 2, 'omitnan');
% mag_rel_mean = mean(mag_rel_mat_norm, 2, 'omitnan');
% 
% %% FFT plot (normalize)
% figure; hold on;
% 
% plot(f_bpm(band_bpm), mag_occ_mean(band_bpm), 'r', 'LineWidth', 0.75);
% plot(f_bpm(band_bpm), mag_rel_mean(band_bpm), 'b', 'LineWidth', 0.75);
% 
% xlim([30 180]);
% title("AC FFT (occlusion / release)");

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
t = ((0:length(t_common)-1)*fs_m)/60;


%% SpO2 & StO2
spo2_mat = nan(N_common, nTrial);
sto2_mat = nan(N_common, nTrial);

for i = 1:nTrial
    tr = trials(i);
    idx = find(trial_id == tr);

    idx = idx(1:N_common);  

    spo2_mat(:,i) = SpO2_est(idx);
    sto2_mat(:,i) = StO2_est(idx);
end

spo2_mean = mean(spo2_mat, 2, 'omitnan');
spo2_std  = std(spo2_mat, 0, 2, 'omitnan');

sto2_mean = mean(sto2_mat, 2, 'omitnan');
sto2_std  = std(sto2_mat, 0, 2, 'omitnan');

figure; hold on;

fill([t fliplr(t)], ...
    [spo2_mean' + spo2_std' fliplr(spo2_mean' - spo2_std')], ...
    [1 0.8 0.8], 'EdgeColor', 'none');

fill([t fliplr(t)], ...
    [sto2_mean' + sto2_std' fliplr(sto2_mean' - sto2_std')], ...
    [0.8 0.8 1], 'EdgeColor', 'none');

plot(t, spo2_mean, 'r', 'LineWidth', 1.38);
plot(t, sto2_mean, 'b', 'LineWidth', 1.38);


% drawPhase(cycle);
% grid on;
xlim([0 3.5]);
xlabel("Time (min)");
ylabel("SpO2 / StO2 (%)");
ylim([0 100]);
title("SpO2 & StO2");

%%
% trials = unique(trial_id);
% 
% spo2_trial1 = SpO2_est(trial_id == trials(1));
% spo2_trial2 = SpO2_est(trial_id == trials(2));
% spo2_trial3 = SpO2_est(trial_id == trials(3));
% 
% sto2_trial1 = StO2_est(trial_id == trials(1));
% sto2_trial2 = StO2_est(trial_id == trials(2));
% sto2_trial3 = StO2_est(trial_id == trials(3));
% 
% N_common = min([
%     length(spo2_trial1), length(spo2_trial2), length(spo2_trial3), ...
%     length(sto2_trial1), length(sto2_trial2), length(sto2_trial3)
% ]);
% 
% SpO2_mat = [
%     spo2_trial1(1:N_common), ...
%     spo2_trial2(1:N_common), ...
%     spo2_trial3(1:N_common)
% ];
% 
% StO2_mat = [
%     sto2_trial1(1:N_common), ...
%     sto2_trial2(1:N_common), ...
%     sto2_trial3(1:N_common)
% ];
% 
% valid_idx = all(isfinite(SpO2_mat), 2) & all(isfinite(StO2_mat), 2);
% 
% SpO2_mat = SpO2_mat(valid_idx, :);
% StO2_mat = StO2_mat(valid_idx, :);
% 
% SpO2_mean = mean(SpO2_mat, 2);
% StO2_mean = mean(StO2_mat, 2);

% save("cuff_occlusion_trial_spo2_sto2.mat", ...
%      "SpO2_mat", "StO2_mat");


%% PI IR / RED
PI_ir_mat  = nan(N_common, nTrial);
PI_red_mat = nan(N_common, nTrial);

for i = 1:nTrial
    tr = trials(i);
    idx = find(trial_id == tr);

    idx = idx(1:N_common);  

    PI_ir_mat(:, i) = PI_IR(idx);
    PI_red_mat(:, i) = PI_RED(idx);
end

PI_IR_mean = mean(PI_ir_mat, 2, 'omitnan');
PI_RED_mean = mean(PI_red_mat, 2, 'omitnan');

PI_IR_std = std(PI_ir_mat, 0, 2, 'omitnan');
PI_RED_std = std(PI_red_mat, 0, 2, 'omitnan');


% baseline 시작점 0으로 수정
PI_IR_base = PI_IR_mean(1);
PI_IR_mean = PI_IR_mean - PI_IR_base;

PI_RED_base = PI_RED_mean(1);
PI_RED_mean = PI_RED_mean - PI_RED_base;

%% PI (IR)
figure; hold on;

fill([t fliplr(t)], ...
     [PI_IR_mean' + PI_IR_std' fliplr(PI_IR_mean' - PI_IR_std')], ...
     [0.8 1 0.8], 'EdgeColor', 'none');

plot(t, PI_IR_mean, 'g', 'LineWidth', 1.38);

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

fill([t fliplr(t)], ...
     [PI_RED_mean' + PI_RED_std' fliplr(PI_RED_mean' - PI_RED_std')], ...
     [1 0.8 0.8], 'EdgeColor', 'none');

plot(t, PI_RED_mean, 'r', 'LineWidth', 1.38);

xlim([0 3.5]);

% drawPhase(cycle);
% grid on;
xlabel("Time (min)");
ylabel("PI (%)");
title("PI (RED)");



%% HbO2, HHb, tHb [DC]
Hb_mat  = nan(N_common, nTrial);
HbO2_mat = nan(N_common, nTrial);

for i = 1:nTrial
    tr = trials(i);
    idx = find(trial_id == tr);

    idx = idx(1:N_common);

    Hb_mat(:, i) = dHHb(idx);
    HbO2_mat(:, i) = dHbO2(idx);
    
end

HHb_mean  = mean(Hb_mat, 2, 'omitnan');
HbO2_mean = mean(HbO2_mat, 2, 'omitnan');

HHb_std  = std(Hb_mat, 0, 2, 'omitnan');
HbO2_std = std(HbO2_mat, 0, 2, 'omitnan');

figure; hold on;

fill([t fliplr(t)], ...
     [HHb_mean' + HHb_std' fliplr(HHb_mean' - HHb_std')], ...
     [0.8 0.8 1], 'EdgeColor', 'none');

fill([t fliplr(t)], ...
     [HbO2_mean' + HbO2_std' fliplr(HbO2_mean' - HbO2_std')], ...
     [1 0.8 0.8], 'EdgeColor', 'none');

% fill([t_common fliplr(t_common)], ...
%      [tHb_mean' + tHb_std' fliplr(tHb_mean' - tHb_std')], ...
%      [1 1 0], 'EdgeColor', 'none', 'FaceAlpha', 0.3);

plot(t, HHb_mean, 'b', 'LineWidth', 1.25);
plot(t, HbO2_mean, 'r', 'LineWidth', 1.25);
% plot(t_common, tHb_mean, 'Color', [1 0.8 0], 'LineWidth', 2);

xlim([0 3.5]);

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


%% waveform plot
occ_start_point = 130;
occ_end_point = 135;

target_trial = 1;

mask_wave1 = ...
    (trial_id == target_trial) & ...
    (t_trial >= occ_start_point) & ...
    (t_trial <= occ_end_point);


figure; %hold on;
plot(t_trial(mask_wave1), red_ac_bp(mask_wave1), 'r', "LineWidth", 1.38);
ylim([-400 400]);


rel_start_point = 190;
rel_end_point = 195;

mask_wave2 = ...
    (trial_id == target_trial) & ...
    (t_trial >= rel_start_point) & ...
    (t_trial <= rel_end_point);

figure;
plot(t_trial(mask_wave2), red_ac_bp(mask_wave2), 'b', 'LineWidth', 1.38);

%%
occ_start_point = 120;
occ_end_point = 150;

target_trial = 1;

mask_wave1 = ...
    (trial_id == target_trial) & ...
    (t_trial >= occ_start_point) & ...
    (t_trial <= occ_end_point);


figure; %hold on;
plot(t_trial(mask_wave1), red_ac(mask_wave1), 'r', "LineWidth", 1.38);
ylim([-400 400]);


rel_start_point = 180;
rel_end_point = 210;

mask_wave2 = ...
    (trial_id == target_trial) & ...
    (t_trial >= rel_start_point) & ...
    (t_trial <= rel_end_point);

figure;
plot(t_trial(mask_wave2), red_ac(mask_wave2), 'b', 'LineWidth', 1.38);

%% baseline red_ac / red_ac_bp mat file 저장
base_start_point = 0;
base_end_point = 30;

mask_wave3 = ...
    (trial_id == target_trial) & ...
    (t_trial >= base_start_point) & ...
    (t_trial <= base_end_point);

red_ac_base = red_ac(mask_wave3);
red_ac_bp_base = red_ac_bp(mask_wave3);

save("red_ac_waveform.mat", "red_ac_base");
save("red_ac_bandpass_waveform.mat", "red_ac_bp_base");
