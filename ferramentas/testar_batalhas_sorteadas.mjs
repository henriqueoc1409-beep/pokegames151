// Teste de estresse: batalhas com Pokémon, níveis e ataques sorteados entre os 165,
// para achar erros em efeitos raros. Dados de TESTE num banco local (PGlite).
// Uso (na pasta ferramentas, uma vez: npm i @electric-sql/pglite@0.3.15):  node testar_batalhas_sorteadas.mjs .. [quantas]
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2], N = +(process.argv[3] || 40);
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql")).sort()) if (f !== "14_recomecar_do_zero.sql") await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => {
  await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`);
  try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); }
};
const P = ["aaaaaaaa-0000-0000-0000-000000000001", "aaaaaaaa-0000-0000-0000-000000000002"];
for (const [i, id] of P.entries()) {
  await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [id, `p${i}@teste.local`, JSON.stringify({ username: `jogador${i}` })]);
  await as(id, `select public.create_character($1, 'mago')`, [`Jogador${i}`]);
}
const effects = new Set(), errors = [];
let turns = 0, ends = {};
for (let k = 0; k < N; k++) {
  await sys(`delete from battles`); await sys(`delete from monsters`); await sys(`update characters set coins = 1000`);   // a aposta (29) gasta moedas
  for (const id of P) {
    for (let j = 0; j < 6; j++) {
      const sp = 1 + Math.floor(Math.random() * 151), lv = 5 + Math.floor(Math.random() * 60);
      const m = (await sys(`select (public.pk_new_monster($1, $2, $3)).id`, [id, sp, lv]))[0].id;
      await sys(`update monsters set moves = (select array_agg(id) from (select id from pk_moves order by random() limit 4) x), team_slot = $2 where id = $1`, [m, j + 1]);
    }
  }
  const ch = await as(P[0], `select row_to_json(public.battle_challenge($1, 10)) b`, [P[1]]);
  if (ch.error) { errors.push("desafio: " + ch.error); break; }
  const b0 = ch.rows[0].b;
  await as(P[1], `select public.battle_respond($1, true)`, [b0.id]);
  let b, guard = 0;
  while (guard++ < 400) {
    b = (await sys(`select * from battles where id = $1`, [b0.id]))[0];
    if (b.status !== "ativa") break;
    for (const side of [0, 1]) {
      b = (await sys(`select * from battles where id = $1`, [b0.id]))[0];
      if (b.status !== "ativa" || (side === 0 ? b.ready1 : b.ready2)) continue;
      const sd = b.state.sides[side], act = sd.mons[sd.active];
      let kind = "move", val;
      if (b.phase === "troca" || sd.need_switch) { kind = "switch"; val = sd.mons.findIndex((m, i) => i !== sd.active && m.hp > 0); }
      else {
        const ok = act.moves.map((m, i) => [m, i]).filter(([m]) => m.pp > 0);
        val = ok.length ? ok[Math.floor(Math.random() * ok.length)][1] : -1;
        if (val >= 0) effects.add(act.moves[val].id);
      }
      const r = await as(P[side], `select public.battle_act($1, $2, $3, $4)`, [b.id, b.turn, kind, val]);
      if (r.error) { errors.push(`${r.error} (ação ${kind} ${val}, fase ${b.phase})`); guard = 999; break; }
    }
  }
  b = (await sys(`select * from battles where id = $1`, [b0.id]))[0];
  turns += b.turn; ends[b.end_reason || b.status] = (ends[b.end_reason || b.status] || 0) + 1;
  const bad = b.log.flatMap(t => t.lines.map(l => l.txt)).filter(t => /undefined|null|NaN/.test(t));
  if (bad.length) errors.push("texto estranho: " + bad[0]);
  if (b.status === "ativa") errors.push(`batalha ${k} não terminou em 400 rodadas`);
}
console.log(`${N} batalhas, ${turns} turnos no total, finais: ${JSON.stringify(ends)}; ${effects.size} ataques diferentes usados.`);
console.log(errors.length ? "ERROS:\n" + [...new Set(errors)].slice(0, 20).join("\n") : "Nenhum erro.");
process.exit(errors.length ? 1 : 0);
