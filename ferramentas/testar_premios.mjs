// Testa o arquivo 50 (prêmios da temporada) com dados de TESTE, como jogadores comuns:
// placar ao vivo das 12 categorias (só até ontem, sem spoiler), entrega no fim da temporada (150 moedas,
// medalha, presente no Correio, Jornal), empate premia todos, uma vez só, e o botão de reserva do admin.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_premios.mjs ..
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
const U = n => `${n}${n}${n}${n}${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${String(n).repeat(12)}`;
const [A, B, C, ADM] = [U(1), U(2), U(3), U(9)];
for (const [u, n] of [[A, "Ana"], [B, "Beto"], [C, "Caio"], [ADM, "Chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'guerreiro')`, [n]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
const season = (await sys(`select id from seasons order by id desc limit 1`))[0].id;
await sys(`update seasons set started_on = public.game_today() - 10 where id = $1`, [season]);
const ago = d => `now() - interval '${d} days'`;
// dados de mentira da temporada (Ana na frente em quase tudo; Ana e Beto empatam nas capturas; Caio anda muito HOJE)
const mv = async (u, d, steps, coins) => sys(`insert into daily_moves(user_id, move_date, modes, base_steps, roll, bonus_steps, skill_steps, from_node, to_node, xp_gained, coins_gained, events, recovered)
  values ($1, public.game_today() - $2::int, '{}', $3, 0, 0, 0, 1, 1, 0, $4, '[]', false)`, [u, d, steps, coins]);
await mv(A, 3, 20, 100); await mv(A, 2, 15, 50); await mv(B, 2, 10, 300); await mv(C, 0, 99, 999);
for (const [u, n] of [[A, 2], [B, 2], [C, 1]]) for (let i = 0; i < n; i++) await sys(`insert into encounters(user_id, move_id, node, species_id, level, throws_left, status, resolved_at)
  values ($1, gen_random_uuid(), 1, 1, 5, 0, 'capturado', ${ago(2)})`, [u]);
await sys(`insert into round_results(d, user_id, rank, attempts, modes_solved) values (public.game_today() - 3, $1, 1, 6, 4), (public.game_today() - 2, $1, 1, 5, 4), (public.game_today() - 2, $2, 2, 8, 4)`, [A, B]);
await sys(`insert into battles(p1, p2, status, winner, mode, ended_at) values ($1, $2, 'encerrada', $1, 'duelo', ${ago(1)}), ($2, $1, 'encerrada', $2, 'guerra', ${ago(1)}), ($2, $2, 'encerrada', $2, 'npc', ${ago(1)})`, [A, B]);
await sys(`insert into duels(challenger, opponent, kind, stake_kind, stake, expires_at, status, winner, resolved_at) values ($1, $2, 'sorte', 'moedas', 10, now(), 'concluido', $2, ${ago(1)})`, [A, B]);
const raid = (await sys(`insert into rocket_raids(starts_at, ends_at, level, team, players, hp_total, hp_left) values (${ago(4)}, ${ago(3)}, 10, '[]', 3, 1000, 0) returning id`))[0].id;
await sys(`insert into rocket_entries(raid_id, user_id, name, mon_name, species, level, damage) values ($1, $2, 'Caio', 'Pidgey', 16, 10, 400), ($1, $3, 'Ana', 'Rattata', 19, 10, 120)`, [raid, C, A]);
await sys(`insert into quizzes(title, question, answer, closes_at, status, winner, closed_at) values ('Quiz', 'Ano?', 1996, ${ago(5)}, 'encerrado', $1, ${ago(5)})`, [B]);
await sys(`insert into npc_fights(user_id, trainer, level, won, created_at) values ($1, 'X', 10, true, ${ago(1)}), ($1, 'Y', 10, true, ${ago(1)}), ($2, 'Z', 10, false, ${ago(1)})`, [C, A]);
await sys(`insert into guess_sessions(user_id, puzzle_date, mode, attempts, solved) values ($1, public.game_today() - 2, 'classico', 1, true), ($1, public.game_today() - 3, 'cartao', 1, true), ($2, public.game_today() - 2, 'classico', 3, true)`, [B, A]);
await sys(`insert into pokedex_entries(user_id, species_id, caught_at) values ($1, 4, ${ago(2)}), ($1, 7, ${ago(2)}), ($2, 1, ${ago(2)}) on conflict do nothing`, [A, C]);
await sys(`insert into hunts(species, level, fork_node, target_node, node_ids, ends_at, status, hunter, hunter_name, resolved_at) values (133, 20, 1, 2, '{2}', now(), 'capturado', $1, 'Caio', ${ago(1)})`, [C]);
// coisas FORA da temporada não contam
await sys(`insert into npc_fights(user_id, trainer, level, won, created_at) values ($1, 'Velho', 10, true, now() - interval '40 days')`, [A]);

console.log("\nPlacar ao vivo");
const board = (await as(B, `select public.season_board() b`)).rows[0].b;
const cat = id => board.cats.find(c => c.id === id), first = id => cat(id).top[0]?.name;
check("qualquer jogador vê o placar, com as 12 categorias", board.cats.length === 12 && board.coins === 150);
check("casas: conta só até ontem (os 99 de hoje do Caio não contam, sem spoiler)", first("casas") === "Ana" && +cat("casas").top[0].val === 35 && !cat("casas").top.some(t => t.name === "Caio"), JSON.stringify(cat("casas").top));
check("moedas ganhas andando", first("moedas") === "Beto");
check("capturas: empate aparece", cat("capturas").top.filter(t => +t.val === 2).length === 2);
check("vitórias na rodada do dia (só 1º lugar)", first("rodadas") === "Ana" && +cat("rodadas").top[0].val === 2 && cat("rodadas").top.length === 1);
check("batalhas: só contra jogadores (guerra e treinador não contam)", first("batalhas") === "Ana" && cat("batalhas").top.length === 1, JSON.stringify(cat("batalhas").top));
check("duelos vencidos", first("duelos") === "Beto");
check("dano na Rocket", first("rocket") === "Caio" && +cat("rocket").top[0].val === 400);
check("quiz", first("quiz") === "Beto");
check("treinadores vencidos (a vitória de 40 dias atrás não conta)", first("treinadores") === "Caio" && !cat("treinadores").top.some(t => t.name === "Ana"));
check("acertos de primeira", first("primeira") === "Beto" && +cat("primeira").top[0].val === 2);
check("espécies novas na Pokédex", first("pokedex") === "Ana");
check("Caçadas vencidas", first("cacadas") === "Caio");

console.log("\nFim da temporada");
const coins0 = Object.fromEntries((await sys(`select user_id, coins from characters`)).map(r => [r.user_id, r.coins]));
const lg = (await sys(`insert into leagues(season_id, name, status, champion, champion_name, legend_id, legend_level, cave_open_at) values ($1, 'Liga', 'caverna', $2, 'Ana', 144, 50, now()) returning id`, [season, A]))[0].id;
await sys(`select public.league_cave_end($1, false)`, [lg]);
const aw = await sys(`select category, user_id, value, coins from season_awards where season_id = $1`, [season]);
check("a temporada fecha e os prêmios saem sozinhos", (await sys(`select status from seasons where id = $1`, [season]))[0].status === "encerrada" && aw.length > 0);
check("no fim, conta até agora: as casas de hoje do Caio valem", aw.some(a => a.category === "casas" && a.user_id === C && +a.value === 99), JSON.stringify(aw.filter(a => a.category === "casas")));
check("empate: Ana e Beto levam o prêmio de capturas", aw.filter(a => a.category === "capturas").length === 2);
const got = u => aw.filter(a => a.user_id === u).length * 150;
const coins1 = Object.fromEntries((await sys(`select user_id, coins from characters`)).map(r => [r.user_id, r.coins]));
check("cada prêmio dá 150 moedas", [A, B, C].every(u => coins1[u] - coins0[u] === got(u)), JSON.stringify([A, B, C].map(u => [coins1[u] - coins0[u], got(u)])));
check("cada prêmio vira um presente no Correio, com a medalha", (await as(A, `select count(*)::int n from gifts where message like '🏅 Prêmio da Temporada%'`)).rows[0].n === aw.filter(a => a.user_id === A).length);
check("o Jornal anuncia os campeões", (await sys(`select count(*)::int n from event_log where kind = 'temporada' and message like '🏅 Prêmios da Temporada%'`))[0].n === 1);
check("todos veem as medalhas", (await as(B, `select count(*)::int n from season_awards`)).rows[0].n === aw.length);
check("ninguém altera as medalhas direto na tabela", !!(await as(B, `insert into season_awards(season_id, category, user_id, value) values (99, 'x', $1, 1)`, [B])).error);
check("entregar de novo não paga duas vezes", (await sys(`select public.season_awards_give($1) n`, [season]))[0].n === 0);

console.log("\nBotão de reserva do admin");
check("jogador comum não usa", /administrador/.test((await as(A, `select public.admin_season_awards()`)).error || ""));
check("se a última temporada já recebeu, o admin recebe aviso", /já foram entregues/.test((await as(ADM, `select public.admin_season_awards()`)).error || ""));
const s2 = (await sys(`insert into seasons(started_on, status, ended_on) values (public.game_today() - 2, 'encerrada', public.game_today()) returning id`))[0].id;
await sys(`insert into npc_fights(user_id, trainer, level, won, created_at) values ($1, 'W', 10, true, now() - interval '1 day')`, [B]);
const r = await as(ADM, `select public.admin_season_awards() n`);
check("temporada fechada de outro jeito: o admin entrega os prêmios", !r.error && r.rows[0].n > 0 && (await sys(`select count(*)::int n from season_awards where season_id = $1`, [s2]))[0].n > 0, r.error);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
