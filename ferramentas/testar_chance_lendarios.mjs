// Testa o arquivo 32 (chance de cada lendário na caverna da Liga) com dados de TESTE:
// sorteia 4000 coroações e confere se as chances ficam perto de 30/30/30/7/3.
// Uso (na pasta ferramentas, uma vez: npm i @electric-sql/pglite@0.3.15):  node testar_chance_lendarios.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql").sort()) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const U = "11111111-1111-1111-1111-111111111111";
await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, 'a@t.l', '{"username":"ana"}')`, [U]);
await sys(`select set_config('request.jwt.claim.sub', $1, false)`, [U]);
await sys(`select public.create_character('Ana', 'mago')`);
await sys(`select set_config('request.jwt.claim.sub', '', false)`);
const sid = (await sys(`select id from seasons order by id desc limit 1`))[0].id;
const N = 4000;
const draw = async () => {
  const c = {};
  const lg = (await sys(`insert into leagues(season_id, name, status) values ($1, 'Teste', 'rodada') returning id`, [sid]))[0].id;
  for (let i = 0; i < N; i++) {
    await sys(`update leagues set status = 'rodada' where id = $1`, [lg]);
    await sys(`select public.league_crown($1, $2)`, [lg, U]);
    const id = (await sys(`select legend_id from leagues where id = $1`, [lg]))[0].legend_id; c[id] = (c[id] || 0) + 1;
  }
  return c;
};
console.log("\nChances padrão (2ª geração desligada)");
const c = await draw();
const pct = id => 100 * (c[id] || 0) / N;
console.log("  ", Object.entries(c).map(([k, v]) => `${k}: ${(100 * v / N).toFixed(1)}%`).join("  "));
for (const [id, want, tol] of [[144, 30, 3], [145, 30, 3], [146, 30, 3], [150, 7, 1.5], [151, 3, 1]]) check(`Pokémon ${id} perto de ${want}%`, Math.abs(pct(id) - want) <= tol, pct(id));
check("nenhum outro Pokémon sai", Object.keys(c).every(k => [144, 145, 146, 150, 151].includes(+k)));
console.log("\n2ª geração ligada, sem chance para os da 2ª");
await sys(`update game_config set config = config || '{"gen2": true}' where active`);
const c2 = await draw();
check("os da 2ª não entram sem chance definida", Object.keys(c2).every(k => +k <= 151));
console.log("\nDono dá chance a um da 2ª");
await sys(`update game_config set config = jsonb_set(config, '{league_legend_pct}', '{"144":0,"145":0,"146":0,"150":0,"151":0,"249":100}') where active`);
const c3 = await draw();
check("com só Lugia em 100%, sai sempre Lugia", Object.keys(c3).join() === "249");
await sys(`update game_config set config = config || '{"gen2": false}' where active`);
const c4 = await draw();
check("Lugia com a 2ª desligada não sai; volta ao padrão", !c4[249] && Object.keys(c4).every(k => [144, 145, 146, 150, 151].includes(+k)));
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
