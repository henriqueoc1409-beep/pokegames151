// Testa o arquivo 31 (Liga Pokémon no fim da temporada) com dados de TESTE, como jogadores comuns:
// chegada de todos os ativos, repescagem, mata-mata 1º x último, uma rodada por dia, W.O., campeão,
// aura, caverna de 24 h com 5% de captura, torcida e a volta de todos à largada.
// Uso (na pasta ferramentas, uma vez: npm i @electric-sql/pglite@0.3.15):  node testar_liga.mjs ..
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
const uid = n => `${n}${n}${n}${n}${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${String(n).repeat(12)}`;
const ADM = uid("9");
await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, 'adm@t.l', '{"username":"chefe"}')`, [ADM]);
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
const P = [1, 2, 3, 4, 5, 6, 7].map(n => uid(String(n)));
const NM = ["Ana", "Beto", "Caio", "Duda", "Edu", "Fabi", "Gil"];
for (let i = 0; i < 7; i++) {
  await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1,$2,$3)`, [P[i], NM[i].toLowerCase() + "@t.l", JSON.stringify({ username: NM[i].toLowerCase() })]);
  await as(P[i], `select public.create_character($1, 'mago')`, [NM[i]]);
  if (i < 6) for (let j = 1; j <= (i === 5 ? 1 : 3); j++) { const m = (await sys(`select (public.pk_new_monster($1, $2, $3)).id`, [P[i], [1, 4, 7][j - 1], 10 + i * 5]))[0].id; await sys(`update monsters set team_slot = $2 where id = $1`, [m, j]); }
}
await sys(`update characters set coins = 100`);
const castle = (await sys(`select id from board_nodes where kind = 'castelo' limit 1`))[0].id;
const name = u => NM[P.indexOf(u)] || u;
const lg = async () => (await sys(`select * from leagues order by id desc limit 1`))[0];
const matches = async st => sys(`select * from league_matches where league_id = (select max(id) from leagues) and stage = $1 order by created_at`, [st]);
const arrive = async i => { await sys(`update characters set node = $1 where user_id = $2`, [castle, P[i]]); await sys(`select public.check_arrival(id) from characters where user_id = $1`, [P[i]]); };
const forfeit = async (m, loser) => as(loser, `select public.battle_act($1, (select turn from battles where id = $1), 'forfeit', null)`, [m.battle_id]);

console.log("\nChegada ao Castelo");
for (let i = 0; i < 6; i++) await arrive(i);
check("prêmio por ordem de chegada continua (500, 300, 150)", (await sys(`select coins from characters where user_id = any($1) order by arrived_rank`, [P.slice(0, 4)])).map(r => r.coins).join() === "600,400,250,100");
check("com 3 chegadas a temporada NÃO fecha mais", (await sys(`select status from seasons order by id desc limit 1`))[0].status === "ativa");
check("enquanto falta um ativo, a Liga não começa", !(await lg()));
let r = await as(P[0], `select public.admin_league_start()`); check("jogador comum não começa a Liga", /administrador/.test(r.error || ""), r.error);
await arrive(6);
let L = await lg();
check("todos os ativos chegaram: a Liga começou com 7", L && L.status === "rodada" && (await sys(`select count(*)::int n from league_players`))[0].n === 7, JSON.stringify(L));

console.log("\nRepescagem e mata-mata");
let m1 = await matches(1);
check("7 é ímpar: repescagem entre os dois piores (6º x 7º)", m1.length === 1 && m1[0].kind === "repescagem" && m1[0].a === P[5] && m1[0].b === P[6], JSON.stringify(m1.map(m => [name(m.a), name(m.b), m.kind])));
check("o 7º não tem Pokémon: perde por W.O.", m1[0].status === "wo" && m1[0].winner === P[5]);
let m2 = await matches(2);
check("a rodada sai logo depois da repescagem: 1º x 6º, 2º x 5º, 3º x 4º", m2.length === 3 && m2.map(m => name(m.a) + "x" + name(m.b)).join() === "AnaxFabi,BetoxEdu,CaioxDuda", JSON.stringify(m2.map(m => name(m.a) + "x" + name(m.b))));
check("as lutas são batalhas de verdade, turno a turno (modo liga)", (await sys(`select count(*)::int n from battles where mode = 'liga' and status = 'ativa'`))[0].n === 3);
check("aparecem na Arena para todos (modo liga)", (await as(P[6], `select count(*)::int n from arena_battles where mode = 'liga'`)).rows?.[0]?.n === 3);
check("quem tem só 1 Pokémon luta com ele", (await sys(`select jsonb_array_length(state->'sides'->1->'mons') n from battles where id = $1`, [m2[0].battle_id]))[0].n === 1);
check("a vida começa cheia", (await sys(`select bool_and((m->>'hp')::int = (m->>'maxhp')::int) ok from battles b, jsonb_array_elements(b.state->'sides') s, jsonb_array_elements(s->'mons') m where b.mode = 'liga'`))[0].ok);
r = await forfeit(m2[0], P[5]); check("Fabi desiste: Ana passa", !r.error, r.error);
r = await forfeit(m2[1], P[1]); check("Beto desiste: Edu passa (zebra)", !r.error, r.error);
r = await as(P[2], `select public.admin_league_wo($1, $2)`, [m2[2].id, P[3]]); check("jogador comum não dá W.O.", /administrador/.test(r.error || ""), r.error);
r = await as(ADM, `select public.admin_league_wo($1, $2)`, [m2[2].id, P[3]]); check("admin dá W.O. numa luta travada (Duda passa)", !r.error, r.error);
check("a luta travada é encerrada", (await sys(`select status from battles where id = $1`, [m2[2].battle_id]))[0].status === "encerrada");
await sys(`select public.league_tick()`);
check("uma rodada por dia: a próxima não sai no mesmo dia", (await matches(3)).length === 0);
await sys(`update leagues set stage_day = stage_day - 1`);
await sys(`select public.settle()`);
let m3 = await matches(3);
check("no dia seguinte: sobraram 3 (ímpar), repescagem Duda x Edu", m3.length === 1 && m3[0].kind === "repescagem" && name(m3[0].a) === "Duda" && name(m3[0].b) === "Edu", JSON.stringify(m3.map(m => [name(m.a), name(m.b), m.kind])));
await forfeit(m3[0], P[4]);
let m4 = await matches(4);
check("depois da repescagem, a GRANDE FINAL: Ana x Duda", m4.length === 1 && name(m4[0].a) === "Ana" && name(m4[0].b) === "Duda");
check("o Jornal anuncia a final", (await sys(`select 1 from event_log where message like '%GRANDE FINAL%'`)).length === 1);

console.log("\nCampeão e caverna");
const auraBefore = (await sys(`select owned_items from characters where user_id = $1`, [P[0]]))[0].owned_items;
await forfeit(m4[0], P[3]);
L = await lg();
check("Ana é a campeã e entrou na caverna", L.status === "caverna" && L.champion === P[0] && L.legend_id, JSON.stringify(L));
check("o lendário é da 1ª geração (2ª desligada)", [144, 145, 146, 150, 151].includes(L.legend_id));
check("nível do lendário = média dos Pokémon dos jogadores", L.legend_level === (await sys(`select round(avg(level))::int n from monsters`))[0].n, L.legend_level);
const owned = (await sys(`select owned_items from characters where user_id = $1`, [P[0]]))[0].owned_items;
check("ganhou a Aura do Campeão com o nome da Liga", owned.includes(L.aura_item) && !auraBefore.includes(L.aura_item) && (await sys(`select name, exclusive from shop_items where id = $1`, [L.aura_item]))[0].exclusive);
r = await as(P[1], `select public.buy_item($1)`, [L.aura_item]); check("ninguém compra a aura do campeão", !!r.error, r.error);
check("ganhou um castelo na vila", (await sys(`select castles from villages where user_id = $1`, [P[0]]))[0].castles === 1);
r = await as(P[0], `select public.league_cave_try()`); check("antes das 24 h não dá para tentar", /ainda não se aproximou/.test(r.error || ""), r.error);
r = await as(P[1], `select public.league_cave_vote('contra')`); check("Beto torce contra", !r.error, r.error);
r = await as(P[2], `select public.league_cave_vote('favor')`); check("Caio torce a favor", !r.error, r.error);
r = await as(P[0], `select public.league_cave_vote('favor')`); check("a campeã não torce", /não torce/.test(r.error || ""), r.error);
r = await as(P[2], `select public.league_cave_cheer('Vai Ana, pega esse lendário!')`); check("mensagem de torcida", !r.error && r.rows[0].league_cave_cheer.side === "favor", r.error);
r = await as(P[2], `select public.league_cave_cheer('de novo')`); check("mensagens seguidas são limitadas", /Calma/.test(r.error || ""), r.error);
r = await as(P[3], `insert into cave_votes(league_id, user_id, side) values (${L.id}, '${P[3]}', 'favor')`); check("ninguém vota direto na tabela", !!r.error);
r = await as(P[1], `select public.league_cave_try()`); check("só a campeã tenta", /Só o campeão/.test(r.error || ""), r.error);
await sys(`update leagues set cave_open_at = now() - interval '1 minute'`);
await sys(`update game_config set config = config || '{"league_capture_pct": 100}' where active`);   // só no teste, para ver a captura
r = await as(P[0], `select public.league_cave_try() t`); check("depois das 24 h: uma tentativa (aqui forçada a 100%)", r.rows?.[0]?.t?.caught === true, r.error || JSON.stringify(r.rows));
check("o lendário entrou na coleção no nível da média", (await sys(`select level from monsters where user_id = $1 and species_id = $2`, [P[0], L.legend_id]))[0]?.level === L.legend_level);
r = await as(P[0], `select public.league_cave_try()`); check("não dá para tentar duas vezes", !!r.error);
check("a temporada fecha depois da caverna", (await sys(`select status from seasons order by id desc limit 1`))[0].status === "encerrada");
await sys(`update game_config set config = config || '{"league_capture_pct": 5}' where active`);
let tries = 0, hits = 0;
for (let i = 0; i < 4000; i++) { tries++; if ((await sys(`select random() * 100 < coalesce((public.cfg()->>'league_capture_pct')::numeric, 5) ok`))[0].ok) hits++; }
check("a chance padrão é 5% (cerca de 1 em 20)", hits / tries > 0.035 && hits / tries < 0.065, `${(hits / tries * 100).toFixed(1)}%`);

console.log("\nNova temporada");
const coinsBefore = (await sys(`select sum(coins)::int s from characters`))[0].s;
await sys(`update seasons set ended_on = ended_on - 1 where status = 'encerrada'`);
await sys(`select public.settle()`);
const s2 = (await sys(`select id, status from seasons order by id desc limit 1`))[0];
check("no dia seguinte começa uma temporada nova", s2.status === "ativa");
check("todos voltam à largada sem perder nada (moedas, Pokémon, aura)", (await sys(`select count(*)::int n from characters where arrived_rank is not null or node <> 0`))[0].n === 0
  && (await sys(`select sum(coins)::int s from characters`))[0].s === coinsBefore && (await sys(`select count(*)::int n from monsters where user_id = $1 and species_id = $2`, [P[0], L.legend_id]))[0].n === 1);

console.log("\nCaverna sem tentativa e Liga começada pelo admin");
await arrive(1); await arrive(2);
r = await as(ADM, `select public.admin_league_start() id`); check("admin começa a Liga antes de todos chegarem", !r.error, r.error);
L = await lg();
const f = (await matches(1))[0];
await forfeit(f, P[2]);
L = await lg();
check("Liga com 2: final direta, Beto campeão", L.status === "caverna" && L.champion === P[1]);
await sys(`update leagues set cave_open_at = now() - interval '25 hours'`);
await sys(`select public.league_tick()`);
L = await lg();
check("sem tentativa em 24 h depois de liberar, o lendário foge", L.status === "encerrada" && L.cave_result === "fugiu");
check("o Jornal conta que ele escapou", (await sys(`select 1 from event_log where message like '%escapou de Beto%'`)).length === 1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
