// Testa o arquivo 49 (painel de uso do admin): só o admin vê; tamanho do banco, tabelas maiores,
// cópias de segurança, publicações do mês e o último SQL; jogador comum não lê a tabela de publicações.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_uso.mjs ..
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
const ANA = "11111111-1111-1111-1111-111111111111", ADM = "99999999-9999-9999-9999-999999999999";
for (const [id, n] of [[ANA, "ana"], [ADM, "chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1,$2,$3)`, [id, n + "@t.l", JSON.stringify({ username: n })]); await as(id, `select public.create_character($1,'mago')`, [n]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
await sys(`insert into publicacoes(versao, por, sql_rodados) values ('aaa1111', 'dono', '{49_painel_uso.sql}'), ('bbb2222', 'dono', '{}')`);
await sys(`insert into publicacoes(quando, versao) values (now() - interval '62 days', 'velha')`);
await db.exec(`create schema copia_2026_10_27; create table copia_2026_10_27.characters as select * from public.characters;`);

let r = await as(ANA, `select public.admin_usage() u`);
check("jogador comum não vê o uso", /administrador/.test(r.error || ""), r.error);
check("jogador comum não lê a tabela de publicações", !!(await as(ANA, `select * from publicacoes`)).error);
r = await as(ADM, `select public.admin_usage() u`); const u = r.rows?.[0]?.u;
check("o admin vê o uso", !r.error && u, r.error);
check("tamanho do banco e limite de 500 MB", u.db_bytes > 0 && u.db_limit_bytes === 500 * 1024 * 1024);
check("lista as tabelas maiores, da maior para a menor", u.tables.length > 5 && u.tables[0].bytes >= u.tables[1].bytes);
check("mostra as cópias de segurança e quanto ocupam", u.backups.length === 1 && u.backups[0].name === "copia_2026_10_27" && u.backups[0].bytes > 0, JSON.stringify(u.backups));
check("conta jogadores", u.players === 2);
check("publicações do mês (a de 2 meses atrás não conta)", u.pubs_month === 2 && u.pubs.length === 3, JSON.stringify(u.pubs_month));
check("sem a tabela de controle do robô, o último SQL fica vazio (sem erro)", u.sql_last === null);
await db.exec(`create table public.sql_aplicados (arquivo text primary key, aplicado_em timestamptz not null default now(), origem text not null default 'robo'); insert into public.sql_aplicados(arquivo) values ('49_painel_uso.sql')`);
check("com a tabela de controle, mostra o último SQL que rodou", (await as(ADM, `select public.admin_usage() u`)).rows[0].u.sql_last === "49_painel_uso.sql");
await sys(`update game_config set config = config || '{"uso_limite_mb": 8000}' where active`);
check("o limite pode ser ajustado (se um dia mudar de plano)", (await as(ADM, `select public.admin_usage() u`)).rows[0].u.db_limit_bytes === 8000 * 1024 * 1024);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
