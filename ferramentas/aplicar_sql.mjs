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

// confere o formato do endereço do Session pooler do Supabase (nunca mostra a senha)
export function conferirEndereco(url) {
  const p = [], txt = url.trim();
  if (txt !== url) p.push("tem espaço ou quebra de linha sobrando no começo ou no fim.");
  if (/\[|\]/.test(txt)) p.push("ainda tem colchetes [ ]: troque [YOUR-PASSWORD] pela senha, sem os colchetes.");
  if ((txt.match(/@/g) || []).length !== 1) p.push(`tem ${(txt.match(/@/g) || []).length} símbolos @, mas deve ter só 1 (logo depois da senha). Se a senha tem @, troque por uma só com letras e números.`);
  if (!/^postgres(ql)?:\/\//.test(txt)) p.push("deve começar com postgresql://");
  let u = null; try { u = new URL(txt); } catch { p.push("não é um endereço válido (copie de novo do Supabase: Connect → Direct → Session pooler)."); }
  if (u) {
    if (!u.hostname.endsWith(".pooler.supabase.com")) p.push(`o servidor é "${u.hostname}", mas deveria terminar em ".pooler.supabase.com" (use o Session pooler).`);
    if (u.port && u.port !== "5432") p.push(`a porta é ${u.port}, mas o Session pooler usa 5432.`);
    if (!decodeURIComponent(u.username).startsWith("postgres.")) p.push(`o usuário é "${decodeURIComponent(u.username)}", mas no Session pooler deve ser "postgres.<código do projeto>".`);
    if (!u.password) p.push("está sem a senha (depois de postgres.<código>: vem a senha e depois o @).");
    else if (/[^A-Za-z0-9]/.test(decodeURIComponent(u.password))) p.push("a senha tem símbolos; troque por uma só com letras e números para evitar erro.");
  }
  return p;
}

// rodando direto pela linha de comando
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const url = process.env.SUPABASE_DB_URL;
  if (!url) { console.error("Falta o segredo SUPABASE_DB_URL (endereço do banco do Supabase)."); process.exit(1); }
  // confere o endereço antes de tentar entrar, com mensagens claras e sem nunca mostrar a senha
  const problemas = conferirEndereco(url);
  if (problemas.length) { console.error("❌ O endereço do banco (segredo SUPABASE_DB_URL) está com problema:\n - " + problemas.join("\n - ")); process.exit(1); }
  const { default: pg } = await import("pg");
  const client = new pg.Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
  await client.connect();
  const db = { exec: s => client.query(s), query: (s, p) => client.query(s, p) };
  try { await aplicar(db, ROOT, { soListar: process.argv.includes("--so-listar") }); }
  catch (e) { console.error("❌ " + e.message); process.exitCode = 1; }
  finally { await client.end(); }
}
