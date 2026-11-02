//=============================================================================
// tb6612_driver.v  —  TB6612FNG 双路 H 桥驱动（单电机）
//
// 控制方式：PWM 调速 + IN1/IN2 定方向
//   duty > 0 且 dir=1 -> IN1=1, IN2=0（正转）
//   duty > 0 且 dir=0 -> IN1=0, IN2=1（反转）
//   duty = 0 或 en=0   -> IN1=0, IN2=0（coast 滑行，按本项目定案）
//
// 关键设计约束（勿改）：
//   1) u_cmd 超量程先钳位再取模，绝不会因取负溢出而反号
//   2) PWM 周期起点锁存 u_cmd，周期内占空比恒定，杜绝边界毛刺
//   3) rst_n=0 / en=0 无条件停转（安全联锁的最外层）
//
// 25kHz @50MHz -> PERIOD=2000，占空比分辨率 1/2000 = 0.05%
//
// ★ u_cmd 的标度固定为「CMD_FULL=2500 对应 100% 占空比 / 12V」，与 PWM 频率无关。
//   改 PWM_HZ 时内部按 PERIOD/CMD_FULL 自动归一化，控制器增益（C1..C4 按 2500=12V
//   标定）不需要跟着重算 —— 否则改频率会顺带把环路增益改掉，等于偷偷重调了一次参数。
//   25kHz 而非 20kHz：避开人耳最敏感的 2~5kHz 谐波、且 20kHz 已在听阈边缘，
//   开关损耗在这个电流量级可忽略。
//=============================================================================
`timescale 1ns/1ps

module tb6612_driver #(
    parameter CLK_FREQ  = 50_000_000,
    parameter PWM_HZ    = 25_000,
    parameter CMD_FULL  = 2500          // u_cmd 满量程（=12V / 100% 占空比）
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire signed [15:0] u_cmd,   // 有符号调速指令，单位=CMD_FULL 满量程
    input  wire               en,      // 0 = 强制停转
    output reg                pwm,
    output reg                in1,
    output reg                in2
);

    // PERIOD 由 PWM_HZ 决定（25kHz -> 2000）
    // DUTY_MUL = PERIOD/CMD_FULL × 2^16（Q16），用于把 u_cmd 归一化到 PWM 周期
    localparam integer PERIOD   = CLK_FREQ / PWM_HZ;
    localparam integer DUTY_MUL = (PERIOD << 16) / CMD_FULL;    // 2000/2500 -> 52428
    localparam signed [15:0] CMD_MAX = CMD_FULL;                // 便于有符号比较

    //------------------------------------------------------------------
    // PWM 计数器（自由运行）
    //------------------------------------------------------------------
    reg [15:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                  cnt <= 16'd0;
        else if (cnt == PERIOD - 1)  cnt <= 16'd0;
        else                         cnt <= cnt + 1'b1;
    end

    //------------------------------------------------------------------
    // 周期起点锁存指令，保证一个 PWM 周期内占空比不变
    //------------------------------------------------------------------
    reg signed [15:0] u_lat;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            u_lat <= 16'sd0;
        else if (cnt == 16'd0) u_lat <= u_cmd;
    end

    //------------------------------------------------------------------
    // 钳位 -> 归一化到 PWM 周期 -> 定方向
    //   先钳位再取模：|u| 最大只有 CMD_FULL，取负不会溢出
    //   归一化用 Q16 常数乘（DUTY_MUL）代替除法，避免综合出除法器
    //------------------------------------------------------------------
    reg [15:0] duty;
    reg        dir;
    reg [15:0] mag;

    always @(*) begin
        if (u_lat > CMD_MAX) begin
            mag = CMD_FULL;
            dir = 1'b1;
        end else if (u_lat < -CMD_MAX) begin
            mag = CMD_FULL;
            dir = 1'b0;
        end else if (u_lat >= 16'sd0) begin
            mag = u_lat;
            dir = 1'b1;
        end else begin
            mag = -u_lat;
            dir = 1'b0;
        end

        duty = (mag * DUTY_MUL + 16'd32768) >> 16;     // 四舍五入
        if (duty > PERIOD) duty = PERIOD;              // 常数除不尽时兜底
    end

    //------------------------------------------------------------------
    // PWM 与方向输出（全部寄存，避免组合毛刺）
    //------------------------------------------------------------------
    wire drive_en = en && (duty != 16'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pwm <= 1'b0;
            in1 <= 1'b0;
            in2 <= 1'b0;
        end else begin
            pwm <= drive_en && (duty > cnt);
            if (!drive_en) begin
                in1 <= 1'b0;            // coast
                in2 <= 1'b0;
            end else if (dir) begin
                in1 <= 1'b1;            // 正转
                in2 <= 1'b0;
            end else begin
                in1 <= 1'b0;            // 反转
                in2 <= 1'b1;
            end
        end
    end

endmodule
