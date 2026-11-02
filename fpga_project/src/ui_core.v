//=============================================================================
// ui_core.v — 菜单状态机
//
// 页面：1 主菜单 2 基础功能(定点/上电/断电) 3 扩展功能(平衡绕圈/角度旋转)
//       4 参数读取(c1~c8 分两页) 5 实时监测 6 平衡绕圈 7 角度旋转 8 曲线
//
// 按键：SW1 返回   SW2 进入/确认   SW3 上移/减小/上一页   SW4 下移/增大/下一页
//=============================================================================
`timescale 1ns/1ps

module ui_core #(
    parameter integer CLK_FREQ = 50_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [3:0]  press,        // 单拍脉冲
    input  wire [3:0]  keys,         // 消抖后的电平（1 = 按下）

    output reg  [3:0]  page,
    output reg  [2:0]  cursor,
    output reg  [3:0]  pstart,       // 参数页起始：0 / 4 / 8
    output reg         edit,
    output reg  [1:0]  dir_state,
    output reg         armed,    // 0=停止 1=顺时针 2=逆时针

    output reg  [11:0] val_c1, val_c2, val_c3, val_c4,
    output reg  [11:0] val_c5, val_c6, val_c7, val_c8,
    output reg  [6:0]  speed,        // 旋转速度 20~50 °/s
    output reg  signed [12:0] val_ang,   // 0.1°，-3600~+3600

    input  wire signed [15:0] mon0, mon1, mon2, mon3,

    output reg         cmd_zero,     // 基础功能·定点：单拍脉冲
    output reg         cmd_on,       // 基础功能·上电：单拍脉冲
    output reg         cmd_off,      // 基础功能·断电：单拍脉冲
    output reg         param_lock,   // 参数页断电锁：1 = 已断电、SW1 不能退出
    output reg  signed [12:0] rot_ang_cmd,   // 角度旋转：确认瞬间的角度快照（0.1°）
    output reg         cmd_rot,       // 角度旋转：单拍命令脉冲
    output reg         dirty
);

    localparam [3:0] P_MAIN = 4'd1, P_BASIC = 4'd2, P_EXT = 4'd3, P_PARAM = 4'd4,
                     P_MON  = 4'd5, P_CIR   = 4'd6, P_ROT = 4'd7, P_CURVE = 4'd8;

    //---------------- 页面表 ----------------
    function [2:0] row_count;
        input [3:0] p;
        begin
            case (p)
                P_MAIN:  row_count = 3'd4;
                P_BASIC: row_count = 3'd3;
                P_EXT:   row_count = 3'd2;
                P_PARAM: row_count = 3'd4;
                P_MON:   row_count = 3'd4;
                P_CIR:   row_count = 3'd2;
                P_ROT:   row_count = 3'd2;
                default: row_count = 3'd0;
            endcase
        end
    endfunction

    function [5:0] row_sid;
        input [3:0] p;
        input [2:0] r;
        input [2:0] ps;
        begin
            case (p)
                P_MAIN:  case (r) 3'd0: row_sid = 6'd1; 3'd1: row_sid = 6'd2;
                                  3'd2: row_sid = 6'd25; default: row_sid = 6'd4; endcase
                P_BASIC: case (r) 3'd0: row_sid = 6'd20; 3'd1: row_sid = 6'd5; default: row_sid = 6'd6; endcase
                P_EXT:   case (r) 3'd0: row_sid = 6'd21; default: row_sid = 6'd22; endcase
                P_PARAM: row_sid = 6'd26 + {2'd0, ps} + {2'd0, r};
                P_MON:   case (r) 3'd0: row_sid = 6'd10; 3'd1: row_sid = 6'd11;
                                  3'd2: row_sid = 6'd12; default: row_sid = 6'd13; endcase
                P_CIR:   case (r) 3'd0: row_sid = 6'd23; default: row_sid = 6'd24; endcase
                P_ROT:   case (r) 3'd0: row_sid = 6'd15; default: row_sid = 6'd24; endcase
                default: row_sid = 6'd0;
            endcase
        end
    endfunction

    // kind: 0=goto 1=action 2=edit 3=value
    function [1:0] row_kind;
        input [3:0] p;
        input [2:0] r;
        begin
            case (p)
                P_BASIC: row_kind = 2'd1;
                P_EXT:   row_kind = 2'd0;
                P_PARAM: row_kind = 2'd3;                       // 只读
                P_MON:   row_kind = 2'd3;
                P_CIR:   row_kind = (r == 3'd0) ? 2'd2 : 2'd1;
                P_ROT:   row_kind = (r == 3'd0) ? 2'd2 : 2'd1;
                default: row_kind = 2'd0;
            endcase
        end
    endfunction

    function [3:0] child_page;
        input [3:0] p;
        input [2:0] r;
        begin
            case (p)
                P_MAIN:  case (r) 3'd0: child_page=P_BASIC; 3'd1: child_page=P_EXT;
                                      3'd2: child_page=P_PARAM; default: child_page=P_MON; endcase
                P_EXT:   child_page = (r == 3'd0) ? P_CIR : P_ROT;
                P_MON:   child_page = P_CURVE;
                default: child_page = P_MAIN;
            endcase
        end
    endfunction

    function [3:0] parent_page;
        input [3:0] p;
        begin
            case (p)
                P_BASIC, P_EXT, P_PARAM, P_MON: parent_page = P_MAIN;
                P_CIR, P_ROT:                   parent_page = P_EXT;
                P_CURVE:                        parent_page = P_MON;
                default:                        parent_page = P_MAIN;
            endcase
        end
    endfunction

    wire [2:0] sel_idx = pstart + cursor;

    reg [2:0] save_cur [0:7];
    wire [3:0] pp_now = parent_page(page);
    wire [3:0] cp_now = child_page(page, cursor);
    integer k;

    localparam integer MON_DIV = CLK_FREQ / 2;
    reg [31:0] mon_cnt;

    reg [1:0] dir_prev;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) dir_prev <= 2'd0;
        else        dir_prev <= dir_state;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            page     <= P_MAIN;
            cursor   <= 3'd0;
            pstart   <= 4'd0;
            edit     <= 1'b0;
            armed    <= 1'b0;
            dir_state<= 2'd0;
            val_c1 <= 12'd800; val_c2 <= 12'd1500; val_c3 <= 12'd0; val_c4 <= 12'd0;
            val_c5 <= 12'd0;   val_c6 <= 12'd0;    val_c7 <= 12'd0; val_c8 <= 12'd0;
            speed  <= 7'd30;        // 默认 30 °/s
            val_ang<= 13'sd0;
            cmd_zero <= 1'b0;
            cmd_on   <= 1'b0;
            cmd_off  <= 1'b0;
            cmd_rot  <= 1'b0;
            rot_ang_cmd <= 13'sd0;
            param_lock <= 1'b0;
            dirty   <= 1'b1;
            mon_cnt <= 32'd0;
            for (k = 0; k < 8; k = k + 1) save_cur[k] <= 3'd0;
        end else begin
            dirty    <= 1'b0;
            cmd_zero <= 1'b0;
            cmd_on   <= 1'b0;
            cmd_off  <= 1'b0;
            cmd_rot  <= 1'b0;

            // 平衡绕圈：SW2 确认后进入“方向指示”；再按 SW1/SW2 先退出确认态
            if (page != P_CIR) begin
                armed <= 1'b0;
            end else if (!armed) begin
                if (!edit && cursor == 3'd1 && press[1]) armed <= 1'b1;
            end else if (press[0] || press[1]) begin
                armed     <= 1'b0;          // 第一次按下：只退出确认态
                dir_state <= 2'd0;
                dirty     <= 1'b1;
            end

            if (page == P_CIR && armed) begin
                if (keys[3] && !keys[2])      dir_state <= 2'd2;     // SW3 按住 → 逆时针
                else if (keys[2] && !keys[3]) dir_state <= 2'd1;     // SW4 按住 → 顺时针
                else                          dir_state <= 2'd0;     // 都抬起 → 停止
                if (dir_state != dir_prev) dirty <= 1'b1;           // 变化就重绘
            end

            if (press[0] && !(page == P_PARAM && param_lock)) begin
                // SW1：退出编辑 / 返回上一级（参数页断电锁时禁用）
                if (edit) begin
                    edit <= 1'b0;
                end else if (page != P_MAIN) begin
                    page   <= pp_now;
                    cursor <= save_cur[pp_now[2:0]];
                end
                dirty <= 1'b1;
            end
            else if (press[1]) begin
                if (edit) begin
                    edit <= 1'b0;
                end else if (row_kind(page, cursor) == 2'd2) begin
                    edit <= 1'b1;
                end else if (row_kind(page, cursor) == 2'd1) begin
                    if (page == P_ROT) begin
                        cmd_rot     <= 1'b1;        // 发一次角度旋转命令
                        rot_ang_cmd <= val_ang;     // 快照角度
                       // val_ang     <= 13'sd0;      // 角度清零
                    end
                    else if (page == P_BASIC) begin
                        // 0 = 定点，1 = 上电，2 = 断电
                        case (cursor)
                            3'd0: cmd_zero <= 1'b1;
                            3'd1: cmd_on   <= 1'b1;
                            default: cmd_off <= 1'b1;
                        endcase
                    end
                end else if (row_kind(page, cursor) == 2'd0) begin
                    save_cur[page[2:0]] <= cursor;
                    page   <= cp_now;
                    cursor <= save_cur[cp_now[2:0]];
                    if (cp_now == P_PARAM) pstart <= 4'd0;
                end else if (page == P_MON) begin
                    save_cur[page[2:0]] <= cursor;
                    page   <= P_CURVE;
                    cursor <= 3'd0;
                end else if (page == P_PARAM) begin
                    // 参数页：SW2 第一次按下 = 断电并锁定；再按一次 = 上电起摆
                    if (!param_lock) begin
                        param_lock <= 1'b1;
                        cmd_off    <= 1'b1;
                    end else begin
                        param_lock <= 1'b0;
                        cmd_on     <= 1'b1;
                    end
                end
                dirty <= 1'b1;
            end
            else if (page != P_CURVE && press[2] && !(page == P_CIR && armed)) begin
                if (edit) begin
                    if (page == P_CIR)      speed   <= (speed <= 7'd20) ? 7'd20 : (speed - 7'd10);
                    else if (page == P_ROT) val_ang <= (val_ang <= -13'sd3590) ? -13'sd3600 : (val_ang - 13'sd100);
                    else if (page == P_PARAM) begin
                        case (sel_idx)
                            3'd0: val_c1 <= (val_c1 >= 12'd10) ? val_c1 - 12'd10 : 12'd0;
                            3'd1: val_c2 <= (val_c2 >= 12'd10) ? val_c2 - 12'd10 : 12'd0;
                            3'd2: val_c3 <= (val_c3 >= 12'd10) ? val_c3 - 12'd10 : 12'd0;
                            3'd3: val_c4 <= (val_c4 >= 12'd10) ? val_c4 - 12'd10 : 12'd0;
                            3'd4: val_c5 <= (val_c5 >= 12'd10) ? val_c5 - 12'd10 : 12'd0;
                            3'd5: val_c6 <= (val_c6 >= 12'd10) ? val_c6 - 12'd10 : 12'd0;
                            3'd6: val_c7 <= (val_c7 >= 12'd10) ? val_c7 - 12'd10 : 12'd0;
                            default: val_c8 <= (val_c8 >= 12'd10) ? val_c8 - 12'd10 : 12'd0;
                        endcase
                    end
                end else if (page == P_PARAM) begin
                    pstart <= (pstart >= 4'd4) ? (pstart - 4'd4) : 4'd0;   // 上一页
                end else begin
                    cursor <= (cursor == 3'd0) ? (row_count(page) - 3'd1) : (cursor - 3'd1);
                end
                dirty <= 1'b1;
            end
            else if (page != P_CURVE && press[3] && !(page == P_CIR && armed)) begin
                if (edit) begin
                    if (page == P_CIR)      speed   <= (speed >= 7'd100) ? 7'd100 : (speed + 7'd10);
                    else if (page == P_ROT) val_ang <= (val_ang >= 13'sd3590) ? 13'sd3600 : (val_ang + 13'sd100);
                    else if (page == P_PARAM) begin
                        case (sel_idx)
                            3'd0: val_c1 <= (val_c1 > 12'd989) ? 12'd999 : val_c1 + 12'd10;
                            3'd1: val_c2 <= (val_c2 > 12'd989) ? 12'd999 : val_c2 + 12'd10;
                            3'd2: val_c3 <= (val_c3 > 12'd989) ? 12'd999 : val_c3 + 12'd10;
                            3'd3: val_c4 <= (val_c4 > 12'd989) ? 12'd999 : val_c4 + 12'd10;
                            3'd4: val_c5 <= (val_c5 > 12'd989) ? 12'd999 : val_c5 + 12'd10;
                            3'd5: val_c6 <= (val_c6 > 12'd989) ? 12'd999 : val_c6 + 12'd10;
                            3'd6: val_c7 <= (val_c7 > 12'd989) ? 12'd999 : val_c7 + 12'd10;
                            default: val_c8 <= (val_c8 > 12'd989) ? 12'd999 : val_c8 + 12'd10;
                        endcase
                    end
                end else if (page == P_PARAM) begin
                    pstart <= (pstart <= 4'd4) ? (pstart + 4'd4) : 4'd8;   // 下一页
                end else begin
                    cursor <= (cursor == (row_count(page) - 3'd1)) ? 3'd0 : (cursor + 3'd1);
                end
                dirty <= 1'b1;
            end

            // 监测页定时重绘
            if (mon_cnt == MON_DIV - 1) mon_cnt <= 32'd0;
            else                        mon_cnt <= mon_cnt + 1'b1;
            if (page == P_MON && mon_cnt == MON_DIV - 1) dirty <= 1'b1;

            if (page == P_CURVE) begin
                cursor <= 3'd0;
                edit   <= 1'b0;
            end

            // 离开参数页后解除断电锁（防止状态残留）
            if (page != P_PARAM && param_lock) param_lock <= 1'b0;
        end
    end

endmodule