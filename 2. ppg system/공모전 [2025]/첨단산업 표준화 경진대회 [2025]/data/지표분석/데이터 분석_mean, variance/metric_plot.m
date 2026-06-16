%% 설정
fname = 'C:\Users\user\Desktop\지표plot.xlsx';   % <- CSV 파일명(경로 포함 가능)

%% CSV 읽기
T = readtable(fname, 'VariableNamingRule','preserve');

% 첫 번째 열(케이스명) 가져오기 (열 이름이 무엇이든 자동으로 감지)
caseColName = T.Properties.VariableNames{1};
cases = string(T.(caseColName)); % 예: "pressure - baseline", "recovery - baseline"

% 케이스 인덱스 찾기
iPress = find(strcmpi(cases, "pressure - baseline"), 1);
iRecov = find(strcmpi(cases, "recovery - baseline"), 1);
if isempty(iPress) || isempty(iRecov)
    error('CSV 안에서 "pressure - baseline" / "recovery - baseline" 행을 찾지 못했습니다.');
end

% 변수명과 (n)/(o) 구분
V = T.Properties.VariableNames;
V = V(2:end); % 첫 열(Case)은 제외
isN = endsWith(V, "(n)");
isO = endsWith(V, "(o)");

Vn = V(isN);
Vo = V(isO);

% 지표 이름(괄호 제거) 정렬
stripParen = @(s) regexprep(s, '\s*\((n|o)\)\s*$', '');
metrics_n = string(stripParen(Vn));
metrics_o = string(stripParen(Vo));

% 두 세트가 같은 지표 순서인지 체크 후, 다르면 정렬 맞추기
[metrics, idxN] = sort(metrics_n);             % 기준 순서
[~, idxOinN]     = ismember(metrics, metrics_o);

Vn = Vn(idxN);
Vo = Vo(idxOinN);

% 값 추출 (행: 케이스, 열: 지표)
vals_press_n = T{iPress, Vn};
vals_press_o = T{iPress, Vo};
vals_recov_n = T{iRecov, Vn};
vals_recov_o = T{iRecov, Vo};

% 그래프용 데이터 행렬 (지표 x 4케이스)
% 열 순서: 1) Normal(Pressure) 2) Occlusion(Pressure) 3) Normal(Recovery) 4) Occlusion(Recovery)
D = [vals_press_n(:), vals_press_o(:), vals_recov_n(:), vals_recov_o(:)];

%% 플로팅
figure('Color','w');
bar(D, 'grouped');
grid on; box off;
ylabel('Value');

% X축 라벨: 지표 이름
set(gca, 'XTick', 1:numel(metrics), 'XTickLabel', metrics, 'XTickLabelRotation', 30);

% 기준선(음수값 보이도록)
yline(0, '--');

% 범례
legend( ...
    {'Normal (pressure-baseline)', 'Occlusion (pressure-baseline)', ...
     'Normal (recovery-baseline)', 'Occlusion (recovery-baseline)'}, ...
    'Location','bestoutside');

title('Metric-wise Comparison (Normal/Occlusion × Pressure/Recovery)');

% 저장 (원하면 주석 해제)
% exportgraphics(gcf, 'metric_groupbars.png', 'Resolution', 200);
