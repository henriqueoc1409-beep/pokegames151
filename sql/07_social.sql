-- =====================================================================
-- POKEGAMES — Social: duelos com aposta, bolão da rodada e reações.
-- Antes de rodar, faça a cópia de segurança (veja as instruções).
-- Rode UMA vez no SQL Editor, depois do 06. Não apaga nenhum dado.
-- =====================================================================

update public.game_config set config = config || '{
  "duel_max_steps": 5, "duel_max_coin_pct": 20, "duel_min_coins": 10, "duel_quiz_max_guesses": 10, "duel_hours": 24,
  "bet_min": 10, "bet_max": 100,
  "reactions": ["GG", "Boa!", "Haha", "Tô chegando", "Cuidado!", "Socorro", "👏", "😂", "😱", "🔥"],
  "reactions_per_day": 15
}'::jsonb where active;

-- 1) Tabelas ------------------------------------------------------------
create table if not exists public.duels (
  id          uuid primary key default gen_random_uuid(),
  challenger  uuid not null references auth.users(id) on delete cascade,
  opponent    uuid not null references auth.users(id) on delete cascade,
  kind        text not null check (kind in ('quiz','sorte')),
  stake_kind  text not null check (stake_kind in ('moedas','casas')),
  stake       int  not null check (stake > 0),
  status      text not null default 'pendente' check (status in ('pendente','aceito','concluido','recusado','expirado','cancelado')),
  pokemon_id  int references public.pokemon(id),
  c_attempts  int not null default 0, c_solved boolean not null default false, c_done_at timestamptz,
  o_attempts  int not null default 0, o_solved boolean not null default false, o_done_at timestamptz,
  winner      uuid,
  result      text,
  created_at  timestamptz not null default now(),
  accepted_at timestamptz,
  expires_at  timestamptz not null,
  resolved_at timestamptz
);
create index if not exists duels_people on public.duels(challenger, opponent, status);

create table if not exists public.duel_guesses (
  id         bigserial primary key,
  duel_id    uuid not null references public.duels(id) on delete cascade,
  user_id    uuid not null,
  pokemon_id int not null references public.pokemon(id),
  correct    boolean not null,
  created_at timestamptz not null default now(),
  unique (duel_id, user_id, pokemon_id)
);

create table if not exists public.round_bets (
  d          date not null,
  user_id    uuid not null references auth.users(id) on delete cascade,
  pick       uuid not null references auth.users(id) on delete cascade,
  amount     int  not null check (amount > 0),
  payout     int,
  created_at timestamptz not null default now(),
  primary key (d, user_id)
);

create table if not exists public.reactions (
  id         bigserial primary key,
  from_user  uuid not null references auth.users(id) on delete cascade,
  to_user    uuid not null references auth.users(id) on delete cascade,
  emoji      text not null,
  created_at timestamptz not null default now()
);
create index if not exists reactions_recent on public.reactions(created_at);

-- 2) Duelos -------------------------------------------------------------
create or replace function public.resolve_duel(_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare d duels; c jsonb := cfg(); w uuid; l uuid; cs int; os int; ch characters; op characters; chance int;
  wc characters; lc characters; msg text; what text;
begin
  select * into d from duels where id = _id for update;
  if d.status <> 'aceito' then return; end if;
  select * into ch from characters where user_id = d.challenger for update;
  select * into op from characters where user_id = d.opponent for update;
  if d.kind = 'quiz' then
    cs := case when d.c_solved then d.c_attempts else 99 end;
    os := case when d.o_solved then d.o_attempts else 99 end;
    if cs < os then w := d.challenger;
    elsif os < cs then w := d.opponent;
    elsif cs = 99 then w := null;
    else w := case when coalesce(d.c_done_at, 'infinity') <= coalesce(d.o_done_at, 'infinity') then d.challenger else d.opponent end;
    end if;
  else
    chance := 50 + (ch.level - op.level) * (c->>'duel_level_factor')::int
                 + case when ch.class::text = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end
                 - case when op.class::text = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end;
    chance := greatest(25, least(75, chance));
    w := case when random() * 100 < chance then d.challenger else d.opponent end;
  end if;
  what := case d.stake_kind when 'moedas' then d.stake || ' moedas' else d.stake || ' casas' end;
  if w is null then
    if d.stake_kind = 'moedas' then
      update characters set coins = coins + d.stake where user_id in (d.challenger, d.opponent);
    end if;
    msg := 'Duelo entre ' || ch.name || ' e ' || op.name || ' terminou sem vencedor. Ninguém acertou o Pokémon.';
  else
    l := case when w = d.challenger then d.opponent else d.challenger end;
    select * into wc from characters where user_id = w;
    select * into lc from characters where user_id = l;
    if d.stake_kind = 'moedas' then
      update characters set coins = coins + 2 * d.stake where user_id = w;
    else
      if wc.arrived_rank is null then perform public.walk(wc.id, d.stake); perform public.check_arrival(wc.id); end if;
      if lc.arrived_rank is null then perform public.go_back(lc.id, d.stake); end if;
    end if;
    msg := wc.name || ' venceu o duelo contra ' || lc.name || ' e levou ' || what || '.';
  end if;
  update duels set status = 'concluido', winner = w, result = msg, resolved_at = now() where id = _id;
  insert into event_log(user_id, kind, message) values (coalesce(w, d.challenger), 'duelo', msg);
end $$;

create or replace function public.expire_duels() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare d duels;
begin
  for d in select * from duels where status = 'pendente' and expires_at < now() for update loop
    update duels set status = 'expirado', resolved_at = now(), result = 'O desafio expirou sem resposta.' where id = d.id;
    if d.stake_kind = 'moedas' then update characters set coins = coins + d.stake where user_id = d.challenger; end if;
  end loop;
  for d in select * from duels where status = 'aceito' and expires_at < now() loop
    update duels set c_done_at = coalesce(c_done_at, now()), o_done_at = coalesce(o_done_at, now()) where id = d.id;
    perform public.resolve_duel(d.id);
  end loop;
end $$;

create or replace function public.create_duel(_opponent uuid, _kind text, _stake_kind text, _stake int) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); t date := public.game_today(); tz text := coalesce(public.cfg()->>'timezone','America/Sao_Paulo');
  me characters; op characters; maxc int; nid uuid;
begin
  perform public.expire_duels();
  if _opponent = uid then raise exception 'Você não pode desafiar a si mesmo.'; end if;
  if _kind not in ('quiz','sorte') or _stake_kind not in ('moedas','casas') then raise exception 'Tipo de duelo inválido.'; end if;
  select * into me from characters where user_id = uid for update;
  select * into op from characters where user_id = _opponent;
  if me.id is null or op.id is null then raise exception 'Jogador não encontrado.'; end if;
  if not exists (select 1 from profiles where id = _opponent and status = 'ativo') then raise exception 'Esse jogador está bloqueado.'; end if;
  if exists (select 1 from duels where challenger = uid and (created_at at time zone tz)::date = t) then raise exception 'Você já enviou um desafio hoje. Volte amanhã.'; end if;
  if exists (select 1 from duels where status in ('pendente','aceito') and ((challenger = uid and opponent = _opponent) or (challenger = _opponent and opponent = uid))) then
    raise exception 'Já existe um duelo entre vocês em andamento.';
  end if;
  if coalesce(_stake,0) < 1 then raise exception 'Escolha um valor para a aposta.'; end if;
  if _stake_kind = 'moedas' then
    maxc := greatest((c->>'duel_min_coins')::int, floor(me.coins * (c->>'duel_max_coin_pct')::numeric / 100)::int);
    if _stake > maxc then raise exception 'Agora você pode apostar no máximo % moedas.', maxc; end if;
    if me.coins < _stake then raise exception 'Moedas insuficientes.'; end if;
    update characters set coins = coins - _stake where id = me.id;
  else
    if _stake > (c->>'duel_max_steps')::int then raise exception 'A aposta máxima é de % casas.', (c->>'duel_max_steps'); end if;
    if me.arrived_rank is not null or op.arrived_rank is not null then raise exception 'Quem já chegou ao Castelo só duela valendo moedas.'; end if;
  end if;
  insert into duels(challenger, opponent, kind, stake_kind, stake, expires_at)
  values (uid, _opponent, _kind, _stake_kind, _stake, now() + make_interval(hours => (c->>'duel_hours')::int)) returning id into nid;
  insert into event_log(user_id, kind, message) values (uid, 'duelo',
    me.name || ' desafiou ' || op.name || ' para um duelo de ' || case _kind when 'quiz' then 'quiz' else 'sorte' end || ' valendo ' || _stake || case _stake_kind when 'moedas' then ' moedas.' else ' casas.' end);
  return nid;
end $$;

create or replace function public.accept_duel(_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); t date := public.game_today(); tz text := coalesce(public.cfg()->>'timezone','America/Sao_Paulo');
  d duels; me characters; ch characters; pid int;
begin
  perform public.expire_duels();
  select * into d from duels where id = _id for update;
  if d.id is null or d.opponent <> uid then raise exception 'Desafio não encontrado.'; end if;
  if d.status <> 'pendente' then raise exception 'Esse desafio não está mais aberto.'; end if;
  if exists (select 1 from duels where opponent = uid and accepted_at is not null and (accepted_at at time zone tz)::date = t) then
    raise exception 'Você já aceitou um duelo hoje. Volte amanhã.';
  end if;
  select * into me from characters where user_id = uid for update;
  select * into ch from characters where user_id = d.challenger;
  if d.stake_kind = 'moedas' then
    if me.coins < d.stake then raise exception 'Você precisa de % moedas para aceitar.', d.stake; end if;
    update characters set coins = coins - d.stake where id = me.id;
  elsif me.arrived_rank is not null or ch.arrived_rank is not null then
    raise exception 'Quem já chegou ao Castelo só duela valendo moedas.';
  end if;
  if d.kind = 'quiz' then
    select p.id into pid from pokemon p join pokemon_media m on m.pokemon_id = p.id where m.silhouette is not null order by random() limit 1;
    if pid is null then raise exception 'Duelos de quiz precisam das imagens da Pokédex. Peça ao administrador para importá-las.'; end if;
  end if;
  update duels set status = 'aceito', accepted_at = now(), pokemon_id = pid,
         expires_at = now() + make_interval(hours => (c->>'duel_hours')::int) where id = _id;
  insert into event_log(user_id, kind, message) values (uid, 'duelo', me.name || ' aceitou o desafio de ' || ch.name || '!');
  if d.kind = 'sorte' then perform public.resolve_duel(_id); end if;
end $$;

create or replace function public.decline_duel(_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d duels;
begin
  select * into d from duels where id = _id for update;
  if d.id is null or d.status <> 'pendente' then raise exception 'Esse desafio não está mais aberto.'; end if;
  if uid = d.opponent then
    update duels set status = 'recusado', resolved_at = now(), result = 'Desafio recusado.' where id = _id;
    insert into event_log(user_id, kind, message) values (uid, 'duelo',
      (select name from characters where user_id = uid) || ' recusou o desafio de ' || (select name from characters where user_id = d.challenger) || '.');
  elsif uid = d.challenger then
    update duels set status = 'cancelado', resolved_at = now(), result = 'Desafio cancelado.' where id = _id;
  else raise exception 'Desafio não encontrado.';
  end if;
  if d.stake_kind = 'moedas' then update characters set coins = coins + d.stake where user_id = d.challenger; end if;
end $$;

create or replace function public.duel_state(_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d duels; side text; mine int; img text;
begin
  perform public.expire_duels();
  select * into d from duels where id = _id;
  if d.id is null or uid not in (d.challenger, d.opponent) then raise exception 'Duelo não encontrado.'; end if;
  side := case when uid = d.challenger then 'c' else 'o' end;
  mine := case side when 'c' then d.c_attempts else d.o_attempts end;
  if d.kind = 'quiz' and d.pokemon_id is not null then select silhouette into img from pokemon_media where pokemon_id = d.pokemon_id; end if;
  return jsonb_build_object('id', d.id, 'kind', d.kind, 'stake_kind', d.stake_kind, 'stake', d.stake, 'status', d.status,
    'challenger', d.challenger, 'opponent', d.opponent, 'expires_at', d.expires_at, 'winner', d.winner, 'result', d.result,
    'max_guesses', (cfg()->>'duel_quiz_max_guesses')::int,
    'me', jsonb_build_object('attempts', mine, 'solved', case side when 'c' then d.c_solved else d.o_solved end,
                             'done', case side when 'c' then d.c_done_at is not null else d.o_done_at is not null end),
    'other_done', case side when 'c' then d.o_done_at is not null else d.c_done_at is not null end,
    'other_attempts', case when d.status = 'concluido' then case side when 'c' then d.o_attempts else d.c_attempts end end,
    'clue', case when img is not null then jsonb_build_object('image', img, 'zoom_step', mine) end,
    'answer', case when d.status = 'concluido' and d.pokemon_id is not null then (select jsonb_build_object('id', id, 'name', name) from pokemon where id = d.pokemon_id) end,
    'guesses', coalesce((select jsonb_agg(jsonb_build_object('pokemon_id', pokemon_id, 'correct', correct) order by id) from duel_guesses where duel_id = d.id and user_id = uid), '[]'::jsonb));
end $$;

create or replace function public.duel_guess(_id uuid, _pokemon_id int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d duels; side text; ok boolean; n int; maxg int := (public.cfg()->>'duel_quiz_max_guesses')::int;
begin
  perform public.expire_duels();
  select * into d from duels where id = _id for update;
  if d.id is null or uid not in (d.challenger, d.opponent) then raise exception 'Duelo não encontrado.'; end if;
  if d.status <> 'aceito' or d.kind <> 'quiz' then raise exception 'Esse duelo não está em andamento.'; end if;
  side := case when uid = d.challenger then 'c' else 'o' end;
  if (side = 'c' and d.c_done_at is not null) or (side = 'o' and d.o_done_at is not null) then raise exception 'Você já terminou este duelo.'; end if;
  if exists (select 1 from duel_guesses where duel_id = _id and user_id = uid and pokemon_id = _pokemon_id) then raise exception 'Você já tentou esse Pokémon.'; end if;
  ok := _pokemon_id = d.pokemon_id;
  insert into duel_guesses(duel_id, user_id, pokemon_id, correct) values (_id, uid, _pokemon_id, ok);
  if side = 'c' then
    update duels set c_attempts = c_attempts + 1, c_solved = ok,
      c_done_at = case when ok or c_attempts + 1 >= maxg then now() end where id = _id returning * into d;
  else
    update duels set o_attempts = o_attempts + 1, o_solved = ok,
      o_done_at = case when ok or o_attempts + 1 >= maxg then now() end where id = _id returning * into d;
  end if;
  if d.c_done_at is not null and d.o_done_at is not null then perform public.resolve_duel(_id); end if;
  return public.duel_state(_id);
end $$;

create or replace function public.duel_list() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active();
begin
  perform public.expire_duels();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', d.id, 'kind', d.kind, 'stake_kind', d.stake_kind, 'stake', d.stake, 'status', d.status,
      'challenger', d.challenger, 'opponent', d.opponent, 'winner', d.winner, 'result', d.result,
      'created_at', d.created_at, 'expires_at', d.expires_at,
      'my_done', case when uid = d.challenger then d.c_done_at is not null else d.o_done_at is not null end,
      'other_done', case when uid = d.challenger then d.o_done_at is not null else d.c_done_at is not null end) order by d.created_at desc)
    from duels d where uid in (d.challenger, d.opponent) and d.created_at > now() - interval '7 days'), '[]'::jsonb);
end $$;

-- 3) Bolão da rodada ----------------------------------------------------
create or replace function public.place_bet(_pick uuid, _amount int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); hoje date := public.game_today(); me characters;
begin
  select * into me from characters where user_id = uid for update;
  if me.id is null then raise exception 'Crie seu personagem primeiro.'; end if;
  if exists (select 1 from round_bets b where b.d = public.game_today() and b.user_id = uid) then raise exception 'Você já apostou no bolão de hoje.'; end if;
  if exists (select 1 from guess_sessions where user_id = uid and puzzle_date = hoje and not recovered)
     or exists (select 1 from daily_moves where user_id = uid and move_date = hoje) then
    raise exception 'O bolão fecha para você quando você começa o desafio do dia.';
  end if;
  if not exists (select 1 from characters where user_id = _pick) then raise exception 'Jogador não encontrado.'; end if;
  if _amount < (c->>'bet_min')::int or _amount > (c->>'bet_max')::int then raise exception 'A aposta deve ser de % a % moedas.', (c->>'bet_min'), (c->>'bet_max'); end if;
  if me.coins < _amount then raise exception 'Moedas insuficientes.'; end if;
  update characters set coins = coins - _amount where id = me.id;
  insert into round_bets(d, user_id, pick, amount) values (hoje, uid, _pick, _amount);
  insert into event_log(user_id, kind, message) values (uid, 'bolao', me.name || ' entrou no bolão de hoje.');
end $$;

create or replace function public.settle_bets() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare r record; b round_bets; w uuid; pot int; good int; n int; wname text;
begin
  for r in select distinct rb.d from round_bets rb where rb.payout is null and rb.d < game_today() loop
    select user_id into w from round_results rr where rr.d = r.d and rr.rank = 1;
    select sum(amount) into pot from round_bets rb where rb.d = r.d;
    select coalesce(sum(amount),0), count(*) into good, n from round_bets rb where rb.d = r.d and rb.pick = w;
    if w is null or good = 0 then
      for b in select * from round_bets rb where rb.d = r.d for update loop
        update round_bets set payout = amount where d = b.d and user_id = b.user_id;
        update characters set coins = coins + b.amount where user_id = b.user_id;
      end loop;
      insert into event_log(kind, message) values ('bolao', 'Bolão de ' || to_char(r.d, 'DD/MM') || ': ninguém acertou o vencedor. As apostas foram devolvidas.');
    else
      for b in select * from round_bets rb where rb.d = r.d for update loop
        update round_bets set payout = case when b.pick = w then floor(pot * b.amount::numeric / good)::int else 0 end where d = b.d and user_id = b.user_id;
        if b.pick = w then update characters set coins = coins + floor(pot * b.amount::numeric / good)::int where user_id = b.user_id; end if;
      end loop;
      wname := (select name from characters where user_id = w);
      insert into event_log(kind, message) values ('bolao', 'Bolão de ' || to_char(r.d, 'DD/MM') || ': ' || case when n = 1 then '1 jogador acertou' else n || ' jogadores acertaram' end || ' que ' || wname || ' venceria e ' || case when n = 1 then 'levou ' else 'dividiram ' end || pot || ' moedas.');
    end if;
  end loop;
end $$;

-- settle passa a fechar também o bolão e os duelos vencidos
create or replace function public.settle() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare d date := game_today(); c jsonb := cfg(); r record; x record; pos int; bs int; bc int; s seasons; names text := '';
begin
  perform pg_advisory_xact_lock(151151);
  for r in select distinct puzzle_date as pd from guess_sessions
           where puzzle_date < d and not recovered and puzzle_date not in (select rd.d from round_days rd) order by 1 loop
    insert into round_days(d) values (r.pd);
    pos := 0; names := '';
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
      if pos = 1 then names := (select name from characters where user_id = x.user_id) || ' venceu a rodada de ' || to_char(r.pd, 'DD/MM') || ' com ' || x.total || ' tentativas'; end if;
    end loop;
    if names <> '' then insert into event_log(kind, message) values ('rodada', names || '.'); end if;
  end loop;
  perform public.settle_bets();
  perform public.expire_duels();
  select * into s from seasons order by id desc limit 1;
  if s.status = 'encerrada' and s.ended_on < d then perform public.start_new_season(); end if;
end $$;

-- 4) Reações ------------------------------------------------------------
create or replace function public.send_reaction(_to uuid, _emoji text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); tz text := coalesce(public.cfg()->>'timezone','America/Sao_Paulo');
begin
  if _to = uid then raise exception 'Mande para outro jogador.'; end if;
  if not exists (select 1 from characters where user_id = _to) then raise exception 'Jogador não encontrado.'; end if;
  if not (c->'reactions' ? _emoji) then raise exception 'Reação inválida.'; end if;
  if (select count(*) from reactions where from_user = uid and (created_at at time zone tz)::date = public.game_today()) >= (c->>'reactions_per_day')::int then
    raise exception 'Você já mandou muitas reações hoje.';
  end if;
  insert into reactions(from_user, to_user, emoji) values (uid, _to, _emoji);
end $$;

-- 5) Resumo social para o painel ----------------------------------------
create or replace function public.social_overview() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); hoje date := public.game_today(); b round_bets;
begin
  perform public.expire_duels();
  select * into b from round_bets rb where rb.d = hoje and rb.user_id = uid;
  return jsonb_build_object(
    'duels_in', (select count(*) from duels where opponent = uid and status = 'pendente'),
    'duels_play', (select count(*) from duels where status = 'aceito' and kind = 'quiz'
                    and ((challenger = uid and c_done_at is null) or (opponent = uid and o_done_at is null))),
    'bet', case when b.user_id is not null then jsonb_build_object('pick', b.pick, 'amount', b.amount) end,
    'pot', (select coalesce(sum(amount),0) from round_bets rb where rb.d = hoje),
    'bettors', (select count(*) from round_bets rb where rb.d = hoje),
    'can_bet', b.user_id is null
               and not exists (select 1 from guess_sessions where user_id = uid and puzzle_date = hoje and not recovered)
               and not exists (select 1 from daily_moves where user_id = uid and move_date = hoje),
    'reactions', coalesce((select jsonb_agg(jsonb_build_object('from', from_user, 'to', to_user, 'emoji', emoji, 'at', created_at) order by id)
                           from reactions where created_at > now() - interval '6 hours'), '[]'::jsonb));
end $$;

-- 6) Segurança ----------------------------------------------------------
alter table public.duels        enable row level security;
alter table public.duel_guesses enable row level security;
alter table public.round_bets   enable row level security;
alter table public.reactions    enable row level security;
revoke all on public.duels, public.duel_guesses, public.round_bets, public.reactions from anon, authenticated;
grant select on public.reactions to authenticated;
drop policy if exists p_reactions on public.reactions;
create policy p_reactions on public.reactions for select to authenticated using (true);
-- duelos e bolão só pelas funções (o Pokémon secreto do duelo fica escondido)
do $$ begin
  begin alter publication supabase_realtime add table public.reactions; exception when duplicate_object then null; end;
end $$;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.username_available(text) to anon, authenticated;
grant execute on function public.has_role(uuid, public.app_role) to authenticated;
grant execute on function
  public.is_admin(), public.create_character(text, public.char_class),
  public.puzzle_state(public.puzzle_mode, date), public.make_guess(public.puzzle_mode, int, date),
  public.use_hint(public.puzzle_mode, date), public.use_retry(public.puzzle_mode, date), public.buy_help(text),
  public.spin_wheel(), public.set_route(int, text), public.use_skill(), public.change_class(public.char_class),
  public.today_overview(), public.day_status(date), public.move_today(), public.move_day(date),
  public.buy_item(text), public.equip_item(text, text), public.place_trap(int), public.today_round(), public.ranking_period(text),
  public.market_refresh(), public.market_create(text, text, int, int, text, text, int), public.market_cancel(uuid), public.market_buy(uuid),
  public.create_duel(uuid, text, text, int), public.accept_duel(uuid), public.decline_duel(uuid), public.duel_state(uuid),
  public.duel_guess(uuid, int), public.duel_list(), public.place_bet(uuid, int), public.send_reaction(uuid, text), public.social_overview(),
  public.admin_players(), public.admin_set_status(uuid, text, text), public.admin_adjust(uuid, int, int, int, text),
  public.admin_reset_day(uuid, date, text), public.admin_set_config(jsonb, text), public.admin_undo_move(uuid, text),
  public.admin_new_season(text), public.admin_save_media(int, text, jsonb, text), public.admin_media_status()
to authenticated;
