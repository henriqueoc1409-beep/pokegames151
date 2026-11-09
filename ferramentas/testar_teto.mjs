// Testa o arquivo 81 (teto de nível fixo nas batalhas valendo moedas) com dados de TESTE, como jogadores comuns.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_teto.mjs ..
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
await sys(`update characters set coins = 1000 where true`);
const mon = async (u, sp, lv, slot) => { const id = (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, sp, lv]))[0].id; await sys(`update monsters set team_slot = $2 where id = $1`, [id, slot]); return id; };
const jynx = await mon(A, 124, 25, 1), a20 = await mon(A, 7, 20, 2); await mon(A, 1, 10, 3);
const gengar = await mon(B, 94, 18, 1); await mon(B, 4, 10, 2); await mon(B, 25, 10, 3);
const bt = async id => (await sys(`select public.bt_mon($1) m`, [id]))[0].m;
const stat = async (id, lv) => (await sys(`select public.pk_stat(p.base_hp, public.pk_hp_dv(m.dv_atk, m.dv_def, m.dv_spd, m.dv_spc), $2, true) hp,
  public.pk_stat(p.base_atk, m.dv_atk, $2, false) atk, public.pk_stat(p.base_def, m.dv_def, $2, false) def, public.pk_stat(p.base_spd, m.dv_spd, $2, false) spd, public.pk_stat(p.base_spc, m.dv_spc, $2, false) spc
  from monsters m join pokemon p on p.id = m.species_id where m.id = $1`, [id, lv]))[0];
const antes = await bt(jynx);

console.log("\nTeto fixo");
check("o teto é 20", (await as(A, `select public.teto_estado() t`)).rows[0].t.nivel === 20);
const cfg = (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c.teto;
check("nos Ajustes só aparecem liga/desliga e o nível", cfg.nivel === 20 && cfg.on === true && !("por_temporada" in cfg) && !("temporada_ref" in cfg), JSON.stringify(cfg));

console.log("\nBatalha valendo moedas: nível 25 contra nível 18");
let r = await as(A, `select (public.battle_challenge($1, 10)).id id`, [B]);
const bid = r.rows?.[0]?.id;
r = await as(B, `select (public.battle_respond($1, true)).state s`, [bid]);
const s = r.rows?.[0]?.s, j = s?.sides?.[0]?.mons?.[0], j20 = s?.sides?.[0]?.mons?.[1], g = s?.sides?.[1]?.mons?.[0];
const st20 = await stat(jynx, 20);
check("a Jynx 25 aparece como nível 20, com o nível real guardado", j?.level === 20 && j.real_level === 25, r.error || JSON.stringify([j?.level, j?.real_level]));
check("com TODOS os atributos do nível 20 (mesma fórmula, não por porcentagem)", j.maxhp === st20.hp && j.hp === st20.hp && j.atk === st20.atk && j.def === st20.def && j.spd === st20.spd && j.spc === st20.spc, JSON.stringify([j, st20]));
check("e menores que os do nível 25", j.maxhp < antes.maxhp && j.atk <= antes.atk);
check("ataques e espécie continuam os mesmos", JSON.stringify(j.moves) === JSON.stringify(antes.moves) && j.species === 124);
const g0 = await bt(gengar);
check("o Gengar 18 não muda (nível e atributos reais)", g?.level === 18 && !g.real_level && g.maxhp === g0.maxhp && g.atk === g0.atk);
const p20 = await bt(a20);
check("um Pokémon exatamente no nível 20 não muda", j20?.level === 20 && !j20.real_level && j20.maxhp === p20.maxhp && j20.atk === p20.atk);

console.log("\nDepois da batalha");
r = await as(A, `select public.battle_act($1, 1, 'forfeit', 0, null)`, [bid]);
check("a batalha termina", (await sys(`select status from battles where id = $1`, [bid]))[0].status === "encerrada", r.error);
const depois = await bt(jynx), row = (await sys(`select level from monsters where id = $1`, [jynx]))[0];
check("a Jynx continua salva no nível 25, com os atributos originais", row.level === 25 && depois.maxhp === antes.maxhp && depois.atk === antes.atk && depois.spd === antes.spd);

console.log("\nTemporada nova e Liga");
await sys(`update seasons set status = 'encerrada' where status = 'ativa'`); await sys(`insert into seasons(started_on) values (current_date)`);
check("na temporada seguinte o teto continua 20 (não sobe mais)", (await as(A, `select public.teto_estado() t`)).rows[0].t.nivel === 20);
const lg = (await sys(`select public.league_side($1) s`, [A]))[0].s.mons[0];
check("na Liga não há teto: a Jynx luta no 25", lg.level === 25 && !lg.real_level && lg.maxhp === antes.maxhp);

console.log("\nAdmin");
r = await as(ADM, `select public.admin_set_config($1::jsonb, 'teste')`, [JSON.stringify({ teto: { on: true, nivel: 30 } })]);
check("o admin muda o teto para 30 nos Ajustes", !r.error && (await as(A, `select public.teto_estado() t`)).rows[0].t.nivel === 30, r.error);
check("o aviso sai no Jornal", (await sys(`select count(*)::int n from posts where title = '📏 Batalhas sempre niveladas no 20'`))[0].n === 1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
