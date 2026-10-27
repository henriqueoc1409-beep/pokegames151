#!/usr/bin/env bash
# Cria um banco local de testes e roda todas as migrações do Pokegames em ordem.
# Uso: ./ferramentas/testar_banco.sh [nome_do_banco]
# Precisa de PostgreSQL instalado (comandos createdb, dropdb e psql disponíveis).
set -euo pipefail
cd "$(dirname "$0")/.."
DB="${1:-pokegames_teste}"
dropdb --if-exists "$DB"
createdb "$DB"
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f ferramentas/supabase_simulado.sql
for f in sql/*.sql; do
  echo "== $f"
  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f" > /dev/null
done
echo "Banco $DB pronto: $(psql -tA -d "$DB" -c 'select count(*) from board_nodes') casas, $(psql -tA -d "$DB" -c 'select count(*) from pokemon') Pokémon."
