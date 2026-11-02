import io

p = r'E:\FPGA_project\total_project\src\total_top.v'
s = io.open(p, encoding='utf-8').read()
orig = s

# ---------------- 1. 提前声明（供后面 always / 例化使用）----------------
s = s.replace("    wire        cmd_zero, cmd_on, cmd_off, param_lock, ui_dirty;",
"""    wire        cmd_zero, cmd_on, cmd_off, param_lock, ui_dirty;
    wire        cmd_rot;                     // 角度旋转：单拍命令
    wire signed [12:0] rot_ang_cmd;          // 角度旋转：角度快照（0.1°）
    reg         arm_jump;                    // 交还时把 arm_target 内部目标拉到基准""")

# ---------------- 2. al_base 只保留声明（赋值挪到后面，需要 step_done）----------------
old_base = """    reg signed [15:0] al_base;
    always @(posedge clk or negedge rst_n_i) begin
        if (!rst_n_i)        al_base <= 16'sd0;
        else if (zero_pulse) al_base <= al_raw;
    end
"""
new_base = """    reg signed [15:0] al_base;   // 赋值在后面（还要接受“角度旋转到位”更新）
"""
assert old_base in s
s = s.replace(old_base, new_base, 1)

# ---------------- 3. ui_core 例化加两个口 ----------------
s = s.replace("        .param_lock (param_lock), .dirty (ui_dirty)",
              "        .param_lock (param_lock),\n        .rot_ang_cmd (rot_ang_cmd), .cmd_rot (cmd_rot),\n        .dirty (ui_dirty)")

# ---------------- 4. arm_target 接 jump，并在其后插入角度旋转逻辑 ----------------
old_arm = """        .al_ref   (al_ref_q12),
        .wref     (wref_q10)
    );"""
new_arm = """        .al_ref   (al_ref_q12),
        .wref     (wref_q10),
        .jump     (arm_jump)
    );

    //=========================================================================
    // 角度旋转（逻辑同 Translate_by_fixed_point 的固定角度平移）
    //   角度(0.1°) → step_q12 = val × 1830 >> 8   （Q12 弧度，360° = 25734）
    //   正值 = 顺时针 → 参考角【减小】（与平衡绕圈方向对齐，按实测取反）
    //   ref_gen 以 2 LSB/拍（≈33.6°/s）限速逼近；到位后把 al_base 交给新位置
    //=========================================================================
    wire signed [23:0] ang_ext  = {{11{rot_ang_cmd[12]}}, rot_ang_cmd};
    wire signed [31:0] ang_prod = ang_ext * 32'sd1830;
    wire signed [15:0] step_q12 = ang_prod[23:8];

    reg  signed [15:0] ref_rot;                       // 累计后的目标角

    wire signed [16:0] ref_cand = {ref_rot[15], ref_rot} - {step_q12[15], step_q12};
    wire signed [16:0] ref_wr   = (ref_cand >=  PI_Q12)  ? (ref_cand - TWO_PI_Q12) :
                                  (ref_cand <  -PI_Q12)  ? (ref_cand + TWO_PI_Q12) : ref_cand;

    wire signed [15:0] al_ref_rot;

    ref_gen #(.STEP_Q12(16'sd2)) u_ref_gen (
        .clk    (clk),
        .rst_n  (rst_n_i),
        .tick   (tick),
        .en     (bal_en),
        .al     (al_raw),
        .target (ref_rot),
        .al_ref (al_ref_rot)
    );

    wire step_arrived = (al_ref_rot == ref_rot);
    reg  step_active;
    wire step_done    = step_active & step_arrived;

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
            wref_used   <= step_active ? 16'sd0    : wref_q10;   // Translate 的 lqr 无前馈
        end
    end"""
assert old_arm in s
s = s.replace(old_arm, new_arm, 1)

# ---------------- 5. lqr 改用选择后的参考 ----------------
s = s.replace("        .al_ref_in  (al_ref_q12),\n        .wref       (wref_q10),",
              "        .al_ref_in  (al_ref_used),\n        .wref       (wref_used),")

io.open(p, 'w', encoding='utf-8').write(s)
print('changed =', s != orig)

# ---------------- 顺序自检 ----------------
lines = s.split('\n')
def first(pat):
    for i, l in enumerate(lines, 1):
        if pat in l:
            return i
    return -1
checks = [
    ('rot_ang_cmd 声明', 'wire signed [12:0] rot_ang_cmd;'),
    ('cmd_rot 声明', 'wire        cmd_rot;'),
    ('arm_jump 声明', 'reg         arm_jump;'),
    ('al_base 声明', 'reg signed [15:0] al_base;'),
    ('jump 连接', '.jump     (arm_jump)'),
    ('al_ref_used 例化', '.al_ref_in  (al_ref_used)'),
]
for name, pat in checks:
    print('  %-16s 行 %d' % (name, first(pat)))
print('al_ref_used 声明行:', first('reg signed [15:0] al_ref_used'))
print('PI_Q12 声明行:', first("localparam signed [16:0] PI_Q12"))