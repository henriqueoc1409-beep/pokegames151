-- =====================================================================
-- POKEGAMES — Minha Vila (mina, torre, catapulta), World Boss, Times
-- e o relatório do Jornal do dia.
-- Antes de rodar, faça a cópia de segurança.
-- Rode UMA vez no SQL Editor, depois do 08. Não apaga nenhum dado.
-- =====================================================================

update public.game_config set config = config || '{
  "mine_costs": [300, 600, 1200], "mine_rates": [20, 40, 70], "collect_max_days": 7,
  "tower_cost": 400, "tower_days": 3, "tower_max": 3,
  "catapult_cost": 500, "catapult_push": 2, "catapult_days": 7,
  "mud_clean_per_level": 50,
  "boss_spawn_pct": 30, "boss_days": 3, "boss_hp_per_player": 120, "boss_hp_min": 600,
  "boss_min_attack": 10, "boss_max_attack": 200, "boss_xp_mult": 1.5, "boss_buff_days": 2,
  "boss_pool": [144, 145, 146, 150, 151],
  "teams": {"chama": {"nome": "Equipe Chama", "cor": "#E0603A"}, "mare": {"nome": "Equipe Maré", "cor": "#3E8FC4"}, "trovao": {"nome": "Equipe Trovão", "cor": "#E0B44C"}},
  "team_week_bonus": 50, "team_change_price": 200,
  "jornal_pesado": true
}'::jsonb where active;

-- 1) Tabelas e colunas --------------------------------------------------
alter table public.characters
  add column if not exists team          text,
  add column if not exists pending_mud   int not null default 0,
  add column if not exists xp_buff_until date;

create table if not exists public.villages (
  user_id            uuid primary key references auth.users(id) on delete cascade,
  statues            int  not null default 0,
  castles            int  not null default 0,
  mud                int  not null default 0 check (mud between 0 and 3),
  mine_level         int  not null default 0 check (mine_level between 0 and 3),
  mine_collected_at  date,
  tower_level        int  not null default 0 check (tower_level between 0 and 1),
  tower_collected_at date,
  catapult_level     int  not null default 0 check (catapult_level between 0 and 1),
  catapult_used_at   date,
  created_at         timestamptz not null default now()
);

create table if not exists public.world_bosses (
  id          serial primary key,
  pokemon_id  int not null references public.pokemon(id),
  node        int not null references public.board_nodes(id),
  hp          int not null,
  max_hp      int not null,
  status      text not null default 'ativo' check (status in ('ativo','derrotado','fugiu')),
  started_on  date not null,
  ends_on     date not null,
  defeated_at timestamptz
);
create table if not exists public.boss_contacts (boss_id int references public.world_bosses(id) on delete cascade, user_id uuid not null, primary key (boss_id, user_id));
create table if not exists public.boss_attacks (
  boss_id int references public.world_bosses(id) on delete cascade, user_id uuid not null, d date not null,
  coins int not null, damage int not null, created_at timestamptz not null default now(), primary key (boss_id, user_id, d));
create table if not exists public.boss_rolls (d date primary key);
create table if not exists public.team_weeks (week_start date primary key, winner text, steps int, settled_at timestamptz not null default now());

-- 2) Minha Vila ---------------------------------------------------------
create or replace function public.village_state(_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); t date := public.game_today(); who uuid; v villages; ch characters;
  mine_days int := 0; mine_coins int := 0; tower_n int := 0; cat_ready boolean;
begin
  who := coalesce(_user, uid);
  insert into villages(user_id) select who where exists (select 1 from characters where user_id = who) on conflict do nothing;
  select * into v from villages where user_id = who;
  select * into ch from characters where user_id = who;
  if v.user_id is null then raise exception 'Jogador não encontrado.'; end if;
  if v.mine_level > 0 then
    mine_days := least((c->>'collect_max_days')::int, greatest(0, t - coalesce(v.mine_collected_at, t)));
    mine_coins := mine_days * (c->'mine_rates'->>(v.mine_level - 1))::int;
  end if;
  if v.tower_level > 0 then
    tower_n := least((c->>'tower_max')::int, greatest(0, (t - coalesce(v.tower_collected_at, t)) / (c->>'tower_days')::int));
  end if;
  cat_ready := v.catapult_level > 0 and (v.catapult_used_at is null or v.catapult_used_at <= t - (c->>'catapult_days')::int);
  return to_jsonb(v) || jsonb_build_object(
    'mine', who = uid, 'name', ch.name, 'class', ch.class, 'level', ch.level, 'outfit', ch.outfit,
    'mine_ready', case when who = uid then mine_coins end,
    'tower_ready', case when who = uid then tower_n end,
    'catapult_ready', case when who = uid then cat_ready end,
    'catapult_next', case when v.catapult_used_at is not null then v.catapult_used_at + (c->>'catapult_days')::int end,
    'clean_cost', v.mud * (c->>'mud_clean_per_level')::int);
end $$;

create or replace function public.village_build(_kind text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); t date := public.game_today(); v villages; me characters; cost int; nm text;
begin
  insert into villages(user_id) values (uid) on conflict do nothing;
  select * into v from villages where user_id = uid for update;
  select * into me from characters where user_id = uid for update;
  if _kind = 'mina' then
    if v.mine_level >= 3 then raise exception 'A mina já está no nível máximo.'; end if;
    cost := (c->'mine_costs'->>v.mine_level)::int; nm := case when v.mine_level = 0 then 'construiu uma Mina de Ouro' else 'melhorou a Mina de Ouro para o nível ' || (v.mine_level + 1) end;
  elsif _kind = 'torre' then
    if v.tower_level >= 1 then raise exception 'Você já tem a Torre de Pesquisa.'; end if;
    cost := (c->>'tower_cost')::int; nm := 'construiu uma Torre de Pesquisa';
  elsif _kind = 'catapulta' then
    if v.catapult_level >= 1 then raise exception 'Você já tem a Catapulta de Lama.'; end if;
    cost := (c->>'catapult_cost')::int; nm := 'construiu uma Catapulta de Lama. Cuidado!';
  else raise exception 'Construção inválida.';
  end if;
  if me.coins < cost then raise exception 'Isso custa % moedas.', cost; end if;
  update characters set coins = coins - cost where id = me.id;
  if _kind = 'mina' then
    -- antes de melhorar, o que já foi produzido continua guardado: a data de coleta só começa a contar na construção
    update villages set mine_level = mine_level + 1, mine_collected_at = coalesce(mine_collected_at, t) where user_id = uid;
  elsif _kind = 'torre' then update villages set tower_level = 1, tower_collected_at = t where user_id = uid;
  else update villages set catapult_level = 1 where user_id = uid;
  end if;
  insert into event_log(user_id, kind, message) values (uid, 'vila', me.name || ' ' || nm || '.');
  return public.village_state(null);
end $$;

create or replace function public.village_collect() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); t date := public.game_today(); v villages; days int; ganho int := 0; n int := 0;
begin
  select * into v from villages where user_id = uid for update;
  if v.user_id is null then raise exception 'Construa algo na sua vila primeiro.'; end if;
  if v.mud > 0 then raise exception 'Sua vila está coberta de lama. Limpe antes de coletar.'; end if;
  if v.mine_level > 0 then
    days := least((c->>'collect_max_days')::int, greatest(0, t - coalesce(v.mine_collected_at, t)));
    ganho := days * (c->'mine_rates'->>(v.mine_level - 1))::int;
    update villages set mine_collected_at = t where user_id = uid;
  end if;
  if v.tower_level > 0 then
    n := least((c->>'tower_max')::int, greatest(0, (t - coalesce(v.tower_collected_at, t)) / (c->>'tower_days')::int));
    if n > 0 then update villages set tower_collected_at = t where user_id = uid; end if;
  end if;
  if ganho = 0 and n = 0 then raise exception 'Ainda não há nada para coletar.'; end if;
  update characters set coins = coins + ganho, hints = hints + n where user_id = uid;
  return jsonb_build_object('coins', ganho, 'hints', n);
end $$;

create or replace function public.village_clean() returns int
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); v villages; cost int; me characters;
begin
  select * into v from villages where user_id = uid for update;
  if v.user_id is null or v.mud = 0 then raise exception 'Sua vila já está limpa.'; end if;
  cost := v.mud * (public.cfg()->>'mud_clean_per_level')::int;
  select * into me from characters where user_id = uid for update;
  if me.coins < cost then raise exception 'A limpeza custa % moedas.', cost; end if;
  update characters set coins = coins - cost where id = me.id;
  update villages set mud = 0 where user_id = uid;
  return cost;
end $$;

create or replace function public.catapult_fire(_target uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); t date := public.game_today(); v villages; me characters; tg characters;
begin
  select * into v from villages where user_id = uid for update;
  if v.user_id is null or v.catapult_level = 0 then raise exception 'Construa a Catapulta de Lama primeiro.'; end if;
  if v.catapult_used_at is not null and v.catapult_used_at > t - (c->>'catapult_days')::int then
    raise exception 'A catapulta está recarregando. Pronta em %.', to_char(v.catapult_used_at + (c->>'catapult_days')::int, 'DD/MM');
  end if;
  if _target = uid then raise exception 'Mire em outro jogador.'; end if;
  select * into me from characters where user_id = uid;
  select * into tg from characters where user_id = _target for update;
  if tg.id is null then raise exception 'Jogador não encontrado.'; end if;
  update characters set pending_mud = least(6, pending_mud + (c->>'catapult_push')::int) where id = tg.id;
  insert into villages(user_id) values (_target) on conflict do nothing;
  update villages set mud = least(3, mud + 1) where user_id = _target;
  update villages set catapult_used_at = t where user_id = uid;
  insert into event_log(user_id, kind, message) values (uid, 'catapulta',
    me.name || ' atirou lama na vila de ' || tg.name || '! ' || tg.name || ' vai perder ' || (c->>'catapult_push') || ' casas na próxima andada.');
end $$;

-- 3) Times --------------------------------------------------------------
create or replace function public.choose_team(_team text) returns public.characters
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); me characters; price int := (public.cfg()->>'team_change_price')::int;
begin
  if not (c->'teams' ? _team) then raise exception 'Time inválido.'; end if;
  select * into me from characters where user_id = uid for update;
  if me.team = _team then raise exception 'Você já está nesse time.'; end if;
  if me.team is not null then
    if me.coins < price then raise exception 'Trocar de time custa % moedas.', price; end if;
    update characters set coins = coins - price where id = me.id;
  end if;
  update characters set team = _team where id = me.id returning * into me;
  insert into event_log(user_id, kind, message) values (uid, 'time', me.name || ' entrou na ' || (c->'teams'->_team->>'nome') || '.');
  return me;
end $$;

create or replace function public.ranking_teams(_kind text) returns table (team text, members int, steps int, days int)
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d date := public.game_today(); start date;
begin
  start := case _kind when 'semana' then date_trunc('week', d)::date when 'mes' then date_trunc('month', d)::date else '2000-01-01'::date end;
  return query
  select t.k::text,
    (select count(*)::int from characters ch where ch.team = t.k),
    coalesce((select sum(dm.base_steps + dm.roll + dm.bonus_steps + dm.skill_steps)::int from daily_moves dm join characters ch on ch.user_id = dm.user_id
              where ch.team = t.k and dm.move_date >= start), 0),
    coalesce((select count(*)::int from daily_moves dm join characters ch on ch.user_id = dm.user_id where ch.team = t.k and dm.move_date >= start), 0)
  from jsonb_object_keys(public.cfg()->'teams') t(k)
  order by 3 desc;
end $$;

create or replace function public.team_week_tick() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := cfg(); ws date := (date_trunc('week', game_today()) - interval '7 days')::date; w record;
begin
  if exists (select 1 from team_weeks where week_start = ws) then return; end if;
  if not exists (select 1 from daily_moves where move_date >= ws and move_date < ws + 7) then return; end if;
  select ch.team as k, sum(dm.base_steps + dm.roll + dm.bonus_steps + dm.skill_steps)::int as s into w
  from daily_moves dm join characters ch on ch.user_id = dm.user_id
  where ch.team is not null and dm.move_date >= ws and dm.move_date < ws + 7
  group by ch.team order by 2 desc limit 1;
  insert into team_weeks(week_start, winner, steps) values (ws, w.k, w.s);
  if w.k is not null then
    update characters set coins = coins + (c->>'team_week_bonus')::int where team = w.k;
    insert into event_log(kind, message) values ('time', (c->'teams'->w.k->>'nome') || ' venceu a semana com ' || w.s || ' casas andadas! Cada membro ganhou ' || (c->>'team_week_bonus') || ' moedas.');
  end if;
end $$;

-- 4) World Boss ---------------------------------------------------------
create or replace function public.boss_tick() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := cfg(); t date := game_today(); b world_bosses; pid int; nid int; players int; hp int;
begin
  for b in select * from world_bosses where status = 'ativo' and ends_on < t loop
    update world_bosses set status = 'fugiu' where id = b.id;
    insert into event_log(kind, message) values ('lendario', (select name from pokemon where id = b.pokemon_id) || ' fugiu! O grupo não conseguiu derrotá-lo a tempo.');
  end loop;
  if exists (select 1 from world_bosses where status = 'ativo') then return; end if;
  insert into boss_rolls(d) values (t) on conflict do nothing;
  if not found then return; end if;
  if random() * 100 >= (c->>'boss_spawn_pct')::int then return; end if;
  select (c->'boss_pool'->>(floor(random() * jsonb_array_length(c->'boss_pool')))::int)::int into pid;
  select id into nid from board_nodes where branch = 'tronco' and kind = 'normal' and dist between 20 and 150 order by random() limit 1;
  players := (select count(distinct user_id) from daily_moves where move_date > t - 7);
  hp := greatest((c->>'boss_hp_min')::int, players * (c->>'boss_hp_per_player')::int);
  insert into world_bosses(pokemon_id, node, hp, max_hp, started_on, ends_on) values (pid, nid, hp, hp, t, t + (c->>'boss_days')::int - 1);
  insert into event_log(kind, message) values ('lendario', 'Um lendário apareceu no mapa: ' || (select name from pokemon where id = pid) || '! Passe por ele para poder atacar. Se o grupo vencer, todos ganham XP extra.');
end $$;

create or replace function public.boss_state() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); t date := public.game_today(); b world_bosses;
begin
  select * into b from world_bosses where status = 'ativo' order by id desc limit 1;
  if b.id is null then
    select * into b from world_bosses order by id desc limit 1;
    return jsonb_build_object('active', false, 'last', case when b.id is not null then jsonb_build_object('status', b.status, 'name', (select name from pokemon where id = b.pokemon_id)) end,
      'buff_until', (select xp_buff_until from characters where user_id = uid));
  end if;
  return jsonb_build_object('active', true, 'id', b.id, 'pokemon_id', b.pokemon_id, 'name', (select name from pokemon where id = b.pokemon_id),
    'node', b.node, 'hp', b.hp, 'max_hp', b.max_hp, 'ends_on', b.ends_on,
    'contact', exists (select 1 from boss_contacts where boss_id = b.id and user_id = uid),
    'attacked_today', exists (select 1 from boss_attacks where boss_id = b.id and user_id = uid and d = t),
    'attackers', (select count(distinct user_id) from boss_attacks where boss_id = b.id),
    'buff_until', (select xp_buff_until from characters where user_id = uid));
end $$;

create or replace function public.boss_attack(_coins int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); t date := public.game_today(); b world_bosses; me characters; dmg int; bname text;
begin
  select * into b from world_bosses where status = 'ativo' order by id desc limit 1 for update;
  if b.id is null then raise exception 'Não há nenhum lendário no mapa agora.'; end if;
  if not exists (select 1 from boss_contacts where boss_id = b.id and user_id = uid) then raise exception 'Passe pela casa do lendário no mapa para poder atacar.'; end if;
  if exists (select 1 from boss_attacks where boss_id = b.id and user_id = uid and d = t) then raise exception 'Você já atacou hoje. Volte amanhã.'; end if;
  if _coins < (c->>'boss_min_attack')::int or _coins > (c->>'boss_max_attack')::int then
    raise exception 'O ataque deve usar de % a % moedas.', (c->>'boss_min_attack'), (c->>'boss_max_attack');
  end if;
  select * into me from characters where user_id = uid for update;
  if me.coins < _coins then raise exception 'Moedas insuficientes.'; end if;
  dmg := round(_coins * (1 + me.level * 0.02) * case when me.class::text = 'guerreiro' then 1.25 else 1 end)::int;
  update characters set coins = coins - _coins where id = me.id;
  insert into boss_attacks(boss_id, user_id, d, coins, damage) values (b.id, uid, t, _coins, dmg);
  update world_bosses set hp = greatest(0, hp - dmg) where id = b.id returning * into b;
  bname := (select name from pokemon where id = b.pokemon_id);
  if b.hp = 0 then
    update world_bosses set status = 'derrotado', defeated_at = now() where id = b.id;
    update characters set xp_buff_until = greatest(coalesce(xp_buff_until, t), t + (c->>'boss_buff_days')::int - 1);
    insert into event_log(user_id, kind, message) values (uid, 'lendario', me.name || ' deu o golpe final! ' || bname || ' foi derrotado e todos ganharam XP extra por ' || (c->>'boss_buff_days') || ' dias.');
  else
    insert into event_log(user_id, kind, message) values (uid, 'lendario', me.name || ' atacou ' || bname || ' e causou ' || dmg || ' de dano.');
  end if;
  return public.boss_state() || jsonb_build_object('damage', dmg);
end $$;

-- 5) Jornal do dia ------------------------------------------------------
create or replace function public.daily_report() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); y date := public.game_today() - 1;
begin
  perform public.settle();
  return jsonb_build_object('date', y, 'pesado', coalesce((cfg()->>'jornal_pesado')::boolean, true),
    'results', coalesce((select jsonb_agg(jsonb_build_object(
        'user_id', rr.user_id, 'name', ch.name, 'rank', rr.rank, 'attempts', rr.attempts, 'solved', rr.modes_solved,
        'first_try', (select count(*) from guess_sessions gs where gs.user_id = rr.user_id and gs.puzzle_date = y and gs.solved and gs.attempts = 1 and not gs.recovered))
      order by rr.rank) from round_results rr join characters ch on ch.user_id = rr.user_id where rr.d = y), '[]'::jsonb),
    'news', coalesce((select jsonb_agg(message order by id) from event_log
                      where kind in ('lendario','catapulta','bolao','time','pousada','castelo','temporada')
                        and (created_at at time zone coalesce(cfg()->>'timezone','America/Sao_Paulo'))::date = y), '[]'::jsonb));
end $$;

-- 6) Funções atualizadas: andar, fechar o dia e chegada ao Castelo ------
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
  if s.status = 'ativa' and rk = 1 then
    insert into villages(user_id) values (ch.user_id) on conflict do nothing;
    update villages set castles = castles + 1 where user_id = ch.user_id;
  end if;
  insert into event_log(user_id, kind, message) values (ch.user_id, 'castelo', ch.name || ' chegou ao Castelo da Liga em ' || rk || 'º lugar!');
  if s.status = 'ativa' and rk >= (c->>'season_arrivals')::int then
    update seasons set status = 'encerrada', ended_on = game_today() where id = s.id;
    insert into event_log(kind, message) values ('temporada', 'Temporada ' || s.id || ' encerrada! Amanhã começa uma nova.');
  end if;
  return 'Você chegou ao Castelo da Liga em ' || rk || 'º lugar!' || case when prize > 0 then ' Prêmio: ' || prize || ' moedas.' else '' end;
end $$;

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
  leader uuid; prop properties; toll int; bounty int := coalesce((public.cfg()->>'bounty_coins')::int, 60);
  boss world_bosses; mud int; passed int[];
begin
  perform public.settle();
  leader := public.leader_id();
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
  -- lama da catapulta de um rival
  mud := coalesce(me.pending_mud, 0);
  if mud > 0 and not _recovery then
    update characters set pending_mud = 0 where id = me.id;
    if public.is_shielded(me.id) then
      ev := ev || jsonb_build_object('t','lama','msg','Atiraram lama em você, mas a Bênção te protegeu.');
    else
      total := greatest(0, total - mud);
      ev := ev || jsonb_build_object('t','lama','msg','Lama da catapulta: você perdeu ' || mud || ' casas nesta andada.');
    end if;
  end if;
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

    -- encontro com o lendário (passando ou parando)
    select * into boss from world_bosses where status = 'ativo' order by id desc limit 1;
    if boss.id is not null then
      passed := (select path from characters where id = me.id)[path0 : coalesce(array_length((select path from characters where id = me.id),1),1)];
      if boss.node = any(passed) and not exists (select 1 from boss_contacts bc where bc.boss_id = boss.id and bc.user_id = uid) then
        insert into boss_contacts(boss_id, user_id) values (boss.id, uid);
        ev := ev || jsonb_build_object('t','lendario','msg','Você encontrou o lendário ' || (select name from pokemon where id = boss.pokemon_id) || '! Agora pode atacá-lo pelo painel.');
      end if;
    end if;

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
          if other.user_id = leader then
            extra_coins := extra_coins + bounty;
            ev := ev || jsonb_build_object('t','procurado','msg','Recompensa: você acertou o procurado e ganhou ' || bounty || ' moedas.');
          end if;
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
        if other.user_id = leader then
          extra_coins := extra_coins + bounty;
          ev := ev || jsonb_build_object('t','procurado','msg','Recompensa: você venceu o procurado e ganhou ' || bounty || ' moedas.');
        end if;
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

    -- 4) pedágio da pousada de outro jogador
    select * into me from characters where id = me.id;
    select * into prop from properties where node = me.node and owner <> uid for update;
    if prop.node is not null then
      toll := greatest((c->>'property_min_toll')::int, ceil(prop.price * (c->>'property_toll_pct')::numeric / 100)::int);
      toll := least(toll, greatest(0, me.coins + extra_coins + base * (c->>'coins_per_step')::int));
      if toll > 0 then
        extra_coins := extra_coins - toll;
        update characters set coins = coins + toll where user_id = prop.owner;
        update properties set tolls_earned = tolls_earned + toll where node = prop.node;
        ev := ev || jsonb_build_object('t','pousada','msg','Pedágio na pousada de ' || (select name from characters where user_id = prop.owner) || ': -' || toll || ' moedas.');
        insert into event_log(user_id, kind, message) values (uid, 'pousada', me.name || ' pagou ' || toll || ' moedas de pedágio na pousada de ' || (select name from characters where user_id = prop.owner) || '.');
      end if;
    end if;
    if sal > 0 then ev := ev || jsonb_build_object('t','pagamento','msg','Dia de pagamento: +' || sal || ' moedas de salário.'); end if;
    msg := public.check_arrival(me.id);
    if msg is not null then ev := ev || jsonb_build_object('t','castelo','msg', msg); end if;
  end if;

  xp_gain := base * (c->>'xp_per_step')::int + (c->>'xp_daily_bonus')::int + extra_xp;
  if (select xp_buff_until from characters where id = me.id) >= today then
    xp_gain := round(xp_gain * coalesce((c->>'boss_xp_mult')::numeric, 1.5))::int;
    ev := ev || jsonb_build_object('t','buff','msg','Bênção do lendário derrotado: XP aumentado.');
  end if;
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
  select * into s from seasons order by id desc limit 1;
  if s.status = 'encerrada' and s.ended_on < d then perform public.start_new_season(); end if;
end $$;

-- 7) Segurança ----------------------------------------------------------
alter table public.villages      enable row level security;
alter table public.world_bosses  enable row level security;
alter table public.boss_contacts enable row level security;
alter table public.boss_attacks  enable row level security;
alter table public.boss_rolls    enable row level security;
alter table public.team_weeks    enable row level security;
revoke all on public.villages, public.world_bosses, public.boss_contacts, public.boss_attacks, public.boss_rolls, public.team_weeks from anon, authenticated;
grant select on public.villages, public.world_bosses, public.team_weeks to authenticated;
drop policy if exists p_villages on public.villages;       create policy p_villages on public.villages for select to authenticated using (true);
drop policy if exists p_bosses on public.world_bosses;     create policy p_bosses on public.world_bosses for select to authenticated using (true);
drop policy if exists p_teamweeks on public.team_weeks;    create policy p_teamweeks on public.team_weeks for select to authenticated using (true);
do $$ begin
  begin alter publication supabase_realtime add table public.world_bosses; exception when duplicate_object then null; end;
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
  public.buy_item(text), public.equip_item(text, text), public.set_outfit_colors(text, text), public.place_trap(int),
  public.today_round(), public.ranking_period(text),
  public.market_refresh(), public.market_create(text, text, int, int, text, text, int), public.market_cancel(uuid), public.market_buy(uuid),
  public.create_duel(uuid, text, text, int), public.accept_duel(uuid), public.decline_duel(uuid), public.duel_state(uuid),
  public.duel_guess(uuid, int), public.duel_list(), public.place_bet(uuid, int), public.send_reaction(uuid, text), public.social_overview(),
  public.buy_property(int), public.sell_property(int),
  public.village_state(uuid), public.village_build(text), public.village_collect(), public.village_clean(), public.catapult_fire(uuid),
  public.choose_team(text), public.ranking_teams(text), public.boss_state(), public.boss_attack(int), public.daily_report(),
  public.admin_players(), public.admin_set_status(uuid, text, text), public.admin_adjust(uuid, int, int, int, text),
  public.admin_reset_day(uuid, date, text), public.admin_set_config(jsonb, text), public.admin_undo_move(uuid, text),
  public.admin_new_season(text), public.admin_save_media(int, text, jsonb, text), public.admin_media_status()
to authenticated;
