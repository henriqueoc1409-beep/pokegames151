// Testa o arquivo 112 (Vale do Treino e Fazenda de Frutas) com dados de TESTE, como jogadores comuns.
// Vale: começar conta no limite do dia, só Pokémon seu, estação que não existe, rápido demais é recusado, a nota vira XP
// pela conta (exp_ref × nível ÷ 7 × nota/100 × afinidade), afinidade pelo tipo, nota abaixo do mínimo não dá XP, nota fora
// de 0..100 é cortada, terminar duas vezes não, treino aberto que ficou para trás some, demora demais = sem XP, limite do
// dia, desligado, tabelas fechadas.
// Fazenda: canteiros de começo e do Pomar, plantar paga a semente, plantar em todos os vazios, não colhe antes da hora,
// colhe e guarda na cesta, regar a horta de outro (cresce mais rápido, quem rega ganha a fruta, uma vez por canteiro,
// limite de regas, não rega a própria), dar fruta (XP, mais quando o tipo gosta, limite por dia, sem fruta não), comprar
// canteiro, horta dos outros sem a cesta, hortas para regar. Ajustes do jogo e Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_vale_fazenda.mjs ..
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
const mk = async (u, sp, lv, slot) => { const id = (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, sp, lv]))[0].id; if (slot) await sys(`update monsters set team_slot = $2 where id = $1`, [id, slot]); return id; };
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;
const exp = async id => (await sys(`select exp, level from monsters where id = $1`, [id]))[0];
const atras = async (id, seg) => sys(`update vale_treinos set comecou_em = now() - make_interval(secs => $2) where id = $1`, [id, seg]);
const conta = (ref, nv, nota, mult) => Math.max(0, Math.floor(ref * nv / 7 * Math.max(0, Math.min(100, nota)) / 100 * mult + 0.5));
// Pikachu (Elétrico) combina com a Pista; Geodude (Pedra/Terra) não
const pika = await mk(A, 25, 20, 1), geo = await mk(A, 74, 20, 2), dele = await mk(B, 1, 10, 1);

console.log("\nVale do Treino");
let e = (await as(A, `select public.vale_estado() e`)).rows[0].e;
check("o estado mostra as 6 estações, o limite e 0 treinos hoje", Object.keys(e.estacoes).length === 6 && e.treinos === 0 && e.treinos_dia === 8, JSON.stringify(e).slice(0, 200));
check("estação que não existe é recusada", !!(await as(A, `select public.vale_comecar('piscina', $1)`, [pika])).error);
check("só treina Pokémon seu", /não é seu/.test((await as(A, `select public.vale_comecar('pista', $1)`, [dele])).error || ""));
let r = (await as(A, `select public.vale_comecar('pista', $1) e`, [pika])).rows[0].e;
check("começar devolve o treino, a semente e a afinidade (Pikachu na Pista)", r.id && Number.isInteger(r.semente) && r.afinidade === true && r.treinos === 1, JSON.stringify(r));
check("terminar logo depois de começar é recusado (rápido demais)", /rápido demais/.test((await as(A, `select public.vale_terminar($1, 90)`, [r.id])).error || ""));
await atras(r.id, 20);
let x0 = await exp(pika);
let t = (await as(A, `select public.vale_terminar($1, 80) e`, [r.id])).rows[0].e;
let x1 = await exp(pika);
check("a nota vira XP pela conta: 120 × nível ÷ 7 × 80% × 1,5 (combina)", t.xp === conta(120, 20, 80, 1.5) && x1.exp - x0.exp === t.xp, `${t.xp} ${conta(120, 20, 80, 1.5)} ${x1.exp - x0.exp}`);
check("o resultado traz o nível antes e depois e o estado novo", t.nivel_antes === 20 && t.nivel_depois >= 20 && t.estado.treinos === 1);
check("terminar duas vezes não", /já terminou/.test((await as(A, `select public.vale_terminar($1, 80)`, [r.id])).error || ""));
r = (await as(A, `select public.vale_comecar('pista', $1) e`, [geo])).rows[0].e; await atras(r.id, 20);
x0 = await exp(geo); t = (await as(A, `select public.vale_terminar($1, 80) e`, [r.id])).rows[0].e;
check("sem afinidade (Geodude na Pista): sem o bônus", r.afinidade === false && t.xp === conta(120, 20, 80, 1), `${t.xp}`);
r = (await as(A, `select public.vale_comecar('saco', $1) e`, [geo])).rows[0].e;
check("Geodude (Pedra) combina com o Saco de Pancada", r.afinidade === true);
await atras(r.id, 20); t = (await as(A, `select public.vale_terminar($1, 500) e`, [r.id])).rows[0].e;
check("nota acima de 100 é cortada em 100", t.nota === 100 && t.xp === conta(120, t.nivel_antes, 100, 1.5), JSON.stringify(t).slice(0, 120));
r = (await as(A, `select public.vale_comecar('templo', $1) e`, [pika])).rows[0].e; await atras(r.id, 20);
t = (await as(A, `select public.vale_terminar($1, 5) e`, [r.id])).rows[0].e;
check("nota abaixo do mínimo (10) não dá XP", t.xp === 0 && t.nota === 5);
r = (await as(A, `select public.vale_comecar('lago', $1) e`, [pika])).rows[0].e;
const r2 = (await as(A, `select public.vale_comecar('lago', $1) e`, [pika])).rows[0].e;
const aberto = (await sys(`select nota, xp, terminou_em from vale_treinos where id = $1`, [r.id]))[0];
check("começar outro fecha o que ficou aberto, sem XP (e conta os dois)", aberto.terminou_em && aberto.xp === 0 && r2.treinos === 6, JSON.stringify(aberto) + " " + r2.treinos);
await atras(r2.id, 20 * 60);
t = (await as(A, `select public.vale_terminar($1, 100) e`, [r2.id])).rows[0].e;
check("demorou demais (mais de 15 min): o treino vence sem XP", t.xp === 0 && t.nota === 0);
for (let i = 0; i < 2; i++) { const q = (await as(A, `select public.vale_comecar('fogueira', $1) e`, [pika])).rows[0].e; await atras(q.id, 20); await as(A, `select public.vale_terminar($1, 50)`, [q.id]); }
check("passou do limite do dia (8): não começa", /já fez os 8 treinos/.test((await as(A, `select public.vale_comecar('pista', $1)`, [pika])).error || ""));
e = (await as(A, `select public.vale_estado() e`)).rows[0].e;
check("o estado mostra os 8 treinos, a XP do dia e os últimos resultados", e.treinos === 8 && e.xp_hoje > 0 && e.recentes.length === 6, JSON.stringify(e).slice(0, 160));
check("o site não lê as tabelas do Vale direto", !((await as(A, `select * from vale_treinos`)).rows?.length) && !((await as(A, `select * from vale_dias`)).rows?.length));
check("o jogador não chama as funções internas", !!(await as(A, `select public.vale_cfg()`)).error && !!(await as(A, `select public.vale_xp_conta(1, 1, 1, 1)`)).error);
await sys(`update game_config set config = jsonb_set(config, '{vale,on}', 'false') where active`);
check("desligado pelo admin: não começa", /fechado/.test((await as(B, `select public.vale_comecar('pista', $1)`, [dele])).error || ""));
await sys(`update game_config set config = jsonb_set(config, '{vale,on}', 'true') where active`);

console.log("\nFazenda de Frutas");
let f = (await as(A, `select public.fazenda_estado() e`)).rows[0].e;
check("começa com 4 canteiros vazios, a cesta vazia e as 6 frutas", f.total === 4 && f.canteiros.length === 0 && Object.keys(f.cesta).length === 0 && Object.keys(f.frutas).length === 6 && f.mine === true, JSON.stringify(f).slice(0, 200));
await sys(`insert into villages(user_id) values ($1) on conflict do nothing`, [A]);
await sys(`update villages set orchard_level = 1 where user_id = $1`, [A]);
f = (await as(A, `select public.fazenda_estado() e`)).rows[0].e;
check("com o Pomar construído: +2 canteiros", f.total === 6 && f.tem_pomar === true);
await sys(`update villages set damaged = jsonb_build_object('pomar', jsonb_build_object('fix', now() + interval '1 day')) where user_id = $1`, [A]);
check("Pomar danificado na guerra: os canteiros dele não contam", (await as(A, `select public.fazenda_estado() e`)).rows[0].e.total === 4);
await sys(`update villages set damaged = '{}'::jsonb where user_id = $1`, [A]);
await sys(`update characters set coins = 1000 where user_id in ($1, $2)`, [A, B]);
let c0 = await coins(A);
let p = (await as(A, `select public.fazenda_plantar(1, 'brasa') e`)).rows[0].e;
check("plantar uma Fruta-Brasa paga a semente (10)", p.custo === 10 && (await coins(A)) === c0 - 10 && p.estado.canteiros.length === 1 && p.estado.canteiros[0].pronto === false);
check("não planta em canteiro ocupado nem em canteiro que não existe", !!(await as(A, `select public.fazenda_plantar(1, 'mel')`)).error && !!(await as(A, `select public.fazenda_plantar(9, 'mel')`)).error);
check("fruta que não existe é recusada", !!(await as(A, `select public.fazenda_plantar(2, 'banana')`)).error);
c0 = await coins(A);
p = (await as(A, `select public.fazenda_plantar(null, 'mel') e`)).rows[0].e;
check("plantar em todos os vazios: 5 canteiros × 5 moedas", p.plantados === 5 && p.custo === 25 && (await coins(A)) === c0 - 25, JSON.stringify(p).slice(0, 100));
check("não colhe antes da hora", /Nada pronto/.test((await as(A, `select public.fazenda_colher(null)`)).error || ""));
// Beto rega a Brasa da Ana
const antes = (await sys(`select extract(epoch from pronto_em - now()) s from fazenda_canteiros where user_id = $1 and slot = 1`, [A]))[0].s;
check("ninguém rega a própria horta", /amigos/.test((await as(A, `select public.fazenda_regar($1, 1)`, [A])).error || ""));
let g = (await as(B, `select public.fazenda_regar($1, 1) e`, [A])).rows[0].e;
const depois = (await sys(`select extract(epoch from pronto_em - now()) s from fazenda_canteiros where user_id = $1 and slot = 1`, [A]))[0].s;
check("regar faz a planta crescer 15% mais rápido", Math.abs(depois - antes * 0.85) < 5, `${antes} ${depois}`);
check("quem regou ganha 1 fruta igual na cesta", g.fruta === "brasa" && g.ganhou === 1 && (await sys(`select qtd from fazenda_cesta where user_id = $1 and fruta = 'brasa'`, [B]))[0]?.qtd === 1);
check("o mesmo jogador não rega o mesmo canteiro duas vezes", /já regou/.test((await as(B, `select public.fazenda_regar($1, 1)`, [A])).error || ""));
const visto = (await as(B, `select public.fazenda_estado($1) e`, [A])).rows[0].e;
check("visitando: vê os canteiros e quem regou, sem a cesta", visto.mine === false && visto.cesta === null && visto.canteiros[0].regadores.includes("Beto") && visto.canteiros[0].eu_reguei === true, JSON.stringify(visto.canteiros[0]));
const rg = (await as(B, `select public.fazenda_regaveis() e`)).rows[0].e;
check("hortas para regar: a da Ana aparece com os canteiros que faltam", rg.length === 1 && rg[0].nome === "Ana" && rg[0].n === 5, JSON.stringify(rg));
for (let s2 = 2; s2 <= 5; s2++) await as(B, `select public.fazenda_regar($1, $2)`, [A, s2]);
check("limite de regas por dia (5)", /já regou 5/.test((await as(B, `select public.fazenda_regar($1, 6)`, [A])).error || ""));
await sys(`update fazenda_canteiros set pronto_em = now() - interval '1 minute' where user_id = $1`, [A]);
const col = (await as(A, `select public.fazenda_colher(null) e`)).rows[0].e;
check("colhe todos os prontos: 3 frutas por canteiro na cesta", col.colhidos === 6 && col.frutas.brasa === 3 && col.frutas.mel === 15 && col.estado.canteiros.length === 0 && col.estado.cesta.mel === 15, JSON.stringify(col.frutas));
// dar de comer
const char = await mk(A, 4, 20);   // Charmander (Fogo) gosta da Brasa
x0 = await exp(char);
let d = (await as(A, `select public.fazenda_dar($1, 'brasa') e`, [char])).rows[0].e;
x1 = await exp(char);
check("Fruta-Brasa para o Charmander (Fogo gosta): 70 × 20 ÷ 7 × 1,5", d.gosta === true && d.xp === conta(70, 20, 100, 1.5) && x1.exp - x0.exp === d.xp, `${d.xp}`);
d = (await as(A, `select public.fazenda_dar($1, 'mel') e`, [char])).rows[0].e;
check("Fruta-Mel para o Charmander (não gosta): sem o bônus", d.gosta === false && d.xp === conta(40, d.nivel_antes, 100, 1), `${d.xp}`);
check("a fruta sai da cesta", d.estado.cesta.brasa === 2 && d.estado.cesta.mel === 14);
check("sem a fruta na cesta não dá", /não tem essa fruta/.test((await as(A, `select public.fazenda_dar($1, 'rocha')`, [char])).error || ""));
check("só Pokémon seu come", /não é seu/.test((await as(A, `select public.fazenda_dar($1, 'mel')`, [dele])).error || ""));
for (let i = 0; i < 8; i++) await as(A, `select public.fazenda_dar($1, 'mel')`, [geo]);
check("limite de frutas por dia (10)", /já comeram 10/.test((await as(A, `select public.fazenda_dar($1, 'mel')`, [geo])).error || ""));
c0 = await coins(A);
let cb = (await as(A, `select public.fazenda_comprar_canteiro() e`)).rows[0].e;
check("comprar canteiro: 400 moedas, +1 canteiro", cb.preco === 400 && (await coins(A)) === c0 - 400 && cb.estado.total === 7);
await sys(`update characters set coins = 5000 where user_id = $1`, [A]);
await as(A, `select public.fazenda_comprar_canteiro()`);
check("depois do último preço não compra mais", /todos os canteiros/.test((await as(A, `select public.fazenda_comprar_canteiro()`)).error || ""));
check("o site não lê as tabelas da Fazenda direto", !((await as(A, `select * from fazenda_cesta`)).rows?.length) && !((await as(A, `select * from fazenda_canteiros`)).rows?.length));
await sys(`update game_config set config = jsonb_set(config, '{fazenda,on}', 'false') where active`);
check("desligada pelo admin: não planta", /fechada/.test((await as(B, `select public.fazenda_plantar(1, 'mel')`)).error || ""));
await sys(`update game_config set config = jsonb_set(config, '{fazenda,on}', 'true') where active`);

console.log("\nAjustes e Jornal");
const aj = (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c;
check("Ajustes do jogo mostram o Vale e a Fazenda", aj.vale?.treinos_dia === 8 && aj.fazenda?.frutas_dia === 10);
check("jogador comum não vê os Ajustes", !!(await as(A, `select public.admin_cfg_efetiva()`)).error);
check("a vila nova vem ligada no visual (o admin desliga)", aj.visual?.vila_nova === true && (await sys(`select config->'visual'->>'vila_nova' v from game_config where active`))[0].v === "true");
const posts = await sys(`select title from posts where title in ('🥋 Vale do Treino na Aventura', '🍓 Fazenda de Frutas e vila nova')`);
check("o Jornal tem as duas novidades, uma vez cada", posts.length === 2);

console.log(`\n${ok} ok, ${fail} falharam`);
process.exit(fail ? 1 : 0);
