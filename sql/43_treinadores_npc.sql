-- =====================================================================
-- 43_treinadores_npc.sql
-- Pedido do dono em 22/10/2026 (lista de ideias, item 2): treinadores do jogo (NPCs) que desafiam
-- quem para em certas casas.
--   * Casa nova 🧢 Treinador (no lugar de algumas casas "Trilha"). Quem para nela enfrenta na hora um
--     treinador do jogo (Pescador, Montanhista, Caça-insetos...), com 3 Pokémon do tipo dele, no nível
--     médio da sua equipe. A luta é automática, com as mesmas regras das batalhas (o servidor escolhe
--     os golpes dos dois lados, como nas guerras), e a vida volta cheia depois.
--   * Venceu: moedas (30 + 2 por nível do treinador) e o XP de batalha para quem derrubou adversários.
--     Perdeu: não perde nada. Quem não tem Pokémon só leva uma bronca.
--   * Cada luta fica guardada em npc_fights (o jogador vê as dele; dá para ver o relato).
--   * Números em game_config.config.casas (npc_coins_base, npc_coins_per_level).
-- Depende do 42. Antes, faça a cópia de segurança.
-- =====================================================================

update public.game_config set config = jsonb_set(config, '{casas}',
  coalesce(config->'casas', '{}'::jsonb) || '{"npc_coins_base": 30, "npc_coins_per_level": 2}'::jsonb, true)
 where active and not (coalesce(config->'casas', '{}'::jsonb) ? 'npc_coins_base');

-- algumas casas "Trilha" viram Treinador (só na primeira vez)
with cand as (
  select id, row_number() over (order by id) rn from public.board_nodes
   where kind = 'normal' and dist between 10 and (select max(dist) - 6 from public.board_nodes)
)
update public.board_nodes b set kind = 'treinador'
  from cand c
 where b.id = c.id and c.rn % 11 = 5
   and not exists (select 1 from public.board_nodes where kind = 'treinador');

-- batalha contra treinador do jogo: o mesmo jogador nos dois lados da tabela de batalhas (o lado 1 é o NPC)
alter table public.battles drop constraint if exists battles_check;
alter table public.battles add constraint battles_check check (p1 <> p2 or mode = 'npc');

create table if not exists public.npc_fights (
  id         bigserial primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  trainer    text not null,
  level      int not null,
  won        boolean not null,
  coins      int not null default 0,
  team       jsonb not null default '[]'::jsonb,
  log        jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists npc_fights_user on public.npc_fights (user_id, created_at desc);
alter table public.npc_fights enable row level security;
drop policy if exists p_npc_fights on public.npc_fights;
create policy p_npc_fights on public.npc_fights for select to authenticated using (user_id = auth.uid() or public.has_role(auth.uid(), 'admin'));
revoke all on public.npc_fights from anon, authenticated;
grant select on public.npc_fights to authenticated;

-- um Pokémon de treinador (DVs medianos, golpes do nível)
create or replace function public.npc_mon(_species int, _lvl int) returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'id', gen_random_uuid(), 'species', p.id, 'name', p.name, 'level', _lvl, 't1', p.g1_type1, 't2', p.g1_type2, 'outfit', '{}'::jsonb,
    'maxhp', public.pk_stat(p.base_hp, public.pk_hp_dv(8, 8, 8, 8), _lvl, true),
    'hp',    public.pk_stat(p.base_hp, public.pk_hp_dv(8, 8, 8, 8), _lvl, true),
    'atk', public.pk_stat(p.base_atk, 8, _lvl, false), 'def', public.pk_stat(p.base_def, 8, _lvl, false),
    'spd', public.pk_stat(p.base_spd, 8, _lvl, false), 'spc', public.pk_stat(p.base_spc, 8, _lvl, false),
    'bspd', p.base_spd, 'bexp', p.base_exp,
    'moves', (select jsonb_agg(jsonb_build_object('id', mv.id, 'pp', mv.pp, 'max', mv.pp) order by u.ord)
                from unnest(public.pk_moves_at(p.id, _lvl)) with ordinality u(mid, ord) join pk_moves mv on mv.id = u.mid),
    'status', null, 'sleep', 0, 'conf', 0, 'st', '{"atk":0,"def":0,"spd":0,"spc":0,"acc":0,"eva":0}'::jsonb, 'fl', '{}'::jsonb, 'last', null)
  from pokemon p where p.id = _species
$$;

-- luta automática contra um treinador sorteado
create or replace function public.npc_fight(_cid uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.casas_cfg(); me characters; s0 jsonb; s1 jsonb; b battles; it int := 0; side int; p jsonb; lvl int; n int;
  tr text; types text[]; mons jsonb := '[]'::jsonb; sp int; won boolean; coins int := 0; pct0 numeric; pct1 numeric; names text;
  trainers jsonb := '[
    {"n": "Pescador", "t": ["AGUA"]}, {"n": "Montanhista", "t": ["PEDRA", "TERRA"]}, {"n": "Caça-insetos", "t": ["INSETO"]},
    {"n": "Faixa-preta", "t": ["LUTA"]}, {"n": "Cientista", "t": ["ELETRICO", "VENENO"]}, {"n": "Médium", "t": ["FANTASMA", "PSIQUICO"]},
    {"n": "Domadora", "t": ["FOGO", "NORMAL"]}, {"n": "Jardineira", "t": ["PLANTA"]}, {"n": "Ornitólogo", "t": ["VOADOR"]},
    {"n": "Patinadora", "t": ["GELO", "AGUA"]}, {"n": "Domador de Dragões", "t": ["DRAGAO", "AGUA"]}]'::jsonb;
  pick jsonb; first_names text[] := array['Zé', 'Lia', 'Beto', 'Duda', 'Rafa', 'Nina', 'Caio', 'Malu', 'Téo', 'Bia', 'Juca', 'Gabi'];
begin
  select * into me from characters where id = _cid;
  s0 := public.league_side(me.user_id);
  pick := trainers->(floor(random() * jsonb_array_length(trainers))::int);
  tr := (pick->>'n') || ' ' || first_names[1 + floor(random() * cardinality(first_names))::int];
  if s0 is null then
    return jsonb_build_object('ev', jsonb_build_array(jsonb_build_object('t', 'treinador', 'msg',
      '🧢 O ' || tr || ' queria uma batalha, mas você nem tem Pokémon! Capture alguns e volte.')), 'coins', 0);
  end if;
  n := jsonb_array_length(s0->'mons');
  select greatest(3, least(100, round(avg((x->>'level')::int))))::int into lvl from jsonb_array_elements(s0->'mons') x;
  lvl := greatest(3, lvl - 1 + floor(random() * 3)::int);
  select array_agg(x) into types from jsonb_array_elements_text(pick->'t') x;
  -- espécies do tipo do treinador que já existiriam nesse nível (sem lendários)
  for i in 1 .. n loop
    select p.id into sp from pokemon p
     where (p.g1_type1 = any(types) or p.g1_type2 = any(types)) and p.catch_rate > 3 and public.gen_ok(p.id)
       and (p.id = p.base_form or exists (select 1 from pk_evolutions e where e.to_id = p.id and ((e.method = 'nivel' and e.level <= lvl) or (e.method <> 'nivel' and lvl >= 30))))
     order by random() limit 1;
    if sp is null then select p.id into sp from pokemon p where p.id = p.base_form and p.catch_rate > 3 and public.gen_ok(p.id) order by random() limit 1; end if;
    mons := mons || jsonb_build_array(public.npc_mon(sp, lvl));
  end loop;
  s1 := jsonb_build_object('user', me.user_id, 'name', tr, 'npc', true, 'active', 0, 'need_switch', false, 'mons', mons);
  select string_agg(x->>'name', ', ') into names from jsonb_array_elements(mons) x;

  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (me.user_id, me.user_id, 'npc', n, 'ativa', 1, 'normal', now(), jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', 'O ' || tr || ' te desafiou para uma batalha!'),
            jsonb_build_object('txt', me.name || ' mandou ' || (s0->'mons'->0->>'name') || '!'),
            jsonb_build_object('txt', tr || ' mandou ' || (mons->0->>'name') || '!')))))
  returning * into b;
  loop
    select * into b from battles where id = b.id;
    exit when b.status <> 'ativa' or b.turn > 60;
    it := it + 1; exit when it > 400;
    for side in 0 .. 1 loop
      if b.phase = 'troca' then
        if coalesce((b.state->'sides'->side->>'need_switch')::boolean, false) then
          insert into battle_actions(battle_id, turn, side, user_id, kind, value)
          values (b.id, b.turn, side, me.user_id, 'switch', public.war_switch(b.state, side, true));
        end if;
      else
        p := public.war_pick(b.state, side, 'forte');
        insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, side, me.user_id, p->>'kind', (p->>'value')::int);
      end if;
    end loop;
    perform public.bt_resolve(b.id);
  end loop;
  select * into b from battles where id = b.id;
  if b.status = 'ativa' then
    select sum((x->>'hp')::int)::numeric / greatest(1, sum((x->>'maxhp')::int)) into pct0 from jsonb_array_elements(b.state->'sides'->0->'mons') x;
    select sum((x->>'hp')::int)::numeric / greatest(1, sum((x->>'maxhp')::int)) into pct1 from jsonb_array_elements(b.state->'sides'->1->'mons') x;
    won := pct0 > pct1;
    perform public.bt_finish(b.id, case when won then me.user_id end, 'limite');
  else
    -- quem ficou com Pokémon de pé venceu (o "vencedor" da tabela é sempre o jogador, então olhamos a vida)
    won := exists (select 1 from jsonb_array_elements(b.state->'sides'->0->'mons') x where (x->>'hp')::int > 0)
       and not exists (select 1 from jsonb_array_elements(b.state->'sides'->1->'mons') x where (x->>'hp')::int > 0);
  end if;
  -- o XP de batalha já foi entregue pelo bt_finish, como nas batalhas entre jogadores (quem derrubou adversário ganha)
  select * into b from battles where id = b.id;
  if won then coins := (c->>'npc_coins_base')::int + (c->>'npc_coins_per_level')::int * lvl; end if;
  insert into npc_fights(user_id, trainer, level, won, coins, team, log)
  values (me.user_id, tr, lvl, won, coins, (select jsonb_agg(jsonb_build_object('species', x->'species', 'name', x->'name')) from jsonb_array_elements(mons) x), b.log);
  delete from battles where id = b.id;
  return jsonb_build_object('coins', coins, 'ev', jsonb_build_array(jsonb_build_object('t', 'treinador', 'fight', (select max(id) from npc_fights where user_id = me.user_id),
    'msg', '🧢 O ' || tr || ' (nível ' || lvl || ', com ' || names || ') te desafiou! ' ||
      case when won then 'Você VENCEU e ganhou ' || coins || ' moedas. Seus Pokémon ganharam XP de batalha.' else 'Você perdeu, mas não perdeu nada. Treine e tente de novo!' end)));
end $$;


create or replace function public.house_extra(_cid uuid, _kind text, _modes jsonb, _dodge boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.casas_cfg(); me characters; ev jsonb := '[]'::jsonb; coins int := 0; sal int := 0; w jsonb; amt int; stone text; solved int; ball text;
begin
  select * into me from characters where id = _cid;
  if _kind = 'mina' then
    -- Mina de pedras: chance de achar uma pedra de evolução; senão, umas moedas
    if random() * 100 < (c->>'mina_stone_pct')::numeric then
      stone := public.random_stone();
      insert into bag_items(user_id, item, qty) values (me.user_id, stone, 1) on conflict (user_id, item) do update set qty = bag_items.qty + 1;
      ev := ev || jsonb_build_object('t', 'mina', 'msg', '⛏️ Mina de pedras: você achou uma ' || public.stone_name(stone) || '! Ela foi para a bolsa.');
      insert into event_log(user_id, kind, message) values (me.user_id, 'mina', me.name || ' achou uma ' || public.stone_name(stone) || ' na mina!');
    else
      coins := (c->>'mina_coins')::int;
      ev := ev || jsonb_build_object('t', 'mina', 'msg', '⛏️ Mina de pedras: nenhuma pedra hoje, mas você juntou ' || coins || ' moedas de minério.');
    end if;
  elsif _kind = 'desafio' then
    -- Casa do Desafio: premia quem acertou os 4 modos do dia; quem errou algum volta casas
    select count(*) into solved from jsonb_each(_modes) x where (x.value->>'solved')::boolean;
    if solved >= 4 then
      coins := (c->>'desafio_coins')::int;
      w := public.walk(_cid, (c->>'desafio_steps')::int); sal := (w->>'salary')::int;
      ev := ev || jsonb_build_object('t', 'desafio', 'msg', '🎯 Casa do Desafio: você acertou os 4 modos! Ganhou ' || coins || ' moedas e avançou ' || (c->>'desafio_steps') || ' casas.');
    else
      amt := (c->>'desafio_back')::int;
      if _dodge then ev := ev || jsonb_build_object('t', 'desafio', 'msg', '🎯 Casa do Desafio: você não acertou os 4 modos, mas o Atalho te livrou da punição.');
      elsif public.is_shielded(_cid) then ev := ev || jsonb_build_object('t', 'desafio', 'msg', '🎯 Casa do Desafio: você não acertou os 4 modos, mas a Bênção te segurou.');
      else
        perform public.go_back(_cid, amt);
        ev := ev || jsonb_build_object('t', 'desafio', 'msg', '🎯 Casa do Desafio: só acertou ' || solved || ' de 4 modos. Voltou ' || amt || ' casas.');
      end if;
    end if;
  elsif _kind = 'ladrao' then
    -- Ladrão de estrada: leva uma parte das moedas (o Clérigo perde metade)
    amt := least((c->>'ladrao_max')::int, floor(me.coins * (c->>'ladrao_pct')::numeric / 100))::int;
    if me.class::text = 'clerigo' then amt := ceil(amt / 2.0)::int; end if;
    if amt <= 0 then ev := ev || jsonb_build_object('t', 'ladrao', 'msg', '🦹 Um ladrão de estrada revirou sua mochila, mas não achou nenhuma moeda. Ufa!');
    elsif _dodge then ev := ev || jsonb_build_object('t', 'ladrao', 'msg', '🦹 Um ladrão de estrada apareceu, mas o Atalho te tirou do caminho dele.');
    elsif public.is_shielded(_cid) then ev := ev || jsonb_build_object('t', 'ladrao', 'msg', '🦹 Um ladrão de estrada tentou te roubar, mas a Bênção te protegeu.');
    else
      coins := -amt;
      ev := ev || jsonb_build_object('t', 'ladrao', 'msg', '🦹 Ladrão de estrada! Ele levou ' || amt || ' moedas da sua mochila.');
    end if;
  elsif _kind = 'fonte' then
    -- Fonte das Bolas: ganha uma Great Ball ou, com sorte, uma Ultra Ball
    ball := case when random() * 100 < (c->>'fonte_ultra_pct')::numeric then 'ultra_ball' else 'great_ball' end;
    insert into bag_items(user_id, item, qty) values (me.user_id, ball, 1) on conflict (user_id, item) do update set qty = bag_items.qty + 1;
    ev := ev || jsonb_build_object('t', 'fonte', 'msg', '⛲ Fonte das Bolas: saiu uma ' || case when ball = 'ultra_ball' then 'Ultra Ball' else 'Great Ball' end || ' para a sua bolsa!');
  elsif _kind = 'treinador' then
    -- Treinador no caminho: batalha automática 3x3 contra um treinador do jogo (arquivo 43)
    w := public.npc_fight(_cid);
    ev := ev || coalesce(w->'ev', '[]'::jsonb); coins := coins + coalesce((w->>'coins')::int, 0);
  end if;
  return jsonb_build_object('ev', ev, 'coins', coins, 'sal', sal);
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
  if b.mode in ('guerra', 'liga', 'npc') then return; end if;
  select name into wn from characters where user_id = _winner;
  select name into ln from characters where user_id = case when _winner = b.p1 then b.p2 else b.p1 end;
  if _winner is not null then insert into event_log(user_id, kind, message) values (_winner, 'batalha', wn || ' venceu a batalha Pokémon contra ' || ln || case when b.bet > 0 and b.bet_paid then ' e levou ' || 2 * b.bet || ' moedas' else '' end || '!'); end if;
end $$;

create or replace function public.bt_arena_trigger() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  if new.mode in ('guerra', 'npc') then return null; end if;
  perform public.arena_sync(new.id);
  return null;
end $$;

revoke execute on function public.npc_mon(int, int), public.npc_fight(uuid), public.house_extra(uuid, text, jsonb, boolean) from public, anon, authenticated;

-- conferência
select kind, count(*) from public.board_nodes where kind in ('mina', 'desafio', 'ladrao', 'fonte', 'treinador') group by kind order by kind;
