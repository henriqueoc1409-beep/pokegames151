// Testa os arquivos 73 e 74 (Liga sem espera, caverna na hora) com dados de TESTE:
// o 1º no Castelo puxa todos para a Liga na hora; durante a Liga ninguém anda, mas o dia conta;
// acabou uma fase, começa a próxima na hora; a caverna abre na hora; acabou a caverna, temporada nova na hora.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_liga_rapida.mjs ..
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
const U = n => `${n}${n}${n}${n}${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${String(n).repeat(12)}`;
const P = { A: U(1), B: U(2), C: U(3), D: U(4) }, ADM = U(9);
for (const [n, u] of [...Object.entries(P), ["Adm", ADM]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: "Jog" + n })]); await as(u, `select public.create_character($1, 'mago')`, ["Jog" + n]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
await sys(`delete from characters where user_id = $1`, [ADM]);   // o admin não joga
for (const u of Object.values(P)) for (const sp of [4, 7, 1]) await sys(`select public.pk_new_monster($1, $2, 5)`, [u, sp]);
await sys(`update monsters set team_slot = sub.rn from (select id, row_number() over (partition by user_id order by id) rn from monsters) sub where monsters.id = sub.id`);
const castelo = (await sys(`select id from board_nodes where kind = 'castelo' limit 1`))[0].id;
const at = async d => (await sys(`select id from board_nodes where kind = 'normal' and dist >= $1 order by dist limit 1`, [d]))[0].id;
await sys(`update characters set node = $1, path = array[$1]::int[] where user_id = $2`, [await at(10), P.B]);
await sys(`update characters set node = $1, path = array[$1]::int[] where user_id = $2`, [await at(50), P.C]);
await sys(`update characters set node = $1, path = array[$1]::int[] where user_id = $2`, [await at(5), P.D]);
const cid = async u => (await sys(`select id from characters where user_id = $1`, [u]))[0].id;
const lg = async () => (await sys(`select * from leagues order by id desc limit 1`))[0];

console.log("\nChegou o 1º: Liga na hora");
await sys(`update characters set node = $1 where user_id = $2`, [castelo, P.A]);
const m = (await sys(`select public.check_arrival($1) m`, [await cid(P.A)]))[0].m;
let L = await lg();
check("a Liga começa na hora da chegada", L && L.status === "rodada" && /começa agora/.test(m), m);
const seeds = (await sys(`select user_id from league_players where league_id = $1 order by seed`, [L.id])).map(r => r.user_id);
check("puxa todos, pela posição no mapa (chegada, depois quem está mais perto)", JSON.stringify(seeds) === JSON.stringify([P.A, P.D, P.B, P.C]), JSON.stringify(seeds));

console.log("\nDurante a Liga o mapa fica parado");
const n0 = (await sys(`select node from characters where user_id = $1`, [P.D]))[0].node;
await sys(`update characters set bonus_steps = 8 where user_id = $1`, [P.D]);
const r = await as(P.D, `select public.move_today() m`);
const dm = (await sys(`select * from daily_moves where user_id = $1`, [P.D]))[0];
check("o desafio do dia conta, mas ninguém anda", !r.error && dm && (await sys(`select node from characters where user_id = $1`, [P.D]))[0].node === n0, r.error || JSON.stringify(dm));
check("e o aviso explica", JSON.stringify(dm?.events || "").includes("mapa fica parado"));

console.log("\nFases sem esperar o dia seguinte");
let st = L.stage;
for (const mt of await sys(`select * from league_matches where league_id = $1 and stage = $2 and status = 'ativa'`, [L.id, st])) await sys(`select public.league_decide($1, $2, false)`, [mt.id, mt.a]);
L = await lg();
check("acabou a 1ª fase, a final começa na hora (no mesmo dia)", L.stage === st + 1 && (await sys(`select count(*)::int n from league_matches where league_id = $1 and stage = $2 and status = 'ativa'`, [L.id, L.stage]))[0].n === 1, JSON.stringify([L.stage, L.status]));
const fin = (await sys(`select * from league_matches where league_id = $1 and stage = $2`, [L.id, L.stage]))[0];
await sys(`select public.league_decide($1, $2, false)`, [fin.id, fin.a]);
L = await lg();
check("o campeão entra na caverna e ela já está aberta", L.status === "caverna" && L.champion === P.A && new Date(L.cave_open_at) <= new Date(), JSON.stringify([L.status, L.cave_open_at]));
const old = (await sys(`select id from seasons order by id desc limit 1`))[0].id;

await sys(`update leagues set cave_open_at = now() + interval '20 hours' where id = $1`, [L.id]);   // caverna da regra antiga, ainda esperando
console.log("\nAcabou a caverna: temporada nova na hora");
const t = await as(P.A, `select public.league_cave_try() r`);
const s = (await sys(`select * from seasons order by id desc limit 1`))[0];
check("o campeão tenta na hora, mesmo numa caverna da regra antiga (arquivo 74)", !t.error, t.error);
check("a temporada nova já começou", s.id === old + 1 && s.status === "ativa" && (await lg()).status === "encerrada", JSON.stringify(s));
check("todos voltam à largada sem chegada marcada", (await sys(`select count(*)::int n from characters where node <> 0 or arrived_rank is not null`))[0].n === 0);
check("e já pode trocar de herói de graça", (await as(P.B, `select public.heroi_troca_estado() s`)).rows[0].s.pode === true);
check("na temporada nova o mapa anda de novo", (await sys(`select public.liga_mapa_parado() p`))[0].p === false);

console.log("\nAdmin");
const c = (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c;
check("a Liga aparece nos Ajustes do jogo", c.liga?.comeca_na_chegada === true && c.liga?.fase_por_dia === false && c.liga?.caverna_horas === 0, JSON.stringify(c.liga));
check("a novidade está no Jornal", (await sys(`select count(*)::int n from posts where title = '⚡ Liga sem espera'`))[0].n === 1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
