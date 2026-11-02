//=============================================================================
// state_observer.v  —  4 状态观测：θ / θ̇ / α / α̇（全定点）
//
// 定点约定（下游必须按此）：
//   th   θ   Q12  有符号  rad    分辨 2.44e-4 rad (0.014°)  范围 ±8 rad
//   thd  θ̇  Q10  有符号  rad/s  分辨 9.8e-4 rad/s           范围 ±32 rad/s
//   al   α   Q12  有符号  rad    已缠绕到 ±π
//   ald  α̇  Q10  有符号  rad/s
//
// 换算系数推导：
//   θ: 电位器 345° 满行程 32768 码 → rad/code = 6.0214/32768 = 1.8375e-4
//        th_q12 = Δcode × 1.8375e-4 × 4096 = Δcode × 0.7526 = (Δcode × 193) >> 8
//   α: 每圈 COUNTS_PER_REV 计数 → rad/cnt = 2π/1040 = 6.0415e-3
//        al_q12 = acnt × 6.0415e-3 × 4096 = acnt × 24.75 = (acnt × 6336) >> 8
//   α̇: speed = 每 SPEED_DIV 的计数差
//        ald_q10 = speed × (CLK_FREQ/SPEED_DIV) × (2π/CPR) × 1024 = speed × KDOT_NUM
//        ★ 窗口取 20ms（不是 5ms）：speed 的最小量化台阶是 ±1 计数，
//          窗口越长同样的台阶代表的角速度越小（20ms 下 1 计数 = 0.0124 rad/s，
//          5ms 下是 0.0496 rad/s）。α̇ 直接乘 C2 进控制量，量化台阶会被放大成占空比跳动。
//   θ̇: 4 点差分（th_d1..th_d4 四级历史），Δt = 4/TICK_HZ
//        thd_q10 = Δth_q12 / 4096 × TICK_HZ/4 × 1024 = Δth × TICK_HZ / 16
//        代码写成 (Δth × TICK_HZ) >> 4：TICK_HZ=1200 时正好 ×75，
//        TICK_HZ=1000（仿真里 1ms 节拍）时正好 ×62.5，两种都是精确值。
//        ★ 为什么不用 1 点差分：ADC 有 ±1~3 码噪声，1 点差分把噪声放大 TICK_HZ 倍，
//          实测会让控制量每秒反向 476 次、每毫秒变化 81/2500 占空比 —— 电机高频嗡鸣。
//          4 点差分把微分噪声降到 1/4，而 3.3ms 滞后相对摆杆 62ms 的不稳定时间常数可忽略。
//        ★ TICK_HZ 必须等于 tick 的实际频率（顶层 = ADS_SPS），否则 θ̇ 整体比例错，
//          等效于把 C4 改了同样的比例 —— C4 又刚好贴近发散下限，标错会直接失稳。
//        ★ 2026-10-31：差分【端点】再加 THD_AVG_SH 点滑动平均（默认 2 = 4 点 / 2 ms）。
//          dth = (Σ近 N 点 − Σ远 N 点) / N，两簇中心仍相距 DTH_N 拍 → 增益逐位不变；
//          每个端点的 ADC 噪声方差 ÷N，θ̇ 噪声 ÷√N。θ 本身不过滤，C3 这条路零延迟。
//          实测（波动(1).txt 静止 18 s）：θ̇ rms 4.21 °/s ≈ 1.9 码 rms 的 ADC 噪声/8ms。
//
// α 为什么在计数层就缠绕：
//   α 是多圈累计值。若直接算 (α-α_ref)，转两圈后误差可达 4π，控制器输出爆表。
//   这里把 acnt 缠绕到 ±半圈，误差项天然有界，且不存在"过零点跳变"。
//=============================================================================
`timescale 1ns/1ps

module state_observer #(
    parameter integer CLK_FREQ       = 50_000_000,
    parameter integer SPEED_DIV      = 1_000_000,  // 20ms，必须与 encoder_decoder 一致
    parameter [15:0]  ANG_MID        = 16'd14920,  // 摆杆直立时 ADC 码值（2026-10-27 实测）
    parameter integer COUNTS_PER_REV = 1064,       // ★ 2026-10-31 20 圈实测（原按铭牌 1040）
    parameter integer KTH_NUM        = 322,        // θ 系数：π/(14920-4679)×4096×256
    // α 系数（Q8：rad/cnt × 4096 × 256）= round(2π×4096×256 / CPR)
    //   CPR=1040 → 6335（原写 6336）；CPR=1052 → 6263；CPR=1064 → 6192
    parameter integer KA_NUM         = 6192,
    parameter integer LPF_SHIFT      = 3,          // θ̇ 一阶低通（越大越平滑）
    parameter integer TICK_HZ        = 1200,       // 控制节拍频率 = ADC 转换率（θ̇ 的 Δt 依据）
                                                   // ★ 顶层显式传 ADS_SPS=2000；默认值仅供单模块 tb 使用
    parameter integer DTH_N          = 4,          // θ̇ 差分窗（tick 数）：4=3.33ms，8=6.67ms（噪声÷2）
    // ★ 2026-10-31 21:2x：差分【端点】滑动平均（只作用于 θ̇，θ 本身不过滤，C3 零延迟）
    //   0 = 关闭（数值等价老版本，仅求和寄存器带来 1 tick = 0.5 ms 附加延迟）
    //   1 = 2 点（1.0 ms）→ 原始导数噪声 ÷1.41，估计点后移 0.5 tick
    //   2 = 4 点（2.0 ms）→ ÷2.00，后移 1.5 tick = 0.75 ms
    //   3 = 8 点（4.0 ms）→ ÷2.83，后移 3.5 tick = 1.75 ms
    //   原理：dth = (Σ前 N 点 − Σ后 N 点) / N，两点簇的中心相距仍是 DTH_N 拍，
    //         所以角速度增益逐位不变，只把每个端点的噪声方差除以 N。
    //   ★ N 不是越大越好：原始导数噪声按 1/√N 降，但输出相关性也变强，
    //     后面 LPF_SHIFT 那一级对相关信号几乎不再平均。仿真实测（tb_obs_avg）
    //     "显示节点"的净降噪比：2 点 1.15× / 4 点 1.39× / 8 点 ~2.0×。
    //   实测依据：静止 18 s 段 θ̇ rms 4.21 °/s，折回 θ 是 1.9 码 rms（1 码=0.0176°）。
    //   窗口端点仍由 DTH_N 决定，与 THD_AVG_SH 正交，可分别扫。
    parameter integer THD_AVG_SH     = 3,
    parameter integer SPEED_SH       = 0,          // speed 的定标右移：0=整数 count（M 法）
                                                   //   4=T 法 Q4（顶层传 4），等效于 KDOT_NUM/16
    // pos 的定标。POS_SH=4 表示 pos 进来的是 Q4 计数（亚计数插值），
    //   缠绕边界同样左移 4 位、al 的换算右移多 4 位。POS_SH=0 时逐位等价于老版本。
    parameter integer POS_SH         = 0
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               tick,                // 控制节拍（顶层由 adc_valid 驱动 = ADS_SPS）
    input  wire [15:0]        adc_code,
    input  wire signed [31:0] pos,
    input  wire signed [15:0] speed,

    output reg  signed [15:0] th,
    output reg  signed [15:0] thd,
    output reg  signed [15:0] al,
    output reg  signed [15:0] ald
);

    // 每圈计数（半圈用于缠绕判决）
    // POS_SH 位对齐 —— pos 是 Q4 时边界与 acnt 同步左移，换算时再右移回来
    localparam signed [16:0] HALF_REV = (COUNTS_PER_REV / 2) << POS_SH;
    localparam signed [16:0] FULL_REV = COUNTS_PER_REV << POS_SH;

    // α̇ 系数 = (CLK_FREQ/SPEED_DIV) × (2π/CPR) × 1024，用 ×4/4096 保持与 KA_NUM 同源
    //   20ms → VEL_RATE=50 → 50×6336×4/4096 = 309.4 → 309
    localparam integer VEL_RATE = CLK_FREQ / SPEED_DIV;
    localparam integer KDOT_NUM = (VEL_RATE * KA_NUM * 4 + 2048) / 4096;   // 四舍五入

    //==================================================================
    // 1. θ：ADC 码值 → Q12 弧度
    //==================================================================
    wire signed [31:0] dcode   = $signed({16'd0, adc_code}) - $signed({16'd0, ANG_MID});
    wire signed [31:0] th_full = (dcode * KTH_NUM) >>> 8;

    //==================================================================
    // 2. α：累计计数 → 缠绕 ±半圈 → Q12 弧度
    //==================================================================
    reg  signed [31:0] pos_d;
    reg  signed [15:0] acnt;

    wire signed [31:0] dpos     = pos - pos_d;
    wire signed [16:0] acnt_nxt = $signed(acnt) + $signed(dpos[16:0]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pos_d <= 32'sd0;
            acnt  <= 16'sd0;
        end else begin
            pos_d <= pos;
            if (dpos != 32'sd0) begin
                if (acnt_nxt >= HALF_REV)
                    acnt <= acnt_nxt - FULL_REV;
                else if (acnt_nxt < -HALF_REV)
                    acnt <= acnt_nxt + FULL_REV;
                else
                    acnt <= acnt_nxt;
            end
        end
    end

    wire signed [31:0] al_full = (acnt * KA_NUM) >>> (8 + POS_SH);

    //==================================================================
    // 3. θ̇ / α̇：控制节拍更新（TICK_HZ）
    //==================================================================
    reg  signed [15:0] th_d1, th_d2, th_d3, th_d4;   // 1/2/3/4 个 tick 前的 θ
    reg  signed [15:0] th_d5, th_d6, th_d7, th_d8;   // 5..8（DTH_N>4 时用）
    reg  signed [15:0] th_d9, th_d10, th_d11, th_d12; // 9..12
    reg  signed [15:0] th_d13, th_d14, th_d15, th_d16;// 13..16（DTH_N=16 时用）
    reg  signed [15:0] th_dly;                       // DTH_N 选中的延迟样本
    // ★ 差分【端点】平滑：th_q1..q7 是 th_dly 之后 1..7 拍。
    //   前半段 = th, th_d1..th_d7；后半段 = th_dly, th_q1..th_q7。
    //   两簇中心相距恰好 DTH_N 拍 → 增益不变，端点噪声 ÷√N。
    reg  signed [15:0] th_q1, th_q2, th_q3, th_q4, th_q5, th_q6, th_q7;

    // 端点求和（符号扩展到 22 位，8×32767 不溢出）
    //   ★ generate 只综合被选中的那一支：写成参数三元表达式时综合器会把四棵树全建出来
    //     再加 4 选 1，LUT +485、关键路径 +3.4 ns（实测 Fmax 54.6 → 46.1，Setup 违例 45）
    wire signed [21:0] sn_c;
    wire signed [21:0] so_c;

    generate
        if (THD_AVG_SH == 0) begin : g_sm0
            assign sn_c = {{6{th[15]}}, th};
            assign so_c = {{6{th_dly[15]}}, th_dly};
        end else if (THD_AVG_SH == 1) begin : g_sm1
            assign sn_c = {{6{th[15]}}, th}       + {{6{th_d1[15]}}, th_d1};
            assign so_c = {{6{th_dly[15]}}, th_dly} + {{6{th_q1[15]}}, th_q1};
        end else if (THD_AVG_SH == 2) begin : g_sm2
            assign sn_c = ({{6{th[15]}}, th}        + {{6{th_d1[15]}}, th_d1})
                        + ({{6{th_d2[15]}}, th_d2}  + {{6{th_d3[15]}}, th_d3});
            assign so_c = ({{6{th_dly[15]}}, th_dly} + {{6{th_q1[15]}}, th_q1})
                        + ({{6{th_q2[15]}}, th_q2}   + {{6{th_q3[15]}}, th_q3});
        end else begin : g_sm3
            assign sn_c = (({{6{th[15]}}, th}     + {{6{th_d1[15]}}, th_d1})
                         + ({{6{th_d2[15]}}, th_d2}  + {{6{th_d3[15]}}, th_d3}))
                        + (({{6{th_d4[15]}}, th_d4}  + {{6{th_d5[15]}}, th_d5})
                         + ({{6{th_d6[15]}}, th_d6}  + {{6{th_d7[15]}}, th_d7}));
            assign so_c = (({{6{th_dly[15]}}, th_dly} + {{6{th_q1[15]}}, th_q1})
                         + ({{6{th_q2[15]}}, th_q2}   + {{6{th_q3[15]}}, th_q3}))
                        + (({{6{th_q4[15]}}, th_q4}   + {{6{th_q5[15]}}, th_q5})
                         + ({{6{th_q6[15]}}, th_q6}   + {{6{th_q7[15]}}, th_q7}));
        end
    endgenerate

    // ★ 求和结果先打一拍再相减：把 3 级 22 位加法从"相减→乘 2000→移位→低通"那条
    //   关键路径上切下来。代价 1 tick = 0.5 ms（相对 62 ms 不稳定时间常数 = 0.8%）。
    reg  signed [21:0] sn_r, so_r;

    // ★ 低通状态用 Q10+4 位小数（20 位）：16 位整数状态在 LPF_SHIFT=4 时有
    //   |err|<16 恒不更新的死区 = 16 LSB = 0.89 °/s，而目标残留只有 ~2 °/s。
    //   加 4 位小数后死区降到 1 LSB = 0.056 °/s。
    reg  signed [19:0] thd_f;
    reg  [4:0]         prime;           // 上电后先对齐差分历史，抑制首拍微分尖峰
                                        // ★ 5 位：DTH_N 最大 16，4 位会溢出成死循环

    // 差分窗选择：DTH_N = 4 / 8 / 16，窗口长度 = DTH_N / TICK_HZ
    //   ★ 窗口要按【时间】选，不是按拍数：
    //     1200Hz： 8 拍 = 6.67ms（原默认）
    //     2000Hz：16 拍 = 8.00ms（保持同一量级的噪声抑制，见顶层注释）
    //   窗越长微分噪声越小（∝ 1/窗长），代价是 C4 那条相位超前通路滞后变大。
    always @(*) begin
        case (DTH_N)
            1:       th_dly = th;
            2:       th_dly = th_d2;
            3:       th_dly = th_d3;
            4:       th_dly = th_d4;
            5:       th_dly = th_d5;
            6:       th_dly = th_d6;
            7:       th_dly = th_d7;
            8:       th_dly = th_d8;
            9:       th_dly = th_d9;
            10:      th_dly = th_d10;
            11:      th_dly = th_d11;
            12:      th_dly = th_d12;
            13:      th_dly = th_d13;
            14:      th_dly = th_d14;
            15:      th_dly = th_d15;
            default: th_dly = th_d16;
        endcase
    end

    // 1/2/4/8/16 -> 0/1/2/3/4
    localparam integer DTH_LOG2 = (DTH_N <= 1)  ? 0 :
                                  (DTH_N == 2)  ? 1 :
                                  (DTH_N == 4)  ? 2 :
                                  (DTH_N == 8)  ? 3 : 4;

    // θ̇ = dth/4096 × TICK_HZ/DTH_N × 1024 = dth × TICK_HZ / (4×DTH_N)
    //   ★ 端点平滑（THD_AVG_SH）：差值取 (N 点和) − (N 点和) 再右移 log2(N)，
    //     等效于对两个端点各做 N 点平均，中心间距仍为 DTH_N 拍 → 增益不变。
    //     THD_AVG_SH=0 时 sn_r=th、so_r=th_dly → 数值与老版本相同（只多 1 tick 延迟）。
    wire signed [31:0] dth     = $signed(sn_r - so_r) >>> THD_AVG_SH;
    wire signed [31:0] thd_raw = (dth * TICK_HZ) >>> (2 + DTH_LOG2);

    //==================================================================
    // 3.5 电位器跳变保护（起摆前必须有的东西）
    //
    // 环形电位器每转一圈有一个跳变点，θ 在那里一次性突变 2π（Q12 下 ±25736）。
    // 不加保护时这一拍算出的 thd = 25736×1200/16 ≈ 1900 rad/s，被 C4 放大后
    // 直接打满 2500 的反向占空比 —— 摆杆刚过顶电机就猛甩一下。
    // 平衡时摆杆只在直立附近 ±10° 内，永远碰不到；一旦做起摆就每圈都踩。
    //
    // 判据：一个差分窗内 |Δθ| > π/2（Q12 = 6434）。
    //   真实运动在 3.33ms 内最多走 0.1 rad，与阈值差 15 倍，不会误触发；
    //   任何 ADC 尖峰（读数跳到 65535 之类）同样被这条兜住。
    // 处理：本拍 θ̇ 冻结在滤波值上（速度在跳变处物理连续，保持比清零准），
    //   并把 DTH_N 个差分历史全部对齐到新的 θ，下一拍即恢复正常。
    //   ★ 全程不需要知道跳变点在哪、也不需要一圈的码数，不用做"环形展开"。
    //==================================================================
    localparam signed [31:0] DTH_LIM = 32'sd6434;   // π/2 in Q12
    // ★ 判据用【未平滑】的首尾差：端点平滑会把一次 2π 跳变摊成 1/N 的斜坡，
    //   第一拍只有 2π/N，用平滑后的 dth 会漏判一拍（算出 32 rad/s 的假速度）。
    //   原始差在跳变当拍就直接越限，保护时序与老版本完全一致。
    wire signed [31:0] dth_chk = $signed(th) - $signed(th_dly);
    wire jump = (dth_chk > DTH_LIM) || (dth_chk < -DTH_LIM);
    wire signed [35:0] thd_raw_q4 = $signed(thd_raw) <<< 4;      // 抬到 Q4 对齐
    wire signed [35:0] thd_f_x    = {{16{thd_f[19]}}, thd_f};
    wire signed [35:0] thd_dif    = thd_raw_q4 - thd_f_x;
    wire signed [35:0] thd_nxt36  = thd_f_x + (thd_dif >>> LPF_SHIFT);
    // 饱和到 20 位（Q4 下 ±32768 对应 ±524288），再右移回 Q10 并饱和到 16 位
    wire signed [19:0] thd_nxt    = (thd_nxt36 >  36'sd524287) ?  20'sd524287 :
                                    (thd_nxt36 < -36'sd524288) ? -20'sd524288 : thd_nxt36[19:0];
    // 输出 +半 LSB 四舍五入回 Q10（不加的话常数速度会稳定在 1999 而不是 2000）
    wire signed [31:0] thd_out32  = ($signed({{12{thd_nxt[19]}}, thd_nxt}) + 32'sd8) >>> 4;
    wire signed [15:0] thd_out    = sat16(thd_out32);

    // SPEED_SH：把 speed 从它自己的定标拉回整数 count
    //   M 法 speed 是整数 count → SPEED_SH=0，结果与旧版逐位一致
    //   T 法 speed_t 是 Q4（×16）→ SPEED_SH=4，先乘再加移位，不丢精度
    wire signed [31:0] ald_full = ($signed({{16{speed[15]}}, speed}) * KDOT_NUM)
                                  >>> SPEED_SH;

    //==================================================================
    // 4. 饱和与输出
    //==================================================================
    function signed [15:0] sat16(input signed [31:0] v);
        begin
            if (v > 32'sd32767)       sat16 = 16'sd32767;
            else if (v < -32'sd32768) sat16 = 16'sh8000;
            else                      sat16 = v[15:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            th      <= 16'sd0;
            thd     <= 16'sd0;
            al      <= 16'sd0;
            ald     <= 16'sd0;
            th_d1   <= 16'sd0;
            th_d2   <= 16'sd0;
            th_d3   <= 16'sd0;
            th_d4   <= 16'sd0;
            th_d5   <= 16'sd0;
            th_d6   <= 16'sd0;
            th_d7   <= 16'sd0;
            th_d8   <= 16'sd0;
            th_d9   <= 16'sd0;
            th_d10  <= 16'sd0;
            th_d11  <= 16'sd0;
            th_d12  <= 16'sd0;
            th_d13  <= 16'sd0;
            th_d14  <= 16'sd0;
            th_d15  <= 16'sd0;
            th_d16  <= 16'sd0;
            th_q1   <= 16'sd0;
            th_q2   <= 16'sd0;
            th_q3   <= 16'sd0;
            th_q4   <= 16'sd0;
            th_q5   <= 16'sd0;
            th_q6   <= 16'sd0;
            th_q7   <= 16'sd0;
            sn_r    <= 22'sd0;
            so_r    <= 22'sd0;
            thd_f   <= 20'sd0;
            prime   <= 5'd0;
        end else begin
            th <= sat16(th_full);
            al <= sat16(al_full);

            if (tick) begin
                th_d1 <= th;
                th_d2 <= th_d1;
                th_d3 <= th_d2;
                th_d4 <= th_d3;
                th_d5 <= th_d4;
                th_d6 <= th_d5;
                th_d7 <= th_d6;
                th_d8 <= th_d7;
                th_d9  <= th_d8;
                th_d10 <= th_d9;
                th_d11 <= th_d10;
                th_d12 <= th_d11;
                th_d13 <= th_d12;
                th_d14 <= th_d13;
                th_d15 <= th_d14;
                th_d16 <= th_d15;
                th_q1  <= th_dly;
                th_q2  <= th_q1;
                th_q3  <= th_q2;
                th_q4  <= th_q3;
                th_q5  <= th_q4;
                th_q6  <= th_q5;
                th_q7  <= th_q6;
                sn_r   <= sn_c;
                so_r   <= so_c;
                if (prime < (DTH_N + 10)) begin
                    // 复位后先对齐 DTH_N 个样本：θ 可能还是上一拍的无效值，
                    // 直接求差会得到 32rad/s 的假角速度 -> 控制器瞬间打满 12V
                    // ★ 端点平滑后尾部还要再走 7 拍才填满，求和寄存器再 1 拍，共多等 10 拍
                    prime <= prime + 1'b1;
                    thd_f <= 20'sd0;
                    thd   <= 16'sd0;
                    ald   <= 16'sd0;
                end else if (jump) begin
                    // 跳变/尖峰：冻结 θ̇，历史对齐到新值（见 3.5 节）
                    th_d1 <= th;
                    th_d2 <= th;
                    th_d3 <= th;
                    th_d4 <= th;
                    th_d5 <= th;
                    th_d6 <= th;
                    th_d7 <= th;
                    th_d8 <= th;
                    th_d9  <= th;
                    th_d10 <= th;
                    th_d11 <= th;
                    th_d12 <= th;
                    th_d13 <= th;
                    th_d14 <= th;
                    th_d15 <= th;
                    th_d16 <= th;
                    th_q1  <= th;
                    th_q2  <= th;
                    th_q3  <= th;
                    th_q4  <= th;
                    th_q5  <= th;
                    th_q6  <= th;
                    th_q7  <= th;
                    // 求和寄存器同步对齐（= 2^SH × th），否则下一拍会拿跳变前的旧和相减
                    sn_r   <= $signed({{4{th[15]}}, th}) <<< THD_AVG_SH;
                    so_r   <= $signed({{4{th[15]}}, th}) <<< THD_AVG_SH;
                    thd   <= thd_out;      // 冻结在低通输出上
                    ald   <= sat16(ald_full);
                end else begin
                    thd_f <= thd_nxt;
                    thd   <= thd_out;
                    ald   <= sat16(ald_full);
                end
            end
        end
    end

endmodule
