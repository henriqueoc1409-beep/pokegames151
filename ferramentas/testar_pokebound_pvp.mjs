// Testa o arquivo 110 (PokeBound entre jogadores, valendo ranking) com dados de TESTE, como jogadores comuns:
// desafiar, só um convite por vez, recusar, aceitar com terreno e posições, só joga na sua vez, o servidor anda, atira,
// explode, tira vida e abre cratera, vento e recarga do especial, turno vencido pula e 3 pulos = derrota, desistir,
// pontos do ranking (quem vence ganha o que o outro perde), limites por dia, ninguém lê a tabela direto, Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_pokebound_pvp.mjs ..
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
const A = "11111111-1111-1111-1111-111111111111", B = "22222222-2222-2222-2222-222222222222", C = "33333333-3333-3333-3333-333333333333";
for (const [u, n] of [[A, "Ana"], [B, "Beto"], [C, "Caio"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'mago')`, [n]); }
const est = async (u, id) => (await as(u, `select public.pb_estado($1) e`, [id])).rows[0].e;
const quem = (e, uid) => (e.p1 === uid ? 0 : 1);

console.log("\nDesafiar");
let r = await as(A, `select public.pb_desafiar($1, 'golem') r`, [B]);
check("desafio criado", !r.error && r.rows[0].r.id, r.error);
let id = r.rows[0].r.id;
check("não desafia outro enquanto tem um desafio aberto", /em andamento/.test((await as(A, `select public.pb_desafiar($1, 'golem')`, [C])).error || ""));
check("quem foi desafiado vê o convite", (await as(B, `select public.pb_meus() m`)).rows[0].m.recebidos[0]?.nome === "Ana");
check("ninguém lê as partidas direto na tabela", !((await as(A, `select * from pb_partidas`)).rows?.length));
check("Pokémon que não existe é recusado", !!(await as(B, `select public.pb_responder($1, true, 'mewtwo')`, [id])).error);
await as(B, `select public.pb_responder($1, false)`, [id]);
check("recusar fecha o desafio", (await sys(`select status from pb_partidas where id = $1`, [id]))[0].status === "recusada");
id = (await as(A, `select public.pb_desafiar($1, 'golem') r`, [B])).rows[0].r.id;
r = await as(B, `select public.pb_responder($1, true, 'blastoise') r`, [id]);
let e = await est(A, id);
check("aceitou: partida ao vivo com terreno de 601 alturas e cada um no seu lado", !r.error && e.status === "ativa" && e.terr.length === 601 && e.jogadores[0].x < 700 && e.jogadores[1].x > 1700, r.error || JSON.stringify(e.jogadores));
check("vida de cada Pokémon pelo PokeBound (Golem 1100, Blastoise 1000)", e.jogadores[0].hp === 1100 && e.jogadores[1].hp === 1000);
check("o adversário não vê nada de fora da partida", !!(await as(C, `select public.pb_estado($1)`, [id])).error);

console.log("\nJogar");
const vez = e.vez, fora = vez === 0 ? B : A, dentro = vez === 0 ? A : B;
check("quem não é da vez não joga", /sua vez/.test((await as(fora, `select public.pb_jogar($1, 0, 1, 45, 50, false)`, [id])).error || ""));
const eu = e.jogadores[vez], alvoX = eu.x + (vez === 0 ? 400 : -400);
r = await as(dentro, `select public.pb_jogar($1, $2, $3, 45, 60, false) r`, [id, alvoX, vez === 0 ? 1 : -1]);
let e2 = r.rows?.[0].r;
check("andar é limitado pelo fôlego (até 160)", e2 && Math.abs(e2.jogadores[vez].x - eu.x) <= 160.5, r.error || JSON.stringify([eu.x, e2?.jogadores[vez].x]));
check("o servidor devolve o caminho do tiro e passa a vez", e2.ultimo.tiros[0].path.length > 5 && e2.vez === 1 - vez && e2.jogada === 1, JSON.stringify(e2.ultimo).slice(0, 200));
// tiro certeiro: procura o ângulo e a força que caem perto do outro e confere dano + cratera
async function acertar(u) {
  const s = await est(u, id), me = s.vez, P = s.jogadores[me], O = s.jogadores[1 - me], face = O.x > P.x ? 1 : -1;
  let best = null;
  for (let a = 20; a <= 80; a += 4) for (let pot = 20; pot <= 100; pot += 4) {
    const rad = (face === 1 ? a : 180 - a) * Math.PI / 180, bx = P.x + Math.cos(rad) * 58, by = P.y - 52 - Math.sin(rad) * 58;
    const q = (await sys(`select public.pb_simular($1::double precision[], $2, $3) r`, [s.terr, JSON.stringify(s.jogadores), JSON.stringify({ x: bx, y: by, ang: face === 1 ? a : 180 - a, pot, vel: { golem: 0.9, blastoise: 0.95 }[P.ch], ventoK: { golem: 1.2, blastoise: 0.7 }[P.ch], wind: s.vento })]))[0].r;
    if (!q.hit) continue; const d = Math.abs(q.hit.x - O.x); if (!best || d < best.d) best = { a, pot, d, face };
  }
  return { s, best };
}
let { s, best } = await acertar(dentro === A ? B : A);
const atirador = s.vez === quem(s, A) ? A : B, hp0 = s.jogadores[1 - s.vez].hp, terr0 = s.terr;
e2 = (await as(atirador, `select public.pb_jogar($1, $2, $3, $4, $5, false) r`, [id, s.jogadores[s.vez].x, best.face, best.a, best.pot])).rows[0].r;
check("acertou: tirou vida do outro", e2.jogadores[1 - s.vez].hp < hp0, JSON.stringify([best, hp0, e2.jogadores[1 - s.vez].hp]));
check("a explosão abriu uma cratera no chão (ou acertou o corpo em cheio)", e2.ultimo.tiros[0].hit?.direto != null || e2.terr.some((h, i) => h > terr0[i] + 5));
const s3 = await est(A, id), me3 = s3.vez, at3 = me3 === quem(s3, A) ? A : B;
await as(at3, `select public.pb_jogar($1, $2, 1, 45, 30, true)`, [id, s3.jogadores[me3].x]);
check("depois do especial, recarga de 3 turnos", (await est(A, id)).jogadores[me3].cd >= 3, JSON.stringify((await est(A, id)).jogadores[me3]));

console.log("\nTempo e fim");
let s4 = await est(A, id); const somido = s4.vez;
for (let k = 0; k < 3; k++) { await sys(`update pb_partidas set turno_fim = now() - interval '1 minute' where id = $1`, [id]); await est(A, id);
  const t = await est(A, id); if (t.status !== "ativa") break; if (t.vez !== somido) { await sys(`update pb_partidas set vez = $2 where id = $1`, [id, somido]); } }
s4 = await est(A, id);
const venc = somido === 0 ? s4.p2 : s4.p1;
check("3 turnos sem jogar = derrota", s4.status === "fim" && s4.vencedor === venc && s4.motivo === "ausente", JSON.stringify([s4.status, s4.motivo]));
const rk = (await as(C, `select * from pb_rank order by pontos desc`)).rows;
check("ranking: quem venceu ganha o que o outro perdeu (começa em 1000)", rk.length === 2 && rk[0].pontos > 1000 && rk[0].pontos + rk[1].pontos === 2000 && rk[0].user_id === venc, JSON.stringify(rk));
check("o Jornal do dia conta", (await sys(`select count(*)::int n from event_log where kind = 'pokebound'`))[0].n === 1);
check("a lista do ranking", (await as(C, `select public.pb_ranking() r`)).rows[0].r.top.length === 2);

console.log("\nDesistir e limites");
id = (await as(C, `select public.pb_desafiar($1, 'electrode') r`, [A])).rows[0].r.id;
await as(A, `select public.pb_responder($1, true, 'dragonite')`, [id]);
r = await as(C, `select public.pb_desistir($1) r`, [id]);
check("desistir é derrota", r.rows?.[0].r.status === "fim" && r.rows[0].r.motivo === "desistiu" && r.rows[0].r.vencedor === A, r.error);
await sys(`update game_config set config = jsonb_set(config, '{pokebound,pvp,mesmo_par_dia}', '1') where active`);
check("o mesmo par tem limite por dia", /já jogaram/.test((await as(A, `select public.pb_desafiar($1, 'golem')`, [C])).error || ""));
id = (await as(B, `select public.pb_desafiar($1, 'golem') r`, [C])).rows[0].r.id;
await sys(`update pb_partidas set criado = now() - interval '10 minutes' where id = $1`, [id]);
check("convite sem resposta expira", (await as(C, `select public.pb_meus() m`)).rows[0].m.recebidos.length === 0 && (await sys(`select status from pb_partidas where id = $1`, [id]))[0].status === "expirou");
await sys(`update game_config set config = jsonb_set(config, '{pokebound,pvp,on}', 'false') where active`);
check("o admin desliga o PokeBound entre jogadores", /desligado/.test((await as(B, `select public.pb_desafiar($1, 'golem')`, [C])).error || ""));
check("aparece em Ajustes do jogo", (await sys(`select public.pokebound_cfg() c`))[0].c.pvp.k === 32);
check("aviso publicado no Jornal uma vez", (await sys(`select count(*)::int n from posts where title = '💥 PokeBound entre jogadores, valendo ranking!'`))[0].n === 1);
console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
