import io
p = r'total_project.gprj'
s = io.open(p, encoding='utf-8').read()
# 移到 FileList 内部（与 expand 一致）
s = s.replace("""    </FileList>
    <Constraints>
        <File path="constr/total_project.cst" type="file.cst" enable="1"/>
        <File path="constr/total_project.sdc" type="file.sdc" enable="1"/>
    </Constraints>""",
"""        <File path="constr/total_project.cst" type="file.cst" enable="1"/>
        <File path="constr/total_project.sdc" type="file.sdc" enable="1"/>
    </FileList>""")
io.open(p, 'w', encoding='utf-8').write(s)
print('gprj 约束位置已修正')
print(io.open(p, encoding='utf-8').read()[-260:])
