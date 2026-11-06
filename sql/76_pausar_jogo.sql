-- =====================================================================
-- POKEGAMES — Pausar o jogo (pedido do dono em 06/11/2026).
-- Liga/desliga em Administração → Ajustes do jogo → Pausar o jogo
-- (game_config.config.pausa: on, texto). Pausado:
--  * jogadores comuns não conseguem jogar nada (assert_active recusa com o aviso);
--  * o site mostra uma tela de "jogo pausado" com o aviso;
--  * nada fecha nem começa sozinho (settle não roda): rodada, Liga, caverna e
--    temporada nova ficam paradas até o admin despausar;
--  * o admin continua entrando e mexendo em tudo.
-- Em produção (onde existe sql_aplicados) este arquivo já liga a pausa com o
-- aviso "Aguardando deliberação dos jogadores para início da nova temporada".
-- Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

create or replace function public.pausa_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on":false,"texto":"Aguardando deliberação dos jogadores para início da nova temporada."}'::jsonb
         || coalesce(public.cfg()->'pausa', '{}'::jsonb);
$$;

create or replace function public.jogo_pausado() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((public.pausa_cfg()->>'on')::boolean, false);
$$;

-- porteiro de todas as ações dos jogadores (versão do 01 + pausa)
create or replace function public.assert_active() returns uuid
language plpgsql stable security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Faça login para continuar.'; end if;
  if not exists (select 1 from profiles where id = uid and status = 'ativo') then
    raise exception 'Sua conta está bloqueada. Fale com o administrador.';
  end if;
  -- arquivo 76: jogo pausado pelo admin (o admin continua jogando e mexendo)
  if public.jogo_pausado() and not public.has_role(uid, 'admin') then
    raise exception '⏸️ %', coalesce(nullif(public.pausa_cfg()->>'texto', ''), 'O jogo está pausado.');
  end if;
  return uid;
end $$;

-- fechamento automático (versão do 46 + pausa)
create or replace function public.settle() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare d date := game_today(); c jsonb := cfg(); r record; x record; pos int; bs int; bc int; s seasons; names text := ''; lastu uuid; firstu uuid;
begin
  if public.jogo_pausado() then return; end if;   -- arquivo 76: jogo pausado, nada fecha nem começa sozinho
  perform pg_advisory_xact_lock(151151);
  for r in select distinct puzzle_date as pd from guess_sessions
           where puzzle_date < d and not recovered and puzzle_date not in (select rd.d from round_days rd) order by 1 loop
    insert into round_days(d) values (r.pd);
    pos := 0; names := ''; lastu := null; firstu := null;
    for x in
      select p.user_id,
             sum(public.rank_attempts(coalesce(gs.attempts,0), coalesce(gs.solved,false), coalesce(gs.hints_used,0), coalesce(gs.retries_used,0)))::int as total,
             count(*) filter (where gs.solved)::int as solved,
             max(gs.finished_at) as fin
      from (select distinct user_id from guess_sessions where puzzle_date = r.pd and not recovered) p
      join characters ch on ch.user_id = p.user_id
      cross join (select mode from daily_puzzles where puzzle_date = r.pd) m
      left join guess_sessions gs on gs.user_id = p.user_id and gs.puzzle_date = r.pd and gs.mode = m.mode
      group by p.user_id
      order by 2 asc, 4 asc nulls last
    loop
      pos := pos + 1;
      bs := coalesce((c->'round_bonus_steps'->>(pos-1))::int, 0);
      bc := coalesce((c->'round_bonus_coins'->>(pos-1))::int, 0);
      insert into round_results(d, user_id, rank, attempts, modes_solved, bonus_steps, bonus_coins)
      values (r.pd, x.user_id, pos, x.total, x.solved, bs, bc);
      if bs > 0 or bc > 0 then update characters set bonus_steps = bonus_steps + bs, coins = coins + bc where user_id = x.user_id; end if;
      if pos = 1 then names := (select name from characters where user_id = x.user_id) || ' venceu a rodada de ' || to_char(r.pd, 'DD/MM') || ' com ' || x.total || ' tentativas'; firstu := x.user_id; end if;
      lastu := x.user_id;
    end loop;
    if firstu is not null then
      insert into villages(user_id) values (firstu) on conflict do nothing;
      update villages set statues = statues + 1 where user_id = firstu;
    end if;
    if pos >= 2 and lastu is not null then
      insert into villages(user_id) values (lastu) on conflict do nothing;
      update villages set mud = 3 where user_id = lastu;
    end if;
    if names <> '' then insert into event_log(kind, message) values ('rodada', names || '.'); end if;
  end loop;
  perform public.settle_bets();
  perform public.expire_duels();
  perform public.boss_tick();
  perform public.team_week_tick();
  perform public.league_tick();
  perform public.rocket_tick();
  perform public.hunt_tick();
  select * into s from seasons order by id desc limit 1;
  if s.status = 'encerrada' and s.ended_on < d then perform public.start_new_season(); end if;
end $$;

-- números para a aba Ajustes do jogo (versão do 73 + pausa)
create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'leilao', public.leilao_cfg(), 'herois', public.herois_cfg(), 'temporada', public.temporada_cfg(), 'liga', public.liga_cfg(), 'pausa', public.pausa_cfg(), 'base', public.cfg());
end $$;

grant execute on function public.jogo_pausado() to authenticated;
revoke execute on function public.pausa_cfg() from public, anon, authenticated;

-- liga a pausa agora, só no banco de verdade (nos testes não existe sql_aplicados)
do $$
begin
  if to_regclass('public.sql_aplicados') is not null then
    update public.game_config
       set config = jsonb_set(config, '{pausa}', '{"on":true,"texto":"Aguardando deliberação dos jogadores para início da nova temporada."}'::jsonb)
     where active;
  end if;
end $$;
