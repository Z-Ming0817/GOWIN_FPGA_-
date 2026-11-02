//=============================================================================
// swing_ctrl.v  —  能量法起摆控制器（2026-10-28）
//
// 目标：摆杆从自然下垂（θ = ±180°）自动荡起，进入 |θ| < 25° 且 |θ̇| < 1 rad/s
//       后把 ready 拉高，由 mode_fsm 交给 LQR 接管。
//
// 原理（Åström 能量泵）：
//   归一化能量   E = ½(θ̇/ω0)² + (cos θ − 1)        （竖直向上静止 E = 0，下垂静止 E = −2）
//   臂的加速度 u 在摆杆上产生的功率 ∝ −u·θ̇·cos θ，所以取
//       u = K · E · sign(θ̇ · cos θ)
//   就把 E 往 0 推：E < 0 顺着 θ̇ 推；E > 0 反着推，自动泄能。
//
// ω0 用实测值：T0 = 0.64 s → ω0 = 9.817 rad/s（W0_Q10 = 10053）。
//   ★ 不要用 MATLAB 模型里的数：模型 A(4,3)=259.4 对应 ω0=16.1、T0=0.39 s，
//     与实测差 1.6 倍，说明建模时的摆杆尺寸和实物不一致。起摆必须用实测 ω0。
//
// cos θ 不查表：取抛物线近似 cos θ ≈ 1 − 2θ²/π²，
//   在 θ = 0 和 θ = ±π 处精确，最大误差 0.056（出现在 ±90°），
//   相对能量的满量程 2.0 只有 2.8%。能量判据只要这个精度，省掉一个 LUT 和取模。
//
// ★ θ 是"以 2π 为周期的锯齿"（电位器跳变点造成）。实测跳变点在离直立 112° 处，
//   起摆每次上扬都会踩过去，所以先折回 ±π 再用。跳变本身由 state_observer 的
//   jump 保护兜住，这边不需要额外处理。
//
//=============================================================================
// ★★ 2026-10-28 15:10 上板第二版：治"贴底剧烈抖动"
//
//   现象：SW_K 提到 5000 之后，摆杆停在下垂位附近剧烈抖动、起不来。
//   原因：u 的大小被 E 顶满（|u|=2500），而**方向只由 sign(θ̇·cosθ) 决定**。
//        下垂位静止时 θ̇ 全是噪声（σ≈1rad/s，DTH_N=4 差分后又放大到几 rad/s），
//        符号每几毫秒翻一次 —— 电机就在 ±2500 之间满幅反向，听起来就是嗡嗡猛抖，
//        而且正负能量互相抵消，一辈子也起不来。
//
//   两条修法：
//   ① 速度死区 SW_VDB（默认 3072 = 3.0 rad/s）：
//        |θ̇| 低于死区时输出直接给 0。真实摆动峰值 10~20 rad/s，轻松越过；
//        噪声永远越不过。抖动从根上没了。
//        代价：折返点附近（θ̇ 天然过零）泵会短暂停一下，但那里 θ̇≈0，
//        本来也做不了功，物理上无损。
//   ② "贴底起动" assist 状态机，替代原来靠 |θ̇|<阈值的"第一脚"：
//        判据改成【位置】—— |θ| 在离下垂 30° 以内连续待够 300ms，就给 80ms 的
//        恒定推力把它推起来。位置判据不受噪声影响，也不会在每次折返点误触发
//        （老版本的 kick 在每个折返点都会白给一脚固定方向的力，一周期两次，
//         这是 ±75° 上不去的直接原因之一）。
//=============================================================================
`timescale 1ns/1ps

module swing_ctrl #(
    parameter signed [15:0] U_LIMIT   = 16'sd2500,   // 输出限幅（与 LQR 的 U_LIMIT 同源）
    parameter integer       W0_Q10    = 10053,       // ω0 = 9.817 rad/s（实测 T0=0.64s）
    parameter integer       SW_K      = 5000,        // 泵增益：E 过半就饱和，等价恒幅 bang-bang
    parameter signed [15:0] THD_CATCH = 16'sd4048,   // 交棒角速度窗 1.0 rad/s
    parameter integer       SW_SIGN   = 1,           // 方向，错了取反
    parameter integer       SW_VDB    = 16'sd3072,   // ★ 速度死区 3.0 rad/s：低于它不输出
    parameter integer       PARK_TICK = 600,         // 贴底判定 300ms ★ 按 tick 换算：
                                                     //   600/2000Hz = 300ms（1200Hz 时代是 360）
                                                     //   位宽 10 位，上限 1023 —— 采样率再高要扩位
    parameter integer       ASSIST_TICK = 160        // 起动推力持续 80ms（160/2000Hz）
                                                     //   位宽 8 位，上限 255 —— 别超过 255
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               tick,      // 控制节拍 ≈2000 Hz（= ADS_SPS）
    input  wire               en,        // 1 = 起摆模式生效
    input  wire signed [15:0] th_catch,  // 交棒角度窗，Q12（可串口写 0x14）
    input  wire signed [15:0] th,        // Q12 rad（锯齿，未折回）
    input  wire signed [15:0] thd,       // Q10 rad/s
    input  wire signed [15:0] al,        // Q12 rad（本版未用，留作臂居中）
    output reg  signed [15:0] u_duty,    // ±U_LIMIT
    output reg                ready      // 1 = 已进入交棒窗口
);

    localparam signed [16:0] PI_Q12     = 17'sd12868;
    localparam signed [16:0] TWO_PI_Q12 = 17'sd25736;
    localparam signed [16:0] HALF_PI    = 17'sd6434;
    localparam integer       PSI_K      = (1024 * 4096 + W0_Q10 / 2) / W0_Q10;   // 417
    localparam               SW_S       = (SW_SIGN != 0) ? 1'b1 : 1'b0;

    localparam signed [16:0] HANG_LO    = 17'sd10650;   // 2.6 rad ≈ 150°，离下垂 30° 以内
    localparam signed [16:0] VDB_X      = {SW_VDB[15], SW_VDB};
    localparam signed [16:0] UMAX_X     = {U_LIMIT[15], U_LIMIT};

    //---------------- θ 折回 ±π ----------------
    // θ 的可达范围约 ±8 rad，一次折回后必然落在 ±π 内（3π=9.42 > 8）
    wire signed [16:0] th_x  = {th[15], th};
    wire signed [16:0] thf   = (th_x >  PI_Q12) ? (th_x - TWO_PI_Q12) :
                               (th_x < -PI_Q12) ? (th_x + TWO_PI_Q12) : th_x;
    wire signed [16:0] thf_a = thf[16] ? -thf : thf;

    //---------------- 动能项 ½(θ̇/ω0)²  （Q16）----------------
    // ψ = θ̇/ω0（无量纲，Q10）；ψ² 为 Q20。
    // ★ ½ψ² 的 Q16 值是 ψ²·65536/(2·2^20) = ψ²>>>5。
    //   旧版写成 >>>4（大了一倍）：底部动能算成 2 倍，E 从"恒定 −1"变成
    //   "峰值 −0.45、底部 +1.88"，泵在中段就自相残杀 —— 这是起不来的主因。
    wire signed [31:0] psi   = (thd * PSI_K) >>> 12;
    wire signed [31:0] psi2  = psi * psi;               // ≤ 1.11e7
    wire signed [31:0] e_kin = psi2 >>> 5;              // ≤ 350 k

    //---------------- 势能项 1 − cos θ  （Q16，32 格查表）----------------
    // ★ 旧版用抛物线 cos θ ≈ 1 − 2θ²/π²。它在 0 和 ±π 处精确，但在 ±90° 处
    //   给出 0.5，真值是 1.0 —— 误差 0.5，是满量程 2.0 的 25%。
    //   而起摆恰恰要在 90° 附近工作：势能少算一半 → E 被高估 0.5 → 泵以为
    //   快到位了，实际还差一半。这条和上面那条一起，让 E 在一个周期内乱跳。
    //
    //   改用查表：|θ| 每 512 码（7.16°）一格，共 26 格用得上，取格中点值。
    //   误差：近直立（<20°）< 0.003；90° 处最大 0.062（那里泵已饱和，无影响）。
    //   代价：26×18 bit 组合表 ≈ 120 LUT，同时省掉原来那个平方乘法器。
    function [17:0] umc;               // 1 − cos(|θ|)，Q16
        input [13:0] a;                // |θ| Q12，0..12868（π）
        reg   [4:0]  ix;
        begin
            ix = a[13:9];              // /512
            case (ix)
                5'd0 : umc = 18'd128;
                5'd1 : umc = 18'd1149;
                5'd2 : umc = 18'd3174;
                5'd3 : umc = 18'd6173;
                5'd4 : umc = 18'd10097;
                5'd5 : umc = 18'd14887;
                5'd6 : umc = 18'd20468;
                5'd7 : umc = 18'd26751;
                5'd8 : umc = 18'd33640;
                5'd9 : umc = 18'd41027;
                5'd10: umc = 18'd48796;
                5'd11: umc = 18'd56826;
                5'd12: umc = 18'd64992;
                5'd13: umc = 18'd73167;
                5'd14: umc = 18'd81223;
                5'd15: umc = 18'd89033;
                5'd16: umc = 18'd96477;
                5'd17: umc = 18'd103439;
                5'd18: umc = 18'd109809;
                5'd19: umc = 18'd115487;
                5'd20: umc = 18'd120387;
                5'd21: umc = 18'd124431;
                5'd22: umc = 18'd127555;
                5'd23: umc = 18'd129712;
                5'd24: umc = 18'd130867;
                default: umc = 18'd131072;   // 25..31：|θ| 已到 π
            endcase
        end
    endfunction

    wire [13:0]  thf_abs = thf_a[13:0];                 // |θ| ≤ π = 12868 < 16384
    wire signed [31:0] e_pot = {14'd0, umc(thf_abs)};   // Q16，0..131072

    wire signed [31:0] e_nrg = e_kin - e_pot;           // Q16；下垂静止 = −131072（=−2.0）

    //---------------- 泵：能量误差 × 方向，带速度死区 ----------------
    // ★ 2026-10-30 23:35 插两级流水（T1）：
    //   原来 查表→减→32×16 乘→选向→饱和 全挤在一拍，实测成为全设计最差路径，
    //   且随布局在 −0.085 ~ −2.646 ns 之间大幅摆动（TNS 时好时坏，纯看运气）。
    //   两处都只在时钟沿打一拍 = 40 ns 延迟，而 tick 是 500 µs，等价于零影响。
    //   拆分后：段1 查表+减，段2 乘法，段3 选向+饱和，各约 7~8 ns。
    reg signed [31:0] e_nrg_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) e_nrg_r <= 32'sd0;
        else        e_nrg_r <= e_nrg;
    end

    reg signed [31:0] u_amp_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) u_amp_r <= 32'sd0;
        else        u_amp_r <= (e_nrg_r * SW_K) >>> 17;   // ∝ E，带符号
    end

    wire cos_neg = (thf_a > HALF_PI);                   // cos θ < 0 ⇔ |θ| > π/2
    wire v_dead  = (thd < VDB_X) && (thd > -VDB_X);     // ★ 死区：噪声永远进不来
    wire dir_live = thd[15] ^ cos_neg ^ SW_S;

    wire signed [31:0] u_pump32 = dir_live ? -u_amp_r : u_amp_r;
    wire signed [15:0] u_pump   = (u_pump32 >  UMAX_X) ?  U_LIMIT :
                                  (u_pump32 < -UMAX_X) ? -U_LIMIT : u_pump32[15:0];

    //---------------- 贴底起动：位置判据，不受噪声影响 ----------------
    reg  [9:0] park_cnt;
    reg  [7:0] as_cnt;
    reg        assist;

    wire near_hang = (thf_a > HANG_LO);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            park_cnt <= 10'd0;
            as_cnt   <= 8'd0;
            assist   <= 1'b0;
        end else if (!en) begin
            park_cnt <= 10'd0;
            as_cnt   <= 8'd0;
            assist   <= 1'b0;
        end else if (tick) begin
            if (!near_hang) begin
                // 一旦离开"贴底区"就全部清零：正常摆动时这里每周期都清零，
                // 所以 assist 只在真的停在下垂位时才可能触发
                park_cnt <= 10'd0;
                as_cnt   <= 8'd0;
                assist   <= 1'b0;
            end else if (assist) begin
                if (as_cnt >= ASSIST_TICK - 1) begin
                    assist <= 1'b0;
                    as_cnt <= 8'd0;
                end else begin
                    as_cnt <= as_cnt + 1'b1;
                end
            end else begin
                if (park_cnt >= PARK_TICK) begin
                    assist   <= 1'b1;      // 贴底 300ms：推一记
                    as_cnt   <= 8'd0;
                    park_cnt <= 10'd0;
                end else begin
                    park_cnt <= park_cnt + 1'b1;
                end
            end
        end
    end

    wire signed [15:0] u_assist = SW_S ? -U_LIMIT : U_LIMIT;
    wire signed [15:0] u_out    = assist   ? u_assist :
                                  v_dead   ? 16'sd0 : u_pump;

    //---------------- 交棒窗口 ----------------
    // ★ 阈值必须先落成 signed 常量：{TH_CATCH[15], TH_CATCH} 是拼接，结果无符号，
    //   拿它取负会绕成 131072−1024，比较就永远为假（实测 ready 恒 0）。
    // TH_CATCH 是端口（每拍跟着参数寄存器走），不能再当 localparam
    wire signed [16:0] TH_CATCH_X = {th_catch[15], th_catch};
    localparam signed [16:0] THD_CATCH_X = {THD_CATCH[15], THD_CATCH};

    wire catch_ok = (thf_a <  TH_CATCH_X) &&
                    (thd   <  THD_CATCH_X) &&
                    (thd   > -THD_CATCH_X);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            u_duty <= 16'sd0;
            ready  <= 1'b0;
        end else if (!en) begin
            u_duty <= 16'sd0;
            ready  <= 1'b0;
        end else if (tick) begin
            u_duty <= u_out;
            ready  <= catch_ok;
        end
    end

    // al 预留：后续要在起摆中加"臂居中"（|α|>90° 时轻微回拉）时接这里
    wire signed [15:0] al_unused = al;

endmodule
