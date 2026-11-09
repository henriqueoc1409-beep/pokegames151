// Testa o arquivo 77 (nivelamento da Temporada 2) com dados de TESTE, como jogadores comuns:
// reset para o nível 5, compensação, creche e leilão cancelados, inicial, teto nas batalhas com aposta,
// Creche nova, Cabo Link e pacote de boas-vindas.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_nivelamento.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql" && f < "81").sort()) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
const A = "11111111-1111-1111-1111-111111111111", B = "22222222-2222-2222-2222-222222222222", C = "33333333-3333-3333-3333-333333333333",
  D = "44444444-4444-4444-4444-444444444444", ADM = "99999999-9999-9999-9999-999999999999";
const user = async (u, n) => { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'mago')`, [n]); };
for (const [u, n] of [[A, "Ana"], [B, "Bia"], [C, "Caio"], [ADM, "Chefe"]]) await user(u, n);
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
await sys(`update characters set coins = 10000 where true`);
const newMon = async (u, sp, lv) => (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, sp, lv]))[0].id;
const mon = async id => (await sys(`select * from monsters where id = $1`, [id]))[0];
const coins = async u => (await sys(`select coins from characters where user_id = $1`, [u]))[0].coins;

console.log("\nAntes do nivelamento");
check("o arquivo não faz o reset no banco de teste", !(await sys(`select public.cfg() ? 'nivelamento_at' x`))[0].x);
const a30 = await newMon(A, 4, 30), a12 = await newMon(A, 7, 12), a3 = await newMon(A, 1, 3), b8 = await newMon(B, 25, 8);
const movesA30 = (await mon(a30)).moves.join(",");
await sys(`update monsters set tr_hp = 0, tr_hurt_at = now(), war_hp = 40, war_hurt_at = now() where id = $1`, [a12]);
let r = await as(A, `select public.creche_treinar($1, 2) x`, [a12]);
check("Creche nova: 13×5 + 14×5 = 135", !r.error && r.rows[0].x.custo === 135, r.error);
r = await as(B, `select public.leilao_criar($1, 10) x`, [b8]);
const lid = (await sys(`select id from leiloes where mon_id = $1`, [b8]))[0]?.id;
r = await as(A, `select public.leilao_lance($1, 40)`, [lid]);
check("leilão aberto com lance da Ana", !r.error && lid, r.error);
const cA = await coins(A), cB = await coins(B), cC = await coins(C);

console.log("\nNivelamento");
const res = (await sys(`select public.nivelamento_aplicar() r`))[0].r;
check("3 Pokémon voltaram ao nível 5", res.pokemon === 3, JSON.stringify(res));
const m30 = await mon(a30);
check("o nível 30 virou 5, com o XP do nível 5", m30.level === 5 && m30.exp === (await sys(`select public.pk_exp_for(growth_rate, 5) x from pokemon where id = 4`))[0].x);
check("ataques ficam como estavam", m30.moves.join(",") === movesA30);
check("o nível 3 não muda", (await mon(a3)).level === 3);
const m12 = await mon(a12);
check("vida cheia de graça (Grama e Guerra)", m12.tr_hp === 100 && m12.war_hp === 100 && m12.tr_hurt_at === null && m12.war_hurt_at === null);
check("a creche foi cancelada e devolveu as moedas", (await sys(`select status from creche_pedidos`))[0].status === "cancelado");
check("o leilão foi cancelado", (await sys(`select status from leiloes where id = $1`, [lid]))[0].status === "cancelado");
check("Ana: compensação de 32 níveis (320) + creche (135) + lance (40)", (await coins(A)) - cA === 320 + 135 + 40, (await coins(A)) - cA);
check("Bia: 3 níveis = 30 moedas", (await coins(B)) - cB === 30, (await coins(B)) - cB);
check("Caio (sem níveis a perder): mínimo de 300", (await coins(C)) - cC === 300, (await coins(C)) - cC);
const gifts = await sys(`select user_id, coins, message from gifts order by user_id`);
check("todo mundo recebeu no Correio, com a explicação", gifts.length === 4 && gifts.every(g => /Nivelamento da Temporada 2/.test(g.message)));
const ini = await sys(`select m.user_id, m.species_id, m.level, m.team_slot from monsters m where m.caught_at > now() - interval '1 minute' and m.level = 5 and m.species_id in (1,4,7,25,133) and m.id not in ($1, $2, $3, $4)`, [a30, a3, a12, b8]);
check("todos ganharam um inicial nível 5 entre os 5 da lista", new Set(ini.map(x => x.user_id)).size === 4, JSON.stringify(ini));
check("o inicial entra na equipe se houver lugar", ini.every(x => x.team_slot !== null));
check("não roda duas vezes", (await sys(`select public.nivelamento_aplicar() r`))[0].r.ja_feito === true);

console.log("\nTeto nas batalhas valendo moedas");
check("o site lê o teto: nível 20", (await as(A, `select public.teto_estado() t`)).rows[0].t.nivel === 20);
const a50 = await newMon(A, 6, 50), b50 = await newMon(B, 9, 50);
await newMon(B, 1, 5); await newMon(B, 4, 5);
await sys(`update monsters set team_slot = null where user_id in ($1, $2)`, [A, B]);
await sys(`update monsters set team_slot = 1 where id in ($1, $2)`, [a50, b50]);
r = await as(A, `select (public.battle_challenge($1, 10)).id id`, [B]);
r = await as(B, `select (public.battle_respond($1, true)).state s`, [r.rows?.[0]?.id]);
const s = r.rows?.[0]?.s;
check("na batalha, o Pokémon nível 50 luta no nível 20", s?.sides?.[0]?.mons?.[0]?.level === 20 && s.sides[1].mons[0].level === 20, r.error || JSON.stringify(s?.sides?.[0]?.mons?.[0]?.level));
check("e com os atributos do nível 20 (o nível real fica guardado)", s?.sides?.[0]?.mons?.[0]?.real_level === 50 && s.sides[0].mons[0].maxhp < 100);
await sys(`update seasons set status = 'encerrada' where status = 'ativa'`); await sys(`insert into seasons(started_on) values (current_date)`);
check("na temporada seguinte o teto sobe para 25", (await as(A, `select public.teto_estado() t`)).rows[0].t.nivel === 25);

console.log("\nCreche nova");
await sys(`delete from creche_pedidos where true`);
const c29 = await newMon(A, 7, 29);
let c0 = await coins(A); r = await as(A, `select public.creche_treinar($1, 3) x`, [c29]);
check("acima do 30 custa ×10: 30×5 + 31×10 + 32×10 = 780", !r.error && c0 - (await coins(A)) === 780, r.error);
await as(A, `select public.creche_cancelar()`);
check("acima do 30 só 5 por semana (já usou 2)", /Acima do nível 30.*Você ainda pode usar 3/.test((await as(A, `select public.creche_treinar($1, 5)`, [await newMon(A, 7, 32)])).error || ""));
const c5 = await newMon(A, 1, 5);
check("até o 30, no máximo 10 por semana (já usou 1)", /Até o nível 30.*Você ainda pode usar 9/.test((await as(A, `select public.creche_treinar($1, 10)`, [c5])).error || ""));
check("9 níveis cabem", !(await as(A, `select public.creche_treinar($1, 9)`, [c5])).error);
const st = (await as(A, `select public.creche_estado() s`)).rows[0].s;
check("o estado mostra os dois limites", st.restante === 0 && st.restante_alto === 3 && st.preco_por_nivel_alto === 10 && st.nivel_alto === 30);

console.log("\nCabo Link");
const kad = await newMon(A, 64, 20);
check("sem Cabo Link, o Kadabra não evolui", /Cabo Link/.test((await as(A, `select public.mon_evolve($1, 65)`, [kad])).error || ""));
check("o Cabo Link está à venda na Loja Pokémon", !(await as(A, `select public.pk_buy('cabo_link', 1)`)).error);
r = await as(A, `select (public.mon_evolve($1, 65)).species_id sp`, [kad]);
check("com o Cabo Link vira Alakazam e o cabo acaba", r.rows?.[0]?.sp === 65 && (await sys(`select qty from bag_items where user_id = $1 and item = 'cabo_link'`, [A]))[0].qty === 0, r.error);
check("o Cabo Link não serve na batalha", (await sys(`select kind from pk_items where id = 'cabo_link'`))[0].kind === "evo");

console.log("\nBoas-vindas");
await user(D, "Duda");
await sys(`update game_config set config = jsonb_set(config, '{pk_start_at}', to_jsonb(now() - interval '1 minute')) where active`);
await as(D, `select public.pk_sync()`);
const dm = await sys(`select species_id, level, team_slot from monsters where user_id = $1 order by level, team_slot`, [D]);
check("jogador novo ganha 4 Pokémon: o inicial nível 5 e 3 no nível 15 (10 abaixo do teto de 25)", dm.length === 4 && dm[0].level === 5 && [1, 4, 7, 25, 133].includes(dm[0].species_id) && dm.slice(1).every(x => x.level === 15), JSON.stringify(dm));
check("todos na equipe e o aviso no Correio", dm.every(x => x.team_slot) && (await sys(`select count(*)::int n from gifts where user_id = $1`, [D]))[0].n === 1);
await as(D, `select public.pk_sync()`);
check("só uma vez", (await sys(`select count(*)::int n from monsters where user_id = $1`, [D]))[0].n === 4);
const nA = (await sys(`select count(*)::int n from monsters where user_id = $1`, [A]))[0].n;
await as(A, `select public.pk_sync()`);
check("quem já jogava não ganha o pacote", (await sys(`select count(*)::int n from monsters where user_id = $1`, [A]))[0].n === nA);

console.log("\nAdmin");
const cfg = (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c;
check("teto e boas-vindas aparecem nos Ajustes do jogo", cfg.teto?.nivel_inicial === 20 && cfg.boas_vindas?.pacote_qtd === 3 && cfg.creche?.preco_por_nivel === 5);
check("jogador comum não roda o nivelamento", !!(await as(A, `select public.nivelamento_aplicar()`)).error);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
