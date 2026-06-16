clear; clc; close all;

%% ===== 0) 파일 지정 =====
fname = "data_20260309_1326.csv";  

% ===== 1) CSV 읽기 =====
T = readtable(fname);

% 컬럼명 확인용(필요시)
%disp(T.Properties.VariableNames)

% ===== 2) 시간축 =====
t = T.t_ms / 1000;   % sec

% ===== 3) 데이터 추출 =====
red_raw = T.red_raw;
red_dc  = T.red_dc;
red_ac  = T.red_ac;

ir_raw  = T.ir_raw;
ir_dc   = T.ir_dc;
ir_ac   = T.ir_ac;

OD_red = T.OD_red;
OD_ir  = T.OD_ir;

spo2 = T.spo2;

phase = T.phase;

% phase 변화 지점
idx_change = find(diff(phase) ~= 0) + 1;

t_change = t(idx_change);
phase_change = phase(idx_change);

T0 = t(find(phase == 0, 1, 'first'));   % occlusion start
T1 = t(find(phase == 1, 2, 'first'));   % 최고 압력 도달 
T2 = t(find(phase == 2, 3, 'first'));   % recovery start 
T3 = t(find(phase == 3, 1, 'first'));

% ---- Prahl extinction coefficients (1/(M·cm)) ----
eps_HHb_660  = 3226.56;
eps_HbO2_660 = 319.6;
eps_HHb_880  = 726.44;
eps_HbO2_880 = 1154;

%% ===== 4.5) Fs 자동 추정 (중요!!) =====
dt = diff(t);
Fs = 1/median(dt);                  % 실제 Fs (~100Hz)
fprintf("Fs ~= %.2f Hz\n", Fs);
disp([min(dt) median(dt) max(dt)]);  


winSec = 2.0;          % 2초 윈도우 (대략 2~3 박동 포함)
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

%% ===== 9) MBLL: OD -> ΔHbO2, ΔHHb (relative) =====

ln10 = log(10);

dA_660 = OD_red(mask)/ln10;       % 660nm
dA_880 = OD_ir(mask)/ln10;        % 880nm

bad = ~isfinite(dA_660) | ~isfinite(dA_880);
dA_660(bad) = NaN;
dA_880(bad) = NaN;

% NaN을 보간해서 필터가 먹게 만들기(가장 무난)
dA_660 = fillmissing(dA_660, "linear", "EndValues","nearest");
dA_880 = fillmissing(dA_880, "linear", "EndValues","nearest");

dA_660 = lowpass(medfilt1(dA_660,5), 0.5, Fs);   % 0.2~0.8Hz 조절
dA_880 = lowpass(medfilt1(dA_880,5), 0.5, Fs);

% offset 제거
dA_660 = dA_660 - mean(dA_660(1:round(5*Fs)), 'omitnan');
dA_880 = dA_880 - mean(dA_880(1:round(5*Fs)), 'omitnan');

% d*DPF는 모르면 1로 둔다 (상대값만 의미)
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

%% ===== 10) ΔHbO2 / ΔHHb / ΔHbT 확인 =====
scale = 1e-5;

figure;
plot(tt, dHbO2/scale, LineWidth = 1.2); hold on;
plot(tt, dHHb/scale, LineWidth = 1.2); hold on;
plot(tt, dHbT/scale, LineWidth = 1.2);
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');
grid on;
xlabel("Time (s)"); ylabel("\times10^{-5}");
title("\DeltaHbO2, \DeltaHHb, \DeltatHb [DC]");
legend("\DeltaHbO2","\DeltaHHb","\DeltatHb", "Location", "best");

%% envelope plotting
dHbO2_env = envelope(abs(dHbO2), 100);
dHHb_env = envelope(abs(dHHb), 100);
dHbT_env = envelope(abs(dHbT), 100);


%% AC 기준 HHb, HbO2, tHb
% 1) mask 적용해서 안정화 구간만 사용
DA_660 = -(red_ac(mask) ./ max(red_dc(mask), 1));
DA_880 = -(ir_ac(mask)  ./ max(ir_dc(mask),  1));

% 2) NaN/Inf 방지(안 넣을 경우 bandpass에서 에러 발생 가능)
bad = ~isfinite(DA_660) | ~isfinite(DA_880);
DA_660(bad) = NaN;
DA_880(bad) = NaN;
DA_660 = fillmissing(DA_660, "linear", "EndValues","nearest");
DA_880 = fillmissing(DA_880, "linear", "EndValues","nearest");

% 3) 스파이크 완화 -> bandpass
DA_660 = medfilt1(DA_660, 5);
DA_880 = medfilt1(DA_880, 5);

DA_660 = bandpass(DA_660, [0.7 4], Fs);
DA_880 = bandpass(DA_880, [0.7 4], Fs);

% 4) offset 제거(마스크 구간 기준)
N0 = round(5*Fs);
DA_660 = DA_660 - mean(DA_660(1:N0), 'omitnan');
DA_880 = DA_880 - mean(DA_880(1:N0), 'omitnan');

% 5) MBLL
dC = (E \ [DA_660.'; DA_880.']).';   % [HHb, HbO2]

DHHb  = dC(:,1);
DHbO2 = dC(:,2);
DtHb  = DHbO2 + DHHb;

%% 변화량 plot
ymin = min([dHbO2(:); DHbO2(:); dHHb(:); DHHb(:); dHbT(:); DtHb(:)]);
ymax = max([dHbO2(:); DHbO2(:); dHHb(:); DHHb(:); dHbT(:); DtHb(:)]);

figure;
plot(tt, dHbO2/scale, "Color", [1 0 0 1], "LineWidth",  1.2); hold on; plot(tt, DHbO2/scale, "Color", [0 0 1 0.5]); 
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');
title("\Delta HbO2  [DC/AC]"); legend("\Delta HbO2 [DC]", "\Delta HbO2 [AC]", "Location", "best");
ylabel("\times10^{-5}"); ylim([ymin ymax]/scale);
grid on;

figure;
plot(tt, dHHb/scale, "Color", [1 0 0 1], "LineWidth", 1.2); hold on; plot(tt, DHHb/scale, "Color", [0 0 1 0.5]); 
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');
title("\Delta HHb [DC/AC]"); legend("\Delta HHb [DC] ", "\Delta HHb [AC]", "Location", "best");
ylabel("\times10^{-5}"); ylim([ymin ymax]/scale);
grid on;

figure;
plot(tt, dHbT/scale, "Color", [1 0 0 1], "LineWidth", 1.2); hold on; plot(tt, DtHb/scale, "Color", [0 0 1 0.5]); 
xline(T1,'k--');    xline(T2,'k--');    xline(T3,'k--');
title("\Delta tHb  [DC/AC]"); legend("\Delta tHb [DC] ", "\Delta tHb [AC]", "Location", "best");
ylabel("\times10^{-5}"); ylim([ymin ymax]/scale);
grid on;