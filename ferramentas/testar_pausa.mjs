// Testa o arquivo 76 (pausar o jogo) com dados de TESTE:
// pausado, o jogador comum não joga e vê o aviso; o admin continua; nada fecha sozinho; despausar volta tudo.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_pausa.mjs ..
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
const pausa = async on => { const c = (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c; return as(ADM, `select public.admin_set_config($1::jsonb, 'teste')`, [JSON.stringify({ pausa: { ...c.pausa, on } })]); };

console.log("\nSem pausa");
check("o arquivo não pausa o banco de teste", (await sys(`select public.jogo_pausado() p`))[0].p === false);
check("a pausa aparece nos Ajustes do jogo, com o aviso", /deliberação dos jogadores/.test((await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c.pausa?.texto || ""));
check("jogador joga normalmente", !(await as(A, `select public.today_overview()`)).error);

console.log("\nPausado");
check("o admin pausa", !(await pausa(true)).error);
const e = await as(A, `select public.move_today()`);
check("o jogador não consegue andar e vê o aviso", /Aguardando deliberação/.test(e.error || ""), e.error);
check("nem adivinhar", /Aguardando deliberação/.test((await as(A, `select public.make_guess('classico', 25)`)).error || ""));
check("o admin continua entrando", !(await as(ADM, `select public.today_overview()`)).error);
await sys(`insert into guess_sessions(user_id, puzzle_date, mode) values ($1, public.game_today() - 2, 'classico') on conflict do nothing`, [A]);
const n0 = (await sys(`select count(*)::int n from round_days`))[0].n;
await sys(`select public.settle()`);
check("nada fecha sozinho durante a pausa", (await sys(`select count(*)::int n from round_days`))[0].n === n0);

console.log("\nDespausado");
await pausa(false);
check("o jogador volta a jogar", !(await as(A, `select public.today_overview()`)).error && !(await as(A, `select public.make_guess('classico', 25)`)).error);
await sys(`select public.settle()`);
check("e o fechamento do dia volta a funcionar", (await sys(`select count(*)::int n from round_days`))[0].n > n0);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
