// Testa o arquivo 27 (dados da 2ª geração guardados escondidos): carrega, confere os números e garante
// que NADA muda no jogo enquanto o 28 não ligar a 2ª geração.
// Uso (na pasta ferramentas, uma vez: npm i @electric-sql/pglite@0.3.15):  node testar_dados_gen2.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
const files = fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql").sort();
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
for (const f of files.filter(f => f < "27")) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
const snap = async () => JSON.stringify(await sys(`select (select count(*) from pokemon) p, (select count(*) from pk_moves) m, (select count(*) from pk_evolutions) e,
  (select count(*) from pk_learnset) l, (select count(*) from pk_type_chart) t, (select md5(string_agg(id || name || coalesce(base_form, 0), ',' order by id)) from pokemon) h`));
const before = await snap();
const sql27 = fs.readFileSync(path.join(root, "sql/27_dados_gen2.sql"), "utf8");
await db.exec(sql27); await db.exec(sql27);
check("o 27 roda duas vezes sem erro", true);
check("rodar o 27 não muda nada no jogo (Pokémon, ataques, evoluções, tipos)", before === await snap(), `${before} -> ${await snap()}`);
const c = (await sys(`select (select count(*) from gen2_species)::int s, (select count(*) from gen2_moves)::int m, (select count(*) from gen2_evolutions)::int e,
  (select count(*) from gen2_learnset)::int l, (select count(*) from gen2_type_chart)::int t, (select count(*) from gen2_base_forms)::int b`))[0];
check("100 Pokémon, 86 ataques novos, 251 formas iniciais", c.s === 100 && c.m === 86 && c.b === 251, JSON.stringify(c));
check("cada Pokémon novo tem ataques por nível e ataque inicial", (await sys(`select count(*)::int n from gen2_species where cardinality(start_moves) = 0 or id not in (select species_id from gen2_learnset)`))[0].n === 0);
check("todo ataque aprendido existe (1ª ou 2ª geração)", (await sys(`select count(*)::int n from gen2_learnset l where l.move_id not in (select id from pk_moves union select id from gen2_moves)`))[0].n === 0);
check("descrições não têm o nome do Pokémon (modo Descrição)", (await sys(`select count(*)::int n from gen2_species where position(lower(name) in lower(description)) > 0`))[0].n === 0);
check("efeitos marcados como funcionando existem no motor da 1ª geração", (await sys(`select count(*)::int n from gen2_moves where effect_g1 is not null and effect_g1 not in (select distinct effect from pk_moves)`))[0].n === 0);
check("categorias dos desafios iguais às da 1ª geração (habitat e cor)", (await sys(`select count(*)::int n from gen2_species where habitat not in (select habitat from pokemon) or color not in (select color from pokemon)`))[0].n === 0);
check("só os tipos novos entram na tabela de tipos", (await sys(`select count(*)::int n from gen2_type_chart where 'SOMBRIO' not in (atk, def) and 'METALICO' not in (atk, def)`))[0].n === 0);
const ev = Object.fromEntries((await sys(`select from_id || '>' || to_id k, method || coalesce(level::text, '') || coalesce(item, '') v from gen2_evolutions`)).map(r => [r.k, r.v]));
check("evoluções do plano (Crobat 38, Steelix e Scizor pela Pedra Metálica, Espeon/Umbreon, Politoed/Slowking pela Pedra do Rei)",
  ev["42>169"] === "nivel38" && ev["95>208"] === "pedrapedra_metal" && ev["123>212"] === "pedrapedra_metal" && ev["133>196"] === "pedrapedra_sol" &&
  ev["133>197"] === "pedrapedra_lua_nova" && ev["61>186"] === "pedrapedra_rei" && ev["79>199"] === "pedrapedra_rei" && ev["117>230"] === "nivel45" && ev["137>233"] === "nivel40", JSON.stringify(ev));
check("nenhuma evolução por troca sobrou", !Object.values(ev).some(v => v.startsWith("troca")));
const bf = Object.fromEntries((await sys(`select id, base_form from gen2_base_forms`)).map(r => [r.id, r.base_form]));
check("com a 2ª ligada, a linha do Pikachu começa no Pichu e a do Onix continua no Onix", bf[25] === 172 && bf[26] === 172 && bf[208] === 95 && bf[1] === 1, JSON.stringify([bf[25], bf[26], bf[208]]));
check("lendários marcados (Raikou, Entei, Suicune, Lugia, Ho-Oh, Celebi)", (await sys(`select array_agg(id order by id) a from gen2_species where legendary`))[0].a.join() === "243,244,245,249,250,251");
check("Especial = média de ataque e defesa especial (Chikorita 49 e 65 = 57)", (await sys(`select base_spc from gen2_species where id = 152`))[0].base_spc === 57);
const U = "11111111-1111-1111-1111-111111111111";
await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, 'a@t.l', '{"username":"ana"}')`, [U]);
let r = await as(U, `select * from gen2_species`); check("jogador não lê os dados escondidos", !!r.error || r.rows.length === 0, JSON.stringify(r).slice(0, 80));
r = await as(U, `select * from gen2_moves`); check("jogador não lê os ataques escondidos", !!r.error || r.rows.length === 0);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
