// Testa o arquivo 56 (Grama de Treino para andar) com dados de TESTE, como jogadores comuns:
// visita de 5 ou 10 minutos tirada do relógio de 60, encontro só com visita aberta e com intervalo, batalha em que o
// jogador dá os comandos e o selvagem joga sozinho, XP e vida no fim, fugir, a luta termina mesmo se o tempo acabar,
// sair antes devolve o tempo, cada um só mexe na sua luta, a luta automática saiu, novidade no Jornal.
// Roda só até o 57 (o 58 mudou o tempo do dia, o sair e a resposta do encontro; os testes dele estão em testar_grama30.mjs).
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_grama.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const root = process.argv[2];
const db = new PGlite({ extensions: { citext, pgcrypto } });
await db.exec(fs.readFileSync(path.join(root, "ferramentas/supabase_simulado.sql"), "utf8"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql") && f !== "14_recomecar_do_zero.sql" && f < "58").sort()) await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
let ok = 0, fail = 0;
const check = (n, c, x = "") => { if (c) { ok++; console.log("  OK  ", n); } else { fail++; console.log("  FALHOU", n, x); } };
const sys = async (q, p = []) => (await db.query(q, p)).rows;
const as = async (uid, q, p = []) => { await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid}', false);`); try { return { rows: (await db.query(q, p)).rows }; } catch (e) { return { error: e.message }; } finally { await db.exec("reset role;"); } };
const U = n => `${n}${n}${n}${n}${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${n}${n}${n}${n}-${String(n).repeat(12)}`;
const [A, B] = [U(1), U(2)];
for (const [u, n] of [[A, "Ana"], [B, "Beto"]]) { await sys(`insert into auth.users(id, email, raw_user_meta_data) values ($1, $2, $3)`, [u, n + "@t.l", JSON.stringify({ username: n })]); await as(u, `select public.create_character($1, 'mago')`, [n]); }
const newMon = async (u, sp, lv) => (await sys(`select (public.pk_new_monster($1, $2, $3)).id id`, [u, sp, lv]))[0].id;
const mon = async id => (await sys(`select * from monsters where id = $1`, [id]))[0];
const st = async u => (await as(u, `select public.treino_estado() s`)).rows[0].s;
const enter = (u, m) => as(u, `select public.treino_entrar($1) s`, [m]);
const meet = (u, id) => as(u, `select public.treino_encontro($1) b`, [id]).then(r => r.error ? r : { b: r.rows[0].b });
const act = (u, b, kind, v, item = null) => as(u, `select * from public.battle_act($1, (select turn from battles where id = $1), $2, $3, $4)`, [b, kind, v, item]);
const battle = async id => (await sys(`select * from battles where id = $1`, [id]))[0];
const cool = u => sys(`update treino_visitas set ult_encontro = now() - interval '1 minute' where user_id = $1`, [u]);
async function fightToEnd(u, b) {
  for (let i = 0; i < 80; i++) {
    const x = await battle(b); if (x.status !== "ativa") return x;
    const mv = x.state.sides[0].mons[0].moves.findIndex(m => m.pp > 0);
    const r = await act(u, b, "move", mv < 0 ? -1 : mv); if (r.error) { console.log("   erro na ação:", r.error); return x; }
  }
  return battle(b);
}
const charm = await newMon(A, 4, 12), bMon = await newMon(B, 7, 12);

console.log("\nVisita");
check("entrar por 7 minutos é recusado (só 5 ou 10)", /5 ou 10/.test((await enter(A, 7)).error || ""));
let r = await enter(A, 10);
check("entra por 10 minutos e o relógio do dia marca 10", !r.error && r.rows[0].s.visita?.minutos === 10 && r.rows[0].s.minutos === 10, r.error || JSON.stringify(r.rows[0].s.visita));
r = await enter(A, 5);
check("entrar de novo com a visita aberta não cobra outra vez", !r.error && r.rows[0].s.minutos === 10 && r.rows[0].s.visita.minutos === 10);
check("sem visita, não há encontro", /tempo na grama acabou/.test((await meet(B, bMon)).error || ""));

console.log("\nEncontro e batalha");
let e = await meet(A, charm);
check("andando na grama, aparece um selvagem (luta criada)", !e.error && !!e.b, e.error);
const b1 = e.b;
check("pedir de novo devolve a mesma luta (termine a que começou)", (await meet(A, charm)).b === b1);
let x = await battle(b1);
check("a luta é 1 contra 1, do modo treino, com o seu Pokémon e o selvagem do nível dele ou abaixo (ou forte, de 3 a 6 acima)",
  x.mode === "treino" && x.state.sides[0].mons.length === 1 && x.state.sides[1].mons.length === 1 && (x.state.treino.forte ? x.state.sides[1].mons[0].level >= 15 && x.state.sides[1].mons[0].level <= 18 : x.state.sides[1].mons[0].level <= 12 && x.state.sides[1].mons[0].level >= 9), JSON.stringify(x.state.sides[1].mons[0].level));
check("outro jogador não mexe na sua luta", /não encontrada/.test((await act(B, b1, "move", 0)).error || ""));
const t0 = x.turn; r = await act(A, b1, "move", 0);
x = await battle(b1);
check("você escolhe o ataque e o selvagem responde na hora (o turno anda)", !r.error && (x.turn > t0 || x.status !== "ativa"), r.error);
x = await fightToEnd(A, b1);
const res = x.state.treino?.res, m1 = await mon(charm);
check("a luta termina e o resultado fica guardado", x.status === "encerrada" && !!res && x.state.treino.feito, JSON.stringify(x.state.treino));
const wi = x.state.sides[1].mons[0];
check("vitória dá exp-base × nível ÷ 7 de XP; derrota não dá nada", res.won ? res.xp === Math.max(1, Math.floor(wi.bexp * wi.level / 7)) : res.xp === 0, JSON.stringify(res));
check("a vida que sobrou fica guardada", m1.tr_hp === res.hp, JSON.stringify([m1.tr_hp, res.hp]));
check("a luta conta no dia e vai para as últimas lutas", (await st(A)).lutas === 1 && (await sys(`select count(*)::int n from treino_lutas where user_id = $1`, [A]))[0].n === 1);
check("a luta do treino não vai para a Arena", (await sys(`select count(*)::int n from arena_battles`))[0].n === 0);
check("jogar de novo na luta encerrada é recusado", /não está em andamento/.test((await act(A, b1, "move", 0)).error || ""));
check("logo depois, ainda não aparece outro (intervalo de 8 s)", /continue andando/.test((await meet(A, charm)).error || ""));

console.log("\nFugir");
await cool(A); await sys(`update monsters set tr_hp = 100 where id = $1`, [charm]);
e = await meet(A, charm); r = await act(A, e.b, "forfeit", null);
x = await battle(e.b);
check("fugir encerra a luta sem XP", !r.error && x.status === "encerrada" && x.state.treino.res.fugiu && !x.state.treino.res.won && x.state.treino.res.xp === 0, r.error || JSON.stringify(x.state.treino));
check("o relato diz que você fugiu", x.log.some(t => t.lines.some(l => /fugiu da luta/.test(l.txt))));
check("a luta antiga some quando aparece a próxima", (await cool(A), await meet(A, charm), (await sys(`select count(*)::int n from battles where mode = 'treino' and p1 = $1`, [A]))[0].n === 1));

console.log("\nTempo acabando no meio da luta");
const live = (await st(A)).batalha;
check("o estado mostra a luta em andamento", !!live);
await sys(`update treino_visitas set fim = now() - interval '1 second' where user_id = $1`, [A]);
check("o tempo acabou: a visita fecha", (await st(A)).visita === null);
r = await act(A, live, "move", 0);
check("mas a luta continua até o fim", !r.error, r.error);
x = await fightToEnd(A, live);
check("e termina normalmente", x.status === "encerrada" && !!x.state.treino.res);
await cool(A);
check("depois disso, não aparece mais nada (precisa entrar de novo)", /tempo na grama acabou/.test((await meet(A, charm)).error || ""));

console.log("\nSair antes e limite do dia");
r = await enter(B, 10); const before = (await st(B)).minutos;
r = await as(B, `select public.treino_sair() s`);
check("sair logo depois devolve o tempo que sobrou (cobra só 1 minuto)", !r.error && r.rows[0].s.visita === null && r.rows[0].s.minutos === before - 9, r.error || JSON.stringify([before, r.rows[0].s.minutos]));
await sys(`update treino_dias set minutos = 55 where user_id = $1`, [B]);
r = await enter(B, 10);
check("faltando 5 minutos no dia, entra só por 5", !r.error && r.rows[0].s.visita.minutos === 5 && r.rows[0].s.minutos === 60);
await as(B, `select public.treino_sair()`); await sys(`update treino_dias set minutos = 60 where user_id = $1`, [B]);
check("com os 60 minutos usados, não entra mais hoje", /acabou/.test((await enter(B, 5)).error || ""));

console.log("\nRegras de antes");
await sys(`update treino_dias set minutos = 0`); await enter(A, 10); await cool(A);
await sys(`update monsters set tr_hp = 0, tr_hurt_at = now() where id = $1`, [charm]);
check("Pokémon desmaiado não entra na luta", /desmaiado/.test((await meet(A, charm)).error || ""));
check("a luta automática antiga saiu do site", /permission|permissão/i.test((await as(A, `select public.treino_lutar($1)`, [charm])).error || ""));
check("a novidade já está no Jornal", (await sys(`select count(*)::int n from posts where title like '🌿 Grama de Treino: agora você anda%' and kind = 'novidade'`))[0].n === 1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
