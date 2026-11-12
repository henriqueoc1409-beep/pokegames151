// Testa o arquivo 79 (benefícios do Quartel) com dados de TESTE, como jogadores comuns:
// escudo e soldo ao construir, soldo na coleta, batalhas extras com XP, treino dos soldados, proteção no saque.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_quartel.mjs ..
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
const A = "11111111-1111-1111-1111-111111111111";
await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, 'a@t.l', '{"username":"Ana"}')`, [A]); await as(A, `select public.create_character('Ana', 'mago')`);
await sys(`update characters set coins = 10000 where true`);
await as(A, `select public.village_state()`);
await sys(`update villages set center_level = 1 where user_id = $1`, [A]);
const vil = async () => (await sys(`select * from villages where user_id = $1`, [A]))[0];
const coins = async () => (await sys(`select coins from characters where user_id = $1`, [A]))[0].coins;

console.log("\nConstruir");
check("sem Quartel, nenhuma batalha extra", (await sys(`select public.quartel_batalhas_extra($1) n`, [A]))[0].n === 0);
let r = await as(A, `select public.village_upgrade('quartel')`);
let v = await vil();
check("constrói o Quartel", !r.error && v.barracks_level === 1, r.error);
check("Quartel novo vem com 72 h de escudo", Math.abs(new Date(v.shield_until) - Date.now() - 72 * 36e5) < 6e4, v.shield_until);
check("o soldo começa a contar hoje", v.barracks_collected_at !== null);

console.log("\nSoldo");
await sys(`update villages set barracks_collected_at = public.game_today() - 3 where user_id = $1`, [A]);
const pend = (await as(A, `select public.village_state() s`)).rows[0].s.pending;
check("3 dias de soldo = 60 moedas na produção", pend.coins === 60, JSON.stringify(pend));
let c0 = await coins(); r = await as(A, `select public.village_collect()`);
check("coletar paga o soldo", !r.error && (await coins()) - c0 === 60, r.error);
check("e zera a contagem", (await as(A, `select public.village_state() s`)).rows[0].s.pending.coins === 0);

console.log("\nBatalhas e treino");
check("Quartel 1 = +1 batalha com XP por dia", (await sys(`select public.quartel_batalhas_extra($1) n`, [A]))[0].n === 1);
const m = (await sys(`select (public.pk_new_monster($1, 4, 10)).id id`, [A]))[0].id;
await sys(`insert into war_squads(user_id, role, slot, monster_id) values ($1, 'ataque', 1, $2)`, [A, m]);
const xp0 = (await sys(`select exp from monsters where id = $1`, [m]))[0].exp;
await as(A, `select public.pk_sync()`);
const xp1 = (await sys(`select exp from monsters where id = $1`, [m]))[0].exp;
check("o soldado ganhou 50 XP no treino do dia", xp1 - xp0 === 50, xp1 - xp0);
await as(A, `select public.pk_sync()`);
check("só uma vez por dia", (await sys(`select exp from monsters where id = $1`, [m]))[0].exp === xp1);
await sys(`update villages set barracks_trained_on = null, damaged = jsonb_build_object('quartel', jsonb_build_object('at', now())) where user_id = $1`, [A]);
await as(A, `select public.pk_sync()`);
check("Quartel danificado não treina", (await sys(`select exp from monsters where id = $1`, [m]))[0].exp === xp1);
check("nem dá batalhas extras", (await sys(`select public.quartel_batalhas_extra($1) n`, [A]))[0].n === 0);

console.log("\nSaque e Ajustes");
check("o Quartel protege moedas no saque (100/200/300) e os números ficam nos Ajustes", JSON.stringify((await sys(`select public.war_cfg()->'buildings'->'quartel'->'protect' p`))[0].p) === "[100,200,300]"
  && /quartel', 'protect'/.test((await sys(`select pg_get_functiondef('public.war_attack(uuid)'::regprocedure) d`))[0].d));
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
