// Testa o arquivo 109 (desmaiado fica bom em 72 h no total) com dados de TESTE, como jogador comum: 24 h parado, depois a
// vida volta aos poucos em 48 h, o ritmo continua igual entre uma conferida e outra, ferido sem desmaiar continua igual,
// ferir de novo volta ao ritmo normal, a hora da vida cheia sai certa, Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_desmaio_72h.mjs ..
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
const A = "11111111-1111-1111-1111-111111111111";
await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, 'a@t.l', '{"username":"Ana"}')`, [A]); await as(A, `select public.create_character('Ana', 'guerreiro')`);
const m = (await sys(`select (public.pk_new_monster($1, 25, 20)).id id`, [A]))[0].id;
const poe = (hp, horas) => sys(`update monsters set tr_hp = $2, tr_ritmo = null, tr_hurt_at = now() - make_interval(secs => $3 * 3600) where id = $1`, [m, hp, horas]);
const ve = async () => { await as(A, `select public.treino_estado()`); return (await sys(`select tr_hp, tr_ritmo from monsters where id = $1`, [m]))[0]; };

console.log("\nDesmaiado: 72 h no total");
await poe(0, 23); check("com 23 h ainda está desmaiado", (await ve()).tr_hp === 0);
await poe(0, 25); let r = await ve(); check("com 25 h começou a voltar (1 h de 48 = 2%)", r.tr_hp === 2 && +r.tr_ritmo === 48, JSON.stringify(r));
await poe(0, 48); check("com 48 h está na metade", (await ve()).tr_hp === 50);
await poe(0, 72); r = await ve(); check("com 72 h está com a vida cheia", r.tr_hp === 100 && r.tr_ritmo === null, JSON.stringify(r));
await poe(0, 30); await ve();   // 6 h de 48 = 12%
await sys(`update monsters set tr_hurt_at = tr_hurt_at - interval '12 hours' where id = $1`, [m]);
r = await ve(); check("o ritmo de 48 h continua entre uma conferida e outra (12% + 25%)", r.tr_hp === 37, JSON.stringify(r));
await sys(`update monsters set tr_hp = 20, tr_hurt_at = now() where id = $1`, [m]);
r = (await sys(`select tr_ritmo from monsters where id = $1`, [m]))[0];
check("ferido de novo: volta ao ritmo normal", r.tr_ritmo === null);

console.log("\nFerido sem desmaiar continua igual");
await poe(50, 36); check("50% com 36 h fica com a vida cheia (1% a cada 72/100 h)", (await ve()).tr_hp === 100);
await poe(50, 18); check("50% com 18 h está em 75%", (await ve()).tr_hp === 75);

console.log("\nHora da vida cheia");
await poe(0, 0);
const st = (await as(A, `select public.treino_estado() e`)).rows[0].e, f = st.feridos.find(x => x.id === m);
const horas = (new Date(f.gratis_em) - new Date(st.agora)) / 3600000;
check("desmaiado agora: vida cheia em 72 h", Math.abs(horas - 72) < 0.1, horas);
check("o estado diz a espera e o ritmo", st.espera_desmaio == 24 && st.ritmo_desmaio == 48, JSON.stringify([st.espera_desmaio, st.ritmo_desmaio]));
check("aviso publicado no Jornal uma vez", (await sys(`select count(*)::int n from posts where title = '💤 Centro Pokémon: desmaiado fica bom em 72 horas'`))[0].n === 1);
console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
