-- =====================================================================
-- POKEGAMES — Prêmios da temporada (pedido do dono em 27/10/2026).
--
-- Quando a temporada fecha (fim da caverna do lendário, league_cave_end),
-- o 1º lugar de cada uma das 12 categorias ganha 150 moedas
-- (season_awards.coins no game_config), uma medalha no cartão e um
-- presente no Correio; o Jornal anuncia todos. Empate: todos os empatados
-- ganham. Categorias (contadas só dentro da temporada):
--   casas (mais casas andadas), capturas (Pokémon capturados), rodadas
--   (vitórias na rodada do dia), batalhas (batalhas Pokémon vencidas contra
--   jogadores, inclusive na Liga), duelos (duelos vencidos), rocket (dano na
--   Equipe Rocket), quiz (quizzes vencidos), treinadores (treinadores do mapa
--   vencidos), moedas (moedas ganhas nas andadas), primeira (acertos de
--   primeira no desafio), pokedex (espécies novas na Pokédex), cacadas
--   (Caçadas vencidas).
-- O placar ao vivo (season_board) conta só até ontem, para não dar spoiler
-- da jogada de hoje. admin_season_awards() entrega à mão, se a temporada
-- fechar de outro jeito (por exemplo, pelo botão "nova temporada").
-- Depende do 31, 38, 43, 44, 46. Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

create table if not exists public.season_awards (
  id         bigserial primary key,
  season_id  int not null,
  category   text not null,
  user_id    uuid not null references auth.users(id) on delete cascade,
  value      numeric not null,
  coins      int not null default 0,
  created_at timestamptz not null default now(),
  unique (season_id, category, user_id)
);
alter table public.season_awards enable row level security;
drop policy if exists p_saw on public.season_awards;
create policy p_saw on public.season_awards for select to authenticated using (true);   -- as medalhas são públicas
revoke all on public.season_awards from anon, authenticated;
grant select on public.season_awards to authenticated;

-- as categorias, com nome, título da medalha e ícone (o site lê daqui)
create or replace function public.season_award_cats() returns jsonb
language sql immutable as $$
  select '[
    {"id":"casas","nome":"Mais casas andadas","titulo":"Andarilho da Temporada","ic":"🥾","un":"casas"},
    {"id":"capturas","nome":"Mais Pokémon capturados","titulo":"Rei das Capturas","ic":"🎯","un":"capturas"},
    {"id":"rodadas","nome":"Mais vitórias na rodada do dia","titulo":"Mestre do Desafio","ic":"🧠","un":"vitórias"},
    {"id":"batalhas","nome":"Mais batalhas Pokémon vencidas","titulo":"Campeão das Batalhas","ic":"⚔️","un":"vitórias"},
    {"id":"duelos","nome":"Mais duelos vencidos","titulo":"Duelista da Temporada","ic":"🤺","un":"vitórias"},
    {"id":"rocket","nome":"Mais dano na Equipe Rocket","titulo":"Terror da Rocket","ic":"🚀","un":"de dano"},
    {"id":"quiz","nome":"Mais vitórias no Quiz","titulo":"Gênio do Quiz","ic":"❓","un":"vitórias"},
    {"id":"treinadores","nome":"Mais treinadores vencidos","titulo":"Caçador de Treinadores","ic":"🧢","un":"vitórias"},
    {"id":"moedas","nome":"Mais moedas ganhas andando","titulo":"Magnata","ic":"💰","un":"moedas"},
    {"id":"primeira","nome":"Mais acertos de primeira","titulo":"Olho de Águia","ic":"👁️","un":"acertos"},
    {"id":"pokedex","nome":"Mais espécies novas na Pokédex","titulo":"Pesquisador Pokémon","ic":"📖","un":"espécies"},
    {"id":"cacadas","nome":"Mais Caçadas vencidas","titulo":"Caçador de Lendas","ic":"🔍","un":"Caçadas"}
  ]'::jsonb
$$;

-- o número de cada jogador numa categoria, entre _t0 (começo da temporada) e _t1 (exclusivo)
create or replace function public.season_rank(_cat text, _t0 timestamptz, _t1 timestamptz)
returns table(user_id uuid, val numeric)
language plpgsql stable security definer set search_path = public, extensions as $$
declare d0 date := (_t0 at time zone 'America/Sao_Paulo')::date;
        d1 date := ((_t1 at time zone 'America/Sao_Paulo') - interval '1 second')::date;   -- último dia que conta
begin
  if _cat = 'casas' then return query
    select m.user_id, sum(m.base_steps + m.roll + m.bonus_steps + coalesce(m.skill_steps, 0))::numeric from daily_moves m where m.move_date between d0 and d1 group by 1;
  elsif _cat = 'moedas' then return query
    select m.user_id, sum(greatest(m.coins_gained, 0))::numeric from daily_moves m where m.move_date between d0 and d1 group by 1;
  elsif _cat = 'capturas' then return query
    select e.user_id, count(*)::numeric from encounters e where e.status = 'capturado' and e.resolved_at >= _t0 and e.resolved_at < _t1 group by 1;
  elsif _cat = 'rodadas' then return query
    select r.user_id, count(*)::numeric from round_results r where r.rank = 1 and r.d between d0 and d1 group by 1;
  elsif _cat = 'batalhas' then return query
    select b.winner, count(*)::numeric from battles b where b.status = 'encerrada' and b.winner is not null and b.p1 <> b.p2
      and coalesce(b.mode, 'duelo') in ('duelo', 'liga') and b.ended_at >= _t0 and b.ended_at < _t1 group by 1;
  elsif _cat = 'duelos' then return query
    select d.winner, count(*)::numeric from duels d where d.status = 'concluido' and d.winner is not null
      and coalesce(d.resolved_at, d.created_at) >= _t0 and coalesce(d.resolved_at, d.created_at) < _t1 group by 1;
  elsif _cat = 'rocket' then return query
    select e.user_id, sum(e.damage)::numeric from rocket_entries e join rocket_raids r on r.id = e.raid_id
      where r.starts_at >= _t0 and r.starts_at < _t1 group by 1;
  elsif _cat = 'quiz' then return query
    select q.winner, count(*)::numeric from quizzes q where q.status = 'encerrado' and q.winner is not null
      and coalesce(q.closed_at, q.closes_at) >= _t0 and coalesce(q.closed_at, q.closes_at) < _t1 group by 1;
  elsif _cat = 'treinadores' then return query
    select f.user_id, count(*)::numeric from npc_fights f where f.won and f.created_at >= _t0 and f.created_at < _t1 group by 1;
  elsif _cat = 'primeira' then return query
    select g.user_id, count(*)::numeric from guess_sessions g where g.solved and g.attempts = 1 and not coalesce(g.recovered, false)
      and g.puzzle_date between d0 and d1 group by 1;
  elsif _cat = 'pokedex' then return query
    select p.user_id, count(*)::numeric from pokedex_entries p where p.caught_at >= _t0 and p.caught_at < _t1 group by 1;
  elsif _cat = 'cacadas' then return query
    select h.hunter, count(*)::numeric from hunts h where h.status = 'capturado' and h.hunter is not null
      and h.resolved_at >= _t0 and h.resolved_at < _t1 group by 1;
  end if;
end $$;

-- placar ao vivo da temporada atual (qualquer jogador): os 3 primeiros de cada categoria, contando até ontem
create or replace function public.season_board() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare s seasons; t0 timestamptz; t1 timestamptz; c jsonb; out jsonb := '[]'::jsonb; top jsonb;
begin
  perform public.assert_active();
  select * into s from seasons order by id desc limit 1;
  if s.id is null then return null; end if;
  t0 := s.started_on::timestamp at time zone 'America/Sao_Paulo';
  t1 := public.game_today()::timestamp at time zone 'America/Sao_Paulo';   -- hoje ainda não conta (sem spoiler)
  for c in select * from jsonb_array_elements(public.season_award_cats()) loop
    select coalesce(jsonb_agg(jsonb_build_object('user_id', x.user_id, 'name', ch.name, 'val', x.val) order by x.val desc, ch.name), '[]'::jsonb) into top
      from (select * from public.season_rank(c->>'id', t0, t1) r where r.val > 0 order by r.val desc limit 3) x
      join characters ch on ch.user_id = x.user_id;
    out := out || jsonb_build_array(c || jsonb_build_object('top', top));
  end loop;
  return jsonb_build_object('season', s.id, 'status', s.status, 'started_on', s.started_on, 'until', public.game_today() - 1,
    'coins', coalesce((public.cfg()->'season_awards'->>'coins')::int, 150), 'cats', out);
end $$;

-- entrega os prêmios de uma temporada (uma vez só)
create or replace function public.season_awards_give(_season int) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare s seasons; t0 timestamptz; t1 timestamptz; c jsonb; top numeric; r record; premio int := coalesce((public.cfg()->'season_awards'->>'coins')::int, 150);
  n int := 0; linhas text := ''; nomes text;
begin
  select * into s from seasons where id = _season;
  if s.id is null or exists (select 1 from season_awards where season_id = s.id) then return 0; end if;
  t0 := s.started_on::timestamp at time zone 'America/Sao_Paulo';
  t1 := now();
  for c in select * from jsonb_array_elements(public.season_award_cats()) loop
    select max(val) into top from public.season_rank(c->>'id', t0, t1) where val > 0;
    continue when top is null;
    nomes := '';
    for r in select x.user_id, ch.name from public.season_rank(c->>'id', t0, t1) x join characters ch on ch.user_id = x.user_id where x.val = top order by ch.name loop
      insert into season_awards(season_id, category, user_id, value, coins) values (s.id, c->>'id', r.user_id, top, premio) on conflict do nothing;
      update characters set coins = coins + premio where user_id = r.user_id;
      insert into gifts(user_id, coins, message) values (r.user_id, premio,
        '🏅 Prêmio da Temporada ' || s.id || ': ' || (c->>'nome') || ' (' || trim(to_char(top, 'FM999G999G990')) || ' ' || (c->>'un') || '). Você ganhou a medalha "' || (c->>'titulo') || '"!');
      nomes := nomes || case when nomes = '' then '' else ' e ' end || r.name;
      n := n + 1;
    end loop;
    linhas := linhas || E'\n' || (c->>'ic') || ' ' || (c->>'nome') || ': ' || nomes || ' (' || trim(to_char(top, 'FM999G999G990')) || ')';
  end loop;
  if n > 0 then
    insert into event_log(kind, message) values ('temporada', '🏅 Prêmios da Temporada ' || s.id || '! Cada campeão ganhou ' || premio || ' moedas e uma medalha:' || linhas);
  end if;
  return n;
end $$;

-- admin: entrega os prêmios da última temporada encerrada, se ainda não recebeu (reserva)
create or replace function public.admin_season_awards() returns int
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); s seasons; n int;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador.'; end if;
  select * into s from seasons where status = 'encerrada' order by id desc limit 1;   -- só a última temporada encerrada
  if s.id is null then raise exception 'Ainda não há temporada encerrada.'; end if;
  if exists (select 1 from season_awards a where a.season_id = s.id) then raise exception 'Os prêmios da Temporada % já foram entregues.', s.id; end if;
  n := public.season_awards_give(s.id);
  insert into admin_audit_log(admin_id, action, target, after) values (uid, 'premios_temporada', s.id::text, jsonb_build_object('premiados', n));
  return n;
end $$;

-- fecha a caverna e a temporada (versão do 31 + prêmios da temporada)
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
  perform public.season_awards_give(lg.season_id);   -- prêmios da temporada (arquivo 50)
  insert into event_log(user_id, kind, message) values (lg.champion, 'liga', case when _caught
    then '🎉 INACREDITÁVEL! ' || lg.champion_name || ' capturou o lendário ' || pn || ' (nível ' || lg.legend_level || ')!'
    else '💨 O lendário ' || pn || ' escapou de ' || lg.champion_name || '... Fica para a próxima Liga!' end
    || ' Amanhã começa uma nova temporada: todos voltam à largada.');
end $$;

-- ---------- permissões ----------
revoke execute on function public.season_rank(text, timestamptz, timestamptz), public.season_awards_give(int) from public, anon, authenticated;
revoke execute on function public.season_board(), public.admin_season_awards(), public.season_award_cats() from public, anon;
grant execute on function public.season_board(), public.admin_season_awards(), public.season_award_cats() to authenticated;
