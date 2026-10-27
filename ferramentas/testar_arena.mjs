// Testa o arquivo 24 (Arena Pokémon, torcida e cobrança de jogada) com dados de TESTE, como jogadores comuns.
// Uso (na pasta ferramentas, uma vez: npm i @electric-sql/pglite@0.3.15):  node testar_arena.mjs ..
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
const id = n => `${n}${n}${n}${n}${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${n.repeat(12)}`;
const ADM = id("9"), ANA = id("1"), BETO = id("2"), CAIO = id("3"), DUDA = id("4"), EVA = id("5");
for (const [u, n] of [[ADM, "chefe"], [ANA, "ana"], [BETO, "beto"], [CAIO, "caio"], [DUDA, "duda"], [EVA, "eva"]]) {
  await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1,$2,$3)`, [u, n + "@t.l", JSON.stringify({ username: n })]);
  await as(u, `select public.create_character($1,'mago')`, [n[0].toUpperCase() + n.slice(1)]);
}
await sys(`insert into user_roles(user_id, role) values ($1, 'admin') on conflict do nothing`, [ADM]);
for (const u of [ANA, BETO]) for (const [j, sp] of [[1, 1], [2, 4], [3, 7]].map(([j, s]) => [j, u === ANA ? s : s + 15])) {
  const m = (await sys(`select (public.pk_new_monster($1, $2, 20)).id`, [u, sp]))[0].id;
  await sys(`update monsters set team_slot = $2 where id = $1`, [m, j]);
}
const arena = async (who, bid) => (await as(who, `select * from arena_battles where battle_id = $1`, [bid])).rows?.[0];
const envelhecer = bid => sys(`update battles set turn_at = now() - interval '1 hour' where id = $1`, [bid]);
const semPressa = () => sys(`update arena_cheers set created_at = created_at - interval '2 minutes'`);

console.log("\nArena: o resumo público");
const bid = (await as(ANA, `select (public.battle_challenge($1, 10)).id`, [BETO])).rows[0].id;
check("convite ainda não aparece na Arena", !(await arena(CAIO, bid)));
await as(BETO, `select public.battle_respond($1, true)`, [bid]);
let a = await arena(CAIO, bid);
check("batalha aceita aparece para quem assiste", a && a.status === "ativa" && a.name1 === "Ana" && a.name2 === "Beto", JSON.stringify(a));
check("mostra os Pokémon em campo com a vida", a?.mon1?.species === 1 && a?.mon2?.species === 16 && a.mon1.hp > 0 && a.mon1.hp === a.mon1.maxhp, JSON.stringify(a?.mon1));
check("os dois estão devendo a jogada", a?.wait1 && a?.wait2);
check("o resumo não mostra os ataques nem PP", !("moves" in (a?.mon1 || {})));
check("sem prazo por turno", (await sys(`select deadline from battles where id = $1`, [bid]))[0].deadline === null);
let r = await as(CAIO, `select * from battles where id = $1`, [bid]); check("quem assiste não lê a batalha inteira direto", r.rows?.length === 0, JSON.stringify(r));
r = await as(CAIO, `select public.arena_battle($1) b`, [bid]); let v = r.rows?.[0]?.b;
check("arena_battle mostra o Pokémon em campo de cada lado", v?.state?.sides?.[0]?.mons?.[0]?.known === true && v.state.sides[1].mons[0].species === 16, r.error);
check("arena_battle esconde os Pokémon que ainda não entraram", v?.state?.sides?.[0]?.mons?.[1]?.known === false && !("species" in v.state.sides[0].mons[1]) && !("hp" in v.state.sides[0].mons[1]), JSON.stringify(v?.state?.sides?.[0]?.mons?.[1]));

console.log("\nTurnos sem cronômetro");
r = await as(ANA, `select public.battle_act($1, 1, 'move', 0)`, [bid]); check("Ana ataca", !r.error, r.error);
a = await arena(CAIO, bid); check("agora só falta o Beto", a && !a.wait1 && a.wait2, JSON.stringify([a?.wait1, a?.wait2]));
r = await as(CAIO, `select public.arena_battle($1) b`, [bid]); check("quem assiste não vê qual ataque a Ana escolheu", !JSON.stringify(r.rows[0].b).includes("battle_actions") && r.rows[0].b.log.length === 1);
r = await as(CAIO, `select * from battle_actions`); check("quem assiste não lê as ações escolhidas", r.rows?.length === 0);
await sys(`update battles set turn_at = now() - interval '30 days' where id = $1`, [bid]);
r = await as(ANA, `select public.battle_claim($1)`, [bid]); check("não existe mais vitória por tempo (mesmo depois de 30 dias)", /não têm mais prazo/.test(r.error || ""), r.error);
check("a batalha continua ativa", (await sys(`select status from battles where id = $1`, [bid]))[0].status === "ativa");

console.log("\nCobrar jogada");
await sys(`update battles set turn_at = now() where id = $1`, [bid]);
r = await as(CAIO, `select public.arena_nudge($1) n`, [bid]); check("não cobra antes de 10 minutos de espera", /10 minutos/.test(r.error || ""), r.error);
await envelhecer(bid);
r = await as(CAIO, `select public.arena_nudge($1) n`, [bid]); check("Caio cobra o Beto", r.rows?.[0]?.n?.name === "Beto" && r.rows[0].n.count === 1, r.error || JSON.stringify(r.rows));
r = await as(CAIO, `select public.arena_nudge($1) n`, [bid]); check("cobrar de novo no mesmo turno é recusado", /já cobrou/.test(r.error || ""), r.error);
r = await as(DUDA, `select public.arena_nudge($1) n`, [bid]); check("Duda também cobra: as cobranças somam (2)", r.rows?.[0]?.n?.count === 2, r.error);
r = await as(ANA, `select public.arena_nudge($1) n`, [bid]); check("a adversária que já jogou também pode cobrar (3)", r.rows?.[0]?.n?.count === 3, r.error);
r = await as(BETO, `select public.arena_nudge($1) n`, [bid]); check("o Beto não cobra a si mesmo", /vez é sua/.test(r.error || ""), r.error);
check("cobranças ficam numa contagem só (3 linhas, nenhuma mensagem no mural)", (await sys(`select count(*)::int n from arena_nudges`))[0].n === 3 && (await sys(`select count(*)::int n from arena_cheers where kind = 'cobrar'`))[0].n === 0);
r = await as(BETO, `select public.arena_away($1, true)`, [bid]); check("Beto avisa que volta mais tarde", !r.error, r.error);
r = await as(EVA, `select public.arena_nudge($1) n`, [bid]); check("ninguém cobra quem avisou que volta mais tarde", /volta mais tarde/.test(r.error || ""), r.error);
r = await as(CAIO, `select public.arena_away($1, true)`, [bid]); check("quem assiste não usa o 'volto mais tarde'", !!r.error);
await as(BETO, `select public.arena_away($1, false)`, [bid]);
r = await as(BETO, `select public.battle_act($1, 1, 'move', 0)`, [bid]); check("Beto volta e joga: o turno é resolvido", !r.error, r.error);
a = await arena(CAIO, bid); check("Arena mostra o turno 2, o último ataque e a vida nova", a?.turn === 2 && a.wait1 && a.wait2 && !!a.last_line && (a.mon1.hp < a.mon1.maxhp || a.mon2.hp < a.mon2.maxhp), JSON.stringify(a));
r = await as(CAIO, `insert into arena_nudges(battle_id, turn, side, user_id) values ('${bid}', 2, 0, '${CAIO}')`); check("ninguém grava cobrança direto na tabela", !!r.error);

console.log("\nTorcida e mensagens");
r = await as(CAIO, `select public.arena_fan($1, 0)`, [bid]); check("Caio torce pela Ana", !r.error, r.error);
r = await as(CAIO, `select public.arena_fan($1, 1)`, [bid]); check("Caio muda de lado", !r.error && (await sys(`select side from arena_fans where user_id = $1`, [CAIO]))[0].side === 1, r.error);
r = await as(ANA, `select public.arena_fan($1, 0)`, [bid]); check("duelista não torce na própria batalha", /torcida é para quem assiste/.test(r.error || ""), r.error);
await semPressa();
r = await as(CAIO, `select public.arena_cheer($1, 'msg', 'Vai Beto!!', 1)`, [bid]); check("Caio manda mensagem", !r.error, r.error);
r = await as(CAIO, `select public.arena_cheer($1, 'reacao', 'Que batalha!')`, [bid]); check("mensagens seguidas em menos de 3 s são recusadas", /Calma/.test(r.error || ""), r.error);
await semPressa();
r = await as(CAIO, `select public.arena_cheer($1, 'reacao', 'Que batalha!')`, [bid]); check("reação pronta", !r.error, r.error);
await semPressa();
r = await as(CAIO, `select public.arena_cheer($1, 'reacao', 'qualquer coisa')`, [bid]); check("reação fora da lista é recusada", /inválida/.test(r.error || ""), r.error);
r = await as(CAIO, `select public.arena_cheer($1, 'msg', $2)`, [bid, "x".repeat(121)]); check("mensagem com mais de 120 letras é recusada", /120/.test(r.error || ""), r.error);
await sys(`insert into daily_puzzles(puzzle_date, mode, pokemon_id) values (public.game_today(), 'classico', 25) on conflict do nothing`);
r = await as(DUDA, `select public.arena_cheer($1, 'msg', 'hoje é o PIKACHU kkk')`, [bid]); check("sem spoiler da resposta do dia", /spoiler/.test(r.error || ""), r.error);
r = await as(DUDA, `insert into arena_cheers(battle_id, user_id, name, kind, body) values ('${bid}', '${DUDA}', 'x', 'msg', 'oi')`); check("ninguém grava mensagem direto na tabela", !!r.error);
for (let i = 0; i < 10; i++) { await sys(`insert into arena_cheers(battle_id, user_id, name, kind, body, created_at) values ($1, $2, 'Eva', 'msg', 'oi', now() - interval '20 seconds')`, [bid, EVA]); }
r = await as(EVA, `select public.arena_cheer($1, 'msg', 'mais uma')`, [bid]); check("no máximo 10 mensagens por minuto", /Espere um minuto/.test(r.error || ""), r.error);
r = await as(DUDA, `select * from arena_cheers`); check("todo mundo lê as mensagens da Arena", r.rows?.length >= 2);

console.log("\nModeração");
r = await as(CAIO, `select public.arena_mute($1, 24)`, [DUDA]); check("jogador comum não silencia ninguém", /administrador/.test(r.error || ""), r.error);
r = await as(ADM, `select public.arena_mute($1, 24, 'spam')`, [CAIO]); check("admin silencia o Caio por 24 h", !r.error, r.error);
await semPressa();
r = await as(CAIO, `select public.arena_cheer($1, 'msg', 'oi')`, [bid]); check("silenciado não manda mensagem", /silenciou/.test(r.error || ""), r.error);
r = await as(CAIO, `select * from arena_mutes`); check("o silenciado vê até quando", r.rows?.length === 1);
r = await as(DUDA, `select * from arena_mutes`); check("os outros não veem quem foi silenciado", r.rows?.length === 0);
const cid = (await sys(`select id from arena_cheers where user_id = $1 order by id limit 1`, [CAIO]))[0].id;
r = await as(DUDA, `select public.arena_cheer_delete($1)`, [cid]); check("jogador comum não apaga mensagem", !!r.error);
r = await as(ADM, `select public.arena_cheer_delete($1)`, [cid]); check("admin apaga mensagem", !r.error && !(await sys(`select 1 from arena_cheers where id = $1`, [cid])).length, r.error);
await as(ADM, `select public.arena_mute($1, 0)`, [CAIO]); check("admin tira o silêncio", !(await sys(`select 1 from arena_mutes`)).length);

console.log("\nFim da batalha e histórico");
r = await as(BETO, `select public.battle_act($1, 2, 'forfeit', null)`, [bid]); check("Beto desiste", !r.error, r.error);
a = await arena(DUDA, bid);
check("Arena mostra a batalha encerrada com vencedora", a?.status === "encerrada" && a.winner === ANA && a.end_reason === "desistencia", JSON.stringify(a));
check("histórico mostra os 3 Pokémon de cada lado", a?.teams?.length === 2 && a.teams[0].mons.length === 3 && a.teams[1].mons.length === 3, JSON.stringify(a?.teams));
r = await as(DUDA, `select public.arena_battle($1) b`, [bid]); check("depois do fim, todos os Pokémon aparecem", r.rows?.[0]?.b?.state?.sides?.every(s => s.mons.every(m => m.known)), r.error);
r = await as(CAIO, `select public.arena_nudge($1)`, [bid]); check("não cobra batalha encerrada", !!r.error);
check("XP da batalha continua sendo dado uma vez", (await sys(`select rewarded from battles where id = $1`, [bid]))[0].rewarded === true);
const pub = (await sys(`select tablename from pg_publication_tables where pubname = 'supabase_realtime'`)).map(x => x.tablename);
check("Arena, torcida, mensagens e cobranças chegam ao vivo", ["arena_battles", "arena_cheers", "arena_fans", "arena_nudges", "battles"].every(t => pub.includes(t)), pub.join(","));
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
