//=============================================================================
// str_rom.v — 字符串表（最多 5 个 16x16 汉字）
//
// 字符编号（font_cn 索引）：
//   1开 2机 3中 4基 5础 6功 7能 8扩 9展 10参 11数 12调 13整 14实 15时
//   16监 17测 18上 19电 20断 21定 22点 23平 24衡 25绕 26圈 27移 28摆
//   29角 30速 31度 32臂 33输 34入 35位 36置 37始 38曲 39线
//   40主 41菜 42单 43c 44'1' 45'2' 46':' 47'.'
//   48旋 49转 50顺 51逆 52读 53取 54针 55'3' 56'4' 57'5' 58'6' 59'7' 60'8'
//=============================================================================
`timescale 1ns/1ps

module str_rom (
    input  wire [5:0] sid,
    input  wire [3:0] pos,
    output reg  [7:0] ch
);

    always @(*) begin
        ch = 8'h00;
        case (sid)
            // 0 主菜单（menu_frame 直接生成 40/41/42，这里也给出）
            6'd0:  case (pos) 4'd0: ch=8'd40; 4'd1: ch=8'd41; 4'd2: ch=8'd42; endcase
            // 1 基础功能 / 2 扩展功能
            6'd1:  case (pos) 4'd0: ch=8'd4;  4'd1: ch=8'd5;  4'd2: ch=8'd6;  4'd3: ch=8'd7;  endcase
            6'd2:  case (pos) 4'd0: ch=8'd8;  4'd1: ch=8'd9;  4'd2: ch=8'd6;  4'd3: ch=8'd7;  endcase
            // 3 参数调整（旧）
            6'd3:  case (pos) 4'd0: ch=8'd10; 4'd1: ch=8'd11; 4'd2: ch=8'd12; 4'd3: ch=8'd13; endcase
            // 4 实时监测
            6'd4:  case (pos) 4'd0: ch=8'd14; 4'd1: ch=8'd15; 4'd2: ch=8'd16; 4'd3: ch=8'd17; endcase
            // 5 上电 / 6 断电
            6'd5:  case (pos) 4'd0: ch=8'd18; 4'd1: ch=8'd19; endcase
            6'd6:  case (pos) 4'd0: ch=8'd20; 4'd1: ch=8'd19; endcase
            // 7 定点平衡（旧）/ 8 平衡绕圈 / 9 定点平移（旧）
            6'd7:  case (pos) 4'd0: ch=8'd21; 4'd1: ch=8'd22; 4'd2: ch=8'd23; 4'd3: ch=8'd24; endcase
            6'd8:  case (pos) 4'd0: ch=8'd23; 4'd1: ch=8'd24; 4'd2: ch=8'd25; 4'd3: ch=8'd26; endcase
            6'd9:  case (pos) 4'd0: ch=8'd21; 4'd1: ch=8'd22; 4'd2: ch=8'd27; endcase
            // 10-13 监测四项
            6'd10: case (pos) 4'd0: ch=8'd28; 4'd1: ch=8'd29; 4'd2: ch=8'd46; endcase
            6'd11: case (pos) 4'd0: ch=8'd28; 4'd1: ch=8'd30; 4'd2: ch=8'd46; endcase
            6'd12: case (pos) 4'd0: ch=8'd32; 4'd1: ch=8'd29; 4'd2: ch=8'd46; endcase
            6'd13: case (pos) 4'd0: ch=8'd32; 4'd1: ch=8'd30; 4'd2: ch=8'd46; endcase
            // 14 位置: / 15 角度:
            6'd14: case (pos) 4'd0: ch=8'd35; 4'd1: ch=8'd36; 4'd2: ch=8'd46; endcase
            6'd15: case (pos) 4'd0: ch=8'd29; 4'd1: ch=8'd31; 4'd2: ch=8'd46; endcase
            // 16/17/18 旧字符串
            6'd16: case (pos) 4'd0: ch=8'd18; 4'd1: ch=8'd19; endcase
            6'd17: case (pos) 4'd0: ch=8'd43; 4'd1: ch=8'd44; 4'd2: ch=8'd46; endcase
            6'd18: case (pos) 4'd0: ch=8'd43; 4'd1: ch=8'd45; 4'd2: ch=8'd46; endcase
            // 20 定点
            6'd20: case (pos) 4'd0: ch=8'd21; 4'd1: ch=8'd22; endcase
            // 21 平衡绕圈
            6'd21: case (pos) 4'd0: ch=8'd23; 4'd1: ch=8'd24; 4'd2: ch=8'd25; 4'd3: ch=8'd26; endcase
            // 22 角度旋转
            6'd22: case (pos) 4'd0: ch=8'd29; 4'd1: ch=8'd31; 4'd2: ch=8'd48; 4'd3: ch=8'd49; endcase
            // 23 速度:
            6'd23: case (pos) 4'd0: ch=8'd30; 4'd1: ch=8'd31; 4'd2: ch=8'd46; endcase
            // 24 旋转
            6'd24: case (pos) 4'd0: ch=8'd48; 4'd1: ch=8'd49; endcase
            // 25 参数读取
            6'd25: case (pos) 4'd0: ch=8'd10; 4'd1: ch=8'd11; 4'd2: ch=8'd52; 4'd3: ch=8'd53; endcase
            // 26~33  c1: ~ c8:
            6'd26: case (pos) 4'd0: ch=8'd43; 4'd1: ch=8'd44; 4'd2: ch=8'd46; endcase
            6'd27: case (pos) 4'd0: ch=8'd43; 4'd1: ch=8'd45; 4'd2: ch=8'd46; endcase
            6'd28: case (pos) 4'd0: ch=8'd43; 4'd1: ch=8'd55; 4'd2: ch=8'd46; endcase
            6'd29: case (pos) 4'd0: ch=8'd43; 4'd1: ch=8'd56; 4'd2: ch=8'd46; endcase
            6'd30: case (pos) 4'd0: ch=8'd43; 4'd1: ch=8'd57; 4'd2: ch=8'd46; endcase
            6'd31: case (pos) 4'd0: ch=8'd43; 4'd1: ch=8'd58; 4'd2: ch=8'd46; endcase
            6'd32: case (pos) 4'd0: ch=8'd43; 4'd1: ch=8'd59; 4'd2: ch=8'd46; endcase
            6'd33: case (pos) 4'd0: ch=8'd43; 4'd1: ch=8'd60; 4'd2: ch=8'd46; endcase
            // 34 停止 / 35 顺时针 / 36 逆时针
            6'd34: case (pos) 4'd0: ch=8'd61; 4'd1: ch=8'd62; endcase
            6'd35: case (pos) 4'd0: ch=8'd50; 4'd1: ch=8'd15; 4'd2: ch=8'd54; endcase
            6'd36: case (pos) 4'd0: ch=8'd51; 4'd1: ch=8'd15; 4'd2: ch=8'd54; endcase
            default: ch = 8'h00;
        endcase
    end

endmodule