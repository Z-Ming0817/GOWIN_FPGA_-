//=============================================================================
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

    //---------------- 上电命令锁存 ----------------
    // ★ cmd_on 只有 1 个时钟宽，而本机只在 tick（2000Hz）上判决，
    //   直接采会漏掉 99.99% 的按键（实测表现：按上电没反应）。
    //   这里锁存到下一个 tick 再消费，置位优先，避免与 tick 同拍时被吞掉。
    reg pend_on;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        pend_on <= 1'b0;
        else if (cmd_on)   pend_on <= 1'b1;     // 置位优先
        else if (tick)     pend_on <= 1'b0;     // 由 tick 消费
    end

    // 定点只在停机状态接受（平衡/起摆中改基准会让目标瞬跳）
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
                    if (pend_on) begin
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
                    if (pend_on) begin             // 起摆中再按上电 = 重新判定
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
                    if (pend_on) begin             // 故障解除后重新上电
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
