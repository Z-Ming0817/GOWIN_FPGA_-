//=============================================================================
// st7789_spi.v — 单字节 SPI 发送器（ST7789，模式 3）
//
// SCLK = clk / (2 * SCLK_DIV)。默认 SCLK_DIV=2 -> 12.5 MHz。
// 之前是 25 MHz，杜邦线较长时处于临界，按键时线束被带动会写错数据，
// 表现为屏幕花屏/黑屏，故降速。
//=============================================================================
`timescale 1ns/1ps

module st7789_spi #(
    parameter integer SCLK_DIV = 2       // 1 -> 25MHz, 2 -> 12.5MHz, 4 -> 6.25MHz
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] tx_data,
    input  wire       tx_cmd,
    input  wire       keep_cs,     // 1 = 本字节结束后继续保持 CS 低（同一笔绘图内）
    output wire       busy,
    output reg        done,
    output wire       sclk,
    output wire       mosi,
    output wire       cs_n,
    output wire       dc
);

    localparam [1:0] S_IDLE = 2'd0, S_ACTIVE = 2'd1;

    reg [1:0] state;
    reg [2:0] bit_idx;
    reg [7:0] shift;

    reg sclk_r, mosi_r, cs_n_r, dc_r;

    // 时钟分频
    reg [7:0] div_cnt;
    wire      tick = (div_cnt == SCLK_DIV[7:0] - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) div_cnt <= 8'd0;
        else if (tick) div_cnt <= 8'd0;
        else div_cnt <= div_cnt + 1'b1;
    end

    assign busy = (state != S_IDLE);
    assign sclk = sclk_r;
    assign mosi = mosi_r;
    assign cs_n = cs_n_r;
    assign dc   = dc_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            bit_idx <= 3'd7;
            shift   <= 8'd0;
            sclk_r  <= 1'b1;
            mosi_r  <= 1'b1;
            cs_n_r  <= 1'b1;
            dc_r    <= 1'b1;
            done    <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    sclk_r <= 1'b1;
                    if (!keep_cs) cs_n_r <= 1'b1;
                    if (start) begin
                        shift   <= tx_data;
                        dc_r    <= ~tx_cmd;
                        cs_n_r  <= 1'b0;
                        sclk_r  <= 1'b0;
                        mosi_r  <= tx_data[7];
                        bit_idx <= 3'd7;
                        state   <= S_ACTIVE;
                    end
                end

                S_ACTIVE: begin
                    if (tick) begin
                        if (!sclk_r) begin
                            sclk_r <= 1'b1;
                        end else begin
                            sclk_r <= 1'b0;
                            if (bit_idx == 3'd0) begin
                                cs_n_r <= keep_cs ? 1'b0 : 1'b1;
                                sclk_r <= 1'b1;
                                done   <= 1'b1;
                                state  <= S_IDLE;
                            end else begin
                                bit_idx <= bit_idx - 3'd1;
                                mosi_r  <= shift[bit_idx - 3'd1];
                            end
                        end
                    end
                end

                default: begin
                    state  <= S_IDLE;
                    sclk_r <= 1'b1;
                    cs_n_r <= 1'b1;
                end
            endcase
        end
    end

endmodule
