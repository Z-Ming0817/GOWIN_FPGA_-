//=============================================================================
// uart_rx.v — 串口接收（8N1，16 倍过采样，中点采样）
//
// 用法：rx_done 单拍有效，同时 rx_byte 为收到的字节。
//       frame_err 在停止位不为 1 时置一拍（用于丢弃错误帧）。
//=============================================================================
`timescale 1ns/1ps

module uart_rx #(
    parameter integer CLK_FREQ = 50_000_000,
    parameter integer BAUD     = 115_200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output reg  [7:0] rx_byte,
    output reg        rx_done,
    output reg        frame_err
);

    localparam integer BITC = CLK_FREQ / BAUD;      // 每位时钟数（434）
    localparam integer HALF = BITC / 2;

    // 两级同步，消除亚稳态
    reg [1:0] sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sync <= 2'b11;
        else        sync <= {sync[0], rx};
    end

    wire rx_fall = (sync == 2'b10);                 // 1 -> 0 下降沿 = 起始位

    reg [1:0]  st;
    reg [15:0] cnt;
    reg [3:0]  bitn;
    reg [7:0]  sh;

    localparam [1:0] S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            cnt       <= 16'd0;
            bitn      <= 4'd0;
            sh        <= 8'd0;
            rx_byte   <= 8'd0;
            rx_done   <= 1'b0;
            frame_err <= 1'b0;
        end else begin
            rx_done   <= 1'b0;
            frame_err <= 1'b0;

            case (st)
                S_IDLE: begin
                    if (rx_fall) begin
                        cnt <= 16'd0;
                        st  <= S_START;
                    end
                end

                // 起始位中点确认
                S_START: begin
                    if (cnt == HALF[15:0]) begin
                        if (sync[0]) st <= S_IDLE;      // 毛刺，丢弃
                        else begin
                            cnt  <= 16'd0;
                            bitn <= 4'd0;
                            st   <= S_DATA;
                        end
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                // 8 个数据位，每位中点采样（LSB 先）
                S_DATA: begin
                    if (cnt == BITC[15:0] - 1) begin
                        cnt <= 16'd0;
                        sh  <= {sync[0], sh[7:1]};
                        if (bitn == 4'd7) st <= S_STOP;
                        else              bitn <= bitn + 1'b1;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                // 停止位
                S_STOP: begin
                    if (cnt == BITC[15:0] - 1) begin
                        cnt      <= 16'd0;
                        rx_byte  <= sh;
                        rx_done  <= 1'b1;
                        frame_err<= ~sync[0];
                        st       <= S_IDLE;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule