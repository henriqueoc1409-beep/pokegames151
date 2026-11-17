// Testa o arquivo 123 (Bosque Sussurrante e Ginásio da Líder Flora de cara nova):
// liga/desliga aventura_viva em game_config e Ajustes do admin, aviso no Jornal alinhado com NOVIDADES,
// integridade completa do mapa deploy/rpg-bosque.js (saídas, Ginásio sem cortar borda, Lenhador Davi,
// riacho, mato perto e mata funda, zero bolsões presos) e encontros/Ginásio do Bosque funcionando iguais.
// Uso:  node ferramentas/testar_bosque_novo.mjs .
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

console.log("\nAjustes do visual e Jornal (arquivo 123)");
const cfg = (await sys(`select config->'visual' c from game_config where active`))[0].c;
check("aventura_viva está ligado no game_config e preserva mapa_novo, vila_nova e herois_novos",
  cfg?.aventura_viva === true && cfg?.mapa_novo === true && cfg?.vila_nova === true && cfg?.herois_novos === true && cfg?.on === true,
  JSON.stringify(cfg));

const admCfg = await as(ADM, `select public.admin_cfg_efetiva() x`);
check("aparece em Ajustes do jogo para o admin", !admCfg.error && admCfg.rows[0].x.visual?.aventura_viva === true, admCfg.error);

await sys(`update game_config set config = jsonb_set(config, '{visual,aventura_viva}', 'false') where active`);
check("o admin desliga aventura_viva e o valor fica guardado", (await sys(`select public.visual_cfg() c`))[0].c.aventura_viva === false);

const TITULO = "🌲 Bosque Sussurrante e Ginásio da Líder Flora de cara nova";
check("aviso publicado no Jornal uma vez", (await sys(`select count(*)::int n from posts where title = $1`, [TITULO]))[0].n === 1);

await db.exec(fs.readFileSync(path.join(root, "sql/123_bosque_sussurrante_novo.sql"), "utf8"));
check("rodar o 123 de novo não repete o aviso nem religa o que o admin desligou",
  (await sys(`select count(*)::int n from posts where title = $1`, [TITULO]))[0].n === 1 &&
  (await sys(`select public.visual_cfg() c`))[0].c.aventura_viva === false);

const indexHtml = fs.readFileSync(path.join(root, "deploy/index.html"), "utf8");
check("NOVIDADES e AJ_LABELS em deploy/index.html têm o mesmo título e o controle aventura_viva",
  indexHtml.includes(TITULO) && indexHtml.includes("aventura_viva:") && indexHtml.includes("RPG_ARTE_V = 4"));

console.log("\nMapa deploy/rpg-bosque.js e conexões");
const ctx = { window: {} };
vm.runInNewContext(fs.readFileSync(path.join(root, "deploy/rpg-bosque.js"), "utf8"), ctx);
const B = ctx.window.RPG_ARTE?.bosque;
check("rpg-bosque.js carrega grade 44×44 e imagem WebP", !!B && B.g?.length === 44 && B.g.every(l => l.length === 44) && B.img?.startsWith("data:image/webp;base64,") && B.img.length > 100000);

const W = 44, H = 44, g = B.g, gp = B.gymPos, np = B.npcs?.[0];
check("prédio 5×4 do Ginásio fica inteiro dentro do mapa (sem cortar na borda)",
  Array.isArray(gp) && gp[0] - 2 >= 1 && gp[0] + 2 <= W - 2 && gp[1] - 4 >= 1 && gp[1] + 1 <= H - 2,
  JSON.stringify(gp));

const gymFoot = (x, y) => x >= gp[0] - 2 && x <= gp[0] + 2 && y >= gp[1] - 4 && y <= gp[1] - 1;
const solid = (x, y) => x < 0 || y < 0 || x >= W || y >= H || "#~".includes(g[y][x]) || gymFoot(x, y) || (x === np[0] && y === np[1]);

const vis = new Set([B.chegada.join(",")]), q = [B.chegada];
while (q.length) {
  const [x, y] = q.shift();
  for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
    const nx = x + dx, ny = y + dy, k = nx + "," + ny;
    if (!solid(nx, ny) && !vis.has(k)) { vis.add(k); q.push([nx, ny]); }
  }
}

const sVila = B.saidas?.find(s => s.para === "vila"), sCharco = B.saidas?.find(s => s.para === "charco");
check("chegada e saídas para Vila Aurora e Charco Sombrio são alcançáveis",
  !solid(...B.chegada) && sVila?.em.every(p => vis.has(p.join(","))) && sCharco?.em.every(p => vis.has(p.join(","))));
check("porta do Ginásio e casa de saída [gymPos.x, gymPos.y+1] são alcançáveis",
  !solid(...gp) && vis.has(gp.join(",")) && !solid(gp[0], gp[1] + 1) && vis.has(gp[0] + "," + (gp[1] + 1)));
check("placa, fogueira/tochas e Lenhador Davi estão em posições válidas e acessíveis",
  !solid(...B.pontos.placa) && vis.has(B.pontos.placa.join(",")) && B.pontos.fogos?.length >= 3 &&
  g[np[1]][np[0]] === "." && [[1, 0], [-1, 0], [0, 1], [0, -1]].some(([dx, dy]) => vis.has((np[0] + dx) + "," + (np[1] + dy))));

let mN = 0, eN = 0, wN = 0, presos = 0;
for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
  if (g[y][x] === "m") mN++;
  if (g[y][x] === "e") eN++;
  if (g[y][x] === "~") wN++;
  if (!solid(x, y) && !vis.has(x + "," + y)) presos++;
}
check("tem riacho (~), mato perto (m), mata funda (e) e zero casas livres presas em bolsões",
  wN >= 60 && mN >= 80 && eN >= 80 && presos === 0, JSON.stringify({ wN, mN, eN, presos }));

console.log("\nEncontros e Ginásio do Bosque intactos");
const m1 = (await sys(`select (public.pk_new_monster($1, 6, 40)).id id`, [A]))[0].id;
const m2 = (await sys(`select (public.pk_new_monster($1, 9, 40)).id id`, [A]))[0].id;
const m3 = (await sys(`select (public.pk_new_monster($1, 3, 40)).id id`, [A]))[0].id;
const m4 = (await sys(`select (public.pk_new_monster($1, 25, 40)).id id`, [A]))[0].id;
await sys(`update monsters set team_slot = 1 where id = $1`, [m1]);

const enc1 = await as(A, `select public.rpg_encontro($1, 'bosque') r`, [m1]);
await sys(`delete from battles where p1 = $1`, [A]);
await sys(`update rpg_dias set ult = now() - interval '1 minute', batalhas = 0 where user_id = $1`, [A]);
const enc2 = await as(A, `select public.rpg_encontro($1, 'bosque_fundo') r`, [m1]);
await sys(`delete from battles where p1 = $1`, [A]);
check("encontros em bosque e bosque_fundo continuam funcionando", !enc1.error && !enc2.error, enc1.error || enc2.error);

const gym = await as(A, `select public.rpg_ginasio_lutar('bosque', null, $1) r`, [`{${[m1, m2, m3, m4].join(",")}}`]);
check("desafio contra a Líder Flora no Ginásio do Bosque funciona normalmente", !gym.error && !!gym.rows?.[0]?.r?.battle, gym.error);

console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
