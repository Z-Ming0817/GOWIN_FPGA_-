//=============================================================================
// total_top.v — 菜单显示 + 倒立摆闭环 总顶层
//
// 数据链：
//   ADS1120 ─SPI─▶ state_observer ◀─ 编码器A/B ─▶ pos_interp
//                        │ th/thd/al/ald
//        ┌───────────────┼────────────────┬──────────────┐
//        ▼               ▼                ▼              ▼
//    mon_conv       mode_fsm         menu_frame      uart_frame(AA55)
//        │               │ bal_en/sw_en                     
//        ▼               ▼
//    ui_core ◀── 按键   arm_target ─▶ lqr_controller ─┐
//        │                 ▲                          ├─▶ tb6612 ─▶ 电机
//        │                 └──── swing_ctrl ──────────┘
//        └── page/cursor/… ─▶ menu_frame ─▶ ST7789 (240x240)
//
// 菜单命令（ui_core 产生）：
//   基础功能：定点 cmd_zero / 上电 cmd_on / 断电 cmd_off
//   平衡绕圈：speed(20~50 °/s) + dir_state(SW3 逆时针 / SW4 顺时针)
//   参数读取：SW2 断电锁定（SW1 禁退，SW3/SW4 仍可翻页），再按 SW2 上电
//=============================================================================
`timescale 1ns/1ps

module total_top #(
    parameter integer CLK_FREQ   = 50_000_000,
    parameter integer BAUD       = 115_200,

    //---------------- 显示屏 ----------------
    parameter integer SCLK_HALF  = 10,
    parameter integer SAMPLE_DIV = 50_000,
    parameter integer WD_DIV     = 5_000_000,
    parameter integer INIT_DLY   = 50_000,

    //---------------- 状态观测器参数 ----------------
    parameter integer SPEED_DIV      = 1_200_000,   // 20 ms
    parameter integer ADS_SPS        = 2000,        // ADS1120 Turbo
    parameter [15:0]  ANG_MID        = 16'd14927,
    parameter integer ANG_SPAN       = 10267,
    parameter integer COUNTS_PER_REV = 1064,
    parameter integer LPF_SHIFT      = 4,
    parameter integer DTH_N          = 16,
    parameter integer THD_AVG_SH     = 0,
    parameter integer A7_EN          = 0,
    parameter integer SPD_SRC        = 0,
    parameter integer SPD_T_HI       = 96,
    parameter integer INV_TH         = 0,
    parameter integer INV_AL         = 0,

    //---------------- 控制 ----------------
    parameter signed [15:0] U_LIMIT  = 16'sd2500,
    parameter integer PWM_HZ         = 80_000,
    parameter integer SMP_DIV        = 33            // 2000/33 ≈ 60 Hz 曲线采样
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [4:0] key,

    // 传感器
    output wire       adc_sclk,
    output wire       adc_cs_n,
    output wire       adc_mosi,
    input  wire       adc_miso,
    input  wire       adc_drdy_n,
    input  wire       enc_a,
    input  wire       enc_b,

    // 电机
    output wire       pwm_out,
    output wire       in1_out,
    output wire       in2_out,

    // 显示屏
    output wire       lcd_sclk,
    output wire       lcd_mosi,
    output wire       lcd_cs_n,
    output wire       lcd_dc,
    output wire       lcd_reset_n,
    output wire       lcd_backlight,

    // 串口
    input  wire       uart_rx,
    output wire       uart_tx
);

    //=========================================================================
    // 复位
    //=========================================================================
    wire rst_n_i;
    sys_reset #(.CLK_FREQ(CLK_FREQ), .HOLD_CYC(CLK_FREQ / 50)) u_sys_reset (
        .clk (clk), .rst_n_in (rst_n), .rst_n (rst_n_i)
    );

    localparam integer RST_CYC = CLK_FREQ / 1000;
    reg [16:0] rst_cnt;
    always @(posedge clk or negedge rst_n_i) begin
        if (!rst_n_i) rst_cnt <= 17'd0;
        else if (rst_cnt != RST_CYC - 1) rst_cnt <= rst_cnt + 1'b1;
    end
    assign lcd_reset_n = (rst_cnt == RST_CYC - 1);

    reg lcd_rst_d;
    always @(posedge clk or negedge rst_n_i) begin
        if (!rst_n_i) lcd_rst_d <= 1'b0;
        else          lcd_rst_d <= lcd_reset_n;
    end
    wire init_go = lcd_reset_n & ~lcd_rst_d;

    //=========================================================================
    // LCD 初始化
    //=========================================================================
    wire       init_done, i_keep_cs;
    wire [7:0] i_tx_data;
    wire       i_tx_cmd, i_tx_start, i_tx_busy, i_tx_done;
    wire       i_sclk, i_mosi, i_cs_n, i_dc;

    lcd_init #(.CLK_FREQ(CLK_FREQ)) u_init (
        .clk (clk), .rst_n (rst_n_i), .start (init_go), .done (init_done),
        .tx_data (i_tx_data), .tx_cmd (i_tx_cmd), .tx_start (i_tx_start),
        .tx_busy (i_tx_busy), .keep_cs (i_keep_cs)
    );

    st7789_spi u_spi_init (
        .clk (clk), .rst_n (rst_n_i),
        .start (i_tx_start), .tx_data (i_tx_data), .tx_cmd (i_tx_cmd),
        .keep_cs (i_keep_cs), .busy (i_tx_busy), .done (i_tx_done),
        .sclk (i_sclk), .mosi (i_mosi), .cs_n (i_cs_n), .dc (i_dc)
    );

    //=========================================================================
    // 传感器：ADS1120 + 编码器 + 观测器
    //=========================================================================
    wire [15:0] adc_code;
    wire        adc_valid, adc_fresh, adc_err;

    ads1120 #(
        .CLK_FREQ   (CLK_FREQ),
        .SCLK_HALF  (SCLK_HALF),
        .SAMPLE_DIV (SAMPLE_DIV),
        .WD_DIV     (WD_DIV),
        .INIT_DLY   (INIT_DLY)
    ) u_adc (
        .clk       (clk),
        .rst_n     (rst_n_i),
        .sclk      (adc_sclk),
        .cs_n      (adc_cs_n),
        .mosi      (adc_mosi),
        .miso      (adc_miso),
        .drdy_n    (adc_drdy_n),
        .mux_sel   (4'b1000),
        .data      (adc_code),
        .valid     (adc_valid),
        .adc_fresh (adc_fresh),
        .adc_err   (adc_err)
    );

    // tick 只有 1 拍宽：单纯两级移位（写成 if(adc_valid) 会得到 2 拍宽，θ̇ 会翻倍）
    reg [1:0] tick_d;
    always @(posedge clk or negedge rst_n_i) begin
        if (!rst_n_i) tick_d <= 2'd0;
        else          tick_d <= {tick_d[0], adc_valid};
    end
    wire tick = tick_d[1];

    wire signed [31:0] enc_pos, enc_pos_q4;
    wire signed [15:0] enc_speed, enc_speed_t;
    wire               enc_dir;

    encoder_decoder #(
        .CLK_FREQ  (CLK_FREQ),
        .SPEED_DIV (SPEED_DIV),
        .SPD_Q4    (A7_EN)
    ) u_enc (
        .clk         (clk),
        .rst_n       (rst_n_i),
        .enc_a       (enc_a),
        .enc_b       (enc_b),
        .pos_q4      (enc_pos_q4),
        .pos         (enc_pos),
        .speed       (enc_speed),
        .speed_valid (),
        .dir         (enc_dir),
        .speed_t     (enc_speed_t)
    );

    pos_interp u_interp (
        .clk     (clk),
        .rst_n   (rst_n_i),
        .tick    (tick),
        .pos     (enc_pos),
        .speed_t (enc_speed_t),
        .pos_q4  (enc_pos_q4)
    );

    wire signed [15:0] spd_m_q4 = (A7_EN != 0) ? enc_speed : (enc_speed <<< 4);
    wire signed [15:0] spd_sel  = (SPD_SRC == 0)                    ? spd_m_q4 :
                                  (enc_speed_t <  SPD_T_HI &&
                                   enc_speed_t > -SPD_T_HI)         ? enc_speed_t :
                                                                      spd_m_q4;

    wire signed [31:0] pos_ctrl = (A7_EN != 0) ? enc_pos_q4 : (enc_pos <<< 4);
    wire signed [31:0] pos_use  = (INV_AL != 0) ? -pos_ctrl : pos_ctrl;

    localparam integer KTH_CALC = (3_294_113 + (ANG_SPAN / 2)) / ANG_SPAN;

    wire signed [15:0] th_raw, thd_raw, al_raw, ald_raw;

    state_observer #(
        .CLK_FREQ       (CLK_FREQ),
        .SPEED_DIV      (SPEED_DIV),
        .ANG_MID        (ANG_MID),
        .COUNTS_PER_REV (COUNTS_PER_REV),
        .KTH_NUM        (KTH_CALC),
        .LPF_SHIFT      (LPF_SHIFT),
        .TICK_HZ        (ADS_SPS),
        .DTH_N          (DTH_N),
        .THD_AVG_SH     (THD_AVG_SH),
        .SPEED_SH       (4),
        .POS_SH         (4)
    ) u_obs (
        .clk      (clk),
        .rst_n    (rst_n_i),
        .tick     (tick),
        .adc_code (adc_code),
        .pos      (pos_use),
        .speed    (spd_sel),
        .th       (th_raw),
        .thd      (thd_raw),
        .al       (al_raw),
        .ald      (ald_raw)
    );

    wire signed [15:0] th  = (INV_TH != 0) ? -th_raw  : th_raw;
    wire signed [15:0] thd = (INV_TH != 0) ? -thd_raw : thd_raw;

    //-------------------------------------------------------------------------
    // 基准点与显示臂角
    //   控制：arm_target 的目标基准 al_base（定点时更新）
    //   显示：臂角读数 = wrap(al_raw - al_base)，定点那一刻变 0，之后从 0 起算
    //   ★ 两段必须放在 mon_conv / uart_frame 之前（Verilog 先声明后使用）
    //-------------------------------------------------------------------------
    wire zero_pulse;

    reg signed [15:0] al_base;   // 赋值在后面（还要接受“角度旋转到位”更新）

    //---------------- 显示用臂角（相对基准点）----------------
    //   定点时记下基准角，读数在定点那一刻变成 0，之后从 0 起算。
    //   实现：显示臂角 = wrap(al_raw - al_base)，缠绕到 ±π。
    //   控制通路仍然用 al_raw 与 al_base，两者互不影响。
    localparam signed [16:0] PI_Q12     =  17'sd12868;   // π  ×4096
    localparam signed [16:0] TWO_PI_Q12 =  17'sd25736;   // 2π ×4096

    wire signed [16:0] al_d17   = {al_raw[15], al_raw} - {al_base[15], al_base};
    wire signed [16:0] al_disp_17 = (al_d17 >=  PI_Q12) ? (al_d17 - TWO_PI_Q12) :
                                    (al_d17 <  -PI_Q12) ? (al_d17 + TWO_PI_Q12) : al_d17;
    // 打一拍：减法+缠绕的组合链直接进 mon_conv/uart_frame 会拉长到 28ns
    // （实测 −8.12ns、66 个违例端点全在这条路上），显示量延迟 20ns 无影响
    reg signed [15:0] al_disp;
    always @(posedge clk or negedge rst_n_i) begin
        if (!rst_n_i) al_disp <= 16'sd0;
        else          al_disp <= al_disp_17[15:0];
    end


    //=========================================================================
    // 按键
    //=========================================================================
    wire [4:0] key_raw = {~key[4], key[3:0]};      // D11 低有效 → 反相
    wire [4:0] key_press5, key_level5;

    key_debounce #(.CLK_FREQ(CLK_FREQ), .DEB_MS(20), .N(5)) u_key (
        .clk (clk), .rst_n (rst_n_i),
        .key_in (key_raw), .key_level (key_level5), .key_press (key_press5)
    );

    // ★ SW2 与 SW3 已独立，不再需要 p_sw3 的互斥屏蔽
    wire p_sw1 = key_press5[0];
    wire p_sw2 = key_press5[1];
    wire p_sw3 = key_press5[2];
    wire p_sw4 = key_press5[3] | key_press5[4];

    localparam integer LOCK_CYC = (CLK_FREQ / 1000) * 200;
    reg [24:0] lock_cnt;
    wire       lock_busy = (lock_cnt != 25'd0);
    wire       any_press = p_sw1 | p_sw2 | p_sw3 | p_sw4;

    always @(posedge clk or negedge rst_n_i) begin
        if (!rst_n_i)                     lock_cnt <= 25'd0;
        else if (any_press && !lock_busy) lock_cnt <= LOCK_CYC;
        else if (lock_busy)               lock_cnt <= lock_cnt - 1'b1;
    end

    reg [3:0] key_press;
    always @(posedge clk or negedge rst_n_i) begin
        if (!rst_n_i)                      key_press <= 4'd0;
        else if (any_press && !lock_busy)  key_press <= {p_sw4, p_sw3, p_sw2, p_sw1};
        else                               key_press <= 4'd0;
    end

    //=========================================================================
    // 菜单
    //=========================================================================
    wire [3:0]  page;
    wire [2:0]  cursor;
    wire [3:0]  pstart;
    wire [3:0]  pr_idx;
    wire [31:0] pr_val;
    wire [23:0] pr_bcd;
    wire        pr_neg;
    wire        edit;
    wire [1:0]  dir_state;
    wire        armed;
    wire [11:0] val_c1, val_c2, val_c3, val_c4, val_c5, val_c6, val_c7, val_c8;
    wire [6:0]  speed;
    wire signed [12:0] val_ang;
    wire        cmd_zero, cmd_on, cmd_off, param_lock, ui_dirty;
    wire        cmd_rot;                     // 角度旋转：单拍命令
    wire signed [12:0] rot_ang_cmd;          // 角度旋转：角度快照（0.1°）
    reg         arm_jump;                    // 交还时把 arm_target 内部目标拉到基准

    // 显示量 / 曲线归一化
    wire signed [15:0] v_th, v_thd, v_al, v_ald;
    wire signed [7:0]  n_th, n_thd, n_al, n_ald;

    mon_conv u_conv (
        .clk (clk), .rst_n (rst_n_i),
        .th (th), .thd (thd), .al (al_disp), .ald (ald_raw),
        .v_th (v_th), .v_thd (v_thd), .v_al (v_al), .v_ald (v_ald),
        .n_th (n_th), .n_thd (n_thd), .n_al (n_al), .n_ald (n_ald)
    );

    reg [5:0] smp_cnt;
    reg       smp_stb;
    always @(posedge clk or negedge rst_n_i) begin
        if (!rst_n_i) begin
            smp_cnt <= 6'd0;
            smp_stb <= 1'b0;
        end else if (tick) begin
            smp_stb <= 1'b0;
            if (smp_cnt == SMP_DIV - 1) begin
                smp_cnt <= 6'd0;
                smp_stb <= 1'b1;
            end else begin
                smp_cnt <= smp_cnt + 1'b1;
            end
        end else begin
            smp_stb <= 1'b0;
        end
    end

    ui_core #(.CLK_FREQ(CLK_FREQ)) u_ui (
        .clk (clk), .rst_n (rst_n_i),
        .press (init_done ? key_press : 4'd0),
        .keys  ({key_level5[3], key_level5[2], key_level5[1], key_level5[0]}),
        .page (page), .cursor (cursor), .pstart (pstart),
        .edit (edit), .dir_state (dir_state), .armed (armed),
        .val_c1 (val_c1), .val_c2 (val_c2), .val_c3 (val_c3), .val_c4 (val_c4),
        .val_c5 (val_c5), .val_c6 (val_c6), .val_c7 (val_c7), .val_c8 (val_c8),
        .speed (speed), .val_ang (val_ang),
        .mon0 (v_th), .mon1 (v_thd), .mon2 (v_al), .mon3 (v_ald),
        .cmd_zero (cmd_zero), .cmd_on (cmd_on), .cmd_off (cmd_off),
        .param_lock (param_lock),
        .rot_ang_cmd (rot_ang_cmd), .cmd_rot (cmd_rot),
        .dirty (ui_dirty)
    );

    //=========================================================================
    // 控制：模式 / 目标 / LQR / 起摆 / 驱动
    //=========================================================================
    wire [1:0] mode;
    wire       bal_en, sw_en, sw_ready;   // zero_pulse 已在前面声明
    wire [31:0] p_scope_div;
    wire signed [15:0] p_c1, p_c2, p_c3, p_c4, p_th_catch;

    mode_fsm u_mode (
        .clk (clk), .rst_n (rst_n_i), .tick (tick),
        .cmd_zero (cmd_zero), .cmd_on (cmd_on), .cmd_off (cmd_off),
        .adc_err (adc_err), .th (th), .sw_ready (sw_ready),
        .mode (mode), .bal_en (bal_en), .sw_en (sw_en), .zero_pulse (zero_pulse)
    );

    // 旋转：SW3=逆时针(dir_state=2)，SW4=顺时针(dir_state=1)
    wire        rot_dir  = (dir_state == 2'd1);
    wire        rot_hold = armed && (dir_state != 2'd0) && bal_en;
    // 速度 °/s → Q25 rad/tick：ROT_W = °/s × 292817/1000 ≈ ×293（30 °/s → 8790）
    // ★ 乘法必须寄存：组合乘法直接进 arm_target 会让 speed→mult 成为最差路径
    //   （实测 slack −1.57 ns，95 个违例端点全在这里）
    reg [15:0] rot_w;
    always @(posedge clk or negedge rst_n_i) begin
        if (!rst_n_i) rot_w <= 16'd0;
        else          rot_w <= speed * 16'd293;
    end

    wire signed [15:0] al_ref_q12, wref_q10;

    arm_target #(
        .TICK_HZ (ADS_SPS),
        .WAIT_MS (3_000),
        .ACC_INC (7),
        .VMAX_W  (26348)
    ) u_arm_tgt (
        .clk      (clk),
        .rst_n    (rst_n_i),
        .tick     (tick),
        .en       (bal_en),
        .rot_hold (rot_hold),
        .rot_w    (rot_w),
        .rot_dir  (rot_dir),
        .al       (al_raw),
        .al_base  (al_base),
        .al_ref   (al_ref_q12),
        .wref     (wref_q10),
        .jump     (arm_jump)
    );

    //=========================================================================
    // 角度旋转（固定角度平移：限速斜坡参考 + 到位吸附）
    //   角度(0.1°) → step_q12 = val × 1830 >> 8   （Q12 弧度，360° = 25734）
    //   正值 = 顺时针 → 参考角【减小】（与平衡绕圈方向对齐，按实测取反）
    //   ref_gen 以 2 LSB/拍（≈33.6°/s）限速逼近；到位后把 al_base 交给新位置
    //=========================================================================
    wire signed [23:0] ang_ext  = {{11{rot_ang_cmd[12]}}, rot_ang_cmd};
    wire signed [31:0] ang_prod = ang_ext * 32'sd1830;
    wire signed [15:0] step_q12 = ang_prod[23:8];

    reg  signed [15:0] ref_rot;                       // 累计后的目标角

    wire signed [16:0] ref_cand = {al_raw[15], al_raw} - {step_q12[15], step_q12};
    wire signed [16:0] ref_wr   = (ref_cand >=  PI_Q12)  ? (ref_cand - TWO_PI_Q12) :
                                  (ref_cand <  -PI_Q12)  ? (ref_cand + TWO_PI_Q12) : ref_cand;

    wire signed [15:0] al_ref_rot;

    // ★ step_active / step_arrived 必须在 ref_gen 例化【之前】声明：
    //   438 行的 .en(bal_en & step_active) 用到了它，先声明后使用
    reg  step_active;
    wire step_arrived = (al_ref_rot == ref_rot);
    wire step_done    = step_active & step_arrived;

    ref_gen #(.STEP_Q12(16'sd2)) u_ref_gen (
        .clk    (clk),
        .rst_n  (rst_n_i),
        .tick   (tick),
        .en     (bal_en & step_active),
        .al     (al_raw),
        .target (ref_rot),
        .al_ref (al_ref_rot)
    );


    always @(posedge clk or negedge rst_n_i) begin
        if (!rst_n_i)        ref_rot <= 16'sd0;
        else if (!bal_en)    ref_rot <= al_base;          // 未平衡：跟随基准
        else if (cmd_rot)    ref_rot <= ref_wr[15:0];     // 确认：累加一次增量
    end

    always @(posedge clk or negedge rst_n_i) begin
        if (!rst_n_i)                step_active <= 1'b0;
        else if (!bal_en)            step_active <= 1'b0;   // 未平衡时忽略命令
        else if (cmd_rot)            step_active <= 1'b1;
        else if (step_arrived)       step_active <= 1'b0;
    end

    // 到位：把基准点交还给新位置，并让 arm_target 内部目标直接对齐（无跳变）
    always @(posedge clk or negedge rst_n_i) begin
        if (!rst_n_i)        al_base <= 16'sd0;
        else if (zero_pulse) al_base <= al_raw;
        else if (step_done)  al_base <= ref_rot;
    end

    always @(posedge clk or negedge rst_n_i) begin
        if (!rst_n_i) arm_jump <= 1'b0;
        else          arm_jump <= step_done;
    end

    // 参考源选择（打一拍，纯寄存器进寄存器出，不碰 lqr 的组合链）
    reg signed [15:0] al_ref_used, wref_used;
    always @(posedge clk or negedge rst_n_i) begin
        if (!rst_n_i) begin
            al_ref_used <= 16'sd0;
            wref_used   <= 16'sd0;
        end else begin
            al_ref_used <= step_active ? al_ref_rot : al_ref_q12;
            wref_used   <= step_active ? 16'sd0    : wref_q10;   // 旋转过程中按无速度前馈处理
        end
    end

    wire signed [15:0] u_lqr, u_swing;

    lqr_controller #(
        .U_LIMIT    (U_LIMIT),
        .U_LP_SHIFT (3)
    ) u_lqr_ctrl (
        .clk        (clk),
        .rst_n      (rst_n_i),
        .tick       (tick),
        .en         (bal_en),
        .C1         (p_c1),
        .C2         (p_c2),
        .C3         (p_c3),
        .C4         (p_c4),
        .al_ref_in  (al_ref_used),
        .wref       (wref_used),
        .al         (al_raw),
        .ald        (ald_raw),
        .th         (th),
        .thd        (thd),
        .u_duty     (u_lqr)
    );

    swing_ctrl #(
        .U_LIMIT (U_LIMIT)
    ) u_swing_ctrl (
        .clk      (clk),
        .rst_n    (rst_n_i),
        .tick     (tick),
        .en       (sw_en),
        .th_catch (p_th_catch),
        .th       (th),
        .thd      (thd),
        .al       (al_raw),
        .u_duty   (u_swing),
        .ready    (sw_ready)
    );

    wire signed [15:0] u_cmd = bal_en ? u_lqr : (sw_en ? u_swing : 16'sd0);
    // 只在平衡/起摆时驱动电机；断电与故障都封锁驱动器
    wire               motor_en = bal_en | sw_en;

    tb6612_driver #(
        .CLK_FREQ (CLK_FREQ),
        .PWM_HZ   (PWM_HZ),
        .CMD_FULL (2500)
    ) u_drv (
        .clk   (clk),
        .rst_n (rst_n_i),
        .u_cmd (u_cmd),
        .en    (motor_en),
        .pwm   (pwm_out),
        .in1   (in1_out),
        .in2   (in2_out)
    );

    //=========================================================================
    // 遥测：示波帧 AA55 + 参数帧 A5 5A（分时共用 TX）
    //=========================================================================
    reg zero_latched;
    always @(posedge clk or negedge rst_n_i) begin
        if (!rst_n_i)          zero_latched <= 1'b0;
        else if (zero_pulse)   zero_latched <= 1'b1;
    end

    // bit0 平衡中 / bit1 起摆中 / bit2 故障 / bit3 已 ZERO
    wire [7:0] tx_status = {4'b0000, zero_latched,
                            (mode == 2'd2), sw_en, bal_en};

    wire        s_txd, s_busy, p_txd, p_active, p_hold;

    uart_frame #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_frame (
        .clk    (clk),
        .rst_n  (rst_n_i),
        .th     (th),
        .thd    (thd),
        .al     (al_disp),      // 与显示一致：定点后从 0 起算
        .ald    (ald_raw),
        .u_duty (u_cmd),
        .status (tx_status),
        .hold   (p_hold),
        .div_n  (p_scope_div),
        .busy   (s_busy),
        .txd    (s_txd)
    );

    param_link #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_param (
        .clk        (clk),
        .rst_n      (rst_n_i),
        .rx         (uart_rx),
        .page       (page),
        .scope_busy (s_busy),
        .txd        (p_txd),
        .tx_active  (p_active),
        .hold       (p_hold),
        .p_scope_div(p_scope_div),
        .pr_idx     (pr_idx),
        .pr_val     (pr_val),
        .pr_bcd     (pr_bcd),
        .pr_neg     (pr_neg),
        .o_c1       (p_c1),
        .o_c2       (p_c2),
        .o_c3       (p_c3),
        .o_c4       (p_c4),
        .o_th_catch (p_th_catch)
    );

    assign uart_tx = p_active ? p_txd : s_txd;

    //=========================================================================
    // 渲染
    //=========================================================================
    reg  pending;
    reg  [25:0] refresh_cnt;

    localparam integer REFRESH_MS  = 150;
    localparam integer REFRESH_CYC = (CLK_FREQ / 1000) * REFRESH_MS;

    wire mf_busy, mf_done;
    wire mf_start = init_done && pending && !mf_busy;
    wire m_sclk, m_mosi, m_cs_n, m_dc;

    wire curve_page = (page == 4'd8);

    always @(posedge clk or negedge rst_n_i) begin
        if (!rst_n_i) begin
            pending     <= 1'b1;
            refresh_cnt <= 26'd0;
        end else begin
            if (ui_dirty)       pending <= 1'b1;
            else if (mf_start)  pending <= 1'b0;

            if (curve_page && init_done) begin
                if (refresh_cnt == REFRESH_CYC - 1) begin
                    refresh_cnt <= 26'd0;
                    pending     <= 1'b1;
                end else begin
                    refresh_cnt <= refresh_cnt + 1'b1;
                end
            end else begin
                refresh_cnt <= 26'd0;
            end
        end
    end

    menu_frame u_mf (
        .clk (clk), .rst_n (rst_n_i),
        .start (mf_start),
        .page (page), .cursor (cursor), .pstart (pstart),
        .pr_val (pr_val), .pr_idx (pr_idx),
        .pr_bcd (pr_bcd), .pr_neg (pr_neg),
        .edit (edit), .dir_state (dir_state), .armed (armed),
        .val_c1 (val_c1), .val_c2 (val_c2), .val_c3 (val_c3), .val_c4 (val_c4),
        .val_c5 (val_c5), .val_c6 (val_c6), .val_c7 (val_c7), .val_c8 (val_c8),
        .speed (speed), .val_ang (val_ang),
        .mon0 (v_th), .mon1 (v_thd), .mon2 (v_al), .mon3 (v_ald),
        .smp_stb (smp_stb),
        .smp0 (n_th), .smp1 (n_thd), .smp2 (n_al), .smp3 (n_ald),
        .busy (mf_busy), .done (mf_done),
        .sclk (m_sclk), .mosi (m_mosi), .cs_n (m_cs_n), .dc (m_dc)
    );

    assign lcd_sclk      = init_done ? m_sclk : i_sclk;
    assign lcd_mosi      = init_done ? m_mosi : i_mosi;
    assign lcd_cs_n      = init_done ? m_cs_n : i_cs_n;
    assign lcd_dc        = init_done ? m_dc   : i_dc;
    assign lcd_backlight = init_done;

endmodule