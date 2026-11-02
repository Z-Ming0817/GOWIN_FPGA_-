//=============================================================================
// uart_frame.v — 二进制遥测帧（AA 55，14 字节，大端，XOR 校验）
//
// 每帧 14 字节，大端（高字节在前），115200 8N1，周期 50ms：
//
//   偏移  内容            格式        说明
//   0-1   AA 55           帧头
//   2     status          u8          bit0=平衡中 bit1=ZERO已锁存 bit2=故障
//                                     bit7:4 = mode
//   3-4   臂角            u16         0.01°，0~35999（0 = 编码器零点）
//   5-6   摆杆角          u16         0.01°，0~35999（底部 = 0）
//   7-8   臂速            s16         0.1°/s
//   9-10  杆速            s16         0.1°/s
//   11-12 占空比 u        s16         ±2500（矩形方波的实际占空比）
//   13    XOR             校验        字节 0~12 异或
//
// 输入是观测器/控制器的原始定点量：
//   th/al   Q12 弧度   thd/ald Q10 弧度每秒   u_duty 直接就是占空比
//=============================================================================
`timescale 1ns/1ps

module uart_frame #(
    parameter integer CLK_FREQ  = 50_000_000,
    parameter integer BAUD      = 115_200,
    parameter integer PERIOD_MS = 10
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire signed [15:0] th,          // 摆杆角 Q12（直立=0）
    input  wire signed [15:0] thd,         // 摆杆角速度 Q10
    input  wire signed [15:0] al,          // 臂角 Q12（±π 缠绕）
    input  wire signed [15:0] ald,         // 臂角速度 Q10
    input  wire signed [15:0] u_duty,      // 实际占空比 ±2500
    input  wire        [7:0]  status,
    input  wire               hold,        // 1 = 参数应答占用 TX，暂停发帧
    input  wire [31:0]        div_n,       // 帧间隔（时钟数），500000 -> 100 Hz
    output wire               busy,
    output wire               txd
);

    wire [31:0] tick = (div_n == 32'd0) ? 32'd500_000 : div_n;

    //---------------------- 定点换算 ----------------------
    // 角度 Q12 rad → 0.01°：×18000/π/4096 = ×1.398823 → ×2865 >> 11（带四舍五入）
    wire signed [31:0] th_d11  = (32'sd36864000 - (th * 32'sd2865)) >>> 11;   // 180.00° - θ
    wire signed [31:0] arm_d11 = (al * 32'sd2865 + 32'sd2048) >>> 11;          // ±18000

    reg [15:0] pen_u;
    always @(*) begin
        if      (th_d11 < 32'sd0)      pen_u = th_d11[15:0] + 16'd36000;
        else if (th_d11 >= 32'sd36000) pen_u = th_d11[15:0] - 16'd36000;
        else                           pen_u = th_d11[15:0];
    end

    reg [15:0] arm_u;
    always @(*) begin
        if      (arm_d11 < 32'sd0)      arm_u = arm_d11[15:0] + 16'd36000;
        else if (arm_d11 >= 32'sd36000) arm_u = arm_d11[15:0] - 16'd36000;
        else                            arm_u = arm_d11[15:0];
    end

    // 角速度 Q10 rad/s → 0.1°/s：×573 >> 10（+512 四舍五入）
    wire signed [15:0] rods = ((thd * 32'sd573 + 32'sd512) >>> 10);
    wire signed [15:0] arms = ((ald * 32'sd573 + 32'sd512) >>> 10);

    //---------------------- UART 发送 ----------------------
    reg  [7:0] tx_data;
    reg        tx_start;
    wire       tx_busy, tx_line;

    uart_tx_8n1 #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_tx (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_start (tx_start),
        .tx_data  (tx_data),
        .txd      (tx_line),
        .tx_busy  (tx_busy)
    );

    assign txd = tx_line;

    //---------------------- 周期触发 ----------------------
    reg [31:0] pdiv;
    reg        fire;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pdiv <= 32'd0;
            fire <= 1'b0;
        end else if (pdiv == tick - 1'b1) begin
            pdiv <= 32'd0;
            fire <= 1'b1;
        end else begin
            pdiv <= pdiv + 1'b1;
            fire <= 1'b0;
        end
    end

    //---------------------- 发送状态机 ----------------------
    localparam [1:0] S_WAIT = 2'd0, S_SEND = 2'd1, S_GAP = 2'd2;

    reg [1:0]  st;

    assign busy = (st != S_WAIT);
    reg [3:0]  idx;
    reg        seen;

    reg [7:0]  st_r;
    reg [15:0] arm_r, pen_r;
    reg signed [15:0] arms_r, rods_r, u_r;

    wire [7:0] chk = st_r ^ arm_r[15:8] ^ arm_r[7:0] ^ pen_r[15:8] ^ pen_r[7:0]
                         ^ arms_r[15:8] ^ arms_r[7:0] ^ rods_r[15:8] ^ rods_r[7:0]
                         ^ u_r[15:8] ^ u_r[7:0] ^ 8'hAA ^ 8'h55;

    function [7:0] byte_at;
        input [3:0] i;
        begin
            case (i)
                4'd0:  byte_at = 8'hAA;
                4'd1:  byte_at = 8'h55;
                4'd2:  byte_at = st_r;
                4'd3:  byte_at = arm_r[15:8];
                4'd4:  byte_at = arm_r[7:0];
                4'd5:  byte_at = pen_r[15:8];
                4'd6:  byte_at = pen_r[7:0];
                4'd7:  byte_at = arms_r[15:8];
                4'd8:  byte_at = arms_r[7:0];
                4'd9:  byte_at = rods_r[15:8];
                4'd10: byte_at = rods_r[7:0];
                4'd11: byte_at = u_r[15:8];
                4'd12: byte_at = u_r[7:0];
                default: byte_at = chk;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_WAIT;
            idx      <= 4'd0;
            seen     <= 1'b0;
            tx_start <= 1'b0;
            tx_data  <= 8'd0;
            st_r     <= 8'd0;
            arm_r    <= 16'd0;
            pen_r    <= 16'd0;
            arms_r   <= 16'sd0;
            rods_r   <= 16'sd0;
            u_r      <= 16'sd0;
        end else begin
            tx_start <= 1'b0;

            case (st)
                S_WAIT: if (fire && !hold) begin
                    st_r   <= status;
                    arm_r  <= arm_u;
                    pen_r  <= pen_u;
                    arms_r <= arms;
                    rods_r <= rods;
                    u_r    <= u_duty;
                    idx    <= 4'd0;
                    seen   <= 1'b0;
                    st     <= S_SEND;
                end

                S_SEND: if (!tx_busy) begin
                    if (!seen) begin
                        tx_data  <= byte_at(idx);
                        tx_start <= 1'b1;
                        seen     <= 1'b1;
                    end else begin
                        if (idx == 4'd13) st <= S_GAP;
                        else begin
                            idx  <= idx + 1'b1;
                            seen <= 1'b0;
                        end
                    end
                end

                S_GAP: if (!tx_busy) st <= S_WAIT;

                default: st <= S_WAIT;
            endcase
        end
    end

endmodule