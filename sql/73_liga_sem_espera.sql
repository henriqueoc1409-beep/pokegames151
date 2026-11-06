-- =====================================================================
-- POKEGAMES — Liga sem espera (pedido do dono em 06/11/2026).
--
-- 1) O 1º que chega ao Castelo encerra a corrida NA HORA: a Liga começa
--    com todos os jogadores ativos, pela posição no mapa (liga.comeca_na_chegada).
-- 2) Durante a Liga o mapa fica parado: os desafios do dia continuam valendo
--    moedas, XP, rodada do dia e Pokémon, mas ninguém anda (liga.mapa_parado).
-- 3) Sem esperar o dia seguinte: acabou uma fase (ou a repescagem), começa a
--    próxima na hora (liga.fase_por_dia = false).
-- 4) A caverna abre na hora (liga.caverna_horas = 0); se o campeão não tentar,
--    o lendário foge em liga.caverna_prazo_horas (24).
-- 5) Acabou a caverna, começa a temporada nova na hora (liga.temporada_na_hora).
-- Todos os números e liga/desliga ficam em Administração → Ajustes do jogo.
-- Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

create or replace function public.liga_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"comeca_na_chegada":true,"mapa_parado":true,"fase_por_dia":false,"caverna_horas":0,"caverna_prazo_horas":24,"temporada_na_hora":true}'::jsonb
         || coalesce(public.cfg()->'liga', '{}'::jsonb);
$$;

-- a Liga desta temporada está acontecendo (rodada ou caverna)?
create or replace function public.liga_mapa_parado() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((public.liga_cfg()->>'mapa_parado')::boolean, true)
     and exists (select 1 from leagues l join seasons s on s.id = l.season_id
                  where l.status in ('rodada', 'caverna') and s.status = 'ativa' and l.started_at >= s.started_on);
$$;

-- começo da Liga (versão do 66 + começa na chegada)
create or replace function public.league_maybe_start(_force boolean default false) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare s seasons; lid int; n int; narr int; first_day date; c jsonb := cfg(); r record; prize int; quem text;
begin
  select * into s from seasons order by id desc limit 1;
  -- uma Liga por temporada (a data protege contra temporadas renumeradas pelo arquivo 14)
  if s.id is null or s.status <> 'ativa' or exists (select 1 from leagues where season_id = s.id and started_at >= s.started_on) then return null; end if;
  select count(*), min((arrived_at at time zone coalesce(c->>'timezone', 'America/Sao_Paulo'))::date) into narr, first_day
    from characters where arrived_rank is not null;
  if narr < 1 then return null; end if;
  -- a corrida acaba quando fecha a rodada do dia em que o 1º chegou (o admin pode forçar)
  if not _force and not coalesce((public.liga_cfg()->>'comeca_na_chegada')::boolean, true) and first_day >= public.game_today() then return null; end if;
  insert into leagues(season_id, name) values (s.id, 'Liga ' || s.id) returning id into lid;
  -- classificação final: quem chegou (pela ordem), depois quem está mais perto do Castelo
  insert into league_players(league_id, user_id, name, seed)
  select lid, x.user_id, x.name, row_number() over (order by x.arrived_rank nulls last, x.arrived_at, x.dist, x.xp desc)
    from (select ch.user_id, ch.name, ch.arrived_rank, ch.arrived_at, coalesce(b.dist, 9999) dist, coalesce(ch.xp_total, 0) xp
            from characters ch left join board_nodes b on b.id = ch.node
           where ch.arrived_rank is not null or ch.user_id in (select a.user_id from public.day_active(public.game_today()) a)) x;
  select count(*) into n from league_players where league_id = lid;
  if n < 2 then delete from leagues where id = lid; return null; end if;
  -- prêmio do Castelo e pódio para quem não chegou, pela posição no mapa
  for r in select lp.user_id, lp.seed, ch.name from league_players lp join characters ch on ch.user_id = lp.user_id
            where lp.league_id = lid and ch.arrived_rank is null order by lp.seed loop
    prize := coalesce((c->'castle_prizes'->>(r.seed - 1))::int, 0);
    if prize > 0 then
      update characters set coins = coins + prize where user_id = r.user_id;
      insert into event_log(user_id, kind, message) values (r.user_id, 'castelo', r.name || ' terminou a corrida em ' || r.seed || 'º lugar no mapa e ganhou ' || prize || ' moedas.');
    end if;
    if r.seed <= (c->>'season_arrivals')::int then
      insert into season_results(season_id, user_id, rank) values (s.id, r.user_id, r.seed) on conflict do nothing;
    end if;
  end loop;
  select name into quem from league_players where league_id = lid and seed = 1;
  insert into event_log(kind, message) values ('liga', '🏁 A corrida acabou! ' || quem || ' chegou primeiro ao Castelo. Começou a Liga ' || s.id || ', com ' || n
    || ' treinadores: o 1º da corrida enfrenta o último, o 2º o penúltimo... '
    || case when coalesce((public.liga_cfg()->>'fase_por_dia')::boolean, false) then 'Uma rodada por dia.' else 'Acabou uma fase, começa a próxima. O mapa fica parado até a temporada nova.' end);
  perform public.league_next_stage(lid);
  return lid;
end $$;

-- chegada ao Castelo (versão do 66 + puxa todos para a Liga na hora)
create or replace function public.check_arrival(_cid uuid) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare ch characters; s seasons; rk int; prize int; c jsonb := cfg(); fim boolean;
begin
  select * into ch from characters where id = _cid for update;
  if ch.arrived_rank is not null or (select kind from board_nodes where id = ch.node) <> 'castelo' then return null; end if;
  select * into s from seasons order by id desc limit 1 for update;
  -- a corrida já acabou (a Liga desta temporada começou): chega sem prêmio
  fim := exists (select 1 from leagues where season_id = s.id and started_at >= s.started_on);
  rk := (select count(*) from characters where arrived_rank is not null) + 1;
  prize := case when s.status = 'ativa' and not fim then coalesce((c->'castle_prizes'->>(rk-1))::int, 0) else 0 end;
  update characters set arrived_rank = rk, arrived_at = now(), coins = coins + prize where id = _cid;
  if s.status = 'ativa' and not fim and rk <= (c->>'season_arrivals')::int then
    insert into season_results(season_id, user_id, rank) values (s.id, ch.user_id, rk) on conflict do nothing;
  end if;
  if fim then return 'Você chegou ao Castelo, mas a corrida desta temporada já terminou. A Liga Pokémon está em andamento!'; end if;
  if rk = 1 and coalesce((public.liga_cfg()->>'comeca_na_chegada')::boolean, true) then perform public.league_maybe_start(false); end if;   -- arquivo 73: puxa todos na hora
  insert into event_log(user_id, kind, message) values (ch.user_id, 'castelo',
    ch.name || ' chegou ao Castelo da Liga em ' || rk || 'º lugar!' || case when rk = 1 then case when coalesce((public.liga_cfg()->>'comeca_na_chegada')::boolean, true) then ' A corrida ACABOU: a Liga Pokémon começa agora!' else ' A corrida termina quando a rodada de hoje fechar, e aí começa a Liga Pokémon!' end else '' end);
  return 'Você chegou ao Castelo da Liga em ' || rk || 'º lugar!' || case when prize > 0 then ' Prêmio: ' || prize || ' moedas.' else '' end
    || case when coalesce((public.liga_cfg()->>'comeca_na_chegada')::boolean, true) then ' A corrida acabou e a Liga Pokémon começa agora!' else ' A corrida termina quando a rodada de hoje fechar (meia-noite). Depois começa a Liga Pokémon!' end;
end $$;

-- resultado de uma luta da Liga (versão do 31 + próxima fase sem esperar)
create or replace function public.league_decide(_match uuid, _winner uuid, _wo boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare m league_matches; lg leagues; loser uuid; w uuid;
begin
  select * into m from league_matches where id = _match for update;
  if m.id is null or m.status <> 'ativa' then return; end if;
  w := coalesce(_winner, m.a);                    -- empate: passa o melhor colocado
  loser := case when w = m.a then m.b else m.a end;
  update league_matches set winner = w, status = case when _wo then 'wo' else 'encerrada' end where id = m.id;
  update league_players set out_stage = m.stage where league_id = m.league_id and user_id = loser;
  select * into lg from leagues where id = m.league_id;
  insert into event_log(user_id, kind, message) values (w, 'liga', lg.name || ': ' || (select name from characters where user_id = w) || ' venceu ' || (select name from characters where user_id = loser) || case when _wo then ' por W.O.' else '' end || ' e segue na Liga!');
  -- terminou a etapa? repescagem libera a rodada na hora; rodada normal espera o dia seguinte (league_tick)
  if not exists (select 1 from league_matches where league_id = m.league_id and stage = m.stage and status = 'ativa') then
    if lg.stage_kind = 'repescagem' or not coalesce((public.liga_cfg()->>'fase_por_dia')::boolean, false)   -- arquivo 73: sem esperar o dia seguinte
       or (select count(*) from league_players where league_id = m.league_id and out_stage is null) = 1 then
      perform public.league_next_stage(m.league_id);
    end if;
  end if;
end $$;

-- relógio da Liga (versão do 31 + sem esperar o dia + prazo da caverna)
create or replace function public.league_tick() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare lg leagues;
begin
  perform public.league_maybe_start(false);
  select * into lg from leagues order by id desc limit 1;
  if lg.id is null then return; end if;
  if lg.status = 'rodada' and (lg.stage_day < public.game_today() or not coalesce((public.liga_cfg()->>'fase_por_dia')::boolean, false))
     and not exists (select 1 from league_matches where league_id = lg.id and stage = lg.stage and status = 'ativa') then
    perform public.league_next_stage(lg.id);
  elsif lg.status = 'caverna' and lg.cave_tried_at is null
     and now() > lg.cave_open_at + make_interval(hours => coalesce((public.liga_cfg()->>'caverna_prazo_horas')::int, 24)) then
    perform public.league_cave_end(lg.id, false);
  end if;
end $$;

-- coroação (versão do 32 + caverna aberta na hora)
create or replace function public.league_crown(_lg int, _champ uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare lg leagues; nm text; leg int; lv int; item text; w jsonb := coalesce(public.cfg()->'league_legend_pct', '{"144":30,"145":30,"146":30,"150":7,"151":3}'::jsonb); tot numeric; r numeric;
begin
  select * into lg from leagues where id = _lg for update;
  if lg.status <> 'rodada' or _champ is null then return; end if;
  select name into nm from characters where user_id = _champ;
  -- sorteio com peso: cada lendário tem a sua chance (league_legend_pct)
  select sum((e.value)::numeric) into tot from jsonb_each_text(w) e
   where (e.value)::numeric > 0 and exists (select 1 from pokemon p where p.id = e.key::int and (p.id <= 151 or public.gen2_on()));
  if coalesce(tot, 0) <= 0 then w := '{"144":30,"145":30,"146":30,"150":7,"151":3}'::jsonb; tot := 100; end if;
  r := random() * tot;
  select k into leg from (
    select e.key::int k, sum((e.value)::numeric) over (order by e.key::int) acc
      from jsonb_each_text(w) e
     where (e.value)::numeric > 0 and exists (select 1 from pokemon p where p.id = e.key::int and (p.id <= 151 or public.gen2_on()))
  ) t where acc > r order by acc limit 1;
  leg := coalesce(leg, 144);
  select greatest(5, least(100, round(avg(level))))::int into lv from monsters;
  item := 'aura_campeao_' || lg.season_id;
  insert into shop_items(id, name, slot, price, min_level, rarity, data, exclusive, coins_ok)
  values (item, 'Aura do Campeão: ' || lg.name, 'aura', 0, 1, 'lendario', jsonb_build_object('c1', '#FFD54A', 'shiny', true, 'league', lg.name), true, false)
  on conflict (id) do nothing;
  update characters set owned_items = case when item = any(owned_items) then owned_items else array_append(owned_items, item) end where user_id = _champ;
  insert into villages(user_id) values (_champ) on conflict do nothing;
  update villages set castles = castles + 1 where user_id = _champ;
  update leagues set status = 'caverna', champion = _champ, champion_name = nm, legend_id = leg, legend_level = coalesce(lv, 30), aura_item = item,
         cave_open_at = now() + make_interval(hours => coalesce((public.liga_cfg()->>'caverna_horas')::int, 0)) where id = _lg;
  insert into event_log(user_id, kind, message) values (_champ, 'liga', '🏆 ' || nm || ' é o CAMPEÃO da ' || lg.name || '! Ganhou a Aura do Campeão e uma estátua no mapa, e entrou na caverna do ' ||
    (select name from pokemon where id = leg) || case when coalesce((public.liga_cfg()->>'caverna_horas')::int, 0) > 0 then '. Daqui a ' || (public.liga_cfg()->>'caverna_horas') || ' horas terá UMA chance de capturá-lo. Torça a favor ou contra!' else '. Ele já pode tentar a captura: UMA chance só!' end);
end $$;

-- fim da caverna (versão do 50 + temporada nova na hora)
create or replace function public.league_cave_end(_lg int, _caught boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare lg leagues; pn text;
begin
  select * into lg from leagues where id = _lg for update;
  if lg.status <> 'caverna' then return; end if;
  select name into pn from pokemon where id = lg.legend_id;
  if _caught then
    perform public.pk_new_monster(lg.champion, lg.legend_id, lg.legend_level);
    perform public.pk_dex_mark(lg.champion, lg.legend_id, true);
  end if;
  update leagues set status = 'encerrada', cave_result = case when _caught then 'capturou' else 'fugiu' end, ended_at = now() where id = lg.id;
  update seasons set status = 'encerrada', ended_on = public.game_today() where id = lg.season_id and status = 'ativa';
  perform public.season_awards_give(lg.season_id);   -- prêmios da temporada (arquivo 50)
  insert into event_log(user_id, kind, message) values (lg.champion, 'liga', case when _caught
    then '🎉 INACREDITÁVEL! ' || lg.champion_name || ' capturou o lendário ' || pn || ' (nível ' || lg.legend_level || ')!'
    else '💨 O lendário ' || pn || ' escapou de ' || lg.champion_name || '... Fica para a próxima Liga!' end
    || case when coalesce((public.liga_cfg()->>'temporada_na_hora')::boolean, true) then ' Começou a temporada nova: todos voltaram à largada, sem perder nada!' else ' Amanhã começa uma nova temporada: todos voltam à largada.' end);
  -- arquivo 73: acabou a Liga, o jogo segue na hora
  if coalesce((public.liga_cfg()->>'temporada_na_hora')::boolean, true) then perform public.start_new_season(); end if;
end $$;

-- andar no dia (versão do 70 + mapa parado durante a Liga)
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

  if me.arrived_rank is null and public.liga_mapa_parado() then   -- arquivo 73: durante a Liga ninguém anda
    ev := ev || jsonb_build_object('t','castelo','msg','A corrida acabou e a Liga Pokémon está acontecendo: o mapa fica parado até a temporada nova. Seus acertos de hoje continuam valendo moedas, XP e a rodada do dia.');
    total := 0;
  elsif me.arrived_rank is not null then
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

-- números para a aba Ajustes do jogo (versão do 71 + liga)
create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'leilao', public.leilao_cfg(), 'herois', public.herois_cfg(), 'temporada', public.temporada_cfg(), 'liga', public.liga_cfg(), 'base', public.cfg());
end $$;

revoke execute on function public.liga_cfg(), public.liga_mapa_parado() from public, anon, authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('⚡ Liga sem espera', 'A Liga Pokémon ficou mais rápida:
• 🏰 Chegou o 1º ao Castelo? A corrida acaba NA HORA e a Liga começa com todo mundo, pela posição no mapa.
• 🗺️ Durante a Liga o mapa fica parado: os desafios do dia continuam valendo moedas, XP, rodada e Pokémon, só não se anda.
• ⚔️ Sem esperar o dia seguinte: acabou uma fase (ou a repescagem), já começa a próxima.
• 🕳️ A caverna do lendário abre na hora para o campeão.
• 🔄 Acabou a caverna? A temporada nova começa na hora, todos na largada, sem perder nada (e com a troca de herói grátis).')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
