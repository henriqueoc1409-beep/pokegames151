// Testa o arquivo 93 (Aventura, o RPG) com dados de TESTE, como jogadores comuns:
// encontro só em terreno com Pokémon, selvagem do tipo do terreno e no nível certo, a luta dá experiência pela conta da Grama,
// não gasta o relógio da Grama, espera entre encontros, limite de lutas por dia, Pokémon desmaiado não luta, só Pokémon próprio,
// fechada pelo admin, Ajustes e aviso no Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_rpg.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql" && f < "97").sort()) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
const A = "11111111-1111-1111-1111-111111111111", B = "22222222-2222-2222-2222-222222222222", ADM = "99999999-9999-9999-9999-999999999999";
for (const [u, n] of [[A, "Ana"], [B, "Beto"], [ADM, "Chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'mago')`, [n]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
const newMon = async (u, sp, lv) => (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, sp, lv]))[0].id;
const mon = async id => (await sys(`select * from monsters where id = $1`, [id]))[0];
const battle = async id => (await sys(`select * from battles where id = $1`, [id]))[0];
const cool = () => sys(`update rpg_dias set ult = now() - interval '1 minute' where true`);
const forte = await newMon(A, 150, 30), alheio = await newMon(B, 7, 10);
async function luta(zona) {
  await sys(`update monsters set tr_hp = 100 where true`); await cool();
  const e = await as(A, `select public.rpg_encontro($1, $2) r`, [forte, zona]);
  if (e.error) return { error: e.error };
  const bid = e.rows[0].r.battle, b0 = await battle(bid);
  for (let i = 0; i < 60; i++) {
    const b = await battle(bid); if (b.status !== "ativa") return { t: b.state.treino, wild: b0.state.sides[1].mons[0] };
    const mv = b.state.sides[0].mons[0].moves.findIndex(m => m.pp > 0);
    const r = await as(A, `select * from public.battle_act($1, (select turn from battles where id = $1), 'move', $2)`, [bid, mv < 0 ? -1 : mv]);
    if (r.error) return { error: r.error };
  }
  return { t: (await battle(bid)).state.treino, wild: b0.state.sides[1].mons[0] };
}

console.log("\nAventura: encontros");
let r = await as(A, `select public.rpg_estado() s`);
check("estado: ligada, 0 de 20 lutas hoje", !r.error && r.rows[0].s.on === true && r.rows[0].s.batalhas === 0 && r.rows[0].s.batalhas_dia === 20, r.error || JSON.stringify(r.rows?.[0]));
check("terreno sem Pokémon não dá encontro", /Não há Pokémon selvagens/.test((await as(A, `select public.rpg_encontro($1, 'estrada')`, [forte])).error || ""));
check("só Pokémon próprio", /Pokémon seu/.test((await as(A, `select public.rpg_encontro($1, 'mato')`, [alheio])).error || ""));
const x0 = (await mon(forte)).exp, minG = (await sys(`select coalesce(sum(minutos), 0)::int n from treino_dias where user_id = $1`, [A]))[0].n;
const tipos = { mato: ["INSETO", "PLANTA", "NORMAL"], pantano: ["AGUA", "VENENO"], pedra: ["PEDRA", "TERRA", "LUTA"], escura: ["NORMAL", "VOADOR", "ELETRICO"] };
let venceu = null, tipoOk = true, nivelOk = true, n = 0;
for (const z of ["mato", "pantano", "pedra", "escura", "mato", "pantano"]) {
  const L = await luta(z); n++;
  if (L.error) { check("luta sem erro em " + z, false, L.error); break; }
  const p = (await sys(`select g1_type1 a, g1_type2 b from pokemon where id = $1`, [L.wild.species]))[0];
  if (!tipos[z].includes(p.a) && !tipos[z].includes(p.b)) tipoOk = false;
  if (L.wild.level < 27 || L.wild.level > 30) nivelOk = false;
  if (L.t.rpg !== z) tipoOk = false;
  if (L.t.res?.won && !venceu) venceu = L.t.res;
}
check("o selvagem é sempre de um tipo do terreno", tipoOk);
check("o selvagem vem de 3 níveis abaixo até o nível do seu Pokémon", nivelOk);
check("vencer dá experiência (a mesma conta da Grama)", !!venceu && venceu.xp > 0 && (await mon(forte)).exp > x0, JSON.stringify(venceu));
check("não gasta o relógio da Grama de Treino", (await sys(`select coalesce(sum(minutos), 0)::int n from treino_dias where user_id = $1`, [A]))[0].n === minG);
check(`as lutas contam no dia (${n})`, (await as(A, `select public.rpg_estado() s`)).rows[0].s.batalhas === n);
r = await as(A, `select public.rpg_encontro($1, 'mato')`, [forte]);
check("precisa esperar entre um encontro e outro", /continue andando/.test(r.error || ""), r.error);
await sys(`update monsters set tr_hp = 0, tr_hurt_at = now() where id = $1`, [forte]); await cool();
check("Pokémon desmaiado não luta", /desmaiado/.test((await as(A, `select public.rpg_encontro($1, 'mato')`, [forte])).error || ""));
await sys(`update monsters set tr_hp = 100 where true`); await sys(`update rpg_dias set batalhas = 20, ult = null where user_id = $1`, [A]);
check("limite de 20 lutas por dia", /lutas de hoje/.test((await as(A, `select public.rpg_encontro($1, 'mato')`, [forte])).error || ""));
check("cada um lê só os seus dias", (await as(B, `select count(*)::int n from rpg_dias`)).rows[0].n === 0);

console.log("\nAjustes e Jornal");
await sys(`update rpg_dias set batalhas = 0 where true`);
await sys(`update game_config set config = jsonb_set(config, '{rpg,on}', 'false') where active`);
check("fechada pelo admin: jogador não luta", /fechada/.test((await as(A, `select public.rpg_encontro($1, 'mato')`, [forte])).error || ""));
await sys(`update game_config set config = jsonb_set(config, '{rpg,on}', 'true') where active`);
r = await as(ADM, `select public.admin_cfg_efetiva() x`);
check("aparece em Ajustes do jogo para o admin (e a Praça continua lá)", !r.error && r.rows[0].x.rpg?.batalhas_dia === 20 && !!r.rows[0].x.praca, r.error);
check("jogador comum não chama rpg_cfg direto", !!(await as(A, `select public.rpg_cfg() x`)).error);
check("aviso publicado no Jornal uma vez", (await sys(`select count(*)::int n from posts where title = '🧭 Chegou a Aventura: o RPG do Pokegames!'`))[0].n === 1);
console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
