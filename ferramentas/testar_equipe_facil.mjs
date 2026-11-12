// Testa o arquivo 105 (Minha equipe): o aviso no Jornal sai uma vez e rodar de novo não repete; o jogador comum continua
// montando a equipe pelo mon_team_set (a tela nova salva sozinha com ele).
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_equipe_facil.mjs ..
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


console.log("Minha equipe");
const T = '🐾 Minha equipe: arrumar ficou fácil';
check("aviso publicado no Jornal uma vez", (await sys(`select count(*)::int n from posts where title = $1`, [T]))[0].n === 1);
await db.exec(fs.readFileSync(path.join(root, "sql/105_equipe_facil.sql"), "utf8"));
check("rodar de novo não repete o aviso", (await sys(`select count(*)::int n from posts where title = $1`, [T]))[0].n === 1);
const ids = []; for (const sp of [25, 4, 7]) ids.push((await sys(`select (public.pk_new_monster($1, $2, 5)).id id`, [A, sp]))[0].id);
let r = await as(A, `select public.mon_team_set($1)`, [`{${ids.join(",")}}`]);
check("o jogador monta a equipe numa chamada só (a tela salva na hora)", !r.error && (await sys(`select count(*)::int n from monsters where user_id = $1 and team_slot is not null`, [A]))[0].n === 3, r.error);
r = await as(A, `select public.mon_team_set($1)`, [`{${[ids[2], ids[0], ids[1]].join(",")}}`]);
check("trocar a ordem salva a ordem nova", !r.error && (await sys(`select id from monsters where user_id = $1 and team_slot = 1`, [A]))[0].id === ids[2], r.error);
console.log(`${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
