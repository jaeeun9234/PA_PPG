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
DC_red0_1 = mean(red_dc1(t0_idx), 'omitnan');
DC_ir0_1  = mean(ir_dc1(t0_idx),  'omitnan');
RAW_red0_1 = mean(red_raw1(t0_idx), 'omitnan');
RAW_ir0_1 = mean(ir_raw1(t0_idx), 'omitnan');

DC_red0_2 = mean(red_dc2(t0_idx), 'omitnan');
DC_ir0_2  = mean(ir_dc2(t0_idx),  'omitnan');
RAW_red0_2 = mean(red_raw2(t0_idx), 'omitnan');
RAW_ir0_2 = mean(ir_raw2(t0_idx), 'omitnan');

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
% SpO2_est_1(SpO2_est_1 > 100) = 100;
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
% SpO2_est_2(SpO2_est_2 > 100) = 100;
SpO2_est_2(SpO2_est_2 < 0) = 0;

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
dHbT_1  = dHbO2_1 + dHHb_1;

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
dHbT_2  = dHbO2_2 + dHHb_2;


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

%% ========================================================================================================== %%
% %% mean ± std plot
% trials = unique(trial_id);
% t_common = linspace(min(t_trial), max(t_trial), 1000);

%% R value mean ± std without interpolation

trials = unique(trial_id);
nTrial = length(trials);

% trial별 sample 개수 확인
N_each = zeros(nTrial, 1);

for i = 1:nTrial
    tr = trials(i);
    N_each(i) = sum(trial_id == tr);
end

% 모든 trial에서 공통으로 쓸 수 있는 최소 sample 수
N_common = min(N_each);

R1_mat = nan(N_common, nTrial);
R2_mat = nan(N_common, nTrial);

for i = 1:nTrial
    tr = trials(i);
    tr_mask = trial_id == tr;

    R1_tr = R_s_1(tr_mask);
    R2_tr = R_s_2(tr_mask);

    % 앞에서부터 N_common개만 사용
    R1_mat(:, i) = R1_tr(1:N_common);
    R2_mat(:, i) = R2_tr(1:N_common);
end

R1_mean = mean(R1_mat, 2, 'omitnan');
R1_std  = std(R1_mat, 0, 2, 'omitnan');

R2_mean = mean(R2_mat, 2, 'omitnan');
R2_std  = std(R2_mat, 0, 2, 'omitnan');

% 시간축도 공통 길이만큼만 사용
t_common = (0:N_common-1)' / Fs;

save("R_with_and_wo_cuff.mat", ...
    "t_common", ...
    "R1_mean", "R1_std", ...
    "R2_mean", "R2_std", ...
    "R1_mat", "R2_mat");


%% spo2 wo cuff (clamping on / off)
trials = unique(trial_id);
nTrial = length(trials);

N_each = zeros(nTrial, 1);

for i = 1:nTrial
    N_each(i) = sum(trial_id == trials(i));
end

N_common = min(N_each);
t_one = (0:N_common - 1)' / Fs;

t_concat = [];
spo2_concat = [];

trial_start_t = zeros(nTrial, 1);
for i = 1:nTrial
    tr = trials(i);
    tr_mask = (trial_id == tr);

    spo2_tr = SpO2_est_1(tr_mask);
    spo2_tr = spo2_tr(1:N_common);

    t_tr_aligned = t_one + (i-1)*t_one(end);

    trial_start_t(i) = t_tr_aligned(1);

    t_concat = [t_concat; t_tr_aligned];
    spo2_concat = [spo2_concat; spo2_tr];
end

figure; hold on; grid on;

plot(t_concat, spo2_concat, 'LineWidth', 1.38);

for i = 1:nTrial
    xline(trial_start_t(i), '--k');
end

xlabel("Time (s)");
ylabel("SpO2 (%)");
title("SpO2 (wo cuff)");

%% spo2 with cuff (clamping on / off)
trials = unique(trial_id);
nTrial = length(trials);

N_each = zeros(nTrial, 1);

for i = 1:nTrial
    N_each(i) = sum(trial_id == trials(i));
end

N_common = min(N_each);
t_one = (0:N_common -1)' / Fs;

t_concat = [];
spo2_concat = [];
trial_start_t = zeros(nTrial, 1);

for i = 1:nTrial
    tr = trials(i);
    tr_mask = (trial_id == tr);

    spo2_tr = SpO2_est_2(tr_mask);
    spo2_tr = spo2_tr(1:N_common);

    t_tr_aligned = t_one + (i-1)*t_one(end);

    trial_start_t(i) = t_tr_aligned(1);

    t_concat = [t_concat; t_tr_aligned];
    spo2_concat = [spo2_concat; spo2_tr];
end

figure; hold on; grid on;

plot(t_concat, spo2_concat, 'LineWidth', 1.38);

for i = 1:nTrial
    xline(trial_start_t(i), '--k');
end

xlabel("Time (s)");
ylabel("SpO2 (%)");
title("SpO2 (with cuff)");

%% mean \pm std clamping on / off
trials = unique(trial_id);
nTrial = length(trials);

N_each = zeros(nTrial, 1);

for i = 1:nTrial
    N_each(i) = sum(trial_id == trials(i));
end

N_common = min(N_each);

SpO2_mat = nan(N_common, nTrial);

for i = 1:nTrial
    tr = trials(i);
    tr_mask = trial_id == tr;

    spo2_tr = SpO2_est_2(tr_mask);   % Sensor1 기준
    SpO2_mat(:, i) = spo2_tr(1:N_common);
end

SpO2_mean = mean(SpO2_mat, 2, 'omitnan');
SpO2_std  = std(SpO2_mat, 0, 2, 'omitnan');

t_common = (0:N_common-1)' / Fs;

figure; hold on; grid on;

fill([t_common; flipud(t_common)], ...
     [SpO2_mean + SpO2_std; flipud(SpO2_mean - SpO2_std)], ...
     [0.8 0.8 0.8], ...
     'EdgeColor', 'none', ...
     'FaceAlpha', 0.4);

plot(t_common, SpO2_mean, 'k', 'LineWidth', 1.8);

xlabel('Time (s)');
ylabel('SpO2 (%)');
title('SpO2 (with cuff)');
