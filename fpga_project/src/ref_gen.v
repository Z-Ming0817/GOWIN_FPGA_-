//=============================================================================
// ref_gen.v — 定点平衡的臂角参考发生器（流水线版）
//
//   en=0  : al_ref 跟随当前臂角（进平衡瞬间参考 = 实际角度）
//   en=1  : al_ref 以 STEP_Q12/拍 限速斜坡逼近 target，到达后精确等于 target
//
// ★ 为什么用 3 拍流水：
//   "target - al_ref → 缠绕 → 限幅 → 再加回 al_ref → 再缠绕" 全串在一级，
//   实测 24ns（Fmax 41MHz，25 个违例）。参考值每 833us 才更新一次，
//   拆成 3 拍对控制完全无影响，却把时序从关键路径上摘掉。
//=============================================================================
`timescale 1ns/1ps

module ref_gen #(
    parameter signed [15:0] STEP_Q12 = 16'sd2
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               tick,
    input  wire               en,
    input  wire signed [15:0] al,
    input  wire signed [15:0] target,
    output reg  signed [15:0] al_ref
);

    localparam signed [16:0] PI_Q12     = 17'sd12868;
    localparam signed [16:0] TWO_PI_Q12 = 17'sd25736;
    localparam signed [16:0] STEP       = {STEP_Q12[15], STEP_Q12};

    //---- 第 1 拍：算最短角差并缠绕 ----
    wire signed [16:0] dif = {target[15], target} - {al_ref[15], al_ref};
    wire signed [16:0] err_nxt = (dif >= PI_Q12)  ? (dif - TWO_PI_Q12) :
                                 (dif < -PI_Q12)  ? (dif + TWO_PI_Q12) : dif;

    reg  signed [16:0] err_r, step_r;
    reg  [1:0]         ph;

    //---- 第 2 拍：限幅成单步 ----
    wire signed [16:0] step_nxt = (err_r >  STEP) ?  STEP :
                                  (err_r < -STEP) ? -STEP : err_r;

    //---- 第 3 拍：加回并缠绕 ----
    wire signed [16:0] cand = {al_ref[15], al_ref} + step_r;


    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            al_ref <= 16'sd0;
            err_r  <= 17'sd0;
            step_r <= 17'sd0;
            ph     <= 2'd0;
        end else if (!en) begin
            al_ref <= al;                   // 待机跟随
            step_r <= 17'sd0;
            ph     <= 2'd0;
        end else begin
            case (ph)
                2'd0: if (tick) begin
                          err_r <= err_nxt;   // 抓一个快照
                          ph    <= 2'd1;
                      end
                2'd1: begin
                          step_r <= step_nxt;
                          ph     <= 2'd2;
                      end
                default: begin
                          if (cand >= PI_Q12)      al_ref <= cand[15:0] - TWO_PI_Q12[15:0];
                          else if (cand < -PI_Q12) al_ref <= cand[15:0] + TWO_PI_Q12[15:0];
                          else                     al_ref <= cand[15:0];
                          ph <= 2'd0;
                      end
            endcase
        end
    end

endmodule
