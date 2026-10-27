# Gera a lista de TMs/HMs da 1ª geração e quais Pokémon aprendem cada uma (para o sql/47).
# Fontes: pret/pokered (1 a 151: lista das TMs, preços e "tmhm" de cada espécie) e pret/pokecrystal
# (152 a 251: só as TMs/HMs da Red/Blue que a espécie aprende na Crystal). Só números e nomes.
# Uso: python ferramentas/gerar_tm_compat.py <pasta pokered-master> <pasta pokecrystal-master> <saída.sql>
import re, sys, os, glob

RED, CRY, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
rd = lambda base, p: open(os.path.join(base, p), encoding="utf-8").read()

def consts(path):
    out, n = {}, 0
    for line in rd(RED, path).splitlines():
        m = re.match(r"\s*const_def\s*(\d+)?", line)
        if m: n = int(m.group(1) or 0); continue
        m = re.match(r"\s*const\s+(\w+)", line)
        if m: out[m.group(1)] = n; n += 1
    return out

MOVE_ID = consts("constants/move_constants.asm")
DEX = {k[4:]: v for k, v in consts("constants/pokedex_constants.asm").items() if k.startswith("DEX_")}
itc = rd(RED, "constants/item_constants.asm")
HMS = re.findall(r"^\s*add_hm\s+(\w+)", itc, re.M)
TMS = re.findall(r"^\s*add_tm\s+(\w+)", itc, re.M)
assert len(HMS) == 5 and len(TMS) == 50, (len(HMS), len(TMS))
prices = [int(x) for x in re.findall(r"nybble (\d+) ; TM\d+", rd(RED, "data/items/tm_prices.asm"))]
assert len(prices) == 50
ALL = set(HMS) | set(TMS)

def tmhm(text):
    m = re.search(r"tmhm (.*?)\n\s*; end", text, re.S)
    return [x for x in re.split(r"[\s,\\]+", m.group(1)) if x] if m else []

compat = []
for f in sorted(glob.glob(os.path.join(RED, "data/pokemon/base_stats/*.asm"))):
    t = open(f, encoding="utf-8").read()
    dex = DEX[re.search(r"db DEX_(\w+)", t).group(1)]
    for mv in tmhm(t):
        if mv in ALL: compat.append((dex, MOVE_ID[mv]))
for f in sorted(glob.glob(os.path.join(CRY, "data/pokemon/base_stats/*.asm"))):
    t = open(f, encoding="utf-8").read()
    m = re.search(r"db \w+ ; (\d+)", t)
    if not m or not (152 <= int(m.group(1)) <= 251): continue
    for mv in tmhm(t):
        if mv in ALL: compat.append((int(m.group(1)), MOVE_ID[mv]))
compat = sorted(set(compat))

with open(OUT, "w", encoding="utf-8", newline="\n") as o:
    o.write("-- gerado por ferramentas/gerar_tm_compat.py (pret/pokered + pret/pokecrystal; só números e nomes)\n")
    o.write("-- tm: (número, ataque, preço na Red/Blue em milhares) | hm: (número, ataque)\n")
    o.write("insert into public.pk_tm_list (item, num, hm, move_id, price_rb) values\n")
    rows = [f"('tm{i + 1:02d}',{i + 1},false,{MOVE_ID[m]},{prices[i] * 1000})" for i, m in enumerate(TMS)]
    rows += [f"('hm{i + 1:02d}',{i + 1},true,{MOVE_ID[m]},0)" for i, m in enumerate(HMS)]
    o.write(",\n".join(rows) + "\non conflict (item) do update set num = excluded.num, hm = excluded.hm, move_id = excluded.move_id, price_rb = excluded.price_rb;\n")
    o.write("insert into public.pk_tm_compat (species_id, move_id) values\n")
    o.write(",\n".join(",".join(f"({a},{b})" for a, b in compat[i:i + 20]) for i in range(0, len(compat), 20)))
    o.write("\non conflict do nothing;\n")
print(len(compat), "pares espécie/ataque;", sum(1 for a, _ in compat if a > 151), "da 2ª geração")
