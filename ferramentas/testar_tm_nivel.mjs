// Testa o arquivo 83 (TMs com nível mínimo, ataque bloqueado até o nível e nível de evolução escondido) com dados de TESTE, como jogadores comuns.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_tm_nivel.mjs ..
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
const A = "11111111-1111-1111-1111-111111111111", ADM = "99999999-9999-9999-9999-999999999999";
for (const [u, n] of [[A, "Ana"], [ADM, "Chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'mago')`, [n]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
const newMon = async (sp, lv) => (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [A, sp, lv]))[0].id;
// uma TM forte que o Charmander (4) aprende só por TM
const forte = (await sys(`select t.item, t.move_id, mv.power from pk_tm_list t join pk_moves mv on mv.id = t.move_id join pk_tm_compat c on c.move_id = t.move_id and c.species_id = 4
  where not t.hm and mv.power > 90 and not public.mon_move_natural(4, t.move_id) order by t.num limit 1`))[0];
const hm = (await sys(`select move_id from pk_tm_list where hm order by num limit 1`))[0].move_id;
const natTm = (await sys(`select t.move_id from pk_tm_list t where not t.hm and public.mon_move_natural(4, t.move_id) limit 1`))[0]?.move_id;
const btMoves = async id => (await sys(`select public.bt_mon($1) m`, [id]))[0].m.moves.map(x => x.id);

console.log("\nNível mínimo das TMs");
check("forte (acima de 90) = nível 40", +(await sys(`select public.tm_nivel_move($1) n`, [forte.move_id]))[0].n === 40, JSON.stringify(forte));
const media = (await sys(`select id from pk_moves where power between 61 and 90 limit 1`))[0].id, fraca = (await sys(`select id from pk_moves where coalesce(power, 0) = 0 limit 1`))[0].id;
check("média (até 90) = 25; sem dano = 10", +(await sys(`select public.tm_nivel_move($1) n`, [media]))[0].n === 25 && +(await sys(`select public.tm_nivel_move($1) n`, [fraca]))[0].n === 10);
const ch = await newMon(4, 30);
await sys(`insert into bag_items(user_id, item, qty) values ($1, $2, 2)`, [A, forte.item]);
let r = await as(A, `select public.mon_teach($1, $2, 1)`, [ch, forte.item]);
check("Charmander nível 30 não aprende a TM forte (pede nível 40)", /a partir do nível 40/.test(r.error || ""), r.error);
check("e a TM não é gasta", (await sys(`select qty from bag_items where user_id = $1 and item = $2`, [A, forte.item]))[0].qty === 2);
await sys(`update monsters set level = 40 where id = $1`, [ch]);
r = await as(A, `select public.mon_teach($1, $2, 1)`, [ch, forte.item]);
check("no nível 40 aprende", !r.error && (await sys(`select moves from monsters where id = $1`, [ch]))[0].moves.includes(forte.move_id), r.error);

console.log("\nQuem já ensinou: ataque bloqueado até o nível");
await sys(`update monsters set level = 30 where id = $1`, [ch]);
check("o ataque continua na ficha", (await sys(`select moves from monsters where id = $1`, [ch]))[0].moves.includes(forte.move_id));
check("mas na batalha ele não aparece (nível 30)", !(await btMoves(ch)).includes(forte.move_id), JSON.stringify(await btMoves(ch)));
const ex = (await as(A, `select public.pk_meus_extras() x`)).rows[0].x;
check("o site sabe que está bloqueado até o nível 40", ex.travas?.[ch]?.[forte.move_id] === 40, JSON.stringify(ex.travas));
await sys(`update monsters set level = 40 where id = $1`, [ch]);
check("no nível 40 libera sozinho", (await btMoves(ch)).includes(forte.move_id));
check("ataque que a espécie aprende sozinha nunca é bloqueado", natTm == null || +(await sys(`select public.mon_move_req(4, $1) n`, [natTm]))[0].n === 0);
check("HM continua livre", +(await sys(`select public.mon_move_req(4, $1) n`, [hm]))[0].n === 0);
const so = await newMon(4, 12); await sys(`update monsters set moves = $2 where id = $1`, [so, [forte.move_id]]);
check("se só tiver ataques bloqueados, luta com os ataques naturais do nível", (await btMoves(so)).length > 0 && !(await btMoves(so)).includes(forte.move_id));

console.log("\nCom o teto das batalhas valendo moedas");
const big = await newMon(6, 45); await sys(`update monsters set moves = array_append(moves[1:3], $2) where id = $1`, [big, forte.move_id]);
const capped = (await sys(`select public.bt_mon_teto($1, 20) m`, [big]))[0].m.moves.map(x => x.id);
check("nível 45 lutando como 20: o ataque de nível 40 fica de fora", !capped.includes(forte.move_id), JSON.stringify(capped));
check("sem teto (Liga), ele usa", (await btMoves(big)).includes(forte.move_id));

console.log("\nNível de evolução escondido");
r = await as(A, `select * from pk_evolutions limit 1`);
check("jogador não lê mais a tabela de evoluções", !!r.error || r.rows.length === 0, JSON.stringify(r.rows));
const evs = (await as(A, `select public.pk_evolucoes() e`)).rows[0].e;
check("o site recebe as evoluções sem o nível", evs.length > 50 && evs.every(e => !("level" in e)) && evs.some(e => e.from_id === 4 && e.to_id === 5));
const c15 = await newMon(4, 15), c16 = await newMon(4, 16);
const ev = (await as(A, `select public.pk_meus_extras() x`)).rows[0].x.evo.map(([m, t]) => `${m}:${t}`);
check("só avisa quem já pode evoluir (16 sim, 15 não)", ev.includes(`${c16}:5`) && !ev.includes(`${c15}:5`), JSON.stringify(ev));
r = await as(A, `select public.mon_evolve($1, 5)`, [c15]);
check("tentar evoluir antes não conta o nível", !!r.error && !/\d/.test(r.error), r.error);
check("no nível certo evolui", !(await as(A, `select public.mon_evolve($1, 5)`, [c16])).error);

console.log("\nAdmin");
const cfg = (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c.tm_nivel;
check("os níveis das TMs ficam nos Ajustes do jogo", cfg?.forte_nivel === 40 && cfg?.media_nivel === 25 && cfg?.fraca_nivel === 10);
check("o aviso sai no Jornal", (await sys(`select count(*)::int n from posts where title = '📀 TMs agora têm nível mínimo'`))[0].n === 1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
