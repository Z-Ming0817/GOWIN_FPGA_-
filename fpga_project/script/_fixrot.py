import io
p = r'src\total_top.v'
s = io.open(p, encoding='utf-8').read()
old = """    // 速度 °/s → Q25 rad/tick：ROT_W = °/s × 292817/1000 ≈ ×293（30 → 8790，与 zzh 一致）
    wire [15:0] rot_w    = speed * 16'd293;"""
new = """    // 速度 °/s → Q25 rad/tick：ROT_W = °/s × 292817/1000 ≈ ×293（30 → 8790，与 zzh 一致）
    // ★ 乘法必须寄存：组合乘法直接进 arm_target 会让 speed→mult 成为最差路径
    //   （实测 slack −1.57 ns，95 个违例端点全在这里）
    reg [15:0] rot_w;
    always @(posedge clk or negedge rst_n_i) begin
        if (!rst_n_i) rot_w <= 16'd0;
        else          rot_w <= speed * 16'd293;
    end"""
assert old in s
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8').write(s)
print('rot_w 已改为寄存')
