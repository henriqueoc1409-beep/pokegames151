// Testa o arquivo 78 (recomeçar a rodada de hoje) com dados de TESTE, como jogadores comuns.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_rodada_nova.mjs ..
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
for (const [u, n] of [[A, "Ana"], [B, "Bia"], [ADM, "Chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'mago')`, [n]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
await sys(`update characters set hints = 3, retries = 3 where true`);
await as(A, `select public.today_overview()`);
const puz = async () => Object.fromEntries((await sys(`select mode::text m, pokemon_id p from daily_puzzles where puzzle_date = public.game_today()`)).map(r => [r.m, r.p]));
const antes = await puz();
const certo = antes.classico, errado = certo === 1 ? 2 : 1;
await as(A, `select public.make_guess('classico', $1)`, [errado]);
let r = await as(A, `select public.use_hint('classico')`);
await as(A, `select public.make_guess('classico', $1)`, [certo]);
const hA = (await sys(`select hints from characters where user_id = $1`, [A]))[0].hints;
check("Ana jogou o Clássico e usou 1 dica", (await sys(`select count(*)::int n from guesses where user_id = $1`, [A]))[0].n >= 2 && hA === 2, r.error);

console.log("\nPermissões");
check("jogador comum não recomeça a rodada", /admin|permiss/i.test((await as(B, `select public.admin_rodada_nova('x')`)).error || ""));

console.log("\nRecomeçar");
r = await as(ADM, `select public.admin_rodada_nova('teste') r`);
check("o admin recomeça: 1 jogador tinha jogado, 1 dica devolvida", !r.error && r.rows[0].r.jogadores === 1 && r.rows[0].r.dicas === 1, r.error || JSON.stringify(r.rows?.[0]));
check("os palpites de hoje sumiram", (await sys(`select count(*)::int n from guesses where puzzle_date = public.game_today()`))[0].n === 0 && (await sys(`select count(*)::int n from guess_sessions where puzzle_date = public.game_today()`))[0].n === 0);
check("a dica voltou para a Ana", (await sys(`select hints from characters where user_id = $1`, [A]))[0].hints === 3);
const depois = await puz();
check("os Pokémon do dia mudaram em todos os modos", Object.keys(antes).length > 0 && Object.keys(antes).every(m => depois[m] && depois[m] !== antes[m]), JSON.stringify({ antes, depois }));
check("a Ana joga de novo, do zero", !(await as(A, `select public.make_guess('classico', $1)`, [depois.classico])).error && (await sys(`select solved from guess_sessions where user_id = $1 and mode = 'classico'`, [A]))[0].solved === true);
check("aviso no Jornal e na Auditoria", (await sys(`select count(*)::int n from posts where title = '🔄 Rodada de hoje recomeçada'`))[0].n === 1 && (await sys(`select count(*)::int n from admin_audit_log where action = 'rodada_nova'`))[0].n === 1);

console.log("\nQuem já andou");
await sys(`insert into daily_moves(user_id, move_date, modes, base_steps, roll, bonus_steps, from_node, to_node, xp_gained, coins_gained) values ($1, public.game_today(), '{}', 0, 1, 0, 0, 1, 0, 0)`, [B]);
check("se alguém já andou hoje, recusa e diz quem", /Já andaram hoje: Bia/.test((await as(ADM, `select public.admin_rodada_nova('x')`)).error || ""));
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
