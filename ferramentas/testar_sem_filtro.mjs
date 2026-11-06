// Confere que nenhuma função do jogo faz UPDATE ou DELETE na tabela inteira sem WHERE.
// O Supabase bloqueia isso nas chamadas que vêm do site ("DELETE requires a WHERE clause"),
// e o banco de teste (PGlite) não tem essa trava. Olha só a versão mais nova de cada função.
// Uso:  node testar_sem_filtro.mjs ..
import fs from "fs"; import path from "path";
const root = process.argv[2], dir = path.join(root, "sql");
const latest = {};
for (const f of fs.readdirSync(dir).filter(f => /^\d+_.*\.sql$/.test(f) && f !== "14_recomecar_do_zero.sql").sort()) {
  const s = fs.readFileSync(path.join(dir, f), "utf8");
  if (/^\s*-- MANUAL/.test(s)) continue;
  const re = /create or replace function public\.(\w+)\(/g; let m;
  while ((m = re.exec(s))) { const a = s.indexOf("$$", m.index), b = s.indexOf("$$", a + 2); latest[m[1]] = { f, body: s.slice(a + 2, b) }; }
}
let ok = 0, fail = 0;
for (const [fn, { f, body }] of Object.entries(latest)) {
  for (const st of body.replace(/--[^\n]*/g, "").split(";")) {
    const t = st.replace(/\s+/g, " ").toLowerCase(), m = t.match(/\b(update\s+[\w.]+\s+set\b.*|delete\s+from\s+[\w.]+.*)/);
    if (m && !/ where /.test(" " + m[1] + " ")) { fail++; console.log("  FALHOU", fn, `(${f}):`, m[1].slice(0, 100)); }
  }
}
ok = Object.keys(latest).length;
console.log(`\n${ok} funções conferidas, ${fail} comandos sem WHERE.`);
console.log(`${fail ? 0 : 1} testes passaram, ${fail ? 1 : 0} falharam.`);
process.exit(fail ? 1 : 0);
