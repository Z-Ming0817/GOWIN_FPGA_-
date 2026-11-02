//=============================================================================
// sys_reset.v  —  上电/按键复位同步与展宽
//
// 输入 rst_n_in 为板载按键（异步、有抖动），输出 rst_n 为内部同步复位：
//   1) 3 级同步器把异步释放同步到 clk 域（异步复位、同步释放）
//   2) 释放后再保持 HOLD_CYC 个时钟，确保所有寄存器离开复位时时钟已稳定
//=============================================================================
`timescale 1ns/1ps

module sys_reset #(
    parameter CLK_FREQ = 50_000_000,
    parameter HOLD_CYC = 1_000_000        // 20ms @50MHz
)(
    input  wire clk,
    input  wire rst_n_in,
    output wire rst_n
);

    reg [2:0] sync_q;
    reg [23:0] hold_cnt;

    // 异步置位、同步释放
    always @(posedge clk or negedge rst_n_in) begin
        if (!rst_n_in) sync_q <= 3'b000;
        else           sync_q <= {sync_q[1:0], 1'b1};
    end

    wire rel = sync_q[2];

    always @(posedge clk or negedge rst_n_in) begin
        if (!rst_n_in)          hold_cnt <= 24'd0;
        else if (!rel)          hold_cnt <= 24'd0;
        else if (hold_cnt != HOLD_CYC - 1) hold_cnt <= hold_cnt + 1'b1;
    end

    assign rst_n = rel && (hold_cnt == HOLD_CYC - 1);

endmodule
