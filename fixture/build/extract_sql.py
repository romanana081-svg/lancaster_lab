import json, re, pathlib
nb = json.load(open('LDLR Get phenotypes.ipynb', encoding='utf-8'))
out = pathlib.Path('fixture/build/queries'); out.mkdir(exist_ok=True)
pat = re.compile(r'(\w+_sql)\s*<-\s*paste\("(.*?)",\s*sep\s*=\s*""\)', re.S)
found = []
for i, c in enumerate(nb['cells']):
    if c['cell_type'] != 'code': continue
    src = ''.join(c['source'])
    for name, sql in pat.findall(src):
        sql = sql.replace('\\"', '"')
        (out / f'{name}.sql').write_text(sql, encoding='utf-8')
        found.append((i, name, len(sql)))
for f in found: print(f)
