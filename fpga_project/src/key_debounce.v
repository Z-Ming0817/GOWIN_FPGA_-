//=============================================================================
// key_debounce.v — 4 路按键消抖 + 单次脉冲
//
// 硬件侧每路已有 10k 上拉 + 1uF 到地（约 10ms RC），这里再做 DEB_MS 的
// 电平确认，避免机械抖动和长线干扰产生多次触发。
//
//   key_in   : 原始电平，按下为 0（低有效）
//   key_level: 消抖后的电平（1 = 松开）
//   key_press: 消抖后"按下"的那一拍，单周期脉冲
//=============================================================================
`timescale 1ns/1ps

module key_debounce #(
    parameter integer CLK_FREQ = 50_000_000,
    parameter integer DEB_MS   = 20,
    parameter integer N        = 4
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire [N-1:0]     key_in,
    output reg  [N-1:0]     key_level,
    output reg  [N-1:0]     key_press
);

    localparam integer DEB_CYC = (CLK_FREQ / 1000) * DEB_MS;

    reg [N-1:0]  sync0, sync1;
    reg [N-1:0]  stable;
    reg [23:0]   cnt [0:N-1];
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync0    <= {N{1'b1}};
            sync1    <= {N{1'b1}};
            stable   <= {N{1'b1}};
            key_level<= {N{1'b1}};
            key_press<= {N{1'b0}};
            for (i = 0; i < N; i = i + 1) cnt[i] <= 24'd0;
        end else begin
            sync0 <= key_in;
            sync1 <= sync0;
            key_press <= {N{1'b0}};

            for (i = 0; i < N; i = i + 1) begin
                if (sync1[i] == stable[i]) begin
                    cnt[i] <= 24'd0;
                end else if (cnt[i] == DEB_CYC - 1) begin
                    cnt[i]   <= 24'd0;
                    stable[i]<= sync1[i];
                    if (!sync1[i]) key_press[i] <= 1'b1;   // 松开->按下
                end else begin
                    cnt[i] <= cnt[i] + 1'b1;
                end
            end

            key_level <= stable;
        end
    end

endmodule