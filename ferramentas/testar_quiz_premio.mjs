// Testa o arquivo 51 (prêmio do Quiz entregue sozinho) com dados de TESTE, como jogadores comuns:
// o admin escolhe o prêmio de verdade, prêmio inválido é recusado, quem chega mais perto recebe na hora
// (conta, bolsa e Correio), o Jornal conta o que ganhou, os outros não recebem, quiz sem prêmio segue como antes.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_quiz_premio.mjs ..
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
const [A, B, ADM] = [U(1), U(2), U(9)];
for (const [u, n] of [[A, "Ana"], [B, "Beto"], [ADM, "Chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'mago')`, [n]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
const create = (who, prize, coins, hints, retries, bag, items) => as(who, `select * from public.admin_quiz_save($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)`,
  ["Quiz", "Valendo!", prize, "Em que ano saiu Pokémon Red?", 1996, 15, 24, coins, hints, retries, JSON.stringify(bag), items]);
const st = async u => (await sys(`select coins, hints, retries, coalesce((select qty from bag_items b where b.user_id = c.user_id and item = 'ultra_ball'), 0) ultra from characters c where user_id = $1`, [u]))[0];

console.log("\nCriar com prêmio");
check("jogador comum não cria quiz", /administrador/.test((await create(A, "200 moedas", 200, 0, 0, {}, [])).error || ""));
check("prêmio inválido é recusado (item que não existe na bolsa)", /inválido/.test((await create(ADM, "x", 0, 0, 0, { bola_magica: 1 }, [])).error || ""));
check("moedas fora do limite são recusadas", /Moedas/.test((await create(ADM, "x", 999999, 0, 0, {}, [])).error || ""));
const q = (await create(ADM, "200 moedas, 1 dica e 2 Ultra Balls", 200, 1, 0, { ultra_ball: 2 }, [])).rows?.[0];
check("admin cria o quiz com prêmio de verdade", q && q.prize_coins === 200 && q.prize_hints === 1 && q.prize_bag.ultra_ball === 2);
check("jogador não lê o quiz direto (o prêmio aparece só pelo texto)", !!(await as(A, `select prize_coins from quizzes`)).error || (await as(A, `select count(*)::int n from quizzes`)).rows[0].n === 0);

console.log("\nVencedor recebe sozinho");
const a0 = await st(A), b0 = await st(B);
await as(A, `select public.quiz_reveal($1)`, [q.id]); await as(A, `select public.quiz_answer($1, 1995)`, [q.id]);
await as(B, `select public.quiz_reveal($1)`, [q.id]); await as(B, `select public.quiz_answer($1, 1980)`, [q.id]);
await as(ADM, `select public.admin_quiz_close($1)`, [q.id]);
const a1 = await st(A), b1 = await st(B);
check("quem chegou mais perto ganha as moedas, a dica e as bolas", a1.coins - a0.coins === 200 && a1.hints - a0.hints === 1 && a1.ultra - a0.ultra === 2, JSON.stringify([a0, a1]));
check("quem perdeu não ganha nada", b1.coins === b0.coins && b1.ultra === b0.ultra);
const g = (await as(A, `select * from gifts`)).rows;
check("o prêmio aparece no Correio do vencedor", g.length === 1 && /Prêmio do Quiz/.test(g[0].message) && g[0].coins === 200, JSON.stringify(g));
check("o Jornal conta o que ele ganhou", (await sys(`select count(*)::int n from event_log where kind = 'quiz' and message like '%venceu o Quiz surpresa "Quiz" e ganhou 200 moedas%'`))[0].n === 1);
check("fica marcado como entregue (não entrega duas vezes)", !!(await sys(`select prize_given_at from quizzes where id = $1`, [q.id]))[0].prize_given_at);
await sys(`select public.quiz_tick($1)`, [q.id]);
check("conferir de novo não paga outra vez", (await st(A)).coins === a1.coins);

console.log("\nQuiz sem prêmio de verdade");
const q2 = (await create(ADM, "Uma surpresa", 0, 0, 0, {}, [])).rows[0];
await as(B, `select public.quiz_reveal($1)`, [q2.id]); await as(B, `select public.quiz_answer($1, 1996)`, [q2.id]);
await as(ADM, `select public.admin_quiz_close($1)`, [q2.id]);
check("sem prêmio escolhido, nada é entregue sozinho (o admin usa \"Dar o prêmio\")", (await as(B, `select count(*)::int n from gifts`)).rows[0].n === 0 && !(await sys(`select prize_given_at from quizzes where id = $1`, [q2.id]))[0].prize_given_at);
check("e o vencedor aparece normalmente", (await sys(`select winner from quizzes where id = $1`, [q2.id]))[0].winner === B);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
