-- =====================================================================
-- POKEGAMES — A vila ajuda em tudo no jogo (pedido do dono em 09/11/2026).
-- Cada construção dá um bônus pequeno num sistema do jogo, pelo nível dela
-- (construção danificada não dá nada, como sempre). Números em
-- game_config.config.vila_bonus (Ajustes do jogo → 🏰 Bônus da vila):
--  * Centro da Vila: +1 casa na andada no nível 3 a 5, +2 no nível 6;
--  * Estábulo: casas extras a cada 2 dias (antes 4; número stable_days);
--  * Pomar: +10% de chance de captura;  Taverna: +1 bola por encontro;
--  * Torre de Vigia: 15/25/35% de chance de um Pokémon comum virar incomum ou mais raro;
--  * Academia: +10/20/30% de XP na Grama;  Arena: +10 minutos por dia na Grama;
--  * Centro Pokémon de Guerra: Centro Pokémon 10/20/30/40% mais barato e cura grátis
--    10/20/30/40% mais rápida;  Poço: Creche 10% mais barata;
--  * Torre de Defesa: +10/20/30% de dano contra a Equipe Rocket;
--  * Muralha: limpar a lama 30/60/100% mais barato;  Mina: salário +5/10/15%;
--  * Cofre: taxa do Mercado e do Leilão 1/2/3/4 pontos menor.
-- Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

create or replace function public.vila_bonus_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true,
    "centro": {"casas": [0, 0, 1, 1, 1, 2]},
    "pomar": {"captura_pct": [10]},
    "taverna": {"bolas": [1]},
    "vigia": {"raro_pct": [15, 25, 35]},
    "academia": {"grama_xp_pct": [10, 20, 30]},
    "arena": {"grama_min": [10]},
    "centropk": {"centro_desc_pct": [10, 20, 30, 40], "cura_rapida_pct": [10, 20, 30, 40]},
    "poco": {"creche_desc_pct": [10]},
    "defesa": {"rocket_dano_pct": [10, 20, 30]},
    "muralha": {"lama_desc_pct": [30, 60, 100]},
    "mina": {"salario_pct": [5, 10, 15]},
    "cofre": {"taxa_menos": [1, 2, 3, 4]}}'::jsonb || coalesce(public.cfg()->'vila_bonus', '{}'::jsonb)
$$;

-- bônus de uma construção da vila do jogador: o número da lista pelo nível que vale (danificada = 0)
create or replace function public.vb(_uid uuid, _b text, _f text) returns numeric
language sql stable security definer set search_path = public, extensions as $$
  select case when not coalesce((public.vila_bonus_cfg()->>'on')::boolean, true) then 0 else coalesce((
    select (l->>(least(public.vl_level(v, _b), jsonb_array_length(l)) - 1))::numeric
      from villages v, (select public.vila_bonus_cfg()->_b->_f as l) x
     where v.user_id = _uid and public.vl_level(v, _b) > 0 and jsonb_typeof(x.l) = 'array' and jsonb_array_length(x.l) > 0), 0) end
$$;

-- os números ficam no config (o site lê para mostrar "o que sua vila te dá")
update public.game_config set config = jsonb_set(config, '{vila_bonus}', public.vila_bonus_cfg()) where active and not (config ? 'vila_bonus');
-- Estábulo: casas extras com mais frequência (a cada 2 dias, antes 4)
update public.game_config set config = jsonb_set(config, '{stable_days}', '2'::jsonb) where active and coalesce((config->>'stable_days')::int, 4) = 4;

-- ---------- andar no tabuleiro (versão do 73 + Centro da Vila) ----------
create or replace function public.do_move(_d date, _recovery boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := auth.uid(); c jsonb := public.cfg(); today date := public.game_today();
  me characters; other characters; nd board_nodes; tr traps; w jsonb; x record;
  m public.puzzle_mode; s guess_sessions; st int; modes jsonb := '{}'::jsonb;
  base int := 0; roll int; r2 int; i int; bonus int; skill_steps int := 0; vcasas int := 0; total int; from_node int; landed int; path0 int;
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
  -- arquivo 82: o Centro da Vila dá casas extras na andada
  vcasas := public.vb(uid, 'centro', 'casas')::int;
  if vcasas > 0 then total := total + vcasas; ev := ev || jsonb_build_object('t', 'vila', 'msg', '🏰 Centro da Vila: +' || vcasas || case when vcasas = 1 then ' casa.' else ' casas.' end); end if;
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

-- ---------- captura (versão do 67 + Pomar) ----------
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
  caught := r1 <= floor(p.catch_rate * case when public.heroi(uid) = 'arqueiro' then (100 + (public.herois_cfg()->>'arqueiro_captura_pct')::numeric) / 100 else 1 end
                       * (100 + public.vb(uid, 'pomar', 'captura_pct')) / 100) and floor(random() * 256) <= f;   -- Arqueiro: mais captura
  if caught then
    m := public.pk_new_monster(uid, e.species_id, e.level);
    update encounters set status = 'capturado', throws_left = throws_left - 1, mon_id = m.id, resolved_at = now() where id = e.id;
    insert into event_log(user_id, kind, message) select uid, 'captura', ch.name || ' capturou um ' || p.name || ' (Nv ' || e.level || ')!' from characters ch where ch.user_id = uid;
    if e.hunt_id is not null then perform public.hunt_finish(e.hunt_id, true); end if;
    return jsonb_build_object('caught', true, 'shakes', 3, 'monster', to_jsonb(m), 'throws_left', e.throws_left - 1);
  end if;
  shakes := case when r1 > p.catch_rate then 0 else 1 + floor(random() * 2)::int end;
  update encounters set throws_left = throws_left - 1,
         status = case when throws_left - 1 <= 0 then 'fugiu' else status end,
         resolved_at = case when throws_left - 1 <= 0 then now() end
   where id = e.id returning * into e;
  if e.status = 'fugiu' and e.hunt_id is not null then perform public.hunt_finish(e.hunt_id, false); end if;
  return jsonb_build_object('caught', false, 'shakes', shakes, 'throws_left', e.throws_left, 'fled', e.status = 'fugiu');
end $$;

-- ---------- encontro depois de andar (versão do 79 + Taverna e Torre de Vigia) ----------
create or replace function public.pk_sync() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.pk_cfg(); dm record; pool int; hcls text := public.heroi(uid); k int; team uuid[]; each_xp int; mid uuid;
  sp int; lv int; maxd int; nd board_nodes; enc encounters; hh hunts; old encounters; start_at timestamptz := coalesce((public.cfg()->>'pk_start_at')::timestamptz, now());
begin
  perform public.creche_tick(uid);   -- níveis da Creche que já chegaram (arquivo 69)
  perform public.boas_vindas_dar(uid);   -- arquivo 77: inicial e pacote de boas-vindas (uma vez só)
  perform public.quartel_treino(uid);    -- arquivo 79: treino diário dos soldados do Quartel
  select max(dist) into maxd from board_nodes;
  for dm in select d.* from daily_moves d where d.user_id = uid and d.created_at >= start_at
             and not exists (select 1 from pk_move_sync s where s.move_id = d.id) order by d.created_at loop
    -- XP dos Pokémon da equipe: dividido igualmente
    pool := (c->'xp'->>'move_base')::int + (c->'xp'->>'per_step')::int * coalesce(dm.base_steps, 0)
          + (c->'xp'->>'per_mode')::int * (select count(*) from jsonb_each(case when jsonb_typeof(dm.modes->'modes') = 'object' then dm.modes->'modes' else dm.modes end) e
                                           where jsonb_typeof(e.value) = 'object' and coalesce((e.value->>'solved')::boolean, false));
    if hcls = 'pesquisador' then pool := ceil(pool * (100 + (public.herois_cfg()->>'pesq_xp_pct')::numeric) / 100)::int; end if;   -- Pesquisador: +XP da equipe
    select array_agg(id order by team_slot) into team from monsters where user_id = uid and team_slot is not null;
    insert into pk_move_sync(move_id, user_id, xp_pool) values (dm.id, uid, case when team is null then 0 else pool end);
    if team is not null then
      each_xp := greatest(1, pool / cardinality(team));
      foreach mid in array team loop perform public.pk_give_xp(mid, each_xp, 'tabuleiro'); end loop;
    end if;
    -- encontro na casa onde parou (o anterior que ficou aberto foge)
    for old in select * from encounters where user_id = uid and status = 'aberto' loop
      update encounters set status = 'fugiu', resolved_at = now() where id = old.id;
      if old.hunt_id is not null then perform public.hunt_finish(old.hunt_id, false); end if;   -- não tentou: o Pokémon da Caçada foge
    end loop;
    select * into nd from board_nodes where id = dm.to_node;
    hh := null;
    if nd.kind = 'alvo' then select * into hh from hunts where target_node = nd.id and status = 'tentando' and hunter = uid; end if;
    if hh.id is not null then
      sp := hh.species; lv := hh.level;   -- Caçada: o Pokémon escolhido pelo admin
    else
    sp := public.pk_pick_species(nd.region);
    -- Pesquisador com a habilidade do dia (Isca de frutas): Pokémon incomum ou mais raro
    if hcls = 'pesquisador' and coalesce(dm.skill_steps, 0) > 0 then
      for k in 1 .. 20 loop
        exit when (select catch_rate from pokemon where id = sp) < (c->'rarity'->>'comum')::int;
        sp := public.pk_pick_species(nd.region);
      end loop;
      -- arquivo 79: se o sorteio insistiu em comum, escolhe direto entre os incomuns ou mais raros
      if (select catch_rate from pokemon where id = sp) >= (c->'rarity'->>'comum')::int then
        select p.id into sp from pokemon p
         where (case when public.gen2_on() then coalesce(p.base_form2, p.base_form) else p.base_form end) = p.id and p.catch_rate < (c->'rarity'->>'comum')::int
           and public.gen_ok(p.id) and p.id not in (144, 145, 146, 150, 151, 243, 244, 245, 249, 250, 251)
         order by random() limit 1;
      end if;
    end if;
    -- arquivo 82: Torre de Vigia da vila: chance de trocar um Pokémon comum por um incomum ou mais raro
    if random() * 100 < public.vb(uid, 'vigia', 'raro_pct') and (select catch_rate from pokemon where id = sp) >= (c->'rarity'->>'comum')::int then
      select p.id into sp from pokemon p
       where (case when public.gen2_on() then coalesce(p.base_form2, p.base_form) else p.base_form end) = p.id and p.catch_rate < (c->'rarity'->>'comum')::int
         and public.gen_ok(p.id) and p.id not in (144, 145, 146, 150, 151, 243, 244, 245, 249, 250, 251)
       order by random() limit 1;
    end if;
    lv := least(100, greatest(1, (c->'encounter'->>'level_min')::int
                + floor((1 - coalesce(nd.dist, maxd)::numeric / greatest(maxd, 1)) * (c->'encounter'->>'level_span')::int)::int
                + floor(random() * ((c->'encounter'->>'level_spread')::int + 1))::int));
    end if;
    insert into encounters(user_id, move_id, node, species_id, level, throws_left, hunt_id)
    values (uid, dm.id, dm.to_node, sp, lv, (c->'capture'->>'throws')::int + case when hcls = 'pesquisador' then (public.herois_cfg()->>'pesq_bolas')::int else 0 end + public.vb(uid, 'taverna', 'bolas')::int, hh.id) on conflict (move_id) do nothing;
    perform public.pk_dex_mark(uid, sp, false);
  end loop;
  select * into enc from encounters where user_id = uid and status = 'aberto' order by created_at desc limit 1;
  return jsonb_build_object('encounter', case when enc.id is null then null else to_jsonb(enc) end,
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.id) from mon_events e where e.user_id = uid and not e.seen), '[]'::jsonb));
end $$;

-- ---------- Grama: XP (versão do 67 + Academia) ----------
create or replace function public.treino_after(_bid uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.treino_cfg(); b battles; t jsonb; m monsters; won boolean; ganho int := 0; hp_fim int; lv2 int; res jsonb; me0 jsonb; wi jsonb; cx int := 0; csp int;
begin
  select * into b from battles where id = _bid for update;
  if b.id is null or b.mode <> 'treino' or b.status = 'ativa' then return null; end if;
  t := b.state->'treino';
  if coalesce((t->>'feito')::boolean, false) then return t->'res'; end if;
  select * into m from monsters where id = (t->>'mon')::uuid;
  me0 := b.state->'sides'->0->'mons'->0; wi := b.state->'sides'->1->'mons'->0;
  won := b.end_reason <> 'desistencia' and (me0->>'hp')::int > 0
         and ((wi->>'hp')::int <= 0 or (b.end_reason = 'limite' and b.winner is not null));
  hp_fim := greatest(0, least(100, floor((me0->>'hp')::numeric * 100 / greatest(1, (me0->>'maxhp')::int))))::int;
  if (me0->>'hp')::int > 0 then hp_fim := greatest(1, hp_fim); end if;
  if m.id is not null then
    update monsters set tr_hp = hp_fim, tr_hurt_at = case when hp_fim < m.tr_hp then now() else tr_hurt_at end where id = m.id;
    if won then
      ganho := greatest(1, floor((wi->>'bexp')::int * (wi->>'level')::int / 7.0 * (c->>'xp_mult')::numeric
               * case when (t->>'forte')::boolean then (c->>'forte_xp_mult')::numeric else 1 end)::int);
      if public.heroi(b.p1) = 'domador' then ganho := ceil(ganho * (100 + (public.herois_cfg()->>'domador_grama_xp_pct')::numeric) / 100)::int; end if;   -- Domador: +XP
      ganho := ceil(ganho * (100 + public.vb(b.p1, 'academia', 'grama_xp_pct')) / 100)::int;   -- arquivo 82: Academia da vila
      perform public.pk_give_xp(m.id, ganho, 'treino');
      -- acompanhante (arquivo 63): ganha uma parte da experiência, como o Exp. Share
      if (t->>'comp') is not null then
        select species_id into csp from monsters where id = (t->>'comp')::uuid and user_id = b.p1;
        if csp is not null then
          cx := greatest(1, floor(ganho * case when public.heroi(b.p1) = 'pesquisador' then (public.herois_cfg()->>'pesq_comp_pct')::numeric else coalesce((c->>'acompanhante_pct')::numeric, 50) end / 100))::int;   -- Pesquisador: acompanhante ganha mais
          perform public.pk_give_xp((t->>'comp')::uuid, cx, 'treino');
        end if;
      end if;
    end if;
    select level into lv2 from monsters where id = m.id;
  end if;
  insert into treino_dias(user_id, dia) values (b.p1, public.game_today()) on conflict do nothing;
  update treino_dias set lutas = lutas + 1, vitorias = vitorias + won::int, xp = treino_dias.xp + ganho where user_id = b.p1 and dia = public.game_today();
  if hp_fim = 0 then
    b.log := b.log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt',
      (me0->>'name') || ' desmaiou! Leve ao Centro Pokémon ou espere ' || (c->>'gratis_horas') || ' horas para ele se recuperar de graça.'))));
  end if;
  res := jsonb_build_object('won', won, 'xp', ganho, 'comp_xp', cx, 'comp_species', csp, 'forte', (t->>'forte')::boolean, 'wild', (wi->>'species')::int, 'wild_level', (wi->>'level')::int,
    'species', m.species_id, 'level_from', m.level, 'level_to', coalesce(lv2, m.level), 'hp', hp_fim, 'desmaiou', hp_fim = 0,
    'fugiu', b.end_reason = 'desistencia');
  insert into treino_lutas(user_id, mon_id, species, wild, wild_level, won, xp, level_from, level_to, log)
  values (b.p1, m.id, coalesce(m.species_id, (me0->>'species')::int), (wi->>'species')::int, (wi->>'level')::int, won, ganho, coalesce(m.level, 1), coalesce(lv2, m.level, 1), b.log);
  delete from treino_lutas where user_id = b.p1 and id not in (select id from treino_lutas where user_id = b.p1 order by id desc limit (c->>'lutas_guardadas')::int);
  update battles set log = b.log, state = jsonb_set(state, '{treino}', t || jsonb_build_object('feito', true, 'res', res)) where id = b.id;
  return res;
end $$;

-- ---------- Grama: entrar (versão do 59 + Arena) ----------
create or replace function public.treino_entrar(_min int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.treino_cfg(); v treino_visitas; d treino_dias; m int;
begin
  if not coalesce((c->>'on')::boolean, true) then raise exception 'A Grama de Treino está fechada no momento.'; end if;
  perform 1 from characters where user_id = uid for update;
  v := public.treino_visita(uid);
  if v.id is not null then return public.treino_estado(); end if;   -- já está lá dentro
  if not (c->'visita_opcoes' @> to_jsonb(_min)) then raise exception 'Escolha quanto tempo quer ficar: % minutos.', (select string_agg(x, ' ou ') from jsonb_array_elements_text(c->'visita_opcoes') x); end if;
  insert into treino_dias(user_id, dia) values (uid, public.game_today()) on conflict do nothing;
  select * into d from treino_dias where user_id = uid and dia = public.game_today() for update;
  m := least(_min, (c->>'minutos_dia')::int + public.vb(uid, 'arena', 'grama_min')::int + d.bonus - d.minutos);   -- bonus = tempo extra dado pelo admin hoje
  if m <= 0 then raise exception 'Seu tempo de treino de hoje acabou (% minutos). Volte amanhã!', c->>'minutos_dia'; end if;
  insert into treino_visitas(user_id, dia, fim, minutos) values (uid, d.dia, now() + make_interval(mins => m), m);
  update treino_dias set minutos = minutos + m where user_id = uid and dia = d.dia;
  return public.treino_estado();
end $$;

-- ---------- Grama: estado (versão do 69 + Arena) ----------
create or replace function public.treino_estado() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.treino_cfg(); d treino_dias; v treino_visitas;
begin
  if uid is null then raise exception 'Entre na sua conta.'; end if;
  perform public.treino_autocura(uid);
  select * into d from treino_dias where user_id = uid and dia = public.game_today();
  v := public.treino_visita(uid);
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'modo', 'andar', 'minutos_dia', (c->>'minutos_dia')::int + public.vb(uid, 'arena', 'grama_min')::int, 'vila_min', public.vb(uid, 'arena', 'grama_min')::int,
    'opcoes', c->'visita_opcoes', 'encontro_seg', (c->>'encontro_seg')::int,
    'nivel_menos', (c->>'nivel_menos')::int, 'nivel_mais', (c->>'nivel_mais')::int, 'gratis_horas', public.cura_horas(uid), 'agora', now(),
    'minutos', coalesce(d.minutos, 0), 'bonus', coalesce(d.bonus, 0), 'lutas', coalesce(d.lutas, 0), 'vitorias', coalesce(d.vitorias, 0), 'xp', coalesce(d.xp, 0),
    'visita', case when v.id is null then null else jsonb_build_object('id', v.id, 'fim', v.fim, 'minutos', v.minutos, 'inicio', v.inicio) end,
    'batalha', public.treino_batalha(uid),
    'feridos', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'tr_hp', m.tr_hp, 'preco', public.centro_preco_mon(uid, m.level, m.tr_hp, m.tr_hurt_at), 'preco_cheio', public.centro_preco_de(uid, m.level, m.tr_hp),
        'gratis_em', coalesce(m.tr_hurt_at, now()) + make_interval(hours => public.cura_horas(uid))) order by m.tr_hp, m.level desc)
      from monsters m where m.user_id = uid and m.tr_hp < 100), '[]'::jsonb),
    'ultimas', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'mon_id', l.mon_id, 'species', l.species, 'wild', l.wild, 'wild_level', l.wild_level,
        'won', l.won, 'xp', l.xp, 'level_from', l.level_from, 'level_to', l.level_to, 'created_at', l.created_at) order by l.id desc)
      from treino_lutas l where l.user_id = uid), '[]'::jsonb));
end $$;

-- ---------- cura grátis (versão do 67 + Centro Pokémon de Guerra) ----------
create or replace function public.cura_horas(_uid uuid) returns int
language sql stable security definer set search_path = public, extensions as $$
  select greatest(1, ceil((case when public.heroi(_uid) = 'clerigo' then (public.herois_cfg()->>'clerigo_cura_horas')::int else (public.treino_cfg()->>'gratis_horas')::int end)
         * (100 - least(90, public.vb(_uid, 'centropk', 'cura_rapida_pct'))) / 100))::int   -- arquivo 82: Centro Pokémon de Guerra da vila
$$;

-- ---------- preço do Centro (versão do 67 + Centro Pokémon de Guerra) ----------
create or replace function public.centro_preco_de(_uid uuid, _level int, _hp int) returns int
language sql stable security definer set search_path = public, extensions as $$
  select case when public.centro_preco(_level, _hp) = 0 then 0 else greatest(1, ceil((case
    when public.heroi(_uid) = 'clerigo' then greatest(1, ceil(public.centro_preco(_level, _hp) * (100 - (public.herois_cfg()->>'clerigo_centro_desc_pct')::numeric) / 100))::int
    else public.centro_preco(_level, _hp) end)
    * (100 - least(90, public.vb(_uid, 'centropk', 'centro_desc_pct'))) / 100))::int end   -- arquivo 82: Centro Pokémon de Guerra da vila
$$;

-- ---------- desconto da Creche (versão do 67 + Poço) ----------
create or replace function public.creche_desc(_uid uuid) returns int
language sql stable security definer set search_path = public, extensions as $$
  select least(90, (case when public.heroi(_uid) = 'domador' then (public.herois_cfg()->>'domador_creche_desc_pct')::int else 0 end)
         + public.vb(_uid, 'poco', 'creche_desc_pct')::int)   -- arquivo 82: Poço da vila
$$;

-- ---------- ataque na batalha (versão do 67 + Torre de Defesa contra a Rocket) ----------
create or replace function public.bt_use_move(_s jsonb, _a int, _mid int, _first boolean, _depth int default 0) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare ds int := 1 - _a; A jsonb := _s->'sides'->_a->'mons'->((_s->'sides'->_a->>'active')::int); D jsonb := _s->'sides'->ds->'mons'->((_s->'sides'->ds->>'active')::int);
  mv pk_moves; eff numeric; crit boolean; hits int := 1; dmg int; total int := 0; i int; t int; acc numeric; lvl int; vatk numeric; vdef numeric; base int;
  phys boolean; chance int; st text; delta int; key text; target jsonb; tgt int; heal int; nm text := A->>'name'; dn text := D->>'name';
  hcls text := case when coalesce((_s->'sides'->_a->>'npc')::boolean, false) then null else public.heroi((_s->'sides'->_a->>'user')::uuid) end;   -- herói de quem ataca (arquivo 67)
  ai int := (_s->'sides'->_a->>'active')::int; di int := (_s->'sides'->ds->>'active')::int; stab boolean; _lines jsonb := coalesce(_s->'_lines', '[]'::jsonb);
begin
  select * into mv from pk_moves where id = _mid;
  -- golpes que chamam outros
  if mv.effect = 'METRONOME_EFFECT' and _depth = 0 then
    select id into t from pk_moves where id not in (118, 165) and (id <= 165 or public.gen2_on()) order by random() limit 1;
    _lines := _lines || jsonb_build_object('txt', nm || ' usou Metronome!');
    return public.bt_use_move(jsonb_set(_s, '{_lines}', _lines), _a, t, _first, 1);
  end if;
  if mv.effect = 'MIRROR_MOVE_EFFECT' and _depth = 0 then
    if D->>'last' is null or (D->>'last')::int = 119 then _lines := _lines || jsonb_build_object('txt', nm || ' usou Mirror Move, mas falhou!'); return jsonb_set(_s, '{_lines}', _lines); end if;
    _lines := _lines || jsonb_build_object('txt', nm || ' usou Mirror Move!');
    return public.bt_use_move(jsonb_set(_s, '{_lines}', _lines), _a, (D->>'last')::int, _first, 1);
  end if;
  _lines := _lines || jsonb_build_object('txt', nm || ' usou ' || mv.name || '!', 'side', _a, 'move', mv.id, 'mtype', mv.type);
  A := jsonb_set(A, '{last}', to_jsonb(mv.id));
  -- primeiro turno dos ataques de dois turnos
  if mv.effect in ('CHARGE_EFFECT','FLY_EFFECT') and coalesce(A->'fl'->>'charging', '') = '' then
    A := jsonb_set(A, '{fl,charging}', to_jsonb(mv.id));
    -- Fly e Dig (como na Red/Blue): no turno de preparo o Pokémon fica no alto ou debaixo da terra e nada o acerta
    if mv.effect = 'FLY_EFFECT' or mv.id = 91 then A := jsonb_set(A, '{fl,invul}', 'true'); end if;
    _lines := _lines || jsonb_build_object('txt', case when mv.id = 91 then nm || ' cavou um buraco e se escondeu debaixo da terra!'
                                                       when mv.effect = 'FLY_EFFECT' then nm || ' voou bem alto!'
                                                       else nm || ' está se preparando…' end);
    return jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{_lines}', _lines);
  end if;
  A := A #- '{fl,charging}'; A := A #- '{fl,invul}';
  -- efeitos que ainda não existem no Pokegames
  if mv.effect in ('TRANSFORM_EFFECT','MIMIC_EFFECT','DISABLE_EFFECT','CONVERSION_EFFECT','BIDE_EFFECT','SUBSTITUTE_EFFECT','G2_NAO_FUNCIONA') or mv.id = 68 then
    _lines := _lines || jsonb_build_object('txt', 'Esse ataque ainda não funciona no Pokegames: não aconteceu nada.');
    return jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{_lines}', _lines);
  end if;
  if mv.effect in ('SWITCH_AND_TELEPORT_EFFECT','SPLASH_EFFECT') then
    _lines := _lines || jsonb_build_object('txt', 'Mas não aconteceu nada!');
    return jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{_lines}', _lines);
  end if;
  -- precisão (1ª geração: sorteio de 0 a 255, então até 100% erra 1 vez em 256)
  if mv.effect <> 'SWIFT_EFFECT' and mv.accuracy > 0 and not (mv.power = 0 and mv.effect in ('HEAL_EFFECT','FOCUS_ENERGY_EFFECT','REFLECT_EFFECT','LIGHT_SCREEN_EFFECT','MIST_EFFECT','HAZE_EFFECT')
       or mv.effect like '%\_UP1\_EFFECT' or mv.effect like '%\_UP2\_EFFECT') then
    acc := floor(mv.accuracy * 255 / 100.0) * public.bt_stage((A->'st'->>'acc')::int) / public.bt_stage((D->'st'->>'eva')::int);
    if hcls = 'mago' and mv.power = 0 then acc := acc * (100 + (public.herois_cfg()->>'mago_status_acc_pct')::numeric) / 100; end if;   -- Mago: ataques de status acertam mais
    if coalesce((D->'fl'->>'invul')::boolean, false) then   -- o alvo está no alto (Fly) ou debaixo da terra (Dig)
      _lines := _lines || jsonb_build_object('txt', 'O ataque de ' || nm || ' não acertou: ' || (D->>'name')
        || case when (D->'fl'->>'charging')::int = 91 then ' está debaixo da terra!' else ' está lá no alto!' end);
      if mv.effect = 'JUMP_KICK_EFFECT' then
        A := jsonb_set(A, '{hp}', to_jsonb(greatest(0, (A->>'hp')::int - 1)));
        _lines := _lines || jsonb_build_object('txt', nm || ' caiu e se machucou!', 'side', _a, 'hp', (A->>'hp')::int);
      end if;
      return jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{_lines}', _lines);
    end if;
    if floor(random() * 256) >= least(255, acc)
       or (mv.effect = 'OHKO_EFFECT' and public.bt_speed(A) < public.bt_speed(D))
       or (mv.effect = 'DREAM_EATER_EFFECT' and coalesce(D->>'status', '') <> 'SLP') then
      _lines := _lines || jsonb_build_object('txt', 'O ataque de ' || nm || ' errou!');
      if mv.effect = 'JUMP_KICK_EFFECT' then
        A := jsonb_set(A, '{hp}', to_jsonb(greatest(0, (A->>'hp')::int - 1)));
        _lines := _lines || jsonb_build_object('txt', nm || ' caiu e se machucou!', 'side', _a, 'hp', (A->>'hp')::int);
      end if;
      return jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{_lines}', _lines);
    end if;
  end if;

  if mv.power > 0 or mv.effect in ('SPECIAL_DAMAGE_EFFECT','SUPER_FANG_EFFECT','OHKO_EFFECT') then
    eff := public.bt_eff(mv.type, D->>'t1', D->>'t2');
    if eff = 0 and mv.effect not in ('SPECIAL_DAMAGE_EFFECT','SUPER_FANG_EFFECT') then
      _lines := _lines || jsonb_build_object('txt', 'Não afeta ' || dn || '…');
      return jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{_lines}', _lines);
    end if;
    if mv.effect = 'TWO_TO_FIVE_ATTACKS_EFFECT' then t := floor(random() * 8); hits := case when t < 3 then 2 when t < 6 then 3 when t < 7 then 4 else 5 end;
    elsif mv.effect in ('ATTACK_TWICE_EFFECT','TWINEEDLE_EFFECT') then hits := 2; end if;
    -- crítico pela velocidade-base (golpes de crítico alto x8; Focus Energy reduz, como o defeito original)
    base := floor((A->>'bspd')::int / 2);
    if mv.code in ('KARATE_CHOP','RAZOR_LEAF','CRABHAMMER','SLASH') then base := least(255, base * 8); end if;
    if coalesce((A->'fl'->>'focus')::boolean, false) then base := floor(base / 4); end if;
    crit := mv.effect not in ('SPECIAL_DAMAGE_EFFECT','SUPER_FANG_EFFECT','OHKO_EFFECT') and floor(random() * 256) < base;
    for i in 1 .. hits loop
      if mv.effect = 'OHKO_EFFECT' then dmg := (D->>'hp')::int;
      elsif mv.effect = 'SUPER_FANG_EFFECT' then dmg := greatest(1, (D->>'hp')::int / 2);
      elsif mv.effect = 'SPECIAL_DAMAGE_EFFECT' then
        dmg := case mv.code when 'SONICBOOM' then 20 when 'DRAGON_RAGE' then 40 when 'PSYWAVE' then 1 + floor(random() * floor((A->>'level')::int * 1.5))::int
               else (A->>'level')::int end;
      else
        phys := public.bt_physical(mv.type); lvl := (A->>'level')::int * case when crit then 2 else 1 end;
        if phys then
          vatk := (A->>'atk')::int * case when crit then 1 else public.bt_stage((A->'st'->>'atk')::int) end;
          if A->>'status' = 'BRN' and not crit then vatk := vatk / 2; end if;
          vdef := (D->>'def')::int * case when crit then 1 else public.bt_stage((D->'st'->>'def')::int) end;
          if coalesce((D->'fl'->>'reflect')::boolean, false) and not crit then vdef := vdef * 2; end if;
        else
          vatk := (A->>'spc')::int * case when crit then 1 else public.bt_stage((A->'st'->>'spc')::int) end;
          vdef := (D->>'spc')::int * case when crit then 1 else public.bt_stage((D->'st'->>'spc')::int) end;
          if coalesce((D->'fl'->>'light')::boolean, false) and not crit then vdef := vdef * 2; end if;
        end if;
        vatk := greatest(1, floor(vatk)); vdef := greatest(1, floor(vdef));
        if mv.effect = 'EXPLODE_EFFECT' then vdef := greatest(1, floor(vdef / 2)); end if;
        if vatk > 255 or vdef > 255 then vatk := greatest(1, floor(vatk / 4)); vdef := greatest(1, floor(vdef / 4)); end if;
        dmg := least(997, floor(floor(floor(2 * lvl / 5 + 2) * vatk * mv.power / vdef) / 50)::int) + 2;
        stab := mv.type in (A->>'t1', coalesce(A->>'t2', ''));
        if stab then dmg := dmg + dmg / 2; end if;
        dmg := floor(dmg * coalesce((select mult from pk_type_chart where atk = mv.type and def = D->>'t1'), 1))::int;
        if D->>'t2' is not null and D->>'t2' <> D->>'t1' then dmg := floor(dmg * coalesce((select mult from pk_type_chart where atk = mv.type and def = D->>'t2'), 1))::int; end if;
        if dmg > 1 then dmg := floor(dmg * (217 + floor(random() * 39)) / 255)::int; end if;
        dmg := greatest(1, dmg);
        if hcls = 'guerreiro' then dmg := ceil(dmg * (100 + (public.herois_cfg()->>'guerreiro_dano_pct')::numeric) / 100)::int; end if;   -- Guerreiro: mais dano
        -- arquivo 82: Torre de Defesa da vila dá mais dano contra a Equipe Rocket
        if hcls is not null and (_s->'sides'->(1 - _a)->>'name') = 'Equipe Rocket' then
          dmg := ceil(dmg * (100 + public.vb((_s->'sides'->_a->>'user')::uuid, 'defesa', 'rocket_dano_pct')) / 100)::int;
        end if;
      end if;
      dmg := least(dmg, (D->>'hp')::int);
      D := jsonb_set(D, '{hp}', to_jsonb((D->>'hp')::int - dmg));
      total := total + dmg;
      _lines := _lines || jsonb_build_object('txt', case when hits > 1 then 'Acertou! ' else '' end || dn || ' perdeu ' || dmg || ' de vida.', 'side', ds, 'hp', (D->>'hp')::int, 'dmg', dmg);
      exit when (D->>'hp')::int <= 0;
    end loop;
    if hits > 1 then _lines := _lines || jsonb_build_object('txt', 'Acertou ' || least(i, hits) || ' vezes!'); end if;
    if crit then _lines := _lines || jsonb_build_object('txt', 'Acerto crítico!'); end if;
    if mv.effect not in ('SPECIAL_DAMAGE_EFFECT','SUPER_FANG_EFFECT','OHKO_EFFECT') then
      if eff > 1 then _lines := _lines || jsonb_build_object('txt', 'É super eficaz!');
      elsif eff < 1 then _lines := _lines || jsonb_build_object('txt', 'Não é muito eficaz…'); end if;
    end if;
    if mv.effect = 'OHKO_EFFECT' then _lines := _lines || jsonb_build_object('txt', 'Nocaute de um golpe só!'); end if;
    -- congelado acertado por fogo descongela
    if mv.type = 'FOGO' and D->>'status' = 'FRZ' then D := jsonb_set(D, '{status}', 'null'); _lines := _lines || jsonb_build_object('txt', dn || ' descongelou!'); end if;
    -- recuo, dreno e explosão
    if mv.effect = 'RECOIL_EFFECT' then
      heal := greatest(1, total / case when mv.code = 'STRUGGLE' then 2 else 4 end);
      A := jsonb_set(A, '{hp}', to_jsonb(greatest(0, (A->>'hp')::int - heal)));
      _lines := _lines || jsonb_build_object('txt', nm || ' sofreu o impacto do próprio golpe.', 'side', _a, 'hp', (A->>'hp')::int);
    elsif mv.effect in ('DRAIN_HP_EFFECT','DREAM_EATER_EFFECT') then
      heal := greatest(1, total / 2);
      A := jsonb_set(A, '{hp}', to_jsonb(least((A->>'maxhp')::int, (A->>'hp')::int + heal)));
      _lines := _lines || jsonb_build_object('txt', dn || ' teve a energia sugada!', 'side', _a, 'hp', (A->>'hp')::int);
    elsif mv.effect = 'EXPLODE_EFFECT' then
      A := jsonb_set(A, '{hp}', '0');
      _lines := _lines || jsonb_build_object('txt', nm || ' explodiu!', 'side', _a, 'hp', 0);
    elsif mv.effect = 'HYPER_BEAM_EFFECT' and (D->>'hp')::int > 0 then
      A := jsonb_set(A, '{fl,recharge}', 'true');
    end if;
    -- efeitos secundários (chances da 1ª geração, em 256)
    if (D->>'hp')::int > 0 then
      chance := case mv.effect
        when 'BURN_SIDE_EFFECT1' then 26 when 'BURN_SIDE_EFFECT2' then 77 when 'FREEZE_SIDE_EFFECT1' then 26 when 'PARALYZE_SIDE_EFFECT1' then 26
        when 'PARALYZE_SIDE_EFFECT2' then 77 when 'POISON_SIDE_EFFECT1' then 52 when 'POISON_SIDE_EFFECT2' then 103 when 'TWINEEDLE_EFFECT' then 52
        when 'FLINCH_SIDE_EFFECT1' then 26 when 'FLINCH_SIDE_EFFECT2' then 77 when 'CONFUSION_SIDE_EFFECT' then 26
        when 'ATTACK_DOWN_SIDE_EFFECT' then 85 when 'DEFENSE_DOWN_SIDE_EFFECT' then 85 when 'SPEED_DOWN_SIDE_EFFECT' then 85 when 'SPECIAL_DOWN_SIDE_EFFECT' then 85
        else 0 end;
      if chance > 0 and floor(random() * 256) < chance then
        st := case when mv.effect like 'BURN%' then 'BRN' when mv.effect like 'FREEZE%' then 'FRZ' when mv.effect like 'PARALYZE%' then 'PAR'
                   when mv.effect like 'POISON%' or mv.effect = 'TWINEEDLE_EFFECT' then 'PSN' end;
        if st is not null then
          -- a 1ª geração não aplica o estado se o alvo for do mesmo tipo do golpe
          if D->>'status' is null and mv.type not in (D->>'t1', coalesce(D->>'t2', '')) then
            D := jsonb_set(D, '{status}', to_jsonb(st));
            _lines := _lines || jsonb_build_object('txt', dn || case st when 'BRN' then ' foi queimado!' when 'FRZ' then ' congelou!' when 'PAR' then ' ficou paralisado!' else ' foi envenenado!' end, 'side', ds, 'status', st);
          end if;
        elsif mv.effect like 'FLINCH%' then
          if _first then D := jsonb_set(D, '{fl,flinch}', 'true'); end if;
        elsif mv.effect = 'CONFUSION_SIDE_EFFECT' then
          if (D->>'conf')::int = 0 then D := jsonb_set(D, '{conf}', to_jsonb(2 + floor(random() * 4)::int)); _lines := _lines || jsonb_build_object('txt', dn || ' ficou confuso!'); end if;
        elsif not coalesce((D->'fl'->>'mist')::boolean, false) then
          key := case when mv.effect like 'ATTACK%' then 'atk' when mv.effect like 'DEFENSE%' then 'def' when mv.effect like 'SPEED%' then 'spd' else 'spc' end;
          if (D->'st'->>key)::int > -6 then
            D := jsonb_set(D, array['st', key], to_jsonb((D->'st'->>key)::int - 1));
            _lines := _lines || jsonb_build_object('txt', case key when 'atk' then 'O ataque' when 'def' then 'A defesa' when 'spd' then 'A velocidade' else 'O especial' end || ' de ' || dn || ' caiu!');
          end if;
        end if;
      end if;
    end if;
  else
    -- ataques sem dano
    if mv.effect = 'SLEEP_EFFECT' then
      if D->>'status' is not null then _lines := _lines || jsonb_build_object('txt', 'Mas falhou!');
      else D := jsonb_set(jsonb_set(D, '{status}', '"SLP"'), '{sleep}', to_jsonb(1 + floor(random() * 7)::int)); _lines := _lines || jsonb_build_object('txt', dn || ' adormeceu!', 'side', ds, 'status', 'SLP'); end if;
    elsif mv.effect = 'POISON_EFFECT' then
      if D->>'status' is not null or 'VENENO' in (D->>'t1', coalesce(D->>'t2', '')) then _lines := _lines || jsonb_build_object('txt', 'Mas falhou!');
      else D := jsonb_set(D, '{status}', '"PSN"'); _lines := _lines || jsonb_build_object('txt', dn || ' foi envenenado!', 'side', ds, 'status', 'PSN'); end if;
    elsif mv.effect = 'PARALYZE_EFFECT' then
      if D->>'status' is not null or (mv.type = 'ELETRICO' and public.bt_eff('ELETRICO', D->>'t1', D->>'t2') = 0) then _lines := _lines || jsonb_build_object('txt', 'Mas falhou!');
      else D := jsonb_set(D, '{status}', '"PAR"'); _lines := _lines || jsonb_build_object('txt', dn || ' ficou paralisado! Talvez não consiga se mover.', 'side', ds, 'status', 'PAR'); end if;
    elsif mv.effect = 'CONFUSION_EFFECT' then
      if (D->>'conf')::int > 0 then _lines := _lines || jsonb_build_object('txt', 'Mas falhou!');
      else D := jsonb_set(D, '{conf}', to_jsonb(2 + floor(random() * 4)::int)); _lines := _lines || jsonb_build_object('txt', dn || ' ficou confuso!'); end if;
    elsif mv.effect like '%\_UP1\_EFFECT' or mv.effect like '%\_UP2\_EFFECT' or mv.effect like '%\_DOWN1\_EFFECT' or mv.effect like '%\_DOWN2\_EFFECT' then
      key := case when mv.effect like 'ATTACK%' then 'atk' when mv.effect like 'DEFENSE%' then 'def' when mv.effect like 'SPEED%' then 'spd'
                  when mv.effect like 'SPECIAL%' then 'spc' when mv.effect like 'ACCURACY%' then 'acc' else 'eva' end;
      delta := case when mv.effect like '%UP2%' then 2 when mv.effect like '%UP1%' then 1 when mv.effect like '%DOWN2%' then -2 else -1 end;
      if delta > 0 then tgt := _a; target := A; else tgt := ds; target := D; end if;
      if delta < 0 and coalesce((D->'fl'->>'mist')::boolean, false) then _lines := _lines || jsonb_build_object('txt', dn || ' está protegido pela névoa!');
      elsif (delta > 0 and (target->'st'->>key)::int >= 6) or (delta < 0 and (target->'st'->>key)::int <= -6) then _lines := _lines || jsonb_build_object('txt', 'Nada aconteceu!');
      else
        target := jsonb_set(target, array['st', key], to_jsonb(greatest(-6, least(6, (target->'st'->>key)::int + delta))));
        _lines := _lines || jsonb_build_object('txt', case key when 'atk' then 'O ataque' when 'def' then 'A defesa' when 'spd' then 'A velocidade'
            when 'spc' then 'O especial' when 'acc' then 'A precisão' else 'A evasão' end || ' de ' || (target->>'name') || case when delta > 0 then ' subiu' else ' caiu' end || case when abs(delta) > 1 then ' muito!' else '!' end);
        if tgt = _a then A := target; else D := target; end if;
      end if;
    elsif mv.effect = 'HEAL_EFFECT' then
      if (A->>'hp')::int >= (A->>'maxhp')::int then _lines := _lines || jsonb_build_object('txt', 'Mas falhou!');
      elsif mv.code = 'REST' then
        A := jsonb_set(jsonb_set(jsonb_set(A, '{hp}', to_jsonb((A->>'maxhp')::int)), '{status}', '"SLP"'), '{sleep}', '2');
        _lines := _lines || jsonb_build_object('txt', nm || ' dormiu e recuperou toda a vida!', 'side', _a, 'hp', (A->>'hp')::int, 'status', 'SLP');
      else
        A := jsonb_set(A, '{hp}', to_jsonb(least((A->>'maxhp')::int, (A->>'hp')::int + (A->>'maxhp')::int / 2)));
        _lines := _lines || jsonb_build_object('txt', nm || ' recuperou vida!', 'side', _a, 'hp', (A->>'hp')::int);
      end if;
    elsif mv.effect = 'FOCUS_ENERGY_EFFECT' then A := jsonb_set(A, '{fl,focus}', 'true'); _lines := _lines || jsonb_build_object('txt', nm || ' está concentrado!');
    elsif mv.effect = 'REFLECT_EFFECT' then A := jsonb_set(A, '{fl,reflect}', 'true'); _lines := _lines || jsonb_build_object('txt', nm || ' ficou mais resistente a golpes físicos!');
    elsif mv.effect = 'LIGHT_SCREEN_EFFECT' then A := jsonb_set(A, '{fl,light}', 'true'); _lines := _lines || jsonb_build_object('txt', nm || ' ficou mais resistente a golpes especiais!');
    elsif mv.effect = 'MIST_EFFECT' then A := jsonb_set(A, '{fl,mist}', 'true'); _lines := _lines || jsonb_build_object('txt', nm || ' se cobriu de névoa!');
    elsif mv.effect = 'HAZE_EFFECT' then
      A := jsonb_set(A, '{st}', '{"atk":0,"def":0,"spd":0,"spc":0,"acc":0,"eva":0}'); D := jsonb_set(D, '{st}', '{"atk":0,"def":0,"spd":0,"spc":0,"acc":0,"eva":0}');
      A := jsonb_set(A, '{conf}', '0'); D := jsonb_set(jsonb_set(D, '{conf}', '0'), '{status}', 'null'); D := D #- '{fl,leech}'; A := A #- '{fl,leech}';
      _lines := _lines || jsonb_build_object('txt', 'Todas as mudanças de atributos foram desfeitas!', 'side', ds, 'status', null);
    elsif mv.effect = 'LEECH_SEED_EFFECT' then
      if 'PLANTA' in (D->>'t1', coalesce(D->>'t2', '')) or coalesce((D->'fl'->>'leech')::boolean, false) then _lines := _lines || jsonb_build_object('txt', 'Mas falhou!');
      else D := jsonb_set(D, '{fl,leech}', 'true'); _lines := _lines || jsonb_build_object('txt', dn || ' foi semeado!'); end if;
    else
      _lines := _lines || jsonb_build_object('txt', 'Mas não aconteceu nada!');
    end if;
  end if;
  _s := jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A);
  _s := jsonb_set(_s, array['sides', ds::text, 'mons', di::text], D);
  return jsonb_set(_s, '{_lines}', _lines);
end $$;

-- ---------- limpar a lama (versão do 09 + Muralha) ----------
create or replace function public.village_clean() returns int
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); v villages; cost int; me characters;
begin
  select * into v from villages where user_id = uid for update;
  if v.user_id is null or v.mud = 0 then raise exception 'Sua vila já está limpa.'; end if;
  cost := ceil(v.mud * (public.cfg()->>'mud_clean_per_level')::int * (100 - least(100, public.vb(uid, 'muralha', 'lama_desc_pct'))) / 100)::int;   -- arquivo 82: Muralha
  select * into me from characters where user_id = uid for update;
  if me.coins < cost then raise exception 'A limpeza custa % moedas.', cost; end if;
  update characters set coins = coins - cost where id = me.id;
  update villages set mud = 0 where user_id = uid;
  return cost;
end $$;

-- ---------- estado da vila (versão do 25 + Muralha no preço da limpeza) ----------
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
    'clean_cost', ceil(v.mud * (c->>'mud_clean_per_level')::int * (100 - least(100, public.vb(who, 'muralha', 'lama_desc_pct'))) / 100)::int,
    'repair_costs', rep, 'atk_tactic', case when who = uid then v.atk_tactic end, 'def_tactic', case when who = uid then v.def_tactic end);
end $$;

-- ---------- salário (versão do 67 + Mina) ----------
create or replace function public.walk(_cid uuid, _steps int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare ch characters; n board_nodes; cur int; p int[]; sal int := 0; c jsonb := cfg(); i int;
begin
  select * into ch from characters where id = _cid;
  cur := ch.node; p := ch.path;
  for i in 1..greatest(_steps,0) loop
    select * into n from board_nodes where id = cur;
    exit when n.kind = 'castelo' or n.next_a is null;
    cur := case when n.next_b is not null and ch.route->>(n.id::text) = 'b' then n.next_b else n.next_a end;
    p := p || cur;
    if (select kind from board_nodes where id = cur) = 'pagamento' then
      sal := sal + (c->>'salary_base')::int + (c->>'salary_per_level')::int * ch.level;
    end if;
  end loop;
  -- Taverna aumenta o salário
  if sal > 0 and exists (select 1 from villages where user_id = ch.user_id and tavern_level > 0) then
    sal := ceil(sal * (100 + coalesce((c->>'tavern_pct')::int, 15)) / 100.0)::int;
  end if;
  -- Mercador (arquivo 67): salário maior
  if sal > 0 and ch.class::text = 'mercador' then sal := ceil(sal * (100 + (public.herois_cfg()->>'merc_salario_pct')::numeric) / 100.0)::int; end if;
  -- arquivo 82: a Mina da vila aumenta o salário
  if sal > 0 then sal := ceil(sal * (100 + public.vb(ch.user_id, 'mina', 'salario_pct')) / 100.0)::int; end if;
  -- Snorlax da rodada recebe menos no Dia de pagamento
  if sal > 0 and ch.user_id = public.snorlax_id() then
    sal := floor(sal * coalesce((c->>'snorlax_salary_pct')::int, 90) / 100.0)::int;
  end if;
  update characters set node = cur, path = p, coins = coins + sal where id = _cid;
  return jsonb_build_object('node', cur, 'salary', sal);
end $$;

-- ---------- Mercado (versão do 67 + Cofre) ----------
create or replace function public.market_buy(_id uuid) returns public.characters
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); l market_listings; me characters; fee int; it text; sname text; sitems text[];
begin
  perform public.expire_listings();
  select * into l from market_listings where id = _id for update;
  if l.id is null or l.status <> 'aberto' then raise exception 'Esse anúncio não está mais disponível.'; end if;
  if l.seller_id = uid then raise exception 'Esse anúncio é seu.'; end if;
  select * into me from characters where user_id = uid for update;
  if l.item_kind = 'item' and l.item_id = any(me.owned_items) then raise exception 'Você já tem esse item.'; end if;
  if l.price is not null then
    if me.coins < l.price then raise exception 'Moedas insuficientes.'; end if;
    fee := ceil(l.price * greatest(0, case when public.heroi(l.seller_id) = 'ladino' then (public.herois_cfg()->>'ladino_taxa_pct')::numeric else (c->>'market_fee_pct')::numeric end
                                   - public.vb(l.seller_id, 'cofre', 'taxa_menos')) / 100);   -- arquivo 82: Cofre da vila   -- Ladino: taxa menor
    update characters set coins = coins - l.price where id = me.id;
    update characters set coins = coins + l.price - fee where user_id = l.seller_id;
    update market_listings set status = 'vendido', buyer_id = uid, closed_at = now() where id = l.id;
  else
    select owned_items into sitems from characters where user_id = l.seller_id;
    if l.want_kind = 'item' and l.want_item = any(sitems) then
      raise exception 'O vendedor já tem o item pedido. A troca não pode ser feita.';
    end if;
    perform public.inv_take(uid, l.want_kind, l.want_item, l.want_qty);
    perform public.inv_give(l.seller_id, l.want_kind, l.want_item, l.want_qty);
    update market_listings set status = 'trocado', buyer_id = uid, closed_at = now() where id = l.id;
  end if;
  perform public.inv_give(uid, l.item_kind, l.item_id, l.qty);
  it := case l.item_kind when 'item' then (select name from shop_items where id = l.item_id) when 'dica' then l.qty || ' Dica(s)' else l.qty || ' Tente outra vez' end;
  sname := (select name from characters where user_id = l.seller_id);
  insert into event_log(user_id, kind, message) values (uid, 'mercado', me.name || case when l.price is not null then ' comprou ' else ' trocou com ' || sname || ' e levou ' end || it || case when l.price is not null then ' de ' || sname || '.' else '.' end);
  select * into me from characters where id = me.id;
  return me;
end $$;

-- ---------- taxa do Leilão (versão do 67 + Cofre) ----------
create or replace function public.leilao_taxa_de(_uid uuid) returns numeric
language sql stable security definer set search_path = public, extensions as $$
  select greatest(0, case public.heroi(_uid) when 'ladino' then (public.herois_cfg()->>'ladino_taxa_pct')::numeric
    when 'mercador' then (public.herois_cfg()->>'merc_leilao_taxa_pct')::numeric else (public.leilao_cfg()->>'taxa_pct')::numeric end
    - public.vb(_uid, 'cofre', 'taxa_menos'))   -- arquivo 82: Cofre da vila
$$;

-- ---------- Ajustes do jogo (versão do 77 + bônus da vila) ----------
create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'leilao', public.leilao_cfg(), 'herois', public.herois_cfg(), 'temporada', public.temporada_cfg(), 'liga', public.liga_cfg(), 'pausa', public.pausa_cfg(), 'teto', public.teto_cfg(), 'boas_vindas', public.boas_vindas_cfg(), 'vila_bonus', public.vila_bonus_cfg(), 'base', public.cfg());
end $$;

revoke execute on function public.vila_bonus_cfg(), public.vb(uuid, text, text) from public, anon, authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🏰 A vila agora ajuda em tudo no jogo!', 'Cada construção da sua vila dá uma vantagem (quanto maior o nível, maior o bônus):
• 🗺️ Andar: Estábulo dá casas extras com mais frequência, e o Centro da Vila nível 3 e 6 dá casas a mais por dia.
• 🎯 Captura: Pomar dá mais chance de captura, Taverna dá +1 Poké Bola por encontro, e a Torre de Vigia traz mais Pokémon raros.
• 🌿 Treino: Academia dá mais XP na Grama, a Arena dá mais minutos na Grama, e o Poço deixa a Creche mais barata.
• 🏥 Cura: o Centro Pokémon de Guerra deixa o Centro Pokémon mais barato e a cura grátis mais rápida.
• ⚔️ Rocket e lama: Torre de Defesa dá mais dano na Equipe Rocket, e a Muralha deixa a limpeza da lama mais barata.
• 💰 Moedas: Mina dá salário maior, e o Cofre dá taxa menor no Mercado e no Leilão.
Na Minha Vila você vê tudo o que a sua vila te dá agora.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
