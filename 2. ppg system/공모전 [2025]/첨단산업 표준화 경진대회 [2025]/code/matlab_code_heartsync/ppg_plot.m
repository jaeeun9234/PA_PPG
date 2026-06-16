raw   = readtable('C:\Users\user\Desktop\ppg_data\1\raw_stream_1.csv');
beats = readtable('C:\Users\user\Desktop\ppg_data\1\beats_metrics_1.csv');

t  = raw.elapsed_s;  yL = raw.filtL;  yR = raw.filtR;
fL = beats.footL_idx;  pL = beats.peakL_idx;
fR = beats.footR_idx;  pR = beats.peakR_idx;

N  = height(raw);
okL = ~isnan(fL)&~isnan(pL)&fL>=1&pL>=1&fL<=N&pL<=N&pL>fL;
okR = ~isnan(fR)&~isnan(pR)&fR>=1&pR>=1&fR<=N&pR<=N&pR>fR;
ok  = okL & okR;

fL = fL(ok); pL = pL(ok);
fR = fR(ok); pR = pR(ok);
bt = mean([t(fL) t(fR)], 2, 'omitnan');

% === (1) PWTT: Python과 동일하게 peak-peak "절대값" ===
PWTT_ms = abs(t(pR) - t(pL)) * 1000;

% === (2) AUSP: Python과 동일하게 '양수 클리핑 + 균일 간격 DT' 적분 ===
FS = 50;             % Python FS_HZ
DT = 1/FS;
epsA = 1e-6;         % Python과 동일한 분모 가드

nB = numel(fL);
A_L = nan(nB,1); A_R = nan(nB,1);

for i = 1:nB
    idxL = fL(i):pL(i);
    idxR = fR(i):pR(i);

    segL = yL(idxL); segL(segL<0) = 0;          % np.clip(..., 0, None)
    segR = yR(idxR); segR(segR<0) = 0;

    % Python: np.trapz(y, dx=DT) → 균일 간격 적분
    A_L(i) = trapz(segL) * DT;
    A_R(i) = trapz(segR) * DT;
end

AUSPR = A_R ./ max(A_L, epsA);                  % 분모 가드
AUSPR(~isfinite(AUSPR)) = NaN;

% === (3) HSI: Python과 동일 식 ===
HSI = abs(AUSPR - 1)./0.05 + max(0, PWTT_ms - 20)./12;

% === Plot ===
figure('Position',[200 200 1000 760]);
subplot(3,1,1); plot(bt,PWTT_ms,'-o'); yline(20,'--','20 ms'); grid on; box on;
ylabel('PWTT (ms)'); title('\DeltaTD (|peak_R - peak_L|)');

subplot(3,1,2); plot(bt,AUSPR,'-o'); yline(1,'-'); yline(0.95,'--'); yline(1.05,'--');
ylabel('AUSPR = Area_R / Area_L'); grid on; box on; title('AUSP (area ratio)');

subplot(3,1,3); plot(bt,HSI,'-o'); grid on; box on;
xlabel('Elapsed time (s)'); ylabel('HSI'); title('HSI = |AUSPR-1|/0.05 + max(0,PWTT-20)/12');
