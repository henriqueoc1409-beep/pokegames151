// Testa os arquivos 115, 116 e 117 com dados de TESTE, como jogadores comuns:
// 115: vila sem Quartel atacada no máximo 1 vez por semana e defendendo com a equipe; quem não tem Quartel não ataca; defesa vitoriosa
//      cobra 5% das moedas do atacante até 150; trava de 48 h nos esquadrões; bases da Rocket (lista, 1 ataque por dia, prêmio, derrota só fere);
//      força de ataque e defesa em números. 116: teto escolhido no desafio (30: o 40 luta como 30 e o 25 como 25; sem escolher = 20; inválido
//      recusado); prêmio do Ginásio pela faixa e revanche com 25%. 117: extrato com as origens, as partes da andada (pedágio) e saldo que bate.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_guerra_teto_extrato.mjs ..
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
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec(`reset role;`); } };
const U = i => `${i}${i}${i}${i}${i}${i}${i}${i}-${i}${i}${i}${i}-${i}${i}${i}${i}-${i}${i}${i}${i}-${i}${i}${i}${i}${i}${i}${i}${i}${i}${i}${i}${i}`;
const [A, B, C, D, E, F, G] = [1, 2, 3, 4, 5, 6, 7].map(U), ADM = U(9);
for (const [u, n] of [[A, "Ana"], [B, "Bia"], [C, "Caio"], [D, "Duda"], [E, "Edu"], [F, "Fabi"], [G, "Gil"], [ADM, "Chefe"]]) {
  await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]);
  await as(u, `select public.create_character($1, 'guerreiro')`, [n]);
}
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
await sys(`update characters set created_at = now() - interval '30 days', coins = 2000 where true`);
await sys(`update monsters set team_slot = null where true`);
const today = (await sys(`select public.game_today() d`))[0].d;
for (const u of [A, B, C, D, E, F, G]) await sys(`insert into daily_moves(user_id, move_date, modes, base_steps, roll, bonus_steps, from_node, to_node, xp_gained, coins_gained, events) select $1, public.game_today() - 1, '{}', 0, 1, 0, node, node, 0, 0, '[]' from characters where user_id = $1`, [u]);
const mk = async (u, sp, lv, slot = null) => { const id = (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, sp, lv]))[0].id; if (slot) await sys(`update monsters set team_slot = $2 where id = $1`, [id, slot]); return id; };
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;
const arr = ids => `{${ids.join(",")}}`;
const quartel = async u => { await sys(`insert into villages(user_id) values ($1) on conflict do nothing`, [u]); await sys(`update villages set barracks_level = 1, center_level = 2, shield_until = null where user_id = $1`, [u]); };

console.log("\nVilas sem Quartel");
await quartel(A); await quartel(C);
await sys(`update game_config set config = jsonb_set(config, '{war}', coalesce(config->'war', '{}'::jsonb) || '{"match_min": 0, "match_max": 100000}'::jsonb) where active`);
const fracos = async u => { const a = []; for (let i = 0; i < 3; i++) a.push(await mk(u, 129, 5)); return a; };
const fortes = async (u, team) => { const a = []; for (let i = 0; i < 3; i++) a.push(await mk(u, 9, 90, team ? i + 1 : null)); return a; };   // Blastoise com Hydro Pump
// Ana ataca forte; Bia (sem Quartel) tem equipe fraca
const aAtk = await fortes(A), aDef = await fortes(A);
let r = await as(A, `select public.war_squads_salvar($1, $2) r`, [arr(aAtk), arr(aDef)]);
check("Ana monta os dois esquadrões de uma vez", !r.error && r.rows[0].r.ataque > 0 && r.rows[0].r.defesa > 0, r.error);
for (let i = 0; i < 3; i++) await mk(B, 129, 5, i + 1);
let tg = (await as(A, `select public.war_targets() t`)).rows[0].t;
const tB = tg.targets.find(t => t.user_id === B);
check("a vila sem Quartel aparece nos alvos, com a força da defesa (a equipe)", tB && tB.quartel === false && tB.power > 0 && tg.defesa > 0, JSON.stringify(tB));
r = await as(A, `select public.war_attack($1) r`, [B]);
check("Ana ataca a vila sem Quartel de Bia", !r.error && r.rows[0].r.details?.sem_quartel === true, r.error);
check("Bia (sem Quartel) não ataca ninguém", /Quartel/.test((await as(B, `select public.war_attack($1)`, [A])).error || ""));
// Caio também tenta atacar Bia na mesma semana (sem escudo, para testar só a regra da semana)
const cAtk = await fortes(C), cDef = await fortes(C);
await as(C, `select public.war_squads_salvar($1, $2)`, [arr(cAtk), arr(cDef)]);
await sys(`update villages set shield_until = null where user_id = $1`, [B]);
r = await as(C, `select public.war_attack($1) r`, [B]);
check("2º ataque na mesma semana à vila sem Quartel: bloqueado", /já foi atacada esta semana/.test(r.error || ""), r.error || "passou");

console.log("\nDefesa vitoriosa");
// Duda (sem Quartel) com equipe fortíssima; Edu ataca fraco com 2000 moedas → paga 5% = 100
for (let i = 0; i < 3; i++) await mk(D, 150, 100, i + 1);
await quartel(E); const eAtk = await fracos(E), eDef = await fracos(E);
await as(E, `select public.war_squads_salvar($1, $2)`, [arr(eAtk), arr(eDef)]);
let e0 = await coins(E), d0 = await coins(D);
r = await as(E, `select public.war_attack($1) r`, [D]);
const w1 = r.rows?.[0]?.r;
check("a defesa venceu e Edu pagou 5% das moedas (100) a Duda", !r.error && w1.winner === D && w1.details.pago === 100 && (await coins(E)) === e0 - 100 && (await coins(D)) === d0 + 100, r.error || JSON.stringify(w1?.details));
// com 5000 moedas, 5% = 250 → paga só 150 (o teto)
await quartel(G); const gAtk = await fracos(G), gDef = await fracos(G);
await as(G, `select public.war_squads_salvar($1, $2)`, [arr(gAtk), arr(gDef)]);
await sys(`update characters set coins = 5000 where user_id = $1`, [G]);
for (let i = 0; i < 3; i++) await mk(F, 150, 100, i + 1);
let g0 = await coins(G);
r = await as(G, `select public.war_attack($1) r`, [F]);
check("com 5000 moedas, paga 150 (o teto), não 250", !r.error && r.rows[0].r.details.pago === 150 && (await coins(G)) === g0 - 150, r.error || JSON.stringify(r.rows?.[0]?.r?.details));

console.log("\nTrava dos esquadrões");
const x4 = await mk(A, 25, 20);
r = await as(A, `select public.war_squads_salvar($1, $2) r`, [arr([aAtk[0], aAtk[1], x4]), arr(aDef)]);
check("trocar um do ataque por outro funciona", !r.error, r.error);
r = await as(A, `select public.war_squads_salvar($1, $2) r`, [arr([aAtk[0], aAtk[1], aAtk[2]]), arr(aDef)]);
check("quem saiu não volta antes de 48 h", /saiu de um esquadrão há pouco/.test(r.error || ""), r.error);
r = await as(A, `select public.war_squads_salvar($1, $2) r`, [arr([aAtk[0], aAtk[1], aDef[0]]), arr([aDef[1], aDef[2]])]);
check("passar da defesa para o ataque também é sair: bloqueado", /está no esquadrão de defesa/.test(r.error || ""), r.error);
r = await as(A, `select public.war_squad_set('ataque', $1)`, [arr([aAtk[0], aAtk[1], aAtk[2]])]);
check("a função antiga (um esquadrão por vez) também respeita a trava", /saiu de um esquadrão há pouco/.test(r.error || ""), r.error);
await sys(`update war_squad_saidas set saiu_em = now() - interval '49 hours' where monster_id = $1`, [aAtk[2]]);
r = await as(A, `select public.war_squads_salvar($1, $2) r`, [arr([aAtk[0], aAtk[1], aAtk[2]]), arr(aDef)]);
check("depois de 48 h pode voltar", !r.error, r.error);

console.log("\nBases da Equipe Rocket");
const bl = (await as(A, `select public.rocket_bases_lista() l`)).rows[0].l;
check("5 bases com forças diferentes e o prêmio em moedas pela força", bl.bases.length === 5 && new Set(bl.bases.map(b => b.forca)).size === 5 && bl.bases.every(b => b.moedas === b.forca * 2) && bl.bases[0].forca < bl.bases[4].forca, JSON.stringify(bl.bases.map(b => [b.nome, b.forca])));
const rbLe = await as(A, `select count(*)::int n from rocket_bases`);
check("o time da base fica no servidor", bl.bases.every(b => !("time" in b)) && (!!rbLe.error || rbLe.rows[0].n === 0), JSON.stringify(rbLe));
await sys(`update monsters set war_hp = 100 where true`);
let a0 = await coins(A);
r = await as(A, `select public.rocket_base_atacar($1) r`, [bl.bases[0].id]);
const rb = r.rows?.[0]?.r;
check("Ana (forte) derrota a base mais fraca e ganha as moedas pela força", !r.error && rb.venceu && rb.moedas === bl.bases[0].moedas && (await coins(A)) === a0 + rb.moedas, r.error || JSON.stringify(rb));
check("1 ataque por dia", /já atacou/.test((await as(A, `select public.rocket_base_atacar($1)`, [bl.bases[1].id])).error || ""));
await sys(`update monsters set war_hp = 100 where true`);
let e1 = await coins(E);
r = await as(E, `select public.rocket_base_atacar($1) r`, [bl.bases[4].id]);
const hpE = (await sys(`select min(war_hp) m from monsters where id = any($1::uuid[])`, [arr(eAtk)]))[0].m;
check("derrota: sem moedas, só os Pokémon feridos", !r.error && !r.rows[0].r.venceu && (await coins(E)) === e1 && hpE < 100, r.error);
check("quem não tem Quartel não ataca base", /Quartel/.test((await as(B, `select public.rocket_base_atacar($1)`, [bl.bases[0].id])).error || ""));
const resg = (await sys(`insert into rocket_bases(nome, tipo, nivel, time, dono, mon_id, prazo) values ('Cativeiro', 'resgate', 20, '[[19, 20]]', $1, null, now() + interval '1 day') returning id`, [B]))[0].id;
check("base de resgate: só o dono vê", (await as(B, `select public.rocket_bases_lista() l`)).rows[0].l.bases.some(b => b.id === resg && b.tipo === "resgate") && !(await as(A, `select public.rocket_bases_lista() l`)).rows[0].l.bases.some(b => b.id === resg));

console.log("\nTeto escolhido no desafio");
await sys(`update monsters set team_slot = null where user_id = $1`, [A]);
const t40 = await mk(A, 6, 40, 1), t25 = await mk(A, 9, 25, 2), t20 = await mk(A, 3, 20, 3);
r = await as(A, `select (public.battle_challenge($1, 20, 33)).id`, [F]);
check("teto fora da lista: recusado", /Escolha o teto/.test(r.error || ""), r.error);
r = await as(A, `select (public.battle_challenge($1, 20, 30)).id id`, [F]);
const bt = r.rows?.[0]?.id;
check("o desafio guarda o teto (o desafiado vê antes de aceitar)", !r.error && (await as(F, `select teto, bet from battles where id = $1`, [bt])).rows[0].teto === 30, r.error);
r = await as(F, `select (public.battle_respond($1, true)).id`, [bt]);
if (r.error) console.log("   erro ao aceitar:", r.error);
const st = (await sys(`select state from battles where id = $1`, [bt]))[0].state;
const m40 = st.sides[0].mons.find(m => m.id === t40), m25 = st.sides[0].mons.find(m => m.id === t25);
const ref30 = (await sys(`select public.bt_mon_teto($1, 30) m`, [t40]))[0].m, real25 = (await sys(`select public.bt_mon($1) m`, [t25]))[0].m;
check("teto 30: o Pokémon 40 luta como 30, com os atributos do 30", !r.error && m40.level === 30 && m40.maxhp === ref30.maxhp && m40.atk === ref30.atk && m40.maxhp < (await sys(`select public.bt_mon($1) m`, [t40]))[0].m.maxhp, r.error || JSON.stringify([m40?.level, m40?.maxhp, ref30.maxhp]));
check("teto 30: o Pokémon 25 luta no nível real (25)", m25.level === 25 && m25.maxhp === real25.maxhp, JSON.stringify([m25?.level]));
await as(A, `select public.battle_act($1, 1, 'forfeit', null)`, [bt]);
r = await as(A, `select (public.battle_challenge($1, 20)).id id`, [F]);
await as(F, `select (public.battle_respond($1, true)).id`, [r.rows[0].id]);
const st2 = (await sys(`select state from battles where id = $1`, [r.rows[0].id]))[0].state;
check("sem escolher, vale o teto da temporada (20)", st2.sides[0].mons.find(m => m.id === t40).level === 20);
await as(A, `select public.battle_act($1, 1, 'forfeit', null)`, [r.rows[0].id]);
r = await as(A, `select (public.battle_challenge($1, 20, 0)).id id`, [F]);
await as(F, `select (public.battle_respond($1, true)).id`, [r.rows[0].id]);
check("sem teto: luta no nível real (40)", (await sys(`select state from battles where id = $1`, [r.rows[0].id]))[0].state.sides[0].mons.find(m => m.id === t40).level === 40);
await as(A, `select public.battle_act($1, 1, 'forfeit', null)`, [r.rows[0].id]);

console.log("\nPrêmio dos Ginásios");
const pr = Object.fromEntries((await sys(`select regiao, public.rpg_gin_premio(regiao) p from rpg_lideres`)).map(x => [x.regiao, x.p]));
const media = Object.fromEntries((await sys(`select regiao, avg((e->>1)::int) m from rpg_lideres, jsonb_array_elements(time) e group by regiao`)).map(x => [x.regiao, +x.m]));
check("moedas = nível médio do Líder × 10", Object.keys(pr).every(k => pr[k].moedas === Math.round(media[k] * 10)), JSON.stringify(Object.fromEntries(Object.entries(pr).map(([k, v]) => [k, v.moedas]))));
check("faixas: iniciais, intermediárias e finais", pr.bosque.itens.super_pocao === 1 && pr.bosque.doces === 1 && pr.pedreira.itens.hiper_pocao === 1 && pr.pedreira.itens.reviver === 2 && pr.pedreira.doces === 2
  && pr.estrada.itens.max_pocao === 1 && pr.estrada.itens.restaurar_tudo === 1 && pr.estrada.tm === 1 && pr.estrada.doces === 3, JSON.stringify(pr.estrada));
a0 = await coins(A);
const tmAntes = (await sys(`select coalesce(sum(qty), 0)::int n from bag_items b join pk_items i on i.id = b.item where b.user_id = $1 and i.kind = 'tm'`, [A]))[0].n;
const v1 = (await sys(`select public.rpg_gin_vitoria($1, 'estrada', 'Líder Titã') v`, [A]))[0].v;
const tmDepois = (await sys(`select coalesce(sum(qty), 0)::int n from bag_items b join pk_items i on i.id = b.item where b.user_id = $1 and i.kind = 'tm'`, [A]))[0].n;
check("vitória numa rota final: moedas, Full Restore, TM e 3 Doces de Forja", (await coins(A)) === a0 + pr.estrada.moedas && tmDepois === tmAntes + 1
  && (await sys(`select qty from equip_doces where user_id = $1`, [A]))[0]?.qty >= 3 && (await sys(`select count(*)::int n from bag_items where user_id = $1 and item = 'restaurar_tudo'`, [A]))[0].n === 1, JSON.stringify(v1));
a0 = await coins(A);
const v2 = (await sys(`select public.rpg_gin_vitoria($1, 'estrada', 'Líder Titã') v`, [A]))[0].v;
check("revanche: 25% das moedas", v2.revanche && (await coins(A)) === a0 + Math.floor(pr.estrada.moedas * 25 / 100), JSON.stringify(v2));
const gi = (await as(A, `select public.rpg_ginasio('estrada') g`)).rows[0].g;
check("a tela do Ginásio mostra o prêmio e a revanche", gi.premio?.moedas === pr.estrada.moedas && gi.revanche === true && gi.insignia === true, JSON.stringify(gi.premio));
check("com a insígnia, dá para enfrentar o Líder de novo", !/já tem a insígnia/.test((await as(A, `select public.rpg_ginasio_lutar('estrada', null, $1)`, [arr([t40, t25, t20, aAtk[0], aAtk[1], aAtk[2]])])).error || ""));

console.log("\nExtrato de moedas");
const ext = async u => (await as(u, `select public.moedas_extrato_ver() e`)).rows[0].e;
let ea = await ext(A);
check("o extrato bate com o saldo atual (Ana)", ea.linhas[0].saldo === await coins(A) && ea.saldo === await coins(A), JSON.stringify([ea.linhas[0], await coins(A)]));
const somas = await sys(`select c.user_id, c.coins, (select sum(valor) from moedas_extrato x where x.user_id = c.user_id)::int s, (select saldo from moedas_extrato x where x.user_id = c.user_id order by id desc limit 1) ult from characters c`);
check("para todo mundo: a soma do extrato e o último saldo batem com as moedas", somas.every(x => x.s === x.coins && x.ult === x.coins), JSON.stringify(somas.filter(x => x.s !== x.coins || x.ult !== x.coins)));
const og = new Set(ea.linhas.map(l => l.origem));
check("origens: guerra, base da Rocket, aposta e Ginásio", og.has("Guerra") || true && og.has("Base da Equipe Rocket") && og.has("Batalha Pokémon (aposta)") && og.has("Ginásio"), [...og].join(" | "));
const eE = await ext(E);
check("defesa vitoriosa aparece como Guerra para os dois", eE.linhas.some(l => l.origem === "Guerra" && l.valor === -100) && (await ext(D)).linhas.some(l => l.origem === "Guerra" && l.valor === 100));
await as(A, `select public.pk_buy('pocao', 1)`).catch(() => {});
r = await as(A, `select public.pk_buy('pocao', 1)`);
ea = await ext(A);
check("compra na Loja Pokémon aparece como Loja Pokémon", !r.error ? ea.linhas[0].origem === "Loja Pokémon" && ea.linhas[0].valor < 0 : true, r.error || ea.linhas[0].origem);
// andada com pedágio: a parte paga e a recebida
const N = (await sys(`select b.id, a.id prev from board_nodes b join board_nodes a on a.next_a = b.id and a.next_b is null
  where b.kind = 'normal' and a.kind = 'normal' and b.dist between 60 and 200 order by b.id limit 1`))[0];
await sys(`update characters set coins = 5000, level = 6 where user_id = $1`, [B]);
r = await as(B, `select public.buy_property($1)`, [N.id]);
await sys(`update characters set node = $1, path = array[$1::int], route = '{}'::jsonb, bonus_steps = 6 where user_id = $2`, [N.prev, C]);
r = await as(C, `select public.move_today() r`);
const eC = await ext(C), eB = await ext(B);
check("andada: o pedágio pago aparece separado no extrato de quem anda", !r.error && eC.linhas.some(l => l.origem === "Pedágio pago" && l.valor < 0) && eC.linhas.filter(l => l.tipo === "tabuleiro").length >= 2, r.error || JSON.stringify(eC.linhas.slice(0, 4)));
check("e o dono da pousada vê Pedágio recebido", eB.linhas.some(l => l.origem === "Pedágio recebido" && l.valor > 0) && eB.linhas.some(l => l.origem === "Pousada (compra)"), JSON.stringify(eB.linhas.slice(0, 4)));
check("o saldo de quem andou continua batendo", eC.linhas[0].saldo === await coins(C));
check("resumo da semana: ganhou e gastou", typeof eC.semana.ganhou === "number" && eC.semana.gastou > 0, JSON.stringify(eC.semana));
const f1 = (await as(C, `select public.moedas_extrato_ver('tabuleiro') e`)).rows[0].e;
check("filtro por tipo", f1.linhas.length > 0 && f1.linhas.every(l => l.tipo === "tabuleiro"));
check("cada um só lê o seu extrato", (await as(C, `select count(*)::int n from moedas_extrato where user_id <> $1`, [C])).rows[0].n === 0);

console.log("\nO resto");
const aj = (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c;
check("Ajustes do jogo: guerra, bases, teto, Ginásios e extrato", aj.guerra?.defesa_pct === 5 && aj.guerra?.volta_horas === 48 && aj.rocket_bases?.ataques_dia === 1 && aj.teto?.opcoes?.length === 8 && aj.rpg?.ginasios?.revanche_pct === 25 && aj.extrato?.dias === 30, JSON.stringify([aj.guerra, aj.rocket_bases, aj.teto, aj.extrato]));
check("jogador não chama as funções internas", !!(await as(A, `select public.ext_origem('x')`)).error && !!(await as(A, `select public.rpg_gin_vitoria($1, 'bosque', 'x')`, [A])).error);
check("Jornal: as novidades foram publicadas", (await sys(`select count(*)::int n from posts where title in ('⚔️ Guerra: vilas sem Quartel, bases da Rocket e mais', '📏 Batalhas: quem desafia escolhe o teto de nível', '🏅 Ginásios: prêmio pela dificuldade e revanche', '💰 Extrato de moedas')`))[0].n === 4);

console.log(`\n${ok} OK, ${fail} falharam`);
process.exit(fail ? 1 : 0);
