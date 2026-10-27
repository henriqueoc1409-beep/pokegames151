-- =====================================================================
-- POKEGAMES — Ranking detalhado e jogada dos amigos (somente leitura).
-- Não cria tabelas, não muda políticas e não altera regras ou pontos.
-- Adiciona 4 funções de leitura que respeitam a regra contra spoiler:
-- palpites e respostas de um dia só aparecem para quem já terminou
-- aquele dia ou quando o dia não pode mais ser recuperado.
-- Rode depois do 11. Antes, faça a cópia de segurança.
-- =====================================================================

-- Pode ver os detalhes do dia? (admin, dia fora do prazo de recuperação,
-- já andou naquele dia, ou ainda não tinha personagem naquele dia)
create or replace function public.can_view_day(_d date) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select public.has_role(auth.uid(), 'admin')
      or _d < public.game_today() - coalesce((public.cfg()->>'recovery_days')::int, 3)
      or exists (select 1 from daily_moves dm where dm.user_id = auth.uid() and dm.move_date = _d)
      or coalesce((select (ch.created_at at time zone coalesce(public.cfg()->>'timezone','America/Sao_Paulo'))::date > _d
                   from characters ch where ch.user_id = auth.uid()), false)
$$;

-- Quadro de um dia: cada jogador, cada modo
create or replace function public.round_board(_date date default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); dia date := coalesce(_date, public.game_today()); vis boolean;
begin
  if dia > public.game_today() then raise exception 'Esse dia ainda não aconteceu.'; end if;
  vis := public.can_view_day(dia);
  return jsonb_build_object(
    'date', dia, 'today', dia = public.game_today(), 'can_see', vis,
    'settled', exists (select 1 from round_days rd where rd.d = dia),
    'modes', coalesce((select jsonb_agg(dp.mode order by dp.mode) from daily_puzzles dp where dp.puzzle_date = dia), '[]'::jsonb),
    'answers', case when vis then coalesce((select jsonb_object_agg(dp.mode, jsonb_build_object('id', p.id, 'name', p.name))
                    from daily_puzzles dp join pokemon p on p.id = dp.pokemon_id where dp.puzzle_date = dia), '{}'::jsonb) end,
    'players', coalesce((
      with avail as (select dp.mode from daily_puzzles dp where dp.puzzle_date = dia),
      rows as (
        select ch.user_id, ch.name::text as nm, ch.class, ch.level, ch.outfit, ch.team, rr.rank,
          exists (select 1 from daily_moves dm where dm.user_id = ch.user_id and dm.move_date = dia) as moved,
          exists (select 1 from daily_moves dm where dm.user_id = ch.user_id and dm.move_date = dia and dm.recovered) as rec,
          exists (select 1 from guess_sessions gs where gs.user_id = ch.user_id and gs.puzzle_date = dia) as played,
          (select coalesce(jsonb_object_agg(a.mode, jsonb_build_object(
              'started', gs.user_id is not null,
              'guesses', coalesce(gs.attempts, 0) + coalesce(gs.retries_used, 0),
              'attempts', coalesce(gs.attempts, 0),
              'solved', coalesce(gs.solved, false), 'failed', coalesce(gs.failed, false),
              'hints', coalesce(gs.hints_used, 0), 'retries', coalesce(gs.retries_used, 0),
              'rank_attempts', public.rank_attempts(coalesce(gs.attempts,0), coalesce(gs.solved,false), coalesce(gs.hints_used,0), coalesce(gs.retries_used,0)),
              'steps', public.mode_steps(coalesce(gs.attempts,0), coalesce(gs.solved,false)))), '{}'::jsonb)
            from avail a left join guess_sessions gs on gs.user_id = ch.user_id and gs.puzzle_date = dia and gs.mode = a.mode) as modes,
          (select sum(public.rank_attempts(coalesce(gs.attempts,0), coalesce(gs.solved,false), coalesce(gs.hints_used,0), coalesce(gs.retries_used,0)))::int
            from avail a left join guess_sessions gs on gs.user_id = ch.user_id and gs.puzzle_date = dia and gs.mode = a.mode) as total,
          (select count(*)::int from guess_sessions gs where gs.user_id = ch.user_id and gs.puzzle_date = dia and gs.solved) as solved,
          (select count(*)::int from guess_sessions gs where gs.user_id = ch.user_id and gs.puzzle_date = dia and (gs.solved or gs.failed)) as done,
          (select max(gs.finished_at) from guess_sessions gs where gs.user_id = ch.user_id and gs.puzzle_date = dia) as fin
        from characters ch
        left join round_results rr on rr.user_id = ch.user_id and rr.d = dia)
      select jsonb_agg(jsonb_build_object(
          'user_id', r.user_id, 'name', r.nm, 'class', r.class, 'level', r.level, 'outfit', r.outfit, 'team', r.team,
          'rank', r.rank, 'moved', r.moved, 'recovered', r.rec, 'played', r.played or r.moved,
          'solved', r.solved, 'done', r.done,
          'visible', vis or r.user_id = uid,
          'total', case when vis or r.user_id = uid then r.total end,
          'modes', case when vis or r.user_id = uid then r.modes
                        else (select coalesce(jsonb_object_agg(e.k, jsonb_build_object('started', (e.v->>'started')::boolean,
                                'done', (e.v->>'solved')::boolean or (e.v->>'failed')::boolean)), '{}'::jsonb) from jsonb_each(r.modes) e(k, v)) end)
        order by r.rank nulls last, (case when r.played or r.moved then 0 else 1 end),
                 (case when vis then r.total end) asc nulls last, r.done desc, r.fin asc nulls last, r.nm)
      from rows r), '[]'::jsonb));
end $$;

-- Jogada de um jogador num dia: sequência de palpites por modo
create or replace function public.play_detail(_user uuid, _date date default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); dia date := coalesce(_date, public.game_today()); vis boolean; own boolean := _user = uid;
begin
  vis := public.can_view_day(dia);
  if not own and not vis then
    raise exception 'A jogada dos outros fica visível depois que você termina o seu dia, ou quando o dia não pode mais ser recuperado.';
  end if;
  return jsonb_build_object('user_id', _user, 'date', dia,
    'name', (select name from characters where user_id = _user),
    'modes', coalesce((select jsonb_object_agg(dp.mode, jsonb_build_object(
        'started', gs.user_id is not null,
        'attempts', coalesce(gs.attempts,0), 'solved', coalesce(gs.solved,false), 'failed', coalesce(gs.failed,false),
        'hints', coalesce(gs.hints_used,0), 'retries', coalesce(gs.retries_used,0),
        'rank_attempts', public.rank_attempts(coalesce(gs.attempts,0), coalesce(gs.solved,false), coalesce(gs.hints_used,0), coalesce(gs.retries_used,0)),
        'steps', public.mode_steps(coalesce(gs.attempts,0), coalesce(gs.solved,false)),
        'finished_at', gs.finished_at,
        -- a resposta só aparece se o dia está liberado ou se o próprio jogador já terminou o modo
        'answer', case when vis or (own and (coalesce(gs.solved,false) or coalesce(gs.failed,false))) then jsonb_build_object('id', p.id, 'name', p.name) end,
        'hint_texts', case when vis or (own and (coalesce(gs.solved,false) or coalesce(gs.failed,false))) then
            (select coalesce(jsonb_agg(h order by n), '[]'::jsonb) from (values (1, 'Tipo principal: ' || p.type1), (2, 'Habitat: ' || p.habitat), (3, 'Começa com a letra ' || left(p.name,1))) x(n, h)
             where n <= coalesce(gs.hints_used,0)) end,
        'guesses', coalesce((select jsonb_agg(jsonb_build_object('pokemon_id', g.pokemon_id, 'correct', g.correct, 'annulled', g.annulled,
                     'feedback', g.feedback, 'at', g.created_at) order by g.id)
                   from guesses g where g.user_id = _user and g.puzzle_date = dia and g.mode = dp.mode), '[]'::jsonb)))
      from daily_puzzles dp join pokemon p on p.id = dp.pokemon_id
      left join guess_sessions gs on gs.user_id = _user and gs.puzzle_date = dia and gs.mode = dp.mode
      where dp.puzzle_date = dia), '{}'::jsonb));
end $$;

-- Desempenho por modo num período (só dias já liberados)
create or replace function public.mode_stats(_kind text) returns table (
  user_id uuid, mode public.puzzle_mode, played int, solved int, avg_attempts numeric, first_try int)
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); hoje date := public.game_today(); start date;
begin
  start := case _kind when 'semana' then date_trunc('week', hoje)::date when 'mes' then date_trunc('month', hoje)::date else '2000-01-01'::date end;
  return query
  select gs.user_id, gs.mode, count(*)::int,
         count(*) filter (where gs.solved)::int,
         round(avg(gs.attempts + gs.retries_used) filter (where gs.solved), 1),
         count(*) filter (where gs.solved and gs.attempts = 1 and gs.retries_used = 0)::int
  from guess_sessions gs
  where gs.puzzle_date >= start and not gs.recovered
    and (gs.puzzle_date < hoje or public.can_view_day(hoje) or gs.user_id = uid)
  group by gs.user_id, gs.mode;
end $$;

-- Permissões: só as funções públicas novas (as anteriores continuam iguais)
revoke execute on function public.can_view_day(date) from public, anon, authenticated;
grant execute on function public.round_board(date), public.play_detail(uuid, date), public.mode_stats(text) to authenticated;
