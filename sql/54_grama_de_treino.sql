-- =====================================================================
-- POKEGAMES — Grama de Treino (pedido do dono em 29/10/2026).
--
-- Área fora do tabuleiro para treinar os Pokémon. O jogador escolhe um
-- Pokémon seu e ele luta sozinho (automático) contra um Pokémon selvagem
-- de nível parecido (de 3 abaixo até o mesmo nível). Vencendo, ganha a experiência
-- da 1ª geração contra selvagem (exp-base × nível ÷ 7, sem o bônus de
-- treinador): com o limite diário, o treino é lento e evoluir é difícil. Perder não custa nada.
-- Limite: um "relógio de treino" de 60 minutos por dia; cada luta gasta 3
-- (20 lutas por dia). Zera à meia-noite (horário do jogo).
-- O XP do treino não gasta o limite de 5 batalhas por dia e não vai para a
-- Arena nem para o Jornal. Números em game_config.config.treino (treino_cfg).
-- Depende do 18, 28, 43 e 44. Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

create or replace function public.treino_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "minutos_dia": 60, "minutos_luta": 3, "xp_mult": 1, "nivel_menos": 3, "nivel_mais": 0, "turnos": 30, "lutas_guardadas": 10}'::jsonb
         || coalesce(public.cfg()->'treino', '{}'::jsonb)
$$;

-- tempo usado por dia
create table if not exists public.treino_dias (
  user_id  uuid not null references auth.users(id) on delete cascade,
  dia      date not null,
  minutos  int  not null default 0,
  lutas    int  not null default 0,
  vitorias int  not null default 0,
  xp       int  not null default 0,
  primary key (user_id, dia)
);
alter table public.treino_dias enable row level security;
drop policy if exists treino_dias_read on public.treino_dias;
create policy treino_dias_read on public.treino_dias for select to authenticated using (user_id = auth.uid());

-- últimas lutas de cada um (só as mais recentes ficam guardadas)
create table if not exists public.treino_lutas (
  id         bigserial primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  mon_id     uuid,
  species    int  not null,
  wild       int  not null,
  wild_level int  not null,
  won        boolean not null,
  xp         int  not null default 0,
  level_from int  not null,
  level_to   int  not null,
  log        jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists treino_lutas_user on public.treino_lutas (user_id, id desc);
alter table public.treino_lutas enable row level security;
drop policy if exists treino_lutas_read on public.treino_lutas;
create policy treino_lutas_read on public.treino_lutas for select to authenticated using (user_id = auth.uid());
grant select on public.treino_dias, public.treino_lutas to authenticated;

-- a batalha do treino tem o jogador dos dois lados (o selvagem joga sozinho)
alter table public.battles drop constraint if exists battles_check;
alter table public.battles add constraint battles_check check (p1 <> p2 or mode in ('npc', 'rocket', 'treino'));

-- estado do treino de hoje (para o site)
create or replace function public.treino_estado() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.treino_cfg(); d treino_dias;
begin
  if uid is null then raise exception 'Entre na sua conta.'; end if;
  select * into d from treino_dias where user_id = uid and dia = public.game_today();
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'minutos_dia', (c->>'minutos_dia')::int, 'minutos_luta', (c->>'minutos_luta')::int,
    'nivel_menos', (c->>'nivel_menos')::int, 'nivel_mais', (c->>'nivel_mais')::int,
    'minutos', coalesce(d.minutos, 0), 'lutas', coalesce(d.lutas, 0), 'vitorias', coalesce(d.vitorias, 0), 'xp', coalesce(d.xp, 0),
    'ultimas', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'mon_id', l.mon_id, 'species', l.species, 'wild', l.wild, 'wild_level', l.wild_level,
        'won', l.won, 'xp', l.xp, 'level_from', l.level_from, 'level_to', l.level_to, 'created_at', l.created_at) order by l.id desc)
      from treino_lutas l where l.user_id = uid), '[]'::jsonb));
end $$;

-- uma luta de treino
create or replace function public.treino_lutar(_mon uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.treino_cfg(); me characters; m monsters; d treino_dias;
  per int := (c->>'minutos_luta')::int; lvl int; sp int; wild jsonb; s0 jsonb; s1 jsonb; b battles; it int := 0; side int; p jsonb;
  won boolean; ganho int := 0; pct0 numeric; pct1 numeric; lv2 int; lid bigint;
begin
  if not coalesce((c->>'on')::boolean, true) then raise exception 'A Grama de Treino está fechada no momento.'; end if;
  select * into me from characters where user_id = uid for update;   -- uma luta por vez
  select * into m from monsters where id = _mon and user_id = uid;
  if m.id is null then raise exception 'Escolha um Pokémon seu para treinar.'; end if;
  if m.level >= 100 then raise exception 'Esse Pokémon já está no nível máximo.'; end if;
  insert into treino_dias(user_id, dia) values (uid, public.game_today()) on conflict do nothing;
  select * into d from treino_dias where user_id = uid and dia = public.game_today();
  if d.minutos + per > (c->>'minutos_dia')::int then
    raise exception 'Seu tempo de treino de hoje acabou (% minutos). Volte amanhã!', c->>'minutos_dia';
  end if;

  -- o selvagem: nível perto do seu Pokémon, espécie que já existiria nesse nível (sem lendários)
  lvl := greatest(1, least(100, m.level - (c->>'nivel_menos')::int + floor(random() * ((c->>'nivel_menos')::int + (c->>'nivel_mais')::int + 1))::int));
  select p.id into sp from pokemon p
   where p.catch_rate > 3 and public.gen_ok(p.id)
     and (p.id = p.base_form or exists (select 1 from pk_evolutions e where e.to_id = p.id and ((e.method = 'nivel' and e.level <= lvl) or (e.method <> 'nivel' and lvl >= 30))))
   order by random() limit 1;
  wild := public.npc_mon(sp, lvl);
  s0 := jsonb_build_object('user', uid, 'name', me.name, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(public.bt_mon(m.id)));
  s1 := jsonb_build_object('user', uid, 'name', 'Pokémon selvagem', 'npc', true, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(wild));

  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (uid, uid, 'treino', 1, 'ativa', 1, 'normal', now(), jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', 'Um ' || (wild->>'name') || ' selvagem (nível ' || lvl || ') apareceu na grama!'),
            jsonb_build_object('txt', me.name || ' mandou ' || (s0->'mons'->0->>'name') || '!')))))
  returning * into b;
  loop
    select * into b from battles where id = b.id;
    exit when b.status <> 'ativa' or b.turn > (c->>'turnos')::int;
    it := it + 1; exit when it > 200;
    for side in 0 .. 1 loop
      if b.phase = 'troca' then
        if coalesce((b.state->'sides'->side->>'need_switch')::boolean, false) then
          insert into battle_actions(battle_id, turn, side, user_id, kind, value)
          values (b.id, b.turn, side, uid, 'switch', public.war_switch(b.state, side, true));
        end if;
      else
        p := public.war_pick(b.state, side, 'forte');
        insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, side, uid, p->>'kind', (p->>'value')::int);
      end if;
    end loop;
    perform public.bt_resolve(b.id);
  end loop;
  select * into b from battles where id = b.id;
  if b.status = 'ativa' then   -- muitos turnos: vence quem tem mais vida (em %)
    pct0 := (b.state->'sides'->0->'mons'->0->>'hp')::numeric / greatest(1, (b.state->'sides'->0->'mons'->0->>'maxhp')::int);
    pct1 := (b.state->'sides'->1->'mons'->0->>'hp')::numeric / greatest(1, (b.state->'sides'->1->'mons'->0->>'maxhp')::int);
    won := pct0 > pct1;
    perform public.bt_finish(b.id, case when won then uid end, 'limite');
    select * into b from battles where id = b.id;
    b.log := b.log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt',
      'A luta demorou demais. ' || case when won then 'O selvagem cansou e fugiu: vitória sua!' else 'Seu Pokémon cansou e o selvagem fugiu.' end))));
  else
    won := (b.state->'sides'->0->'mons'->0->>'hp')::int > 0 and (b.state->'sides'->1->'mons'->0->>'hp')::int <= 0;
  end if;
  if won then
    ganho := greatest(1, floor((wild->>'bexp')::int * lvl / 7.0 * (c->>'xp_mult')::numeric)::int);
    perform public.pk_give_xp(m.id, ganho, 'treino');
  end if;
  select level into lv2 from monsters where id = m.id;
  update treino_dias set minutos = minutos + per, lutas = lutas + 1, vitorias = vitorias + won::int, xp = treino_dias.xp + ganho
   where user_id = uid and dia = d.dia;
  insert into treino_lutas(user_id, mon_id, species, wild, wild_level, won, xp, level_from, level_to, log)
  values (uid, m.id, m.species_id, sp, lvl, won, ganho, m.level, lv2, b.log) returning id into lid;
  delete from treino_lutas where user_id = uid and id not in (select id from treino_lutas where user_id = uid order by id desc limit (c->>'lutas_guardadas')::int);
  delete from battles where id = b.id;
  return jsonb_build_object('id', lid, 'won', won, 'xp', ganho, 'wild', sp, 'wild_level', lvl, 'level_from', m.level, 'level_to', lv2, 'log', b.log,
    'minutos', d.minutos + per, 'minutos_dia', (c->>'minutos_dia')::int,
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.id) from mon_events e where e.user_id = uid and not e.seen), '[]'::jsonb));
end $$;

-- fim da batalha (versão do 44 + modo treino sem XP de batalha)
create or replace function public.bt_finish(_id uuid, _winner uuid, _reason text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b battles; c jsonb := public.pk_cfg(); k text; v int; owner uuid; limit_n int := (c->'xp'->>'battles_per_day')::int; wn text; ln text;
begin
  select * into b from battles where id = _id for update;
  if b.status <> 'ativa' then return; end if;
  if b.mode = 'treino' then   -- Grama de Treino (arquivo 54): o XP é do treino, não das batalhas
    update battles set status = 'encerrada', winner = _winner, end_reason = _reason, ended_at = now(), deadline = null, rewarded = true where id = b.id;
    return;
  end if;
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

-- Arena (versão do 44 + o treino não aparece)
create or replace function public.bt_arena_trigger() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  if new.mode in ('guerra', 'npc', 'rocket', 'treino') then return null; end if;
  perform public.arena_sync(new.id);
  return null;
end $$;

-- ---------- permissões ----------
revoke execute on function public.treino_cfg() from public, anon, authenticated;
revoke execute on function public.treino_estado(), public.treino_lutar(uuid) from public, anon;
grant execute on function public.treino_estado(), public.treino_lutar(uuid) to authenticated;
