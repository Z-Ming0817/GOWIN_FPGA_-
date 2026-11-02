import io

# ===================== param_link：默认值对齐 zzh + 增加增益输出 =====================
p = r'E:\FPGA_project\total_project\src\param_link.v'
s = io.open(p, encoding='utf-8').read()

# 1) 默认值严格对齐 zzh（cfg_regs.v 的 C1..C4/THC_DEF）
s = s.replace("localparam signed [31:0] DEF_C1   = -32'sd1011;",
              "localparam signed [31:0] DEF_C1   = -32'sd1200;   // zzh: C1_DEF")
s = s.replace("localparam signed [31:0] DEF_C2   = -32'sd1770;",
              "localparam signed [31:0] DEF_C2   = -32'sd1700;   // zzh: C2_DEF")
s = s.replace("localparam signed [31:0] DEF_C3   =  32'sd7050;",
              "localparam signed [31:0] DEF_C3   =  32'sd6900;   // zzh: C3_DEF")
s = s.replace("localparam signed [31:0] DEF_C4   =  32'sd1950;",
              "localparam signed [31:0] DEF_C4   =  32'sd1940;   // zzh: C4_DEF")

# 2) 增加 LQR/起摆需要的输出
s = s.replace("""    input  wire [3:0]  pr_idx,        // 菜单读取：参数序号 0~9""",
"""    output wire signed [15:0] o_c1,   // 给 lqr_controller
    output wire signed [15:0] o_c2,
    output wire signed [15:0] o_c3,
    output wire signed [15:0] o_c4,
    output wire signed [15:0] o_th_catch,   // 给 swing_ctrl
    input  wire [3:0]  pr_idx,        // 菜单读取：参数序号 0~9""")

s = s.replace("    assign p_scope_div = r_sco;",
"""    assign p_scope_div = r_sco;
    assign o_c1       = r_c1[15:0];
    assign o_c2       = r_c2[15:0];
    assign o_c3       = r_c3[15:0];
    assign o_c4       = r_c4[15:0];
    assign o_th_catch = r_thc[15:0];""")

io.open(p, 'w', encoding='utf-8').write(s)
print('param_link 已对齐 zzh 默认值并加输出')

# ===================== total_top：声明参数线 =====================
p = r'E:\FPGA_project\total_project\src\total_top.v'
s = io.open(p, encoding='utf-8').read()
if 'p_c1' in s and 'wire signed [15:0] p_c1' not in s:
    s = s.replace("    wire [31:0] p_scope_div;",
"""    wire [31:0] p_scope_div;
    wire signed [15:0] p_c1, p_c2, p_c3, p_c4, p_th_catch;""")
    io.open(p, 'w', encoding='utf-8').write(s)
    print('total_top 已声明参数线')