// Testa o arquivo 38 (Quiz surpresa) com dados de TESTE, como jogadores comuns:
// pergunta escondida até revelar, tempo contado no servidor, uma tentativa, quem chegou mais perto,
// empate pelo horário, fecha quando todos respondem ou no prazo, resultado para todos.
// Uso (na pasta ferramentas, uma vez: npm i @electric-sql/pglite@0.3.15):  node testar_quiz.mjs ..
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
const cur = async u => (await as(u, `select public.quiz_current() q`)).rows?.[0]?.q;
const create = (who, ...a) => as(who, `select * from public.admin_quiz_save($1, $2, $3, $4, $5, $6, $7)`, a);

console.log("\nCriar");
check("jogador comum não cria", /administrador/.test((await create(A, "Quiz", "", "", "Quantos Pokémon?", 151, 15, 24)).error || ""));
const q1 = await create(ADM, "Quiz surpresa!", "Vale um prêmio!", "Aura dourada", "Em que ano saiu Pokémon Red no Japão?", 1996, 15, 24);
check("admin cria", !q1.error, q1.error);
const ID = q1.rows?.[0]?.id;
check("só um quiz aberto por vez", /Já existe/.test((await create(ADM, "Outro", "", "", "Pergunta outra?", 1, 15, 24)).error || ""));
console.log("\nSegredo");
const c0 = await cur(A);
check("jogador vê aviso e prêmio", c0?.title === "Quiz surpresa!" && c0.prize === "Aura dourada" && c0.me === "novo");
check("pergunta escondida antes de revelar", c0?.question == null && c0?.answer == null);
check("não lê as tabelas direto", !!(await as(A, `select * from quizzes`)).error && !!(await as(A, `select * from quiz_entries`)).error);
check("responder sem revelar recusa", /Revele/.test((await as(A, `select public.quiz_answer($1, 1990)`, [ID])).error || ""));
console.log("\nRevelar e responder");
const rv = (await as(A, `select public.quiz_reveal($1) r`, [ID])).rows?.[0]?.r;
check("revelar mostra a pergunta e o tempo", rv?.question?.includes("Pokémon Red") && rv.seconds === 15 && rv.left > 13);
const rv2 = (await as(A, `select public.quiz_reveal($1) r`, [ID])).rows?.[0]?.r;
check("revelar de novo não reinicia o tempo", rv2.left <= rv.left);
check("resposta certa ainda escondida", (await cur(A)).answer == null);
check("responde dentro do tempo", !(await as(A, `select public.quiz_answer($1, 1995)`, [ID])).error);
check("não responde duas vezes", /já respondeu/.test((await as(A, `select public.quiz_answer($1, 1996)`, [ID])).error || ""));
check("não vê o palpite dos outros antes do fim", (await cur(A)).results == null);
// Beto revela e o tempo passa (simulado)
await as(B, `select public.quiz_reveal($1)`, [ID]);
await sys(`update quiz_entries set revealed_at = now() - interval '19 seconds' where user_id = $1`, [B]);
check("depois do tempo (+3 s de folga) recusa", /tempo acabou/.test((await as(B, `select public.quiz_answer($1, 1996)`, [ID])).error || ""));
check("quem perdeu o tempo fica como 'perdeu'", (await cur(B)).me === "perdeu");
await as(C, `select public.quiz_reveal($1)`, [ID]);
await sys(`update quiz_entries set revealed_at = now() - interval '16 seconds' where user_id = $1`, [C]);
check("dentro da folga de 3 s ainda vale", !(await as(C, `select public.quiz_answer($1, 1997)`, [ID])).error);
console.log("\nEncerrar e resultado");
check("todos participaram (Beto deixou o tempo acabar): fecha sozinho", (await cur(A)).status === "encerrado");
await as(ADM, `select public.admin_quiz_close($1)`, [ID]);
const fim = await cur(B);
check("encerrado mostra pergunta e resposta para todos", fim.status === "encerrado" && +fim.answer === 1996 && fim.question);
check("empate (1995 e 1997) fica com quem respondeu antes: Ana", fim.winner === A && fim.results[0].name === "Ana", JSON.stringify(fim.results));
check("lista com os palpites e a diferença", fim.results.length === 2 && +fim.results[1].diff === 1);
check("no Jornal: vencedor anunciado", (await sys(`select count(*)::int n from event_log where kind = 'quiz'`))[0].n === 1);
check("depois de encerrado não revela", /encerrado/.test((await as(B, `select public.quiz_reveal($1)`, [ID])).error || ""));
console.log("\nFecha sozinho");
const q2 = await create(ADM, "Quiz 2", "", "", "Quantas casas tem o tabuleiro?", 443, 10, 24);
const ID2 = q2.rows[0].id;
for (const [u, g] of [[A, 400], [B, 443], [C, 500]]) { await as(u, `select public.quiz_reveal($1)`, [ID2]); await as(u, `select public.quiz_answer($1, $2)`, [ID2, g]); }
const f2 = await cur(C);
check("quando todos os ativos respondem, fecha", f2.status === "encerrado" && f2.winner === B, JSON.stringify(f2).slice(0, 200));
const q3 = await create(ADM, "Quiz 3", "", "", "Pergunta com prazo?", 7, 15, 1);
await sys(`update quizzes set closes_at = now() - interval '1 minute' where id = $1`, [q3.rows[0].id]);
check("no prazo, fecha sozinho (sem vencedor se ninguém respondeu)", (await cur(A)).status === "encerrado" && (await cur(A)).winner === null);
const q4 = await create(ADM, "Quiz 4", "", "", "Quem deixa o tempo acabar conta?", 5, 10, 24);
const ID4 = q4.rows[0].id;
for (const [u, g] of [[A, 4], [B, 6]]) { await as(u, `select public.quiz_reveal($1)`, [ID4]); await as(u, `select public.quiz_answer($1, $2)`, [ID4, g]); }
await as(C, `select public.quiz_reveal($1)`, [ID4]);
check("com alguém ainda dentro do tempo, continua aberto", (await cur(A)).status === "aberto");
await sys(`update quiz_entries set revealed_at = now() - interval '30 seconds' where user_id = $1 and quiz_id = $2`, [C, ID4]);
check("quando o tempo dele acaba, fecha", (await cur(A)).status === "encerrado");
console.log("\nAdmin");
const lst = (await as(ADM, `select public.admin_quiz_list() l`)).rows[0].l;
check("admin vê a lista com todas as respostas", lst.length === 4 && lst.find(x => x.id === ID).entries.length === 3);
check("jogador comum não vê a lista", /administrador/.test((await as(A, `select public.admin_quiz_list()`)).error || ""));
await as(ADM, `select public.admin_quiz_delete($1)`, [q3.rows[0].id]);
check("admin apaga", (await sys(`select count(*)::int n from quizzes`))[0].n === 3);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
