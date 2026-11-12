// Testa o arquivo 65 (Leilão de Pokémon) com dados de TESTE, como jogadores comuns:
// criar com mínimo, 1 a cada 3 dias, lance só a partir do mínimo e acima do atual, reserva e devolução das moedas,
// quem está na frente só paga a diferença, dono não dá lance, últimos 5 min esticam, fim com venda (Pokémon troca de
// dono, sai da equipe/mascote/guerra, vendedor recebe menos 5%), sem lance nada muda, Pokémon apagado cancela e devolve.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_leilao.mjs ..
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
const [A, B, C] = [U(1), U(2), U(3)];
for (const [u, n] of [[A, "Ana"], [B, "Beto"], [C, "Caio"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'mago')`, [n]); }
await sys(`update characters set coins = 1000`);
const newMon = async (u, sp, lv) => (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, sp, lv]))[0].id;
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;
const leilao = async id => (await sys(`select * from leiloes where id = $1`, [id]))[0];
const lance = (u, id, v) => as(u, `select public.leilao_lance($1, $2) x`, [id, v]);
const fim = id => sys(`update leiloes set ends_at = now() - interval '1 second' where id = $1`, [id]);
const pika = await newMon(A, 25, 20), outro = await newMon(A, 16, 5), doB = await newMon(B, 7, 8);
await sys(`update monsters set team_slot = 1 where id = $1`, [pika]);
await sys(`update characters set mascot = jsonb_build_object('id', $1::text, 'species', 25) where user_id = $2`, [pika, A]);

console.log("\nCriar");
check("não põe Pokémon de outro jogador", /Pokémon seu/.test((await as(A, `select public.leilao_criar($1, 50)`, [doB])).error || ""));
check("mínimo abaixo de 10 é recusado", /pelo menos 10/.test((await as(A, `select public.leilao_criar($1, 5)`, [pika])).error || ""));
let r = await as(A, `select public.leilao_criar($1, 100) x`, [pika]);
const L1 = r.rows?.[0].x.id;
check("a Ana põe o Pikachu a partir de 100, por 24 h", !r.error && r.rows[0].x.min_price === 100 && Math.abs(new Date(r.rows[0].x.ends_at) - Date.now() - 864e5) < 6e4, r.error);
check("guarda a foto do Pokémon (ataques e atributos) para todos verem", (await as(C, `select info from leiloes where id = $1`, [L1])).rows[0].info.moves?.length > 0);
check("só 1 leilão a cada 3 dias", /a cada 3 dias/.test((await as(A, `select public.leilao_criar($1, 50)`, [outro])).error || ""));

console.log("\nLances");
check("a dona não dá lance no próprio leilão", /próprio leilão/.test((await lance(A, L1, 200)).error || ""));
check("lance abaixo do mínimo é recusado", /pelo menos 100/.test((await lance(B, L1, 90)).error || ""));
r = await lance(B, L1, 100);
check("o Beto dá 100: as moedas ficam reservadas", !r.error && (await coins(B)) === 900, r.error);
check("o próximo lance precisa ser pelo menos +5", /pelo menos 105/.test((await lance(C, L1, 101)).error || ""));
r = await lance(C, L1, 150);
check("o Caio cobre com 150: o Beto recebe as 100 de volta na hora", !r.error && (await coins(C)) === 850 && (await coins(B)) === 1000);
r = await lance(C, L1, 200);
check("quem já está na frente só paga a diferença", !r.error && (await coins(C)) === 800);
check("sem moedas suficientes, recusa", /tem 1000 moedas/.test((await lance(B, L1, 5000)).error || ""));
await sys(`update leiloes set ends_at = now() + interval '2 minutes' where id = $1`, [L1]);
await lance(B, L1, 250);
check("lance nos últimos 5 minutos estica o leilão", (new Date((await leilao(L1)).ends_at) - Date.now()) > 4.5 * 60000);
check("todos veem os lances", (await as(A, `select count(*)::int n from leilao_lances where leilao_id = $1`, [L1])).rows[0].n === 4);

console.log("\nFim com venda");
const sq = await sys(`insert into war_squads(user_id, role, slot, monster_id) values ($1, 'defesa', 1, $2) returning *`, [A, pika]);
const a0 = await coins(A);
await fim(L1);
const st = (await as(C, `select public.leilao_estado() s`)).rows[0].s;
const l1 = await leilao(L1), m = (await sys(`select * from monsters where id = $1`, [pika]))[0];
check("fechou sozinho ao abrir o leilão: vendido para o Beto por 250", l1.status === "vendido" && l1.top_bidder === B && l1.top_bid === 250 && st.encerrados.some(x => x.id === L1));
check("o Pikachu agora é do Beto, fora da equipe", m.user_id === B && m.team_slot === null);
check("saiu do mascote e da guerra da Ana", !(await sys(`select mascot from characters where user_id = $1`, [A]))[0].mascot && (await sys(`select count(*)::int n from war_squads where monster_id = $1`, [pika]))[0].n === 0);
check("a Ana recebe 250 menos 5% (237)", (await coins(A)) - a0 === 238 || (await coins(A)) - a0 === 237, String((await coins(A)) - a0));
check("o Caio, que foi coberto, ficou com as moedas de volta", (await coins(C)) === 1000);
check("entrou na Pokédex do Beto como capturado", (await sys(`select caught_at from pokedex_entries where user_id = $1 and species_id = 25`, [B]))[0]?.caught_at != null);
check("conta no Jornal", (await sys(`select count(*)::int n from event_log where kind = 'leilao' and message like '%arrematou Pikachu%'`))[0].n === 1);

console.log("\nSem lance e cancelado");
let L2 = (await as(B, `select public.leilao_criar($1, 30) x`, [doB])).rows[0].x.id;
await fim(L2); await as(A, `select public.leilao_estado()`);
check("sem lance: o Pokémon continua com o dono", (await leilao(L2)).status === "sem_lance" && (await sys(`select user_id from monsters where id = $1`, [doB]))[0].user_id === B);
await sys(`update leiloes set created_at = created_at - interval '4 days' where seller = $1`, [A]);
const L3 = (await as(A, `select public.leilao_criar($1, 20) x`, [outro])).rows[0].x.id;
await lance(C, L3, 40); const c0 = await coins(C);
await as(A, `select public.mon_release($1)`, [outro]);
check("se o dono solta o Pokémon, o leilão cancela e devolve o lance", (await leilao(L3)).status === "cancelado" && (await coins(C)) === c0 + 40);
check("a novidade está no Jornal", (await sys(`select count(*)::int n from posts where title = '🔨 Novo: Leilão de Pokémon'`))[0].n === 1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
