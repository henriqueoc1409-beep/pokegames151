-- Cópia de segurança do Pokegames. Rode no SQL Editor do Supabase ANTES de qualquer SQL novo.
-- Só COPIA: não muda nem apaga nada do jogo. Cria uma pasta (schema) chamada copia_AAAA_MM_DD
-- com a data de hoje e copia para lá as tabelas que existirem. Se rodar de novo no mesmo dia,
-- a cópia do dia é refeita. Para não encher o plano grátis do Supabase, guarda só as 7 cópias
-- mais recentes: as mais antigas (copia_ de outras datas) são apagadas no fim.
do $$
declare
  pasta text := 'copia_' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYY_MM_DD');
  t text;
begin
  execute format('create schema if not exists %I', pasta);
  foreach t in array array[
    'profiles', 'user_roles', 'characters', 'guess_sessions', 'guesses', 'daily_moves', 'daily_puzzles',
    'round_results', 'round_days', 'seasons', 'season_results', 'traps', 'market_listings', 'daily_spins',
    'game_config', 'properties', 'villages', 'duels', 'shop_items', 'event_log', 'invites',
    'monsters', 'pokedex_entries', 'encounters', 'pk_move_sync', 'bag_items', 'mon_events', 'battles', 'battle_actions',
    'chat_messages', 'donations', 'pix_offers', 'contributions', 'posts', 'poll_votes',
    'arena_battles', 'arena_fans', 'arena_cheers', 'arena_nudges', 'arena_mutes', 'war_squads', 'wars', 'post_images',
    'leagues', 'league_players', 'league_matches', 'cave_votes', 'cave_cheers', 'gifts', 'quizzes', 'quiz_entries', 'sac_tickets', 'sac_messages', 'sac_agents', 'npc_fights', 'board_nodes', 'rocket_raids', 'rocket_entries', 'hunts', 'pk_items', 'hunt_entries'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop table if exists %I.%I', pasta, t);
      execute format('create table %I.%I as select * from public.%I', pasta, t, t);
    end if;
  end loop;
  -- guarda só as 7 cópias mais recentes (o nome tem a data, então a ordem alfabética é a das datas)
  for t in select nspname from pg_namespace where nspname ~ '^copia_[0-9]{4}_[0-9]{2}_[0-9]{2}$' order by nspname desc offset 7 loop
    execute format('drop schema %I cascade', t);
  end loop;
end $$;

-- Mostra as cópias feitas hoje e quantas linhas cada tabela tem
select table_name as tabela_copiada,
       (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from %I.%I', table_schema, table_name), false, true, '')))[1]::text::int as linhas
from information_schema.tables
where table_schema = 'copia_' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYY_MM_DD')
order by 1;
