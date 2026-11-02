//=============================================================================
// menu_frame.v — 整帧流式菜单渲染（不用窗口命令，字 2 倍大）
//
// 行样式（style）：
//   0 纯文字（最多 5 字，居中）           —— 24..183
//   1 标签 + 六格小数 ±ddd.d             —— 值区 136..231
//   2 标签 + 两位整数（速度 00~99）      —— 值区 168..199
//   3 旋转顺(逆)时针（5 字，第 3 字动态） —— 24..183
//
// 曲线页：4 条独立小图，数据来自 60Hz 环形缓冲（内部 BSRAM）
//=============================================================================
`timescale 1ns/1ps

module menu_frame (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [3:0]  page,
    input  wire [2:0]  cursor,
    input  wire [3:0]  pstart,
    input  wire [31:0] pr_val,       // 当前预扫描行的参数实时值
    input  wire [23:0] pr_bcd,       // 6 位 BCD（高位在前）
    input  wire        pr_neg,       // 负数标志
    output wire [3:0]  pr_idx,
    input  wire        edit,
    input  wire [1:0]  dir_state,
    input  wire        armed,
    input  wire [11:0] val_c1, val_c2, val_c3, val_c4,
    input  wire [11:0] val_c5, val_c6, val_c7, val_c8,
    input  wire [6:0]  speed,
    input  wire signed [12:0] val_ang,
    input  wire signed [15:0] mon0, mon1, mon2, mon3,

    input  wire               smp_stb,
    input  wire signed [7:0]  smp0, smp1, smp2, smp3,

    output reg         busy,
    output reg         done,

    output wire        sclk,
    output wire        mosi,
    output wire        cs_n,
    output wire        dc
);

    localparam [15:0] C_BG = 16'h0841;
    localparam [15:0] C_FG = 16'hFFFF;
    localparam [15:0] C_HL = 16'h2D7F;
    localparam [15:0] C_HF = 16'h0000;
    localparam [15:0] C_ED = 16'hFD20;
    localparam [15:0] C_TT = 16'h07FF;
    localparam [15:0] C_AX = 16'h5AEB;
    localparam [15:0] C_BASE = 16'h2104;
    localparam [15:0] C_CH0 = 16'h07FF, C_CH1 = 16'h07E0,
                       C_CH2 = 16'hFD20, C_CH3 = 16'hF81F;

    function [15:0] chan_col;
        input [1:0] i;
        begin
            case (i) 2'd0: chan_col = C_CH0; 2'd1: chan_col = C_CH1;
                     2'd2: chan_col = C_CH2; default: chan_col = C_CH3; endcase
        end
    endfunction

    //---------------- SPI ----------------
    reg  [7:0] tx_data;
    reg        tx_cmd;
    reg        tx_start;
    wire       tx_busy, tx_done;

    st7789_spi u_spi (
        .clk (clk), .rst_n (rst_n),
        .start (tx_start), .tx_data (tx_data), .tx_cmd (tx_cmd),
        .keep_cs (1'b0),
        .busy (tx_busy), .done (tx_done),
        .sclk (sclk), .mosi (mosi), .cs_n (cs_n), .dc (dc)
    );

    //---------------- 坐标 ----------------
    reg [7:0]  px, py;
    reg [16:0] pix_cnt;

    //---------------- 曲线环形缓冲 ----------------
    reg [31:0] cmem [0:255];
    reg [7:0]  wptr;
    reg [31:0] cdat;

    wire [8:0] rsum  = {1'b0, wptr} + {1'b0, px};
    wire [7:0] raddr = (rsum >= 9'd240) ? (rsum[7:0] - 8'd240) : rsum[7:0];

    always @(posedge clk) begin
        if (smp_stb) cmem[wptr] <= {smp3, smp2, smp1, smp0};
        cdat <= cmem[raddr];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)       wptr <= 8'd0;
        else if (smp_stb) wptr <= (wptr == 8'd239) ? 8'd0 : (wptr + 8'd1);
    end

    //---------------- 页面表 ----------------
    function [2:0] row_cnt;
        input [3:0] p;
        begin
            case (p)
                4'd1: row_cnt = 3'd4;
                4'd2: row_cnt = 3'd3;
                4'd3: row_cnt = 3'd2;
                4'd4: row_cnt = 3'd4;
                4'd5: row_cnt = 3'd4;
                4'd6: row_cnt = 3'd2;
                4'd7: row_cnt = 3'd2;
                default: row_cnt = 3'd0;
            endcase
        end
    endfunction

    function [5:0] row_sid;
        input [3:0] p;
        input [2:0] r;
        input [2:0] ps;
        begin
            case (p)
                4'd1: case (r) 3'd0: row_sid = 6'd1; 3'd1: row_sid = 6'd2;
                              3'd2: row_sid = 6'd25; default: row_sid = 6'd4; endcase
                4'd2: case (r) 3'd0: row_sid = 6'd20; 3'd1: row_sid = 6'd5; default: row_sid = 6'd6; endcase
                4'd3: case (r) 3'd0: row_sid = 6'd21; default: row_sid = 6'd22; endcase
                4'd4: row_sid = 6'd26 + {2'd0, ps} + {2'd0, r};
                4'd5: case (r) 3'd0: row_sid = 6'd10; 3'd1: row_sid = 6'd11;
                              3'd2: row_sid = 6'd12; default: row_sid = 6'd13; endcase
                4'd6: case (r) 3'd0: row_sid = 6'd23; default: row_sid = 6'd24; endcase
                4'd7: case (r) 3'd0: row_sid = 6'd15; default: row_sid = 6'd24; endcase
                default: row_sid = 6'd0;
            endcase
        end
    endfunction

    function [2:0] row_style;
        input [3:0] p;
        input [2:0] r;
        begin
            case (p)
                4'd4: row_style = 3'd6;
                4'd5: row_style = 3'd1;
                4'd6: row_style = (r == 3'd0) ? 3'd2 : 3'd4;
                4'd7: row_style = (r == 3'd0) ? 3'd1 : 3'd0;
                default: row_style = 3'd0;
            endcase
        end
    endfunction

    function [5:0] ttl_sid;
        input [3:0] p;
        begin
            case (p)
                4'd1: ttl_sid = 6'd0;
                4'd2: ttl_sid = 6'd1;
                4'd3: ttl_sid = 6'd2;
                4'd4: ttl_sid = 6'd25;
                4'd5: ttl_sid = 6'd4;
                4'd6: ttl_sid = 6'd8;
                4'd7: ttl_sid = 6'd22;
                default: ttl_sid = 6'd4;
            endcase
        end
    endfunction

    function [2:0] sid_len;
        input [5:0] s;
        begin
            case (s)
                6'd5, 6'd6, 6'd16, 6'd20:          sid_len = 3'd2;
                6'd10, 6'd11, 6'd12, 6'd13,
                6'd14, 6'd15, 6'd17, 6'd18,
                6'd23, 6'd24, 6'd26, 6'd27, 6'd28, 6'd29,
                6'd30, 6'd31, 6'd32, 6'd33:          sid_len = 3'd3;
                default:                              sid_len = 3'd4;
            endcase
        end
    endfunction

    //---------------- 行带 ----------------
    wire [2:0] nrow = row_cnt(page);

    reg [7:0] y0row;
    always @(*) begin
        case (nrow)
            3'd4: y0row = 8'd74;
            3'd3: y0row = 8'd93;
            3'd2: y0row = 8'd112;
            default: y0row = 8'd74;
        endcase
    end

    wire in_r0 = (nrow >= 3'd1) && (py >= y0row)          && (py < y0row + 8'd32);
    wire in_r1 = (nrow >= 3'd2) && (py >= y0row + 8'd38)  && (py < y0row + 8'd70);
    wire in_r2 = (nrow >= 3'd3) && (py >= y0row + 8'd76)  && (py < y0row + 8'd108);
    wire in_r3 = (nrow >= 3'd4) && (py >= y0row + 8'd114) && (py < y0row + 8'd146);
    wire in_rows = in_r0 | in_r1 | in_r2 | in_r3;

    reg [2:0] ridx;
    reg [7:0] rrem;
    always @(*) begin
        if (in_r0)      begin ridx = 3'd0; rrem = py - y0row;          end
        else if (in_r1) begin ridx = 3'd1; rrem = py - (y0row + 8'd38); end
        else if (in_r2) begin ridx = 3'd2; rrem = py - (y0row + 8'd76); end
        else            begin ridx = 3'd3; rrem = py - (y0row + 8'd114); end
    end

    wire [2:0] rcur = in_rows ? ridx : 3'd0;

    //---------------- 标题 ----------------
    wire in_ttl_band = (py >= 8'd18) && (py <= 8'd49);
    wire [3:0] gy_ttl = (py - 8'd18) >> 1;

    wire [2:0] ttl_len = (page == 4'd1) ? 3'd3 : 3'd4;
    wire [7:0] ttl_x0  = 8'd120 - ({6'd0, ttl_len} << 4);

    wire in_ttl_txt = in_ttl_band && (px >= ttl_x0) &&
                      (px < (ttl_x0 + ({6'd0, ttl_len} << 5)));
    wire [7:0] dx_ttl = px - ttl_x0;
    wire [1:0] cidx_ttl = dx_ttl[6:5];
    wire [3:0] gx_ttl = dx_ttl[4:1];

    //---------------- 行文字 ----------------
    wire [2:0] style = row_style(page, rcur);
    wire [5:0] sid   = row_sid(page, rcur, pstart);
    wire       is_s4  = (style == 3'd4);
    wire [2:0] rlen   = (style == 3'd6) ? 3'd0 : (is_s4 ? 3'd2 : sid_len(sid));

    wire [7:0] row_x0      = (style == 3'd0)
                             ? (8'd120 - ({6'd0, rlen} << 4)) : 8'd24;
    wire [7:0] row_txt_end = row_x0 + ({6'd0, rlen} << 5);

    wire in_row_txt = in_rows && (px >= row_x0) && (px < row_txt_end);
    wire [7:0] dx_row = px - row_x0;
    wire [2:0] cidx_row = dx_row[7:5];
    wire [3:0] gx_row = dx_row[4:1];
    wire [3:0] gy_row = rrem[4:1];

    //---------------- style4：左「旋转」 + 右侧状态词（在 88~239 内居中）----------------
    wire [5:0] s2sid = (dir_state == 2'd0) ? 6'd34 : (dir_state == 2'd1) ? 6'd35 : 6'd36;
    wire [2:0] s2len = (dir_state == 2'd0) ? 3'd2 : 3'd3;
    wire [7:0] s2x0  = (dir_state == 2'd0) ? 8'd128 : 8'd112;   // 中心 ≈160

    wire in_s2 = in_rows && is_s4 && (px >= s2x0) &&
                 (px < (s2x0 + ({5'd0, s2len} << 5)));
    wire [7:0] dx_s2   = px - s2x0;
    wire [2:0] cidx_s2 = dx_s2[7:5];
    wire [3:0] gx_s2   = dx_s2[4:1];

    wire [5:0] sid_f  = in_ttl_txt ? ttl_sid(page) : (in_s2 ? s2sid : sid);
    wire [2:0] cidx_f = in_ttl_txt ? {1'b0, cidx_ttl} : (in_s2 ? cidx_s2 : cidx_row);

    wire [7:0] rch;
    str_rom u_str (.sid(sid_f), .pos({1'b0, cidx_f}), .ch(rch));

    wire [5:0] chid = rch[7] ? 6'd0 : {1'b0, rch[5:0]};

    wire [3:0] gy_mux = in_ttl_txt ? gy_ttl : gy_row;
    wire [3:0] gx_mux = in_ttl_txt ? gx_ttl : (in_s2 ? gx_s2 : gx_row);

    wire [15:0] glyph;
    font_cn u_fc (.idx(chid), .row(gy_mux), .bits(glyph));
    wire on = glyph[4'd15 - gx_mux];

    //---------------- 参数页：1.5x ASCII（12px/字 x 24px 高，18 字一行，x=12..227）----------------
    //  放大 1.5 倍不能用移位，这里用乘加代替除法：
    //    字形坐标 g = floor(2*u/3)，用 (u*2731)>>12 精确实现
    //    2731/4096 = 0.66675 >= 2/3，且误差 u*8.14e-5 < 1/3 对 u<4095 恒成立 → 逐点精确
    wire [3:0]  pidx  = pstart[3:0] + {1'b0, rcur};
    assign pr_idx = pstart[3:0] + {2'b0, rcur};

    wire [7:0]  ux    = px - 8'd12;                  // 文本区横坐标 0..215
    wire [27:0] hmul  = ux * 20'd2731;
    wire [7:0]  gcol  = hmul[19:12];                 // 全局字形列 0..143
    wire [4:0]  acidx = gcol[7:3];                   // 字符序号 0..17
    wire [2:0]  agx   = gcol[2:0];                   // 字形内横坐标

    wire [7:0]  ach_name;
    param_rom u_prom (.idx(pidx), .pos(acidx), .ch(ach_name));

    // 数值区：槽 11=符号，12~17=6 位数字；CLK_FREQ（第 0 行）固定显示 50M
    wire [3:0]  vslot   = acidx - 5'd11;
    wire        use_val = (style == 3'd6) && (pidx != 4'd0) &&
                          (pidx < 4'd10) && (acidx >= 5'd11);

    // 6 位 BCD 数字（d5 最高位）
    wire [3:0] d5 = pr_bcd[23:20], d4 = pr_bcd[19:16], d3 = pr_bcd[15:12];
    wire [3:0] d2 = pr_bcd[11:8],  d1 = pr_bcd[7:4],   d0 = pr_bcd[3:0];

    // 槽 11 = 符号，12~17 = 六位数字（前导零消隐）
    wire [7:0] ach_val =
        (vslot == 4'd0) ? (pr_neg ? 8'h2D : 8'h20) :
        (vslot == 4'd1) ? ((d5 != 4'd0) ? (8'h30 + d5) : 8'h20) :
        (vslot == 4'd2) ? ((d5 | d4) != 4'd0 ? (8'h30 + d4) : 8'h20) :
        (vslot == 4'd3) ? ((d5 | d4 | d3) != 4'd0 ? (8'h30 + d3) : 8'h20) :
        (vslot == 4'd4) ? ((d5 | d4 | d3 | d2) != 4'd0 ? (8'h30 + d2) : 8'h20) :
        (vslot == 4'd5) ? ((d5 | d4 | d3 | d2 | d1) != 4'd0 ? (8'h30 + d1) : 8'h20) :
        (vslot == 4'd6) ? (8'h30 + d0) : 8'h20;

    wire [7:0]  ach     = use_val ? ach_val : ach_name;

    wire asc_on = in_rows && (style == 3'd6) && (px >= 8'd12) && (px < 8'd228) &&
                  (rrem >= 8'd4) && (rrem < 8'd28);

    wire [7:0]  dy    = rrem - 8'd4;                 // 0..23
    wire [27:0] vmul  = dy * 20'd2731;
    wire [3:0]  agy   = vmul[15:12];                 // 0..15（16 行字形撑成 24px 高）

    wire [7:0]  abits;
    font_ascii u_fa2 (.code(ach[6:0]), .row(agy), .bits(abits));
    wire aon = abits[3'd7 - agx];

    //---------------- 数值区 ----------------
    reg [7:0]  vtab [0:31];


    wire in_val1 = in_rows && (style == 3'd1) && (px >= 8'd136) && (px <= 8'd231);
    wire in_val2 = in_rows && (style == 3'd2) && (px >= 8'd168) && (px <= 8'd199);
    wire in_val  = in_val1 | in_val2;

    wire [7:0] vdx   = in_val1 ? (px - 8'd136) : (px - 8'd168);
    wire [2:0] vcell = vdx[7:4];              // 16px 一格：0..5
    wire [3:0] vgx16 = vdx[3:0] >> 1;         // 8x16 字形横向 0..7
    wire [3:0] vgy   = rrem[4:1];

    wire [7:0] vtab_r;
    wire [7:0] vbits;
    font_ascii u_fa (.code(vtab_r[6:0]), .row(vgy), .bits(vbits));
    wire v_on = vbits[3'd7 - vgx16];

    // style2（速度）只用前两格
    wire [2:0] vcell_eff = (style == 3'd2) ? {2'b00, vcell[0]} : vcell;
    assign vtab_r = vtab[{rcur[1:0], vcell_eff}];

    //---------------- 数值预计算 ----------------
    function signed [15:0] vsel_of;
        input [2:0] r;
        reg [2:0] ix;
        begin
            ix = pstart + r;
            case (page)
                4'd4: vsel_of = (ix == 3'd0) ? {4'd0, val_c1} * 16'sd10 :
                                (ix == 3'd1) ? {4'd0, val_c2} * 16'sd10 :
                                (ix == 3'd2) ? {4'd0, val_c3} * 16'sd10 :
                                (ix == 3'd3) ? {4'd0, val_c4} * 16'sd10 :
                                (ix == 3'd4) ? {4'd0, val_c5} * 16'sd10 :
                                (ix == 3'd5) ? {4'd0, val_c6} * 16'sd10 :
                                (ix == 3'd6) ? {4'd0, val_c7} * 16'sd10 :
                                               {4'd0, val_c8} * 16'sd10;
                4'd5: vsel_of = (r == 3'd0) ? mon0 : (r == 3'd1) ? mon1 :
                                (r == 3'd2) ? mon2 : mon3;
                4'd7: vsel_of = {{3{val_ang[12]}}, val_ang};
                default: vsel_of = 16'sd0;
            endcase
        end
    endfunction

    function [15:0] bin2bcd;
        input [13:0] bin;
        integer i;
        reg [27:0] acc;
        begin
            acc = 28'd0;
            for (i = 13; i >= 0; i = i - 1) begin
                if (acc[3:0]   >= 4'd5) acc[3:0]   = acc[3:0]   + 4'd3;
                if (acc[7:4]   >= 4'd5) acc[7:4]   = acc[7:4]   + 4'd3;
                if (acc[11:8]  >= 4'd5) acc[11:8]  = acc[11:8]  + 4'd3;
                if (acc[15:12] >= 4'd5) acc[15:12] = acc[15:12] + 4'd3;
                acc = {acc[26:0], bin[i]};
            end
            bin2bcd = acc[15:0];
        end
    endfunction

    reg [1:0]  pre_r;
    reg [4:0]  pre_base;
    reg        pre_neg;
    reg [13:0] pre_mag;
    reg [15:0] pre_bcd;
    reg [2:0]  pre_sty;

    wire signed [15:0] pre_s = vsel_of(pre_r);


    //---------------- 曲线页 ----------------
    wire [1:0] band   = (py < 8'd96) ? 2'd0 : (py < 8'd136) ? 2'd1 : (py < 8'd176) ? 2'd2 : 2'd3;
    wire       in_band = (py >= 8'd56) && (py <= 8'd215);

    wire signed [7:0] samp = (band == 2'd0) ? cdat[7:0]   :
                             (band == 2'd1) ? cdat[15:8]  :
                             (band == 2'd2) ? cdat[23:16] : cdat[31:24];

    wire signed [9:0]  center = 10'sd76 + {1'b0, band, 5'd0} + {1'b0, band, 3'd0};
    wire signed [15:0] soff   = (samp * 16'sd51) >>> 8;
    wire signed [9:0]  ycurve = center - soff[9:0];
    wire signed [9:0]  py10 = {2'b00, py};
    wire on_curve = (py10 >= ycurve - 10'sd1) && (py10 <= ycurve + 10'sd1);

    wire [15:0] curve_px = in_band
                         ? (on_curve ? chan_col(band)
                                     : ((py10 == center) ? C_BASE : C_BG))
                         : C_BG;

    //---------------- 颜色 ----------------
    wire       sel_row = (rcur == cursor) && (page != 4'd4);
    wire       on_mon  = (page == 4'd5);
    wire [15:0] ch_col = chan_col(rcur[1:0]);

    wire [15:0] row_bg = on_mon ? (sel_row ? ch_col : C_BG)
                               : ((sel_row && (edit || armed)) ? C_ED : (sel_row ? C_HL : C_BG));
    wire [15:0] row_fg = on_mon ? (sel_row ? C_HF : ch_col)
                               : (sel_row ? C_HF : C_FG);

    wire [15:0] pix_color =
        (page == 4'd8) ? (in_ttl_txt ? (on ? C_TT : C_BG) : curve_px) :
        in_ttl_txt ? (on ? C_TT : C_BG) :
        asc_on     ? (aon ? row_fg : row_bg) :
        in_row_txt ? (on ? row_fg : row_bg) :
        in_s2      ? (on ? row_fg : row_bg) :
        in_val     ? (v_on ? row_fg : row_bg) :
        in_rows    ? row_bg :
                     C_BG;

    //---------------- 状态机 ----------------
    localparam [3:0] S_IDLE  = 4'd0, S_PRE_A = 4'd1, S_PRE_B = 4'd2,
                     S_CMD   = 4'd3, S_CMD_W = 4'd9, S_SET   = 4'd4,
                     S_PIX   = 4'd5, S_HI_W  = 4'd6, S_LO_W  = 4'd7,
                     S_DONE  = 4'd8;

    reg [3:0]  st;
    reg [1:0]  sett;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            busy     <= 1'b0;
            done     <= 1'b0;
            tx_start <= 1'b0;
            tx_data  <= 8'd0;
            tx_cmd   <= 1'b1;
            px       <= 8'd0;
            py       <= 8'd0;
            pix_cnt  <= 17'd0;
            pre_r    <= 2'd0;
            pre_base <= 5'd0;
            pre_neg  <= 1'b0;
            pre_mag  <= 14'd0;
            pre_bcd  <= 16'd0;
            pre_sty  <= 2'd0;
            sett     <= 2'd0;
        end else begin
            done     <= 1'b0;
            tx_start <= 1'b0;

            case (st)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy    <= 1'b1;
                        px      <= 8'd0;
                        py      <= 8'd0;
                        pix_cnt <= 17'd0;
                        pre_r   <= 2'd0;
                        pre_base<= 5'd0;
                        st      <= S_PRE_A;
                    end
                end

                S_PRE_A: begin
                    pre_sty <= row_style(page, pre_r);
                    pre_neg <= pre_s[15];
                    pre_mag <= (pre_s[15] ? (14'd0 - pre_s[13:0]) : pre_s[13:0]);
                    pre_bcd <= bin2bcd(pre_s[15] ? (14'd0 - pre_s[13:0]) : pre_s[13:0]);
                    st      <= S_PRE_B;
                end

                S_PRE_B: begin
                    if (pre_sty == 3'd1) begin
                        vtab[pre_base + 5'd0] <= pre_neg ? 8'h2D : 8'h2B;
                        vtab[pre_base + 5'd1] <= (pre_bcd[15:12] == 4'd0) ? 8'h20 : (8'h30 + pre_bcd[15:12]);
                        vtab[pre_base + 5'd2] <= (pre_bcd[15:12] == 4'd0 && pre_bcd[11:8] == 4'd0)
                                                 ? 8'h20 : (8'h30 + pre_bcd[11:8]);
                        vtab[pre_base + 5'd3] <= 8'h30 + pre_bcd[7:4];
                        vtab[pre_base + 5'd4] <= 8'd46;
                        vtab[pre_base + 5'd5] <= 8'h30 + pre_bcd[3:0];
                    end else if (pre_sty == 3'd2) begin
                        vtab[pre_base + 5'd0] <= 8'h30 + (speed / 7'd10);
                        vtab[pre_base + 5'd1] <= 8'h30 + (speed - (speed / 7'd10) * 7'd10);
                    end else begin
                        vtab[pre_base + 5'd0] <= 8'h20;
                        vtab[pre_base + 5'd1] <= 8'h20;
                    end

                    if (pre_r == 2'd3) st <= S_CMD;
                    else begin
                        pre_r    <= pre_r + 1'b1;
                        pre_base <= pre_base + 5'd8;
                        st       <= S_PRE_A;
                    end
                end

                S_CMD: begin
                    tx_data  <= 8'h2C;
                    tx_cmd   <= 1'b1;
                    tx_start <= 1'b1;
                    st       <= S_CMD_W;
                end

                S_CMD_W: begin
                    if (tx_done) begin
                        sett <= 2'd0;
                        st   <= S_SET;
                    end
                end

                S_SET: begin
                    if (sett == 2'd2) st <= S_PIX;
                    else              sett <= sett + 1'b1;
                end

                S_PIX: begin
                    tx_data  <= pix_color[15:8];
                    tx_cmd   <= 1'b0;
                    tx_start <= 1'b1;
                    st       <= S_HI_W;
                end

                S_HI_W: begin
                    if (tx_done) begin
                        tx_data  <= pix_color[7:0];
                        tx_cmd   <= 1'b0;
                        tx_start <= 1'b1;
                        st       <= S_LO_W;
                    end
                end

                S_LO_W: begin
                    if (tx_done) begin
                        if (px == 8'd239) begin
                            px <= 8'd0;
                            py <= py + 1'b1;
                        end else begin
                            px <= px + 1'b1;
                        end

                        if (pix_cnt == 17'd57599) begin
                            st <= S_DONE;
                        end else begin
                            pix_cnt <= pix_cnt + 1'b1;
                            sett    <= 2'd0;
                            st      <= S_SET;
                        end
                    end
                end

                S_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    st   <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule