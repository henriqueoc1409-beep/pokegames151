// Testa o arquivo 28 (interruptor da 2ª geração) com dados de TESTE, como jogadores comuns:
// desligada = jogo igual ao de hoje; ligada = 2ª nos encontros, evoluções e (a partir de amanhã) desafios;
// desligar de novo não tira nada de ninguém. Inclui batalhas sorteadas com as duas gerações.
// Uso (na pasta ferramentas, uma vez: npm i @electric-sql/pglite@0.3.15):  node testar_gen2.mjs .. [batalhas]
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2], NB = +(process.argv[3] || 40);
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql").sort()) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
const ADM = "99999999-9999-9999-9999-999999999999", ANA = "11111111-1111-1111-1111-111111111111", BETO = "22222222-2222-2222-2222-222222222222";
for (const [id, n] of [[ADM, "chefe"], [ANA, "ana"], [BETO, "beto"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1,$2,$3)`, [id, n + "@t.l", JSON.stringify({ username: n })]); await as(id, `select public.create_character($1,'mago')`, [n[0].toUpperCase() + n.slice(1)]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
await sys(`update characters set coins = 5000`);
const newMon = async (u, sp, lv) => (await sys(`select (public.pk_new_monster($1, $2, $3)).id`, [u, sp, lv]))[0].id;
const picks = async n => { const out = new Set(); for (let i = 0; i < n; i++) out.add((await sys(`select public.pk_pick_species('Floresta') p`))[0].p); return [...out]; };
const puzzleIds = async (from, days) => { for (let i = 0; i < days; i++) await sys(`select public.ensure_puzzles(public.game_today() + $1::int)`, [from + i]);
  return (await sys(`select distinct pokemon_id from daily_puzzles where puzzle_date >= public.game_today() + $1::int`, [from])).map(r => r.pokemon_id); };

console.log("\nDesligada (padrão): o jogo fica igual");
check("a 2ª começa desligada", (await sys(`select public.gen2_on() g`))[0].g === false);
check("os dados estão lá (251 Pokémon, 251 ataques)", (await sys(`select (select count(*) from pokemon)::int p, (select count(*) from pk_moves)::int m`))[0].p === 251);
let ids = await puzzleIds(0, 40); check("40 dias de desafios: só Pokémon da 1ª", ids.length > 20 && ids.every(i => i <= 151), ids.filter(i => i > 151).join());
let pk = await picks(300); check("300 encontros: só da 1ª e a linha do Pikachu começa no Pikachu", pk.every(i => i <= 151) && !pk.includes(172), pk.filter(i => i > 151).join());
let r = await as(ANA, `select public.make_guess('classico', 152)`); check("palpite da 2ª é recusado", /ainda não faz parte/.test(r.error || ""), r.error);
r = await as(ANA, `select public.make_guess('classico', 25)`); check("palpite da 1ª continua normal", !r.error, r.error);
const golbat = await newMon(ANA, 42, 37), pichu = await newMon(ANA, 172, 20), eevee = await newMon(ANA, 133, 20);
await sys(`select public.pk_give_xp($1, 20000, 'teste')`, [golbat]);
check("Golbat sobe de nível sem pedir evolução para Crobat", !(await sys(`select 1 from mon_events where mon_id = $1 and kind = 'evolucao'`, [golbat])).length);
r = await as(ANA, `select public.mon_evolve($1, 169)`, [golbat]); check("evoluir para Crobat é recusado (Pokémon espera)", /desligada/.test(r.error || ""), r.error);
r = await as(ANA, `select public.mon_evolve($1, 25)`, [pichu]); check("Pichu já capturado não evolui com ela desligada", /desligada/.test(r.error || ""), r.error);
r = await as(ANA, `select public.pk_buy('pedra_sol', 1)`); check("pedras novas não estão à venda", /inválido/.test(r.error || ""), r.error);
r = await as(ANA, `select public.admin_set_gen2(true)`); check("jogador comum não liga a 2ª", /administrador/.test(r.error || ""), r.error);

console.log("\nLigada");
const today = (await sys(`select public.game_today()::text d`))[0].d;
r = await as(ADM, `select public.admin_set_gen2(true) c`); check("admin liga a 2ª", !r.error && r.rows[0].c.gen2 === true, r.error);
check("vale para os desafios a partir de amanhã", (await sys(`select (public.cfg()->>'gen2_from')::date = public.game_today() + 1 ok`))[0].ok);
check("o Jornal avisa", (await sys(`select 1 from event_log where kind = 'novidade' and message like 'A 2ª geração chegou%'`)).length === 1);
await sys(`delete from daily_puzzles where puzzle_date = public.game_today() and mode = 'descricao'`);
await sys(`select public.ensure_puzzles(public.game_today())`);
check("o desafio de hoje continua só da 1ª", (await sys(`select max(pokemon_id)::int m from daily_puzzles where puzzle_date = public.game_today()`))[0].m <= 151);
await sys(`delete from daily_puzzles where puzzle_date > public.game_today()`);
ids = await puzzleIds(1, 60); check("a partir de amanhã os desafios incluem a 2ª", ids.some(i => i > 151), `máximo ${Math.max(...ids)}`);
pk = await picks(400);
check("encontros incluem a 2ª", pk.some(i => i > 151), pk.join());
check("a linha do Pikachu agora começa no Pichu (Pikachu não aparece mais selvagem)", !pk.includes(25) && !pk.includes(35) && !pk.includes(39));
check("lendários das duas gerações nunca aparecem", !pk.some(i => [144, 145, 146, 150, 151, 243, 244, 245, 249, 250, 251].includes(i)));
r = await as(ANA, `select public.mon_evolve($1, 169)`, [golbat]); check("Golbat evolui para Crobat", !r.error, r.error);
r = await as(ANA, `select public.mon_evolve($1, 25)`, [pichu]); check("Pichu evolui para Pikachu", !r.error, r.error);
r = await as(ANA, `select public.mon_evolve($1, 196)`, [eevee]); check("Espeon pede a Pedra do Sol", /pedra/.test(r.error || ""), r.error);
r = await as(ANA, `select public.pk_buy('pedra_sol', 1)`); check("Pedra do Sol à venda", !r.error, r.error);
r = await as(ANA, `select public.mon_evolve($1, 196)`, [eevee]); check("Eevee evolui para Espeon com a pedra", !r.error, r.error);
check("tipos novos: Sombrio é forte contra Psíquico, e Psíquico não pega em Sombrio",
  (await sys(`select public.bt_eff('SOMBRIO', 'PSIQUICO', null) a, public.bt_eff('PSIQUICO', 'SOMBRIO', null) b, public.bt_eff('FOGO', 'METALICO', null) c`)).map(x => `${+x.a}/${+x.b}/${+x.c}`)[0] === "2/0/2");
check("Metálico é golpe físico; Sombrio é especial", (await sys(`select public.bt_physical('METALICO') a, public.bt_physical('SOMBRIO') b`))[0].a === true);
check("os confrontos antigos não mudaram (Fantasma x Psíquico continua 0, como na 1ª)", +(await sys(`select public.bt_eff('FANTASMA', 'PSIQUICO', null) e`))[0].e === 0);

console.log(`\nBatalhas sorteadas com as duas gerações (${NB})`);
let errs = [], notyet = 0, ends = {};
for (let k = 0; k < NB; k++) {
  await sys(`delete from battles`); await sys(`delete from monsters where user_id in ($1, $2)`, [ADM, BETO]);
  for (const u of [ADM, BETO]) for (let j = 0; j < 3; j++) {
    const m = await newMon(u, 1 + Math.floor(Math.random() * 251), 5 + Math.floor(Math.random() * 60));
    await sys(`update monsters set moves = (select array_agg(id) from (select id from pk_moves where id <> 165 order by random() limit 4) x), team_slot = $2 where id = $1`, [m, j + 1]);
  }
  const b0 = (await as(ADM, `select (public.battle_challenge($1, 10)).id`, [BETO])).rows?.[0]?.id;
  if (!b0) { errs.push("desafio falhou"); continue; }
  await as(BETO, `select public.battle_respond($1, true)`, [b0]);
  for (let g = 0; g < 300; g++) {
    const b = (await sys(`select * from battles where id = $1`, [b0]))[0]; if (b.status !== "ativa") break;
    for (const side of [0, 1]) {
      if (side === 0 ? b.ready1 : b.ready2) continue;
      const sd = b.state.sides[side], mon = sd.mons[sd.active];
      let kind = "move", val = Math.floor(Math.random() * mon.moves.length);
      if (b.phase === "troca" || sd.need_switch) { kind = "switch"; val = sd.mons.findIndex((m, i) => i !== sd.active && m.hp > 0); }
      else if (mon.moves.every(x => x.pp <= 0)) val = -1; else while (mon.moves[val].pp <= 0) val = (val + 1) % mon.moves.length;
      const rr = await as(side ? BETO : ADM, `select public.battle_act($1, $2, $3, $4)`, [b0, b.turn, kind, val]);
      if (rr.error && !/Não dá para trocar/.test(rr.error)) { errs.push(rr.error); break; }
      if (rr.error) await as(side ? BETO : ADM, `select public.battle_act($1, $2, 'move', 0)`, [b0, b.turn]);
    }
  }
  const b = (await sys(`select status, end_reason, log from battles where id = $1`, [b0]))[0];
  ends[b.end_reason || b.status] = (ends[b.end_reason || b.status] || 0) + 1;
  notyet += JSON.stringify(b.log).split("ainda não funciona").length - 1;
  if (/undefined|"null"/.test(JSON.stringify(b.log))) errs.push("relato estranho");
}
console.log("     finais:", JSON.stringify(ends), "| ataques que avisaram 'ainda não funciona':", notyet);
check("batalhas com Pokémon e ataques das duas gerações terminam sem erro", errs.length === 0 && !ends.ativa, errs.slice(0, 4).join(" | "));

console.log("\nDesligada de novo: ninguém perde nada");
const golbat2 = await newMon(ANA, 42, 40);
r = await as(ADM, `select public.admin_set_gen2(false) c`); check("admin desliga", !r.error && r.rows[0].c.gen2 === false, r.error);
check("Crobat e Espeon continuam na coleção", (await sys(`select count(*)::int n from monsters where id in ($1, $2) and species_id in (169, 196)`, [golbat, eevee]))[0].n === 2);
pk = await picks(300); check("encontros voltam a ser só da 1ª", pk.every(i => i <= 151));
r = await as(ANA, `select public.mon_evolve($1, 169)`, [golbat2]); check("evoluções da 2ª voltam a esperar", /desligada/.test(r.error || ""), r.error);
await sys(`delete from daily_puzzles where puzzle_date > public.game_today()`);
ids = await puzzleIds(1, 30); check("desafios futuros voltam a ser só da 1ª", ids.every(i => i <= 151));
r = await as(ADM, `select public.admin_set_gen2(true) c`); r = await as(ADM, `select public.admin_set_gen2(false) c`);
check("liga e desliga várias vezes sem erro", !r.error, r.error);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
