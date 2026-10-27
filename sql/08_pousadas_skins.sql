-- =====================================================================
-- POKEGAMES — Pousadas com pedágio, o Procurado e novas skins.
-- Antes de rodar, faça a cópia de segurança.
-- Rode UMA vez no SQL Editor, depois do 07. Não apaga nenhum dado.
-- =====================================================================

update public.game_config set config = config || '{
  "property_base_price": 600, "property_min_level": 5, "property_max_per_player": 2,
  "property_raise_pct": 30, "property_fee_pct": 10, "property_toll_pct": 10, "property_min_toll": 15, "property_refund_pct": 50,
  "bounty_coins": 60
}'::jsonb where active;

-- 1) Pousadas -----------------------------------------------------------
create table if not exists public.properties (
  node         int primary key references public.board_nodes(id),
  owner        uuid not null references auth.users(id) on delete cascade,
  price        int  not null check (price > 0),
  bought_at    timestamptz not null default now(),
  tolls_earned int  not null default 0
);

create or replace function public.leader_id() returns uuid
language sql stable security definer set search_path = public, extensions as $$
  select ch.user_id from characters ch join board_nodes b on b.id = ch.node
  where ch.arrived_rank is null
  order by b.dist asc, ch.last_move_date asc nulls last, ch.created_at asc limit 1
$$;

create or replace function public.buy_property(_node int) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); me characters; n board_nodes; p properties; cost int; fee int; oname text;
begin
  select * into me from characters where user_id = uid for update;
  select * into n from board_nodes where id = _node;
  if n.id is null or n.kind <> 'normal' then raise exception 'Só dá para comprar casas comuns da trilha, sem efeito especial.'; end if;
  if me.level < (c->>'property_min_level')::int then raise exception 'Você precisa ser nível % para ter uma pousada.', (c->>'property_min_level'); end if;
  select * into p from properties where node = _node for update;
  if p.owner = uid then raise exception 'Essa pousada já é sua.'; end if;
  if (select count(*) from properties where owner = uid) >= (c->>'property_max_per_player')::int then
    raise exception 'Você já tem % pousadas, o máximo permitido.', (c->>'property_max_per_player');
  end if;
  if p.node is null then
    cost := (c->>'property_base_price')::int;
    if me.coins < cost then raise exception 'Uma pousada custa % moedas.', cost; end if;
    update characters set coins = coins - cost where id = me.id;
    insert into properties(node, owner, price) values (_node, uid, cost);
    insert into event_log(user_id, kind, message) values (uid, 'pousada', me.name || ' comprou uma pousada em ' || n.region || ' por ' || cost || ' moedas.');
  else
    cost := ceil(p.price * (1 + (c->>'property_raise_pct')::numeric / 100))::int;
    if me.coins < cost then raise exception 'Para tomar esta pousada você precisa oferecer % moedas.', cost; end if;
    fee := ceil(cost * (c->>'property_fee_pct')::numeric / 100)::int;
    oname := (select name from characters where user_id = p.owner);
    update characters set coins = coins - cost where id = me.id;
    update characters set coins = coins + cost - fee where user_id = p.owner;
    update properties set owner = uid, price = cost, bought_at = now(), tolls_earned = 0 where node = _node;
    insert into event_log(user_id, kind, message) values (uid, 'pousada', me.name || ' tomou a pousada de ' || oname || ' em ' || n.region || ' oferecendo ' || cost || ' moedas!');
  end if;
  return cost;
end $$;

create or replace function public.sell_property(_node int) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); p properties; refund int;
begin
  select * into p from properties where node = _node for update;
  if p.node is null or p.owner <> uid then raise exception 'Essa pousada não é sua.'; end if;
  refund := floor(p.price * (public.cfg()->>'property_refund_pct')::numeric / 100)::int;
  update characters set coins = coins + refund where user_id = uid;
  delete from properties where node = _node;
  return refund;
end $$;

-- 2) Novas skins --------------------------------------------------------
alter table public.shop_items drop constraint if exists shop_items_slot_check;
alter table public.shop_items add constraint shop_items_slot_check check (slot in ('chapeu','capa','roupa','aura','acessorio'));

insert into public.shop_items (id,name,slot,price,min_level,rarity,data) values
 ('bone_reto','Boné','chapeu',60,1,'comum','{"c1":"#3a7bc8","c2":"#1f4a80"}'),
 ('capuz_sapo','Capuz de sapo','chapeu',160,3,'incomum','{"c1":"#5fae3a","c2":"#f6efe0"}'),
 ('capuz_raposa','Capuz de raposa','chapeu',200,4,'raro','{"c1":"#e0782f","c2":"#f6efe0"}'),
 ('chapeu_pirata','Chapéu de pirata','chapeu',180,4,'raro','{"c1":"#2b2b33","c2":"#f5f5f5"}'),
 ('cartola','Cartola','chapeu',220,5,'raro','{"c1":"#1b1626","c2":"#c0392b"}'),
 ('capuz_dragao','Capuz de dragão','chapeu',260,5,'raro','{"c1":"#3f9a4a","c2":"#f5d547"}'),
 ('louros','Coroa de louros','chapeu',350,7,'epico','{"c1":"#7fb24a","c2":"#4f7a2a"}'),
 ('camisa_time','Camisa listrada (você escolhe as cores)','roupa',150,2,'incomum','{"c1":"#c0392b","c2":"#1b1626","pattern":"listras","custom":true}'),
 ('fantasia_sapo','Fantasia de sapo','roupa',150,3,'incomum','{"c1":"#5fae3a","c2":"#3d7a25","extra":[[5,8,"#d9e8a0"],[6,8,"#d9e8a0"],[5,9,"#d9e8a0"],[6,9,"#d9e8a0"],[5,10,"#d9e8a0"],[6,10,"#d9e8a0"]]}'),
 ('fantasia_raposa','Fantasia de raposa','roupa',190,4,'raro','{"c1":"#e0782f","c2":"#a8501f","extra":[[5,8,"#f6efe0"],[6,8,"#f6efe0"],[5,9,"#f6efe0"],[6,9,"#f6efe0"],[5,10,"#f6efe0"],[6,10,"#f6efe0"]]}'),
 ('fantasia_dragao','Fantasia de dragão','roupa',240,5,'raro','{"c1":"#3f9a4a","c2":"#2b6e34","extra":[[5,8,"#f5d547"],[6,8,"#f5d547"],[5,9,"#f5d547"],[6,9,"#f5d547"],[5,10,"#f5d547"],[6,10,"#f5d547"]]}'),
 ('terno','Terno executivo','roupa',300,6,'epico','{"c1":"#2a2f45","c2":"#1a1d2b","extra":[[4,7,"#f5f5f5"],[7,7,"#f5f5f5"],[5,7,"#c0392b"],[6,7,"#c0392b"],[5,8,"#c0392b"],[6,8,"#c0392b"],[5,9,"#a83226"],[6,9,"#a83226"],[5,10,"#a83226"],[6,10,"#a83226"]]}'),
 ('armadura_dourada','Armadura dourada','roupa',700,12,'lendario','{"c1":"#e0b44c","c2":"#a8822f","extra":[[5,8,"#fff3b0"],[6,8,"#fff3b0"],[3,7,"#fff3b0"],[8,7,"#fff3b0"]]}'),
 ('capa_estrelas','Capa estrelada','capa',320,6,'epico','{"c1":"#2c3a7a","c2":"#f5d547","shape":"estrelas"}'),
 ('asas_anjo','Asas de anjo','capa',450,8,'epico','{"c1":"#f5f5f5","c2":"#c9d3e0","shape":"asas"}'),
 ('bigode','Bigodão','acessorio',70,1,'comum','{"px":[[4,5,"#3b2414"],[5,5,"#3b2414"],[6,5,"#3b2414"],[7,5,"#3b2414"],[3,5,"#3b2414"],[8,5,"#3b2414"]]}'),
 ('cachecol','Cachecol','acessorio',80,1,'comum','{"px":[[3,7,"#d1453b"],[4,7,"#d1453b"],[5,7,"#d1453b"],[6,7,"#d1453b"],[7,7,"#d1453b"],[8,7,"#d1453b"],[8,8,"#d1453b"],[8,9,"#a8321f"]]}'),
 ('oculos_escuros','Óculos escuros','acessorio',90,2,'incomum','{"px":[[3,4,"#111111"],[4,4,"#111111"],[5,4,"#5a6275"],[6,4,"#5a6275"],[7,4,"#111111"],[8,4,"#111111"]]}'),
 ('mascara_heroi','Máscara de herói','acessorio',140,3,'raro','{"px":[[2,4,"#c0392b"],[3,4,"#c0392b"],[4,4,"#ffffff"],[5,4,"#c0392b"],[6,4,"#c0392b"],[7,4,"#ffffff"],[8,4,"#c0392b"],[9,4,"#c0392b"]]}'),
 ('medalha','Medalha de campeão','acessorio',260,6,'raro','{"px":[[5,8,"#f5d547"],[6,8,"#f5d547"],[5,9,"#e0b44c"],[6,9,"#e0b44c"]]}'),
 ('aura_fogo','Aura de fogo','aura',450,7,'epico','{"c1":"#ff7a2f"}'),
 ('aura_sombria','Aura sombria','aura',450,7,'epico','{"c1":"#9b59d0"}'),
 ('brilho_raro','Brilho raro (versão brilhante)','aura',800,10,'lendario','{"c1":"#fff3b0","shiny":true}')
on conflict (id) do nothing;

-- Cores da camisa listrada
create or replace function public.set_outfit_colors(_c1 text, _c2 text) returns public.characters
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters;
begin
  if _c1 !~ '^#[0-9a-fA-F]{6}$' or _c2 !~ '^#[0-9a-fA-F]{6}$' then raise exception 'Cor inválida.'; end if;
  select * into me from characters where user_id = uid for update;
  if not ('camisa_time' = any(me.owned_items)) then raise exception 'Compre a camisa listrada primeiro.'; end if;
  update characters set outfit = outfit || jsonb_build_object('cores', jsonb_build_array(lower(_c1), lower(_c2))) where id = me.id returning * into me;
  return me;
end $$;

-- 3) Movimento e duelo com pedágio e recompensa do procurado ------------
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
begin
  perform public.settle();
  leader := public.leader_id();
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
      end if;
    end if;

    -- 3) encontro na mesma casa vira duelo
    select * into me from characters where id = me.id;
    select ch.* into other from characters ch join board_nodes b on b.id = ch.node
     where ch.user_id <> uid and ch.node = me.node and ch.arrived_rank is null and b.kind not in ('inicio','castelo')
     order by random() limit 1 for update of ch;
    if other.id is not null then
      chance := 50 + (me.level - other.level) * (c->>'duel_level_factor')::int
                   + case when cls = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end
                   - case when other.class::text = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end;
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
    if sal > 0 then ev := ev || jsonb_build_object('t','pagamento','msg','Dia de pagamento: +' || sal || ' moedas de salário.'); end if;
    msg := public.check_arrival(me.id);
    if msg is not null then ev := ev || jsonb_build_object('t','castelo','msg', msg); end if;
  end if;

  xp_gain := base * (c->>'xp_per_step')::int + (c->>'xp_daily_bonus')::int + extra_xp;
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

create or replace function public.resolve_duel(_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare d duels; c jsonb := cfg(); w uuid; l uuid; cs int; os int; ch characters; op characters; chance int; leader uuid := public.leader_id(); bounty int := coalesce((cfg()->>'bounty_coins')::int, 60);
  wc characters; lc characters; msg text; what text;
begin
  select * into d from duels where id = _id for update;
  if d.status <> 'aceito' then return; end if;
  select * into ch from characters where user_id = d.challenger for update;
  select * into op from characters where user_id = d.opponent for update;
  if d.kind = 'quiz' then
    cs := case when d.c_solved then d.c_attempts else 99 end;
    os := case when d.o_solved then d.o_attempts else 99 end;
    if cs < os then w := d.challenger;
    elsif os < cs then w := d.opponent;
    elsif cs = 99 then w := null;
    else w := case when coalesce(d.c_done_at, 'infinity') <= coalesce(d.o_done_at, 'infinity') then d.challenger else d.opponent end;
    end if;
  else
    chance := 50 + (ch.level - op.level) * (c->>'duel_level_factor')::int
                 + case when ch.class::text = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end
                 - case when op.class::text = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end;
    chance := greatest(25, least(75, chance));
    w := case when random() * 100 < chance then d.challenger else d.opponent end;
  end if;
  what := case d.stake_kind when 'moedas' then d.stake || ' moedas' else d.stake || ' casas' end;
  if w is null then
    if d.stake_kind = 'moedas' then
      update characters set coins = coins + d.stake where user_id in (d.challenger, d.opponent);
    end if;
    msg := 'Duelo entre ' || ch.name || ' e ' || op.name || ' terminou sem vencedor. Ninguém acertou o Pokémon.';
  else
    l := case when w = d.challenger then d.opponent else d.challenger end;
    select * into wc from characters where user_id = w;
    select * into lc from characters where user_id = l;
    if d.stake_kind = 'moedas' then
      update characters set coins = coins + 2 * d.stake where user_id = w;
    else
      if wc.arrived_rank is null then perform public.walk(wc.id, d.stake); perform public.check_arrival(wc.id); end if;
      if lc.arrived_rank is null then perform public.go_back(lc.id, d.stake); end if;
    end if;
    msg := wc.name || ' venceu o duelo contra ' || lc.name || ' e levou ' || what || '.';
    if l = leader then
      update characters set coins = coins + bounty where user_id = w;
      msg := msg || ' Venceu o procurado e ganhou mais ' || bounty || ' moedas de recompensa!';
    end if;
  end if;
  update duels set status = 'concluido', winner = w, result = msg, resolved_at = now() where id = _id;
  insert into event_log(user_id, kind, message) values (coalesce(w, d.challenger), 'duelo', msg);
end $$;

-- 4) Segurança ----------------------------------------------------------
alter table public.properties enable row level security;
revoke all on public.properties from anon, authenticated;
grant select on public.properties to authenticated;
drop policy if exists p_props on public.properties;
create policy p_props on public.properties for select to authenticated using (true);
do $$ begin
  begin alter publication supabase_realtime add table public.properties; exception when duplicate_object then null; end;
end $$;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.username_available(text) to anon, authenticated;
grant execute on function public.has_role(uuid, public.app_role) to authenticated;
grant execute on function
  public.is_admin(), public.create_character(text, public.char_class),
  public.puzzle_state(public.puzzle_mode, date), public.make_guess(public.puzzle_mode, int, date),
  public.use_hint(public.puzzle_mode, date), public.use_retry(public.puzzle_mode, date), public.buy_help(text),
  public.spin_wheel(), public.set_route(int, text), public.use_skill(), public.change_class(public.char_class),
  public.today_overview(), public.day_status(date), public.move_today(), public.move_day(date),
  public.buy_item(text), public.equip_item(text, text), public.set_outfit_colors(text, text), public.place_trap(int),
  public.today_round(), public.ranking_period(text),
  public.market_refresh(), public.market_create(text, text, int, int, text, text, int), public.market_cancel(uuid), public.market_buy(uuid),
  public.create_duel(uuid, text, text, int), public.accept_duel(uuid), public.decline_duel(uuid), public.duel_state(uuid),
  public.duel_guess(uuid, int), public.duel_list(), public.place_bet(uuid, int), public.send_reaction(uuid, text), public.social_overview(),
  public.buy_property(int), public.sell_property(int),
  public.admin_players(), public.admin_set_status(uuid, text, text), public.admin_adjust(uuid, int, int, int, text),
  public.admin_reset_day(uuid, date, text), public.admin_set_config(jsonb, text), public.admin_undo_move(uuid, text),
  public.admin_new_season(text), public.admin_save_media(int, text, jsonb, text), public.admin_media_status()
to authenticated;
