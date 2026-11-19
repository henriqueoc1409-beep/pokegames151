// Testa o arquivo 129 (Vale do Treino com 8 estações e desempate no Top 3) com dados de TESTE, como jogadores comuns:
// as 2 estações novas existem e treinam, o config guardado ganhou as novas sem perder as antigas, o desempate
// (mesma nota: quem jogou melhor; depois o mais rápido; depois quem fez primeiro), o desempenho não foge da nota,
// o tempo não passa do treino de verdade, a chamada antiga (só a nota) continua valendo, minijogos no site, Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_vale_8.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path"; import vm from "vm";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql").sort((a, b) => parseInt(a) - parseInt(b) || a.localeCompare(b))) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
const U = n => `${n}${n}${n}${n}${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${String(n).repeat(12)}`;
const [A, B, C, D] = [U(1), U(2), U(3), U(4)];
for (const [u, n] of [[A, "ana"], [B, "beto"], [C, "caio"], [D, "duda"]]) await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]);
for (const [u, n] of [[A, "Ana"], [B, "Beto"], [C, "Caio"], [D, "Duda"]]) await as(u, `select public.create_character($1, 'mago')`, [n]);
await sys(`update seasons set started_on = current_date - 5 where id = (select max(id) from seasons)`);
const mk = async (u, sp, lv) => (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, sp, lv]))[0].id;
const atras = (id, seg) => sys(`update vale_treinos set comecou_em = now() - make_interval(secs => $2) where id = $1`, [id, seg]);
// faz um treino completo: começa, "passa" o tempo e termina com nota, desempenho e tempo
const treina = async (u, mon, est, nota, fina, ms, seg = 30) => {
  const r = (await as(u, `select public.vale_comecar($1, $2) e`, [est, mon])).rows?.[0]?.e; if (!r) return null; await atras(r.id, seg);
  const t = await as(u, `select public.vale_terminar($1, $2, $3, $4) e`, [r.id, nota, fina, ms]); return t.error ? t : t.rows[0].e;
};

console.log("\n1. As 8 estações");
const est = (await sys(`select config->'vale'->'estacoes' e from game_config where active`))[0].e;
check("o config guardado tem as 8 estações (as 6 antigas continuam)", Object.keys(est).length === 8 && est.alvo?.nome === "Estande de Pontaria" && est.frutas?.nome === "Pomar das Frutas" && est.lago?.nome === "Lago das Correntes");
const ea = (await as(A, `select public.vale_estado() s`)).rows[0].s;
check("o Vale mostra as 8 estações e um ranking para cada uma", Object.keys(ea.estacoes).length === 8 && Array.isArray(ea.ranking?.alvo) && Array.isArray(ea.ranking?.frutas));
const ma = await mk(A, 25, 10), mb = await mk(B, 4, 10), mc = await mk(C, 7, 10), md = await mk(D, 1, 10);
let r = await treina(A, ma, "alvo", 80, 80.4, 21000);
check("treina no Estande de Pontaria e ganha XP", r && !r.error && r.xp > 0, JSON.stringify(r));
r = await treina(A, ma, "frutas", 60, 60.2, 25000);
check("treina no Pomar das Frutas", r && !r.error && r.nota === 60, JSON.stringify(r));

console.log("\n2. Desempate no Top 3");
await treina(A, ma, "lago", 90, 90.2, 30000);
await treina(B, mb, "lago", 90, 93.5, 30000);   // mesma nota, jogou melhor
await treina(C, mc, "lago", 90, 90.2, 22000);   // mesma nota e desempenho da Ana, mas mais rápido
await treina(D, md, "lago", 90, 90.2, 30000);   // igual à Ana em tudo, mas fez depois
let L = (await as(D, `select public.vale_estado() s`)).rows[0].s.ranking.lago.map(x => x.nome).join(",");
check("mesma nota: Beto (jogou melhor), Caio (mais rápido), Ana (fez antes da Duda)", L === "Beto,Caio,Ana", L);
const fin = async u => (await sys(`select nota_fina, tempo_ms from vale_treinos where user_id = $1 and estacao = 'lago' order by id desc limit 1`, [u]))[0];
r = await treina(D, md, "saco", 50, 99, 9999999, 20);
let f = (await sys(`select nota_fina, tempo_ms from vale_treinos where user_id = $1 and estacao = 'saco'`, [D]))[0];
check("o desempenho não pode passar muito da nota e o tempo não passa do treino de verdade", Number(f.nota_fina) <= 90 && f.tempo_ms <= 21000, JSON.stringify(f));
r = await treina(D, md, "templo", 70, 10, 5000);
f = (await sys(`select nota_fina from vale_treinos where user_id = $1 and estacao = 'templo'`, [D]))[0];
check("desempenho muito abaixo da nota é corrigido para perto dela", Number(f.nota_fina) >= 69, JSON.stringify(f));
const q = (await as(C, `select public.vale_comecar('pista', $1) e`, [mc])).rows[0].e; await atras(q.id, 20);
r = await as(C, `select public.vale_terminar($1, 55) e`, [q.id]);
check("a chamada antiga (só a nota) continua valendo", !r.error && r.rows[0].e.nota === 55, r.error);
check("o desempenho fica igual à nota sem o número exato", Number((await sys(`select nota_fina from vale_treinos where id = $1`, [q.id]))[0].nota_fina) === 55);

console.log("\n3. Site e Jornal");
const html = fs.readFileSync(path.join(root, "deploy/index.html"), "utf8");
const i = html.indexOf("const vjTexto ="), j = html.indexOf("// arquivo 106: o salão da Liga");
let T = 0; const ctx = { sfx: () => {}, performance: { now: () => T * 1000 }, VJ: { mon: { species_id: 1 } }, rpgArt: () => null, Math };
vm.createContext(ctx); vm.runInContext(html.slice(i, j).replace("const VALE_JOGOS", "globalThis.VALE_JOGOS"), ctx);
const mulberry = a => () => { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
const jogos = ["ritmo", "combo", "memoria", "desvio", "reflexo", "folego", "alvo", "frutas"];
let tudoOk = true;
for (const tipo of jogos) { T = 0; const G = ctx.VALE_JOGOS[tipo](mulberry(3)); let n = 0; while (!G.acabou() && n < 7200) { T += 1 / 60; G.update(1 / 60); if (n % 9 === 0) { G.key(" ", true); G.key("ArrowLeft", true); G.key("ArrowLeft", false); G.tap(300, 200, true); } n++; }
  if (!G.acabou() || !isFinite(G.nota()) || G.nota() > 100) { tudoOk = false; console.log("   ", tipo, G.acabou(), G.nota()); } }
check("os 8 minijogos rodam até o fim com nota de no máximo 100", tudoOk);
check("o site tem as 2 estações novas no mapa e manda o desempate", /alvo: \[40, 4\], frutas: \[16, 14\]/.test(html) && html.includes("_fina:") && html.includes("_ms:"));
check("aviso publicado no Jornal uma vez e igual no site", (await sys(`select count(*)::int n from posts where title = '🥋 Vale do Treino: 8 estações, treinos mais difíceis e desempate'`))[0].n === 1
  && html.includes('title: "🥋 Vale do Treino: 8 estações, treinos mais difíceis e desempate"'));
console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
