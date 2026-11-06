-- =====================================================================
-- POKEGAMES — Benefícios do Quartel (pedido do dono em 06/11/2026).
-- A guerra continua opcional, mas o Quartel passa a valer a pena:
--  * 💰 soldo: 20/40/60 moedas por dia (nível 1/2/3), coletadas na vila junto com a Mina;
--  * ⚔️ +1/+2/+3 batalhas por dia com XP (além das 5 de sempre);
--  * 🐾 treino dos soldados: os Pokémon dos esquadrões ganham 50/100/150 XP por dia;
--  * 🛡️ Quartel novo vem com 72 h de escudo, e ele protege +100/+200/+300 moedas no saque.
-- Números em game_config.config.war (Ajustes do jogo → Vila e Guerras → Quartel Pokémon).
-- Quartel danificado não dá nada até ser consertado (como as outras construções).
-- Conserto junto: a Isca de frutas do Pesquisador às vezes dava Pokémon comum (pk_sync).
-- Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

alter table public.villages add column if not exists barracks_collected_at date;
alter table public.villages add column if not exists barracks_trained_on   date;
update public.villages set barracks_collected_at = public.game_today() where barracks_level > 0 and barracks_collected_at is null;

update public.game_config
   set config = jsonb_set(config, '{war,buildings,quartel}', (config->'war'->'buildings'->'quartel')
         || '{"soldo": [20, 40, 60], "batalhas_xp": [1, 2, 3], "treino_xp": [50, 100, 150], "protect": [100, 200, 300]}'::jsonb)
 where active and config->'war'->'buildings' ? 'quartel' and not (config->'war'->'buildings'->'quartel' ? 'soldo');
update public.game_config set config = jsonb_set(config, '{war,quartel_escudo_horas}', '72'::jsonb)
 where active and config ? 'war' and not (config->'war' ? 'quartel_escudo_horas');

-- batalhas extras com XP do Quartel
create or replace function public.quartel_batalhas_extra(_uid uuid) returns int
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((select public.war_num('quartel', 'batalhas_xp', public.vl_level(v, 'quartel'))::int from villages v where v.user_id = _uid), 0)
$$;

-- treino diário dos soldados (Pokémon dos esquadrões de ataque e defesa), uma vez por dia
create or replace function public.quartel_treino(_uid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v villages; xp int; r record;
begin
  select * into v from villages where user_id = _uid for update;
  if v.user_id is null or public.vl_level(v, 'quartel') < 1 or coalesce(v.barracks_trained_on, '-infinity'::date) >= public.game_today() then return; end if;
  update villages set barracks_trained_on = public.game_today() where user_id = _uid;
  xp := public.war_num('quartel', 'treino_xp', public.vl_level(v, 'quartel'))::int;
  if xp <= 0 then return; end if;
  for r in select distinct monster_id from war_squads where user_id = _uid loop
    perform public.pk_give_xp(r.monster_id, xp, 'quartel');
  end loop;
end $$;

-- produção da vila (versão do 25 + soldo do Quartel)
create or replace function public.village_pending(v public.villages) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare c jsonb := cfg(); t date := game_today(); md int := (cfg()->>'collect_max_days')::int; tz text := coalesce(cfg()->>'timezone', 'America/Sao_Paulo');
  e_mine date; e_tower date; e_orch date; e_forge date; e_stab date; e_quart date; soldo int := 0;
begin
  e_mine  := case when v.damaged ? 'mina'     then least(t, ((v.damaged->'mina'->>'at')::timestamptz at time zone tz)::date) else t end;
  e_tower := case when v.damaged ? 'torre'    then least(t, ((v.damaged->'torre'->>'at')::timestamptz at time zone tz)::date) else t end;
  e_orch  := case when v.damaged ? 'pomar'    then least(t, ((v.damaged->'pomar'->>'at')::timestamptz at time zone tz)::date) else t end;
  e_forge := case when v.damaged ? 'ferreiro' then least(t, ((v.damaged->'ferreiro'->>'at')::timestamptz at time zone tz)::date) else t end;
  e_stab  := case when v.damaged ? 'estabulo' then least(t, ((v.damaged->'estabulo'->>'at')::timestamptz at time zone tz)::date) else t end;
  -- arquivo 79: soldo do Quartel (moedas por dia, para quando ele está danificado)
  e_quart := case when v.damaged ? 'quartel' then least(t, ((v.damaged->'quartel'->>'at')::timestamptz at time zone tz)::date) else t end;
  if v.barracks_level > 0 then
    soldo := least(md, greatest(0, e_quart - coalesce(v.barracks_collected_at, t))) * public.war_num('quartel', 'soldo', v.barracks_level)::int;
  end if;
  return jsonb_build_object(
    'coins',   case when v.mine_level > 0 then least(md, greatest(0, e_mine - coalesce(v.mine_collected_at, t))) * (c->'mine_rates'->>(v.mine_level - 1))::int else 0 end + soldo,
    'hints',   case when v.tower_level > 0 then least((c->>'tower_max')::int, greatest(0, (e_tower - coalesce(v.tower_collected_at, t)) / (c->>'tower_days')::int)) else 0 end,
    'xp',      case when v.orchard_level > 0 then least(md, greatest(0, e_orch - coalesce(v.orchard_collected_at, t))) * (c->>'orchard_xp')::int else 0 end,
    'retries', case when v.forge_level > 0 then least((c->>'forge_max')::int, greatest(0, (e_forge - coalesce(v.forge_collected_at, t)) / (c->>'forge_days')::int)) else 0 end,
    'steps',   case when v.stable_level > 0 then least((c->>'stable_max')::int, greatest(0, (e_stab - coalesce(v.stable_collected_at, t)) / (c->>'stable_days')::int)) else 0 end,
    'until',   jsonb_build_object('mina', e_mine, 'torre', e_tower, 'pomar', e_orch, 'ferreiro', e_forge, 'estabulo', e_stab, 'quartel', e_quart));
end $$;

-- coleta (versão do 25 + soldo)
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
    stable_collected_at  = case when (p->>'steps')::int > 0 then (p->'until'->>'estabulo')::date else stable_collected_at end,
    barracks_collected_at = case when v.barracks_level > 0 then (p->'until'->>'quartel')::date else barracks_collected_at end
  where user_id = uid;
  select * into me from characters where user_id = uid for update;
  update characters set
    coins = coins + (p->>'coins')::int, hints = hints + (p->>'hints')::int, retries = retries + (p->>'retries')::int,
    bonus_steps = bonus_steps + (p->>'steps')::int,
    xp_total = xp_total + (p->>'xp')::int, level = public.level_for_xp(me.xp_total + (p->>'xp')::int)
  where id = me.id;
  return p - 'until';
end $$;

-- construir e melhorar (versão do 25 + escudo e soldo do Quartel novo)
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
  -- arquivo 79: Quartel novo começa o soldo hoje e ganha escudo (ninguém ataca nos primeiros dias)
  if _kind = 'quartel' and lvl = 0 then
    update villages set barracks_collected_at = public.game_today(),
           shield_until = greatest(coalesce(shield_until, now()), now() + make_interval(hours => coalesce((public.war_cfg()->>'quartel_escudo_horas')::int, 72)))
     where user_id = uid;
  end if;
  nm := case when lvl = 0 then 'construiu ' || (b->>'name') else 'melhorou ' || (b->>'name') || ' para o nível ' || nl end;
  insert into event_log(user_id, kind, message) values (uid, 'vila', me.name || ' ' || nm || '.');
  return public.village_state(null);
end $$;

-- ataque (versão do 25 + o Quartel protege moedas do saque)
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
                             'atk_tactic', atac, 'def_tactic', dtac))
  returning * into wr;
  reason := case when winner = uid then ach.name || ' invadiu a vila de ' || dch.name || ' e levou ' || loot || ' moedas!'
                 when winner = _target then 'A defesa de ' || dch.name || ' segurou o ataque de ' || ach.name || '!'
                 else ach.name || ' e ' || dch.name || ' empataram na guerra.' end;
  insert into event_log(user_id, kind, message) values (uid, 'guerra', reason);
  return to_jsonb(wr) || jsonb_build_object('message', reason);
end $$;

-- fim da batalha (versão do 54 + batalhas extras com XP do Quartel)
create or replace function public.bt_finish(_id uuid, _winner uuid, _reason text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b battles; c jsonb := public.pk_cfg(); k text; v int; owner uuid; limit_n int := (c->'xp'->>'battles_per_day')::int; wn text; ln text;
begin
  select * into b from battles where id = _id for update;
  if b.status <> 'ativa' then return; end if;
  if b.mode = 'treino' then   -- Grama de Treino (arquivo 54): o XP é do treino, não das batalhas
    update battles set status = 'encerrada', winner = _winner, end_reason = _reason, ended_at = now(), deadline = null, rewarded = true where id = b.id;
    return;
  end if;
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
          and (x.ended_at at time zone coalesce(public.cfg()->>'timezone','America/Sao_Paulo'))::date = public.game_today()) >= limit_n + public.quartel_batalhas_extra(owner) then continue; end if;   -- arquivo 79: Quartel dá batalhas extras com XP
    perform public.pk_give_xp(k::uuid, v, 'batalha');
  end loop;
  update battles set rewarded = true where id = b.id;
  if b.mode = 'liga' then perform public.league_decide((select id from league_matches where battle_id = b.id), _winner, false); end if;
  if b.mode in ('guerra', 'liga', 'npc', 'rocket') then return; end if;
  select name into wn from characters where user_id = _winner;
  select name into ln from characters where user_id = case when _winner = b.p1 then b.p2 else b.p1 end;
  if _winner is not null then insert into event_log(user_id, kind, message) values (_winner, 'batalha', wn || ' venceu a batalha Pokémon contra ' || ln || case when b.bet > 0 and b.bet_paid then ' e levou ' || 2 * b.bet || ' moedas' else '' end || '!'); end if;
end $$;

-- pk_sync (versão do 77 + treino dos soldados)
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
    lv := least(100, greatest(1, (c->'encounter'->>'level_min')::int
                + floor((1 - coalesce(nd.dist, maxd)::numeric / greatest(maxd, 1)) * (c->'encounter'->>'level_span')::int)::int
                + floor(random() * ((c->'encounter'->>'level_spread')::int + 1))::int));
    end if;
    insert into encounters(user_id, move_id, node, species_id, level, throws_left, hunt_id)
    values (uid, dm.id, dm.to_node, sp, lv, (c->'capture'->>'throws')::int + case when hcls = 'pesquisador' then (public.herois_cfg()->>'pesq_bolas')::int else 0 end, hh.id) on conflict (move_id) do nothing;
    perform public.pk_dex_mark(uid, sp, false);
  end loop;
  select * into enc from encounters where user_id = uid and status = 'aberto' order by created_at desc limit 1;
  return jsonb_build_object('encounter', case when enc.id is null then null else to_jsonb(enc) end,
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.id) from mon_events e where e.user_id = uid and not e.seen), '[]'::jsonb));
end $$;

revoke execute on function public.quartel_batalhas_extra(uuid), public.quartel_treino(uuid) from public, anon, authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🪖 O Quartel agora vale a pena', 'O Quartel Pokémon ganhou vantagens para quem tem (a guerra continua opcional):
• 💰 Soldo: 20, 40 ou 60 moedas por dia (nível 1, 2 ou 3), coletadas na vila junto com a Mina.
• ⚔️ Mais batalhas com XP: +1, +2 ou +3 por dia, além das 5 de sempre.
• 🐾 Treino dos soldados: os Pokémon dos seus esquadrões ganham 50, 100 ou 150 XP todo dia.
• 🛡️ Quartel novo vem com 3 dias de escudo, e ele protege mais 100, 200 ou 300 moedas no saque.
Construa em Minha Vila → ⚔️ Pokémon e guerra.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
