// Testa o arquivo 22 (avisos do admin e enquetes) com dados de TESTE.
// (Roda os arquivos só até o 40: desde o 41, aviso não é mais apagado e imagem não vence; isso é testado em testar_jornal_permanente.mjs.)
// Uso (na pasta ferramentas, uma vez: npm i @electric-sql/pglite@0.3.15):  node testar_avisos.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql")).sort()) if (f !== "14_recomecar_do_zero.sql" && f < "41") await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
const ADM = "99999999-9999-9999-9999-999999999999", ANA = "11111111-1111-1111-1111-111111111111", BETO = "22222222-2222-2222-2222-222222222222";
for (const [id, n] of [[ADM, "chefe"], [ANA, "ana"], [BETO, "beto"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1,$2,$3)`, [id, n + "@t.l", JSON.stringify({ username: n })]); await as(id, `select public.create_character($1,'mago')`, [n[0].toUpperCase() + n.slice(1)]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);

console.log("\nAvisos");
let r = await as(ANA, `select public.admin_save_post(null, 'aviso', 'oi', 'x', '{}', null, false)`); check("jogador comum não publica", /administrador/.test(r.error || ""), r.error);
r = await as(ANA, `insert into posts(kind, title, created_by) values ('aviso', 'x', '${ANA}')`); check("ninguém grava aviso pelo navegador", !!r.error);
const a1 = (await as(ADM, `select (public.admin_save_post(null, 'promocao', 'Pacote de moedas pela metade!', 'Só até domingo.', '{}', null, true)).id`)).rows[0].id;
check("admin publica uma promoção fixada", !!a1);
r = await as(ADM, `select row_to_json(public.admin_save_post($1, 'evento', 'Evento de Halloween', 'Começa sexta.', '{}', null, false)) p`, [a1]); check("admin edita o aviso", !r.error && r.rows[0].p.kind === "evento", r.error);
r = await as(ANA, `select title from posts`); check("jogador lê os avisos", r.rows?.[0]?.title === "Evento de Halloween", JSON.stringify(r));

console.log("\nEnquetes");
r = await as(ADM, `select public.admin_save_post(null, 'enquete', 'Qual evento?', '', '{"só uma"}', null, false)`); check("enquete com 1 opção é recusada", /2 a 6/.test(r.error || ""), r.error);
const e1 = (await as(ADM, `select (public.admin_save_post(null, 'enquete', 'Qual o próximo evento?', 'Vote!', '{"Halloween","Natal"," ","Copa"}', null, false)).id`)).rows[0].id;
check("admin cria enquete (opção vazia é ignorada)", (await sys(`select cardinality(options) n from posts where id = $1`, [e1]))[0].n === 3);
r = await as(ANA, `select public.poll_vote($1, 0)`, [e1]); check("Ana vota em Halloween", !r.error, r.error);
r = await as(ANA, `select public.poll_vote($1, 2)`, [e1]); check("Ana muda o voto para Copa", !r.error && (await sys(`select count(*)::int n from poll_votes`))[0].n === 1, r.error);
r = await as(BETO, `select public.poll_vote($1, 9)`, [e1]); check("opção inexistente é recusada", /inválida/.test(r.error || ""), r.error);
r = await as(BETO, `select public.poll_vote($1, 2)`, [e1]); check("Beto vota em Copa", !r.error, r.error);
r = await as(BETO, `insert into poll_votes(post_id, user_id, option) values (${e1}, '${ANA}', 0)`); check("ninguém vota pelos outros direto na tabela", !!r.error);
r = await as(ANA, `select public.poll_results() r`); const res = r.rows?.[0]?.r?.[String(e1)];
check("resultado: Copa 2 votos, total 2, meu voto = Copa", res && JSON.stringify(res.counts) === "[0,0,2]" && +res.total === 2 && res.mine === 2, JSON.stringify(res));
r = await as(ANA, `select * from poll_votes`); check("Ana não vê o voto do Beto", r.rows?.length === 1, JSON.stringify(r));
r = await as(ADM, `select public.admin_save_post($1, 'enquete', 'Qual o próximo evento?', 'Vote!', '{"A","B"}', null, false)`, [e1]); check("não muda opções depois que tem voto", /já tem votos/.test(r.error || ""), r.error);
r = await as(ADM, `select public.admin_save_post($1, 'enquete', 'Qual o próximo evento?', 'Encerrada', '{"Halloween","Natal","Copa"}', now() - interval '1 minute', false)`, [e1]); check("admin encerra a enquete (prazo no passado)", !r.error, r.error);
r = await as(BETO, `select public.poll_vote($1, 1)`, [e1]); check("não vota depois de encerrada", /encerrada/.test(r.error || ""), r.error);
r = await as(ANA, `select public.admin_delete_post($1)`, [a1]); check("jogador comum não apaga", !!r.error);
r = await as(ADM, `select public.admin_delete_post($1)`, [e1]); check("admin apaga a enquete (e os votos somem)", !r.error && (await sys(`select count(*)::int n from poll_votes`))[0].n === 0, r.error);
check("tudo na auditoria", (await sys(`select count(*)::int n from admin_audit_log where action in ('aviso','aviso_apagado')`))[0].n >= 4);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
