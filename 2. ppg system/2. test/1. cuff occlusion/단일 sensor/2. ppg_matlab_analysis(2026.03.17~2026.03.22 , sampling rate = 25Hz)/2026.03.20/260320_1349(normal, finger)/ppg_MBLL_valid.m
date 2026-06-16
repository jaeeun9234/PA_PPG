clear; clc;

%%
eps_HHb_660  = 3226.56;
eps_HbO2_660 = 319.6;
eps_HHb_880  = 726.44;
eps_HbO2_880 = 1154;

E = [eps_HbO2_660, eps_HHb_660;
     eps_HbO2_880, eps_HHb_880];

% ===== case 1: HbO2만 증가 =====
true_dC = [ 1e-6; 0 ];   % [dHbO2; dHHb]
dA = E * true_dC;        % 이상적인 흡광도 변화

est_dC = E \ dA;

disp('case 1: HbO2 only increase')
disp('true ='), disp(true_dC)
disp('est  ='), disp(est_dC)

% ===== case 2: HHb만 증가 =====
true_dC = [ 0; 1e-6 ];
dA = E * true_dC;
est_dC = E \ dA;

disp('case 2: HHb only increase')
disp('true ='), disp(true_dC)
disp('est  ='), disp(est_dC)

% ===== case 3: HbO2 감소 + HHb 증가 =====
true_dC = [ -1e-6; 1e-6 ];
dA = E * true_dC;
est_dC = E \ dA;

disp('case 3: HbO2 decrease + HHb increase')
disp('true ='), disp(true_dC)
disp('est  ='), disp(est_dC)