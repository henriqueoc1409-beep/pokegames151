// Testa o arquivo 82 (a vila ajuda em tudo no jogo) com dados de TESTE, como jogadores comuns.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_vila_bonus.mjs ..
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
for (const [u, n] of [[A, "Ana"], [B, "Bia"], [ADM, "Chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'mago')`, [n]); await as(u, `select public.village_state()`); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
await sys(`update characters set coins = 5000 where true`);
// Ana com a vila cheia; Bia sem nada
await sys(`update villages set center_level = 3, orchard_level = 1, tavern_level = 1, watch_level = 2, academy_level = 1, arena_level = 1, wcenter_level = 2,
  well_level = 1, dtower_level = 1, wall_level = 2, mine_level = 3, vault_level = 2, mud = 2 where user_id = $1`, [A]);
const vb = async (u, b, f) => +(await sys(`select public.vb($1, $2, $3) v`, [u, b, f]))[0].v;
const fdef = async sig => (await sys(`select pg_get_functiondef($1::regprocedure) d`, [sig]))[0].d;

console.log("\nNúmeros");
check("Centro nv 3 = +1 casa; Bia sem vila = 0", (await vb(A, "centro", "casas")) === 1 && (await vb(B, "centro", "casas")) === 0);
check("Torre de Vigia nv 2 = 25%; Cofre nv 2 = 2 pontos; Mina nv 3 = 15%", (await vb(A, "vigia", "raro_pct")) === 25 && (await vb(A, "cofre", "taxa_menos")) === 2 && (await vb(A, "mina", "salario_pct")) === 15);
await sys(`update villages set damaged = jsonb_build_object('pomar', jsonb_build_object('at', now())) where user_id = $1`, [A]);
check("construção danificada não dá bônus", (await vb(A, "pomar", "captura_pct")) === 0);
await sys(`update villages set damaged = '{}'::jsonb where user_id = $1`, [A]);
check("Pomar = +10% de captura (e entra na conta da captura)", (await vb(A, "pomar", "captura_pct")) === 10 && /'pomar', 'captura_pct'/.test(await fdef("public.encounter_throw(uuid,text)")));
check("Estábulo: casas extras a cada 2 dias", (await sys(`select public.cfg()->>'stable_days' d`))[0].d === "2");

console.log("\nAndar");
const ma = await as(A, `select public.move_today() r`), mb = await as(B, `select public.move_today() r`);
const evA = ma.rows?.[0]?.r?.events || [], evB = mb.rows?.[0]?.r?.events || [];
check("Ana anda +1 casa pelo Centro da Vila (e vê o aviso)", evA.some(e => e.t === "vila" && /\+1 casa/.test(e.msg)), ma.error || JSON.stringify(evA));
check("Bia não ganha nada", !mb.error && !evB.some(e => e.t === "vila"), mb.error);

console.log("\nEncontros");
await sys(`update game_config set config = jsonb_set(jsonb_set(config, '{pk_start_at}', to_jsonb(now() - interval '1 day')), '{vila_bonus,vigia,raro_pct}', '[100, 100, 100]'::jsonb) where active`);
for (let i = 1; i <= 4; i++) await sys(`insert into daily_moves(user_id, move_date, modes, base_steps, roll, bonus_steps, from_node, to_node, xp_gained, coins_gained)
  values ($1, public.game_today() - $2::int, '{}', 0, 1, 0, 0, 5, 0, 0) on conflict do nothing`, [A, i]);
await as(A, `select public.pk_sync()`);
const enc = await sys(`select e.throws_left, p.catch_rate from encounters e join pokemon p on p.id = e.species_id where e.user_id = $1`, [A]);
check("Taverna: 4 bolas por encontro (3 + 1)", enc.length >= 4 && enc.every(e => e.throws_left === 4), JSON.stringify(enc));
check("Torre de Vigia (no teste em 100%): nenhum Pokémon comum", enc.length >= 4 && enc.every(e => e.catch_rate < 190), JSON.stringify(enc));

console.log("\nGrama, Centro e Creche");
const tr = (await as(A, `select public.treino_estado() s`)).rows[0].s, trB = (await as(B, `select public.treino_estado() s`)).rows[0].s;
check("Arena: +10 minutos na Grama", tr.minutos_dia === trB.minutos_dia + 10 && tr.vila_min === 10, JSON.stringify([tr.minutos_dia, trB.minutos_dia]));
check("Academia: +XP na Grama (na conta da luta)", (await vb(A, "academia", "grama_xp_pct")) === 10 && /'academia', 'grama_xp_pct'/.test(await fdef("public.treino_after(uuid)")));
const ch = async u => +(await sys(`select public.cura_horas($1) h`, [u]))[0].h, cp = async u => +(await sys(`select public.centro_preco_de($1, 20, 0) p`, [u]))[0].p;
check("Centro Pokémon de Guerra nv 2: cura grátis 20% mais rápida", (await ch(A)) === Math.ceil((await ch(B)) * 0.8), JSON.stringify([await ch(A), await ch(B)]));
check("e Centro Pokémon 20% mais barato", (await cp(A)) === Math.max(1, Math.ceil((await cp(B)) * 0.8)), JSON.stringify([await cp(A), await cp(B)]));
check("Poço: Creche 10% mais barata", +(await sys(`select public.creche_desc($1) d`, [A]))[0].d === 10 && +(await sys(`select public.creche_desc($1) d`, [B]))[0].d === 0);
check("Torre de Defesa: +dano contra a Rocket (na conta do ataque)", (await vb(A, "defesa", "rocket_dano_pct")) === 10 && /Equipe Rocket/.test(await fdef("public.bt_use_move(jsonb,integer,integer,boolean,integer)")));

console.log("\nLama, salário e taxas");
const st = (await as(A, `select public.village_state() s`)).rows[0].s;
check("Muralha nv 2: limpar a lama 60% mais barato (2 × 50 = 100 → 40)", st.clean_cost === 40, st.clean_cost);
let c0 = (await sys(`select coins from characters where user_id = $1`, [A]))[0].coins, r = await as(A, `select public.village_clean()`);
check("e a limpeza cobra esse preço", !r.error && c0 - (await sys(`select coins from characters where user_id = $1`, [A]))[0].coins === 40, r.error);
const pay = (await sys(`select a.id from board_nodes a where a.kind = 'pagamento' and exists (select 1 from board_nodes b where b.next_a = a.id) order by a.id limit 1`))[0].id;
const prev = (await sys(`select id from board_nodes where next_a = $1 order by id limit 1`, [pay]))[0].id;
await sys(`update characters set node = $1, level = 5, route = '{}'::jsonb where user_id in ($2, $3)`, [prev, A, B]);
const sal = async u => (await sys(`select public.walk(id, 1) w from characters where user_id = $1`, [u]))[0].w.salary;
const sA = await sal(A), sB = await sal(B);
check("Mina nv 3: salário 15% maior no Dia de Pagamento (somado aos 15% da Taverna)", sB > 0 && sA === Math.ceil(Math.ceil(sB * 1.15) * 1.15), JSON.stringify([sA, sB]));
check("Cofre nv 2: taxa do Leilão 2 pontos menor (5 → 3)", +(await sys(`select public.leilao_taxa_de($1) t`, [A]))[0].t === 3 && +(await sys(`select public.leilao_taxa_de($1) t`, [B]))[0].t === 5);
check("e do Mercado (na conta da venda)", /'cofre', 'taxa_menos'/.test(await fdef("public.market_buy(uuid)")));

console.log("\nAdmin");
const cfg = (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c;
check("os bônus aparecem nos Ajustes do jogo", cfg.vila_bonus?.centro?.casas?.length === 6);
r = await as(ADM, `select public.admin_set_config($1::jsonb, 'teste')`, [JSON.stringify({ vila_bonus: { ...cfg.vila_bonus, on: false } })]);
check("o admin desliga tudo de uma vez", !r.error && (await vb(A, "centro", "casas")) === 0, r.error);
check("o aviso sai no Jornal", (await sys(`select count(*)::int n from posts where title = '🏰 A vila agora ajuda em tudo no jogo!'`))[0].n === 1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
