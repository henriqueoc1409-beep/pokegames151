-- =====================================================================
-- POKEGAMES — Coleção de Pokémon: encontro e captura depois de andar,
-- Pokédex, equipe de até 6, XP e evolução (regras da 1ª geração), mascote
-- no tabuleiro, bolsa (Poké Bolas e pedras) e roupas para os Pokémon.
--
-- NÃO muda: casas andadas, desafio do dia, XP, moedas e recompensas atuais.
-- O XP dos Pokémon é separado do XP do herói (regra em pk_cfg()->'xp').
-- Todas as ações passam por funções no servidor: o site não escolhe a
-- espécie, não decide a captura e não grava em nenhuma tabela.
-- Depende do 16 (dados da 1ª geração). Rode depois do 16.
-- Antes de rodar, faça a cópia de segurança.
-- =====================================================================

-- ---------- regras do Pokegames (configuráveis pelo game_config.config->'pk') ----------
-- Valores padrão. Para mudar, o admin grava, por exemplo, {"pk": {"xp": {...}}} no game_config:
-- cada bloco gravado substitui o bloco padrão inteiro.
create or replace function public.pk_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{
    "encounter": {"level_min": 3, "level_span": 37, "level_spread": 3, "legendaries": false, "region_bonus": 3,
                  "rarity_weight": {"comum": 10, "incomum": 6, "raro": 3, "muito_raro": 1}},
    "rarity": {"comum": 190, "incomum": 120, "raro": 60},
    "capture": {"throws": 3, "balls": {
        "poke":  {"name": "Poké Bola",   "range": 255, "factor": 12, "price": 0},
        "great": {"name": "Great Ball",  "range": 200, "factor": 8,  "price": 40},
        "ultra": {"name": "Ultra Ball",  "range": 150, "factor": 12, "price": 90}}},
    "stones": {"price": 250},
    "xp": {"move_base": 100, "per_step": 15, "per_mode": 40, "battle_mult": 1.5, "battles_per_day": 5},
    "storage": {"max_monsters": 300},
    "battle": {"size": 3, "min_captured": 3, "turn_hours": 24}
  }'::jsonb || coalesce(public.cfg()->'pk', '{}'::jsonb)
$$;

-- região do tabuleiro -> tipos que aparecem mais por lá
create or replace function public.pk_region_types(_region text) returns text[]
language sql immutable as $$
  select case
    when _region in ('Floresta','Bosque Antigo','Bosque Enevoado','Vale dos Ventos') then array['INSETO','PLANTA','NORMAL','VOADOR']
    when _region in ('Praia','Aldeia dos Pescadores','Trilha do Farol','Cidade Portuária','Ponte Velha') then array['AGUA','NORMAL','VOADOR']
    when _region in ('Montanha','Desfiladeiro','Ravina das Vespas','Escadaria do Trovão') then array['PEDRA','TERRA','LUTA','ELETRICO']
    when _region in ('Caverna Escura','Atalho das Sombras') then array['PEDRA','FANTASMA','VENENO','TERRA']
    when _region in ('Pântano','Pântano Tóxico','Lamaçal Profundo') then array['VENENO','AGUA','INSETO']
    when _region in ('Cratera','Estrada do Vulcão') then array['FOGO','PEDRA']
    when _region in ('Mosteiro','Planalto Real','Jardins Reais','Estrada Real','Castelo da Liga') then array['PSIQUICO','FADA','NORMAL','PLANTA','DRAGAO','GELO']
    else array['NORMAL'] end
$$;

create or replace function public.pk_rarity(_catch int) returns text
language sql stable security definer set search_path = public, extensions as $$
  select case when _catch >= (public.pk_cfg()->'rarity'->>'comum')::int then 'comum'
              when _catch >= (public.pk_cfg()->'rarity'->>'incomum')::int then 'incomum'
              when _catch >= (public.pk_cfg()->'rarity'->>'raro')::int then 'raro'
              else 'muito_raro' end
$$;

-- ---------- fórmulas da 1ª geração ----------
-- experiência total para um nível (curvas de crescimento de Red/Blue)
create or replace function public.pk_exp_for(_growth text, _lvl int) returns int
language sql immutable as $$
  select greatest(0, floor(case _growth
    when 'medio_rapido' then power(_lvl, 3)
    when 'pouco_rapido' then 0.75 * power(_lvl, 3) + 10 * power(_lvl, 2) - 30
    when 'pouco_lento'  then 0.75 * power(_lvl, 3) + 20 * power(_lvl, 2) - 70
    when 'medio_lento'  then 1.2 * power(_lvl, 3) - 15 * power(_lvl, 2) + 100 * _lvl - 140
    when 'rapido'       then 0.8 * power(_lvl, 3)
    when 'lento'        then 1.25 * power(_lvl, 3)
    else power(_lvl, 3) end))::int
$$;
-- atributo (sem "stat exp", que o Pokegames não usa)
create or replace function public.pk_stat(_base int, _dv int, _lvl int, _hp boolean) returns int
language sql immutable as $$
  select floor(((_base + _dv) * 2) * _lvl / 100.0)::int + case when _hp then _lvl + 10 else 5 end
$$;
create or replace function public.pk_hp_dv(_a int, _d int, _s int, _c int) returns int
language sql immutable as $$ select ((_a & 1) << 3) | ((_d & 1) << 2) | ((_s & 1) << 1) | (_c & 1) $$;

-- os 4 ataques mais recentes que a espécie conhece num nível
create or replace function public.pk_moves_at(_species int, _lvl int) returns int[]
language sql stable security definer set search_path = public, extensions as $$
  with all_m as (
    select m, 0 as lv, ord from pokemon p, unnest(p.start_moves) with ordinality u(m, ord) where p.id = _species
    union all
    select move_id, level, 0 from pk_learnset where species_id = _species and level <= _lvl),
  firsts as (select m, min(lv) lv, min(ord) ord from all_m group by m)
  select coalesce(array_agg(m order by lv, ord), '{}') from (select m, lv, ord from firsts order by lv desc, ord desc limit 4) x
$$;

-- ---------- tabelas dos jogadores ----------
create table if not exists public.monsters (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  species_id    int not null references public.pokemon(id),
  level         int not null check (level between 1 and 100),
  exp           int not null default 0 check (exp >= 0),
  dv_atk        int not null check (dv_atk between 0 and 15),
  dv_def        int not null check (dv_def between 0 and 15),
  dv_spd        int not null check (dv_spd between 0 and 15),
  dv_spc        int not null check (dv_spc between 0 and 15),
  moves         int[] not null default '{}' check (cardinality(moves) between 1 and 4),
  pending_moves int[] not null default '{}',
  team_slot     int check (team_slot between 1 and 6),
  outfit        jsonb not null default '{}'::jsonb,
  caught_species int not null,
  caught_at     timestamptz not null default now(),
  unique (user_id, team_slot)
);
create index if not exists monsters_dono on public.monsters (user_id);

create table if not exists public.pokedex_entries (
  user_id    uuid not null references auth.users(id) on delete cascade,
  species_id int not null references public.pokemon(id),
  seen_at    timestamptz not null default now(),
  caught_at  timestamptz,
  primary key (user_id, species_id)
);

create table if not exists public.encounters (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  move_id     uuid not null unique,                 -- uma movimentação = no máximo um encontro
  node        int,
  species_id  int not null references public.pokemon(id),
  level       int not null,
  status      text not null default 'aberto' check (status in ('aberto','capturado','fugiu','recusado')),
  throws_left int not null,
  mon_id      uuid,
  created_at  timestamptz not null default now(),
  resolved_at timestamptz
);
create index if not exists encounters_abertos on public.encounters (user_id) where status = 'aberto';

-- movimentações já transformadas em XP de Pokémon e encontro (evita dar duas vezes)
create table if not exists public.pk_move_sync (
  move_id    uuid primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  xp_pool    int not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.bag_items (
  user_id uuid not null references auth.users(id) on delete cascade,
  item    text not null,
  qty     int not null default 0 check (qty >= 0),
  primary key (user_id, item)
);

-- avisos de subida de nível, ataque novo e evolução disponível
create table if not exists public.mon_events (
  id         bigserial primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  mon_id     uuid,
  kind       text not null,
  data       jsonb not null default '{}'::jsonb,
  seen       boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists mon_events_novos on public.mon_events (user_id) where not seen;

-- mascote: cópia leve para o mapa desenhar sem consulta extra
alter table public.characters add column if not exists mascot jsonb;

-- roupas de Pokémon usam o mesmo catálogo da loja, com espaços próprios
alter table public.shop_items drop constraint if exists shop_items_slot_check;
alter table public.shop_items add constraint shop_items_slot_check
  check (slot in ('chapeu','capa','roupa','aura','acessorio','pk_cabeca','pk_rosto','pk_pescoco','pk_aura'));

-- data de início: só movimentações a partir de agora geram encontro e XP de Pokémon
update public.game_config set config = jsonb_set(config, '{pk_start_at}', to_jsonb(now()), true)
 where active and not (config ? 'pk_start_at');

-- ---------- permissões de leitura ----------
alter table public.monsters enable row level security;
alter table public.pokedex_entries enable row level security;
alter table public.encounters enable row level security;
alter table public.pk_move_sync enable row level security;
alter table public.bag_items enable row level security;
alter table public.mon_events enable row level security;
drop policy if exists p_mon on public.monsters;        create policy p_mon on public.monsters for select to authenticated using (true);
drop policy if exists p_dex on public.pokedex_entries; create policy p_dex on public.pokedex_entries for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists p_enc on public.encounters;      create policy p_enc on public.encounters for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists p_pms on public.pk_move_sync;    create policy p_pms on public.pk_move_sync for select to authenticated using (user_id = auth.uid());
drop policy if exists p_bag on public.bag_items;       create policy p_bag on public.bag_items for select to authenticated using (user_id = auth.uid());
drop policy if exists p_mev on public.mon_events;      create policy p_mev on public.mon_events for select to authenticated using (user_id = auth.uid());
revoke all on public.monsters, public.pokedex_entries, public.encounters, public.pk_move_sync, public.bag_items, public.mon_events from anon, authenticated;
revoke all on sequence public.mon_events_id_seq from anon, authenticated;
grant select on public.monsters, public.pokedex_entries, public.encounters, public.pk_move_sync, public.bag_items, public.mon_events to authenticated;

-- ---------- funções internas ----------
create or replace function public.pk_dex_mark(_uid uuid, _species int, _caught boolean) returns void
language sql security definer set search_path = public, extensions as $$
  insert into pokedex_entries(user_id, species_id, caught_at) values (_uid, _species, case when _caught then now() end)
  on conflict (user_id, species_id) do update set caught_at = coalesce(pokedex_entries.caught_at, excluded.caught_at)
$$;

create or replace function public.pk_refresh_mascot(_uid uuid) returns void
language sql security definer set search_path = public, extensions as $$
  update characters ch set mascot = (select jsonb_build_object('id', m.id, 'species', m.species_id, 'outfit', m.outfit, 'level', m.level)
                                      from monsters m where m.id = (ch.mascot->>'id')::uuid and m.user_id = _uid)
   where ch.user_id = _uid and ch.mascot is not null
$$;

create or replace function public.pk_new_monster(_uid uuid, _species int, _lvl int) returns public.monsters
language plpgsql security definer set search_path = public, extensions as $$
declare r monsters; p pokemon;
begin
  select * into p from pokemon where id = _species;
  if (select count(*) from monsters where user_id = _uid) >= (public.pk_cfg()->'storage'->>'max_monsters')::int then
    raise exception 'Sua coleção está cheia (% Pokémon). Solte algum antes de capturar outro.', public.pk_cfg()->'storage'->>'max_monsters';
  end if;
  insert into monsters(user_id, species_id, level, exp, dv_atk, dv_def, dv_spd, dv_spc, moves, caught_species)
  values (_uid, _species, _lvl, public.pk_exp_for(p.growth_rate, _lvl), floor(random() * 16), floor(random() * 16), floor(random() * 16), floor(random() * 16),
          public.pk_moves_at(_species, _lvl), _species)
  returning * into r;
  perform public.pk_dex_mark(_uid, _species, true);
  return r;
end $$;

-- dá XP a um Pokémon: sobe de nível, aprende ataques e avisa evoluções (sem evoluir sozinho)
create or replace function public.pk_give_xp(_mon uuid, _xp int, _source text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare m monsters; p pokemon; newlvl int; lv int; mv int; ev record;
begin
  if _xp <= 0 then return; end if;
  select * into m from monsters where id = _mon for update;
  if m.id is null or m.level >= 100 then return; end if;
  select * into p from pokemon where id = m.species_id;
  m.exp := least(m.exp + _xp, public.pk_exp_for(p.growth_rate, 100));
  newlvl := m.level;
  while newlvl < 100 and m.exp >= public.pk_exp_for(p.growth_rate, newlvl + 1) loop newlvl := newlvl + 1; end loop;
  if newlvl > m.level then
    insert into mon_events(user_id, mon_id, kind, data) values (m.user_id, m.id, 'nivel', jsonb_build_object('species', m.species_id, 'from', m.level, 'to', newlvl, 'source', _source));
    for lv in m.level + 1 .. newlvl loop
      for mv in select move_id from pk_learnset where species_id = m.species_id and level = lv order by move_id loop
        if mv = any(m.moves) or mv = any(m.pending_moves) then continue; end if;
        if cardinality(m.moves) < 4 then
          m.moves := m.moves || mv;
          insert into mon_events(user_id, mon_id, kind, data) values (m.user_id, m.id, 'golpe', jsonb_build_object('species', m.species_id, 'move', mv, 'learned', true));
        else
          m.pending_moves := m.pending_moves || mv;
          insert into mon_events(user_id, mon_id, kind, data) values (m.user_id, m.id, 'golpe', jsonb_build_object('species', m.species_id, 'move', mv, 'learned', false));
        end if;
      end loop;
    end loop;
    for ev in select * from pk_evolutions where from_id = m.species_id and method = 'nivel' and level > m.level and level <= newlvl loop
      insert into mon_events(user_id, mon_id, kind, data) values (m.user_id, m.id, 'evolucao', jsonb_build_object('species', m.species_id, 'to', ev.to_id));
    end loop;
  end if;
  update monsters set exp = m.exp, level = newlvl, moves = m.moves, pending_moves = m.pending_moves where id = m.id;
  if newlvl > m.level then perform public.pk_refresh_mascot(m.user_id); end if;
end $$;

-- sorteia a espécie de um encontro (sempre a forma inicial da linha evolutiva)
create or replace function public.pk_pick_species(_region text) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.pk_cfg()->'encounter'; tps text[] := public.pk_region_types(_region); pick int;
begin
  with pool as (
    select p.id, (coalesce((c->'rarity_weight'->>public.pk_rarity(p.catch_rate))::numeric, 1)
                  * case when p.g1_type1 = any(tps) or p.g1_type2 = any(tps) then coalesce((c->>'region_bonus')::numeric, 1) else 1 end) as w
    from pokemon p
    where p.base_form = p.id and p.catch_rate is not null
      and (coalesce((c->>'legendaries')::boolean, false) or p.id not in (144, 145, 146, 150, 151))),
  acc as (select id, sum(w) over (order by id) as hi, sum(w) over () as tot from pool)
  select id into pick from acc where hi >= random() * tot order by hi limit 1;
  return pick;
end $$;

-- ---------- funções chamadas pelo site ----------
-- Depois de andar: transforma cada movimentação nova em XP para a equipe e em um encontro.
-- Pode ser chamada quantas vezes quiser: cada movimentação só conta uma vez.
create or replace function public.pk_sync() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.pk_cfg(); dm record; pool int; team uuid[]; each_xp int; mid uuid;
  sp int; lv int; maxd int; nd board_nodes; enc encounters; start_at timestamptz := coalesce((public.cfg()->>'pk_start_at')::timestamptz, now());
begin
  select max(dist) into maxd from board_nodes;
  for dm in select d.* from daily_moves d where d.user_id = uid and d.created_at >= start_at
             and not exists (select 1 from pk_move_sync s where s.move_id = d.id) order by d.created_at loop
    -- XP dos Pokémon da equipe: dividido igualmente
    pool := (c->'xp'->>'move_base')::int + (c->'xp'->>'per_step')::int * coalesce(dm.base_steps, 0)
          + (c->'xp'->>'per_mode')::int * (select count(*) from jsonb_each(case when jsonb_typeof(dm.modes->'modes') = 'object' then dm.modes->'modes' else dm.modes end) e
                                           where jsonb_typeof(e.value) = 'object' and coalesce((e.value->>'solved')::boolean, false));
    select array_agg(id order by team_slot) into team from monsters where user_id = uid and team_slot is not null;
    insert into pk_move_sync(move_id, user_id, xp_pool) values (dm.id, uid, case when team is null then 0 else pool end);
    if team is not null then
      each_xp := greatest(1, pool / cardinality(team));
      foreach mid in array team loop perform public.pk_give_xp(mid, each_xp, 'tabuleiro'); end loop;
    end if;
    -- encontro na casa onde parou (o anterior que ficou aberto foge)
    update encounters set status = 'fugiu', resolved_at = now() where user_id = uid and status = 'aberto';
    select * into nd from board_nodes where id = dm.to_node;
    sp := public.pk_pick_species(nd.region);
    lv := least(100, greatest(2, (c->'encounter'->>'level_min')::int
                + floor((1 - coalesce(nd.dist, maxd)::numeric / greatest(maxd, 1)) * (c->'encounter'->>'level_span')::int)::int
                + floor(random() * ((c->'encounter'->>'level_spread')::int + 1))::int));
    insert into encounters(user_id, move_id, node, species_id, level, throws_left)
    values (uid, dm.id, dm.to_node, sp, lv, (c->'capture'->>'throws')::int) on conflict (move_id) do nothing;
    perform public.pk_dex_mark(uid, sp, false);
  end loop;
  select * into enc from encounters where user_id = uid and status = 'aberto' order by created_at desc limit 1;
  return jsonb_build_object('encounter', case when enc.id is null then null else to_jsonb(enc) end,
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.id) from mon_events e where e.user_id = uid and not e.seen), '[]'::jsonb));
end $$;

-- Jogar uma Poké Bola. Chance calculada aqui, com a fórmula da 1ª geração para vida cheia:
--   passa 1: sorteio de 0 a "range" da bola <= taxa de captura da espécie
--   passa 2: sorteio de 0 a 255 <= "factor" convertido (vida cheia: 255*4/factor)
create or replace function public.encounter_throw(_id uuid, _ball text default 'poke') returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); e encounters; p pokemon; b jsonb := public.pk_cfg()->'capture'->'balls'->_ball;
  r1 int; f int; caught boolean; shakes int; m monsters; have int;
begin
  if b is null then raise exception 'Bola inválida.'; end if;
  select * into e from encounters where id = _id and user_id = uid for update;
  if e.id is null then raise exception 'Encontro não encontrado.'; end if;
  if e.status <> 'aberto' then raise exception 'Esse encontro já terminou.'; end if;
  if (b->>'price')::int > 0 then
    select qty into have from bag_items where user_id = uid and item = _ball || '_ball' for update;
    if coalesce(have, 0) < 1 then raise exception 'Você não tem %.', b->>'name'; end if;
    update bag_items set qty = qty - 1 where user_id = uid and item = _ball || '_ball';
  end if;
  select * into p from pokemon where id = e.species_id;
  r1 := floor(random() * ((b->>'range')::int + 1));
  f := least(255, floor(255 * 4 / (b->>'factor')::numeric))::int;
  caught := r1 <= p.catch_rate and floor(random() * 256) <= f;
  if caught then
    m := public.pk_new_monster(uid, e.species_id, e.level);
    update encounters set status = 'capturado', throws_left = throws_left - 1, mon_id = m.id, resolved_at = now() where id = e.id;
    insert into event_log(user_id, kind, message) select uid, 'captura', ch.name || ' capturou um ' || p.name || ' (Nv ' || e.level || ')!' from characters ch where ch.user_id = uid;
    return jsonb_build_object('caught', true, 'shakes', 3, 'monster', to_jsonb(m), 'throws_left', e.throws_left - 1);
  end if;
  shakes := case when r1 > p.catch_rate then 0 else 1 + floor(random() * 2)::int end;
  update encounters set throws_left = throws_left - 1,
         status = case when throws_left - 1 <= 0 then 'fugiu' else status end,
         resolved_at = case when throws_left - 1 <= 0 then now() end
   where id = e.id returning * into e;
  return jsonb_build_object('caught', false, 'shakes', shakes, 'throws_left', e.throws_left, 'fled', e.status = 'fugiu');
end $$;

create or replace function public.encounter_skip(_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active();
begin
  update encounters set status = 'recusado', resolved_at = now() where id = _id and user_id = uid and status = 'aberto';
end $$;

-- Equipe: lista ordenada de até 6 Pokémon do próprio jogador (substitui a equipe inteira de uma vez)
create or replace function public.mon_team_set(_ids uuid[]) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); n int := coalesce(cardinality(_ids), 0); i int;
begin
  if n > 6 then raise exception 'A equipe tem no máximo 6 Pokémon.'; end if;
  if n <> (select count(distinct x) from unnest(coalesce(_ids, '{}')) x) then raise exception 'Pokémon repetido na equipe.'; end if;
  if n <> (select count(*) from monsters where user_id = uid and id = any(coalesce(_ids, '{}'))) then raise exception 'Só dá para usar Pokémon da sua coleção.'; end if;
  update monsters set team_slot = null where user_id = uid and team_slot is not null;
  for i in 1 .. n loop update monsters set team_slot = i where id = _ids[i] and user_id = uid; end loop;
end $$;

create or replace function public.mon_set_mascot(_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active();
begin
  if _id is null then update characters set mascot = null where user_id = uid; return; end if;
  if not exists (select 1 from monsters where id = _id and user_id = uid) then raise exception 'Esse Pokémon não é seu.'; end if;
  update characters set mascot = jsonb_build_object('id', _id) where user_id = uid;
  perform public.pk_refresh_mascot(uid);
end $$;

-- Evoluir (o jogador escolhe a hora; adiar é só não chamar esta função)
create or replace function public.mon_evolve(_id uuid, _to int) returns public.monsters
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); m monsters; ev pk_evolutions; have int; mv int; tp pokemon;
begin
  select * into m from monsters where id = _id and user_id = uid for update;
  if m.id is null then raise exception 'Esse Pokémon não é seu.'; end if;
  select * into ev from pk_evolutions where from_id = m.species_id and to_id = _to;
  if ev.from_id is null then raise exception 'Essa evolução não existe.'; end if;
  if ev.method = 'troca' then raise exception 'Essa evolução acontece por troca entre jogadores, que ainda não existe no Pokegames.'; end if;
  if ev.method = 'nivel' and m.level < ev.level then raise exception 'Precisa chegar ao nível %.', ev.level; end if;
  if ev.method = 'pedra' then
    select qty into have from bag_items where user_id = uid and item = ev.item for update;
    if coalesce(have, 0) < 1 then raise exception 'Você precisa de uma pedra para essa evolução.'; end if;
    update bag_items set qty = qty - 1 where user_id = uid and item = ev.item;
  end if;
  select * into tp from pokemon where id = _to;
  m.species_id := _to;
  -- ataques que a nova espécie aprende exatamente no nível atual
  for mv in select move_id from pk_learnset where species_id = _to and level = m.level loop
    if mv = any(m.moves) then continue; end if;
    if cardinality(m.moves) < 4 then m.moves := m.moves || mv; else m.pending_moves := m.pending_moves || mv; end if;
  end loop;
  update monsters set species_id = m.species_id, moves = m.moves, pending_moves = m.pending_moves where id = m.id returning * into m;
  perform public.pk_dex_mark(uid, _to, true);
  perform public.pk_refresh_mascot(uid);
  insert into event_log(user_id, kind, message) select uid, 'evolucao', ch.name || ': ' || (select name from pokemon where id = ev.from_id) || ' evoluiu para ' || tp.name || '!' from characters ch where ch.user_id = uid;
  return m;
end $$;

-- Aprender um ataque pendente: _forget = posição (1 a 4) a esquecer, ou null para desistir do ataque
create or replace function public.mon_learn(_id uuid, _move int, _forget int) returns public.monsters
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); m monsters;
begin
  select * into m from monsters where id = _id and user_id = uid for update;
  if m.id is null then raise exception 'Esse Pokémon não é seu.'; end if;
  if not (_move = any(m.pending_moves)) then raise exception 'Esse ataque não está esperando para ser aprendido.'; end if;
  if _forget is not null then
    if _forget < 1 or _forget > cardinality(m.moves) then raise exception 'Escolha um ataque para esquecer.'; end if;
    m.moves[_forget] := _move;
  end if;
  update monsters set moves = m.moves, pending_moves = array_remove(m.pending_moves, _move) where id = m.id returning * into m;
  return m;
end $$;

create or replace function public.mon_release(_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active();
begin
  if not exists (select 1 from monsters where id = _id and user_id = uid) then raise exception 'Esse Pokémon não é seu.'; end if;
  if exists (select 1 from characters where user_id = uid and mascot->>'id' = _id::text) then update characters set mascot = null where user_id = uid; end if;
  delete from monsters where id = _id and user_id = uid;
end $$;

create or replace function public.mon_events_seen() returns void
language sql security definer set search_path = public, extensions as $$
  update mon_events set seen = true where user_id = auth.uid() and not seen
$$;

-- Comprar bolas e pedras (bolsa)
create or replace function public.pk_buy(_item text, _qty int default 1) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.pk_cfg(); price int; me characters;
begin
  if _qty is null or _qty < 1 or _qty > 20 then raise exception 'Quantidade inválida.'; end if;
  if _item like '%\_ball' and c->'capture'->'balls' ? replace(_item, '_ball', '') then price := (c->'capture'->'balls'->replace(_item, '_ball', '')->>'price')::int;
  elsif _item in ('pedra_fogo','pedra_agua','pedra_trovao','pedra_folha','pedra_lua') then price := (c->'stones'->>'price')::int;
  else raise exception 'Item inválido.'; end if;
  if price <= 0 then raise exception 'Esse item é grátis.'; end if;
  select * into me from characters where user_id = uid for update;
  if me.coins < price * _qty then raise exception 'Moedas insuficientes.'; end if;
  update characters set coins = coins - price * _qty where id = me.id;
  insert into bag_items(user_id, item, qty) values (uid, _item, _qty) on conflict (user_id, item) do update set qty = bag_items.qty + _qty;
  return jsonb_build_object('item', _item, 'qty', (select qty from bag_items where user_id = uid and item = _item), 'coins', me.coins - price * _qty);
end $$;

-- Roupas de Pokémon: compra (sem vestir o herói) e vestir/tirar num Pokémon
create or replace function public.pk_cosmetic_buy(_item text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters; it shop_items;
begin
  select * into it from shop_items where id = _item and slot like 'pk\_%';
  if it.id is null then raise exception 'Item inexistente.'; end if;
  select * into me from characters where user_id = uid for update;
  if _item = any(me.owned_items) then raise exception 'Você já tem esse item.'; end if;
  if me.level < it.min_level then raise exception 'Precisa do nível % para comprar.', it.min_level; end if;
  if me.coins < it.price then raise exception 'Moedas insuficientes.'; end if;
  update characters set coins = coins - it.price, owned_items = array_append(owned_items, _item) where id = me.id;
end $$;

create or replace function public.mon_equip(_id uuid, _slot text, _item text) returns public.monsters
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); m monsters; it shop_items; me characters;
begin
  if _slot not in ('pk_cabeca','pk_rosto','pk_pescoco','pk_aura') then raise exception 'Espaço inválido.'; end if;
  select * into m from monsters where id = _id and user_id = uid for update;
  if m.id is null then raise exception 'Esse Pokémon não é seu.'; end if;
  if _item is null then
    update monsters set outfit = outfit - _slot where id = m.id returning * into m;
  else
    select * into it from shop_items where id = _item;
    if it.id is null or it.slot <> _slot then raise exception 'Esse item não vai nesse espaço.'; end if;
    select * into me from characters where user_id = uid;
    if not (_item = any(me.owned_items)) then raise exception 'Você ainda não tem esse item.'; end if;
    if it.data ? 'species' and not (it.data->'species' @> to_jsonb(m.species_id)) then raise exception 'Esse item não serve nessa espécie.'; end if;
    update monsters set outfit = outfit || jsonb_build_object(_slot, _item) where id = m.id returning * into m;
  end if;
  perform public.pk_refresh_mascot(uid);
  return m;
end $$;

-- ---------- catálogo inicial de roupas (desenhos originais em pixel, feitos por código) ----------
-- data.px: linhas de pixels; letras = cores da paleta data.pal; "." = vazio. Âncora: topo da cabeça (pk_cabeca),
-- olhos (pk_rosto), pescoço (pk_pescoco). data.species (opcional) limita as espécies.
insert into public.shop_items (id, name, slot, price, min_level, rarity, data) values
 ('pk_bone_vermelho', 'Boné vermelho', 'pk_cabeca', 0, 1, 'comum',
  '{"px": ["..rrrr..", ".rrrrrr.", "rrrrrrrr", "......kkkk"], "pal": {"r": "#D1453B", "k": "#7E2A22"}}'),
 ('pk_cartola', 'Cartola de mágico', 'pk_cabeca', 120, 1, 'incomum',
  '{"px": [".kkkkk.", ".kkkkk.", ".kkkkk.", ".rrrrr.", "kkkkkkk"], "pal": {"k": "#2A2236", "r": "#C0392B"}}'),
 ('pk_coroa', 'Coroa real', 'pk_cabeca', 300, 5, 'raro',
  '{"px": ["y.y.y.y", "yyyyyyy", "yryyyby"], "pal": {"y": "#F5C542", "r": "#D1453B", "b": "#4C9BE8"}}'),
 ('pk_chapeu_bruxa', 'Chapéu de bruxa', 'pk_cabeca', 200, 3, 'incomum',
  '{"px": ["....p..", "...pp..", "..ppp..", "..pppp.", ".pppppp", "ppyyyppp"], "pal": {"p": "#5B46A8", "y": "#E0B44C"}}'),
 ('pk_capacete_espacial', 'Capacete espacial', 'pk_cabeca', 350, 8, 'epico',
  '{"px": ["..wwww..", ".wcccwww", "wccccccw", "wccccccw", ".wwwwww."], "pal": {"w": "#E8ECF3", "c": "#8FD3F0"}}'),
 ('pk_oculos_escuros', 'Óculos escuros', 'pk_rosto', 80, 1, 'comum',
  '{"px": ["kkk.kkk", "kkkkkkk", ".k...k."], "pal": {"k": "#1B1626"}}'),
 ('pk_oculos_aviador', 'Óculos de aviador', 'pk_rosto', 150, 3, 'incomum',
  '{"px": ["ooo.ooo", "oyyoyyo", ".o...o."], "pal": {"o": "#8A5A2B", "y": "#F5D27A"}}'),
 ('pk_lenco_azul', 'Lenço azul', 'pk_pescoco', 60, 1, 'comum',
  '{"px": ["bbbbbbb", ".bbbbb.", "..bbb..", "...b..."], "pal": {"b": "#3E8FC4"}}'),
 ('pk_cachecol_torcida', 'Cachecol de torcida (verde e branco)', 'pk_pescoco', 120, 1, 'incomum',
  '{"px": ["gwgwgwgwg", "gwgwgwgwg", "......gw.", "......wg."], "pal": {"g": "#2E7D4A", "w": "#F4F1E8"}}'),
 ('pk_medalha', 'Medalha de campeão', 'pk_pescoco', 250, 5, 'raro',
  '{"px": ["r.....b", ".r...b.", "..ryb..", "..yyy..", "..yyy.."], "pal": {"r": "#D1453B", "b": "#3A5F9E", "y": "#F5C542"}}'),
 ('pk_aura_dourada', 'Aura dourada', 'pk_aura', 400, 10, 'epico', '{"glow": "#F5C542"}'),
 ('pk_aura_sombria', 'Aura sombria', 'pk_aura', 400, 10, 'epico', '{"glow": "#8A5BD6"}')
on conflict (id) do nothing;

-- ---------- permissões ----------
revoke execute on function public.pk_cfg(), public.pk_region_types(text), public.pk_rarity(int), public.pk_exp_for(text, int), public.pk_stat(int, int, int, boolean),
  public.pk_hp_dv(int, int, int, int), public.pk_moves_at(int, int), public.pk_dex_mark(uuid, int, boolean), public.pk_refresh_mascot(uuid),
  public.pk_new_monster(uuid, int, int), public.pk_give_xp(uuid, int, text), public.pk_pick_species(text) from public, anon, authenticated;
revoke execute on function public.pk_sync(), public.encounter_throw(uuid, text), public.encounter_skip(uuid), public.mon_team_set(uuid[]), public.mon_set_mascot(uuid),
  public.mon_evolve(uuid, int), public.mon_learn(uuid, int, int), public.mon_release(uuid), public.mon_events_seen(), public.pk_buy(text, int),
  public.pk_cosmetic_buy(text), public.mon_equip(uuid, text, text) from public, anon;
grant execute on function public.pk_sync(), public.encounter_throw(uuid, text), public.encounter_skip(uuid), public.mon_team_set(uuid[]), public.mon_set_mascot(uuid),
  public.mon_evolve(uuid, int), public.mon_learn(uuid, int, int), public.mon_release(uuid), public.mon_events_seen(), public.pk_buy(text, int),
  public.pk_cosmetic_buy(text), public.mon_equip(uuid, text, text) to authenticated;
-- regras de captura e XP para o site mostrar (só leitura)
create or replace function public.pk_rules() returns jsonb
language sql stable security definer set search_path = public, extensions as $$ select public.pk_cfg() $$;
revoke execute on function public.pk_rules() from public, anon;
grant execute on function public.pk_rules() to authenticated;
