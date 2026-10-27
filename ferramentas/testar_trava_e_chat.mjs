// Testa o SQL 15 (e o 14) como jogadores comuns, não admin, com dados de TESTE.
// Uso (na pasta ferramentas, uma vez: npm i @electric-sql/pglite@0.3.15):  node testar_trava_e_chat.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
const exec = async f => { try { await db.exec(fs.readFileSync(f, "utf8")); } catch (e) { console.error("ERRO em", f, e.message); process.exit(1); } };
await exec(path.join(root, "ferramentas/supabase_simulado.sql"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql")).sort()) if (f !== "14_recomecar_do_zero.sql") await exec(path.join(root, "sql", f));
let ok = 0, fail = 0;
const check = (name, cond, extra = "") => { if (cond) { ok++; console.log("  OK  ", name); } else { fail++; console.log("  FALHOU", name, extra); } };
const as = async (uid, sql, params = []) => {
  await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`);
  try { return { rows: (await db.query(sql, params)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); }
};
const sys = async (sql, p = []) => (await db.query(sql, p)).rows;
const U = { ana: "11111111-1111-1111-1111-111111111111", beto: "22222222-2222-2222-2222-222222222222", caio: "33333333-3333-3333-3333-333333333333", duda: "44444444-4444-4444-4444-444444444444" };
for (const [n, id] of Object.entries(U)) await sys(`insert into auth.users(id, email, raw_user_meta_data, email_confirmed_at) values ($1, $2, $3, now())`, [id, `${n}@teste.local`, JSON.stringify({ username: n })]);
for (const [n, id] of Object.entries(U)) { const r = await as(id, `select public.create_character($1, 'guerreiro')`, [n[0].toUpperCase() + n.slice(1)]); if (r.error) { console.log("criar", n, r.error); process.exit(1); } }
// Duda criou o herói há 10 dias e nunca jogou: não é ativa
await sys(`update characters set created_at = now() - interval '10 days' where user_id = $1`, [U.duda]);
await as(U.ana, `select public.today_overview()`);
const answers = (await sys(`select p.name from daily_puzzles dp join pokemon p on p.id = dp.pokemon_id where dp.puzzle_date = public.game_today()`)).map(r => r.name);
console.log("Respostas de hoje (teste):", answers.join(", "));

console.log("\n1) Chat");
let r = await as(U.ana, `select public.chat_send('Bom dia, aventureiros!')`); check("mensagem normal é enviada", !r.error, r.error);
r = await as(U.ana, `select public.chat_send('outra')`); check("2ª mensagem em menos de 3 s é barrada", /Calma/.test(r.error || ""), r.error);
r = await as(U.beto, `select public.chat_send($1)`, [`acho que é ${answers[0].toUpperCase()} hein`]); check("resposta do dia é bloqueada", /spoiler/i.test(r.error || ""), r.error);
r = await as(U.beto, `select public.chat_send($1)`, [answers[1].replace(/[aeiou]/, m => ({ a: "á", e: "é", i: "í", o: "ó", u: "ú" })[m])]); check("resposta com acento também é bloqueada", /spoiler/i.test(r.error || ""), r.error);
r = await as(U.beto, `insert into chat_messages(user_id, name, body) values ('${U.beto}', 'x', 'trapaça') returning id`); check("jogador não grava direto na tabela", !!r.error, r.error);
r = await as(U.caio, `select count(*)::int n from chat_messages`); check("jogador lê o chat", r.rows?.[0]?.n === 1, JSON.stringify(r));
r = await as(U.beto, `select public.chat_delete(1)`); check("jogador comum não apaga mensagens", /administrador/.test(r.error || ""), r.error);

console.log("\n2) Ranking travado");
r = await as(U.ana, `select public.move_today()`); check("Ana anda no dia", !r.error, r.error);
r = await as(U.ana, `select public.round_board() b`); let B = r.rows?.[0]?.b;
check("Ana não vê números dos outros enquanto Beto e Caio não jogaram", B && B.can_see === false && B.players.find(p => p.user_id === U.beto).total === null, r.error || JSON.stringify(B?.can_see));
check("Ana vê os próprios números", B && B.players.find(p => p.user_id === U.ana).total !== null);
check("respostas do dia escondidas", B && B.answers === null);
r = await as(U.ana, `select public.play_detail('${U.beto}')`); check("Ana não abre a jogada do Beto", !!r.error, r.error);
r = await as(U.ana, `select public.day_presence() p`); let P = r.rows?.[0]?.p;
check("presença: travado, Duda não é ativa", P && P.released === false && P.players.find(p => p.user_id === U.duda).active === false && P.players.find(p => p.user_id === U.ana).moved === true, JSON.stringify(P));
check("presença não mostra números", P && !JSON.stringify(P).includes("total") && !JSON.stringify(P).includes("attempts"));
r = await as(U.beto, `select public.move_today()`); check("Beto anda", !r.error, r.error);
r = await as(U.beto, `select public.round_board() b`); B = r.rows?.[0]?.b; check("Beto também não vê (falta o Caio)", B && B.can_see === false);
r = await as(U.caio, `select public.move_today()`); check("Caio anda", !r.error, r.error);
r = await as(U.ana, `select public.round_board() b`); B = r.rows?.[0]?.b;
check("todos os ativos jogaram: Ana vê tudo", B && B.can_see === true && B.players.find(p => p.user_id === U.beto).total !== null && B.answers !== null);
r = await as(U.duda, `select public.round_board() b`); B = r.rows?.[0]?.b; check("Duda (não jogou hoje) continua sem ver", B && B.can_see === false);
r = await as(U.ana, `select public.play_detail('${U.caio}')`); check("Ana abre a jogada do Caio", !r.error, r.error);
r = await as(U.caio, `select public.chat_send($1)`, [`era ${answers[0]}!`]); check("depois de liberado, falar da resposta é permitido", !r.error, r.error);
r = await as(U.ana, `select * from public.mode_stats('semana')`); check("mode_stats continua funcionando", !r.error, r.error);

console.log("\n3) Permissões");
await db.exec(`set role anon;`); let e = null; try { await db.query(`select public.chat_send('oi')`); } catch (x) { e = x.message; } await db.exec("reset role;");
check("visitante sem login não usa o chat", !!e, e);
r = await as(U.ana, `select public.can_view_day(public.game_today())`); check("função interna fechada para o site", !!r.error, r.error);

console.log("\n4) Arquivo 14 (recomeço) com dados");
await exec(path.join(root, "sql/14_recomecar_do_zero.sql"));
const c = await sys(`select count(*)::int n, min(level) mi, max(level) ma, max(coins) mc, max(node) mn from characters`);
check("todos no nível 1, 50 moedas, na largada", c[0].mi === 1 && c[0].ma === 1 && c[0].mc === 50 && c[0].mn === 0, JSON.stringify(c));
check("histórico apagado", (await sys(`select count(*)::int n from daily_moves`))[0].n === 0);
check("temporada 1", (await sys(`select id from seasons`)).map(x => x.id).join() === "1");
r = await as(U.ana, `select public.day_presence() p`); P = r.rows?.[0]?.p;
check("depois do recomeço, todos contam como ativos (inclusive Duda)", P && P.players.every(p => p.active), JSON.stringify(P?.players?.map(p => p.active)));
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
await db.close();
process.exit(fail ? 1 : 0);
