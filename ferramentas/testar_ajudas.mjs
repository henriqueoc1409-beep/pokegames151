// Testa o arquivo 52: Dica e "Tente outra vez" não contam como tentativa no ranking da rodada.
// Uso (na pasta ferramentas, uma vez: npm install):  node testar_ajudas.mjs ..
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
const ra = async (a, s, h, r) => (await db.query(`select public.rank_attempts($1, $2, $3, $4) n`, [a, s, h, r])).rows[0].n;
check("acertou com 3 palpites, sem ajuda: 3", await ra(3, true, 0, 0) === 3);
check("acertou com 3 palpites usando 2 Dicas: continua 3", await ra(3, true, 2, 0) === 3);
check("\"Tente outra vez\" apagou um erro (ficaram 2 palpites): 2, sem castigo", await ra(2, true, 0, 1) === 2);
check("Dica e \"Tente outra vez\" juntos também não somam", await ra(4, true, 3, 1) === 4);
check("modo não acertado continua valendo 10", await ra(6, false, 1, 1) === 10);
const steps = async (a, s) => (await db.query(`select public.mode_steps($1, $2) n`, [a, s])).rows[0].n;
check("as casas não mudam (1 palpite = 5 casas)", await steps(1, true) === 5);
console.log(`\n${ok} testes passaram, ${fail} falharam.`);
process.exit(fail ? 1 : 0);
