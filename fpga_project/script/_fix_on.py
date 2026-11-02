import io

p = r'E:\FPGA_project\total_project\src\mode_fsm.v'
s = io.open(p, encoding='utf-8').read()
orig = s

# 1) 新增 cmd_on 的 pending 锁存（与 zzh 的 key_pend 同理）
anchor = "    // 定点只能在停机状态做（与 zzh 的 zero_cmd 条件一致）"
assert anchor in s
add = """    //---------------- 上电命令锁存 ----------------
    // ★ cmd_on 只有 1 个时钟宽，而本机只在 tick（2000Hz）上判决，
    //   直接采会漏掉 99.99% 的按键（实测表现：按上电没反应）。
    //   这里锁存到下一个 tick 再消费，置位优先，避免与 tick 同拍时被吞掉。
    reg pend_on;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        pend_on <= 1'b0;
        else if (cmd_on)   pend_on <= 1'b1;     // 置位优先
        else if (tick)     pend_on <= 1'b0;     // 由 tick 消费
    end

"""
s = s.replace(anchor, add + anchor, 1)

# 2) 三处 cmd_on 判定改用 pend_on
s = s.replace("                    if (cmd_on) begin\n                        if (th_ok) begin           // 已经立着：直接闭环",
              "                    if (pend_on) begin\n                        if (th_ok) begin           // 已经立着：直接闭环")
s = s.replace("                    if (cmd_on) begin              // 起摆中再按上电 = 重新判定",
              "                    if (pend_on) begin             // 起摆中再按上电 = 重新判定")
s = s.replace("                    if (cmd_on) begin              // 故障解除后重新上电",
              "                    if (pend_on) begin             // 故障解除后重新上电")

io.open(p, 'w', encoding='utf-8').write(s)
print('changed =', s != orig)
for ln, line in enumerate(s.split('\n'), 1):
    if 'pend_on' in line or 'cmd_on' in line:
        print(' ', ln, line.strip())