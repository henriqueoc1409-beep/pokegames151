// Testa o arquivo 66 (novo fim de temporada) com dados de TESTE:
// o 1º no Castelo encerra a corrida quando a rodada do dia fecha; quem chega no mesmo dia ainda conta;
// a Liga começa com todos os ativos, chaves pela classificação (chegada, depois quem está mais perto do Castelo);
// prêmio do Castelo por posição; depois que a Liga começa, chegar não dá prêmio.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_fim_temporada.mjs ..
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
const P = { A: U(1), B: U(2), C: U(3), D: U(4) };
for (const [n, u] of Object.entries(P)) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: "Jog" + n })]); await as(u, `select public.create_character($1, 'mago')`, ["Jog" + n]); }
const castelo = (await sys(`select id from board_nodes where kind = 'castelo' limit 1`))[0].id;
const at = async d => (await sys(`select id from board_nodes where kind = 'normal' and dist >= $1 order by dist limit 1`, [d]))[0].id;
await sys(`update characters set node = $1, coins = 0 where user_id = $2`, [await at(10), P.B]);
await sys(`update characters set node = $1, coins = 0 where user_id = $2`, [await at(50), P.C]);
await sys(`update characters set node = $1, coins = 0 where user_id = $2`, [await at(5), P.D]);
await sys(`update characters set coins = 0`);
const cid = async u => (await sys(`select id from characters where user_id = $1`, [u]))[0].id;
const arrive = async u => { await sys(`update characters set node = $1 where user_id = $2`, [castelo, u]); return (await sys(`select public.check_arrival($1) m`, [await cid(u)]))[0].m; };
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;

console.log("\nPrimeira chegada");
let m = await arrive(P.A);
check("A chega em 1º e ganha 500", (await coins(P.A)) === 500 && /1º lugar/.test(m) && /meia-noite/.test(m), m);
check("a Liga ainda não começa no mesmo dia (os outros ainda jogam hoje)", (await sys(`select public.league_maybe_start(false) l`))[0].l === null);
m = await arrive(P.B);
check("B chega no mesmo dia: 2º com 300", (await coins(P.B)) === 300 && /2º lugar/.test(m));

console.log("\nRodada fechou: corrida acaba");
await sys(`update characters set arrived_at = arrived_at - interval '1 day' where arrived_rank is not null`);
const lid = (await sys(`select public.league_maybe_start(false) l`))[0].l;
check("a Liga começa sozinha depois que a rodada fecha", !!lid);
const seeds = (await sys(`select user_id, seed from league_players where league_id = $1 order by seed`, [lid])).map(r => r.user_id);
check("todos os ativos entram, na ordem: chegada, depois quem está mais perto", JSON.stringify(seeds) === JSON.stringify([P.A, P.B, P.D, P.C]), JSON.stringify(seeds));
check("o 3º (mais perto do Castelo) ganha o prêmio de 3º: 150", (await coins(P.D)) === 150);
check("o 4º não tem prêmio (só há 3)", (await coins(P.C)) === 0);
check("pódio da temporada: A, B e D", JSON.stringify((await sys(`select user_id from season_results order by rank`)).map(r => r.user_id)) === JSON.stringify([P.A, P.B, P.D]));
check("o Jornal anuncia o fim da corrida", (await sys(`select count(*)::int n from event_log where kind = 'liga' and message like '%A corrida acabou! JogA%'`))[0].n === 1);
check("não começa outra Liga", (await sys(`select public.league_maybe_start(true) l`))[0].l === null);

console.log("\nDepois do fim");
m = await arrive(P.C);
check("quem chega depois não ganha prêmio", (await coins(P.C)) === 0 && /já terminou/.test(m), m);
check("a novidade está no Jornal", (await sys(`select count(*)::int n from posts where title like '🏁 Novo fim de temporada%'`))[0].n === 1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
