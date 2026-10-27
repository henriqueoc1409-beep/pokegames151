// Testa o arquivo 21 (preços em PIX controlados pelo admin) com dados de TESTE.
// Uso (na pasta ferramentas, uma vez: npm i @electric-sql/pglite@0.3.15):  node testar_pix.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql")).sort()) if (f !== "14_recomecar_do_zero.sql") await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
const ADM = "99999999-9999-9999-9999-999999999999", ANA = "11111111-1111-1111-1111-111111111111";
for (const [id, n] of [[ADM, "chefe"], [ANA, "ana"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1,$2,$3)`, [id, n + "@t.l", JSON.stringify({ username: n })]); await as(id, `select public.create_character($1,'mago')`, [n === "ana" ? "Ana" : "Chefe"]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
await sys(`update characters set coins = 5000, level = 10 where user_id = $1`, [ANA]);
const me = async () => (await sys(`select coins, hints, retries, owned_items from characters where user_id = $1`, [ANA]))[0];

console.log("\nSem o 19 e o 20");
check("o 21 roda sozinho (tabelas do Caixa, ofertas e mural existem)", (await sys(`select count(*)::int n from pg_tables where tablename in ('donations','pix_offers','contributions')`))[0].n === 3);
let r;

console.log("\nAdmin muda preços dos itens");
r = await as(ANA, `select public.admin_set_item_prices('pk_cartola', 10, 2, true)`); check("jogador comum não muda preço", /administrador/.test(r.error || ""), r.error);
r = await as(ANA, `update shop_items set price = 0 where id = 'pk_cartola'`); check("ninguém muda preço pelo navegador", !!r.error);
r = await as(ADM, `select row_to_json(public.admin_set_item_prices('pk_coroa', 300, 2, false)) i`); check("admin: Coroa (roupa de Pokémon) só por PIX, R$ 2", !r.error && r.rows[0].i.coins_ok === false, r.error);
r = await as(ANA, `select public.pk_cosmetic_buy('pk_coroa')`); check("Coroa não sai por moedas", /só sai por PIX/.test(r.error || ""), r.error);
r = await as(ADM, `select row_to_json(public.admin_set_item_prices('pk_coroa', 500, 3.5, true)) i`); check("admin: Coroa por 500 moedas OU R$ 3,50", !r.error && r.rows[0].i.coins_ok === true && +r.rows[0].i.price_brl === 3.5, r.error);
r = await as(ANA, `select public.pk_cosmetic_buy('pk_coroa')`); check("agora a Ana compra a Coroa com moedas", !r.error && (await me()).coins === 4500, r.error);
r = await as(ADM, `select public.admin_set_item_prices('chapeu_palha', 80, 1.99, false)`); check("admin: item do herói só por PIX (R$ 1,99)", !r.error, r.error);
r = await as(ANA, `select public.buy_item('chapeu_palha')`); check("loja do herói recusa comprar com moedas", /só sai por PIX/.test(r.error || ""), r.error);
r = await as(ADM, `select public.admin_set_item_prices('chapeu_palha', 80, null, false)`); check("não deixa 'só PIX' sem preço em PIX", /precisa ter preço em PIX/.test(r.error || ""), r.error);
r = await as(ADM, `select public.admin_set_item_prices('chapeu_palha', -1, null, true)`); check("preço negativo é recusado", !!r.error);
r = await as(ADM, `select public.admin_set_item_prices('chapeu_palha', 80, null, true)`); check("admin tira o PIX e volta a vender por moedas", !r.error && (await sys(`select price_brl from shop_items where id = 'chapeu_palha'`))[0].price_brl === null, r.error);

console.log("\nOfertas extras (eventos)");
r = await as(ANA, `select public.admin_save_pix_offer(null, 'moedas', null, 1000, 'Pacote 1000 moedas', 5, true, null)`); check("jogador comum não cria oferta", /administrador/.test(r.error || ""), r.error);
r = await as(ADM, `select public.admin_save_pix_offer(null, 'bolsa', 'master_ball', 1, 'x', 5, true, null)`); check("bola inexistente é recusada", /bola ou pedra/.test(r.error || ""), r.error);
const o1 = (await as(ADM, `select (public.admin_save_pix_offer(null, 'moedas', null, 1000, 'Pacote 1000 moedas', 5, true, now() + interval '7 days')).id`)).rows[0].id;
const o2 = (await as(ADM, `select (public.admin_save_pix_offer(null, 'bolsa', 'ultra_ball', 10, '10 Ultra Balls', 4, true, null)).id`)).rows[0].id;
const o3 = (await as(ADM, `select (public.admin_save_pix_offer(null, 'dica', null, 5, '5 dicas', 2, true, null)).id`)).rows[0].id;
const o4 = (await as(ADM, `select (public.admin_save_pix_offer(null, 'outra_vez', null, 3, '3 tente outra vez', 2, true, null)).id`)).rows[0].id;
check("admin cria 4 ofertas (moedas, Ultra Balls, dicas, outra vez)", o1 && o2 && o3 && o4);
r = await as(ADM, `select row_to_json(public.admin_save_pix_offer($1, 'moedas', null, 1500, 'Pacote 1500 moedas (evento!)', 5, true, null)) o`, [o1]); check("admin muda a oferta (evento)", !r.error && r.rows[0].o.qty === 1500, r.error);
r = await as(ANA, `select count(*)::int n from pix_offers`); check("jogador vê as ofertas", r.rows?.[0]?.n === 4, JSON.stringify(r));
r = await as(ANA, `insert into pix_offers(kind, qty, name, price_brl) values ('moedas', 999999, 'x', 1)`); check("ninguém cria oferta pelo navegador", !!r.error);

console.log("\nDoação entrega tudo");
const before = await me();
r = await as(ADM, `select row_to_json(public.admin_add_donation($1, 13, 'Valeu, Ana!', '{chapeu_palha}', $2)) d`, [ANA, [o1, o2, o3, o4, o2]]);
check("admin registra R$ 13 com 1 item e 5 ofertas", !r.error, r.error);
const after = await me(), ub = (await sys(`select qty from bag_items where user_id = $1 and item = 'ultra_ball'`, [ANA]))[0]?.qty;
check("+1500 moedas", after.coins === before.coins + 1500, JSON.stringify([before.coins, after.coins]));
check("+20 Ultra Balls (a oferta veio 2 vezes)", ub === 20, ub);
check("+5 dicas e +3 tente outra vez", after.hints === before.hints + 5 && after.retries === before.retries + 3);
check("ganhou o chapéu", after.owned_items.includes("chapeu_palha"));
check("o mural guarda as ofertas entregues", (await sys(`select jsonb_array_length(extras) n from donations order by id desc limit 1`))[0].n === 5);
r = await as(ADM, `select public.admin_add_donation($1, 5, '', '{}', '{99999}')`, [ANA]); check("oferta inexistente é recusada", /inexistente/.test(r.error || ""), r.error);
r = await as(ADM, `select public.admin_delete_pix_offer($1)`, [o4]); check("admin apaga oferta", !r.error && (await sys(`select count(*)::int n from pix_offers`))[0].n === 3, r.error);
await as(ANA, `select public.donation_thanks_seen()`);
check("agradecimento marcado como visto", (await sys(`select bool_and(thanked) t from donations where user_id = $1`, [ANA]))[0].t === true);
const did = (await sys(`select id from donations order by id limit 1`))[0].id;
r = await as(ANA, `select public.admin_delete_donation($1)`, [did]); check("jogador comum não apaga doação", !!r.error);
r = await as(ADM, `select public.admin_delete_donation($1)`, [did]); check("admin apaga doação lançada errado", !r.error, r.error);

console.log("\nMural de contribuições");
r = await as(ANA, `select public.admin_set_contribution($1, 'eu mesma', 0)`, [ANA]); check("jogador comum não escreve no mural", /administrador/.test(r.error || ""), r.error);
r = await as(ADM, `select public.admin_set_contribution($1, 'Desenhou as roupas do evento e testou as batalhas.', 1)`, [ANA]); check("admin escreve a contribuição da Ana", !r.error, r.error);
r = await as(ADM, `select public.admin_set_contribution($1, 'Texto novo.', 2)`, [ANA]); check("admin edita (não duplica)", !r.error && (await sys(`select count(*)::int n from contributions`))[0].n === 1, r.error);
r = await as(ANA, `select text from contributions`); check("todos leem o mural", r.rows?.[0]?.text === "Texto novo.", JSON.stringify(r));
r = await as(ANA, `insert into contributions(user_id, text) values ('${ANA}', 'x')`); check("ninguém grava no mural pelo navegador", !!r.error);
r = await as(ADM, `select public.admin_set_contribution($1, '', 0)`, [ANA]); check("texto vazio apaga do mural", !r.error && (await sys(`select count(*)::int n from contributions`))[0].n === 0, r.error);
check("tudo ficou na auditoria", (await sys(`select count(*)::int n from admin_audit_log where action in ('preco_item','oferta_pix','oferta_pix_apagada','doacao','doacao_apagada','contribuicao')`))[0].n >= 10);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
