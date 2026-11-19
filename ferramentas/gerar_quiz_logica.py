# Gera as perguntas de lógica do quiz (o insert do sql/127) a partir dos dados do jogo (sql/02 e sql/16).
# Uso (na pasta do projeto): python ferramentas/gerar_quiz_logica.py > perguntas.sql
import re, pathlib, math, sys
R = pathlib.Path(__file__).resolve().parent.parent
t2 = (R / "sql/02_pokemon.sql").read_text(encoding="utf8")
P = {}
S_ = r"'(?:[^']|'')*'"
for m in re.finditer(r"\((\d+),(" + S_ + r"),[^\n]*?,\d+,(\d+),(\d+)\)", t2):
    P[m.group(2)[1:-1].replace("''", "'")] = {"h": int(m.group(3)) / 10, "w": int(m.group(4)) / 10}
t16 = (R / "sql/16_pokemon_gen1.sql").read_text(encoding="utf8")
nome_id = {int(m.group(1)): m.group(2)[1:-1].replace("''", "'") for m in re.finditer(r"\((\d+),(" + S_ + r"),[^\n]*?,\d+,\d+,\d+\)", t2)}
for m in re.finditer(r"base_hp = (\d+), base_atk = (\d+), base_def = (\d+), base_spd = (\d+), base_spc = (\d+).*? where id = (\d+);", t16):
    P[nome_id[int(m.group(6))]].update(hp=int(m.group(1)), atk=int(m.group(2)), df=int(m.group(3)), spd=int(m.group(4)), spc=int(m.group(5)))
MV = {m.group(2): int(m.group(3)) for m in re.finditer(r"\(\d+,'[A-Z_]+','([^']+)','[A-Z]+',(\d+)", t16) for _ in [0]} if False else {}
for m in re.finditer(r"\(\d+,'[A-Z_]+','([^']+)','[A-Z]+',(\d+),", t16):
    MV[m.group(1)] = int(m.group(2))
assert len(P) == 151, len(P)

def br(x, casas=None):
    if casas is None:
        casas = 0 if abs(x - round(x)) < 1e-9 else (1 if abs(x * 10 - round(x * 10)) < 1e-9 else 2)
    s = f"{x:,.{casas}f}"
    return s.replace(",", "X").replace(".", ",").replace("X", ".")
def arred(x, casas=0):
    f = 10 ** casas
    return math.floor(x * f + 0.5) / f
def fim(x, casas=0):
    a = arred(x, casas)
    if abs(x - a) < 1e-9: return a, f"= {br(a)}."
    ex = abs(x * 100 - round(x * 100)) < 1e-9
    return a, f"= {br(x) if ex else br(x, 2) + '…'} → arredondando, {br(a, casas)}."

Q = []
def add(pergunta, resposta, explic):
    assert 5 <= len(pergunta) <= 300, (len(pergunta), pergunta)
    Q.append((pergunta, resposta, explic))

# 1) Empilhados até alcançar algo do nosso mundo (o número do mundo real vai na pergunta)
ALT = [
  ("Pikachu", "o topo do Cristo Redentor", 30, "a estátua do Cristo Redentor tem 30 m (sem o pedestal)"),
  ("Diglett", "a trave do gol", 2.44, "a trave de um gol oficial tem 2,44 m de altura"),
  ("Diglett", "o aro de uma cesta de basquete", 3.05, "o aro do basquete fica a 3,05 m do chão"),
  ("Onix", "o topo do Monte Everest", 8849, "o Everest tem 8.849 m"),
  ("Onix", "o topo da Torre Eiffel", 330, "a Torre Eiffel tem 330 m"),
  ("Onix", "o topo do Pão de Açúcar", 396, "o Pão de Açúcar tem 396 m"),
  ("Snorlax", "o topo do Cristo Redentor", 30, "a estátua do Cristo Redentor tem 30 m (sem o pedestal)"),
  ("Dragonite", "o telhado de um prédio de 10 andares", 30, "um prédio de 10 andares tem cerca de 30 m (3 m por andar)"),
  ("Mew", "o topo da Torre Eiffel", 330, "a Torre Eiffel tem 330 m"),
  ("Jigglypuff", "a cabeça de uma girafa", 5.5, "uma girafa adulta tem cerca de 5,5 m"),
  ("Mewtwo", "o topo do Pão de Açúcar", 396, "o Pão de Açúcar tem 396 m"),
  ("Pidgey", "a altura de um jogador de basquete", 2.1, "o jogador tem 2,10 m"),
  ("Bulbasaur", "o topo do Cristo Redentor", 30, "a estátua do Cristo Redentor tem 30 m (sem o pedestal)"),
  ("Gyarados", "o topo da Torre Eiffel", 330, "a Torre Eiffel tem 330 m"),
]
for p, alvo, v, info in ALT:
    h = P[p]["h"]; x = v / h; a, f = fim(x)
    add(f"Quantos {p} empilhados, um em cima do outro, alcançam {alvo} ({br(v)} m)?", a,
        f"Na Pokédex, o {p} mede {br(h)} m. {info[0].upper() + info[1:]}. Então: {br(v)} ÷ {br(h)} {f}")

# 2) Deitados em fila
FILA = [
  ("Onix", "a Ponte Rio–Niterói", 13290, "a Ponte Rio–Niterói tem 13.290 m"),
  ("Gyarados", "um campo de futebol oficial", 105, "um campo oficial tem 105 m de comprimento"),
  ("Magikarp", "uma piscina olímpica", 50, "a piscina olímpica tem 50 m"),
  ("Caterpie", "a pista dos 100 metros rasos", 100, "a pista tem 100 m"),
  ("Ekans", "uma quadra de vôlei", 18, "a quadra de vôlei tem 18 m de comprimento"),
  ("Arbok", "um campo de futebol oficial", 105, "um campo oficial tem 105 m de comprimento"),
  ("Dragonair", "uma piscina olímpica", 50, "a piscina olímpica tem 50 m"),
  ("Lapras", "um ônibus urbano", 12, "um ônibus urbano tem cerca de 12 m"),
  ("Pikachu", "uma quadra de futsal", 40, "uma quadra de futsal tem 40 m de comprimento"),
  ("Seaking", "uma piscina olímpica", 50, "a piscina olímpica tem 50 m"),
  ("Rattata", "um campo de futebol oficial", 105, "um campo oficial tem 105 m de comprimento"),
  ("Dratini", "um ônibus urbano", 12, "um ônibus urbano tem cerca de 12 m"),
]
for p, alvo, v, info in FILA:
    h = P[p]["h"]; x = v / h; a, f = fim(x)
    add(f"Quantos {p} deitados em fila, cabeça com rabo, cobrem {alvo} ({br(v)} m)?", a,
        f"O {p} mede {br(h)} m na Pokédex (vamos usar a altura como o comprimento dele deitado). {info[0].upper() + info[1:]}. Então: {br(v)} ÷ {br(h)} {f}")

# 3) Peso: quantos para igualar algo do nosso mundo
PESO = [
  ("Pikachu", "o limite de um elevador de 8 pessoas", 600, "o elevador aguenta 600 kg"),
  ("Pikachu", "um botijão de gás cheio", 28, "o botijão cheio pesa cerca de 28 kg"),
  ("Snorlax", "um elefante africano", 6000, "um elefante africano pesa cerca de 6.000 kg"),
  ("Snorlax", "uma baleia-azul", 150000, "a baleia-azul pesa cerca de 150.000 kg"),
  ("Gastly", "uma pessoa", 70, "a pessoa pesa 70 kg"),
  ("Gastly", "uma tonelada", 1000, "uma tonelada são 1.000 kg"),
  ("Golem", "um elefante africano", 6000, "um elefante africano pesa cerca de 6.000 kg"),
  ("Golem", "um Fusca", 800, "o Fusca pesa cerca de 800 kg"),
  ("Eevee", "uma pessoa", 70, "a pessoa pesa 70 kg"),
  ("Jigglypuff", "um saco de cimento", 50, "o saco de cimento pesa 50 kg"),
  ("Onix", "um carro popular", 1000, "o carro popular pesa cerca de 1.000 kg"),
  ("Mew", "uma pessoa", 70, "a pessoa pesa 70 kg"),
  ("Charmander", "uma geladeira", 70, "a geladeira pesa 70 kg"),
  ("Pidgey", "um peru de Natal", 7, "o peru pesa 7 kg"),
  ("Dragonite", "um carro popular", 1000, "o carro popular pesa cerca de 1.000 kg"),
  ("Haunter", "uma bola de futebol", 0.43, "a bola oficial pesa cerca de 0,43 kg"),
  ("Lapras", "um caminhão carregado", 15000, "o caminhão pesa 15.000 kg"),
  ("Diglett", "um saco de arroz", 5, "o saco de arroz pesa 5 kg"),
]
for p, alvo, v, info in PESO:
    w = P[p]["w"]; x = v / w; a, f = fim(x)
    add(f"Quantos {p} juntos pesam o mesmo que {alvo} ({br(v)} kg)?", a,
        f"Na Pokédex, o {p} pesa {br(w)} kg. {info[0].upper() + info[1:]}. Então: {br(v)} ÷ {br(w)} {f}")

# 4) Quantas pessoas pesam um Pokémon (o contrário)
for p in ["Snorlax", "Gyarados", "Golem", "Onix", "Lapras", "Dragonite"]:
    w = P[p]["w"]; a, f = fim(w / 70)
    add(f"Quantas pessoas de 70 kg seria preciso pôr na balança para igualar o peso de um {p}?", a,
        f"O {p} pesa {br(w)} kg na Pokédex. Cada pessoa pesa 70 kg. Então: {br(w)} ÷ 70 {f}")

# 5) Evolução: quantos do primeiro pesam o último
EVO = [("Magikarp", "Gyarados"), ("Caterpie", "Butterfree"), ("Gastly", "Gengar"), ("Geodude", "Golem"), ("Charmander", "Charizard"),
       ("Squirtle", "Blastoise"), ("Bulbasaur", "Venusaur"), ("Pidgey", "Pidgeot"), ("Pikachu", "Raichu"), ("Mew", "Mewtwo"), ("Onix", "Snorlax"),
       ("Dratini", "Dragonite"), ("Machop", "Machamp"), ("Weedle", "Beedrill"), ("Poliwag", "Poliwrath")]
for a1, b1 in EVO:
    wa, wb = P[a1]["w"], P[b1]["w"]; a, f = fim(wb / wa)
    extra = " (o Mewtwo foi criado a partir do DNA do Mew)" if a1 == "Mew" else ""
    add(f"Quantos {a1} juntos seria preciso pôr na balança para igualar o peso de um {b1}?", a,
        f"O {a1} pesa {br(wa)} kg e o {b1} pesa {br(wb)} kg{extra}. Então: {br(wb)} ÷ {br(wa)} {f}")

# 6) Somas de time
TIMES = [["Charizard", "Blastoise", "Venusaur"], ["Snorlax", "Onix", "Gyarados"], ["Articuno", "Zapdos", "Moltres"],
         ["Pikachu", "Eevee", "Jigglypuff", "Meowth"], ["Machamp", "Golem", "Gengar", "Alakazam"]]
for t in TIMES:
    ws = [P[p]["w"] for p in t]; s = sum(ws); a, f = fim(s)
    add(f"Quantos kg pesa, ao todo, um time com {', '.join(t[:-1])} e {t[-1]}?", a,
        "Pela Pokédex: " + ", ".join(f"{p} {br(P[p]['w'])} kg" for p in t) + f". Somando: {' + '.join(br(x) for x in ws)} {f}")
for t in [["Onix", "Gyarados", "Dragonair"], ["Snorlax", "Lapras", "Dragonite"]]:
    hs = [P[p]["h"] for p in t]; s = sum(hs); a, f = fim(s, 1)
    add(f"Se {', '.join(t[:-1])} e {t[-1]} deitassem em fila, quantos metros a fila teria?", a,
        "Pela Pokédex: " + ", ".join(f"{p} {br(P[p]['h'])} m" for p in t) + f". Somando: {' + '.join(br(x) for x in hs)} {f}")

# 7) Diferenças (curiosidades de tamanho)
DIF = [("Onix", "Pikachu", "h", "metros", "mais alto"), ("Snorlax", "Pikachu", "w", "kg", "mais pesado"),
       ("Gyarados", "Magikarp", "h", "metros", "mais alto"), ("Golem", "Graveler", "w", "kg", "mais pesado"),
       ("Mewtwo", "Mew", "h", "metros", "mais alto")]
for a1, b1, k, un, txt in DIF:
    va, vb = P[a1][k], P[b1][k]; a, f = fim(va - vb, 1)
    add(f"Quantos {un} o {a1} é {txt} que o {b1}?", a,
        f"O {a1} tem {br(va)} {'m' if k == 'h' else 'kg'} e o {b1} tem {br(vb)} {'m' if k == 'h' else 'kg'}. Então: {br(va)} − {br(vb)} {f}")

# 8) Atributos de batalha (os números base da Red/Blue)
ATR = [("Chansey", "Pikachu", "hp", "pontos de vida"), ("Electrode", "Slowpoke", "spd", "velocidade"),
       ("Alakazam", "Magikarp", "spc", "especial"), ("Cloyster", "Abra", "df", "defesa"), ("Machamp", "Chansey", "atk", "ataque"),
       ("Snorlax", "Diglett", "hp", "pontos de vida"), ("Jolteon", "Snorlax", "spd", "velocidade")]
for a1, b1, k, nome in ATR:
    va, vb = P[a1][k], P[b1][k]; a, f = fim(va / vb, 1)
    add(f"No atributo base de {nome} (o número da espécie na Red/Blue), quantas vezes o {a1} tem mais que o {b1}?", a,
        f"Na tabela da 1ª geração, o {a1} tem {va} de {nome} e o {b1} tem {vb}. Então: {va} ÷ {vb} {f}")
for p in ["Mewtwo", "Snorlax", "Dragonite", "Pikachu", "Magikarp"]:
    s = sum(P[p][k] for k in ["hp", "atk", "df", "spd", "spc"])
    add(f"Somando os 5 atributos base do {p} (vida, ataque, defesa, velocidade e especial), quanto dá?", s,
        f"Na tabela da 1ª geração, o {p} tem vida {P[p]['hp']}, ataque {P[p]['atk']}, defesa {P[p]['df']}, velocidade {P[p]['spd']} e especial {P[p]['spc']}. Somando: {P[p]['hp']} + {P[p]['atk']} + {P[p]['df']} + {P[p]['spd']} + {P[p]['spc']} = {s}.")

# 9) Poder dos golpes
GOL = [("Tackle", "Hyper Beam"), ("Scratch", "Explosion"), ("Ember", "Fire Blast"), ("Water Gun", "Hydro Pump"), ("Pound", "Hyper Beam")]
for fr, fo in GOL:
    a1, b1 = MV[fr], MV[fo]; a, f = fim(b1 / a1, 1)
    add(f"Quantos {fr} somam o mesmo poder de um único {fo}?", a,
        f"No jogo, o {fr} tem poder {a1} e o {fo} tem poder {b1}. Então: {b1} ÷ {a1} {f}")

# 10) O que eles fariam no nosso mundo (dados da Pokédex na pergunta)
add("A Pokédex diz que o Snorlax come 400 kg de comida por dia. Quantos pratos de feijoada de 500 g ele comeria num dia?", 800,
    "400 kg = 400.000 g. Cada prato tem 500 g. Então: 400.000 ÷ 500 = 800 pratos.")
add("O Snorlax come 400 kg de comida por dia. Em quantos dias ele comeria 1 tonelada (1.000 kg) de comida?", 2.5,
    "1.000 ÷ 400 = 2,5 dias.")
add("A Pokédex diz que o Dragonite dá a volta ao mundo (40.000 km) em 16 horas. Quantas horas ele levaria de São Paulo a Lisboa (7.900 km)?", 3.2,
    "Velocidade: 40.000 ÷ 16 = 2.500 km por hora. São Paulo a Lisboa: 7.900 ÷ 2.500 = 3,16… arredondando, 3,2 horas.")
add("O Dragonite dá a volta ao mundo (40.000 km) em 16 horas. Quantos minutos ele levaria do Rio a São Paulo (430 km)?", 10,
    "Velocidade: 40.000 ÷ 16 = 2.500 km por hora. 430 ÷ 2.500 = 0,172 hora. 0,172 × 60 = 10,32… arredondando, 10 minutos.")
add("A Pokédex diz que o Arcanine corre 10.000 km num dia. Quantos dias ele levaria para dar a volta na Terra (40.000 km)?", 4,
    "40.000 ÷ 10.000 = 4 dias.")
add("O Arcanine corre 10.000 km em 24 horas. Quantas horas ele levaria de Porto Alegre a Manaus (cerca de 4.500 km)?", 10.8,
    "Velocidade: 10.000 ÷ 24 = 416,7 km por hora. 4.500 ÷ 416,7 = 10,8 horas.")
add("Dizem que o Alakazam tem QI de 5.000. Quantas pessoas com QI 100 seria preciso somar para dar o QI de um Alakazam?", 50,
    "5.000 ÷ 100 = 50 pessoas.")
add("Dizem que o Machamp dá 1.000 socos em 2 segundos. Quantos socos ele daria numa partida de futebol de 90 minutos?", 2700000,
    "1.000 socos em 2 s = 500 socos por segundo. 90 minutos = 5.400 s. 500 × 5.400 = 2.700.000 socos.")
add("Dizem que o Machamp dá 1.000 socos em 2 segundos. Quantos socos em 1 minuto?", 30000,
    "500 socos por segundo × 60 s = 30.000 socos.")
add("A Pokédex diz que o Onix cava túneis a 80 km/h. Quantos minutos ele levaria para cavar um túnel de 20 km?", 15,
    "20 ÷ 80 = 0,25 hora. 0,25 × 60 = 15 minutos.")
add("Cada Exeggcute é um grupo de 6 ovos e pesa 2,5 kg. Quantos gramas pesa cada ovo?", 417,
    "2,5 kg = 2.500 g. 2.500 ÷ 6 = 416,7… arredondando, 417 g.")
add(f"O Dugtrio são 3 Diglett juntos, mas pesa {br(P['Dugtrio']['w'])} kg. Quantos kg ele pesa A MAIS do que 3 Diglett somados?",
    arred(P['Dugtrio']['w'] - 3 * P['Diglett']['w'], 1),
    f"Cada Diglett pesa {br(P['Diglett']['w'])} kg; 3 Diglett = {br(3 * P['Diglett']['w'])} kg. {br(P['Dugtrio']['w'])} − {br(3 * P['Diglett']['w'])} = {br(arred(P['Dugtrio']['w'] - 3 * P['Diglett']['w'], 1))} kg.")
add(f"O Magneton é feito de 3 Magnemite. Quantos kg ele pesa A MAIS do que 3 Magnemite somados?",
    arred(P['Magneton']['w'] - 3 * P['Magnemite']['w'], 1),
    f"O Magnemite pesa {br(P['Magnemite']['w'])} kg; 3 deles = {br(3 * P['Magnemite']['w'])} kg. O Magneton pesa {br(P['Magneton']['w'])} kg. {br(P['Magneton']['w'])} − {br(3 * P['Magnemite']['w'])} = {br(arred(P['Magneton']['w'] - 3 * P['Magnemite']['w'], 1))} kg.")
add("Num time de 6 Machamp, quantos braços tem ao todo?", 24, "Cada Machamp tem 4 braços. 6 × 4 = 24 braços.")
add("Quantas cabeças somam, juntos, 1 Dodrio, 1 Dugtrio, 1 Exeggutor e 1 Magneton?", 12,
    "Dodrio 3, Dugtrio 3, Exeggutor 3 (as cabeças de coco) e Magneton 3 (os 3 Magnemite). 3 + 3 + 3 + 3 = 12.")
h = P["Onix"]["h"]
add(f"Se o Onix ficasse em pé ao lado de um prédio, ele chegaria a qual andar? (cada andar tem 3 m)", arred(h / 3),
    f"O Onix mede {br(h)} m. {br(h)} ÷ 3 = {br(h / 3, 2)}… arredondando, ele chega no {br(arred(h / 3))}º andar.")
h = P["Gyarados"]["h"]
add(f"Um Gyarados cabe numa piscina de casa de 8 m? Responda quantos metros SOBRAM (ou negativo se faltar).", arred(8 - h, 1),
    f"O Gyarados mede {br(h)} m. 8 − {br(h)} = {br(arred(8 - h, 1))} m de sobra.")
w = P["Snorlax"]["w"]
add(f"Um Snorlax dorme no meio da estrada. Quantos guinchos que puxam 120 kg cada seriam precisos para tirar ele de lá?", math.ceil(w / 120),
    f"O Snorlax pesa {br(w)} kg. {br(w)} ÷ 120 = {br(w / 120, 2)}. Como não dá para usar pedaço de guincho, são {math.ceil(w / 120)}.")
w = P["Pikachu"]["w"]
add("Uma ponte de madeira aguenta 100 kg. Quantos Pikachu inteiros podem atravessar juntos sem ela quebrar?", math.floor(100 / w),
    f"O Pikachu pesa {br(w)} kg. 100 ÷ {br(w)} = {br(100 / w, 2)}…, então cabem {math.floor(100 / w)} inteiros (o 17º quebraria a ponte).")

def sq(s): return "'" + s.replace("'", "''") + "'"
NL = chr(10)
linhas = ("," + NL).join(f"  ({sq(p)}, {('%g' % r) if r != int(r) else int(r)}, {sq(e)})" for p, r, e in Q)
sys.stdout.reconfigure(encoding="utf-8")
print("insert into public.quiz_banco(pergunta, resposta, explicacao) values" + NL + linhas + NL +
      "on conflict (pergunta) do update set resposta = excluded.resposta, explicacao = excluded.explicacao, ativo = true;")
