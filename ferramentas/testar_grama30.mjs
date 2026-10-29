// Testa o arquivo 58 (Grama de Treino: 30 minutos, tempo perdido ao sair, encontros mais espaçados e lendário raro)
// com dados de TESTE, como jogadores comuns.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_grama30.mjs ..
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
const A = "11111111-1111-1111-1111-111111111111";
await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, 'a@t.l', '{"username":"Ana"}')`, [A]); await as(A, `select public.create_character('Ana', 'mago')`);
const mon = (await sys(`select (public.pk_new_monster($1, 66, 14)).id id`, [A]))[0].id;   // Machop
const st = async () => (await as(A, `select public.treino_estado() s`)).rows[0].s;
const enter = m => as(A, `select public.treino_entrar($1) s`, [m]);
const meet = () => as(A, `select public.treino_encontro($1) r`, [mon]).then(r => r.error ? r : { r: r.rows[0].r });
const setCfg = j => sys(`update game_config set config = jsonb_set(config, '{treino}', $1::jsonb) where active`, [JSON.stringify(j)]);

console.log("\n30 minutos e tempo perdido ao sair");
let s = await st();
check("o relógio do dia tem 30 minutos e 15 s entre encontros", s.minutos_dia === 30 && s.encontro_seg === 15, JSON.stringify([s.minutos_dia, s.encontro_seg]));
await enter(10); let r = await as(A, `select public.treino_sair() s`);
check("saiu logo depois de entrar: os 10 minutos foram gastos (não volta nada)", !r.error && r.rows[0].s.minutos === 10 && r.rows[0].s.visita === null, r.error || JSON.stringify(r.rows[0].s.minutos));
await enter(10); await as(A, `select public.treino_sair()`);
r = await enter(10);
check("na terceira visita de 10, completa os 30 do dia", !r.error && r.rows[0].s.minutos === 30, r.error);
await as(A, `select public.treino_sair()`);
check("com os 30 usados, não entra mais hoje", /acabou \(30 minutos\)/.test((await enter(5)).error || ""));

console.log("\nEncontros mais espaçados");
await sys(`delete from treino_dias`); await sys(`delete from treino_visitas`); await setCfg({ lendario_pct: 0 });
await enter(10);
let e = await meet();
check("o encontro devolve a luta", !e.error && !!e.r.battle && !e.r.lendario, e.error || JSON.stringify(e.r));
await as(A, `select * from public.battle_act($1, (select turn from battles where id = $1), 'forfeit', null)`, [e.r.battle]);
await sys(`update monsters set tr_hp = 100 where id = $1`, [mon]);
await sys(`update treino_visitas set ult_encontro = now() - interval '10 seconds'`);
check("10 segundos depois, ainda não aparece outro", /continue andando/.test((await meet()).error || ""));
await sys(`update treino_visitas set ult_encontro = now() - interval '16 seconds'`);
e = await meet();
check("16 segundos depois, aparece", !e.error && !!e.r.battle, e.error);
await as(A, `select * from public.battle_act($1, (select turn from battles where id = $1), 'forfeit', null)`, [e.r.battle]);

console.log("\nLendário");
await setCfg({ lendario_pct: 100 }); await sys(`update monsters set tr_hp = 100 where id = $1`, [mon]); await sys(`update treino_visitas set ult_encontro = now() - interval '1 minute'`);
const lutasAntes = (await st()).lutas, batalhasAntes = (await sys(`select count(*)::int n from battles where mode = 'treino' and status = 'ativa'`))[0].n;
e = await meet();
const L = e.r?.lendario;
check("aparece um lendário da 1ª geração, nível 70", !e.error && L && [144, 145, 146, 150, 151].includes(L.species) && L.level === 70, e.error || JSON.stringify(e.r));
check("não tem batalha", !e.r?.battle && (await sys(`select count(*)::int n from battles where mode = 'treino' and status = 'ativa'`))[0].n === batalhasAntes);
check("o seu Pokémon desmaia na hora", (await sys(`select tr_hp from monsters where id = $1`, [mon]))[0].tr_hp === 0);
const last = (await st()).ultimas[0];
check("conta como luta perdida, sem experiência", (await st()).lutas === lutasAntes + 1 && last.wild === L.species && !last.won && last.xp === 0, JSON.stringify(last));
check("o relato diz que o lendário acabou com você", /O lendário acabou com você/.test(JSON.stringify((await sys(`select log from treino_lutas order by id desc limit 1`))[0].log)));
await sys(`update treino_visitas set ult_encontro = now() - interval '1 minute'`);
check("desmaiado, não encontra mais nada até curar", /desmaiado/.test((await meet()).error || ""));
await setCfg({ lendario_pct: 1 });
check("a chance normal do lendário é 1%", (await sys(`select public.treino_cfg()->>'lendario_pct' x`))[0].x === "1");
check("a novidade está no Jornal", (await sys(`select count(*)::int n from posts where title like '🌿 Grama de Treino: 30 minutos%'`))[0].n === 1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
