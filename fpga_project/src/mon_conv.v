//=============================================================================
// mon_conv.v — 观测量 → 显示量 / 曲线归一化
//
//   th,thd,al,ald   : Q12 弧度 / Q10 弧度每秒（来自 state_observer）
//   v_th .. v_ald   : 0.1° / 0.1°/s（显示用，±9999）
//   n_th .. n_ald   : ±100（曲线用，8 位有符号）
//=============================================================================
`timescale 1ns/1ps

module mon_conv (
    input  wire               clk,
    input  wire               rst_n,

    input  wire signed [15:0] th,
    input  wire signed [15:0] thd,
    input  wire signed [15:0] al,
    input  wire signed [15:0] ald,

    output reg  signed [15:0] v_th,
    output reg  signed [15:0] v_thd,
    output reg  signed [15:0] v_al,
    output reg  signed [15:0] v_ald,

    output reg  signed [7:0]  n_th,
    output reg  signed [7:0]  n_thd,
    output reg  signed [7:0]  n_al,
    output reg  signed [7:0]  n_ald
);

    function signed [15:0] clamp10k;
        input signed [31:0] x;
        begin
            if (x >  32'sd9999)      clamp10k =  16'sd9999;
            else if (x < -32'sd9999) clamp10k = -16'sd9999;
            else                     clamp10k = x[15:0];
        end
    endfunction

    function signed [7:0] clamp100;
        input signed [31:0] x;
        begin
            if (x >  32'sd100)      clamp100 =  8'sd100;
            else if (x < -32'sd100) clamp100 = -8'sd100;
            else                    clamp100 = x[7:0];
        end
    endfunction

    // 0.1° / 0.1°/s
    // 0.1°/Q12 = 573/4096（0.1399），比 143/1024 精确 3 倍
    wire signed [31:0] m_a   = th  * 32'sd573;
    wire signed [31:0] m_thd = thd * 32'sd2292;   // 0.1°/(°/s 的 Q10) = 2292/4096
    wire signed [31:0] m_al  = al  * 32'sd573;
    wire signed [31:0] m_ald = ald * 32'sd2292;

    wire signed [15:0] d_th  = clamp10k(m_a   >>> 12);
    wire signed [15:0] d_thd = clamp10k(m_thd >>> 12);
    wire signed [15:0] d_al  = clamp10k(m_al  >>> 12);
    wire signed [15:0] d_ald = clamp10k(m_ald >>> 12);

    // 归一化到 ±100（÷9 / ÷40 / ÷18 / ÷40）
    wire signed [31:0] q_th  = d_th  * 32'sd114;
    wire signed [31:0] q_thd = d_thd * 32'sd26;
    wire signed [31:0] q_al  = d_al  * 32'sd57;
    wire signed [31:0] q_ald = d_ald * 32'sd26;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_th  <= 16'sd0; v_thd <= 16'sd0; v_al <= 16'sd0; v_ald <= 16'sd0;
            n_th  <= 8'sd0;  n_thd <= 8'sd0;  n_al <= 8'sd0;  n_ald <= 8'sd0;
        end else begin
            v_th  <= d_th;
            v_thd <= d_thd;
            v_al  <= d_al;
            v_ald <= d_ald;

            n_th  <= clamp100(q_th  >>> 10);
            n_thd <= clamp100(q_thd >>> 10);
            n_al  <= clamp100(q_al  >>> 10);
            n_ald <= clamp100(q_ald >>> 10);
        end
    end

endmodule
