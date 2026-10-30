// Testa o arquivo 60 (silhueta travada e descrição em partes) com dados de TESTE, como jogadores comuns:
// só a etapa atual da silhueta sai do servidor (desafio e duelo), a imagem inteira só no fim; a descrição começa
// com 1 frase e cada erro revela mais uma; o admin desliga; só o admin grava as etapas; novidade no Jornal.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_silhueta_descricao.mjs ..
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
for (const [u, n] of [[A, "Ana"], [B, "Beto"], [ADM, "Chefe"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'mago')`, [n]); }
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
// imagens de TESTE para todos (a silhueta "inteira" tem a marca INTEIRA)
await sys(`insert into pokemon_media(pokemon_id, silhouette, pixel_levels) select id, 'data:image/png;base64,INTEIRA' || id, '["data:x","data:y"]'::jsonb from pokemon
           on conflict (pokemon_id) do update set silhouette = excluded.silhouette, pixel_levels = excluded.pixel_levels`);
const lv = id => JSON.stringify([0, 1, 2, 3, 4, 5, 6].map(k => `data:image/png;base64,ETAPA${k}-${id}`));

console.log("\nGravar as etapas");
check("jogador comum não grava as etapas", /administrador|admin/i.test((await as(A, `select public.admin_save_sil_levels(1, $1::jsonb)`, [lv(1)])).error || ""));
check("o admin precisa mandar 7 etapas", /7 etapas/.test((await as(ADM, `select public.admin_save_sil_levels(1, '["data:a"]'::jsonb)`)).error || ""));
const st = await as(ADM, `select public.admin_media_status() s`);
check("o painel mostra quantas faltam travar", st.rows?.[0].s.sil_levels === 0 && st.rows[0].s.missing_sil.length > 100 && st.rows[0].s.desc_parts >= 151, JSON.stringify(st.rows?.[0].s.sil_levels));

console.log("\nSilhueta do desafio");
const sil = (await as(A, `select public.puzzle_state('silhueta') s`)).rows[0].s;
const ans = (await sys(`select pokemon_id from daily_puzzles where puzzle_date = public.game_today() and mode = 'silhueta'`))[0].pokemon_id;
check("sem as etapas, continua como antes (enquanto o admin não trava)", sil.clue.image === `data:image/png;base64,INTEIRA${ans}` && !sil.clue.cropped);
await as(ADM, `select public.admin_save_sil_levels($1, $2::jsonb)`, [ans, lv(ans)]);
let s = (await as(A, `select public.puzzle_state('silhueta') s`)).rows[0].s;
check("travada: chega só a 1ª etapa (zoom maior)", s.clue.image === `data:image/png;base64,ETAPA0-${ans}` && s.clue.cropped === true, JSON.stringify(s.clue));
const wrong = ans === 1 ? 2 : 1;
await as(A, `select public.make_guess('silhueta', $1)`, [wrong]);
s = (await as(A, `select public.puzzle_state('silhueta') s`)).rows[0].s;
check("depois de 1 erro, chega a 2ª etapa", s.clue.image === `data:image/png;base64,ETAPA1-${ans}`);
check("a imagem inteira não sai do servidor antes do fim", !JSON.stringify(s).includes("INTEIRA") && !JSON.stringify(s).includes("ETAPA6"));
await as(A, `select public.make_guess('silhueta', $1)`, [ans]);
s = (await as(A, `select public.puzzle_state('silhueta') s`)).rows[0].s;
check("acertou: aparece a silhueta inteira (última etapa)", s.finished && s.clue.image === `data:image/png;base64,ETAPA6-${ans}`);

console.log("\nDescrição em partes");
const dAns = (await as(B, `select public.puzzle_state('descricao') s`)).rows[0].s;
const parts = (await sys(`select description_parts p from pokemon_media where pokemon_id = (select pokemon_id from daily_puzzles where puzzle_date = public.game_today() and mode = 'descricao')`))[0].p;
check("começa só com a 1ª frase (pista 1 de 4)", dAns.clue.text === parts[0] && dAns.clue.parts === 1 && dAns.clue.parts_total === 4, JSON.stringify(dAns.clue));
check("as outras frases não saem do servidor", !JSON.stringify(dAns).includes(parts[3]));
const dId = (await sys(`select pokemon_id from daily_puzzles where puzzle_date = public.game_today() and mode = 'descricao'`))[0].pokemon_id;
await as(B, `select public.make_guess('descricao', $1)`, [dId === 1 ? 2 : 1]);
let d2 = (await as(B, `select public.puzzle_state('descricao') s`)).rows[0].s;
check("1 erro revela a 2ª frase", d2.clue.text === parts[0] + " " + parts[1] && d2.clue.parts === 2);
await sys(`update game_config set config = jsonb_set(config, '{desafio}', '{"desc_progressiva": false}') where active`);
d2 = (await as(B, `select public.puzzle_state('descricao') s`)).rows[0].s;
check("o admin pode desligar: o verbete vem inteiro", d2.clue.text === parts.join(" ") && !d2.clue.parts);
await sys(`update game_config set config = jsonb_set(config, '{desafio}', '{"desc_progressiva": true}') where active`);
check("251 Pokémon têm o verbete novo em 4 partes", (await sys(`select count(*)::int n from pokemon_media where jsonb_array_length(description_parts) = 4`))[0].n === 251);
const ajg = (await as(ADM, `select public.admin_cfg_efetiva() c`)).rows[0].c;
check("o liga/desliga aparece nos Ajustes do jogo", ajg.desafio?.desc_progressiva === true);

console.log("\nDuelo de quiz");
const did = (await sys(`insert into duels(challenger, opponent, kind, stake_kind, stake, status, pokemon_id, expires_at, accepted_at)
                        values ($1, $2, 'quiz', 'moedas', 10, 'aceito', $3, now() + interval '1 day', now()) returning id`, [A, B, ans]))[0].id;
let du = (await as(A, `select public.duel_state($1) s`, [did])).rows[0].s;
check("no duelo também chega só a etapa atual", du.clue.image === `data:image/png;base64,ETAPA0-${ans}` && du.clue.cropped === true, JSON.stringify(du.clue));
await sys(`update duels set c_attempts = 3 where id = $1`, [did]);
du = (await as(A, `select public.duel_state($1) s`, [did])).rows[0].s;
check("e anda com os erros (3 erros = 4ª etapa)", du.clue.image === `data:image/png;base64,ETAPA3-${ans}` && !JSON.stringify(du).includes("INTEIRA"));
check("a novidade está no Jornal", (await sys(`select count(*)::int n from posts where title = '🔍 Desafio mais difícil: Descrição e Silhueta'`))[0].n === 1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
