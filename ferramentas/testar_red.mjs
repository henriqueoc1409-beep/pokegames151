// Testa o arquivo 70 (treinadores obrigatórios ao passar e o Red) com dados de TESTE, como jogador comum.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_red.mjs ..
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
const A = "11111111-1111-1111-1111-111111111111";
await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, 'a@t.l', '{"username":"Ana"}')`, [A]); await as(A, `select public.create_character('Ana', 'mago')`);
for (const sp of [4, 7, 1]) await sys(`select public.pk_new_monster($1, $2, 5)`, [A, sp]);
await sys(`update monsters set team_slot = sub.rn from (select id, row_number() over (order by id) rn from monsters) sub where monsters.id = sub.id`);
const cid = (await sys(`select id from characters where user_id = $1`, [A]))[0].id;

console.log("\nO Red no mapa");
const red = (await sys(`select * from board_nodes where npc = 'red'`));
check("o Red está numa casa de Treinador do caminho principal, perto do Castelo", red.length === 1 && red[0].kind === "treinador" && red[0].branch === "tronco" && red[0].dist >= 4 && red[0].dist <= 12, JSON.stringify(red));
const w = (await sys(`select public.npc_fight($1, $2) w`, [cid, red[0].id]))[0].w;
const f = (await sys(`select * from npc_fights order by id desc limit 1`))[0];
check("o time do Red: Pikachu, Espeon, Snorlax, Venusaur, Charizard e Blastoise", f.trainer === "Red" && JSON.stringify(f.team.map(x => x.species)) === "[25,196,143,3,6,9]", JSON.stringify(f.team));
check("com um time fraco, perde (e o aviso fala do Red)", !f.won && /Red, o treinador lendário/.test(w.ev[0].msg), w.ev[0].msg);
check("perder para o Red não tira nada", w.coins === 0);
check("prêmio de quem vencer: 1000 moedas (Ajustes do jogo)", (await sys(`select public.casas_cfg()->>'red_premio' x`))[0].x === "1000");

console.log("\nPassar pelo Treinador");
// coloca a Ana 2 casas antes de um Treinador comum do caminho principal, com bônus de casas para passar dele
const t = (await sys(`select b.id, (select id from board_nodes a where a.next_a = b.id and a.next_b is null and a.kind = 'normal' limit 1) antes
                        from board_nodes b where b.kind = 'treinador' and coalesce(b.npc, '') <> 'red' and b.branch = 'tronco' order by b.id`)).find(r => r.antes != null);
const antes2 = (await sys(`select id from board_nodes where next_a = $1 and next_b is null limit 1`, [t.antes]))[0].id;
await sys(`update characters set node = $1, path = array[$1]::int[], bonus_steps = 8 where id = $2`, [antes2, cid]);
const n0 = (await sys(`select count(*)::int n from npc_fights`))[0].n;
const r = await as(A, `select public.move_today() m`);
const dm = (await sys(`select * from daily_moves where user_id = $1`, [A]))[0];
const pathAfter = (await sys(`select path from characters where id = $1`, [cid]))[0].path;
check("andou e passou pela casa do Treinador sem parar nela", !r.error && pathAfter.includes(t.id) && pathAfter.at(-1) !== t.id, r.error || JSON.stringify(pathAfter));
check("mesmo sem parar, teve que batalhar com ele", (await sys(`select count(*)::int n from npc_fights`))[0].n > n0 && JSON.stringify(dm.events).includes("te desafiou"), JSON.stringify(dm.events).slice(0, 300));

console.log("\nPróxima temporada");
await sys(`select public.start_new_season()`);
check("no mapa novo (492 casas) o Red também aparece", (await sys(`select count(*)::int n from board_nodes`))[0].n === 492 && (await sys(`select count(*)::int n from board_nodes where npc = 'red' and kind = 'treinador'`))[0].n === 1);
check("a novidade está no Jornal", (await sys(`select count(*)::int n from posts where title like '🔴 O Red apareceu%'`))[0].n === 1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
