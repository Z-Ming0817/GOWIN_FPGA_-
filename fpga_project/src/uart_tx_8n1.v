//=============================================================================
// uart_tx_8n1.v  —  参数化 8N1 UART 发送器（遥测帧与参数应答共用）
//
// 帧格式：1 起始位(0) + 8 数据位(LSB first) + 1 停止位(1)，空闲为高
// 分频：DIV = round(CLK_FREQ / BAUD)，50MHz/115200 -> 434（误差 +0.006%）
//=============================================================================
`timescale 1ns/1ps

module uart_tx_8n1 #(
    parameter CLK_FREQ = 50_000_000,
    parameter BAUD     = 115200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       tx_start,   // 单周期脉冲，tx_busy=0 时有效
    input  wire [7:0] tx_data,
    output reg        txd,
    output reg        tx_busy
);

    localparam integer DIV = (CLK_FREQ + BAUD / 2) / BAUD;

    localparam [1:0] S_IDLE = 2'd0,
                     S_START = 2'd1,
                     S_DATA = 2'd2,
                     S_STOP = 2'd3;

    reg [1:0]  st;
    reg [15:0] baud_cnt;
    reg [3:0]  bit_idx;
    reg [7:0]  sh;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            baud_cnt <= 16'd0;
            bit_idx  <= 4'd0;
            sh       <= 8'd0;
            txd      <= 1'b1;
            tx_busy  <= 1'b0;
        end else begin
            case (st)
                S_IDLE: begin
                    txd      <= 1'b1;
                    tx_busy  <= 1'b0;
                    baud_cnt <= 16'd0;
                    bit_idx  <= 4'd0;
                    if (tx_start) begin
                        sh      <= tx_data;
                        txd     <= 1'b0;      // 起始位
                        tx_busy <= 1'b1;
                        st      <= S_START;
                    end
                end

                S_START: begin
                    if (baud_cnt == DIV - 1) begin
                        baud_cnt <= 16'd0;
                        txd      <= sh[0];
                        sh       <= {1'b0, sh[7:1]};
                        bit_idx  <= 4'd1;
                        st       <= S_DATA;
                    end else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                S_DATA: begin
                    if (baud_cnt == DIV - 1) begin
                        baud_cnt <= 16'd0;
                        if (bit_idx == 4'd8) begin
                            txd <= 1'b1;             // 停止位
                            st  <= S_STOP;
                        end else begin
                            txd     <= sh[0];
                            sh      <= {1'b0, sh[7:1]};
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                S_STOP: begin
                    if (baud_cnt == DIV - 1) begin
                        baud_cnt <= 16'd0;
                        tx_busy  <= 1'b0;
                        st       <= S_IDLE;
                    end else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
