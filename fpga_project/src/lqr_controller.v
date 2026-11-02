//=============================================================================
// lqr_controller.v  —  LQR 状态反馈（定点，1kHz）
//
// 控制律：u_duty = -(C1·(α-α_ref) + C2·α̇ + C3·θ + C4·θ̇) >> 12
//
// ★ α 参考点 α_ref（en 下降沿期间跟随，en=1 后冻结）
//   α 是绝对臂角（已缠绕 ±π）。若直接送进控制器，进入平衡瞬间臂角落在哪，
//   LQR 就会拼命把臂"拉回 0 位"。实测 α=±π 时 C1·α 折算约 1071/2500 = 43% 占空比，
//   按键瞬间电机猛冲一下，会把摆杆甩出去。所以必须用 (α − α_ref)，
//   且 α_ref 在进入平衡（bal_en 上升沿）那一刻采样，之后保持不变。
//   差值再做一次 ±π 缠绕（两端各在 ±π，差可达 ±2π）。
//
// ★ 状态顺序按 lqr_gain.m 的 A/B 矩阵结构确定：[α, α̇, θ, θ̇]
//   依据：A(4,3)=mgl(I+mr²)/Q_eq=+259.4 > 0 是倒立摆的不稳定项，乘的是 x3
//         且 x0=[0;0;0.1745;0] 给的 10° 初值也落在 x3 上。
//   注意：doc/README.md 里写的 u=-(k1θ+k2θ̇+k3(α-αref)+k4α̇) 把 k1/k3 弄反了。
//
// 原始增益（MATLAB dlqr，Q=diag(50,25,50,10)，R=1，Ts=20ms）：
//   k1=-1.6349(α)  k2=-1.7563(α̇)  k3=+26.8000(θ)  k4=+2.3682(θ̇)   [单位：伏特]
//
// 定点换算（u 伏特 -> 占空比，满量程 12V 对应 ±2500）：
//   C_i = k_i × (2500/12) × 4096 / 2^Q_i        Q_i: α/θ 为 12，α̇/θ̇ 为 10
//   C1 = -340.6 → -341      C2 = -1463.6 → 原 -1464，现 -730（×0.5）
//   C3 = +5583.3 → +5583    C4 = +1973.5 → +1974
//
// ★ 为什么 C2 减半（2026-10-28，降噪定案）
//   α̇ 来自 5→20ms 测速窗的计数差，最小量化台阶 = ±1 计数。这个台阶乘上 C2 会让
//   控制量在零点附近来回跳，是"嗡嗡"声的主要来源之一。用定点模型扫描（scratch_tune.py）：
//     C2×1.0 → |Δu|=5.5  C2×0.7 → 1.5  C2×0.5 → 1.7（且扰动恢复更快）
//     C2×0.3 → 4.2（太软，静态开始晃）   C2×0   → 失稳
//   即"必需但不能配大"，0.5~0.7 是甜点。C4 相反：×0.6 直接发散（提供相位超前，不是阻尼），
//   绝对不能动。
//
// 已验证：该组系数在 1kHz 闭环下 4s 内收敛，|u| 峰值 4.68V（不饱和）
//=============================================================================
`timescale 1ns/1ps

module lqr_controller #(
    parameter signed [15:0] U_LIMIT = 16'sd2500, // 占空比限幅（±12V 对应 2500）
    parameter integer U_LP_SHIFT = 4             // 输出一阶低通（每 1ms），0 = 不滤
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               tick,             // 1kHz
    input  wire               en,               // 1 = 闭环运行（bal_en）

    //---------------- 四个增益由寄存器输入（默认值见 param_link）----------------
    //   默认值在顶层 parameter 里（LQR_C1..C4），上电由 cfg_regs 复位成同一组，
    //   之后可通过串口 0x10~0x13 改。范围卡 ±8191，否则下面的 32 位 acc 会溢出。
    input  wire signed [15:0] C1,               // α   (Q12 状态)
    input  wire signed [15:0] C2,               // α̇  (Q10 状态)
    input  wire signed [15:0] C3,               // θ   (Q12 状态)
    input  wire signed [15:0] C4,               // θ̇  (Q10 状态)
    input  wire signed [15:0] al_ref_in,        // 臂目标角 Q12（由 arm_target 产生）
    input  wire signed [15:0] wref,             // 目标角速度 Q10 rad/s（速度前馈）
    input  wire signed [15:0] al,               // Q12 rad（已缠绕 ±π）
    input  wire signed [15:0] ald,              // Q10 rad/s
    input  wire signed [15:0] th,               // Q12 rad
    input  wire signed [15:0] thd,              // Q10 rad/s
    output reg  signed [15:0] u_duty            // ±U_LIMIT
);

    //---------------- α 参考点 ----------------
    // ★ 2026-11-01：α_ref 不再在本模块内部采样，改由 arm_target 统一产生。
    //   原来这里是 "if (!en) al_ref <= al;"，进平衡瞬间把目标锁在当前臂角——
    //   无扰接合是对的，但同时也意味着"控制器没有绝对目标，臂在哪哪就是 0"，
    //   所以臂永远回不到基准点。现在目标由外部给定，可为定点点、可为斜坡。
    localparam signed [16:0] PI_Q12     =  17'sd12868;   // π  ×4096 = 12867.96
    localparam signed [16:0] TWO_PI_Q12 =  17'sd25736;   // 2π ×4096 = 25735.9

    wire signed [16:0] al_d17  = {al[15], al} - {al_ref_in[15], al_ref_in};
    wire signed [16:0] al_rel  = (al_d17 >= PI_Q12)  ? (al_d17 - TWO_PI_Q12) :
                                 (al_d17 < -PI_Q12)  ? (al_d17 + TWO_PI_Q12) : al_d17;

    // 速度前馈：C2 吃的是"实际角速度 - 目标角速度"
    //   匀速旋转时 α̇ = wref，这一项归零；不加前馈的话，90 °/s 的稳态滞后达 158°，
    //   C1 项会直接打满 U_LIMIT，臂根本转不起来。
    wire signed [16:0] ald_eff = {ald[15], ald} - {wref[15], wref};

    // 4 项乘积（每个 16×16 -> 32 位有符号）
    wire signed [31:0] p1 = C1 * al_rel;
    wire signed [31:0] p2 = C2 * ald_eff;
    wire signed [31:0] p3 = C3 * th;
    wire signed [31:0] p4 = C4 * thd;

    // 最坏情况 4×(5583×32767) = 7.3e8，32 位有符号(2.1e9)可容纳
    wire signed [31:0] acc = p1 + p2 + p3 + p4;
    wire signed [31:0] u_raw = -(acc) >>> 12;

    //---------------- 限幅 + 输出低通 ----------------
    // ★ 为什么输出还要滤：微分项已经把噪声压下来了，但残留的量化抖动仍会让占空比
    //   在 0 附近每毫秒反复穿越 —— 实测每秒反向 233 次。加一级低通后降到 92 次，
    //   每次跳变幅度也从 13 降到 5/2500。U_LP_SHIFT=3 即 τ=8ms，
    //   相对摆杆 62ms 的不稳定时间常数仍可忽略（模型里改善主要是 |Δu| 再降一档）。
    wire signed [15:0] u_sat = (u_raw >  $signed({1'b0, U_LIMIT})) ?  U_LIMIT :
                               (u_raw < -$signed({1'b0, U_LIMIT})) ? -U_LIMIT : u_raw[15:0];

    // 限幅结果先打一拍（每时钟都打，不是每 tick）：
    // 乘法→累加→限幅→滤波若全串在一级，实测 WNS 只剩 +0.071ns。
    // 观察器输出本身是 tick 寄存器，这里再打一拍不增加任何控制延迟（20ns）。
    reg signed [15:0] u_sat_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) u_sat_r <= 16'sd0;
        else        u_sat_r <= u_sat;
    end

    reg signed [15:0] u_f;
    wire signed [16:0] u_err  = {u_sat_r[15], u_sat_r} - {u_f[15], u_f};
    wire signed [16:0] u_step = u_err >>> U_LP_SHIFT;
    wire signed [15:0] u_step16 = u_step[15:0];   // 部分选择是无符号的，显式重解释

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            u_duty <= 16'sd0;
            u_f    <= 16'sd0;
        end else if (!en) begin
            u_f    <= 16'sd0;           // 待机/故障：滤波器归零，进平衡时从 0 平滑起
            u_duty <= 16'sd0;
        end else if (tick) begin
            u_f    <= u_f + u_step16;
            u_duty <= u_f + u_step16;   // 与 u_f 同拍输出，避免多一拍延迟
        end
    end

endmodule
