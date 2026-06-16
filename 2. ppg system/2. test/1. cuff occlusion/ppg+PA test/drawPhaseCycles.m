function drawPhaseCycles(cycles)
% drawPhaseCycles
% parsePhaseCycles로 만든 cycles 구조체를 이용해
% 그래프에 phase 시작선 표시

    hold on;

    for k = 1:length(cycles)

        if ~isnan(cycles(k).baseline)
            xline(cycles(k).baseline, 'k--', 'LineWidth', 1.5);
        end

        if ~isnan(cycles(k).occlusion)
            xline(cycles(k).occlusion, 'k-.');
        end

        if ~isnan(cycles(k).maxPressure)
            xline(cycles(k).maxPressure, 'k-.');
        end

        if ~isnan(cycles(k).recovery)
            xline(cycles(k).recovery, 'k--');
        end

    end
end