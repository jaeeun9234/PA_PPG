function phases = parsePhaseBreathHold(t_trial, phase)
% parsePhaseBreathHold
% breath hold test용 phase 시작 시점 정리
%
% phase 정의:
%   0 = baseline
%   1 = breath hold
%   2 = recovery

    phases = struct( ...
        'baseline', NaN, ...
        'breathHold', NaN, ...
        'recovery', NaN);

    if isempty(t_trial) || isempty(phase)
        return;
    end

    % phase가 바뀌는 시작 지점
    idx_change = [1; find(diff(phase) ~= 0) + 1];
    t_change   = t_trial(idx_change);
    p_change   = phase(idx_change);

    for i = 1:length(p_change)
        switch p_change(i)
            case 0
                if isnan(phases.baseline)
                    phases.baseline = t_change(i);
                end
            case 1
                if isnan(phases.breathHold)
                    phases.breathHold = t_change(i);
                end
            case 2
                if isnan(phases.recovery)
                    phases.recovery = t_change(i);
                end
        end
    end
end