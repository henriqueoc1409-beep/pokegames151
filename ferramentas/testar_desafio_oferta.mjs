// Testa o arquivo 107 (desafio na Aventura com escolha) com dados de TESTE, como jogadores comuns: 1 desafio por dia,
// o desafio não cria batalha sozinho, quem foi desafiado luta ou oferece moedas (guardadas), quem desafiou aceita (sem
// batalha, recebe as moedas) ou recusa (moedas voltam e a batalha começa), prazo de 24 h devolve, só os donos respondem, Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_desafio_oferta.mjs ..
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
const U = i => `${i}${i}${i}${i}${i}${i}${i}${i}-${i}${i}${i}${i}-${i}${i}${i}${i}-${i}${i}${i}${i}-${String(i).repeat(12)}`;
const nomes = ["Ana", "Beto", "Caio", "Duda"], J = nomes.map((_, i) => U(i + 1));
for (const [k, n] of nomes.entries()) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [J[k], n + "@t.l", JSON.stringify({ username: n })]); await as(J[k], `select public.create_character($1, 'mago')`, [n]); }
await sys(`update monsters set team_slot = null where true`);
for (const u of J) for (let s = 1; s <= 3; s++) { const id = (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, [25, 4, 7][s - 1], 10]))[0].id; await sys(`update monsters set team_slot = $2 where id = $1`, [id, s]); }
await sys(`update characters set coins = 500 where true`);
const [A, B, C, D] = J;
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;
const batalhas = async () => (await sys(`select count(*)::int n from battles where state->>'rpg_pvp' = 'true'`))[0].n;
const pend = async u => (await as(u, `select public.rpg_pvp_pendentes() p`)).rows[0].p;

console.log("\nDesafiar");
let r = await as(A, `select public.rpg_desafiar($1, 'bosque') r`, [B]);
check("o desafio vira um convite, sem batalha", !r.error && r.rows[0].r.id && await batalhas() === 0, r.error);
const d1 = r.rows[0].r.id;
check("quem foi desafiado vê o desafio", (await pend(B)).recebidos.length === 1 && (await pend(B)).recebidos[0].nome === "Ana");
check("só 1 desafio por dia", /desafio de hoje/.test((await as(A, `select public.rpg_desafiar($1)`, [C])).error || ""));
check("o mesmo par não tem outro desafio no dia", /já tiveram um desafio/.test((await as(B, `select public.rpg_desafiar($1)`, [A])).error || ""));
check("quem desafiou não responde por quem foi desafiado", !!(await as(A, `select public.rpg_desafio_responder($1, true)`, [d1])).error);

console.log("\nOferecer moedas");
check("oferta maior que as moedas que tem é recusada", /só tem 500/.test((await as(B, `select public.rpg_desafio_responder($1, false, 900)`, [d1])).error || ""));
r = await as(B, `select public.rpg_desafio_responder($1, false, 120)`, [d1]);
check("a oferta guarda as moedas de quem ofereceu", !r.error && await coins(B) === 380, r.error);
check("quem desafiou vê a oferta", (await pend(A)).ofertas[0]?.moedas === 120);
check("só quem desafiou decide", !!(await as(B, `select public.rpg_desafio_decidir($1, true)`, [d1])).error);
r = await as(A, `select public.rpg_desafio_decidir($1, true)`, [d1]);
check("aceitou: recebe as moedas e não tem batalha", !r.error && await coins(A) === 620 && await coins(B) === 380 && await batalhas() === 0, r.error);
check("o Jornal do dia conta", (await sys(`select count(*)::int n from event_log where message like '%pagou 120 moedas%'`))[0].n === 1);

console.log("\nRecusar a oferta e lutar");
r = await as(C, `select public.rpg_desafiar($1) r`, [D]); const d2 = r.rows[0].r.id;
await as(D, `select public.rpg_desafio_responder($1, false, 50)`, [d2]);
r = await as(C, `select public.rpg_desafio_decidir($1, false) r`, [d2]);
check("recusou: as moedas voltam e a batalha começa", !r.error && r.rows[0].r.battle && await coins(D) === 500 && await batalhas() === 1, r.error);
check("a batalha é a de sempre (3 contra 3, sem moedas)", (await sys(`select bet, status from battles where id = $1`, [r.rows[0].r.battle]))[0].status === "ativa");
await sys(`update battles set status = 'encerrada' where true`);
await sys(`update rpg_pvp_desafios set dia = dia - 1 where true`);
r = await as(B, `select public.rpg_desafiar($1) r`, [C]); const d3 = r.rows[0].r.id;
r = await as(C, `select public.rpg_desafio_responder($1, true) r`, [d3]);
check("quem foi desafiado pode escolher lutar na hora", !r.error && r.rows[0].r.battle && await batalhas() === 2, r.error);

console.log("\nPrazo");
await sys(`update battles set status = 'encerrada' where true`);
r = await as(D, `select public.rpg_desafiar($1) r`, [A]); const d4 = r.rows[0].r.id;
await as(A, `select public.rpg_desafio_responder($1, false, 40)`, [d4]);
const a0 = await coins(A);
await sys(`update rpg_pvp_desafios set criado = now() - interval '25 hours' where id = $1`, [d4]);
const p = await pend(A);
check("sem resposta em 24 h: some sem batalha e a oferta volta", (await sys(`select status from rpg_pvp_desafios where id = $1`, [d4]))[0].status === "expirou" && await coins(A) === a0 + 40 && p.esperando.length === 0);
check("decidir depois do prazo não vale", !!(await as(D, `select public.rpg_desafio_decidir($1, true)`, [d4])).error);
const aj = (await sys(`select config c from game_config where active`))[0].c.rpg.pvp;
check("1 desafio por dia e o prazo ficam em Ajustes do jogo", aj.desafia_dia === 1 && aj.prazo_horas === 24);
check("aviso publicado no Jornal uma vez", (await sys(`select count(*)::int n from posts where title = '⚔️ Aventura: desafio com escolha'`))[0].n === 1);
console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
