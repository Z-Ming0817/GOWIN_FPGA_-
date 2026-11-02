//=============================================================================
// encoder_decoder.v  —  MG513 正交编码器解码（AB 相 4 倍频 + 位置 + 测速）
//
// 功能：
//   · AB 两相各 2 级同步，抑制亚稳态
//   · 4 倍频解码：A、B 的每个边沿都计数（分辨率 = 单相 PPR × 4）
//   · pos        32 位有符号累计位置（掉电不保持，复位清零）
//   · speed      固定窗口内的计数差（有符号 16 位），窗口默认 20ms
//   · speed_valid 窗口结束脉冲
//
// 单位换算（下游做，本模块只出原始计数）：
//   每圈计数 = PPR × 4 × 减速比     例：13 × 4 × 20 = 1040 count/圈
//   角速度  = speed / (SPEED_DIV/CLK_FREQ) / 1040 × 360  [度/秒]
//
// 为什么窗口取 20ms：
//   窗口越短，±1 计数的量化误差越被放大。5ms 窗下 1 计数 = 0.0496 rad/s，
//   乘上 C2 后折算成几十个 duty 的台阶，成为"嗡嗡"声的直接来源；
//   20ms 窗下 1 计数只有 0.0124 rad/s（÷4）。代价是 20ms 的零阶保持滞后，
//   相对摆杆 62ms 的不稳定时间常数仍可接受，且模型里扰动恢复反而更快。
//=============================================================================
`timescale 1ns/1ps

module encoder_decoder #(
    parameter CLK_FREQ  = 50_000_000,
    parameter SPEED_DIV = 1_000_000,     // 20ms @50MHz
    // 窗口差用插值位置 pos_q4 而不是整数 pos，speed 输出随之变 Q4。
    //   窗长、时基、除法器一律不动 —— 只把"窗口端点"从整数 count 换成亚计数位置，
    //   量化台阶 1 count → ~1/10 count，而滞后一拍不增加。
    //   SPD_Q4=0 时逐位等价于老版本（回退开关）。
    parameter integer SPD_Q4 = 0
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               enc_a,
    input  wire               enc_b,
    input  wire signed [31:0] pos_q4,     // A7 插值位置（Q4）；SPD_Q4=0 时忽略
    output reg  signed [31:0] pos,        // 4 倍频累计计数
    output reg  signed [15:0] speed,      // 每窗口计数差（SPD_Q4=1 时是 Q4）
    output reg                speed_valid,
    output reg                dir,        // 1=正向，0=反向（无变化时保持）
    output reg  signed [15:0] speed_t     // ★ T 法，Q4 定标（值 = count/20ms × 16）
);

    //------------------------------------------------------------------
    // 输入同步
    //------------------------------------------------------------------
    reg [1:0] a_s, b_s;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_s <= 2'b00;
            b_s <= 2'b00;
        end else begin
            a_s <= {a_s[0], enc_a};
            b_s <= {b_s[0], enc_b};
        end
    end

    wire [1:0] q_now  = {a_s[1], b_s[1]};
    reg  [1:0] q_prev;

    //------------------------------------------------------------------
    // 4 倍频解码
    //------------------------------------------------------------------
    reg signed [1:0] delta;

    always @(*) begin
        case ({q_prev, q_now})
            4'b00_01, 4'b01_11, 4'b11_10, 4'b10_00: delta = 2'sd1;
            4'b00_10, 4'b10_11, 4'b11_01, 4'b01_00: delta = -2'sd1;
            default:                                delta = 2'sd0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_prev <= 2'b00;
            pos    <= 32'sd0;
            dir    <= 1'b1;
        end else begin
            q_prev <= q_now;
            if (delta != 2'sd0) begin
                pos <= pos + {{30{delta[1]}}, delta};
                dir <= (delta > 0);
            end
        end
    end

    //------------------------------------------------------------------
    // M 法测速：固定窗口内的计数差
    //------------------------------------------------------------------
    reg [31:0] win_cnt;
    reg signed [31:0] pos_last;

    // 窗口端点取插值位置（Q4）时，dpos 直接就是 Q4 计数，speed 输出 Q4，
    //   下游 SPEED_SH=4 的解释不变，spd_m_q4 不再左移。
    wire signed [31:0] pos_win = (SPD_Q4 != 0) ? pos_q4 : pos;
    wire signed [31:0] dpos = pos_win - pos_last;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win_cnt     <= 32'd0;
            pos_last    <= 32'sd0;
            speed       <= 16'sd0;
            speed_valid <= 1'b0;
        end else begin
            speed_valid <= 1'b0;

            if (win_cnt == SPEED_DIV - 1) begin
                win_cnt     <= 32'd0;
                pos_last    <= pos_win;
                speed_valid <= 1'b1;
                if (dpos > 32'sd32767)
                    speed <= 16'sd32767;
                else if (dpos < -32'sd32768)
                    speed <= 16'sh8000;          // -32768
                else
                    speed <= dpos[15:0];
            end else begin
                win_cnt <= win_cnt + 1'b1;
            end
        end
    end

    //------------------------------------------------------------------
    // T 法测速（2026-10-29）
    //
    // 原理：测相邻边沿的间隔 dt（50MHz），换算成"若保持这个速度，20ms 会走多少 count"
    //       speed_t = 0.02 × CLK_FREQ / dt = 1_000_000 / dt        （50MHz，整数版）
    //   ★ 2026-10-29 00:30 改为 Q4（×16）：
    //       speed_t = 16_000_000 / dt  →  值 = count/20ms × 16
    //   为什么必须乘 16：整数版 speed_t 的分辨率仍然只有 1 count，和 M 法完全一样，
    //   那 T 法就只剩"更吵"这一个特征了（实测稳态 σ 1.46 vs M 法 0.49）。
    //   真正的价值在亚计数分辨率：平衡时 α̇ 只有 2.3 count，Q4 后是 36.8，
    //   C2 看到的是一根连续曲线而不是 2↔3 的台阶（台阶高 121 duty，正是粘滑触发器）。
    //
    // 实现：24 次迭代恢复余数除法（1 个组合减法器 + 24 拍状态机）
    //   50MHz 下 24 拍 = 480ns，远小于最短边沿间隔（0.3ms @20rad/s），
    //   新边沿到来时直接重启除法（永远算最新的 dt）。
    //
    // 边界：
    //   · dt 上限钳到 2_000_000（40ms）→ 最慢输出 8（= 0.5 count）
    //   · dt > 5_000_000（100ms）无边沿 → 判零速（静止时必须清掉旧值）
    //   · 商 > 32767（2048 count）→ 饱和，防止绕回负数
    //   · 方向用边沿时刻锁存的 dir_lat，避免除法过程中方向变了
    //------------------------------------------------------------------
    localparam [23:0] T_NUM = 24'd16_000_000;   // 0.02s × 50MHz × 16（Q4）

    reg [31:0] t_now;         // 自由计数器
    reg [31:0] t_last;        // 上一边沿时刻
    reg [31:0] dt_raw;
    reg        dir_lat;

    reg        t_stale;       // 1=已判零速，等下一个边沿才恢复
    reg [5:0]  dv_st;         // 0=idle, 1..24=迭代, 25=输出
    reg [24:0] dv_rem;        // rem < den ≤ 2^21，移位后 < 2^22，25 位足够
    reg [23:0] dv_quo;
    reg [20:0] dv_den;

    wire        is_edge = (delta != 2'sd0);
    wire [4:0]  dv_idx  = 5'd24 - dv_st[4:0];   // dv_st=1→bit23(MSB) … 24→bit0(LSB)
    wire [24:0] rem_sh  = {dv_rem[23:0], T_NUM[dv_idx]};
    wire        rem_ge  = (rem_sh >= {4'b0, dv_den});
    wire [31:0] dt_live = t_now - t_last;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t_now   <= 32'd0;
            t_last  <= 32'd0;
            dt_raw  <= 32'd0;
            dir_lat <= 1'b1;
            dv_st   <= 6'd0;
            dv_rem  <= 25'd0;
            dv_quo  <= 24'd0;
            dv_den  <= 21'd1;
            t_stale <= 1'b0;
            speed_t <= 16'sd0;
        end else begin
            t_now <= t_now + 1'b1;

            if (is_edge) begin
                // 新边沿：锁存间隔、重启除法
                dt_raw  <= dt_live;
                dir_lat <= (delta > 0);
                dv_den  <= (dt_live > 32'd2_000_000) ? 21'd2_000_000
                                                     : dt_live[20:0];
                dv_st   <= 6'd1;
                dv_rem  <= 25'd0;
                dv_quo  <= 24'd0;
                t_stale <= 1'b0;
                t_last  <= t_now;
            end else if (dt_live > 32'd5_000_000) begin
                // 超时 100ms 无边沿：判零速，并锁住直到下一个边沿
                speed_t <= 16'sd0;
                dv_st   <= 6'd0;
                t_stale <= 1'b1;
            end else if (!t_stale && dv_st == 6'd0 && dt_raw != 32'd0
                         && dt_live > dt_raw) begin
                // ★ 盲窗重算（2026-10-29 00:40）
                // 问题：平衡时臂的 α̇ 只有 2.3 count/20ms，换向点附近长时间没有边沿，
                //   纯 T 法只能**保持上一次读数** → 用旧速度、旧方向持续几十毫秒。
                //   C2=1800 时 1 count = 136 duty，等于每次换向都朝反方向推一把。
                // 做法：一旦实时间隔超过"上一次的间隔"，说明臂在减速，
                //   就用 dt_live 重新做一次除法。speed_t ∝ 1/dt，于是它沿 1/dt
                //   连续衰减：20ms→1.0 count，40ms→0.5，60ms→0.31，100ms→0。
                //   这正好是"减速到静止"的物理形状，且不需要额外的衰减逻辑。
                dv_den  <= (dt_live > 32'd2_000_000) ? 21'd2_000_000
                                                     : dt_live[20:0];
                dv_st   <= 6'd1;
                dv_rem  <= 25'd0;
                dv_quo  <= 24'd0;
            end else if (dv_st >= 6'd1 && dv_st <= 6'd24) begin
                if (rem_ge) begin
                    dv_rem <= rem_sh - {4'b0, dv_den};
                    dv_quo[dv_idx] <= 1'b1;
                end else begin
                    dv_rem <= rem_sh;
                end
                dv_st <= dv_st + 1'b1;
            end else if (dv_st == 6'd25) begin
                // 商已稳定
                if (dir_lat) speed_t <= (dv_quo > 24'd32767) ? 16'sd32767
                                                            : $signed({1'b0, dv_quo[14:0]});
                else         speed_t <= (dv_quo > 24'd32767) ? -16'sd32767
                                                            : -$signed({1'b0, dv_quo[14:0]});
                dv_st <= 6'd0;
            end
        end
    end

endmodule
