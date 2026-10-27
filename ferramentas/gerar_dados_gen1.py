# Gera sql/16_pokemon_gen1.sql com os dados de batalha da 1ª geração (Pokémon Red/Blue).
# Fonte: projeto pret/pokered (https://github.com/pret/pokered), reconstrução pública dos jogos.
# Usamos SOMENTE números e nomes (status-base, tipos, taxa de captura, experiência-base,
# curva de crescimento, evoluções, ataques por nível, ataques e tabela de tipos).
# Nenhum código, imagem ou som é copiado.
# Uso: python ferramentas/gerar_dados_gen1.py <pasta pokered-master> sql/16_pokemon_gen1.sql
import re, sys, os, glob

SRC, OUT = sys.argv[1], sys.argv[2]
rd = lambda p: open(os.path.join(SRC, p), encoding="utf-8").read()

def consts(path, start=0):
    out, n = {}, start
    for line in rd(path).splitlines():
        m = re.match(r"\s*const_def\s*(\d+)?", line)
        if m: n = int(m.group(1) or 0); continue
        m = re.match(r"\s*const\s+(\w+)", line)
        if m: out[m.group(1)] = n; n += 1
    return out

DEX = {k[4:]: v for k, v in consts("constants/pokedex_constants.asm").items() if k.startswith("DEX_")}
MOVE_ID = consts("constants/move_constants.asm")
INTERNAL = consts("constants/pokemon_constants.asm")
TYPES = {"NORMAL": "NORMAL", "FIGHTING": "LUTA", "FLYING": "VOADOR", "POISON": "VENENO", "GROUND": "TERRA", "ROCK": "PEDRA", "BUG": "INSETO",
         "GHOST": "FANTASMA", "FIRE": "FOGO", "WATER": "AGUA", "GRASS": "PLANTA", "ELECTRIC": "ELETRICO", "PSYCHIC_TYPE": "PSIQUICO", "ICE": "GELO", "DRAGON": "DRAGAO"}
GROWTH = {"GROWTH_MEDIUM_FAST": "medio_rapido", "GROWTH_SLIGHTLY_FAST": "pouco_rapido", "GROWTH_SLIGHTLY_SLOW": "pouco_lento",
          "GROWTH_MEDIUM_SLOW": "medio_lento", "GROWTH_FAST": "rapido", "GROWTH_SLOW": "lento"}
STONES = {"FIRE_STONE": "pedra_fogo", "THUNDER_STONE": "pedra_trovao", "WATER_STONE": "pedra_agua", "LEAF_STONE": "pedra_folha", "MOON_STONE": "pedra_lua"}

# --- espécies (status-base) ---
species = {}
for f in sorted(glob.glob(os.path.join(SRC, "data/pokemon/base_stats/*.asm"))):
    t = open(f, encoding="utf-8").read()
    dex = DEX[re.search(r"db DEX_(\w+)", t).group(1)]
    hp, atk, de, spd, spc = map(int, re.search(r"db\s+(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+)\s*\n\s*;\s*hp", t).groups())
    t1, t2 = re.search(r"db (\w+), (\w+) ; type", t).groups()
    catch = int(re.search(r"db (\d+) ; catch rate", t).group(1))
    bexp = int(re.search(r"db (\d+) ; base exp", t).group(1))
    lv1 = [m for m in re.search(r"db ([\w, ]+) ; level 1 learnset", t).group(1).replace(" ", "").split(",") if m != "NO_MOVE"]
    growth = GROWTH[re.search(r"db (GROWTH_\w+) ; growth rate", t).group(1)]
    species[dex] = dict(hp=hp, atk=atk, de=de, spd=spd, spc=spc, t1=TYPES[t1], t2=None if t2 == t1 else TYPES[t2], catch=catch, bexp=bexp,
                        lv1=[MOVE_ID[m] for m in lv1], growth=growth)
# Mew fica num arquivo separado (data/pokemon/mew.asm) em algumas versões
if 151 not in species and os.path.exists(os.path.join(SRC, "data/pokemon/mew.asm")):
    raise SystemExit("Mew não encontrado em base_stats; confira data/pokemon/mew.asm")
assert len(species) == 151, len(species)

# --- evoluções e ataques por nível ---
t = rd("data/pokemon/evos_moves.asm")
labels = re.findall(r"dw (\w+)EvosMoves", t)
DEXN = {k.replace("_", ""): v for k, v in DEX.items()}
evos, learn = [], []
for lab in dict.fromkeys(labels):
    if lab.upper() not in DEXN: continue  # MissingNo e afins
    dex = DEXN[lab.upper()]
    block = t[t.index(lab + "EvosMoves:"):]
    ev_part, rest = block.split("; Learnset", 1)
    for line in ev_part.splitlines():
        m = re.match(r"\s*db EVOLVE_LEVEL, (\d+), (\w+)", line)
        if m: evos.append((dex, DEX[m.group(2)], "nivel", int(m.group(1)), None)); continue
        m = re.match(r"\s*db EVOLVE_ITEM, (\w+), \d+, (\w+)", line)
        if m: evos.append((dex, DEX[m.group(2)], "pedra", None, STONES[m.group(1)])); continue
        m = re.match(r"\s*db EVOLVE_TRADE, \d+, (\w+)", line)
        if m: evos.append((dex, DEX[m.group(1)], "troca", None, None))
    for line in rest.splitlines():
        if re.match(r"\s*db 0\b", line): break
        m = re.match(r"\s*db (\d+), (\w+)", line)
        if m: learn.append((dex, int(m.group(1)), MOVE_ID[m.group(2)]))
# forma inicial da linha evolutiva
parent = {to: fr for fr, to, *_ in evos}
def base(d):
    seen = set()
    while d in parent:
        assert d not in seen, f"ciclo de evolução em {d}"
        seen.add(d); d = parent[d]
    return d

# --- ataques ---
moves = []
names_txt = rd("data/moves/names.asm")
move_names = re.findall(r'li "([^"]+)"', names_txt)
for line in rd("data/moves/moves.asm").splitlines():
    m = re.match(r"\s*move (\w+),\s*(\w+),\s*(\d+),\s*(\w+),\s*(\d+),\s*(\d+)", line)
    if not m: continue
    code, eff, power, typ, acc, pp = m.groups()
    mid = MOVE_ID[code]
    nm = move_names[mid - 1].title().replace("Pokémon", "Pokémon")
    moves.append((mid, code, nm, TYPES[typ], int(power), int(acc), int(pp), eff))
assert len(moves) == 165, len(moves)

# --- tabela de tipos ---
chart = []
for line in rd("data/types/type_matchups.asm").splitlines():
    m = re.match(r"\s*db (\w+),\s*(\w+),\s*(SUPER_EFFECTIVE|NOT_VERY_EFFECTIVE|NO_EFFECT)", line)
    if m: chart.append((TYPES[m.group(1)], TYPES[m.group(2)], {"SUPER_EFFECTIVE": 2, "NOT_VERY_EFFECTIVE": 0.5, "NO_EFFECT": 0}[m.group(3)]))

q = lambda v: "null" if v is None else ("'" + str(v).replace("'", "''") + "'" if isinstance(v, str) else str(v))
arr = lambda a: "'{" + ",".join(map(str, a)) + "}'"
L = []
L.append("""-- =====================================================================
-- POKEGAMES — Dados de batalha da 1ª geração (Pokémon Red/Blue).
-- Gerado por ferramentas/gerar_dados_gen1.py a partir do projeto pret/pokered
-- (reconstrução pública dos jogos). Só números e nomes: nenhuma imagem ou código.
-- Não muda nada do que já existe: só acrescenta colunas na tabela pokemon
-- e cria tabelas novas de ataques, evoluções, ataques por nível e tipos.
-- Rode depois do 15. Antes, faça a cópia de segurança.
-- =====================================================================
alter table public.pokemon
  add column if not exists g1_type1    text,
  add column if not exists g1_type2    text,
  add column if not exists base_hp     int,
  add column if not exists base_atk    int,
  add column if not exists base_def    int,
  add column if not exists base_spd    int,
  add column if not exists base_spc    int,
  add column if not exists catch_rate  int,
  add column if not exists base_exp    int,
  add column if not exists growth_rate text,
  add column if not exists start_moves int[] not null default '{}',
  add column if not exists base_form   int;

create table if not exists public.pk_moves (
  id int primary key, code text not null unique, name text not null, type text not null,
  power int not null, accuracy int not null, pp int not null, effect text not null);
create table if not exists public.pk_evolutions (
  from_id int not null references public.pokemon(id), to_id int not null references public.pokemon(id),
  method text not null check (method in ('nivel','pedra','troca')), level int, item text, primary key (from_id, to_id));
create table if not exists public.pk_learnset (
  species_id int not null references public.pokemon(id), level int not null, move_id int not null references public.pk_moves(id),
  primary key (species_id, level, move_id));
create table if not exists public.pk_type_chart (
  atk text not null, def text not null, mult numeric not null, primary key (atk, def));

-- dados do jogo: todos podem ler, ninguém escreve pelo site
alter table public.pk_moves enable row level security;
alter table public.pk_evolutions enable row level security;
alter table public.pk_learnset enable row level security;
alter table public.pk_type_chart enable row level security;
drop policy if exists p_pkm on public.pk_moves;      create policy p_pkm on public.pk_moves for select to authenticated using (true);
drop policy if exists p_pke on public.pk_evolutions; create policy p_pke on public.pk_evolutions for select to authenticated using (true);
drop policy if exists p_pkl on public.pk_learnset;   create policy p_pkl on public.pk_learnset for select to authenticated using (true);
drop policy if exists p_pkt on public.pk_type_chart; create policy p_pkt on public.pk_type_chart for select to authenticated using (true);
revoke all on public.pk_moves, public.pk_evolutions, public.pk_learnset, public.pk_type_chart from anon, authenticated;
grant select on public.pk_moves, public.pk_evolutions, public.pk_learnset, public.pk_type_chart to authenticated;
""")
L.append("insert into public.pk_moves (id, code, name, type, power, accuracy, pp, effect) values\n" +
         ",\n".join(f"({m[0]},{q(m[1])},{q(m[2])},{q(m[3])},{m[4]},{m[5]},{m[6]},{q(m[7])})" for m in moves) +
         "\non conflict (id) do update set code = excluded.code, name = excluded.name, type = excluded.type, power = excluded.power, accuracy = excluded.accuracy, pp = excluded.pp, effect = excluded.effect;\n")
for d in sorted(species):
    s = species[d]
    L.append(f"update public.pokemon set g1_type1 = {q(s['t1'])}, g1_type2 = {q(s['t2'])}, base_hp = {s['hp']}, base_atk = {s['atk']}, base_def = {s['de']}, base_spd = {s['spd']}, base_spc = {s['spc']}, "
             f"catch_rate = {s['catch']}, base_exp = {s['bexp']}, growth_rate = {q(s['growth'])}, start_moves = {arr(s['lv1'])}, base_form = {base(d)} where id = {d};")
L.append("\ndelete from public.pk_evolutions;\ninsert into public.pk_evolutions (from_id, to_id, method, level, item) values\n" +
         ",\n".join(f"({e[0]},{e[1]},{q(e[2])},{q(e[3])},{q(e[4])})" for e in evos) + ";\n")
L.append("delete from public.pk_learnset;\ninsert into public.pk_learnset (species_id, level, move_id) values\n" +
         ",\n".join(f"({a},{b},{c})" for a, b, c in sorted(set(learn))) + ";\n")
L.append("delete from public.pk_type_chart;\ninsert into public.pk_type_chart (atk, def, mult) values\n" +
         ",\n".join(f"({q(a)},{q(b)},{m})" for a, b, m in chart) + ";\n")
open(OUT, "w", encoding="utf-8", newline="\n").write("\n".join(L))
print(f"{len(species)} espécies, {len(moves)} ataques, {len(evos)} evoluções, {len(set(learn))} ataques por nível, {len(chart)} relações de tipo")
