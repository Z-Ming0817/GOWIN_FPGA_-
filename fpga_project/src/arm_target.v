//=============================================================================
// arm_target.v  —  臂目标发生器（回零 + 平衡旋转）
//
// 职责：产生送给 LQR 的两个量
//   al_ref : 臂的目标角（Q12 rad，缠绕 ±π）—— 决定"往哪走"
//   wref   : 目标当前的变化速率（Q10 rad/s）—— 给 C2 做速度前馈
//
// 为什么要有 wref：
//   原来 C2 项吃的是绝对角速度 α̇。让臂匀速转时它会给出恒定反向力矩，
//   控制器只能靠位置误差抵消，稳态滞后 e = C2/C1·ω = 1.75·ω [rad]。
//      30 °/s → 滞后 52°     60 °/s → 105°     90 °/s → 158°（C1 项直接饱和）
//   把 C2 改成 C2·(α̇ − wref) 后，匀速时该项归零，滞后降到只剩摩擦引起的 ~8.5°。
//   wref 必须与 al_ref 的每拍增量【同源】，否则前馈与实际斜坡对不上，会留残差。
//
// 四个状态：
//   IDLE  EN=0（待机/起摆/故障）：al_ref 每拍跟随 al，无扰接合
//   WAIT  EN 上升后等 3 s：目标冻结在进平衡那一点，臂原地不动，专心接摆杆
//   MOVE  限速+限加速驶向 al_base（基准点）；到 1° 内直接吸附
//   HOLD  到位后停住；rot_hold=1 时按 ROT_W 连续积分（平衡旋转）
//
// 定点格式（Q25）：
//   角速度/角加速度如果按 Q12 存，1 tick 的增量会被截断成 0（90 °/s 只有 3.2/tick），
//   所以内部用 Q25（2^25），32 位有符号可表示 ±π 而有余量：
//     PI_Q25 = 105,392,326   TPI_Q25 = 210,784,652
//     90 °/s       → w = 26,348
//     47.8 °/s²    → Δw = 7 / tick
//   输出时 al_ref = tgt >> 13，wref = w*TICK_HZ >> 15。
//
// 减速判据（无开方）：
//   从速度 w 刹到 0 的距离 = w²/(2a)。把它与剩余误差比较：
//       w² >= 2·ACC·|err|  →  现在开始减速
//   1 个 16×16 乘法（1 个 DSP），不占关键路径（全部在 tick 域）。
//
// ★ 与死区的关系（上板前必读）：
//   执行器静摩擦死区约 240 duty，C1 折算 17.6 duty/度，所以臂要产生 240 duty
//   需要约 13.6° 的位置误差。这意味着 **偏移小于 13.6° 时回零指令不会让臂动**——
//   目标走到了基准点，臂却停在原地，误差一直存在。这是执行器特性，不是本模块的 bug。
//=============================================================================
`timescale 1ns/1ps

module arm_target #(
    parameter integer TICK_HZ  = 2000,
    parameter integer WAIT_MS  = 3000,      // 进平衡后原地等待时长
    // 加速度限制：每 tick 的速率增量（Q25 rad/tick²）
    //   4  ≈ 27.3 °/s²   7  ≈ 47.8 °/s² ← 目标 50 的取整值
    //   9  ≈ 61.4 °/s²   15 ≈ 102 °/s²
    parameter integer ACC_INC  = 7,
    // 速度上限（Q25 rad/tick）：26348 ≈ 90 °/s，17565 ≈ 60，8790 ≈ 30
    parameter integer VMAX_W   = 26348
    // 旋转速度/方向改为运行期输入（菜单可改），不再用 parameter
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               tick,          // 2 kHz 控制节拍
    input  wire               en,            // bal_en
    input  wire               rot_hold,      // 1 = 正在旋转（保持方向）
    input  wire [15:0]        rot_w,         // 旋转速度 Q25 rad/tick（≈ °/s × 293）
    input  wire               rot_dir,       // 1 = 顺时针方向，0 = 逆时针方向
    input  wire               jump,          // 1 = 把内部目标直接拉到 al_base（角度旋转交还时用）
    input  wire signed [15:0] al,            // 当前臂角 Q12（来自观察器 al_raw）
    input  wire signed [15:0] al_base,       // 基准点 Q12（上电=0，定点时更新）
    output reg  signed [15:0] al_ref,        // 目标 Q12
    output reg  signed [15:0] wref           // 前馈 Q10 rad/s
);

    localparam signed [31:0] PI_Q25   = 32'sd105392326;   // π × 2^25
    localparam signed [31:0] TPI_Q25  = 32'sd210784652;   // 2π × 2^25
    localparam signed [31:0] SNAP_Q25 = 32'sd585600;      // 1°：进这个圈就直接吸附

    localparam integer WAIT_TICK = (TICK_HZ / 1000) * WAIT_MS;

    localparam [1:0] S_IDLE = 2'd0, S_WAIT = 2'd1, S_MOVE = 2'd2, S_HOLD = 2'd3;

    reg [1:0]          st;
    reg [31:0]         wait_cnt;
    reg  signed [31:0] tgt;      // 目标，Q25 rad，缠绕 ±π
    reg  signed [31:0] w;        // 当前速率，Q25 rad/tick

    //---------------- 输入扩到 Q25 ----------------
    wire signed [31:0] al_q25   = {{16{al[15]}},      al}      <<< 13;
    wire signed [31:0] base_q25 = {{16{al_base[15]}}, al_base} <<< 13;

    //---------------- 剩余误差（缠绕到 ±π）----------------
    //   目标与基准都在 ±π 内，差值最大 2π，折回一次即可
    wire signed [31:0] err_raw = base_q25 - tgt;
    wire signed [31:0] err     = (err_raw >  PI_Q25) ? (err_raw - TPI_Q25) :
                                 (err_raw < -PI_Q25) ? (err_raw + TPI_Q25) : err_raw;

    //---------------- 三级流水 ----------------
    //   ★ 不流水时实测：tgt → 减法 → 缠绕 → 取绝对值 → 乘法 → 34 位比较 → 速率选择
    //     全串在一拍里，Data Delay **21.8 ns**，Setup 违例 68 个，TNS −78.6。
    //   拆成 4 段后每段只剩 3~5 ns。这些量只在 tick（2 kHz = 500 ns）上被消费，
    //   多 4 拍（80 ns）完全无影响。
    reg signed [31:0] err_r;
    reg        [31:0] err_abs_r, w_abs_r, w2_r;
    reg        [33:0] brake_r;
    reg               slow_r;

    // 减速判据：w² >= 2·ACC·|err| → 已到刹车点
    //   w 最大 26348 → w² 最大 6.9e8；2·7·|err| 最大 1.5e9，34 位够
    wire [33:0] brake_c = ({2'b00, ACC_INC} * {2'b00, err_abs_r}) <<< 1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            err_r     <= 32'sd0;
            err_abs_r <= 32'd0;
            w_abs_r   <= 32'd0;
            w2_r      <= 32'd0;
            brake_r   <= 34'd0;
            slow_r    <= 1'b0;
        end else begin
            err_r     <= err;                                      // 段1：缠绕后的误差
            err_abs_r <= err_r[31] ? (32'd0 - err_r) : err_r;      // 段2：取绝对值
            w_abs_r   <= w[31]     ? (32'd0 - w)     : w;
            w2_r      <= w_abs_r * w_abs_r;                        // 段3：平方（DSP）
            brake_r   <= brake_c;
            slow_r    <= ({2'b00, w2_r} >= brake_r);               // 段4：比较
        end
    end

    //---------------- 目标累加后缠绕 ----------------
    // 旋转速度输入转成 32 位有符号（0~65535 足够：90 °/s = 26348）
    wire signed [31:0] rot_w_s = {16'd0, rot_w};

    wire signed [31:0] tgt_sum = tgt + w;
    wire signed [31:0] tgt_ww  = (tgt_sum >  PI_Q25) ? (tgt_sum - TPI_Q25) :
                                 (tgt_sum < -PI_Q25) ? (tgt_sum + TPI_Q25) : tgt_sum;

    //---------------- Q25 tgt → Q12 al_ref ----------------
    //   >>13 后是 15 位有符号，补 1 位符号扩展到 16 位
    wire signed [15:0] tgt_q12 = {{1{tgt[27]}}, tgt[27:13]};

    //---------------- 速率爬升（限加速）----------------
    //   朝 target 每拍最多走 ACC_INC，到了就压住
    function signed [31:0] ramp;
        input signed [31:0] cur;
        input signed [31:0] aim;
        begin
            if      (cur < aim - ACC_INC) ramp = cur + ACC_INC;
            else if (cur > aim + ACC_INC) ramp = cur - ACC_INC;
            else                          ramp = aim;
        end
    endfunction

    //---------------- 状态机 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            wait_cnt <= 32'd0;
            tgt      <= 32'sd0;
            w        <= 32'sd0;
            al_ref   <= 16'sd0;
            wref     <= 16'sd0;
        end else if (jump) begin
            // 外部要求把目标直接拉到基准（角度旋转到位后交还，臂已在那里，无跳变）
            tgt      <= base_q25;
            w        <= 32'sd0;
            st       <= S_HOLD;
        end else if (!en) begin
            // 非闭环：目标跟随、速率清零，保证进平衡瞬间误差为 0（无扰接合）
            st       <= S_IDLE;
            wait_cnt <= 32'd0;
            tgt      <= al_q25;
            w        <= 32'sd0;
            al_ref   <= al;
            wref     <= 16'sd0;
        end else if (tick) begin
            case (st)
                //---------------------------------------------
                S_IDLE: begin
                    tgt      <= al_q25;          // 锁在进平衡那一刻
                    w        <= 32'sd0;
                    wait_cnt <= 32'd0;
                    st       <= S_WAIT;
                end
                //---------------------------------------------
                S_WAIT: begin
                    if (wait_cnt >= WAIT_TICK) st <= S_MOVE;
                    else                       wait_cnt <= wait_cnt + 32'd1;
                end
                //---------------------------------------------
                S_MOVE: begin
                    if (err_abs_r <= SNAP_Q25) begin
                        tgt <= base_q25;         // 1° 内直接吸附，避免整数小信号爬不动
                        w   <= 32'sd0;
                        st  <= S_HOLD;
                    end else begin
                        tgt <= tgt_ww;
                        if (slow_r) w <= ramp(w, 32'sd0);
                        else      w <= ramp(w, err_r[31] ? -VMAX_W : VMAX_W);
                    end
                end
                //---------------------------------------------
                S_HOLD: begin
                    tgt <= tgt_ww;
                    if (rot_hold) w <= ramp(w, rot_dir ? rot_w_s : -rot_w_s);
                    else          w <= ramp(w, 32'sd0);
                end
                //---------------------------------------------
                default: begin
                    st  <= S_IDLE;
                    w   <= 32'sd0;
                    tgt <= al_q25;
                end
            endcase

            al_ref <= tgt_q12;
            wref   <= (w * TICK_HZ) >>> 15;
        end
    end

endmodule
