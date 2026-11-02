import io
p = r'src\total_top.v'
s = io.open(p, encoding='utf-8').read()
old = "    wire signed [15:0] al_disp  = al_disp_17[15:0];"
new = """    // 打一拍：减法+缠绕的组合链直接进 mon_conv/uart_frame 会拉长到 28ns
    // （实测 −8.12ns、66 个违例端点全在这条路上），显示量延迟 20ns 无影响
    reg signed [15:0] al_disp;
    always @(posedge clk or negedge rst_n_i) begin
        if (!rst_n_i) al_disp <= 16'sd0;
        else          al_disp <= al_disp_17[15:0];
    end"""
assert old in s
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8').write(s)
print('al_disp 已寄存')
