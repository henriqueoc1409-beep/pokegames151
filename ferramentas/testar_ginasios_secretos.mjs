// Testa o arquivo 101 (Ginásios com time secreto) com dados de TESTE, como jogadores comuns: ninguém lê o time do
// Líder (nem no game_config), só a quantidade; escolher a mesma quantidade de Pokémon seus e com vida; ordem do Líder
// sorteada e vida cheia a cada tentativa; perde quando os escolhidos caem; vence e ganha a insígnia; admin edita; Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_ginasios_secretos.mjs ..
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
const mk = async (u, sp, lv) => (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, sp, lv]))[0].id;
const cura = () => sys(`update monsters set tr_hp = 100, tr_hurt_at = null where true`);
async function luta(u, bid) {
  for (let i = 0; i < 80; i++) { const b = (await sys(`select * from battles where id = $1`, [bid]))[0]; if (b.status !== "ativa") return b;
    let r; for (const mv of [0, 1, 2, 3, -1]) { r = await as(u, `select public.battle_act($1, $2, 'move', $3)`, [bid, b.turn, mv]); if (!r.error) break; } if (r.error) return b; }
  return (await sys(`select * from battles where id = $1`, [bid]))[0];
}
const arr = ids => `{${ids.join(",")}}`;

console.log("\nTime secreto");
const cfg = (await sys(`select config c from game_config where active`))[0].c;
check("o game_config não tem mais os times dos Líderes", !cfg.rpg?.ginasios?.lideres, JSON.stringify(cfg.rpg?.ginasios));
check("jogador não lê a tabela dos Líderes", (await as(A, `select count(*)::int n from rpg_lideres`)).rows?.[0]?.n === 0 || !!(await as(A, `select count(*)::int n from rpg_lideres`)).error);
const st = (await as(A, `select public.rpg_estado() e`)).rows[0].e;
check("o estado mostra só nome, tipo e quantos (4)", st.lideres?.bosque?.n === 4 && !st.lideres.bosque.time && st.lideres.bosque.nome === "Líder Flora", JSON.stringify(st.lideres?.bosque));
const g = (await as(A, `select public.rpg_ginasio('bosque') g`)).rows[0].g;
check("o Ginásio também não mostra o time", g.lider.n === 4 && !g.lider.time && !JSON.stringify(g).includes("time"), JSON.stringify(g));

console.log("\nEscolher os Pokémon");
const fortes = []; for (let i = 0; i < 4; i++) fortes.push(await mk(A, 150, 80));
const fracos = []; for (let i = 0; i < 4; i++) fracos.push(await mk(B, 129, 5));
const alheio = await mk(B, 129, 5);
check("sem escolher, recusa", /Escolha 4/.test((await as(A, `select public.rpg_ginasio_lutar('bosque')`)).error || ""));
check("com 3, recusa", /Escolha 4/.test((await as(A, `select public.rpg_ginasio_lutar('bosque', null, $1)`, [arr(fortes.slice(0, 3))])).error || ""));
check("repetido, recusa", /Escolha 4/.test((await as(A, `select public.rpg_ginasio_lutar('bosque', null, $1)`, [arr([fortes[0], fortes[0], fortes[1], fortes[2]])])).error || ""));
check("Pokémon de outro, recusa", /só Pokémon seus/.test((await as(A, `select public.rpg_ginasio_lutar('bosque', null, $1)`, [arr([...fortes.slice(0, 3), alheio])])).error || ""));
await sys(`update monsters set tr_hp = 0, tr_hurt_at = now() where id = $1`, [fortes[3]]);
check("desmaiado, recusa", /com vida/.test((await as(A, `select public.rpg_ginasio_lutar('bosque', null, $1)`, [arr(fortes)])).error || ""));
await cura();

console.log("\nOrdem sorteada e vida cheia");
const time = (await sys(`select time from rpg_lideres where regiao = 'pico'`))[0].time;
let x = await as(B, `select public.rpg_ginasio_lutar('pico', null, $1) r`, [arr(fracos)]);
let t = (await sys(`select * from rpg_gin_tent where user_id = $1 order by id desc limit 1`, [B]))[0];
let b0 = (await sys(`select * from battles where id = $1`, [x.rows[0].r.battle]))[0];
check("a ordem do Líder é um sorteio dos 4", JSON.stringify([...t.ordem].sort()) === "[0,1,2,3]", JSON.stringify(t.ordem));
check("o primeiro Pokémon dele segue a ordem sorteada", b0.state.sides[1].mons[0].species === time[t.ordem[0]][0], JSON.stringify([b0.state.sides[1].mons[0].species, time, t.ordem]));
check("entra o primeiro que você escolheu", b0.state.sides[0].mons[0].id === fracos[0] || b0.state.treino.mon === fracos[0]);
let fim = null;
for (let k = 0; k < 8 && !fim; k++) { const bb = await luta(B, x.rows[0].r.battle); t = (await sys(`select * from rpg_gin_tent where id = $1`, [t.id]))[0]; if (t.status !== "andando") { fim = t.status; break; }
  x = await as(B, `select public.rpg_ginasio_lutar('pico') r`); if (x.rows?.[0]?.r?.fim) { fim = "perdeu"; break; } }
check("perde quando os 4 escolhidos caem", fim === "perdeu" && (await sys(`select count(*)::int n from monsters where id = any($1) and tr_hp > 0`, [arr(fracos)]))[0].n === 0, fim);
await cura();
const ordens = new Set([JSON.stringify(t.ordem)]);
x = await as(B, `select public.rpg_ginasio_lutar('pico', null, $1) r`, [arr(fracos)]);
const t2 = (await sys(`select * from rpg_gin_tent where user_id = $1 order by id desc limit 1`, [B]))[0];
check("tentativa nova: todos os Pokémon do Líder com a vida cheia", t2.id !== t.id && t2.hp.every(h => h === 100) && t2.idx === 0, JSON.stringify(t2.hp));
ordens.add(JSON.stringify(t2.ordem));
// sorteio: em 30 tentativas simuladas, aparece mais de uma ordem
const varia = (await sys(`select count(distinct o)::int n from (select (select jsonb_agg(i order by random() + g * 0) from generate_series(0, 3) i)::text o from generate_series(1, 30) g) z`))[0].n;
check("a ordem muda de uma tentativa para outra", varia > 1, varia);
await as(B, `select public.battle_act($1, 1, 'forfeit', null)`, [x.rows[0].r.battle]);

console.log("\nVencer");
await cura(); let venceu = false;
x = await as(A, `select public.rpg_ginasio_lutar('bosque', null, $1) r`, [arr(fortes)]);
for (let k = 0; k < 8 && !venceu; k++) { const bb = await luta(A, x.rows[0].r.battle); if (bb.state.treino.pos?.status === "venceu") { venceu = true; break; } await cura(); x = await as(A, `select public.rpg_ginasio_lutar('bosque') r`); if (x.error) break; }
check("vence os 4 e ganha a insígnia", venceu && (await sys(`select count(*)::int n from rpg_insignias where user_id = $1`, [A]))[0].n === 1);

console.log("\nAdmin");
check("jogador não edita o Líder", !!(await as(A, `select public.admin_rpg_lider_salvar('praia', 'X', 'mago', 'Água', '[[7, 10]]')`)).error);
const ed = await as(ADM, `select public.admin_rpg_lider_salvar('praia', 'Líder Onda', 'mago', 'Água', '[[7, 20], [8, 25], [9, 40]]') r`);
check("admin edita nome e time (3 Pokémon) e vai para a Auditoria", !ed.error && (await as(A, `select public.rpg_estado() e`)).rows[0].e.lideres.praia.n === 3 && (await sys(`select count(*)::int n from admin_audit_log where action = 'rpg_lider'`))[0].n === 1, ed.error);
check("admin não salva Pokémon inválido", !!(await as(ADM, `select public.admin_rpg_lider_salvar('praia', 'X', 'mago', '', '[[999, 20]]')`)).error);
check("aviso publicado no Jornal uma vez", (await sys(`select count(*)::int n from posts where title = '🏟️ Ginásios de verdade e o mapa com os nomes'`))[0].n === 1);
console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
