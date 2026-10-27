// Robô de publicação do banco: roda no Supabase, em ordem, os arquivos sql/NN_*.sql que ainda não rodaram.
//  * Quais já rodaram fica anotado na tabela public.sql_aplicados (criada UMA vez pelo dono com
//    ferramentas/marcar_sql_ja_rodados.sql). Sem essa tabela, o robô para e não faz nada.
//  * Antes do primeiro arquivo novo, faz a cópia de segurança (ferramentas/copia_de_seguranca.sql).
//  * Cada arquivo roda num bloco só: se der erro, nada daquele arquivo fica no banco e o robô para.
//  * Arquivos MANUAIS nunca rodam sozinhos: o 14_recomecar_do_zero e qualquer um que comece com "-- MANUAL".
// Uso no GitHub (o endereço do banco fica guardado em segredo):  SUPABASE_DB_URL=... node ferramentas/aplicar_sql.mjs
// Só listar o que rodaria, sem mudar nada:                          node ferramentas/aplicar_sql.mjs --so-listar
import fs from "fs"; import path from "path"; import { fileURLToPath } from "url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const MANUAIS = ["14_recomecar_do_zero.sql"];

export function arquivosSql(root) {
  return fs.readdirSync(path.join(root, "sql")).filter(f => /^\d+_.+\.sql$/.test(f)).sort((a, b) => parseInt(a) - parseInt(b) || a.localeCompare(b));
}
export function manual(root, f) {
  if (MANUAIS.includes(f)) return true;
  const topo = fs.readFileSync(path.join(root, "sql", f), "utf8").split("\n").slice(0, 5).join("\n");
  return /^--\s*MANUAL/im.test(topo);
}
// db: { exec(sql) roda vários comandos; query(sql, params) devolve { rows } }
export async function aplicar(db, root, { soListar = false, log = console.log } = {}) {
  const tem = (await db.query("select to_regclass('public.sql_aplicados') is not null as ok")).rows[0].ok;
  if (!tem) throw new Error("A tabela sql_aplicados não existe. Rode uma vez ferramentas/marcar_sql_ja_rodados.sql no SQL Editor do Supabase.");
  const feitos = new Set((await db.query("select arquivo from public.sql_aplicados")).rows.map(r => r.arquivo));
  const faltam = arquivosSql(root).filter(f => !feitos.has(f));
  const pular = faltam.filter(f => manual(root, f)), rodar = faltam.filter(f => !manual(root, f));
  for (const f of pular) log(`⏭️  ${f}: é MANUAL, o robô não roda (o dono roda à mão, se quiser).`);
  if (!rodar.length) { log("✅ Nenhum SQL novo para rodar."); return { rodados: [], pulados: pular }; }
  log(`📋 SQL novos, nesta ordem: ${rodar.join(", ")}`);
  if (soListar) return { rodados: [], faltam: rodar, pulados: pular };
  log("💾 Fazendo a cópia de segurança…");
  await db.exec(fs.readFileSync(path.join(root, "ferramentas/copia_de_seguranca.sql"), "utf8"));
  const rodados = [];
  for (const f of rodar) {
    log(`▶️  Rodando ${f}…`);
    await db.exec("begin");
    try {
      await db.exec(fs.readFileSync(path.join(root, "sql", f), "utf8"));
      await db.query("insert into public.sql_aplicados(arquivo, origem) values ($1, 'robo')", [f]);
      await db.exec("commit");
    } catch (e) {
      try { await db.exec("rollback"); } catch {}
      throw new Error(`Erro no ${f} (nada dele ficou no banco; os anteriores ficaram): ${e.message}`);
    }
    rodados.push(f); log(`✅ ${f} rodou.`);
  }
  return { rodados, pulados: pular };
}

// rodando direto pela linha de comando
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const url = process.env.SUPABASE_DB_URL;
  if (!url) { console.error("Falta o segredo SUPABASE_DB_URL (endereço do banco do Supabase)."); process.exit(1); }
  const { default: pg } = await import("pg");
  const client = new pg.Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
  await client.connect();
  const db = { exec: s => client.query(s), query: (s, p) => client.query(s, p) };
  try { await aplicar(db, ROOT, { soListar: process.argv.includes("--so-listar") }); }
  catch (e) { console.error("❌ " + e.message); process.exitCode = 1; }
  finally { await client.end(); }
}
