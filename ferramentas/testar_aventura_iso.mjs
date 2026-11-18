// Testa o arquivo 126 (Aventura em 3D diagonal isométrica, Inventário na tela e Mapa Grande com guia):
// confere game_config/Ajustes, publicação no Jornal sem expor porcentagens, regras da Aventura intactas
// e executa no Node o motor 3D isométrico, a inversão de clique na tela, o cálculo de caminhos/rotas,
// o Mapa Grande em 2 abas e o Inventário flutuante sobre os mapas reais (rpg-arte.js e rpg-bosque.js).
// Uso:  node ferramentas/testar_aventura_iso.mjs .
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs";
import path from "path";
import vm from "vm";

const root = process.argv[2] || ".";
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql").sort((a, b) => parseInt(a) - parseInt(b) || a.localeCompare(b))) {
  await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
}

let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => {
  await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`);
  try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); }
};

const A = "11111111-1111-1111-1111-111111111111", ADM = "99999999-9999-9999-9999-999999999999";
for (const [u, n] of [[A, "Ana"], [ADM, "Chefe"]]) {
  await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]);
  await as(u, `select public.create_character($1, 'guerreiro')`, [n]);
}
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);

console.log("\n1. Banco, Ajustes do jogo e Jornal (arquivo 126)");
const cfg = (await sys(`select config->'visual' c from game_config where active`))[0].c;
check("aventura_iso está ligado por padrão e preserva todos os outros ajustes do visual",
  cfg?.aventura_iso === true && cfg?.tabuleiro_vivo === true && cfg?.telas_compactas === true &&
  cfg?.aventura_viva === true && cfg?.mapa_novo === true && cfg?.vila_nova === true && cfg?.on === true,
  JSON.stringify(cfg));

const admCfg = await as(ADM, `select public.admin_cfg_efetiva() x`);
check("admin vê aventura_iso em Ajustes do jogo",
  !admCfg.error && admCfg.rows[0].x.visual?.aventura_iso === true, admCfg.error);

const usrAdm = await as(A, `select public.admin_cfg_efetiva() x`);
const usrFn = await as(A, `select public.visual_cfg() x`);
check("jogador comum não chama admin_cfg_efetiva nem visual_cfg direto", !!usrAdm.error && !!usrFn.error);

await sys(`update game_config set config = jsonb_set(config, '{visual,aventura_iso}', 'false') where active`);
const vOff = (await sys(`select public.visual_cfg() c`))[0].c;
check("admin pode desligar aventura_iso e a escolha fica guardada", vOff.aventura_iso === false, JSON.stringify(vOff));

const TITULO = "🧭 Aventura em 3D diagonal, Inventário na tela e Mapa Grande com guia";
const postRows = await sys(`select title, body from posts where title = $1`, [TITULO]);
check("novidade publicada no Jornal uma vez e sem expor porcentagens (%)",
  postRows.length === 1 && !postRows[0].body.includes("%"));

await db.exec(fs.readFileSync(path.join(root, "sql/126_aventura_isometrica_e_mapa.sql"), "utf8"));
const vAfter = (await sys(`select public.visual_cfg() c`))[0].c;
check("rodar o 126 de novo não duplica o post nem religa o que o admin desligou",
  (await sys(`select count(*)::int n from posts where title = $1`, [TITULO]))[0].n === 1 && vAfter.aventura_iso === false);

const est = await as(A, `select public.rpg_estado() r`);
check("rpg_estado continua funcionando normalmente para jogador comum",
  !est.error && Array.isArray(est.rows[0].r?.missoes) && est.rows[0].r?.batalhas_dia >= 20, est.error);

console.log("\n2. Motor 3D diagonal, clique no chão, Mapa Grande e Inventário (deploy/index.html)");
const html = fs.readFileSync(path.join(root, "deploy/index.html"), "utf8");
check("NOVIDADES, AJ_LABELS e Biblioteca atualizados em deploy/index.html",
  html.includes(TITULO) && html.includes("aventura_iso:") && html.includes("visão 3D diagonal"));

// Executa o script do site num ambiente simulado leve para testar a matemática 3D, BFS e telas
const mainScript = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]).join("\n");
const makeCtx2D = () => new Proxy({
  canvas: { width: 960, height: 600 },
  measureText: t => ({ width: String(t).length * 7 }),
  createLinearGradient: () => ({ addColorStop() {} }),
  createRadialGradient: () => ({ addColorStop() {} }),
  getImageData: (_, __, w, h) => ({ data: new Uint8ClampedArray(w * h * 4) })
}, { get: (t, p) => p in t ? t[p] : () => {} });
const makeEl = (tag = "div") => {
  const el = {
    tagName: tag.toUpperCase(), id: "", className: "", hidden: false, style: {}, dataset: {},
    width: 960, height: 600, clientWidth: 960, clientHeight: 600, offsetParent: {},
    innerHTML: "", textContent: "", children: [],
    classList: { _s: new Set(), add(...a) { a.forEach(x => this._s.add(x)); }, remove(...a) { a.forEach(x => this._s.delete(x)); }, toggle(x, f) { const on = f != null ? !!f : !this._s.has(x); if (on) this._s.add(x); else this._s.delete(x); return on; }, contains(x) { return this._s.has(x); } },
    getContext: () => makeCtx2D(),
    getBoundingClientRect: function () { return { left: 0, top: 0, width: this.clientWidth || 960, height: this.clientHeight || 600 }; },
    addEventListener() {}, removeEventListener() {}, setAttribute() {}, remove() {}, appendChild(c) { this.children.push(c); return c; },
    querySelector: () => makeEl(), querySelectorAll: () => []
  };
  return el;
};
const els = new Map();
const bySel = sel => {
  if (typeof sel === "string" && sel.startsWith("#") && !sel.includes(" ")) {
    const id = sel.slice(1);
    if (!els.has(id)) { const e = makeEl(id.includes("cv") || id.includes("mini") || id.includes("rmap") ? "canvas" : "div"); e.id = id; els.set(id, e); }
    return els.get(id);
  }
  return null;
};
const store = new Map();
const sandbox = {
  console, Math, Date, JSON, Object, Array, Map, Set, Number, String, Boolean, RegExp, Promise, Error,
  Int32Array, Uint8Array, Uint8ClampedArray, parseInt, parseFloat, isFinite, isNaN,
  setTimeout: () => 1, clearTimeout() {}, setInterval: () => 1, clearInterval() {},
  requestAnimationFrame: () => 1, cancelAnimationFrame() {},
  performance: { now: () => 1000 },
  localStorage: { getItem: k => store.has(k) ? store.get(k) : null, setItem: (k, v) => store.set(k, String(v)), removeItem: k => store.delete(k) },
  matchMedia: () => ({ matches: false, addEventListener() {} }),
  addEventListener() {}, removeEventListener() {},
  location: { search: "", href: "http://localhost/", origin: "http://localhost" },
  history: { replaceState() {} },
  navigator: { clipboard: { writeText: async () => {} } },
  devicePixelRatio: 1, innerWidth: 1280, innerHeight: 720,
  Image: class { constructor() { this.complete = true; this.naturalWidth = 64; this.width = 1920; this.height = 1920; this.dataset = {}; } set src(v) { this._src = v; if (this.onload) this.onload(); } get src() { return this._src; } },
  AudioContext: class {}, Path2D: class {},
  URL, encodeURIComponent, decodeURIComponent, btoa: s => Buffer.from(s).toString("base64"), atob: s => Buffer.from(s, "base64").toString("binary"),
  supabase: { createClient: () => ({ auth: { getSession: async () => ({ data: { session: null } }), onAuthStateChange() {} }, channel: () => ({ on() { return this; }, subscribe() { return this; }, untrack() {}, send() {} }), removeChannel() {} }) },
  document: {
    body: makeEl("body"), head: makeEl("head"), documentElement: makeEl("html"),
    createElement: tag => makeEl(tag),
    querySelector: sel => bySel(sel),
    querySelectorAll: () => [],
    getElementById: id => bySel("#" + id),
    addEventListener() {}
  }
};
sandbox.window = sandbox;
sandbox.self = sandbox;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(path.join(root, "deploy/rpg-arte.js"), "utf8"), sandbox);
vm.runInContext(fs.readFileSync(path.join(root, "deploy/rpg-bosque.js"), "utf8"), sandbox);
vm.runInContext(fs.readFileSync(path.join(root, "deploy/rpg-vale.js"), "utf8"), sandbox);
vm.runInContext(mainScript, sandbox);

const res = vm.runInContext(`(() => {
  S.session = { user: { id: "${A}" } };
  S.me = { user_id: "${A}", name: "Ana", class: "guerreiro", level: 12, xp: 45, coins: 1250, hints: 2, retries: 1, outfit: {} };
  S.cfg = { visual: { aventura_iso: true, aventura_viva: true } };
  S.pk = { on: true, mons: [{ id: "m1", species_id: 25, level: 18, team_slot: 1, hp_pct: 80 }], bag: { potion: 3, fire_stone: 1 }, items: { potion: { id: "potion", name: "Potion", kind: "cura", sort: 1, descr: "Recupera 20 PV" } }, rules: { capture: { balls: { poke: { name: "Poké Bola", price: 0 } } }, storage: { max_monsters: 60 } }, dex: { 25: true } };
  const vila = window.RPG_ARTE.vila, bosque = window.RPG_ARTE.bosque;
  AV.dc = { vila: { ...vila, im: new Image() }, bosque: { ...bosque, im: new Image() } };
  AV.r = "vila"; AV.dados = AV.dc.vila; AV.img = AV.dc.vila.im; AV.g = vila.g;
  AV.x = 28; AV.y = 30; AV.fx = 28; AV.fy = 30; AV.open = true;
  AV.st = { batalhas: 2, batalhas_dia: 20, insignias: ["bosque"], missoes: [{ n: 1, regiao: "vila", tipo: "regiao", alvo: "bosque", meta: 3, prog: 1, resgatada: false, premio: { coins: 50 } }] };
  rpgDecoInit("vila");
  const decoCount = AV.decoMons?.length || 0;

  // 1. Rota entre regiões distantes no mundo
  const rotaElite = rpgRotaMundo("vila", "elite");
  const rotaVulcao = rpgRotaMundo("charco", "vulcao");

  // 2. Caminho BFS na Vila Aurora (da praça 28,30 até o Centro Pokémon 57,46 atravessando a ponte)
  const camCentro = rpgAchaCaminho(28, 30, 57, 46, "vila");
  const camValido = Array.isArray(camCentro) && camCentro.length > 20 && camCentro.every(([x, y]) => !"#~".includes(vila.g[y][x]));

  // 3. Clique em cima do telhado/parede sólida da Loja Pokémon (30, 24) leva até a porta andável (30, 26)
  const camLoja = rpgAchaCaminho(28, 30, 30, 24, "vila");
  const portaLoja = camLoja?.at(-1);

  // 4. Desenho 3D isométrico + conversão exata de clique na tela -> casa (tx, ty) em 3 alturas (chão z=0, porto z=0.25, penhasco z=1.0)
  const cv = document.querySelector("#rpg-cv");
  cv.clientWidth = 1200; cv.clientHeight = 800;
  rpgPinta(1200);
  const cam = AV._cam;
  const projCentro = (tx, ty) => {
    const z = isoElev("vila", vila.g, tx, ty);
    return [(cam.ox + (tx - ty) * cam.IW) * cam.k - cam.cx, (cam.oy + (tx + ty + 1) * cam.IH - z * cam.IZ) * cam.k - cam.cy];
  };
  const [sx1, sy1] = projCentro(28, 30);
  const hit1 = rpgTelaParaCasa(sx1, sy1);
  AV.x = 50; AV.y = 8; AV.fx = 50; AV.fy = 8; rpgPinta(1300);
  const [sx2, sy2] = ((c) => { const z = isoElev("vila", vila.g, 52, 6); return [(c.ox + (52 - 6) * c.IW) * c.k - c.cx, (c.oy + (52 + 6 + 1) * c.IH - z * c.IZ) * c.k - c.cy]; })(AV._cam);
  const hit2 = rpgTelaParaCasa(sx2, sy2);

  // 5. Renderização do Mapa Grande (2 abas) e do Inventário flutuante
  AV.x = 28; AV.y = 30; AV.fx = 28; AV.fy = 30;
  const htmlLocal = rpgMapaHTML("local");
  AV.mapSel = "pico";
  const htmlMundo = rpgMapaHTML("mundo");
  const invEl = document.querySelector("#rpg-inv");
  invEl.hidden = false;
  rpgInvRender();
  rpgHud();
  rpgMapaLocalDesenha();
  rpgMapaMundoDesenha();

  // 6. Desenha também Bosque, Vale do Treino, Salão de Ginásio, Planalto e modo 2D clássico sem erros
  AV.dc.vale = { ...window.RPG_ARTE.vale, im: new Image() };
  AV.dc.gym_bosque = rpgGymInterior("bosque");
  AV.dc.elite = rpgEliteInterior();
  for (const reg of ["bosque", "vale", "gym_bosque", "elite"]) {
    AV.r = reg; AV.dados = AV.dc[reg]; AV.img = AV.dc[reg].im; AV.g = AV.dc[reg].g;
    const ch = AV.dados.chegada || [5, 5]; AV.x = ch[0]; AV.y = ch[1]; AV.fx = ch[0]; AV.fy = ch[1];
    rpgDecoInit(reg);
    rpgPinta(1500);
  }
  rpgToggleIso(); // alterna para 2D clássico
  rpgPinta(1600);
  const voltou2D = AV._cam?.iso === false;
  rpgToggleIso(); // volta para 3D diagonal

  return {
    rotaElite, rotaVulcao, camValido, portaLoja,
    isoAtivo: cam?.iso === true, voltou2D,
    hit1, hit2, decoCount,
    temLocal: htmlLocal.includes("Centro Pokémon") && htmlLocal.includes("Gruta da Pedreira") && htmlLocal.includes("Saídas"),
    temMundo: htmlMundo.includes("Pico Gelado") && htmlMundo.includes("Gruta da Pedreira") && htmlMundo.includes("Caminho:"),
    temInv: invEl.innerHTML.includes("Inventário") && invEl.innerHTML.includes("Pokébolas") && invEl.innerHTML.includes("Lv. 18") && invEl.innerHTML.includes("1.250"),
    temHeroBar: document.querySelector("#rpg-hero-bar").innerHTML.includes("Missão Diária") && document.querySelector("#rpg-loc-bar").innerHTML.includes("Mundo:")
  };
})()`, sandbox);

check("rota do Mundo calcula o caminho exato entre regiões (Vila ➔ Planalto e Charco ➔ Vulcão)",
  JSON.stringify(res.rotaElite) === JSON.stringify(["vila", "pedreira", "pico", "estrada", "elite"]) &&
  JSON.stringify(res.rotaVulcao) === JSON.stringify(["charco", "bosque", "vila", "deserto", "vulcao"]),
  JSON.stringify(res.rotaElite));

check("BFS na Vila Aurora acha o caminho livre de muros e água até o Centro Pokémon", res.camValido);
check("clicar em cima do prédio 3D da Loja leva exatamente à porta andável (30, 26)",
  JSON.stringify(res.portaLoja) === JSON.stringify([30, 26]), JSON.stringify(res.portaLoja));

check("motor 3D isométrico desenha sem erro e converte o clique na tela para a casa exata (no chão e no alto do penhasco)",
  res.isoAtivo && JSON.stringify(res.hit1) === JSON.stringify([28, 30]) && JSON.stringify(res.hit2) === JSON.stringify([52, 6]),
  JSON.stringify({ hit1: res.hit1, hit2: res.hit2 }));

check("Pokémon selvagens decorativos iniciam nas áreas de mato da região", res.decoCount >= 4, String(res.decoCount));
check("Mapa Grande renderiza a aba 'Onde estou' com lojas e saídas e a aba 'Mundo inteiro' com a rota passo a passo",
  res.temLocal && res.temMundo);
check("Inventário flutuante e barras RPG (nível/EXP/Missão Diária e coordenadas) renderizam completos",
  res.temInv && res.temHeroBar);
check("Bosque, Vale do Treino, Ginásios, Planalto e alternância 3D/2D desenham sem erros", res.voltou2D === true);

console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
