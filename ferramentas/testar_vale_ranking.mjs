// Testa o arquivo 128 (Top 3 das estações do Vale do Treino, prêmio no fim da temporada e Praça fechada)
// com dados de TESTE, como jogadores comuns: melhor nota de cada jogador na temporada, empate por quem fez primeiro,
// treino de outra temporada e de admin não contam, Pokémon do treino no ranking, minha melhor nota, prêmio do top 3
// de cada estação com Correio e Acontecimentos, uma vez só, campeões no Vale, Ajustes, Praça fechada, Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_vale_ranking.mjs ..
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
const U = n => `${n}${n}${n}${n}${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${String(n).repeat(12)}`;
const [A, B, C, D, ADM] = [U(1), U(2), U(3), U(4), U(9)];
for (const [u, n] of [[A, "ana"], [B, "beto"], [C, "caio"], [D, "duda"], [ADM, "chefe"]]) await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]);
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
for (const [u, n] of [[A, "Ana"], [B, "Beto"], [C, "Caio"], [D, "Duda"], [ADM, "Chefe"]]) await as(u, `select public.create_character($1, 'mago')`, [n]);
// temporada que começou há 10 dias
const SID = (await sys(`select id from seasons order by id desc limit 1`))[0].id;
await sys(`update seasons set started_on = current_date - 10, status = 'ativa', ended_on = null where id = $1`, [SID]);
// treino terminado (nota, Pokémon, nível, há quantas horas)
const treino = (u, est, nota, esp, nv, horas) => sys(`insert into vale_treinos(user_id, mon_id, estacao, especie, nivel, comecou_em, terminou_em, nota, xp)
  values ($1, gen_random_uuid(), $2, $3, $4, now() - make_interval(hours => $5) - interval '1 minute', now() - make_interval(hours => $5), $6, 10)`, [u, est, esp, nv, horas, nota]);
await treino(A, "fogueira", 80, 4, 12, 50);  await treino(A, "fogueira", 95, 6, 36, 30);   // Ana: melhor 95 com Charizard
await treino(B, "fogueira", 95, 126, 30, 20);                                              // Beto: 95 também, mas depois
await treino(C, "fogueira", 70, 58, 20, 10);
await treino(D, "fogueira", 60, 77, 15, 5);
await treino(ADM, "fogueira", 100, 38, 50, 5);                                            // admin não entra
await treino(D, "fogueira", 99, 37, 15, 24 * 20);                                         // temporada passada: não conta
await treino(B, "lago", 88, 7, 18, 3);

console.log("\n1. Top 3 da temporada");
let st = (await as(C, `select public.vale_estado() s`)).rows[0].s;
const fg = st.ranking?.fogueira || [];
check("top 3 da fogueira: Ana, Beto (empate: Ana fez primeiro) e Caio", fg.map(r => r.nome).join(",") === "Ana,Beto,Caio", JSON.stringify(fg));
check("vale a MELHOR nota de cada um, com o Pokémon e o nível daquele treino", fg[0]?.nota === 95 && fg[0]?.especie === 6 && fg[0]?.nivel === 36, JSON.stringify(fg[0]));
check("admin e treino de outra temporada não contam", !fg.some(r => r.nome === "Chefe") && !fg.some(r => r.nota === 99));
check("só 3 aparecem", fg.length === 3);
check("outra estação tem o próprio ranking", st.ranking?.lago?.[0]?.nome === "Beto" && st.ranking?.lago?.length === 1 && Array.isArray(st.ranking?.pista) && !st.ranking.pista.length);
check("minha melhor nota em cada estação", st.meu_melhor?.fogueira?.nota === 70 && st.meu_melhor?.lago == null, JSON.stringify(st.meu_melhor));
check("os prêmios aparecem para todos (150/100/50)", JSON.stringify(st.premios) === "[150,100,50]");
check("jogador comum não chama vale_top nem vale_premiar", !!(await as(A, `select * from public.vale_top('fogueira', now() - interval '1 day', now(), 3)`)).error && !!(await as(A, `select public.vale_premiar(1)`)).error);

console.log("\n2. Prêmio no fim da temporada");
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;
const antes = { A: await coins(A), B: await coins(B), C: await coins(C), D: await coins(D) };
await sys(`update seasons set status = 'encerrada', ended_on = current_date where id = $1`, [SID]);
await sys(`select public.season_awards_give($1)`, [SID]);
const ganho = async (u, k) => (await coins(u)) - antes[k];
const pr = await sys(`select estacao, pos, user_id, nota, especie, coins from vale_premios where season_id = $1 order by estacao, pos`, [SID]);
check("top 3 da fogueira premiado na ordem certa", pr.filter(p => p.estacao === "fogueira").map(p => [p.pos, p.user_id, p.coins].join(":")).join(",") === `1:${A}:150,2:${B}:100,3:${C}:50`, JSON.stringify(pr));
check("o 1º do lago também é premiado (Beto ganha nas duas estações)", pr.some(p => p.estacao === "lago" && p.pos === 1 && p.user_id === B));
const vgA = (await sys(`select coalesce(sum(coins), 0)::int n from vale_premios where user_id = $1`, [A]))[0].n;
check("as moedas do Vale entram na conta (Ana +150 do Vale)", vgA === 150 && (await ganho(A, "A")) >= 150, await ganho(A, "A"));
check("quem ficou fora do top 3 não ganha pelo Vale", !pr.some(p => p.user_id === D));
check("presente no Correio com a estação, a nota e o Pokémon", (await sys(`select count(*)::int n from gifts where user_id = $1 and message like '%Fogueira do Fôlego%nota 95%Charizard%150 moedas%'`, [A]))[0].n === 1);
check("aparece nos Acontecimentos", (await sys(`select count(*)::int n from event_log where message like '%Campeões do Vale do Treino%'`))[0].n === 1);
check("vai para o extrato como prêmio", (await sys(`select count(*)::int n from moedas_extrato where user_id = $1 and origem = 'Prêmio do Vale do Treino'`, [A]))[0].n === 1);
const depois = await coins(A);
await sys(`select public.season_awards_give($1)`, [SID]); await sys(`select public.vale_premiar($1)`, [SID]);
check("paga uma vez só", (await coins(A)) === depois && (await sys(`select count(*)::int n from vale_premios where season_id = $1`, [SID]))[0].n === pr.length);
st = (await as(D, `select public.vale_estado() s`)).rows[0].s;
check("o Vale mostra os campeões da última temporada", st.campeoes_temporada === SID && st.campeoes?.fogueira?.[0]?.nome === "Ana");
check("qualquer jogador lê os campeões", (await as(D, `select count(*)::int n from vale_premios`)).rows?.[0]?.n === pr.length);

console.log("\n3. Ajustes, Praça e Jornal");
const ef = (await as(ADM, `select public.admin_cfg_efetiva() e`)).rows[0].e;
check("o ranking está em Ajustes do jogo → Vale do Treino", ef.vale?.ranking?.top === 3 && ef.vale?.ranking?.on === true);
await sys(`update game_config set config = jsonb_set(config, '{vale,ranking,premios}', '[300, 0, 0]') where active`);
check("o admin muda os prêmios", JSON.stringify((await as(C, `select public.vale_estado() s`)).rows[0].s.premios) === "[300,0,0]");
check("a Praça Central fica fechada", (await sys(`select config->'praca'->>'on' v from game_config where active`))[0].v === "false");
check("aviso publicado no Jornal uma vez", (await sys(`select count(*)::int n from posts where title = '🏆 Vale do Treino: Top 3 de cada estação e prêmio na temporada'`))[0].n === 1);
const html = fs.readFileSync(path.join(root, "deploy/index.html"), "utf8");
check("o site mostra o top 3, tem a novidade e não tem mais a Praça no menu",
  html.includes("function valeRankHTML") && html.includes('title: "🏆 Vale do Treino: Top 3 de cada estação e prêmio na temporada"') && !html.includes('["caixa", "chat", "correio", "praca"]') && !html.includes('btn("⛲", "Praça Central"'));
console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
