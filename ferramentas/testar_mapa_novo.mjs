// Testa o arquivo 68 (mapa com +49 casas guardado para a próxima temporada) com dados de TESTE:
// nada muda ao rodar; na virada da temporada o tabuleiro troca sozinho, todos voltam à largada, pousadas são
// devolvidas, casas especiais e HMs são espalhadas de novo, todo caminho chega ao Castelo, o Jornal anuncia, troca uma vez só.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_mapa_novo.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql" && f < "84").sort()) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
const A = "11111111-1111-1111-1111-111111111111";
await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, 'a@t.l', '{"username":"Ana"}')`, [A]); await as(A, `select public.create_character('Ana', 'mago')`);
const n = async q => (await sys(q))[0].n;

console.log("\nAntes da virada");
check("rodar o arquivo não muda o tabuleiro (443 casas)", (await n(`select count(*)::int n from board_nodes`)) === 443);
check("o mapa novo fica guardado (492 casas)", (await n(`select count(*)::int n from board_next`)) === 492);
check("jogador comum não lê o mapa guardado", !!(await as(A, `select count(*) from board_next`)).error || (await as(A, `select count(*)::int n from board_next`)).rows[0].n === 0);
const meio = (await sys(`select id from board_nodes where kind = 'normal' and dist between 150 and 200 limit 1`))[0].id;
await sys(`update characters set node = $1, coins = 100 where user_id = $2`, [meio, A]);
await sys(`insert into properties(node, owner, price) values ($1, $2, 300)`, [meio, A]);

console.log("\nVirada da temporada");
await sys(`select public.start_new_season()`);
check("o tabuleiro agora tem 492 casas", (await n(`select count(*)::int n from board_nodes`)) === 492);
check("o mapa guardado foi usado (ficou vazio)", (await n(`select count(*)::int n from board_next`)) === 0);
check("a Ana voltou para a largada", (await sys(`select node from characters where user_id = $1`, [A]))[0].node === 0);
check("a pousada foi devolvida com 100% (100 + 300)", (await n(`select count(*)::int n from properties`)) === 0 && (await sys(`select coins from characters where user_id = $1`, [A]))[0].coins === 400);
const kinds = Object.fromEntries((await sys(`select kind, count(*)::int n from board_nodes group by kind`)).map(r => [r.kind, r.n]));
check("casas especiais espalhadas de novo (Mina, Desafio, Ladrão, Fonte, Treinador)", ["mina", "desafio", "ladrao", "fonte", "treinador"].every(k => kinds[k] > 0), JSON.stringify(kinds));
check("obstáculos das HMs espalhados de novo", (await n(`select count(*)::int n from board_nodes where hm is not null`)) > 10);
check("9 bifurcações, 1 largada e 1 Castelo", kinds.bifurcacao === 9 && kinds.inicio === 1 && kinds.castelo === 1);
check("toda casa chega ao Castelo (distância calculada)", (await n(`select count(*)::int n from board_nodes where dist is null`)) === 0 && (await n(`select count(*)::int n from board_nodes where next_a is null and kind <> 'castelo'`)) === 0);
check("o Jornal anuncia o mapa novo", (await n(`select count(*)::int n from posts where title = '🗺️ O mapa cresceu: 492 casas!'`)) === 1);
check("a Ana consegue andar no mapa novo", !(await as(A, `select public.move_today()`)).error);

console.log("\nVirada seguinte");
await sys(`select public.start_new_season()`);
check("na temporada seguinte o mapa fica igual (troca uma vez só)", (await n(`select count(*)::int n from board_nodes`)) === 492 && (await n(`select count(*)::int n from posts where title like '🗺️ O mapa cresceu%'`)) === 1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
