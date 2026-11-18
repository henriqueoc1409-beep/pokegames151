// Testa o arquivo 114 (troca de Pokémon entre jogadores) com dados de TESTE, como jogadores comuns: propor com moedas (ficam guardadas),
// resumo para os dois, aceitar troca os donos (nível, XP, ataques e roupas), taxa de 5% (Ladino 2%, Mercador 0%), sem moedas sem taxa,
// Haunter evolui com a troca, trava de 7 dias, 3 trocas por semana, quem não pode ser trocado (Creche, esquadrão, suporte, Leilão,
// Ginásio, Desafio do Planalto), recusar/cancelar/vencer devolvem as moedas, só quem recebeu responde, Acontecimentos, Ajustes e Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_trocas.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql" && parseInt(f) < 125).sort((a, b) => parseInt(a) - parseInt(b) || a.localeCompare(b))) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec(`reset role;`); } };
const A = "11111111-1111-1111-1111-111111111111", B = "22222222-2222-2222-2222-222222222222", C = "33333333-3333-3333-3333-333333333333", D = "44444444-4444-4444-4444-444444444444", ADM = "99999999-9999-9999-9999-999999999999";
for (const [u, n, h] of [[A, "Ana", "guerreiro"], [B, "Beto", "ladino"], [C, "Cris", "guerreiro"], [D, "Duda", "mercador"], [ADM, "Chefe", "guerreiro"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, $2)`, [n, h]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
await sys(`update characters set coins = 1000 where true`);
const mk = async (u, sp, lv) => (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, sp, lv]))[0].id;
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;
const mon = async id => (await sys(`select * from monsters where id = $1`, [id]))[0];
const propor = (u, para, md, mp, cd = 0, cp = 0) => as(u, `select public.troca_propor($1, $2, $3, $4, $5) r`, [para, md, mp, cd, cp]);
const responder = (u, id, s) => as(u, `select public.troca_responder($1, $2) r`, [id, s]);

console.log("\nPropor e aceitar (com moedas e a evolução do Haunter)");
const haunter = await mk(A, 93, 30), pidgey = await mk(B, 16, 12);
await sys(`update monsters set outfit = '{"pk_chapeu": "x"}'::jsonb where id = $1`, [haunter]);
const h0 = await mon(haunter);
let r = await propor(A, B, haunter, pidgey, 100, 0);
const t1 = r.rows?.[0]?.r?.id;
check("propor: as moedas oferecidas ficam guardadas", !!t1 && await coins(A) === 900, r.error);
const mB = (await as(B, `select public.troca_minhas() m`)).rows[0].m;
const pB = mB.propostas.find(p => p.id === t1);
check("quem recebe vê o resumo: Pokémon, nível, ataques e moedas de cada lado", pB && pB.mon_de.species === 93 && pB.mon_de.level === 30 && pB.mon_de.moves.length > 0 && pB.mon_para.species === 16 && pB.moedas_de === 100 && pB.moedas_para === 0, JSON.stringify(pB));
check("Cris não responde a proposta dos outros", /não encontrada/.test((await responder(C, t1, true)).error || ""));
check("Cris não lê as trocas dos outros", (await as(C, `select count(*)::int n from trocas`)).rows[0].n === 0);
r = await responder(B, t1, true);
const hd = await mon(haunter), pg = await mon(pidgey);
check("aceitou: os donos trocaram", !r.error && hd.user_id === B && pg.user_id === A, r.error);
check("o Haunter evoluiu para Gengar com a troca", hd.species_id === 94 && r.rows[0].r.evoluiu?.de?.para === 94, JSON.stringify(r.rows?.[0]?.r));
check("foi com nível, XP, ataques e roupas", hd.level === h0.level && +hd.exp === +h0.exp && hd.moves.length >= 1 && hd.outfit?.pk_chapeu === "x" && hd.team_slot === null);
check("Beto (Ladino) recebeu as 100 moedas menos 2% de taxa", await coins(B) === 1000 + 98, await coins(B));
check("o Gengar entrou na Pokédex de quem recebeu", (await sys(`select count(*)::int n from pokedex_entries where user_id = $1 and species_id = 94 and caught_at is not null`, [B]))[0].n === 1);
check("a troca está nos Acontecimentos", (await sys(`select count(*)::int n from event_log where kind = 'troca' and message like '%trocou Haunter com Beto por Pidgey%'`))[0].n === 1);
check("trava de 7 dias: o Pidgey que chegou não pode ser trocado de novo", /chegou por troca/.test((await propor(A, C, pidgey, await mk(C, 19, 5))).error || ""));
await sys(`update monsters set troca_em = now() - interval '8 days' where id = $1`, [pidgey]);
check("depois de 7 dias pode", !(await propor(A, C, pidgey, await mk(C, 19, 5))).error);
await sys(`update trocas set status = 'cancelada' where status = 'pendente'`);

console.log("\nTaxa");
const a2 = await mk(A, 10, 5), c2 = await mk(C, 13, 5);
let c0 = await coins(C), a0 = await coins(A);
r = await propor(A, C, a2, c2, 200, 0); r = await responder(C, r.rows[0].r.id, true);
check("taxa padrão: Cris recebeu 200 menos 5%", await coins(C) === c0 + 190 && await coins(A) === a0 - 200, r.error || [await coins(C), c0]);
const a3 = await mk(A, 10, 5), d3 = await mk(D, 13, 5);
let d0 = await coins(D); a0 = await coins(A);
r = await propor(A, D, a3, d3, 0, 50); r = await responder(D, r.rows[0].r.id, true);
check("quem pede moedas: Duda pagou 50 e Ana recebeu 50 menos 5%", await coins(D) === d0 - 50 && await coins(A) === a0 + 48, r.error || [await coins(D), d0, await coins(A), a0]);
const d4 = await mk(D, 13, 5), b4 = await mk(B, 10, 5);
d0 = await coins(D);
r = await propor(B, D, b4, d4, 100, 0); const tm = r.rows?.[0]?.r?.id; r = await responder(D, tm, true);
check("Mercador não paga taxa", await coins(D) === d0 + 100, r.error);
const b5 = await mk(B, 10, 5), c5 = await mk(C, 13, 5);
r = await propor(B, C, b5, c5); r = await responder(C, r.rows[0].r.id, true);
const t5 = (await sys(`select * from trocas order by id desc limit 1`))[0];
check("troca sem moedas, sem taxa", !r.error && t5.taxa_de === 0 && t5.taxa_para === 0 && t5.status === "aceita", r.error);

console.log("\nLimite da semana");
check("Ana já fez 3 trocas: a 4ª proposta é recusada", /3 trocas esta semana/.test((await propor(A, C, await mk(A, 10, 5), await mk(C, 13, 5))).error || ""), (await sys(`select public.troca_semana($1) n`, [A]))[0].n);
check("e ninguém propõe para quem já fez 3", /já fez as 3 trocas/.test((await propor(D, A, await mk(D, 10, 5), await mk(A, 13, 5))).error || ""));

console.log("\nQuem não pode ser trocado");
const E = "55555555-5555-5555-5555-555555555555", F = "66666666-6666-6666-6666-666666666666";
for (const [u, n] of [[E, "Eva"], [F, "Fred"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'guerreiro')`, [n]); }
await sys(`update characters set coins = 1000 where user_id in ($1, $2)`, [E, F]);
const fm = await mk(F, 13, 5);
const tenta = async id => (await propor(E, F, id, fm)).error || "";
const e1 = await mk(E, 10, 5); await sys(`insert into creche_pedidos(user_id, mon_id, species, level_from, niveis, horas) values ($1, $2, 10, 5, 1, 12)`, [E, e1]);
check("na Creche, não", /Creche/.test(await tenta(e1)));
const e2 = await mk(E, 10, 5); await sys(`insert into war_squads(user_id, role, slot, monster_id) values ($1, 'ataque', 1, $2)`, [E, e2]);
check("num esquadrão de guerra, não", /esquadrão/.test(await tenta(e2)));
const e3 = await mk(E, 10, 5); await as(E, `select public.rpg_suporte_set($1)`, [e3]);
check("o suporte da Aventura (guardado no servidor), não", /suporte/.test(await tenta(e3)));
const e4 = await mk(E, 10, 5); await sys(`insert into leiloes(seller, mon_id, species, level, min_price, ends_at) values ($1, $2, 10, 5, 10, now() + interval '1 day')`, [E, e4]).catch(async () => { await as(E, `select public.leilao_criar($1, 10)`, [e4]); });
check("no Leilão, não", /Leilão/.test(await tenta(e4)));
const g = []; for (let i = 0; i < 4; i++) g.push(await mk(E, 150, 70));
r = await as(E, `select public.rpg_ginasio_lutar('bosque', null, $1) r`, [`{${g.join(",")}}`]);
check("numa batalha de Ginásio em andamento, não", /Ginásio/.test(await tenta(g[0])), r.error);
const e6 = await mk(E, 10, 5);
await sys(`insert into rpg_elite_run(user_id, dia, meus, vida, hp) values ($1, public.game_today(), $2::jsonb, '{}'::jsonb, '[100]'::jsonb)`, [E, JSON.stringify([e6])]);
check("no Desafio do Planalto em andamento, não", /Desafio do Planalto/.test(await tenta(e6)));
const livre = await mk(E, 10, 5);
const col = (await as(E, `select public.troca_colecao($1) c`, [E])).rows[0].c;
check("a coleção para a troca mostra o motivo de quem não pode", col.find(x => x.id === e1)?.motivo?.includes("Creche") && col.find(x => x.id === livre) && !col.find(x => x.id === livre).motivo, JSON.stringify(col.map(x => x.motivo)));
check("Pokémon de outra pessoa, não", /não é/.test((await propor(E, F, fm, fm)).error || ""));

console.log("\nRecusar, cancelar, vencer");
const e7 = await mk(E, 10, 5), e8 = await mk(E, 10, 5), e9 = await mk(E, 10, 5);
let ce = await coins(E);
r = await propor(E, F, e7, fm, 50); const tr1 = r.rows[0].r.id;
check("Fred recusa: as moedas voltam para Eva", !(await responder(F, tr1, false)).error && await coins(E) === ce && (await sys(`select status from trocas where id = $1`, [tr1]))[0].status === "recusada");
r = await propor(E, F, e8, fm, 30); const tr2 = r.rows[0].r.id;
check("Eva cancela: as moedas voltam", !(await as(E, `select public.troca_cancelar($1)`, [tr2])).error && await coins(E) === ce);
r = await propor(E, F, e9, fm, 40); const tr3 = r.rows[0].r.id;
await sys(`update trocas set expira_em = now() - interval '1 minute' where id = $1`, [tr3]);
const mE = (await as(E, `select public.troca_minhas() m`)).rows[0].m;
check("depois de 24 horas a proposta vence e as moedas voltam", await coins(E) === ce && (await sys(`select status from trocas where id = $1`, [tr3]))[0].status === "expirou" && !mE.propostas.some(p => p.id === tr3));
await sys(`update characters set coins = 5 where user_id = $1`, [F]);
r = await propor(E, F, e9, fm, 0, 100);
check("sem moedas para pagar o que a proposta pede, não aceita", /pede 100 moedas/.test((await responder(F, r.rows[0].r.id, true)).error || ""));

console.log("\nO resto");
check("jogador não chama as funções internas", !!(await as(A, `select public.troca_passa($1, $2, $3)`, [fm, F, A])).error && !!(await as(A, `select public.troca_evolui($1)`, [fm])).error);
const aj = (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c;
check("Ajustes do jogo: as trocas", aj.troca?.taxa_pct === 5 && aj.troca?.semana_max === 3 && aj.troca?.trava_dias === 7 && aj.troca?.expira_horas === 24, JSON.stringify(aj.troca));
check("Jornal: a novidade foi publicada", (await sys(`select count(*)::int n from posts where title = '🔁 Troca de Pokémon entre jogadores'`))[0].n === 1);

console.log(`\n${ok} OK, ${fail} falharam`);
process.exit(fail ? 1 : 0);
