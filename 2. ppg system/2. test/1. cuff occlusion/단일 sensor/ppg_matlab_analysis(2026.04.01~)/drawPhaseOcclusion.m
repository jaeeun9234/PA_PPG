function drawPhaseOcclusion(phases)
% drawPhaseOcclusion
% cuff occlusion test phase 시작선 표시

    hold on;

    % if ~isnan(phases.baseline)
    %     xline(phases.baseline, 'k--', 'LineWidth', 1.2);
    % end

    if ~isnan(phases.occlusion)
        xline(phases.occlusion, 'k--', 'LineWidth', 1.5);
    end

    if ~isnan(phases.max_pressure)
        xline(phases.max_pressure, 'k--', 'LineWidth', 1.2);
    end

    if ~isnan(phases.recovery)
        xline(phases.recovery, 'k-.', 'LineWidth', 1.5);
    end
end