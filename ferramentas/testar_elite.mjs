// Testa o arquivo 106 (2 Ginásios novos e a Elite 4) com dados de TESTE, como jogadores comuns: 8 Líderes e 20 áreas,
// encontro nas rotas novas, a Liga só com as 8 insígnias, escolher de 1 a 6 Pokémon, os 5 em sequência, a vida da Liga
// não volta (nem curando), todos desmaiados = perdeu, fugir = desistir, 1 tentativa por dia, Hall da Fama e prêmio
// (grande só na 1ª vez), times secretos, admin edita com Auditoria, Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_elite.mjs ..
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
const A = "11111111-1111-1111-1111-111111111111", B = "22222222-2222-2222-2222-222222222222", ADM = "99999999-9999-9999-9999-999999999999";
for (const [u, n] of [[A, "Ana"], [B, "Beto"], [ADM, "Chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'guerreiro')`, [n]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
await sys(`update monsters set team_slot = null where true`);
const mk = async (u, sp, lv) => (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, sp, lv]))[0].id;
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;
const run = async u => (await sys(`select * from rpg_elite_run where user_id = $1 order by id desc limit 1`, [u]))[0];
async function luta(u, bid) {
  for (let i = 0; i < 80; i++) { const b = (await sys(`select * from battles where id = $1`, [bid]))[0]; if (b.status !== "ativa") return b;
    const mv = b.state.sides[0].mons[b.state.sides[0].active].moves, pw = await sys(`select id, coalesce(power, 0) p from pk_moves where id = any($1::int[])`, [mv.map(x => x.id)]);
    const ord = mv.map((x, i) => [i, (pw.find(q => q.id === x.id)?.p || 0) * (x.pp > 0 ? 1 : 0)]).sort((a, c) => c[1] - a[1]).map(x => x[0]);
    let r; for (const k of [...ord, -1]) { r = await as(u, `select public.battle_act($1, $2, 'move', $3)`, [bid, b.turn, k]); if (!r.error) break; } if (r.error) return b; }
  return (await sys(`select * from battles where id = $1`, [bid]))[0];
}

console.log("\nRotas e Ginásios novos");
const cfg = (await sys(`select config c from game_config where active`))[0].c;
check("20 áreas (vila + 8 rotas × 2), com as 4 novas", Object.keys(cfg.rpg.zonas).length === 20 && cfg.rpg.zonas.estrada_fundo?.max === 70 && cfg.rpg.zonas.vulcao?.regiao === "vulcao", JSON.stringify(Object.keys(cfg.rpg.zonas)));
const est = (await as(A, `select public.rpg_estado() e`)).rows[0].e;
check("8 Líderes, os novos sem o time", Object.keys(est.lideres).length === 8 && est.lideres.vulcao?.n === 5 && est.lideres.estrada?.n === 6 && !("time" in est.lideres.estrada), JSON.stringify(est.lideres.estrada));
const forte = await mk(A, 59, 100);
await sys(`update rpg_dias set ult = null where true`);
let r = await as(A, `select public.rpg_encontro($1, 'estrada_fundo') r`, [forte]);
const w = r.rows && (await sys(`select state from battles where id = $1`, [r.rows[0].r.battle]))[0].state.sides[1].mons[0];
check("encontro no desfiladeiro da Estrada (nível 58 a 70)", w && w.level >= 58 && w.level <= 70, r.error || w?.level);
await sys(`delete from battles where p1 = $1`, [A]);
check("o Ginásio do Vulcão abre", !(await as(A, `select public.rpg_ginasio('vulcao')`)).error);

console.log("\nEntrar na Liga");
const L = (await as(A, `select public.rpg_elite() e`)).rows[0].e;
check("a Liga tem 5 (Elite 4 + Campeão) e o time é segredo", L.membros.length === 5 && L.membros[4].n === 6 && !JSON.stringify(L.membros).includes("time"), JSON.stringify(L.membros[0]));
check("jogador não lê os times direto na tabela", !((await as(A, `select * from rpg_elite`)).rows?.length));
check("sem as 8 insígnias não entra", /8 insígnias/.test((await as(A, `select public.rpg_elite_lutar(null, array[$1]::uuid[])`, [forte])).error || ""));
for (const u of [A, B]) await sys(`insert into rpg_insignias(user_id, regiao) select $1, regiao from rpg_lideres on conflict do nothing`, [u]);
check("precisa escolher os Pokémon", /de 1 a 6/.test((await as(A, `select public.rpg_elite_lutar()`)).error || ""));
const mons = []; for (let i = 0; i < 7; i++) mons.push(await mk(A, 129, 5));
check("no máximo 6", /de 1 a 6/.test((await as(A, `select public.rpg_elite_lutar(null, $1::uuid[])`, [mons])).error || ""));
await sys(`update monsters set tr_hp = 0, tr_hurt_at = now() where id = $1`, [mons[0]]);
check("desmaiado não entra", /com vida/.test((await as(A, `select public.rpg_elite_lutar(null, array[$1, $2]::uuid[])`, [forte, mons[0]])).error || ""));
check("Pokémon de outro jogador não entra", !!(await as(B, `select public.rpg_elite_lutar(null, array[$1]::uuid[])`, [forte])).error);

console.log("\nOs 5 em sequência (times pequenos pelo admin para o teste)");
check("jogador não edita a Liga", !!(await as(A, `select public.admin_rpg_elite()`)).error);
for (let k = 1; k <= 5; k++) await as(ADM, `select public.admin_rpg_elite_salvar($1, $2, 'mago', 'teste', $3)`, [k, "Treinador " + k, JSON.stringify(k === 5 ? [[129, 2], [129, 2]] : [[129, 2]])]);
check("admin salva e fica na Auditoria", (await sys(`select count(*)::int n from admin_audit_log where action = 'rpg_elite'`))[0].n === 5);
const c0 = await coins(A), d0 = (await sys(`select coalesce((select qty from equip_doces where user_id = $1), 0) q`, [A]))[0].q;
let etapas = [], b;
for (let i = 0; i < 12; i++) {
  r = await as(A, `select public.rpg_elite_lutar(null, array[$1]::uuid[]) r`, [forte]);
  if (r.error || r.rows[0].r.fim) break;
  b = await luta(A, r.rows[0].r.battle); etapas.push(b.state.treino.pos?.etapa);
  if (b.state.treino.pos?.status !== "andando") break;
}
const er = await run(A);
check("venceu os 5 em sequência, um atrás do outro", er.status === "venceu" && er.etapa === 5 && JSON.stringify(etapas) === "[1,2,3,4,4,5]", JSON.stringify([er.status, etapas, r.error]));
const hall = (await as(B, `select * from rpg_campeoes`)).rows;
check("entrou no Hall da Fama (todos veem)", hall.length === 1 && hall[0].user_id === A && hall[0].vezes === 1);
const ganhou = (await coins(A)) - c0, doces = (await sys(`select qty q from equip_doces where user_id = $1`, [A]))[0].q - d0;
check("prêmio grande na 1ª vez (5000 moedas e 5 Doces de Forja)", ganhou >= 5000 && doces === 5, JSON.stringify([ganhou, doces]));
check("o Jornal do dia conta", (await sys(`select count(*)::int n from event_log where kind = 'elite' and message like '%Hall da Fama%'`))[0].n === 1);
check("só uma tentativa por dia", /hoje/.test((await as(A, `select public.rpg_elite_lutar(null, array[$1]::uuid[])`, [forte])).error || ""));
await sys(`update rpg_elite_run set dia = dia - 1 where user_id = $1`, [A]);
const c1 = await coins(A);
for (let i = 0; i < 12; i++) { r = await as(A, `select public.rpg_elite_lutar(null, array[$1]::uuid[]) r`, [forte]); if (r.error || r.rows[0].r.fim) break; b = await luta(A, r.rows[0].r.battle); if (b.state.treino.pos?.status !== "andando") break; }
check("vencer de novo dá o prêmio menor (1000)", (await run(A)).status === "venceu" && (await coins(A)) - c1 >= 1000 && (await coins(A)) - c1 < 5000 && (await sys(`select vezes from rpg_campeoes where user_id = $1`, [A]))[0].vezes === 2);
const e2 = (await as(A, `select public.rpg_estado() e`)).rows[0].e;
check("o estado da Aventura mostra a coroa", e2.elite?.campeao === 2 && e2.campeoes.includes(A));

console.log("\nA vida não volta");
const b1 = await mk(B, 59, 100), b2 = await mk(B, 59, 100);
await as(ADM, `select public.admin_rpg_elite_salvar(1, 'Treinador 1', 'mago', 'teste', '[[129, 2], [129, 2], [129, 2]]')`);
r = await as(B, `select public.rpg_elite_lutar(null, array[$1, $2]::uuid[]) r`, [b1, b2]);
b = await luta(B, r.rows[0].r.battle);
await sys(`update rpg_elite_run set vida = jsonb_set(vida, array[$2], '37') where user_id = $1 and status = 'andando'`, [B, b1]);
await sys(`update monsters set tr_hp = 100, tr_hurt_at = null where user_id = $1`, [B]);   // como se curasse no Centro
r = await as(B, `select public.rpg_elite_lutar() r`);
b = (await sys(`select * from battles where id = $1`, [r.rows[0].r.battle]))[0];
const me = b.state.sides[0].mons[0], pct = Math.round(me.hp * 100 / me.maxhp);
check("curar no Centro não muda a vida da Liga (entra com 37%)", Math.abs(pct - 37) <= 1 && b.state.sides[0].mons[0].hp < b.state.sides[0].mons[0].maxhp, pct);
check("o inimigo continua de onde parou (2º Pokémon do treinador)", b.state.treino.elite_idx === 1, b.state.treino.elite_idx);
const c2 = await coins(B);
await as(B, `select public.battle_act($1, $2, 'forfeit', null)`, [b.id, b.turn]);
check("fugir na Liga é desistir (e não cobra moedas)", (await run(B)).status === "perdeu" && (await coins(B)) === c2, JSON.stringify([(await run(B)).status, c2, await coins(B)]));
await sys(`update rpg_elite_run set dia = dia - 1 where user_id = $1`, [B]);
r = await as(B, `select public.rpg_elite_lutar(null, array[$1]::uuid[]) r`, [b2]);
await sys(`delete from battles where p1 = $1`, [B]);
await sys(`update rpg_elite_run set vida = jsonb_set(vida, array[$2], '0') where user_id = $1 and status = 'andando'`, [B, b2]);
r = await as(B, `select public.rpg_elite_lutar() r`);
check("todos desmaiados: a tentativa acaba", r.rows?.[0].r.fim === "perdeu" && (await run(B)).status === "perdeu", r.error || JSON.stringify(r.rows?.[0]));
await sys(`update rpg_elite_run set dia = dia - 1 where user_id = $1`, [B]);
r = await as(B, `select public.rpg_elite_lutar(null, array[$1]::uuid[]) r`, [b2]); await sys(`delete from battles where p1 = $1`, [B]);
check("desistir pelo botão", !(await as(B, `select public.rpg_elite_desistir()`)).error && (await run(B)).status === "perdeu");
check("aparece em Ajustes do jogo", (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c.rpg?.elite?.insignias_min === 8);
check("aviso publicado no Jornal uma vez", (await sys(`select count(*)::int n from posts where title = '🏛️ Aventura: 2 Ginásios novos e a Elite 4'`))[0].n === 1);
console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
