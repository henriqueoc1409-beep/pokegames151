// Testa o arquivo 103 (Equipamentos do +0 ao +9) com dados de TESTE, como jogadores comuns: loja, equipar, Doce de
// Forja (sucesso, falha que não perde até +4 e volta 1 do +5), máximo +9, bônus de cada peça (Calça XP, Peitoral vida,
// Botas raro, Luvas e Capacete), achados nas lutas, feira entre jogadores com taxa, funções internas fechadas, Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_equipamentos.mjs ..
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
await sys(`update monsters set team_slot = null where true`);
const forte = (await sys(`select (public.pk_new_monster($1, 150, 80)).id id`, [A]))[0].id; await sys(`update monsters set team_slot = 1 where id = $1`, [forte]);
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;
const est = async u => (await as(u, `select public.equip_estado() e`)).rows[0].e;
const cfgSet = (k, v) => sys(`update game_config set config = jsonb_set(config, $1::text[], $2::jsonb) where active`, [`{equip,${k}}`, JSON.stringify(v)]);
async function luta(bid) {
  for (let i = 0; i < 80; i++) { const b = (await sys(`select * from battles where id = $1`, [bid]))[0]; if (b.status !== "ativa") return b;
    let r; for (const mv of [0, 1, 2, 3, -1]) { r = await as(A, `select public.battle_act($1, $2, 'move', $3)`, [bid, b.turn, mv]); if (!r.error) break; } if (r.error) return b; }
  return (await sys(`select * from battles where id = $1`, [bid]))[0];
}
const prep = () => db.exec(`update rpg_dias set ult = null, batalhas = 0 where true; delete from battles where true; update monsters set tr_hp = 100 where true`);

console.log("\nLoja e equipar");
let e = await est(A);
check("começa sem peças e sem doces, preço 5.000", e.minhas.length === 0 && e.doces === 0 && e.preco === 5000);
await sys(`update characters set coins = 4000 where user_id = $1`, [A]);
check("sem moedas não compra", /5000 moedas/.test((await as(A, `select public.equip_comprar('calca')`)).error || ""));
await sys(`update characters set coins = 20000 where user_id = $1`, [A]);
for (const sl of ["calca", "peitoral", "botas"]) await as(A, `select public.equip_comprar($1)`, [sl]);
e = await est(A);
check("comprou 3 peças +0 por 15.000", e.minhas.length === 3 && e.minhas.every(p => p.nivel === 0) && await coins(A) === 5000);
const calca = e.minhas.find(p => p.slot === "calca").id, peit = e.minhas.find(p => p.slot === "peitoral").id, botas = e.minhas.find(p => p.slot === "botas").id;
for (const id of [calca, peit, botas]) await as(A, `select public.equip_equipar($1)`, [id]);
check("equipou as 3", (await est(A)).minhas.every(p => p.equipada));

console.log("\nDoce de Forja");
check("sem doce não refina", /Doce de Forja/.test((await as(A, `select public.equip_refinar($1)`, [calca])).error || ""));
await sys(`insert into equip_doces(user_id, qty) values ($1, 100) on conflict (user_id) do update set qty = 100`, [A]);
await cfgSet("chances", [100, 100, 100, 100, 100, 100, 100, 100, 100]);
for (let i = 0; i < 9; i++) await as(A, `select public.equip_refinar($1)`, [calca]);
check("com 100% de chance, 9 doces levam do +0 ao +9", (await sys(`select nivel from equip_pecas where id = $1`, [calca]))[0].nivel === 9);
check("não passa do +9", /máximo/.test((await as(A, `select public.equip_refinar($1)`, [calca])).error || ""));
check("o +9 vai para os Acontecimentos", (await sys(`select count(*)::int n from event_log where kind = 'equip' and message like '%+9%'`))[0].n === 1);
await cfgSet("chances", [0, 0, 0, 0, 0, 0, 0, 0, 0]);
await sys(`update equip_pecas set nivel = 3 where id = $1`, [botas]);
let r = (await as(A, `select public.equip_refinar($1) r`, [botas])).rows[0].r;
check("falhou no +3: só perde o doce, continua +3", r.ok === false && r.nivel === 3 && r.doces === 90, JSON.stringify(r));
await sys(`update equip_pecas set nivel = 6 where id = $1`, [botas]);
r = (await as(A, `select public.equip_refinar($1) r`, [botas])).rows[0].r;
check("falhou no +6: volta para o +5", r.ok === false && r.nivel === 5, JSON.stringify(r));
await cfgSet("chances", [100, 90, 80, 70, 55, 40, 30, 20, 10]);

console.log("\nBônus de cada peça");
check("Calça +9 = 18%", Number((await sys(`select public.eq_bonus($1, 'calca') v`, [A]))[0].v) === 18);
await prep();
let x = await as(A, `select public.rpg_encontro($1, 'mato') r`, [forte]); let b = await luta(x.rows[0].r.battle);
const w = b.state.sides[1].mons[0], res = b.state.treino.res, base = Math.floor(w.bexp * w.level / 7);
check("Calça +9: a vitória dá 18% a mais de experiência", res.won && res.xp === Math.ceil(base * 1.18), JSON.stringify([res.xp, base]));
await sys(`update equip_pecas set nivel = 9 where id = $1`, [peit]);
const semPeit = (await sys(`select (public.bt_mon($1)->>'maxhp')::int v`, [forte]))[0].v;
await prep(); x = await as(A, `select public.rpg_encontro($1, 'mato') r`, [forte]);
b = (await sys(`select * from battles where id = $1`, [x.rows[0].r.battle]))[0];
check("Peitoral +9 (−18% de dano): mais vida na luta da Aventura", b.state.sides[0].mons[0].maxhp === Math.round(semPeit * 100 / 82), JSON.stringify([b.state.sides[0].mons[0].maxhp, semPeit]));
await cfgSet("pecas,botas,bonus", [100, 100, 100, 100, 100, 100, 100, 100, 100, 100]);
let raro = true;
for (let i = 0; i < 10; i++) { await prep(); x = await as(A, `select public.rpg_encontro($1, 'mato') r`, [forte]); const sp = (await sys(`select state->'sides'->1->'mons'->0->>'species' s from battles where id = $1`, [x.rows[0].r.battle]))[0].s;
  if ((await sys(`select catch_rate from pokemon where id = $1`, [sp]))[0].catch_rate > 120) raro = false; }
check("Botas: com 100% de bônus, só aparecem os mais raros", raro);
await cfgSet("pecas,botas,bonus", [1, 2, 3, 4, 5, 7, 9, 11, 14, 18]);
await sys(`update characters set coins = 20000 where user_id = $1`, [A]);
for (const sl of ["luvas", "capacete"]) { await as(A, `select public.equip_comprar($1)`, [sl]); const id = (await sys(`select id from equip_pecas where user_id = $1 and slot = $2`, [A, sl]))[0].id; await as(A, `select public.equip_equipar($1)`, [id]); await sys(`update equip_pecas set nivel = 5 where id = $1`, [id]); }
check("Luvas e Capacete +5 = 7% cada (captura e moedas no tabuleiro)", Number((await sys(`select public.eq_bonus($1, 'luvas') + public.eq_bonus($1, 'capacete') v`, [A]))[0].v) === 14);

console.log("\nAchados nas lutas");
await cfgSet("doce_pct", 100); await cfgSet("peca_pct", 100);
const d0 = (await est(A)).doces, n0 = (await est(A)).minhas.length;
await prep(); x = await as(A, `select public.rpg_encontro($1, 'mato') r`, [forte]); b = await luta(x.rows[0].r.battle);
check("vencer selvagem pode dar Doce e peça (aparece no fim da luta)", b.state.treino.pos?.drop?.doces === 1 && !!b.state.treino.pos.drop.peca && (await est(A)).doces === d0 + 1 && (await est(A)).minhas.length === n0 + 1, JSON.stringify(b.state.treino.pos));
await cfgSet("doce_pct", 2); await cfgSet("peca_pct", 0.08);

console.log("\nFeira entre jogadores");
await sys(`update characters set coins = 10000 where user_id = $1`, [B]); const cA = await coins(A);
check("peça equipada vai à venda (sai do corpo)", !(await as(A, `select public.equip_ofertar('peca', $1, 1, 2000)`, [calca])).error && (await sys(`select equipada, a_venda from equip_pecas where id = $1`, [calca]))[0].a_venda === true);
check("peça à venda não pode ser equipada nem refinada", !!(await as(A, `select public.equip_equipar($1)`, [calca])).error && !!(await as(A, `select public.equip_refinar($1)`, [calca])).error);
check("não compra a própria oferta", !!(await as(A, `select public.equip_oferta_comprar(id) from equip_ofertas limit 1`)).error);
const of = (await sys(`select id from equip_ofertas where tipo = 'peca'`))[0].id;
r = await as(B, `select public.equip_oferta_comprar($1)`, [of]);
check("Beto compra a Calça +9: a peça vira dele e Ana recebe menos 5% de taxa", !r.error && (await sys(`select user_id, nivel from equip_pecas where id = $1`, [calca]))[0].user_id === B && await coins(A) === cA + 1900 && await coins(B) === 8000, r.error);
const dA = (await est(A)).doces;
await as(A, `select public.equip_ofertar('doce', null, 5, 100)`);
check("vender 5 doces separa os doces na hora", (await est(A)).doces === dA - 5);
const ofd = (await sys(`select id from equip_ofertas where tipo = 'doce'`))[0].id;
await as(A, `select public.equip_oferta_cancelar($1)`, [ofd]);
check("cancelar devolve os doces", (await est(A)).doces === dA);
await as(A, `select public.equip_ofertar('doce', null, 5, 100)`); const ofd2 = (await sys(`select id from equip_ofertas where tipo = 'doce'`))[0].id;
await as(B, `select public.equip_oferta_comprar($1)`, [ofd2]);
check("Beto compra os 5 doces", (await est(B)).doces === 5);
check("as ofertas aparecem para todos com o nome de quem vende", Array.isArray((await est(B)).ofertas));

console.log("\nSegurança e Jornal");
check("jogador não chama o achado direto", !!(await as(A, `select public.equip_drop($1, 'chefe')`, [A])).error);
check("jogador não lê os doces dos outros", (await as(B, `select count(*)::int n from equip_doces where user_id = '${A}'`)).rows[0].n === 0);
check("aparece em Ajustes do jogo", !!(await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c.equip?.pecas?.calca);
check("aviso publicado no Jornal uma vez", (await sys(`select count(*)::int n from posts where title = '🛡️ Equipamentos da Aventura: do +0 ao +9'`))[0].n === 1);
console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
