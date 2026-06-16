raw = readtable("C:\Users\user\Desktop\matlab_figure_dual_ppg\Nomal\nomal_J_1\raw_stream.csv");
beats = readtable("C:\Users\user\Desktop\matlab_figure_dual_ppg\Nomal\nomal_J_1\beats_metrics.csv");

%% === 1) beats_metrics에서 주요 열 찾기 ===
findCol = @(tbl, aliases) find(ismember( lower(string(tbl.Properties.VariableNames)), lower(string(aliases)) ),1,'first');
getVar  = @(tbl, aliases) tbl{:, tbl.Properties.VariableNames{findCol(tbl, aliases)}};

% beat 시간
bt_idx = findCol(beats, {'beat_time_s','beat_ts_s','time_s','t_s','ts_s','elapsed_s','t','ts'});
assert(~isempty(bt_idx), 'beats_metrics에 beat 시간 열이 필요합니다 (예: elapsed_s).');
bt = beats{:, bt_idx};

% PWTT
pwtt_col = findCol(beats, {'PWTT_ms','DeltaTD_ms','DT_ms','PAD_ms','PWTT','DeltaTD','DT','PAD'});
assert(~isempty(pwtt_col), 'PWTT/DeltaTD 계열 열을 찾지 못했습니다.');
PWTT_ms = beats{:, pwtt_col};

% PAD_ms (있을 경우)
pad_col = findCol(beats, {'PAD_ms','DeltaTD_ms','DT_ms','PAD'});
PAD_ms = [];
if ~isempty(pad_col)
    PAD_ms = beats{:, pad_col};
end

% AUSP/AUSPR
ausp_col = findCol(beats, {'AUSP','AUSPR','SUTR_over_SUTL','AUSPratio'});
assert(~isempty(ausp_col), 'AUSP/AUSPR 열을 찾지 못했습니다.');
AUSP = beats{:, ausp_col};

% HSI
hsi_col = findCol(beats, {'HSI','HSI_score','risk_HSI'});
assert(~isempty(hsi_col), 'HSI 열을 찾지 못했습니다.');
HSI = beats{:, hsi_col};

% marker
mcol = findCol(beats, {'marker','phase','mark'});
assert(~isempty(mcol), 'marker 열이 필요합니다.');
mk = string(lower(beats{:, mcol}));
mk = replace(mk, [" ","-"], "_");   % 예: 'pressure start' → 'pressure_start'

%% === 2) marker 기반 경계 시점 계산 ===
t_baseline2press = getBoundaryTime(mk, bt, "baseline",       "pressure_start");
t_press2release  = getBoundaryTime(mk, bt, "pressure_start",  "pressure_release");
fprintf("[BORDER] baseline→pressure_start = %s\n", tfmt(t_baseline2press));
fprintf("[BORDER] pressure_start→pressure_release = %s\n", tfmt(t_press2release));

%% === 3) raw_stream에서 시간/PPG 컬럼 ===
findColRaw = @(aliases) find(ismember( lower(string(raw.Properties.VariableNames)), lower(string(aliases)) ),1,'first');

t_raw_idx = findColRaw({'elapsed_s','t_s','time_s','ts','t'});
fL_idx    = findColRaw({'filtL','yL','ppgf_l','ppg_l_filt','left_filt'});
fR_idx    = findColRaw({'filtR','yR','ppgf_r','ppg_r_filt','right_filt'});

assert(~isempty(t_raw_idx), 'raw_stream에서 시간 열을 찾지 못했습니다.');
assert(~isempty(fL_idx) && ~isempty(fR_idx), 'raw_stream에서 filtL/filtR(필터 PPG) 열을 찾지 못했습니다.');

t_raw = raw{:, t_raw_idx};
yL    = raw{:, fL_idx};
yR    = raw{:, fR_idx};

%% === 4) Figure 1: 필터된 PPG 파형 ===
N = numel(t_raw); maxPts = 200000;
step = max(1, floor(N / maxPts)); idx = 1:step:N;

figure('Name','Filtered PPG (raw_stream)','Position',[250 250 1100 420]);
plot(t_raw(idx), yR(idx), '-', 'LineWidth', 1.0); hold on;
plot(t_raw(idx), yL(idx), '-', 'LineWidth', 1.0);
grid on; box on;
xlabel('Elapsed time (s)'); ylabel('Filtered PPG (a.u.)');
title('Filtered PPG');
drawBorders([t_baseline2press, t_press2release], true);
legend({'Right (filt)','Left (filt)','Marker boundary','Pressure Start','Pressure Release'}, 'Location','northeast');

%% === 5) Figure 2: 2x2 Metrics (PWTT, PAD, AUSPR, HSI) ===
figure('Name','Beat-wise Metrics (2x2)','Position',[220 100 1000 800]);

% --- (1,1) PWTT ---
subplot(2,2,1);
plot(bt, PWTT_ms, 'o', 'LineWidth', 1.2, 'MarkerSize', 4, 'DisplayName','PWTT (ms)');
xlabel('time (sec)'); ylabel('PWTT (ms)'); title('PWTT');
xlim([0 180]); xticks(0:30:180);
ylim([-10 110]); yticks(-10:20:110);
grid on; box on;
drawBorders([t_baseline2press, t_press2release], true);
legend({'PWTT','Pressure Start','Pressure Release'},'Location','northeast');

% --- (1,2) PAD ---
subplot(2,2,2);
plot(bt, PAD_ms, 's', 'LineWidth', 1.2, 'MarkerSize', 5, ...
    'DisplayName','PAD (ms)', 'MarkerFaceColor',[0.1 0.4 0.8], 'MarkerEdgeColor','k');
xlabel('time (sec)'); ylabel('PAD (ms)');
title('PAD (Foot-to-Foot 차이)');
xlim([0 180]); xticks(0:30:180);
ylim([-110 100]); yticks(-110:20:100);
grid on; box on;
drawBorders([t_baseline2press, t_press2release], true);
legend({'PAD','Pressure Start','Pressure Release'},'Location','northeast');

% --- (2,1) AUSP ---
subplot(2,2,3);
plot(bt, AUSP, 'o', 'LineWidth', 1.2, 'MarkerSize', 4, 'DisplayName','AUSPR');
xlabel('time (sec)'); ylabel('AUSPR (R/L 면적비)');
title('AUSPR');
xlim([0 180]); xticks(0:30:180);
ylim([0 2.2]); yticks(0:0.2:2.2);
grid on; box on;
drawBorders([t_baseline2press, t_press2release], true);
legend({'AUSP','Pressure Start','Pressure Release'},'Location','northeast');

% --- (2,2) HSI ---
subplot(2,2,4);
plot(bt, HSI, 'o', 'LineWidth', 1.2, 'MarkerSize', 4, 'DisplayName','HSI');
xlabel('time (sec)'); ylabel('HSI (혈류 비대칭 지수)');
title('HSI');
xlim([0 180]); xticks(0:30:180);
ylim([0 5.5]); yticks(0:1:5.5);
grid on; box on;
drawBorders([t_baseline2press, t_press2release], true);
legend({'HSI','Pressure Start','Pressure Release'},'Location','northeast');

%% === 6) 간단 통계 출력 ===
%fprintf('PWTT mean = %.2f ms (omitnan)\n', mean(PWTT_ms,'omitnan'));
%if ~isempty(PAD_ms)
%    fprintf('PAD  mean = %.2f ms (omitnan)\n', mean(PAD_ms,'omitnan'));
%end
%fprintf('AUSPR mean = %.3f (omitnan)\n', mean(AUSP,'omitnan'));
%fprintf('HSI  mean = %.3f (omitnan)\n', mean(HSI,'omitnan'));


%% === Local functions ===
function t = getBoundaryTime(mk, bt, a, b)
    % marker 전환 시점 검출
    t = NaN;
    if isempty(bt), return; end
    i = find(mk(1:end-1)==a & mk(2:end)==b, 1, 'first');
    if ~isempty(i)
        t = mean([bt(i) bt(i+1)], 'omitnan');
    else
        j = find(mk==b, 1, 'first');
        if ~isempty(j) && ~isnan(bt(j)), t = bt(j); end
    end
end

function drawBorders(ts, addToLegend)
    % 회색 또는 검은 점선으로 경계 표시
    if nargin < 2, addToLegend = false; end
    ts = ts(~isnan(ts));
    if isempty(ts), return; end
    yl = ylim; hold on;

    % 점선 색상
    lineColor = [0 0 0];
    labels = ["Pressure Start","Pressure Release"]; % legend용 이름
    nLabel = numel(labels);

    for k = 1:numel(ts)
        label = '';
        if addToLegend && k <= nLabel
            label = labels(k);
        end

        % legend에 표시할 라인만 HandleVisibility='on'
        if addToLegend && k <= nLabel
            xline(ts(k), ':', 'Color', lineColor, 'LineWidth', 1.4, ...
                  'HandleVisibility','on', 'DisplayName', label);
        else
            xline(ts(k), ':', 'Color', lineColor, 'LineWidth', 1.4, ...
                  'HandleVisibility','off');
        end
    end
    ylim(yl);
end


function s = tfmt(t)
    % 숫자를 사람이 읽기 좋은 문자열로 변환
    if isnan(t)
        s = 'NaN';
    else
        s = sprintf('%.3f s', t);
    end
end
