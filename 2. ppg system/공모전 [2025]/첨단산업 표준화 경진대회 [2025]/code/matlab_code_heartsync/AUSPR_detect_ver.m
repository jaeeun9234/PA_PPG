%% ============================
%  HeartSync: CSV vs MATLAB(calc)
%  - Python 정의와 동일하게 재계산하여 비교/플롯
%  - AUSP: rectified area ratio (R/L), trapz(y)*DT
%  - PWTT: |peakR - peakL| * 1000/FS (옵션 토글)
%  ============================

%% ---- 설정 ----
raw_path   = 'C:\Users\user\Desktop\ppg_data\1\raw_stream_1.csv';
beats_path = 'C:\Users\user\Desktop\ppg_data\1\beats_metrics_1.csv';

FS  = 50;           % Python FS_HZ와 동일
DT  = 1/FS;
epsA = 1e-6;        % 분모 가드
PWTT_mode = "peak"; % "peak" 또는 "foot"
PWTT_abs  = true;   % true면 절대값

%% ---- 로드 (열 이름 자동 매핑 + 숫자 강제 변환) ----
normalize = @(s) regexprep(lower(strtrim(string(s))), '\s+', '');

% 강건한 컬럼 선택 함수
pick_numeric = @(T, cands) local_pick_numeric(T, cands);

optsB = detectImportOptions(beats_path);
optsB = setvaropts(optsB, 'TreatAsMissing', {'','NA','NaN','nan'});
beats = readtable(beats_path, optsB);

optsR = detectImportOptions(raw_path);
raw   = readtable(raw_path, optsR);

% 신호/인덱스
t  = pick_numeric(raw,   {'elapsed_s','time_s','t'});
yL = pick_numeric(raw,   {'filtL','yl','left_filt'});
yR = pick_numeric(raw,   {'filtR','yr','right_filt'});

fL = pick_numeric(beats, {'footL_idx','footL','foot_left_idx'});
pL = pick_numeric(beats, {'peakL_idx','peakL','peak_left_idx'});
fR = pick_numeric(beats, {'footR_idx','footR','foot_right_idx'});
pR = pick_numeric(beats, {'peakR_idx','peakR','peak_right_idx'});

% CSV 지표(있으면 사용)
AUSPR_csv  = pick_numeric(beats, {'AUSPR','ausp_ratio','auspratio'});
DTD_ms_csv = pick_numeric(beats, {'DeltaTD_ms','pwtT_ms','dtd_ms'});

%% ---- 유효 비트만 선택 ----
N  = height(raw);
ok = ~isnan(fL)&~isnan(pL)&~isnan(fR)&~isnan(pR) & ...
     fL>=1&pL>=1&fR>=1&pR>=1 & fL<=N&pL<=N&fR<=N&pR<=N & ...
     pL>fL & pR>fR;

fL = fL(ok); pL = pL(ok); fR = fR(ok); pR = pR(ok);
AUSPR_csv  = AUSPR_csv(ok);
DTD_ms_csv = DTD_ms_csv(ok);

bt = mean([t(fL) t(fR)], 2, 'omitnan');  % beat time(참고용)

%% ---- Python 동일 정의로 재계산 ----
% (1) PWTT
switch lower(PWTT_mode)
    case 'foot'
        dIdx = (fR - fL);
    otherwise % 'peak'
        dIdx = (pR - pL);
end
PWTT_ms_mat = dIdx * 1000/FS;
if PWTT_abs, PWTT_ms_mat = abs(PWTT_ms_mat); end

% (2) AUSP: rectified area ratio (R/L), trapz(y)*DT
nB   = numel(fL);
A_L  = nan(nB,1); A_R = nan(nB,1);
for i = 1:nB
    segL = yL(fL(i):pL(i)); segL(segL<0) = 0;
    segR = yR(fR(i):pR(i)); segR(segR<0) = 0;
    A_L(i) = trapz(segL) * DT;  % np.trapz(y, dx=DT)와 동일
    A_R(i) = trapz(segR) * DT;
end
AUSPR_mat = A_R ./ max(A_L, epsA);
AUSPR_mat(~isfinite(AUSPR_mat)) = NaN;

% (3) HSI (둘 다로 계산)
HSI_mat = abs(AUSPR_mat - 1)./0.05 + max(0, PWTT_ms_mat - 20)./12;
HSI_csv = abs(AUSPR_csv - 1)./0.05 + max(0, DTD_ms_csv - 20)./12;

%% ---- 일치성 리포트 ----
va = ~isnan(AUSPR_mat) & ~isnan(AUSPR_csv);
vd = ~isnan(DTD_ms_csv);
fprintf('AUSPR corr (MAT vs CSV): %.4f (n=%d)\n', corr(AUSPR_mat(va), AUSPR_csv(va)), sum(va));
fprintf('PWTT  MAE  (MAT vs CSV): %.3f ms (n=%d)\n', mean(abs(PWTT_ms_mat(vd) - DTD_ms_csv(vd)),'omitnan'), sum(vd));

%% ---- 플롯: MAT(calc)=라인, CSV=점 ----
figure('Position',[180 120 1000 780])

subplot(3,1,1)
plot(bt, PWTT_ms_mat, '-o', 'LineWidth', 1.0, 'MarkerSize', 4); hold on
if any(vd), plot(bt(vd), DTD_ms_csv(vd), '.', 'MarkerSize', 12); end
yline(20,'--','20 ms'); grid on; box on
ylabel('PWTT (ms)'); title('\DeltaTD: MAT(calc)  vs  CSV')

subplot(3,1,2)
plot(bt, AUSPR_mat, '-o', 'LineWidth', 1.0, 'MarkerSize', 4); hold on
if any(va), plot(bt(va), AUSPR_csv(va), '.', 'MarkerSize', 12); end
yline(1,'-'); yline(0.95,'--'); yline(1.05,'--'); grid on; box on
ylabel('AUSPR'); title('AUSP (area ratio): MAT(calc)  vs  CSV')

subplot(3,1,3)
plot(bt, HSI_mat, '-o', 'LineWidth', 1.0, 'MarkerSize', 4); hold on
vc = ~isnan(HSI_csv);
if any(vc), plot(bt(vc), HSI_csv(vc), '.', 'MarkerSize', 12); end
grid on; box on
xlabel('Elapsed time (s)'); ylabel('HSI')
title('HSI: MAT(calc)  vs  CSV (recomputed from CSV fields)')

%% ---- 로컬 함수 ----
function v = local_pick_numeric(T, candidates)
    names = string(T.Properties.VariableNames);
    normNames = regexprep(lower(strtrim(names)), '\s+', '');
    v = []; found = '';
    for c = string(candidates)
        key = regexprep(lower(strtrim(c)), '\s+', '');
        idx = find(strcmp(normNames, key), 1);
        if isempty(idx), idx = find(contains(normNames, key), 1); end
        if ~isempty(idx)
            col = T.(names(idx));
            if iscell(col) || isstring(col) || ischar(col)
                v = str2double(string(col));   % "12.3"→12.3, ""→NaN
            else
                v = double(col);
            end
            found = names(idx);
            fprintf('Mapped "%s" -> "%s"\n', c, found);
            break
        end
    end
    if isempty(v)
        % 못 찾으면 NaN 벡터 반환
        v = nan(height(T),1);
        warning('No column matched for: %s', strjoin(string(candidates), ', '));
    end
end
