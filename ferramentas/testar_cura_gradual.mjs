// Testa o arquivo 95 (a vida do treino volta aos poucos) com dados de TESTE, como jogador comum:
// desmaiado volta um pouco por hora e pode lutar, vida cheia no tempo certo, a sobra do tempo não se perde,
// preço do Centro só pela vida que falta, gratis_em certo, desligado volta a regra antiga, Ajustes, Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_cura_gradual.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql" && parseInt(f) < 97).sort((a, b) => parseInt(a) - parseInt(b) || a.localeCompare(b))) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
const U = n => `${n}${n}${n}${n}${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${String(n).repeat(12)}`;
const [A, ADM] = [U(1), U(9)];
for (const [u, n] of [[A, "ana"], [ADM, "chefe"]]) await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]);
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
for (const [u, n] of [[A, "Ana"], [ADM, "Chefe"]]) await as(u, `select public.create_character($1, 'guerreiro')`, [n]);
await sys(`update characters set coins = 5000`);
// três Pokémon de teste da Ana
const mon = async (sp, lv) => (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [A, sp, lv]))[0].id;
const M1 = await mon(19, 10), M2 = await mon(16, 10), M3 = await mon(10, 10);
const fere = (id, hp, horas) => sys(`update monsters set tr_hp = $2, tr_hurt_at = now() - make_interval(secs => $3::numeric * 3600) where id = $1`, [id, hp, horas]);
const hp = async id => (await sys(`select tr_hp, tr_hurt_at from monsters where id = $1`, [id]))[0];
const est = async () => (await as(A, `select public.treino_estado() e`)).rows[0].e;

console.log("\nA vida volta aos poucos");
await fere(M1, 0, 7.2);    // desmaiado há 7,2 h: 72 h para 100% → +10%
await fere(M2, 50, 40);    // metade da vida, ferido há 40 h → cheio (precisava de 36 h)
await fere(M3, 30, 1);     // ferido há 1 h → +1% e sobra 0,28 h
let e = await est();
check("o estado diz que a cura é aos poucos", e.cura_gradual === true, JSON.stringify(e.cura_gradual));
let h1 = await hp(M1), h2 = await hp(M2), h3 = await hp(M3);
check("desmaiado há 7,2 h voltou com 10% da vida", h1.tr_hp === 10, h1.tr_hp);
check("ferido pela metade há 40 h já está com a vida cheia (e sem ferimento marcado)", h2.tr_hp === 100 && h2.tr_hurt_at === null, JSON.stringify(h2));
check("ferido há 1 h recuperou 1%", h3.tr_hp === 31, h3.tr_hp);
const sobra = (await sys(`select extract(epoch from now() - tr_hurt_at) / 3600 h from monsters where id = $1`, [M3]))[0].h;
check("a sobra do tempo não se perde (0,28 h contam para o próximo 1%)", Math.abs(sobra - 0.28) < 0.01, sobra);
await est();
check("chamar de novo não dá vida a mais", (await hp(M3)).tr_hp === 31);

const f1 = e.feridos.find(f => f.id === M1);
const fim = (new Date(f1.gratis_em) - new Date(e.agora)) / 3600000;
check("vida cheia de graça em 64,8 h (faltam 90%)", Math.abs(fim - 64.8) < 0.05, fim);
const cheio = (await sys(`select public.centro_preco_de($1, 10, 10) p`, [A]))[0].p;
check("preço do Centro é só pela vida que falta (sem desconto duplo pelo tempo)", f1.preco === cheio && f1.preco === f1.preco_cheio, JSON.stringify(f1));
check("quem recuperou mais paga menos", e.feridos.find(f => f.id === M3).preco < (await sys(`select public.centro_preco_de($1, 10, 0) p`, [A]))[0].p);

// desmaiado que recuperou já entra na Grama
await as(A, `select public.treino_entrar(5)`);
const enc = await as(A, `select public.treino_encontro($1, null) r`, [M1]);
check("desmaiado que recuperou 10% já pode lutar", !enc.error, enc.error);

const cura = await as(A, `select public.centro_curar(array[$1]::uuid[]) r`, [M3]);
check("curar no Centro ainda deixa a vida cheia na hora", !cura.error && (await hp(M3)).tr_hp === 100, cura.error);

console.log("\nDesligado volta a regra antiga");
await as(ADM, `select public.admin_set_config('{"treino": {"cura_gradual": false}}'::jsonb, 'teste')`);
await fere(M2, 0, 40);
e = await est();
check("desligado: 40 h depois continua desmaiado", e.cura_gradual === false && (await hp(M2)).tr_hp === 0);
await fere(M2, 0, 73); await est();
check("desligado: depois de 72 h volta inteiro", (await hp(M2)).tr_hp === 100);

const aj = (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c;
check("aparece em Ajustes do jogo", JSON.stringify(aj).includes("cura_gradual"));
check("aviso publicado no Jornal uma vez", (await sys(`select count(*)::int n from posts where title = '❤️ Centro Pokémon: a vida agora volta aos poucos'`))[0].n === 1);
console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
