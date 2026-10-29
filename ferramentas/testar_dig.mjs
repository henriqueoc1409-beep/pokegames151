// Testa o arquivo 57 (Dig protege no turno de preparo, como o Fly) com dados de TESTE, como jogador comum,
// numa luta da Grama de Treino: no turno em que cava, nada acerta; no turno seguinte ele sai atacando.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_dig.mjs ..
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
await sys(`update game_config set config = jsonb_set(config, '{treino}', '{"lendario_pct": 0}') where active`);   // sem lendário no teste
const dig = (await sys(`select (public.pk_new_monster($1, 50, 30)).id id`, [A]))[0].id;   // Diglett
await sys(`update monsters set moves = '{91}' where id = $1`, [dig]);
const battle = async id => (await sys(`select * from battles where id = $1`, [id]))[0];
const act = (b, kind, v) => as(A, `select * from public.battle_act($1, (select turn from battles where id = $1), $2, $3)`, [b, kind, v]);
let protegido = 0, acertou = 0, saiu = 0, tentativas = 0;
for (let k = 0; k < 6; k++) {
  await sys(`update monsters set tr_hp = 100 where id = $1`, [dig]); await sys(`delete from treino_dias`); await sys(`delete from treino_visitas`);
  await as(A, `select public.treino_entrar(10)`);
  const e = await as(A, `select public.treino_encontro($1) b`, [dig]); if (e.error) { check("encontro", false, e.error); break; }
  const bid = e.rows[0].b?.battle ?? e.rows[0].b;   // o 58 devolve {battle}
  // o selvagem só tem ataques que sempre acertam quem está à vista (Quick Attack, 100%)
  await sys(`update battles set state = jsonb_set(jsonb_set(state, '{sides,1,mons,0,moves}', '[{"id":98,"pp":30,"max":30}]'), '{sides,1,mons,0,hp}', '999') where id = $1`, [bid]);
  await sys(`update battles set state = jsonb_set(state, '{sides,1,mons,0,maxhp}', '999') where id = $1`, [bid]);
  for (let t = 0; t < 4; t++) {
    const before = await battle(bid); if (before.status !== "ativa") break;
    const hp0 = before.state.sides[0].mons[0].hp, cavando = !before.state.sides[0].mons[0].fl?.charging;
    const r = await act(bid, "move", 0); if (r.error) { check("ação", false, r.error); break; }
    const after = await battle(bid), lines = after.log.at(-1).lines.map(l => l.txt).join(" | ");
    if (cavando && /cavou um buraco/.test(lines)) tentativas++;
    else if (!cavando && /Diglett usou Dig/.test(lines)) {
      // turno seguinte: o Quick Attack (sempre primeiro) chega com o Diglett ainda debaixo da terra
      saiu++;
      const dano = hp0 - after.state.sides[0].mons[0].hp;
      if (/Quick Attack/.test(lines)) { if (dano === 0 && /não acertou: Diglett está debaixo da terra/.test(lines)) protegido++; else acertou++; }
    }
  }
  await as(A, `select public.treino_sair()`);
}
check(`debaixo da terra, o ataque do selvagem não acerta (${protegido} de ${protegido + acertou})`, protegido > 0 && acertou === 0);
check("o relato diz que ele cavou um buraco", tentativas > 0);
check(`no turno seguinte ele sai do chão e ataca (${saiu} vezes)`, saiu > 0);
const fly = (await sys(`select prosrc from pg_proc where proname = 'bt_use_move'`))[0].prosrc;
check("o Fly continua protegendo", /FLY_EFFECT' or mv.id = 91/.test(fly));
check("a novidade está no Jornal", (await sys(`select count(*)::int n from posts where title = '⛏️ Dig agora funciona como no jogo'`))[0].n === 1);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
