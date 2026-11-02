import io

p = r'E:\FPGA_project\total_project\src\ui_core.v'
s = io.open(p, encoding='utf-8').read()
orig = s

# ---------------- 1. 端口：基础功能命令 + 参数页断电锁 ----------------
s = s.replace("""    output reg  [6:0]  speed,        // 0~99""",
"""    output reg  [6:0]  speed,        // 旋转速度 20~50 °/s""")
s = s.replace("""    output reg         run_flag,
    output reg         dirty
);""",
"""    output reg         cmd_zero,     // 基础功能·定点：单拍脉冲
    output reg         cmd_on,       // 基础功能·上电：单拍脉冲
    output reg         cmd_off,      // 基础功能·断电：单拍脉冲
    output reg         param_lock,   // 参数页断电锁：1 = 已断电、SW1 不能退出
    output reg         dirty
);""")

# ---------------- 2. 复位默认值 ----------------
s = s.replace("""            speed  <= 7'd0;""", """            speed  <= 7'd30;        // 默认 30 °/s""")
s = s.replace("""            run_flag<= 1'b0;""",
"""            cmd_zero <= 1'b0;
            cmd_on   <= 1'b0;
            cmd_off  <= 1'b0;
            param_lock <= 1'b0;""")

# ---------------- 3. 每拍清脉冲 ----------------
s = s.replace("""        end else begin
            dirty <= 1'b0;""",
"""        end else begin
            dirty    <= 1'b0;
            cmd_zero <= 1'b0;
            cmd_on   <= 1'b0;
            cmd_off  <= 1'b0;""")

# ---------------- 4. 方向映射：SW3=逆时针，SW4=顺时针 ----------------
s = s.replace("""                if (keys[2] && !keys[3])      dir_state <= 2'd1;     // SW3 按住 → 顺时针
                else if (keys[3] && !keys[2]) dir_state <= 2'd2;     // SW4 按住 → 逆时针""",
"""                if (keys[2] && !keys[3])      dir_state <= 2'd2;     // SW3 按住 → 逆时针
                else if (keys[3] && !keys[2]) dir_state <= 2'd1;     // SW4 按住 → 顺时针""")

# ---------------- 5. SW1 在参数页断电锁下不能退出 ----------------
s = s.replace("""            if (press[0]) begin
                // SW1：退出编辑 / 返回上一级
                if (edit) begin
                    edit <= 1'b0;
                end else if (page != P_MAIN) begin""",
"""            if (press[0] && !(page == P_PARAM && param_lock)) begin
                // SW1：退出编辑 / 返回上一级（参数页断电锁时禁用）
                if (edit) begin
                    edit <= 1'b0;
                end else if (page != P_MAIN) begin""")

# ---------------- 6. 基础功能：三行分别产生命令 ----------------
s = s.replace("""                end else if (row_kind(page, cursor) == 2'd1) begin
                    if (page == P_ROT)       val_ang <= 13'sd0;     // 角度自动归零
                    else if (page == P_BASIC) run_flag <= (cursor != 3'd2);
                end""",
"""                end else if (row_kind(page, cursor) == 2'd1) begin
                    if (page == P_ROT)       val_ang <= 13'sd0;     // 角度自动归零
                    else if (page == P_BASIC) begin
                        // 0 = 定点，1 = 上电，2 = 断电
                        case (cursor)
                            3'd0: cmd_zero <= 1'b1;
                            3'd1: cmd_on   <= 1'b1;
                            default: cmd_off <= 1'b1;
                        endcase
                    end
                end""")

# ---------------- 7. 参数页：SW2 切换断电/上电锁 ----------------
s = s.replace("""                end else if (page == P_MON) begin
                    save_cur[page[2:0]] <= cursor;
                    page   <= P_CURVE;
                    cursor <= 3'd0;
                end""",
"""                end else if (page == P_MON) begin
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
                end""")

# 离开参数页时自动解锁
s = s.replace("""            if (page == P_CURVE) begin
                cursor <= 3'd0;
                edit   <= 1'b0;
            end""",
"""            if (page == P_CURVE) begin
                cursor <= 3'd0;
                edit   <= 1'b0;
            end

            // 离开参数页后解除断电锁（防止状态残留）
            if (page != P_PARAM && param_lock) param_lock <= 1'b0;""")

# ---------------- 8. 速度范围 20~50 ----------------
s = s.replace("""                    if (page == P_CIR)      speed   <= (speed == 7'd0) ? 7'd99 : (speed - 7'd1);""",
"""                    if (page == P_CIR)      speed   <= (speed <= 7'd20) ? 7'd20 : (speed - 7'd1);""")
s = s.replace("""                    if (page == P_CIR)      speed   <= (speed == 7'd99) ? 7'd0 : (speed + 7'd1);""",
"""                    if (page == P_CIR)      speed   <= (speed >= 7'd50) ? 7'd50 : (speed + 7'd1);""")

# ---------------- 9. 参数页取消旧的 8 参数增减（参数已由上位机写） ----------------
# 保留原样即可：P_PARAM 是只读行，edit 永远不会置位，这些分支不可达。

io.open(p, 'w', encoding='utf-8').write(s)
print('ui_core 修改:', 'CHANGED' if s != orig else 'NO CHANGE')
for tag in ['cmd_zero', 'param_lock', '7\'d30', 'dir_state <= 2\'d2']:
    print('  ', tag, '->', s.count(tag))