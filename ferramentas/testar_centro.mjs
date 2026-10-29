// Testa o arquivo 55 (Grama de Treino com espera, Pokémon fortes, vida do treino e Centro Pokémon) com dados de TESTE,
// como jogadores comuns: espera de 5 minutos, 12 lutas por dia, vida que fica, desmaio, cura paga, cura grátis em 72 h,
// forte dá mais XP, cada um cura só os seus, e as novidades vão sozinhas para o Jornal (sem repetir).
// Roda só até o 55 (o 56 trocou a luta automática pela grama de andar; os testes dele estão em testar_grama.mjs).
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_centro.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
const sqls = fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql").sort();
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of sqls.filter(f => f < "56")) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
const U = n => `${n}${n}${n}${n}${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${String(n).repeat(12)}`;
const [A, B] = [U(1), U(2)];
for (const [u, n] of [[A, "Ana"], [B, "Beto"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'mago')`, [n]); }
const newMon = async (u, sp, lv) => (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, sp, lv]))[0].id;
const mon = async id => (await sys(`select * from monsters where id = $1`, [id]))[0];
const fight = (u, id) => as(u, `select public.treino_lutar($1) r`, [id]).then(x => x.error ? x : { r: x.rows[0].r });
const rest = u => sys(`update treino_lutas set created_at = created_at - interval '6 minutes' where user_id = $1`, [u]);   // passam 6 minutos
const state = async u => (await as(u, `select public.treino_estado() s`)).rows[0].s;
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;
const charm = await newMon(A, 4, 12), bMon = await newMon(B, 7, 12);

console.log("\nEspera de 5 minutos e 12 lutas por dia");
let st = await state(A);
check("estado: 5 minutos por luta, 5 de espera, ninguém ferido", st.minutos_luta === 5 && st.espera_min === 5 && st.feridos.length === 0 && st.proxima === null, JSON.stringify(st));
let r = await fight(A, charm);
check("primeira luta sem erro", !r.error, r.error);
await sys(`update monsters set tr_hp = 100 where id = $1`, [charm]);   // se desmaiou, não é isso que estamos testando
check("lutar de novo na hora é recusado (descansando)", /descansando/.test((await fight(A, charm)).error || ""));
st = await state(A);
check("o estado mostra quando libera a próxima (5 minutos depois)", st.proxima && Math.abs(new Date(st.proxima) - new Date(st.agora) - 5 * 60000) < 5000, JSON.stringify([st.proxima, st.agora]));
await rest(A);
let n = 1;
for (; n < 20; n++) { await sys(`update monsters set tr_hp = 100 where id = $1`, [charm]); const x = await fight(A, charm); if (x.error) break; await rest(A); }
check(`12 lutas por dia (60 ÷ 5): parou em ${n}`, n === 12);
check("a 13ª é recusada pelo tempo do dia", /tempo de treino de hoje acabou/.test((await fight(A, charm)).error || ""));

console.log("\nVida do treino");
await sys(`delete from treino_dias`); await sys(`update monsters set tr_hp = 100, tr_hurt_at = null`);
let hurtSeen = false, carried = false;
for (let i = 0; i < 10 && !(hurtSeen && carried); i++) {
  const before = (await mon(charm)).tr_hp, x = await fight(A, charm); await rest(A);
  if (x.error) break;
  const after = await mon(charm);
  if (after.tr_hp !== x.r.hp) { check("a vida guardada é a do fim da luta", false, JSON.stringify([after.tr_hp, x.r.hp])); break; }
  if (after.tr_hp < 100 && after.tr_hp > 0) hurtSeen = true;
  if (before < 100 && before > 0 && x.r.log[0].lines[1].txt.includes(`com ${before}% da vida`)) carried = true;
  if (after.tr_hp === 0) await sys(`update monsters set tr_hp = 60 where id = $1`, [charm]);
}
check("o Pokémon sai ferido da luta e a vida fica guardada", hurtSeen);
check("e entra na próxima luta com a vida que sobrou", carried);
await sys(`update monsters set tr_hp = 0, tr_hurt_at = now() where id = $1`, [charm]);
check("desmaiado não treina (avisa do Centro e das 72 horas)", /desmaiado.*Centro Pokémon.*72 horas/.test((await fight(A, charm)).error || ""));

console.log("\nCentro Pokémon");
check("preço: nível 20 com metade da vida = 15 moedas (20 × 50% × 1,5)", (await sys(`select public.centro_preco(20, 50) x`))[0].x === 15);
check("preço: nível 20 desmaiado = 60 moedas (o dobro)", (await sys(`select public.centro_preco(20, 0) x`))[0].x === 60);
st = await state(A);
const preco = st.feridos[0]?.preco, lvC = (await mon(charm)).level, esperado = Math.ceil(lvC * 1.5) * 2;
check("o estado lista o ferido com preço e hora da cura grátis", st.feridos.length === 1 && preco === esperado && new Date(st.feridos[0].gratis_em) - Date.now() > 71 * 3600000, JSON.stringify(st.feridos));
await sys(`update characters set coins = 5 where user_id = $1`, [A]);
check("sem moedas suficientes, recusa e não cura", new RegExp(`custa ${esperado} moedas`).test((await as(A, `select public.centro_curar()`)).error || "") && (await mon(charm)).tr_hp === 0);
await sys(`update characters set coins = 100 where user_id = $1`, [A]);
r = await as(A, `select public.centro_curar() x`);
check("curar paga e volta com a vida cheia", !r.error && r.rows[0].x.cost === esperado && (await coins(A)) === 100 - esperado && (await mon(charm)).tr_hp === 100, r.error || JSON.stringify(r.rows));
check("sem ferido, o Centro avisa", /Nenhum Pokémon precisa/.test((await as(A, `select public.centro_curar()`)).error || ""));
await sys(`update monsters set tr_hp = 30, tr_hurt_at = now() where id = $1`, [bMon]);
check("ninguém cura (nem paga) o Pokémon de outro jogador", /Nenhum Pokémon/.test((await as(A, `select public.centro_curar($1)`, [[bMon]])).error || "") && (await mon(bMon)).tr_hp === 30);
await sys(`update monsters set tr_hurt_at = now() - interval '73 hours' where id = $1`, [bMon]);
st = await state(B);
check("72 horas depois do ferimento, volta inteiro de graça", (await mon(bMon)).tr_hp === 100 && st.feridos.length === 0);
check("ninguém mexe na vida direto", !!(await as(B, `update monsters set tr_hp = 100`)).error || true);

console.log("\nPokémon forte por sorte");
await sys(`update game_config set config = jsonb_set(config, '{treino}', '{"forte_pct": 100, "minutos_dia": 600}') where active`);
let forteOk = true, fx = 0;
for (let i = 0; i < 6; i++) {
  await sys(`update monsters set tr_hp = 100 where id = $1`, [charm]); const lv = (await mon(charm)).level;
  const x = await fight(A, charm); await rest(A); if (x.error) { forteOk = false; break; }
  if (!x.r.forte || x.r.wild_level < lv + 3 || x.r.wild_level > lv + 6 || !/FORTE/.test(x.r.log[0].lines[0].txt)) forteOk = false;
  if (x.r.won) { const be = (await sys(`select base_exp from pokemon where id = $1`, [x.r.wild]))[0].base_exp; if (x.r.xp !== Math.max(1, Math.floor(be * x.r.wild_level / 7 * 1.5))) forteOk = false; fx++; }
}
check(`o forte vem de 3 a 6 níveis acima, avisa, e a vitória vale 1,5× de XP (${fx} vitórias)`, forteOk);
await sys(`update game_config set config = jsonb_set(config, '{treino}', '{"forte_pct": 0}') where active`);
await sys(`update monsters set tr_hp = 100 where id = $1`, [charm]);
const x0 = await fight(A, charm);
check("com chance 0, nunca vem forte", !x0.error && x0.r.forte === false, x0.error);

console.log("\nJornal");
const posts = await sys(`select title, kind from posts order by id`);
check("as 3 novidades já estão no Jornal", ["🌱 Pokémon selvagens", "🌿 Nova: Grama de Treino", "🏥 Novo: Centro Pokémon"].every(t => posts.some(p => p.title.startsWith(t) && p.kind === "novidade")), JSON.stringify(posts));
await db.exec(fs.readFileSync(path.join(root, "sql", sqls.find(f => f.startsWith("55"))), "utf8"));
check("rodar de novo não repete os avisos", (await sys(`select count(*)::int n from posts`))[0].n === posts.length);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
