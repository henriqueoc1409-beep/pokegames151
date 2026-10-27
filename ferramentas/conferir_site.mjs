// Confere o site antes de publicar: o JavaScript do deploy/index.html não pode ter erro de digitação,
// e a chave do Supabase no site TEM que ser a pública ("anon"), nunca a secreta ("service_role").
// Uso: node ferramentas/conferir_site.mjs
import fs from "fs"; import path from "path"; import os from "os"; import { execFileSync } from "child_process"; import { fileURLToPath } from "url";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const html = fs.readFileSync(path.join(root, "deploy/index.html"), "utf8");
let erros = 0;
const key = html.match(/SUPABASE_ANON_KEY\s*=\s*"([^"]+)"/)?.[1];
if (!key) { console.error("❌ Não achei a SUPABASE_ANON_KEY no deploy/index.html."); erros++; }
else if (key !== "COLE_AQUI_A_ANON_KEY") {
  let role = "?";
  try { role = JSON.parse(Buffer.from(key.split(".")[1], "base64url").toString()).role; } catch {}
  if (role !== "anon") { console.error(`❌ A chave do site é "${role}". Só a chave pública "anon" pode ficar no site!`); erros++; }
  else console.log("✅ Chave do site: a pública (anon).");
}
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
const tmp = path.join(os.tmpdir(), "pokegames-conferir.js");
fs.writeFileSync(tmp, scripts[scripts.length - 1] || "");
try { execFileSync(process.execPath, ["--check", tmp], { stdio: "pipe" }); console.log("✅ JavaScript do site sem erro de digitação."); }
catch (e) { console.error("❌ Erro no JavaScript do site:\n" + e.stderr?.toString()); erros++; }
process.exit(erros ? 1 : 0);
