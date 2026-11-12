// Testa o arquivo 67 (heróis em tudo + Pesquisador e Mercador) com dados de TESTE, como jogadores comuns.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_herois.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql" && parseInt(f) < 77).sort((a, b) => parseInt(a) - parseInt(b) || a.localeCompare(b))) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
const U = n => `${n}${n}${n}${n}${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${String(n).repeat(12)}`;
const H = { guerreiro: U(1), mago: U(2), arqueiro: U(3), ladino: U(4), clerigo: U(5), domador: U(6), pesquisador: U(7), mercador: U(8) };
console.log("\nHeróis novos");
for (const [cls, u] of Object.entries(H)) {
  await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, cls + "@t.l", JSON.stringify({ username: "J" + cls.slice(0, 10) })]);
  const r = await as(u, `select public.create_character($1, $2)`, ["J" + cls.slice(0, 10), cls]);
  if (["pesquisador", "mercador"].includes(cls)) check(`dá para criar herói ${cls}`, !r.error, r.error);
}
await sys(`update characters set coins = 10000`);
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;
const newMon = async (u, sp, lv) => (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, sp, lv]))[0].id;

console.log("\nLojas (Mercador)");
const it = (await sys(`select id, price from shop_items where coins_ok and price > 0 and min_level <= 1 order by price desc limit 1`))[0];
let c0 = await coins(H.mercador); await as(H.mercador, `select public.buy_item($1)`, [it.id]);
check(`loja do herói 10% mais barata (${it.price} → ${Math.ceil(it.price * .9)})`, c0 - (await coins(H.mercador)) === Math.ceil(it.price * .9));
c0 = await coins(H.guerreiro); await as(H.guerreiro, `select public.buy_item($1)`, [it.id]);
check("os outros pagam o preço normal", c0 - (await coins(H.guerreiro)) === it.price);
c0 = await coins(H.mercador); await as(H.mercador, `select public.pk_buy('great_ball', 1)`);
check("Loja Pokémon também (Great Ball 40 → 36)", c0 - (await coins(H.mercador)) === 36);

console.log("\nCentro Pokémon (Clérigo)");
const mc = await newMon(H.clerigo, 7, 20), mg = await newMon(H.guerreiro, 7, 20);
await sys(`update monsters set tr_hp = 0, tr_hurt_at = now() where id in ($1, $2)`, [mc, mg]);
const stC = (await as(H.clerigo, `select public.treino_estado() s`)).rows[0].s, stG = (await as(H.guerreiro, `select public.treino_estado() s`)).rows[0].s;
check("Clérigo: cura 30% mais barata (60 → 42) e grátis em 48 h", stC.feridos[0].preco === 42 && stG.feridos[0].preco === 60 && stC.gratis_horas === 48 && stG.gratis_horas === 72, JSON.stringify([stC.feridos[0], stG.feridos[0], stC.gratis_horas]));
c0 = await coins(H.clerigo); await as(H.clerigo, `select public.centro_curar()`);
check("e paga 42 de verdade", c0 - (await coins(H.clerigo)) === 42);
await sys(`update monsters set tr_hp = 0, tr_hurt_at = now() - interval '49 hours' where id in ($1, $2)`, [mc, mg]);
await as(H.clerigo, `select public.treino_estado()`); await as(H.guerreiro, `select public.treino_estado()`);
const hp = async id => (await sys(`select tr_hp from monsters where id = $1`, [id]))[0].tr_hp;
check("49 h depois: o do Clérigo já voltou, o do Guerreiro ainda não", (await hp(mc)) === 100 && (await hp(mg)) === 0);

console.log("\nCreche (Domador)");
const md = await newMon(H.domador, 4, 10);
let r = await as(H.domador, `select public.creche_treinar($1, 2) x`, [md]);
check("Creche 20% mais barata para o Domador (230 → 184)", r.rows?.[0].x.custo === 184, r.error || JSON.stringify(r.rows));
check("o estado mostra o desconto", (await as(H.domador, `select public.creche_estado() s`)).rows[0].s.desconto_pct === 20);

console.log("\nLeilão (Ladino e Mercador)");
const vender = async (vend, comp, sp) => {
  const m = await newMon(vend, sp, 10); const l = (await as(vend, `select public.leilao_criar($1, 100) x`, [m])).rows[0].x.id;
  await as(comp, `select public.leilao_lance($1, 200)`, [l]); const v0 = await coins(vend);
  await sys(`update leiloes set ends_at = now() - interval '1 second' where id = $1`, [l]); await as(comp, `select public.leilao_estado()`);
  return (await coins(vend)) - v0;
};
check("vendendo por 200: normal recebe 190 (5%)", (await vender(H.guerreiro, H.mago, 16)) === 190);
check("Ladino recebe 196 (2%)", (await vender(H.ladino, H.mago, 19)) === 196);
check("Mercador recebe 200 (sem taxa)", (await vender(H.mercador, H.mago, 10)) === 200);

console.log("\nTabuleiro e encontros");
await sys(`update game_config set config = jsonb_set(config, '{pk_start_at}', to_jsonb(now() - interval '1 minute')) where active`);
for (const cls of ["pesquisador", "mercador", "arqueiro"]) { const s = await as(H[cls], `select public.use_skill()`); if (s.error) console.log(cls, s.error); }
for (const cls of ["pesquisador", "mercador", "arqueiro", "guerreiro"]) { const m = await as(H[cls], `select public.move_today()`); if (m.error) console.log(cls, m.error); }
const mv = async u => (await sys(`select * from daily_moves where user_id = $1`, [u]))[0];
check("Pesquisador: Isca de frutas anda +1 casa", (await mv(H.pesquisador)).skill_steps === 1);
check("Mercador: Negócio da China anda +1 casa", (await mv(H.mercador)).skill_steps === 1);
check("Arqueiro: Tiro certeiro deixa a roleta no máximo (3)", (await mv(H.arqueiro)).roll === 3);
await newMon(H.pesquisador, 1, 5); await sys(`update monsters set team_slot = 1 where user_id = $1`, [H.pesquisador]);
await newMon(H.guerreiro, 1, 5); await sys(`update monsters set team_slot = 1 where user_id = $1 and species_id = 1`, [H.guerreiro]);
const sp = (await as(H.pesquisador, `select public.pk_sync() s`)).rows[0].s, sg = (await as(H.guerreiro, `select public.pk_sync() s`)).rows[0].s;
check("Pesquisador tem 4 bolas por encontro (os outros, 3)", sp.encounter?.throws_left === 4 && sg.encounter?.throws_left === 3, JSON.stringify([sp.encounter?.throws_left, sg.encounter?.throws_left]));
const cr = (await sys(`select catch_rate from pokemon where id = $1`, [sp.encounter.species_id]))[0].catch_rate;
check(`com a Isca de frutas, o Pokémon é incomum ou mais raro (captura ${cr} < 190)`, cr < 190);
const pool = async u => (await sys(`select xp_pool from pk_move_sync where user_id = $1`, [u]))[0].xp_pool;
const base = async u => { const d = await mv(u); const modes = Object.values(d.modes.modes || d.modes).filter(x => x && x.solved).length; return 100 + 15 * d.base_steps + 40 * modes; };
check("Pesquisador: +10% de XP da equipe na andada", (await pool(H.pesquisador)) === Math.ceil((await base(H.pesquisador)) * 110 / 100) && (await pool(H.guerreiro)) === (await base(H.guerreiro)));

console.log("\nBatalha (Guerreiro)");
const mon = (await sys(`select public.npc_mon(6, 30) m`))[0].m, alvo = (await sys(`select public.npc_mon(10, 5) m`))[0].m;
alvo.hp = alvo.maxhp = 9999;
const st = u => ({ sides: [{ user: u, active: 0, mons: [{ ...mon, moves: [{ id: 33, pp: 35, max: 35 }] }] }, { user: H.mago, npc: true, active: 0, mons: [alvo] }] });
// mediana (o golpe crítico dobra o dano e deixava a média sorteada demais)
const media = async u => { const ds = []; for (let i = 0; i < 300; i++) { const s = (await sys(`select public.bt_use_move($1::jsonb, 0, 33, true) s`, [JSON.stringify(st(u))]))[0].s; const d = 9999 - s.sides[1].mons[0].hp; if (d > 0) ds.push(d); } ds.sort((a, b) => a - b); return ds[ds.length >> 1]; };
const dG = await media(H.guerreiro), dM = await media(H.mago);
check(`Guerreiro dá ~10% a mais de dano (${dG.toFixed(1)} contra ${dM.toFixed(1)})`, dG / dM > 1.05 && dG / dM < 1.2);
const cfgA = (await sys(`select public.admin_cfg_efetiva() c`).catch(() => null));
check("os números dos heróis estão nos Ajustes do jogo", (await sys(`select public.herois_cfg()->>'guerreiro_dano_pct' x`))[0].x === "10");
check("a novidade está no Jornal", (await sys(`select count(*)::int n from posts where title like '🛡️ Heróis mais fortes%'`))[0].n === 1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
