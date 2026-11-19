// Testa o arquivo 127 (Quiz com perguntas de lógica e explicação) com dados de TESTE, como jogadores comuns:
// perguntas novas com explicação e conta certa pelos dados do jogo, absurdas antigas desligadas (não apagadas),
// sorteio só das ligadas e com a explicação, explicação escondida enquanto o quiz está aberto e mostrada no
// resultado, admin cria quiz e cadastra pergunta com explicação, ligar/desligar não apaga a explicação, Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_quiz_logica.mjs ..
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
const U = n => `${n}${n}${n}${n}${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${String(n).repeat(12)}`;
const [A, B, ADM] = [U(1), U(2), U(9)];
for (const [u, n] of [[A, "ana"], [B, "beto"], [ADM, "chefe"]]) await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]);
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
for (const [u, n] of [[A, "Ana"], [B, "Beto"], [ADM, "Chefe"]]) await as(u, `select public.create_character($1, 'mago')`, [n]);

console.log("\n1. Banco de perguntas");
const novas = await sys(`select * from quiz_banco where autor = 'jogo' and explicacao is not null`);
check("mais de 100 perguntas de lógica, todas com explicação e ligadas", novas.length >= 100 && novas.every(b => b.ativo && b.explicacao.length > 10), novas.length);
check("as absurdas antigas foram desligadas, não apagadas", (await sys(`select count(*)::int n from quiz_banco where autor = 'jogo' and explicacao is null and not ativo`))[0].n >= 300
  && !(await sys(`select 1 from quiz_banco where autor = 'jogo' and explicacao is null and ativo`)).length);
const onix = (await sys(`select height_dm from pokemon where name = 'Onix'`))[0].height_dm / 10;
const eiffel = novas.find(b => /Onix empilhados.*Torre Eiffel/.test(b.pergunta));
check("conta certa pelos dados do jogo (Onix × Torre Eiffel)", eiffel && Number(eiffel.resposta) === Math.round(330 / onix) && eiffel.explicacao.includes("330 ÷ 8,8"), JSON.stringify(eiffel));
const snor = (await sys(`select weight_hg from pokemon where name = 'Snorlax'`))[0].weight_hg / 10;
const ele = novas.find(b => /Snorlax juntos pesam o mesmo que um elefante/.test(b.pergunta));
check("conta certa pelos dados do jogo (Snorlax × elefante)", ele && Number(ele.resposta) === Math.round(6000 / snor), JSON.stringify(ele));
const mv = (await sys(`select power from pk_moves where name = 'Hyper Beam'`))[0].power;
const hb = novas.find(b => /Tackle somam o mesmo poder de um único Hyper Beam/.test(b.pergunta));
check("conta certa pelo poder dos golpes do jogo", hb && Number(hb.resposta) === Math.round(mv / 35 * 10) / 10, JSON.stringify(hb));
check("jogador comum não lê o banco", (await as(A, `select count(*)::int n from quiz_banco`)).rows?.[0]?.n === 0);
check("nenhuma pergunta mostra chance ou porcentagem de captura", !novas.some(b => /chance|%|captur/i.test(b.pergunta + b.explicacao)));

console.log("\n2. Sorteio e admin");
let s = (await as(ADM, `select public.admin_quiz_sortear() s`)).rows[0].s;
check("o sorteio traz uma pergunta nova com a explicação", s?.explicacao && novas.some(b => b.pergunta === s.question), JSON.stringify(s));
check("jogador comum não sorteia", !!(await as(A, `select public.admin_quiz_sortear()`)).error);
let r = await as(ADM, `select (public.admin_quiz_banco_save(null, 'Quantos Pikachu cabem num ônibus de 12 m deitados em fila?', 30, true, 'O Pikachu mede 0,4 m. 12 ÷ 0,4 = 30.')).id id`);
const mid = r.rows?.[0]?.id;
check("o admin cadastra pergunta com explicação", mid && (await sys(`select explicacao from quiz_banco where id = $1`, [mid]))[0].explicacao.includes("12 ÷ 0,4"), r.error);
r = await as(ADM, `select public.admin_quiz_banco_save($1, 'Quantos Pikachu cabem num ônibus de 12 m deitados em fila?', 30, false)`, [mid]);
check("desligar não apaga a explicação", !r.error && (await sys(`select ativo, explicacao from quiz_banco where id = $1`, [mid]))[0].explicacao?.includes("12 ÷ 0,4"), r.error);
r = await as(ADM, `select public.admin_quiz_banco_save(null, 'Quantos pastéis o Karneiro come na feira?', 12)`);
check("pergunta sem explicação continua funcionando (chamada antiga)", !r.error, r.error);

console.log("\n3. A explicação só aparece no resultado");
let q = await as(ADM, `select * from public.admin_quiz_save($1, $2, $3, $4, $5, $6, $7, 0, 0, 0, '{}'::jsonb, '{}', $8)`,
  ["Quiz", "", "", "Quantos Onix empilhados alcançam a Torre Eiffel (330 m)?", 38, 20, 24, "O Onix mede 8,8 m. 330 ÷ 8,8 = 37,5 → 38."]);
const ID = q.rows?.[0]?.id;
check("o admin cria o quiz com explicação", ID && q.rows[0].explicacao?.includes("330 ÷ 8,8"), q.error);
await sys(`update quizzes set status = 'aberto', closed_at = null, winner = null where id = $1`, [ID]);
await as(A, `select public.quiz_reveal($1)`, [ID]);
let cur = (await as(A, `select public.quiz_current() q`)).rows[0].q;
check("aberto: o jogador NÃO recebe a explicação nem a resposta", cur.status === "aberto" && cur.explicacao == null && cur.answer == null && !JSON.stringify(cur).includes("330 ÷ 8,8"), JSON.stringify(cur).slice(0, 300));
await as(A, `select public.quiz_answer($1, 36)`, [ID]);
await as(ADM, `select public.admin_quiz_close($1)`, [ID]);
cur = (await as(B, `select public.quiz_current() q`)).rows[0].q;
check("fechado: o resultado traz a resposta e a explicação", cur.status === "encerrado" && Number(cur.answer) === 38 && cur.explicacao?.includes("330 ÷ 8,8"), JSON.stringify(cur).slice(0, 300));
check("o último quiz encerrado também traz a explicação", cur.ultimo?.explicacao?.includes("330 ÷ 8,8"));
q = await as(ADM, `select * from public.admin_quiz_save($1, $2, $3, $4, $5, $6, $7)`, ["Quiz 2", "", "", "Outra pergunta?", 5, 20, 24]);
check("criar quiz sem explicação (chamada antiga) continua valendo", !q.error && q.rows[0].explicacao == null, q.error);

console.log("\n4. Jornal");
check("aviso publicado no Jornal uma vez", (await sys(`select count(*)::int n from posts where title = '🧠 Quiz novo: perguntas de lógica com explicação'`))[0].n === 1);
const html = fs.readFileSync(path.join(root, "deploy/index.html"), "utf8");
check("o site tem a mesma novidade e mostra a explicação no resultado", html.includes('title: "🧠 Quiz novo: perguntas de lógica com explicação"') && html.includes("Como chegar nesse número") && html.includes("_explicacao"));
console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
