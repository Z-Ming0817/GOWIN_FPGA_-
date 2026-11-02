import io, shutil, os

T = r'E:\FPGA_project\total_project'

# ===================== 0. 引入 ref_gen.v =====================
src = r'E:\FPGA_project\Translate_by_fixed_point\src\ref_gen.v'
dst = os.path.join(T, 'src', 'ref_gen.v')
shutil.copyfile(src, dst)
print('ref_gen.v 已复制')

# 加进 gprj（放在 arm_target 之后）
p = os.path.join(T, 'total_project.gprj')
s = io.open(p, encoding='utf-8').read()
if 'ref_gen.v' not in s:
    s = s.replace('<File path="src/tb6612_driver.v"',
                  '<File path="src/ref_gen.v" type="file.verilog" enable="1"/>\n        <File path="src/tb6612_driver.v"')
    io.open(p, 'w', encoding='utf-8').write(s)
    print('gprj +ref_gen.v')

# ===================== 1. arm_target：加 jump 输入 =====================
p = os.path.join(T, 'src', 'arm_target.v')
s = io.open(p, encoding='utf-8').read()
if 'jump' not in s:
    s = s.replace("    input  wire               rot_dir,       // 1 = 顺时针方向，0 = 逆时针方向",
                  "    input  wire               rot_dir,       // 1 = 顺时针方向，0 = 逆时针方向\n"
                  "    input  wire               jump,          // 1 = 把内部目标直接拉到 al_base（角度旋转交还时用）")
    s = s.replace("""        end else if (!en) begin
            // 非闭环：目标跟随、速率清零，保证进平衡瞬间误差为 0（无扰接合）
            st       <= S_IDLE;""",
"""        end else if (jump) begin
            // 外部要求把目标直接拉到基准（角度旋转到位后交还，臂已在那里，无跳变）
            tgt      <= base_q25;
            w        <= 32'sd0;
            st       <= S_HOLD;
        end else if (!en) begin
            // 非闭环：目标跟随、速率清零，保证进平衡瞬间误差为 0（无扰接合）
            st       <= S_IDLE;""")
    io.open(p, 'w', encoding='utf-8').write(s)
    print('arm_target: +jump')

# ===================== 2. ui_core：cmd_rot + 角度快照 =====================
p = os.path.join(T, 'src', 'ui_core.v')
s = io.open(p, encoding='utf-8').read()
if 'cmd_rot' not in s:
    s = s.replace("    output reg         param_lock,   // 参数页断电锁：1 = 已断电、SW1 不能退出",
"""    output reg         param_lock,   // 参数页断电锁：1 = 已断电、SW1 不能退出
    output reg  signed [12:0] rot_ang_cmd,   // 角度旋转：确认瞬间的角度快照（0.1°）
    output reg         cmd_rot,       // 角度旋转：单拍命令脉冲""")

    s = s.replace("""            cmd_zero <= 1'b0;
            cmd_on   <= 1'b0;
            cmd_off  <= 1'b0;
            param_lock <= 1'b0;""",
"""            cmd_zero <= 1'b0;
            cmd_on   <= 1'b0;
            cmd_off  <= 1'b0;
            cmd_rot  <= 1'b0;
            rot_ang_cmd <= 13'sd0;
            param_lock <= 1'b0;""")

    s = s.replace("""            cmd_zero <= 1'b0;
            cmd_on   <= 1'b0;
            cmd_off  <= 1'b0;

""",
"""            cmd_zero <= 1'b0;
            cmd_on   <= 1'b0;
            cmd_off  <= 1'b0;
            cmd_rot  <= 1'b0;

""")

    s = s.replace("""                end else if (row_kind(page, cursor) == 2'd1) begin
                    if (page == P_ROT)       val_ang <= 13'sd0;     // 角度自动归零""",
"""                end else if (row_kind(page, cursor) == 2'd1) begin
                    if (page == P_ROT) begin
                        cmd_rot     <= 1'b1;        // 发一次角度旋转命令
                        rot_ang_cmd <= val_ang;     // 快照角度
                        val_ang     <= 13'sd0;      // 角度清零
                    end""")
    io.open(p, 'w', encoding='utf-8').write(s)
    print('ui_core: +cmd_rot/rot_ang_cmd')

print('--- 校验关键行 ---')
for f, keys in [('arm_target.v', ['jump']), ('ui_core.v', ['cmd_rot', 'rot_ang_cmd'])]:
    s = io.open(os.path.join(T, 'src', f), encoding='utf-8').read()
    for k in keys:
        print('  %-14s %-12s %d 次' % (f, k, s.count(k)))