// Testa o arquivo 91 (heróis no estilo novo): liga/desliga no game_config, Ajustes do admin e aviso no Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_herois_novos.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql").sort()) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
const A = "11111111-1111-1111-1111-111111111111", ADM = "99999999-9999-9999-9999-999999999999";
for (const [u, n] of [[A, "Ana"], [ADM, "Chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'mago')`, [n]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);


console.log("Heróis no estilo novo");
const cfg = (await sys(`select config->'visual' c from game_config where active`))[0].c;
check("o liga/desliga dos heróis novos está no game_config, ligado, e os outros do visual continuam", cfg && cfg.herois_novos === true && cfg.on === true && cfg.chat_fixo === true, JSON.stringify(cfg));
let r = await as(ADM, `select public.admin_cfg_efetiva() x`);
check("aparece em Ajustes do jogo para o admin", !r.error && r.rows[0].x.visual?.herois_novos === true, r.error);
await sys(`update game_config set config = jsonb_set(config, '{visual,herois_novos}', 'false') where active`);
check("o admin volta para o pixel art e o valor fica guardado", (await sys(`select public.visual_cfg() c`))[0].c.herois_novos === false);
r = await as(A, `select config->'visual'->>'herois_novos' o from game_config where active`);
check("o jogador lê a config (o site usa o desenho antigo)", r.rows?.[0]?.o === "false", r.error);
check("aviso publicado no Jornal uma vez", (await sys(`select count(*)::int n from posts where title = '🧙 Os heróis ganharam visual novo!'`))[0].n === 1);
await db.exec(fs.readFileSync(path.join(root, "sql/91_herois_estilo_novo.sql"), "utf8"));
check("rodar de novo não repete o aviso nem religa", (await sys(`select count(*)::int n from posts where title = '🧙 Os heróis ganharam visual novo!'`))[0].n === 1 && (await sys(`select public.visual_cfg() c`))[0].c.herois_novos === false);
console.log(`${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
