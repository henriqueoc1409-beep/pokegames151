-- =====================================================================
-- POKEGAMES — Vila expandida (18 construções) e Guerras Pokémon entre vilas.
-- Pedido do dono em 21/10/2026 (plano em PLANO_VILA_E_GUERRAS.md, aprovado):
--   * guerra OPCIONAL: só ataca e só é atacado quem tem o Quartel e os dois esquadrões;
--   * 3 Pokémon de ataque e 3 de defesa; a defesa luta sozinha com o dono fora do jogo;
--   * combate automático com o MESMO motor de batalha da 1ª geração (bt_*), resolvido
--     inteiro no servidor numa única transação (não dá para processar duas vezes);
--   * saque limitado (o Cofre protege), danos temporários às construções, conserto pago
--     ou grátis depois de 3 dias, cura dos Pokémon paga ou grátis depois de 24 horas;
--   * XP para quem derruba, dentro do mesmo limite diário das batalhas;
--   * 8 construções novas e níveis novos para Muralha e Ferreiro.
-- Não apaga dados, não muda o motor de batalha nem as fórmulas de pontos e moedas do jogo.
-- Depende do 09, 11, 15, 16, 17, 18 e 24. Antes de rodar, faça a cópia de segurança.
-- =====================================================================

-- ---------- 1) regras (ficam no game_config, ajustáveis pelo admin) ----------
update public.game_config set config = jsonb_set(config, '{war}', '{
  "buildings": {
    "centro":     {"col": "center_level",   "name": "Centro da Vila",           "max": 6, "costs": [0, 600, 1400, 2800, 4500, 6500], "hero": [1, 1, 5, 10, 15, 20]},
    "cofre":      {"col": "vault_level",    "name": "Cofre",                    "max": 4, "costs": [400, 900, 1800, 3000], "cv": [1, 2, 3, 5], "protect": [300, 600, 1000, 1500]},
    "quartel":    {"col": "barracks_level", "name": "Quartel Pokémon",          "max": 3, "costs": [600, 1600, 3200], "cv": [1, 3, 5], "attacks": [1, 2, 3]},
    "defesa":     {"col": "dtower_level",   "name": "Torre de Defesa",          "max": 3, "costs": [700, 1500, 2800], "cv": [2, 3, 5], "bonus": [5, 10, 15], "req": {"quartel": 1}},
    "armadilhas": {"col": "traps_level",    "name": "Oficina de Armadilhas",    "max": 2, "costs": [600, 1300], "cv": [2, 4], "pct": [5, 10], "req": {"quartel": 1}},
    "vigia":      {"col": "watch_level",    "name": "Torre de Vigia",           "max": 3, "costs": [400, 1000, 2000], "cv": [1, 2, 4], "req": {"quartel": 1}},
    "centropk":   {"col": "wcenter_level",  "name": "Centro Pokémon de Guerra", "max": 4, "costs": [500, 1200, 2500, 4000], "cv": [1, 2, 4, 6], "disc": [10, 20, 30, 40], "req": {"quartel": 1}},
    "academia":   {"col": "academy_level",  "name": "Academia de Treinadores",  "max": 3, "costs": [800, 1800, 3500], "cv": [2, 4, 6], "req": {"quartel": 1}},
    "muralha":    {"col": "wall_level",     "name": "Muralha",                  "max": 3, "costs": [500, 900, 1600], "cv": [1, 2, 4], "reduce": [0, 15, 30]},
    "ferreiro":   {"col": "forge_level",    "name": "Oficina do Ferreiro",      "max": 3, "costs": [450, 1000, 2200], "cv": [1, 2, 4], "repair_disc": [0, 15, 30]}
  },
  "base_protect": 100, "loot_pct": 10, "loot_max": 150,
  "shield_hours": 24, "pair_hours": 72, "active_days": 7, "min_age_days": 3,
  "match_min": 75, "match_max": 135, "match_fill": 3, "max_turns": 60, "def_cap": 20,
  "repair_pct": 20, "repair_min": 20, "auto_fix_days": 3, "heal_coef": 1.5, "free_heal_hours": 24,
  "damage_pool": ["mina", "torre", "pomar", "ferreiro", "estabulo", "defesa", "armadilhas", "vigia", "centropk", "academia"]
}'::jsonb, true) where active and not (config ? 'war');

create or replace function public.war_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$ select coalesce(public.cfg()->'war', '{}'::jsonb) $$;

-- ---------- 2) colunas e tabelas novas (nada é apagado) ----------
alter table public.villages add column if not exists center_level   int not null default 1;
alter table public.villages add column if not exists vault_level    int not null default 0;
alter table public.villages add column if not exists barracks_level int not null default 0;
alter table public.villages add column if not exists dtower_level   int not null default 0;
alter table public.villages add column if not exists traps_level    int not null default 0;
alter table public.villages add column if not exists watch_level    int not null default 0;
alter table public.villages add column if not exists wcenter_level  int not null default 0;
alter table public.villages add column if not exists academy_level  int not null default 0;
alter table public.villages add column if not exists damaged        jsonb not null default '{}'::jsonb;  -- {"mina": {"at": ..., "fix": ...}}
alter table public.villages add column if not exists shield_until   timestamptz;
alter table public.villages add column if not exists atk_tactic     text not null default 'forte';
alter table public.villages add column if not exists def_tactic     text not null default 'forte';

-- quem já tem vila começa com o Centro no nível do que já construiu (ninguém perde nada)
update public.villages v set center_level = greatest(v.center_level, case when n <= 3 then 1 when n <= 6 then 2 when n <= 9 then 3 else 4 end)
from (select user_id, (mine_level > 0)::int + (tower_level > 0)::int + (catapult_level > 0)::int + (orchard_level > 0)::int + (forge_level > 0)::int
        + (stable_level > 0)::int + (tavern_level > 0)::int + (wall_level > 0)::int + (well_level > 0)::int + (arena_level > 0)::int as n from public.villages) x
where x.user_id = v.user_id;

-- vida de guerra de cada Pokémon (em %), separada da batalha normal e do RPG
alter table public.monsters add column if not exists war_hp      int not null default 100;
alter table public.monsters add column if not exists war_hurt_at timestamptz;

-- batalhas de guerra usam a mesma tabela e o mesmo motor das batalhas normais
alter table public.battles add column if not exists mode text not null default 'duelo';

create table if not exists public.war_squads (
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       text not null check (role in ('ataque', 'defesa')),
  slot       int  not null check (slot between 1 and 3),
  monster_id uuid not null unique references public.monsters(id) on delete cascade,
  primary key (user_id, role, slot)
);

create table if not exists public.wars (
  id          uuid primary key default gen_random_uuid(),
  attacker    uuid not null references auth.users(id) on delete cascade,
  defender    uuid not null references auth.users(id) on delete cascade,
  att_name    text, def_name text,
  battle_id   uuid references public.battles(id) on delete set null,
  winner      uuid,
  att_power   int, def_power int,
  loot        int not null default 0,
  damaged     text[] not null default '{}',
  att_lost    int not null default 0,     -- Pokémon do atacante que desmaiaram
  def_lost    int not null default 0,
  details     jsonb not null default '{}'::jsonb,
  def_seen    boolean not null default false,
  created_at  timestamptz not null default now(),
  check (attacker <> defender)
);
create index if not exists wars_att on public.wars (attacker, created_at desc);
create index if not exists wars_def on public.wars (defender, created_at desc);

alter table public.war_squads enable row level security;
alter table public.wars enable row level security;
drop policy if exists p_wsq on public.war_squads; create policy p_wsq on public.war_squads for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists p_wars on public.wars;      create policy p_wars on public.wars for select to authenticated using (auth.uid() in (attacker, defender) or public.is_admin());
revoke all on public.war_squads, public.wars from anon, authenticated;
grant select on public.war_squads, public.wars to authenticated;
do $$ begin
  begin alter publication supabase_realtime add table public.wars; exception when duplicate_object then null; end;
end $$;

-- ---------- 3) utilidades da vila ----------
-- coluna de nível de cada construção (antigas e novas)
create or replace function public.vl_col(_k text) returns text
language sql immutable as $$
  select case _k when 'mina' then 'mine_level' when 'torre' then 'tower_level' when 'catapulta' then 'catapult_level' when 'pomar' then 'orchard_level'
    when 'ferreiro' then 'forge_level' when 'estabulo' then 'stable_level' when 'taverna' then 'tavern_level' when 'muralha' then 'wall_level'
    when 'poco' then 'well_level' when 'arena' then 'arena_level' when 'centro' then 'center_level' when 'cofre' then 'vault_level'
    when 'quartel' then 'barracks_level' when 'defesa' then 'dtower_level' when 'armadilhas' then 'traps_level' when 'vigia' then 'watch_level'
    when 'centropk' then 'wcenter_level' when 'academia' then 'academy_level' end
$$;
-- nível que vale de verdade (construção danificada não funciona)
create or replace function public.vl_level(_v public.villages, _k text, _raw boolean default false) returns int
language sql stable as $$
  select case when _v.user_id is null then 0 when not _raw and _v.damaged ? _k then 0 else coalesce((to_jsonb(_v)->>public.vl_col(_k))::int, 0) end
$$;
-- número de uma lista da regra para um nível (nível 0 = 0)
create or replace function public.war_num(_k text, _field text, _lvl int) returns numeric
language sql stable security definer set search_path = public, extensions as $$
  select case when coalesce(_lvl, 0) <= 0 then 0 else coalesce((public.war_cfg()->'buildings'->_k->_field->>(_lvl - 1))::numeric, 0) end
$$;
-- preço do nível atual de uma construção (base do conserto)
create or replace function public.vl_price(_k text, _lvl int) returns int
language sql stable security definer set search_path = public, extensions as $$
  select case
    when _lvl <= 0 then 0
    when public.war_cfg()->'buildings' ? _k then public.war_num(_k, 'costs', _lvl)::int
    when _k = 'mina' then (public.cfg()->'mine_costs'->>(_lvl - 1))::int
    when _k = 'torre' then (public.cfg()->>'tower_cost')::int
    when _k = 'pomar' then (public.cfg()->>'orchard_cost')::int
    when _k = 'estabulo' then (public.cfg()->>'stable_cost')::int
    else 0 end
$$;
-- coluna de "coletado em" das construções que produzem
create or replace function public.vl_collect_col(_k text) returns text
language sql immutable as $$
  select case _k when 'mina' then 'mine_collected_at' when 'torre' then 'tower_collected_at' when 'pomar' then 'orchard_collected_at'
    when 'ferreiro' then 'forge_collected_at' when 'estabulo' then 'stable_collected_at' end
$$;

-- tira o dano de uma construção; o tempo parada não conta para a produção
create or replace function public.vl_unbreak(_uid uuid, _k text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v villages; col text := public.vl_collect_col(_k); d int; tz text := coalesce(public.cfg()->>'timezone', 'America/Sao_Paulo');
begin
  select * into v from villages where user_id = _uid;
  if not (v.damaged ? _k) then return; end if;
  d := public.game_today() - ((v.damaged->_k->>'at')::timestamptz at time zone tz)::date;
  if col is not null and d > 0 then
    execute format('update villages set %I = %I + $2 where user_id = $1 and %I is not null', col, col, col) using _uid, d;
  end if;
  update villages set damaged = damaged - _k where user_id = _uid;
end $$;

-- conserta de graça o que já passou dos 3 dias
create or replace function public.vl_autofix(_uid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v villages; k text;
begin
  select * into v from villages where user_id = _uid;
  if v.user_id is null then return; end if;
  for k in select key from jsonb_each(v.damaged) where (value->>'fix')::timestamptz <= now() loop
    perform public.vl_unbreak(_uid, k);
  end loop;
end $$;

-- cura grátis de quem já passou das 24 horas
create or replace function public.war_free_heal(_uid uuid) returns void
language sql security definer set search_path = public, extensions as $$
  update monsters set war_hp = 100, war_hurt_at = null
   where user_id = _uid and war_hurt_at is not null
     and war_hurt_at <= now() - make_interval(hours => coalesce((public.war_cfg()->>'free_heal_hours')::int, 24));
$$;

-- produção da vila: construção danificada para de produzir (o que juntou antes do dano continua lá)
create or replace function public.village_pending(v public.villages) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare c jsonb := cfg(); t date := game_today(); md int := (cfg()->>'collect_max_days')::int; tz text := coalesce(cfg()->>'timezone', 'America/Sao_Paulo');
  e_mine date; e_tower date; e_orch date; e_forge date; e_stab date;
begin
  e_mine  := case when v.damaged ? 'mina'     then least(t, ((v.damaged->'mina'->>'at')::timestamptz at time zone tz)::date) else t end;
  e_tower := case when v.damaged ? 'torre'    then least(t, ((v.damaged->'torre'->>'at')::timestamptz at time zone tz)::date) else t end;
  e_orch  := case when v.damaged ? 'pomar'    then least(t, ((v.damaged->'pomar'->>'at')::timestamptz at time zone tz)::date) else t end;
  e_forge := case when v.damaged ? 'ferreiro' then least(t, ((v.damaged->'ferreiro'->>'at')::timestamptz at time zone tz)::date) else t end;
  e_stab  := case when v.damaged ? 'estabulo' then least(t, ((v.damaged->'estabulo'->>'at')::timestamptz at time zone tz)::date) else t end;
  return jsonb_build_object(
    'coins',   case when v.mine_level > 0 then least(md, greatest(0, e_mine - coalesce(v.mine_collected_at, t))) * (c->'mine_rates'->>(v.mine_level - 1))::int else 0 end,
    'hints',   case when v.tower_level > 0 then least((c->>'tower_max')::int, greatest(0, (e_tower - coalesce(v.tower_collected_at, t)) / (c->>'tower_days')::int)) else 0 end,
    'xp',      case when v.orchard_level > 0 then least(md, greatest(0, e_orch - coalesce(v.orchard_collected_at, t))) * (c->>'orchard_xp')::int else 0 end,
    'retries', case when v.forge_level > 0 then least((c->>'forge_max')::int, greatest(0, (e_forge - coalesce(v.forge_collected_at, t)) / (c->>'forge_days')::int)) else 0 end,
    'steps',   case when v.stable_level > 0 then least((c->>'stable_max')::int, greatest(0, (e_stab - coalesce(v.stable_collected_at, t)) / (c->>'stable_days')::int)) else 0 end,
    'until',   jsonb_build_object('mina', e_mine, 'torre', e_tower, 'pomar', e_orch, 'ferreiro', e_forge, 'estabulo', e_stab));
end $$;

-- coleta (versão do 11 + construções danificadas guardam a data em que pararam)
create or replace function public.village_collect() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); v villages; p jsonb; me characters;
begin
  perform public.vl_autofix(uid);
  select * into v from villages where user_id = uid for update;
  if v.user_id is null then raise exception 'Construa algo na sua vila primeiro.'; end if;
  if v.mud > 0 then raise exception 'Sua vila está coberta de lama. Limpe antes de coletar.'; end if;
  p := public.village_pending(v);
  if (p->>'coins')::int + (p->>'hints')::int + (p->>'xp')::int + (p->>'retries')::int + (p->>'steps')::int = 0 then
    raise exception 'Ainda não há nada para coletar.';
  end if;
  update villages set
    mine_collected_at    = case when v.mine_level > 0 then (p->'until'->>'mina')::date else mine_collected_at end,
    tower_collected_at   = case when (p->>'hints')::int > 0 then (p->'until'->>'torre')::date else tower_collected_at end,
    orchard_collected_at = case when v.orchard_level > 0 then (p->'until'->>'pomar')::date else orchard_collected_at end,
    forge_collected_at   = case when (p->>'retries')::int > 0 then (p->'until'->>'ferreiro')::date else forge_collected_at end,
    stable_collected_at  = case when (p->>'steps')::int > 0 then (p->'until'->>'estabulo')::date else stable_collected_at end
  where user_id = uid;
  select * into me from characters where user_id = uid for update;
  update characters set
    coins = coins + (p->>'coins')::int, hints = hints + (p->>'hints')::int, retries = retries + (p->>'retries')::int,
    bonus_steps = bonus_steps + (p->>'steps')::int,
    xp_total = xp_total + (p->>'xp')::int, level = public.level_for_xp(me.xp_total + (p->>'xp')::int)
  where id = me.id;
  return p - 'until';
end $$;

-- estado da vila (versão do 11 + conserto automático vencido e preços de conserto)
create or replace function public.village_state(_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); t date := public.game_today(); who uuid; v villages; ch characters; rep jsonb := '{}'::jsonb; k text;
begin
  who := coalesce(_user, uid);
  insert into villages(user_id) select who where exists (select 1 from characters where user_id = who) on conflict do nothing;
  perform public.vl_autofix(who);
  select * into v from villages where user_id = who;
  select * into ch from characters where user_id = who;
  if v.user_id is null then raise exception 'Jogador não encontrado.'; end if;
  for k in select key from jsonb_each(v.damaged) loop rep := rep || jsonb_build_object(k, public.vl_repair_cost(v, k)); end loop;
  return to_jsonb(v) || jsonb_build_object(
    'mine', who = uid, 'name', ch.name, 'class', ch.class, 'level', ch.level, 'outfit', ch.outfit,
    'pending', case when who = uid then public.village_pending(v) - 'until' end,
    'catapult_ready', case when who = uid then v.catapult_level > 0 and (v.catapult_used_at is null or v.catapult_used_at <= t - (c->>'catapult_days')::int) end,
    'catapult_next', case when v.catapult_used_at is not null then v.catapult_used_at + (c->>'catapult_days')::int end,
    'wall_ready', v.wall_level > 0 and (v.wall_used_at is null or v.wall_used_at <= t - (c->>'wall_days')::int),
    'well_ready', v.well_level > 0 and (v.well_used_at is null or v.well_used_at <= t - (c->>'well_days')::int),
    'clean_cost', v.mud * (c->>'mud_clean_per_level')::int,
    'repair_costs', rep, 'atk_tactic', case when who = uid then v.atk_tactic end, 'def_tactic', case when who = uid then v.def_tactic end);
end $$;

create or replace function public.vl_repair_cost(_v public.villages, _k text) returns int
language sql stable security definer set search_path = public, extensions as $$
  select greatest(coalesce((public.war_cfg()->>'repair_min')::int, 20),
    ceil(public.vl_price(_k, public.vl_level(_v, _k, true)) * coalesce((public.war_cfg()->>'repair_pct')::numeric, 20) / 100
         * (1 - public.war_num('ferreiro', 'repair_disc', public.vl_level(_v, 'ferreiro')) / 100))::int)
$$;

-- ---------- 4) construir e melhorar (construções novas e níveis novos) ----------
create or replace function public.village_upgrade(_kind text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); b jsonb := public.war_cfg()->'buildings'->_kind; v villages; me characters; lvl int; nl int; cost int; need int; rk text; rv int; nm text;
begin
  if b is null then raise exception 'Construção inválida.'; end if;
  insert into villages(user_id) values (uid) on conflict do nothing;
  perform public.vl_autofix(uid);
  select * into v from villages where user_id = uid for update;
  select * into me from characters where user_id = uid for update;
  if v.damaged ? _kind then raise exception 'Essa construção está danificada. Conserte antes de melhorar.'; end if;
  lvl := public.vl_level(v, _kind, true); nl := lvl + 1;
  if nl > (b->>'max')::int then raise exception '% já está no nível máximo.', b->>'name'; end if;
  if _kind = 'centro' then
    need := coalesce((b->'hero'->>(nl - 1))::int, 1);
    if me.level < need then raise exception 'O Centro da Vila nível % pede herói nível %.', nl, need; end if;
  else
    need := coalesce((b->'cv'->>(nl - 1))::int, 1);
    if v.center_level < need then raise exception '% nível % pede o Centro da Vila nível %.', b->>'name', nl, need; end if;
    for rk, rv in select key, value::int from jsonb_each_text(coalesce(b->'req', '{}'::jsonb)) loop
      if public.vl_level(v, rk, true) < rv then raise exception '% pede % nível %.', b->>'name', public.war_cfg()->'buildings'->rk->>'name', rv; end if;
    end loop;
  end if;
  cost := coalesce((b->'costs'->>(nl - 1))::int, 0);
  if me.coins < cost then raise exception 'Isso custa % moedas.', cost; end if;
  update characters set coins = coins - cost where id = me.id;
  execute format('update villages set %I = $2 where user_id = $1', b->>'col') using uid, nl;
  if _kind = 'ferreiro' and lvl = 0 then update villages set forge_collected_at = public.game_today() where user_id = uid; end if;
  nm := case when lvl = 0 then 'construiu ' || (b->>'name') else 'melhorou ' || (b->>'name') || ' para o nível ' || nl end;
  insert into event_log(user_id, kind, message) values (uid, 'vila', me.name || ' ' || nm || '.');
  return public.village_state(null);
end $$;

-- consertar agora, pagando
create or replace function public.village_repair(_kind text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); v villages; me characters; cost int;
begin
  perform public.vl_autofix(uid);
  select * into v from villages where user_id = uid for update;
  if v.user_id is null or not (v.damaged ? _kind) then raise exception 'Essa construção não está danificada.'; end if;
  select * into me from characters where user_id = uid for update;
  cost := public.vl_repair_cost(v, _kind);
  if me.coins < cost then raise exception 'O conserto custa % moedas. Se preferir, ela se conserta sozinha em até 3 dias.', cost; end if;
  update characters set coins = coins - cost where id = me.id;
  perform public.vl_unbreak(uid, _kind);
  return public.village_state(null);
end $$;

-- ---------- 5) esquadrões, táticas e cura ----------
create or replace function public.war_squad_set(_role text, _ids uuid[]) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); n int := coalesce(cardinality(_ids), 0); i int;
begin
  if _role not in ('ataque', 'defesa') then raise exception 'Esquadrão inválido.'; end if;
  if not exists (select 1 from villages where user_id = uid and barracks_level > 0) then raise exception 'Construa o Quartel Pokémon para montar esquadrões.'; end if;
  if n > 3 then raise exception 'Cada esquadrão tem no máximo 3 Pokémon.'; end if;
  if n <> (select count(distinct x) from unnest(coalesce(_ids, '{}')) x) then raise exception 'Pokémon repetido no esquadrão.'; end if;
  if n <> (select count(*) from monsters where user_id = uid and id = any(coalesce(_ids, '{}'))) then raise exception 'Só dá para usar Pokémon da sua coleção.'; end if;
  if exists (select 1 from war_squads where user_id = uid and role <> _role and monster_id = any(coalesce(_ids, '{}'))) then
    raise exception 'Um Pokémon não pode ficar no ataque e na defesa ao mesmo tempo.'; end if;
  delete from war_squads where user_id = uid and role = _role;
  for i in 1 .. n loop insert into war_squads(user_id, role, slot, monster_id) values (uid, _role, i, _ids[i]); end loop;
end $$;

create or replace function public.war_tactic(_role text, _tactic text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); v villages;
begin
  if _tactic not in ('forte', 'segura') then raise exception 'Tática inválida.'; end if;
  select * into v from villages where user_id = uid for update;
  if _role = 'ataque' then
    if public.vl_level(v, 'academia') < 1 and _tactic <> 'forte' then raise exception 'A Academia de Treinadores nível 1 libera a tática do ataque.'; end if;
    update villages set atk_tactic = _tactic where user_id = uid;
  elsif _role = 'defesa' then
    if public.vl_level(v, 'academia') < 2 and _tactic <> 'forte' then raise exception 'A Academia de Treinadores nível 2 libera a tática da defesa.'; end if;
    update villages set def_tactic = _tactic where user_id = uid;
  else raise exception 'Esquadrão inválido.'; end if;
end $$;

create or replace function public.war_heal_cost(_uid uuid, _ids uuid[] default null) returns int
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(sum(greatest(1, ceil(m.level * (100 - m.war_hp) / 100.0 * coalesce((public.war_cfg()->>'heal_coef')::numeric, 1.5)
           * (1 - public.war_num('centropk', 'disc', public.vl_level(v, 'centropk')) / 100)))), 0)::int
  from monsters m left join villages v on v.user_id = m.user_id
  where m.user_id = _uid and m.war_hp < 100 and (_ids is null or m.id = any(_ids))
$$;

-- cura agora pagando (_ids null = todos os feridos)
create or replace function public.war_heal(_ids uuid[] default null) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters; cost int;
begin
  perform public.war_free_heal(uid);
  select * into me from characters where user_id = uid for update;
  cost := public.war_heal_cost(uid, _ids);
  if cost = 0 then raise exception 'Nenhum Pokémon precisa de cura.'; end if;
  if me.coins < cost then raise exception 'A cura custa % moedas. Se preferir, eles se recuperam sozinhos em 24 horas.', cost; end if;
  update characters set coins = coins - cost where id = me.id;
  update monsters set war_hp = 100, war_hurt_at = null where user_id = uid and war_hp < 100 and (_ids is null or id = any(_ids));
  return cost;
end $$;

-- ---------- 6) força e pareamento ----------
-- força de um Pokémon: soma dos atributos no nível dele / 10 (vida de guerra não entra)
create or replace function public.war_mon_power(_id uuid) returns numeric
language sql stable security definer set search_path = public, extensions as $$
  select ((x->>'maxhp')::int + (x->>'atk')::int + (x->>'def')::int + (x->>'spd')::int + (x->>'spc')::int) / 10.0 from (select public.bt_mon(_id) x) q
$$;
-- força de um esquadrão; a defesa soma os bônus da vila (até o limite) e o Centro da Vila
create or replace function public.war_power(_uid uuid, _role text) returns int
language plpgsql stable security definer set search_path = public, extensions as $$
declare v villages; p numeric; b numeric := 0;
begin
  select * into v from villages where user_id = _uid;
  select coalesce(sum(public.war_mon_power(monster_id)), 0) into p from war_squads where user_id = _uid and role = _role;
  if _role = 'defesa' then
    b := least(coalesce((public.war_cfg()->>'def_cap')::numeric, 20),
               public.war_num('defesa', 'bonus', public.vl_level(v, 'defesa')) + public.war_num('armadilhas', 'pct', public.vl_level(v, 'armadilhas')));
  end if;
  return round(p * (1 + b / 100) + 2 * coalesce(v.center_level, 1))::int;
end $$;

-- por que alguém NÃO pode ser alvo (null = pode)
create or replace function public.war_block(_att uuid, _def uuid) returns text
language plpgsql stable security definer set search_path = public, extensions as $$
declare w jsonb := public.war_cfg(); v villages; ch characters; t date := public.game_today();
begin
  if _att = _def then return 'você mesmo'; end if;
  select * into v from villages where user_id = _def;
  select * into ch from characters where user_id = _def;
  if ch.id is null or v.user_id is null or v.barracks_level < 1 then return 'não entrou na guerra'; end if;
  if (select count(*) from war_squads where user_id = _def and role = 'defesa') < 3 then return 'sem defesa montada'; end if;
  if ch.created_at > now() - make_interval(days => (w->>'min_age_days')::int) then return 'herói novo'; end if;
  if not exists (select 1 from daily_moves where user_id = _def and move_date >= t - (w->>'active_days')::int) then return 'não joga há dias'; end if;
  if coalesce(v.shield_until, '-infinity') > now() then return 'escudo'; end if;
  if exists (select 1 from wars where attacker = _att and defender = _def and created_at > now() - make_interval(hours => (w->>'pair_hours')::int)) then return 'atacou há pouco'; end if;
  return null;
end $$;

-- alvos possíveis, com o que a sua Torre de Vigia deixa ver
create or replace function public.war_targets() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); w jsonb := public.war_cfg(); mv villages; my int; watch int; r record; out jsonb := '[]'::jsonb; ok int := 0; info jsonb; dp int; bl text; ratio numeric;
begin
  select * into mv from villages where user_id = uid;
  my := public.war_power(uid, 'ataque'); watch := public.vl_level(mv, 'vigia');
  for r in
    select ch.user_id, ch.name, ch.level, ch.class, ch.outfit, v.center_level, v.shield_until, public.war_block(uid, ch.user_id) as bl,
           public.war_power(ch.user_id, 'defesa') as dp
      from characters ch join villages v on v.user_id = ch.user_id
     where ch.user_id <> uid and v.barracks_level > 0
  loop
    ratio := case when my > 0 then r.dp * 100.0 / my else 999 end;
    info := jsonb_build_object('user_id', r.user_id, 'name', r.name, 'level', r.level, 'class', r.class, 'outfit', r.outfit, 'center', r.center_level,
      'power', r.dp, 'ratio', round(ratio), 'block', r.bl, 'shield_until', r.shield_until,
      'fair', ratio between (w->>'match_min')::numeric and (w->>'match_max')::numeric);
    if watch >= 1 and r.bl is distinct from 'sem defesa montada' then
      info := info || jsonb_build_object('squad', (select jsonb_agg(jsonb_build_object('species', m.species_id,
              'level', case when watch >= 2 then m.level end,
              'hp', case when watch >= 2 then case when m.war_hurt_at is not null and m.war_hurt_at <= now() - make_interval(hours => (w->>'free_heal_hours')::int) then 100 else m.war_hp end end,
              'moves', case when watch >= 3 then (select jsonb_agg(pm.name order by u.o) from unnest(m.moves) with ordinality u(mid, o) join pk_moves pm on pm.id = u.mid) end) order by s.slot)
              from war_squads s join monsters m on m.id = s.monster_id where s.user_id = r.user_id and s.role = 'defesa'));
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
  return jsonb_build_object('power', my, 'watch', watch, 'targets', coalesce(out, '[]'::jsonb));
end $$;

-- ---------- 7) combate automático (mesmo motor das batalhas) ----------
-- escolhe o ataque: "forte" = mais dano esperado; "segura" = prefere golpes certeiros e põe o rival para dormir/paralisa
create or replace function public.war_pick(_s jsonb, _a int, _tactic text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare A jsonb := _s->'sides'->_a->'mons'->((_s->'sides'->_a->>'active')::int);
  D jsonb := _s->'sides'->(1 - _a)->'mons'->((_s->'sides'->(1 - _a)->>'active')::int);
  i int; mv pk_moves; sc numeric; bs numeric := -1; best int := -1; ratio numeric;
begin
  if coalesce(A->'fl'->>'charging', '') <> '' or coalesce((A->'fl'->>'recharge')::boolean, false) then return '{"kind": "forced", "value": 0}'; end if;
  for i in 0 .. jsonb_array_length(A->'moves') - 1 loop
    continue when (A->'moves'->i->>'pp')::int <= 0;
    select * into mv from pk_moves where id = (A->'moves'->i->>'id')::int;
    if mv.effect in ('TRANSFORM_EFFECT','MIMIC_EFFECT','DISABLE_EFFECT','CONVERSION_EFFECT','BIDE_EFFECT','SUBSTITUTE_EFFECT','SPLASH_EFFECT','SWITCH_AND_TELEPORT_EFFECT') or mv.id = 68 then sc := 0.01;
    elsif mv.effect = 'DREAM_EATER_EFFECT' and coalesce(D->>'status', '') <> 'SLP' then sc := 0.01;
    elsif mv.effect = 'OHKO_EFFECT' then sc := 30 * mv.accuracy / 100.0 * case when public.bt_eff(mv.type, D->>'t1', D->>'t2') = 0 then 0 else 1 end;
    elsif mv.effect = 'SPECIAL_DAMAGE_EFFECT' or mv.power = 1 then sc := 40 * case when public.bt_eff(mv.type, D->>'t1', D->>'t2') = 0 then 0 else 1 end;
    elsif mv.power > 1 then
      ratio := case when public.bt_physical(mv.type) then greatest(1, (A->>'atk')::numeric) / greatest(1, (D->>'def')::numeric)
                    else greatest(1, (A->>'spc')::numeric) / greatest(1, (D->>'spc')::numeric) end;
      sc := mv.power * public.bt_eff(mv.type, D->>'t1', D->>'t2') * case when mv.type in (A->>'t1', coalesce(A->>'t2', '')) then 1.5 else 1 end * ratio
            * case when _tactic = 'segura' then power(mv.accuracy / 100.0, 2) else mv.accuracy / 100.0 end;
      if mv.effect in ('CHARGE_EFFECT', 'FLY_EFFECT', 'HYPER_BEAM_EFFECT') then sc := sc * 0.6; end if;
      if mv.effect = 'EXPLODE_EFFECT' then sc := sc * 0.3; end if;
    else
      sc := case when _tactic = 'segura' and D->>'status' is null and mv.effect in ('SLEEP_EFFECT', 'PARALYZE_EFFECT') then 200 * mv.accuracy / 100.0 else 3 end;
    end if;
    sc := sc * (0.9 + random() * 0.2);
    if sc > bs then bs := sc; best := i; end if;
  end loop;
  if best < 0 then return '{"kind": "move", "value": -1}'; end if;   -- sem PP: Struggle
  return jsonb_build_object('kind', 'move', 'value', best);
end $$;

-- quem entra quando o Pokémon em campo desmaia: o próximo da fila, ou (Academia 3) o melhor contra o tipo do rival
create or replace function public.war_switch(_s jsonb, _a int, _smart boolean) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare D jsonb := _s->'sides'->(1 - _a)->'mons'->((_s->'sides'->(1 - _a)->>'active')::int); i int; m jsonb; sc numeric; bs numeric := -1; best int := -1;
begin
  for i in 0 .. jsonb_array_length(_s->'sides'->_a->'mons') - 1 loop
    m := _s->'sides'->_a->'mons'->i;
    continue when (m->>'hp')::int <= 0 or i = (_s->'sides'->_a->>'active')::int;
    if not _smart then return i; end if;
    sc := greatest(public.bt_eff(m->>'t1', D->>'t1', D->>'t2'), coalesce(public.bt_eff(m->>'t2', D->>'t1', D->>'t2'), 0))
          / greatest(0.25, greatest(public.bt_eff(D->>'t1', m->>'t1', m->>'t2'), coalesce(public.bt_eff(D->>'t2', m->>'t1', m->>'t2'), 0)));
    if sc > bs then bs := sc; best := i; end if;
  end loop;
  return best;
end $$;

-- encerramento (versão do 18 + na guerra o relato vai para o Jornal pela função da guerra)
create or replace function public.bt_finish(_id uuid, _winner uuid, _reason text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b battles; c jsonb := public.pk_cfg(); k text; v int; owner uuid; limit_n int := (c->'xp'->>'battles_per_day')::int; wn text; ln text;
begin
  select * into b from battles where id = _id for update;
  if b.status <> 'ativa' then return; end if;
  update battles set status = 'encerrada', winner = _winner, end_reason = _reason, ended_at = now(), deadline = null where id = b.id;
  if b.rewarded then return; end if;
  -- XP dos Pokémon que derrubaram adversários, só nas primeiras batalhas do dia de cada dono (guerras contam no mesmo limite)
  for k, v in select key, value::int from jsonb_each_text(coalesce(b.state->'xp', '{}'::jsonb)) loop
    select user_id into owner from monsters where id = k::uuid;
    if owner is null then continue; end if;
    if (select count(*) from battles x where x.status = 'encerrada' and x.rewarded and owner in (x.p1, x.p2)
          and (x.ended_at at time zone coalesce(public.cfg()->>'timezone','America/Sao_Paulo'))::date = public.game_today()) >= limit_n then continue; end if;
    perform public.pk_give_xp(k::uuid, v, 'batalha');
  end loop;
  update battles set rewarded = true where id = b.id;
  if b.mode = 'guerra' then return; end if;
  select name into wn from characters where user_id = _winner;
  select name into ln from characters where user_id = case when _winner = b.p1 then b.p2 else b.p1 end;
  if _winner is not null then insert into event_log(user_id, kind, message) values (_winner, 'batalha', wn || ' venceu a batalha Pokémon contra ' || ln || '!'); end if;
end $$;

-- monta um lado da guerra a partir do esquadrão (vida de guerra atual; desmaiados ficam de fora)
create or replace function public.war_side(_uid uuid, _role text, _bonus numeric, _trap numeric) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare mons jsonb := '[]'::jsonb; r record; m jsonb; k int := 0;
begin
  for r in select m2.id, m2.war_hp from war_squads s join monsters m2 on m2.id = s.monster_id
            where s.user_id = _uid and s.role = _role and m2.war_hp > 0 order by s.slot loop
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

-- ---------- 8) atacar ----------
create or replace function public.war_attack(_target uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); w jsonb := public.war_cfg(); t date := public.game_today(); tz text := coalesce(public.cfg()->>'timezone', 'America/Sao_Paulo');
  av villages; dv villages; ach characters; dch characters; tg jsonb; s0 jsonb; s1 jsonb; b battles; it int := 0; side int; p jsonb; m jsonb;
  bonus numeric; trap numeric; cap numeric; atac text; dtac text; asmart boolean; dsmart boolean; winner uuid; pct0 numeric; pct1 numeric;
  att_lost int; def_lost int; prot int; loot int := 0; nd int; k text; pool text[]; dmg text[] := '{}'; red numeric; wr wars; i int; reason text;
begin
  if _target = uid then raise exception 'Você não pode atacar a própria vila.'; end if;
  -- trava as duas vilas sempre na mesma ordem (dois ataques ao mesmo tempo não passam juntos)
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
    prot := (w->>'base_protect')::int + public.war_num('cofre', 'protect', public.vl_level(dv, 'cofre'))::int;
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
                             'atk_tactic', atac, 'def_tactic', dtac))
  returning * into wr;
  reason := case when winner = uid then ach.name || ' invadiu a vila de ' || dch.name || ' e levou ' || loot || ' moedas!'
                 when winner = _target then 'A defesa de ' || dch.name || ' segurou o ataque de ' || ach.name || '!'
                 else ach.name || ' e ' || dch.name || ' empataram na guerra.' end;
  insert into event_log(user_id, kind, message) values (uid, 'guerra', reason);
  return to_jsonb(wr) || jsonb_build_object('message', reason);
end $$;

-- ---------- 9) tela da guerra ----------
create or replace function public.war_state() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); w jsonb := public.war_cfg(); v villages; t date := public.game_today(); tz text := coalesce(public.cfg()->>'timezone', 'America/Sao_Paulo');
begin
  perform public.war_free_heal(uid);
  perform public.vl_autofix(uid);
  select * into v from villages where user_id = uid;
  return jsonb_build_object(
    'cfg', w,
    'barracks', coalesce(v.barracks_level, 0), 'academy', public.vl_level(v, 'academia'), 'watch', public.vl_level(v, 'vigia'), 'wcenter', public.vl_level(v, 'centropk'),
    'atk_tactic', coalesce(v.atk_tactic, 'forte'), 'def_tactic', coalesce(v.def_tactic, 'forte'), 'shield_until', v.shield_until,
    'squads', jsonb_build_object(
      'ataque', coalesce((select jsonb_agg(monster_id order by slot) from war_squads where user_id = uid and role = 'ataque'), '[]'::jsonb),
      'defesa', coalesce((select jsonb_agg(monster_id order by slot) from war_squads where user_id = uid and role = 'defesa'), '[]'::jsonb)),
    'power_atk', public.war_power(uid, 'ataque'), 'power_def', public.war_power(uid, 'defesa'),
    'attacks_today', (select count(*) from wars where attacker = uid and (created_at at time zone tz)::date = t),
    'attacks_max', public.war_num('quartel', 'attacks', coalesce(v.barracks_level, 0))::int,
    'heal_cost', public.war_heal_cost(uid, null),
    'unseen', (select count(*) from wars where defender = uid and not def_seen),
    'wars', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (select * from wars where uid in (attacker, defender) order by created_at desc limit 30) x), '[]'::jsonb));
end $$;

create or replace function public.war_seen() returns void
language sql security definer set search_path = public, extensions as $$
  update wars set def_seen = true where defender = auth.uid() and not def_seen;
$$;

-- ---------- 10) Arena: guerras não aparecem para quem assiste (a defesa é segredo da Torre de Vigia) ----------
alter table public.arena_battles add column if not exists mode text;
create or replace function public.bt_arena_trigger() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  if new.mode = 'guerra' then return null; end if;
  perform public.arena_sync(new.id);
  return null;
end $$;

create or replace function public.arena_battle(_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); b battles; s jsonb; sides jsonb := '[]'::jsonb; i int; sd jsonb; seen int[]; mons jsonb; k int; m jsonb;
begin
  select * into b from battles where id = _id;
  if b.id is null or b.status not in ('ativa', 'encerrada') then raise exception 'Batalha não encontrada.'; end if;
  if b.mode = 'guerra' and uid not in (b.p1, b.p2) and not public.is_admin() then raise exception 'Batalha não encontrada.'; end if;
  s := b.state;
  for i in 0 .. 1 loop
    sd := s->'sides'->i;
    select array_agg(distinct x) into seen from (
      select 0 as x
      union select (l->>'switch')::int from jsonb_array_elements(b.log) t, jsonb_array_elements(t->'lines') l where (l->>'side')::int = i and l ? 'switch') q;
    mons := '[]'::jsonb;
    for k in 0 .. jsonb_array_length(sd->'mons') - 1 loop
      m := sd->'mons'->k;
      if b.status = 'encerrada' or k = any(seen) or k = (sd->>'active')::int then
        mons := mons || jsonb_build_array(public.arena_mon(m) || jsonb_build_object('known', true));
      else
        mons := mons || jsonb_build_array(jsonb_build_object('known', false, 'out', (m->>'hp')::int <= 0));
      end if;
    end loop;
    sides := sides || jsonb_build_object('user', sd->'user', 'name', sd->'name', 'active', sd->'active', 'need_switch', sd->'need_switch', 'mons', mons);
  end loop;
  return jsonb_build_object('id', b.id, 'p1', b.p1, 'p2', b.p2, 'status', b.status, 'turn', b.turn, 'phase', b.phase, 'mode', b.mode,
    'ready1', b.ready1, 'ready2', b.ready2, 'turn_at', b.turn_at, 'acted_at', b.acted_at, 'away1', b.away1, 'away2', b.away2,
    'winner', b.winner, 'end_reason', b.end_reason, 'started_at', b.started_at, 'ended_at', b.ended_at,
    'state', jsonb_build_object('sides', sides), 'log', b.log);
end $$;

-- soltar um Pokémon também o tira do esquadrão (a tabela já faz isso sozinha); nada mais muda

-- ---------- permissões ----------
revoke execute on function public.war_cfg(), public.vl_col(text), public.vl_level(public.villages, text, boolean), public.war_num(text, text, int),
  public.vl_price(text, int), public.vl_collect_col(text), public.vl_unbreak(uuid, text), public.vl_autofix(uuid), public.war_free_heal(uuid),
  public.vl_repair_cost(public.villages, text), public.war_heal_cost(uuid, uuid[]), public.war_mon_power(uuid), public.war_power(uuid, text),
  public.war_block(uuid, uuid), public.war_pick(jsonb, int, text), public.war_switch(jsonb, int, boolean), public.war_side(uuid, text, numeric, numeric),
  public.village_pending(public.villages)
  from public, anon, authenticated;
revoke execute on function public.village_collect(), public.village_state(uuid), public.village_upgrade(text), public.village_repair(text),
  public.war_squad_set(text, uuid[]), public.war_tactic(text, text), public.war_heal(uuid[]), public.war_targets(), public.war_attack(uuid),
  public.war_state(), public.war_seen(), public.arena_battle(uuid)
  from public, anon;
grant execute on function public.village_collect(), public.village_state(uuid), public.village_upgrade(text), public.village_repair(text),
  public.war_squad_set(text, uuid[]), public.war_tactic(text, text), public.war_heal(uuid[]), public.war_targets(), public.war_attack(uuid),
  public.war_state(), public.war_seen(), public.arena_battle(uuid)
  to authenticated;
