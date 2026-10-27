-- =====================================================================
-- POKEGAMES — 6 heróis com habilidades, troca de herói, mercado entre
-- jogadores e recuperação de dias perdidos (até 72 horas).
-- Rode UMA vez no SQL Editor, depois do 04 e do 05.
-- =====================================================================

-- 1) Novos heróis --------------------------------------------------------
alter type public.char_class add value if not exists 'ladino';
alter type public.char_class add value if not exists 'clerigo';
alter type public.char_class add value if not exists 'domador';

alter table public.characters
  add column if not exists skill_date        date,
  add column if not exists weekly_bonus_date date;
alter table public.guess_sessions add column if not exists recovered boolean not null default false;
alter table public.daily_moves    add column if not exists recovered boolean not null default false;
alter table public.daily_moves    add column if not exists skill_steps int not null default 0;

update public.game_config set config = config || '{
  "skill_levels": [1,5,10,15,20],
  "skills":   {"guerreiro":[1,1,2,2,3], "mago":[4,5,6,7,8], "arqueiro":[2,2,2,3,3], "ladino":[1,1,1,2,2], "clerigo":[0,0,1,1,2], "domador":[2,2,2,2,3]},
  "passives": {"ladino":[5,8,10,12,15], "domador":[1,1,1,2,2]},
  "class_change_price": 300,
  "market_fee_pct": 5, "market_hours": 72, "market_max_open": 5,
  "recovery_days": 3
}'::jsonb where active;

-- 2) Mercado ------------------------------------------------------------
create table if not exists public.market_listings (
  id         uuid primary key default gen_random_uuid(),
  seller_id  uuid not null references auth.users(id) on delete cascade,
  item_kind  text not null check (item_kind in ('item','dica','retry')),
  item_id    text references public.shop_items(id),
  qty        int  not null default 1 check (qty between 1 and 20),
  price      int  check (price is null or price > 0),
  want_kind  text check (want_kind in ('item','dica','retry')),
  want_item  text references public.shop_items(id),
  want_qty   int  check (want_qty is null or want_qty between 1 and 20),
  status     text not null default 'aberto' check (status in ('aberto','vendido','trocado','cancelado','expirado')),
  buyer_id   uuid,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  closed_at  timestamptz,
  check ((price is not null) <> (want_kind is not null))
);
create index if not exists market_open_idx on public.market_listings(status, expires_at);

-- 3) Funções auxiliares -------------------------------------------------
create or replace function public.skill_rank(_level int) returns int
language sql stable security definer set search_path = public, extensions as $$
  select greatest(1, (select count(*)::int from jsonb_array_elements_text(cfg()->'skill_levels') l where l::int <= _level))
$$;
create or replace function public.skill_value(_class text, _level int) returns int
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((cfg()->'skills'->_class->>(public.skill_rank(_level) - 1))::int, 0)
$$;
create or replace function public.passive_value(_class text, _level int) returns int
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((cfg()->'passives'->_class->>(public.skill_rank(_level) - 1))::int, 0)
$$;
create or replace function public.is_shielded(_cid uuid) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from characters where id = _cid and class::text = 'clerigo' and skill_date = game_today())
$$;

-- Volta casas pelo caminho feito, a não ser que a Bênção do Clérigo esteja ativa.
create or replace function public.go_back(_cid uuid, _k int) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare p int[]; l int; cur int;
begin
  select path, node into p, cur from characters where id = _cid;
  if public.is_shielded(_cid) then return cur; end if;
  l := greatest(1, coalesce(array_length(p,1),1) - _k);
  update characters set path = p[1:l], node = p[l] where id = _cid;
  return p[l];
end $$;

-- Casas até a próxima casa boa à frente (para o Teleporte do Mago).
create or replace function public.next_good_steps(_cid uuid, _max int) returns int
language plpgsql stable security definer set search_path = public, extensions as $$
declare ch characters; n board_nodes; cur int; i int;
begin
  select * into ch from characters where id = _cid; cur := ch.node;
  for i in 1.._max loop
    select * into n from board_nodes where id = cur;
    exit when n.kind = 'castelo' or n.next_a is null;
    cur := case when n.next_b is not null and ch.route->>(n.id::text) = 'b' then n.next_b else n.next_a end;
    if (select kind from board_nodes where id = cur) in ('avanco','bau','xp','pagamento','carta') then return i; end if;
  end loop;
  return 0;
end $$;

-- Dia que o jogador pode jogar: hoje, ou um dia perdido dos últimos 3.
create or replace function public.play_date(_d date) returns date
language plpgsql stable security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); t date := game_today(); cr date;
begin
  if _d is null or _d = t then return t; end if;
  if _d > t or _d < t - (cfg()->>'recovery_days')::int then
    raise exception 'Esse dia não pode mais ser recuperado. O limite é de 72 horas.';
  end if;
  select (created_at at time zone coalesce(cfg()->>'timezone','America/Sao_Paulo'))::date into cr from characters where user_id = uid;
  if cr is null or _d < cr then raise exception 'Você ainda não jogava nesse dia.'; end if;
  if exists (select 1 from daily_moves where user_id = uid and move_date = _d) then raise exception 'Você já jogou e andou nesse dia.'; end if;
  return _d;
end $$;

-- Resumo dos 4 modos de um dia para um jogador.
create or replace function public.modes_summary(_uid uuid, _d date) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare m public.puzzle_mode; modes jsonb := '{}'::jsonb; s guess_sessions; avail boolean; steps int := 0; ra int := 0; done int := 0;
begin
  perform public.ensure_puzzles(_d);
  foreach m in array enum_range(null::public.puzzle_mode) loop
    s := null;
    select * into s from guess_sessions where user_id = _uid and puzzle_date = _d and mode = m;
    avail := exists (select 1 from daily_puzzles where puzzle_date = _d and mode = m);
    steps := steps + public.mode_steps(coalesce(s.attempts,0), coalesce(s.solved,false));
    if avail then
      ra := ra + public.rank_attempts(coalesce(s.attempts,0), coalesce(s.solved,false), coalesce(s.hints_used,0), coalesce(s.retries_used,0));
      if coalesce(s.solved,false) or coalesce(s.failed,false) then done := done + 1; end if;
    end if;
    modes := modes || jsonb_build_object(m::text, jsonb_build_object(
      'available', avail, 'attempts', coalesce(s.attempts,0), 'solved', coalesce(s.solved,false), 'failed', coalesce(s.failed,false),
      'steps', public.mode_steps(coalesce(s.attempts,0), coalesce(s.solved,false)),
      'hints_used', coalesce(s.hints_used,0), 'retries_used', coalesce(s.retries_used,0)));
  end loop;
  return jsonb_build_object('date', _d, 'modes', modes, 'steps', steps, 'rank_attempts', ra, 'modes_done', done);
end $$;

-- 4) Desafio com data (hoje ou dia recuperado) --------------------------
drop function if exists public.puzzle_state(public.puzzle_mode);
drop function if exists public.make_guess(public.puzzle_mode, int);
drop function if exists public.use_hint(public.puzzle_mode);
drop function if exists public.use_retry(public.puzzle_mode);

create or replace function public.puzzle_state(_mode public.puzzle_mode, _date date default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d date;
  ans int; a pokemon; s guess_sessions; media pokemon_media; clue jsonb := '{}'::jsonb;
  moved boolean; finished boolean; lvl int; n int; made int; hints jsonb := '[]'::jsonb; last guesses;
begin
  d := case when _date is null or _date = public.game_today() then public.game_today() else public.play_date(_date) end;
  perform public.ensure_puzzles(d);
  select pokemon_id into ans from daily_puzzles where puzzle_date = d and mode = _mode;
  if ans is null then return jsonb_build_object('mode', _mode, 'date', d, 'available', false); end if;
  select * into a from pokemon where id = ans;
  select * into s from guess_sessions where user_id = uid and puzzle_date = d and mode = _mode;
  moved := exists (select 1 from daily_moves where user_id = uid and move_date = d);
  finished := coalesce(s.solved,false) or coalesce(s.failed,false) or moved;
  made := coalesce(s.attempts,0) + coalesce(s.retries_used,0);
  select * into media from pokemon_media where pokemon_id = ans;
  if _mode = 'descricao' then
    clue := jsonb_build_object('text', media.description);
  elsif _mode = 'silhueta' then
    clue := jsonb_build_object('image', media.silhouette, 'zoom_step', made);
  elsif _mode = 'cartao' then
    n := jsonb_array_length(media.pixel_levels);
    lvl := case when finished then n - 1 else least(made, n - 2) end;
    clue := jsonb_build_object('image', media.pixel_levels->>lvl, 'level', lvl, 'levels', n);
  end if;
  if coalesce(s.hints_used,0) >= 1 then hints := hints || to_jsonb('Tipo principal: ' || a.type1); end if;
  if coalesce(s.hints_used,0) >= 2 then hints := hints || to_jsonb('Habitat: ' || a.habitat); end if;
  if coalesce(s.hints_used,0) >= 3 then hints := hints || to_jsonb('Começa com a letra ' || left(a.name,1)); end if;
  select * into last from guesses where user_id = uid and puzzle_date = d and mode = _mode order by id desc limit 1;
  return jsonb_build_object(
    'mode', _mode, 'date', d, 'available', true, 'recovery', d < public.game_today(),
    'attempts', coalesce(s.attempts,0), 'solved', coalesce(s.solved,false),
    'failed', coalesce(s.failed,false) or (moved and not coalesce(s.solved,false)),
    'finished', finished, 'max_guesses', (cfg()->>'max_guesses')::int,
    'steps', public.mode_steps(coalesce(s.attempts,0), coalesce(s.solved,false)),
    'rank_attempts', case when coalesce(s.solved,false) then public.rank_attempts(s.attempts, true, s.hints_used, s.retries_used) end,
    'hints_used', coalesce(s.hints_used,0), 'retries_used', coalesce(s.retries_used,0),
    'max_hints', (cfg()->>'max_hints_per_mode')::int, 'hints', hints,
    'can_retry', not finished and coalesce(s.retries_used,0) < 1 and last.id is not null and not last.correct and not last.annulled,
    'clue', clue,
    'answer', case when finished then jsonb_build_object('id', a.id, 'name', a.name) end,
    'guesses', coalesce((select jsonb_agg(jsonb_build_object('pokemon_id', pokemon_id, 'correct', correct, 'annulled', annulled, 'feedback', feedback) order by id)
                         from guesses where user_id = uid and puzzle_date = d and mode = _mode), '[]'::jsonb));
end $$;

create or replace function public.make_guess(_mode public.puzzle_mode, _pokemon_id int, _date date default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d date := public.play_date(_date);
  ans int; s guess_sessions; ok boolean; fb jsonb; maxg int := (public.cfg()->>'max_guesses')::int;
begin
  if not exists (select 1 from characters where user_id = uid) then raise exception 'Crie seu personagem primeiro.'; end if;
  if exists (select 1 from daily_moves where user_id = uid and move_date = d) then raise exception 'Você já andou nesse dia. O desafio dele está encerrado para você.'; end if;
  if not exists (select 1 from pokemon where id = _pokemon_id) then raise exception 'Pokémon desconhecido.'; end if;
  perform public.ensure_puzzles(d);
  select pokemon_id into ans from daily_puzzles where puzzle_date = d and mode = _mode;
  if ans is null then raise exception 'Este modo ainda não está disponível. O administrador precisa importar a Pokédex.'; end if;
  insert into guess_sessions(user_id, puzzle_date, mode, recovered) values (uid, d, _mode, d < public.game_today()) on conflict do nothing;
  select * into s from guess_sessions where user_id = uid and puzzle_date = d and mode = _mode for update;
  if s.solved or s.failed then raise exception 'Você já concluiu este modo.'; end if;
  if exists (select 1 from guesses where user_id = uid and puzzle_date = d and mode = _mode and pokemon_id = _pokemon_id) then
    raise exception 'Você já tentou esse Pokémon neste modo.';
  end if;
  ok := _pokemon_id = ans;
  if _mode = 'classico' then fb := public.compare_pokemon(_pokemon_id, ans); end if;
  insert into guesses(user_id, puzzle_date, mode, pokemon_id, correct, feedback) values (uid, d, _mode, _pokemon_id, ok, fb);
  update guess_sessions set attempts = attempts + 1, solved = ok, failed = (not ok and attempts + 1 >= maxg),
         finished_at = case when ok or attempts + 1 >= maxg then now() end
   where user_id = uid and puzzle_date = d and mode = _mode;
  return public.puzzle_state(_mode, d);
end $$;

create or replace function public.use_hint(_mode public.puzzle_mode, _date date default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d date := public.play_date(_date); s guess_sessions; me characters;
begin
  if exists (select 1 from daily_moves where user_id = uid and move_date = d) then raise exception 'Você já andou nesse dia.'; end if;
  perform public.ensure_puzzles(d);
  if not exists (select 1 from daily_puzzles where puzzle_date = d and mode = _mode) then raise exception 'Modo indisponível.'; end if;
  insert into guess_sessions(user_id, puzzle_date, mode, recovered) values (uid, d, _mode, d < public.game_today()) on conflict do nothing;
  select * into s from guess_sessions where user_id = uid and puzzle_date = d and mode = _mode for update;
  if s.solved or s.failed then raise exception 'Você já concluiu este modo.'; end if;
  if s.hints_used >= (public.cfg()->>'max_hints_per_mode')::int then raise exception 'Você já usou todas as dicas deste modo.'; end if;
  select * into me from characters where user_id = uid for update;
  if me.hints < 1 then raise exception 'Você não tem dicas. Compre na loja, no mercado ou ganhe na roleta.'; end if;
  update characters set hints = hints - 1 where id = me.id;
  update guess_sessions set hints_used = hints_used + 1 where user_id = uid and puzzle_date = d and mode = _mode;
  return public.puzzle_state(_mode, d);
end $$;

create or replace function public.use_retry(_mode public.puzzle_mode, _date date default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d date := public.play_date(_date); s guess_sessions; me characters; last guesses;
begin
  if exists (select 1 from daily_moves where user_id = uid and move_date = d) then raise exception 'Você já andou nesse dia.'; end if;
  select * into s from guess_sessions where user_id = uid and puzzle_date = d and mode = _mode for update;
  if s.user_id is null then raise exception 'Faça um palpite antes.'; end if;
  if s.solved or s.failed then raise exception 'Você já concluiu este modo.'; end if;
  if s.retries_used >= 1 then raise exception 'Só dá para usar Tente outra vez uma vez por modo.'; end if;
  select * into last from guesses where user_id = uid and puzzle_date = d and mode = _mode order by id desc limit 1;
  if last.id is null or last.correct or last.annulled then raise exception 'Use logo depois de um palpite errado.'; end if;
  select * into me from characters where user_id = uid for update;
  if me.retries < 1 then raise exception 'Você não tem Tente outra vez. Compre na loja, no mercado ou ganhe na roleta.'; end if;
  update guesses set annulled = true where id = last.id;
  update guess_sessions set attempts = attempts - 1, retries_used = retries_used + 1 where user_id = uid and puzzle_date = d and mode = _mode;
  update characters set retries = retries - 1 where id = me.id;
  return public.puzzle_state(_mode, d);
end $$;

-- Rodadas ignoram sessões de dias recuperados.
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
  select * into s from seasons order by id desc limit 1;
  if s.status = 'encerrada' and s.ended_on < d then perform public.start_new_season(); end if;
end $$;

-- 5) Habilidade do herói ------------------------------------------------
create or replace function public.use_skill() returns public.characters
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d date := public.game_today(); me characters;
  nomes jsonb := '{"guerreiro":"Investida","mago":"Teleporte","arqueiro":"Tiro certeiro","ladino":"Atalho","clerigo":"Bênção","domador":"Montaria"}';
begin
  select * into me from characters where user_id = uid for update;
  if me.id is null then raise exception 'Crie seu personagem primeiro.'; end if;
  if exists (select 1 from daily_moves where user_id = uid and move_date = d) then raise exception 'Você já andou hoje. Use a habilidade antes de andar.'; end if;
  if me.skill_date = d then raise exception 'Você já usou sua habilidade hoje.'; end if;
  update characters set skill_date = d where id = me.id returning * into me;
  insert into event_log(user_id, kind, message) values (uid, 'habilidade', me.name || ' usou ' || (nomes->>me.class::text) || '.');
  return me;
end $$;

create or replace function public.change_class(_class public.char_class) returns public.characters
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters; price int := (public.cfg()->>'class_change_price')::int;
begin
  select * into me from characters where user_id = uid for update;
  if me.id is null then raise exception 'Crie seu personagem primeiro.'; end if;
  if me.class = _class then raise exception 'Você já é desse herói.'; end if;
  if me.coins < price then raise exception 'A troca de herói custa % moedas.', price; end if;
  update characters set class = _class, coins = coins - price, skill_date = null where id = me.id returning * into me;
  insert into event_log(user_id, kind, message) values (uid, 'heroi', me.name || ' trocou de herói.');
  return me;
end $$;

-- 6) Movimento (hoje ou dia recuperado) ---------------------------------
create or replace function public.do_move(_d date, _recovery boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := auth.uid(); c jsonb := public.cfg(); today date := public.game_today();
  me characters; other characters; nd board_nodes; tr traps; w jsonb; x record;
  m public.puzzle_mode; s guess_sessions; st int; modes jsonb := '{}'::jsonb;
  base int := 0; roll int; r2 int; i int; bonus int; skill_steps int := 0; total int; from_node int; landed int; path0 int;
  ev jsonb := '[]'::jsonb; sal int := 0; extra_coins int := 0; extra_xp int := 0; cls text; sv int; skill_on boolean; dodge boolean := false;
  card int; chance int; steal int; my_dist int; tmp_node int; tmp_path int[]; msg text; amt int;
  xp_gain int; coin_gain int; new_level int; old_level int;
begin
  perform public.settle();
  select * into me from characters where user_id = uid for update;
  if me.id is null then raise exception 'Crie seu personagem primeiro.'; end if;
  if exists (select 1 from daily_moves where user_id = uid and move_date = _d) then raise exception 'Você já andou nesse dia.'; end if;
  old_level := me.level; cls := me.class::text;
  skill_on := not _recovery and me.skill_date = today;
  sv := public.skill_value(cls, me.level);

  foreach m in array enum_range(null::public.puzzle_mode) loop
    s := null;
    select * into s from guess_sessions where user_id = uid and puzzle_date = _d and mode = m;
    st := public.mode_steps(coalesce(s.attempts,0), coalesce(s.solved,false));
    base := base + st;
    modes := modes || jsonb_build_object(m::text, jsonb_build_object('attempts', coalesce(s.attempts,0), 'solved', coalesce(s.solved,false), 'steps', st));
  end loop;

  roll := (c->>'roll_min')::int + floor(random() * ((c->>'roll_max')::int - (c->>'roll_min')::int + 1))::int;
  if skill_on and cls = 'arqueiro' then
    for i in 2..greatest(sv,2) loop
      r2 := (c->>'roll_min')::int + floor(random() * ((c->>'roll_max')::int - (c->>'roll_min')::int + 1))::int;
      roll := greatest(roll, r2);
    end loop;
    ev := ev || jsonb_build_object('t','habilidade','msg','Tiro certeiro: a roleta girou ' || greatest(sv,2) || ' vezes e ficou com ' || roll || '.');
  end if;
  if cls = 'arqueiro' and roll < (c->>'arqueiro_min_die')::int then
    roll := (c->>'arqueiro_min_die')::int;
    ev := ev || jsonb_build_object('t','arqueiro','msg','Olho de arqueiro: a roleta vale no mínimo ' || roll || '.');
  end if;
  if skill_on and cls = 'domador' then
    roll := roll * greatest(sv,2);
    ev := ev || jsonb_build_object('t','habilidade','msg','Montaria: a roleta valeu ' || greatest(sv,2) || ' vezes mais (' || roll || ').');
  end if;
  if skill_on and cls in ('guerreiro','ladino','clerigo') and sv > 0 then
    skill_steps := sv;
    ev := ev || jsonb_build_object('t','habilidade','msg',
      case cls when 'guerreiro' then 'Investida' when 'ladino' then 'Atalho' else 'Bênção' end || ': +' || sv || ' casas.');
  end if;
  if skill_on and cls = 'mago' then
    skill_steps := public.next_good_steps(me.id, sv);
    ev := ev || jsonb_build_object('t','habilidade','msg', case when skill_steps > 0 then 'Teleporte: saltou ' || skill_steps || ' casas até uma casa especial.' else 'Teleporte: nenhuma casa especial ao alcance.' end);
  end if;
  if skill_on and cls = 'ladino' then dodge := true; end if;
  if skill_on and cls = 'clerigo' then ev := ev || jsonb_build_object('t','habilidade','msg','Bênção ativa: nada te empurra para trás hoje.'); end if;

  bonus := me.bonus_steps;
  total := base + roll + bonus + skill_steps;
  from_node := me.node;

  if me.arrived_rank is not null then
    ev := ev || jsonb_build_object('t','castelo','msg','Você já está no Castelo. Continue jogando para ganhar moedas, XP e vencer rodadas.');
    total := 0;
  else
    update characters set bonus_steps = 0 where id = me.id;
    path0 := coalesce(array_length(me.path,1),1);
    w := public.walk(me.id, total);
    sal := sal + (w->>'salary')::int;
    landed := (w->>'node')::int;

    -- Ladino: pega moedas de quem ultrapassa
    if cls = 'ladino' then
      amt := public.passive_value('ladino', me.level);
      for x in
        select ch.id, ch.name, ch.coins from characters ch
        where ch.user_id <> uid and ch.arrived_rank is null
          and ch.node = any ((select path from characters where id = me.id)[path0 + 1 : coalesce(array_length((select path from characters where id = me.id),1),1) - 1])
        for update
      loop
        steal := least(amt, x.coins);
        if steal > 0 then
          update characters set coins = coins - steal where id = x.id;
          extra_coins := extra_coins + steal;
          ev := ev || jsonb_build_object('t','ladino','msg','Mão leve: pegou ' || steal || ' moedas de ' || x.name || ' ao passar.');
        end if;
      end loop;
    end if;

    -- 1) armadilha de outro jogador
    select * into tr from traps where node = landed and triggered_at is null and owner_id <> uid for update;
    if tr.id is not null then
      update traps set triggered_by = uid, triggered_at = now() where id = tr.id;
      select * into other from characters where user_id = tr.owner_id;
      if dodge then
        ev := ev || jsonb_build_object('t','armadilha','msg','Atalho: você desviou da armadilha de ' || other.name || '.');
      elsif cls = 'mago' and random() * 100 < (c->>'mago_resist_pct')::int then
        ev := ev || jsonb_build_object('t','armadilha','msg','Você desfez com magia a armadilha de ' || other.name || '.');
      elsif public.is_shielded(me.id) then
        ev := ev || jsonb_build_object('t','armadilha','msg','A Bênção te protegeu da armadilha de ' || other.name || '.');
      else
        perform public.go_back(me.id, (c->>'trap_push')::int);
        update characters set coins = coins + (c->>'trap_reward')::int where user_id = tr.owner_id;
        ev := ev || jsonb_build_object('t','armadilha','msg','Você caiu na armadilha de ' || other.name || ' e voltou ' || (c->>'trap_push') || ' casas.');
        insert into event_log(user_id, kind, message) values (uid, 'armadilha', me.name || ' caiu na armadilha de ' || other.name || '.');
      end if;
    else
      -- 2) efeito da casa
      select * into nd from board_nodes where id = landed;
      if nd.kind = 'avanco' then
        w := public.walk(me.id, nd.value); sal := sal + (w->>'salary')::int;
        ev := ev || jsonb_build_object('t','avanco','msg','Vento a favor! Avançou mais ' || nd.value || ' casas.');
      elsif nd.kind = 'recuo' then
        if dodge then ev := ev || jsonb_build_object('t','recuo','msg','Atalho: você contornou o lamaçal.');
        elsif public.is_shielded(me.id) then ev := ev || jsonb_build_object('t','recuo','msg','A Bênção te segurou no lamaçal.');
        elsif cls = 'mago' and random() * 100 < (c->>'mago_resist_pct')::int then ev := ev || jsonb_build_object('t','recuo','msg','Escorregou, mas a magia segurou você no lugar.');
        else perform public.go_back(me.id, nd.value); ev := ev || jsonb_build_object('t','recuo','msg','Lamaçal! Voltou ' || nd.value || ' casas.');
        end if;
      elsif nd.kind = 'bau' then
        extra_coins := extra_coins + (c->>'chest_coins')::int;
        ev := ev || jsonb_build_object('t','bau','msg','Achou um baú com ' || (c->>'chest_coins') || ' moedas.');
      elsif nd.kind = 'xp' then
        extra_xp := extra_xp + (c->>'xp_square')::int;
        ev := ev || jsonb_build_object('t','xp','msg','Treino na clareira: +' || (c->>'xp_square') || ' XP.');
      elsif nd.kind = 'pagamento' then
        ev := ev || jsonb_build_object('t','pagamento','msg','Parou no Dia de pagamento.');
      elsif nd.kind = 'carta' then
        card := floor(random() * 6)::int;
        if card = 0 then
          extra_coins := extra_coins + (c->>'card_coins_win')::int;
          ev := ev || jsonb_build_object('t','carta','msg','Carta da sorte: um treinador agradecido te deu ' || (c->>'card_coins_win') || ' moedas.');
        elsif card = 1 then
          amt := (c->>'card_coins_lose')::int; if cls = 'clerigo' then amt := ceil(amt / 2.0); end if;
          extra_coins := extra_coins - amt;
          ev := ev || jsonb_build_object('t','carta','msg','Carta do azar: sua mochila rasgou e você perdeu ' || amt || ' moedas.');
        elsif card = 2 then
          w := public.walk(me.id, (c->>'card_steps')::int); sal := sal + (w->>'salary')::int;
          ev := ev || jsonb_build_object('t','carta','msg','Carta da sorte: atalho secreto! Avançou ' || (c->>'card_steps') || ' casas.');
        elsif card = 3 then
          amt := (c->>'card_steps')::int; if cls = 'clerigo' then amt := ceil(amt / 2.0); end if;
          if public.is_shielded(me.id) then ev := ev || jsonb_build_object('t','carta','msg','Carta do azar: você ia se perder, mas a Bênção te guiou.');
          else perform public.go_back(me.id, amt); ev := ev || jsonb_build_object('t','carta','msg','Carta do azar: você se perdeu e voltou ' || amt || ' casas.');
          end if;
        elsif card = 4 then
          update characters set hints = hints + 1 where id = me.id;
          ev := ev || jsonb_build_object('t','carta','msg','Carta da sorte: ganhou 1 Dica.');
        else
          update characters set retries = retries + 1 where id = me.id;
          ev := ev || jsonb_build_object('t','carta','msg','Carta da sorte: ganhou 1 Tente outra vez.');
        end if;
      elsif nd.kind = 'raio' then
        select ch.* into other from characters ch join board_nodes b on b.id = ch.node
         where ch.arrived_rank is null and ch.user_id <> uid order by b.dist asc limit 1 for update of ch;
        my_dist := (select dist from board_nodes where id = landed);
        if other.id is null or (select dist from board_nodes where id = other.node) >= my_dist then
          ev := ev || jsonb_build_object('t','raio','msg','A tempestade caiu longe: ninguém está à sua frente.');
        elsif public.is_shielded(other.id) then
          ev := ev || jsonb_build_object('t','raio','msg','Você chamou um raio em ' || other.name || ', mas a Bênção dele o protegeu.');
        elsif other.class::text = 'mago' and random() * 100 < (c->>'mago_resist_pct')::int then
          ev := ev || jsonb_build_object('t','raio','msg','Você chamou um raio em ' || other.name || ', mas a magia dele desviou.');
        else
          perform public.go_back(other.id, (c->>'storm_push')::int);
          ev := ev || jsonb_build_object('t','raio','msg','Você chamou um raio no líder ' || other.name || ': ele voltou ' || (c->>'storm_push') || ' casas.');
          insert into event_log(user_id, kind, message) values (uid, 'raio', me.name || ' derrubou um raio no líder ' || other.name || '.');
        end if;
      elsif nd.kind = 'troca' then
        my_dist := (select dist from board_nodes where id = landed);
        select ch.* into other from characters ch join board_nodes b on b.id = ch.node
         where ch.arrived_rank is null and ch.user_id <> uid and b.dist < my_dist order by b.dist desc limit 1 for update of ch;
        if other.id is not null and public.is_shielded(other.id) then
          ev := ev || jsonb_build_object('t','troca','msg','O portal tentou te trocar com ' || other.name || ', mas a Bênção dele impediu.');
        elsif other.id is not null then
          select node, path into tmp_node, tmp_path from characters where id = me.id;
          update characters set node = other.node, path = other.path where id = me.id;
          update characters set node = tmp_node, path = tmp_path where id = other.id;
          ev := ev || jsonb_build_object('t','troca','msg','Portal! Você trocou de lugar com ' || other.name || '.');
          insert into event_log(user_id, kind, message) values (uid, 'troca', me.name || ' trocou de lugar com ' || other.name || ' pelo portal.');
        else
          ev := ev || jsonb_build_object('t','troca','msg','O portal não encontrou ninguém à sua frente.');
        end if;
      end if;
    end if;

    -- 3) encontro na mesma casa vira duelo
    select * into me from characters where id = me.id;
    select ch.* into other from characters ch join board_nodes b on b.id = ch.node
     where ch.user_id <> uid and ch.node = me.node and ch.arrived_rank is null and b.kind not in ('inicio','castelo')
     order by random() limit 1 for update of ch;
    if other.id is not null then
      chance := 50 + (me.level - other.level) * (c->>'duel_level_factor')::int
                   + case when cls = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end
                   - case when other.class::text = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end;
      chance := greatest(25, least(75, chance));
      if random() * 100 < chance then
        steal := least((c->>'duel_coins')::int, other.coins);
        update characters set coins = coins - steal where id = other.id;
        perform public.go_back(other.id, (c->>'duel_push')::int);
        extra_coins := extra_coins + steal;
        ev := ev || jsonb_build_object('t','duelo','msg','Encontro com ' || other.name || ': você venceu o duelo, ganhou ' || steal || ' moedas' || case when public.is_shielded(other.id) then '.' else ' e empurrou o rival.' end);
        insert into event_log(user_id, kind, message) values (uid, 'duelo', me.name || ' venceu um duelo contra ' || other.name || '.');
      else
        steal := least((c->>'duel_coins')::int, greatest(0, me.coins + extra_coins));
        update characters set coins = coins + steal where id = other.id;
        extra_coins := extra_coins - steal;
        perform public.go_back(me.id, (c->>'duel_push')::int);
        ev := ev || jsonb_build_object('t','duelo','msg','Encontro com ' || other.name || ': você perdeu o duelo e ' || steal || ' moedas' || case when public.is_shielded(me.id) then ', mas a Bênção te manteve no lugar.' else ' e voltou ' || (c->>'duel_push') || ' casas.' end);
        insert into event_log(user_id, kind, message) values (uid, 'duelo', other.name || ' defendeu sua casa contra ' || me.name || '.');
      end if;
    end if;

    if sal > 0 then ev := ev || jsonb_build_object('t','pagamento','msg','Dia de pagamento: +' || sal || ' moedas de salário.'); end if;
    msg := public.check_arrival(me.id);
    if msg is not null then ev := ev || jsonb_build_object('t','castelo','msg', msg); end if;
  end if;

  xp_gain := base * (c->>'xp_per_step')::int + (c->>'xp_daily_bonus')::int + extra_xp;
  coin_gain := base * (c->>'coins_per_step')::int + extra_coins;
  select * into me from characters where id = me.id;
  new_level := public.level_for_xp(me.xp_total + xp_gain);
  if new_level > old_level then
    ev := ev || jsonb_build_object('t','nivel','msg','Subiu para o nível ' || new_level || '!');
    insert into event_log(user_id, kind, message) values (uid, 'nivel', me.name || ' chegou ao nível ' || new_level || '.');
  end if;
  update characters set xp_total = xp_total + xp_gain, level = new_level,
         coins = greatest(0, coins + coin_gain), last_move_date = greatest(coalesce(last_move_date, _d), _d)
   where id = me.id returning * into me;

  insert into daily_moves(user_id, move_date, modes, base_steps, roll, bonus_steps, skill_steps, from_node, to_node, xp_gained, coins_gained, events, recovered)
  values (uid, _d, modes, base, roll, bonus, skill_steps, from_node, me.node, xp_gain, coin_gain + sal, ev, _recovery);
  insert into event_log(user_id, kind, message, data)
  values (uid, 'andou', me.name || ' andou ' || total || ' casas' || case when _recovery then ' recuperando o dia ' || to_char(_d, 'DD/MM') else '' end || '.', jsonb_build_object('steps', total));

  return jsonb_build_object('date', _d, 'recovery', _recovery, 'base', base, 'roll', roll, 'bonus', bonus, 'skill', skill_steps, 'total', total, 'modes', modes,
    'from', from_node, 'to', me.node, 'path', to_jsonb(me.path), 'events', ev,
    'xp', xp_gain, 'coins', coin_gain + sal, 'level', new_level, 'leveled', new_level > old_level);
end $$;

create or replace function public.move_today() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.assert_active();
  return public.do_move(public.game_today(), false);
end $$;

create or replace function public.move_day(_date date) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare d date;
begin
  perform public.assert_active();
  d := public.play_date(_date);
  if d = public.game_today() then raise exception 'Para hoje, use Andar no mapa.'; end if;
  return public.do_move(d, true);
end $$;

-- 7) Painel do dia: habilidade, bônus semanal do Domador e dias recuperáveis
create or replace function public.today_overview() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d date := public.game_today(); me characters; mv daily_moves; sp daily_spins; se seasons;
  summ jsonb; rec jsonb := '[]'::jsonb; k int; dd date; cr date; v int;
begin
  perform public.settle();
  select * into me from characters where user_id = uid for update;
  -- Domador: dicas grátis toda semana
  if me.class::text = 'domador' and (me.weekly_bonus_date is null or me.weekly_bonus_date < date_trunc('week', d)::date) then
    v := public.passive_value('domador', me.level);
    update characters set hints = hints + v, weekly_bonus_date = d where id = me.id;
    insert into event_log(user_id, kind, message) values (uid, 'domador', me.name || ' recebeu ' || v || ' dica(s) da semana.');
  end if;
  summ := public.modes_summary(uid, d);
  select * into mv from daily_moves where user_id = uid and move_date = d;
  select * into sp from daily_spins where user_id = uid and daily_spins.d = game_today();
  select * into se from seasons order by id desc limit 1;
  cr := (me.created_at at time zone coalesce(cfg()->>'timezone','America/Sao_Paulo'))::date;
  for k in 1..(cfg()->>'recovery_days')::int loop
    dd := d - k;
    if dd >= cr and not exists (select 1 from daily_moves where user_id = uid and move_date = dd) then
      rec := rec || jsonb_build_object('date', dd, 'until', dd + (cfg()->>'recovery_days')::int + 1,
        'modes_done', (select count(*) from guess_sessions gs where gs.user_id = uid and gs.puzzle_date = dd and (gs.solved or gs.failed)));
    end if;
  end loop;
  return summ || jsonb_build_object(
    'moved', mv.id is not null, 'move', case when mv.id is not null then to_jsonb(mv) end,
    'spin', case when sp.user_id is not null then sp.prize end,
    'skill', jsonb_build_object('used', me.skill_date = d, 'rank', public.skill_rank(me.level), 'value', public.skill_value(me.class::text, me.level),
                                'passive', public.passive_value(me.class::text, me.level)),
    'recoverable', rec,
    'season', jsonb_build_object('id', se.id, 'status', se.status, 'started_on', se.started_on,
       'arrivals', coalesce((select jsonb_agg(jsonb_build_object('user_id', user_id, 'name', name, 'rank', arrived_rank) order by arrived_rank)
                             from characters where arrived_rank is not null), '[]'::jsonb)),
    'yesterday', coalesce((select jsonb_agg(jsonb_build_object('user_id', rr.user_id, 'name', ch.name, 'rank', rr.rank, 'attempts', rr.attempts) order by rr.rank)
                           from round_results rr join characters ch on ch.user_id = rr.user_id
                           where rr.d = public.game_today() - 1 and rr.rank <= 3), '[]'::jsonb),
    'server_time', now());
end $$;

create or replace function public.day_status(_date date) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d date := public.play_date(_date);
begin
  return public.modes_summary(uid, d) || jsonb_build_object('recovery', d < public.game_today(), 'moved', false,
    'until', d + (public.cfg()->>'recovery_days')::int + 1);
end $$;

-- 8) Mercado -------------------------------------------------------------
create or replace function public.inv_take(_uid uuid, _kind text, _item text, _qty int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me characters;
begin
  select * into me from characters where user_id = _uid for update;
  if _kind = 'item' then
    if not (_item = any(me.owned_items)) then raise exception 'Item não encontrado no inventário.'; end if;
    update characters set owned_items = array_remove(owned_items, _item),
      outfit = (select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from jsonb_each(outfit) e(k, v) where v <> to_jsonb(_item))
    where id = me.id;
  elsif _kind = 'dica' then
    if me.hints < _qty then raise exception 'Dicas insuficientes.'; end if;
    update characters set hints = hints - _qty where id = me.id;
  else
    if me.retries < _qty then raise exception 'Tente outra vez insuficientes.'; end if;
    update characters set retries = retries - _qty where id = me.id;
  end if;
end $$;

create or replace function public.inv_give(_uid uuid, _kind text, _item text, _qty int) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if _kind = 'item' then
    update characters set owned_items = case when _item = any(owned_items) then owned_items else array_append(owned_items, _item) end where user_id = _uid;
  elsif _kind = 'dica' then update characters set hints = hints + _qty where user_id = _uid;
  else update characters set retries = retries + _qty where user_id = _uid;
  end if;
end $$;

create or replace function public.expire_listings() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare l market_listings;
begin
  for l in update market_listings set status = 'expirado', closed_at = now()
           where status = 'aberto' and expires_at < now() returning * loop
    perform public.inv_give(l.seller_id, l.item_kind, l.item_id, l.qty);
  end loop;
end $$;

create or replace function public.market_refresh() returns setof public.market_listings
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.assert_active();
  perform public.expire_listings();
  return query select * from market_listings
   where status = 'aberto' or (closed_at > now() - interval '3 days' and (seller_id = auth.uid() or buyer_id = auth.uid()))
   order by created_at desc limit 200;
end $$;

create or replace function public.market_create(_kind text, _item text, _qty int, _price int, _want_kind text, _want_item text, _want_qty int) returns public.market_listings
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); l market_listings; nm text; it text; mine text[];
begin
  perform public.expire_listings();
  if _kind not in ('item','dica','retry') then raise exception 'Tipo de item inválido.'; end if;
  if _kind = 'item' then
    _qty := 1;
    if not exists (select 1 from shop_items where id = _item) then raise exception 'Item inválido.'; end if;
  else _item := null; _qty := coalesce(_qty, 1);
  end if;
  if (coalesce(_price,0) > 0) = (_want_kind is not null) then raise exception 'Escolha vender por moedas ou trocar por um item, não os dois.'; end if;
  if _want_kind is not null then
    if _want_kind not in ('item','dica','retry') then raise exception 'Troca inválida.'; end if;
    if _want_kind = 'item' then
      _want_qty := 1;
      if not exists (select 1 from shop_items where id = _want_item) then raise exception 'Item pedido inválido.'; end if;
      select owned_items into mine from characters where user_id = uid;
      if _want_item = any(mine) then raise exception 'Você já tem o item que está pedindo.'; end if;
    else _want_item := null; _want_qty := coalesce(_want_qty, 1);
    end if;
    _price := null;
  end if;
  if (select count(*) from market_listings where seller_id = uid and status = 'aberto') >= (c->>'market_max_open')::int then
    raise exception 'Você já tem % anúncios abertos.', (c->>'market_max_open');
  end if;
  perform public.inv_take(uid, _kind, _item, _qty);
  insert into market_listings(seller_id, item_kind, item_id, qty, price, want_kind, want_item, want_qty, expires_at)
  values (uid, _kind, _item, _qty, nullif(_price,0), _want_kind, _want_item, _want_qty, now() + make_interval(hours => (c->>'market_hours')::int))
  returning * into l;
  nm := (select name from characters where user_id = uid);
  it := case _kind when 'item' then (select name from shop_items where id = _item) when 'dica' then _qty || ' Dica(s)' else _qty || ' Tente outra vez' end;
  insert into event_log(user_id, kind, message) values (uid, 'mercado', nm || ' anunciou ' || it || ' no mercado.');
  return l;
end $$;

create or replace function public.market_cancel(_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); l market_listings;
begin
  select * into l from market_listings where id = _id for update;
  if l.id is null or l.seller_id <> uid then raise exception 'Anúncio não encontrado.'; end if;
  if l.status <> 'aberto' then raise exception 'Esse anúncio já foi encerrado.'; end if;
  update market_listings set status = 'cancelado', closed_at = now() where id = _id;
  perform public.inv_give(uid, l.item_kind, l.item_id, l.qty);
end $$;

create or replace function public.market_buy(_id uuid) returns public.characters
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); l market_listings; me characters; fee int; it text; sname text; sitems text[];
begin
  perform public.expire_listings();
  select * into l from market_listings where id = _id for update;
  if l.id is null or l.status <> 'aberto' then raise exception 'Esse anúncio não está mais disponível.'; end if;
  if l.seller_id = uid then raise exception 'Esse anúncio é seu.'; end if;
  select * into me from characters where user_id = uid for update;
  if l.item_kind = 'item' and l.item_id = any(me.owned_items) then raise exception 'Você já tem esse item.'; end if;
  if l.price is not null then
    if me.coins < l.price then raise exception 'Moedas insuficientes.'; end if;
    fee := ceil(l.price * (c->>'market_fee_pct')::numeric / 100);
    update characters set coins = coins - l.price where id = me.id;
    update characters set coins = coins + l.price - fee where user_id = l.seller_id;
    update market_listings set status = 'vendido', buyer_id = uid, closed_at = now() where id = l.id;
  else
    select owned_items into sitems from characters where user_id = l.seller_id;
    if l.want_kind = 'item' and l.want_item = any(sitems) then
      raise exception 'O vendedor já tem o item pedido. A troca não pode ser feita.';
    end if;
    perform public.inv_take(uid, l.want_kind, l.want_item, l.want_qty);
    perform public.inv_give(l.seller_id, l.want_kind, l.want_item, l.want_qty);
    update market_listings set status = 'trocado', buyer_id = uid, closed_at = now() where id = l.id;
  end if;
  perform public.inv_give(uid, l.item_kind, l.item_id, l.qty);
  it := case l.item_kind when 'item' then (select name from shop_items where id = l.item_id) when 'dica' then l.qty || ' Dica(s)' else l.qty || ' Tente outra vez' end;
  sname := (select name from characters where user_id = l.seller_id);
  insert into event_log(user_id, kind, message) values (uid, 'mercado', me.name || case when l.price is not null then ' comprou ' else ' trocou com ' || sname || ' e levou ' end || it || case when l.price is not null then ' de ' || sname || '.' else '.' end);
  select * into me from characters where id = me.id;
  return me;
end $$;

-- 9) Segurança ----------------------------------------------------------
alter table public.market_listings enable row level security;
revoke all on public.market_listings from anon, authenticated;
grant select on public.market_listings to authenticated;
drop policy if exists p_market on public.market_listings;
create policy p_market on public.market_listings for select to authenticated using (true);

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
  public.admin_players(), public.admin_set_status(uuid, text, text), public.admin_adjust(uuid, int, int, int, text),
  public.admin_reset_day(uuid, date, text), public.admin_set_config(jsonb, text), public.admin_undo_move(uuid, text),
  public.admin_new_season(text), public.admin_save_media(int, text, jsonb, text), public.admin_media_status()
to authenticated;
