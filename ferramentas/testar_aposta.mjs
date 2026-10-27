// Testa o arquivo 29 (aposta obrigatória nas batalhas Pokémon 3x3) com dados de TESTE, como jogadores comuns.
// Uso (na pasta ferramentas, uma vez: npm i @electric-sql/pglite@0.3.15):  node testar_aposta.mjs ..
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
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
const ANA = "11111111-1111-1111-1111-111111111111", BETO = "22222222-2222-2222-2222-222222222222", CAIO = "33333333-3333-3333-3333-333333333333";
for (const [id, n] of [[ANA, "ana"], [BETO, "beto"], [CAIO, "caio"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1,$2,$3)`, [id, n + "@t.l", JSON.stringify({ username: n })]); await as(id, `select public.create_character($1,'mago')`, [n[0].toUpperCase() + n.slice(1)]); }
for (const u of [ANA, BETO, CAIO]) for (let j = 1; j <= 3; j++) { const m = (await sys(`select (public.pk_new_monster($1, $2, 20)).id`, [u, [1, 4, 7][j - 1]]))[0].id; await sys(`update monsters set team_slot = $2 where id = $1`, [m, j]); }
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;
const setc = (u, c) => sys(`update characters set coins = $2 where user_id = $1`, [u, c]);
const total = async () => (await sys(`select sum(coins)::int s from characters`))[0].s;

console.log("\nDesafio com aposta");
await setc(ANA, 500); await setc(BETO, 500); await setc(CAIO, 30);
let r = await as(ANA, `select public.battle_challenge($1)`, [BETO]); check("desafio sem valor é recusado (aposta obrigatória)", /aposta/.test(r.error || ""), r.error);
r = await as(ANA, `select public.battle_challenge($1, 5)`, [BETO]); check("abaixo do mínimo (10) é recusado", /de 10 a 100/.test(r.error || ""), r.error);
r = await as(ANA, `select public.battle_challenge($1, 101)`, [BETO]); check("acima do máximo (100) é recusado", /de 10 a 100/.test(r.error || ""), r.error);
r = await as(CAIO, `select public.battle_challenge($1, 50)`, [ANA]); check("quem não tem o valor não desafia", /não tem 50/.test(r.error || ""), r.error);
r = await as(ANA, `select public.battle_challenge($1, 50)`, [CAIO]); check("não dá para apostar mais do que o adversário tem", /só tem 30/.test(r.error || ""), r.error);
let b1 = (await as(ANA, `select (public.battle_challenge($1, 50)).id`, [BETO])).rows[0].id;
// desde o arquivo 30, a parte de quem desafia já sai ao desafiar (e volta se recusar ou cancelar)
check("desafio de 50 enviado: só a parte de quem desafia sai agora", await coins(ANA) === 450 && await coins(BETO) === 500);
r = await as(BETO, `select public.battle_respond($1, false)`, [b1]); check("recusar não custa nada", !r.error && await coins(ANA) === 500 && await coins(BETO) === 500, r.error);
b1 = (await as(ANA, `select (public.battle_challenge($1, 50)).id`, [BETO])).rows[0].id;
await setc(BETO, 40);
r = await as(BETO, `select public.battle_respond($1, true)`, [b1]); check("sem o valor na hora de aceitar, não aceita", /aposta é de 50/.test(r.error || ""), r.error);
await setc(BETO, 500);
const t0 = await total() + 50;   // + as 50 da Ana já reservadas na batalha
r = await as(BETO, `select public.battle_respond($1, true)`, [b1]); check("aceitou: 50 saem de cada um e ficam guardados", !r.error && await coins(ANA) === 450 && await coins(BETO) === 450, r.error);
check("a Arena mostra quanto está em jogo", (await as(CAIO, `select bet from arena_battles where battle_id = $1`, [b1])).rows?.[0]?.bet === 50);
r = await as(ANA, `update battles set bet = 1 where id = '${b1}'`); check("ninguém muda a aposta direto na tabela", !!r.error || (await sys(`select bet from battles where id = $1`, [b1]))[0].bet === 50);

console.log("\nFim da batalha");
r = await as(BETO, `select public.battle_act($1, 1, 'forfeit', null)`, [b1]); check("Beto desiste", !r.error, r.error);
check("quem vence leva tudo (100)", await coins(ANA) === 550 && await coins(BETO) === 450, `${await coins(ANA)} / ${await coins(BETO)}`);
check("nenhuma moeda criada ou perdida", await total() === t0, `${t0} -> ${await total()}`);
await sys(`select public.bt_finish($1, $2, 'nocaute')`, [b1, ANA]);
check("pagamento acontece uma vez só", await coins(ANA) === 550);
check("o Jornal conta quanto levou", (await sys(`select 1 from event_log where message like '%venceu a batalha Pokémon contra Beto e levou 100 moedas!%'`)).length === 1);
const b2 = (await as(BETO, `select (public.battle_challenge($1, 30)).id`, [ANA])).rows[0].id;
await as(ANA, `select public.battle_respond($1, true)`, [b2]);
check("segunda batalha: 30 de cada um", await coins(ANA) === 520 && await coins(BETO) === 420);
await sys(`select public.bt_finish($1, null, 'empate')`, [b2]);
check("empate devolve a parte de cada um", await coins(ANA) === 550 && await coins(BETO) === 450, `${await coins(ANA)} / ${await coins(BETO)}`);
const b3 = (await as(ANA, `select (public.battle_challenge($1, 20)).id`, [BETO])).rows[0].id;
r = await as(ANA, `select public.battle_cancel($1)`, [b3]); check("cancelar o convite não custa nada", !r.error && await coins(ANA) === 550, r.error);
check("guerras continuam sem aposta", (await sys(`select column_default from information_schema.columns where table_name = 'battles' and column_name = 'bet'`))[0].column_default === "0");
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
