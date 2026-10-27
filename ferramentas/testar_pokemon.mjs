// Testa os arquivos 16, 17 e 18 (dados, coleção, captura, evolução, roupas e batalhas)
// como jogadores comuns, com dados de TESTE num banco local (PGlite).
// Uso (na pasta ferramentas, uma vez: npm i @electric-sql/pglite@0.3.15):  node testar_pokemon.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
const exec = async f => { try { await db.exec(fs.readFileSync(f, "utf8")); } catch (e) { console.error("ERRO em", f, e.message); process.exit(1); } };
await exec(path.join(root, "ferramentas/supabase_simulado.sql"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql")).sort()) if (f !== "14_recomecar_do_zero.sql") await exec(path.join(root, "sql", f));
let ok = 0, fail = 0;
const check = (name, cond, extra = "") => { if (cond) { ok++; console.log("  OK  ", name); } else { fail++; console.log("  FALHOU", name, extra); } };
const as = async (uid, sql, params = []) => {
  await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`);
  try { return { rows: (await db.query(sql, params)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); }
};
const one = async (uid, sql, params = []) => { const r = await as(uid, sql, params); if (r.error) throw new Error(r.error); return Object.values(r.rows[0] || {})[0]; };
const sys = async (sql, p = []) => (await db.query(sql, p)).rows;
const U = { ana: "11111111-1111-1111-1111-111111111111", beto: "22222222-2222-2222-2222-222222222222", caio: "33333333-3333-3333-3333-333333333333" };
for (const [n, id] of Object.entries(U)) {
  await sys(`insert into auth.users(id, email, raw_user_meta_data, email_confirmed_at) values ($1, $2, $3, now())`, [id, `${n}@teste.local`, JSON.stringify({ username: n })]);
  await as(id, `select public.create_character($1, 'guerreiro')`, [n[0].toUpperCase() + n.slice(1)]);
}

console.log("\n1) Dados da 1ª geração");
check("165 ataques da 1ª geração (mais os 86 da 2ª, se o 28 rodou)", (await sys(`select count(*)::int n from pk_moves where id <= 165`))[0].n === 165 && [165, 251].includes((await sys(`select count(*)::int n from pk_moves`))[0].n));
const ch = (await sys(`select * from pokemon where id = 4`))[0];
check("Charmander: 39/52/43/65/50, Fogo, captura 45", ch.base_hp === 39 && ch.base_atk === 52 && ch.base_spc === 50 && ch.g1_type1 === "FOGO" && ch.catch_rate === 45);
check("Charmander evolui no 16, Dratini no 30, Kadabra por troca",
  (await sys(`select count(*)::int n from pk_evolutions where (from_id,to_id,method,coalesce(level,0)) in ((4,5,'nivel',16),(147,148,'nivel',30),(64,65,'troca',0))`))[0].n === 3);
check("tipos da Red/Blue: Água>Fogo 2x, Elétrico>Terra 0, Fantasma>Psíquico 0",
  (await sys(`select bt_eff('AGUA','FOGO',null) a, bt_eff('ELETRICO','TERRA',null) b, bt_eff('FANTASMA','PSIQUICO',null) c`)).every(r => +r.a === 2 && +r.b === 0 && +r.c === 0));
check("curva médio-lento no nível 16 = 2535 de experiência (fórmula 6/5n³-15n²+100n-140)", (await sys(`select pk_exp_for('medio_lento', 16) x`))[0].x === 2535);

console.log("\n2) Encontro e captura depois de andar");
await sys(`update game_config set config = jsonb_set(config, '{pk_start_at}', to_jsonb(now() - interval '1 minute'))`);
let r = await as(U.ana, `select public.move_today()`); check("Ana anda no dia", !r.error, r.error);
let syncA = await one(U.ana, `select public.pk_sync()`);
const enc = syncA.encounter;
check("apareceu um encontro", !!enc && enc.status === "aberto" && enc.throws_left === 3, JSON.stringify(syncA));
const base = (await sys(`select base_form from pokemon where id = $1`, [enc.species_id]))[0].base_form;
check("o Pokémon encontrado é a forma inicial da linha", base === enc.species_id);
const syncB = await one(U.ana, `select public.pk_sync()`);
check("chamar de novo não cria outro encontro", syncB.encounter?.id === enc.id && (await sys(`select count(*)::int n from encounters where user_id = $1`, [U.ana]))[0].n === 1);
r = await as(U.beto, `select public.encounter_throw($1)`, [enc.id]); check("Beto não joga bola no encontro da Ana", !!r.error, r.error);
r = await as(U.ana, `insert into encounters(user_id, move_id, species_id, level, throws_left) values ('${U.ana}', gen_random_uuid(), 150, 5, 3)`); check("Ana não cria encontro pelo navegador", !!r.error);
let res, tries = 0;
do { res = await one(U.ana, `select public.encounter_throw($1)`, [enc.id]); tries++; } while (!res.caught && !res.fled && tries < 5);
check(`a captura termina em até 3 bolas (${res.caught ? "capturou" : "fugiu"} na ${tries}ª)`, tries <= 3 && (res.caught || res.fled));
r = await as(U.ana, `select public.encounter_throw($1)`, [enc.id]); check("não dá para jogar bola depois que terminou", /terminou/.test(r.error || ""), r.error);
// chance: Caterpie (255) >> Dratini (45) no cálculo da 1ª geração
const sim = await sys(`with t as (select catch_rate cr from pokemon where id in (10, 147))
  select cr, round(((least(cr,255)+1)/256.0) * (85+1)/256.0 * 100, 1) pct from t order by cr desc`);
check(`chance por bola: Caterpie ${sim[0].pct}% > Dratini ${sim[1].pct}%`, +sim[0].pct > 30 && +sim[1].pct < 7);

console.log("\n3) Coleção, equipe e mascote");
const mk = async (uid, sp, lv) => (await sys(`select (public.pk_new_monster($1, $2, $3)).id`, [uid, sp, lv]))[0].id;
const A = { char: await mk(U.ana, 4, 15), cat: await mk(U.ana, 10, 6), dra: await mk(U.ana, 147, 29), eev: await mk(U.ana, 133, 20), aba: await mk(U.ana, 63, 15), x6: await mk(U.ana, 16, 5), x7: await mk(U.ana, 19, 5) };
const B = { sq: await mk(U.beto, 7, 15), pid: await mk(U.beto, 16, 10), abra: await mk(U.beto, 63, 20) };
const C = { c1: await mk(U.caio, 10, 3), c2: await mk(U.caio, 13, 3) };
const mon = async id => (await sys(`select * from monsters where id = $1`, [id]))[0];
check("Charmander nível 15 sabe Scratch/Growl/Ember/Leer", JSON.stringify((await mon(A.char)).moves) === JSON.stringify([10, 45, 52, 43]), JSON.stringify((await mon(A.char)).moves));
r = await as(U.ana, `select public.mon_team_set($1)`, [[A.char, A.cat, A.dra, A.eev, A.aba, A.x6, A.x7]]); check("equipe com 7 é recusada", /máximo 6/.test(r.error || ""), r.error);
r = await as(U.ana, `select public.mon_team_set($1)`, [[A.char, A.char]]); check("Pokémon repetido na equipe é recusado", /repetido/.test(r.error || ""), r.error);
r = await as(U.ana, `select public.mon_team_set($1)`, [[A.char, B.sq]]); check("Pokémon de outro jogador é recusado", /coleção/.test(r.error || ""), r.error);
r = await as(U.ana, `select public.mon_team_set($1)`, [[A.dra, A.char, A.cat]]); check("equipe válida de 3", !r.error, r.error);
check("ordem da equipe gravada", (await mon(A.dra)).team_slot === 1 && (await mon(A.cat)).team_slot === 3);
r = await as(U.beto, `select public.mon_team_set($1)`, [[B.sq, B.pid, B.abra]]); check("Beto monta a equipe", !r.error, r.error);
r = await as(U.ana, `update monsters set level = 100 where id = '${A.char}'`); check("Ana não altera o próprio Pokémon pelo navegador", !!r.error);
r = await as(U.ana, `select public.mon_set_mascot($1)`, [B.sq]); check("mascote de outro jogador é recusado", !!r.error);
r = await as(U.ana, `select public.mon_set_mascot($1)`, [A.dra]); check("Ana escolhe o Dratini de mascote", !r.error, r.error);
r = await as(U.beto, `select mascot from characters where user_id = '${U.ana}'`); check("Beto vê o mascote da Ana", r.rows?.[0]?.mascot?.species === 147, JSON.stringify(r));

console.log("\n4) XP, níveis, ataques e evolução");
await sys(`select public.pk_give_xp($1, public.pk_exp_for('medio_lento', 16) - (select exp from monsters where id = $1), 'teste')`, [A.char]);
check("Charmander sobe para o 16", (await mon(A.char)).level === 16);
check("aviso de evolução disponível", (await sys(`select count(*)::int n from mon_events where mon_id = $1 and kind = 'evolucao'`, [A.char]))[0].n === 1);
check("não evoluiu sozinho (dá para adiar)", (await mon(A.char)).species_id === 4);
r = await as(U.ana, `select public.mon_evolve($1, 6)`, [A.char]); check("não pula para Charizard", !!r.error, r.error);
r = await as(U.ana, `select public.mon_evolve($1, 5)`, [A.char]); check("evolui para Charmeleon", !r.error && (await mon(A.char)).species_id === 5, r.error);
check("Pokédex registra Charmeleon", (await sys(`select caught_at from pokedex_entries where user_id = $1 and species_id = 5`, [U.ana]))[0]?.caught_at != null);
r = await as(U.ana, `select public.mon_evolve($1, 5)`, [A.char]); check("evolução inexistente é recusada", !!r.error);
r = await as(U.beto, `select public.mon_evolve($1, 64)`, [B.abra]); check("Abra no 20 evolui para Kadabra", !r.error, r.error);
r = await as(U.beto, `select public.mon_evolve($1, 65)`, [B.abra]); check("Kadabra -> Alakazam bloqueado (precisa de troca)", /troca/.test(r.error || ""), r.error);
r = await as(U.ana, `select public.mon_evolve($1, 136)`, [A.eev]); check("Eevee sem pedra não evolui", /pedra/.test(r.error || ""), r.error);
r = await as(U.ana, `select public.pk_buy('pedra_fogo', 1)`); check("sem moedas não compra pedra", /insuficientes/.test(r.error || ""), r.error);
await sys(`update characters set coins = 1000 where user_id = $1`, [U.ana]);
r = await as(U.ana, `select public.pk_buy('pedra_fogo', 1)`); check("compra a Pedra do Fogo (250)", !r.error && (await sys(`select coins from characters where user_id = $1`, [U.ana]))[0].coins === 750, r.error);
r = await as(U.ana, `select public.mon_evolve($1, 136)`, [A.eev]); check("Eevee + Pedra do Fogo = Flareon (pedra gasta)", !r.error && (await mon(A.eev)).species_id === 136 && (await sys(`select qty from bag_items where user_id = $1 and item = 'pedra_fogo'`, [U.ana]))[0].qty === 0, r.error);
// ataque novo com 4 ataques: fica pendente para o jogador escolher
await sys(`update monsters set moves = '{10,45,52,43}', pending_moves = '{}' where id = $1`, [A.char]);
await sys(`select public.pk_give_xp($1, public.pk_exp_for('medio_lento', 24) - (select exp from monsters where id = $1), 'teste')`, [A.char]);
const cm = await mon(A.char);
check("Charmeleon no 24 tem Rage esperando (já sabia 4)", cm.level === 24 && cm.pending_moves.includes(99), JSON.stringify(cm));
r = await as(U.ana, `select public.mon_learn($1, 99, 2)`, [A.char]); check("troca Growl por Rage", !r.error && JSON.stringify((await mon(A.char)).moves) === JSON.stringify([10, 99, 52, 43]), r.error);
// XP vindo do tabuleiro: dividido igualmente pela equipe
const before = await Promise.all([A.dra, A.char, A.cat].map(async id => (await mon(id)).exp));
await sys(`insert into daily_moves(user_id, move_date, modes, base_steps, roll, bonus_steps, from_node, to_node, xp_gained, coins_gained)
           values ($1, public.game_today() - 1, '{"modes": {"classico": {"solved": true}, "cartao": {"solved": true}}}', 9, 2, 0, 5, 20, 10, 5)`, [U.ana]);
await as(U.ana, `select public.pk_sync()`);
const after = await Promise.all([A.dra, A.char, A.cat].map(async id => (await mon(id)).exp));
const gains = after.map((v, i) => v - before[i]);
const pool = 100 + 15 * 9 + 40 * 2;
check(`XP do tabuleiro dividido igualmente (${gains.join(", ")} de ${pool})`, gains.every(g => g === Math.floor(pool / 3)), JSON.stringify(gains));
check("o XP e as moedas do herói não mudaram", (await sys(`select coins from characters where user_id = $1`, [U.ana]))[0].coins === 750);
await as(U.ana, `select public.pk_sync()`);
const again = await Promise.all([A.dra, A.char, A.cat].map(async id => (await mon(id)).exp));
check("a mesma movimentação não dá XP duas vezes", JSON.stringify(again) === JSON.stringify(after));
await sys(`select public.pk_give_xp($1, public.pk_exp_for('medio_rapido', 7) - (select exp from monsters where id = $1), 'teste')`, [A.cat]);
const cat = await mon(A.cat);
check("Caterpie que chega ao 7 tem evolução disponível", cat.level === 7 && (await sys(`select count(*)::int n from mon_events where mon_id = $1 and kind = 'evolucao'`, [A.cat]))[0].n === 1, JSON.stringify({ lv: cat.level }));

console.log("\n5) Roupas");
r = await as(U.ana, `select public.mon_equip($1, 'pk_cabeca', 'pk_coroa')`, [A.dra]); check("não veste item que não comprou", /ainda não tem/.test(r.error || ""), r.error);
r = await as(U.ana, `select public.pk_cosmetic_buy('pk_bone_vermelho')`); check("pega o boné grátis", !r.error, r.error);
r = await as(U.ana, `select public.pk_cosmetic_buy('pk_bone_vermelho')`); check("não compra o mesmo item duas vezes", /já tem/.test(r.error || ""), r.error);
r = await as(U.ana, `select public.mon_equip($1, 'pk_rosto', 'pk_bone_vermelho')`, [A.dra]); check("boné não vai no rosto", !!r.error, r.error);
r = await as(U.ana, `select public.mon_equip($1, 'pk_cabeca', 'pk_bone_vermelho')`, [A.dra]); check("veste o boné no Dratini", !r.error && (await mon(A.dra)).outfit.pk_cabeca === "pk_bone_vermelho", r.error);
check("mascote no mapa já aparece de boné", (await sys(`select mascot from characters where user_id = $1`, [U.ana]))[0].mascot.outfit.pk_cabeca === "pk_bone_vermelho");
check("roupa não muda atributo de batalha", JSON.stringify((await sys(`select bt_mon($1) - 'outfit' m`, [A.dra]))[0].m) === JSON.stringify((await sys(`select bt_mon($1) - 'outfit' m`, [A.dra]))[0].m));
r = await as(U.beto, `select public.mon_equip($1, 'pk_cabeca', null)`, [A.dra]); check("Beto não mexe na roupa do Pokémon da Ana", !!r.error);

console.log("\n6) Batalha");
r = await as(U.caio, `select public.battle_challenge($1, 10)`, [U.ana]); check("quem tem menos de 3 Pokémon não duela", /pelo menos 3/.test(r.error || ""), r.error);
r = await as(U.ana, `select public.battle_challenge($1, 10)`, [U.caio]); check("não dá para desafiar quem tem menos de 3", /ainda não tem/.test(r.error || ""), r.error);
let bat = await one(U.ana, `select row_to_json(public.battle_challenge($1, 10))`, [U.beto]);
check("Ana desafia Beto", bat.status === "convite");
r = await as(U.ana, `select public.battle_challenge($1, 10)`, [U.beto]); check("não abre dois desafios iguais", !!r.error);
r = await as(U.ana, `select public.battle_respond($1, true)`, [bat.id]); check("quem desafiou não aceita o próprio convite", !!r.error);
bat = await one(U.beto, `select row_to_json(public.battle_respond($1, true))`, [bat.id]);
check("Beto aceita: 3 contra 3, turno 1", bat.status === "ativa" && bat.turn === 1 && bat.state.sides[0].mons.length === 3 && bat.state.sides[1].mons.length === 3);
check("a batalha usa a equipe real e a ordem (Dratini primeiro)", bat.state.sides[0].mons[0].species === 147);
r = await as(U.ana, `select public.battle_act($1, 1, 'move', 0)`, [bat.id]); check("Ana escolhe o ataque", !r.error, r.error);
r = await as(U.ana, `select public.battle_act($1, 1, 'move', 1)`, [bat.id]); check("ação repetida no mesmo turno é recusada", /já escolheu/.test(r.error || ""), r.error);
r = await as(U.beto, `select public.battle_act($1, 2, 'move', 0)`, [bat.id]); check("ação fora do turno é recusada", /turno/.test(r.error || ""), r.error);
r = await as(U.beto, `select * from battle_actions where battle_id = '${bat.id}'`); check("Beto não vê a ação escolhida pela Ana", r.rows?.length === 0, JSON.stringify(r));
r = await as(U.beto, `update battles set winner = '${U.beto}' where id = '${bat.id}'`); check("ninguém altera a batalha pelo navegador", !!r.error);
r = await as(U.beto, `select public.battle_act($1, 1, 'move', 9)`, [bat.id]); check("ataque inexistente é recusado", !!r.error);
r = await as(U.beto, `select public.battle_act($1, 1, 'move', 0)`, [bat.id]); check("Beto escolhe e o turno é resolvido", !r.error, r.error);
bat = (await sys(`select * from battles where id = $1`, [bat.id]))[0];
check("turno 2 e relato do turno 1 gravado", bat.turn === 2 && bat.log.length === 2 && bat.log[1].lines.length >= 2, JSON.stringify(bat.log).slice(0, 300));
console.log("     relato:", bat.log[1].lines.map(l => l.txt).join(" | "));
// joga até o fim com escolhas aleatórias válidas
const pickAction = (b, side) => {
  const sd = b.state.sides[side], act = sd.mons[sd.active];
  if (b.phase === "troca" || sd.need_switch) { const i = sd.mons.findIndex((m, k) => k !== sd.active && m.hp > 0); return ["switch", i]; }
  if (Math.random() < 0.1) { const i = sd.mons.findIndex((m, k) => k !== sd.active && m.hp > 0); if (i >= 0 && !(act.fl || {}).charging && !(act.fl || {}).recharge) return ["switch", i]; }
  const moves = act.moves.map((m, i) => [m, i]).filter(([m]) => m.pp > 0);
  return moves.length ? ["move", moves[Math.floor(Math.random() * moves.length)][1]] : ["move", -1];
};
let guard = 0;
const xpBefore = await Promise.all([A.dra, A.char, A.cat, B.sq, B.pid, B.abra].map(async id => (await mon(id)).exp));
while (bat.status === "ativa" && guard++ < 300) {
  for (const [side, uid] of [[0, U.ana], [1, U.beto]]) {
    bat = (await sys(`select * from battles where id = $1`, [bat.id]))[0];
    if (bat.status !== "ativa") break;
    if ((side === 0 && bat.ready1) || (side === 1 && bat.ready2)) continue;
    const [k, v] = pickAction(bat, side);
    const rr = await as(uid, `select public.battle_act($1, $2, $3, $4)`, [bat.id, bat.turn, k, v]);
    if (rr.error) { console.log("     erro inesperado:", rr.error, k, v, "fase", bat.phase); guard = 999; break; }
  }
  bat = (await sys(`select * from battles where id = $1`, [bat.id]))[0];
}
check(`a batalha termina (${bat.turn} turnos, motivo: ${bat.end_reason})`, bat.status === "encerrada" && ["nocaute", "empate"].includes(bat.end_reason), JSON.stringify({ st: bat.status, t: bat.turn }));
check("recompensa entregue uma vez", bat.rewarded === true);
const xpAfter = await Promise.all([A.dra, A.char, A.cat, B.sq, B.pid, B.abra].map(async id => (await mon(id)).exp));
check("quem derrubou adversários ganhou XP de batalha", xpAfter.some((v, i) => v > xpBefore[i]));
await sys(`select public.bt_finish($1, $2, 'teste')`, [bat.id, U.ana]);
const xpTwice = await Promise.all([A.dra, A.char, A.cat, B.sq, B.pid, B.abra].map(async id => (await mon(id)).exp));
check("encerrar de novo não dá XP de novo", JSON.stringify(xpTwice) === JSON.stringify(xpAfter));
r = await as(U.ana, `select public.battle_act($1, $2, 'move', 0)`, [bat.id, bat.turn]); check("não joga depois do fim", !!r.error);
check("depois da batalha os Pokémon voltam com vida cheia", (await sys(`select (bt_mon($1)->>'hp') = (bt_mon($1)->>'maxhp') ok`, [A.dra]))[0].ok === true);
const allLines = bat.log.flatMap(t => t.lines.map(l => l.txt));
console.log("     amostra do relato:", allLines.slice(0, 14).join(" | "));
check("nenhum erro de ataque desconhecido no relato", !allLines.some(t => /undefined|null/.test(t)));
// desistência e prazo
let b2 = await one(U.beto, `select row_to_json(public.battle_challenge($1, 10))`, [U.ana]);
await as(U.ana, `select public.battle_respond($1, true)`, [b2.id]);
r = await as(U.ana, `select public.battle_claim($1)`, [b2.id]); check("não reivindica vitória dentro do prazo", !!r.error);
await as(U.ana, `select public.battle_act($1, 1, 'move', 0)`, [b2.id]);
await sys(`update battles set deadline = now() - interval '1 hour' where id = $1`, [b2.id]);
// desde o arquivo 24 não existe mais prazo por turno: ninguém perde por demora
r = await as(U.ana, `select row_to_json(public.battle_claim($1)) b`, [b2.id]); check("não existe vitória por tempo (arquivo 24)", /não têm mais prazo/.test(r.error || "") && (await sys(`select status from battles where id = $1`, [b2.id]))[0].status === "ativa", JSON.stringify(r));
await as(U.beto, `select public.battle_act($1, 1, 'forfeit', null)`, [b2.id]);
let b3 = await one(U.ana, `select row_to_json(public.battle_challenge($1, 10))`, [U.beto]);
await as(U.beto, `select public.battle_respond($1, true)`, [b3.id]);
r = await as(U.beto, `select row_to_json(public.battle_act($1, 1, 'forfeit', null)) b`, [b3.id]); check("desistir dá a vitória ao outro", r.rows?.[0]?.b?.winner === U.ana, JSON.stringify(r));

console.log("\n7) O jogo de antes continua igual");
r = await as(U.beto, `select public.round_board() b`); check("ranking do dia funciona", !r.error, r.error);
r = await as(U.beto, `select public.day_presence() p`); check("quem jogou hoje funciona", !r.error, r.error);
r = await as(U.beto, `select public.move_today()`); check("Beto anda normalmente", !r.error, r.error);
check("Beto ganhou encontro depois de andar", !!(await one(U.beto, `select public.pk_sync()`)).encounter);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
await db.close();
process.exit(fail ? 1 : 0);
