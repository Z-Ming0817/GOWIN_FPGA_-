//=============================================================================
// param_rom.v — 参数读取页的 10 行文字（自动生成，请勿手改）
//
// 每行 18 个字符：左边参数名（11 字），右边数值（7 字，右对齐）
// 渲染：1.5x 放大，12px/字，整行 216px 居中（x=12..227）
//=============================================================================
`timescale 1ns/1ps

module param_rom (
    input  wire [3:0] idx,     // 0~9
    input  wire [4:0] pos,     // 0~17
    output reg  [7:0] ch
);

    always @(*) begin
        ch = 8'h20;
        case (idx)
            4'd0: begin
                case (pos)
                    5'd0: ch = 8'h43;
                    5'd1: ch = 8'h4C;
                    5'd2: ch = 8'h4B;
                    5'd3: ch = 8'h5F;
                    5'd4: ch = 8'h46;
                    5'd5: ch = 8'h52;
                    5'd6: ch = 8'h45;
                    5'd7: ch = 8'h51;
                    5'd15: ch = 8'h35;
                    5'd16: ch = 8'h30;
                    5'd17: ch = 8'h4D;
                    default: ch = 8'h20;
                endcase
            end
            4'd1: begin
                case (pos)
                    5'd0: ch = 8'h42;
                    5'd1: ch = 8'h41;
                    5'd2: ch = 8'h55;
                    5'd3: ch = 8'h44;
                    5'd12: ch = 8'h31;
                    5'd13: ch = 8'h31;
                    5'd14: ch = 8'h35;
                    5'd15: ch = 8'h32;
                    5'd16: ch = 8'h30;
                    5'd17: ch = 8'h30;
                    default: ch = 8'h20;
                endcase
            end
            4'd2: begin
                case (pos)
                    5'd0: ch = 8'h50;
                    5'd1: ch = 8'h57;
                    5'd2: ch = 8'h4D;
                    5'd3: ch = 8'h5F;
                    5'd4: ch = 8'h48;
                    5'd5: ch = 8'h5A;
                    5'd13: ch = 8'h38;
                    5'd14: ch = 8'h30;
                    5'd15: ch = 8'h30;
                    5'd16: ch = 8'h30;
                    5'd17: ch = 8'h30;
                    default: ch = 8'h20;
                endcase
            end
            4'd3: begin
                case (pos)
                    5'd0: ch = 8'h53;
                    5'd1: ch = 8'h43;
                    5'd2: ch = 8'h4F;
                    5'd3: ch = 8'h50;
                    5'd4: ch = 8'h45;
                    5'd5: ch = 8'h5F;
                    5'd6: ch = 8'h44;
                    5'd7: ch = 8'h49;
                    5'd8: ch = 8'h56;
                    5'd12: ch = 8'h35;
                    5'd13: ch = 8'h30;
                    5'd14: ch = 8'h30;
                    5'd15: ch = 8'h30;
                    5'd16: ch = 8'h30;
                    5'd17: ch = 8'h30;
                    default: ch = 8'h20;
                endcase
            end
            4'd4: begin
                case (pos)
                    5'd0: ch = 8'h43;
                    5'd1: ch = 8'h5F;
                    5'd2: ch = 8'h50;
                    5'd3: ch = 8'h5F;
                    5'd4: ch = 8'h52;
                    5'd5: ch = 8'h45;
                    5'd6: ch = 8'h56;
                    5'd14: ch = 8'h31;
                    5'd15: ch = 8'h30;
                    5'd16: ch = 8'h36;
                    5'd17: ch = 8'h34;
                    default: ch = 8'h20;
                endcase
            end
            4'd5: begin
                case (pos)
                    5'd0: ch = 8'h4C;
                    5'd1: ch = 8'h51;
                    5'd2: ch = 8'h52;
                    5'd3: ch = 8'h5F;
                    5'd4: ch = 8'h43;
                    5'd5: ch = 8'h31;
                    5'd13: ch = 8'h2D;
                    5'd14: ch = 8'h31;
                    5'd15: ch = 8'h30;
                    5'd16: ch = 8'h31;
                    5'd17: ch = 8'h31;
                    default: ch = 8'h20;
                endcase
            end
            4'd6: begin
                case (pos)
                    5'd0: ch = 8'h4C;
                    5'd1: ch = 8'h51;
                    5'd2: ch = 8'h52;
                    5'd3: ch = 8'h5F;
                    5'd4: ch = 8'h43;
                    5'd5: ch = 8'h32;
                    5'd13: ch = 8'h2D;
                    5'd14: ch = 8'h31;
                    5'd15: ch = 8'h37;
                    5'd16: ch = 8'h37;
                    5'd17: ch = 8'h30;
                    default: ch = 8'h20;
                endcase
            end
            4'd7: begin
                case (pos)
                    5'd0: ch = 8'h4C;
                    5'd1: ch = 8'h51;
                    5'd2: ch = 8'h52;
                    5'd3: ch = 8'h5F;
                    5'd4: ch = 8'h43;
                    5'd5: ch = 8'h33;
                    5'd14: ch = 8'h37;
                    5'd15: ch = 8'h30;
                    5'd16: ch = 8'h35;
                    5'd17: ch = 8'h30;
                    default: ch = 8'h20;
                endcase
            end
            4'd8: begin
                case (pos)
                    5'd0: ch = 8'h4C;
                    5'd1: ch = 8'h51;
                    5'd2: ch = 8'h52;
                    5'd3: ch = 8'h5F;
                    5'd4: ch = 8'h43;
                    5'd5: ch = 8'h34;
                    5'd14: ch = 8'h31;
                    5'd15: ch = 8'h39;
                    5'd16: ch = 8'h35;
                    5'd17: ch = 8'h30;
                    default: ch = 8'h20;
                endcase
            end
            4'd9: begin
                case (pos)
                    5'd0: ch = 8'h54;
                    5'd1: ch = 8'h48;
                    5'd2: ch = 8'h5F;
                    5'd3: ch = 8'h43;
                    5'd4: ch = 8'h41;
                    5'd5: ch = 8'h54;
                    5'd6: ch = 8'h43;
                    5'd7: ch = 8'h48;
                    5'd14: ch = 8'h31;
                    5'd15: ch = 8'h36;
                    5'd16: ch = 8'h35;
                    5'd17: ch = 8'h30;
                    default: ch = 8'h20;
                endcase
            end
            default: ch = 8'h20;
        endcase
    end

endmodule