// Testa o arquivo 53 com dados de TESTE, como jogadores comuns:
// Pokémon selvagens sempre do nível 1 ao 5 (em qualquer casa do tabuleiro) e o jogador "teste" apagado por completo.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_selvagens.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
const sqls = fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql").sort();
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
const U = n => `${n}${n}${n}${n}${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${String(n).repeat(12)}`;
const [A, T, ADM] = [U(1), U(2), U(9)];

await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of sqls.filter(f => f < "53")) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
for (const [u, n] of [[A, "Ana"], [T, "teste"], [ADM, "Chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'mago')`, [n]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
// o "teste" tem coisas espalhadas pelo jogo
await sys(`update game_config set config = jsonb_set(config, '{pk_start_at}', to_jsonb(now() - interval '1 minute')) where active`);
await as(T, `select public.move_today()`); await as(T, `select public.pk_sync()`);
await as(T, `select public.chat_send('oi')`);
check("antes do 53: o \"teste\" tem herói, jogada e encontro", (await sys(`select (select count(*) from characters where user_id = $1) + (select count(*) from daily_moves where user_id = $1) + (select count(*) from encounters where user_id = $1) n`, [T]))[0].n >= 3);

for (const f of sqls.filter(f => f >= "53")) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));

console.log("\nPokémon selvagens do nível 1 ao 5");
const e = (await sys(`select public.pk_cfg()->'encounter' e`))[0].e;
check("configuração: nível 1, sem subir pelo tabuleiro, sorteio de 0 a 4", e.level_min === 1 && e.level_span === 0 && e.level_spread === 4 && e.rarity_weight?.comum === 10, JSON.stringify(e));
const nodes = (await sys(`select id from board_nodes where not coalesce(hidden, false) order by dist nulls last`)).map(r => r.id);
const pick = [nodes[0], nodes[1], nodes[Math.floor(nodes.length / 2)], nodes.at(-2), nodes.at(-1)];
for (let i = 0; i < 60; i++)
  await sys(`insert into daily_moves(user_id, move_date, modes, base_steps, roll, bonus_steps, from_node, to_node, xp_gained, coins_gained)
             values ($1, public.game_today() - 1 - $2::int, '{}', 1, 1, 0, $3, $3, 0, 0)`, [A, i, pick[i % pick.length]]);
const r = await as(A, `select public.pk_sync()`);
check("o jogador comum sincroniza sem erro", !r.error, r.error);
const lv = (await sys(`select level from encounters where user_id = $1`, [A])).map(x => x.level);
check(`60 encontros, do começo ao Castelo, todos entre 1 e 5 (${Math.min(...lv)} a ${Math.max(...lv)})`, lv.length === 60 && lv.every(l => l >= 1 && l <= 5), JSON.stringify(lv));
check("aparecem tanto o nível 1 quanto o 5", lv.includes(1) && lv.includes(5));
check("a chance de captura não mudou (bolas iguais)", (await sys(`select public.pk_cfg()->'capture'->'balls'->'poke'->>'factor' f`))[0].f === "12");

console.log("\nJogador \"teste\" apagado");
check("a conta do \"teste\" sumiu", (await sys(`select count(*)::int n from auth.users where id = $1`, [T]))[0].n === 0);
check("herói, perfil, jogadas, encontros e chat dele também", (await sys(`select (select count(*) from characters where user_id = $1) + (select count(*) from profiles where id = $1) + (select count(*) from daily_moves where user_id = $1) + (select count(*) from encounters where user_id = $1) + (select count(*) from chat_messages where user_id = $1) n`, [T]))[0].n === 0);
check("os outros jogadores continuam", (await sys(`select count(*)::int n from characters where user_id in ($1, $2)`, [A, ADM]))[0].n === 2);
const f53 = fs.readFileSync(path.join(root, "sql", sqls.find(f => f.startsWith("53"))), "utf8");
const bloco = f53.slice(f53.indexOf("do $$"));
await db.exec(bloco);
check("rodar de novo sem o \"teste\" não dá erro e não apaga ninguém", (await sys(`select count(*)::int n from characters`))[0].n === 2);
const X = U(3), Y = U(4);
// herói "Teste" numa conta e usuário "teste" (sem herói) em outra
for (const [u, n, h] of [[X, "outro", "Teste"], [Y, "teste", null]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); if (h) await as(u, `select public.create_character($1, 'mago')`, [h]); }
let err = ""; try { await db.exec(bloco); } catch (e) { err = e.message; }
check("com duas contas chamadas \"teste\", para sem apagar nada", /2 contas/.test(err) && (await sys(`select count(*)::int n from auth.users`))[0].n === 4, err);
await sys(`delete from auth.users where id = $1`, [Y]); await sys(`insert into user_roles(user_id, role) values ($1, 'admin')`, [X]);
err = ""; try { await db.exec(bloco); } catch (e) { err = e.message; }
check("se o \"teste\" for administrador, não apaga", /administrador/.test(err) && (await sys(`select count(*)::int n from auth.users where id = $1`, [X]))[0].n === 1, err);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
