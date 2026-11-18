// Testa o arquivo 124 (Tabuleiro renovado, caminhada ao vivo e telas mais compactas):
// liga/desliga tabuleiro_vivo e telas_compactas em game_config e Ajustes do admin,
// aviso no Jornal alinhado com NOVIDADES, funções novas do site presentes e sem expor chances,
// e caminhada/rotas/casas funcionando exatamente igual para jogador comum.
// Uso:  node ferramentas/testar_tabuleiro_vivo.mjs .
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs";
import path from "path";

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

console.log("\nAjustes do visual e Jornal (arquivo 124)");
const cfg = (await sys(`select config->'visual' c from game_config where active`))[0].c;
check("tabuleiro_vivo e telas_compactas estão ligados e preservam todos os outros ajustes do visual",
  cfg?.tabuleiro_vivo === true && cfg?.telas_compactas === true && cfg?.aventura_viva === true &&
  cfg?.mapa_novo === true && cfg?.vila_nova === true && cfg?.herois_novos === true && cfg?.corrida === true && cfg?.on === true,
  JSON.stringify(cfg));

const admCfg = await as(ADM, `select public.admin_cfg_efetiva() x`);
check("aparecem em Ajustes do jogo para o admin",
  !admCfg.error && admCfg.rows[0].x.visual?.tabuleiro_vivo === true && admCfg.rows[0].x.visual?.telas_compactas === true,
  admCfg.error);

const usrAdm = await as(A, `select public.admin_cfg_efetiva() x`);
const usrFn = await as(A, `select public.visual_cfg() x`);
check("jogador comum não chama admin_cfg_efetiva nem visual_cfg direto", !!usrAdm.error && !!usrFn.error);

await sys(`update game_config set config = jsonb_set(jsonb_set(config, '{visual,tabuleiro_vivo}', 'false'), '{visual,telas_compactas}', 'false') where active`);
const vOff = (await sys(`select public.visual_cfg() c`))[0].c;
check("o admin desliga os dois interruptores e os valores ficam guardados",
  vOff.tabuleiro_vivo === false && vOff.telas_compactas === false, JSON.stringify(vOff));

const TITULO = "🎲 Tabuleiro renovado, caminhada ao vivo e telas mais compactas";
const postRows = await sys(`select title, body from posts where title = $1`, [TITULO]);
check("aviso publicado no Jornal uma vez e sem expor porcentagens/chances",
  postRows.length === 1 && !postRows[0].body.includes("%"));

await db.exec(fs.readFileSync(path.join(root, "sql/124_tabuleiro_vivo_e_telas.sql"), "utf8"));
const vAfter = (await sys(`select public.visual_cfg() c`))[0].c;
check("rodar o 124 de novo não repete o aviso nem religa o que o admin desligou",
  (await sys(`select count(*)::int n from posts where title = $1`, [TITULO]))[0].n === 1 &&
  vAfter.tabuleiro_vivo === false && vAfter.telas_compactas === false);

console.log("\nConferência do site (deploy/index.html)");
const indexHtml = fs.readFileSync(path.join(root, "deploy/index.html"), "utf8");
check("NOVIDADES e AJ_LABELS em deploy/index.html têm o mesmo título e os dois controles",
  indexHtml.includes(TITULO) && indexHtml.includes("tabuleiro_vivo:") && indexHtml.includes("telas_compactas:"));
check("nova versão da arte do mapa e funções de caminhada/interação/menu compacto estão presentes",
  indexHtml.includes('MAP_ART_VERSION = "mapa-pintado-7"') &&
  indexHtml.includes("function animateBoardWalk(") &&
  indexHtml.includes("function walkSummaryModal(") &&
  indexHtml.includes("function renderBoardPop(") &&
  indexHtml.includes("function drawForkSigns(") &&
  indexHtml.includes("function drawWalkPreview(") &&
  indexHtml.includes("function menuBadges("));

console.log("\nTabuleiro e caminhada intactos nas regras");
const fork = (await sys(`select id from board_nodes where next_b is not null order by id limit 1`))[0];
const rt = await as(A, `select (public.set_route($1, 'b')).route r`, [fork.id]);
check("escolha de rota em bifurcação continua funcionando igual", !rt.error && rt.rows[0].r?.[String(fork.id)] === "b", rt.error);

const st = await as(A, `select public.today_overview() r`);
const sp = await as(A, `select public.spin_wheel() r`);
const mv = await as(A, `select public.move_today() r`);
check("today_overview, roleta e move_today funcionam normalmente para jogador comum",
  !st.error && !sp.error && !mv.error && mv.rows[0].r.total >= 1 && Array.isArray(mv.rows[0].r.path),
  st.error || sp.error || mv.error);

console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
