// Testa o arquivo 63 (acompanhante na Grama de Treino) com dados de TESTE, como jogadores comuns:
// o acompanhante ganha metade da experiência de cada vitória, só Pokémon do próprio jogador, não pode ser o mesmo
// que luta, desmaiado não vai junto (arquivo 72), sem acompanhante nada muda, a porcentagem vem dos Ajustes, novidade no Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_acompanhante.mjs ..
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
const A = "11111111-1111-1111-1111-111111111111", B = "22222222-2222-2222-2222-222222222222";
for (const [u, n] of [[A, "Ana"], [B, "Beto"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'mago')`, [n]); }
await sys(`update game_config set config = jsonb_set(config, '{treino}', '{"lendario_pct": 0, "forte_pct": 0, "minutos_dia": 600}') where active`);
const newMon = async (u, sp, lv) => (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, sp, lv]))[0].id;
const mon = async id => (await sys(`select * from monsters where id = $1`, [id]))[0];
const lutador = await newMon(A, 150, 12), karp = await newMon(A, 129, 10), alheio = await newMon(B, 7, 10);
const battle = async id => (await sys(`select * from battles where id = $1`, [id]))[0];
const cool = () => sys(`update treino_visitas set ult_encontro = now() - interval '1 minute'`);
async function luta(comp) {
  await sys(`update monsters set tr_hp = 100`); await cool();
  const e = await as(A, `select public.treino_encontro($1, $2) r`, [lutador, comp]);
  if (e.error) return { error: e.error };
  const bid = e.rows[0].r.battle;
  for (let i = 0; i < 60; i++) {
    const b = await battle(bid); if (b.status !== "ativa") return b.state.treino;
    const mv = b.state.sides[0].mons[0].moves.findIndex(m => m.pp > 0);
    const r = await as(A, `select * from public.battle_act($1, (select turn from battles where id = $1), 'move', $2)`, [bid, mv < 0 ? -1 : mv]);
    if (r.error) return { error: r.error };
  }
  return (await battle(bid)).state.treino;
}
await as(A, `select public.treino_entrar(10)`);

console.log("\nAcompanhante");
check("não pode ser o mesmo Pokémon que luta", /outro Pokémon seu/.test((await as(A, `select public.treino_encontro($1, $1)`, [lutador])).error || ""));
check("não pode ser Pokémon de outro jogador", /outro Pokémon seu/.test((await as(A, `select public.treino_encontro($1, $2)`, [lutador, alheio])).error || ""));
await sys(`update monsters set tr_hp = 0, tr_hurt_at = now() where id = $1`, [karp]); await cool();
check("acompanhante desmaiado não vai junto (arquivo 72)", /acompanhante .* está desmaiado/.test((await as(A, `select public.treino_encontro($1, $2)`, [lutador, karp])).error || ""));
let won = null;
for (let k = 0; k < 12 && !won; k++) {
  const x0 = (await mon(karp)).exp, t = await luta(karp);
  if (t.error) { check("luta sem erro", false, t.error); break; }
  if (t.res.won) won = { t, ganho: (await mon(karp)).exp - x0 };
}
check("o Mewtwo venceu uma luta", !!won);
if (won) {
  check(`o Magikarp (acompanhante) ganhou metade da experiência (${won.ganho} de ${won.t.res.xp})`, won.ganho === Math.max(1, Math.floor(won.t.res.xp * 0.5)) && won.t.res.comp_xp === won.ganho && won.t.res.comp_species === 129, JSON.stringify(won.t.res));
}
let solo = null;
for (let k = 0; k < 12 && !solo; k++) { const x0 = (await mon(karp)).exp, t = await luta(null); if (t.res?.won) solo = { t, ganho: (await mon(karp)).exp - x0 }; }
check("sem acompanhante, o Magikarp não ganha nada", solo && solo.ganho === 0 && solo.t.res.comp_xp === 0);
await sys(`update game_config set config = jsonb_set(config, '{treino}', (config->'treino') || '{"acompanhante_pct": 100}') where active`);
let cem = null;
for (let k = 0; k < 12 && !cem; k++) { const x0 = (await mon(karp)).exp, t = await luta(karp); if (t.res?.won) cem = { t, ganho: (await mon(karp)).exp - x0 }; }
check("o admin muda a porcentagem (100% = a mesma experiência)", cem && cem.ganho === cem.t.res.xp, JSON.stringify(cem?.t.res));
check("a novidade está no Jornal", (await sys(`select count(*)::int n from posts where title = '🎒 Acompanhante na Grama de Treino'`))[0].n === 1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
