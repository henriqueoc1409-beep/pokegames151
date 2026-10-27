// Testa os arquivos 33 e 36 (bandeiras da vila) com dados de TESTE, como jogador comum:
// item na loja, compra, hastear/baixar, aparece para quem visita, venda só por PIX.
// Uso (na pasta ferramentas, uma vez: npm i @electric-sql/pglite@0.3.15):  node testar_bandeira.mjs ..
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
const A = "11111111-1111-1111-1111-111111111111", B = "22222222-2222-2222-2222-222222222222", ADM = "99999999-9999-9999-9999-999999999999";
for (const [u, n] of [[A, "ana"], [B, "beto"], [ADM, "chefe"]]) await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]);
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
await as(A, `select public.create_character('Ana', 'mago')`); await as(B, `select public.create_character('Beto', 'guerreiro')`);
const ID = "vila_bandeira_tricolor";
console.log("\nItem na loja");
const it = (await as(A, `select * from shop_items where id = $1`, [ID])).rows?.[0];
check("jogador vê a bandeira na loja", !!it && it.slot === "vila_bandeira" && it.price === 500);
check("desenho tem 47 linhas de 28 pixels e 5 cores", it?.data.rows.length === 47 && it.data.rows.every(r => r.length === 28) && Object.keys(it.data.pal).length === 5);
console.log("\nCompra");
await sys(`update characters set coins = 400 where user_id = $1`, [A]);
check("sem moedas suficientes não compra", /insuficientes/.test((await as(A, `select public.buy_item($1)`, [ID])).error || ""));
await sys(`update characters set coins = 700 where user_id = $1`, [A]);
const r = await as(A, `select * from public.buy_item($1)`, [ID]);
check("compra por 500 moedas", !r.error && r.rows[0].coins === 200, r.error);
check("já fica hasteada ao comprar", r.rows?.[0].outfit.vila_bandeira === ID);
check("não compra duas vezes", /já tem/.test((await as(A, `select public.buy_item($1)`, [ID])).error || ""));
console.log("\nHastear e baixar");
check("baixar", (await as(A, `select outfit from public.equip_item('vila_bandeira', null)`)).rows[0].outfit.vila_bandeira === undefined);
check("hastear de novo", (await as(A, `select outfit from public.equip_item('vila_bandeira', $1)`, [ID])).rows[0].outfit.vila_bandeira === ID);
check("bandeira não serve em outro espaço", /não serve/.test((await as(A, `select public.equip_item('chapeu', $1)`, [ID])).error || ""));
check("quem não comprou não hasteia", /não tem/.test((await as(B, `select public.equip_item('vila_bandeira', $1)`, [ID])).error || ""));
console.log("\nVisita");
const v = (await as(B, `select public.village_state($1) as v`, [A])).rows?.[0]?.v;
check("quem visita a vila vê a bandeira", v?.outfit?.vila_bandeira === ID, JSON.stringify(v)?.slice(0, 200));
console.log("\nSó PIX pelo admin");
await as(ADM, `select public.admin_set_item_prices($1, 500, 10, false)`, [ID]);
await sys(`update characters set coins = 900 where user_id = $1`, [B]);
check("com 'vende por moedas' desmarcado, não compra com moedas", /PIX/.test((await as(B, `select public.buy_item($1)`, [ID])).error || ""));
console.log("\nBandeiras do arquivo 36");
for (const [id, nm] of [["vila_bandeira_missao", "Bandeira Missão"], ["vila_bandeira_pinguim", "Bandeira Pinguim do Sul"]]) {
  const x = (await as(B, `select * from shop_items where id = $1`, [id])).rows[0];
  check(`${nm} na loja por 500, desenho completo`, x?.name === nm && x.price === 500 && x.data.rows.length > 40 && x.data.rows.every(r => r.length === x.data.rows[0].length));
  await sys(`update characters set coins = 500 where user_id = $1`, [B]);
  const c = await as(B, `select outfit from public.buy_item($1)`, [id]);
  check(`${nm}: compra e hasteia`, !c.error && c.rows[0].outfit.vila_bandeira === id, c.error);
}
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
