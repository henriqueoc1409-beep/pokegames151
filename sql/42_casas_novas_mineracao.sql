-- =====================================================================
-- 42_casas_novas_mineracao.sql
-- Pedido do dono em 22/10/2026 (lista de ideias, item 1): casas especiais novas no tabuleiro e
-- mineração de pedras de evolução.
--   * 4 casas novas, no lugar de algumas casas "Trilha" (sem efeito), espalhadas pelo mapa:
--       ⛏️ Mina de pedras    → 30% de chance de achar uma pedra de evolução; senão, 20 moedas;
--       🎯 Casa do Desafio  → acertou os 4 modos do dia: +30 moedas e +2 casas; senão volta 2 casas;
--       🦹 Ladrão de estrada → leva 10% das moedas (no máximo 60; o Clérigo perde metade);
--       ⛲ Fonte das Bolas   → ganha 1 Great Ball (70%) ou 1 Ultra Ball (30%).
--     Atalho (Ladino) e Bênção (Clérigo) protegem das casas ruins, como nas outras.
--   * Mina da vila: 1 vez por dia o jogador pode "Cavar pedras" (15/25/35% de chance pelo nível da mina).
--   * Todos os números ficam em game_config.config.casas e podem ser mudados sem site.
-- Depende do 11, 17, 25 e 30. Antes, faça a cópia de segurança.
-- =====================================================================

alter table public.board_nodes drop constraint if exists board_nodes_kind_check;
alter table public.board_nodes add constraint board_nodes_kind_check
  check (kind in ('inicio','normal','bifurcacao','avanco','recuo','bau','xp','raio','troca','pagamento','carta','castelo',
                  'mina','desafio','ladrao','fonte','treinador'));
alter table public.villages add column if not exists mine_dig_on date;

update public.game_config set config = config || jsonb_build_object('casas', '{
  "mina_stone_pct": 30, "mina_coins": 20,
  "desafio_coins": 30, "desafio_steps": 2, "desafio_back": 2,
  "ladrao_pct": 10, "ladrao_max": 60,
  "fonte_ultra_pct": 30,
  "dig_pct": [15, 25, 35]}'::jsonb)
 where active and not (config ? 'casas');

create or replace function public.casas_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"mina_stone_pct":30,"mina_coins":20,"desafio_coins":30,"desafio_steps":2,"desafio_back":2,"ladrao_pct":10,"ladrao_max":60,"fonte_ultra_pct":30,"dig_pct":[15,25,35]}'::jsonb
         || coalesce(public.cfg()->'casas', '{}'::jsonb)
$$;

-- troca algumas casas "Trilha" pelas novas (só na primeira vez; longe da largada e do castelo)
with cand as (
  select id, row_number() over (order by id) rn from public.board_nodes
   where kind = 'normal' and dist between 8 and (select max(dist) - 8 from public.board_nodes)
)
update public.board_nodes b set kind = (array['mina', 'desafio', 'ladrao', 'fonte'])[((c.rn / 6) % 4) + 1]
  from cand c
 where b.id = c.id and c.rn % 6 = 3
   and not exists (select 1 from public.board_nodes where kind in ('mina', 'desafio', 'ladrao', 'fonte'));

-- pedras: nomes e sorteio (as da 2ª geração só com ela ligada)
create or replace function public.stone_name(_s text) returns text
language sql immutable as $$
  select case _s when 'pedra_fogo' then 'Pedra do Fogo' when 'pedra_agua' then 'Pedra da Água' when 'pedra_trovao' then 'Pedra do Trovão'
    when 'pedra_folha' then 'Pedra da Folha' when 'pedra_lua' then 'Pedra da Lua' when 'pedra_sol' then 'Pedra do Sol'
    when 'pedra_lua_nova' then 'Pedra da Lua Nova' when 'pedra_metal' then 'Pedra Metálica' when 'pedra_rei' then 'Pedra do Rei' else _s end
$$;
create or replace function public.random_stone() returns text
language plpgsql volatile security definer set search_path = public, extensions as $$
declare pool text[] := array['pedra_fogo', 'pedra_agua', 'pedra_trovao', 'pedra_folha', 'pedra_lua'];
begin
  if public.gen2_on() then pool := pool || array['pedra_sol', 'pedra_lua_nova', 'pedra_metal', 'pedra_rei']; end if;
  return pool[1 + floor(random() * cardinality(pool))::int];
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
  
  end if;
  return jsonb_build_object('ev', ev, 'coins', coins, 'sal', sal);
end $$;

-- Mina da vila: cavar pedras 1 vez por dia
create or replace function public.village_mine_dig() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); v villages; c jsonb := public.casas_cfg(); pct numeric; stone text; ch characters;
begin
  select * into v from villages where user_id = uid for update;
  if v.user_id is null or v.mine_level < 1 then raise exception 'Construa a Mina de Ouro primeiro.'; end if;
  if coalesce(v.damaged, '{}'::jsonb) ? 'mina' then raise exception 'A mina está danificada pela guerra. Conserte antes de cavar.'; end if;
  if v.mud > 0 then raise exception 'A vila está cheia de lama. Limpe antes de cavar.'; end if;
  if v.mine_dig_on = public.game_today() then raise exception 'Você já cavou hoje. Volte amanhã!'; end if;
  pct := (c->'dig_pct'->>(least(v.mine_level, 3) - 1))::numeric;
  update villages set mine_dig_on = public.game_today() where user_id = uid;
  if random() * 100 < pct then
    stone := public.random_stone();
    insert into bag_items(user_id, item, qty) values (uid, stone, 1) on conflict (user_id, item) do update set qty = bag_items.qty + 1;
    select * into ch from characters where user_id = uid;
    insert into event_log(user_id, kind, message) values (uid, 'mina', ch.name || ' cavou na mina da vila e achou uma ' || public.stone_name(stone) || '!');
    return jsonb_build_object('found', true, 'stone', stone, 'name', public.stone_name(stone), 'pct', pct);
  end if;
  return jsonb_build_object('found', false, 'pct', pct);
end $$;

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
  boss world_bosses; mud int; passed int[]; champ uuid; hx jsonb;
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
  if skill_on and cls = 'arqueiro' then
    for i in 2..greatest(sv,2) loop
      r2 := (c->>'roll_min')::int + floor(random() * ((c->>'roll_max')::int - (c->>'roll_min')::int + 1))::int;
      roll := greatest(roll, r2);
    end loop;
    ev := ev || jsonb_build_object('t','habilidade','msg','Tiro certeiro: a roleta girou ' || greatest(sv,2) || ' vezes e ficou com ' || roll || '.');
  end if;
  if cls = 'arqueiro' and roll < (c->>'arqueiro_min_die')::int then
    roll := (c->>'arqueiro_min_die')::int;
    ev := ev || jsonb_build_object('t','arqueiro','msg','Olho de arqueiro: a roleta vale no mínimo ' || roll || '.');
  end if;
  if skill_on and cls = 'domador' then
    roll := roll * greatest(sv,2);
    ev := ev || jsonb_build_object('t','habilidade','msg','Montaria: a roleta valeu ' || greatest(sv,2) || ' vezes mais (' || roll || ').');
  end if;
  if skill_on and cls in ('guerreiro','ladino','clerigo') and sv > 0 then
    skill_steps := sv;
    ev := ev || jsonb_build_object('t','habilidade','msg',
      case cls when 'guerreiro' then 'Investida' when 'ladino' then 'Atalho' else 'Bênção' end || ': +' || sv || ' casas.');
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
    path0 := coalesce(array_length(me.path,1),1);
    w := public.walk(me.id, total);
    sal := sal + (w->>'salary')::int;
    landed := (w->>'node')::int;

    -- encontro com o lendário (passando ou parando)
    select * into boss from world_bosses where status = 'ativo' order by id desc limit 1;
    if boss.id is not null then
      passed := (select path from characters where id = me.id)[path0 : coalesce(array_length((select path from characters where id = me.id),1),1)];
      if boss.node = any(passed) and not exists (select 1 from boss_contacts bc where bc.boss_id = boss.id and bc.user_id = uid) then
        insert into boss_contacts(boss_id, user_id) values (boss.id, uid);
        ev := ev || jsonb_build_object('t','lendario','msg','Você encontrou o lendário ' || (select name from pokemon where id = boss.pokemon_id) || '! Agora pode atacá-lo pelo painel.');
      end if;
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
        extra_coins := extra_coins + (c->>'chest_coins')::int;
        ev := ev || jsonb_build_object('t','bau','msg','Achou um baú com ' || (c->>'chest_coins') || ' moedas.');
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
      elsif nd.kind in ('mina', 'desafio', 'ladrao', 'fonte', 'treinador') then
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

  insert into daily_moves(user_id, move_date, modes, base_steps, roll, bonus_steps, skill_steps, from_node, to_node, xp_gained, coins_gained, events, recovered)
  values (uid, _d, modes, base, roll, bonus, skill_steps, from_node, me.node, xp_gain, coin_gain + sal, ev, _recovery);
  insert into event_log(user_id, kind, message, data)
  values (uid, 'andou', me.name || ' andou ' || total || ' casas' || case when _recovery then ' recuperando o dia ' || to_char(_d, 'DD/MM') else '' end || '.', jsonb_build_object('steps', total));

  return jsonb_build_object('date', _d, 'recovery', _recovery, 'base', base, 'roll', roll, 'bonus', bonus, 'skill', skill_steps, 'total', total, 'modes', modes,
    'from', from_node, 'to', me.node, 'path', to_jsonb(me.path), 'events', ev,
    'xp', xp_gain, 'coins', coin_gain + sal, 'level', new_level, 'leveled', new_level > old_level);
end $$;

revoke execute on function public.house_extra(uuid, text, jsonb, boolean), public.random_stone(), public.casas_cfg() from public, anon, authenticated;
revoke execute on function public.village_mine_dig() from public, anon;
grant execute on function public.village_mine_dig(), public.do_move(date, boolean) to authenticated;

-- conferência: quantas casas de cada tipo novo
select kind, count(*) from public.board_nodes where kind in ('mina', 'desafio', 'ladrao', 'fonte') group by kind order by kind;
