// Testa o arquivo 113 com dados de TESTE, como jogadores comuns: Ginásio em uma batalha só (4 contra 4, trocar gasta o turno e o
// Líder ataca quem entrou, quem desmaia você escolhe quem entra, Revive com metade da vida, limite de 2 itens na batalha, trava no
// Centro/Creche/Leilão/equipe, voltar continua igual, prazo de 30 min vira derrota, desistir, XP dividida entre quem lutou, insígnia);
// ataques dos Pokémon do jogo (cobertura nos times dos Líderes, os da Pedreira acertam um Gengar, nunca usa ataque que não afeta,
// no máximo 1 status a cada 3 turnos, não repete status, prefere super efetivo); a Elite continua igual; nome "Desafio do Planalto"; Ajustes; Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_ginasio_batalha.mjs ..
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
const A = "11111111-1111-1111-1111-111111111111", B = "22222222-2222-2222-2222-222222222222", ADM = "99999999-9999-9999-9999-999999999999";
for (const [u, n] of [[A, "Ana"], [B, "Beto"], [ADM, "Chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'guerreiro')`, [n]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
const mk = async (u, sp, lv) => (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, sp, lv]))[0].id;
const arr = ids => `{${ids.join(",")}}`;
const bat = async id => (await sys(`select * from battles where id = $1`, [id]))[0];
const act = (u, b, kind, v, item = null) => as(u, `select (public.battle_act($1, $2, $3, $4, $5)).id`, [b.id, b.turn, kind, v, item]);
const mv = async id => (await sys(`select id, power, type, effect from pk_moves where id = $1`, [id]))[0];
const eff = async (t, d1, d2) => +(await sys(`select public.bt_eff($1, $2, $3) e`, [t, d1, d2]))[0].e;
const setMon = (bid, side, i, campo, valor) => sys(`update battles set state = jsonb_set(state, array['sides', $2::text, 'mons', $3::text, $4], $5::jsonb) where id = $1`, [bid, side, i, campo, JSON.stringify(valor)]);

console.log("\nAtaques dos Pokémon do jogo");
const lid = await sys(`select regiao, time from rpg_lideres order by regiao`);
check("os times dos 8 Líderes guardam os 4 ataques de cada Pokémon", lid.length === 8 && lid.every(l => l.time.every(e => e.length === 3 && e[2].length >= 1 && e[2].length <= 4)), JSON.stringify(lid.map(l => l.time)));
let cobre = true, semCob = [];
for (const l of lid) for (const e of l.time) {
  const tipos = new Set(); for (const id of e[2]) { const m = await mv(id); if (m.power > 0) tipos.add(m.type); }
  if (tipos.size < 2) { cobre = false; semCob.push(`${l.regiao}:${e[0]}:${e[2].join("/")}`); }
}
check("cada Pokémon dos Líderes tem ataques de dano de pelo menos 2 tipos", cobre, semCob.join(" "));
const ped = lid.find(l => l.regiao === "pedreira");
let acertaGengar = true;
for (const e of ped.time) { let algum = false; for (const id of e[2]) { const m = await mv(id); if ((m.power > 0 || m.effect === "SPECIAL_DAMAGE_EFFECT") && await eff(m.type, "FANTASMA", "VENENO") > 0) algum = true; } if (!algum) acertaGengar = false; }
check("todo Pokémon da Pedreira tem ataque de dano que acerta um Gengar", acertaGengar, JSON.stringify(ped.time));
check("a Pedreira tem ataque do tipo Pedra (Rock Slide ou Rock Throw)", (await sys(`select count(*)::int n from pk_moves where id = any($1::int[]) and code in ('ROCK_SLIDE', 'ROCK_THROW')`, [arr(ped.time.flatMap(e => e[2]))]))[0].n > 0);

// simula 30 turnos de cada Pokémon da Pedreira contra um Gengar
let errados = 0, statusDemais = false, repetiu = false, usouStatus = 0;
for (const e of ped.time) {
  let s = { sides: [{ active: 0, mons: [(await sys(`select public.ia_mon($1, $2, $3::int[], true) m`, [e[0], e[1], arr(e[2])]))[0].m] }, { active: 0, mons: [(await sys(`select public.npc_mon(94, 50) m`))[0].m] }] };
  const usos = {}; let st = [];
  for (let turno = 1; turno <= 30; turno++) {
    const p = (await sys(`select public.ia_pick($1::jsonb, 0, 'lider', $2) p`, [JSON.stringify(s), turno]))[0].p;
    s = (await sys(`select public.ia_memo($1::jsonb, 0, $2::jsonb, $3) s`, [JSON.stringify(s), JSON.stringify(p), turno]))[0].s;
    const m = await mv(s.sides[0].mons[0].moves[p.value].id);
    const dano = m.power > 0 || ["SPECIAL_DAMAGE_EFFECT", "SUPER_FANG_EFFECT", "OHKO_EFFECT"].includes(m.effect);
    if (dano && m.effect !== "SPECIAL_DAMAGE_EFFECT" && await eff(m.type, "FANTASMA", "VENENO") === 0) errados++;
    if (!dano) { st.push(turno); usos[m.id] = (usos[m.id] || 0) + 1; usouStatus++; }
  }
  for (let i = 1; i < st.length; i++) if (st[i] - st[i - 1] < 3) statusDemais = true;
  if (Object.values(usos).some(n => n > 2)) repetiu = true;
}
check("contra o Gengar, nunca escolhe ataque de dano que não afeta", errados === 0, errados);
check("no máximo 1 ataque de status a cada 3 turnos", !statusDemais);
check("não repete o mesmo status mais de 2 vezes", !repetiu);
// sem nenhum ataque de dano que acerte: usa status, sem repetir o que já fez efeito
{ const ids = (await sys(`select array_agg(id order by id) a from pk_moves where code in ('TACKLE', 'GROWL', 'HYPNOSIS', 'QUICK_ATTACK')`))[0].a;
  let s = { sides: [{ active: 0, mons: [(await sys(`select public.ia_mon(16, 30, $1::int[]) m`, [arr(ids)]))[0].m] }, { active: 0, mons: [(await sys(`select public.npc_mon(94, 30) m`))[0].m] }] };
  const vistos = [];
  for (let turno = 1; turno <= 6; turno++) {
    const p = (await sys(`select public.ia_pick($1::jsonb, 0, 'selvagem', $2) p`, [JSON.stringify(s), turno]))[0].p;
    s = (await sys(`select public.ia_memo($1::jsonb, 0, $2::jsonb, $3) s`, [JSON.stringify(s), JSON.stringify(p), turno]))[0].s;
    const m = await mv(s.sides[0].mons[0].moves[p.value].id); vistos.push(m.code || m.id);
    if (m.effect === "SLEEP_EFFECT") s.sides[1].mons[0].status = "SLP";   // o sono pegou
  }
  const nomes = await Promise.all(vistos.map(async id => (await sys(`select code from pk_moves where id = $1`, [id]))[0]?.code || id));
  check("sem ataque que acerte, usa status e não repete o sono em quem já dorme", !nomes.includes("TACKLE") && !nomes.includes("QUICK_ATTACK") && nomes.filter(n => n === "HYPNOSIS").length === 1, nomes.join(","));
}
// prefere o super efetivo: Golem (Earthquake) contra um Pikachu
{ const ids = (await sys(`select array_agg(id) a from pk_moves where code in ('EARTHQUAKE', 'TACKLE', 'ROCK_THROW', 'DEFENSE_CURL')`))[0].a;
  const s = { sides: [{ active: 0, mons: [(await sys(`select public.ia_mon(76, 40, $1::int[]) m`, [arr(ids)]))[0].m] }, { active: 0, mons: [(await sys(`select public.npc_mon(25, 40) m`))[0].m] }] };
  let eq = 0; for (let i = 0; i < 20; i++) { const p = (await sys(`select public.ia_pick($1::jsonb, 0, 'selvagem', 1) p`, [JSON.stringify(s)]))[0].p; const m = await mv(s.sides[0].mons[0].moves[p.value].id); if (m.type === "TERRA") eq++; }
  check("com ataque super efetivo, escolhe ele (selvagem: o sorteio fica entre os super efetivos)", eq === 20, eq);
}

console.log("\nGinásio em uma batalha só (4 contra 4)");
const m1 = await mk(A, 9, 80), k1 = await mk(A, 129, 5), k2 = await mk(A, 129, 5), m2 = await mk(A, 9, 80);   // Blastoise com Hydro Pump
await sys(`update monsters set team_slot = 1 where id = $1`, [m1]);
const xp0 = Object.fromEntries((await sys(`select id, exp as xp from monsters where user_id = $1`, [A])).map(r => [r.id, +r.xp]));
let r = await as(A, `select public.rpg_ginasio_lutar('pedreira', null, $1) r`, [arr([m1, k1, k2, m2])]);
const bid = r.rows?.[0]?.r?.battle;
let b = await bat(bid);
const tent = (await sys(`select * from rpg_gin_tent where user_id = $1 order by id desc limit 1`, [A]))[0];
check("é UMA batalha com os 4 de cada lado", b && b.size === 4 && b.state.sides[0].mons.length === 4 && b.state.sides[1].mons.length === 4, r.error || JSON.stringify(b?.state?.sides?.map(s => s.mons.length)));
check("os seus entram na ordem escolhida", JSON.stringify(b.state.sides[0].mons.map(m => m.id)) === JSON.stringify([m1, k1, k2, m2]));
const lid0 = b.state.sides[1].mons[0];
check("o 1º do Líder segue a ordem sorteada, com os ataques do time", lid0.species === ped.time[tent.ordem[0]][0] && JSON.stringify(lid0.moves.map(x => x.id)) === JSON.stringify(ped.time[tent.ordem[0]][2]));
check("o time do Líder continua secreto: os que não entraram não aparecem na batalha", b.state.sides[1].mons.slice(1).every(m => m.oculto && !m.species && m.known === false) && !JSON.stringify(b.state.sides[1].mons.slice(1)).includes('"species"'));
const ocA = await as(A, `select count(*)::int n from rpg_gin_ocultos`);
check("jogador não lê os Pokémon guardados do Líder", !!ocA.error || ocA.rows[0].n === 0);
// trocar de Pokémon gasta o turno e o Líder ataca quem entrou
r = await act(A, b, "switch", 3);
b = await bat(bid);
const acts1 = await sys(`select side, kind from battle_actions where battle_id = $1 and turn = 1 order by side`, [bid]);
const linhas1 = b.log.find(l => l.turn === 1)?.lines || [];
check("trocar: o seu novo Pokémon entrou e o Líder jogou no mesmo turno", !r.error && b.state.sides[0].active === 3 && acts1.length === 2 && acts1[0].kind === "switch" && acts1[1].kind === "move", r.error || JSON.stringify(acts1));
check("trocar: o ataque do Líder foi no que entrou (relato do turno)", linhas1.some(l => l.switch === 3) && linhas1.findIndex(l => l.switch === 3) < linhas1.length - 1, JSON.stringify(linhas1));
// quem desmaia, você escolhe quem entra
await act(A, b, "switch", 1); b = await bat(bid);
let desmaiou = b.state.sides[0].mons[1].hp <= 0;   // pode cair já ao entrar
for (let i = 0; i < 12 && !desmaiou; i++) {
  await setMon(bid, 0, 1, "hp", 1); b = await bat(bid);
  await act(A, b, "move", 0); b = await bat(bid);
  desmaiou = b.state.sides[0].mons[1].hp <= 0;
}
check("o Magikarp desmaiou e a batalha espera a sua escolha", desmaiou && b.phase === "troca" && b.state.sides[0].need_switch === true && b.state.sides[0].active === 1, JSON.stringify({ desmaiou, phase: b.phase, ns: b.state.sides[0].need_switch, act: b.state.sides[0].active, hp: b.state.sides[0].mons.map(m => m.hp), hp1: b.state.sides[1].mons.map(m => m.hp), log: b.log.slice(-3) }));
r = await act(A, b, "move", 0);
check("sem escolher quem entra, não dá para atacar", /Escolha qual Pokémon vai entrar/.test(r.error || ""), r.error);
r = await act(A, b, "switch", 0); b = await bat(bid);
check("você escolheu: entra o primeiro Blastoise", !r.error && b.state.sides[0].active === 0 && b.phase === "normal", r.error);
// Revive em quem desmaiou (gasta o turno do que está em campo) e o limite de 2 itens
await sys(`insert into bag_items(user_id, item, qty) values ($1, 'reviver', 3), ($1, 'pocao', 3) on conflict (user_id, item) do update set qty = 3`, [A]);
r = await act(A, b, "item", 1, "reviver"); b = await bat(bid);
const k1m = b.state.sides[0].mons[1];
check("Revive: o Magikarp volta com metade da vida", !r.error && k1m.hp === Math.max(1, Math.floor(k1m.maxhp / 2)) && (b.state.sides[0].items | 0) === 1, r.error || JSON.stringify(k1m));
if (b.phase === "troca" || b.state.sides[0].need_switch) { const nx = b.state.sides[0].mons.findIndex((m, j) => m.hp > 0 && j !== b.state.sides[0].active); await act(A, b, "switch", nx); b = await bat(bid); }
await setMon(bid, 0, b.state.sides[0].active, "hp", 50); b = await bat(bid);
r = await act(A, b, "item", b.state.sides[0].active, "pocao"); b = await bat(bid);
check("2º item (Poção) funciona", !r.error && (b.state.sides[0].items | 0) === 2, r.error);
if (b.phase === "troca" || b.state.sides[0].need_switch) { const nx = b.state.sides[0].mons.findIndex((m, j) => m.hp > 0 && j !== b.state.sides[0].active); await act(A, b, "switch", nx); b = await bat(bid); }   // se alguém caiu, escolhe quem entra
r = await act(A, b, "item", b.state.sides[0].active, "pocao");
check("3º item na mesma batalha: bloqueado", /limite/.test(r.error || ""), r.error);
await setMon(bid, 0, 0, "hp", b.state.sides[0].mons[0].maxhp); b = await bat(bid);   // (para o resto do teste)
// trava enquanto a batalha existe
check("Centro: não cura quem está no Ginásio", /batalha de Ginásio/.test((await as(A, `select public.centro_curar($1)`, [arr([m1])])).error || ""));
check("Creche: não aceita quem está no Ginásio", /batalha de Ginásio/.test((await as(A, `select public.creche_treinar($1, 1)`, [m1])).error || ""));
check("Leilão: não aceita quem está no Ginásio", /batalha de Ginásio/.test((await as(A, `select public.leilao_criar($1, 10)`, [m1])).error || ""));
check("Equipe: quem está no Ginásio não sai", /não pode sair da equipe/.test((await as(A, `select public.mon_team_set('{}')`)).error || ""));
// sair e voltar: a mesma batalha, com a mesma vida e o mesmo status
await setMon(bid, 0, 0, "status", "PAR"); b = await bat(bid);
const antes = JSON.stringify(b.state.sides);
r = await as(A, `select public.rpg_ginasio_lutar('pedreira') r`);
const b2 = await bat(bid);
check("voltar: continua a mesma batalha, igualzinha", r.rows?.[0]?.r?.battle === bid && JSON.stringify(b2.state.sides) === antes, r.error);
const g = (await as(A, `select public.rpg_ginasio('pedreira') g`)).rows[0].g;
check("a tela do Ginásio mostra a batalha em andamento e o prazo", g.batalha?.id === bid && g.expira_min === 30 && g.itens_batalha === 2, JSON.stringify(g));
await setMon(bid, 0, 0, "status", null);
// vencer: o Mewtwo usa o ataque mais forte; quem cai, entra o próximo
for (let i = 0; i < 120; i++) {
  b = await bat(bid); if (b.status !== "ativa") break;
  const S0 = b.state.sides[0];
  if (b.phase === "troca" && S0.need_switch) { const nx = S0.mons.findIndex((m, j) => m.hp > 0 && j !== S0.active); await act(A, b, "switch", nx); continue; }
  const A0 = S0.mons[S0.active]; let best = 0, bp = -1;
  for (let j = 0; j < A0.moves.length; j++) { if (A0.moves[j].pp <= 0) continue; const m = await mv(A0.moves[j].id); if ((m.power || 0) > bp) { bp = m.power || 0; best = j; } }
  r = await act(A, b, "move", best); if (r.error) { console.log("   erro:", r.error); break; }
}
b = await bat(bid);
const t2 = (await sys(`select * from rpg_gin_tent where id = $1`, [tent.id]))[0];
check("no fim, os do Líder entraram na ordem sorteada", b.state.sides[1].mons.every((m, i) => m.species === ped.time[tent.ordem[i]][0]), JSON.stringify(b.state.sides[1].mons.map(m => m.species)));
check("venceu: insígnia e tentativa vencida", b.status !== "ativa" && t2.status === "venceu" && (await sys(`select count(*)::int n from rpg_insignias where user_id = $1 and regiao = 'pedreira'`, [A]))[0].n === 1, JSON.stringify({ st: b.status, t: t2.status }));
const gxp = b.state.treino.gxp || {};
check("a XP foi dividida entre quem lutou (pelo menos 2 ganharam)", Object.keys(gxp).length >= 2 && !gxp["2"], JSON.stringify({ gxp, part: b.state.treino.part, xpd: b.state.treino.xpd, hp: b.state.sides[0].mons.map(m => m.hp), log: b.log.slice(3, 12).map(t => t.lines.map(l => l.txt).join(" | ")) }));
const xp1 = Object.fromEntries((await sys(`select id, exp as xp from monsters where user_id = $1`, [A])).map(r => [r.id, +r.xp]));
check("quem nunca entrou em campo não ganhou XP", xp1[k2] === xp0[k2] && xp1[m1] > xp0[m1], JSON.stringify([xp0[k2], xp1[k2], xp0[m1], xp1[m1]]));
const vidas = (await sys(`select id, tr_hp from monsters where id = any($1::uuid[])`, [arr([m1, k1, k2, m2])]));
const espera = b.state.sides[0].mons.map(m => m.hp <= 0 ? 0 : Math.max(1, Math.floor(m.hp * 100 / m.maxhp)));
check("a vida perdida continua perdida depois da batalha", vidas.every(v => v.tr_hp === espera[[m1, k1, k2, m2].indexOf(v.id)]), JSON.stringify([vidas, espera]));
check("depois da batalha, a trava sai", !(await as(A, `select public.creche_treinar($1, 1)`, [m2])).error?.includes("batalha de Ginásio"));
check("o resultado mostra a XP de cada um", b.state.treino.res?.multi && b.state.treino.res.mons.length === 4 && b.state.treino.pos?.status === "venceu", JSON.stringify(b.state.treino.res));

console.log("\nPrazo e desistência");
const bs = []; for (let i = 0; i < 4; i++) bs.push(await mk(B, 129, 5));
r = await as(B, `select public.rpg_ginasio_lutar('bosque', null, $1) r`, [arr(bs)]);
const bid2 = r.rows[0].r.battle;
await sys(`update battles set started_at = now() - interval '31 minutes' where id = $1`, [bid2]);
b = await bat(bid2);
r = await act(B, b, "move", 0); b = await bat(bid2);
check("batalha abandonada há mais de 30 min: jogar nela encerra como derrota", !r.error && b.status !== "ativa" && b.end_reason === "tempo", r.error || b.status);
let t3 = (await sys(`select * from rpg_gin_tent where user_id = $1 order by id desc limit 1`, [B]))[0];
check("conta como derrota (gasta a tentativa)", t3.status === "perdeu" && (await as(B, `select public.rpg_ginasio('bosque') g`)).rows[0].g.tentativas === 1);
r = await as(B, `select public.rpg_ginasio_lutar('bosque', null, $1) r`, [arr(bs)]);
const bid3 = r.rows[0].r.battle;
await sys(`update battles set started_at = now() - interval '31 minutes' where id = $1`, [bid3]);
const gg = (await as(B, `select public.rpg_ginasio('bosque') g`)).rows[0].g;
b = await bat(bid3);
check("também vence o prazo só de abrir a tela do Ginásio", b.end_reason === "tempo" && !gg.batalha && gg.tentativas === 2, JSON.stringify(gg));
check("depois do prazo, o Centro volta a curar", !/batalha de Ginásio/.test((await as(B, `select public.centro_curar($1)`, [arr([bs[0]])])).error || ""));
const moedasB = (await sys(`select coins from characters where user_id = $1`, [B]))[0].coins;
r = await as(B, `select public.rpg_ginasio_lutar('bosque', null, $1) r`, [arr(bs)]);
if (r.error) { await sys(`update monsters set tr_hp = 100 where user_id = $1`, [B]); r = await as(B, `select public.rpg_ginasio_lutar('bosque', null, $1) r`, [arr(bs)]); }
const bid4 = r.rows?.[0]?.r?.battle; b = await bat(bid4);
r = await act(B, b, "forfeit", 0); b = await bat(bid4);
t3 = (await sys(`select * from rpg_gin_tent where user_id = $1 order by id desc limit 1`, [B]))[0];
check("desistir encerra a tentativa sem cobrar moedas", b.status !== "ativa" && t3.status === "perdeu" && (await sys(`select coins from characters where user_id = $1`, [B]))[0].coins === moedasB, r.error);
check("3 tentativas usadas: a 4ª é recusada", /tentativas de hoje/.test((await as(B, `select public.rpg_ginasio_lutar('bosque', null, $1) r`, [arr(bs)])).error || ""));

console.log("\nO resto");
const fdef = async n => (await sys(`select string_agg(pg_get_functiondef(p.oid), ' ') d from pg_proc p where proname = $1`, [n]))[0].d || "";
check("a Liga do Planalto (Elite) continua com a escolha antiga", /'elite' then p := public\.war_pick/.test(await fdef("battle_act")) && /npc_mon\(/.test(await fdef("rpg_elite_lutar")) && !/ia_mon\(/.test(await fdef("rpg_elite_lutar")));
check("selvagens, Chefe, Expedições e Rocket usam os ataques novos", ["rpg_encontro", "rpg_chefe_lutar", "exp_batalha", "rocket_side"].every(async n => /ia_mon\(/.test(await fdef(n))) && /ia_mon\(/.test(await fdef("rpg_encontro")) && /ia_mon\(/.test(await fdef("rocket_side")));
check("o nome novo: Desafio do Planalto", /Desafio do Planalto só recebe/.test((await as(B, `select public.rpg_elite_lutar(null, $1)`, [arr(bs.slice(0, 1))])).error || ""));
check("jogador não chama as funções internas", !!(await as(A, `select public.ia_moves(25, 30, true)`)).error && !!(await as(A, `select public.rpg_gin_expira($1)`, [A])).error);
const aj = (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c;
check("Ajustes do jogo: escolha de ataques e o prazo do Ginásio", aj.ia?.lider_melhor_pct === 70 && aj.ia?.status_cada === 3 && aj.rpg?.ginasios?.expira_min === 30, JSON.stringify([aj.ia, aj.rpg?.ginasios]));
r = await as(ADM, `select public.admin_rpg_lider_salvar('bosque', 'Líder Flora', 'domador', 'Planta', '[[3, 40], [12, 38, [94, 76]]]'::jsonb) x`);
const flora = (await sys(`select time from rpg_lideres where regiao = 'bosque'`))[0].time;
check("admin salva o Líder: ataques automáticos ou os que escolheu", !r.error && flora[0].length === 3 && flora[0][2].length >= 2 && JSON.stringify(flora[1][2]) === "[94,76]", r.error || JSON.stringify(flora));
check("Jornal: a novidade foi publicada", (await sys(`select count(*)::int n from posts where title = '🏟️ Ginásio em uma batalha só, como na Red/Blue'`))[0].n === 1);

console.log(`\n${ok} OK, ${fail} falharam`);
process.exit(fail ? 1 : 0);
