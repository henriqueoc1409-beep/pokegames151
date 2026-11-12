// Testa o arquivo 90 (Praça Central): ajustes no game_config, Ajustes do admin e aviso no Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_praca.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql").sort((a, b) => parseInt(a) - parseInt(b) || a.localeCompare(b))) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
const A = "11111111-1111-1111-1111-111111111111", ADM = "99999999-9999-9999-9999-999999999999";
for (const [u, n] of [[A, "Ana"], [ADM, "Chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'mago')`, [n]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);


console.log("Praça Central");
const cfg = (await sys(`select config->'praca' c from game_config where active`))[0].c;
check("os ajustes da Praça estão no game_config, aberta", cfg && cfg.on === true && cfg.envio_seg === 1.5 && cfg.mascote === true && cfg.baloes === true, JSON.stringify(cfg));
let r = await as(ADM, `select public.admin_cfg_efetiva() x`);
check("aparece em Ajustes do jogo para o admin (e o Visual novo continua lá)", !r.error && r.rows[0].x.praca?.on === true && !!r.rows[0].x.visual, r.error);
r = await as(A, `select public.admin_cfg_efetiva() x`);
check("jogador comum não lê os Ajustes", !!r.error);
await sys(`update game_config set config = jsonb_set(config, '{praca,on}', 'false') where active`);
check("o admin fecha a Praça e o valor fica guardado", (await sys(`select public.praca_cfg() c`))[0].c.on === false);
r = await as(A, `select config->'praca'->>'on' o from game_config where active`);
check("o jogador lê a config (o site esconde a Praça)", r.rows?.[0]?.o === "false", r.error);
check("aviso publicado no Jornal uma vez", (await sys(`select count(*)::int n from posts where title = '⛲ Abriu a Praça Central!'`))[0].n === 1);
await db.exec(fs.readFileSync(path.join(root, "sql/90_praca_central.sql"), "utf8"));
check("rodar de novo não repete o aviso nem reabre", (await sys(`select count(*)::int n from posts where title = '⛲ Abriu a Praça Central!'`))[0].n === 1 && (await sys(`select public.praca_cfg() c`))[0].c.on === false);
console.log(`${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
