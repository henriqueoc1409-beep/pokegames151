// Testa o arquivo 102 (batalha entre jogadores na Aventura) com dados de TESTE, como jogadores comuns: o desafio cria a
// batalha já ativa (obrigatória), sem moedas e com o teto de nível, o outro joga na vez dele; o mesmo par 1 vez por dia;
// limites de desafiar e de ser desafiado; sem equipe não dá; admin desliga; Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_rpg_pvp.mjs ..
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
const U = i => `${i}${i}${i}${i}${i}${i}${i}${i}-${i}${i}${i}${i}-${i}${i}${i}${i}-${i}${i}${i}${i}-${String(i).repeat(12)}`;
const nomes = ["Ana", "Beto", "Caio", "Duda", "Eva", "Fabi", "Gil"], J = nomes.map((_, i) => U(i + 1)), ADM = U(9);
for (const [k, n] of nomes.entries()) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [J[k], n + "@t.l", JSON.stringify({ username: n })]); await as(J[k], `select public.create_character($1, 'mago')`, [n]); }
await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, 'c@t.l', '{"username":"chefe"}')`, [ADM]); await as(ADM, `select public.create_character('Chefe', 'mago')`);
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
await sys(`update monsters set team_slot = null where true`);
for (const u of J.slice(0, 6)) for (let s = 1; s <= 3; s++) { const id = (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, [25, 4, 7][s - 1], s === 1 ? 35 : 10]))[0].id; await sys(`update monsters set team_slot = $2 where id = $1`, [id, s]); }
await sys(`update characters set coins = 500 where true`);
const [A, B, C, D, E, F, G] = J;
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;

console.log("\nDesafio obrigatório");
let r = await as(A, `select * from public.rpg_desafiar($1, 'bosque')`, [B]);
const b = r.rows?.[0];
check("o desafio cria a batalha já ativa (sem convite para aceitar)", b && b.status === "ativa" && b.p1 === A && b.p2 === B && b.turn === 1, r.error || JSON.stringify(b?.status));
check("sem moedas: ninguém pagou nada", b.bet === 0 && await coins(A) === 500 && await coins(B) === 500);
check("3 Pokémon de cada lado e o teto de nível (35 luta como 20)", b.state.sides[0].mons.length === 3 && b.state.sides[0].mons[0].level === 20 && b.state.rpg_pvp === true, JSON.stringify(b.state.sides[0].mons.map(m => m.level)));
check("o desafiado vê a batalha e joga na vez dele", !(await as(B, `select public.battle_act($1, 1, 'move', 0)`, [b.id])).error);
check("o Jornal do dia conta o encontro", (await sys(`select count(*)::int n from event_log where message like '%encontrou Beto na Aventura%'`))[0].n === 1);

console.log("\nLimites");
check("não dá para desafiar você mesmo", !!(await as(A, `select public.rpg_desafiar($1)`, [A])).error);
check("com batalha aberta entre os dois, não abre outra", /aberta entre vocês/.test((await as(B, `select public.rpg_desafiar($1)`, [A])).error || ""));
await sys(`update battles set status = 'encerrada' where id = $1`, [b.id]);
check("o mesmo par só uma vez por dia", /já batalharam hoje/.test((await as(B, `select public.rpg_desafiar($1)`, [A])).error || ""));
check("quem não tem equipe não pode ser desafiado", /não tem equipe/.test((await as(A, `select public.rpg_desafiar($1)`, [G])).error || ""));
for (const o of [C, D, E]) { const x = await as(o, `select public.rpg_desafiar($1)`, [F]); if (x.error) console.log("   ", x.error); await sys(`update battles set status = 'encerrada' where status = 'ativa'`); }
check("cada um é desafiado no máximo 3 vezes por dia", /3 vezes hoje/.test((await as(A, `select public.rpg_desafiar($1)`, [F])).error || ""));
for (const o of [C, D, E]) { await as(A, `select public.rpg_desafiar($1)`, [o]); await sys(`update battles set status = 'encerrada' where status = 'ativa'`); }
const x5 = await as(A, `select public.rpg_desafiar($1)`, [ADM]);
check("cada um desafia no máximo 5 por dia", /5 jogadores/.test(x5.error || "") || /não tem equipe/.test(x5.error || ""), x5.error);
await sys(`update game_config set config = jsonb_set(config, '{rpg,pvp,on}', 'false') where active`);
check("o admin desliga e ninguém desafia", /desligadas/.test((await as(C, `select public.rpg_desafiar($1)`, [D])).error || ""));
const aj = (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c;
check("aparece em Ajustes do jogo", aj.rpg?.pvp?.distancia === 2);
check("aviso publicado no Jornal uma vez", (await sys(`select count(*)::int n from posts where title = '⚔️ Aventura: encontrou, pode desafiar!'`))[0].n === 1);
console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
