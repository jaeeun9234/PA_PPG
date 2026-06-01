%% === 0) 옵션: raw_stream이 없어도 동작하지만,
% beat 시간(bt)이 beats 파일에 없으면 raw_stream으로 보완해서 시간축을 만들 수 있게 해둠.
rawExists = isfile('C:\Users\user\Documents\카카오톡 받은 파일\heartsync_amp_ratio_norm_final\heartsync_amp_ratio_norm_final\heartsync_logs\normal\raw_stream_normal.csv');
if rawExists
    raw = readtable('C:\Users\user\Documents\카카오톡 받은 파일\heartsync_amp_ratio_norm_final\heartsync_amp_ratio_norm_final\heartsync_logs\normal\raw_stream_normal.csv');   % elapsed_s, filtL, filtR, ...
    t_raw = raw.elapsed_s;
end

%% === 1) beats_metrics 불러오기 ===
beats = readtable('C:\Users\user\Documents\카카오톡 받은 파일\heartsync_amp_ratio_norm_final\heartsync_amp_ratio_norm_final\heartsync_logs\normal\beats_metrics_normal.csv');

% --- 유틸: 열 찾기 (대소문자 무시 + 여러 별칭)
findCol = @(aliases) ...
    find(ismember(lower(string(beats.Properties.VariableNames)), lower(string(aliases))), 1, 'first');

getVar = @(aliases) ...
    beats{:, beats.Properties.VariableNames{findCol(aliases)}};

% --- beat 시간(초) 열 찾기
bt_idx = findCol({'beat_time_s','beat_ts_s','time_s','t_s','ts_s','elapsed_s','t','ts'});
if ~isempty(bt_idx)
    bt = beats{:, bt_idx};
else
    % beats 안에 시간이 없으면 foot 인덱스로 근사치 생성 (필요 시만 사용)
    if rawExists && ~isempty(findCol({'footL_idx'})) && ~isempty(findCol({'footR_idx'}))
        fL = getVar({'footL_idx'});
        fR = getVar({'footR_idx'});
        N  = numel(t_raw);
        ok = ~isnan(fL) & ~isnan(fR) & fL>=1 & fR>=1 & fL<=N & fR<=N;
        bt = mean([t_raw(fL(ok)) t_raw(fR(ok))], 2, 'omitnan');
        % beats 행 수와 맞추기 (ok 아닌 행은 NaN)
        tmp = nan(height(beats),1); tmp(ok) = bt; bt = tmp;
    else
        error('beats_metrics.csv에 beat 시간 열이 없고, 보완 가능한 인덱스/raw_stream도 없습니다.');
    end
end

% --- PWTT(ΔTD) 찾기 (단위: ms 가정)
pwtt_col = findCol({'PWTT_ms','DeltaTD_ms','DT_ms','PAD_ms','PWTT','DeltaTD','DT','PAD'});
if isempty(pwtt_col), error('PWTT/DeltaTD/PAD 계열 열을 beats에서 찾지 못했습니다.'); end
PWTT_ms = beats{:, pwtt_col};

% --- AUSP(AUSPR) 찾기
ausp_col = findCol({'AUSP','AUSPR','SUTR_over_SUTL','AUSPratio'});
if isempty(ausp_col), error('AUSP/AUSPR 열을 beats에서 찾지 못했습니다.'); end
AUSP = beats{:, ausp_col};

% --- HSI 찾기
hsi_col = findCol({'HSI','HSI_score','risk_HSI'});
if isempty(hsi_col), error('HSI 열을 beats에서 찾지 못했습니다.'); end
HSI = beats{:, hsi_col};

%% === 2) 플롯: beat-wise Metrics (별도 Figure) ===
figure('Name','Beat-wise Metrics from beats_metrics.csv','Position',[200 200 1000 760]);

% (a) PWTT
subplot(3,1,1);
plot(bt, PWTT_ms, '-o', 'LineWidth', 1.1, 'MarkerSize', 4); hold on;
xlabel('Elapsed time (s)'); ylabel('PWTT (ms)');
title('PWTT');
%xlim([0 140]); xticks(0:20:140);
ylim([0 80]); yticks(0:20:80);
grid on; box on;

% (b) AUSP
subplot(3,1,2);
plot(bt, AUSP, '-o', 'LineWidth', 1.1, 'MarkerSize', 4); hold on;
xlabel('Elapsed time (s)'); ylabel('AUSPR (SUT_R / SUT_L)');
title('AUSPR');
%xlim([0 140]); xticks(0:20:140);
ylim([0.4 1.8]); yticks(0.4:0.2:1.8);
grid on; box on;

% (c) HSI
subplot(3,1,3);
plot(bt, HSI, '-o', 'LineWidth', 1.1, 'MarkerSize', 4); hold on;
xlabel('Elapsed time (s)'); ylabel('HSI (unitless)');
title('HSI');
%xlim([0 140]); xticks(0:20:140);
ylim([0 5]); yticks(0:1:5);
grid on; box on;

%% === 3) 간단 요약 출력 (옵션)
fprintf('PWTT mean = %.2f ms (omitnan)\n', mean(PWTT_ms,'omitnan'));
fprintf('AUSP mean = %.3f (omitnan)\n', mean(AUSP,'omitnan'));
fprintf('HSI  mean = %.3f (omitnan)\n', mean(HSI,'omitnan'));


%% === (추가) raw_stream에서 필터링된 PPG만 플롯 ===
if rawExists
    % --- 유틸: 컬럼 이름 자동 탐색 (대소문자 무시)
    findColIn = @(tbl, aliases) ...
        find(ismember(lower(string(tbl.Properties.VariableNames)), lower(string(aliases))), 1, 'first');

    % 필터링된 PPG 컬럼 찾기
    filtL_idx = findColIn(raw, {'filtL','yL','ppgf_l','ppg_l_filt','left_filt'});
    filtR_idx = findColIn(raw, {'filtR','yR','ppgf_r','ppg_r_filt','right_filt'});
    mark_idx  = findColIn(raw, {'marker','current_marker','mark'});

    if isempty(filtL_idx) || isempty(filtR_idx)
        warning('raw_stream.csv에서 필터링된 PPG 컬럼(filtL/filtR)을 찾지 못했습니다.');
    else
        % --- 너무 긴 데이터는 디시메이션
        N = height(raw);
        maxPts = 200000;
        step = max(1, floor(N / maxPts));
        idx = 1:step:N;

        % --- 필터링된 PPG 파형 플롯
        figure('Name','Filtered PPG (raw_stream.csv)','Position',[250 250 1100 400]);
        plot(t_raw(idx), raw{idx, filtL_idx}, '-', 'LineWidth', 1.0); hold on;
        plot(t_raw(idx), raw{idx, filtR_idx}, '-', 'LineWidth', 1.0);
        grid on; box on;
        xlabel('Elapsed time (s)');
        ylabel('Filtered PPG (a.u.)');
        %title('Filtered PPG from raw\_stream.csv');
        title('Filtered PPG');
        legend({'Left (filt)','Right (filt)'}, 'Location','best');

        % --- 마커 컬럼 있으면 구간 변화점 표시 (선택)
        if ~isempty(mark_idx)
            mk = string(raw{:, mark_idx});
            chPts = [1; 1 + find(mk(2:end) ~= mk(1:end-1))];
            yl = ylim;
            for k = chPts.'
                if k <= numel(t_raw)
                    xline(t_raw(k), ':');
                end
            end
            ylim(yl);
        end
    end
else
    warning('raw_stream CSV가 없어서 필터링된 PPG를 표시할 수 없습니다.');
end
