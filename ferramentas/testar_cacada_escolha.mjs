// Testa o arquivo 48 (Caçada com escolha) com dados de TESTE, como jogadores comuns:
// cada um escolhe ir atrás do Pokémon ou continuar o jogo; vale para quem está atrás e quem está na frente;
// quem vai anda pelo caminho da Caçada e volta para a casa onde estava (pegando ou não); desistir; prazo.
// Uso (na pasta ferramentas, uma vez: npm i @electric-sql/pglite@0.3.15):  node testar_cacada_escolha.mjs ..
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
const [A, B, C, D, E, ADM] = [U(1), U(2), U(3), U(4), U(5), U(9)];
for (const [u, n] of [[A, "ana"], [B, "beto"], [C, "caio"], [D, "duda"], [E, "edu"], [ADM, "chefe"]]) await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]);
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
for (const [u, n] of [[A, "Ana"], [B, "Beto"], [C, "Caio"], [D, "Duda"], [E, "Edu"], [ADM, "Chefe"]]) await as(u, `select public.create_character($1, 'guerreiro')`, [n]);
await sys(`update board_nodes set hm = null`);   // sem atalhos de HM, para as contas de casas ficarem exatas
const F = (await sys(`select id, x, y, dist from board_nodes where kind = 'normal' and next_b is null and dist between 120 and 220 order by id limit 1`))[0];
const behind = (await sys(`select id from board_nodes where kind = 'normal' and next_b is null and dist > $1 + 20 order by dist limit 1`, [F.dist]))[0].id;
const ahead = (await sys(`select id from board_nodes where kind = 'normal' and next_b is null and dist < $1 - 20 and dist > 30 order by dist desc limit 1`, [F.dist]))[0].id;
const PTS = [[F.x + 40, F.y + 60], [F.x + 80, F.y + 120], [F.x + 120, F.y + 180]];
const create = days => as(ADM, `select * from public.admin_hunt_create(133, 25, $1, $2, $3)`, [F.id, JSON.stringify(PTS), days]);
const goTo = async (u, node) => { await sys(`update characters set node = $2, path = array[1, $2::int], bonus_steps = 0, pending_mud = 0, route = '{}' where user_id = $1`, [u, node]); await sys(`delete from daily_moves where user_id = $1`, [u]); };
const move = async u => { await sys(`delete from daily_moves where user_id = $1`, [u]); const x = await as(u, `select public.move_today() m`); return x.error ? { error: x.error } : x.rows[0].m; };
const node = async u => (await sys(`select node from characters where user_id = $1`, [u]))[0].node;
const plen = async u => (await sys(`select array_length(path, 1) n from characters where user_id = $1`, [u]))[0].n;
const roll = n => sys(`update game_config set config = config || jsonb_build_object('roll_min', $1::int, 'roll_max', $1::int) where active`, [n]);
const choose = (u, go) => as(u, `select * from public.hunt_choose($1)`, [go]);

console.log("\nEscolher");
check("sem Caçada aberta, não dá para escolher", /Não há Caçada/.test((await choose(A, true)).error || ""));
const h = (await create(3)).rows[0];
await goTo(A, behind); await goTo(B, ahead); await goTo(C, F.id); await goTo(D, F.id);
check("Ana (atrás do começo da Caçada) escolhe ir atrás do Pokémon", (await choose(A, true)).rows?.[0]?.go === true);
check("Beto (já passou do começo, está na frente) também pode ir", (await choose(B, true)).rows?.[0]?.go === true);
check("Caio escolhe continuar o jogo", (await choose(C, false)).rows?.[0]?.go === false);
check("cada um só vê a própria escolha", (await as(A, `select count(*)::int n from hunt_entries`)).rows[0].n === 1);
await sys(`update characters set arrived_rank = 1 where user_id = $1`, [E]);
check("quem já chegou ao Castelo não entra", /Castelo/.test((await choose(E, true)).error || ""));
await sys(`update characters set arrived_rank = null where user_id = $1`, [E]);

console.log("\nAndar");
await roll(1);
let m = await move(A);
check("Ana vai para o caminho da Caçada e anda nele", h.node_ids[0] === await node(A) && m.hunt_go === F.id && (m.events || []).some(e => /foi atrás/.test(e.msg)), JSON.stringify(m).slice(0, 300));
const oA = (await sys(`select origin_node from hunt_entries where user_id = $1`, [A]))[0].origin_node;
check("a casa onde a Ana estava fica guardada", oA === behind);
m = await move(B);
check("Beto, que estava na frente, também entra no caminho", h.node_ids[0] === await node(B), JSON.stringify(m).slice(0, 200));
await sys(`update characters set route = jsonb_build_object($2::text, 'b') where user_id = $1`, [C, F.id]);
await move(C);
check("quem escolheu o jogo segue a corrida, mesmo com o caminho b marcado", !h.node_ids.includes(await node(C)));
await sys(`update characters set route = jsonb_build_object($2::text, 'b') where user_id = $1`, [D, F.id]);
await move(D);
check("quem não escolheu também segue a corrida", !h.node_ids.includes(await node(D)));
await roll(3);
m = await move(A);
check("Ana chega primeiro no Pokémon", await node(A) === h.target_node && (await sys(`select status, hunter from hunts where id = $1`, [h.id]))[0].hunter === A);
m = await move(B);
check("Beto chega depois e volta na hora para a casa onde estava (na frente)", await node(B) === ahead && (m.events || []).some(e => /casa onde estava/.test(e.msg)), JSON.stringify(m.events));
const sync = (await as(A, `select public.pk_sync() s`)).rows[0].s;
await sys(`update pokemon set catch_rate = 255 where id = 133`);
let t;
for (let k = 0; k < 40; k++) { await sys(`update encounters set throws_left = 3 where id = $1`, [sync.encounter.id]); t = (await as(A, `select public.encounter_throw($1, 'poke') r`, [sync.encounter.id])).rows?.[0]?.r; if (t?.caught) break; }
check("Ana captura o Pokémon da Caçada", t?.caught === true && (await sys(`select status from hunts where id = $1`, [h.id]))[0].status === "capturado");
check("e volta para a casa onde estava antes (não para o começo da Caçada)", await node(A) === behind && await plen(A) === 2);
check("as casas da Caçada somem", (await sys(`select count(*)::int n from board_nodes where id = any($1) and not hidden`, [h.node_ids]))[0].n === 0);

console.log("\nDesistir e prazo");
const h2 = (await create(2)).rows[0];
await goTo(E, ahead); await choose(E, true); await roll(1); await move(E);
check("Edu entra no caminho da nova Caçada", h2.node_ids.includes(await node(E)));
let r = await choose(E, false);
check("desistir no meio: volta na hora para a casa onde estava", !r.error && await node(E) === ahead, r.error);
check("e não pode ir de novo nessa Caçada", /já foi atrás/.test((await choose(E, true)).error || ""));
await goTo(A, behind); await choose(A, true); await move(A);
await sys(`update hunts set ends_at = now() - interval '1 minute' where id = $1`, [h2.id]);
await as(C, `select public.pk_sync()`); await move(C);   // qualquer andada chama o settle, que fecha a Caçada vencida
check("acabou o prazo: o Pokémon foge e quem estava no caminho volta para a casa onde estava", (await sys(`select status from hunts where id = $1`, [h2.id]))[0].status === "fugiu" && await node(A) === behind);
check("ninguém fica preso nas casas da Caçada", (await sys(`select count(*)::int n from characters where node = any($1)`, [h2.node_ids]))[0].n === 0);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
