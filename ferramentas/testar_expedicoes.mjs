// Testa o arquivo 111 (Expedições: Mina Esquecida) com dados de TESTE, como jogadores comuns: lista sem os segredos do
// roteiro, começar, só uma por vez, escolhas com custo, caminhos diferentes, consequências (marcas mudam o que aparece),
// opções que pedem golpe (Força), luta pela batalha da Aventura e volta à expedição, captura pelo encounter_throw de sempre,
// energia acabando, voltar mais cedo, expiração (perde a mochila), entrega UMA vez, Diário e conquistas, limite por dia,
// tabelas fechadas para o site, admin edita o roteiro com conferência, Ajustes e Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_expedicoes.mjs ..
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
const mk = async (u, sp, lv, slot) => { const id = (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, sp, lv]))[0].id; if (slot) await sys(`update monsters set team_slot = $2 where id = $1`, [id, slot]); return id; };
const forteA = await mk(A, 59, 100, 1), forteB = await mk(B, 59, 100, 1);
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;
const estado = async u => (await as(u, `select public.exp_estado() e`)).rows[0].e;
async function luta(u, bid) {
  for (let i = 0; i < 80; i++) { const b = (await sys(`select * from battles where id = $1`, [bid]))[0]; if (!b || b.status !== "ativa") return b;
    const mv = b.state.sides[0].mons[0].moves, pw = await sys(`select id, coalesce(power, 0) p from pk_moves where id = any($1::int[])`, [mv.map(x => x.id)]);
    const ord = mv.map((x, k) => [k, (pw.find(q => q.id === x.id)?.p || 0) * (x.pp > 0 ? 1 : 0)]).sort((a, c) => c[1] - a[1]).map(x => x[0]);
    let r; for (const k of [...ord, -1]) { r = await as(u, `select public.battle_act($1, $2, 'move', $3)`, [bid, b.turn, k]); if (!r.error) break; } if (r.error) return b; }
}
// joga uma expedição inteira escolhendo ao acaso (entre as opções que dá para escolher), lutando quando precisar
async function jogar(u, cam) {
  let s = await estado(u), passos = 0, lutas = 0;
  while (s.run && passos < 30) {
    passos++;
    const r = s.run; if (r.status === "batalha") { await luta(u, r.batalha); lutas++; await sys(`update monsters set tr_hp = 100 where user_id = $1`, [u]); s = await estado(u); continue; }
    const ops = r.evento.opcoes.filter(o => o.ok); const o = (r.etapa === 1 && cam) ? ops.find(x => x.id === cam) : ops[Math.floor(Math.random() * ops.length)];
    const x = await as(u, `select public.exp_escolher($1, $2) e`, [r.id, o.id]);
    if (x.error) return { erro: x.error };
    s = x.rows[0].e;
  }
  return { fim: s.ultimo_fim, lutas, passos };
}

console.log("\nComeçar");
const L = (await as(A, `select public.exp_lista() l`)).rows[0].l;
check("a lista mostra a Mina Esquecida, sem os eventos nem as chances", L.cenarios.length === 1 && L.cenarios[0].nome === "Mina Esquecida" && !JSON.stringify(L).includes("resultados") && !JSON.stringify(L).includes("peso"), JSON.stringify(L).slice(0, 200));
check("o site não lê os roteiros nem as expedições direto", !((await as(A, `select * from exp_cenarios`)).rows?.length) && !((await as(A, `select * from exp_runs`)).rows?.length));
let r = await as(A, `select public.exp_iniciar('mina') e`);
let s = r.rows?.[0].e;
check("começa na etapa 1 com os 3 caminhos, energia 5 e luz 3", s?.run?.etapa === 1 && s.run.evento.opcoes.length === 3 && s.run.recursos.energia === 5 && s.run.recursos.luz === 3, r.error || JSON.stringify(s?.run?.evento));
check("o acontecimento não mostra os resultados nem os pesos", !JSON.stringify(s.run.evento).includes("resultados") && !JSON.stringify(s.run.evento).includes("peso"));
check("só uma expedição por vez", /em andamento/.test((await as(A, `select public.exp_iniciar('mina')`)).error || ""));
check("escolha que não existe é recusada", !!(await as(A, `select public.exp_escolher($1, 'voar')`, [s.run.id])).error);
check("outro jogador não mexe na sua expedição", !!(await as(B, `select public.exp_escolher($1, 'tunel')`, [s.run.id])).error);
r = await as(A, `select public.exp_escolher($1, 'cristais') e`, [s.run.id]); s = r.rows[0].e;
check("a passagem dos cristais custa 1 de luz e leva à etapa 2", s.run.etapa === 2 && s.run.recursos.luz === 2 && s.run.caminho === "cristais", JSON.stringify(s.run.recursos));
check("o acontecimento da etapa 2 é do caminho escolhido (ou dos que valem para todos)", ["cristais_azuis", "minerador", "bloqueio", "escuro"].includes(s.run.evento.id), s.run.evento.id);
check("o resultado da escolha aparece na tela", !!s.run.ultimo?.txt);

console.log("\nSair e voltar");
check("a expedição continua salva (sair e voltar)", (await estado(A)).run?.id === s.run.id && (await estado(A)).run.etapa === 2);

console.log("\nConsequências e golpes");
const run = (await sys(`select * from exp_runs where id = $1`, [s.run.id]))[0];
const ev = (await sys(`select x.v e from exp_cenarios c, jsonb_array_elements(c.def->'eventos') x(v) where c.id = 'mina' and x.v->>'id' = 'corda'`))[0].e;
const pub = async () => (await sys(`select public.exp_evento_pub($1, (select r from exp_runs r where id = $2), $3) p`, [A, run.id, JSON.stringify(ev)]))[0].p;
let forca = (await pub()).opcoes.find(o => o.id === "golpe_forca");
check("sem Força na equipe, a opção aparece trancada com o motivo", forca && !forca.ok && /Força|Strength/i.test(forca.motivo), JSON.stringify(forca));
await sys(`update monsters set moves = array[70] || moves[1:3] where id = $1`, [forteA]);
forca = (await pub()).opcoes.find(o => o.id === "golpe_forca");
check("com um Pokémon que sabe Força, a opção libera", forca.ok);
const cands = await sys(`select array_agg(x.v->>'id') ids from exp_cenarios c, jsonb_array_elements(c.def->'eventos') x(v) where c.id = 'mina' and x.v->'etapa' @> '4' and x.v ? 'flags_req'`);
check("na etapa 4 há acontecimentos que só existem por causa do que você fez antes", cands[0].ids.length >= 3);
// força a etapa 4 com a marca "porta_aberta": a sala selada tem que poder aparecer
let viu = false;
for (let k = 0; k < 12 && !viu; k++) { await sys(`update exp_runs set etapa = 4, flags = array['porta_aberta'], usados = '{}' where id = $1`, [run.id]); await sys(`select public.exp_sortear($1)`, [run.id]); viu = (await sys(`select evento_id from exp_runs where id = $1`, [run.id]))[0].evento_id === "sala_secreta"; }
check("a porta aberta antes leva à sala selada", viu);

console.log("\nLuta e captura");
await sys(`update exp_runs set etapa = 2, flags = array['cristais'], evento_id = null, usados = '{}' where id = $1`, [run.id]);
const bid = (await sys(`select public.exp_batalha($1, '{"especies": [74], "delta": [-50, -50], "captura": true, "se_venceu": {"moedas": [10, 10]}, "se_perdeu": {"energia": -1}}') b`, [run.id]))[0].b;
s = await estado(A);
check("a luta é uma batalha da Aventura e a expedição espera", s.run.status === "batalha" && s.run.batalha === bid);
check("durante a luta não dá para escolher", /luta/.test((await as(A, `select public.exp_escolher($1, 'x')`, [run.id])).error || ""));
await luta(A, bid);
s = await estado(A);
check("venceu: volta para a expedição, na etapa seguinte, com o prêmio na mochila", s.run?.status === "andando" && s.run.etapa === 3 && s.run.mochila.moedas >= 10 && s.run.ultimo?.venceu === true, JSON.stringify([s.run?.status, s.run?.etapa, s.run?.mochila]));
check("o Pokémon vencido pode ser capturado com a captura de sempre", s.run.encontro?.species_id === 74 && s.run.encontro.status === "aberto");
const cap = await as(A, `select public.encounter_throw($1, 'poke') t`, [s.run.encontro.id]);
check("encounter_throw funciona no encontro da expedição", !cap.error, cap.error);
check("o Pokémon avistado vai para a mochila (e depois para o Diário)", s.run.mochila.avistados.includes("74"));

console.log("\nEntrega uma vez só");
let c0 = await coins(A), m0 = (await sys(`select mochila from exp_runs where id = $1`, [run.id]))[0].mochila.moedas;
r = await as(A, `select public.exp_recuar($1) e`, [run.id]);
const fimR = (await sys(`select * from exp_runs where id = $1`, [run.id]))[0];
check("voltar mais cedo entrega a mochila", fimR.status === "recuou" && (await coins(A)) >= c0 + m0 && fimR.entregue_em, JSON.stringify([fimR.status, c0, m0, await coins(A)]));
const c1 = await coins(A);
await sys(`select public.exp_finalizar($1, 'concluida')`, [run.id]);
check("chamar a entrega de novo não paga duas vezes", (await coins(A)) === c1);

console.log("\nExpedições inteiras");
const caminhos = new Set(); let concl = 0, lutasT = 0, erro = null;
for (let k = 0; k < 2; k++) {
  await sys(`update exp_runs set dia = dia - 1 where dono = $1`, [A]);
  const cam = ["tunel", "poco"][k]; await as(A, `select public.exp_iniciar('mina')`);
  const j = await jogar(A, cam); if (j.erro) { erro = j.erro; break; }
  caminhos.add(j.fim?.caminho); lutasT += j.lutas; if (["concluida", "exausta"].includes(j.fim?.status)) concl++;
}
check("expedições do começo ao fim, por caminhos diferentes", !erro && concl === 2 && caminhos.size === 2, erro || JSON.stringify([...caminhos]));
const dia = (await as(A, `select public.exp_diario_ver() d`)).rows[0].d[0];
check("o Diário guarda caminhos, relíquias (as que faltam aparecem como ???) e histórico", dia.caminhos.length >= 2 && dia.reliquias.some(x => x.nome === "???" || x.achou) && dia.historico.length >= 3, JSON.stringify(dia).slice(0, 300));
const tem1 = dia.conquistas.find(x => x.id === "primeira_descida")?.tem;
check("a conquista da primeira descida (se terminou a mina)", tem1 === (dia.concluidas > 0), JSON.stringify([tem1, dia.concluidas]));
const cq = (await sys(`select count(*)::int n from exp_diario where user_id = $1 and tipo = 'conquista'`, [A]))[0].n;
await sys(`update exp_runs set dia = dia - 1 where dono = $1`, [A]); await as(A, `select public.exp_iniciar('mina')`); await jogar(A, "cristais");
check("conquista não se repete", (await sys(`select count(*)::int n from exp_diario where user_id = $1 and tipo = 'conquista' and chave = 'mina:primeira_descida'`, [A]))[0].n <= 1 && (await sys(`select count(*)::int n from exp_diario where user_id = $1 and tipo = 'conquista'`, [A]))[0].n >= cq);

console.log("\nEnergia, expiração e limites");
s = (await as(B, `select public.exp_iniciar('mina') e`)).rows[0].e;
await as(B, `select public.exp_escolher($1, 'tunel')`, [s.run.id]);
await sys(`update exp_runs set recursos = '{"energia": 0, "luz": 0}', etapa = 2, mochila = jsonb_set(mochila, '{moedas}', '40') where id = $1`, [s.run.id]);
s = await estado(B); const op = s.run.evento.opcoes.find(o => o.ok);
const cB = await coins(B);
s = (await as(B, `select public.exp_escolher($1, $2) e`, [s.run.id, op.id])).rows[0].e;
if (s.run?.status === "batalha") { await luta(B, s.run.batalha); s = await estado(B); }
check("sem energia, a expedição acaba e entrega o que tinha na mochila", s.ultimo_fim?.status === "exausta" && s.ultimo_fim.resultado.entregue && (await coins(B)) - cB === s.ultimo_fim.resultado.moedas && s.ultimo_fim.resultado.moedas > 0, JSON.stringify([s.run?.status, s.ultimo_fim?.status, s.ultimo_fim?.resultado?.moedas]));
await sys(`update exp_runs set dia = dia - 1 where dono = $1`, [B]);
s = (await as(B, `select public.exp_iniciar('mina') e`)).rows[0].e;
await sys(`update exp_runs set mochila = jsonb_set(mochila, '{moedas}', '500'), expira = now() - interval '1 minute' where id = $1`, [s.run.id]);
const cE = await coins(B); s = await estado(B);
check("expirou: acaba e a mochila se perde", !s.run && s.ultimo_fim.status === "expirou" && (await coins(B)) === cE);
for (let k = 0; k < 2; k++) { await as(B, `select public.exp_iniciar('mina')`); const rid = (await sys(`select id from exp_runs where dono = $1 and status = 'andando'`, [B]))[0].id; await as(B, `select public.exp_recuar($1)`, [rid]); }
check("limite de expedições por dia", /hoje/.test((await as(B, `select public.exp_iniciar('mina')`)).error || ""));

console.log("\nAdmin");
check("jogador não vê nem edita os roteiros", !!(await as(A, `select public.admin_exp_cenarios()`)).error && !!(await as(A, `select public.admin_exp_cenario_salvar('x', '{}', true)`)).error);
const novo = { nome: "Teste", etapas: 1, recursos: { energia: 3, luz: 1 }, eventos: [{ id: "a", etapa: [1], opcoes: [{ id: "b", txt: "ir", resultados: [{ peso: 1, txt: "ok", efeitos: { moedas: [5, 5] } }] }] }] };
check("admin salva um roteiro novo (expedição nova sem programar)", !(await as(ADM, `select public.admin_exp_cenario_salvar('teste', $1, true)`, [JSON.stringify(novo)])).error && (await as(A, `select public.exp_lista() l`)).rows[0].l.cenarios.length === 2);
check("roteiro sem acontecimento para uma etapa é recusado", /etapa 2/.test((await as(ADM, `select public.admin_exp_cenario_salvar('teste2', $1, true)`, [JSON.stringify({ ...novo, etapas: 2 })])).error || ""));
check("fica na Auditoria", (await sys(`select count(*)::int n from admin_audit_log where action = 'exp_cenario'`))[0].n === 1);
await sys(`update game_config set config = jsonb_set(config, '{exp,on}', 'false') where active`);
await sys(`update exp_runs set dia = dia - 1 where dono = $1`, [A]);
check("o admin fecha as Expedições", /fechadas/.test((await as(A, `select public.exp_iniciar('mina')`)).error || ""));
check("aparece em Ajustes do jogo", (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c.exp?.limite_dia === 3);
check("aviso publicado no Jornal uma vez", (await sys(`select count(*)::int n from posts where title = '⛏️ Expedições: a Mina Esquecida'`))[0].n === 1);
console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
