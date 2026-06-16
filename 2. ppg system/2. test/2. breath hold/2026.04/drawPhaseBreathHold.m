function drawPhaseBreathHold(phases)
% drawPhaseBreathHold
% breath hold test phase 시작선 표시

    hold on;

    % if ~isnan(phases.baseline)
    %     xline(phases.baseline, 'k--', 'LineWidth', 1.2);
    % end

    if ~isnan(phases.breathHold)
        xline(phases.breathHold, 'k--', 'LineWidth', 1.5);
    end

    if ~isnan(phases.recovery)
        xline(phases.recovery, 'k-.');
    end
end