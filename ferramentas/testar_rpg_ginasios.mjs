// Testa o arquivo 99 (Aventura: Ginásios e insígnias, missões, noite e Chefe da rota) com dados de TESTE, como
// jogadores comuns: missões do dia, progresso e prêmio uma vez; noite traz Fantasma/Sombrio; Ginásio Pokémon por
// Pokémon com vida guardada, insígnia e prêmio, sem repetir, tentativas por dia, desistir perde; Chefe com barra
// coletiva, dano por luta, tentativas, prêmio para todos quando cai; só admin solta; Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_rpg_ginasios.mjs ..
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
const A = "11111111-1111-1111-1111-111111111111", B = "22222222-2222-2222-2222-222222222222", ADM = "99999999-9999-9999-9999-999999999999";
for (const [u, n] of [[A, "Ana"], [B, "Beto"], [ADM, "Chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'guerreiro')`, [n]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
const newMon = async (u, sp, lv, slot) => { const id = (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, sp, lv]))[0].id; await sys(`update monsters set team_slot = null where user_id = $1 and team_slot = $2`, [u, slot]); await sys(`update monsters set team_slot = $2 where id = $1`, [id, slot]); return id; };
await sys(`update monsters set team_slot = null where true`);
const forte = await newMon(A, 150, 80, 1);
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;
const bag = async (u, it) => (await sys(`select coalesce((select qty from bag_items where user_id = $1 and item = $2), 0) q`, [u, it]))[0].q;
const cura = () => sys(`update monsters set tr_hp = 100, tr_hurt_at = null where true`);
async function luta(u, bid) {
  for (let i = 0; i < 80; i++) {
    const b = (await sys(`select * from battles where id = $1`, [bid]))[0]; if (b.status !== "ativa") return b;
    let r; for (const mv of [0, 1, 2, 3, -1]) { r = await as(u, `select public.battle_act($1, $2, 'move', $3)`, [bid, b.turn, mv]); if (!r.error) break; }
    if (r.error) { console.log("   erro na luta:", r.error); return b; }
  }
  return (await sys(`select * from battles where id = $1`, [bid]))[0];
}
const estado = async u => { const r = await as(u, `select public.rpg_estado() e`); if (r.error) console.log("   rpg_estado:", r.error); return r.rows?.[0]?.e; };

console.log("\nConfig");
const cfg = (await sys(`select config->'rpg' c from game_config where active`))[0].c;
check("rpg tem ginásios (6 líderes), missões, noite e chefe", Object.keys(cfg.ginasios?.lideres || {}).length === 6 && cfg.missoes && cfg.noite && cfg.chefe?.nivel === 75);

console.log("\nMissões");
let e = await estado(A);
check("3 missões do dia geradas", e.missoes?.length === 3, JSON.stringify(e.missoes));
const ehj = await estado(A);
check("pedir de novo não gera mais", ehj.missoes.length === 3);
await sys(`update rpg_missoes set tipo = 'regiao', alvo = 'vila', meta = 1, prog = 0, premio = '{"coins": 30, "bag": {"pocao": 1}}' where user_id = $1 and n = 1`, [A]);
check("missão incompleta não dá prêmio", !!(await as(A, `select public.rpg_missao_resgatar(1)`)).error);
await sys(`update game_config set config = jsonb_set(config, '{rpg,noite,on}', 'false') where active`);
let r = await as(A, `select public.rpg_encontro($1, 'mato') r`, [forte]);
let b = await luta(A, r.rows[0].r.battle);
let m1 = (await sys(`select prog from rpg_missoes where user_id = $1 and n = 1`, [A]))[0].prog;
check("vencer um selvagem na Vila conta na missão da Vila", b.state.treino.res?.won === true && m1 === 1, JSON.stringify([b.state.treino.res?.won, m1]));
let c0 = await coins(A), p0 = await bag(A, "pocao");
r = await as(A, `select public.rpg_missao_resgatar(1)`);
check("pegar o prêmio dá moedas e item", !r.error && await coins(A) - c0 === 30 && await bag(A, "pocao") - p0 === 1, r.error);
check("o prêmio sai uma vez só", !!(await as(A, `select public.rpg_missao_resgatar(1)`)).error);
check("ninguém lê as missões dos outros", (await as(B, `select count(*)::int n from rpg_missoes where user_id = '${A}'`)).rows[0].n === 0);

console.log("\nNoite");
let viuNoite = false, okDia = true;
await sys(`update rpg_dias set batalhas = 0, ult = null where true`);
for (let i = 0; i < 25; i++) {
  await sys(`update rpg_dias set ult = null, batalhas = 0 where true`); await sys(`delete from battles where p1 = $1`, [A]);
  const x = await as(A, `select public.rpg_encontro($1, 'pedra') r`, [forte]); if (x.error) continue;
  const w = (await sys(`select state->'sides'->1->'mons'->0 w from battles where id = $1`, [x.rows[0].r.battle]))[0].w;
  const p = (await sys(`select g1_type1, g1_type2 from pokemon where id = $1`, [w.species]))[0];
  if (["FANTASMA", "SOMBRIO"].includes(p.g1_type1) || ["FANTASMA", "SOMBRIO"].includes(p.g1_type2)) okDia = false;
}
check("de dia (noite desligada) nunca aparece Fantasma no penhasco", okDia);
await sys(`update game_config set config = jsonb_set(jsonb_set(jsonb_set(config, '{rpg,noite,on}', 'true'), '{rpg,noite,inicio}', '0'), '{rpg,noite,fim}', '24') where active`);
check("o estado diz que é noite", (await estado(A)).noite === true);
for (let i = 0; i < 40 && !viuNoite; i++) {
  await sys(`update rpg_dias set ult = null, batalhas = 0 where true`); await sys(`delete from battles where p1 = $1`, [A]);
  const x = await as(A, `select public.rpg_encontro($1, 'pedra') r`, [forte]); if (x.error) continue;
  const w = (await sys(`select state->'sides'->1->'mons'->0 w from battles where id = $1`, [x.rows[0].r.battle]))[0].w;
  const p = (await sys(`select g1_type1, g1_type2 from pokemon where id = $1`, [w.species]))[0];
  if (["FANTASMA", "SOMBRIO"].includes(p.g1_type1) || ["FANTASMA", "SOMBRIO"].includes(p.g1_type2)) viuNoite = true;
}
check("de noite aparece Fantasma/Sombrio até no penhasco", viuNoite);
await sys(`delete from battles where p1 = $1`, [A]);
await sys(`update game_config set config = jsonb_set(config, '{rpg,noite,on}', 'false') where active`);

console.log("\nGinásio");
await cura(); c0 = await coins(A); const mp0 = await bag(A, "max_pocao");
let g = (await as(A, `select public.rpg_ginasio('bosque') g`)).rows[0].g;
check("o Ginásio mostra o Líder e o time de 4", g.lider?.nome === "Líder Flora" && g.lider.time.length === 4 && g.insignia === false);
let fim = null, lutas = 0;
for (let k = 0; k < 10 && !fim; k++) {
  await cura();
  const x = await as(A, `select public.rpg_ginasio_lutar('bosque') r`); if (x.error) { fim = "erro: " + x.error; break; }
  if (x.rows[0].r.fim) { fim = x.rows[0].r.fim; break; }
  const bb = await luta(A, x.rows[0].r.battle); lutas++;
  if (bb.state.treino.pos?.status === "venceu") fim = "venceu";
}
check("vence os 4 Pokémon do Líder, um por luta", fim === "venceu" && lutas === 4, `${fim} ${lutas}`);
check("ganhou a insígnia, 300 moedas e 2 Max Potion", (await sys(`select count(*)::int n from rpg_insignias where user_id = $1 and regiao = 'bosque'`, [A]))[0].n === 1 && await coins(A) - c0 === 300 && await bag(A, "max_pocao") - mp0 === 2, `${await coins(A) - c0}`);
check("o Jornal do dia conta a vitória", (await sys(`select count(*)::int n from event_log where kind = 'ginasio'`))[0].n >= 1);
check("não dá para repetir o Ginásio vencido", /já tem a insígnia/.test((await as(A, `select public.rpg_ginasio_lutar('bosque')`)).error || ""));
check("as insígnias aparecem no estado e são públicas", (await estado(A)).insignias.includes("bosque") && (await as(B, `select count(*)::int n from rpg_insignias where user_id = '${A}'`)).rows[0].n === 1);
// vida do Líder guardada entre as lutas, e desmaiado sai
const fraco = await newMon(B, 129, 5, 1);
let x = await as(B, `select public.rpg_ginasio_lutar('pico') r`);
let bb = await luta(B, x.rows[0].r.battle);
let tt = (await sys(`select * from rpg_gin_tent where user_id = $1 order by id desc limit 1`, [B]))[0];
check("perdeu com o único Pokémon: tentativa acaba", tt.status === "perdeu" && (await sys(`select tr_hp from monsters where id = $1`, [fraco]))[0].tr_hp === 0, JSON.stringify(tt));
await cura(); await sys(`update monsters set tr_hp = 100 where true`);
x = await as(B, `select public.rpg_ginasio_lutar('pico') r`);
c0 = await coins(B);
let f = await as(B, `select public.battle_act($1, 1, 'forfeit', null)`, [x.rows[0].r.battle]);
tt = (await sys(`select * from rpg_gin_tent where user_id = $1 order by id desc limit 1`, [B]))[0];
check("desistir do Ginásio perde a tentativa e não cobra moedas", !f.error && tt.status === "perdeu" && await coins(B) === c0, f.error);
await cura();
x = await as(B, `select public.rpg_ginasio_lutar('pico') r`); await as(B, `select public.battle_act($1, 1, 'forfeit', null)`, [x.rows[0].r.battle]);
check("3 tentativas por dia por Ginásio", /3 tentativas/.test((await as(B, `select public.rpg_ginasio_lutar('pico')`)).error || ""));

console.log("\nChefe da rota");
check("jogador comum não solta o chefe", !!(await as(A, `select public.admin_rpg_chefe('praia', 143)`)).error);
const ch = (await as(ADM, `select public.admin_rpg_chefe('praia', 143) c`)).rows[0].c;
check("o admin solta o chefe nível 75 com a barra de vida grande", ch.nivel === 75 && ch.regiao === "praia" && ch.hp_total > 1000, JSON.stringify(ch));
e = await estado(A);
check("o estado mostra o chefe", e.chefe?.especie === 143 && e.chefe.status === "ativo");
await cura(); await sys(`delete from battles where true`);
x = await as(A, `select public.rpg_chefe_lutar() r`);
bb = await luta(A, x.rows[0].r.battle);
const ch2 = (await sys(`select * from rpg_chefes where id = $1`, [ch.id]))[0], d2 = (await sys(`select * from rpg_chefe_dano where user_id = $1`, [A]))[0];
check("a luta acaba em até 12 turnos e o dano vai para a barra de todos", bb.status !== "ativa" && bb.turn <= 14 && ch2.dano > 0 && d2.dano === ch2.dano, JSON.stringify([bb.turn, ch2.dano, d2?.dano]));
check("o ranking do chefe mostra quem bateu", (await estado(B)).chefe.ranking[0]?.name === "Ana");
await cura(); x = await as(A, `select public.rpg_chefe_lutar() r`); await as(A, `select public.battle_act($1, 1, 'forfeit', null)`, [x.rows[0].r.battle]);
await cura(); x = await as(A, `select public.rpg_chefe_lutar() r`); await as(A, `select public.battle_act($1, 1, 'forfeit', null)`, [x.rows[0].r.battle]);
check("3 lutas por dia contra o chefe", /3 vezes/.test((await as(A, `select public.rpg_chefe_lutar()`)).error || ""));
await sys(`update rpg_chefes set hp_total = dano + 1 where id = $1`, [ch.id]);
await sys(`update monsters set tr_hp = 100 where user_id = $1`, [B]); await newMon(B, 150, 80, 1);
c0 = await coins(A); const cB = await coins(B);
x = await as(B, `select public.rpg_chefe_lutar() r`); bb = await luta(B, x.rows[0].r.battle);
const ch3 = (await sys(`select * from rpg_chefes where id = $1`, [ch.id]))[0];
check("o golpe final derruba o chefe e todos que lutaram ganham", ch3.status === "vencido" && ch3.premiado && await coins(A) - c0 >= 250 && await coins(B) - cB >= 250, JSON.stringify([ch3.status, await coins(A) - c0, await coins(B) - cB]));
check("o 1º do ranking ganha o extra de 300", Math.max(await coins(A) - c0, await coins(B) - cB) === 550);
check("aviso do chefe no Jornal do dia", (await sys(`select count(*)::int n from event_log where kind = 'chefe'`))[0].n === 2);

console.log("\nJornal");
check("aviso publicado no Jornal uma vez", (await sys(`select count(*)::int n from posts where title = '🏟️ Aventura: Ginásios, missões, noite e o Chefe da rota'`))[0].n === 1);
console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
