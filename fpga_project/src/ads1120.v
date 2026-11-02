//=============================================================================
// ads1120.v  —  ADS1120 16bit ΔΣ ADC 的 SPI 主机驱动
//
// 协议：SPI 模式 1（CPOL=0, CPHA=1）
//   · SCLK 空闲低；上升沿从机移出 DOUT，下降沿从机锁存 DIN
//   · 主机：下降沿采样 MISO；MOSI 在下降沿后 1 拍更新，
//     从机在下一个下降沿锁存 DIN，建立/保持余量各约半个 SCLK 周期
//   · 约束：SCLK_HALF >= 2（=1 时 MOSI 与下降沿同刻变化，建立时间为 0）
//   · CS 低有效，一条完整命令（命令字节 + 数据）在同一个 CS 低电平内完成
//
// 初始化序列（上电后自动执行）：
//   RESET 0x06 → WREG 0x43 + {0x81,0xD4,0xC0,0x00} → START/SYNC 0x08
//     Reg0=0x81  AIN0 单端对 AVSS，GAIN=1，PGA 旁路
//     Reg1=0xD4  Turbo 2000SPS，连续转换（CM=1）
//                = 110 10 1 00 : DR=110(Turbo 2000SPS) MODE=10(Turbo) CM=1
//                旧值 0xB4 = 101 10 1 00 → Turbo 1200SPS（2026-10-28 22:xx 改）
//     Reg2=0xC0  VREF=AVDD 比例式
//     Reg3=0x00  IDAC 关闭，DRDY 独立
//
// 读取策略：**DRDY 触发**。DRDY 每次下降沿（新样本就绪）发一次 RDATA 0x10。
//   · 采样网格由 ADC 自己决定（2000SPS = 500us），Δt 恒定
//   · 旧做法"每 1ms 无条件读"与 833us 转换周期不同源，两者以约 10Hz 慢拍漂移，
//     等效 Δt 抖动 ±21%，直接污染 θ̇ —— 这是本次改动的主因
//   · 兜底：若 2×SAMPLE_DIV 内没有 DRDY，仍强读一次，保证 valid 不断流
//     （顶层 tick 由 valid 驱动，断流会让控制环停在最后一个 u 上）
// 看门狗：START 之后若 WD_DIV（默认 100ms）内没有 DRDY 下降沿 → adc_err=1
//           并自动重新初始化；收到新的 DRDY 后 adc_err 清零。
//=============================================================================
`timescale 1ns/1ps

module ads1120 #(
    parameter CLK_FREQ   = 50_000_000,
    parameter SCLK_HALF  = 10,           // 半个 SCLK 周期的时钟数 -> 2.5MHz
    parameter SAMPLE_DIV = 50_000,       // 兜底读取周期 / MUX 稳定基准（1ms）
    parameter WD_DIV     = 5_000_000,    // DRDY 看门狗 100ms
    parameter INIT_DLY   = 50_000,       // 上电/RESET 等待 1ms
    parameter GAP_CYC    = CLK_FREQ / 250_000   // START 后静默 4us，让 DRDY 起跳
)(
    input  wire        clk,
    input  wire        rst_n,

    output reg         sclk,
    output reg         cs_n,
    output reg         mosi,
    input  wire        miso,
    input  wire        drdy_n,
    input  wire [3:0]  mux_sel,      // 运行期通道选择：1000~1011=AIN0~AIN3 单端，
                                     // 1101=(AVDD-AVSS)/4 内部监测，1110=输入端短接到中点
                                     // 变化时驱动内部自动重写 Reg0 并等待 2 个转换周期

    output reg  [15:0] data,
    output reg         valid,        // 一次 RDATA 完成，data 有效（1 周期脉冲）
    output reg         adc_fresh,    // DRDY 下降沿（数据新鲜度标记）
    output reg         adc_err       // 看门狗超时：ADC 失联
);

    //=====================================================================
    // 1. SPI 传输引擎
    //=====================================================================
    localparam [1:0] E_IDLE = 2'd0,
                     E_HI   = 2'd1,
                     E_LO   = 2'd2,
                     E_END  = 2'd3;

    reg [1:0]  est;
    reg [39:0] pat;             // 待发送码型（左对齐，MSB 在 bit39）
    reg [5:0]  xfer_len;
    reg [5:0]  cap_start;
    reg        cap_en;
    reg        xfer_go;

    reg [39:0] tx_sr;
    reg [15:0] rx_sr;
    reg [5:0]  bit_len;
    reg [5:0]  bit_idx;
    reg [5:0]  cap_idx;      // 采样起始位序号
    reg [5:0]  cap_cnt;      // 已采样位数（上限 16）
    reg        cap_on;
    reg [15:0] hcnt;

    wire       xfer_done;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            est       <= E_IDLE;
            sclk      <= 1'b0;
            cs_n      <= 1'b1;
            mosi      <= 1'b0;
            tx_sr     <= 40'd0;
            rx_sr     <= 16'd0;
            bit_len   <= 6'd0;
            bit_idx   <= 6'd0;
            cap_idx   <= 6'd0;
            cap_cnt   <= 6'd0;
            cap_on    <= 1'b0;
            hcnt      <= 16'd0;
            data      <= 16'd0;
            valid     <= 1'b0;
        end else begin
            valid <= 1'b0;

            case (est)
                E_IDLE: begin
                    sclk <= 1'b0;
                    cs_n <= 1'b1;
                    hcnt <= 16'd0;
                    if (xfer_go) begin
                        tx_sr   <= pat;
                        bit_len <= xfer_len;
                        bit_idx <= 6'd0;
                        cap_idx <= cap_start;
                        cap_cnt <= 6'd0;
                        cap_on  <= cap_en;
                        rx_sr   <= 16'd0;
                        mosi    <= pat[39];
                        cs_n    <= 1'b0;
                        est     <= E_HI;
                    end
                end

                E_HI: begin                     // SCLK 上升沿（从机移出 DOUT）
                    sclk <= 1'b1;
                    if (hcnt == SCLK_HALF - 1) begin
                        hcnt <= 16'd0;
                        est  <= E_LO;
                    end else begin
                        hcnt <= hcnt + 1'b1;
                    end
                end

                E_LO: begin                     // SCLK 下降沿（从机锁存 DIN，主机采样）
                    sclk <= 1'b0;
                    // 关键：每个 bit 只在进入 E_LO 的第一拍采样一次
                    // （用 hcnt==0 门控；否则 E_LO 持续 SCLK_HALF 拍，同一位会被采样多次）
                    if (cap_on && (hcnt == 16'd0) &&
                        (bit_idx >= cap_idx) && (cap_cnt < 6'd16)) begin
                        rx_sr   <= {rx_sr[14:0], miso};
                        cap_cnt <= cap_cnt + 1'b1;
                    end

                    if (hcnt == SCLK_HALF - 1) begin
                        hcnt  <= 16'd0;
                        tx_sr <= {tx_sr[38:0], 1'b0};
                        if (bit_idx == bit_len - 1) begin
                            est <= E_END;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                            mosi    <= tx_sr[38];
                            est     <= E_HI;
                        end
                    end else begin
                        hcnt <= hcnt + 1'b1;
                    end
                end

                E_END: begin
                    sclk  <= 1'b0;
                    cs_n  <= 1'b1;
                    est   <= E_IDLE;
                    if (cap_on) begin
                        data  <= rx_sr;
                        valid <= 1'b1;
                    end
                end

                default: est <= E_IDLE;
            endcase
        end
    end

    assign xfer_done = (est == E_END);

    //=====================================================================
    // 2. DRDY 同步与下降沿检测
    //=====================================================================
    reg [2:0] ds;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ds <= 3'b111;
        else        ds <= {ds[1:0], drdy_n};
    end

    // ds[2] 为最老的采样：高→低 才是 DRDY 下降沿（数据就绪）
    wire drdy_fall = ds[2] & ~ds[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) adc_fresh <= 1'b0;
        else        adc_fresh <= drdy_fall;
    end

    //=====================================================================
    // 3. 命令序列状态机
    //=====================================================================
    localparam [3:0] Q_PWR   = 4'd0,
                     Q_RESET = 4'd1,
                     Q_RESW  = 4'd2,
                     Q_CFG   = 4'd3,
                     Q_START = 4'd4,
                     Q_GAP   = 4'd5,
                     Q_POLL  = 4'd6,
                     Q_RDATA = 4'd7,
                     Q_MUX   = 4'd8;      // 运行期改通道：只重写 Reg0

    reg [3:0]  qst;
    reg [31:0] timer;
    reg [31:0] wd_cnt;
    reg        wd_on;
    reg [3:0]  mux_cur;              // 芯片里当前生效的 MUX 编码

    // DRDY 待读标志：每次 DRDY 下降沿置位，发起 RDATA 时清除。
    // 用它代替"每 1ms 无条件读"：采样网格由 ADC 决定，θ̇ 的 Δt 恒定。
    reg        drdy_pend;

    // 兜底计数：DRDY 迟迟不来时强读一次，保证 valid 不断流
    localparam integer FB_DIV = SAMPLE_DIV * 2;      // 2ms
    reg [31:0] poll_cnt;

    wire [31:0] timer_done = (timer == 32'd0);
    wire        wd_fire    = wd_on && (wd_cnt >= WD_DIV - 1);
    wire        fb_fire    = (poll_cnt >= FB_DIV - 1);

    // 两个"发起动作"的判定提到 case 之前，供 drdy_pend / poll_cnt 统一处理
    wire mux_go  = (qst == Q_POLL) && !wd_fire && (mux_sel != mux_cur);
    wire read_go = (qst == Q_POLL) && !wd_fire && !mux_go &&
                   timer_done && (drdy_pend || fb_fire);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            qst      <= Q_PWR;
            timer    <= INIT_DLY;
            wd_cnt   <= 32'd0;
            wd_on    <= 1'b0;
            adc_err  <= 1'b0;
            pat      <= 40'd0;
            xfer_len <= 6'd0;
            cap_start<= 6'd0;
            cap_en   <= 1'b0;
            xfer_go  <= 1'b0;
            mux_cur  <= 4'd0;
            drdy_pend <= 1'b0;
            poll_cnt  <= 32'd0;
        end else begin
            xfer_go <= 1'b0;

            // 通用定时器
            if (timer != 32'd0) timer <= timer - 1'b1;

            // DRDY 待读标志：初始化/故障期间不累积；发起读或换通道时清除
            if (!wd_on)                    drdy_pend <= 1'b0;
            else if (read_go || mux_go)    drdy_pend <= 1'b0;
            else if (drdy_fall)            drdy_pend <= 1'b1;

            // 兜底计数：只在 Q_POLL 等 DRDY 期间增长，发起动作时清零
            if ((qst != Q_POLL) || read_go || mux_go)
                poll_cnt <= 32'd0;
            else if (!fb_fire)
                poll_cnt <= poll_cnt + 1'b1;

            // DRDY 看门狗：计数到 WD_DIV-1 后保持饱和（不清零），
            // 保证 wd_fire 一定能被 Q_POLL 采到，不会被状态机错过一拍
            if (!wd_on) begin
                wd_cnt <= 32'd0;
            end else if (drdy_fall) begin
                wd_cnt <= 32'd0;
                if (adc_err) adc_err <= 1'b0;      // 重新收到 DRDY，解除封锁
            end else if (wd_cnt < WD_DIV - 1) begin
                wd_cnt <= wd_cnt + 1'b1;
            end

            case (qst)
                Q_PWR: begin
                    if (timer_done) begin
                        pat       <= 40'h06_0000_0000;   // RESET
                        xfer_len  <= 6'd8;
                        cap_en    <= 1'b0;
                        cap_start <= 6'd0;
                        xfer_go   <= 1'b1;
                        qst       <= Q_RESET;
                    end
                end

                Q_RESET: begin
                    if (xfer_done) begin
                        timer <= INIT_DLY;
                        qst   <= Q_RESW;
                    end
                end

                Q_RESW: begin
                    if (timer_done) begin
                        // WREG reg0..3，一次写 4 字节
                        // Reg0 = {MUX[3:0], GAIN=000, PGA_BYPASS=1}，MUX 取自 mux_sel
                        // Reg1 = 0xD4：DR=110 + MODE=10(Turbo) + CM=1 → 2000 SPS
                        pat       <= {8'h43, mux_sel, 4'h1, 8'hD4, 8'hC0, 8'h00};
                        xfer_len  <= 6'd40;
                        cap_en    <= 1'b0;
                        cap_start <= 6'd0;
                        xfer_go   <= 1'b1;
                        qst       <= Q_CFG;
                    end
                end

                Q_CFG: begin
                    if (xfer_done) begin
                        pat       <= 40'h08_0000_0000;   // START/SYNC
                        xfer_len  <= 6'd8;
                        cap_en    <= 1'b0;
                        cap_start <= 6'd0;
                        xfer_go   <= 1'b1;
                        qst       <= Q_START;
                    end
                end

                Q_START: begin
                    if (xfer_done) begin
                        timer <= GAP_CYC;                // START 后静默，等 DRDY 起跳
                        qst   <= Q_GAP;
                    end
                end

                Q_GAP: begin
                    if (timer_done) begin
                        wd_on     <= 1'b1;               // 开始监视 DRDY
                        wd_cnt    <= 32'd0;
                        mux_cur   <= mux_sel;            // 初始化已写入该 MUX
                        timer     <= 32'd0;              // 不做定时等待，直接等第一个 DRDY
                        qst       <= Q_POLL;
                    end
                end

                Q_POLL: begin
                    if (wd_fire) begin
                        adc_err  <= 1'b1;                // ADC 失联：封锁 + 重初始化
                        wd_on    <= 1'b0;
                        timer    <= INIT_DLY;
                        qst      <= Q_PWR;
                    end else if (mux_go) begin
                        // 通道切换：只重写 Reg0（WREG rr=00 nn=00 -> 0x40 + 1 字节）
                        pat       <= {8'h40, mux_sel, 4'h1, 24'h0};
                        xfer_len  <= 6'd16;
                        cap_en    <= 1'b0;
                        cap_start <= 6'd0;
                        xfer_go   <= 1'b1;
                        qst       <= Q_MUX;
                    end else if (read_go) begin
                        // DRDY 已就绪（或兜底超时）：读一次
                        pat       <= 40'h10_0000_0000;   // RDATA
                        xfer_len  <= 6'd24;
                        cap_en    <= 1'b1;
                        cap_start <= 6'd8;               // 命令字节之后开始采样
                        xfer_go   <= 1'b1;
                        qst       <= Q_RDATA;
                    end
                end

                Q_MUX: begin
                    if (xfer_done) begin
                        mux_cur <= mux_sel;
                        timer   <= SAMPLE_DIV * 2;       // 等 2 个转换周期，让新通道稳定
                        qst     <= Q_POLL;
                    end
                end

                Q_RDATA: begin
                    if (xfer_done) begin
                        timer <= 32'd0;                  // 回到 Q_POLL 继续等下一个 DRDY
                        qst   <= Q_POLL;
                    end
                end

                default: qst <= Q_PWR;
            endcase
        end
    end

endmodule
