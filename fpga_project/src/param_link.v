//=============================================================================
// param_link.v — A5 5A 参数从机（与上位机「对接说明」一致）
//
// 请求（上位机 → 板子）
//   A5 5A 01 idx CRC                读参数          5 B
//   A5 5A 02 idx v0 v1 v2 v3 CRC    写参数          9 B（值低字节在前）
//   A5 5A 03 CRC                    全部读取        4 B
//
// 应答（板子 → 上位机，固定 10 B）
//   A5 5A 命令|0x80 结果 idx v0..v3 CRC
//   结果 00 成功 / 01 失败（不在参数页、不可写、超范围…）
//
// CRC8：多项式 0x07，初值 0；整帧（含 CRC 字节）累加后为 0 即正确。
//
// TX 线共用：与示波帧分时。hold=1 表示要占用，等 scope_busy=0 后 tx_active=1。
//=============================================================================
`timescale 1ns/1ps

module param_link #(
    parameter integer CLK_FREQ = 50_000_000,
    parameter integer BAUD     = 115_200
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rx,
    input  wire [3:0]  page,          // 菜单页，4 = 参数页
    input  wire        scope_busy,    // 示波帧正在发送

    output wire        txd,           // 参数应答数据
    output reg         tx_active,     // 1 = 占用 TX 线
    output reg         hold,          // 1 = 请示波帧等待

    output wire [31:0] p_scope_div,   // 示波分频（给 uart_frame 用）

    output wire signed [15:0] o_c1,   // 给 lqr_controller
    output wire signed [15:0] o_c2,
    output wire signed [15:0] o_c3,
    output wire signed [15:0] o_c4,
    output wire signed [15:0] o_th_catch,   // 给 swing_ctrl
    input  wire [3:0]  pr_idx,        // 菜单读取：参数序号 0~9
    output wire [23:0] pr_bcd,        // 菜单读取：6 位 BCD（[23:20]=万…[3:0]=个）
    output wire        pr_neg,        // 菜单读取：是否为负
    output wire [31:0] pr_val         // 菜单读取：对应数值
);

    //---------------- 参数寄存器 ----------------
    localparam signed [31:0] DEF_CLK  = 32'sd50_000_000;
    localparam signed [31:0] DEF_BAUD = 32'sd115_200;
    localparam signed [31:0] DEF_PWM  = 32'sd80_000;
    localparam signed [31:0] DEF_SCO  = 32'sd500_000;
    localparam signed [31:0] DEF_CPR  = 32'sd1064;
    localparam signed [31:0] DEF_C1   = -32'sd1350;   // 默认增益
    localparam signed [31:0] DEF_C2   = -32'sd1700;   // 默认增益
    localparam signed [31:0] DEF_C3   =  32'sd7300;   // 默认增益
    localparam signed [31:0] DEF_C4   =  32'sd1940;   // 默认增益
    localparam signed [31:0] DEF_THC  =  32'sd1800;

    reg signed [31:0] r_clk, r_baud, r_pwm, r_sco, r_cpr;
    reg signed [31:0] r_c1, r_c2, r_c3, r_c4, r_thc;

    assign p_scope_div = r_sco;
    assign o_c1       = r_c1[15:0];
    assign o_c2       = r_c2[15:0];
    assign o_c3       = r_c3[15:0];
    assign o_c4       = r_c4[15:0];
    assign o_th_catch = r_thc[15:0];

    function [7:0] idx_of_row;
        input [3:0] r;
        begin
            case (r)
                4'd0: idx_of_row = 8'h01;  4'd1: idx_of_row = 8'h02;
                4'd2: idx_of_row = 8'h03;  4'd3: idx_of_row = 8'h04;
                4'd4: idx_of_row = 8'h05;  4'd5: idx_of_row = 8'h10;
                4'd6: idx_of_row = 8'h11;  4'd7: idx_of_row = 8'h12;
                4'd8: idx_of_row = 8'h13;  default: idx_of_row = 8'h14;
            endcase
        end
    endfunction


    // 参数值查询
    function signed [31:0] val_of;
        input [7:0] ix;
        begin
            case (ix)
                8'h01: val_of = r_clk;
                8'h02: val_of = r_baud;
                8'h03: val_of = r_pwm;
                8'h04: val_of = r_sco;
                8'h05: val_of = r_cpr;
                8'h10: val_of = r_c1;
                8'h11: val_of = r_c2;
                8'h12: val_of = r_c3;
                8'h13: val_of = r_c4;
                8'h14: val_of = r_thc;
                default: val_of = 32'sd0;
            endcase
        end
    endfunction

    // 菜单读取口（必须放在 val_of 定义之后，否则综合取到 0）
    assign pr_val = val_of(idx_of_row(pr_idx));

    //---------------- BCD 表：10 个参数各 6 位十进制（写触发/上电全量转换）----------------
    function [3:0] row_of_idx;
        input [7:0] ix;
        begin
            case (ix)
                8'h01: row_of_idx = 4'd0;  8'h02: row_of_idx = 4'd1;
                8'h03: row_of_idx = 4'd2;  8'h04: row_of_idx = 4'd3;
                8'h05: row_of_idx = 4'd4;  8'h10: row_of_idx = 4'd5;
                8'h11: row_of_idx = 4'd6;  8'h12: row_of_idx = 4'd7;
                8'h13: row_of_idx = 4'd8;  default: row_of_idx = 4'd9;
            endcase
        end
    endfunction

    // 每个 BCD 位 >=5 则 +3（double-dabble 的校正）
    function [23:0] bcd_add3;
        input [23:0] v;
        integer i;
        reg [3:0] d;
        begin
            for (i = 0; i < 6; i = i + 1) begin
                d = v[i*4 +: 4];
                bcd_add3[i*4 +: 4] = (d >= 4'd5) ? (d + 4'd3) : d;
            end
        end
    endfunction

    // 取某行的绝对值（负数转 BCD 前必须取绝对值，否则会把补码当无符号数转换）
    function [31:0] abs_of_row;
        input [3:0] r;
        reg [31:0] v;
        begin
            v = val_of(idx_of_row(r));
            abs_of_row = v[31] ? (32'd0 - v) : v;
        end
    endfunction

    reg [23:0] bcd_tab [0:9];

    reg [31:0] cvt_bin;
    reg [23:0] cvt_bcd;
    reg [4:0]  cvt_cnt;
    reg [3:0]  cvt_row;
    reg        cvt_all;
    reg        cvt_go;
    reg        bcd_ready;
    reg        wr_pulse;
    reg [3:0]  wr_row;

    reg [1:0]  bs;
    localparam [1:0] B_IDLE = 2'd0, B_RUN = 2'd1, B_NEXT = 2'd2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bs        <= B_IDLE;
            cvt_bin   <= 32'd0;
            cvt_bcd   <= 24'd0;
            cvt_cnt   <= 5'd0;
            cvt_row   <= 4'd0;
            cvt_all   <= 1'b0;
            bcd_ready <= 1'b0;
        end else begin
            case (bs)
                B_IDLE: begin
                    // 上电先全量转换一遍，之后只在写入成功时转换该参数
                    if (!bcd_ready) begin
                        cvt_all <= 1'b1;
                        cvt_row <= 4'd0;
                        cvt_bin <= abs_of_row(4'd0);
                        cvt_bcd <= 24'd0;
                        cvt_cnt <= 5'd0;
                        bs      <= B_RUN;
                    end else if (wr_pulse) begin
                        cvt_all <= 1'b0;
                        cvt_row <= wr_row;
                        cvt_bin <= abs_of_row(wr_row);
                        cvt_bcd <= 24'd0;
                        cvt_cnt <= 5'd0;
                        bs      <= B_RUN;
                    end
                end

                B_RUN: begin
                    cvt_bcd <= (bcd_add3(cvt_bcd) << 1) | {20'd0, cvt_bin[31]};
                    cvt_bin <= {cvt_bin[30:0], 1'b0};
                    if (cvt_cnt == 5'd31) bs <= B_NEXT;
                    else                  cvt_cnt <= cvt_cnt + 1'b1;
                end

                B_NEXT: begin
                    bcd_tab[cvt_row] <= cvt_bcd;
                    if (cvt_all && cvt_row < 4'd9) begin
                        cvt_row <= cvt_row + 1'b1;
                        cvt_bin <= abs_of_row(cvt_row + 1'b1);
                        cvt_bcd <= 24'd0;
                        cvt_cnt <= 5'd0;
                        bs      <= B_RUN;
                    end else begin
                        bcd_ready <= 1'b1;
                        bs        <= B_IDLE;
                    end
                end
            endcase
        end
    end

    assign pr_bcd = bcd_tab[pr_idx];
    assign pr_neg = pr_val[31];

    // 是否可写（0x04 / 0x10~0x14）
    function is_writable;
        input [7:0] ix;
        begin
            is_writable = (ix == 8'h04) || (ix >= 8'h10 && ix <= 8'h14);
        end
    endfunction

    // 范围检查
    function in_range;
        input [7:0]  ix;
        input signed [31:0] v;
        begin
            case (ix)
                8'h04: in_range = (v >= 32'sd50_000) && (v <= 32'sd5_000_000);
                8'h14: in_range = (v >= 32'sd0) && (v <= 32'sd8191);
                8'h10, 8'h11, 8'h12, 8'h13:
                       in_range = (v >= -32'sd8191) && (v <= 32'sd8191);
                default: in_range = 1'b0;
            endcase
        end
    endfunction

    //---------------- CRC8（多项式 0x07）----------------
    function [7:0] crc8_b;
        input [7:0] c;
        input [7:0] d;
        integer i;
        reg [7:0] t;
        begin
            t = c ^ d;
            for (i = 0; i < 8; i = i + 1)
                t = t[7] ? ((t << 1) ^ 8'h07) : (t << 1);
            crc8_b = t;
        end
    endfunction

    //---------------- 接收 ----------------
    wire [7:0] rx_byte;
    wire       rx_done;
    wire       rx_err;

    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst_n(rst_n), .rx(rx),
        .rx_byte(rx_byte), .rx_done(rx_done), .frame_err(rx_err)
    );

    // 帧装配
    localparam [2:0] H_HUNT = 3'd0, H_H1 = 3'd1, H_CMD = 3'd2,
                     H_BODY = 3'd3, H_CRC = 3'd4;

    reg [2:0]  hs;
    reg [7:0]  hdr [0:8];       // 收到的字节
    reg [3:0]  hcnt;            // 已收字节数
    reg [7:0]  crc_r;
    reg        got_frame;       // 一帧校验通过，待处理
    reg [7:0]  f_cmd, f_idx;
    reg signed [31:0] f_val;

    reg [31:0] all_idx;         // 全读时的序号

    // 每帧需要的字节数
    function [3:0] frame_len;
        input [7:0] c;
        begin
            case (c)
                8'h01:   frame_len = 4'd5;    // 头2 + 命令 + 编号 + CRC
                8'h02:   frame_len = 4'd9;    // 头2 + 命令 + 编号 + 4 值 + CRC
                8'h03:   frame_len = 4'd4;    // 头2 + 命令 + CRC
                default: frame_len = 4'd0;
            endcase
        end
    endfunction

    wire [3:0] need_len = frame_len(hdr[2]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs        <= H_HUNT;
            hcnt      <= 4'd0;
            crc_r     <= 8'd0;
            got_frame <= 1'b0;
            f_cmd     <= 8'd0;
            f_idx     <= 8'd0;
            f_val     <= 32'sd0;
        end else begin
            got_frame <= 1'b0;

            if (rx_done) begin
                // CRC 只覆盖 A5 5A 之后的字节（命令字节起）
                if (hs == H_CMD || hs == H_BODY) crc_r <= crc8_b(crc_r, rx_byte);
                if (hcnt < 4'd9) hdr[hcnt] <= rx_byte;
                hcnt  <= hcnt + 1'b1;

                case (hs)
                    H_HUNT: begin
                        if (rx_byte == 8'hA5) hs <= H_H1;
                        else begin hcnt <= 4'd0; crc_r <= 8'd0; end
                    end
                    H_H1: begin
                        if (rx_byte == 8'h5A) hs <= H_CMD;
                        else begin hs <= H_HUNT; hcnt <= 4'd0; crc_r <= 8'd0; end
                    end
                    H_CMD: hs <= H_BODY;
                    H_BODY: begin
                        // hcnt 已经把本字节计入；收到末字节（CRC）时判断
                        if (hcnt + 4'd1 >= need_len) begin
                            hs   <= H_HUNT;
                            hcnt <= 4'd0;
                            if (crc8_b(crc_r, rx_byte) == 8'd0 && need_len != 4'd0) begin
                                got_frame <= 1'b1;
                                f_cmd     <= hdr[2];
                                f_idx     <= hdr[3];
                                f_val     <= {hdr[7], hdr[6], hdr[5], hdr[4]};   // 值在 hdr[4..7]（低字节在前）
                            end
                            crc_r <= 8'd0;
                        end
                    end
                    default: hs <= H_HUNT;
                endcase
            end
        end
    end

    //---------------- 应答组装 ----------------
    reg [4:0]  st;
    reg [7:0]  resp [0:9];
    reg [3:0]  bpos;
    reg        seen;
    reg [7:0]  wx_idx;
    reg signed [31:0] wx_val;
    reg        wx_err;
    reg        rd_all;

    reg [7:0]  tx_data;
    reg        tx_start;
    wire       tx_busy;
    wire       p_txd;

    uart_tx_8n1 #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .tx_start(tx_start), .tx_data(tx_data),
        .txd(p_txd), .tx_busy(tx_busy)
    );

    assign txd = p_txd;

    localparam [4:0] S_IDLE = 5'd0, S_PREP = 5'd1, S_WAIT = 5'd2,
                     S_SEND = 5'd3, S_GAP  = 5'd4, S_NEXT = 5'd5;

    // 写操作门控（组合）
    wire wr_gate    = got_frame && (f_cmd == 8'h02);
    wire wr_allowed = (page == 4'd4) && is_writable(f_idx) && in_range(f_idx, f_val);

    // 组装一帧应答
    task build_resp;
        input [7:0] cmd;
        input       res;
        input [7:0] ix;
        input signed [31:0] v;
        reg   [7:0] c;
        begin
            resp[0] <= 8'hA5;
            resp[1] <= 8'h5A;
            resp[2] <= cmd | 8'h80;
            resp[3] <= res ? 8'h01 : 8'h00;
            resp[4] <= ix;
            resp[5] <= v[7:0];
            resp[6] <= v[15:8];
            resp[7] <= v[23:16];
            resp[8] <= v[31:24];
            c = crc8_b(8'd0, cmd | 8'h80);
            c = crc8_b(c, res ? 8'h01 : 8'h00);
            c = crc8_b(c, ix);
            c = crc8_b(c, v[7:0]);
            c = crc8_b(c, v[15:8]);
            c = crc8_b(c, v[23:16]);
            c = crc8_b(c, v[31:24]);
            resp[9] <= c;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            bpos      <= 4'd0;
            seen      <= 1'b0;
            tx_start  <= 1'b0;
            tx_data   <= 8'd0;
            wr_pulse  <= 1'b0;
            wr_row    <= 4'd0;
            r_clk  <= DEF_CLK;   r_baud <= DEF_BAUD;  r_pwm <= DEF_PWM;
            r_sco  <= DEF_SCO;   r_cpr  <= DEF_CPR;
            r_c1   <= DEF_C1;    r_c2   <= DEF_C2;    r_c3  <= DEF_C3;
            r_c4   <= DEF_C4;    r_thc  <= DEF_THC;
            tx_active <= 1'b0;
            hold      <= 1'b0;
            rd_all    <= 1'b0;
            all_idx   <= 32'd0;
            wx_idx    <= 8'd0;
            wx_val    <= 32'sd0;
            wx_err    <= 1'b0;
        end else begin
            tx_start <= 1'b0;

            case (st)
                S_IDLE: begin
                    hold      <= 1'b0;
                    tx_active <= 1'b0;
                    if (got_frame) begin
                        rd_all <= (f_cmd == 8'h03);
                        all_idx<= 32'd0;
                        wx_idx <= f_idx;
                        wx_val <= f_val;
                        wx_err <= (page != 4'd4) ? 1'b1 :
                                  ((f_cmd == 8'h02) ? (wr_allowed ? 1'b0 : 1'b1) : 1'b0);
                        // 写入必须与 f_val 同一拍落盘（wx_val 下一拍才更新）
                        if (wr_gate && wr_allowed) begin
                            wr_pulse <= 1'b1;
                            wr_row   <= row_of_idx(f_idx);
                            case (f_idx)
                                8'h04: r_sco <= f_val;
                                8'h10: r_c1  <= f_val;
                                8'h11: r_c2  <= f_val;
                                8'h12: r_c3  <= f_val;
                                8'h13: r_c4  <= f_val;
                                8'h14: r_thc <= f_val;
                                default: ;
                            endcase
                        end
                        st <= S_PREP;
                    end
                end

                S_PREP: begin
                    hold     <= 1'b1;
                    wr_pulse <= 1'b0;
                    if (rd_all) begin
                        // 全读：按顺序回 10 个参数
                        build_resp(8'h01, wx_err,
                                   idx_of_row(all_idx[3:0]),
                                   val_of(idx_of_row(all_idx[3:0])));
                        all_idx <= all_idx + 1'b1;
                    end else if (f_cmd == 8'h02) begin
                        // 写：回写后的实际值
                        build_resp(8'h02, wx_err, wx_idx,
                                   wx_err ? val_of(wx_idx) : wx_val);
                    end else begin
                        build_resp(8'h01, wx_err, wx_idx, val_of(wx_idx));
                    end
                    bpos <= 4'd0;
                    seen <= 1'b0;
                    st   <= S_WAIT;
                end

                S_WAIT: begin
                    hold <= 1'b1;
                    if (!scope_busy) begin
                        tx_active <= 1'b1;
                        st        <= S_SEND;
                    end
                end

                S_SEND: begin
                    if (!tx_busy) begin
                        if (!seen) begin
                            tx_data  <= resp[bpos];
                            tx_start <= 1'b1;
                            seen     <= 1'b1;
                        end else if (bpos == 4'd9) begin
                            st <= S_GAP;
                        end else begin
                            bpos <= bpos + 1'b1;
                            seen <= 1'b0;
                        end
                    end
                end

                S_GAP: begin
                    if (!tx_busy) begin
                        if (rd_all && all_idx < 32'd10) st <= S_PREP;
                        else                            st <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    tx_active <= 1'b0;
                    hold      <= 1'b0;
                    rd_all    <= 1'b0;
                    st        <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule