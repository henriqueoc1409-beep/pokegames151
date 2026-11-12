// Testa o arquivo 86 (quiz automático com perguntas absurdas) com dados de TESTE, como jogadores comuns.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_quiz_auto.mjs ..
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
const total = (await sys(`select count(*)::int n from quiz_banco`))[0].n;

console.log("\nBanco de perguntas");
check("o banco vem com perguntas absurdas (mais de 300)", total >= 300, total);
check("tem a do sushi do Snorlax", (await sys(`select resposta from quiz_banco where pergunta ilike '%sushi o Snorlax%'`))[0]?.resposta == 47);
let r = await as(A, `select count(*)::int n from quiz_banco`);
check("jogador não consegue ler as perguntas e respostas", !!r.error || r.rows[0].n === 0, JSON.stringify(r));
check("o admin consegue", (await as(ADM, `select count(*)::int n from quiz_banco`)).rows[0].n === total);

console.log("\nSortear");
check("jogador não sorteia", !!(await as(A, `select public.admin_quiz_sortear()`)).error);
const s1 = (await as(ADM, `select public.admin_quiz_sortear() s`)).rows[0].s;
check("o admin sorteia pergunta, resposta e prêmio com texto", s1.question && s1.answer != null && s1.prize_txt && s1.seconds === 20, JSON.stringify(s1));
const vistos = new Set([s1.id]);
for (let i = 1; i < total; i++) vistos.add((await as(ADM, `select public.admin_quiz_sortear() s`)).rows[0].s.id);
check("não repete até todas as perguntas saírem", vistos.size === total, `${vistos.size} de ${total}`);
const txt = async p => (await sys(`select public.quiz_premio_txt($1::jsonb) t`, [JSON.stringify(p)]))[0].t;
check("texto do prêmio: '1 dica e 100 moedas' / '3 Great Balls'", (await txt({ hints: 1, coins: 100 })) === "100 moedas e 1 dica" && (await txt({ bag: { great_ball: 3 } })) === "3 Great Balls", JSON.stringify([await txt({ hints: 1, coins: 100 }), await txt({ bag: { great_ball: 3 } })]));

console.log("\nCadastrar as minhas");
r = await as(ADM, `select (public.admin_quiz_banco_save(null, 'Quantos pastéis o Karneiro come na feira?', 12)).id id`);
const mid = r.rows?.[0]?.id;
check("o admin cadastra uma pergunta dele", !r.error && mid, r.error);
check("pergunta repetida não entra", /já está no banco/.test((await as(ADM, `select public.admin_quiz_banco_save(null, 'Quantos pastéis o Karneiro come na feira?', 3)`)).error || ""));
r = await as(ADM, `select public.admin_quiz_banco_save($1, 'Quantos pastéis o Karneiro come na feira de domingo?', 15, false)`, [mid]);
check("e muda (e desliga)", !r.error && (await sys(`select ativo, resposta from quiz_banco where id = $1`, [mid]))[0].ativo === false, r.error);
check("e apaga", !(await as(ADM, `select public.admin_quiz_banco_delete($1)`, [mid])).error && !(await sys(`select 1 from quiz_banco where id = $1`, [mid])).length);

console.log("\nQuiz automático");
await as(A, `select public.quiz_current()`);
check("nos bancos de teste ele não abre sozinho", !(await sys(`select 1 from quizzes`)).length);
await sys(`create table if not exists public.sql_aplicados(arquivo text primary key)`);
const hr = (await sys(`select extract(hour from now() at time zone 'America/Sao_Paulo')::int h`))[0].h;
if (hr >= 1) {
  await sys(`update game_config set config = jsonb_set(config, '{quiz_auto}', config->'quiz_auto' || jsonb_build_object('dias', '[0,1,2,3,4,5,6]'::jsonb, 'hora_min', $1::int, 'hora_max', $1::int + 1)) where active`, [hr - 1]);
  await as(A, `select public.quiz_current()`);
  const q = (await sys(`select * from quizzes`));
  check("na hora marcada, abre sozinho um quiz com pergunta do banco e prêmio", q.length === 1 && q[0].auto && q[0].question && (q[0].prize_coins + q[0].prize_hints + q[0].prize_retries > 0 || Object.keys(q[0].prize_bag).length > 0), JSON.stringify(q[0]));
  await as(A, `select public.quiz_current()`);
  check("e só um por dia", (await sys(`select count(*)::int n from quizzes`))[0].n === 1);
  const cur = (await as(A, `select public.quiz_current() c`)).rows[0].c;
  check("o jogador vê o aviso e o prêmio (sem a resposta)", cur?.status === "aberto" && cur.prize && cur.answer == null, JSON.stringify(cur));
  await sys(`update quizzes set status = 'encerrado', created_at = now() - interval '2 days' where true`);
  await sys(`update game_config set config = jsonb_set(config, '{quiz_auto,dias}', '[]') where active`);
  await as(A, `select public.quiz_current()`);
  check("fora dos dias marcados não abre", (await sys(`select count(*)::int n from quizzes where status = 'aberto'`))[0].n === 0);
} else { for (let i = 0; i < 4; i++) check("(meia-noite: teste de horário pulado)", true); }

console.log("\nAdmin");
const qa = (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c.quiz_auto;
check("o quiz automático aparece nos Ajustes do jogo", qa?.premios?.length === 5 && Array.isArray(qa?.dias));
check("o aviso sai no Jornal", (await sys(`select count(*)::int n from posts where title = '❓ Quiz surpresa automático!'`))[0].n === 1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
