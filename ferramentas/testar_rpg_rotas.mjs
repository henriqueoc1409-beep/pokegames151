// Testa o arquivo 97 (Aventura maior) com dados de TESTE, como jogadores comuns: Grama fechada, áreas com nível fixo,
// todos os Pokémon (menos lendários) aparecem em alguma área, evoluído só no nível certo, tipo da área, fuga paga
// (10 + 10 por ataque), sem moedas não foge, Ajustes, Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_rpg_rotas.mjs ..
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
const A = "11111111-1111-1111-1111-111111111111", ADM = "99999999-9999-9999-9999-999999999999";
for (const [u, n] of [[A, "Ana"], [ADM, "Chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'guerreiro')`, [n]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
const newMon = async (u, sp, lv) => (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, sp, lv]))[0].id;
const cool = () => sys(`update rpg_dias set ult = now() - interval '1 minute', batalhas = 0 where true`);
const forte = await newMon(A, 150, 70);
const coins = async () => (await sys(`select coins from characters where user_id = $1`, [A]))[0].coins;
const fecha = () => sys(`delete from battles where p1 = $1`, [A]);
async function encontro(zona) {
  await cool(); await sys(`update monsters set tr_hp = 100 where true`);
  const r = await as(A, `select public.rpg_encontro($1, $2) r`, [forte, zona]); if (r.error) return { error: r.error };
  const b = (await sys(`select * from battles where id = $1`, [r.rows[0].r.battle]))[0];
  return { b, w: b.state.sides[1].mons[0] };
}

console.log("\nGrama fechada e áreas novas");
const cfg = (await sys(`select config c from game_config where active`))[0].c;
check("a Grama de Treino está fechada", cfg.treino?.on === false, JSON.stringify(cfg.treino));
check("a Aventura tem as 16 áreas com nível e tipos (vila + 6 rotas × 2)", Object.keys(cfg.rpg.zonas).length === 16 && cfg.rpg.zonas.bosque_fundo.min === 18 && !("nivel_menos" in cfg.rpg), JSON.stringify(Object.keys(cfg.rpg.zonas)));
check("entrar na Grama é recusado", !!(await as(A, `select public.treino_entrar(5)`)).error);

console.log("\nTodos os Pokémon aparecem em algum lugar");
const falta = await sys(`
  with z as (select key, (value->>'min')::int mn, (value->>'max')::int mx, array(select jsonb_array_elements_text(value->'tipos')) tipos from jsonb_each((select config->'rpg'->'zonas' from game_config where active)))
  select p.id, p.name, public.rpg_nivel_min(p.id) a, public.rpg_nivel_max(p.id) b from pokemon p
   where p.id <= 151 and p.id not in (144,145,146,150,151)
     and not exists (select 1 from z where (p.g1_type1 = any(z.tipos) or p.g1_type2 = any(z.tipos)) and greatest(z.mn, public.rpg_nivel_min(p.id)) <= least(z.mx, public.rpg_nivel_max(p.id) - 1))`);
check("os 146 Pokémon da 1ª geração (sem lendários) têm pelo menos uma área", falta.length === 0, JSON.stringify(falta));
await sys(`update game_config set config = config || '{"gen2": true, "gen2_from": "2020-01-01"}' where active`);
const falta2 = await sys(`
  with z as (select key, (value->>'min')::int mn, (value->>'max')::int mx, array(select jsonb_array_elements_text(value->'tipos')) tipos from jsonb_each((select config->'rpg'->'zonas' from game_config where active)))
  select p.id, p.name from pokemon p where public.gen_ok(p.id) and p.id not in (144,145,146,150,151,243,244,245,249,250,251)
     and not exists (select 1 from z where (p.g1_type1 = any(z.tipos) or p.g1_type2 = any(z.tipos)) and greatest(z.mn, public.rpg_nivel_min(p.id)) <= least(z.mx, public.rpg_nivel_max(p.id) - 1))`);
check("com a 2ª geração ligada, os 240 (sem lendários) também têm área", falta2.length === 0, JSON.stringify(falta2));
await sys(`update game_config set config = config || '{"gen2": false}' where active`);
const niv = Object.fromEntries((await sys(`select id, public.rpg_nivel_min(id) a from pokemon where id in (4,5,6,94,149,25,26,134)`)).map(r => [r.id, r.a]));
check("nível mínimo pela evolução: Charmeleon 16, Charizard 36, Gengar (troca) 36, Dragonite 55, Raichu (pedra) 28", niv[5] === 16 && niv[6] === 36 && niv[94] === 36 && niv[149] === 55 && niv[26] === 28 && niv[4] === 1, JSON.stringify(niv));

console.log("\nEncontros");
let okNivel = true, okTipo = true, okEvo = true, vistos = new Set(), erro = null;
const Z = cfg.rpg.zonas;
for (const zona of ["mato", "bosque_fundo", "pico_fundo"]) for (let i = 0; i < 12; i++) {
  const r = await encontro(zona); if (r.error) { erro = r.error; break; }
  const sp = r.b.state.sides[1].mons[0].species ?? r.b.state.sides[1].mons[0].species_id; const p = (await sys(`select g1_type1, g1_type2, public.rpg_nivel_min(id) a from pokemon where id = $1`, [sp]))[0];
  const lv = r.w.level; vistos.add(zona + ":" + sp);
  if (lv < Z[zona].min || lv > Z[zona].max) okNivel = false;
  if (!Z[zona].tipos.includes(p.g1_type1) && !Z[zona].tipos.includes(p.g1_type2)) okTipo = false;
  if (p.a > lv) okEvo = false;
  await fecha();
}
check("encontros acontecem nas áreas novas", !erro, erro);
check("o nível do selvagem fica na faixa da área", okNivel);
check("o selvagem é de um tipo da área", okTipo);
check("nenhum evoluído abaixo do nível da evolução", okEvo);
check("aparecem espécies variadas", vistos.size >= 12, vistos.size);
check("área que não existe é recusada", !!(await as(A, `select public.rpg_encontro($1, 'grama_que_nao_existe')`, [forte])).error);

console.log("\nFugir custa moedas");
await sys(`update characters set coins = 500 where user_id = $1`, [A]);
let r = await encontro("mato"); let c0 = await coins();
let f = await as(A, `select public.battle_act($1, 1, 'forfeit', null)`, [r.b.id]);
check("fugir logo custa 10 moedas", !f.error && c0 - await coins() === 10, f.error || (c0 - await coins()));
await fecha();
r = await encontro("pico_fundo");   // selvagem forte: a luta dura
const fraco = await newMon(A, 129, 5);
await sys(`update battles set state = jsonb_set(state, '{treino,ataques}', '0') where id = $1`, [r.b.id]);
let b = r.b, atq = 0;
for (let i = 0; i < 2; i++) { b = (await sys(`select * from battles where id = $1`, [b.id]))[0]; if (b.status !== "ativa") break; const a = await as(A, `select public.battle_act($1, $2, 'move', 0)`, [b.id, b.turn]); if (!a.error) atq++; }
b = (await sys(`select * from battles where id = $1`, [b.id]))[0];
check("cada ataque fica contado na luta", b.state.treino.ataques === atq && atq > 0, JSON.stringify(b.state.treino));
if (b.status === "ativa") {
  c0 = await coins(); f = await as(A, `select public.battle_act($1, $2, 'forfeit', null)`, [b.id, b.turn]);
  check(`depois de ${atq} ataques, fugir custa ${10 + 10 * atq}`, !f.error && c0 - await coins() === 10 + 10 * atq, f.error || (c0 - await coins()));
  const log = (await sys(`select log from battles where id = $1`, [b.id]))[0].log;
  check("o relato diz quanto pagou", JSON.stringify(log).includes("pagou " + (10 + 10 * atq)));
} else check("luta seguiu ativa para testar a fuga", false, b.status);
await fecha();
await sys(`update characters set coins = 5 where user_id = $1`, [A]);
r = await encontro("mato");
f = await as(A, `select public.battle_act($1, 1, 'forfeit', null)`, [r.b.id]);
check("sem moedas suficientes, não foge", !!f.error && /custa 10 moedas/.test(f.error) && await coins() === 5, f.error);
await fecha();

console.log("\nAjustes e Jornal");
const aj = (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c;
check("aparece em Ajustes do jogo (fuga e zonas)", aj.rpg?.fuga_base === 10 && aj.rpg?.fuga_por_ataque === 10 && aj.rpg?.zonas?.pico_fundo?.max === 60);
await sys(`update game_config set config = jsonb_set(config, '{rpg,fuga_base}', '0') where active`);
await sys(`update game_config set config = jsonb_set(config, '{rpg,fuga_por_ataque}', '0') where active`);
await sys(`update characters set coins = 0 where user_id = $1`, [A]);
r = await encontro("mato"); f = await as(A, `select public.battle_act($1, 1, 'forfeit', null)`, [r.b.id]);
check("o admin zera o preço e a fuga fica grátis", !f.error, f.error);
check("aviso publicado no Jornal uma vez", (await sys(`select count(*)::int n from posts where title = '🧭 Aventura maior: 6 rotas novas e todos os Pokémon'`))[0].n === 1);
console.log(`\n${ok} verificações passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
