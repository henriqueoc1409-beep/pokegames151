// Testa o arquivo 59 (controles do admin) com dados de TESTE: tempo extra na Grama de Treino para um jogador,
// os números de todos os sistemas para a aba "Ajustes do jogo" e salvar um ajuste. Jogador comum não consegue nada disso.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_admin_controles.mjs ..
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
await sys(`select (public.pk_new_monster($1, 66, 14)).id`, [A]);
const st = async () => (await as(A, `select public.treino_estado() s`)).rows[0].s;

console.log("\nTempo extra na Grama de Treino");
check("jogador comum não dá tempo extra", /administrador|admin/i.test((await as(A, `select public.admin_treino_bonus($1, 30)`, [A])).error || ""));
for (const m of [10, 10, 10]) { await as(A, `select public.treino_entrar($1)`, [m]); await as(A, `select public.treino_sair()`); }
check("a Ana usou os 30 minutos do dia e não entra mais", /acabou/.test((await as(A, `select public.treino_entrar(5)`)).error || ""));
let r = await as(ADM, `select public.admin_treino_bonus($1, 15, 'presente de aniversário') x`, [A]);
check("o admin dá 15 minutos a mais para ela hoje", !r.error && r.rows[0].x.bonus === 15 && r.rows[0].x.livre === 15, r.error || JSON.stringify(r.rows));
let s = await st();
check("o relógio dela mostra o tempo extra", s.bonus === 15 && s.minutos === 30, JSON.stringify([s.bonus, s.minutos]));
r = await as(A, `select public.treino_entrar(10) s`);
check("ela entra de novo por 10 minutos", !r.error && r.rows[0].s.visita?.minutos === 10, r.error);
await as(A, `select public.treino_sair()`);
r = await as(A, `select public.treino_entrar(10) s`);
check("e depois só pelos 5 que sobraram", !r.error && r.rows[0].s.visita?.minutos === 5, r.error);
await as(A, `select public.treino_sair()`);
check("o presente vai para a Auditoria com o motivo", (await sys(`select count(*)::int n from admin_audit_log where action = 'treino_bonus' and target = $1 and reason = 'presente de aniversário'`, [A]))[0].n === 1);
check("minutos fora do limite são recusados", /Minutos/.test((await as(ADM, `select public.admin_treino_bonus($1, 0)`, [A])).error || ""));

console.log("\nAjustes do jogo");
check("jogador comum não vê os ajustes", /administrador|admin/i.test((await as(A, `select public.admin_cfg_efetiva()`)).error || ""));
const c = (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c;
check("o admin vê os números de todos os sistemas, já com os padrões", c.treino.minutos_dia === 30 && c.pk.encounter && c.casas && c.itens.per_battle === 2 && c.war && c.rocket.reward === 100 && c.base, JSON.stringify(Object.keys(c)));
r = await as(ADM, `select public.admin_set_config($1::jsonb, 'teste') x`, [JSON.stringify({ treino: { ...c.treino, minutos_dia: 45 } })]);
check("salvar um ajuste muda o jogo na hora (Grama com 45 minutos)", !r.error && (await sys(`select public.treino_cfg()->>'minutos_dia' x`))[0].x === "45", r.error);
check("e o resto da Grama continua igual", (await sys(`select public.treino_cfg()->>'lendario_pct' x`))[0].x === "1");
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
