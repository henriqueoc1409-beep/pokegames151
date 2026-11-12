// Testa o arquivo 71 (troca de herói grátis nos primeiros dias da temporada nova) com dados de TESTE, como jogador comum.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_troca_heroi.mjs ..
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
await sys(`update characters set coins = 777, level = 4`);
const est = async () => (await as(A, `select public.heroi_troca_estado() s`)).rows[0].s;
const troca = k => as(A, `select (public.heroi_troca_gratis($1)).class c`, [k]);

console.log("\nFora da temporada nova");
await sys(`update seasons set started_on = public.game_today() - 10 where status = 'ativa'`);
check("temporada antiga: não pode", (await est()).pode === false);
check("e a troca é recusada", /primeiros dias/.test((await troca("guerreiro")).error || ""));

console.log("\nTemporada nova");
await sys(`select public.start_new_season()`);
let st = await est();
check("temporada nova: pode trocar, por 3 dias", st.pode === true && Date.parse(st.ate) - Date.parse(st.started_on) === 2 * 864e5, JSON.stringify(st));
check("o aviso da temporada fala da troca grátis", (await sys(`select count(*)::int n from event_log where kind = 'temporada' and message like '%trocar de herói de graça%'`))[0].n === 1);
check("mesmo herói é recusado", /já é desse herói/.test((await troca("mago")).error || ""));
const r = await troca("pesquisador");
const me = (await sys(`select class, coins, level from characters where user_id = $1`, [A]))[0];
check("troca para Pesquisador de graça, sem perder nada", !r.error && me.class === "pesquisador" && me.coins === 777 && me.level === 4, r.error || JSON.stringify(me));
check("depois de usar, não pode mais", (await est()).pode === false && (await est()).usada === true);
check("a segunda troca grátis é recusada", /já usou/.test((await troca("guerreiro")).error || ""));
check("a troca paga continua funcionando", !(await as(A, `select public.change_class('guerreiro')`)).error && (await sys(`select coins from characters where user_id = $1`, [A]))[0].coins < 777);

console.log("\nPrazo e admin");
await sys(`update characters set troca_gratis_season = null where user_id = $1`, [A]);
await sys(`update seasons set started_on = public.game_today() - 3 where status = 'ativa'`);
check("passados os 3 dias, fecha", (await est()).pode === false);
await sys(`update seasons set started_on = public.game_today() where status = 'ativa'`);
const c = (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c;
check("aparece nos Ajustes do jogo", c.temporada?.troca_heroi_dias === 3 && c.temporada?.troca_heroi_gratis === true, JSON.stringify(c.temporada));
await as(ADM, `select public.admin_set_config($1::jsonb, 'teste')`, [JSON.stringify({ temporada: { troca_heroi_gratis: false, troca_heroi_dias: 3 } })]);
check("o admin pode desligar", (await est()).pode === false);
check("a novidade está no Jornal", (await sys(`select count(*)::int n from posts where title like '🏟️ Festa da Liga%'`))[0].n === 1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
