// Testa o arquivo 84 (pousadas: passou, pagou; pousada continua na temporada seguinte) com dados de TESTE, como jogadores comuns.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_pousada.mjs ..
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
const A = "11111111-1111-1111-1111-111111111111", B = "22222222-2222-2222-2222-222222222222", C = "33333333-3333-3333-3333-333333333333", ADM = "99999999-9999-9999-9999-999999999999";
for (const [u, n] of [[A, "Ana"], [B, "Bia"], [C, "Caio"], [ADM, "Chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'guerreiro')`, [n]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
await sys(`update characters set coins = 2000, level = 6 where true`);
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;
// casa comum do tronco, com outra casa comum antes dela, longe do início
const N = (await sys(`select b.id, a.id prev from board_nodes b join board_nodes a on a.next_a = b.id and a.next_b is null
  where b.kind = 'normal' and a.kind = 'normal' and b.dist between 60 and 200 order by b.id limit 1`))[0];
let r = await as(A, `select public.buy_property($1)`, [N.id]);
check("Ana compra a pousada", !r.error, r.error);
const toll = Math.max(15, Math.ceil(600 * 10 / 100));

console.log("\nPassou, pagou");
await sys(`update characters set node = $1, path = array[$1::int], route = '{}'::jsonb, bonus_steps = 6 where user_id = $2`, [N.prev, B]);
let a0 = await coins(A), b0 = await coins(B);
r = await as(B, `select public.move_today() r`);
const evB = r.rows?.[0]?.r?.events || [];
check("Bia passa pela pousada sem parar e paga o pedágio", !r.error && evB.filter(e => e.t === "pousada").length === 1 && (await coins(A)) - a0 === toll, r.error || JSON.stringify(evB));
check("e não paga duas vezes na mesma andada", evB.filter(e => e.t === "pousada").length === 1);

console.log("\nCom a regra antiga (só quem para)");
await sys(`update game_config set config = jsonb_set(config, '{property_pedagio_passou}', 'false') where active`);
await sys(`update characters set node = $1, path = array[$1::int], route = '{}'::jsonb, bonus_steps = 6 where user_id = $2`, [N.prev, C]);
a0 = await coins(A);
r = await as(C, `select public.move_today() r`);
check("desligado no admin: quem só passa não paga", !r.error && (await coins(A)) === a0, r.error);
await sys(`update game_config set config = jsonb_set(config, '{property_pedagio_passou}', 'true') where active`);

console.log("\nTemporada seguinte com mapa novo");
const outra = (await sys(`select id from board_nodes where kind = 'normal' and id <> $1 and dist between 60 and 200 order by id desc limit 1`, [N.id]))[0].id;
r = await as(A, `select public.buy_property($1)`, [outra]);
await sys(`delete from board_next where true`);
await sys(`insert into board_next (id, x, y, kind, value, region, branch, next_a, next_b, dist) select id, x, y, kind, value, region, branch, next_a, next_b, dist from board_nodes`);
await sys(`update board_next set kind = 'bau' where id = $1`, [outra]);
a0 = await coins(A);
await sys(`select public.board_swap()`);
check("a pousada continua com a Ana no mapa novo", (await sys(`select owner from properties where node = $1`, [N.id]))[0]?.owner === A);
check("e a casa dela continua comum", (await sys(`select kind from board_nodes where id = $1`, [N.id]))[0].kind === "normal");
check("a pousada que ficou numa casa que mudou volta com 100% do valor", !(await sys(`select 1 from properties where node = $1`, [outra])).length && (await coins(A)) - a0 === 600, (await coins(A)) - a0);
check("o aviso sai no Jornal", (await sys(`select count(*)::int n from posts where title = '🏠 Pousadas: passou, pagou!'`))[0].n === 1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
