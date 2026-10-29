// Testa o arquivo 54 (Grama de Treino) com dados de TESTE, como jogadores comuns:
// luta automática contra selvagem de nível parecido, XP só na vitória (lento pelo limite), 60 minutos por dia (3 por luta),
// não gasta o limite de batalhas, não vai para a Arena, cada um vê só o seu, guarda só as últimas lutas.
// Roda só até o 54 (o 55 mudou a espera e o tempo de cada luta; os testes dele estão em testar_centro.mjs).
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_treino.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql" && f < "55").sort()) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
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
const charm = await newMon(A, 4, 5), bMon = await newMon(B, 7, 5);

console.log("\nComeço");
let st = (await as(A, `select public.treino_estado() s`)).rows[0].s;
check("estado: 60 minutos por dia, 3 por luta, nada usado", st.on && st.minutos_dia === 60 && st.minutos_luta === 3 && st.minutos === 0 && st.ultimas.length === 0, JSON.stringify(st));
check("não treina Pokémon de outro jogador", /Escolha um Pokémon seu/.test((await fight(A, bMon)).error || ""));

console.log("\nLutas");
let wins = 0, losses = 0, lvOk = true, xpOk = true, lossOk = true, total = 0;
for (let i = 0; i < 20; i++) {
  const before = await mon(charm), r = await fight(A, charm);
  if (r.error) { check(`luta ${i + 1} sem erro`, false, r.error); break; }
  const x = r.r, after = await mon(charm);
  if (x.wild_level < Math.max(1, before.level - 3) || x.wild_level > before.level) lvOk = false;
  if (x.won) {
    wins++; total += x.xp;
    const be = (await sys(`select base_exp from pokemon where id = $1`, [x.wild]))[0].base_exp;
    if (x.xp !== Math.max(1, Math.floor(be * x.wild_level / 7)) || after.exp - before.exp !== x.xp) xpOk = false;
  } else { losses++; if (x.xp !== 0 || after.exp !== before.exp) lossOk = false; }
  if (!x.log?.length) lvOk = false;
}
check(`20 lutas feitas (${wins} vitórias, ${losses} derrotas)`, wins + losses === 20);
check("o selvagem tem nível de 3 abaixo até o nível do seu Pokémon, e a luta tem relato", lvOk);
check(`vitória dá exp-base × nível ÷ 7 de XP (${total} no total)`, wins === 0 || xpOk);
check("derrota não dá XP e não tira nada", losses === 0 || lossOk);
st = (await as(A, `select public.treino_estado() s`)).rows[0].s;
check("o relógio marca 60 de 60 minutos e 20 lutas", st.minutos === 60 && st.lutas === 20 && st.vitorias === wins && st.xp === total, JSON.stringify({ ...st, ultimas: st.ultimas.length }));
check("a 21ª luta do dia é recusada", /tempo de treino de hoje acabou/.test((await fight(A, charm)).error || ""));
check("guarda só as 10 últimas lutas", (await sys(`select count(*)::int n from treino_lutas where user_id = $1`, [A]))[0].n === 10 && st.ultimas.length === 10);
check("a batalha do treino some no fim e não vai para a Arena", (await sys(`select (select count(*) from battles where mode = 'treino') + (select count(*) from arena_battles) n`))[0].n === 0);
check("não gasta o limite de batalhas do dia (nenhuma batalha recompensada fica)", (await sys(`select count(*)::int n from battles where rewarded`))[0].n === 0);
check("não vai para o Jornal", (await sys(`select count(*)::int n from event_log where message ilike '%selvagem%'`))[0].n === 0);

console.log("\nCada um vê só o seu");
check("Beto não vê as lutas da Ana", (await as(B, `select count(*)::int n from treino_lutas`)).rows[0].n === 0 && (await as(B, `select count(*)::int n from treino_dias`)).rows[0].n === 0);
check("Ana vê as dela", (await as(A, `select count(*)::int n from treino_lutas`)).rows[0].n === 10);
check("Beto ainda tem os 60 minutos dele", !(await fight(B, bMon)).error);
check("ninguém escreve nas tabelas do treino", !!(await as(B, `update treino_dias set minutos = 0`)).error || (await sys(`select minutos from treino_dias where user_id = $1`, [B]))[0].minutos === 3);

console.log("\nTreino lento e evolução");
const strong = await newMon(B, 147, 20);   // Dratini nível 20: precisa de muitas lutas
const ex0 = (await mon(strong)).exp;
await sys(`update game_config set config = jsonb_set(config, '{treino}', '{"minutos_dia": 600}') where active`);
let lutas = 0; while (lutas < 60) { const r = await fight(B, strong); if (r.error) break; lutas++; }
const m2 = await mon(strong);
check(`60 lutas (3 dias) não levam o Dratini do 20 ao 30 (foi para o ${m2.level}, ${lutas} lutas, +${m2.exp - ex0} XP)`, m2.level < 30 && m2.exp > ex0, JSON.stringify({ lv: m2.level, exp: m2.exp }));
check("subir de nível no treino avisa como sempre (evento de nível)", (await sys(`select count(*)::int n from mon_events where mon_id = $1 and kind = 'nivel' and data->>'source' = 'treino'`, [charm]))[0].n >= 1);
await sys(`update game_config set config = jsonb_set(config, '{treino}', '{"on": false}') where active`);
check("o admin pode fechar a Grama de Treino", /fechada/.test((await fight(B, bMon)).error || ""));
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
