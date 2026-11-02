import io, os

T = r'E:\FPGA_project\total_project'

# ===================== 1. menu_frame：参数页改 1.5× =====================
p = os.path.join(T, 'src', 'menu_frame.v')
s = io.open(p, encoding='utf-8').read()

start = s.index("    //---------------- 参数页：8x16 ASCII")
end   = s.index("    wire aon = abits[3'd7 - agx];") + len("    wire aon = abits[3'd7 - agx];")
old_block = s[start:end]

new_block = """    //---------------- 参数页：1.5x ASCII（12px/字 x 24px 高，18 字一行，x=12..227）----------------
    //  放大 1.5 倍不能用移位，这里用乘加代替除法：
    //    字形坐标 g = floor(2*u/3)，用 (u*2731)>>12 精确实现
    //    2731/4096 = 0.66675 >= 2/3，且误差 u*8.14e-5 < 1/3 对 u<4095 恒成立 → 逐点精确
    wire [3:0]  pidx  = pstart[3:0] + {1'b0, rcur};
    assign pr_idx = pstart[3:0] + {2'b0, rcur};

    wire [7:0]  ux    = px - 8'd12;                  // 文本区横坐标 0..215
    wire [27:0] hmul  = ux * 20'd2731;
    wire [7:0]  gcol  = hmul[19:12];                 // 全局字形列 0..143
    wire [4:0]  acidx = gcol[7:3];                   // 字符序号 0..17
    wire [2:0]  agx   = gcol[2:0];                   // 字形内横坐标

    wire [7:0]  ach_name;
    param_rom u_prom (.idx(pidx), .pos(acidx), .ch(ach_name));

    // 数值区：槽 11=符号，12~17=6 位数字；CLK_FREQ（第 0 行）固定显示 50M
    wire [3:0]  vslot   = acidx - 5'd11;
    wire        use_val = (style == 3'd6) && (pidx != 4'd0) &&
                          (pidx < 4'd10) && (acidx >= 5'd11);

    // 6 位 BCD 数字（d5 最高位）
    wire [3:0] d5 = pr_bcd[23:20], d4 = pr_bcd[19:16], d3 = pr_bcd[15:12];
    wire [3:0] d2 = pr_bcd[11:8],  d1 = pr_bcd[7:4],   d0 = pr_bcd[3:0];

    // 槽 11 = 符号，12~17 = 六位数字（前导零消隐）
    wire [7:0] ach_val =
        (vslot == 4'd0) ? (pr_neg ? 8'h2D : 8'h20) :
        (vslot == 4'd1) ? ((d5 != 4'd0) ? (8'h30 + d5) : 8'h20) :
        (vslot == 4'd2) ? ((d5 | d4) != 4'd0 ? (8'h30 + d4) : 8'h20) :
        (vslot == 4'd3) ? ((d5 | d4 | d3) != 4'd0 ? (8'h30 + d3) : 8'h20) :
        (vslot == 4'd4) ? ((d5 | d4 | d3 | d2) != 4'd0 ? (8'h30 + d2) : 8'h20) :
        (vslot == 4'd5) ? ((d5 | d4 | d3 | d2 | d1) != 4'd0 ? (8'h30 + d1) : 8'h20) :
        (vslot == 4'd6) ? (8'h30 + d0) : 8'h20;

    wire [7:0]  ach     = use_val ? ach_val : ach_name;

    wire asc_on = in_rows && (style == 3'd6) && (px >= 8'd12) && (px < 8'd228) &&
                  (rrem >= 8'd4) && (rrem < 8'd28);

    wire [7:0]  dy    = rrem - 8'd4;                 // 0..23
    wire [27:0] vmul  = dy * 20'd2731;
    wire [3:0]  agy   = vmul[15:12];                 // 0..15（16 行字形撑成 24px 高）

    wire [7:0]  abits;
    font_ascii u_fa2 (.code(ach[6:0]), .row(agy), .bits(abits));
    wire aon = abits[3'd7 - agx];"""

s = s[:start] + new_block + s[end:]
io.open(p, 'w', encoding='utf-8').write(s)
print('menu_frame 已改为 1.5x')

# ===================== 2. 重新生成 param_rom（18 字：名字 11 + 数值 7）=====================
rows = [
    ("CLK_FREQ",  "50M"),
    ("BAUD",      "115200"),
    ("PWM_HZ",    "80000"),
    ("SCOPE_DIV", "500000"),
    ("C_P_REV",   "1064"),
    ("LQR_C1",    "-1011"),
    ("LQR_C2",    "-1770"),
    ("LQR_C3",    "7050"),
    ("LQR_C4",    "1950"),
    ("TH_CATCH",  "1650"),
]
NAME_W, VAL_W, W = 11, 7, 18

lines = []
lines.append('//=============================================================================')
lines.append('// param_rom.v — 参数读取页的 10 行文字（自动生成，请勿手改）')
lines.append('//')
lines.append('// 每行 18 个字符：左边参数名（11 字），右边数值（7 字，右对齐）')
lines.append('// 渲染：1.5x 放大，12px/字，整行 216px 居中（x=12..227）')
lines.append('//=============================================================================')
lines.append('`timescale 1ns/1ps')
lines.append('')
lines.append('module param_rom (')
lines.append('    input  wire [3:0] idx,     // 0~9')
lines.append('    input  wire [4:0] pos,     // 0~17')
lines.append('    output reg  [7:0] ch')
lines.append(');')
lines.append('')
lines.append('    always @(*) begin')
lines.append("        ch = 8'h20;")
lines.append('        case (idx)')
for i, (name, val) in enumerate(rows):
    seg = name.ljust(NAME_W) + val.rjust(VAL_W)
    assert len(seg) == W, (name, len(seg))
    assert len(name) <= NAME_W, name
    lines.append("            4'd%d: begin" % i)
    lines.append('                case (pos)')
    for k, c in enumerate(seg):
        if c != ' ':
            lines.append("                    5'd%d: ch = 8'h%02X;" % (k, ord(c)))
    lines.append("                    default: ch = 8'h20;")
    lines.append('                endcase')
    lines.append('            end')
lines.append("            default: ch = 8'h20;")
lines.append('        endcase')
lines.append('    end')
lines.append('')
lines.append('endmodule')
io.open(os.path.join(T, 'src', 'param_rom.v'), 'w', encoding='utf-8').write('\n'.join(lines))
print('param_rom 已重生成（18 字/行）')
for n, v in rows:
    print('  |%s|' % (n.ljust(NAME_W) + v.rjust(VAL_W)))