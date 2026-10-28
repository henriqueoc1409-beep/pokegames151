-- =====================================================================
-- POKEGAMES — Dica e "Tente outra vez" não contam mais como tentativa
-- no ranking da rodada do dia (pedido do dono em 28/10/2026).
--
-- Antes: cada Dica somava +1 e cada "Tente outra vez" somava +2 na conta
-- da rodada (rank_attempts). Agora as ajudas são só bônus: a rodada conta
-- apenas os palpites que ficaram valendo (o "Tente outra vez" continua
-- apagando o último palpite errado). Modo não acertado continua contando
-- unsolved_rank_attempts (10). As casas andadas não mudam: elas já não
-- contavam as ajudas.
-- Vale para as contas feitas daqui em diante (rodada de hoje inclusive);
-- os vencedores das rodadas já fechadas não mudam.
-- Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

create or replace function public.rank_attempts(_attempts int, _solved boolean, _hints int, _retries int) returns int
language sql stable security definer set search_path = public, extensions as $$
  -- _hints e _retries ficam na assinatura (muitas funções chamam assim), mas não somam mais nada
  select case when _solved then _attempts
              else (cfg()->>'unsolved_rank_attempts')::int end
$$;
