-- Arquivo 115 (pedido do dono em 17/11/2026, aprovado pelo grupo): Guerra.
-- (1) Vilas SEM Quartel podem ser atacadas (no máximo `guerra.sem_quartel_semana` (1) vez por semana cada) e defendem com os 3 primeiros
--     Pokémon da equipe do dono; quem não tem Quartel continua sem atacar.
-- (2) Defesa vitoriosa: o atacante paga ao defensor `guerra.defesa_pct` (5) % das moedas dele, até `guerra.defesa_max` (150).
--     (Os Pokémon da defesa já ganham XP pelos adversários que derrubam, como em toda batalha.)
-- (3) Trava dos esquadrões: quem sai de um esquadrão só volta a qualquer esquadrão depois de `guerra.volta_horas` (48) horas.
--     Salvar os dois esquadrões agora é uma ação só (`war_squads_salvar`), para nada ficar pela metade.
-- (4) Bases da Equipe Rocket: lista de bases com forças diferentes; quem tem Quartel ataca a que quiser, `rocket_bases.ataques_dia` (1) por dia;
--     vitória paga moedas pela força da base (e às vezes um Doce de Forja); a XP vem dos Pokémon derrubados; derrota só deixa feridos.
--     Tipo "resgate" (Pokémon e prazo) já pronto para o pacote de resgate.
-- (5) A força de ataque e de defesa aparece em números (a conta está na Biblioteca).

create or replace function public.guerra_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"sem_quartel_on": true, "sem_quartel_semana": 1, "defesa_pct": 5, "defesa_max": 150, "volta_horas": 48}'::jsonb || coalesce(public.cfg()->'guerra', '{}'::jsonb)
$$;
create or replace function public.rocket_bases_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "ataques_dia": 1, "moedas_por_forca": 2, "doce_pct_por_forca": 0.4, "doce_pct_max": 60}'::jsonb || coalesce(public.cfg()->'rocket_bases', '{}'::jsonb)
$$;

-- ---------- trava dos esquadrões ----------
create table if not exists public.war_squad_saidas (
  monster_id uuid primary key references public.monsters(id) on delete cascade, saiu_em timestamptz not null default now());
alter table public.war_squad_saidas enable row level security;
drop policy if exists war_squad_saidas_minhas on public.war_squad_saidas;
create policy war_squad_saidas_minhas on public.war_squad_saidas for select to authenticated
  using (exists (select 1 from monsters m where m.id = monster_id and m.user_id = auth.uid()));
grant select on public.war_squad_saidas to authenticated;

-- salva os dois esquadrões de uma vez (confere tudo antes de mudar)
create or replace function public.war_squads_salvar(_ataque uuid[], _defesa uuid[]) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); h int := coalesce((public.guerra_cfg()->>'volta_horas')::int, 48); a uuid[] := coalesce(_ataque, '{}'); d uuid[] := coalesce(_defesa, '{}');
  x uuid; papel text; antes text; quando timestamptz; nm text; i int;
begin
  if not exists (select 1 from villages where user_id = uid and barracks_level > 0) then raise exception 'Construa o Quartel Pokémon para montar esquadrões.'; end if;
  if cardinality(a) > 3 or cardinality(d) > 3 then raise exception 'Cada esquadrão tem no máximo 3 Pokémon.'; end if;
  if cardinality(a) <> (select count(distinct y) from unnest(a) y) or cardinality(d) <> (select count(distinct y) from unnest(d) y) then raise exception 'Pokémon repetido no esquadrão.'; end if;
  if exists (select 1 from unnest(a) y where y = any(d)) then raise exception 'Um Pokémon não pode ficar no ataque e na defesa ao mesmo tempo.'; end if;
  if cardinality(a) + cardinality(d) <> (select count(*) from monsters where user_id = uid and (id = any(a) or id = any(d))) then raise exception 'Só dá para usar Pokémon da sua coleção.'; end if;
  -- quem entra num esquadrão onde não estava: precisa não ter saído de nenhum nas últimas horas (trocar de esquadrão também é sair)
  for x, papel in select y, 'ataque' from unnest(a) y union all select y, 'defesa' from unnest(d) y loop
    select role into antes from war_squads where user_id = uid and monster_id = x;
    continue when antes = papel;
    select name into nm from pokemon where id = (select species_id from monsters where id = x);
    if antes is not null then raise exception '% está no esquadrão de %: quem sai de um esquadrão só volta a outro depois de % horas.', nm, antes, h; end if;
    select saiu_em into quando from war_squad_saidas where monster_id = x;
    if quando is not null and quando > now() - make_interval(hours => h) then
      raise exception '% saiu de um esquadrão há pouco: só pode voltar a partir de %.', nm, to_char((quando + make_interval(hours => h)) at time zone coalesce(public.cfg()->>'timezone', 'America/Sao_Paulo'), 'DD/MM "às" HH24:MI');
    end if;
  end loop;
  -- quem sai: anota a hora
  insert into war_squad_saidas(monster_id, saiu_em)
  select s.monster_id, now() from war_squads s where s.user_id = uid and not ((s.role = 'ataque' and s.monster_id = any(a)) or (s.role = 'defesa' and s.monster_id = any(d)))
  on conflict (monster_id) do update set saiu_em = now();
  delete from war_squads where user_id = uid;
  for i in 1 .. cardinality(a) loop insert into war_squads(user_id, role, slot, monster_id) values (uid, 'ataque', i, a[i]); end loop;
  for i in 1 .. cardinality(d) loop insert into war_squads(user_id, role, slot, monster_id) values (uid, 'defesa', i, d[i]); end loop;
  return jsonb_build_object('ataque', public.war_power(uid, 'ataque'), 'defesa', public.war_power(uid, 'defesa'));
end $$;

-- a versão antiga (um esquadrão por vez) passa pela mesma conferência
create or replace function public.war_squad_set(_role text, _ids uuid[]) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); outros uuid[];
begin
  if _role not in ('ataque', 'defesa') then raise exception 'Esquadrão inválido.'; end if;
  select coalesce(array_agg(monster_id order by slot), '{}') into outros from war_squads where user_id = uid and role <> _role;
  perform public.war_squads_salvar(case when _role = 'ataque' then _ids else outros end, case when _role = 'defesa' then _ids else outros end);
end $$;

-- ---------- vilas sem Quartel ----------
-- quem defende: o esquadrão de defesa (com Quartel) ou os 3 primeiros da equipe (sem Quartel)
create or replace function public.war_def_ids(_uid uuid) returns uuid[]
language sql stable security definer set search_path = public, extensions as $$
  select case when exists (select 1 from villages where user_id = _uid and barracks_level > 0)
    then (select coalesce(array_agg(monster_id order by slot), '{}') from war_squads where user_id = _uid and role = 'defesa')
    else (select coalesce(array_agg(id order by team_slot), '{}') from (select id, team_slot from monsters where user_id = _uid and team_slot is not null order by team_slot limit 3) t) end
$$;

-- ---------- bases da Equipe Rocket ----------
create table if not exists public.rocket_bases (
  id serial primary key, nome text not null, tipo text not null default 'normal' check (tipo in ('normal', 'resgate')),
  nivel int not null, time jsonb not null, ativa boolean not null default true,
  mon_id uuid, dono uuid references auth.users(id) on delete cascade, prazo timestamptz,   -- tipo "resgate": o Pokémon, de quem é e até quando
  criada_em timestamptz not null default now());
alter table public.rocket_bases enable row level security;   -- sem política: o time fica no servidor
create table if not exists public.rocket_base_ataques (
  id bigserial primary key, user_id uuid not null references auth.users(id) on delete cascade, base_id int not null references public.rocket_bases(id) on delete cascade,
  dia date not null, venceu boolean not null, forca int not null, minha_forca int not null, moedas int not null default 0, doce int not null default 0,
  log jsonb, criado_em timestamptz not null default now());
create index if not exists rocket_base_ataques_user on public.rocket_base_ataques (user_id, dia);
alter table public.rocket_base_ataques enable row level security;
drop policy if exists rocket_base_ataques_meus on public.rocket_base_ataques;
create policy rocket_base_ataques_meus on public.rocket_base_ataques for select to authenticated using (user_id = auth.uid() or public.is_admin());
grant select on public.rocket_base_ataques to authenticated;

insert into public.rocket_bases(nome, nivel, time)
select x.nome, x.nivel, x.time::jsonb from (values
  ('Esconderijo do Porto', 15, '[[19, 14], [23, 15], [109, 16]]'),
  ('Armazém Abandonado', 25, '[[20, 24], [24, 25], [110, 26]]'),
  ('Laboratório Secreto', 35, '[[42, 34], [89, 35], [53, 36]]'),
  ('Fortaleza da Rocket', 45, '[[24, 44], [110, 45], [115, 46]]'),
  ('Quartel-General da Rocket', 55, '[[34, 54], [31, 55], [112, 56]]')) x(nome, nivel, time)
 where not exists (select 1 from public.rocket_bases);

-- força de um time da Rocket: a mesma conta da força dos esquadrões (soma de vida, ataque, defesa, velocidade e especial ÷ 10)
create or replace function public.rocket_base_forca(_time jsonb) returns int
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(round(sum(((m->>'maxhp')::int + (m->>'atk')::int + (m->>'def')::int + (m->>'spd')::int + (m->>'spc')::int) / 10.0))::int, 0)
    from jsonb_array_elements(_time) e, lateral (select public.npc_mon((e->>0)::int, (e->>1)::int) m) q
$$;

create or replace function public.rocket_bases_lista() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.rocket_bases_cfg(); feitos int;
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  select count(*) into feitos from rocket_base_ataques where user_id = uid and dia = public.game_today();
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'ataques_dia', (c->>'ataques_dia')::int, 'feitos', feitos,
    'quartel', exists (select 1 from villages where user_id = uid and barracks_level > 0), 'minha_forca', public.war_power(uid, 'ataque'),
    'bases', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'nome', b.nome, 'tipo', b.tipo, 'nivel', b.nivel, 'n', jsonb_array_length(b.time),
        'forca', public.rocket_base_forca(b.time), 'moedas', public.rocket_base_forca(b.time) * (c->>'moedas_por_forca')::int, 'prazo', b.prazo,
        'vitorias', (select count(*) from rocket_base_ataques a where a.base_id = b.id and a.user_id = uid and a.venceu)) order by b.nivel, b.id)
      from rocket_bases b where b.ativa and (b.tipo = 'normal' or (b.dono = uid and coalesce(b.prazo, 'infinity') > now()))), '[]'::jsonb),
    'ultimos', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'base', (select nome from rocket_bases where id = a.base_id), 'venceu', a.venceu,
        'moedas', a.moedas, 'doce', a.doce, 'em', a.criado_em) order by a.id desc) from (select * from rocket_base_ataques where user_id = uid order by id desc limit 10) a), '[]'::jsonb));
end $$;

-- ataque automático, como a guerra: o esquadrão de ataque contra o time da base
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
  if rb.id is null or not rb.ativa or (rb.tipo = 'resgate' and (rb.dono is distinct from uid or coalesce(rb.prazo, 'infinity') <= now())) then raise exception 'Essa base não está disponível.'; end if;
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
  else
    msg := 'A ' || rb.nome || ' resistiu. Seus Pokémon voltaram feridos.';
  end if;
  insert into rocket_base_ataques(user_id, base_id, dia, venceu, forca, minha_forca, moedas, doce, log)
  values (uid, rb.id, public.game_today(), venceu, forca, minha, moedas, doce, b.log);
  delete from battles where id = b.id;   -- o relato fica guardado no ataque
  return jsonb_build_object('venceu', venceu, 'moedas', moedas, 'doce', doce, 'forca', forca, 'minha_forca', minha, 'msg', msg, 'log', b.log);
end $$;

create or replace function public.admin_rocket_bases() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(to_jsonb(b) || jsonb_build_object('forca', public.rocket_base_forca(b.time)) order by b.nivel, b.id) from rocket_bases b), '[]'::jsonb);
end $$;
create or replace function public.admin_rocket_base_salvar(_id int, _nome text, _nivel int, _time jsonb, _ativa boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare antes jsonb; e jsonb;
begin
  perform public.assert_admin();
  if length(btrim(coalesce(_nome, ''))) < 2 then raise exception 'Dê um nome à base.'; end if;
  if jsonb_typeof(_time) <> 'array' or jsonb_array_length(_time) not between 1 and 6 then raise exception 'O time precisa ter de 1 a 6 Pokémon.'; end if;
  for e in select * from jsonb_array_elements(_time) loop
    if jsonb_typeof(e) <> 'array' or not exists (select 1 from pokemon where id = (e->>0)::int) or (e->>1)::int not between 1 and 100 then raise exception 'Pokémon ou nível inválido: %', e; end if;
  end loop;
  if _id is null then
    insert into rocket_bases(nome, nivel, time, ativa) values (btrim(_nome), coalesce(_nivel, 1), _time, coalesce(_ativa, true));
  else
    select to_jsonb(b) into antes from rocket_bases b where id = _id;
    if antes is null then raise exception 'Base não encontrada.'; end if;
    update rocket_bases set nome = btrim(_nome), nivel = coalesce(_nivel, nivel), time = _time, ativa = coalesce(_ativa, ativa) where id = _id;
  end if;
  insert into admin_audit_log(admin_id, action, target, after) values (auth.uid(), 'rocket_base', coalesce(_id::text, 'nova'), jsonb_build_object('antes', antes, 'nome', _nome, 'time', _time, 'ativa', _ativa));
  return public.admin_rocket_bases();
end $$;


-- war_power: versão do 25 com a mudança do arquivo 115
create or replace function public.war_power(_uid uuid, _role text) returns int
language plpgsql stable security definer set search_path = public, extensions as $$
declare v villages; p numeric; b numeric := 0;
begin
  select * into v from villages where user_id = _uid;
  if _role = 'defesa' then select coalesce(sum(public.war_mon_power(x)), 0) into p from unnest(public.war_def_ids(_uid)) x;   -- sem Quartel: os 3 primeiros da equipe
  else select coalesce(sum(public.war_mon_power(monster_id)), 0) into p from war_squads where user_id = _uid and role = _role; end if;
  if _role = 'defesa' then
    b := least(coalesce((public.war_cfg()->>'def_cap')::numeric, 20),
               public.war_num('defesa', 'bonus', public.vl_level(v, 'defesa')) + public.war_num('armadilhas', 'pct', public.vl_level(v, 'armadilhas')));
  end if;
  return round(p * (1 + b / 100) + 2 * coalesce(v.center_level, 1))::int;
end $$;


-- war_side: versão do 25 com a mudança do arquivo 115
create or replace function public.war_side(_uid uuid, _role text, _bonus numeric, _trap numeric) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare mons jsonb := '[]'::jsonb; r record; m jsonb; k int := 0;
begin
  for r in select m2.id, m2.war_hp from unnest(case when _role = 'defesa' then public.war_def_ids(_uid)   -- arquivo 115: sem Quartel defende com a equipe
              else (select coalesce(array_agg(monster_id order by slot), '{}') from war_squads where user_id = _uid and role = _role) end) with ordinality u(mid, o)
              join monsters m2 on m2.id = u.mid where m2.war_hp > 0 order by u.o loop
    m := public.bt_mon(r.id);
    if _bonus > 0 then
      m := jsonb_set(m, '{maxhp}', to_jsonb(ceil((m->>'maxhp')::int * (1 + _bonus / 100))::int));
      m := jsonb_set(m, '{def}', to_jsonb(ceil((m->>'def')::int * (1 + _bonus / 100))::int));
    end if;
    m := jsonb_set(m, '{hp}', to_jsonb(greatest(1, ceil((m->>'maxhp')::int * r.war_hp / 100.0))::int));
    if k = 0 and _trap > 0 then m := jsonb_set(m, '{hp}', to_jsonb(greatest(1, ceil((m->>'hp')::int * (1 - _trap / 100))::int))); end if;
    mons := mons || jsonb_build_array(m); k := k + 1;
  end loop;
  return jsonb_build_object('user', _uid, 'name', (select name from characters where user_id = _uid), 'active', 0, 'need_switch', false, 'mons', mons);
end $$;


-- war_block: versão do 25 com a mudança do arquivo 115
create or replace function public.war_block(_att uuid, _def uuid) returns text
language plpgsql stable security definer set search_path = public, extensions as $$
declare w jsonb := public.war_cfg(); v villages; ch characters; t date := public.game_today();
begin
  if _att = _def then return 'você mesmo'; end if;
  select * into v from villages where user_id = _def;
  select * into ch from characters where user_id = _def;
  if ch.id is null then return 'não entrou na guerra'; end if;
  if v.user_id is null or v.barracks_level < 1 then   -- arquivo 115: vila sem Quartel
    if not coalesce((public.guerra_cfg()->>'sem_quartel_on')::boolean, true) then return 'não entrou na guerra'; end if;
    if cardinality(public.war_def_ids(_def)) < 3 then return 'sem 3 Pokémon na equipe'; end if;
    if (select count(*) from wars where defender = _def and created_at >= public.creche_semana()) >= coalesce((public.guerra_cfg()->>'sem_quartel_semana')::int, 1) then return 'já foi atacada esta semana'; end if;
  elsif (select count(*) from war_squads where user_id = _def and role = 'defesa') < 3 then return 'sem defesa montada'; end if;
  if ch.created_at > now() - make_interval(days => (w->>'min_age_days')::int) then return 'herói novo'; end if;
  if not exists (select 1 from daily_moves where user_id = _def and move_date >= t - (w->>'active_days')::int) then return 'não joga há dias'; end if;
  if coalesce(v.shield_until, '-infinity') > now() then return 'escudo'; end if;
  if exists (select 1 from wars where attacker = _att and defender = _def and created_at > now() - make_interval(hours => (w->>'pair_hours')::int)) then return 'atacou há pouco'; end if;
  return null;
end $$;


-- war_targets: versão do 25 com a mudança do arquivo 115
create or replace function public.war_targets() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); w jsonb := public.war_cfg(); mv villages; my int; watch int; r record; out jsonb := '[]'::jsonb; ok int := 0; info jsonb; dp int; bl text; ratio numeric;
begin
  select * into mv from villages where user_id = uid;
  my := public.war_power(uid, 'ataque'); watch := public.vl_level(mv, 'vigia');
  for r in
    select ch.user_id, ch.name, ch.level, ch.class, ch.outfit, v.center_level, v.shield_until, public.war_block(uid, ch.user_id) as bl, coalesce(v.barracks_level, 0) > 0 as tem_q,
           public.war_power(ch.user_id, 'defesa') as dp
      from characters ch left join villages v on v.user_id = ch.user_id   -- arquivo 115: vilas sem Quartel também entram
     where ch.user_id <> uid and (coalesce(v.barracks_level, 0) > 0 or coalesce((public.guerra_cfg()->>'sem_quartel_on')::boolean, true))
  loop
    ratio := case when my > 0 then r.dp * 100.0 / my else 999 end;
    info := jsonb_build_object('user_id', r.user_id, 'name', r.name, 'level', r.level, 'class', r.class, 'outfit', r.outfit, 'center', r.center_level,
      'power', r.dp, 'ratio', round(ratio), 'block', r.bl, 'shield_until', r.shield_until,
      'quartel', r.tem_q, 'fair', ratio between (w->>'match_min')::numeric and (w->>'match_max')::numeric);
    if watch >= 1 and r.bl is distinct from 'sem defesa montada' then
      info := info || jsonb_build_object('squad', (select jsonb_agg(jsonb_build_object('species', m.species_id,
              'level', case when watch >= 2 then m.level end,
              'hp', case when watch >= 2 then case when m.war_hurt_at is not null and m.war_hurt_at <= now() - make_interval(hours => (w->>'free_heal_hours')::int) then 100 else m.war_hp end end,
              'moves', case when watch >= 3 then (select jsonb_agg(pm.name order by u.o) from unnest(m.moves) with ordinality u(mid, o) join pk_moves pm on pm.id = u.mid) end) order by u.o)
              from unnest(public.war_def_ids(r.user_id)) with ordinality u(mid, o) join monsters m on m.id = u.mid));
    end if;
    if watch >= 3 and my > 0 then info := info || jsonb_build_object('chance', round(100.0 * my * my / (my * my + r.dp * r.dp))); end if;
    out := out || jsonb_build_array(info);
  end loop;
  -- quem pode ser atacado: força parecida; se houver poucos, entram as vilas mais fortes mais próximas
  select count(*) into ok from jsonb_array_elements(out) x where x->>'block' is null and (x->>'fair')::boolean;
  select jsonb_agg(x || jsonb_build_object('can', x->>'block' is null and ((x->>'fair')::boolean
           or (ok < (w->>'match_fill')::int and x->>'user_id' in (
                 select y->>'user_id' from jsonb_array_elements(out) y where y->>'block' is null and not (y->>'fair')::boolean
                    and (y->>'ratio')::numeric >= (w->>'match_min')::numeric   -- completa só com vilas mais fortes: nunca com muito mais fracas
                  order by abs((y->>'ratio')::numeric - 100) limit greatest(0, (w->>'match_fill')::int - ok)))))
         order by (x->>'block') is not null, abs((x->>'ratio')::numeric - 100))
    into out from jsonb_array_elements(out) x;
  return jsonb_build_object('power', my, 'defesa', public.war_power(uid, 'defesa'), 'watch', watch, 'targets', coalesce(out, '[]'::jsonb));
end $$;


-- war_attack: versão do 79 com a mudança do arquivo 115
create or replace function public.war_attack(_target uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); w jsonb := public.war_cfg(); t date := public.game_today(); tz text := coalesce(public.cfg()->>'timezone', 'America/Sao_Paulo');
  av villages; dv villages; ach characters; dch characters; tg jsonb; s0 jsonb; s1 jsonb; b battles; it int := 0; side int; p jsonb; m jsonb;
  bonus numeric; trap numeric; cap numeric; atac text; dtac text; asmart boolean; dsmart boolean; winner uuid; pct0 numeric; pct1 numeric;
  att_lost int; def_lost int; prot int; loot int := 0; nd int; k text; pool text[]; dmg text[] := '{}'; red numeric; wr wars; i int; reason text; pago int := 0;
begin
  if _target = uid then raise exception 'Você não pode atacar a própria vila.'; end if;
  -- trava as duas vilas sempre na mesma ordem (dois ataques ao mesmo tempo não passam juntos)
  insert into villages(user_id) values (_target) on conflict do nothing;   -- arquivo 115: quem nunca abriu a vila também pode ser atacado
  perform 1 from villages where user_id in (uid, _target) order by user_id for update;
  perform public.war_free_heal(uid); perform public.war_free_heal(_target);
  perform public.vl_autofix(uid); perform public.vl_autofix(_target);
  select * into av from villages where user_id = uid;
  select * into dv from villages where user_id = _target;
  select * into ach from characters where user_id = uid for update;
  select * into dch from characters where user_id = _target for update;
  if av.user_id is null or av.barracks_level < 1 then raise exception 'Construa o Quartel Pokémon para entrar na guerra.'; end if;
  if (select count(*) from war_squads where user_id = uid and role = 'ataque') < 3 then raise exception 'Monte os 3 Pokémon de ataque no Quartel.'; end if;
  if (select count(*) from war_squads where user_id = uid and role = 'defesa') < 3 then raise exception 'Monte também os 3 Pokémon de defesa: quem ataca também pode ser atacado.'; end if;
  if ach.created_at > now() - make_interval(days => (w->>'min_age_days')::int) then raise exception 'Heróis com menos de % dias ainda não guerreiam.', w->>'min_age_days'; end if;
  if (select count(*) from wars where attacker = uid and (created_at at time zone tz)::date = t) >= public.war_num('quartel', 'attacks', av.barracks_level) then
    raise exception 'Você já fez os % ataques de hoje. Melhore o Quartel para atacar mais.', public.war_num('quartel', 'attacks', av.barracks_level)::int; end if;
  if not exists (select 1 from war_squads s join monsters m2 on m2.id = s.monster_id where s.user_id = uid and s.role = 'ataque' and m2.war_hp > 0) then
    raise exception 'Seus Pokémon de ataque estão desmaiados. Cure no Centro Pokémon ou espere 24 horas.'; end if;
  select x into tg from jsonb_array_elements(public.war_targets()->'targets') x where x->>'user_id' = _target::text;
  if tg is null then raise exception 'Esse jogador não está na guerra.'; end if;
  if not (tg->>'can')::boolean then
    raise exception 'Não dá para atacar %: %.', dch.name, coalesce(tg->>'block', 'a força é muito diferente da sua'); end if;

  -- bônus da defesa (Torre de Defesa + Armadilhas, até o limite) e táticas (Academia)
  cap := (w->>'def_cap')::numeric;
  bonus := least(cap, public.war_num('defesa', 'bonus', public.vl_level(dv, 'defesa')));
  trap := least(cap - bonus, public.war_num('armadilhas', 'pct', public.vl_level(dv, 'armadilhas')));
  atac := case when public.vl_level(av, 'academia') >= 1 then av.atk_tactic else 'forte' end;
  dtac := case when public.vl_level(dv, 'academia') >= 2 then dv.def_tactic else 'forte' end;
  asmart := public.vl_level(av, 'academia') >= 3; dsmart := public.vl_level(dv, 'academia') >= 3;
  s0 := public.war_side(uid, 'ataque', 0, trap);
  s1 := public.war_side(_target, 'defesa', bonus, 0);

  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (uid, _target, 'guerra', 3, 'ativa', 1, 'normal', now(), jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', ach.name || ' atacou a vila de ' || dch.name || '!'),
            jsonb_build_object('txt', ach.name || ' mandou ' || (s0->'mons'->0->>'name') || '!')) ||
            case when jsonb_array_length(s1->'mons') > 0 then jsonb_build_array(jsonb_build_object('txt', dch.name || ' defendeu com ' || (s1->'mons'->0->>'name') || '!'))
                 else jsonb_build_array(jsonb_build_object('txt', 'Os defensores de ' || dch.name || ' estavam desmaiados!')) end ||
            case when bonus > 0 then jsonb_build_array(jsonb_build_object('txt', 'Torre de Defesa: defensores com +' || bonus || '% de vida e defesa.')) else '[]'::jsonb end ||
            case when trap > 0 then jsonb_build_array(jsonb_build_object('txt', 'Armadilha! ' || (s0->'mons'->0->>'name') || ' entrou com ' || trap || '% a menos de vida.')) else '[]'::jsonb end)))
  returning * into b;

  if jsonb_array_length(s1->'mons') = 0 then
    perform public.bt_finish(b.id, uid, 'sem_defesa');
  else
    -- turno a turno, os dois lados escolhidos pelo servidor
    loop
      select * into b from battles where id = b.id;
      exit when b.status <> 'ativa' or b.turn > (w->>'max_turns')::int;
      it := it + 1; exit when it > 400;
      for side in 0 .. 1 loop
        if b.phase = 'troca' then
          if coalesce((b.state->'sides'->side->>'need_switch')::boolean, false) then
            insert into battle_actions(battle_id, turn, side, user_id, kind, value)
            values (b.id, b.turn, side, case when side = 0 then uid else _target end, 'switch', public.war_switch(b.state, side, case when side = 0 then asmart else dsmart end));
          end if;
        else
          p := public.war_pick(b.state, side, case when side = 0 then atac else dtac end);
          insert into battle_actions(battle_id, turn, side, user_id, kind, value)
          values (b.id, b.turn, side, case when side = 0 then uid else _target end, p->>'kind', (p->>'value')::int);
        end if;
      end loop;
      perform public.bt_resolve(b.id);
    end loop;
    select * into b from battles where id = b.id;
    if b.status = 'ativa' then
      -- passou do limite de turnos: vence quem tiver mais vida (em %)
      select sum((x->>'hp')::int)::numeric / greatest(1, sum((x->>'maxhp')::int)) into pct0 from jsonb_array_elements(b.state->'sides'->0->'mons') x;
      select sum((x->>'hp')::int)::numeric / greatest(1, sum((x->>'maxhp')::int)) into pct1 from jsonb_array_elements(b.state->'sides'->1->'mons') x;
      update battles set log = log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt',
        'Fim do tempo da guerra! Vence quem ficou com mais vida.')))) where id = b.id;
      perform public.bt_finish(b.id, case when pct0 > pct1 then uid when pct1 > pct0 then _target else null end, 'limite');
    end if;
  end if;
  select * into b from battles where id = b.id;
  winner := b.winner;
  -- arquivo 115: defesa vitoriosa: o atacante paga ao defensor uma parte das moedas dele, com teto
  if winner = _target then
    pago := least(coalesce((public.guerra_cfg()->>'defesa_max')::int, 150),
                  floor(greatest(0, (select coins from characters where user_id = uid)) * coalesce((public.guerra_cfg()->>'defesa_pct')::numeric, 5) / 100))::int;
    if pago > 0 then
      update characters set coins = coins - pago where user_id = uid;
      update characters set coins = coins + pago where user_id = _target;
    end if;
  end if;

  -- desgaste: os dois lados ficam com a vida que sobrou (o nível e o XP não mudam)
  for side in 0 .. 1 loop
    for m in select x from jsonb_array_elements(b.state->'sides'->side->'mons') x loop
      update monsters set war_hp = greatest(0, least(100, floor((m->>'hp')::int * 100.0 / greatest(1, (m->>'maxhp')::int))))::int,
                          war_hurt_at = case when (m->>'hp')::int < (m->>'maxhp')::int then now() else war_hurt_at end
       where id = (m->>'id')::uuid;
    end loop;
  end loop;
  select count(*) filter (where (x->>'hp')::int <= 0) into att_lost from jsonb_array_elements(b.state->'sides'->0->'mons') x;
  select count(*) filter (where (x->>'hp')::int <= 0) into def_lost from jsonb_array_elements(b.state->'sides'->1->'mons') x;

  -- saque e danos (só quando o atacante vence)
  if winner = uid then
    prot := (w->>'base_protect')::int + public.war_num('cofre', 'protect', public.vl_level(dv, 'cofre'))::int
          + public.war_num('quartel', 'protect', public.vl_level(dv, 'quartel'))::int;   -- arquivo 79: o Quartel também protege
    loot := least((w->>'loot_max')::int, floor(greatest(0, dch.coins - prot) * (w->>'loot_pct')::numeric / 100))::int;
    loot := greatest(0, least(loot, dch.coins));
    if loot > 0 then
      update characters set coins = coins - loot where user_id = _target;
      update characters set coins = coins + loot where user_id = uid;
    end if;
    nd := 1 + case when att_lost = 0 then 1 else 0 end;   -- 2 danos se a defesa não derrubou nenhum atacante
    red := public.war_num('muralha', 'reduce', public.vl_level(dv, 'muralha'));
    for i in 1 .. nd loop
      continue when random() * 100 >= 100 - red;
      select array_agg(x) into pool from jsonb_array_elements_text(w->'damage_pool') x
       where public.vl_level(dv, x, true) > 0 and not (dv.damaged ? x) and not (x = any(dmg));
      exit when pool is null;
      k := pool[1 + floor(random() * cardinality(pool))::int];
      dmg := dmg || k;
    end loop;
    if cardinality(dmg) > 0 then
      update villages set damaged = damaged || (select jsonb_object_agg(x, jsonb_build_object('at', now(), 'fix', now() + make_interval(days => (w->>'auto_fix_days')::int))) from unnest(dmg) x)
       where user_id = _target;
    end if;
  end if;
  update villages set shield_until = now() + make_interval(hours => (w->>'shield_hours')::int) where user_id = _target;

  insert into wars(attacker, defender, att_name, def_name, battle_id, winner, att_power, def_power, loot, damaged, att_lost, def_lost, details)
  values (uid, _target, ach.name, dch.name, b.id, winner, public.war_power(uid, 'ataque'), (tg->>'power')::int, loot, dmg, att_lost, def_lost,
          jsonb_build_object('bonus', bonus, 'trap', trap, 'protected', case when winner = uid then prot end, 'turns', b.turn, 'reason', b.end_reason,
                             'atk_tactic', atac, 'def_tactic', dtac, 'pago', pago, 'sem_quartel', coalesce(dv.barracks_level, 0) < 1))
  returning * into wr;
  reason := case when winner = uid then ach.name || ' invadiu a vila de ' || dch.name || ' e levou ' || loot || ' moedas!'
                 when winner = _target then 'A defesa de ' || dch.name || ' segurou o ataque de ' || ach.name || '!' || case when pago > 0 then ' ' || ach.name || ' pagou ' || pago || ' moedas a ' || dch.name || '.' else '' end
                 else ach.name || ' e ' || dch.name || ' empataram na guerra.' end;
  insert into event_log(user_id, kind, message) values (uid, 'guerra', reason);
  return to_jsonb(wr) || jsonb_build_object('message', reason);
end $$;


-- admin_cfg_efetiva: versão do 114 com a mudança do arquivo 115
create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'leilao', public.leilao_cfg(), 'herois', public.herois_cfg(), 'temporada', public.temporada_cfg(), 'liga', public.liga_cfg(), 'pausa', public.pausa_cfg(), 'teto', public.teto_cfg(), 'boas_vindas', public.boas_vindas_cfg(), 'vila_bonus', public.vila_bonus_cfg(), 'tm_nivel', public.tm_nivel_cfg(), 'quiz_auto', public.quiz_auto_cfg(), 'cartas', public.tcg_cfg(), 'pokebound', public.pokebound_cfg(), 'visual', public.visual_cfg(), 'praca', public.praca_cfg(), 'rpg', public.rpg_cfg(), 'equip', public.equip_cfg(), 'base', public.cfg(), 'exp', public.exp_cfg(), 'vale', public.vale_cfg(), 'fazenda', public.fazenda_cfg(), 'ia', public.ia_cfg(), 'troca', public.troca_cfg(), 'guerra', public.guerra_cfg(), 'rocket_bases', public.rocket_bases_cfg());   -- arquivo 115   -- arquivo 114: troca entre jogadores   -- arquivo 113: escolha de ataques   -- arquivo 112: Vale do Treino e Fazenda   -- arquivo 111: Expedições
end $$;


revoke execute on function public.guerra_cfg(), public.rocket_bases_cfg(), public.war_def_ids(uuid), public.rocket_base_forca(jsonb) from public, anon, authenticated;
grant execute on function public.war_squads_salvar(uuid[], uuid[]), public.war_squad_set(text, uuid[]), public.war_targets(), public.war_attack(uuid),
  public.rocket_bases_lista(), public.rocket_base_atacar(int), public.admin_rocket_bases(), public.admin_rocket_base_salvar(int, text, int, jsonb, boolean),
  public.admin_cfg_efetiva() to authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values
   ('⚔️ Guerra: vilas sem Quartel, bases da Rocket e mais', 'A Guerra entre vilas mudou, a pedido da turma:
• Vilas SEM Quartel agora também podem ser atacadas, no máximo 1 vez por semana cada. Elas defendem com os 3 primeiros Pokémon da equipe do dono. Quem não tem Quartel continua sem poder atacar.
• Defesa vitoriosa: quem atacou e perdeu paga ao defensor 5% das moedas dele (até 150).
• Esquadrões: um Pokémon que sai de um esquadrão (ataque ou defesa) só volta a qualquer esquadrão depois de 48 horas.
• Bases da Equipe Rocket: quem tem Quartel pode atacar 1 base por dia, escolhendo a força. Quanto mais forte a base, maior o prêmio em moedas e experiência, e às vezes vem um Doce de Forja. Se perder, os Pokémon só voltam feridos.
• A força de ataque e de defesa de cada vila agora aparece em números. A Biblioteca explica a conta.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
