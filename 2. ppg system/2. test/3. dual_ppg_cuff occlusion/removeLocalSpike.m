function x_clean = removeLocalSpike(x, win, k)
    x_local = movmedian(x, win, 'omitnan');
    resid = x - x_local;
    thr = k * movmad(resid, win, 1, 'omitnan');

    spike_idx = abs(resid) > thr;

    %spike_idx = bwareaopen(spike_idx, 1);

    x_clean = x;
    x_clean(spike_idx) = NaN;
    x_clean = fillmissing(x_clean, 'pchip');
end