-- =====================================================================
-- 44_equipe_rocket.sql
-- Pedido do dono em 22/10/2026 (lista de ideias, item 4): Invasão da Equipe Rocket, em formato Raid.
--   * Toda terça, sexta e domingo, às 8h (Brasília), a Equipe Rocket invade por 24 horas.
--   * A Rocket tem uma barra de vida COLETIVA, que cresce com o número de jogadores ativos com Pokémon.
--   * Cada jogador cede 1 Pokémon (uma vez por invasão) e luta a sua parte quando quiser, turno a turno,
--     escolhendo os ataques na tela de batalha de sempre; o servidor joga pela Rocket na hora.
--     Todo dano que cada um tira da Rocket sai da mesma barra.
--   * Barra zerada dentro das 24 h: vitória, e cada participante ganha 100 moedas.
--   * Se não zerar: sorteio entre os participantes (uma chance por pessoa) e a Rocket ROUBA PARA SEMPRE
--     o Pokémon que o sorteado cedeu (decisão do dono). Quem não participou não corre risco.
--   * O XP de batalha vale como nas outras batalhas (quem derruba ganha).
--   * Sem tarefa agendada: a invasão começa e termina pelo settle(), na primeira ação depois do horário.
--   * Números em game_config.config.rocket; o admin pode chamar a Rocket na hora (admin_rocket_start).
-- Depende do 15, 17, 18, 25 e 43. Antes, faça a cópia de segurança.
-- =====================================================================

update public.game_config set config = config || jsonb_build_object('rocket',
  '{"days": [0, 2, 5], "hour": 8, "hours": 24, "reward": 100, "hp_factor": 0.5, "max_turns": 30, "level_bonus": 2}'::jsonb)
 where active and not (config ? 'rocket');
create or replace function public.rocket_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"days":[0,2,5],"hour":8,"hours":24,"reward":100,"hp_factor":0.5,"max_turns":30,"level_bonus":2}'::jsonb || coalesce(public.cfg()->'rocket', '{}'::jsonb)
$$;

alter table public.battles drop constraint if exists battles_check;
alter table public.battles add constraint battles_check check (p1 <> p2 or mode in ('npc', 'rocket'));

create table if not exists public.rocket_raids (
  id           bigserial primary key,
  status       text not null default 'ativa' check (status in ('ativa', 'vitoria', 'derrota')),
  starts_at    timestamptz not null,
  ends_at      timestamptz not null,
  level        int not null,
  team         jsonb not null,             -- [{species, name}] (os 3 Pokémon da Rocket)
  players      int not null,               -- jogadores ativos com Pokémon quando começou
  hp_total     int not null,
  hp_left      int not null,
  stolen_user  uuid,
  stolen_name  text,                        -- nome do jogador
  stolen_mon   text,                        -- nome do Pokémon roubado
  stolen_species int,
  stolen_level int,
  resolved_at  timestamptz,
  created_at   timestamptz not null default now()
);
create table if not exists public.rocket_entries (
  raid_id    bigint not null references public.rocket_raids(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  name       text not null,
  mon_id     uuid,
  mon_name   text not null,
  species    int not null,
  level      int not null,
  battle_id  uuid,
  damage     int not null default 0,
  done       boolean not null default false,
  joined_at  timestamptz not null default now(),
  primary key (raid_id, user_id)
);
alter table public.rocket_raids enable row level security;
alter table public.rocket_entries enable row level security;
drop policy if exists p_rocket_raids on public.rocket_raids;
create policy p_rocket_raids on public.rocket_raids for select to authenticated using (true);
drop policy if exists p_rocket_entries on public.rocket_entries;
create policy p_rocket_entries on public.rocket_entries for select to authenticated using (true);
revoke all on public.rocket_raids, public.rocket_entries from anon, authenticated;
grant select on public.rocket_raids, public.rocket_entries to authenticated;
do $$ begin
  begin alter publication supabase_realtime add table public.rocket_raids; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.rocket_entries; exception when duplicate_object then null; end;
end $$;

-- dano já tirado da Rocket numa luta (soma do que falta de vida nos Pokémon dela)
create or replace function public.rocket_dmg(_state jsonb) returns int
language sql immutable as $$
  select coalesce(sum((x->>'maxhp')::int - greatest(0, (x->>'hp')::int)), 0)::int from jsonb_array_elements(_state->'sides'->1->'mons') x
$$;

-- os 3 Pokémon da Rocket para uma luta (sempre novos, com vida cheia)
create or replace function public.rocket_side(_raid rocket_raids, _uid uuid) returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object('user', _uid, 'name', 'Equipe Rocket', 'npc', true, 'active', 0, 'need_switch', false,
    'mons', (select jsonb_agg(public.npc_mon((t->>'species')::int, _raid.level) order by o) from jsonb_array_elements(_raid.team) with ordinality x(t, o)))
$$;

-- começa uma invasão
create or replace function public.rocket_begin(_starts timestamptz, _hours int) returns public.rocket_raids
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rocket_cfg(); r rocket_raids; lvl int; n int; team jsonb; hp int; pool int[];
begin
  select count(distinct a.user_id) into n from public.day_active(public.game_today()) a where exists (select 1 from monsters m where m.user_id = a.user_id);
  select round(avg(m.level))::int into lvl from monsters m where m.team_slot is not null and m.user_id in (select user_id from public.day_active(public.game_today()));
  lvl := greatest(5, least(100, coalesce(lvl, 10) + (c->>'level_bonus')::int));
  pool := case when lvl < 25 then array[19, 23, 41, 52, 88, 109] else array[20, 24, 42, 53, 89, 110] end;
  select jsonb_agg(jsonb_build_object('species', p.id, 'name', p.name)) into team
    from (select id, name from pokemon where id = any(pool) order by random() limit 3) p;
  insert into rocket_raids(starts_at, ends_at, level, team, players, hp_total, hp_left)
  values (_starts, _starts + make_interval(hours => _hours), lvl, team, greatest(1, n), 1, 1) returning * into r;
  -- vida coletiva: vida da equipe da Rocket × jogadores × fator (padrão 0,5: metade dos jogadores derrubando a equipe toda)
  hp := greatest(1, round(public.rocket_dmg(jsonb_build_object('sides', jsonb_build_array('{}'::jsonb,
          jsonb_set(public.rocket_side(r, null), '{mons}', (select jsonb_agg(jsonb_set(x, '{hp}', '0')) from jsonb_array_elements(public.rocket_side(r, null)->'mons') x)))))
          * greatest(1, n) * (c->>'hp_factor')::numeric))::int;
  update rocket_raids set hp_total = hp, hp_left = hp where id = r.id returning * into r;
  insert into event_log(kind, message) values ('rocket', '🚀 A Equipe Rocket invadiu! Ceda 1 Pokémon e lute junto com todos para expulsar a Rocket em ' || _hours || ' horas, ou alguém vai perder um Pokémon!');
  return r;
end $$;

-- vitória: cada participante ganha as moedas
create or replace function public.rocket_win(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rocket_cfg(); n int;
begin
  update rocket_raids set status = 'vitoria', hp_left = 0, resolved_at = now() where id = _id and status = 'ativa';
  if not found then return; end if;
  update characters ch set coins = coins + (c->>'reward')::int from rocket_entries e where e.raid_id = _id and e.user_id = ch.user_id;
  select count(*) into n from rocket_entries where raid_id = _id;
  insert into event_log(kind, message) values ('rocket', '🎉 A Equipe Rocket foi expulsa! Os ' || n || ' treinadores que lutaram ganharam ' || (c->>'reward') || ' moedas cada.');
end $$;

-- derrota: sorteio (uma chance por pessoa) e a Rocket rouba o Pokémon cedido pelo sorteado
create or replace function public.rocket_lose(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare e rocket_entries; m monsters;
begin
  perform 1 from rocket_raids where id = _id and status = 'ativa' for update;
  if not found then return; end if;
  select x.* into e from rocket_entries x join monsters mm on mm.id = x.mon_id and mm.user_id = x.user_id
   where x.raid_id = _id order by random() limit 1;
  if e.user_id is null then
    update rocket_raids set status = 'derrota', resolved_at = now() where id = _id;
    insert into event_log(kind, message) values ('rocket', '🚀 A Equipe Rocket foi embora sem levar nada: ninguém tinha Pokémon cedido para roubar.');
    return;
  end if;
  select * into m from monsters where id = e.mon_id;
  update rocket_raids set status = 'derrota', resolved_at = now(), stolen_user = e.user_id, stolen_name = e.name,
         stolen_mon = e.mon_name, stolen_species = m.species_id, stolen_level = m.level where id = _id;
  delete from monsters where id = e.mon_id;
  update characters set mascot = null where user_id = e.user_id and (mascot->>'id')::uuid = e.mon_id;
  insert into event_log(user_id, kind, message) values (e.user_id, 'rocket', '😱 A Equipe Rocket venceu e roubou o ' || e.mon_name || ' (nível ' || m.level || ') de ' || e.name || '!');
end $$;

-- abre e fecha invasões no horário (chamado pelo settle)
create or replace function public.rocket_tick() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rocket_cfg(); tz text := coalesce(public.cfg()->>'timezone', 'America/Sao_Paulo'); r rocket_raids;
  loc timestamp := now() at time zone tz; st timestamptz;
begin
  for r in select * from rocket_raids where status = 'ativa' loop
    if r.hp_left <= 0 then perform public.rocket_win(r.id);
    elsif now() >= r.ends_at then perform public.rocket_lose(r.id); end if;
  end loop;
  if not (extract(dow from loc)::int in (select x::int from jsonb_array_elements_text(c->'days') x)) then return; end if;
  if extract(hour from loc)::int < (c->>'hour')::int then return; end if;
  st := (date_trunc('day', loc) + make_interval(hours => (c->>'hour')::int)) at time zone tz;
  if exists (select 1 from rocket_raids where starts_at >= st - interval '1 hour') or exists (select 1 from rocket_raids where status = 'ativa') then return; end if;
  if now() >= st + make_interval(hours => (c->>'hours')::int) then return; end if;
  perform pg_advisory_xact_lock(4404);
  if exists (select 1 from rocket_raids where starts_at >= st - interval '1 hour') then return; end if;
  perform public.rocket_begin(st, (c->>'hours')::int);
end $$;

-- depois de cada turno contra a Rocket: conta o dano, fecha a luta e checa a vitória
create or replace function public.rocket_after(_bid uuid, _pre int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b battles; c jsonb := public.rocket_cfg(); e rocket_entries; d int; left_ int; mine_alive boolean; rk_alive boolean;
begin
  select * into b from battles where id = _bid;
  select * into e from rocket_entries where battle_id = _bid for update;
  if e.user_id is null then return; end if;
  d := greatest(0, public.rocket_dmg(b.state) - coalesce(_pre, 0));
  if d > 0 then
    update rocket_entries set damage = damage + d where raid_id = e.raid_id and user_id = e.user_id;
    update rocket_raids set hp_left = greatest(0, hp_left - d) where id = e.raid_id and status = 'ativa' returning hp_left into left_;
    if left_ is not null and left_ <= 0 then perform public.rocket_win(e.raid_id); end if;
  end if;
  if b.status = 'ativa' and b.turn > (c->>'max_turns')::int then
    update battles set log = log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt', 'A Equipe Rocket fugiu da luta!'))))
     where id = b.id;
    perform public.bt_finish(b.id, null, 'limite');
    select * into b from battles where id = _bid;
  end if;
  if b.status <> 'ativa' then
    update rocket_entries set done = true where raid_id = e.raid_id and user_id = e.user_id;
    -- os dois lados são do mesmo jogador: o "vencedor" certo é quem ficou de pé
    mine_alive := exists (select 1 from jsonb_array_elements(b.state->'sides'->0->'mons') x where (x->>'hp')::int > 0);
    rk_alive := exists (select 1 from jsonb_array_elements(b.state->'sides'->1->'mons') x where (x->>'hp')::int > 0);
    update battles set winner = case when mine_alive and not rk_alive then b.p1 end where id = b.id;
  end if;
end $$;

-- o que o jogador vê da invasão atual (ou da última, por 3 dias)
create or replace function public.rocket_current() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); r rocket_raids; e rocket_entries;
begin
  perform public.rocket_tick();
  select * into r from rocket_raids where status = 'ativa' or resolved_at > now() - interval '3 days' order by id desc limit 1;
  if r.id is null then return null; end if;
  select * into e from rocket_entries where raid_id = r.id and user_id = uid;
  return to_jsonb(r) || jsonb_build_object(
    'joined', (select count(*) from rocket_entries where raid_id = r.id),
    'ranking', (select coalesce(jsonb_agg(jsonb_build_object('user_id', x.user_id, 'name', x.name, 'mon', x.mon_name, 'species', x.species, 'damage', x.damage, 'done', x.done) order by x.damage desc), '[]'::jsonb)
                  from rocket_entries x where x.raid_id = r.id),
    'me', case when e.user_id is null then null else jsonb_build_object('mon', e.mon_name, 'species', e.species, 'damage', e.damage, 'done', e.done, 'battle_id', e.battle_id) end);
end $$;

-- ceder 1 Pokémon e começar a sua luta
create or replace function public.rocket_join(_mon uuid) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); r rocket_raids; m monsters; ch characters; s0 jsonb; s1 jsonb; bid uuid;
begin
  perform public.rocket_tick();
  select * into r from rocket_raids where status = 'ativa' order by id desc limit 1 for update;
  if r.id is null then raise exception 'A Equipe Rocket não está invadindo agora.'; end if;
  if now() >= r.ends_at then raise exception 'A invasão já acabou.'; end if;
  if exists (select 1 from rocket_entries where raid_id = r.id and user_id = uid) then raise exception 'Você já cedeu um Pokémon nesta invasão.'; end if;
  select * into m from monsters where id = _mon and user_id = uid;
  if m.id is null then raise exception 'Escolha um Pokémon seu.'; end if;
  select * into ch from characters where user_id = uid;
  s0 := jsonb_build_object('user', uid, 'name', ch.name, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(public.bt_mon(m.id)));
  s1 := public.rocket_side(r, uid);
  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (uid, uid, 'rocket', 1, 'ativa', 1, 'normal', now(), jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', 'Prepare-se para encrenca! A Equipe Rocket chegou!'),
            jsonb_build_object('txt', ch.name || ' mandou ' || (s0->'mons'->0->>'name') || '!'),
            jsonb_build_object('txt', 'A Equipe Rocket mandou ' || (s1->'mons'->0->>'name') || '!')))))
  returning id into bid;
  insert into rocket_entries(raid_id, user_id, name, mon_id, mon_name, species, level, battle_id)
  values (r.id, uid, ch.name, m.id, (select name from pokemon where id = m.species_id), m.species_id, m.level, bid);
  return bid;
end $$;

-- admin: chamar a Equipe Rocket agora (para eventos)
create or replace function public.admin_rocket_start(_hours int default 24) returns public.rocket_raids
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); r rocket_raids;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador chama a Equipe Rocket.'; end if;
  if exists (select 1 from rocket_raids where status = 'ativa') then raise exception 'A Equipe Rocket já está invadindo.'; end if;
  if coalesce(_hours, 24) not between 1 and 72 then raise exception 'Duração: de 1 a 72 horas.'; end if;
  r := public.rocket_begin(now(), coalesce(_hours, 24));
  insert into admin_audit_log(admin_id, action, target) values (uid, 'rocket', r.id::text);
  return r;
end $$;

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
  perform public.rocket_tick();
  select * into s from seasons order by id desc limit 1;
  if s.status = 'encerrada' and s.ended_on < d then perform public.start_new_season(); end if;
end $$;

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
  if b.mode in ('guerra', 'liga', 'npc', 'rocket') then return; end if;
  select name into wn from characters where user_id = _winner;
  select name into ln from characters where user_id = case when _winner = b.p1 then b.p2 else b.p1 end;
  if _winner is not null then insert into event_log(user_id, kind, message) values (_winner, 'batalha', wn || ' venceu a batalha Pokémon contra ' || ln || case when b.bet > 0 and b.bet_paid then ' e levou ' || 2 * b.bet || ' moedas' else '' end || '!'); end if;
end $$;

create or replace function public.bt_arena_trigger() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  if new.mode in ('guerra', 'npc', 'rocket') then return null; end if;
  perform public.arena_sync(new.id);
  return null;
end $$;

create or replace function public.battle_act(_id uuid, _turn int, _kind text, _value int) returns public.battles
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); b battles; side int; s jsonb; A jsonb; kind text := _kind; ok boolean; pre int; p jsonb; k int;
begin
  select * into b from battles where id = _id for update;
  if b.id is null or uid not in (b.p1, b.p2) then raise exception 'Batalha não encontrada.'; end if;
  if b.status <> 'ativa' then raise exception 'Essa batalha não está em andamento.'; end if;
  side := case when uid = b.p1 then 0 else 1 end;
  if _kind = 'forfeit' then
    update battles set log = log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt', (b.state->'sides'->side->>'name') || ' desistiu da batalha.'))))
     where id = b.id;
    perform public.bt_finish(b.id, case when side = 0 then b.p2 else b.p1 end, 'desistencia');
    if b.mode = 'rocket' then perform public.rocket_after(b.id, public.rocket_dmg(b.state)); end if;
    select * into b from battles where id = _id; return b;
  end if;
  if _turn <> b.turn then raise exception 'Esse turno já passou. Atualize a tela.'; end if;
  if (side = 0 and b.ready1) or (side = 1 and b.ready2) then raise exception 'Você já escolheu a ação deste turno. Espere o adversário.'; end if;
  s := b.state; A := s->'sides'->side->'mons'->((s->'sides'->side->>'active')::int);
  if b.phase = 'troca' or coalesce((s->'sides'->side->>'need_switch')::boolean, false) then
    if _kind <> 'switch' then raise exception 'Escolha qual Pokémon vai entrar.'; end if;
  end if;
  if _kind = 'switch' then
    if _value is null or _value < 0 or _value >= jsonb_array_length(s->'sides'->side->'mons') then raise exception 'Pokémon inválido.'; end if;
    if _value = (s->'sides'->side->>'active')::int then raise exception 'Esse Pokémon já está em campo.'; end if;
    if (s->'sides'->side->'mons'->_value->>'hp')::int <= 0 then raise exception 'Esse Pokémon desmaiou.'; end if;
    if (A->>'hp')::int > 0 and b.phase <> 'troca' and (coalesce(A->'fl'->>'charging', '') <> '' or coalesce((A->'fl'->>'recharge')::boolean, false)) then raise exception 'Não dá para trocar agora.'; end if;
  elsif _kind = 'move' then
    if coalesce(A->'fl'->>'charging', '') <> '' or coalesce((A->'fl'->>'recharge')::boolean, false) then kind := 'forced';
    elsif _value = -1 then
      select bool_and((x->>'pp')::int = 0) into ok from jsonb_array_elements(A->'moves') x;
      if not ok then raise exception 'Ainda há ataques com PP.'; end if;
    else
      if _value is null or _value < 0 or _value >= jsonb_array_length(A->'moves') then raise exception 'Ataque inválido.'; end if;
      if (A->'moves'->_value->>'pp')::int <= 0 then raise exception 'Esse ataque está sem PP.'; end if;
    end if;
  else raise exception 'Ação inválida.'; end if;
  insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, side, uid, kind, _value);
  -- Equipe Rocket (arquivo 44): o servidor joga pelo lado da Rocket na hora e conta o dano na barra coletiva
  if b.mode = 'rocket' then
    pre := public.rocket_dmg(b.state);
    p := public.war_pick(b.state, 1, 'forte');
    insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, uid, p->>'kind', (p->>'value')::int);
    perform public.bt_resolve(b.id);
    for k in 1 .. 3 loop
      select * into b from battles where id = _id;
      exit when b.status <> 'ativa' or b.phase <> 'troca' or not coalesce((b.state->'sides'->1->>'need_switch')::boolean, false);
      insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, uid, 'switch', public.war_switch(b.state, 1, true));
      perform public.bt_resolve(b.id);
    end loop;
    perform public.rocket_after(_id, pre);
    select * into b from battles where id = _id;
    return b;
  end if;
  if side = 0 then update battles set ready1 = true where id = b.id returning * into b;
  else update battles set ready2 = true where id = b.id returning * into b; end if;
  if b.ready1 and b.ready2 then perform public.bt_resolve(b.id); end if;
  select * into b from battles where id = _id;
  return b;
end $$;

revoke execute on function public.rocket_cfg(), public.rocket_side(rocket_raids, uuid), public.rocket_begin(timestamptz, int), public.rocket_win(bigint),
  public.rocket_lose(bigint), public.rocket_tick(), public.rocket_after(uuid, int) from public, anon, authenticated;
revoke execute on function public.rocket_current(), public.rocket_join(uuid), public.admin_rocket_start(int) from public, anon;
grant execute on function public.rocket_current(), public.rocket_join(uuid), public.admin_rocket_start(int), public.battle_act(uuid, int, text, int) to authenticated;
