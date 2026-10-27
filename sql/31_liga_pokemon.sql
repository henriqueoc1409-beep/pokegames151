-- =====================================================================
-- POKEGAMES — Novo final de temporada: a LIGA POKÉMON (pedido do dono em 22/10/2026).
--   1) A temporada não acaba mais com 3 chegadas. Quando TODOS OS ATIVOS (jogaram nos
--      últimos 7 dias) chegam ao Castelo, começa a Liga. O admin pode começar antes.
--      O prêmio por ordem de chegada ao Castelo continua (500, 300, 150 moedas).
--   2) Mata-mata em batalhas Pokémon TURNO A TURNO (as mesmas batalhas de sempre, sem prazo,
--      com a vida sempre cheia no começo de cada luta). Chaveamento pela ordem de chegada:
--      o 1º enfrenta o último, o 2º o penúltimo e assim por diante. Se o número for ímpar,
--      os dois piores fazem antes uma REPESCAGEM e o vencedor entra no mata-mata.
--      Uma rodada por dia (a repescagem não conta: assim que termina, a rodada sai).
--      Quem tem 1 ou 2 Pokémon luta com o que tem; sem nenhum, perde por W.O.
--      Empate: passa quem chegou antes ao Castelo. Luta travada: o admin pode dar W.O.
--      As lutas aparecem na Arena para todos assistirem e torcerem.
--   3) O CAMPEÃO ganha a Aura Dourada do Campeão (com o nome da liga), um castelo na vila e a
--      estátua no mapa (sempre o campeão mais recente). Ele entra na CAVERNA: um lendário
--      (nível = média dos Pokémon de todos os jogadores) fica à vista por 24 horas, e todos
--      podem torcer a favor ou contra. Depois das 24 h, ele tem UMA tentativa, com 5% de chance
--      (league_capture_pct). Se não tentar em mais 24 h, o lendário foge.
--   4) Depois da caverna a temporada fecha e, no dia seguinte, todos voltam à largada sem
--      perder nada (como sempre).
-- Depende do 09, 15, 17, 18, 24, 28 e 29. Não apaga nada. Antes, faça a cópia de segurança.
-- =====================================================================

update public.game_config set config = config || '{"league_capture_pct": 5, "league_cave_hours": 24}'::jsonb where active and not (config ? 'league_capture_pct');

-- ---------- 1) tabelas ----------
create table if not exists public.leagues (
  id            serial primary key,
  season_id     int not null,                      -- sem ligação forte com seasons: o arquivo 14 (recomeçar do zero) apaga e renumera as temporadas
  name          text not null,
  status        text not null default 'rodada' check (status in ('rodada', 'caverna', 'encerrada')),
  stage         int not null default 0,          -- rodada atual (repescagens contam como etapa própria)
  stage_kind    text,                            -- 'repescagem' ou 'rodada'
  stage_day     date,                            -- dia em que a etapa atual começou
  champion      uuid references auth.users(id) on delete set null,
  champion_name text,
  legend_id     int,
  legend_level  int,
  cave_open_at  timestamptz,                     -- a partir de quando o campeão pode tentar
  cave_result   text check (cave_result in ('capturou', 'fugiu')),
  cave_tried_at timestamptz,
  aura_item     text,
  started_at    timestamptz not null default now(),
  ended_at      timestamptz
);
create index if not exists leagues_season on public.leagues (season_id);
create table if not exists public.league_players (
  league_id   int not null references public.leagues(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  name        text not null,
  seed        int not null,                       -- ordem de chegada ao Castelo
  out_stage   int,                                -- em que etapa caiu (vazio = ainda vivo)
  primary key (league_id, user_id)
);
create table if not exists public.league_matches (
  id         uuid primary key default gen_random_uuid(),
  league_id  int not null references public.leagues(id) on delete cascade,
  stage      int not null,
  kind       text not null check (kind in ('repescagem', 'rodada')),
  a          uuid not null, b uuid not null,      -- a = melhor colocado
  battle_id  uuid references public.battles(id) on delete set null,
  winner     uuid,
  status     text not null default 'ativa' check (status in ('ativa', 'encerrada', 'wo')),
  created_at timestamptz not null default now()
);
create index if not exists league_matches_lg on public.league_matches (league_id, stage);
create table if not exists public.cave_votes (
  league_id int not null references public.leagues(id) on delete cascade,
  user_id   uuid not null references auth.users(id) on delete cascade,
  side      text not null check (side in ('favor', 'contra')),
  primary key (league_id, user_id)
);
create table if not exists public.cave_cheers (
  id         bigint generated always as identity primary key,
  league_id  int not null references public.leagues(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  name       text not null,
  side       text,
  body       text not null,
  created_at timestamptz not null default now()
);
alter table public.shop_items add column if not exists exclusive boolean not null default false;   -- prêmio que não está à venda

alter table public.leagues enable row level security;
alter table public.league_players enable row level security;
alter table public.league_matches enable row level security;
alter table public.cave_votes enable row level security;
alter table public.cave_cheers enable row level security;
drop policy if exists p_lg on public.leagues;         create policy p_lg on public.leagues for select to authenticated using (true);
drop policy if exists p_lgp on public.league_players; create policy p_lgp on public.league_players for select to authenticated using (true);
drop policy if exists p_lgm on public.league_matches; create policy p_lgm on public.league_matches for select to authenticated using (true);
drop policy if exists p_cv on public.cave_votes;      create policy p_cv on public.cave_votes for select to authenticated using (true);
drop policy if exists p_cc on public.cave_cheers;     create policy p_cc on public.cave_cheers for select to authenticated using (true);
revoke all on public.leagues, public.league_players, public.league_matches, public.cave_votes, public.cave_cheers from anon, authenticated;
grant select on public.leagues, public.league_players, public.league_matches, public.cave_votes, public.cave_cheers to authenticated;
do $$ begin
  begin alter publication supabase_realtime add table public.leagues; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.league_matches; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.cave_votes; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.cave_cheers; exception when duplicate_object then null; end;
end $$;

-- ---------- 2) lutas da Liga ----------
-- monta um lado da batalha: a equipe (até 3); sem equipe, os 3 de nível mais alto; vida cheia
create or replace function public.league_side(_uid uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare mons jsonb;
begin
  select jsonb_agg(public.bt_mon(x.id) order by x.team_slot) into mons
    from (select id, team_slot from monsters where user_id = _uid and team_slot is not null order by team_slot limit 3) x;
  if mons is null then   -- sem equipe montada: os 3 de nível mais alto
    select jsonb_agg(public.bt_mon(x.id) order by x.level desc) into mons
      from (select id, level from monsters where user_id = _uid order by level desc limit 3) x;
  end if;
  if mons is null then return null; end if;
  return jsonb_build_object('user', _uid, 'name', (select name from characters where user_id = _uid), 'active', 0, 'need_switch', false, 'mons', mons);
end $$;

create or replace function public.league_make_match(_lg int, _stage int, _kind text, _a uuid, _b uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare sa jsonb := public.league_side(_a); sb jsonb := public.league_side(_b); bid uuid; mid uuid; lg leagues;
begin
  select * into lg from leagues where id = _lg;
  insert into league_matches(league_id, stage, kind, a, b) values (_lg, _stage, _kind, _a, _b) returning id into mid;
  if sa is null or sb is null then   -- sem Pokémon: W.O. (se os dois não têm, passa o melhor colocado)
    perform public.league_decide(mid, case when sa is null and sb is not null then _b else _a end, true);
    return;
  end if;
  insert into battles(p1, p2, size, status, turn, phase, started_at, mode, state, log)
  values (_a, _b, 3, 'ativa', 1, 'normal', now(), 'liga', jsonb_build_object('sides', jsonb_build_array(sa, sb), 'xp', '{}'::jsonb),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', '🏆 ' || lg.name || ': ' || (sa->>'name') || ' x ' || (sb->>'name') || case when _kind = 'repescagem' then ' (repescagem)' else '' end || '!'),
            jsonb_build_object('txt', (sa->>'name') || ' mandou ' || (sa->'mons'->0->>'name') || '!'),
            jsonb_build_object('txt', (sb->>'name') || ' mandou ' || (sb->'mons'->0->>'name') || '!')))))
  returning id into bid;
  update league_matches set battle_id = bid where id = mid;
end $$;

-- cria a próxima etapa (repescagem se ímpar; senão 1º x último, 2º x penúltimo...) ou coroa o campeão
create or replace function public.league_next_stage(_lg int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare lg leagues; alive uuid[]; n int; i int; st int;
begin
  select * into lg from leagues where id = _lg for update;
  if lg.status <> 'rodada' then return; end if;
  select array_agg(user_id order by seed) into alive from league_players where league_id = _lg and out_stage is null;
  n := coalesce(cardinality(alive), 0);
  if n <= 1 then perform public.league_crown(_lg, alive[1]); return; end if;
  st := lg.stage + 1;
  if n % 2 = 1 then
    update leagues set stage = st, stage_kind = 'repescagem', stage_day = public.game_today() where id = _lg;
    insert into event_log(kind, message) values ('liga', lg.name || ': repescagem entre ' || (select name from characters where user_id = alive[n - 1]) || ' e ' || (select name from characters where user_id = alive[n]) || '. Quem vencer entra no mata-mata!');
    perform public.league_make_match(_lg, st, 'repescagem', alive[n - 1], alive[n]);
  else
    update leagues set stage = st, stage_kind = 'rodada', stage_day = public.game_today() where id = _lg;
    insert into event_log(kind, message) values ('liga', lg.name || ': começou a ' || case n when 2 then 'GRANDE FINAL' when 4 then 'semifinal' when 8 then 'rodada das quartas de final' when 16 then 'rodada das oitavas de final' else 'rodada com ' || n || ' treinadores' end || '!');
    for i in 1 .. n / 2 loop perform public.league_make_match(_lg, st, 'rodada', alive[i], alive[n + 1 - i]); end loop;
  end if;
end $$;

-- resultado de uma luta da Liga (uma vez só)
create or replace function public.league_decide(_match uuid, _winner uuid, _wo boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare m league_matches; lg leagues; loser uuid; w uuid;
begin
  select * into m from league_matches where id = _match for update;
  if m.id is null or m.status <> 'ativa' then return; end if;
  w := coalesce(_winner, m.a);                    -- empate: passa o melhor colocado
  loser := case when w = m.a then m.b else m.a end;
  update league_matches set winner = w, status = case when _wo then 'wo' else 'encerrada' end where id = m.id;
  update league_players set out_stage = m.stage where league_id = m.league_id and user_id = loser;
  select * into lg from leagues where id = m.league_id;
  insert into event_log(user_id, kind, message) values (w, 'liga', lg.name || ': ' || (select name from characters where user_id = w) || ' venceu ' || (select name from characters where user_id = loser) || case when _wo then ' por W.O.' else '' end || ' e segue na Liga!');
  -- terminou a etapa? repescagem libera a rodada na hora; rodada normal espera o dia seguinte (league_tick)
  if not exists (select 1 from league_matches where league_id = m.league_id and stage = m.stage and status = 'ativa') then
    if lg.stage_kind = 'repescagem' or (select count(*) from league_players where league_id = m.league_id and out_stage is null) = 1 then
      perform public.league_next_stage(m.league_id);
    end if;
  end if;
end $$;

-- campeão: aura, castelo, estátua e a caverna com o lendário
create or replace function public.league_crown(_lg int, _champ uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare lg leagues; nm text; leg int; lv int; item text; pool int[] := array[144, 145, 146, 150, 151];
begin
  select * into lg from leagues where id = _lg for update;
  if lg.status <> 'rodada' or _champ is null then return; end if;
  select name into nm from characters where user_id = _champ;
  if public.gen2_on() then pool := pool || array[243, 244, 245, 249, 250, 251]; end if;
  leg := pool[1 + floor(random() * cardinality(pool))::int];
  select greatest(5, least(100, round(avg(level))))::int into lv from monsters;
  item := 'aura_campeao_' || lg.season_id;
  insert into shop_items(id, name, slot, price, min_level, rarity, data, exclusive, coins_ok)
  values (item, 'Aura do Campeão: ' || lg.name, 'aura', 0, 1, 'lendario', jsonb_build_object('c1', '#FFD54A', 'shiny', true, 'league', lg.name), true, false)
  on conflict (id) do nothing;
  update characters set owned_items = case when item = any(owned_items) then owned_items else array_append(owned_items, item) end where user_id = _champ;
  insert into villages(user_id) values (_champ) on conflict do nothing;
  update villages set castles = castles + 1 where user_id = _champ;
  update leagues set status = 'caverna', champion = _champ, champion_name = nm, legend_id = leg, legend_level = coalesce(lv, 30), aura_item = item,
         cave_open_at = now() + make_interval(hours => coalesce((public.cfg()->>'league_cave_hours')::int, 24)) where id = _lg;
  insert into event_log(user_id, kind, message) values (_champ, 'liga', '🏆 ' || nm || ' é o CAMPEÃO da ' || lg.name || '! Ganhou a Aura do Campeão e uma estátua no mapa, e entrou na caverna do ' ||
    (select name from pokemon where id = leg) || '. Daqui a 24 horas terá UMA chance de capturá-lo. Torça a favor ou contra!');
end $$;

-- a Liga começa quando todos os ativos chegaram ao Castelo (ou pelo admin)
create or replace function public.league_maybe_start(_force boolean default false) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare s seasons; lid int; n int;
begin
  select * into s from seasons order by id desc limit 1;
  -- uma Liga por temporada (a data protege contra temporadas renumeradas pelo arquivo 14)
  if s.id is null or s.status <> 'ativa' or exists (select 1 from leagues where season_id = s.id and started_at >= s.started_on) then return null; end if;
  select count(*) into n from characters where arrived_rank is not null;
  if n < 2 then return null; end if;
  if not _force and exists (select 1 from public.day_active(public.game_today()) a join characters ch on ch.user_id = a.user_id where ch.arrived_rank is null) then return null; end if;
  insert into leagues(season_id, name) values (s.id, 'Liga ' || s.id) returning id into lid;
  insert into league_players(league_id, user_id, name, seed)
  select lid, user_id, name, row_number() over (order by arrived_rank, arrived_at) from characters where arrived_rank is not null;
  insert into event_log(kind, message) values ('liga', '🏆 Todos chegaram ao Castelo: começou a Liga ' || s.id || ', com ' || n || ' treinadores! O 1º a chegar enfrenta o último, o 2º o penúltimo... Uma rodada por dia.');
  perform public.league_next_stage(lid);
  return lid;
end $$;

-- chamado pelo fechamento do dia: nova rodada (uma por dia) e fim da caverna sem tentativa
create or replace function public.league_tick() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare lg leagues;
begin
  perform public.league_maybe_start(false);
  select * into lg from leagues order by id desc limit 1;
  if lg.id is null then return; end if;
  if lg.status = 'rodada' and lg.stage_day < public.game_today()
     and not exists (select 1 from league_matches where league_id = lg.id and stage = lg.stage and status = 'ativa') then
    perform public.league_next_stage(lg.id);
  elsif lg.status = 'caverna' and lg.cave_tried_at is null
     and now() > lg.cave_open_at + make_interval(hours => coalesce((public.cfg()->>'league_cave_hours')::int, 24)) then
    perform public.league_cave_end(lg.id, false);
  end if;
end $$;

-- fecha a caverna e a temporada (no dia seguinte, todos voltam à largada)
create or replace function public.league_cave_end(_lg int, _caught boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare lg leagues; pn text;
begin
  select * into lg from leagues where id = _lg for update;
  if lg.status <> 'caverna' then return; end if;
  select name into pn from pokemon where id = lg.legend_id;
  if _caught then
    perform public.pk_new_monster(lg.champion, lg.legend_id, lg.legend_level);
    perform public.pk_dex_mark(lg.champion, lg.legend_id, true);
  end if;
  update leagues set status = 'encerrada', cave_result = case when _caught then 'capturou' else 'fugiu' end, ended_at = now() where id = lg.id;
  update seasons set status = 'encerrada', ended_on = public.game_today() where id = lg.season_id and status = 'ativa';
  insert into event_log(user_id, kind, message) values (lg.champion, 'liga', case when _caught
    then '🎉 INACREDITÁVEL! ' || lg.champion_name || ' capturou o lendário ' || pn || ' (nível ' || lg.legend_level || ')!'
    else '💨 O lendário ' || pn || ' escapou de ' || lg.champion_name || '... Fica para a próxima Liga!' end
    || ' Amanhã começa uma nova temporada: todos voltam à largada.');
end $$;

-- ---------- 3) funções do site ----------
create or replace function public.league_cave_try() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); lg leagues; ok boolean;
begin
  select * into lg from leagues where status = 'caverna' order by id desc limit 1 for update;
  if lg.id is null then raise exception 'Não há ninguém na caverna agora.'; end if;
  if lg.champion <> uid then raise exception 'Só o campeão da Liga pode tentar capturar o lendário.'; end if;
  if now() < lg.cave_open_at then raise exception 'O lendário ainda não se aproximou. Tente depois de %.', to_char(lg.cave_open_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'); end if;
  ok := random() * 100 < coalesce((public.cfg()->>'league_capture_pct')::numeric, 5);
  update leagues set cave_tried_at = now() where id = lg.id;
  perform public.league_cave_end(lg.id, ok);
  return jsonb_build_object('caught', ok, 'pokemon', lg.legend_id, 'level', lg.legend_level);
end $$;

create or replace function public.league_cave_vote(_side text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); lg leagues;
begin
  select * into lg from leagues where status = 'caverna' order by id desc limit 1;
  if lg.id is null then raise exception 'Não há ninguém na caverna agora.'; end if;
  if uid = lg.champion then raise exception 'O campeão não torce: ele vai tentar a captura!'; end if;
  if _side is null then delete from cave_votes where league_id = lg.id and user_id = uid; return; end if;
  if _side not in ('favor', 'contra') then raise exception 'Escolha a favor ou contra.'; end if;
  insert into cave_votes(league_id, user_id, side) values (lg.id, uid, _side) on conflict (league_id, user_id) do update set side = excluded.side;
end $$;

create or replace function public.league_cave_cheer(_body text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); lg leagues; me characters; txt text := btrim(coalesce(_body, '')); r cave_cheers;
begin
  select * into lg from leagues where status = 'caverna' order by id desc limit 1;
  if lg.id is null then raise exception 'Não há ninguém na caverna agora.'; end if;
  select * into me from characters where user_id = uid;
  if txt = '' then raise exception 'Escreva alguma coisa.'; end if;
  if char_length(txt) > 120 then raise exception 'A mensagem pode ter no máximo 120 letras.'; end if;
  if exists (select 1 from arena_mutes where user_id = uid and until > now()) then raise exception 'O administrador silenciou você.'; end if;
  if exists (select 1 from cave_cheers where user_id = uid and created_at > now() - interval '3 seconds') then raise exception 'Calma! Espere alguns segundos.'; end if;
  if (select count(*) from cave_cheers where user_id = uid and created_at > now() - interval '1 minute') >= 10 then raise exception 'Muitas mensagens seguidas. Espere um minuto.'; end if;
  insert into cave_cheers(league_id, user_id, name, side, body) values (lg.id, uid, me.name, (select side from cave_votes where league_id = lg.id and user_id = uid), txt) returning * into r;
  return to_jsonb(r);
end $$;

-- admin: começar a Liga antes de todos chegarem, e dar W.O. numa luta travada
create or replace function public.admin_league_start() returns int
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); lid int;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador começa a Liga.'; end if;
  lid := public.league_maybe_start(true);
  if lid is null then raise exception 'Não dá para começar: precisa de pelo menos 2 treinadores no Castelo, e não pode já ter uma Liga nesta temporada.'; end if;
  insert into admin_audit_log(admin_id, action, target) values (uid, 'liga_comecar', lid::text);
  return lid;
end $$;

create or replace function public.admin_league_wo(_match uuid, _winner uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); m league_matches;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador decide uma luta.'; end if;
  select * into m from league_matches where id = _match;
  if m.id is null or m.status <> 'ativa' then raise exception 'Essa luta não está em andamento.'; end if;
  if _winner not in (m.a, m.b) then raise exception 'O vencedor precisa ser um dos dois.'; end if;
  insert into admin_audit_log(admin_id, action, target, after) values (uid, 'liga_wo', _match::text, jsonb_build_object('vencedor', _winner));
  if m.battle_id is not null then
    update battles set log = log || jsonb_build_array(jsonb_build_object('turn', turn, 'lines', jsonb_build_array(jsonb_build_object('txt', 'O administrador encerrou a luta por W.O.')))) where id = m.battle_id and status = 'ativa';
    perform public.bt_finish(m.battle_id, _winner, 'wo');
  end if;
  perform public.league_decide(m.id, _winner, true);
end $$;

-- chegada ao Castelo (versão do 09: prêmio por ordem continua; a temporada só fecha depois da Liga)
create or replace function public.check_arrival(_cid uuid) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare ch characters; s seasons; rk int; prize int; c jsonb := cfg();
begin
  select * into ch from characters where id = _cid for update;
  if ch.arrived_rank is not null or (select kind from board_nodes where id = ch.node) <> 'castelo' then return null; end if;
  select * into s from seasons order by id desc limit 1 for update;
  rk := (select count(*) from characters where arrived_rank is not null) + 1;
  prize := case when s.status = 'ativa' then coalesce((c->'castle_prizes'->>(rk-1))::int, 0) else 0 end;
  update characters set arrived_rank = rk, arrived_at = now(), coins = coins + prize where id = _cid;
  if s.status = 'ativa' and rk <= (c->>'season_arrivals')::int then
    insert into season_results(season_id, user_id, rank) values (s.id, ch.user_id, rk) on conflict do nothing;
  end if;
  insert into event_log(user_id, kind, message) values (ch.user_id, 'castelo', ch.name || ' chegou ao Castelo da Liga em ' || rk || 'º lugar!');
  -- a temporada não fecha mais com 3 chegadas: quando todos os ativos chegam, começa a Liga
  perform public.league_maybe_start(false);
  return 'Você chegou ao Castelo da Liga em ' || rk || 'º lugar!' || case when prize > 0 then ' Prêmio: ' || prize || ' moedas.' else '' end || ' Quando todos chegarem, começa a Liga Pokémon!';
end $$;

-- fechamento do dia (versão do 09 + andamento da Liga)
create or replace function public.settle() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare d date := game_today(); c jsonb := cfg(); r record; x record; pos int; bs int; bc int; s seasons; names text := ''; lastu uuid; firstu uuid;
begin
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
  select * into s from seasons order by id desc limit 1;
  if s.status = 'encerrada' and s.ended_on < d then perform public.start_new_season(); end if;
end $$;

-- encerramento da batalha (versão do 29 + resultado das lutas da Liga)
create or replace function public.bt_finish(_id uuid, _winner uuid, _reason text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b battles; c jsonb := public.pk_cfg(); k text; v int; owner uuid; limit_n int := (c->'xp'->>'battles_per_day')::int; wn text; ln text;
begin
  select * into b from battles where id = _id for update;
  if b.status <> 'ativa' then return; end if;
  update battles set status = 'encerrada', winner = _winner, end_reason = _reason, ended_at = now(), deadline = null where id = b.id;
  -- aposta: quem vence leva as duas partes; empate devolve a de cada um (uma única vez)
  if b.bet > 0 and b.bet_paid and not b.bet_paid_out then
    if _winner is null then update characters set coins = coins + b.bet where user_id in (b.p1, b.p2);
    else update characters set coins = coins + 2 * b.bet where user_id = _winner; end if;
    update battles set bet_paid_out = true where id = b.id;
  end if;
  if b.rewarded then
    if b.mode = 'liga' then perform public.league_decide((select id from league_matches where battle_id = b.id), _winner, false); end if;
    return;
  end if;
  -- XP dos Pokémon que derrubaram adversários, só nas primeiras batalhas do dia de cada dono (guerras contam no mesmo limite)
  for k, v in select key, value::int from jsonb_each_text(coalesce(b.state->'xp', '{}'::jsonb)) loop
    select user_id into owner from monsters where id = k::uuid;
    if owner is null then continue; end if;
    if (select count(*) from battles x where x.status = 'encerrada' and x.rewarded and owner in (x.p1, x.p2)
          and (x.ended_at at time zone coalesce(public.cfg()->>'timezone','America/Sao_Paulo'))::date = public.game_today()) >= limit_n then continue; end if;
    perform public.pk_give_xp(k::uuid, v, 'batalha');
  end loop;
  update battles set rewarded = true where id = b.id;
  if b.mode = 'liga' then perform public.league_decide((select id from league_matches where battle_id = b.id), _winner, false); end if;
  if b.mode in ('guerra', 'liga') then return; end if;
  select name into wn from characters where user_id = _winner;
  select name into ln from characters where user_id = case when _winner = b.p1 then b.p2 else b.p1 end;
  if _winner is not null then insert into event_log(user_id, kind, message) values (_winner, 'batalha', wn || ' venceu a batalha Pokémon contra ' || ln || case when b.bet > 0 and b.bet_paid then ' e levou ' || 2 * b.bet || ' moedas' else '' end || '!'); end if;
end $$;

-- resumo da Arena (versão do 29 + modo, para mostrar as lutas da Liga)
create or replace function public.arena_sync(_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b battles; s jsonb; a0 jsonb; a1 jsonb; ln text; tm jsonb;
begin
  select * into b from battles where id = _id;
  if b.id is null then return; end if;
  if b.status not in ('ativa', 'encerrada') then delete from arena_battles where battle_id = b.id; return; end if;
  s := b.state;
  a0 := s->'sides'->0->'mons'->((s->'sides'->0->>'active')::int);
  a1 := s->'sides'->1->'mons'->((s->'sides'->1->>'active')::int);
  select l->>'txt' into ln from jsonb_array_elements(coalesce(b.log->-1->'lines', '[]'::jsonb)) with ordinality x(l, o) order by o desc limit 1;
  if b.status = 'encerrada' then
    select jsonb_agg(jsonb_build_object('user', sd->'user', 'mons',
             (select jsonb_agg(jsonb_build_object('species', m->'species', 'name', m->'name', 'level', m->'level', 'out', (m->>'hp')::int <= 0)) from jsonb_array_elements(sd->'mons') m)))
      into tm from jsonb_array_elements(s->'sides') sd;
  end if;
  insert into arena_battles as a (battle_id, p1, p2, name1, name2, status, turn, phase, wait1, wait2, mon1, mon2, left1, left2, size,
                                  last_line, turn_at, acted_at, away1, away2, winner, end_reason, teams, started_at, ended_at, updated_at, bet, mode)
  values (b.id, b.p1, b.p2, s->'sides'->0->>'name', s->'sides'->1->>'name', b.status, b.turn, b.phase,
          b.status = 'ativa' and not b.ready1, b.status = 'ativa' and not b.ready2,
          public.arena_mon(a0), public.arena_mon(a1),
          (select count(*) from jsonb_array_elements(s->'sides'->0->'mons') m where (m->>'hp')::int > 0),
          (select count(*) from jsonb_array_elements(s->'sides'->1->'mons') m where (m->>'hp')::int > 0),
          jsonb_array_length(coalesce(s->'sides'->0->'mons', '[]'::jsonb)),
          ln, b.turn_at, b.acted_at, b.away1, b.away2, b.winner, b.end_reason, tm, b.started_at, b.ended_at, now(), b.bet, b.mode)
  on conflict (battle_id) do update set status = excluded.status, turn = excluded.turn, phase = excluded.phase, wait1 = excluded.wait1, wait2 = excluded.wait2,
    mon1 = excluded.mon1, mon2 = excluded.mon2, left1 = excluded.left1, left2 = excluded.left2, size = excluded.size, last_line = excluded.last_line,
    turn_at = excluded.turn_at, acted_at = excluded.acted_at, away1 = excluded.away1, away2 = excluded.away2, winner = excluded.winner,
    end_reason = excluded.end_reason, teams = excluded.teams, started_at = excluded.started_at, ended_at = excluded.ended_at, updated_at = now(), bet = excluded.bet, mode = excluded.mode;
end $$;

-- ---------- permissões ----------
revoke execute on function public.league_side(uuid), public.league_make_match(int, int, text, uuid, uuid), public.league_next_stage(int),
  public.league_decide(uuid, uuid, boolean), public.league_crown(int, uuid), public.league_maybe_start(boolean), public.league_tick(),
  public.league_cave_end(int, boolean) from public, anon, authenticated;
revoke execute on function public.league_cave_try(), public.league_cave_vote(text), public.league_cave_cheer(text), public.admin_league_start(),
  public.admin_league_wo(uuid, uuid) from public, anon;
grant execute on function public.league_cave_try(), public.league_cave_vote(text), public.league_cave_cheer(text), public.admin_league_start(),
  public.admin_league_wo(uuid, uuid) to authenticated;

-- se a temporada atual já tem todos os ativos no Castelo, a Liga começa agora
select public.league_maybe_start(false);
