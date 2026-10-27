// Testa o arquivo 47 (itens da Red/Blue: poções, curas, Revive, X, TMs e HMs) com dados de TESTE, como jogadores comuns:
// loja, preço pelo admin, HM rara (não vende; baús 1% e treinadores 2%, uma de cada por jogador), ensinar TM/HM,
// usar item na batalha (gasta a vez, limite de 2), atalhos das HMs (+1 casa, 1 por andada), Fly 1 vez por temporada,
// itens nos baús e nos presentes.
// Uso (na pasta ferramentas, uma vez: npm i @electric-sql/pglite@0.3.15):  node testar_itens.mjs ..
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
const ANA = "11111111-1111-1111-1111-111111111111", BETO = "22222222-2222-2222-2222-222222222222", ADM = "99999999-9999-9999-9999-999999999999";
for (const [id, n] of [[ANA, "ana"], [BETO, "beto"], [ADM, "chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1,$2,$3)`, [id, n + "@t.l", JSON.stringify({ username: n })]); await as(id, `select public.create_character($1,'guerreiro')`, [n[0].toUpperCase() + n.slice(1)]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
const mons = {};
for (const u of [ANA, BETO]) { mons[u] = []; for (let j = 1; j <= 3; j++) { const m = (await sys(`select (public.pk_new_monster($1, $2, 20)).id`, [u, [1, 4, 7][j - 1]]))[0].id; await sys(`update monsters set team_slot = $2 where id = $1`, [m, j]); mons[u].push(m); } }
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;
const qty = async (u, it) => (await sys(`select coalesce((select qty from bag_items where user_id = $1 and item = $2), 0) q`, [u, it]))[0].q;
await sys(`update characters set coins = 2000`);

console.log("\nLoja");
let r = await as(ANA, `select public.pk_buy('pocao', 3)`);
check("compra 3 Potions por 20 cada (Red/Blue 300 ÷ 15)", !r.error && await qty(ANA, "pocao") === 3 && await coins(ANA) === 1940, r.error);
r = await as(ANA, `select public.pk_buy('tm01', 1)`); check("TM01 (Mega Punch) custa 200 (3000 ÷ 15)", !r.error && await coins(ANA) === 1740, r.error);
r = await as(ANA, `select public.pk_buy('hm01', 1)`); check("HM é rara: não vende na loja", /não está à venda/.test(r.error || ""), r.error);
await sys(`insert into bag_items(user_id, item, qty) values ($1, 'hm01', 1)`, [ANA]);   // como se tivesse achado num baú
r = await as(ANA, `select public.admin_pk_item_set('pocao', 0)`); check("jogador comum não muda preço", /administrador/.test(r.error || ""), r.error);
r = await as(ADM, `select public.admin_pk_item_set('pocao', 0)`); check("admin tira a Potion da venda (preço 0)", !r.error, r.error);
r = await as(ANA, `select public.pk_buy('pocao', 1)`); check("item com preço 0 não vende", /não está à venda/.test(r.error || ""), r.error);
await as(ADM, `select public.admin_pk_item_set('pocao', 20)`);
check("todos leem o catálogo e quem aprende cada TM", (await as(BETO, `select count(*)::int n from pk_items`)).rows[0].n === 71 && (await as(BETO, `select count(*)::int n from pk_tm_compat`)).rows[0].n > 3000);

console.log("\nEnsinar TM e HM");
const [bulba, charm, squirt] = mons[ANA];
r = await as(ANA, `select public.mon_teach($1, 'tm01', 1)`, [bulba]); check("Bulbasaur não aprende Mega Punch (igual à Red/Blue)", /não consegue aprender/.test(r.error || ""), r.error);
await sys(`update monsters set moves = array[10, 45, 52, 43] where id = $1`, [charm]);
r = await as(ANA, `select public.mon_teach($1, 'tm01', null)`, [charm]); check("com 4 ataques, precisa escolher qual esquecer", /esquecer/.test(r.error || ""), r.error);
r = await as(ANA, `select (public.mon_teach($1, 'tm01', 2)).moves`, [charm]);
check("Charmander aprende Mega Punch no lugar do 2º ataque", !r.error && r.rows[0].moves[1] === 5, r.error);
check("a TM acabou", await qty(ANA, "tm01") === 0);
r = await as(ANA, `select public.mon_teach($1, 'tm01', 1)`, [charm]); check("sem TM na bolsa, não ensina", /não tem/.test(r.error || ""), r.error);
await sys(`update monsters set moves = array[33, 45] where id = $1`, [bulba]);
r = await as(ANA, `select (public.mon_teach($1, 'hm01', null)).moves`, [bulba]); check("Bulbasaur aprende Cut (com espaço, sem esquecer nada)", !r.error && r.rows[0].moves.includes(15), r.error);
r = await as(ANA, `select (public.mon_teach($1, 'hm01', 1)).moves`, [charm]); check("a HM continua: ensina Cut também ao Charmander", !r.error && await qty(ANA, "hm01") === 1, r.error);
r = await as(ANA, `select public.mon_teach($1, 'hm01', 1)`, [bulba]); check("não ensina o que já sabe", /já sabe/.test(r.error || ""), r.error);
r = await as(BETO, `select public.mon_teach($1, 'hm01', 1)`, [bulba]); check("não ensina Pokémon dos outros", /não é seu/.test(r.error || ""), r.error);

console.log("\nItens na batalha");
const b = (await as(ANA, `select (public.battle_challenge($1, 10)).id`, [BETO])).rows[0].id;
await as(BETO, `select public.battle_respond($1, true)`, [b]);
await sys(`update bag_items set qty = 5 where user_id = $1 and item = 'pocao'`, [ANA]);
await sys(`insert into bag_items(user_id, item, qty) values ($1, 'antidoto', 1), ($1, 'reviver', 1), ($1, 'x_ataque', 1)`, [ANA]);
const st = async () => (await sys(`select state, turn, phase, log from battles where id = $1`, [b]))[0];
const act = (u, kind, value, item = null) => as(u, `select public.battle_act($1, (select turn from battles where id = $1), $2, $3, $4)`, [b, kind, value, item]);
r = await act(ANA, "item", 0, "pocao"); check("Potion com a vida cheia é recusada", /já está cheia/.test(r.error || ""), r.error);
r = await act(ANA, "item", 0, "cura_gelo"); check("item que não tem na bolsa é recusado", /não tem/.test(r.error || ""), r.error);
r = await act(ANA, "item", 1, "x_ataque"); check("item X só vale para o Pokémon em campo", /em campo/.test(r.error || ""), r.error);
r = await act(ANA, "item", 1, "reviver"); check("Revive só em Pokémon desmaiado", /desmaiado/.test(r.error || ""), r.error);
await sys(`update battles set state = jsonb_set(jsonb_set(state, '{sides,0,mons,0,hp}', '10'), '{sides,0,mons,0,status}', '"PSN"') where id = $1`, [b]);
r = await act(ANA, "item", 0, "pocao"); check("Ana usa Potion no Pokémon em campo (gasta a vez)", !r.error, r.error);
await act(BETO, "move", 0);
let s = await st(); let lines = s.log.at(-1).lines.map(l => l.txt).join(" | ");
check("o item vem antes do ataque e recupera 20", /Ana usou Potion em Bulbasaur\..*recuperou 20 de vida.*Charmander usou|Ana usou Potion em Bulbasaur\..*recuperou 20 de vida.*usou/.test(lines) && lines.indexOf("Potion") < lines.indexOf(" usou ", lines.indexOf("Potion") + 8), lines);
check("a Potion saiu da bolsa", await qty(ANA, "pocao") === 4);
check("a Ana não atacou nesse turno (o item gastou a vez)", !s.log.at(-1).lines.some(l => l.move && l.side === 0), lines);
r = await act(ANA, "item", 0, "antidoto");
await act(BETO, "move", 0);
s = await st(); lines = s.log.at(-1).lines.map(l => l.txt).join(" | ");
check("Antidote cura o veneno", !r.error && /não está mais envenenado/.test(lines) && s.state.sides[0].mons[0].status === null, r.error || lines);
r = await act(ANA, "item", 0, "pocao"); check("3º item na mesma batalha é recusado (limite 2)", /limite/.test(r.error || ""), r.error);
await sys(`update battles set state = jsonb_set(state, '{sides,0,items}', '1') where id = $1`, [b]);
await sys(`update battles set state = jsonb_set(jsonb_set(state, '{sides,0,mons,2,hp}', '0'), '{sides,0,mons,2,fl}', '{"fainted": true}') where id = $1`, [b]);
const maxhp = (await st()).state.sides[0].mons[2].maxhp;
r = await act(ANA, "item", 2, "reviver");
await act(BETO, "move", 0);
s = await st();
check("Revive traz o Squirtle desmaiado com metade da vida", !r.error && s.state.sides[0].mons[2].hp === Math.max(1, Math.floor(maxhp / 2)) && !s.state.sides[0].mons[2].fl.fainted, r.error || JSON.stringify(s.state.sides[0].mons[2]));
check("ninguém vê o item escolhido pelo outro antes do turno", (await as(BETO, `select count(*)::int n from battle_actions where battle_id = $1 and user_id = $2`, [b, ANA])).rows[0].n === 0);
await act(BETO, "forfeit", null);

console.log("\nAtalhos das HMs no tabuleiro");
const cut = (await sys(`select o.id, o.dist, p.id prev from board_nodes o join board_nodes p on p.next_a = o.id and p.next_b is null
   where o.hm = 'CUT' and p.hm is null and p.kind = 'normal' order by o.id limit 1`))[0];
await sys(`update game_config set config = config || '{"roll_min": 1, "roll_max": 1}' where active`);
const goTo = async (u, node) => { await sys(`update characters set node = $2, path = array[$2::int], bonus_steps = 0, pending_mud = 0, route = '{}' where user_id = $1`, [u, node]); await sys(`delete from daily_moves where user_id = $1`, [u]); };
const move = async u => { await sys(`delete from daily_moves where user_id = $1`, [u]); const x = await as(u, `select public.move_today() m`); return x.error ? { error: x.error } : x.rows[0].m; };
const pathLen = async u => (await sys(`select array_length(path, 1) n from characters where user_id = $1`, [u]))[0].n;
await goTo(ANA, cut.prev); await goTo(BETO, cut.prev);
let m = await move(ANA);
check("com Cut na equipe, a árvore vira atalho: andou 1 + 1 casa", !m.error && await pathLen(ANA) === 3 && (m.events || []).some(e => e.t === "hm" && /Cut/.test(e.msg)), m.error || JSON.stringify(m.events));
m = await move(BETO);
check("sem Cut, anda só a roleta e recebe a dica", !m.error && await pathLen(BETO) === 2 && (m.events || []).some(e => e.t === "hm" && /teria pego um atalho/.test(e.msg)), m.error || JSON.stringify(m.events));
await sys(`update monsters set team_slot = null where id = $1`, [bulba]); await sys(`update monsters set team_slot = null where id = $1`, [charm]);
await goTo(ANA, cut.prev); m = await move(ANA);
check("o Pokémon com Cut precisa estar na equipe", await pathLen(ANA) === 2, JSON.stringify(m.events));
await sys(`update monsters set team_slot = 1 where id = $1`, [bulba]);
const pidgey = (await sys(`select (public.pk_new_monster($1, 16, 20)).id`, [ANA]))[0].id;
await sys(`update monsters set team_slot = 4, moves = array[16] where id = $1`, [pidgey]);
await sys(`insert into bag_items(user_id, item, qty) values ($1, 'hm02', 1)`, [ANA]);
r = await as(ANA, `select public.mon_teach($1, 'hm02', null)`, [pidgey]); check("Pidgey aprende Fly", !r.error, r.error);
const far = (await sys(`select id from board_nodes where kind = 'normal' and next_b is null and dist between 200 and 300 and hm is null order by id limit 1`))[0].id;
await sys(`update board_nodes set hm = null where id in (select id from board_nodes where hm is not null and dist between 150 and 300)`);
await goTo(ANA, far); m = await move(ANA);
check("Fly: o andar ganha +3 casas", !m.error && await pathLen(ANA) === 5 && (m.events || []).some(e => /Fly/.test(e.msg)), m.error || JSON.stringify(m.events));
await goTo(ANA, far); m = await move(ANA);
check("Fly é 1 voo por temporada", await pathLen(ANA) === 2);
await sys(`insert into seasons(started_on) values (current_date)`);
await goTo(ANA, far); m = await move(ANA);
check("na temporada seguinte, voa de novo", await pathLen(ANA) === 5);
// dois obstáculos seguidos: só 1 atalho por andada
await sys(`update game_config set config = config || '{"roll_min": 3, "roll_max": 3}' where active`);
const s1 = (await sys(`select id, next_a from board_nodes where id = $1`, [far]))[0], s2 = (await sys(`select id, next_a from board_nodes where id = $1`, [s1.next_a]))[0];
await sys(`update board_nodes set hm = 'CUT' where id in ($1, $2)`, [s1.next_a, s2.next_a]);
await goTo(ANA, far); m = await move(ANA);
check("dois obstáculos no caminho: só 1 atalho por andada (3 + 1)", await pathLen(ANA) === 5, JSON.stringify(m.events));
await sys(`update board_nodes set hm = null where id in ($1, $2)`, [s1.next_a, s2.next_a]);
await sys(`update game_config set config = config || '{"roll_min": 1, "roll_max": 1}' where active`);
await sys(`update game_config set config = config || '{"itens": {"hm": {"on": false}}}' where active`);
await goTo(ANA, cut.prev); m = await move(ANA);
check("o admin pode desligar os atalhos (itens.hm.on = false)", await pathLen(ANA) === 2);
await sys(`update game_config set config = config - 'itens' where active`);

console.log("\nBaús, Fonte e presentes");
await sys(`update game_config set config = config || '{"itens": {"bau_pct": 100}}' where active`);
const bau = (await sys(`select p.id prev from board_nodes o join board_nodes p on p.next_a = o.id and p.next_b is null where o.kind = 'bau' and p.hm is null and o.hm is null order by o.id limit 1`))[0];
await sys(`update characters set fly_season = (select max(id) from seasons) where user_id = $1`, [ANA]);
const before = (await sys(`select coalesce(sum(qty), 0)::int s from bag_items where user_id = $1`, [ANA]))[0].s;
await goTo(ANA, bau.prev); m = await move(ANA);
check("com chance de 100%, o baú também tem um item", (m.events || []).some(e => e.t === "item") && (await sys(`select coalesce(sum(qty), 0)::int s from bag_items where user_id = $1`, [ANA]))[0].s === before + 1, JSON.stringify(m.events));
await sys(`update game_config set config = config || '{"itens": {"bau_pct": 0}}' where active`);
check("com 0%, não sai nada", (await sys(`select public.item_drop($1, 'bau') x`, [ANA]))[0].x === null);
check("as HMs não entram no sorteio comum dos baús", (await sys(`select count(*)::int n from pk_items where kind = 'hm' and drop_w > 0`))[0].n === 0);
check("HM rara com a chance normal (1%): quase nunca sai", (await sys(`select count(*)::int n from generate_series(1, 300) g, lateral (select public.hm_drop($1, 'bau') x) y where x is not null`, [BETO]))[0].n < 15);
await sys(`delete from bag_items where user_id = $1 and item like 'hm%'`, [BETO]);
await sys(`update game_config set config = config || '{"itens": {"hm_bau_pct": 100, "hm_npc_pct": 100}}' where active`);
const got = [];
for (let k = 0; k < 6; k++) { const x = (await sys(`select public.hm_drop($1, $2) x`, [BETO, k % 2 ? "npc" : "bau"]))[0].x; got.push(x?.item || null); }
check("cada HM sai uma vez só: as 5 diferentes e depois nada", new Set(got.slice(0, 5)).size === 5 && got[5] === null, JSON.stringify(got));
check("achar uma HM sai no Jornal", (await sys(`select count(*)::int n from event_log where kind = 'hm'`))[0].n >= 5);
r = await as(ADM, `select public.admin_gift($1, 'Presente', '{}', 0, 0, 0, '{"hiper_pocao": 2, "tm24": 1}')`, [BETO]);
check("o admin pode dar itens novos de presente", !r.error && await qty(BETO, "hiper_pocao") === 2 && await qty(BETO, "tm24") === 1, r.error);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
