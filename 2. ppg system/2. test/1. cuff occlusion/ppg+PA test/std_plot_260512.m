%% plot_ppg_csv.m
clear; clc; %close all;

%% ===== 0) 파일 지정 =====
fname = "data_20260416_1307.csv";  

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
ir_raw  = T.ir_raw;

%spo2 = T.spo2;

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

%%
N = 20; nsigma = 2.5;
red_raw_f = hampel(red_raw, N, nsigma);
ir_raw_f  = hampel(ir_raw,  N, nsigma);

alpha_dc = 0.01;    % LPF cutoff = 0.05Hz

red_dc = zeros(size(red_raw_f));
ir_dc  = zeros(size(ir_raw_f));

red_dc(1) = red_raw_f(1);
ir_dc(1)  = ir_raw_f(1);

for i = 2:length(red_raw_f)
    red_dc(i) = (1-alpha_dc)*red_dc(i-1) + alpha_dc*red_raw_f(i);
    ir_dc(i)  = (1-alpha_dc)*ir_dc(i-1)  + alpha_dc*ir_raw_f(i);
end

% fc_dc = 0.3;
% red_dc = lowpass(red_raw_f, fc_dc, Fs);
% ir_dc = lowpass(ir_raw_f, fc_dc, Fs);

red_ac = red_raw_f - red_dc;
ir_ac  = ir_raw_f  - ir_dc;
% 심박 대역만 남김
% 0.7~5 Hz ≈ 42~300 BPM
bp_low = 0.7;
bp_high = 4.0;

red_ac_bp = bandpass(red_ac, [bp_low bp_high], Fs);
ir_ac_bp  = bandpass(ir_ac,  [bp_low bp_high], Fs);


%% spike 추가 제거용 
winSpike = round(0.8 * Fs);   % 0.5~1.0초 정도, winSpike = 20
kSpike   = 4;                 % 작을수록 많이 제거

red_raw = removeLocalSpike(red_raw, winSpike, kSpike);
ir_raw  = removeLocalSpike(ir_raw,  winSpike, kSpike);

red_ac  = removeLocalSpike(red_ac_bp,  winSpike, kSpike);
ir_ac   = removeLocalSpike(ir_ac_bp,   winSpike, kSpike);

%%
DC_red0 = mean(red_dc(t0_idx), 'omitnan');
DC_ir0 = mean(ir_dc(t0_idx), 'omitnan');
RAW_red0 = mean(red_raw(t0_idx), 'omitnan');
RAW_ir0 = mean(ir_raw(t0_idx), 'omitnan');

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


% %% ===== Peak-based AC amplitude =====
% 
% % 최소 peak 간격: 심박 기준
% minPeakDist = round(0.4 * Fs);   % 0.4초 = 최대 약 150 BPM
% minProm_IR  = std(ir_ac, 'omitnan') * 0.3;
% minProm_RED = std(red_ac, 'omitnan') * 0.3;
% 
% % IR peak / trough detection
% [pk_ir, loc_pk_ir] = findpeaks(ir_ac, ...
%     'MinPeakDistance', minPeakDist, ...
%     'MinPeakProminence', minProm_IR);
% 
% [tr_ir_neg, loc_tr_ir] = findpeaks(-ir_ac, ...
%     'MinPeakDistance', minPeakDist, ...
%     'MinPeakProminence', minProm_IR);
% 
% tr_ir = -tr_ir_neg;
% 
% % RED peak / trough detection
% [pk_red, loc_pk_red] = findpeaks(red_ac, ...
%     'MinPeakDistance', minPeakDist, ...
%     'MinPeakProminence', minProm_RED);
% 
% [tr_red_neg, loc_tr_red] = findpeaks(-red_ac, ...
%     'MinPeakDistance', minPeakDist, ...
%     'MinPeakProminence', minProm_RED);
% 
% tr_red = -tr_red_neg;
% 
% % ===== IR pulse amplitude =====
% AC_IR_pulse = nan(size(pk_ir));
% t_IR_pulse  = nan(size(pk_ir));
% 
% for k = 1:length(loc_pk_ir)
%     prev_tr_idx = find(loc_tr_ir < loc_pk_ir(k), 1, 'last');
% 
%     if isempty(prev_tr_idx)
%         continue;
%     end
% 
%     AC_IR_pulse(k) = pk_ir(k) - tr_ir(prev_tr_idx);
%     t_IR_pulse(k)  = t(loc_pk_ir(k));
% end
% 
% % ===== RED pulse amplitude =====
% AC_RED_pulse = nan(size(pk_red));
% t_RED_pulse  = nan(size(pk_red));
% 
% for k = 1:length(loc_pk_red)
%     prev_tr_idx = find(loc_tr_red < loc_pk_red(k), 1, 'last');
% 
%     if isempty(prev_tr_idx)
%         continue;
%     end
% 
%     AC_RED_pulse(k) = pk_red(k) - tr_red(prev_tr_idx);
%     t_RED_pulse(k)  = t(loc_pk_red(k));
% end
% 
% % NaN 제거 후 interpolation
% 
% valid_ir = isfinite(t_IR_pulse) & isfinite(AC_IR_pulse);
% valid_red = isfinite(t_RED_pulse) & isfinite(AC_RED_pulse);
% 
% AC_IR_amp = interp1(t_IR_pulse(valid_ir), ...
%                     AC_IR_pulse(valid_ir), ...
%                     t, 'linear', NaN);
% 
% AC_RED_amp = interp1(t_RED_pulse(valid_red), ...
%                      AC_RED_pulse(valid_red), ...
%                      t, 'linear', NaN);
% 
% % DC
% DC_IR  = movmean(ir_dc, W, 'omitnan');
% DC_RED = movmean(red_dc, W, 'omitnan');
% 
% % PI
% PI_IR  = 100 * (AC_IR_amp  ./ DC_IR);
% PI_RED = 100 * (AC_RED_amp ./ DC_RED);


%% ===== Sliding-window AC amplitude =====

% AC amplitude window
% 심박 1~2 beat 정도 포함되도록 설정
W_ac = round(Fs * 5);   % 2초 window, 필요하면 1.5~3초 조절

% IR / RED AC amplitude
AC_IR_amp = movmax(ir_ac, W_ac, 'omitnan') - movmin(ir_ac, W_ac, 'omitnan');
AC_RED_amp = movmax(red_ac, W_ac, 'omitnan') - movmin(red_ac, W_ac, 'omitnan');

% 너무 튀는 amplitude 완화
AC_IR_amp = movmedian(AC_IR_amp, round(Fs * 1), 'omitnan');
AC_RED_amp = movmedian(AC_RED_amp, round(Fs * 1), 'omitnan');

AC_IR_amp = movmean(AC_IR_amp, round(Fs * 1), 'omitnan');
AC_RED_amp = movmean(AC_RED_amp, round(Fs * 1), 'omitnan');

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

dA_660 = -log10(red_dc ./ DC_red0);
dA_880 = -log10(ir_dc ./ DC_ir0);

bad = ~isfinite(dA_660) | ~isfinite(dA_880);
dA_660(bad) = NaN;
dA_880(bad) = NaN;

dA_660 = fillmissing(dA_660, "linear", "EndValues","nearest");
dA_880 = fillmissing(dA_880, "linear", "EndValues","nearest");


% d*DPF = 1
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

%% ===== SpO2: arduino 조건 비슷하게 수정한 ver =====
rmsWin = round(Fs * 5);

AC_red_rms = sqrt(movmean(red_ac.^2, rmsWin, 'omitnan'));
AC_ir_rms  = sqrt(movmean(ir_ac.^2,  rmsWin, 'omitnan'));

DC_red = movmean(red_dc, rmsWin, 'omitnan');
DC_ir  = movmean(ir_dc,  rmsWin, 'omitnan');


% ratio
ratio_red = AC_red_rms ./ DC_red;
ratio_ir  = AC_ir_rms  ./ DC_ir;

eps_ratio = 1e-6;

R = ratio_red ./ max(ratio_ir, eps_ratio);

MIN_RATIO = 0.0001;
MAX_RATIO  = 0.10;
MIN_AC_RMS = 4.0;
R_MIN = 0.3;
R_MAX = 2.0;

R = ratio_red ./ ratio_ir;

valid = isfinite(R) & ...
        isfinite(ratio_red) & isfinite(ratio_ir) & ...
        AC_red_rms >= MIN_AC_RMS & AC_ir_rms >= MIN_AC_RMS & ...
        ratio_red >= MIN_RATIO & ratio_red <= MAX_RATIO & ...
        ratio_ir  >= MIN_RATIO & ratio_ir  <= MAX_RATIO & ...
        R >= R_MIN & R <= R_MAX;

R(~valid) = NaN;

R = filloutliers(R, NaN, 'movmedian', round(Fs*5), ...
    'ThresholdFactor', 2.5);

R = fillmissing(R, 'linear', ...
    'MaxGap', round(Fs*2), ...
    'EndValues', 'nearest');

R = movmedian(R, round(Fs*7), 'omitnan');
R = movmean(R, round(Fs*3), 'omitnan');

SpO2_est = 110 - 25 * R;
SpO2_est = min(max(SpO2_est, 0), 100);
SpO2_est = movmean(SpO2_est, round(Fs*3), 'omitnan');


%%
% reference baseline values
StO2_0 = 0.70;   % assumed baseline tissue saturation
tHb_0  = 7e-5;    % arbitrary reference total Hb scale
HbO2_0 = StO2_0*tHb_0;

sto2_ref = (HbO2_0 + dHbO2) ./ (tHb_0 + dHbT);
sto2_ref = sto2_ref*100;


%% 
trials = unique(trial_id);
t_common = linspace(min(t_trial), max(t_trial), 1000);
mask2 = t_common >= 5;


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

plot(t_common, spo2_mean, 'b', 'LineWidth', 1.38);
plot(t_common, sto2_mean, 'r', 'LineWidth', 1.38);

xlim([0 210])

% set(gca, 'Position', [0 0 1 1])
% set(gcf, 'Units', 'centimeters')
% set(gcf, 'Position', [5 5 9.52 5])

drawPhase(cycle);
grid on;
xlabel("Time (s)"); ylabel("spo2 & sto2"); ylim([0 100]); title("spo2 & sto2"); 
legend("SpO2", "StO2", "Location", "best");


%% PI (IR)
PI_mat_ir = nan(length(t_common), length(trials));

for i = 1:length(trials)
    tr = trials(i);

    tr_mask = (trial_id == tr);

    t_tr = t_trial(tr_mask);
    PI_IR_tr = PI_IR(tr_mask);

    % % NaN 제거
    % valid = isfinite(t_tr) & isfinite(PI_IR_tr);
    % t_tr = t_tr(valid);
    % PI_IR_tr = PI_IR_tr(valid);
    % 
    % [t_tr, idx] = unique(t_tr, 'stable');
    % PI_IR_tr = PI_IR_tr(idx);

    PI_mat_ir(:, i) = interp1(t_tr, PI_IR_tr, t_common, 'linear', NaN);
end

PI_IR_mean = mean(PI_mat_ir, 2, 'omitnan');
PI_IR_std  = std(PI_mat_ir, 0, 2, 'omitnan');

figure; hold on;

x = t_common(:);
m = PI_IR_mean(:);
s = PI_IR_std(:);

upper = m + s;
lower = m - s;

valid = isfinite(x) & isfinite(upper) & isfinite(lower);

xv = x(valid);
uv = upper(valid);
lv = lower(valid);
mv = m(valid);

fill([xv; flipud(xv)], ...
     [uv; flipud(lv)], ...
     [0.8 0.8 1], ...
     'EdgeColor', 'none', ...
     'FaceAlpha', 0.6);

plot(xv, mv, 'b', 'LineWidth', 1.38);

% xlim([0 210]);

% set(gca, 'Position', [0 0 1 1])
% set(gcf, 'Units', 'centimeters')
% set(gcf, 'Position', [5 5 9.52 4.8])


grid on;
xlabel("Time (s)");
ylabel("PI");
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


% figure; hold on;
% 
% fill([t_common fliplr(t_common)], ...
%      [PI_RED_mean'+PI_RED_std' fliplr(PI_RED_mean'-PI_RED_std')], ...
%      [0.8 0.8 1], 'EdgeColor', 'none');
% plot(t_common, PI_RED_mean, 'b', 'LineWidth', 1.38);
% 
% xlim([0 210]);
% 
% % set(gca, 'Position', [0 0 1 1])
% % set(gcf, 'Units', 'centimeters')
% % set(gcf, 'Position', [5 5 9.52 4.9])
% 
% drawPhase(cycle);
% grid on; 
% xlabel("Time (s)"); ylabel("PI"); title("PI (RED)");

figure; hold on;

x = t_common(:);
m2 = PI_RED_mean(:);
s2 = PI_RED_std(:);

upper = m2 + s2;
lower = m2 - s2;

valid = isfinite(x) & isfinite(upper) & isfinite(lower);

xv = x(valid);
uv = upper(valid);
lv = lower(valid);
mv = m2(valid);

fill([xv; flipud(xv)], ...
     [uv; flipud(lv)], ...
     [0.8 0.8 1], ...
     'EdgeColor', 'none', ...
     'FaceAlpha', 0.6);

plot(xv, mv, 'b', 'LineWidth', 1.38);

xlim([0 210]);

% set(gca, 'Position', [0 0 1 1])
% set(gcf, 'Units', 'centimeters')
% set(gcf, 'Position', [5 5 9.52 4.8])

grid on;
xlabel("Time (s)");
ylabel("PI");
title("PI (RED)");


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

plot(t_common, HHb_dc_mean, 'b', 'LineWidth', 1.38);
plot(t_common, HbO2_dc_mean, 'r', 'LineWidth', 1.38);
plot(t_common, tHb_dc_mean, 'Color', [1 0.8 0], 'LineWidth', 1.38);

xlim([0 210]);

% set(gca, 'Position', [0 0 1 1])
% set(gcf, 'Units', 'centimeters')
% set(gcf, 'Position', [5 5 9.52 4.9])

drawPhase(cycle);
grid on; 
xlabel("Time (s)"); title("HbO2, HHb, tHb [DC]");
legend("HHb", "HbO2", "tHb", "Location", "best"); 
