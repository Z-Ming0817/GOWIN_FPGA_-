//=============================================================================
// lcd_init.v — ST7789 上电初始化序列
//
// 62 条序列，取自 first_test 工程（同一块 1.54" 240x240 IPS 屏已实测点亮）。
// 关键点：SWRESET 后等 120ms，SLPOUT 后等 120ms，DISPON 后等 20ms。
// 完成时 init_done 拉高，此后显示交给 gfx。
//=============================================================================
`timescale 1ns/1ps

module lcd_init #(
    parameter [7:0]   MADCTL_CFG    = 8'h00,
    parameter         INVERT_COLORS = 1'b1,   // 本屏实测需要反相（INVON），置 0 会黑白颠倒
    parameter integer CLK_FREQ      = 50_000_000
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    output reg        done,

    output reg  [7:0] tx_data,
    output reg        tx_cmd,
    output reg        tx_start,
    input  wire       tx_busy,
    output wire       keep_cs        // 初始化全程保持 CS 低
);

    localparam [5:0] LAST = 6'd61;

    function [7:0] init_byte;
        input [5:0] index;
        begin
            case (index)
                6'd0:  init_byte = 8'h01;   // SWRESET
                6'd1:  init_byte = 8'h11;   // SLPOUT
                6'd2:  init_byte = 8'h3A;   // COLMOD
                6'd3:  init_byte = 8'h55;   //  16bit/pixel
                6'd4:  init_byte = 8'h36;   // MADCTL
                6'd5:  init_byte = MADCTL_CFG;
                6'd6:  init_byte = 8'hB2;
                6'd7:  init_byte = 8'h0C;
                6'd8:  init_byte = 8'h0C;
                6'd9:  init_byte = 8'h00;
                6'd10: init_byte = 8'h33;
                6'd11: init_byte = 8'h33;
                6'd12: init_byte = 8'hB7;
                6'd13: init_byte = 8'h35;
                6'd14: init_byte = 8'hBB;
                6'd15: init_byte = 8'h19;
                6'd16: init_byte = 8'hC0;
                6'd17: init_byte = 8'h2C;
                6'd18: init_byte = 8'hC2;
                6'd19: init_byte = 8'h01;
                6'd20: init_byte = 8'hC3;
                6'd21: init_byte = 8'h12;
                6'd22: init_byte = 8'hC4;
                6'd23: init_byte = 8'h20;
                6'd24: init_byte = 8'hC6;
                6'd25: init_byte = 8'h0F;
                6'd26: init_byte = 8'hD0;
                6'd27: init_byte = 8'hA4;
                6'd28: init_byte = 8'hA1;
                6'd29: init_byte = 8'hE0;
                6'd30: init_byte = 8'hD0;
                6'd31: init_byte = 8'h04;
                6'd32: init_byte = 8'h0D;
                6'd33: init_byte = 8'h11;
                6'd34: init_byte = 8'h13;
                6'd35: init_byte = 8'h2B;
                6'd36: init_byte = 8'h3F;
                6'd37: init_byte = 8'h54;
                6'd38: init_byte = 8'h4C;
                6'd39: init_byte = 8'h18;
                6'd40: init_byte = 8'h0D;
                6'd41: init_byte = 8'h0B;
                6'd42: init_byte = 8'h1F;
                6'd43: init_byte = 8'h23;
                6'd44: init_byte = 8'hE1;
                6'd45: init_byte = 8'hD0;
                6'd46: init_byte = 8'h04;
                6'd47: init_byte = 8'h0C;
                6'd48: init_byte = 8'h11;
                6'd49: init_byte = 8'h13;
                6'd50: init_byte = 8'h2C;
                6'd51: init_byte = 8'h3F;
                6'd52: init_byte = 8'h44;
                6'd53: init_byte = 8'h51;
                6'd54: init_byte = 8'h2F;
                6'd55: init_byte = 8'h1F;
                6'd56: init_byte = 8'h1F;
                6'd57: init_byte = 8'h20;
                6'd58: init_byte = 8'h23;
                6'd59: init_byte = INVERT_COLORS ? 8'h21 : 8'h20;  // INVON / INVOFF
                6'd60: init_byte = 8'h13;   // NORON
                6'd61: init_byte = 8'h29;   // DISPON
                default: init_byte = 8'h00;
            endcase
        end
    endfunction

    function init_is_cmd;
        input [5:0] index;
        begin
            case (index)
                6'd0, 6'd1, 6'd2, 6'd4, 6'd6, 6'd12, 6'd14, 6'd16,
                6'd18, 6'd20, 6'd22, 6'd24, 6'd26, 6'd29, 6'd44,
                6'd59, 6'd60, 6'd61: init_is_cmd = 1'b1;
                default: init_is_cmd = 1'b0;
            endcase
        end
    endfunction

    function [27:0] init_wait_clks;
        input [5:0] index;
        begin
            if (index == 6'd0 || index == 6'd1)
                init_wait_clks = (CLK_FREQ / 1000) * 120;
            else if (index == 6'd61)
                init_wait_clks = (CLK_FREQ / 1000) * 20;
            else
                init_wait_clks = 28'd0;
        end
    endfunction

    localparam [3:0] S_IDLE = 4'd0,
                     S_SEND = 4'd1,
                     S_BUSY = 4'd2,
                     S_NEXT = 4'd3,
                     S_WAIT = 4'd4;

    reg [3:0]  st;
    assign keep_cs = 1'b0;        // 逐字节 CS（与已验证的 first_test 一致）
    reg [5:0]  idx;
    reg [27:0] wait_cnt;
    reg        seen_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            idx       <= 6'd0;
            done      <= 1'b0;
            tx_data   <= 8'd0;
            tx_cmd    <= 1'b1;
            tx_start  <= 1'b0;
            wait_cnt  <= 28'd0;
            seen_busy <= 1'b0;
        end else begin
            tx_start <= 1'b0;

            case (st)
                S_IDLE: begin
                    if (start) begin
                        idx <= 6'd0;
                        st  <= S_SEND;          // 先发 SWRESET，发完再等 120ms
                    end
                end

                S_SEND: begin
                    tx_data   <= init_byte(idx);
                    tx_cmd    <= init_is_cmd(idx);
                    tx_start  <= 1'b1;
                    seen_busy <= 1'b0;
                    st        <= S_BUSY;
                end

                S_BUSY: begin
                    if (tx_busy) begin
                        seen_busy <= 1'b1;
                    end else if (seen_busy) begin
                        st <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    wait_cnt <= init_wait_clks(idx);   // 该条命令之后的等待
                    st       <= S_WAIT;
                end

                S_WAIT: begin
                    if (wait_cnt == 28'd0) begin
                        if (idx == LAST) begin
                            done <= 1'b1;
                            st   <= S_IDLE;
                        end else begin
                            idx <= idx + 1'b1;
                            st  <= S_SEND;
                        end
                    end else begin
                        wait_cnt <= wait_cnt - 1'b1;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
