function xhat = kf_dc(z, Q, R)

N = numel(z);
xhat = zeros(N,1);

x = z(1);     % 초기 상태
P = 1e5;      % 초기 오차 공분산

for k = 1:N
    % Predict
    P = P + Q;

    % Update
    K = P / (P + R);
    x = x + K*(z(k) - x);
    P = (1 - K)*P;

    xhat(k) = x;
end
end