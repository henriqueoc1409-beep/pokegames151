// Testa os arquivos 118 a 122 com dados de TESTE, como jogadores comuns:
// 118: Caçada gasta só as casas até o Pokémon, o resto é andado depois da volta; quem não capturou ganha metade das casas gastas; distância e prazo.
// 119: Creche com 1 vaga + 1 por nível do Poço; Mercado vende pedras, TMs, bolas e curas da bolsa (HM e Poké Ball não; só por moedas; taxa 5%).
// 120: casas perdidas (Azarado), categorias novas, empate divide as moedas. 121: pódio da Liga (500/300/150 e o 3º pela colocação), título,
//      bônus do campeão, consolo da caverna. 122: Rocket em ondas (nível da 1ª onda, +3 por onda, ranking por ondas, barra pela média, XP para
//      todos, recorde e Superação, multiplicador), roubo para o esconderijo e resgate pelo Quartel, Giovanni (time, roubo, revanche, devolução).
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_pacote3.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql" && parseInt(f) < 125).sort((a, b) => parseInt(a) - parseInt(b) || a.localeCompare(b))) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec(`reset role;`); } };
const U = i => `${i}${i}${i}${i}${i}${i}${i}${i}-${i}${i}${i}${i}-${i}${i}${i}${i}-${i}${i}${i}${i}-${i}${i}${i}${i}${i}${i}${i}${i}${i}${i}${i}${i}`;
const [A, B, C, D, E] = [1, 2, 3, 4, 5].map(U), ADM = U(9);
for (const [u, n] of [[A, "Ana"], [B, "Beto"], [C, "Caio"], [D, "Duda"], [E, "Edu"], [ADM, "Chefe"]]) {
  await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]);
  await as(u, `select public.create_character($1, 'guerreiro')`, [n]);
}
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
await sys(`update characters set created_at = now() - interval '30 days', coins = 3000 where true`);
await sys(`update monsters set team_slot = null where true`);
await sys(`update board_nodes set hm = null where true`);
await sys(`update game_config set config = config || '{"rocket": {"days": []}}'::jsonb where active`);   // sem invasão automática no meio do teste
for (const u of [A, B, C, D, E]) await sys(`insert into daily_moves(user_id, move_date, modes, base_steps, roll, bonus_steps, from_node, to_node, xp_gained, coins_gained, events) select $1, public.game_today() - 1, '{}', 0, 1, 0, node, node, 0, 0, '[]' from characters where user_id = $1`, [u]);
const mk = async (u, sp, lv, slot = null) => { const id = (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, sp, lv]))[0].id; if (slot) await sys(`update monsters set team_slot = $2 where id = $1`, [id, slot]); return id; };
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;
const bag = async (u, it) => (await sys(`select coalesce((select qty from bag_items where user_id = $1 and item = $2), 0) q`, [u, it]))[0].q;
const node = async u => (await sys(`select node from characters where user_id = $1`, [u]))[0].node;
const plen = async u => (await sys(`select array_length(path, 1) n from characters where user_id = $1`, [u]))[0].n;
const arr = ids => `{${ids.join(",")}}`;

// ============================== 118 Caçada ==============================
console.log("\nCaçada (118)");
const F = (await sys(`select id, x, y, dist from board_nodes where kind = 'normal' and next_b is null and dist between 120 and 220 order by id limit 1`))[0];
const behind = (await sys(`select id from board_nodes where kind = 'normal' and next_b is null and dist > $1 + 20 order by dist limit 1`, [F.dist]))[0].id;
const PTS = [[F.x + 40, F.y + 60], [F.x + 80, F.y + 120], [F.x + 120, F.y + 180]];
const goTo = async (u, n) => { await sys(`update characters set node = $2, path = array[1, $2::int], bonus_steps = 0, pending_mud = 0, route = '{}' where user_id = $1`, [u, n]); await sys(`delete from daily_moves where user_id = $1`, [u]); };
const move = async u => { await sys(`delete from daily_moves where user_id = $1`, [u]); const x = await as(u, `select public.move_today() m`); return x.error ? { error: x.error } : x.rows[0].m; };
const roll = n => sys(`update game_config set config = config || jsonb_build_object('roll_min', $1::int, 'roll_max', $1::int) where active`, [n]);
const h = (await as(ADM, `select * from public.admin_hunt_create(133, 25, $1, $2, 3)`, [F.id, JSON.stringify(PTS)])).rows[0];
const dist = h.node_ids.length;
await goTo(A, behind); await goTo(B, behind);
await as(A, `select public.hunt_choose(true)`); await as(B, `select public.hunt_choose(true)`);
let est = (await as(A, `select public.hunt_estado() e`)).rows?.[0]?.e;
check("antes de ir: a distância até o Pokémon e o prazo aparecem", est && est.distancia === dist && est.prazo, JSON.stringify(est));
await roll(1);
let m = await move(B);   // Beto entra no caminho primeiro (gasta 1)
check("Beto entra no caminho da Caçada e gasta 1 casa", h.node_ids[0] === await node(B) && (await sys(`select gastas from hunt_entries where user_id = $1`, [B]))[0].gastas === 1);
await roll(dist + 2);
m = await move(A);
let eA = (await sys(`select gastas, sobra from hunt_entries where user_id = $1`, [A]))[0];
check(`com ${dist + 2} casas, a Ana gasta só ${dist} e guarda 2`, await node(A) === h.target_node && eA.gastas === dist && eA.sobra === 2 && (m.events || []).some(e => /ficam guardadas/.test(e.msg)), JSON.stringify(eA) + JSON.stringify(m.events));
const lenB0 = await plen(B);
m = await move(B);
const bB = (await sys(`select bonus_steps from characters where user_id = $1`, [B]))[0].bonus_steps;
check("Beto chega depois: volta e anda as 3 casas que sobraram a partir da casa dele", await plen(B) === 2 + 3 && !h.node_ids.includes(await node(B)), `→ ${await plen(B)}`);
check(`e ganha metade das casas gastas (${dist}) na próxima andada: +${Math.ceil(dist / 2)}`, bB === Math.ceil(dist / 2), bB);
const sync = (await as(A, `select public.pk_sync() s`)).rows[0].s;
await sys(`update pokemon set catch_rate = 255 where id = 133`);
let t;
for (let k = 0; k < 40; k++) { await sys(`update encounters set throws_left = 3 where id = $1`, [sync.encounter.id]); t = (await as(A, `select public.encounter_throw($1, 'poke') r`, [sync.encounter.id])).rows?.[0]?.r; if (t?.caught) break; }
check("Ana captura: volta para a casa dela e anda as 2 casas guardadas", t?.caught && await plen(A) === 4, await plen(A));
check("quem capturou não ganha o bônus de metade das casas", (await sys(`select bonus_steps from characters where user_id = $1`, [A]))[0].bonus_steps === 0);
check("a escolha de cada um continua fechada para os outros", (await as(A, `select count(*)::int n from hunt_entries`)).rows[0].n === 1);

// ============================== 119 Creche e Mercado ==============================
console.log("\nCreche com vagas (119)");
const c1 = await mk(C, 25, 10), c2 = await mk(C, 7, 10), c3 = await mk(C, 1, 10);
let r = await as(C, `select public.creche_treinar($1, 1) r`, [c1]);
check("1ª vaga: treina um Pokémon", !r.error, r.error);
r = await as(C, `select public.creche_treinar($1, 1) r`, [c2]);
check("sem Poço, a 2ª vaga não existe", /vaga/.test(r.error || ""), r.error || "passou");
await sys(`insert into villages(user_id) values ($1) on conflict do nothing`, [C]);
await sys(`update villages set well_level = 2 where user_id = $1`, [C]);
r = await as(C, `select public.creche_treinar($1, 1) r`, [c2]);
check("com o Poço nível 2: mais vagas, treina outro ao mesmo tempo", !r.error, r.error);
check("o mesmo Pokémon não treina em duas vagas", /já está treinando/.test((await as(C, `select public.creche_treinar($1, 1)`, [c1])).error || ""));
let cs = (await as(C, `select public.creche_estado() e`)).rows[0].e;
check("o estado mostra as 3 vagas e os 2 treinos", cs.vagas === 3 && cs.treinos.length === 2, JSON.stringify({ v: cs.vagas, n: cs.treinos?.length }));
await sys(`update villages set damaged = '{"poco": true}'::jsonb where user_id = $1`, [C]);
check("Poço danificado não dá vaga", (await as(C, `select public.creche_vagas($1) v`, [C])).rows[0].v === 1);
await sys(`update villages set damaged = '{}'::jsonb where user_id = $1`, [C]);
const c0 = await coins(C), idc2 = cs.treinos.find(x => x.mon_id === c2).id;
r = await as(C, `select public.creche_cancelar($1) r`, [idc2]);
check("cancelar um treino pelo número devolve só o dele", !r.error && r.rows[0].r.devolvido > 0 && (await coins(C)) === c0 + r.rows[0].r.devolvido
  && (await as(C, `select public.creche_estado() e`)).rows[0].e.treinos.length === 1, r.error);

console.log("\nMercado com itens da bolsa (119)");
const tm = (await sys(`select id from pk_items where kind = 'tm' and price > 0 order by id limit 1`))[0].id, hm = (await sys(`select id from pk_items where kind = 'hm' limit 1`))[0].id;
for (const [it, q] of [["pedra_fogo", 3], ["ultra_ball", 2], [tm, 1], [hm, 1], ["poke_ball", 5], ["pocao", 2]]) await sys(`insert into bag_items(user_id, item, qty) values ($1, $2, $3) on conflict (user_id, item) do update set qty = excluded.qty`, [A, it, q]);
r = await as(A, `select (public.market_create('bolsa', 'pedra_fogo', 2, 100, null, null, null)).id id`);
check("Ana anuncia 2 Pedras do Fogo por 100 moedas", !r.error && await bag(A, "pedra_fogo") === 1, r.error);
const lid = r.rows?.[0]?.id;
check("HM não vai para o Mercado", /não pode ser vendido/.test((await as(A, `select public.market_create('bolsa', $1, 1, 50, null, null, null)`, [hm])).error || ""));
check("a Poké Ball grátis também não", /não pode ser vendido/.test((await as(A, `select public.market_create('bolsa', 'poke_ball', 1, 5, null, null, null)`)).error || ""));
check("item da bolsa não vai para troca, só por moedas", /só são vendidos por moedas/.test((await as(A, `select public.market_create('bolsa', 'pocao', 1, null, 'dica', null, 1)`)).error || ""));
check("não dá para anunciar mais do que tem", /não tem/.test((await as(A, `select public.market_create('bolsa', 'ultra_ball', 5, 50, null, null, null)`)).error || ""));
r = await as(A, `select (public.market_create('bolsa', $1, 1, 40, null, null, null)).id id`, [tm]);
check("uma TM que ainda não foi usada também vende", !r.error, r.error);
const a0 = await coins(A), b0 = await coins(B);
r = await as(B, `select public.market_buy($1)`, [lid]);
check("Beto compra: as pedras vão para a bolsa dele", !r.error && await bag(B, "pedra_fogo") === 2, r.error);
check("Beto paga 100 e Ana recebe 95 (taxa de 5%)", (await coins(B)) === b0 - 100 && (await coins(A)) === a0 + 95, `${await coins(B) - b0} / ${await coins(A) - a0}`);
r = await as(A, `select (public.market_create('bolsa', 'ultra_ball', 1, 30, null, null, null)).id id`);
await as(A, `select public.market_cancel($1)`, [r.rows[0].id]);
check("cancelar devolve o item para a bolsa", await bag(A, "ultra_ball") === 2);
check("o nome do anúncio aparece certinho", (await sys(`select public.mercado_nome('bolsa', 'pedra_fogo', 2) n`))[0].n === "2× Pedra do Fogo");

// ============================== 120 Prêmios da temporada ==============================
console.log("\nPrêmios da temporada (120)");
const cidOf = async u => (await sys(`select id from characters where user_id = $1`, [u]))[0].id;
await sys(`update characters set path = array[1,2,3,4,5,6,7,8,9,10,11,12], node = 12 where user_id in ($1, $2)`, [D, E]);
await sys(`do $$ begin perform public.perda_motivo('lamacal'); perform public.go_back($1::uuid, 4); end $$`.replace("$1::uuid", `'${await cidOf(D)}'::uuid`));
await sys(`do $$ begin perform public.perda_motivo('raio'); perform public.go_back($1::uuid, 4); end $$`.replace("$1::uuid", `'${await cidOf(E)}'::uuid`));
await sys(`select public.go_back($1, 2)`, [await cidOf(E)]);   // sem motivo (ex.: carta do azar): não conta
const perd = await sys(`select user_id, sum(casas)::int s from casas_perdidas group by 1`);
check("as casas perdidas no Lamaçal e no Raio ficam guardadas (sem motivo não conta)", perd.length === 2 && perd.every(p => p.s === 4), JSON.stringify(perd));
check("cada um lê só as suas casas perdidas", (await as(D, `select count(*)::int n from casas_perdidas`)).rows[0].n === 1);
const cats = (await sys(`select public.season_award_cats() c`))[0].c;
check("22 categorias, com as 10 novas", cats.length === 22 && ["evolucoes", "insignias", "ataques", "defesas", "cartas", "pokebound", "missoes", "chefe", "negociante", "azarado"].every(k => cats.some(c => c.id === k)));
check("a da Rocket virou ondas vencidas", cats.find(c => c.id === "rocket").nome === "Mais ondas vencidas contra a Rocket");
const se = (await sys(`select id from seasons order by id desc limit 1`))[0].id;
const rk = async cat => (await sys(`select user_id, val::int v from public.season_rank($1, (select started_on::timestamp at time zone 'America/Sao_Paulo' from seasons where id = $2), now() + interval '1 minute')`, [cat, se]));
const az = await rk("azarado");
check("Azarado: Duda e Edu empatados com 4 casas", az.length === 2 && az.every(x => x.v === 4), JSON.stringify(az));
const neg = await rk("negociante");
check("Maior negociante conta a venda para Ana e para Beto", neg.find(x => x.user_id === A)?.v === 1 && neg.find(x => x.user_id === B)?.v === 1, JSON.stringify(neg));
await sys(`insert into event_log(user_id, kind, message) values ($1, 'evolucao', 'teste: evoluiu')`, [C]);
check("Mais evoluções conta o que está nos Acontecimentos", (await rk("evolucoes")).find(x => x.user_id === C)?.v === 1);
await sys(`insert into rpg_insignias(user_id, regiao) values ($1, 'bosque'), ($1, 'praia')`, [D]);
check("Mais insígnias conta as insígnias ganhas na temporada", (await rk("insignias")).find(x => x.user_id === D)?.v === 2);
const n0 = await sys(`select public.season_awards_give($1) n`, [se]);
const azw = await sys(`select user_id, coins from season_awards where season_id = $1 and category = 'azarado'`, [se]);
check("empate: os dois ganham a medalha e as 150 moedas são divididas (75 cada)", azw.length === 2 && azw.every(x => x.coins === 75), JSON.stringify(azw));
check("o presente no Correio explica a divisão", (await sys(`select count(*)::int n from gifts where user_id = $1 and message like '%divididas%'`, [D]))[0].n >= 1);

// ============================== 121 Liga ==============================
console.log("\nPódio da Liga (121)");
const lg = (await sys(`insert into leagues(season_id, name, status, stage) values ($1, 'Liga Teste', 'rodada', 2) returning id`, [se]))[0].id;
for (const [u, s] of [[A, 1], [B, 2], [C, 3], [D, 4]]) await sys(`insert into league_players(league_id, user_id, name, seed) values ($1, $2, (select name from characters where user_id = $2), $3)`, [lg, u, s]);
await sys(`insert into league_matches(league_id, stage, kind, a, b, winner, status) values ($1, 1, 'rodada', $2, $5, $2, 'encerrada'), ($1, 1, 'rodada', $3, $4, $3, 'encerrada'), ($1, 2, 'rodada', $2, $3, $2, 'encerrada')`, [lg, A, B, C, D]);
const L0 = await Promise.all([A, B, C, D].map(coins));
await sys(`select public.league_crown($1, $2)`, [lg, A]);
const L1 = await Promise.all([A, B, C, D].map(coins));
check("campeão 500, vice 300, 3º 150 (Caio, melhor colocado entre quem caiu na semifinal), 4º nada", L1[0] - L0[0] === 500 && L1[1] - L0[1] === 300 && L1[2] - L0[2] === 150 && L1[3] === L0[3], JSON.stringify(L1.map((v, i) => v - L0[i])));
check("o título fica gravado e todos podem ver", (await as(B, `select user_id, season_id from liga_titulos`)).rows[0]?.user_id === A);
check("campeão tem +10% de XP na Aventura e de salário; os outros não", (await sys(`select public.liga_campeao_pct($1, 'xp') a, public.liga_campeao_pct($1, 'salario') b, public.liga_campeao_pct($2, 'xp') c`, [A, B]))[0].a == 10 && (await sys(`select public.liga_campeao_pct($1, 'xp') c`, [B]))[0].c == 0);
await sys(`select public.league_crown($1, $2)`, [lg, A]);
check("o pódio paga uma vez só", (await coins(A)) === L1[0]);
await sys(`update game_config set config = config || '{"league_capture_pct": 0}'::jsonb where active`);
const u0 = await bag(A, "ultra_ball"), m0 = await coins(A);
r = await as(A, `select public.league_cave_try() r`);
check("lendário escapou: o campeão leva 3 Ultra Balls e 200 moedas", !r.error && r.rows[0].r.caught === false && await bag(A, "ultra_ball") === u0 + 3 && (await coins(A)) >= m0 + 200 && r.rows[0].r.consolo?.moedas === 200, r.error || JSON.stringify(r.rows?.[0]?.r));

// ============================== 122 Rocket em ondas ==============================
console.log("\nEquipe Rocket em ondas (122)");
const ativos = (await sys(`select count(distinct a.user_id)::int n from public.day_active(public.game_today()) a where exists (select 1 from monsters m where m.user_id = a.user_id)`))[0].n;
console.log('  (invasões abertas antes:', JSON.stringify(await sys(`select id, status, starts_at from rocket_raids`)), ')');
await sys(`update rocket_raids set status = 'derrota', resolved_at = now() where status = 'ativa'`);
const st0 = await as(ADM, `select * from public.admin_rocket_start(24)`); if (st0.error) console.log(st0.error);
let raid = st0.rows?.[0];
check(`barra = 250 (sem histórico) × ${ativos} ativos × 1,0`, raid.hp_total === 250 * ativos && Number(raid.mult) === 1, `${raid.hp_total} / ${ativos}`);
const aMon = await mk(A, 9, 80);   // Blastoise 80
let bid = (await as(A, `select public.rocket_join($1) b`, [aMon])).rows[0].b;
let bt = (await sys(`select state from battles where id = $1`, [bid]))[0].state;
check("1ª onda 5 níveis abaixo do cedido, com a fila guardada", bt.sides[1].mons[0].level === 75 && bt.sides[1].mons.length === 2 && bt.sides[1].mons[1].oculto === true && bt.rk.base === 80, JSON.stringify(bt.sides[1].mons.map(x => x.level)));
check("uma tentativa por invasão", /já cedeu/.test((await as(A, `select public.rocket_join($1)`, [aMon])).error || ""));
const melhor = async id => { const s = (await sys(`select state, turn from battles where id = $1`, [id]))[0]; const ms = s.state.sides[0].mons[0].moves;
  const pw = await sys(`select id, coalesce(power, 0) p from pk_moves where id = any($1)`, [ms.map(x => x.id)]);
  let best = 0, bp = -1; ms.forEach((x, i) => { const p = pw.find(y => y.id === x.id)?.p ?? 0; if (x.pp > 0 && p > bp) { bp = p; best = i; } }); return { turn: s.turn, v: best }; };
const joga = async (u, id, maxOndas, maxT = 120) => { for (let k = 0; k < maxT; k++) { const b = (await sys(`select status, state from battles where id = $1`, [id]))[0];
  if (b.status !== "ativa" || (b.state.rk?.ondas ?? 0) >= maxOndas) return b; const x = await melhor(id); const res = await as(u, `select (public.battle_act($1, $2, 'move', $3)).status`, [id, x.turn, x.v]); if (res.error && !/turno|PP/.test(res.error)) return { erro: res.error }; }
  return (await sys(`select status, state from battles where id = $1`, [id]))[0]; };
let b = await joga(A, bid, 2);
const lv2 = b.state?.sides?.[1]?.mons?.map(x => x.level);
check("vencendo a onda, entra a próxima 3 níveis acima", (b.state?.rk?.ondas ?? 0) >= 1 && lv2.includes(78), b.erro || JSON.stringify(lv2));
let ent = (await sys(`select ondas, damage from rocket_entries where battle_id = $1`, [bid]))[0];
raid = (await sys(`select * from rocket_raids where id = $1`, [raid.id]))[0];
check("as ondas e o dano contam; o dano sai da barra", ent.ondas >= 1 && ent.damage > 0 && raid.hp_left === raid.hp_total - raid.dano_total && raid.dano_total === ent.damage, JSON.stringify(ent));
const xp0 = +(await sys(`select exp::int x from monsters where id = $1`, [aMon]))[0].x;
await as(A, `select public.battle_act($1, (select turn from battles where id = $1), 'forfeit', null)`, [bid]);
ent = (await sys(`select * from rocket_entries where battle_id = $1`, [bid]))[0];
check("a luta acaba (desistindo ou desmaiando) e o Pokémon ganha XP de participação", ent.done && ent.xp === 800 && +(await sys(`select (m.exp - public.pk_exp_for(p.growth_rate, 80))::int x from monsters m join pokemon p on p.id = m.species_id where m.id = $1`, [aMon]))[0].x >= 800, JSON.stringify({ xp: ent.xp, xp0, agora: (await sys(`select exp::int x from monsters where id = $1`, [aMon]))[0].x }));
check("a 1ª luta da temporada só marca o recorde (sem Superação)", (await sys(`select ondas from rocket_recordes where user_id = $1`, [A]))[0]?.ondas === ent.ondas && !ent.superou);
// Beto luta fraco: 0 ondas
const bMon = await mk(B, 129, 5);
const bidB = (await as(B, `select public.rocket_join($1) b`, [bMon])).rows[0].b;
await as(B, `select public.battle_act($1, 1, 'forfeit', null)`, [bidB]);
const cur = (await as(B, `select public.rocket_current() r`)).rows[0].r;
check("o ranking é por ondas (Ana na frente)", cur.ranking[0].user_id === A && cur.ranking[0].ondas >= 1 && cur.ranking[1].ondas === 0 && cur.mult !== undefined, JSON.stringify(cur.ranking.map(x => [x.name, x.ondas])));
const pa = await coins(A), pb = await coins(B);
await sys(`select public.rocket_win($1)`, [raid.id]);
check("vitória: 100 para cada um, +50 para quem mais venceu ondas", (await coins(A)) - pa === 150 && (await coins(B)) - pb === 100, `${(await coins(A)) - pa} / ${(await coins(B)) - pb}`);
let meta = (await sys(`select * from rocket_meta`))[0];
check("o multiplicador sobe para 1,05", Number(meta.mult) === 1.05 && meta.vitorias === 1, JSON.stringify(meta));
check("a categoria Rocket da temporada conta as ondas", (await rk("rocket")).find(x => x.user_id === A)?.v === ent.ondas);

console.log("\nSuperação e roubo para o esconderijo");
raid = (await as(ADM, `select * from public.admin_rocket_start(24)`)).rows[0];
check("a barra nova usa o multiplicador (×1,05)", Number(raid.mult) === 1.05);
await sys(`update rocket_recordes set ondas = 0 where user_id = $1`, [A]);
await sys(`update game_config set config = jsonb_set(config, '{rocket,onda_menos}', '40') where active`);   // onda bem mais fraca, para vencer com certeza
const aMon2 = await mk(A, 9, 80);
bid = (await as(A, `select public.rocket_join($1) b`, [aMon2])).rows[0].b;
b = await joga(A, bid, 1);
const sa = await coins(A);
await as(A, `select public.battle_act($1, (select turn from battles where id = $1), 'forfeit', null)`, [bid]);
ent = (await sys(`select * from rocket_entries where battle_id = $1`, [bid]))[0];
check("bater o recorde da temporada dá +20 de Superação", ent.ondas >= 1 && ent.superou && (await coins(A)) - sa === 20, JSON.stringify({ o: ent.ondas, s: ent.superou, c: (await coins(A)) - sa }));
// Duda cede um Magikarp 10 e o grupo perde abaixo de 80%: a Rocket leva para o esconderijo
const dMon = await mk(D, 129, 10);
const bidD = (await as(D, `select public.rocket_join($1) b`, [dMon])).rows[0].b;
await as(D, `select public.battle_act($1, 1, 'forfeit', null)`, [bidD]);
await sys(`delete from rocket_entries where raid_id = $1 and user_id = $2`, [raid.id, A]);   // só a Duda no sorteio
await sys(`update rocket_raids set dano_total = 0 where id = $1`, [raid.id]);
await sys(`select public.rocket_lose($1)`, [raid.id]);
const base = (await sys(`select * from rocket_bases where tipo = 'resgate' and dono = $1`, [D]))[0];
check("derrota abaixo de 80%: o Pokémon some da Duda e vai para um esconderijo de 7 dias", base && base.ativa && (await sys(`select count(*)::int n from monsters where id = $1`, [dMon]))[0].n === 0
  && Math.round((new Date(base.prazo) - Date.now()) / 864e5) === 7, JSON.stringify(base?.mon_info));
meta = (await sys(`select * from rocket_meta`))[0];
check("e o multiplicador cai 0,1", Math.abs(Number(meta.mult) - 0.95) < 1e-9, meta.mult);
await sys(`insert into villages(user_id) values ($1) on conflict do nothing`, [E]);
await sys(`update villages set barracks_level = 1, center_level = 2 where user_id = $1`, [E]);
const eAtk = [await mk(E, 9, 90), await mk(E, 9, 90), await mk(E, 9, 90)], eDef = [await mk(E, 9, 90), await mk(E, 9, 90), await mk(E, 9, 90)];
await as(E, `select public.war_squads_salvar($1, $2)`, [arr(eAtk), arr(eDef)]);
const lista = (await as(E, `select public.rocket_bases_lista() l`)).rows[0].l;
const bl = lista.bases.find(x => x.id === base.id);
check("o esconderijo aparece para qualquer um, com o nome da dona", bl && bl.mon?.dono_nome === "Duda" && bl.meu === false, JSON.stringify(bl));
const e0 = await coins(E);
r = await as(E, `select public.rocket_base_atacar($1) r`, [base.id]);
check("Edu (com Quartel) resgata: o Magikarp volta para a Duda", !r.error && r.rows[0].r.venceu && (await sys(`select user_id from monsters where id = $1`, [dMon]))[0]?.user_id === D, r.error || JSON.stringify(r.rows?.[0]?.r?.msg));
check("e Edu ganha +50 além do prêmio da base", (await coins(E)) - e0 === r.rows[0].r.moedas && r.rows[0].r.moedas >= 50 && !(await sys(`select ativa from rocket_bases where id = $1`, [base.id]))[0].ativa);
// esconderijo que vence
await sys(`select public.rocket_resgate_criar(0, row(0, $1, 'Edu', $2, 'Blastoise', 9, 90, null, 0, false, now(), 0, 0, 1, 0, 0, false)::rocket_entries)`, [E, eAtk[0]]);
await sys(`update rocket_bases set prazo = now() - interval '1 minute' where dono = $1 and ativa`, [E]);
await sys(`select public.rocket_resgate_tick()`);
check("sem resgate a tempo, o Pokémon se perde", (await sys(`select count(*)::int n from monsters where id = $1`, [eAtk[0]]))[0].n === 0 && (await sys(`select count(*)::int n from rocket_bases where dono = $1 and ativa`, [E]))[0].n === 0);

console.log("\nGiovanni");
await sys(`update rocket_meta set vitorias = 4, giovanni_apos_vitoria = false where id = 1`);
raid = (await as(ADM, `select * from public.admin_rocket_start(24)`)).rows[0];
await sys(`select public.rocket_win($1)`, [raid.id]);
check("na 5ª vitória do grupo, a próxima invasão é do Giovanni", (await sys(`select giovanni_pendente g from rocket_meta`))[0].g === true);
raid = (await as(ADM, `select * from public.admin_rocket_start(24)`)).rows[0];
check("Giovanni chega com o time dele e a barra pelo fator 1,1", raid.giovanni && raid.team.map(x => x.species).join() === "111,51,31,34,53,112" && Number(raid.mult) === 1.1, JSON.stringify(raid.team));
const multAntes = Number((await sys(`select mult from rocket_meta`))[0].mult);
const cMon = await mk(C, 25, 20);
await as(C, `select public.rocket_join($1)`, [cMon]);
await sys(`select public.rocket_lose($1)`, [raid.id]);
check("Giovanni venceu: levou o Pikachu do Caio", (await sys(`select count(*)::int n from rocket_roubados where user_id = $1 and status = 'preso'`, [C]))[0].n === 1 && (await sys(`select count(*)::int n from monsters where id = $1`, [cMon]))[0].n === 0);
meta = (await sys(`select * from rocket_meta`))[0];
check("o fator do Giovanni cai para 1,0 e o multiplicador comum não muda", Math.abs(Number(meta.giovanni_fator) - 1.0) < 1e-9 && Math.abs(Number(meta.mult) - multAntes) < 1e-9 && meta.giovanni_apos_vitoria, JSON.stringify(meta));
check("o Caio vê o Pikachu na lista do Giovanni", (await as(C, `select public.rocket_current() r`)).rows[0].r.roubados?.[0]?.meu === true);
// depois de uma vitória do grupo, o Giovanni volta
raid = (await as(ADM, `select * from public.admin_rocket_start(24)`)).rows[0];
check("depois da derrota, a invasão seguinte é comum", !raid.giovanni);
await sys(`select public.rocket_win($1)`, [raid.id]);
raid = (await as(ADM, `select * from public.admin_rocket_start(24)`)).rows[0];
check("e o Giovanni volta na invasão depois da vitória, com a barra aliviada (fator − 0,1)", raid.giovanni && Math.abs(Number(raid.mult) - 0.9) < 1e-9, raid.mult);
const cMon2 = await mk(C, 9, 60);
bid = (await as(C, `select public.rocket_join($1) b`, [cMon2])).rows[0].b;
bt = (await sys(`select state from battles where id = $1`, [bid]))[0].state;
ent = (await sys(`select peso from rocket_entries where battle_id = $1`, [bid]))[0];
check("revanche: o Pikachu aparece numa das ondas e o dano do Caio vale 1,25", bt.rk.roubo_sp === 25 && bt.rk.roubo_onda >= 2 && Number(ent.peso) === 1.25, JSON.stringify(bt.rk));
await sys(`select public.rocket_lose($1)`, [raid.id]);
check("1ª revanche perdida: o Pikachu continua com ele (1 chance gasta)", (await sys(`select revanches, status from rocket_roubados where species = 25`))[0].revanches === 1);
await sys(`update rocket_meta set giovanni_pendente = true where id = 1`);
raid = (await as(ADM, `select * from public.admin_rocket_start(24)`)).rows[0];
await sys(`select public.rocket_lose($1)`, [raid.id]);
check("2ª revanche perdida seguida: o mais antigo se perde", (await sys(`select status from rocket_roubados where species = 25`))[0].status === "perdido");
// vitória sobre o Giovanni devolve os que ele tem
const presos = await sys(`select user_id, snap->>'id' mon from rocket_roubados where status = 'preso'`);
await sys(`update rocket_meta set giovanni_pendente = true where id = 1`);
raid = (await as(ADM, `select * from public.admin_rocket_start(24)`)).rows[0];
const eMon = await mk(E, 9, 60);
await as(E, `select public.rocket_join($1)`, [eMon]);
const donos0 = await Promise.all(presos.map(p => coins(p.user_id))), ee0 = await coins(E);
await sys(`select public.rocket_win($1)`, [raid.id]);
check("vencendo o Giovanni, os prêmios são em dobro", (await coins(E)) - ee0 === 200, (await coins(E)) - ee0);
const ok1 = presos.length > 0 && (await Promise.all(presos.map(async (p, i) => (await sys(`select user_id from monsters where id = $1`, [p.mon]))[0]?.user_id === p.user_id && (await coins(p.user_id)) >= donos0[i] + 50))).every(Boolean);
check("e todos os Pokémon que ele tinha voltam para os donos, com +50 moedas", ok1 && (await sys(`select count(*)::int n from rocket_roubados where status = 'preso'`))[0].n === 0, JSON.stringify(presos));
check("o fator do Giovanni sobe 0,05", Math.abs(Number((await sys(`select giovanni_fator f from rocket_meta`))[0].f) - 0.95) < 1e-9);
check("jogador comum não lê os roubados nem o estado da Rocket direto", [await as(A, `select count(*)::int n from rocket_roubados`), await as(A, `select count(*)::int n from rocket_meta`)].every(x => x.error || x.rows[0].n === 0));
check("só o admin chama o Giovanni", /administrador/.test((await as(A, `select public.admin_rocket_giovanni(true)`)).error || ""));
const aj = (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c;
check("Ajustes do jogo têm os números da Rocket e do pódio da Liga", aj.rocket.giovanni_cada === 5 && aj.rocket.max_turns === 300 && aj.liga.premio_campeao === 500);

console.log("\nJornal");
const tit = ["🎯 Caçada: casas que sobram e bônus para quem foi", "🏡 Creche com mais vagas e 🛒 Mercado com itens da bolsa", "🏅 Prêmios da temporada: 10 categorias novas", "🏆 Liga Pokémon com prêmio para o pódio", "🚀 Equipe Rocket em ondas e a chegada do Giovanni"];
check("as 5 novidades estão no Jornal, uma vez cada", (await sys(`select count(*)::int n from posts where title = any($1)`, [tit]))[0].n === 5);

console.log(`\n${ok} OK, ${fail} falharam`);
process.exit(fail ? 1 : 0);
