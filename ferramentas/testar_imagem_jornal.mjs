// Testa o arquivo 26 (imagem nos avisos do Jornal, some em 3 dias) com dados de TESTE.
// (Roda os arquivos só até o 40: desde o 41, aviso não é mais apagado e imagem não vence; isso é testado em testar_jornal_permanente.mjs.)
// Uso (na pasta ferramentas, uma vez: npm i @electric-sql/pglite@0.3.15):  node testar_imagem_jornal.mjs ..
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
const ADM = "99999999-9999-9999-9999-999999999999", ANA = "11111111-1111-1111-1111-111111111111";
for (const [id, n] of [[ADM, "chefe"], [ANA, "ana"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1,$2,$3)`, [id, n + "@t.l", JSON.stringify({ username: n })]); await as(id, `select public.create_character($1,'mago')`, [n[0].toUpperCase() + n.slice(1)]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
const IMG = "data:image/jpeg;base64," + "QUJD".repeat(2000);
const pid = (await as(ADM, `select (public.admin_save_post(null, 'evento', 'Torneio', 'Sábado', '{}', null, false)).id`)).rows[0].id;

console.log("\nImagem no aviso");
let r = await as(ANA, `select public.admin_post_image($1, $2)`, [pid, IMG]); check("jogador comum não envia imagem", /administrador/.test(r.error || ""), r.error);
r = await as(ADM, `select public.admin_post_image($1, $2)`, [pid, "javascript:alert(1)"]); check("só aceita imagem de verdade", /inválida/.test(r.error || ""), r.error);
r = await as(ADM, `select public.admin_post_image($1, $2)`, [pid, "data:image/jpeg;base64," + "A".repeat(700001)]); check("imagem grande demais é recusada", !!r.error, r.error);
r = await as(ADM, `select public.admin_post_image($1, $2)`, [pid, IMG]); check("admin envia a imagem", !r.error, r.error);
check("o aviso marca que tem imagem", !!(await sys(`select image_at from posts where id = $1`, [pid]))[0].image_at);
r = await as(ANA, `select data from post_images where post_id = $1`, [pid]); check("jogador vê a imagem", r.rows?.[0]?.data === IMG, r.error);
r = await as(ANA, `insert into post_images(post_id, data) values (${pid}, 'x')`); check("ninguém grava imagem direto na tabela", !!r.error);
r = await as(ADM, `select public.admin_post_image($1, $2)`, [pid, IMG.replace("QUJD", "WFla")]); check("admin troca a imagem", !r.error && (await sys(`select count(*)::int n from post_images`))[0].n === 1, r.error);

console.log("\nSome em 3 dias (e sai do banco)");
await sys(`update post_images set created_at = now() - interval '3 days 1 minute'`);
r = await as(ANA, `select * from post_images`); check("depois de 3 dias o jogador já não vê", r.rows?.length === 0);
r = await as(ANA, `select public.post_images_purge() n`); check("a limpeza apaga do banco", !r.error && (await sys(`select count(*)::int n from post_images`))[0].n === 0, r.error);
check("o aviso continua, sem imagem", (await sys(`select title, image_at from posts where id = $1`, [pid]))[0].image_at === null);
await as(ADM, `select public.admin_post_image($1, $2)`, [pid, IMG]);
r = await as(ADM, `select public.admin_post_image($1, '')`, [pid]); check("admin tira a imagem", !r.error && (await sys(`select count(*)::int n from post_images`))[0].n === 0, r.error);
await as(ADM, `select public.admin_post_image($1, $2)`, [pid, IMG]);
await as(ADM, `select public.admin_delete_post($1)`, [pid]); check("apagar o aviso apaga a imagem", (await sys(`select count(*)::int n from post_images`))[0].n === 0);
await sys(`update game_config set config = config || '{"post_image_days": 7}' where active`);
const p2 = (await as(ADM, `select (public.admin_save_post(null, 'aviso', 'Outro', '', '{}', null, false)).id`)).rows[0].id;
await as(ADM, `select public.admin_post_image($1, $2)`, [p2, IMG]); await sys(`update post_images set created_at = now() - interval '4 days'`);
r = await as(ANA, `select * from post_images`); check("o prazo pode ser mudado nas regras (7 dias)", r.rows?.length === 1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
