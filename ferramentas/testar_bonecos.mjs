// Testa o arquivo 104 (bonecos da Aventura): o aviso no Jornal sai uma vez, e rodar de novo não repete; o arquivo dos bonecos
// existe, traz as camadas e os créditos.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_bonecos.mjs ..
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
const A = "11111111-1111-1111-1111-111111111111", ADM = "99999999-9999-9999-9999-999999999999";
for (const [u, n] of [[A, "Ana"], [ADM, "Chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'mago')`, [n]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);


console.log("Bonecos da Aventura");
const T = '🧍 Aventura: boneco novo, vestindo os seus equipamentos';
check("aviso publicado no Jornal uma vez", (await sys(`select count(*)::int n from posts where title = $1`, [T]))[0].n === 1);
await db.exec(fs.readFileSync(path.join(root, "sql/104_bonecos_aventura.sql"), "utf8"));
check("rodar de novo não repete o aviso", (await sys(`select count(*)::int n from posts where title = $1`, [T]))[0].n === 1);
const js = fs.readFileSync(path.join(root, "deploy/rpg-bonecos.js"), "utf8"); global.window = {}; eval(js);
const k = Object.keys(window.RPG_BONECOS || {});
check("o arquivo dos bonecos traz o corpo, a cabeça, os cabelos e as peças", ["corpo", "cabeca", "camisa", "peito_couro", "peito_malha", "peito_placa", "elmo_ouro", "bota_placa", "luva"].every(x => k.includes(x)) && k.length >= 30, k.length);
check("e os créditos dos artistas e das licenças", (window.RPG_BONECOS_CREDITOS?.artistas || []).length >= 10 && (window.RPG_BONECOS_CREDITOS.licencas || []).every(l => /OGA-BY|CC-BY|CC0/.test(l)));
console.log(`${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
