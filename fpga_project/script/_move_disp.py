import io, re

p = r'E:\FPGA_project\total_project\src\total_top.v'
s = io.open(p, encoding='utf-8').read()

# 1) 取出后置的两段（al_base 块 + al_disp 块）
m_disp = re.search(r"    //-+ 显示用臂角.*?\n    wire signed \[15:0\] al_disp  = al_disp_17\[15:0\];\n\n", s, re.S)
assert m_disp, 'al_disp 块没找到'
disp_block = m_disp.group(0)
s = s[:m_disp.start()] + s[m_disp.end():]

m_base = re.search(r"    // 定点：把\"当前位置\"定义成基准\n    reg signed \[15:0\] al_base;\n    always @\(posedge clk or negedge rst_n_i\) begin\n        if \(!rst_n_i\)        al_base <= 16'sd0;\n        else if \(zero_pulse\) al_base <= al_raw;\n    end\n\n", s)
assert m_base, 'al_base 块没找到'
base_block = m_base.group(0)
s = s[:m_base.start()] + s[m_base.end():]

# 2) 前移到 th/thd 声明之后（mon_conv 之前）
anchor = "    wire signed [15:0] thd = (INV_TH != 0) ? -thd_raw : thd_raw;\n"
assert anchor in s
moved = anchor + """
    //-------------------------------------------------------------------------
    // 基准点与显示臂角（与 zzh 的 al_base / pos0+arm_rel 等价）
    //   控制：arm_target 的目标基准 al_base（定点时更新）
    //   显示：臂角读数 = wrap(al_raw - al_base)，定点那一刻变 0，之后从 0 起算
    //   ★ 两段必须放在 mon_conv / uart_frame 之前（Verilog 先声明后使用）
    //-------------------------------------------------------------------------
    wire zero_pulse;

    reg signed [15:0] al_base;
    always @(posedge clk or negedge rst_n_i) begin
        if (!rst_n_i)        al_base <= 16'sd0;
        else if (zero_pulse) al_base <= al_raw;
    end

""" + disp_block
s = s.replace(anchor, moved, 1)

io.open(p, 'w', encoding='utf-8').write(s)

# 3) 自检：声明行号必须早于所有使用点
lines = s.split('\n')
decl = next(i for i, l in enumerate(lines, 1) if 'wire signed [15:0] al_disp ' in l)
uses = [i for i, l in enumerate(lines, 1) if 'al_disp)' in l or 'al_disp,' in l]
bdecl = next(i for i, l in enumerate(lines, 1) if 'reg signed [15:0] al_base;' in l)
buses = [i for i, l in enumerate(lines, 1) if '.al_base' in l]
print('al_disp 声明行:', decl, ' 使用行:', uses)
print('al_base 声明行:', bdecl, ' 使用行:', buses)
print('顺序正确:', decl < min(uses) and bdecl < min(buses))