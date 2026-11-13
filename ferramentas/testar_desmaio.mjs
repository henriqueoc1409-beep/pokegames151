// Testa o arquivo 98 (desmaiado só começa a se recuperar depois de 24 h) com dados de TESTE, como jogador comum:
// desmaiado há 10 h continua desmaiado e não luta na Aventura, depois de 24 h + 7,2 h está com 10%, ferido com vida
// continua igual, hora da vida cheia, admin muda a espera, Ajustes, Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_desmaio.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql" && parseInt(f) < 109).sort((a, b) => parseInt(a) - parseInt(b) || a.localeCompare(b))) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
const A = "11111111-1111-1111-1111-111111111111", ADM = "99999999-9999-9999-9999-999999999999";
for (const [u, n] of [[A, "Ana"], [ADM, "Chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'guerreiro')`, [n]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
const mon = async (sp, lv) => (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [A, sp, lv]))[0].id;
const M1 = await mon(94, 30), M2 = await mon(16, 10);
const fere = (id, hp, horas) => sys(`update monsters set tr_hp = $2, tr_hurt_at = now() - make_interval(secs => $3::numeric * 3600) where id = $1`, [id, hp, horas]);
const hp = async id => (await sys(`select tr_hp from monsters where id = $1`, [id]))[0].tr_hp;
const est = async () => (await as(A, `select public.treino_estado() e`)).rows[0].e;

console.log("\nDesmaiado espera 24 h");
await fere(M1, 0, 10); await fere(M2, 50, 1);
let e = await est();
check("desmaiado há 10 h continua desmaiado", await hp(M1) === 0);
check("ferido com vida continua recuperando aos poucos (+1% em 1 h)", await hp(M2) === 51);
const f1 = e.feridos.find(f => f.id === M1), falta = (new Date(f1.gratis_em) - new Date(e.agora)) / 3600000;
check("vida cheia em 14 h + 72 h (faltam 86 h)", Math.abs(falta - 86) < 0.05, falta);
const enc = await as(A, `select public.rpg_encontro($1, 'mato')`, [M1]);
check("desmaiado não luta na Aventura", !!enc.error && /desmaiado/.test(enc.error), enc.error);
await fere(M1, 0, 24 + 7.2); await est();
check("depois de 24 h + 7,2 h está com 10%", await hp(M1) === 10, await hp(M1));
await est();
check("chamar de novo não dá vida a mais", await hp(M1) === 10);
await fere(M1, 0, 30); await sys(`update game_config set config = jsonb_set(config, '{treino,desmaio_espera_horas}', '0') where active`); await est();
check("o admin zera a espera e volta a regra do 95 (30 h = 41%)", await hp(M1) === 41, await hp(M1));
const aj = (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c;
check("aparece em Ajustes do jogo", aj.treino?.desmaio_espera_horas === 0);
check("avisos publicados no Jornal uma vez", (await sys(`select count(*)::int n from posts where title in ('💤 Centro Pokémon: desmaiado só começa a se recuperar depois de 24 h', '📜 Acontecimentos no chat')`))[0].n === 2);
console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
