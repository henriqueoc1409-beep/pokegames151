// Testa o arquivo 25 (vila expandida e guerras entre vilas) com dados de TESTE, como jogadores comuns.
// Uso (na pasta ferramentas, uma vez: npm i @electric-sql/pglite@0.3.15):  node testar_guerras.mjs .. [guerras_sorteadas]
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2], NR = +(process.argv[3] || 120);
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql")).sort()) if (f !== "14_recomecar_do_zero.sql") await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
const one = async (uid, q, p = []) => { const r = await as(uid, q, p); if (r.error) throw new Error(r.error); return Object.values(r.rows[0] || {})[0]; };
const id = n => `${n}${n}${n}${n}${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${n.repeat(12)}`;
const A = id("1"), D = id("2"), E = id("3"), F = id("4"), G = id("5");
const NAMES = { [A]: "Ana", [D]: "Davi", [E]: "Eva", [F]: "Fabi", [G]: "Gil" };
for (const [u, n] of Object.entries(NAMES)) {
  await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1,$2,$3)`, [u, n.toLowerCase() + "@t.l", JSON.stringify({ username: n.toLowerCase() })]);
  await as(u, `select public.create_character($1,'mago')`, [n]);
}
// heróis antigos e ativos (menos a Fabi, que é nova)
await sys(`update characters set created_at = now() - interval '20 days', coins = 5000, level = 12, xp_total = 18150 where user_id <> $1`, [F]);
await sys(`update characters set coins = 5000 where user_id = $1`, [F]);
for (const u of [A, D, E, F, G]) await sys(`insert into daily_moves(user_id, move_date, modes, base_steps, roll, bonus_steps, from_node, to_node, xp_gained, coins_gained, events) select $1, public.game_today() - 1, '{}', 0, 1, 0, node, node, 0, 0, '[]' from characters where user_id = $1`, [u]);
const mons = {};
async function giveMons(u, list) { mons[u] = []; for (const [sp, lv] of list) mons[u].push((await sys(`select (public.pk_new_monster($1, $2, $3)).id`, [u, sp, lv]))[0].id); }
await giveMons(A, [[4, 30], [7, 30], [1, 30], [25, 30], [16, 30], [19, 30]]);
await giveMons(D, [[7, 28], [74, 28], [43, 28], [60, 28], [21, 28], [41, 28]]);
await giveMons(E, [[1, 25], [4, 25], [7, 25], [10, 25], [13, 25], [16, 25]]);
await giveMons(F, [[1, 30], [4, 30], [7, 30], [10, 30], [13, 30], [16, 30]]);
await giveMons(G, [[133, 31], [66, 31], [92, 31], [27, 31], [35, 31], [39, 31]]);
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;
const vil = async u => (await sys(`select * from villages where user_id = $1`, [u]))[0];

console.log("\nConstruções novas e níveis");
await sys(`update characters set coins = 100 where user_id = $1`, [A]);
let r = await as(A, `select public.village_upgrade('quartel')`); check("sem moedas não constrói", /custa 600/.test(r.error || ""), r.error);
await sys(`update characters set coins = 5000 where user_id = $1`, [A]);
r = await as(A, `select public.village_upgrade('quartel')`); check("constrói o Quartel (600)", !r.error && await coins(A) === 4400, r.error);
r = await as(A, `select public.village_upgrade('cofre')`); check("Cofre nível 1 com Centro 1", !r.error, r.error);
r = await as(A, `select public.village_upgrade('cofre')`); check("Cofre nível 2 pede Centro da Vila 2", /Centro da Vila nível 2/.test(r.error || ""), r.error);
r = await as(A, `select public.village_upgrade('centro')`); check("Centro da Vila nível 2 (600)", !r.error && (await vil(A)).center_level === 2, r.error);
r = await as(A, `select public.village_upgrade('centro')`); check("Centro 3 com herói nível 12 (pede 5)", !r.error, r.error);
await sys(`update characters set level = 3 where user_id = $1`, [E]);
r = await as(E, `select public.village_upgrade('centro')`); r = await as(E, `select public.village_upgrade('centro')`); check("Centro 3 pede herói nível 5", /herói nível 5/.test(r.error || ""), r.error);
await sys(`update characters set level = 12 where user_id = $1`, [E]);
r = await as(E, `select public.village_upgrade('vigia')`); check("Torre de Vigia pede o Quartel antes", /pede Quartel/.test(r.error || ""), r.error);
r = await as(A, `select public.village_upgrade('quartel')`); r = await as(A, `select public.village_upgrade('quartel')`);
check("Quartel 2 com Centro 3; Quartel 3 pede Centro 5", (await vil(A)).barracks_level === 2 && /Centro da Vila nível 5/.test(r.error || ""), r.error);
r = await as(A, `select public.village_upgrade('xyz')`); check("construção inventada é recusada", /inválida/.test(r.error || ""));
r = await as(A, `update villages set vault_level = 4 where user_id = '${A}'`); check("ninguém muda o nível direto na tabela", !!r.error || (await vil(A)).vault_level === 1);
await sys(`update characters set coins = 5000 where user_id = $1`, [A]);
r = await as(A, `select public.village_build('muralha')`); check("construção antiga continua (Muralha pelo jeito antigo)", !r.error && (await vil(A)).wall_level === 1, r.error);
r = await as(A, `select public.village_upgrade('muralha')`); check("Muralha ganha nível 2", !r.error && (await vil(A)).wall_level === 2, r.error);

console.log("\nEsquadrões");
for (const u of [D, E, G]) { await as(u, `select public.village_upgrade('quartel')`); }
const sq = (u, role, ids) => as(u, `select public.war_squad_set($1, $2)`, [role, ids]);
r = await sq(F, "ataque", mons[F].slice(0, 3)); check("sem Quartel não monta esquadrão", /Quartel/.test(r.error || ""), r.error);
await as(F, `select public.village_upgrade('quartel')`);
r = await sq(A, "ataque", mons[A].slice(0, 4)); check("no máximo 3 por esquadrão", /máximo 3/.test(r.error || ""), r.error);
r = await sq(A, "ataque", [mons[A][0], mons[D][0]]); check("não usa Pokémon dos outros", /sua coleção/.test(r.error || ""), r.error);
r = await sq(A, "ataque", mons[A].slice(0, 3)); check("monta o ataque", !r.error, r.error);
r = await sq(A, "defesa", [mons[A][2], mons[A][3], mons[A][4]]); check("o mesmo Pokémon não fica no ataque e na defesa", /ao mesmo tempo/.test(r.error || ""), r.error);
r = await sq(A, "defesa", mons[A].slice(3, 6)); check("monta a defesa", !r.error, r.error);
for (const u of [D, E, F, G]) { await sq(u, "ataque", mons[u].slice(0, 3)); await sq(u, "defesa", mons[u].slice(3, 6)); }
r = await as(A, `insert into war_squads(user_id, role, slot, monster_id) values ('${A}', 'ataque', 1, '${mons[A][5]}')`); check("ninguém grava esquadrão direto na tabela", !!r.error);

console.log("\nPareamento e proteções");
let tg = (await one(A, `select public.war_targets()`)).targets;
const T = u => tg.find(x => x.user_id === u);
check("Davi aparece como alvo possível", T(D)?.can === true, JSON.stringify(T(D)));
check("Fabi (herói com menos de 3 dias) está protegida", T(F)?.block === "herói novo", JSON.stringify(T(F)));
check("sem Torre de Vigia não vê os Pokémon do alvo", T(D) && !("squad" in T(D)));
await sys(`delete from daily_moves where user_id = $1`, [G]);
tg = (await one(A, `select public.war_targets()`)).targets;
check("quem não joga há 7 dias não pode ser atacado", T(G)?.block === "não joga há dias", JSON.stringify(T(G)));
await sys(`insert into daily_moves(user_id, move_date, modes, base_steps, roll, bonus_steps, from_node, to_node, xp_gained, coins_gained, events) select $1, public.game_today() - 1, '{}', 0, 1, 0, node, node, 0, 0, '[]' from characters where user_id = $1`, [G]);
await sys(`update monsters set level = 90 where user_id = $1`, [G]);
tg = (await one(A, `select public.war_targets()`)).targets;
check("vila muito mais forte fica fora do pareamento justo", T(G) && !T(G).fair, JSON.stringify(T(G)));
check("com poucos jogadores, dá para desafiar uma vila mais forte (risco de quem ataca)", T(G)?.can === true, JSON.stringify(T(G)));
await sys(`update monsters set level = 31 where user_id = $1`, [G]);
await sys(`update monsters set level = 3 where user_id = $1`, [E]);
tg = (await one(A, `select public.war_targets()`)).targets;
check("vila muito mais fraca nunca pode ser atacada", T(E) && !T(E).fair && !T(E).can, JSON.stringify(T(E)));
await sys(`update monsters set level = 25 where user_id = $1`, [E]);
r = await as(F, `select public.war_attack($1)`, [D]); check("herói novo não ataca", /menos de 3 dias/.test(r.error || ""), r.error);
r = await as(E, `select public.war_tactic('ataque', 'segura')`); check("tática pede a Academia", /Academia/.test(r.error || ""), r.error);

console.log("\nAtaque automático");
const total0 = (await sys(`select sum(coins)::int s from characters`))[0].s;
await sys(`update characters set coins = 1100 where user_id = $1`, [D]);
await sys(`update villages set mine_level = 2, mine_collected_at = public.game_today() - 2, orchard_level = 1, orchard_collected_at = public.game_today() - 2 where user_id = $1`, [D]);
const totalA = (await sys(`select sum(coins)::int s from characters`))[0].s;
const dB = await coins(D), aB = await coins(A);
let war = await one(A, `select public.war_attack($1)`, [D]);
check("o ataque roda sozinho e termina", !!war?.battle_id && war.message, JSON.stringify(war));
let bt = (await sys(`select * from battles where id = $1`, [war.battle_id]))[0];
check("a luta usa o motor de batalha e fica registrada (modo guerra)", bt.mode === "guerra" && bt.status === "encerrada" && bt.log.length > 2, JSON.stringify({ st: bt.status, n: bt.log.length }));
check("ninguém escolheu ação por fora: cada turno tem as ações dos dois", (await sys(`select count(*)::int n from battle_actions where battle_id = $1`, [war.battle_id]))[0].n >= 2);
r = await as(D, `select * from wars`); check("o defensor vê o relatório", r.rows?.length === 1);
r = await as(D, `select log from battles where id = $1`, [war.battle_id]); check("o defensor vê a luta inteira", r.rows?.[0]?.log?.length === bt.log.length);
r = await as(E, `select * from wars`); check("os outros não veem o relatório", r.rows?.length === 0);
r = await as(E, `select public.arena_battle($1)`, [war.battle_id]); check("quem assiste a Arena não vê a guerra (defesa é segredo)", !!r.error);
check("guerra não aparece na Arena", !(await sys(`select 1 from arena_battles where battle_id = $1`, [war.battle_id])).length);
const totalB = (await sys(`select sum(coins)::int s from characters`))[0].s;
check("nenhuma moeda é criada: o saque só muda de dono", totalA === totalB, `${totalA} -> ${totalB}`);
if (war.winner === A) {
  check("saque = 10% acima de 100 protegidas, até 150", war.loot === Math.min(150, Math.floor((dB - 100) * 0.1)) && await coins(D) === dB - war.loot && await coins(A) === aB + war.loot, JSON.stringify([war.loot, dB]));
  check("venceu: construção danificada", war.damaged.length >= 1, JSON.stringify(war.damaged));
} else console.log("     (a defesa venceu este ataque; saque e danos são testados abaixo com força combinada)");
const heal = u => sys(`update monsters set war_hp = 100, war_hurt_at = null where user_id = $1`, [u]);
check("o defensor ganhou escudo de 24 h", new Date((await vil(D)).shield_until) > new Date(Date.now() + 23 * 3600e3));
const hurt = await sys(`select war_hp from monsters where id = any($1)`, [[...mons[A].slice(0, 3), ...mons[D].slice(3, 6)]]);
check("os dois lados ficam feridos depois da guerra", hurt.some(m => m.war_hp < 100), JSON.stringify(hurt));
const lv = await sys(`select level from monsters where id = any($1)`, [mons[D]]);
check("a guerra não tira nível dos Pokémon", lv.every(m => m.level >= 28));
await heal(A);
r = await as(A, `select public.war_attack($1)`, [D]); check("escudo impede atacar de novo", /escudo|ataques de hoje/.test(r.error || ""), r.error);
await heal(A); await sys(`update game_config set config = jsonb_set(config, '{war,match_min}', '0') where active`);
r = await as(A, `select public.war_attack($1)`, [E]); check("Quartel 2 = 2 ataques por dia (o 2º passa)", !r.error, r.error);
await heal(A);
r = await as(A, `select public.war_attack($1)`, [G]); check("o 3º ataque do dia é recusado", /ataques de hoje/.test(r.error || ""), r.error);
await sys(`update game_config set config = jsonb_set(config, '{war,match_min}', '75') where active`);
await sys(`update villages set shield_until = null where user_id = $1`, [D]);
await sys(`update wars set created_at = created_at - interval '1 day' where attacker = $1`, [A]);
await sys(`update monsters set war_hp = 100, war_hurt_at = null where user_id = $1`, [A]);
r = await as(A, `select public.war_attack($1)`, [D]); check("o mesmo alvo só 1 vez a cada 3 dias", /atacou há pouco/.test(r.error || ""), r.error);
r = await as(A, `insert into wars(attacker, defender) values ('${A}', '${E}')`); check("ninguém grava guerra direto na tabela", !!r.error);

console.log("\nSaque, Cofre, danos e conserto (força combinada para o atacante vencer)");
async function forceWar(att, def, defCoins) {
  await sys(`update monsters set level = 70, war_hp = 100, war_hurt_at = null where id in (select monster_id from war_squads where user_id = $1 and role = 'ataque')`, [att]);
  await sys(`update monsters set level = 8, war_hp = 100, war_hurt_at = null where id in (select monster_id from war_squads where user_id = $1 and role = 'defesa')`, [def]);
  await sys(`update villages set shield_until = null where user_id = $1`, [def]);
  await sys(`delete from wars where attacker = $1`, [att]);
  await sys(`update characters set coins = $2 where user_id = $1`, [def, defCoins]);
  await sys(`update villages set damaged = '{}' where user_id = $1`, [def]);
  await sys(`update game_config set config = jsonb_set(config, '{war,match_min}', '0') where active`);
  const w = await one(att, `select public.war_attack($1)`, [def]);
  await sys(`update game_config set config = jsonb_set(config, '{war,match_min}', '75') where active`);
  return w;
}
war = await forceWar(A, D, 150);
check("atacante forte vence", war.winner === A, JSON.stringify(war));
check("só 50 desprotegidas: leva 5", war.loot === 5, war.loot);
check("2 construções danificadas quando a defesa não derruba ninguém", war.damaged.length === 2 && war.att_lost === 0, JSON.stringify(war));
await sys(`update characters set coins = 1000 where user_id = $1`, [D]);
r = await as(D, `select public.village_upgrade('cofre')`); check("Davi constrói o Cofre", !r.error, r.error);
war = await forceWar(A, D, 380); check("Cofre 1 protege 400 (100 + 300): não leva nada", war.loot === 0, war.loot);
war = await forceWar(A, D, 9000); check("saque máximo de 150", war.loot === 150, war.loot);
war = await forceWar(A, D, 0); check("quem não tem moedas não fica negativo", war.loot === 0 && await coins(D) === 0);
await sys(`update characters set coins = 2000 where user_id = $1`, [D]);
let v = await one(D, `select public.village_state()`);
check("a vila mostra o custo do conserto", Object.values(v.repair_costs).every(c => c >= 20), JSON.stringify(v.repair_costs));
const dk = Object.keys(v.damaged)[0], cost = v.repair_costs[dk], c0 = await coins(D);
await sys(`update villages set damaged = damaged || '{"cofre": {"at": "2026-01-01T00:00:00Z", "fix": "2999-01-01T00:00:00Z"}}' where user_id = $1`, [D]);
r = await as(D, `select public.village_upgrade('cofre')`); check("construção danificada não pode ser melhorada", /danificada/.test(r.error || ""), r.error);
await sys(`update villages set damaged = damaged - 'cofre' where user_id = $1`, [D]);
r = await as(D, `select public.village_repair($1)`, [dk]); check("conserto pago tira o dano e cobra o preço", !r.error && await coins(D) === c0 - cost && !((await vil(D)).damaged[dk]), r.error);
await sys(`update villages set damaged = jsonb_build_object('mina', jsonb_build_object('at', now() - interval '4 days', 'fix', now() - interval '1 day')), mine_collected_at = public.game_today() - 5 where user_id = $1`, [D]);
v = await one(D, `select public.village_state()`); check("depois de 3 dias o conserto é automático e grátis", !v.damaged.mina, JSON.stringify(v.damaged));
check("os dias parada não contam na produção da Mina", v.pending.coins === 40, JSON.stringify(v.pending));
await sys(`update villages set damaged = jsonb_build_object('mina', jsonb_build_object('at', now() - interval '2 days', 'fix', now() + interval '1 day')), mine_collected_at = public.game_today() - 5 where user_id = $1`, [D]);
v = await one(D, `select public.village_state()`); check("Mina danificada para de produzir (junta só até o dia do dano)", v.pending.coins === 3 * 40, JSON.stringify(v.pending));

console.log("\nRecuperação");
await sys(`update monsters set war_hp = 40, war_hurt_at = now() where id = $1`, [mons[A][1]]);
const hc = await one(A, `select (public.war_state())->'heal_cost'`);
check("tem custo de cura depois da guerra", hc > 0, hc);
await sys(`update characters set coins = 0 where user_id = $1`, [A]);
r = await as(A, `select public.war_heal()`); check("sem moedas não cura (e avisa das 24 h)", /24 horas/.test(r.error || ""), r.error);
await sys(`update characters set coins = 1000 where user_id = $1`, [A]);
r = await as(A, `select public.war_heal() c`); check("cura paga o preço certo", r.rows?.[0]?.c === hc && await coins(A) === 1000 - hc, r.error || JSON.stringify(r.rows));
check("todos curados", (await sys(`select count(*)::int n from monsters where user_id = $1 and war_hp < 100`, [A]))[0].n === 0);
await as(A, `select public.village_upgrade('centropk')`);
await sys(`update monsters set war_hp = 0, war_hurt_at = now() where id = $1`, [mons[A][0]]);
const full = Math.ceil(70 * 1.5), disc = await one(A, `select (public.war_state())->'heal_cost'`);
check("Centro Pokémon 1 dá 10% de desconto", disc === Math.max(1, Math.ceil(70 * 1.5 * 0.9)), `${disc} (sem desconto ${full})`);
await sys(`update monsters set war_hurt_at = now() - interval '25 hours' where id = $1`, [mons[A][0]]);
await one(A, `select public.war_state()`);
check("de graça depois de 24 horas", (await sys(`select war_hp from monsters where id = $1`, [mons[A][0]]))[0].war_hp === 100);
await sys(`update monsters set war_hp = 0, war_hurt_at = now() where id in (select monster_id from war_squads where user_id = $1 and role = 'ataque')`, [A]);
await sys(`update villages set shield_until = null where user_id = $1`, [E]); await sys(`delete from wars where attacker = $1`, [A]);
r = await as(A, `select public.war_attack($1)`, [E]); check("com todo o ataque desmaiado não dá para atacar", /desmaiados/.test(r.error || ""), r.error);
await sys(`update monsters set war_hp = 100, war_hurt_at = null where user_id = $1`, [A]);

console.log("\nXP dentro do limite e coisas antigas");
await sys(`update battles set ended_at = ended_at - interval '2 days'`);  // limite de XP do dia zerado
const exp0 = (await sys(`select sum(exp)::int s from monsters where user_id = $1`, [A]))[0].s;
war = await forceWar(A, D, 500);
const exp1 = (await sys(`select sum(exp)::int s from monsters where user_id = $1`, [A]))[0].s;
check("quem derrubou ganhou XP", exp1 > exp0, `${exp0} -> ${exp1}`);
check("guerra não escreve 'venceu a batalha Pokémon' no Jornal, mas escreve a invasão", !(await sys(`select 1 from event_log where kind = 'batalha'`)).length && (await sys(`select 1 from event_log where kind = 'guerra'`)).length > 0);
await sys(`update villages set damaged = '{}', mud = 0, mine_collected_at = public.game_today() - 2 where user_id = $1`, [D]);
r = await as(D, `select public.village_collect() p`); check("coleta antiga continua funcionando", !r.error && r.rows[0].p.coins === 80, r.error || JSON.stringify(r.rows));
await sys(`update villages set catapult_level = 1 where user_id = $1`, [A]);
r = await as(A, `select public.catapult_fire($1)`, [E]); check("catapulta continua funcionando", !r.error, r.error);

console.log(`\nGuerras sorteadas (${NR})`);
let errs = [], ends = {}, neg = 0;
const P = [A, D, E, G];
await sys(`update game_config set config = jsonb_set(config, '{war,match_min}', '0') where active`);
const before = (await sys(`select sum(coins)::int s from characters`))[0].s;
for (let k = 0; k < NR; k++) {
  const att = P[k % 4], def = P[(k + 1 + (k >> 2) % 3) % 4];
  for (const u of [att, def]) for (const m of mons[u]) {
    await sys(`update monsters set species_id = $2, level = $3, war_hp = $4, moves = (select array_agg(id) from (select id from pk_moves where id <> 165 order by random() limit 4) x) where id = $1`,
      [m, 1 + Math.floor(Math.random() * 151), 5 + Math.floor(Math.random() * 60), Math.random() < .2 ? 30 : 100]);
  }
  await sys(`update villages set shield_until = null, damaged = '{}' where user_id = $1`, [def]); await sys(`delete from wars where attacker = $1`, [att]);
  await sys(`update villages set dtower_level = $2, traps_level = $3, academy_level = $4, def_tactic = $5, atk_tactic = $5 where user_id = $1`, [def, k % 4, k % 3, k % 4, k % 2 ? "segura" : "forte"]);
  const r2 = await as(att, `select public.war_attack($1) w`, [def]);
  if (r2.error) { if (!/força|desmaiados/.test(r2.error)) errs.push(r2.error); continue; }
  const b2 = (await sys(`select status, end_reason, log from battles where id = $1`, [r2.rows[0].w.battle_id]))[0];
  if (b2.status !== "encerrada") errs.push("guerra não terminou");
  ends[b2.end_reason] = (ends[b2.end_reason] || 0) + 1;
  if (JSON.stringify(b2.log).match(/undefined|"null"/)) errs.push("relato estranho");
  neg += (await sys(`select count(*)::int n from characters where coins < 0`))[0].n;
}
const after = (await sys(`select sum(coins)::int s from characters`))[0].s;
console.log("     finais:", JSON.stringify(ends));
check(`${NR} guerras sorteadas sem erro`, errs.length === 0, errs.slice(0, 5).join(" | "));
check("ninguém ficou com moedas negativas", neg === 0);
check("as moedas só mudaram de dono nas guerras sorteadas", before === after, `${before} -> ${after}`);
check("nenhuma batalha de guerra ficou aberta", (await sys(`select count(*)::int n from battles where mode = 'guerra' and status <> 'encerrada'`))[0].n === 0);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
