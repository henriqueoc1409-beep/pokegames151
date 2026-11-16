-- Arquivo 122 (pedido do dono em 17/11/2026, aprovado pelo grupo): Equipe Rocket em ondas e Giovanni.
-- Luta: cada participante cede 1 Pokémon (1 tentativa por invasão) e enfrenta uma fila sem fim de Pokémon da Rocket até o seu desmaiar
-- ou desistir. 1ª onda no nível do cedido − 5 (mínimo 5); cada onda seguinte +3. A barra conta o dano; o ranking conta as ondas
-- (desempate: menos turnos, depois mais dano).
-- Barra: média de dano por participante nas últimas 3 invasões (250 enquanto não houver 3) × jogadores ativos × multiplicador
-- (começa 1,0; +0,05 por vitória do grupo, −0,1 por derrota; entre 0,8 e 1,2).
-- Prêmios: vitória = 100 moedas para cada um, +50/+30/+20 para os 3 com mais ondas; Superação +20 para quem bate o próprio recorde da
-- temporada (a 1ª participação da temporada só marca o recorde); XP no Pokémon cedido para todos, mesmo na derrota.
-- Roubo (invasão comum): só se o grupo acabar abaixo de 80% da barra; o sorteado perde o Pokémon cedido, que vai para uma base de resgate
-- da Rocket por 7 dias (aparece nas bases da guerra com o nome do dono). Quem tem Quartel ataca; vencer devolve o Pokémon ao dono e dá
-- +50 moedas a quem resgatou. Sem resgate em 7 dias, o Pokémon se perde.
-- Giovanni: a cada 5 vitórias do grupo. Time próprio (Rhyhorn, Dugtrio, Nidoqueen, Nidoking, Persian, Rhydon), barra = média histórica ×
-- ativos × fator do Giovanni (começa 1,1; +0,05 por vitória sobre ele, −0,1 por derrota; entre 0,9 e 1,3), prêmios em dobro. Em qualquer
-- derrota rouba 1 Pokémon cedido e fica com ele. Na revanche, o roubado aparece numa das ondas; enquanto ele tiver um roubado, o fator cai
-- 0,1 e o dano do dono vale 1,25× na barra. Vitória devolve todos com +50 moedas cada; 2 revanches perdidas seguidas = o mais antigo se
-- perde. Depois de uma derrota, Giovanni volta na invasão seguinte a uma vitória do grupo. Ele não mexe no multiplicador comum.
-- Números em `rocket` (Ajustes do jogo → Equipe Rocket).

create or replace function public.rocket_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"days":[0,2,5],"hour":8,"hours":24,"reward":100,"max_turns":300,"level_bonus":2,
           "onda_menos":5,"onda_mais":3,"onda_min":5,"media_padrao":250,"media_invasoes":3,
           "mult_inicio":1.0,"mult_vitoria":0.05,"mult_derrota":0.1,"mult_min":0.8,"mult_max":1.2,
           "top_bonus":[50,30,20],"superacao":20,"xp_por_nivel":10,
           "roubo_pct":80,"resgate_dias":7,"resgate_bonus":50,
           "giovanni_cada":5,"giovanni_fator":1.1,"giovanni_vitoria":0.05,"giovanni_derrota":0.1,"giovanni_min":0.9,"giovanni_max":1.3,
           "giovanni_alivio":0.1,"giovanni_dono_peso":1.25,"giovanni_premio_mult":2,"giovanni_devolve_bonus":50,"giovanni_chances":2}'::jsonb
         || coalesce(public.cfg()->'rocket', '{}'::jsonb)
$$;
-- quem já salvou a Rocket em Ajustes tinha 30 turnos: a luta em ondas precisa de mais
update public.game_config set config = jsonb_set(config, '{rocket,max_turns}', '300'::jsonb)
 where config->'rocket' ? 'max_turns' and (config->'rocket'->>'max_turns')::int < 300;

-- estado da Rocket entre as invasões (multiplicador, vitórias, Giovanni)
create table if not exists public.rocket_meta (
  id int primary key default 1 check (id = 1),
  mult numeric not null default 1.0,
  vitorias int not null default 0,
  giovanni_pendente boolean not null default false,       -- a próxima invasão é do Giovanni
  giovanni_apos_vitoria boolean not null default false,   -- perdeu para o Giovanni: ele volta depois da próxima vitória do grupo
  giovanni_fator numeric not null default 1.1
);
alter table public.rocket_meta enable row level security;
insert into public.rocket_meta(id, mult, giovanni_fator) values (1, 1.0, 1.1) on conflict (id) do nothing;

alter table public.rocket_raids add column if not exists giovanni boolean not null default false;
alter table public.rocket_raids add column if not exists mult numeric;          -- multiplicador (ou fator do Giovanni) usado na barra
alter table public.rocket_raids add column if not exists media numeric;         -- média de dano usada na barra
alter table public.rocket_raids add column if not exists dano_total int not null default 0;
alter table public.rocket_entries add column if not exists turnos int not null default 0;
alter table public.rocket_entries add column if not exists peso numeric not null default 1;
alter table public.rocket_entries add column if not exists xp int not null default 0;
alter table public.rocket_entries add column if not exists bonus int not null default 0;
alter table public.rocket_entries add column if not exists superou boolean not null default false;

-- recorde de ondas de cada um na temporada
create table if not exists public.rocket_recordes (
  user_id uuid not null references auth.users(id) on delete cascade,
  season_id int not null,
  ondas int not null default 0,
  primary key (user_id, season_id)
);
alter table public.rocket_recordes enable row level security;
drop policy if exists rocket_recordes_ler on public.rocket_recordes;
create policy rocket_recordes_ler on public.rocket_recordes for select to authenticated using (true);
grant select on public.rocket_recordes to authenticated;

-- Pokémon que o Giovanni levou (sem leitura: o site recebe pelo rocket_current)
create table if not exists public.rocket_roubados (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  nome text not null, mon_nome text not null, species int not null, level int not null,
  snap jsonb not null, raid_id bigint,
  revanches int not null default 0,
  status text not null default 'preso' check (status in ('preso', 'devolvido', 'perdido')),
  created_at timestamptz not null default now(), resolved_at timestamptz
);
alter table public.rocket_roubados enable row level security;

-- base de resgate guarda o Pokémon inteiro
alter table public.rocket_bases add column if not exists mon_snap jsonb;
alter table public.rocket_bases add column if not exists mon_info jsonb;

create or replace function public.rocket_temporada() returns int
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((select max(id) from seasons), 0)
$$;

-- tira o Pokémon do dono e devolve a foto completa dele
create or replace function public.rocket_tira_mon(_mon uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare m monsters; snap jsonb;
begin
  select * into m from monsters where id = _mon for update;
  if m.id is null then return null; end if;
  snap := to_jsonb(m);
  delete from monsters where id = _mon;
  update characters set mascot = null where user_id = m.user_id and (mascot->>'id')::uuid = _mon;
  return snap;
end $$;

-- devolve o Pokémon ao dono (fora da equipe, com a vida do treino cheia)
create or replace function public.rocket_devolve_mon(_snap jsonb, _dono uuid) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare m monsters;
begin
  if _snap is null then return null; end if;
  m := jsonb_populate_record(null::monsters, _snap || jsonb_build_object('user_id', _dono, 'team_slot', null));
  if exists (select 1 from monsters where id = m.id) then return m.id; end if;
  insert into monsters select m.*;
  update monsters set tr_hp = 100, tr_hurt_at = null where id = m.id;
  insert into pokedex_entries(user_id, species_id, caught_at) values (_dono, m.species_id, now()) on conflict do nothing;
  return m.id;
end $$;

-- média de dano por participante (_n últimas invasões; _n null = todas)
create or replace function public.rocket_media(_n int) returns numeric
language plpgsql stable security definer set search_path = public, extensions as $$
declare ids bigint[]; v numeric;
begin
  select array_agg(id) into ids from (
    select r.id from rocket_raids r where r.status <> 'ativa' and exists (select 1 from rocket_entries e where e.raid_id = r.id)
     order by r.id desc limit coalesce(_n, 1000000)) x;
  if ids is null or (_n is not null and cardinality(ids) < _n) then return null; end if;
  select avg(e.damage) into v from rocket_entries e where e.raid_id = any(ids);
  return v;
end $$;

-- lugar guardado do lado da Rocket: mantém a fila viva para a próxima onda
create or replace function public.rocket_lugar() returns jsonb
language sql immutable as $$
  select jsonb_build_object('id', gen_random_uuid(), 'name', 'Próxima onda', 'known', false, 'oculto', true, 'level', 0,
    'hp', 1, 'maxhp', 1, 'atk', 1, 'def', 1, 'spd', 1, 'spc', 1, 'bspd', 1, 'bexp', 0, 'moves', '[]'::jsonb, 'status', null, 'sleep', 0, 'conf', 0,
    'st', '{"atk":0,"def":0,"spd":0,"spc":0,"acc":0,"eva":0}'::jsonb, 'fl', '{}'::jsonb, 'outfit', '{}'::jsonb)
$$;

-- o Pokémon de uma onda
create or replace function public.rocket_onda_mon(_rk jsonb, _onda int, _giovanni boolean) returns jsonb
language plpgsql volatile security definer set search_path = public, extensions as $$
declare c jsonb := public.rocket_cfg(); lv int; sp int; w jsonb; time_g int[] := array[111, 51, 31, 34, 53, 112];
begin
  lv := least(100, greatest((c->>'onda_min')::int, (_rk->>'base')::int - (c->>'onda_menos')::int) + (_onda - 1) * (c->>'onda_mais')::int);
  if (_rk->>'roubo_onda')::int = _onda and (_rk->>'roubo_sp') is not null then
    sp := (_rk->>'roubo_sp')::int;
  elsif _giovanni then
    sp := time_g[1 + ((_onda - 1) % 6)];
  elsif lv < 25 then
    sp := (array[23, 109, 52, 41, 19, 88, 96])[1 + floor(random() * 7)::int];
  else
    sp := (array[24, 110, 53, 42, 20, 89, 97])[1 + floor(random() * 7)::int];
  end if;
  w := public.ia_mon(sp, lv);
  if (_rk->>'roubo_onda')::int = _onda and (_rk->>'roubo_nome') is not null then
    w := w || jsonb_build_object('name', (w->>'name') || ' de ' || (_rk->>'roubo_nome'));
  end if;
  return w;
end $$;

-- a onda caiu: entra a próxima (chamada pelo battle_act depois do turno)
create or replace function public.rocket_onda_nova(_bid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b battles; rk jsonb; n int; w jsonb; idx int; g boolean;
begin
  select * into b from battles where id = _bid for update;
  rk := b.state->'rk';
  if rk is null then   -- batalha antiga (antes do arquivo 122): troca como antes
    insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, b.p1, 'switch', public.war_switch(b.state, 1, true));
    return;
  end if;
  select coalesce(r.giovanni, false) into g from rocket_entries e join rocket_raids r on r.id = e.raid_id where e.battle_id = _bid;
  n := (rk->>'ondas')::int + 1;   -- ondas vencidas
  w := public.rocket_onda_mon(rk, n + 1, coalesce(g, false));
  idx := jsonb_array_length(b.state->'sides'->1->'mons');
  update battles set state = jsonb_set(jsonb_set(jsonb_set(state, '{rk,ondas}', to_jsonb(n)), '{rk,onda}', to_jsonb(n + 1)),
                                       array['sides', '1', 'mons'], (state->'sides'->1->'mons') || jsonb_build_array(w)),
         log = log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(
                 jsonb_build_object('txt', '🌊 Onda ' || n || ' vencida! Vem a onda ' || (n + 1) || ': ' || (w->>'name') || ' (nível ' || (w->>'level') || ').'))))
   where id = b.id;
  insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, b.p1, 'switch', idx);
end $$;

-- base de resgate com o Pokémon roubado (invasão comum)
create or replace function public.rocket_resgate_criar(_raid bigint, _e rocket_entries) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rocket_cfg(); snap jsonb; lv int; t jsonb; pool int[];
begin
  snap := public.rocket_tira_mon(_e.mon_id);
  if snap is null then return; end if;
  lv := greatest(5, (snap->>'level')::int);
  pool := case when lv < 25 then array[23, 109, 52, 41, 19, 88, 96] else array[24, 110, 53, 42, 20, 89, 97] end;
  select jsonb_agg(jsonb_build_array(s, lv)) into t from (select unnest(pool) s order by random() limit 3) x;
  insert into rocket_bases(nome, tipo, nivel, time, ativa, mon_id, dono, prazo, mon_snap, mon_info)
  values ('Esconderijo com o ' || _e.mon_name || ' de ' || _e.name, 'resgate', lv, t, true, _e.mon_id, _e.user_id,
          now() + make_interval(days => (c->>'resgate_dias')::int), snap,
          jsonb_build_object('mon', _e.mon_name, 'species', snap->'species_id', 'level', lv, 'dono_nome', _e.name));
end $$;

-- base de resgate vencida: o Pokémon se perde
create or replace function public.rocket_resgate_tick() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare rb rocket_bases;
begin
  for rb in update rocket_bases set ativa = false where tipo = 'resgate' and ativa and prazo is not null and prazo <= now() returning * loop
    insert into event_log(user_id, kind, message) values (rb.dono, 'rocket', '😢 Ninguém resgatou o ' || coalesce(rb.mon_info->>'mon', 'Pokémon') || ' de '
      || coalesce(rb.mon_info->>'dono_nome', '?') || ' a tempo. A Equipe Rocket sumiu com ele.');
  end loop;
end $$;

-- recorde e superação de quem terminou a luta
create or replace function public.rocket_recorde(_e rocket_entries, _giovanni boolean) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rocket_cfg(); s int := public.rocket_temporada(); rec int; v int := 0;
begin
  select ondas into rec from rocket_recordes where user_id = _e.user_id and season_id = s;
  if rec is null then
    insert into rocket_recordes(user_id, season_id, ondas) values (_e.user_id, s, _e.ondas) on conflict do nothing;
    return 0;
  end if;
  if _e.ondas > rec then
    update rocket_recordes set ondas = _e.ondas where user_id = _e.user_id and season_id = s;
    v := (c->>'superacao')::int * case when _giovanni then (c->>'giovanni_premio_mult')::int else 1 end;
    if v > 0 then
      perform public.ext_origem('Equipe Rocket: superação', 'guerra');
      update characters set coins = coins + v where user_id = _e.user_id;
      insert into event_log(user_id, kind, message) values (_e.user_id, 'rocket', '🌊 ' || _e.name || ' bateu o próprio recorde contra a Rocket: ' || _e.ondas || ' ondas! +' || v || ' moedas de Superação.');
    end if;
  end if;
  return v;
end $$;

create or replace function public.rocket_begin(_starts timestamptz, _hours int) returns public.rocket_raids
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rocket_cfg(); r rocket_raids; lvl int; n int; team jsonb; hp int; mt rocket_meta; g boolean; med numeric; f numeric;
begin
  insert into rocket_meta(id) values (1) on conflict do nothing;
  select * into mt from rocket_meta where id = 1 for update;
  g := mt.giovanni_pendente;
  select count(distinct a.user_id) into n from public.day_active(public.game_today()) a where exists (select 1 from monsters m where m.user_id = a.user_id);
  select round(avg(m.level))::int into lvl from monsters m where m.team_slot is not null and m.user_id in (select user_id from public.day_active(public.game_today()));
  lvl := greatest(5, least(100, coalesce(lvl, 10)));
  if g then
    med := coalesce(public.rocket_media(null), (c->>'media_padrao')::numeric);
    f := mt.giovanni_fator - case when exists (select 1 from rocket_roubados where status = 'preso') then (c->>'giovanni_alivio')::numeric else 0 end;
    f := greatest(0.1, f);
    select jsonb_agg(jsonb_build_object('species', p.id, 'name', p.name) order by o) into team
      from unnest(array[111, 51, 31, 34, 53, 112]) with ordinality u(s, o) join pokemon p on p.id = u.s;
  else
    med := coalesce(public.rocket_media((c->>'media_invasoes')::int), (c->>'media_padrao')::numeric);
    f := mt.mult;
    select jsonb_agg(jsonb_build_object('species', p.id, 'name', p.name) order by p.id) into team
      from pokemon p where p.id = any(case when lvl < 25 then array[23, 109, 52, 41, 19, 88, 96] else array[24, 110, 53, 42, 20, 89, 97] end);
  end if;
  hp := greatest(1, ceil(med * greatest(1, n) * f))::int;
  insert into rocket_raids(starts_at, ends_at, level, team, players, hp_total, hp_left, giovanni, mult, media)
  values (_starts, _starts + make_interval(hours => _hours), lvl, team, greatest(1, n), hp, hp, g, f, round(med, 1)) returning * into r;
  update rocket_meta set giovanni_pendente = false where id = 1;
  insert into event_log(kind, message) values ('rocket', case when g then
    '🕴️ GIOVANNI chegou com a Equipe Rocket! Ceda 1 Pokémon e vença o máximo de ondas para expulsá-lo em ' || _hours || ' horas. Os prêmios valem em dobro, mas se ele vencer, leva um Pokémon com ele!'
    else '🚀 A Equipe Rocket invadiu! Ceda 1 Pokémon e vença o máximo de ondas para expulsar a Rocket em ' || _hours || ' horas.' end);
  return r;
end $$;

create or replace function public.rocket_join(_mon uuid) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.rocket_cfg(); r rocket_raids; m monsters; ch characters; s0 jsonb; s1 jsonb; bid uuid; rk jsonb; w jsonb;
  rb rocket_roubados; peso numeric := 1;
begin
  perform public.rocket_tick();
  select * into r from rocket_raids where status = 'ativa' order by id desc limit 1 for update;
  if r.id is null then raise exception 'A Equipe Rocket não está invadindo agora.'; end if;
  if now() >= r.ends_at then raise exception 'A invasão já acabou.'; end if;
  if exists (select 1 from rocket_entries where raid_id = r.id and user_id = uid) then raise exception 'Você já cedeu um Pokémon nesta invasão.'; end if;
  select * into m from monsters where id = _mon and user_id = uid;
  if m.id is null then raise exception 'Escolha um Pokémon seu.'; end if;
  perform public.gin_trava(uid, array[_mon]);
  select * into ch from characters where user_id = uid;
  rk := jsonb_build_object('ondas', 0, 'onda', 1, 'base', m.level);
  if r.giovanni then
    -- revanche: um Pokémon que o Giovanni levou aparece numa das ondas (o do próprio jogador, se houver)
    select * into rb from rocket_roubados where status = 'preso' order by (user_id = uid) desc, random() limit 1;
    if rb.id is not null then
      rk := rk || jsonb_build_object('roubo_onda', 2 + floor(random() * 3)::int, 'roubo_sp', rb.species, 'roubo_nome', rb.nome);
    end if;
    if exists (select 1 from rocket_roubados where status = 'preso' and user_id = uid) then peso := (c->>'giovanni_dono_peso')::numeric; end if;
  end if;
  w := public.rocket_onda_mon(rk, 1, r.giovanni);
  s0 := jsonb_build_object('user', uid, 'name', ch.name, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(public.bt_mon(m.id)));
  s1 := jsonb_build_object('user', uid, 'name', case when r.giovanni then 'Giovanni' else 'Equipe Rocket' end, 'npc', true, 'active', 0, 'need_switch', false,
                           'mons', jsonb_build_array(w, public.rocket_lugar()));
  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (uid, uid, 'rocket', 1, 'ativa', 1, 'normal', now(), jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb, 'rk', rk),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', case when r.giovanni then 'Giovanni sorri: "Vamos ver até onde você aguenta."' else 'Prepare-se para encrenca! A Equipe Rocket chegou!' end),
            jsonb_build_object('txt', ch.name || ' mandou ' || (s0->'mons'->0->>'name') || '!'),
            jsonb_build_object('txt', 'Onda 1: ' || (w->>'name') || ' (nível ' || (w->>'level') || ')!')))))
  returning id into bid;
  insert into rocket_entries(raid_id, user_id, name, mon_id, mon_name, species, level, battle_id, peso)
  values (r.id, uid, ch.name, m.id, (select name from pokemon where id = m.species_id), m.species_id, m.level, bid, peso);
  return bid;
end $$;

create or replace function public.rocket_after(_bid uuid, _pre int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b battles; c jsonb := public.rocket_cfg(); e rocket_entries; r rocket_raids; d int; dp int; left_ int; vxp int; sup int;
begin
  select * into b from battles where id = _bid;
  select * into e from rocket_entries where battle_id = _bid for update;
  if e.user_id is null then return; end if;
  select * into r from rocket_raids where id = e.raid_id;
  d := greatest(0, public.rocket_dmg(b.state) - coalesce(_pre, 0));
  update rocket_entries set ondas = greatest(ondas, coalesce((b.state->'rk'->>'ondas')::int, 0)), turnos = b.turn where raid_id = e.raid_id and user_id = e.user_id;
  if d > 0 then
    dp := round(d * coalesce(e.peso, 1))::int;   -- revanche do Giovanni: o dano do dono do roubado vale mais na barra
    update rocket_entries set damage = damage + d where raid_id = e.raid_id and user_id = e.user_id;
    update rocket_raids set hp_left = greatest(0, hp_left - dp), dano_total = dano_total + dp where id = e.raid_id and status = 'ativa' returning hp_left into left_;
    if left_ is not null and left_ <= 0 then perform public.rocket_win(e.raid_id); end if;
  end if;
  if b.status = 'ativa' and b.turn > (c->>'max_turns')::int then
    update battles set log = log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt', 'A Equipe Rocket recuou: a luta já durou demais!'))))
     where id = b.id;
    perform public.bt_finish(b.id, null, 'limite');
    select * into b from battles where id = _bid;
  end if;
  if b.status <> 'ativa' and not e.done then
    select * into e from rocket_entries where battle_id = _bid;
    update rocket_entries set done = true where raid_id = e.raid_id and user_id = e.user_id;
    -- a fila da Rocket não acaba: quem ficou de pé é sempre a Rocket
    update battles set winner = null where id = b.id;
    -- XP de participação no Pokémon cedido (mesmo na derrota)
    if exists (select 1 from monsters where id = e.mon_id and user_id = e.user_id) then
      vxp := greatest(1, ceil(e.level * (c->>'xp_por_nivel')::numeric))::int;
      perform public.pk_give_xp(e.mon_id, vxp, 'rocket');
      update rocket_entries set xp = xp + vxp where raid_id = e.raid_id and user_id = e.user_id;
    end if;
    sup := public.rocket_recorde(e, coalesce(r.giovanni, false));
    if sup > 0 then update rocket_entries set bonus = bonus + sup, superou = true where raid_id = e.raid_id and user_id = e.user_id; end if;
  end if;
end $$;

create or replace function public.rocket_win(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rocket_cfg(); n int; r rocket_raids; k int; mx int; x record; i int := 0; v int; rb rocket_roubados; devolvidos text := '';
begin
  update rocket_raids set status = 'vitoria', hp_left = 0, resolved_at = now() where id = _id and status = 'ativa' returning * into r;
  if r.id is null then return; end if;
  k := case when r.giovanni then (c->>'giovanni_premio_mult')::int else 1 end;
  perform public.ext_origem('Equipe Rocket', 'guerra');
  update characters ch set coins = coins + (c->>'reward')::int * k from rocket_entries e where e.raid_id = _id and e.user_id = ch.user_id;
  update rocket_entries set bonus = bonus + (c->>'reward')::int * k where raid_id = _id;
  -- os 3 com mais ondas
  for x in select e.user_id, e.name, e.ondas from rocket_entries e where e.raid_id = _id and e.ondas > 0 order by e.ondas desc, e.turnos, e.damage desc limit 3 loop
    v := coalesce((c->'top_bonus'->>i)::int, 0) * k; i := i + 1;
    continue when v <= 0;
    perform public.ext_origem('Equipe Rocket: ranking', 'guerra');
    update characters set coins = coins + v where user_id = x.user_id;
    update rocket_entries set bonus = bonus + v where raid_id = _id and user_id = x.user_id;
  end loop;
  select count(*) into n from rocket_entries where raid_id = _id;
  insert into rocket_meta(id) values (1) on conflict do nothing;
  if r.giovanni then
    update rocket_meta set giovanni_fator = least((c->>'giovanni_max')::numeric, giovanni_fator + (c->>'giovanni_vitoria')::numeric), giovanni_apos_vitoria = false where id = 1;
    -- devolve todos os Pokémon que ele tinha levado
    for rb in select * from rocket_roubados where status = 'preso' order by id loop
      perform public.rocket_devolve_mon(rb.snap, rb.user_id);
      update rocket_roubados set status = 'devolvido', resolved_at = now() where id = rb.id;
      if (c->>'giovanni_devolve_bonus')::int > 0 then
        perform public.ext_origem('Equipe Rocket: Pokémon devolvido', 'guerra');
        update characters set coins = coins + (c->>'giovanni_devolve_bonus')::int where user_id = rb.user_id;
      end if;
      devolvidos := devolvidos || case when devolvidos = '' then '' else ', ' end || rb.mon_nome || ' de ' || rb.nome;
    end loop;
    insert into event_log(kind, message) values ('rocket', '🎉 GIOVANNI FOI DERROTADO! Os ' || n || ' treinadores que lutaram ganharam ' || (c->>'reward')::int * k || ' moedas cada (em dobro).'
      || case when devolvidos <> '' then ' Voltaram para casa: ' || devolvidos || ' (+' || (c->>'giovanni_devolve_bonus') || ' moedas para cada dono).' else '' end);
  else
    update rocket_meta set mult = least((c->>'mult_max')::numeric, mult + (c->>'mult_vitoria')::numeric), vitorias = vitorias + 1 where id = 1;
    update rocket_meta set giovanni_pendente = true, giovanni_apos_vitoria = false
     where id = 1 and (giovanni_apos_vitoria or (vitorias > 0 and vitorias % greatest(1, (c->>'giovanni_cada')::int) = 0));
    insert into event_log(kind, message) values ('rocket', '🎉 A Equipe Rocket foi expulsa! Os ' || n || ' treinadores que lutaram ganharam ' || (c->>'reward') || ' moedas cada.');
  end if;
end $$;

create or replace function public.rocket_lose(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rocket_cfg(); r rocket_raids; e rocket_entries; snap jsonb; rb rocket_roubados;
begin
  select * into r from rocket_raids where id = _id and status = 'ativa' for update;
  if r.id is null then return; end if;
  update rocket_raids set status = 'derrota', resolved_at = now() where id = _id;
  insert into rocket_meta(id) values (1) on conflict do nothing;
  select x.* into e from rocket_entries x join monsters mm on mm.id = x.mon_id and mm.user_id = x.user_id
   where x.raid_id = _id order by random() limit 1;
  if r.giovanni then
    update rocket_meta set giovanni_fator = greatest((c->>'giovanni_min')::numeric, giovanni_fator - (c->>'giovanni_derrota')::numeric), giovanni_apos_vitoria = true where id = 1;
    -- os que já estavam com ele perderam mais uma chance; com 2 revanches perdidas seguidas, o mais antigo se perde
    update rocket_roubados set revanches = revanches + 1 where status = 'preso' and raid_id <> _id;
    for rb in select * from rocket_roubados where status = 'preso' and revanches >= (c->>'giovanni_chances')::int order by id limit 1 loop
      update rocket_roubados set status = 'perdido', resolved_at = now() where id = rb.id;
      insert into event_log(user_id, kind, message) values (rb.user_id, 'rocket', '😢 Giovanni venceu de novo e sumiu com o ' || rb.mon_nome || ' de ' || rb.nome || ' para sempre.');
    end loop;
    if e.user_id is not null then
      snap := public.rocket_tira_mon(e.mon_id);
      if snap is not null then
        insert into rocket_roubados(user_id, nome, mon_nome, species, level, snap, raid_id) values (e.user_id, e.name, e.mon_name, (snap->>'species_id')::int, (snap->>'level')::int, snap, _id);
        update rocket_raids set stolen_user = e.user_id, stolen_name = e.name, stolen_mon = e.mon_name, stolen_species = (snap->>'species_id')::int, stolen_level = (snap->>'level')::int where id = _id;
        insert into event_log(user_id, kind, message) values (e.user_id, 'rocket', '🕴️ Giovanni venceu e levou o ' || e.mon_name || ' de ' || e.name || '! Vença o Giovanni na próxima vez para trazê-lo de volta.');
        return;
      end if;
    end if;
    insert into event_log(kind, message) values ('rocket', '🕴️ Giovanni venceu, mas foi embora sem levar nenhum Pokémon.');
    return;
  end if;
  update rocket_meta set mult = greatest((c->>'mult_min')::numeric, mult - (c->>'mult_derrota')::numeric) where id = 1;
  -- só rouba se o grupo ficou abaixo de 80% da barra
  if e.user_id is not null and r.dano_total < r.hp_total * (c->>'roubo_pct')::numeric / 100 then
    perform public.rocket_resgate_criar(_id, e);
    update rocket_raids set stolen_user = e.user_id, stolen_name = e.name, stolen_mon = e.mon_name, stolen_species = e.species, stolen_level = e.level where id = _id;
    insert into event_log(user_id, kind, message) values (e.user_id, 'rocket', '😱 A Equipe Rocket venceu e levou o ' || e.mon_name || ' de ' || e.name
      || ' para um esconderijo! Quem tem Quartel pode atacar o esconderijo nas bases da Rocket (Guerras) em até ' || (c->>'resgate_dias') || ' dias para resgatá-lo.');
  else
    insert into event_log(kind, message) values ('rocket', '🚀 A Equipe Rocket venceu, mas o grupo lutou bem e ela foi embora sem levar nenhum Pokémon.');
  end if;
end $$;

create or replace function public.rocket_current() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.rocket_cfg(); r rocket_raids; e rocket_entries; mt rocket_meta; rec int;
begin
  perform public.rocket_tick();
  select * into mt from rocket_meta where id = 1;
  select ondas into rec from rocket_recordes where user_id = uid and season_id = public.rocket_temporada();
  select * into r from rocket_raids where status = 'ativa' or resolved_at > now() - interval '3 days' order by id desc limit 1;
  if r.id is null then
    return jsonb_build_object('vazio', true, 'mult', coalesce(mt.mult, 1), 'recorde', rec,
      'proxima_giovanni', coalesce(mt.giovanni_pendente, false),
      'roubados', (select coalesce(jsonb_agg(jsonb_build_object('nome', x.nome, 'mon', x.mon_nome, 'species', x.species, 'level', x.level, 'meu', x.user_id = uid, 'revanches', x.revanches) order by x.id), '[]'::jsonb)
                     from rocket_roubados x where x.status = 'preso'));
  end if;
  select * into e from rocket_entries where raid_id = r.id and user_id = uid;
  return to_jsonb(r) || jsonb_build_object(
    'joined', (select count(*) from rocket_entries where raid_id = r.id),
    'mult_atual', coalesce(mt.mult, 1), 'recorde', rec,
    'vitorias_ate_giovanni', greatest(0, (c->>'giovanni_cada')::int - (coalesce(mt.vitorias, 0) % greatest(1, (c->>'giovanni_cada')::int))),
    'proxima_giovanni', coalesce(mt.giovanni_pendente, false) or coalesce(mt.giovanni_apos_vitoria, false),
    'roubados', (select coalesce(jsonb_agg(jsonb_build_object('nome', x.nome, 'mon', x.mon_nome, 'species', x.species, 'level', x.level, 'meu', x.user_id = uid, 'revanches', x.revanches) order by x.id), '[]'::jsonb)
                   from rocket_roubados x where x.status = 'preso'),
    'ranking', (select coalesce(jsonb_agg(jsonb_build_object('user_id', x.user_id, 'name', x.name, 'mon', x.mon_name, 'species', x.species, 'ondas', x.ondas, 'turnos', x.turnos,
                    'damage', x.damage, 'done', x.done, 'superou', x.superou) order by x.ondas desc, x.turnos, x.damage desc), '[]'::jsonb)
                  from rocket_entries x where x.raid_id = r.id),
    'me', case when e.user_id is null then null else jsonb_build_object('mon', e.mon_name, 'species', e.species, 'damage', e.damage, 'ondas', e.ondas, 'turnos', e.turnos,
                  'xp', e.xp, 'bonus', e.bonus, 'superou', e.superou, 'done', e.done, 'battle_id', e.battle_id) end);
end $$;

-- admin: a próxima invasão é do Giovanni
create or replace function public.admin_rocket_giovanni(_on boolean default true) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active();
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador.'; end if;
  insert into rocket_meta(id) values (1) on conflict do nothing;
  update rocket_meta set giovanni_pendente = coalesce(_on, true) where id = 1;
  insert into admin_audit_log(admin_id, action, target, after) values (uid, 'rocket_giovanni', '1', jsonb_build_object('on', coalesce(_on, true)));
end $$;


-- battle_act: versão do 113 com a mudança do arquivo 122
create or replace function public.battle_act(_id uuid, _turn int, _kind text, _value int, _item text default null) returns public.battles
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); b battles; side int; s jsonb; A jsonb; kind text := _kind; ok boolean; pre int; p jsonb; k int; item text;
  rc jsonb; custo int := 0; moedas int; lim int;
begin
  select * into b from battles where id = _id for update;
  if b.id is null or uid not in (b.p1, b.p2) then raise exception 'Batalha não encontrada.'; end if;
  if b.status <> 'ativa' then raise exception 'Essa batalha não está em andamento.'; end if;
  -- arquivo 113: a batalha do Ginásio que passou do prazo vira derrota
  if b.mode = 'treino' and b.state->'treino' ? 'multi' and coalesce((public.rpg_cfg()->'ginasios'->>'expira_min')::int, 30) > 0
     and b.started_at < now() - make_interval(mins => coalesce((public.rpg_cfg()->'ginasios'->>'expira_min')::int, 30)) then
    perform public.rpg_gin_expira(b.p1);
    select * into b from battles where id = _id;
    return b;
  end if;
  side := case when uid = b.p1 then 0 else 1 end;
  if _kind = 'forfeit' then
    -- arquivo 97: fugir de uma luta da Aventura custa moedas (base + um tanto por ataque já feito)
    if b.mode = 'treino' and b.state->'treino'->>'rpg' is not null then
      rc := public.rpg_cfg();
      custo := greatest(0, coalesce((rc->>'fuga_base')::int, 0) + coalesce((rc->>'fuga_por_ataque')::int, 0) * coalesce((b.state->'treino'->>'ataques')::int, 0));
      if custo > 0 then
        select coins into moedas from characters where user_id = uid for update;
        if coalesce(moedas, 0) < custo then raise exception 'Fugir agora custa % moedas e você tem %. Continue lutando!', custo, coalesce(moedas, 0); end if;
        update characters set coins = coins - custo where user_id = uid;
        update battles set state = jsonb_set(state, '{treino,fuga_paga}', to_jsonb(custo)) where id = b.id;
      end if;
    end if;
    update battles set log = log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt', case when b.mode = 'treino' then case when custo > 0 then 'Você pagou ' || custo || ' moedas e fugiu da luta.' else case when b.state->'treino' ? 'multi' then 'Você desistiu do Ginásio.' else 'Você fugiu da luta.' end end else (b.state->'sides'->side->>'name') || ' desistiu da batalha.' end))))
     where id = b.id;
    perform public.bt_finish(b.id, case when side = 0 then b.p2 else b.p1 end, 'desistencia');
    if b.mode = 'rocket' then perform public.rocket_after(b.id, public.rocket_dmg(b.state)); end if;
    if b.mode = 'treino' then perform public.treino_after(b.id); perform public.rpg_after(b.id); end if;
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
  elsif _kind = 'item' then
    perform public.bt_item_check(s, side, uid, _item, _value);
    item := _item;
  else raise exception 'Ação inválida.'; end if;
  insert into battle_actions(battle_id, turn, side, user_id, kind, value, item) values (b.id, b.turn, side, uid, kind, _value, item);
  -- Equipe Rocket (arquivo 44): o servidor joga pelo lado da Rocket na hora e conta o dano na barra coletiva
  if b.mode = 'rocket' then
    pre := public.rocket_dmg(b.state);
    p := public.ia_pick(b.state, 1, 'lider', b.turn);   -- arquivo 113: escolha nova
    update battles set state = public.ia_memo(state, 1, p, b.turn) where id = b.id;
    insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, uid, p->>'kind', (p->>'value')::int);
    perform public.bt_resolve(b.id);
    for k in 1 .. 3 loop
      select * into b from battles where id = _id;
      exit when b.status <> 'ativa' or b.phase <> 'troca' or not coalesce((b.state->'sides'->1->>'need_switch')::boolean, false);
      perform public.rocket_onda_nova(b.id);   -- arquivo 122: a próxima onda entra
      perform public.bt_resolve(b.id);
    end loop;
    perform public.rocket_after(_id, pre);
    select * into b from battles where id = _id;
    return b;
  end if;
  -- arquivo 113: Ginásio em uma batalha só. O Líder escolhe pela regra nova; quando o Pokémon dele cai, entra o próximo da ordem
  if b.mode = 'treino' and b.state->'treino' ? 'multi' then
    if b.phase = 'troca' then
      if coalesce((b.state->'sides'->1->>'need_switch')::boolean, false) and not exists (select 1 from battle_actions ba where ba.battle_id = b.id and ba.turn = b.turn and ba.side = 1) then
        k := public.war_switch(b.state, 1, false);
        perform public.rpg_gin_revela(b.id, k);
        insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, uid, 'switch', k);
      end if;
    else
      perform public.rpg_gin_par(b.id);
      select * into b from battles where id = _id;
      p := public.ia_pick(b.state, 1, 'lider', b.turn);
      update battles set state = public.ia_memo(state, 1, p, b.turn) where id = b.id;
      insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, uid, p->>'kind', (p->>'value')::int);
    end if;
    perform public.bt_resolve(b.id);
    perform public.rpg_gin_depois(b.id);
    select * into b from battles where id = _id;
    if b.status <> 'ativa' then perform public.treino_after(_id); perform public.rpg_after(_id); select * into b from battles where id = _id; end if;
    return b;
  end if;
  -- Grama de Treino (arquivo 56): o selvagem joga sozinho na hora; no fim, XP e vida pelo treino_after
  if b.mode = 'treino' then
    if kind = 'move' and b.state->'treino'->>'rpg' is not null then   -- arquivo 97: conta os ataques (a fuga fica mais cara)
      update battles set state = jsonb_set(state, '{treino,ataques}', to_jsonb(coalesce((state->'treino'->>'ataques')::int, 0) + 1)) where id = b.id;
    end if;
    if b.state->'treino' ? 'elite' then p := public.war_pick(b.state, 1, 'forte');   -- a Liga do Planalto continua como era
    else
      p := public.ia_pick(b.state, 1, 'selvagem', b.turn);   -- arquivo 113: selvagens, Chefe e Expedições
      update battles set state = public.ia_memo(state, 1, p, b.turn) where id = b.id;
    end if;
    insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, uid, p->>'kind', (p->>'value')::int);
    perform public.bt_resolve(b.id);
    select * into b from battles where id = _id;
    lim := case when b.state->'treino' ? 'chefe' then coalesce((public.rpg_cfg()->'chefe'->>'turnos')::int, 12) else (public.treino_cfg()->>'turnos')::int end;
    if b.status = 'ativa' and b.turn > lim then
      update battles set log = log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt',
        case when b.state->'treino' ? 'chefe' then 'O chefe rugiu e jogou você para longe! Fim da luta.' else 'A luta demorou demais e o selvagem fugiu para a grama.' end))))
       where id = b.id;
      perform public.bt_finish(b.id, null, 'limite');
    end if;
    select * into b from battles where id = _id;
    if b.status <> 'ativa' then perform public.treino_after(_id); perform public.rpg_after(_id); select * into b from battles where id = _id; end if;
    return b;
  end if;
  if side = 0 then update battles set ready1 = true where id = b.id returning * into b;
  else update battles set ready2 = true where id = b.id returning * into b; end if;
  if b.ready1 and b.ready2 then perform public.bt_resolve(b.id); end if;
  select * into b from battles where id = _id;
  return b;
end $$;


-- rocket_tick: versão do 44 com a mudança do arquivo 122
create or replace function public.rocket_tick() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rocket_cfg(); tz text := coalesce(public.cfg()->>'timezone', 'America/Sao_Paulo'); r rocket_raids;
  loc timestamp := now() at time zone tz; st timestamptz;
begin
  perform public.rocket_resgate_tick();   -- arquivo 122: esconderijos vencidos
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


-- rocket_bases_lista: versão do 115 com a mudança do arquivo 122
create or replace function public.rocket_bases_lista() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.rocket_bases_cfg(); feitos int;
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  perform public.rocket_resgate_tick();   -- arquivo 122
  select count(*) into feitos from rocket_base_ataques where user_id = uid and dia = public.game_today();
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'ataques_dia', (c->>'ataques_dia')::int, 'feitos', feitos,
    'quartel', exists (select 1 from villages where user_id = uid and barracks_level > 0), 'minha_forca', public.war_power(uid, 'ataque'),
    'bases', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'nome', b.nome, 'tipo', b.tipo, 'nivel', b.nivel, 'n', jsonb_array_length(b.time),
        'forca', public.rocket_base_forca(b.time), 'moedas', public.rocket_base_forca(b.time) * (c->>'moedas_por_forca')::int, 'prazo', b.prazo, 'mon', b.mon_info, 'meu', b.dono = uid,
        'vitorias', (select count(*) from rocket_base_ataques a where a.base_id = b.id and a.user_id = uid and a.venceu)) order by b.nivel, b.id)
      from rocket_bases b where b.ativa and (b.tipo = 'normal' or coalesce(b.prazo, 'infinity') > now())), '[]'::jsonb),
    'ultimos', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'base', (select nome from rocket_bases where id = a.base_id), 'venceu', a.venceu,
        'moedas', a.moedas, 'doce', a.doce, 'em', a.criado_em) order by a.id desc) from (select * from rocket_base_ataques where user_id = uid order by id desc limit 10) a), '[]'::jsonb));
end $$;


-- rocket_base_atacar: versão do 115 com a mudança do arquivo 122
create or replace function public.rocket_base_atacar(_base int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.rocket_bases_cfg(); w jsonb := public.war_cfg(); rb rocket_bases; av villages; me characters;
  s0 jsonb; s1 jsonb := '[]'::jsonb; e jsonb; b battles; it int := 0; side int; p jsonb; m jsonb; venceu boolean; forca int; minha int; moedas int := 0; doce int := 0; atac text; msg text;
begin
  if not coalesce((c->>'on')::boolean, true) then raise exception 'As bases da Equipe Rocket estão fechadas no momento.'; end if;
  select * into av from villages where user_id = uid;
  select * into me from characters where user_id = uid for update;
  if av.user_id is null or av.barracks_level < 1 then raise exception 'Construa o Quartel Pokémon para atacar as bases da Rocket.'; end if;
  select * into rb from rocket_bases where id = _base;
  perform public.rocket_resgate_tick();   -- arquivo 122: qualquer um com Quartel pode resgatar
  select * into rb from rocket_bases where id = _base;
  if rb.id is null or not rb.ativa or (rb.tipo = 'resgate' and coalesce(rb.prazo, 'infinity') <= now()) then raise exception 'Essa base não está disponível.'; end if;
  if (select count(*) from rocket_base_ataques where user_id = uid and dia = public.game_today()) >= (c->>'ataques_dia')::int then
    raise exception 'Você já atacou % base(s) da Rocket hoje. Volte amanhã!', c->>'ataques_dia'; end if;
  perform public.war_free_heal(uid);
  if not exists (select 1 from war_squads s join monsters m2 on m2.id = s.monster_id where s.user_id = uid and s.role = 'ataque' and m2.war_hp > 0) then
    raise exception 'Seus Pokémon de ataque estão desmaiados. Cure no Centro Pokémon ou espere 24 horas.'; end if;
  forca := public.rocket_base_forca(rb.time); minha := public.war_power(uid, 'ataque');
  atac := case when public.vl_level(av, 'academia') >= 1 then av.atk_tactic else 'forte' end;
  s0 := public.war_side(uid, 'ataque', 0, 0);
  for e in select x from jsonb_array_elements(rb.time) x loop
    s1 := s1 || jsonb_build_array(public.ia_mon((e->>0)::int, (e->>1)::int, null, true));
  end loop;
  s1 := jsonb_build_object('user', uid, 'name', rb.nome, 'npc', true, 'active', 0, 'need_switch', false, 'mons', s1);
  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (uid, uid, 'npc', 3, 'ativa', 1, 'normal', now(), jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', me.name || ' invadiu a ' || rb.nome || '!'),
            jsonb_build_object('txt', 'A Equipe Rocket mandou ' || (s1->'mons'->0->>'name') || '!'),
            jsonb_build_object('txt', me.name || ' mandou ' || (s0->'mons'->0->>'name') || '!')))))
  returning * into b;
  loop
    select * into b from battles where id = b.id;
    exit when b.status <> 'ativa' or b.turn > (w->>'max_turns')::int;
    it := it + 1; exit when it > 400;
    for side in 0 .. 1 loop
      if b.phase = 'troca' then
        if coalesce((b.state->'sides'->side->>'need_switch')::boolean, false) then
          insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, side, uid, 'switch', public.war_switch(b.state, side, side = 1 or public.vl_level(av, 'academia') >= 3));
        end if;
      else
        if side = 0 then p := public.war_pick(b.state, 0, atac);
        else p := public.ia_pick(b.state, 1, 'lider', b.turn); update battles set state = public.ia_memo(state, 1, p, b.turn) where id = b.id; end if;
        insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, side, uid, p->>'kind', (p->>'value')::int);
      end if;
    end loop;
    perform public.bt_resolve(b.id);
  end loop;
  select * into b from battles where id = b.id;
  venceu := not exists (select 1 from jsonb_array_elements(b.state->'sides'->1->'mons') x where (x->>'hp')::int > 0)
            and exists (select 1 from jsonb_array_elements(b.state->'sides'->0->'mons') x where (x->>'hp')::int > 0);
  if b.status = 'ativa' then perform public.bt_finish(b.id, case when venceu then uid end, 'limite'); end if;   -- passou do limite de turnos: derrota
  -- os seus ficam com a vida que sobrou (como na guerra)
  for m in select x from jsonb_array_elements(b.state->'sides'->0->'mons') x loop
    update monsters set war_hp = greatest(0, least(100, floor((m->>'hp')::int * 100.0 / greatest(1, (m->>'maxhp')::int))))::int,
                        war_hurt_at = case when (m->>'hp')::int < (m->>'maxhp')::int then now() else war_hurt_at end
     where id = (m->>'id')::uuid and user_id = uid;
  end loop;
  if venceu then
    moedas := forca * (c->>'moedas_por_forca')::int;
    update characters set coins = coins + moedas where user_id = uid;
    if random() * 100 < least((c->>'doce_pct_max')::numeric, forca * (c->>'doce_pct_por_forca')::numeric) then
      doce := 1;
      insert into equip_doces(user_id, qty) values (uid, 1) on conflict (user_id) do update set qty = equip_doces.qty + 1;
    end if;
    msg := '🚀 ' || me.name || ' derrotou a ' || rb.nome || ' e levou ' || moedas || ' moedas' || case when doce > 0 then ' e um Doce de Forja' else '' end || '!';
    insert into event_log(user_id, kind, message) values (uid, 'rocket', msg);
    -- arquivo 122: esconderijo de resgate vencido = o Pokémon volta para o dono e quem resgatou ganha um bônus
    if rb.tipo = 'resgate' then
      update rocket_bases set ativa = false where id = rb.id;
      perform public.rocket_devolve_mon(rb.mon_snap, rb.dono);
      if (public.rocket_cfg()->>'resgate_bonus')::int > 0 then
        perform public.ext_origem('Resgate da Rocket', 'guerra');
        update characters set coins = coins + (public.rocket_cfg()->>'resgate_bonus')::int where user_id = uid;
        moedas := moedas + (public.rocket_cfg()->>'resgate_bonus')::int;
      end if;
      msg := '🦸 ' || me.name || ' invadiu o esconderijo da Rocket e resgatou o ' || coalesce(rb.mon_info->>'mon', 'Pokémon') || ' de ' || coalesce(rb.mon_info->>'dono_nome', '?')
             || '! Ele voltou para o dono, e ' || me.name || ' ganhou +' || (public.rocket_cfg()->>'resgate_bonus') || ' moedas.';
      insert into event_log(user_id, kind, message) values (rb.dono, 'rocket', msg);
    end if;
  else
    msg := 'A ' || rb.nome || ' resistiu. Seus Pokémon voltaram feridos.';
  end if;
  insert into rocket_base_ataques(user_id, base_id, dia, venceu, forca, minha_forca, moedas, doce, log)
  values (uid, rb.id, public.game_today(), venceu, forca, minha, moedas, doce, b.log);
  delete from battles where id = b.id;   -- o relato fica guardado no ataque
  return jsonb_build_object('venceu', venceu, 'moedas', moedas, 'doce', doce, 'forca', forca, 'minha_forca', minha, 'msg', msg, 'log', b.log);
end $$;


revoke execute on function public.rocket_tira_mon(uuid), public.rocket_devolve_mon(jsonb, uuid), public.rocket_media(int), public.rocket_onda_mon(jsonb, int, boolean),
  public.rocket_onda_nova(uuid), public.rocket_resgate_criar(bigint, public.rocket_entries), public.rocket_resgate_tick(), public.rocket_recorde(public.rocket_entries, boolean),
  public.rocket_temporada() from public, anon, authenticated;
grant execute on function public.rocket_current(), public.rocket_join(uuid), public.rocket_bases_lista(), public.rocket_base_atacar(int), public.admin_rocket_giovanni(boolean) to authenticated;

insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values
   ('🚀 Equipe Rocket em ondas e a chegada do Giovanni', 'A Equipe Rocket mudou:
• Você cede 1 Pokémon e enfrenta uma fila de Pokémon da Rocket, onda após onda, até o seu desmaiar ou você desistir. Uma tentativa por invasão. Cada onda vem um pouco mais forte.
• A barra conta o dano de todos. O ranking conta as ondas vencidas.
• Vitória do grupo: 100 moedas para cada um e bônus para os 3 com mais ondas. Bater o seu recorde da temporada dá moedas de Superação. Todo mundo que lutou ganha XP no Pokémon cedido, mesmo na derrota.
• A barra se ajusta ao grupo: quanto mais vitórias seguidas, mais forte a Rocket volta.
• Se o grupo perder feio, a Rocket leva um Pokémon cedido para um esconderijo por 7 dias. Quem tem Quartel pode atacar o esconderijo (Guerras → bases da Rocket) e devolver o Pokémon ao dono, ganhando um bônus.
• De tempos em tempos quem aparece é o GIOVANNI, com time próprio e prêmios em dobro. Se ele vencer, leva um Pokémon com ele: para trazer de volta, é preciso derrotá-lo na próxima vez.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
