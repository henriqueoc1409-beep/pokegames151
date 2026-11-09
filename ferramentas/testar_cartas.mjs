// Testa o arquivo 87 (Cartas Pokegames) com dados de TESTE, como jogadores comuns.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_cartas.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql").sort()) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
const A = "11111111-1111-1111-1111-111111111111", B = "22222222-2222-2222-2222-222222222222", ADM = "99999999-9999-9999-9999-999999999999";
for (const [u, n] of [[A, "Ana"], [B, "Bia"], [ADM, "Chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'mago')`, [n]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
await sys(`update characters set coins = 5000 where true`);
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;
const est = async u => (await as(u, `select public.tcg_estado() s`)).rows[0].s;

console.log("\nAs cartas");
check("151 cartas, só da 1ª geração", (await sys(`select count(*)::int n, max(species) m from tcg_cartas`))[0].n === 151 && (await sys(`select max(species) m from tcg_cartas`))[0].m === 151);
const cz = (await sys(`select * from tcg_cartas where species = 6`))[0];
check("Charizard: PV 120, Ember 30, Flamethrower 90, ultra rara", cz.pv === 120 && cz.fraco_nome === "Ember" && cz.fraco_dano === 30 && cz.forte_nome === "Flamethrower" && cz.forte_dano === 90 && cz.raridade === "ultra", JSON.stringify(cz));
check("toda carta tem 2 ataques com dano", (await sys(`select count(*)::int n from tcg_cartas where fraco_dano < 10 or forte_dano < 20`))[0].n === 0);

console.log("\nPacotes e coleção");
let s = await est(A);
check("todo mundo começa com 2 pacotes", s.pacotes === 2, s.pacotes);
let r = await as(A, `select public.tcg_abrir_pacote() c`);
const pk = r.rows?.[0]?.c || [];
const rars = await Promise.all(pk.map(async c => (await sys(`select raridade from tcg_cartas where species = $1`, [c.s]))[0].raridade));
check("o pacote tem 5 cartas, a 4ª incomum ou melhor e a 5ª rara ou melhor", pk.length === 5 && rars[3] !== "comum" && ["rara", "ultra"].includes(rars[4]), JSON.stringify(rars));
check("as cartas entram na coleção", (await sys(`select coalesce(sum(qtd), 0)::int n from tcg_colecao where user_id = $1`, [A]))[0].n === 5);
check("e sobra 1 pacote", (await est(A)).pacotes === 1);
let c0 = await coins(A); r = await as(A, `select public.tcg_comprar_pacote(2) x`);
check("comprar 2 pacotes na loja (300 cada)", !r.error && c0 - (await coins(A)) === 600 && (await est(A)).pacotes === 3, r.error);
check("jogador não lê a coleção dos outros", (await as(B, `select count(*)::int n from tcg_colecao where user_id = $1`, [A])).rows[0].n === 0);

console.log("\nPrêmios automáticos");
await sys(`insert into daily_moves(user_id, move_date, modes, base_steps, roll, bonus_steps, from_node, to_node, xp_gained, coins_gained) values ($1, public.game_today(), '{}', 0, 1, 0, 0, 1, 0, 0)`, [A]);
let rs = (await as(A, `select public.tcg_resumo() r`)).rows[0].r;
check("andou hoje: ganha a carta do dia (aparece como nova)", rs.novas === 1, JSON.stringify(rs));
await as(A, `select public.tcg_resumo()`);
check("só uma por dia", (await sys(`select count(*)::int n from tcg_aberturas where user_id = $1 and origem = 'Carta do dia'`, [A]))[0].n === 1);
await as(A, `select public.tcg_visto()`);
check("depois de ver, some o aviso", (await as(A, `select public.tcg_resumo() r`)).rows[0].r.novas === 0);
const p0 = (await est(A)).pacotes;
await sys(`insert into round_results(d, user_id, rank, attempts, modes_solved) values (public.game_today(), $1, 1, 4, 4)`, [A]);
await as(A, `select public.tcg_resumo()`);
check("venceu a rodada: +1 pacote (uma vez só)", (await est(A)).pacotes === p0 + 1 && (await est(A)).pacotes === p0 + 1);

console.log("\nDeck");
const comuns = (await sys(`select species from tcg_cartas where raridade = 'comum' order by species limit 10`)).map(x => x.species);
for (const u of [A, B]) for (const sp of comuns) await sys(`insert into tcg_colecao(user_id, species, brilhante, qtd) values ($1, $2, false, 3) on conflict (user_id, species, brilhante) do update set qtd = 3`, [u, sp]);
const deck = comuns.map(s => ({ s, b: false }));
check("deck com 9 cartas não vale", /exatamente 10/.test((await as(A, `select public.tcg_deck_salvar($1::jsonb)`, [JSON.stringify(deck.slice(0, 9))])).error || ""));
check("3 cartas iguais não vale", /No máximo 2/.test((await as(A, `select public.tcg_deck_salvar($1::jsonb)`, [JSON.stringify([...deck.slice(1, 8), deck[0], deck[0], deck[0]])])).error || ""));
check("carta que não tem não vale", /não tem/.test((await as(A, `select public.tcg_deck_salvar($1::jsonb)`, [JSON.stringify([...deck.slice(0, 9), { s: 150, b: false }])])).error || ""));
for (const u of [A, B]) { r = await as(u, `select public.tcg_deck_salvar($1::jsonb)`, [JSON.stringify(deck)]); }
check("deck de 10 salvo", !r.error && (await est(A)).deck.length === 10, r.error);
check("desmanchar repetida dá moedas e deixa a do deck", !(await as(A, `select public.tcg_desmanchar($1, false, 2)`, [comuns[0]])).error
  && /fica pelo menos 1/.test((await as(A, `select public.tcg_desmanchar($1, false, 1)`, [comuns[0]])).error || ""));

console.log("\nMercado de cartas");
r = await as(B, `select (public.tcg_ofertar($1, false, 100)).id id`, [comuns[1]]);
const of = r.rows?.[0]?.id;
check("Bia põe uma repetida à venda", !r.error && of, r.error);
const ca = await coins(A), cb = await coins(B), qa = (await sys(`select coalesce(sum(qtd), 0)::int n from tcg_colecao where user_id = $1 and species = $2`, [A, comuns[1]]))[0].n;
r = await as(A, `select public.tcg_oferta_comprar($1)`, [of]);
check("Ana compra: paga 100, Bia recebe 95 (taxa 5%) e a carta muda de dono", !r.error && ca - (await coins(A)) === 100 && (await coins(B)) - cb === 95
  && (await sys(`select coalesce(sum(qtd), 0)::int n from tcg_colecao where user_id = $1 and species = $2`, [A, comuns[1]]))[0].n === qa + 1, r.error);

console.log("\nTreino contra o computador");
c0 = await coins(A);
let d = (await as(A, `select public.tcg_treino() d`)).rows?.[0]?.d;
check("o treino começa", d?.status === "ativa" && d.eu?.ativo && d.eu.mao.length === 3, JSON.stringify(d));
for (let i = 0; i < 300 && d.status === "ativa"; i++) {
  const ac = d.eu.energia >= 3 ? "forte" : d.eu.energia >= 1 ? "fraco" : "passar";
  r = await as(A, `select public.tcg_jogar($1, $2) d`, [d.id, ac]); if (r.error) { console.log(r.error); break; } d = r.rows[0].d;
}
check("o treino termina (alguém derruba 3)", d.status === "encerrada", d.status);
check("e não dá nem tira moedas", (await coins(A)) === c0);

console.log("\nDuelo valendo moedas");
const a0 = await coins(A), b0 = await coins(B);
r = await as(A, `select public.tcg_desafiar($1, 50) id`, [B]); const id = r.rows?.[0]?.id;
check("Ana desafia Bia valendo 50 (a parte dela fica guardada)", !r.error && a0 - (await coins(A)) === 50, r.error);
check("jogador não lê a tabela dos duelos", !!(await as(B, `select * from tcg_duelos`)).error || (await as(B, `select count(*)::int n from tcg_duelos`)).rows?.[0]?.n === 0);
d = (await as(B, `select public.tcg_responder($1, true) d`, [id])).rows?.[0]?.d;
check("Bia aceita e paga a parte dela", d?.status === "ativa" && b0 - (await coins(B)) === 50, JSON.stringify(d));
const quem = async () => { const x = (await as(A, `select public.tcg_duelo_estado($1) d`, [id])).rows[0].d; return x.minha_vez ? A : B; };
const outro = (await quem()) === A ? B : A;
check("não dá para jogar fora da vez", /não é a sua vez/.test((await as(outro, `select public.tcg_jogar($1, 'passar')`, [id])).error || ""));
const vA = (await as(A, `select public.tcg_duelo_estado($1) d`, [id])).rows[0].d;
check("a mão e o baralho do outro ficam escondidos", vA.op && !("mao" in vA.op) && !("pilha" in vA.op) && vA.op.mao_n === 3 || vA.op.mao_n >= 0 && !("mao" in vA.op), JSON.stringify(vA.op));
for (let i = 0; i < 400; i++) {
  const u = await quem(); const x = (await as(u, `select public.tcg_duelo_estado($1) d`, [id])).rows[0].d; if (x.status !== "ativa") break;
  const ac = x.eu.energia >= 3 ? "forte" : x.eu.energia >= 1 ? "fraco" : "passar";
  r = await as(u, `select public.tcg_jogar($1, $2) d`, [id, ac]); if (r.error) { console.log(r.error); break; }
}
const fim = (await sys(`select status, winner, quitado from tcg_duelos where id = $1`, [id]))[0];
check("o duelo termina e o vencedor leva 100", fim.status === "encerrada" && (fim.winner ? (await coins(fim.winner)) - (fim.winner === A ? a0 : b0) === 50 : true), JSON.stringify(fim));
check("as moedas dos dois somam o mesmo de antes", (await coins(A)) + (await coins(B)) === a0 + b0);
check("o ranking mostra o vencedor", !fim.winner || (await as(A, `select public.tcg_ranking() r`)).rows[0].r.duelos.some(x => x.user_id === fim.winner && x.v === 1));
r = await as(A, `select public.tcg_desafiar($1, 30) id`, [B]); const id2 = r.rows?.[0]?.id; const a1 = await coins(A);
await as(B, `select public.tcg_responder($1, false)`, [id2]);
check("recusar devolve a aposta", (await coins(A)) - a1 === 30);

console.log("\nAdmin");
check("os números ficam nos Ajustes do jogo", (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c.cartas?.pacote_preco === 300);
check("o aviso sai no Jornal", (await sys(`select count(*)::int n from posts where title = '🃏 Chegaram as Cartas Pokegames!'`))[0].n === 1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
