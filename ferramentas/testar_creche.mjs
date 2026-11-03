// Testa o arquivo 64 (Creche Pokémon) com dados de TESTE, como jogadores comuns:
// sobe de nível na hora pagando (nível alcançado × 10 por nível), limite de 5 níveis por semana somando todos,
// só até o nível 40, moedas insuficientes, Pokémon de outro, aviso de evolução, cada um vê só o seu, admin ajusta.
// Roda só até o 68 (o 69 fez os níveis chegarem aos poucos; os testes dele estão em testar_creche_espera.mjs).
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_creche.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql" && f < "69").sort()) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
const A = "11111111-1111-1111-1111-111111111111", B = "22222222-2222-2222-2222-222222222222", ADM = "99999999-9999-9999-9999-999999999999";
for (const [u, n] of [[A, "Ana"], [B, "Beto"], [ADM, "Chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'mago')`, [n]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
await sys(`update characters set coins = 5000`);
const newMon = async (u, sp, lv) => (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, sp, lv]))[0].id;
const mon = async id => (await sys(`select * from monsters where id = $1`, [id]))[0];
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;
const train = (u, id, n) => as(u, `select public.creche_treinar($1, $2) r`, [id, n]).then(x => x.error ? x : { r: x.rows[0].r });
const ch = await newMon(A, 4, 10), velho = await newMon(A, 7, 39), doB = await newMon(B, 1, 5);

console.log("\nTreinar");
let st = (await as(A, `select public.creche_estado() s`)).rows[0].s;
check("estado: 5 níveis por semana, até o 40, 10 por nível, nada usado", st.niveis_semana === 5 && st.nivel_max === 40 && st.preco_por_nivel === 10 && st.restante === 5, JSON.stringify(st));
let r = await train(A, ch, 2);
check("Charmander do 10 ao 12 custa 230 (11×10 + 12×10)", !r.error && r.r.custo === 230 && (await mon(ch)).level === 12 && (await coins(A)) === 4770, r.error || JSON.stringify(r.r));
r = await train(A, ch, 3);
check("mais 3 níveis (12 → 15) na mesma semana", !r.error && (await mon(ch)).level === 15, r.error);
check("o 6º nível da semana é recusado (somando todos)", /no máximo 5 níveis/.test((await train(A, velho, 1)).error || ""));
await sys(`update creche_log set created_at = created_at - interval '8 days'`);
r = await train(A, ch, 1);
check("na semana seguinte, volta a poder", !r.error && (await mon(ch)).level === 16, r.error);
check("ao chegar no nível de evoluir, avisa (evento de evolução)", r.r?.events?.some(e => e.kind === "evolucao"), JSON.stringify(r.r?.events));
check("não passa do nível 40", /até o nível 40/.test((await train(A, velho, 2)).error || ""));
check("39 → 40 pode", !(await train(A, velho, 1)).error && (await mon(velho)).level === 40);
check("Pokémon de outro jogador não", /Pokémon seu/.test((await train(A, doB, 1)).error || ""));
await sys(`update characters set coins = 10 where user_id = $1`, [B]);
check("sem moedas suficientes, recusa", /Custa 60 moedas/.test((await train(B, doB, 1)).error || ""));
check("cada um vê só os seus treinos", (await as(B, `select count(*)::int n from creche_log`)).rows[0].n === 0 && (await as(A, `select count(*)::int n from creche_log`)).rows[0].n === 4);

console.log("\nAdmin");
const c = (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c;
check("a Creche aparece nos Ajustes do jogo", c.creche?.niveis_semana === 5);
await as(ADM, `select public.admin_set_config($1::jsonb, 'teste')`, [JSON.stringify({ creche: { ...c.creche, on: false } })]);
check("o admin pode fechar a Creche", /fechada/.test((await train(A, ch, 1)).error || ""));
check("a novidade está no Jornal", (await sys(`select count(*)::int n from posts where title = '🏡 Nova: Creche Pokémon'`))[0].n === 1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
