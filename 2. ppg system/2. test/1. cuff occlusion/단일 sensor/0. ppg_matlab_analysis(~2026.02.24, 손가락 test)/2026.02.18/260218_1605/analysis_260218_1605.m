filename = "C:\Users\user\Desktop\ppg_matlab_analysis\260218_1605\ppg_data_260218_1605.csv";

M = readmatrix(filename);

t       = M(:,1) / 1000;
red_raw = M(:,2);
ir_raw  = M(:,3);
red_dc  = M(:,4);
ir_dc   = M(:,5);


%% plotting
plot(t, red_raw); hold on;
plot(t, red_dc);
legend('RED raw','RED DC');