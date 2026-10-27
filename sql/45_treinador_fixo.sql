-- =====================================================================
-- 45_treinador_fixo.sql
-- Pedido do dono em 22/10/2026: o treinador de cada casa de Treinador fica sempre o mesmo
-- (escolhido pelo número da casa), para o site desenhar o personagem em pé no mapa e todos
-- saberem com quem vão duelar. A luta, o nível e os prêmios não mudam.
-- Depende do 43. Antes, faça a cópia de segurança.
-- =====================================================================

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
  -- cada casa tem sempre o mesmo treinador (pelo número da casa), para o mapa mostrar quem está lá
  pick := trainers->(me.node % jsonb_array_length(trainers));
  tr := (pick->>'n') || ' ' || first_names[1 + (me.node / jsonb_array_length(trainers)) % cardinality(first_names)];
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

revoke execute on function public.npc_fight(uuid) from public, anon, authenticated;
