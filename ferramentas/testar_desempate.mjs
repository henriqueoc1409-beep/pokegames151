// Testa o arquivo 23 (desempate do duelo de quiz pelo tempo de cada um) com dados de TESTE.
// Uso (na pasta ferramentas, uma vez: npm i @electric-sql/pglite@0.3.15):  node testar_desempate.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql")).sort()) if (f !== "14_recomecar_do_zero.sql") await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
const ANA = "11111111-1111-1111-1111-111111111111", BETO = "22222222-2222-2222-2222-222222222222";
for (const [id, n] of [[ANA, "ana"], [BETO, "beto"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1,$2,$3)`, [id, n + "@t.l", JSON.stringify({ username: n })]); await as(id, `select public.create_character($1,'mago')`, [n[0].toUpperCase() + n.slice(1)]); }
await sys(`insert into pokemon_media(pokemon_id, silhouette) select id, 'x' from pokemon where id <= 10 on conflict (pokemon_id) do update set silhouette = 'x'`);
await sys(`update characters set coins = 500`);

// joga um duelo: cada um abre, erra 1 vez e acerta (2 tentativas para os dois = empate em tentativas)
const envelhecer = () => sys(`update duels set created_at = created_at - interval '2 days', accepted_at = accepted_at - interval '2 days'`); // limite de 1 desafio por dia
async function duelo(segAna, segBeto, abrirAnaPrimeiro = true) {
  await envelhecer();
  const r = await as(ANA, `select public.create_duel($1, 'quiz', 'moedas', 10) as id`, [BETO]);
  if (r.error) throw new Error(r.error);
  const id = r.rows[0].id;
  let x = await as(BETO, `select public.accept_duel($1)`, [id]); if (x.error) throw new Error(x.error);
  const pid = (await sys(`select pokemon_id from duels where id = $1`, [id]))[0].pokemon_id, wrong = pid === 1 ? 2 : 1;
  const jogar = async (uid, seg) => {
    await as(uid, `select public.duel_state($1)`, [id]);
    // finge que a pessoa levou "seg" segundos: puxa a hora de início para trás
    const col = uid === ANA ? "c_started_at" : "o_started_at";
    await sys(`update duels set ${col} = now() - make_interval(secs => $2) where id = $1`, [id, seg]);
    await as(uid, `select public.duel_guess($1, $2)`, [id, wrong]);
    return as(uid, `select public.duel_guess($1, $2)`, [id, pid]);
  };
  if (abrirAnaPrimeiro) { await jogar(ANA, segAna); await jogar(BETO, segBeto); } else { await jogar(BETO, segBeto); await jogar(ANA, segAna); }
  return (await sys(`select * from duels where id = $1`, [id]))[0];
}
console.log("\nDesempate pelo tempo de cada um");
let d = await duelo(300, 20, true);
check("Ana jogou primeiro (5 min), Beto depois (20 s): Beto vence", d.status === "concluido" && d.winner === BETO, JSON.stringify({ w: d.winner, st: d.status, r: d.result }));
d = await duelo(15, 200, false);
check("Beto jogou primeiro (200 s), Ana depois (15 s): Ana vence", d.winner === ANA, JSON.stringify({ w: d.winner }));
const ds = (await as(ANA, `select public.duel_state($1) s`, [d.id])).rows[0].s;
check("a tela mostra o tempo dos dois no fim", Math.round(ds.my_seconds) === 15 && Math.round(ds.other_seconds) === 200, JSON.stringify([ds.my_seconds, ds.other_seconds]));
console.log("\nRegra antiga continua valendo para duelos sem hora de início");
await envelhecer();
const r = await as(ANA, `select public.create_duel($1, 'quiz', 'moedas', 10) as id`, [BETO]); const id = r.rows[0].id;
await as(BETO, `select public.accept_duel($1)`, [id]);
const pid = (await sys(`select pokemon_id from duels where id = $1`, [id]))[0].pokemon_id;
await as(ANA, `select public.duel_guess($1, $2)`, [id, pid]);
await as(BETO, `select public.duel_guess($1, $2)`, [id, pid]);
d = (await sys(`select * from duels where id = $1`, [id]))[0];
check("sem abrir a tela (sem cronômetro): vence quem terminou antes", d.winner === ANA, JSON.stringify({ w: d.winner }));
const r2 = await as(ANA, `select public.resolve_duel($1)`, [id]); check("jogador não chama o desempate direto", !!r2.error);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
