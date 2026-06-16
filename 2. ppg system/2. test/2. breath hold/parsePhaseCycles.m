function cycles = parsePhaseCycles(t_trial, phase, trial_id)
% parsePhaseCycles
% trial_id를 기준으로 각 trial의 phase 시작 시점을 cycle 단위로 정리
%
% 입력:
%   t_trial  : 각 trial 내부 상대시간 벡터
%   phase    : phase 벡터
%   trial_id : trial 번호 벡터
%
% 출력:
%   cycles(k).trial_id
%   cycles(k).baseline
%   cycles(k).occlusion
%   cycles(k).maxPressure
%   cycles(k).recovery
%
% 없는 phase는 NaN으로 저장됨
%
% phase 정의:
%   0 = baseline
%   1 = occlusion start
%   2 = max pressure
%   3 = recovery start

    % 초기화
    cycles = struct( ...
        'trial_id', {}, ...
        'baseline', {}, ...
        'occlusion', {}, ...
        'maxPressure', {}, ...
        'recovery', {} );

    % 유효한 trial_id만 추출
    utrial = unique(trial_id(~isnan(trial_id)));

    c = 0;

    for k = 1:length(utrial)
        tid = utrial(k);

        idx = (trial_id == tid);
        tt = t_trial(idx);
        ph = phase(idx);

        if isempty(tt)
            continue;
        end

        % phase가 바뀌는 시작 지점
        idx_change = [1; find(diff(ph) ~= 0) + 1];
        t_change   = tt(idx_change);
        p_change   = ph(idx_change);

        c = c + 1;
        cycles(c).trial_id     = tid;
        cycles(c).baseline     = NaN;
        cycles(c).occlusion    = NaN;
        cycles(c).maxPressure  = NaN;
        cycles(c).recovery     = NaN;

        for i = 1:length(p_change)
            switch p_change(i)
                case 0
                    if isnan(cycles(c).baseline)
                        cycles(c).baseline = t_change(i);
                    end
                case 1
                    if isnan(cycles(c).occlusion)
                        cycles(c).occlusion = t_change(i);
                    end
                case 2
                    if isnan(cycles(c).maxPressure)
                        cycles(c).maxPressure = t_change(i);
                    end
                case 3
                    if isnan(cycles(c).recovery)
                        cycles(c).recovery = t_change(i);
                    end
            end
        end
    end
end