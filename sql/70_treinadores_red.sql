-- =====================================================================
-- POKEGAMES — Treinadores obrigatórios e o Red (pedido do dono em 03/11/2026).
--
-- 1) Treinadores obrigatórios: quem PASSA por uma casa de Treinador agora
--    também tem que batalhar com ele (antes só quem parava). Vale para cada
--    treinador do caminho, na ordem. Vencer dá as moedas de sempre; perder
--    não tira nada. Liga/desliga: casas.passar_luta.
-- 2) Red: um treinador lendário numa casa do caminho principal perto do
--    Castelo (todo mundo passa por ele). Time do fim dos jogos de Game Boy:
--    Pikachu 81, Espeon 73, Snorlax 75, Venusaur 77, Charizard 77 e
--    Blastoise 77. A ideia é ninguém vencer. Quem vencer ganha red_premio
--    (1000) moedas e aparece no Jornal. Perder não tira nada.
--    No mapa novo da próxima temporada (68) ele também aparece.
-- board_nodes.npc ('red'); npc_fight é apagada e criada de novo com a casa.
-- Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

alter table public.board_nodes add column if not exists npc text;

-- números das casas (versão do 42 + treinadores obrigatórios e prêmio do Red)
create or replace function public.casas_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"mina_stone_pct":30,"mina_coins":20,"desafio_coins":30,"desafio_steps":2,"desafio_back":2,"ladrao_pct":10,"ladrao_max":60,"fonte_ultra_pct":30,"dig_pct":[15,25,35],"passar_luta":true,"red_premio":1000}'::jsonb
         || coalesce(public.cfg()->'casas', '{}'::jsonb)
$$;

-- põe o Red numa casa comum do caminho principal, perto do Castelo (uma vez só)
create or replace function public.red_colocar() returns int
language plpgsql security definer set search_path = public, extensions as $$
declare nid int;
begin
  select id into nid from board_nodes where npc = 'red' limit 1;
  if nid is not null then return nid; end if;
  select id into nid from board_nodes
   where branch = 'tronco' and kind = 'normal' and hm is null and next_b is null and not hidden and dist between 4 and 12
   order by dist desc limit 1;
  if nid is null then return null; end if;
  update board_nodes set kind = 'treinador', npc = 'red' where id = nid;
  return nid;
end $$;
select public.red_colocar();

-- luta automática contra um treinador (versão do 45 + a casa escolhida e o Red)
drop function if exists public.npc_fight(uuid);
create or replace function public.npc_fight(_cid uuid, _node int default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.casas_cfg(); me characters; s0 jsonb; s1 jsonb; b battles; it int := 0; side int; p jsonb; lvl int; n int;
  tr text; types text[]; mons jsonb := '[]'::jsonb; sp int; won boolean; coins int := 0; pct0 numeric; pct1 numeric; names text;
  trainers jsonb := '[
    {"n": "Pescador", "t": ["AGUA"]}, {"n": "Montanhista", "t": ["PEDRA", "TERRA"]}, {"n": "Caça-insetos", "t": ["INSETO"]},
    {"n": "Faixa-preta", "t": ["LUTA"]}, {"n": "Cientista", "t": ["ELETRICO", "VENENO"]}, {"n": "Médium", "t": ["FANTASMA", "PSIQUICO"]},
    {"n": "Domadora", "t": ["FOGO", "NORMAL"]}, {"n": "Jardineira", "t": ["PLANTA"]}, {"n": "Ornitólogo", "t": ["VOADOR"]},
    {"n": "Patinadora", "t": ["GELO", "AGUA"]}, {"n": "Domador de Dragões", "t": ["DRAGAO", "AGUA"]}]'::jsonb;
  nd int; red boolean; pick jsonb; first_names text[] := array['Zé', 'Lia', 'Beto', 'Duda', 'Rafa', 'Nina', 'Caio', 'Malu', 'Téo', 'Bia', 'Juca', 'Gabi'];
begin
  select * into me from characters where id = _cid;
  nd := coalesce(_node, me.node);   -- a casa do treinador (parando nela ou passando por ela, arquivo 70)
  red := (select npc from board_nodes where id = nd) = 'red';
  s0 := public.league_side(me.user_id);
  -- cada casa tem sempre o mesmo treinador (pelo número da casa), para o mapa mostrar quem está lá
  pick := trainers->(nd % jsonb_array_length(trainers));
  tr := case when red then 'Red' else (pick->>'n') || ' ' || first_names[1 + (nd / jsonb_array_length(trainers)) % cardinality(first_names)] end;
  if s0 is null then
    return jsonb_build_object('ev', jsonb_build_array(jsonb_build_object('t', 'treinador', 'msg',
      '🧢 O ' || tr || ' queria uma batalha, mas você nem tem Pokémon! Capture alguns e volte.')), 'coins', 0);
  end if;
  n := jsonb_array_length(s0->'mons');
  if red then
    -- Red (arquivo 70): o time do fim dos jogos de Game Boy, para ninguém conseguir vencer
    lvl := 81;
    select jsonb_agg(public.npc_mon(x.sp, x.lv) order by x.o) into mons
      from (values (25, 81, 1), (196, 73, 2), (143, 75, 3), (3, 77, 4), (6, 77, 5), (9, 77, 6)) x(sp, lv, o);
  else
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
  end if;
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
  if won then coins := case when red then coalesce((c->>'red_premio')::int, 1000) else (c->>'npc_coins_base')::int + (c->>'npc_coins_per_level')::int * lvl end; end if;
  if won and red then
    insert into event_log(user_id, kind, message) values (me.user_id, 'treinador', '🔴 INACREDITÁVEL! ' || me.name || ' venceu o Red e ganhou ' || coins || ' moedas!');
  end if;
  insert into npc_fights(user_id, trainer, level, won, coins, team, log)
  values (me.user_id, tr, lvl, won, coins, (select jsonb_agg(jsonb_build_object('species', x->'species', 'name', x->'name')) from jsonb_array_elements(mons) x), b.log);
  delete from battles where id = b.id;
  return jsonb_build_object('coins', coins, 'ev', jsonb_build_array(jsonb_build_object('t', 'treinador', 'fight', (select max(id) from npc_fights where user_id = me.user_id),
    'msg', case when red then '🔴 Red, o treinador lendário (com ' || names || '), bloqueou o caminho! ' else '🧢 O ' || tr || ' (nível ' || lvl || ', com ' || names || ') te desafiou! ' end ||
      case when won then 'Você VENCEU e ganhou ' || coins || ' moedas. Seus Pokémon ganharam XP de batalha.' else case when red then 'Ele acabou com o seu time, como faz com todo mundo. Você não perdeu nada.' else 'Você perdeu, mas não perdeu nada. Treine e tente de novo!' end end)));
end $$;

-- andar no dia (versão do 67 + treinadores obrigatórios no caminho)
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
  boss world_bosses; mud int; passed int[]; tn int; champ uuid; hx jsonb; hh hunts; he hunt_entries; hgo int;
begin
  perform public.settle();
  leader := public.leader_id(); champ := public.round_champion();
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
  if skill_on and cls = 'arqueiro' then   -- Tiro certeiro (arquivo 67): a roleta vale o máximo
    roll := (c->>'roll_max')::int;
    ev := ev || jsonb_build_object('t','habilidade','msg','Tiro certeiro: a roleta ficou no máximo (' || roll || ').');
  end if;
  if cls = 'arqueiro' and roll < (c->>'arqueiro_min_die')::int then
    roll := (c->>'arqueiro_min_die')::int;
    ev := ev || jsonb_build_object('t','arqueiro','msg','Olho de arqueiro: a roleta vale no mínimo ' || roll || '.');
  end if;
  if skill_on and cls = 'domador' then
    roll := roll * greatest(sv,2);
    ev := ev || jsonb_build_object('t','habilidade','msg','Montaria: a roleta valeu ' || greatest(sv,2) || ' vezes mais (' || roll || ').');
  end if;
  if skill_on and cls in ('guerreiro','ladino','clerigo','pesquisador','mercador') and sv > 0 then
    skill_steps := sv;
    ev := ev || jsonb_build_object('t','habilidade','msg',
      case cls when 'guerreiro' then 'Investida' when 'ladino' then 'Atalho' when 'pesquisador' then 'Isca de frutas' when 'mercador' then 'Negócio da China' else 'Bênção' end || ': +' || sv || ' casas.');
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
    -- Caçada (arquivo 48): quem escolheu ir atrás do Pokémon vai para o começo do caminho dela;
    -- quem escolheu o jogo (ou não escolheu) segue a corrida normal
    select * into hh from hunts where status in ('ativa', 'tentando') order by id desc limit 1;
    if hh.id is not null then
      select * into he from hunt_entries where hunt_id = hh.id and user_id = uid;
      if coalesce(he.go, false) and not he.done and hh.status = 'ativa' and not (me.node = any(hh.node_ids)) then
        update hunt_entries set origin_node = me.node, origin_len = coalesce(array_length(me.path, 1), 1) where hunt_id = hh.id and user_id = uid;
        update characters set node = hh.fork_node, path = path || hh.fork_node,
               route = coalesce(route, '{}'::jsonb) || jsonb_build_object(hh.fork_node::text, 'b') where id = me.id;
        hgo := hh.fork_node;
        ev := ev || jsonb_build_object('t', 'cacada', 'msg', '🎯 Você foi atrás do Pokémon misterioso! Suas andadas agora são pelo caminho da Caçada. Pegando ou não o Pokémon, você volta para a casa onde estava.');
      elsif not coalesce(he.go, false) or he.done then
        update characters set route = coalesce(route, '{}'::jsonb) - hh.fork_node::text where id = me.id and route ? hh.fork_node::text;
      end if;
      select * into me from characters where id = me.id;
    end if;
    path0 := coalesce(array_length(me.path,1),1);
    w := public.walk(me.id, total);
    sal := sal + (w->>'salary')::int;
    landed := (w->>'node')::int;

    -- atalhos das HMs (arquivo 47): Cut, Surf, Strength e Flash nas casas com obstáculo; Fly de tempos em tempos
    hx := public.hm_shortcut(me.id, path0);
    ev := ev || coalesce(hx->'ev', '[]'::jsonb);
    if coalesce((hx->>'steps')::int, 0) > 0 then
      w := public.walk(me.id, (hx->>'steps')::int); sal := sal + (w->>'salary')::int;
      landed := (w->>'node')::int;
    end if;

    -- encontro com o lendário (passando ou parando)
    select * into boss from world_bosses where status = 'ativo' order by id desc limit 1;
    if boss.id is not null then
      passed := (select path from characters where id = me.id)[path0 : coalesce(array_length((select path from characters where id = me.id),1),1)];
      if boss.node = any(passed) and not exists (select 1 from boss_contacts bc where bc.boss_id = boss.id and bc.user_id = uid) then
        insert into boss_contacts(boss_id, user_id) values (boss.id, uid);
        ev := ev || jsonb_build_object('t','lendario','msg','Você encontrou o lendário ' || (select name from pokemon where id = boss.pokemon_id) || '! Agora pode atacá-lo pelo painel.');
      end if;
    end if;

    -- Treinadores no caminho (arquivo 70): passou pela casa, tem que batalhar (quem para nela luta pelo house_extra)
    if coalesce((public.casas_cfg()->>'passar_luta')::boolean, true) then
      for tn in select p.id from unnest((select path from characters where id = me.id)[path0 + 1 : coalesce(array_length((select path from characters where id = me.id),1),1) - 1]) with ordinality p(id, o)
                 join board_nodes b on b.id = p.id where b.kind = 'treinador' order by p.o loop
        w := public.npc_fight(me.id, tn);
        ev := ev || coalesce(w->'ev', '[]'::jsonb); extra_coins := extra_coins + coalesce((w->>'coins')::int, 0);
      end loop;
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
        extra_coins := extra_coins + (c->>'chest_coins')::int * case when skill_on and cls = 'mercador' then 2 else 1 end;
        ev := ev || jsonb_build_object('t','bau','msg','Achou um baú com ' || (c->>'chest_coins')::int * case when skill_on and cls = 'mercador' then 2 else 1 end || ' moedas.' || case when skill_on and cls = 'mercador' then ' (Negócio da China: em dobro!)' else '' end);
        hx := public.item_drop(uid, 'bau');
        if hx is not null then ev := ev || hx; end if;
        hx := public.hm_drop(uid, 'bau');
        if hx is not null then ev := ev || hx; end if;
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
      elsif nd.kind in ('mina', 'desafio', 'ladrao', 'fonte', 'treinador', 'alvo') then
        -- casas novas (arquivo 42) e treinadores (arquivo 43)
        hx := public.house_extra(me.id, nd.kind, modes, dodge);
        ev := ev || coalesce(hx->'ev', '[]'::jsonb);
        extra_coins := extra_coins + coalesce((hx->>'coins')::int, 0);
        extra_xp := extra_xp + coalesce((hx->>'xp')::int, 0);
        sal := sal + coalesce((hx->>'sal')::int, 0);
      end if;
    end if;

    -- 3) encontro na mesma casa vira duelo
    select * into me from characters where id = me.id;
    select ch.* into other from characters ch join board_nodes b on b.id = ch.node
     where ch.user_id <> uid and ch.node = me.node and ch.arrived_rank is null and b.kind not in ('inicio','castelo')
       -- com o líder, só há encontro se o outro for o melhor da última rodada (se o líder for o melhor, nada acontece)
       and (leader is null or (ch.user_id <> leader and uid <> leader) or (champ is not null and champ <> leader and champ in (uid, ch.user_id)))
     order by random() limit 1 for update of ch;
    if other.id is not null then
      chance := 50 + (me.level - other.level) * (c->>'duel_level_factor')::int
                   + case when cls = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end
                   - case when other.class::text = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end;
      chance := chance
        + case when exists (select 1 from villages where user_id = uid and arena_level > 0) then coalesce((c->>'arena_bonus')::int, 10) else 0 end
        - case when exists (select 1 from villages where user_id = other.user_id and arena_level > 0) then coalesce((c->>'arena_bonus')::int, 10) else 0 end;
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
    if sal > 0 then ev := ev || jsonb_build_object('t','pagamento','msg','Dia de pagamento: +' || sal || ' moedas de salário' ||
      case when uid = public.snorlax_id() then ' (10% a menos por ser o Snorlax da rodada).' else '.' end); end if;
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

  -- Mercador com a habilidade do dia: o salário dos Dias de pagamento vem em dobro
  if skill_on and cls = 'mercador' and sal > 0 then
    update characters set coins = coins + sal where id = me.id;
    ev := ev || jsonb_build_object('t','habilidade','msg','Negócio da China: o salário veio em dobro (+' || sal || ' moedas).');
    sal := sal * 2;
  end if;
  insert into daily_moves(user_id, move_date, modes, base_steps, roll, bonus_steps, skill_steps, from_node, to_node, xp_gained, coins_gained, events, recovered)
  values (uid, _d, modes, base, roll, bonus, skill_steps, from_node, me.node, xp_gain, coin_gain + sal, ev, _recovery);
  insert into event_log(user_id, kind, message, data)
  values (uid, 'andou', me.name || ' andou ' || total || ' casas' || case when _recovery then ' recuperando o dia ' || to_char(_d, 'DD/MM') else '' end || '.', jsonb_build_object('steps', total));

  return jsonb_build_object('date', _d, 'recovery', _recovery, 'base', base, 'roll', roll, 'bonus', bonus, 'skill', skill_steps, 'total', total, 'modes', modes,
    'from', from_node, 'to', me.node, 'path', to_jsonb(me.path), 'events', ev, 'hunt_go', hgo,
    'xp', xp_gain, 'coins', coin_gain + sal, 'level', new_level, 'leveled', new_level > old_level);
end $$;

-- troca do mapa na próxima temporada (versão do 68 + o Red)
create or replace function public.board_swap() returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare n int;
begin
  select count(*) into n from board_next;
  if n = 0 then return false; end if;
  -- pousadas devolvidas, lendário e Caçada fogem
  update characters ch set coins = ch.coins + p.total
    from (select owner, sum(price)::int as total from properties group by owner) p where p.owner = ch.user_id;
  delete from properties;
  update world_bosses set status = 'fugiu' where status = 'ativo';
  update world_bosses set node = 0;
  update hunts set status = 'fugiu' where status in ('ativa', 'tentando');
  update characters set node = 0, path = '{0}', route = '{}'::jsonb;
  -- casas novas
  insert into board_nodes (id, x, y, kind, value, region, branch, next_a, next_b, dist)
  select id, x, y, kind, value, region, branch, next_a, next_b, dist from board_next
  on conflict (id) do update set x = excluded.x, y = excluded.y, kind = excluded.kind, value = excluded.value, region = excluded.region,
    branch = excluded.branch, next_a = excluded.next_a, next_b = excluded.next_b, dist = excluded.dist, hm = null, hunt_id = null, hidden = false, npc = null;
  delete from board_nodes where id not in (select id from board_next);
  -- casas especiais pelas mesmas regras do arquivo 42 (Mina, Desafio, Ladrão, Fonte) e do 43 (Treinador)
  with cand as (select id, row_number() over (order by id) rn from board_nodes where kind = 'normal' and dist between 8 and (select max(dist) - 8 from board_nodes))
  update board_nodes b set kind = (array['mina', 'desafio', 'ladrao', 'fonte'])[((c.rn / 6) % 4) + 1] from cand c where b.id = c.id and c.rn % 6 = 3;
  with cand as (select id, row_number() over (order by id) rn from board_nodes where kind = 'normal' and dist between 10 and (select max(dist) - 6 from board_nodes))
  update board_nodes b set kind = 'treinador' from cand c where b.id = c.id and c.rn % 11 = 5;
  -- obstáculos das HMs pelas regras do arquivo 47
  update board_nodes b set hm = x.hm from (
    select id, hm, row_number() over (partition by region order by id) rn, count(*) over (partition by region) n from (
      select id, region, case
        when region in ('Floresta', 'Bosque Antigo', 'Jardins Reais') then 'CUT'
        when region in ('Praia', 'Aldeia dos Pescadores', 'Cidade Portuária', 'Ponte Velha') then 'SURF'
        when region in ('Montanha', 'Desfiladeiro', 'Cratera', 'Escadaria do Trovão', 'Vale dos Ventos') then 'STRENGTH'
        when region in ('Caverna Escura', 'Atalho das Sombras', 'Bosque Enevoado', 'Mosteiro') then 'FLASH' end hm
      from board_nodes where kind = 'normal' and next_b is null and hunt_id is null and not hidden) y
    where hm is not null) x
  where b.id = x.id and (x.rn % 8 = 4 or (x.n < 8 and x.rn = (x.n + 1) / 2));
  perform public.red_colocar();   -- o Red perto do Castelo (arquivo 70)
  delete from board_next;
  insert into event_log(kind, message) values ('temporada', 'O mundo cresceu! O tabuleiro agora tem ' || n || ' casas. Boa sorte na nova temporada.');
  insert into posts(kind, title, body, created_by)
  select 'novidade', '🗺️ O mapa cresceu: ' || n || ' casas!', 'Nesta temporada o tabuleiro ficou maior: agora são ' || n || ' casas, ' || (n - 443) || ' a mais que antes.
• As 9 bifurcações continuam, com o mesmo equilíbrio entre a rota segura e a arriscada.
• As casas especiais (Mina, Desafio, Ladrão, Fonte, Treinadores) e os obstáculos das HMs foram espalhados de novo.
• As pousadas foram devolvidas aos donos com 100% do valor, porque as casas mudaram de lugar.
Boa corrida!', coalesce((select user_id from user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  where not exists (select 1 from posts where title = '🗺️ O mapa cresceu: ' || n || ' casas!');
  return true;
end $$;

-- ---------- permissões ----------
revoke execute on function public.npc_fight(uuid, int), public.red_colocar() from public, anon, authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🔴 O Red apareceu, e treinador agora é obrigatório', 'Dois avisos:
• 🧢 Treinadores obrigatórios: passou pela casa de um Treinador, tem que batalhar com ele, parando na casa ou não. Vencer dá moedas; perder não tira nada.
• 🔴 O Red, o treinador lendário, está no caminho perto do Castelo. Ele tem um time de níveis 73 a 81, e todo mundo vai ter que enfrentá-lo. Dizem que ninguém consegue vencer… quem conseguir ganha 1.000 moedas e fica famoso no Jornal!')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
