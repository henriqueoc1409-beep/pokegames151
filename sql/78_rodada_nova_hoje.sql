-- =====================================================================
-- POKEGAMES — Recomeçar a rodada de hoje (pedido do dono em 06/11/2026).
-- Botão em Administração → Temporada. Para todos os jogadores:
--  * apaga os palpites de hoje (quem jogou e quem não jogou começam do zero);
--  * devolve as Dicas e os "Tente outra vez" usados hoje;
--  * sorteia Pokémon NOVOS para os 4 modos (nunca os mesmos de antes);
--  * publica um aviso no Jornal.
-- Só funciona se ninguém andou hoje (quem andou: "Desfazer andada" antes).
-- Fica na Auditoria. Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

create or replace function public.admin_rodada_nova(_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare d date := public.game_today(); antes jsonb; depois jsonb; quem text; n int; dicas int; tentes int; i int;
begin
  perform public.assert_admin();
  select string_agg(ch.name::text, ', ' order by ch.name) into quem
    from daily_moves dm join characters ch on ch.user_id = dm.user_id where dm.move_date = d;
  if quem is not null then
    raise exception 'Já andaram hoje: %. Use "Desfazer andada" neles (Administração → Jogadores) e tente de novo.', quem;
  end if;
  select coalesce(jsonb_object_agg(mode::text, pokemon_id), '{}'::jsonb) into antes from daily_puzzles where puzzle_date = d;

  -- devolve as ajudas usadas hoje
  select count(distinct user_id), coalesce(sum(hints_used), 0), coalesce(sum(retries_used), 0) into n, dicas, tentes
    from guess_sessions where puzzle_date = d;
  update characters ch set hints = ch.hints + s.h, retries = ch.retries + s.r
    from (select user_id, sum(hints_used)::int h, sum(retries_used)::int r from guess_sessions where puzzle_date = d group by user_id) s
   where ch.user_id = s.user_id and (s.h > 0 or s.r > 0);

  delete from guesses where puzzle_date = d;
  delete from guess_sessions where puzzle_date = d;
  delete from daily_puzzles where puzzle_date = d;
  perform public.ensure_puzzles(d);
  -- nunca o mesmo Pokémon de antes no mesmo modo
  for i in 1 .. 20 loop
    exit when not exists (select 1 from daily_puzzles p where p.puzzle_date = d and (antes->>(p.mode::text))::int = p.pokemon_id);
    delete from daily_puzzles p where p.puzzle_date = d and (antes->>(p.mode::text))::int = p.pokemon_id;
    perform public.ensure_puzzles(d);
  end loop;
  select coalesce(jsonb_object_agg(mode::text, pokemon_id), '{}'::jsonb) into depois from daily_puzzles where puzzle_date = d;

  perform public.audit('rodada_nova', null, antes, depois, coalesce(nullif(btrim(_reason), ''), 'Rodada de hoje recomeçada'));
  insert into posts(kind, title, body, created_by)
  values ('aviso', '🔄 Rodada de hoje recomeçada',
    'O admin recomeçou a rodada de hoje: Pokémon novos nos 4 desafios, e todo mundo joga do zero (quem já tinha jogado também). As Dicas e os "Tente outra vez" usados hoje voltaram para a sua conta. Aperte Ctrl+F5 (ou feche e abra a aba no celular) e bom jogo!',
    auth.uid());
  return jsonb_build_object('jogadores', n, 'dicas', dicas, 'tentes', tentes);
end $$;

revoke execute on function public.admin_rodada_nova(text) from public, anon;
grant execute on function public.admin_rodada_nova(text) to authenticated;
