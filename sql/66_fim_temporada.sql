-- =====================================================================
-- POKEGAMES — Novo fim de temporada (pedido do dono em 03/11/2026).
--
-- Antes: a Liga só começava quando TODOS os jogadores ativos chegassem ao
-- Castelo. Agora:
-- • O 1º jogador que chega ao Castelo encerra a corrida. Os outros ainda
--   jogam o resto daquele dia; quando a rodada do dia fecha (meia-noite),
--   a corrida acaba e a Liga Pokémon começa na hora.
-- • Classificação final da corrida: primeiro quem chegou ao Castelo (pela
--   ordem de chegada), depois quem estava mais perto do Castelo.
-- • Prêmio do Castelo por posição (castle_prizes: 500, 300, 150): quem
--   chegou recebe ao chegar, como antes; os outros recebem no fim da corrida,
--   pela posição no mapa. O pódio da temporada (season_results) segue a mesma
--   ordem, até season_arrivals posições.
-- • A Liga entra com quem chegou e todos os jogadores ativos, e as chaves
--   seguem a classificação (1º x último...). A Liga em si não muda.
-- • Depois que a Liga começa, quem chegar ao Castelo não ganha mais prêmio.
-- Novas versões de check_arrival e league_maybe_start (a anterior era a do 31).
-- Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

create or replace function public.check_arrival(_cid uuid) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare ch characters; s seasons; rk int; prize int; c jsonb := cfg(); fim boolean;
begin
  select * into ch from characters where id = _cid for update;
  if ch.arrived_rank is not null or (select kind from board_nodes where id = ch.node) <> 'castelo' then return null; end if;
  select * into s from seasons order by id desc limit 1 for update;
  -- a corrida já acabou (a Liga desta temporada começou): chega sem prêmio
  fim := exists (select 1 from leagues where season_id = s.id and started_at >= s.started_on);
  rk := (select count(*) from characters where arrived_rank is not null) + 1;
  prize := case when s.status = 'ativa' and not fim then coalesce((c->'castle_prizes'->>(rk-1))::int, 0) else 0 end;
  update characters set arrived_rank = rk, arrived_at = now(), coins = coins + prize where id = _cid;
  if s.status = 'ativa' and not fim and rk <= (c->>'season_arrivals')::int then
    insert into season_results(season_id, user_id, rank) values (s.id, ch.user_id, rk) on conflict do nothing;
  end if;
  if fim then return 'Você chegou ao Castelo, mas a corrida desta temporada já terminou. A Liga Pokémon está em andamento!'; end if;
  insert into event_log(user_id, kind, message) values (ch.user_id, 'castelo',
    ch.name || ' chegou ao Castelo da Liga em ' || rk || 'º lugar!' || case when rk = 1 then ' A corrida termina quando a rodada de hoje fechar, e aí começa a Liga Pokémon!' else '' end);
  return 'Você chegou ao Castelo da Liga em ' || rk || 'º lugar!' || case when prize > 0 then ' Prêmio: ' || prize || ' moedas.' else '' end
    || ' A corrida termina quando a rodada de hoje fechar (meia-noite). Depois começa a Liga Pokémon!';
end $$;

create or replace function public.league_maybe_start(_force boolean default false) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare s seasons; lid int; n int; narr int; first_day date; c jsonb := cfg(); r record; prize int; quem text;
begin
  select * into s from seasons order by id desc limit 1;
  -- uma Liga por temporada (a data protege contra temporadas renumeradas pelo arquivo 14)
  if s.id is null or s.status <> 'ativa' or exists (select 1 from leagues where season_id = s.id and started_at >= s.started_on) then return null; end if;
  select count(*), min((arrived_at at time zone coalesce(c->>'timezone', 'America/Sao_Paulo'))::date) into narr, first_day
    from characters where arrived_rank is not null;
  if narr < 1 then return null; end if;
  -- a corrida acaba quando fecha a rodada do dia em que o 1º chegou (o admin pode forçar)
  if not _force and first_day >= public.game_today() then return null; end if;
  insert into leagues(season_id, name) values (s.id, 'Liga ' || s.id) returning id into lid;
  -- classificação final: quem chegou (pela ordem), depois quem está mais perto do Castelo
  insert into league_players(league_id, user_id, name, seed)
  select lid, x.user_id, x.name, row_number() over (order by x.arrived_rank nulls last, x.arrived_at, x.dist, x.xp desc)
    from (select ch.user_id, ch.name, ch.arrived_rank, ch.arrived_at, coalesce(b.dist, 9999) dist, coalesce(ch.xp_total, 0) xp
            from characters ch left join board_nodes b on b.id = ch.node
           where ch.arrived_rank is not null or ch.user_id in (select a.user_id from public.day_active(public.game_today()) a)) x;
  select count(*) into n from league_players where league_id = lid;
  if n < 2 then delete from leagues where id = lid; return null; end if;
  -- prêmio do Castelo e pódio para quem não chegou, pela posição no mapa
  for r in select lp.user_id, lp.seed, ch.name from league_players lp join characters ch on ch.user_id = lp.user_id
            where lp.league_id = lid and ch.arrived_rank is null order by lp.seed loop
    prize := coalesce((c->'castle_prizes'->>(r.seed - 1))::int, 0);
    if prize > 0 then
      update characters set coins = coins + prize where user_id = r.user_id;
      insert into event_log(user_id, kind, message) values (r.user_id, 'castelo', r.name || ' terminou a corrida em ' || r.seed || 'º lugar no mapa e ganhou ' || prize || ' moedas.');
    end if;
    if r.seed <= (c->>'season_arrivals')::int then
      insert into season_results(season_id, user_id, rank) values (s.id, r.user_id, r.seed) on conflict do nothing;
    end if;
  end loop;
  select name into quem from league_players where league_id = lid and seed = 1;
  insert into event_log(kind, message) values ('liga', '🏁 A corrida acabou! ' || quem || ' chegou primeiro ao Castelo. Começou a Liga ' || s.id || ', com ' || n
    || ' treinadores: o 1º da corrida enfrenta o último, o 2º o penúltimo... Uma rodada por dia.');
  perform public.league_next_stage(lid);
  return lid;
end $$;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🏁 Novo fim de temporada: o 1º no Castelo encerra a corrida', 'Mudou o fim da temporada:
• O primeiro jogador que chegar ao Castelo encerra a corrida. Os outros ainda jogam o resto daquele dia.
• Quando a rodada daquele dia fecha (meia-noite), a corrida acaba e a Liga Pokémon começa na hora, com todos os jogadores ativos.
• Os prêmios do Castelo vão pela posição: o 1º é quem chegou primeiro; o 2º, o 3º e os seguintes são quem estava mais perto do Castelo.
• As chaves da Liga seguem essa classificação: o 1º da corrida enfrenta o último, o 2º o penúltimo...
Corra, porque agora cada casa conta!')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
