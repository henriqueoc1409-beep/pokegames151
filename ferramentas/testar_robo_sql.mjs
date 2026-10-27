// Testa o robô de publicação do banco (aplicar_sql.mjs) e a marcação inicial (marcar_sql_ja_rodados.sql):
// banco com os SQL só até o 45 → marca → o robô faz a cópia e roda só os novos, em ordem, sem o 14;
// rodar de novo não faz nada; SQL com erro é desfeito e o robô para; arquivo "-- MANUAL" nunca roda.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_robo_sql.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path"; import os from "os";
import { aplicar, arquivosSql } from "./aplicar_sql.mjs";
const root = path.resolve(process.argv[2] || "..");
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const pg = new PGlite({ extensions: { citext, pgcrypto } });
const db = { exec: s => pg.exec(s), query: (s, p) => pg.query(s, p) };
const quiet = () => {};
await pg.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
const todos = arquivosSql(root);
for (const f of todos.filter(f => parseInt(f) <= 45 && f !== "14_recomecar_do_zero.sql")) await pg.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));

console.log("\nAntes de marcar");
let erro = null; try { await aplicar(db, root, { log: quiet }); } catch (e) { erro = e.message; }
check("sem a tabela de controle, o robô para e não roda nada", /marcar_sql_ja_rodados/.test(erro || "") && !(await pg.query("select to_regclass('public.hunts') x")).rows[0].x);

console.log("\nMarcar os que já rodaram");
await pg.exec(fs.readFileSync(path.join(root, "ferramentas/marcar_sql_ja_rodados.sql"), "utf8"));
const marcados = (await pg.query("select arquivo from sql_aplicados order by arquivo")).rows.map(r => r.arquivo);
check("marca os já rodados (01 a 45, menos o 14)", todos.filter(f => parseInt(f) <= 45 && f !== "14_recomecar_do_zero.sql").every(f => marcados.includes(f)), JSON.stringify(todos.filter(f => parseInt(f) <= 45 && !marcados.includes(f))));
check("não marca os que ainda não rodaram (46, 47, 48)", !marcados.some(f => parseInt(f) >= 46));
check("o 14 (recomeçar do zero) não fica marcado como rodado", !marcados.includes("14_recomecar_do_zero.sql"));
check("jogadores não leem a tabela de controle", !(await pg.query("select has_table_privilege('authenticated', 'public.sql_aplicados', 'select') x")).rows[0].x);

console.log("\nSó listar");
let r = await aplicar(db, root, { soListar: true, log: quiet });
check("lista o que rodaria, sem rodar", JSON.stringify(r.faltam) === JSON.stringify(todos.filter(f => parseInt(f) >= 46)) && !(await pg.query("select to_regclass('public.hunts') x")).rows[0].x, JSON.stringify(r));

console.log("\nRodar de verdade");
for (let d = 1; d <= 9; d++) await pg.exec(`create schema copia_2020_01_0${d}; create table copia_2020_01_0${d}.x (id int);`);   // cópias antigas
const logs = []; r = await aplicar(db, root, { log: m => logs.push(m), info: { versao: "abc1234", execucao: "7", por: "dono" } });
check("roda só os novos, em ordem", JSON.stringify(r.rodados) === JSON.stringify(todos.filter(f => parseInt(f) >= 46)), JSON.stringify(r.rodados));
check("o 14 fica de fora (é MANUAL)", r.pulados.includes("14_recomecar_do_zero.sql") && !logs.some(l => /Rodando 14_/.test(l)));
const copias = (await pg.query("select schema_name s from information_schema.schemata where schema_name like 'copia_%' order by 1 desc")).rows.map(x => x.s);
check("fez a cópia de segurança antes e guarda só as 7 mais recentes", copias.length === 7 && copias[0] > "copia_2020" && !copias.includes("copia_2020_01_01"), JSON.stringify(copias));
check("as tabelas novas existem (Caçada, itens, escolha)", (await pg.query("select to_regclass('public.hunts') a, to_regclass('public.pk_items') b, to_regclass('public.hunt_entries') c")).rows.every(x => x.a && x.b && x.c));
check("anotou os novos como rodados pelo robô", (await pg.query("select count(*)::int n from sql_aplicados where origem = 'robo'")).rows[0].n === todos.filter(f => parseInt(f) >= 46).length);
const pub = (await pg.query("select * from publicacoes order by id")).rows;
check("anotou a publicação (versão, quem pediu e os SQL que rodaram)", pub.length === 1 && pub[0].versao === "abc1234" && pub[0].por === "dono" && pub[0].sql_rodados.length === r.rodados.length, JSON.stringify(pub));
r = await aplicar(db, root, { log: quiet, info: { versao: "def5678" } });
check("rodar de novo não roda SQL, mas anota a publicação", r.rodados.length === 0 && (await pg.query("select count(*)::int n from publicacoes")).rows[0].n === 2);

console.log("\nErro e arquivo manual");
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "pg-robo-"));
fs.mkdirSync(path.join(tmp, "sql")); fs.mkdirSync(path.join(tmp, "ferramentas"));
for (const f of todos) fs.copyFileSync(path.join(root, "sql", f), path.join(tmp, "sql", f));
fs.copyFileSync(path.join(root, "ferramentas/copia_de_seguranca.sql"), path.join(tmp, "ferramentas/copia_de_seguranca.sql"));
fs.writeFileSync(path.join(tmp, "sql", "49_teste_bom.sql"), "create table public.teste_robo (id int);");
fs.writeFileSync(path.join(tmp, "sql", "50_teste_ruim.sql"), "create table public.teste_meio (id int);\nselect coluna_que_nao_existe from public.teste_robo;");
fs.writeFileSync(path.join(tmp, "sql", "51_teste_depois.sql"), "create table public.teste_depois (id int);");
fs.writeFileSync(path.join(tmp, "sql", "52_teste_manual.sql"), "-- MANUAL: só o dono roda\ncreate table public.teste_manual (id int);");
erro = null; try { await aplicar(db, tmp, { log: quiet }); } catch (e) { erro = e.message; }
const t = (await pg.query("select to_regclass('public.teste_robo') a, to_regclass('public.teste_meio') b, to_regclass('public.teste_depois') c, to_regclass('public.teste_manual') d")).rows[0];
check("o arquivo bom antes do erro rodou", !!t.a);
check("o arquivo com erro foi desfeito por inteiro", !t.b && /50_teste_ruim/.test(erro || ""), erro);
check("depois do erro, o robô para (o 51 não rodou)", !t.c);
check("o arquivo com erro não fica marcado como rodado", !(await pg.query("select 1 from sql_aplicados where arquivo = '50_teste_ruim.sql'")).rows.length);
fs.writeFileSync(path.join(tmp, "sql", "50_teste_ruim.sql"), "create table public.teste_meio (id int);");
r = await aplicar(db, tmp, { log: quiet });
check("corrigido o arquivo, o robô continua de onde parou", JSON.stringify(r.rodados) === JSON.stringify(["50_teste_ruim.sql", "51_teste_depois.sql"]), JSON.stringify(r.rodados));
check("arquivo com \"-- MANUAL\" no topo nunca roda sozinho", r.pulados.includes("52_teste_manual.sql") && !(await pg.query("select to_regclass('public.teste_manual') x")).rows[0].x);
fs.rmSync(tmp, { recursive: true, force: true });
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
