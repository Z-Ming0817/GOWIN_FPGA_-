import io

# ===================== arm_target：旋转速度/方向改成运行期输入 =====================
p = r'E:\FPGA_project\total_project\src\arm_target.v'
s = io.open(p, encoding='utf-8').read()

s = s.replace("""    // 速度上限（Q25 rad/tick）：26348 ≈ 90 °/s，17565 ≈ 60，8790 ≈ 30
    parameter integer VMAX_W   = 26348,
    // 旋转速度（同上）。演示想要更慢就调这里，别调 VMAX（回零用得到）
    parameter integer ROT_W    = 26348,
    parameter integer ROT_DIR  = 1           // 1=显示角度增大方向，-1=反向""",
"""    // 速度上限（Q25 rad/tick）：26348 ≈ 90 °/s，17565 ≈ 60，8790 ≈ 30
    parameter integer VMAX_W   = 26348
    // 旋转速度/方向改为运行期输入（菜单可改），不再用 parameter""")

s = s.replace("""    input  wire               rot_hold,      // 长按 P12：1=正在旋转""",
"""    input  wire               rot_hold,      // 1 = 正在旋转（保持方向）
    input  wire [15:0]        rot_w,         // 旋转速度 Q25 rad/tick（≈ °/s × 293）
    input  wire               rot_dir,       // 1 = 顺时针方向，0 = 逆时针方向""")

s = s.replace("""                S_HOLD: begin
                    tgt <= tgt_ww;
                    if (rot_hold) w <= ramp(w, ROT_DIR ? ROT_W : -ROT_W);
                    else          w <= ramp(w, 32'sd0);
                end""",
"""                S_HOLD: begin
                    tgt <= tgt_ww;
                    if (rot_hold) w <= ramp(w, rot_dir ? rot_w_s : -rot_w_s);
                    else          w <= ramp(w, 32'sd0);
                end""")

s = s.replace("""    wire signed [31:0] tgt_sum = tgt + w;""",
"""    // 旋转速度输入转成 32 位有符号（0~65535 足够：90 °/s = 26348）
    wire signed [31:0] rot_w_s = {16'd0, rot_w};

    wire signed [31:0] tgt_sum = tgt + w;""")

io.open(p, 'w', encoding='utf-8').write(s)
print('arm_target:', 'ROT_W' not in s.split('endmodule')[0].split('input  wire [15:0]        rot_w')[1])

# ===================== mode_fsm：命令驱动 =====================
mode = '''//=============================================================================
// mode_fsm.v — 运行模式状态机（菜单命令驱动版）
//
//   M_OFF  : 断电 —— 电机停转，bal_en/sw_en 全 0
//   M_BAL  : LQR 闭环平衡（上电后 |θ| 已在安全窗内，或起摆交棒后）
//   M_SW   : 能量法起摆，进入交棒窗口后自动切 M_BAL
//   M_FAULT: ADC 失联封锁，需重新上电清除
//
// 命令（都由菜单按键产生，单拍脉冲）：
//   cmd_zero 定点：仅非平衡/非起摆时接受（平衡中改基准会瞬间跳目标）
//   cmd_on   上电：|θ| < TH_SAFE 直接平衡，否则先起摆
//   cmd_off  断电：任何状态都立即停机
//
// 安全：平衡中 |θ| 超出 TH_SAFE 自动断电（防止发散后满速甩摆）
//=============================================================================
`timescale 1ns/1ps

module mode_fsm #(
    parameter signed [15:0] TH_SAFE_Q12 = 16'sd2048   // 0.5 rad ≈ 28.6°
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               tick,

    input  wire               cmd_zero,
    input  wire               cmd_on,
    input  wire               cmd_off,

    input  wire               adc_err,
    input  wire signed [15:0] th,
    input  wire               sw_ready,

    output reg  [1:0]         mode,
    output reg                bal_en,
    output reg                sw_en,
    output reg                zero_pulse
);

    localparam [1:0] M_OFF = 2'd0, M_BAL = 2'd1, M_FAULT = 2'd2, M_SW = 2'd3;

    wire signed [16:0] th_ext = {th[15], th};
    wire signed [16:0] th_abs = th_ext[16] ? -th_ext : th_ext;
    wire               th_ok  = (th_abs < {TH_SAFE_Q12[15], TH_SAFE_Q12});

    // 定点只能在停机状态做（与 zzh 的 zero_cmd 条件一致）
    wire zero_ok = cmd_zero && (mode == M_OFF);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) zero_pulse <= 1'b0;
        else        zero_pulse <= zero_ok;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode   <= M_OFF;
            bal_en <= 1'b0;
            sw_en  <= 1'b0;
        end else if (adc_err) begin
            mode   <= M_FAULT;
            bal_en <= 1'b0;
            sw_en  <= 1'b0;
        end else if (cmd_off) begin
            // 断电优先级最高：立即停机
            mode   <= M_OFF;
            bal_en <= 1'b0;
            sw_en  <= 1'b0;
        end else if (tick) begin
            case (mode)
                M_OFF: begin
                    if (cmd_on) begin
                        if (th_ok) begin           // 已经立着：直接闭环
                            mode   <= M_BAL;
                            bal_en <= 1'b1;
                            sw_en  <= 1'b0;
                        end else begin             // 垂着：先起摆
                            mode   <= M_SW;
                            bal_en <= 1'b0;
                            sw_en  <= 1'b1;
                        end
                    end
                end

                M_SW: begin
                    if (cmd_on) begin              // 起摆中再按上电 = 重新判定
                        if (th_ok) begin
                            mode   <= M_BAL;
                            bal_en <= 1'b1;
                            sw_en  <= 1'b0;
                        end
                    end else if (sw_ready) begin   // 进入交棒窗口
                        mode   <= M_BAL;
                        bal_en <= 1'b1;
                        sw_en  <= 1'b0;
                    end
                end

                M_BAL: begin
                    if (!th_ok) begin              // 摔倒：自动断电
                        mode   <= M_OFF;
                        bal_en <= 1'b0;
                    end
                end

                M_FAULT: begin
                    if (cmd_on) begin              // 故障解除后重新上电
                        mode   <= M_OFF;
                        bal_en <= 1'b0;
                        sw_en  <= 1'b0;
                    end
                end

                default: begin
                    mode   <= M_OFF;
                    bal_en <= 1'b0;
                    sw_en  <= 1'b0;
                end
            endcase
        end
    end

endmodule
'''
io.open(r'E:\FPGA_project\total_project\src\mode_fsm.v', 'w', encoding='utf-8').write(mode)
print('mode_fsm 已重写（命令驱动）')