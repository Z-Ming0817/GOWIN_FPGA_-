//=============================================================================
// pos_interp.v  —  编码器位置「边沿间插值」（亚计数位置）
//
// 要解决的问题（先看清量化在哪，别修错地方）
//   编码器 4 倍频后 pos 只有整数 count。1 count 对控制量的贡献是：
//       · C1 项（α）  ：C1=800 × (KA_NUM>>8=24.75) >> 12 =  4.8 duty   ← 小
//       · C2 项（α̇）  ：C2=1750 × 309             >> 12 = 132  duty   ← 大
//   台阶的大头在 α̇ 的 1 count/20ms 量化上。所以 A7 不能只把 α 变细，
//   必须把**测速窗口的端点**从整数 count 换成插值位置（见 encoder_decoder 的 SPD_Q4）。
//   本模块只负责产出那个插值位置。
//
// 原理
//   臂在匀速转时，两个边沿之间的真实位置是线性爬升的，而我们只知道"离下一个边沿
//   还差多少"。T 法（speed_t，Q4）量的正是这段斜率：
//       每个控制 tick(0.5ms) 前进的 count 数 = speed_t/16 × (0.5/20) = speed_t/640
//   于是用 1/640 count 为单位的累加器 acc 积分这个斜率：
//       acc += speed_t          （每 tick）
//       acc -= 640 × Δpos       （每来一个边沿）
//   第二行是关键：**不是清零，是把整 1 count 减掉**。
//   清零会在每个边沿造成最多 1 count 的跳变（正是要消除的台阶）；减 640 则把
//   "预测超前/滞后"留成残差，曲线连续，误差靠随后几个 tick 自然收敛。
//   累加器饱和 ±640：臂真停住时 speed_t→0，acc 冻结在最后的值（≤1 count；
//   进平衡时 α_ref 采样的是同一个 α，这点静态偏置整体被吃掉，不影响平衡点）。
//
// 输出
//   pos_q4 = (pos << 4) + acc×16/640       [Q4 计数]
//   ×16/640 = ×51/2048（0.0249 比精确 0.025 小 0.4% → 满量程 15.94 而非 16，
//   每个边沿留 0.06 Q4 = 0.5 duty 残差，可忽略；换来纯移位+常数乘）
//
// 时序（为什么要有 acc_c）
//   pos 是 encoder 打的寄存器，dpos 比 pos 晚一拍才被"看见"。若输出直接用 acc，
//   边沿那一拍会出现 1 count 的尖峰（20ns，随后被修正）。虽然只在 1/25000 概率
//   上撞到 tick，但 al 是每 clk 打拍的，所以这里多一级 acc_c 把修正量对齐到当前
//   pos，宁可多两个加法器也不留毛刺。
//
// 代价
//   窗长仍 20ms → α̇ 的滞后一点没变（刻意，见 doc/路线图 §A7）
//   不加额外滤波 → 不引入新的相位滞后
//   约 60 LUT（1 个 12×12 常数乘 + 3 个 32 位加法）
//=============================================================================
`timescale 1ns/1ps

module pos_interp (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               tick,          // 控制节拍 2kHz（与 ADC 同源）
    input  wire signed [31:0] pos,           // 整数 4 倍频计数
    input  wire signed [15:0] speed_t,       // T 法 Q4：count/20ms × 16
    output reg  signed [31:0] pos_q4         // Q4 计数（= 16 × count）
);

    localparam signed [31:0] ONE_CNT = 32'sd640;   // 1 count = 640 个 1/640 单位

    function signed [17:0] sat640(input signed [31:0] v);
        begin
            if      (v >  ONE_CNT) sat640 =  18'sd640;
            else if (v < -ONE_CNT) sat640 = -18'sd640;
            else                   sat640 = v[17:0];
        end
    endfunction

    reg  signed [17:0] acc;          // 边沿内进度，单位 1/640 count
    reg  signed [31:0] pos_d;        // 上一拍的 pos（找边沿）

    wire signed [31:0] dpos  = pos - pos_d;

    // 与"当前 pos"对齐的进度：边沿一出现就整 1 count 退掉（640 = 512 + 128）
    wire signed [31:0] acc_c = acc - (dpos <<< 9) - (dpos <<< 7);
    // 下一拍的进度：再加上本 tick 的斜率
    wire signed [31:0] acc_n = acc_c + (tick ? {{16{speed_t[15]}}, speed_t} : 32'sd0);

    wire signed [17:0] f_q4 = (sat640(acc_c) * 18'sd51) >>> 11;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc    <= 18'sd0;
            pos_d  <= 32'sd0;
            pos_q4 <= 32'sd0;
        end else begin
            acc    <= sat640(acc_n);
            pos_d  <= pos;
            pos_q4 <= (pos <<< 4) + f_q4;
        end
    end

endmodule
