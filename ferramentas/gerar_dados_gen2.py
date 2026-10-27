# Gera sql/27_dados_gen2.sql com os dados da 2ª geração (Pokémon 152 a 251), GUARDADOS ESCONDIDOS
# em tabelas próprias (gen2_*). Rodar o 27 não muda nada no jogo; quem liga é o 28 (interruptor do admin).
# Fontes (só números e nomes, nenhum código, imagem ou som é copiado):
#   * pret/pokecrystal (https://github.com/pret/pokecrystal): atributos, tipos da época, taxa de captura,
#     experiência-base, curva, evoluções, ataques por nível, ataques novos e tabela de tipos;
#   * PokeAPI (https://pokeapi.co): fatos dos desafios (tipos atuais, altura, peso, cor, habitat, evolução);
#   * ferramentas/descricoes_gen2_pt.txt: 100 descrições originais em português.
# Regras da 1ª geração (pedido do dono em 21/10/2026): o Especial vira um só (média de ataque e defesa
# especial); só os confrontos dos tipos novos (Sombrio e Metálico) entram na tabela de tipos; ataques novos
# com efeito parecido usam o efeito da 1ª geração, os outros ficam marcados como "ainda não funciona";
# evoluções por amizade, hora do dia e troca viram nível ou pedra, como no PLANO_SEGUNDA_GERACAO.md.
# Uso: python -I ferramentas/gerar_dados_gen2.py <pasta pokecrystal-master> <gen2.json da PokeAPI> ferramentas/descricoes_gen2_pt.txt sql/27_dados_gen2.sql
import re, sys, os, glob, json

SRC, API, DESC, OUT = sys.argv[1:5]
rd = lambda p: open(os.path.join(SRC, p), encoding="utf-8").read()

def consts(path, stop=None):
    out, n = {}, 0
    for line in rd(path).splitlines():
        m = re.match(r"\s*const_def\s*(-?\d+)?", line)
        if m:
            if out and stop: break          # só o primeiro bloco
            n = int(m.group(1) or 0); continue
        m = re.match(r"\s*const\s+(\w+)", line)
        if m:
            out[m.group(1)] = n; n += 1
            if m.group(1) == stop: break
    return out

MON = consts("constants/pokemon_constants.asm", stop="CELEBI")
MOVE_ID = consts("constants/move_constants.asm")
assert MON["CHIKORITA"] == 152 and MON["CELEBI"] == 251 and MOVE_ID["SKETCH"] == 166 and MOVE_ID["BEAT_UP"] == 251
TYPES = {"NORMAL": "NORMAL", "FIGHTING": "LUTA", "FLYING": "VOADOR", "POISON": "VENENO", "GROUND": "TERRA", "ROCK": "PEDRA", "BUG": "INSETO",
         "GHOST": "FANTASMA", "FIRE": "FOGO", "WATER": "AGUA", "GRASS": "PLANTA", "ELECTRIC": "ELETRICO", "PSYCHIC_TYPE": "PSIQUICO", "ICE": "GELO",
         "DRAGON": "DRAGAO", "DARK": "SOMBRIO", "STEEL": "METALICO", "CURSE_TYPE": "FANTASMA"}
GROWTH = {"GROWTH_MEDIUM_FAST": "medio_rapido", "GROWTH_SLIGHTLY_FAST": "pouco_rapido", "GROWTH_SLIGHTLY_SLOW": "pouco_lento",
          "GROWTH_MEDIUM_SLOW": "medio_lento", "GROWTH_FAST": "rapido", "GROWTH_SLOW": "lento"}
STONES = {"FIRE_STONE": "pedra_fogo", "THUNDERSTONE": "pedra_trovao", "WATER_STONE": "pedra_agua", "LEAF_STONE": "pedra_folha", "MOON_STONE": "pedra_lua", "SUN_STONE": "pedra_sol"}
# evoluções que não existem na 1ª geração (amizade, hora do dia, troca, atributo) -> regras simples do plano
OVERRIDE = {
    ("PICHU", "PIKACHU"): ("nivel", 15, None), ("CLEFFA", "CLEFAIRY"): ("nivel", 15, None), ("IGGLYBUFF", "JIGGLYPUFF"): ("nivel", 15, None),
    ("TOGEPI", "TOGETIC"): ("nivel", 20, None), ("GOLBAT", "CROBAT"): ("nivel", 38, None), ("CHANSEY", "BLISSEY"): ("nivel", 40, None),
    ("EEVEE", "ESPEON"): ("pedra", None, "pedra_sol"), ("EEVEE", "UMBREON"): ("pedra", None, "pedra_lua_nova"),
    ("ONIX", "STEELIX"): ("pedra", None, "pedra_metal"), ("SCYTHER", "SCIZOR"): ("pedra", None, "pedra_metal"),
    ("SLOWPOKE", "SLOWKING"): ("pedra", None, "pedra_rei"), ("POLIWHIRL", "POLITOED"): ("pedra", None, "pedra_rei"),
    ("SEADRA", "KINGDRA"): ("nivel", 45, None), ("PORYGON", "PORYGON2"): ("nivel", 40, None),
    ("TYROGUE", "HITMONLEE"): ("nivel", 20, None), ("TYROGUE", "HITMONCHAN"): ("nivel", 20, None), ("TYROGUE", "HITMONTOP"): ("nivel", 20, None),
}
# efeito da 2ª geração -> efeito equivalente da 1ª geração que o motor já sabe fazer (None = "ainda não funciona")
def g1_effect(eff, power, chance):
    side = lambda base: f"{base}2" if chance >= 30 else f"{base}1"
    if power == 1: return None                        # poder variável (Return, Flail, Magnitude, Hidden Power…)
    return {
        "EFFECT_NORMAL_HIT": "NO_ADDITIONAL_EFFECT", "EFFECT_PRIORITY_HIT": "NO_ADDITIONAL_EFFECT", "EFFECT_ATTACK_UP_HIT": "NO_ADDITIONAL_EFFECT",
        "EFFECT_DEFENSE_UP_HIT": "NO_ADDITIONAL_EFFECT", "EFFECT_ALL_UP_HIT": "NO_ADDITIONAL_EFFECT", "EFFECT_ACCURACY_DOWN_HIT": "NO_ADDITIONAL_EFFECT",
        "EFFECT_FALSE_SWIPE": "NO_ADDITIONAL_EFFECT", "EFFECT_PURSUIT": "NO_ADDITIONAL_EFFECT", "EFFECT_RAPID_SPIN": "NO_ADDITIONAL_EFFECT",
        "EFFECT_THIEF": "NO_ADDITIONAL_EFFECT", "EFFECT_FURY_CUTTER": "NO_ADDITIONAL_EFFECT", "EFFECT_ROLLOUT": "NO_ADDITIONAL_EFFECT",
        "EFFECT_BEAT_UP": "NO_ADDITIONAL_EFFECT", "EFFECT_FUTURE_SIGHT": "NO_ADDITIONAL_EFFECT", "EFFECT_SNORE": None,
        "EFFECT_PARALYZE_HIT": side("PARALYZE_SIDE_EFFECT"), "EFFECT_BURN_HIT": side("BURN_SIDE_EFFECT"), "EFFECT_FLAME_WHEEL": side("BURN_SIDE_EFFECT"),
        "EFFECT_SACRED_FIRE": side("BURN_SIDE_EFFECT"), "EFFECT_POISON_HIT": side("POISON_SIDE_EFFECT"), "EFFECT_FREEZE_HIT": "FREEZE_SIDE_EFFECT1",
        "EFFECT_TWISTER": "FLINCH_SIDE_EFFECT1", "EFFECT_CONFUSE_HIT": "CONFUSION_SIDE_EFFECT", "EFFECT_SPEED_DOWN_HIT": "SPEED_DOWN_SIDE_EFFECT",
        "EFFECT_DEFENSE_DOWN_HIT": "DEFENSE_DOWN_SIDE_EFFECT", "EFFECT_SP_DEF_DOWN_HIT": "SPECIAL_DOWN_SIDE_EFFECT",
        "EFFECT_LEECH_HIT": "DRAIN_HP_EFFECT", "EFFECT_MULTI_HIT": "TWO_TO_FIVE_ATTACKS_EFFECT", "EFFECT_TRIPLE_KICK": "TWO_TO_FIVE_ATTACKS_EFFECT",
        "EFFECT_ALWAYS_HIT": "SWIFT_EFFECT", "EFFECT_TRAP_TARGET": "TRAPPING_EFFECT", "EFFECT_RAMPAGE": "THRASH_PETAL_DANCE_EFFECT",
        "EFFECT_CONFUSE": "CONFUSION_EFFECT", "EFFECT_SWAGGER": "CONFUSION_EFFECT", "EFFECT_SPEED_DOWN_2": "SPEED_DOWN1_EFFECT",
        "EFFECT_ATTACK_DOWN_2": "ATTACK_DOWN1_EFFECT", "EFFECT_HEAL": "HEAL_EFFECT", "EFFECT_MORNING_SUN": "HEAL_EFFECT",
        "EFFECT_SYNTHESIS": "HEAL_EFFECT", "EFFECT_MOONLIGHT": "HEAL_EFFECT",
    }.get(eff)
PT_TYPE = {"normal": "Normal", "fire": "Fogo", "water": "Água", "grass": "Planta", "electric": "Elétrico", "ice": "Gelo", "fighting": "Lutador",
           "poison": "Venenoso", "ground": "Terrestre", "flying": "Voador", "psychic": "Psíquico", "bug": "Inseto", "rock": "Pedra",
           "ghost": "Fantasma", "dragon": "Dragão", "dark": "Sombrio", "steel": "Aço", "fairy": "Fada"}
PT_COLOR = {"green": "Verde", "red": "Vermelho", "blue": "Azul", "white": "Branco", "brown": "Marrom", "yellow": "Amarelo", "purple": "Roxo",
            "pink": "Rosa", "gray": "Cinza", "black": "Preto"}
PT_HAB = {"grassland": "Pradaria", "urban": "Urbano", "forest": "Floresta", "waters-edge": "Beira d'água", "mountain": "Montanha", "sea": "Mar",
          "rough-terrain": "Terreno acidentado", "cave": "Caverna", "rare": "Raro"}

api = {int(k): v for k, v in json.load(open(API, encoding="utf-8")).items()}
desc = {}
for line in open(DESC, encoding="utf-8"):
    if line.strip() and not line.startswith("#"):
        n, t = line.rstrip("\n").split("|", 1); desc[int(n)] = t.strip()
assert sorted(api) == list(range(152, 252)) and sorted(desc) == list(range(152, 252)), "faltam Pokémon na PokeAPI ou nas descrições"

# --- evoluções (todas as 251) e ataques por nível ---
t = rd("data/pokemon/evos_attacks.asm")
evos_all, learn = [], []
for name, block in re.findall(r"^(\w+)EvosAttacks:\n(.*?)(?=^\w+EvosAttacks:|\Z)", t, re.S | re.M):
    key = re.sub(r"(?<!^)(?=[A-Z0-9])", "_", name).upper()
    dex = MON.get(key) or MON.get(name.upper()) or next((v for k, v in MON.items() if k.replace("_", "") == name.upper()), None)
    if not dex: continue
    ev, mv = block.split("db 0 ; no more evolutions", 1)
    for line in ev.splitlines():
        m = re.match(r"\s*db EVOLVE_(\w+), ([\w-]+), (?:(\w+), )?(\w+)", line)
        if not m: continue
        kind, a, b, to = m.groups()
        evos_all.append((dex, MON[to], kind, a))
    for line in mv.splitlines():
        if re.match(r"\s*db 0\b", line): break
        m = re.match(r"\s*db (\d+), (\w+)", line)
        if m and dex >= 152: learn.append((dex, int(m.group(1)), MOVE_ID[m.group(2)]))
INV = {v: k for k, v in MON.items()}
evos = []
for fr, to, kind, a in evos_all:
    if fr < 152 and to < 152: continue                 # as da 1ª geração já estão no 16
    o = OVERRIDE.get((INV[fr], INV[to]))
    if o: evos.append((fr, to, *o))
    elif kind == "LEVEL": evos.append((fr, to, "nivel", int(a), None))
    elif kind == "ITEM": evos.append((fr, to, "pedra", None, STONES[a]))
    else: raise SystemExit(f"evolução sem regra: {INV[fr]} -> {INV[to]} ({kind})")
parent = {}
for fr, to, kind, a in evos_all: parent.setdefault(to, fr)
def base(d):
    seen = set()
    while d in parent:
        assert d not in seen; seen.add(d); d = parent[d]
    return d

# --- espécies ---
species = {}
for f in sorted(glob.glob(os.path.join(SRC, "data/pokemon/base_stats/*.asm"))):
    s = open(f, encoding="utf-8").read()
    dex = MON[re.search(r"db (\w+) ; \d+", s).group(1)]
    if dex < 152: continue
    hp, atk, de, spd, sat, sdf = map(int, re.search(r"db\s+(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+)\s*\n\s*;\s*hp", s).groups())
    t1, t2 = re.search(r"db (\w+), (\w+) ; type", s).groups()
    species[dex] = dict(hp=hp, atk=atk, de=de, spd=spd, spc=int((sat + sdf) / 2 + 0.5), t1=TYPES[t1], t2=None if t2 == t1 else TYPES[t2],
                        catch=int(re.search(r"db (\d+) ; catch rate", s).group(1)), bexp=int(re.search(r"db (\d+) ; base exp", s).group(1)),
                        growth=GROWTH[re.search(r"db (GROWTH_\w+) ; growth rate", s).group(1)])
assert sorted(species) == list(range(152, 252)), len(species)
lv1 = {}
for d, lv, m in learn:
    if lv == 1 and m not in lv1.setdefault(d, []): lv1[d].append(m)
def stage(d):
    n, x = 1, api[d]["from"]
    while x:
        n += 1; pid = int(x.rstrip("/").split("/")[-1]); x = api[pid]["from"] if pid in api else None
        if pid < 152:   # antecessor da 1ª geração: conta também os de antes dele
            p2 = parent.get(pid); n += 1 if p2 and p2 < 152 else 0; break
    return n

# --- ataques novos (166 a 251) ---
names = re.findall(r'li "([^"]+)"', rd("data/moves/names.asm"))
moves = []
for line in rd("data/moves/moves.asm").splitlines():
    m = re.match(r"\s*move (\w+),\s*(\w+),\s*(\d+),\s*(\w+),\s*(\d+),\s*(\d+),\s*(\d+)", line)
    if not m: continue
    code, eff, power, typ, acc, pp, ch = m.groups(); mid = MOVE_ID[code]
    if mid < 166: continue
    moves.append((mid, code, names[mid - 1].title(), TYPES[typ], int(power), int(acc), int(pp), eff, g1_effect(eff, int(power), int(ch))))
assert len(moves) == 86, len(moves)

# --- tabela de tipos: só os confrontos que envolvem os tipos novos ---
chart = []
for line in rd("data/types/type_matchups.asm").splitlines():
    m = re.match(r"\s*db (\w+),\s*(\w+),\s*(SUPER_EFFECTIVE|NOT_VERY_EFFECTIVE|NO_EFFECT)", line)
    if m and ("DARK" in m.group(1, 2) or "STEEL" in m.group(1, 2)):
        chart.append((TYPES[m.group(1)], TYPES[m.group(2)], {"SUPER_EFFECTIVE": 2, "NOT_VERY_EFFECTIVE": 0.5, "NO_EFFECT": 0}[m.group(3)]))

q = lambda v: "null" if v is None else ("'" + str(v).replace("'", "''") + "'" if isinstance(v, str) else ("true" if v is True else "false" if v is False else str(v)))
arr = lambda a: "'{" + ",".join(map(str, a)) + "}'"
L = ["""-- =====================================================================
-- POKEGAMES — Dados da 2ª geração (Pokémon 152 a 251), GUARDADOS ESCONDIDOS.
-- Gerado por ferramentas/gerar_dados_gen2.py (pret/pokecrystal + PokeAPI + descrições originais).
-- Rodar este arquivo NÃO muda nada no jogo: os dados ficam em tabelas próprias (gen2_*), que
-- ninguém lê pelo site. Quem liga e desliga a 2ª geração é o arquivo 28 (botão no admin).
-- Regras da 1ª geração: Especial = média de ataque e defesa especial; tipos novos Sombrio e
-- Metálico só nos confrontos com eles; ataques novos sem efeito equivalente ficam marcados
-- (effect_g1 vazio = "ainda não funciona"); evoluções simplificadas (ver PLANO_SEGUNDA_GERACAO.md).
-- Pode rodar mais de uma vez. Antes, faça a cópia de segurança.
-- =====================================================================
create table if not exists public.gen2_species (
  id int primary key, name text not null, type1 text not null, type2 text, habitat text not null, color text not null, stage int not null,
  height_dm int not null, weight_hg int not null, g1_type1 text not null, g1_type2 text, base_hp int not null, base_atk int not null,
  base_def int not null, base_spd int not null, base_spc int not null, catch_rate int not null, base_exp int not null, growth_rate text not null,
  start_moves int[] not null default '{}', base_form int not null, legendary boolean not null default false, baby boolean not null default false,
  description text not null);
create table if not exists public.gen2_base_forms (id int primary key, base_form int not null);   -- forma inicial de cada linha (1 a 251) com a 2ª ligada
create table if not exists public.gen2_moves (
  id int primary key, code text not null unique, name text not null, type text not null, power int not null, accuracy int not null, pp int not null,
  effect_g2 text not null, effect_g1 text);
create table if not exists public.gen2_evolutions (
  from_id int not null, to_id int not null, method text not null check (method in ('nivel','pedra','troca')), level int, item text, primary key (from_id, to_id));
create table if not exists public.gen2_learnset (species_id int not null, level int not null, move_id int not null, primary key (species_id, level, move_id));
create table if not exists public.gen2_type_chart (atk text not null, def text not null, mult numeric not null, primary key (atk, def));
-- escondidas: ninguém lê nem escreve pelo site
alter table public.gen2_species enable row level security;
alter table public.gen2_base_forms enable row level security;
alter table public.gen2_moves enable row level security;
alter table public.gen2_evolutions enable row level security;
alter table public.gen2_learnset enable row level security;
alter table public.gen2_type_chart enable row level security;
revoke all on public.gen2_species, public.gen2_base_forms, public.gen2_moves, public.gen2_evolutions, public.gen2_learnset, public.gen2_type_chart from anon, authenticated;
"""]
L.append("insert into public.gen2_species (id, name, type1, type2, habitat, color, stage, height_dm, weight_hg, g1_type1, g1_type2, base_hp, base_atk, base_def, base_spd, base_spc, catch_rate, base_exp, growth_rate, start_moves, base_form, legendary, baby, description) values")
rows = []
for d in range(152, 252):
    a, s = api[d], species[d]
    nm = a["names"].get("en") or a["name"].title()
    rows.append(f"({d},{q(nm)},{q(PT_TYPE[a['types'][0]])},{q(PT_TYPE[a['types'][1]]) if len(a['types']) > 1 else 'null'},{q(PT_HAB.get(a['habitat'], 'Raro'))},{q(PT_COLOR[a['color']])},"
                f"{stage(d)},{a['height']},{a['weight']},{q(s['t1'])},{q(s['t2'])},{s['hp']},{s['atk']},{s['de']},{s['spd']},{s['spc']},{s['catch']},{s['bexp']},{q(s['growth'])},"
                f"{arr(lv1.get(d, [])[-4:])},{base(d)},{q(bool(a['legend']))},{q(bool(a['baby']))},$d${desc[d]}$d$)")
L.append(",\n".join(rows) + "\non conflict (id) do update set name = excluded.name, type1 = excluded.type1, type2 = excluded.type2, habitat = excluded.habitat, color = excluded.color, stage = excluded.stage, height_dm = excluded.height_dm, weight_hg = excluded.weight_hg, g1_type1 = excluded.g1_type1, g1_type2 = excluded.g1_type2, base_hp = excluded.base_hp, base_atk = excluded.base_atk, base_def = excluded.base_def, base_spd = excluded.base_spd, base_spc = excluded.base_spc, catch_rate = excluded.catch_rate, base_exp = excluded.base_exp, growth_rate = excluded.growth_rate, start_moves = excluded.start_moves, base_form = excluded.base_form, legendary = excluded.legendary, baby = excluded.baby, description = excluded.description;\n")
L.append("insert into public.gen2_base_forms (id, base_form) values\n" + ",\n".join(f"({d},{base(d)})" for d in range(1, 252)) + "\non conflict (id) do update set base_form = excluded.base_form;\n")
L.append("insert into public.gen2_moves (id, code, name, type, power, accuracy, pp, effect_g2, effect_g1) values\n" + ",\n".join(f"({m[0]},{q(m[1])},{q(m[2])},{q(m[3])},{m[4]},{m[5]},{m[6]},{q(m[7])},{q(m[8])})" for m in moves)
         + "\non conflict (id) do update set code = excluded.code, name = excluded.name, type = excluded.type, power = excluded.power, accuracy = excluded.accuracy, pp = excluded.pp, effect_g2 = excluded.effect_g2, effect_g1 = excluded.effect_g1;\n")
L.append("delete from public.gen2_evolutions;\ninsert into public.gen2_evolutions (from_id, to_id, method, level, item) values\n" + ",\n".join(f"({e[0]},{e[1]},{q(e[2])},{q(e[3])},{q(e[4])})" for e in evos) + ";\n")
L.append("delete from public.gen2_learnset;\ninsert into public.gen2_learnset (species_id, level, move_id) values\n" + ",\n".join(f"({d},{lv},{m})" for d, lv, m in sorted(set(learn))) + ";\n")
L.append("delete from public.gen2_type_chart;\ninsert into public.gen2_type_chart (atk, def, mult) values\n" + ",\n".join(f"({q(a)},{q(b)},{m})" for a, b, m in chart) + ";\n")
open(OUT, "w", encoding="utf-8", newline="\n").write("\n".join(L))
unsup = [m[2] for m in moves if not m[8]]
print(f"{len(species)} Pokémon, {len(moves)} ataques novos ({len(moves) - len(unsup)} funcionam, {len(unsup)} ainda não), {len(evos)} evoluções, {len(set(learn))} ataques por nível, {len(chart)} confrontos de tipo")
print("ainda não funcionam:", ", ".join(unsup))
