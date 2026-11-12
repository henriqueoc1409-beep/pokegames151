// Testa o arquivo 100 (Aventura: Pokémon de suporte e a vila no treino) com dados de TESTE, como jogador comum:
// Arena da vila dá +5 lutas por dia na Aventura, o suporte ganha metade da experiência (selvagem, Ginásio e Chefe),
// suporte desmaiado ou igual a quem luta é ignorado, Academia dá XP a mais na Aventura, Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_rpg_suporte.mjs ..
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
for (const [u, n] of [[A, "Ana"], [ADM, "Chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'guerreiro')`, [n]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
await sys(`update monsters set team_slot = null where true`);
const mk = async (sp, lv, slot) => { const id = (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [A, sp, lv]))[0].id; if (slot) await sys(`update monsters set team_slot = $2 where id = $1`, [id, slot]); return id; };
const forte = await mk(150, 80, 1), sup = await mk(129, 5, 2);
const xp = async id => (await sys(`select exp from monsters where id = $1`, [id]))[0].exp;
const cura = () => sys(`update monsters set tr_hp = 100, tr_hurt_at = null where true`);
const prepara = () => sys(`update rpg_dias set ult = null where true`);
async function luta(bid) {
  for (let i = 0; i < 80; i++) { const b = (await sys(`select * from battles where id = $1`, [bid]))[0]; if (b.status !== "ativa") return b;
    let r; for (const mv of [0, 1, 2, 3, -1]) { r = await as(A, `select public.battle_act($1, $2, 'move', $3)`, [bid, b.turn, mv]); if (!r.error) break; } if (r.error) return b; }
  return (await sys(`select * from battles where id = $1`, [bid]))[0];
}
const estado = async () => (await as(A, `select public.rpg_estado() e`)).rows[0].e;

console.log("\nArena da vila");
let e = await estado();
check("sem Arena: 20 lutas por dia", e.batalhas_dia === 20 && e.vila_lutas === 0, JSON.stringify([e.batalhas_dia, e.vila_lutas]));
await sys(`insert into villages(user_id) values ($1) on conflict do nothing`, [A]); await sys(`update villages set arena_level = 1 where user_id = $1`, [A]);
e = await estado();
check("com a Arena: 25 lutas por dia", e.batalhas_dia === 25 && e.vila_lutas === 5, JSON.stringify([e.batalhas_dia, e.vila_lutas]));
await sys(`insert into rpg_dias(user_id, dia, batalhas) values ($1, public.game_today(), 22) on conflict (user_id, dia) do update set batalhas = 22, ult = null`, [A]);
let r = await as(A, `select public.rpg_encontro($1, 'mato') r`, [forte]);
check("com 22 lutas feitas ainda luta (o limite é 25)", !r.error, r.error);
await sys(`delete from battles where p1 = $1`, [A]);
await sys(`update rpg_dias set batalhas = 25, ult = null where user_id = $1`, [A]);
check("na 26ª recusa", /25 lutas/.test((await as(A, `select public.rpg_encontro($1, 'mato')`, [forte])).error || ""));
await sys(`update rpg_dias set batalhas = 0 where true`);

console.log("\nPokémon de suporte");
let x0 = await xp(sup);
r = await as(A, `select public.rpg_encontro($1, 'mato', $2) r`, [forte, sup]);
let b = await luta(r.rows[0].r.battle), res = b.state.treino.res;
check("contra selvagem: o suporte ganha metade da experiência", res.won && res.comp_xp === Math.floor(res.xp * 0.5) && await xp(sup) > x0, JSON.stringify(res));
await prepara(); await sys(`delete from battles where p1 = $1`, [A]);
r = await as(A, `select public.rpg_encontro($1, 'mato', $2) r`, [forte, forte]);
b = (await sys(`select * from battles where id = $1`, [r.rows[0].r.battle]))[0];
check("o suporte não pode ser quem luta", b.state.treino.comp === null);
await sys(`delete from battles where p1 = $1`, [A]); await prepara();
await sys(`update monsters set tr_hp = 0, tr_hurt_at = now() where id = $1`, [sup]);
r = await as(A, `select public.rpg_encontro($1, 'mato', $2) r`, [forte, sup]);
b = (await sys(`select * from battles where id = $1`, [r.rows[0].r.battle]))[0];
check("suporte desmaiado não vai", b.state.treino.comp === null);
await sys(`delete from battles where p1 = $1`, [A]); await cura();
x0 = await xp(sup);
r = await as(A, `select public.rpg_ginasio_lutar('bosque', $1) r`, [sup]);
b = await luta(r.rows[0].r.battle);
check("no Ginásio o suporte também ganha", b.state.treino.comp === sup && b.state.treino.res.comp_xp > 0 && await xp(sup) > x0, JSON.stringify(b.state.treino.res));
await sys(`delete from battles where p1 = $1`, [A]); await cura();
await as(ADM, `select public.admin_rpg_chefe('praia', 143)`);
r = await as(A, `select public.rpg_chefe_lutar($1) r`, [sup]);
b = (await sys(`select * from battles where id = $1`, [r.rows[0].r.battle]))[0];
check("contra o Chefe o suporte vai junto", b.state.treino.comp === sup, JSON.stringify(b.state.treino));
check("o estado diz a porcentagem do suporte", e.acompanhante_pct === 50);

console.log("\nAcademia");
await sys(`delete from battles where p1 = $1`, [A]); await prepara(); await cura();
r = await as(A, `select public.rpg_encontro($1, 'mato') r`, [forte]); b = await luta(r.rows[0].r.battle);
const w = b.state.sides[1].mons[0], base = Math.floor(w.bexp * w.level / 7);
await sys(`update villages set academy_level = 3 where user_id = $1`, [A]); await prepara(); await sys(`delete from battles where p1 = $1`, [A]);
let ok2 = false;
for (let i = 0; i < 6 && !ok2; i++) { await prepara(); await sys(`delete from battles where p1 = $1`, [A]);
  r = await as(A, `select public.rpg_encontro($1, 'mato') r`, [forte]); b = await luta(r.rows[0].r.battle);
  const w2 = b.state.sides[1].mons[0]; if (b.state.treino.res.won) ok2 = b.state.treino.res.xp === Math.ceil(Math.floor(w2.bexp * w2.level / 7) * 1.3); }
check("Academia nível 3 dá +30% de XP na Aventura", ok2);
check("aviso publicado no Jornal uma vez", (await sys(`select count(*)::int n from posts where title = '🎒 Aventura: Pokémon de suporte e a vila ajudando no treino'`))[0].n === 1);
console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
