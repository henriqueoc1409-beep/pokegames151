-- =====================================================================
-- POKEGAMES — Painel de uso para o admin (pedido do dono em 27/10/2026).
--
--   * Tabela publicacoes: o robô de publicação (ferramentas/aplicar_sql.mjs)
--     anota cada publicação (quando, versão do código, quem pediu, quais SQL
--     rodaram). Ninguém lê direto; só o admin, pela função abaixo.
--   * admin_usage(): tamanho do banco e limite do plano grátis (500 MB,
--     ajustável em game_config.config.uso_limite_mb), as tabelas maiores,
--     o espaço das cópias de segurança (schemas copia_*), número de
--     jogadores, publicações do mês e o último SQL que rodou.
-- Não muda nada do jogo. Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

create table if not exists public.publicacoes (
  id          bigserial primary key,
  quando      timestamptz not null default now(),
  versao      text,          -- commit do GitHub publicado
  execucao    text,          -- número da publicação no GitHub Actions
  por         text,          -- quem pediu no GitHub
  sql_rodados text[] not null default '{}'
);
alter table public.publicacoes enable row level security;
revoke all on public.publicacoes from anon, authenticated;

create or replace function public.admin_usage() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); ultimo text; mes timestamptz;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador vê o uso do jogo.'; end if;
  -- a tabela de controle do robô é criada à mão (ferramentas/marcar_sql_ja_rodados.sql): lida só se existir
  if to_regclass('public.sql_aplicados') is not null then
    execute 'select arquivo from public.sql_aplicados order by aplicado_em desc, arquivo desc limit 1' into ultimo;
  end if;
  mes := date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  return jsonb_build_object(
    'db_bytes', pg_database_size(current_database()),
    'db_limit_bytes', coalesce((public.cfg()->>'uso_limite_mb')::bigint, 500) * 1024 * 1024,
    'tables', (select coalesce(jsonb_agg(jsonb_build_object('name', relname, 'bytes', b, 'rows', greatest(rows, 0)) order by b desc), '[]'::jsonb)
               from (select c.relname, pg_total_relation_size(c.oid) b, c.reltuples::bigint rows
                     from pg_class c join pg_namespace n on n.oid = c.relnamespace
                     where n.nspname = 'public' and c.relkind = 'r' order by 2 desc limit 12) t),
    'backups', (select coalesce(jsonb_agg(jsonb_build_object('name', nspname, 'bytes', b) order by nspname desc), '[]'::jsonb)
                from (select n.nspname, sum(pg_total_relation_size(c.oid))::bigint b
                      from pg_namespace n left join pg_class c on c.relnamespace = n.oid and c.relkind = 'r'
                      where n.nspname like 'copia\_%' group by n.nspname) t),
    'players', (select count(*) from characters),
    'monsters', (select count(*) from monsters),
    'pubs_month', (select count(*) from publicacoes where quando >= mes),
    'pubs', (select coalesce(jsonb_agg(to_jsonb(p) order by p.quando desc), '[]'::jsonb) from (select * from publicacoes order by quando desc limit 15) p),
    'sql_last', ultimo
  );
end $$;
revoke execute on function public.admin_usage() from public, anon;
grant execute on function public.admin_usage() to authenticated;
