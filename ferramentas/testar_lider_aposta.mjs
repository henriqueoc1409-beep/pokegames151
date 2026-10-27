// Testa o arquivo 30 com dados de TESTE, como jogadores comuns:
//  1) aposta da batalha Pokémon reservada ao desafiar (devolve ao recusar/cancelar);
//  2) o líder só enfrenta o melhor da última rodada (Duelos obrigatórios e encontros no mapa).
// Uso (na pasta ferramentas, uma vez: npm i @electric-sql/pglite@0.3.15):  node testar_lider_aposta.mjs ..
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
const id = n => `${n}${n}${n}${n}${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${n.repeat(12)}`;
const ANA = id("1"), BETO = id("2"), CAIO = id("3"), DUDA = id("4");
for (const [u, n] of [[ANA, "ana"], [BETO, "beto"], [CAIO, "caio"], [DUDA, "duda"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1,$2,$3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1,'mago')`, [n[0].toUpperCase() + n.slice(1)]); }
await sys(`update characters set coins = 500`);
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;

console.log("\nAposta da batalha Pokémon reservada ao desafiar");
for (const u of [ANA, BETO]) for (let j = 1; j <= 3; j++) { const m = (await sys(`select (public.pk_new_monster($1, $2, 20)).id`, [u, [1, 4, 7][j - 1]]))[0].id; await sys(`update monsters set team_slot = $2 where id = $1`, [m, j]); }
let b = (await as(ANA, `select (public.battle_challenge($1, 60)).id`, [BETO])).rows[0].id;
check("ao desafiar, as 60 de quem desafia já saem", await coins(ANA) === 440 && await coins(BETO) === 500);
let r = await as(BETO, `select public.battle_respond($1, false)`, [b]); check("recusou: as 60 voltam", !r.error && await coins(ANA) === 500, r.error);
b = (await as(ANA, `select (public.battle_challenge($1, 60)).id`, [BETO])).rows[0].id;
r = await as(ANA, `select public.battle_cancel($1)`, [b]); check("cancelou: as 60 voltam", !r.error && await coins(ANA) === 500, r.error);
await sys(`update characters set coins = 120 where user_id = $1`, [ANA]);
const b1 = (await as(ANA, `select (public.battle_challenge($1, 100)).id`, [BETO])).rows[0].id;
await sys(`update characters set coins = 500 where user_id = $1`, [CAIO]);
for (let j = 1; j <= 3; j++) { const m = (await sys(`select (public.pk_new_monster($1, 25, 20)).id`, [CAIO]))[0].id; await sys(`update monsters set team_slot = $2 where id = $1`, [m, j]); }
r = await as(ANA, `select public.battle_challenge($1, 100)`, [CAIO]); check("não dá para mandar outro convite de 100 com só 20 sobrando", /não tem 100/.test(r.error || ""), r.error);
r = await as(BETO, `select public.battle_respond($1, true)`, [b1]); check("aceitou: só quem aceita paga agora", !r.error && await coins(ANA) === 20 && await coins(BETO) === 400, r.error);
await as(BETO, `select public.battle_act($1, 1, 'forfeit', null)`, [b1]);
check("vencedora leva as 200", await coins(ANA) === 220 && await coins(BETO) === 400, `${await coins(ANA)} / ${await coins(BETO)}`);
await sys(`insert into battles(p1, p2, size, bet, status) values ($1, $2, 3, 50, 'convite')`, [CAIO, BETO]);
const old = (await sys(`select id from battles where p1 = $1 and status = 'convite'`, [CAIO]))[0].id;
r = await as(BETO, `select public.battle_respond($1, true)`, [old]); check("convite antigo (sem reserva) cobra os dois ao aceitar", !r.error && await coins(CAIO) === 450 && await coins(BETO) === 350, r.error);

console.log("\nLíder só enfrenta o melhor da rodada (Duelos)");
// Ana é a líder (mais perto do Castelo); Beto venceu a última rodada
const path3 = (await sys(`select a.id n0, b.id n1, c.id n2 from board_nodes a join board_nodes b on b.id = a.next_a join board_nodes c on c.id = b.next_a
  where a.kind = 'normal' and b.kind = 'normal' and c.kind = 'normal' and a.next_b is null and b.next_b is null order by c.dist limit 1`))[0];
const far = (await sys(`select id from board_nodes where kind = 'normal' order by dist desc limit 1`))[0].id;
await sys(`update characters set node = $1, path = array[$1::int]`, [far]);
await sys(`update characters set node = $1, path = array[$1::int] where user_id = $2`, [path3.n2, ANA]);
await sys(`insert into round_results(d, user_id, rank, attempts, modes_solved) values (public.game_today() - 1, $1, 1, 6, 4), (public.game_today() - 1, $2, 2, 9, 4)`, [BETO, CAIO]);
check("Ana é a líder e Beto o melhor da rodada", (await sys(`select public.leader_id() = $1 a, public.round_champion() = $2 b`, [ANA, BETO])).every(x => x.a && x.b));
await sys(`insert into pokemon_media(pokemon_id, silhouette) select id, 'x' from pokemon where id <= 10 on conflict (pokemon_id) do update set silhouette = 'x'`);
await sys(`update characters set coins = 500`);
r = await as(CAIO, `select public.create_duel($1, 'quiz', 'moedas', 20)`, [ANA]); check("quem não é o melhor da rodada não desafia a líder", /só pode ser desafiado pelo melhor da última rodada \(Beto\)/.test(r.error || ""), r.error);
await sys(`update characters set coins = 5 where user_id = $1`, [ANA]);
r = await as(BETO, `select public.create_duel($1, 'quiz', 'moedas', 20)`, [ANA]); check("não dá para apostar mais do que a líder tem", /só tem 5/.test(r.error || ""), r.error);
await sys(`update characters set coins = 500 where user_id = $1`, [ANA]);
r = await as(BETO, `select public.create_duel($1, 'quiz', 'moedas', 20) id`, [ANA]);
const dz = r.rows?.[0]?.id ? (await sys(`select * from duels where id = $1`, [r.rows[0].id]))[0] : null;
check("o melhor da rodada desafia e o duelo já começa aceito (obrigatório)", dz?.status === "aceito" && dz.pokemon_id && await coins(ANA) === 480 && await coins(BETO) === 480, r.error || JSON.stringify(dz));
r = await as(ANA, `select public.decline_duel($1)`, [dz?.id]); check("a líder não consegue recusar", !!r.error, r.error);
check("o Jornal avisa do duelo obrigatório", (await sys(`select 1 from event_log where message like '%o melhor da rodada, chamou o líder Ana para um duelo obrigatório%'`)).length === 1);
await sys(`update duels set created_at = created_at - interval '2 days'`);
r = await as(CAIO, `select public.create_duel($1, 'sorte', 'moedas', 10)`, [DUDA]); check("duelo entre jogadores comuns continua normal (pendente)", !r.error && (await sys(`select status from duels where challenger = $1`, [CAIO]))[0].status === "pendente", r.error);
await sys(`update round_results set user_id = $1 where rank = 1`, [ANA]);
await sys(`update duels set created_at = created_at - interval '2 days', status = 'concluido'`);
r = await as(BETO, `select public.create_duel($1, 'sorte', 'moedas', 10)`, [ANA]); check("se a líder é a melhor da rodada, ninguém a desafia", /ninguém pode desafiá-la|ninguém pode desafiá-lo/.test(r.error || ""), r.error);
await sys(`update round_results set user_id = $1 where rank = 1`, [BETO]);

console.log("\nLíder só enfrenta o melhor da rodada (encontros no mapa)");
await sys(`update game_config set config = config || '{"roll_min": 2, "roll_max": 2}' where active`);
const moveTo = async (u, node) => sys(`update characters set node = $2, path = array[$2::int], bonus_steps = 0, pending_mud = 0 where user_id = $1`, [u, node]);
const encounter = async (u) => { const r2 = await as(u, `select public.move_today() m`); if (r2.error) return "ERRO " + r2.error; return (r2.rows[0].m.events || []).filter(e => e.t === "duelo").length ? "duelo" : "nada"; };
await moveTo(CAIO, path3.n0);
let e1 = await encounter(CAIO); check("Caio cai na casa da líder: nada acontece", e1 === "nada", e1);
await moveTo(BETO, path3.n0);
e1 = await encounter(BETO); check("Beto (melhor da rodada) cai na casa da líder: duelo", e1 === "duelo", e1);
const ahead = (await sys(`select id from board_nodes where kind = 'normal' and dist < (select dist from board_nodes where id = $1) order by dist limit 1`, [path3.n2]))[0].id;
await moveTo(ANA, ahead); await moveTo(DUDA, path3.n2); await moveTo(CAIO, path3.n0);
await sys(`delete from daily_moves where user_id = $1`, [CAIO]);
e1 = await encounter(CAIO); check("entre jogadores comuns o encontro continua (duelo)", e1 === "duelo", e1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
