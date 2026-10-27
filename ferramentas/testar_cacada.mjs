// Testa o arquivo 46 (Caçada) com dados de TESTE, como jogadores comuns:
// admin cria o caminho, bifurcação temporária, o primeiro a chegar tenta capturar com as bolas de sempre,
// volta para a casa de origem, as casas somem, quem estava no caminho volta, prazo faz o Pokémon fugir.
// Roda só até o arquivo 47: o 48 trocou a entrada pela bifurcação pela escolha de cada jogador (testar_cacada_escolha.mjs).
// Uso (na pasta ferramentas, uma vez: npm i @electric-sql/pglite@0.3.15):  node testar_cacada.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql" && f < "48").sort()) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
const U = n => `${n}${n}${n}${n}${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${String(n).repeat(12)}`;
const [A, B, C, ADM] = [U(1), U(2), U(3), U(9)];
for (const [u, n] of [[A, "ana"], [B, "beto"], [C, "caio"], [ADM, "chefe"]]) await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]);
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
for (const [u, n] of [[A, "Ana"], [B, "Beto"], [C, "Caio"], [ADM, "Chefe"]]) await as(u, `select public.create_character($1, 'guerreiro')`, [n]);
const F = (await sys(`select id, x, y from board_nodes where kind = 'normal' and next_b is null and dist between 50 and 300 order by id limit 1`))[0];
const PTS = [[F.x + 40, F.y + 60], [F.x + 80, F.y + 120], [F.x + 120, F.y + 180]];
const create = (who, sp, lv, fork, pts, days) => as(who, `select * from public.admin_hunt_create($1, $2, $3, $4, $5)`, [sp, lv, fork, JSON.stringify(pts), days]);
console.log("\nCriar");
check("jogador comum não cria", /administrador/.test((await create(A, 133, 20, F.id, PTS, 3)).error || ""));
check("lendário não entra", /Lendários/.test((await create(ADM, 150, 70, F.id, PTS, 3)).error || ""));
check("castelo não pode ser o começo", /não pode virar/.test((await create(ADM, 133, 20, (await sys(`select id from board_nodes where kind = 'castelo'`))[0].id, PTS, 3)).error || ""));
const h = (await create(ADM, 133, 25, F.id, PTS, 3)).rows?.[0];
check("admin cria a Caçada com o Eevee nível 25", h?.status === "ativa" && h.node_ids.length === 3);
const nodes = await sys(`select * from board_nodes where id = any($1) order by id`, [h.node_ids]);
check("casas novas: 2 de caminho e o fim (alvo), encadeadas", nodes[0].kind === "cacada" && nodes[2].kind === "alvo" && nodes[0].next_a === nodes[1].id && nodes[2].next_a === null);
check("a casa de começo virou bifurcação temporária", (await sys(`select next_b from board_nodes where id = $1`, [F.id]))[0].next_b === nodes[0].id);
check("as casas novas não adiantam a corrida (mesma distância do começo)", nodes.every(n => n.dist === (nodes[0].dist)));
check("só uma Caçada por vez", /Já existe/.test((await create(ADM, 25, 10, F.id, PTS, 3)).error || ""));
check("todo mundo vê a Caçada", (await as(B, `select count(*)::int n from hunts`)).rows[0].n === 1);
console.log("\nEntrar e chegar");
await sys(`update game_config set config = config || '{"roll_min": 3, "roll_max": 3}' where active`);
const goTo = async (u, node) => { await sys(`update characters set node = $2, path = array[$2::int], bonus_steps = 0, pending_mud = 0 where user_id = $1`, [u, node]); await sys(`delete from daily_moves where user_id = $1`, [u]); };
const move = async u => { await sys(`delete from daily_moves where user_id = $1`, [u]); const r = await as(u, `select public.move_today() m`); return r.error ? { error: r.error } : r.rows[0].m; };
const node = async u => (await sys(`select node from characters where user_id = $1`, [u]))[0].node;
check("o jogador escolhe entrar (caminho b)", !(await as(A, `select public.set_route($1, 'b')`, [F.id])).error);
await goTo(A, F.id);
let m = await move(A);
check("anda 3 e para no fim, onde está o Pokémon", (await node(A)) === h.target_node, JSON.stringify(m).slice(0, 200));
check("o aviso diz que chegou primeiro", (m.events || []).some(e => e.t === "cacada" && /chegou primeiro/.test(e.msg)));
check("a Caçada fica 'tentando' com a Ana", (await sys(`select status, hunter from hunts`))[0].status === "tentando");
const sync = (await as(A, `select public.pk_sync() s`)).rows[0].s;
check("o encontro é com o Pokémon da Caçada (Eevee 25)", sync.encounter?.species_id === 133 && sync.encounter.level === 25 && sync.encounter.hunt_id === h.id, JSON.stringify(sync.encounter));
console.log("\nOutro jogador no caminho");
await as(B, `select public.set_route($1, 'b')`, [F.id]);
await goTo(B, F.id); await sys(`update game_config set config = config || '{"roll_min": 1, "roll_max": 1}' where active`);
await move(B);
check("Beto está no meio do caminho da Caçada", h.node_ids.includes(await node(B)));
console.log("\nCaptura");
await sys(`update pokemon set catch_rate = 255 where id = 133`);
// a Poké Bola pega uns 33% das vezes mesmo com a taxa no máximo: joga de novo (devolvendo as chances) até pegar
let t;
for (let k = 0; k < 40; k++) {
  await sys(`update encounters set throws_left = 3 where id = $1`, [sync.encounter.id]);
  t = (await as(A, `select public.encounter_throw($1, 'poke') r`, [sync.encounter.id])).rows?.[0]?.r;
  if (t?.caught) break;
}
check("joga a Poké Bola e captura (taxa no máximo, para o teste)", t?.caught === true, JSON.stringify(t));
check("a Ana ganhou o Eevee", (await sys(`select count(*)::int n from monsters where user_id = $1 and species_id = 133 and level = 25`, [A]))[0].n === 1);
const hf = (await sys(`select * from hunts where id = $1`, [h.id]))[0];
check("a Caçada terminou como capturado", hf.status === "capturado");
check("a Ana voltou para a casa de origem", (await node(A)) === F.id);
check("o Beto, que estava no caminho, também voltou", (await node(B)) === F.id);
check("as casas sumiram e a bifurcação acabou", (await sys(`select count(*)::int n from board_nodes where id = any($1) and not hidden`, [h.node_ids]))[0].n === 0 && (await sys(`select next_b from board_nodes where id = $1`, [F.id]))[0].next_b === null);
check("a escolha de caminho foi limpa", !((await sys(`select route from characters where user_id = $1`, [B]))[0].route || {})[F.id]);
check("o Jornal conta quem capturou", (await sys(`select count(*)::int n from event_log where kind = 'cacada' and message like '%CAPTUROU%'`))[0].n === 1);
m = await move(A);
check("depois disso, a Ana segue pelo caminho normal", !m.error && (await node(A)) !== h.node_ids[0], m.error);
console.log("\nEscapou e prazo");
await sys(`update pokemon set catch_rate = 45 where id = 133`);
const h2 = (await create(ADM, 7, 12, F.id, PTS, 2)).rows[0];
await sys(`update game_config set config = config || '{"roll_min": 3, "roll_max": 3}' where active`);
await as(C, `select public.set_route($1, 'b')`, [F.id]); await goTo(C, F.id); await move(C);
const s2 = (await as(C, `select public.pk_sync() s`)).rows[0].s;
await as(C, `select public.encounter_skip($1)`, [s2.encounter.id]);
check("recusar/fugir: o Pokémon escapa, a pessoa volta e as casas somem", (await sys(`select status from hunts where id = $1`, [h2.id]))[0].status === "escapou" && (await node(C)) === F.id);
const h3 = (await create(ADM, 7, 12, F.id, PTS, 1)).rows[0];
await sys(`update hunts set ends_at = now() - interval '1 minute' where id = $1`, [h3.id]);
await as(B, `select public.pk_sync()`);   // qualquer ação chama o settle
await move(B);
check("passou do prazo sem ninguém chegar: o Pokémon foge", (await sys(`select status from hunts where id = $1`, [h3.id]))[0].status === "fugiu");
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
