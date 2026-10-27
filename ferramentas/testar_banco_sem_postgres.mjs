// Igual ao ferramentas/testar_banco.sh, mas com o PostgreSQL rodando dentro do Node (PGlite).
// Uso (na pasta ferramentas, uma vez: npm i @electric-sql/pglite@0.3.15):
//   node testar_banco_sem_postgres.mjs ..
import { PGlite } from "@electric-sql/pglite";
import { citext } from "@electric-sql/pglite/contrib/citext";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import fs from "fs"; import path from "path";
const [root, dataDir] = process.argv.slice(2);
const db = new PGlite(dataDir, { extensions: { citext, pgcrypto } });
const run = async (f) => { const sql = fs.readFileSync(f, "utf8"); try { await db.exec(sql); } catch (e) { console.error("ERRO em", path.basename(f), "\n", e.message, e.where || ""); process.exit(1); } };
await run(path.join(root, "ferramentas/supabase_simulado.sql"));
for (const f of fs.readdirSync(path.join(root, "sql")).filter(f => f.endsWith(".sql")).sort()) { console.log("==", f); await run(path.join(root, "sql", f)); }
const q = async s => (await db.query(s)).rows;
console.log("Banco pronto:", (await q("select count(*) n from board_nodes"))[0].n, "casas,", (await q("select count(*) n from pokemon"))[0].n, "Pokémon,", (await q("select count(*) n from shop_items"))[0].n, "itens");
await db.close();
