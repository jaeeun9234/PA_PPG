%% kalman filter 선언
function xhat = kf_1d_randomwalk(z, Q, R, x0, P0)

N = numel(z);
xhat = zeros(N,1);

x = x0;
P = P0;

for k = 1:N
    P = P+Q;

    K = P / (P + R);
    X = x + K * (z(k) - x);
    P = (1-K)*P;
    
    xhat(k) = x;
end
end