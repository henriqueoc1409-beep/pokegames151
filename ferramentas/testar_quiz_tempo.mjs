// Testa o arquivo 94 (desempate do Quiz pelo tempo gasto) com dados de TESTE, como jogadores comuns:
// empatados na distância, vence quem respondeu mais rápido depois de revelar (mesmo tendo aberto o quiz depois),
// sem empate continua valendo quem chegou mais perto, o tempo aparece no resultado e na lista do admin, aviso no Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_quiz_tempo.mjs ..
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
const U = n => `${n}${n}${n}${n}${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${String(n).repeat(12)}`;
const [A, B, C, ADM] = [U(1), U(2), U(3), U(9)];
for (const [u, n] of [[A, "ana"], [B, "beto"], [C, "caio"], [ADM, "chefe"]]) await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]);
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
for (const [u, n] of [[A, "Ana"], [B, "Beto"], [C, "Caio"], [ADM, "Chefe"]]) await as(u, `select public.create_character($1, 'mago')`, [n]);
const create = (...a) => as(ADM, `select * from public.admin_quiz_save($1, $2, $3, $4, $5, $6, $7)`, a);
// grava a entrada com horários controlados: revelou em t0 (minutos atrás) e respondeu s segundos depois
const entra = (id, u, guess, minAtras, s) => sys(`insert into quiz_entries(quiz_id, user_id, revealed_at, answered_at, guess)
  values ($1, $2, now() - make_interval(mins => $3), now() - make_interval(mins => $3) + make_interval(secs => $4), $5)`, [id, u, minAtras, s, guess]);

console.log("\nDesempate pelo tempo");
let q = await create("Quiz", "", "", "Quantas máscaras de dormir o Hypno tem?", 11, 20, 24);
const ID = q.rows[0].id;
// Ana abriu há 30 min e levou 15 s; Beto abriu há 10 min e levou 4 s; os dois chutaram 7 (diferença 4). Caio chutou 2.
await entra(ID, A, 7, 30, 15); await entra(ID, B, 7, 10, 4); await entra(ID, C, 2, 20, 1);
await as(ADM, `select public.admin_quiz_close($1)`, [ID]);
let w = (await sys(`select winner from quizzes where id = $1`, [ID]))[0].winner;
check("empatados: vence quem gastou menos tempo (Beto, 4 s), mesmo tendo aberto depois", w === B, w);
const cur = (await as(C, `select public.quiz_current() q`)).rows[0].q;
const res = cur?.result || cur?.results || cur?.ranking || Object.values(cur || {}).find(v => Array.isArray(v) && v[0]?.guess != null);
check("o resultado para os jogadores traz o tempo e a ordem certa", Array.isArray(res) && res[0].name === "Beto" && Number(res[0].tempo) === 4 && res[1].name === "Ana" && Number(res[1].tempo) === 15, JSON.stringify(res));
const lst = (await as(ADM, `select public.admin_quiz_list(5) l`)).rows[0].l;
const en = lst.find(x => x.id === ID)?.entries || [];
check("a lista do admin traz o tempo e a mesma ordem", en[0]?.name === "Beto" && Number(en[0].tempo) === 4 && en[1]?.name === "Ana", JSON.stringify(en.slice(0, 2)));

q = await create("Quiz 2", "", "", "Outra?", 11, 20, 24);
const ID2 = q.rows[0].id;
await entra(ID2, A, 10, 5, 19); await entra(ID2, B, 7, 5, 1);   // Ana mais perto, mesmo demorando mais
await as(ADM, `select public.admin_quiz_close($1)`, [ID2]);
w = (await sys(`select winner from quizzes where id = $1`, [ID2]))[0].winner;
check("sem empate continua valendo quem chegou mais perto (Ana)", w === A, w);
check("aviso publicado no Jornal uma vez", (await sys(`select count(*)::int n from posts where title = '⏱️ Quiz: empate agora vai pelo tempo de resposta'`))[0].n === 1);
console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
