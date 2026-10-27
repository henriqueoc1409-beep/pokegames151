import math, json, random
random.seed(151)
W, H = 3200, 2720
ROWS = [210, 730, 1250, 1770, 2290]
XL, XR = 360, 2840
TRUNK = ["Floresta", "Praia", "Montanha", "Pântano", "Planalto Real"]
MID = [("Bosque Antigo", "Ravina das Vespas"), ("Cidade Portuária", "Ponte Velha"), ("Mosteiro", "Cratera"),
       ("Aldeia dos Pescadores", "Lamaçal Profundo"), ("Estrada Real", "Atalho das Sombras")]
TURN = [("Trilha do Farol", "Caverna Escura"), ("Vale dos Ventos", "Desfiladeiro"), ("Bosque Enevoado", "Pântano Tóxico"), ("Jardins Reais", "Escadaria do Trovão")]
nodes = []
def add(x, y, region, branch, kind="normal", value=0):
    nodes.append(dict(id=len(nodes), x=round(x), y=round(y), kind=kind, value=value, region=region, branch=branch, next_a=None, next_b=None)); return len(nodes) - 1
def curve(r, x):  # trilha principal em curva suave
    return ROWS[r] + 62 * math.sin(2 * math.pi * x / 940 + r * 1.3)
def poly_len(pts): return sum(math.dist(pts[i], pts[i + 1]) for i in range(len(pts) - 1))
def resample(pts, n):  # n pontos estritamente entre o primeiro e o último
    segs = [(pts[i], pts[i + 1]) for i in range(len(pts) - 1)]; L = [math.dist(a, b) for a, b in segs]; tot = sum(L); out = []
    for k in range(1, n + 1):
        t = tot * k / (n + 1); acc = 0
        for (a, b), l in zip(segs, L):
            if acc + l >= t:
                f = (t - acc) / l; out.append((a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f)); break
            acc += l
    return out
def dense(f, x0, x1, steps=60): return [(x0 + (x1 - x0) * i / steps, f(x0 + (x1 - x0) * i / steps)) for i in range(steps + 1)]
# composição das rotas (equilíbrio): arriscada = lamaçal pesado; segura = baús e salário
def risky_kinds(n):
    ks = ["recuo"] * round(n * .45) + ["carta"] * round(n * .2) + ["raio"] * max(1, round(n * .1)) + ["bau"] * round(n * .1)
    ks += ["normal"] * (n - len(ks)); ks = ks[:n]; random.shuffle(ks)
    if ks[0] == "recuo": ks[0], ks[-1] = ks[-1], ks[0]
    return ks
def safe_kinds(n):
    ks = ["bau"] * round(n * .18) + ["pagamento"] * 2 + ["xp"] * round(n * .1) + ["avanco"] * max(1, round(n * .06))
    ks += ["normal"] * (n - len(ks)); ks = ks[:n]; random.shuffle(ks); return ks
TR = lambda i: ("raio" if i % 23 == 17 else "troca" if i % 29 == 13 else "avanco" if i % 17 == 9 else "recuo" if i % 19 == 14 else
                "pagamento" if i % 13 == 6 else "carta" if i % 8 == 3 else "bau" if i % 11 == 7 else "xp" if i % 21 == 11 else "normal")
forks_info = []
def make_fork(fork, merge_xy, safe_pts, risky_pts, names):
    ls, lr = poly_len(safe_pts), poly_len(risky_pts)
    ns = max(12, round(ls / 56)); nr = max(9, round(ns * .8))
    s_ids = [add(x, y, names[0], "seguro", k, 2 if k == "avanco" else 0) for (x, y), k in zip(resample(safe_pts, ns), safe_kinds(ns))]
    r_ids = [add(x, y, names[1], "arriscado", k, 6 if k == "recuo" else 0) for (x, y), k in zip(resample(risky_pts, nr), risky_kinds(nr))]
    for a, b in zip(s_ids, s_ids[1:]): nodes[a]["next_a"] = b
    for a, b in zip(r_ids, r_ids[1:]): nodes[a]["next_a"] = b
    nodes[fork]["kind"] = "bifurcacao"; nodes[fork]["next_a"] = s_ids[0]; nodes[fork]["next_b"] = r_ids[0]
    forks_info.append(dict(fork=fork, safe=s_ids, risky=r_ids, names=names))
    return s_ids, r_ids
prev = None; counter = 0
start = add(XL, curve(0, XL), "Floresta", "tronco", "inicio")
prev = start
for r in range(5):
    ltr = r % 2 == 0
    x0, x1 = (XL, XR) if ltr else (XR, XL)
    sgn = 1 if ltr else -1
    # trecho 1 da linha, até a bifurcação do meio
    xa, xb = (XL + (XR - XL) * .38, XL + (XR - XL) * .64) if ltr else (XR - (XR - XL) * .38, XR - (XR - XL) * .64)
    def trunk_run(xs, xe, first_skip=True):
        global prev, counter
        pts = dense(lambda x: curve(r, x), xs, xe, 120); n = max(2, round(poly_len(pts) / 58))
        ids = []
        for (x, y) in resample(pts, n - 1) + [(xe, curve(r, xe))]:
            counter += 1
            k = TR(counter)
            nid = add(x, y, TRUNK[r], "tronco", k, 3 if k in ("avanco", "recuo") else 0)
            if prev is not None and nodes[prev]["next_a"] is None and nodes[prev]["kind"] != "bifurcacao": nodes[prev]["next_a"] = nid
            ids.append(nid); prev = nid
        return ids
    if r > 0:  # o primeiro nó da linha é o ponto de chegada da curva anterior
        pass
    ids1 = trunk_run(x0 if r == 0 else x0, xa)
    fork = ids1[-1]
    for i in ids1[-2:]: nodes[i]["kind"] = "normal"; nodes[i]["value"] = 0
    # bifurcação do meio da linha: segura faz um arco longo; arriscada corta reto
    bulge = 1
    safe_pts = [(x, curve(r, x) + bulge * 250 * math.sin(math.pi * i / 60)) for i, (x, _) in enumerate(dense(lambda x: 0, xa, xb, 60))]
    risky_pts = [(x, curve(r, x) - bulge * 45 * math.sin(math.pi * i / 60)) for i, (x, _) in enumerate(dense(lambda x: 0, xa, xb, 60))]
    merge = add(xb, curve(r, xb), TRUNK[r], "tronco", "normal")
    s_ids, r_ids = make_fork(fork, (xb, curve(r, xb)), safe_pts, risky_pts, MID[r])
    nodes[s_ids[-1]]["next_a"] = merge; nodes[r_ids[-1]]["next_a"] = merge
    prev = merge
    ids2 = trunk_run(xb, x1)
    for i in ids2[:2]: nodes[i]["kind"] = "normal"; nodes[i]["value"] = 0
    if r == 4:
        nodes[ids2[-1]]["kind"] = "castelo"; nodes[ids2[-1]]["region"] = "Castelo da Liga"; nodes[ids2[-1]]["value"] = 0
        break
    # curva para a próxima linha: segura dá a volta por fora; arriscada desce em zigue-zague
    tf = ids2[-1]; nodes[ids2[-2]]["kind"] = "normal"; nodes[ids2[-2]]["value"] = 0
    fx, fy = nodes[tf]["x"], nodes[tf]["y"]; mx = x1; my = curve(r + 1, x1)
    out = 250 * sgn; inner = -95 * sgn
    safe_pts = [(fx, fy), (fx + out * .7, fy - 40), (fx + out, fy + 60), (fx + out, my - 60), (fx + out * .7, my + 40), (mx, my)]
    risky_pts = [(fx, fy), (fx + inner, fy + (my - fy) * .3), (fx, fy + (my - fy) * .55), (fx + inner * .8, fy + (my - fy) * .8), (mx, my)]
    merge = add(mx, my, TRUNK[r + 1], "tronco", "normal")
    s_ids, r_ids = make_fork(tf, (mx, my), safe_pts, risky_pts, TURN[r])
    nodes[s_ids[-1]]["next_a"] = merge; nodes[r_ids[-1]]["next_a"] = merge
    prev = merge
# distância até o castelo
castle = [n for n in nodes if n["kind"] == "castelo"][0]["id"]
dist = {castle: 0}; changed = True
while changed:
    changed = False
    for n in nodes:
        c = [dist[x] for x in (n["next_a"], n["next_b"]) if x is not None and x in dist]
        if c and (n["id"] not in dist or dist[n["id"]] > 1 + min(c)): dist[n["id"]] = 1 + min(c); changed = True
assert len(dist) == len(nodes), "nós sem caminho até o castelo"
for n in nodes: n["dist"] = dist[n["id"]]
def walk(choice):
    i, s = 0, 0
    while nodes[i]["kind"] != "castelo":
        n = nodes[i]; i = n["next_b"] if (choice == "b" and n["next_b"] is not None) else n["next_a"]; s += 1
    return s
# checagens de geometria
md = min(math.dist((a["x"], a["y"]), (nodes[a["next_a"]]["x"], nodes[a["next_a"]]["y"])) for a in nodes if a["next_a"] is not None)
close = sum(1 for a in nodes for b in nodes if a["id"] < b["id"] and math.dist((a["x"], a["y"]), (b["x"], b["y"])) < 30)
inside = all(40 < n["x"] < W - 40 and 60 < n["y"] < H - 40 for n in nodes)
from collections import Counter
print("casas:", len(nodes), "| caminho todo seguro:", walk("a"), "| todo arriscado:", walk("b"), "| bifurcações:", len(forks_info))
print("menor espaçamento:", round(md), "| pares sobrepostos (<30px):", close, "| dentro do mapa:", inside)
print(Counter(n["kind"] for n in nodes))
# equilíbrio por bifurcação
MOVE = 13.5; SAL = 90
print("\nbifurcação | seguro | arriscado | dist. efetiva segura x arriscada | moedas extras na segura")
for f in forks_info:
    S_ = [nodes[i] for i in f["safe"]]; R_ = [nodes[i] for i in f["risky"]]
    ls, lr = len(S_) + 1, len(R_) + 1
    p_rec = sum(n["kind"] == "recuo" for n in R_) / len(R_)
    loss = p_rec * 6                          # casas perdidas esperadas por parada na arriscada
    gain_s = sum(n["kind"] == "avanco" for n in S_) / len(S_) * 2
    eff_r = lr + (lr / MOVE) * loss; eff_s = ls - (ls / MOVE) * gain_s
    coins = sum(n["kind"] == "pagamento" for n in S_) * SAL + (ls / MOVE) * (sum(n["kind"] == "bau" for n in S_) / len(S_)) * 30
    print(f"{f['names'][0][:18]:18s} x {f['names'][1][:18]:18s} | {ls:3d} | {lr:3d} | {eff_s:5.1f} x {eff_r:5.1f} | +{coins:.0f}")
meta = {"w": W, "h": H, "water": [[470, 540], [1490, 1560]],
        "labels": [[TRUNK[r], (XL + 260) if r % 2 == 0 else (XR - 260), ROWS[r] - 110] for r in range(5)]}
import os
json.dump(dict(nodes=nodes, meta=meta), open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "mapa_gerado.json"), "w"), ensure_ascii=False)
bad = [n for n in nodes if not (40 < n["x"] < W - 40 and 60 < n["y"] < H - 40)]
print("fora do mapa:", [(n["id"], n["x"], n["y"], n["region"]) for n in bad][:5])
pairs = [(a["id"], b["id"], a["region"], b["region"], round(math.dist((a["x"], a["y"]), (b["x"], b["y"])))) for a in nodes for b in nodes if a["id"] < b["id"] and math.dist((a["x"], a["y"]), (b["x"], b["y"])) < 30]
print("sobrepostos:", pairs)
