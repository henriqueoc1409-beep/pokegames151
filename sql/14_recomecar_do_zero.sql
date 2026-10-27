-- =====================================================================
-- POKEGAMES — Recomeçar do zero (pedido do dono).
-- ATENÇÃO: apaga o progresso de TODOS os jogadores, inclusive o do admin.
--   Fica: contas (e-mail e senha), papéis de admin, convites, nome e classe
--         de cada herói, configuração do jogo, tabuleiro, Pokémon e loja.
--   Volta ao início: nível 1, 0 XP, 50 moedas, 1 dica, 1 tente outra vez,
--         sem itens nem roupas, sem time, na largada, vila nova.
--   Some: rodadas, rankings, jogadas, roleta, duelos, mercado, pousadas,
--         armadilhas, apostas, reações, mural, lendários e temporadas.
-- Não muda funções, regras nem pontos. Rode UMA vez, depois do 13.
-- Antes de rodar, faça a cópia de segurança. Não tem como desfazer sem ela.
-- =====================================================================
begin;

-- 1) Histórico e tudo que gira em torno dele
truncate table
  public.guesses, public.guess_sessions, public.daily_moves, public.daily_spins,
  public.round_results, public.round_days, public.round_bets,
  public.duel_guesses, public.duels, public.market_listings,
  public.properties, public.traps, public.reactions, public.event_log,
  public.villages, public.team_weeks,
  public.boss_attacks, public.boss_contacts, public.boss_rolls, public.world_bosses,
  public.season_results, public.seasons
restart identity;

-- 2) Desafio de hoje com Pokémon novos (quem já jogou hoje não sabe as respostas).
--    Os dias anteriores ficam guardados só para o jogo não repetir Pokémon tão cedo.
delete from public.daily_puzzles where puzzle_date >= public.game_today();

-- 3) Heróis de volta ao começo, com o mesmo nome e a mesma classe.
--    created_at = agora: assim ninguém recupera dias de antes do recomeço.
update public.characters set
  level = 1, xp_total = 0, coins = 50, hints = 1, retries = 1,
  outfit = '{}'::jsonb, owned_items = '{}',
  node = 0, path = '{0}', route = '{}'::jsonb, bonus_steps = 0,
  arrived_rank = null, arrived_at = null, last_move_date = null,
  skill_date = null, weekly_bonus_date = null,
  team = null, pending_mud = 0, xp_buff_until = null,
  created_at = now();

-- 4) Temporada 1 começando hoje
insert into public.seasons (started_on) values (public.game_today());
insert into public.event_log (kind, message) values ('temporada', 'Tudo do zero! Começa a Temporada 1: todos na largada, no nível 1. Boa sorte!');

commit;

-- Conferência (aparece embaixo depois de rodar): deve mostrar todos no nível 1,
-- com 50 moedas, na casa 0, e a temporada 1.
select name, class, level, coins, node from public.characters order by name;
select id, started_on, status from public.seasons;
