// Testa o arquivo 125 (guerra sem travamento + impasse, trocas com vitrine e aprovação dupla,
// Rocket com barra histórica + 15 linhas por nível + cobertura + roubo de ativos,
// ataque surpresa às vilas com reforços em teto, limite de 3 revanches pagas/dia,
// descrição real dos golpes no site, último Quiz sempre visível e lama de 72h).
// Uso:  node ferramentas/testar_pacote4.mjs .
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs";
import path from "path";

const root = process.argv[2] || ".";
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql"))
  .filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql")
  .sort((a, b) => parseInt(a) - parseInt(b) || a.localeCompare(b))) {
  await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
}

let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => {
  await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`);
  try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); }
};

const U = i => `${i}${i}${i}${i}${i}${i}${i}${i}-${i}${i}${i}${i}-${i}${i}${i}${i}-${i}${i}${i}${i}-${String(i).repeat(12)}`;
const [A, B, C, D, E, F, ADM] = [1, 2, 3, 4, 5, 6, 9].map(U);
for (const [u, n, h] of [[A, "Ana", "guerreiro"], [B, "Beto", "ladino"], [C, "Caio", "mercador"], [D, "Duda", "guerreiro"], [E, "Edu", "guerreiro"], [F, "Fabi", "guerreiro"], [ADM, "Chefe", "guerreiro"]]) {
  await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]);
  await as(u, `select public.create_character($1, $2)`, [n, h]);
}
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
await sys(`update characters set created_at = now() - interval '30 days', coins = 3000 where true`);
await sys(`update monsters set team_slot = null where true`);
await sys(`update game_config set config = config || '{"rocket": {"days": []}}'::jsonb where active`);
for (const u of [A, B, C, D, E]) {
  await sys(`insert into daily_moves(user_id, move_date, modes, base_steps, roll, bonus_steps, from_node, to_node, xp_gained, coins_gained, events)
             select $1, public.game_today() - 1, '{}', 0, 1, 0, node, node, 0, 0, '[]' from characters where user_id = $1`, [u]);
}

const mk = async (u, sp, lv, moves = null, slot = null) => {
  const id = (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, sp, lv]))[0].id;
  if (moves) await sys(`update monsters set moves = $2 where id = $1`, [id, moves]);
  if (slot) await sys(`update monsters set team_slot = $2 where id = $1`, [id, slot]);
  return id;
};
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;
const arr = ids => `{${ids.join(",")}}`;
const quartel = async u => {
  await sys(`insert into villages(user_id) values ($1) on conflict do nothing`, [u]);
  await sys(`update villages set barracks_level = 1, center_level = 2, shield_until = null where user_id = $1`, [u]);
};

// ============================================================================
// 1. GUERRA DE VILAS: TROCA CONTRA IMUNE, IMPASSE E TETO DE 50 TURNOS
// ============================================================================
console.log("\n1. Guerra de vilas (troca automática, impasse e Night Shade)");
await sys(`update game_config set config = jsonb_set(config, '{war}', coalesce(config->'war', '{}'::jsonb) || '{"match_min": 0, "match_max": 100000}'::jsonb) where active`);
await quartel(A); await quartel(B);

// Caso A: Gengar só com Lick (122) em campo, mas com Pikachu (Thunderbolt 85) no banco vs Raticate só com Tackle (33) -> deve trocar para o Pikachu e vencer sem loop!
const gengarLick = await mk(A, 94, 35, [122]);
const pikaReserva = await mk(A, 25, 45, [85]);
const pidgeyRes = await mk(A, 18, 35, [17]);
const aDef = [await mk(A, 94, 35, [122]), await mk(A, 94, 35, [122]), await mk(A, 94, 35, [122])];
await as(A, `select public.war_squads_salvar($1, $2)`, [arr([gengarLick, pikaReserva, pidgeyRes]), arr(aDef)]);

const bAtk = [await mk(B, 20, 25, [33]), await mk(B, 20, 25, [33]), await mk(B, 20, 25, [33])];
const rat1 = await mk(B, 20, 25, [33]), rat2 = await mk(B, 20, 25, [33]), rat3 = await mk(B, 20, 25, [33]);
await as(B, `select public.war_squads_salvar($1, $2)`, [arr(bAtk), arr([rat1, rat2, rat3])]);

let r = await as(A, `select public.war_attack($1) r`, [B]);
let wr = r.rows?.[0]?.r;
check("Gengar só com Lick troca sozinho pelo colega do esquadrão que acerta o Raticate e vence rápido",
  !r.error && wr.winner === A && wr.details.turns < 20 && wr.details.reason === "nocaute",
  r.error || JSON.stringify(wr?.details));

// Caso B: Impasse total! 3 Gengar só com Lick (122) vs 3 Raticate só com Tackle (33) -> encerra imediatamente por impasse (sem loop!) e vence quem tem maior % de vida!
await sys(`update villages set shield_until = null where true`);
await sys(`delete from wars where true`);
await sys(`update monsters set war_hp = 100 where user_id = $1`, [A]);
await sys(`update monsters set war_hp = 60 where id = $1`, [rat1]); // Beto com menor % de vida somada (60+100+100 vs 100+100+100)
await sys(`delete from war_squad_saidas where true`);
const g1 = await mk(A, 94, 30, [122]), g2 = await mk(A, 94, 30, [122]), g3 = await mk(A, 94, 30, [122]);
await as(A, `select public.war_squads_salvar($1, $2)`, [arr([g1, g2, g3]), arr(aDef)]);
r = await as(A, `select public.war_attack($1) r`, [B]);
wr = r.rows?.[0]?.r;
check("Impasse (Raticate só Normal vs Gengar só Lick): encerra na hora sem loop e vence maior % de vida",
  !r.error && wr.details.reason === "impasse" && wr.details.turns <= 2 && wr.winner === A,
  r.error || JSON.stringify(wr?.details));

// Caso C: Gengar com Lick (122) + Night Shade (101) vs Raticate só com Tackle (33) -> usa Night Shade (nunca Lick!) e vence!
await sys(`delete from wars where true`);
await sys(`delete from war_squad_saidas where true`);
await sys(`update villages set shield_until = null where true`);
await sys(`update monsters set war_hp = 100 where true`);
const gNight = await mk(A, 94, 45, [122, 101]);
await as(A, `select public.war_squads_salvar($1, $2)`, [arr([gNight, g2, g3]), arr(aDef)]);
r = await as(A, `select public.war_attack($1) r`, [B]);
wr = r.rows?.[0]?.r;
const btLog = (await sys(`select log from battles where id = $1`, [wr.battle_id]))[0].log;
const txtAll = JSON.stringify(btLog);
check("Gengar com Lick + Night Shade nunca usa Lick no Raticate: usa Night Shade e vence",
  !r.error && wr.winner === A && txtAll.includes("Night Shade") && !txtAll.includes("usou Lick"),
  r.error || txtAll.slice(0, 300));
check("Limite da guerra está em 50 turnos", (await sys(`select (config->'war'->>'max_turns')::int m from game_config where active`))[0].m === 50);

// ============================================================================
// 2. TROCAS DE POKÉMON: VITRINE E DUPLA APROVAÇÃO
// ============================================================================
console.log("\n2. Trocas de Pokémon (vitrine e aprovação dos dois lados)");
const dVit = await mk(D, 16, 15);    // Pidgey na vitrine
const dSec1 = await mk(D, 150, 70);  // Mewtwo fora da vitrine (secreto!)
const dSec2 = await mk(D, 149, 55);  // Dragonite fora da vitrine (mas Duda pode escolher dar no passo 2!)
await as(D, `select public.mon_troca_vitrine($1, true)`, [dVit]);

const colDPorC = (await as(C, `select public.troca_colecao($1) c`, [D])).rows[0].c;
const rawDPorC = (await as(C, `select id from monsters where user_id = $1`, [D])).rows;
check("Vitrine: outro jogador vê SÓ os Pokémon marcados como 'aceito trocar' (tanto na função quanto na tabela)",
  colDPorC.length === 1 && colDPorC[0].id === dVit && rawDPorC.length === 1 && rawDPorC[0].id === dVit,
  JSON.stringify([colDPorC, rawDPorC]));
check("O próprio dono continua vendo a coleção inteira dele",
  (await as(D, `select public.troca_colecao($1) c`, [D])).rows[0].c.length >= 3);
check("Não dá para pedir na proposta um Pokémon fora da vitrine do outro",
  /vitrine/.test((await as(C, `select public.troca_propor($1, $2, $3, 0)`, [D, await mk(C, 19, 10), dSec1])).error || ""));

// Fluxo completo em 3 passos com Haunter (evolui!) + moedas dos dois lados
const haunterC = await mk(C, 93, 30);
const cAntes = await coins(C), dAntes = await coins(D);
r = await as(C, `select public.troca_propor($1, $2, $3, 100) r`, [D, haunterC, dVit]);
const tid = r.rows?.[0]?.r?.id;
check("Passo 1: Caio envia proposta com 100 moedas guardadas; Pokémon ainda não trocou de dono",
  !r.error && !!tid && (await coins(C)) === cAntes - 100 && (await sys(`select user_id from monsters where id = $1`, [haunterC]))[0].user_id === C,
  r.error);
check("Passo 2: Duda não pode aprovar direto sem escolher o Pokémon dela",
  /Escolha primeiro/.test((await as(D, `select public.troca_responder($1, true)`, [tid])).error || ""));

// Duda escolhe dar dSec2 (que NÃO estava na vitrine, mas é da coleção dela!) + 200 moedas
r = await as(D, `select public.troca_escolher($1, $2, $3) r`, [tid, dSec2, 200]);
check("Passo 2: Duda escolhe qualquer Pokémon elegível da coleção dela + 200 moedas -> vai para confirmação do 1º jogador, ainda sem trocar dono",
  !r.error && r.rows[0].r.status === "confirmar" && (await coins(D)) === dAntes - 200
  && (await sys(`select user_id from monsters where id = $1`, [haunterC]))[0].user_id === C
  && (await sys(`select user_id from monsters where id = $1`, [dSec2]))[0].user_id === D,
  r.error);
check("Duda não pode dar a aprovação final no lugar do Caio",
  /quem enviou/.test((await as(D, `select public.troca_responder($1, true)`, [tid])).error || ""));

// Passo 3: Caio (Mercador: 0% taxa) aprova; Duda (Guerreiro: 5% taxa sobre 100 = 5) recebe 95!
r = await as(C, `select public.troca_responder($1, true) r`, [tid]);
check("Passo 3: Caio aprova -> troca concluída com as duas aprovações, Haunter evoluiu para Gengar e taxas certas",
  !r.error && r.rows[0].r.status === "aceita"
  && (await sys(`select user_id, species_id from monsters where id = $1`, [haunterC]))[0].user_id === D
  && (await sys(`select species_id from monsters where id = $1`, [haunterC]))[0].species_id === 94
  && (await sys(`select user_id from monsters where id = $1`, [dSec2]))[0].user_id === C
  && (await coins(C)) === cAntes - 100 + 200
  && (await coins(D)) === dAntes - 200 + 95,
  r.error || JSON.stringify([await coins(C), await coins(D)]));

// Cancelamento pelo 2º jogador e expiração em 24h devolvendo moedas dos dois lados
const mC2 = await mk(C, 10, 5), mD2 = await mk(D, 13, 5);
const cPre = await coins(C), dPre = await coins(D);
const tCancel = (await as(C, `select public.troca_propor($1, $2, null, 80) r`, [D, mC2])).rows[0].r.id;
await as(D, `select public.troca_escolher($1, $2, 60)`, [tCancel, mD2]);
r = await as(D, `select public.troca_cancelar($1)`, [tCancel]);
check("Qualquer um dos dois pode cancelar antes da conclusão e todas as moedas voltam",
  !r.error && (await coins(C)) === cPre && (await coins(D)) === dPre, r.error);

const tExp = (await as(C, `select public.troca_propor($1, $2, null, 50) r`, [D, mC2])).rows[0].r.id;
await as(D, `select public.troca_escolher($1, $2, 70)`, [tExp, mD2]);
await sys(`update trocas set expira_em = now() - interval '1 minute' where id = $1`, [tExp]);
await as(C, `select public.troca_minhas()`);
check("Expiração em 24h devolve as moedas guardadas dos dois lados",
  (await coins(C)) === cPre && (await coins(D)) === dPre && (await sys(`select status from trocas where id = $1`, [tExp]))[0].status === "expirou");

// ============================================================================
// 3. EQUIPE ROCKET: BARRA HISTÓRICA, 15 LINHAS POR NÍVEL, COBERTURA E GENGAR
// ============================================================================
console.log("\n3. Equipe Rocket (barra por ativos + histórico, níveis de evolução e ondas contra Gengar)");
// Simula uma invasão pré-122 (media is null) no banco: NÃO pode contaminar a barra!
await sys(`insert into rocket_raids(starts_at, ends_at, level, team, players, hp_total, hp_left, status, media)
           values (now() - interval '10 days', now() - interval '9 days', 20, '[]'::jsonb, 5, 500, 0, 'vitoria', null)`);
const nAtivos = (await sys(`select count(distinct a.user_id)::int n from public.day_active(public.game_today()) a where exists (select 1 from monsters m where m.user_id = a.user_id)`))[0].n;
await as(ADM, `select public.admin_rocket_start(24)`);
let raid1 = (await as(A, `select public.rocket_current() r`)).rows[0].r;
check("Sem histórico de ondas (ignorando invasão antiga), a barra usa 250 × jogadores ativos",
  raid1.hp_total === 250 * nAtivos && Number(raid1.media) === 250, JSON.stringify([raid1.hp_total, nAtivos, raid1.media]));

// Simula exatamente o histórico do teste relatado (1.070 e 187 -> média 628,5) e fecha como vitória (mult vai a 1,05)
const gengarRaid = await mk(A, 94, 42, [94, 85, 101, 109]);
const bidRk = (await as(A, `select public.rocket_join($1) b`, [gengarRaid])).rows[0].b;
const rkMon2 = await mk(B, 9, 30);
await as(B, `select public.rocket_join($1)`, [rkMon2]);
await sys(`update rocket_entries set damage = 1070, ondas = 9, done = true where raid_id = $1 and user_id = $2`, [raid1.id, A]);
await sys(`update rocket_entries set damage = 187, ondas = 4, done = true where raid_id = $1 and user_id = $2`, [raid1.id, B]);
await sys(`update battles set status = 'encerrada' where id = $1`, [bidRk]);
await sys(`select public.rocket_win($1)`, [raid1.id]);

// Próxima invasão já usa o histórico desde a 1ª invasão (sem esperar 3!): ceil(628.5 * nAtivos * 1.05)
await as(ADM, `select public.admin_rocket_start(24)`);
let raid2 = (await as(A, `select public.rocket_current() r`)).rows[0].r;
const esperadoHp2 = Math.ceil(628.5 * nAtivos * 1.05);
check("A partir da 1ª invasão em ondas, a barra já usa a média histórica (~628,5 × ativos × mult)",
  raid2.hp_total === esperadoHp2 && Math.abs(Number(raid2.media) - 628.5) < 0.2,
  JSON.stringify({ hp: raid2.hp_total, esperadoHp2, media: raid2.media, mult: raid2.mult }));

// Confere níveis de evolução em todos os níveis de 5 a 45
let erroEvo = "";
for (let lv = 5; lv <= 45; lv++) {
  const sps = (await sys(`select public.rocket_especies_nivel($1) s`, [lv]))[0].s;
  if (lv < 16 && (sps.includes(64) || sps.includes(65))) erroEvo = `Kadabra/Alakazam no nv ${lv}`;
  if (lv < 40 && sps.includes(65)) erroEvo = `Alakazam no nv ${lv}`;
  if (lv >= 40 && !sps.includes(65)) erroEvo = `Faltou Alakazam no nv ${lv}`;
  if (lv < 35 && (sps.includes(59) || sps.includes(71) || sps.includes(110))) erroEvo = `Arcanine/Victreebel/Weezing no nv ${lv}`;
  if (lv >= 35 && (!sps.includes(59) || !sps.includes(71) || !sps.includes(110))) erroEvo = `Faltou evoluído 35 no nv ${lv}`;
  if (lv < 20 && sps.includes(20)) erroEvo = `Raticate no nv ${lv}`;
  if (lv < 21 && (sps.includes(70) || sps.includes(71))) erroEvo = `Weepinbell no nv ${lv}`;
  if (lv < 22 && (sps.includes(24) || sps.includes(42) || sps.includes(28))) erroEvo = `Evoluído 22 no nv ${lv}`;
  if (lv < 26 && sps.includes(97)) erroEvo = `Hypno no nv ${lv}`;
  if (lv < 28 && (sps.includes(105) || sps.includes(53) || sps.includes(67))) erroEvo = `Evoluído 28 no nv ${lv}`;
  if (lv < 30 && sps.includes(82)) erroEvo = `Magneton no nv ${lv}`;
  if (lv < 38 && sps.includes(89)) erroEvo = `Muk no nv ${lv}`;
  if (!sps.includes(108)) erroEvo = `Faltou Lickitung no nv ${lv}`;
  if (erroEvo) break;
}
check("Níveis de evolução respeitados: <40 nunca traz Alakazam, <35 nunca traz Arcanine/Victreebel/Weezing, <16 nunca traz Kadabra",
  !erroEvo, erroEvo);

// Cobertura e ondas contra Gengar cedido
const mPersian = (await sys(`select public.rocket_moves(53, 30) m`))[0].m;
const mArbok = (await sys(`select public.rocket_moves(24, 30) m`))[0].m;
const mWeezing = (await sys(`select public.rocket_moves(110, 36) m`))[0].m;
const mLicki = (await sys(`select public.rocket_moves(108, 30) m`))[0].m;
check("Golpes de cobertura na Rocket (Persian Bubblebeam/Thunderbolt, Arbok Earthquake, Weezing Thunderbolt/Fire Blast, Lickitung Earthquake/Ice Beam)",
  mPersian.includes(61) && mPersian.includes(85) && mArbok.includes(89) && mWeezing.includes(85) && mWeezing.includes(126) && mLicki.includes(89) && mLicki.includes(58),
  JSON.stringify({ mPersian, mArbok, mWeezing, mLicki }));

// Testa 12 ondas seguidas contra um Gengar (FANTASMA/VENENO): todas devem ter golpe >= 1x e pelo menos 1 a cada 3 deve ter vantagem (> 1x)
let rkState = { ondas: 0, onda: 1, base: 30, def_t1: "FANTASMA", def_t2: "VENENO", sem_vant: 0, ult_sp: 0 };
const effsGengar = [];
for (let onda = 1; onda <= 12; onda++) {
  const row = (await sys(`
    with w as (select public.rocket_onda_mon($1::jsonb, $2, false) m)
    select (m->>'species')::int sp, (m->>'name') nm, public.rocket_melhor_eff(m, 'FANTASMA', 'VENENO') eff from w
  `, [JSON.stringify(rkState), onda]))[0];
  effsGengar.push(+row.eff);
  rkState = { ...rkState, ondas: onda, onda: onda + 1, ult_sp: row.sp, sem_vant: +row.eff > 1 ? 0 : rkState.sem_vant + 1 };
}
const todasAcertam = effsGengar.every(e => e >= 1);
const janelas3Ok = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].every(i => effsGengar.slice(i, i + 3).some(e => e > 1));
check("Gengar cedido: todas as 12 ondas acertam com dano >= 1x e toda janela de 3 ondas tem vantagem de tipo (> 1x)",
  todasAcertam && janelas3Ok, JSON.stringify(effsGengar));

// E em batalha real contra a Rocket, o Gengar cedido leva dano de verdade!
const bidGengar = (await as(A, `select public.rocket_join($1) b`, [gengarRaid])).rows[0].b;
for (let t = 1; t <= 4; t++) {
  const bCur = (await sys(`select turn, status from battles where id = $1`, [bidGengar]))[0];
  if (bCur.status !== "ativa") break;
  await as(A, `select public.battle_act($1, $2, 'move', 0)`, [bidGengar, bCur.turn]);
}
const stAfter = (await sys(`select state from battles where id = $1`, [bidGengar]))[0].state;
check("Na luta real da invasão, a Rocket causa dano no Gengar cedido",
  stAfter.sides[0].mons[0].hp < stAfter.sides[0].mons[0].maxhp,
  `${stAfter.sides[0].mons[0].hp}/${stAfter.sides[0].mons[0].maxhp}`);

// ============================================================================
// 4. ROUBO NA DERROTA: INCLUI JOGADORES ATIVOS QUE NÃO PARTICIPARAM (PESO 2)
// ============================================================================
console.log("\n4. Roubo na derrota da Rocket (ativos não participantes entram com peso 2)");
// Fecha raid2 e cria uma invasão onde NINGUÉM participou, mas E (ativo) tem Pokémon na equipe!
await sys(`update rocket_raids set status = 'vitoria' where id = $1`, [raid2.id]);
await sys(`update monsters set team_slot = null where true`);
const eTeamMon = await mk(E, 25, 22, null, 1); // Edu está ativo e tem Pikachu no slot 1 da equipe, sem participar!
await as(ADM, `select public.admin_rocket_start(24)`);
const raidSemPart = (await as(A, `select public.rocket_current() r`)).rows[0].r;
await sys(`select public.rocket_lose($1)`, [raidSemPart.id]);
const raidRoubo = (await sys(`select * from rocket_raids where id = $1`, [raidSemPart.id]))[0];
const baseRoubo = (await sys(`select * from rocket_bases where dono = $1 and tipo = 'resgate' and ativa`, [E]))[0];
check("Derrota: jogador ativo que NÃO participou é sorteado e perde 1 Pokémon da equipe para esconderijo de 7 dias",
  raidRoubo.stolen_user === E && !!baseRoubo && (await sys(`select count(*)::int n from monsters where id = $1`, [eTeamMon]))[0].n === 0,
  JSON.stringify([raidRoubo.stolen_user, !!baseRoubo]));
check("Aviso da invasão alerta que quem não participar também pode perder Pokémon",
  (await sys(`select count(*)::int n from event_log where kind = 'rocket' and message like '%Quem não participar também pode perder um Pokémon%'`))[0].n >= 1);

// Confere proporção ~2:1 entre não-participante (E) e participante (D) em múltiplas simulações em transação revertida
const dPartMon = await mk(D, 133, 20);
const eEq2 = await mk(E, 25, 20, null, 1);
let cntAus = 0, cntPart = 0;
await db.exec("begin");
for (let i = 0; i < 90; i++) {
  await db.exec("savepoint sp_roubo");
  await as(ADM, `select public.admin_rocket_start(24)`);
  const rid = (await sys(`select id from rocket_raids where status = 'ativa' order by id desc limit 1`))[0].id;
  await sys(`insert into rocket_entries(raid_id, user_id, name, mon_id, mon_name, species, level) values ($1, $2, 'Duda', $3, 'Eevee', 133, 20)`, [rid, D, dPartMon]);
  await sys(`select public.rocket_lose($1)`, [rid]);
  const su = (await sys(`select stolen_user from rocket_raids where id = $1`, [rid]))[0].stolen_user;
  if (su === E) cntAus++; else if (su === D) cntPart++;
  await db.exec("rollback to savepoint sp_roubo");
}
await db.exec("rollback");
check("Peso 2 para quem não participou vs peso 1 para quem participou",
  cntAus > cntPart && cntAus >= 42 && cntPart >= 12, `ausente=${cntAus}, participou=${cntPart}`);

// Giovanni também rouba de jogador ativo que não participou (sorteando 1 da equipe)
await db.exec("begin");
await sys(`update monsters set team_slot = null where true`);
const eGioEq = await mk(E, 6, 36, null, 2);
await sys(`update rocket_meta set giovanni_pendente = true where id = 1`);
await as(ADM, `select public.admin_rocket_start(24)`);
const gioId = (await sys(`select id from rocket_raids where status = 'ativa' order by id desc limit 1`))[0].id;
await sys(`select public.rocket_lose($1)`, [gioId]);
check("Giovanni na derrota também sorteia ativo que não participou e leva 1 Pokémon da equipe (preso para revanche)",
  (await sys(`select count(*)::int n from rocket_roubados where raid_id = $1 and user_id = $2 and status = 'preso'`, [gioId, E]))[0].n === 1
  && (await sys(`select count(*)::int n from monsters where id = $1`, [eGioEq]))[0].n === 0);
await db.exec("rollback");

// ============================================================================
// 5. ATAQUE SURPRESA DA ROCKET ÀS VILAS (24H, REFORÇOS EM TETO, VITÓRIA, DERROTA, 0 KO)
// ============================================================================
console.log("\n5. Ataque surpresa da Rocket às vilas");
// Dias da semana nunca caem em domingo (0), terça (2) ou sexta (5)
await sys(`update game_config set config = jsonb_set(config, '{rocket,days}', '[0,2,5]'::jsonb) where active`);
const diasSem = (await sys(`select public.rocket_vila_dias_semana(date '2026-11-16') d`))[0].d;
check("2 dias sorteados na semana nunca caem em dia de invasão da Rocket (terça, sexta e domingo)",
  diasSem.length === 2 && diasSem.every(d => ![0, 2, 5].includes(d)), JSON.stringify(diasSem));

// Fabi (F) entrou há menos de 7 dias e não moveu -> nunca entra no sorteio
await sys(`update characters set created_at = now() - interval '2 days', coins = 999999 where user_id = $1`, [F]);
await mk(F, 6, 50, null, 1);

// Sorteia ataque para Ana (que tem Pokémon máximo nível 25)
await sys(`delete from monsters where user_id = $1`, [A]);
const aDef1 = await mk(A, 6, 25, [53, 89], 1), aDef2 = await mk(A, 9, 25, [57, 58], 2), aDef3 = await mk(A, 3, 25, [75, 34], 3);
await sys(`delete from war_squads where user_id = $1`, [A]);
await sys(`delete from war_squad_saidas where true`);
await as(A, `select public.war_squads_salvar($1, $2)`, [arr([]), arr([aDef1, aDef2, aDef3])]);

const aid1 = (await sys(`select public.rocket_vila_sortear($1) id`, [A]))[0].id;
const estVila = (await as(A, `select public.rocket_vila_estado() e`)).rows[0].e;
const ag1 = estVila.agendados.find(x => x.id === +aid1);
const hrsAviso = (new Date(ag1.ataca_em) - new Date(ag1.avisado_em)) / 36e5;
check("Aviso com 24h de antecedência criado na vila, nos Acontecimentos e no Jornal",
  !!ag1 && hrsAviso > 23.9 && hrsAviso <= 24.1
  && (await sys(`select count(*)::int n from posts where title like '%Ataque surpresa da Rocket à vila de Ana%'`))[0].n === 1,
  JSON.stringify(ag1));

// 2 amigos emprestam Pokémon (Beto empresta Mewtwo nível 80 -> deve cair para o teto nível 25 da Ana!)
const bMewtwo80 = await mk(B, 150, 80, [94, 85]);
const cAlakazam60 = await mk(C, 65, 60, [94]);
const dExtra = await mk(D, 149, 60);
let empB = await as(B, `select public.rocket_vila_emprestar($1, $2) r`, [aid1, bMewtwo80]);
let empC = await as(C, `select public.rocket_vila_emprestar($1, $2) r`, [aid1, cAlakazam60]);
let empD = await as(D, `select public.rocket_vila_emprestar($1, $2) r`, [aid1, dExtra]);
check("Até 2 amigos podem emprestar 1 Pokémon cada, e o nível de luta fica no máximo no Pokémon mais forte do dono (25)",
  !empB.error && empB.rows[0].r.nivel_luta === 25 && !empC.error && empC.rows[0].r.nivel_luta === 25 && /limite de 2/.test(empD.error || ""),
  JSON.stringify([empB, empC, empD]));

// Vitória da defesa: forçamos a hora do ataque e garantimos vitória (Torre de Defesa alta / cura cheia)
await sys(`update villages set wall_level = 3, def_level = 5 where user_id = $1`, [A]).catch(() => {});
// Para garantir vitória determinística no teste de prêmio, ajustamos forca_min_pct = 50, forca_max_pct = 50 só nesta resolução, depois testamos 100..120!
const aCoins0 = await coins(A), bCoins0 = await coins(B), cCoins0 = await coins(C);
const bExp0 = +(await sys(`select exp from monsters where id = $1`, [bMewtwo80]))[0].exp;
const aExp0 = +(await sys(`select exp from monsters where id = $1`, [aDef1]))[0].exp;

// Primeiro confere que com config padrão (100%..120%) a força da Rocket fica entre 100% e 120% da defesa completa:
await db.exec("begin");
const resPct = (await sys(`select public.rocket_vila_resolver($1) r`, [aid1]))[0].r;
const rowPct = (await sys(`select def_forca, rk_forca, rk_pct from rocket_vila_ataques where id = $1`, [aid1]))[0];
check("Força da Rocket fica entre 100% e 120% da defesa completa (com reforços em teto)",
  rowPct.rk_pct >= 100 && rowPct.rk_pct <= 120 && rowPct.rk_forca >= Math.floor(rowPct.def_forca * 0.92) && rowPct.rk_forca <= Math.ceil(rowPct.def_forca * 1.28),
  JSON.stringify(rowPct));
await db.exec("rollback");

// Agora resolve uma vitória limpa para testar prêmios (75..200, +25% extra para ajudantes, XP, defesas vencidas)
await sys(`update game_config set config = jsonb_set(config, '{rocket_vila}', '{"forca_min_pct": 40, "forca_max_pct": 40}'::jsonb) where active`);
await sys(`update rocket_vila_ataques set ataca_em = now() - interval '1 minute' where id = $1`, [aid1]);
await as(B, `select public.village_state()`); // resolve sozinho mesmo com a dona (Ana) offline!
await sys(`update game_config set config = config - 'rocket_vila' where active`);
const atkVit = (await sys(`select * from rocket_vila_ataques where id = $1`, [aid1]))[0];
const bBonusEsp = Math.max(1, Math.round(atkVit.moedas * 0.25));
check("Vitória offline: defensor ganha 75 a 200 moedas e XP; amigos ganham +25% extra (sem descontar do defensor) e XP no emprestado",
  atkVit.status === "vitoria" && atkVit.moedas >= 75 && atkVit.moedas <= 200
  && (await coins(A)) === aCoins0 + atkVit.moedas
  && (await coins(B)) === bCoins0 + bBonusEsp
  && (await coins(C)) === cCoins0 + bBonusEsp
  && +(await sys(`select exp from monsters where id = $1`, [bMewtwo80]))[0].exp > bExp0
  && +(await sys(`select exp from monsters where id = $1`, [aDef1]))[0].exp > aExp0,
  JSON.stringify([atkVit, await coins(A) - aCoins0, await coins(B) - bCoins0]));

const rkDef = await sys(`select * from public.season_rank('defesas', now() - interval '1 day', now() + interval '1 day') where user_id = $1`, [A]);
check("Vitória contra a Rocket conta em 'defesas vencidas' nos prêmios da temporada",
  rkDef.length === 1 && +rkDef[0].val >= 1, JSON.stringify(rkDef));

// Mesma vila não pode ser sorteada de novo em menos de 7 dias
await db.exec("begin");
for (let i = 0; i < 15; i++) {
  await db.exec("savepoint sp_cd");
  const sId = (await sys(`select public.rocket_vila_sortear() id`))[0].id;
  const uId = sId ? (await sys(`select user_id from rocket_vila_ataques where id = $1`, [sId]))[0].user_id : null;
  if (uId === A || uId === F) { check("Cooldown de 7 dias e exclusão de conta < 7 dias", false, uId); break; }
  await db.exec("rollback to savepoint sp_cd");
  if (i === 14) check("Mesma vila não entra em novo sorteio antes de 7 dias (nem conta com < 7 dias)", true);
}
await db.exec("rollback");

// Derrota sem derrubar nenhum Pokémon da Rocket: perde 10% desprotegido (até 200), 1 construção danificada, escudo 24h, ajudante não perde nada, e leva 1 Pokémon DO DONO (nunca o emprestado!)
await sys(`insert into villages(user_id) values ($1) on conflict do nothing`, [D]);
await sys(`update villages set mine_level = 2, damaged = '{}'::jsonb, shield_until = null, barracks_level = 0 where user_id = $1`, [D]);
await sys(`update characters set coins = 1500 where user_id = $1`, [D]);
await sys(`delete from monsters where user_id = $1`, [D]);
const dMagikarp = await mk(D, 129, 5, [150], 1); // Magikarp nv 5 só com Splash -> 0 derrubados!
const aidDer = (await sys(`select public.rocket_vila_sortear($1) id`, [D]))[0].id;
const bSplash = await mk(B, 129, 5, [150]);
await as(B, `select public.rocket_vila_emprestar($1, $2)`, [aidDer, bSplash]);
const dCoinsPre = await coins(D), bCoinsPre = await coins(B);
await sys(`update game_config set config = jsonb_set(config, '{rocket_vila}', '{"forca_min_pct": 300, "forca_max_pct": 300}'::jsonb) where active`);
await sys(`select public.rocket_vila_resolver($1)`, [aidDer]);
await sys(`update game_config set config = config - 'rocket_vila' where active`);

const atkDer = (await sys(`select * from rocket_vila_ataques where id = $1`, [aidDer]))[0];
const vD = (await sys(`select * from villages where user_id = $1`, [D]))[0];
check("Derrota: perde 10% das moedas desprotegidas (até 200), 1 construção danificada, escudo de 24h e ajudante não perde nada",
  atkDer.status === "derrota" && atkDer.saque > 0 && atkDer.saque <= 200
  && (await coins(D)) === dCoinsPre - atkDer.saque
  && Object.keys(vD.damaged || {}).length === 1
  && new Date(vD.shield_until) > new Date(Date.now() + 23 * 36e5)
  && (await coins(B)) === bCoinsPre
  && (await sys(`select user_id from monsters where id = $1`, [bSplash]))[0]?.user_id === B,
  JSON.stringify([atkDer, vD.damaged, vD.shield_until]));
check("Derrota com 0 derrubados: a Rocket leva 1 Pokémon DO DONO (nunca o emprestado) para esconderijo de resgate",
  atkDer.rk_caidos === 0 && !!atkDer.roubado_info
  && (await sys(`select count(*)::int n from monsters where id = $1`, [dMagikarp]))[0].n === 0
  && (await sys(`select count(*)::int n from rocket_bases where dono = $1 and tipo = 'resgate' and ativa`, [D]))[0].n === 1);

// ============================================================================
// 6. REVANCHES DE GINÁSIO: SÓ AS 3 PRIMEIRAS DO DIA PAGAM MOEDAS
// ============================================================================
console.log("\n6. Revanches de ginásio (limite de 3 pagas no dia)");
for (const reg of ["bosque", "praia", "deserto", "pedreira"]) {
  await sys(`insert into rpg_insignias(user_id, regiao) values ($1, $2) on conflict do nothing`, [A, reg]);
}
let gInfo = (await as(A, `select public.rpg_ginasio('bosque') g`)).rows[0].g;
check("Tela do ginásio informa 3 revanches pagas restantes hoje", gInfo.revanche_restantes === 3 && gInfo.revanche_pagas_dia === 3);

const cGin0 = await coins(A);
const rv1 = (await sys(`select public.rpg_gin_vitoria($1, 'bosque', 'Líder Flora') v`, [A]))[0].v;
const rv2 = (await sys(`select public.rpg_gin_vitoria($1, 'praia', 'Líder Marina') v`, [A]))[0].v;
const rv3 = (await sys(`select public.rpg_gin_vitoria($1, 'deserto', 'Líder Brasa') v`, [A]))[0].v;
const cGin3 = await coins(A);
const rv4 = (await sys(`select public.rpg_gin_vitoria($1, 'pedreira', 'Líder Rocha') v`, [A]))[0].v;
const cGin4 = await coins(A);
gInfo = (await as(A, `select public.rpg_ginasio('pedreira') g`)).rows[0].g;
check("As 3 primeiras revanches vencidas do dia pagam moedas; a 4ª não paga moedas (0) e mostra 0 restantes",
  rv1.premio.moedas > 0 && rv2.premio.moedas > 0 && rv3.premio.moedas > 0 && cGin3 > cGin0
  && rv4.revanche_sem_moedas === true && rv4.premio.moedas === 0 && cGin4 === cGin3 && gInfo.revanche_restantes === 0,
  JSON.stringify([rv1, rv2, rv3, rv4, gInfo.revanche_restantes]));

// ============================================================================
// 7. RESULTADO DO ÚLTIMO QUIZ ENCERRADO SEMPRE VISÍVEL
// ============================================================================
console.log("\n7. Resultado do último Quiz encerrado");
const qz1 = (await as(ADM, `select * from public.admin_quiz_save('Quiz Antigo', '', '100 moedas', 'Quantos dentes tem o Golbat?', 4, 20, 24)`)).rows[0].id;
await sys(`insert into quiz_entries(quiz_id, user_id, revealed_at, answered_at, guess) values ($1, $2, now() - interval '10 seconds', now() - interval '5 seconds', 5)`, [qz1, A]);
await sys(`insert into quiz_entries(quiz_id, user_id, revealed_at, answered_at, guess) values ($1, $2, now() - interval '10 seconds', now() - interval '3 seconds', 8)`, [qz1, B]);
await as(ADM, `select public.admin_quiz_close($1)`, [qz1]);
await sys(`update quizzes set closed_at = now() - interval '5 days' where id = $1`, [qz1]);
let qCur = (await as(A, `select public.quiz_current() q`)).rows[0].q;
check("Mesmo após mais de 3 dias sem quiz novo, o último resultado continua visível",
  qCur?.status === "encerrado" && +qCur.answer === 4 && qCur.winner === A && qCur.results.length === 2);

await as(ADM, `select * from public.admin_quiz_save('Quiz Novo', '', '200 moedas', 'Pergunta nova?', 99, 20, 24)`);
qCur = (await as(A, `select public.quiz_current() q`)).rows[0].q;
check("Com um quiz novo aberto, o resultado completo do último quiz encerrado continua em 'ultimo' (pergunta, resposta, palpites, tempos e vencedor)",
  qCur?.status === "aberto" && qCur.answer == null
  && qCur.ultimo?.id === qz1 && qCur.ultimo.question === "Quantos dentes tem o Golbat?"
  && +qCur.ultimo.answer === 4 && qCur.ultimo.winner === A && qCur.ultimo.winner_name === "Ana"
  && qCur.ultimo.results.length === 2 && qCur.ultimo.results[0].tempo != null,
  JSON.stringify(qCur?.ultimo));

// ============================================================================
// 8. LAMA NA VILA (72 HORAS) + VERIFICAÇÃO DO SITE E DO EXTRATO
// ============================================================================
console.log("\n8. Lama na vila (72h) e conferência final");
await sys(`insert into villages(user_id) values ($1) on conflict do nothing`, [C]);
await sys(`update villages set mud = 2, mud_at = now() - interval '40 hours' where user_id = $1`, [C]);
let vSt = (await as(C, `select public.village_state() v`)).rows[0].v;
check("Antes de 72h a lama continua lá (com mud_free_at calculado) e dá para limpar pagando",
  vSt.mud === 2 && !!vSt.mud_free_at);
const cClean0 = await coins(C);
await as(C, `select public.village_clean()`);
check("Limpar antes pagando continua funcionando", (await coins(C)) < cClean0 && (await as(C, `select public.village_state() v`)).rows[0].v.mud === 0);

await sys(`update villages set mud = 3, mud_at = now() - interval '73 hours' where user_id = $1`, [C]);
vSt = (await as(C, `select public.village_state() v`)).rows[0].v;
check("Depois de 72h a lama sai sozinha sem gastar moedas", vSt.mud === 0 && vSt.mud_free_at == null);

// Site: função de efeito real dos golpes presente e sem expor probabilidades proibidas
const html = fs.readFileSync(path.join(root, "deploy/index.html"), "utf8");
check("Site tem moveEffectTxt cobrindo Thrash, Toxic, Wrap e golpes sem efeito",
  html.includes("function moveEffectTxt(") && html.includes("THRASH_PETAL_DANCE_EFFECT") && html.includes("veneno comum neste jogo"));

// Extrato de moedas: soma e último saldo batem para todos os personagens!
const somas = await sys(`
  select c.name, c.coins,
         (select sum(valor)::int from moedas_extrato x where x.user_id = c.user_id) as soma,
         (select saldo from moedas_extrato x where x.user_id = c.user_id order by id desc limit 1) as ult
    from characters c
`);
check("Extrato de moedas continua batendo 100% com o saldo de todos os jogadores",
  somas.every(x => x.soma === x.coins && x.ult === x.coins),
  JSON.stringify(somas.filter(x => x.soma !== x.coins || x.ult !== x.coins)));

const aj = (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c;
check("Ajustes do jogo incluem rocket_vila, revanche_pagas_dia e mud_auto_hours",
  aj.rocket_vila?.por_semana === 2 && aj.rpg?.ginasios?.revanche_pagas_dia === 3 && aj.base?.mud_auto_hours === 72);

console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
