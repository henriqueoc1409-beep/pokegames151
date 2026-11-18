-- 125_guerra_trocas_rocket_golpes_quiz_lama.sql
-- Pacote de correções e novidades pedido pelo dono:
--   1. Guerra de vilas sem travamento: escolha de ataques pelas regras do pacote 1 (ia_pick + ia_memo: nunca usa ataque 0x,
--      prefere super efetivo, no máximo 1 status a cada 3 turnos), troca automática quando o Pokémon ativo não tem ataque que
--      afete o adversário, encerramento imediato por impasse quando nenhum lado consegue causar dano, e limite de 50 turnos
--      (vence quem tiver maior % de vida somada no esquadrão).
--   2. Troca de Pokémon com vitrine ("aceito trocar") e aprovação dupla em 3 passos (propor -> escolher -> aprovar), mantendo
--      limite semanal, trava de 7 dias, taxa e evolução por troca. Outros jogadores só veem a vitrine, nunca a coleção inteira.
--   3. Equipe Rocket (invasão): barra pela média histórica das invasões em ondas disponíveis (desde a 1ª, até as 3 últimas) ×
--      jogadores ativos × multiplicador; lista oficial de 15 linhas evolutivas respeitando os níveis exatos de evolução; golpes
--      de cobertura; ondas que sempre acertam o cedido (>= 1x) e pelo menos 1 a cada 3 ondas com vantagem de tipo (> 1x); sorteio
--      de roubo na derrota incluindo todos os ativos (peso 2 para quem não participou, levando 1 da equipe; peso 1 para quem
--      participou, levando o cedido).
--   4. Ataque surpresa da Equipe Rocket às vilas: 2 por semana em dias sem invasão da Rocket, peso pelo saldo (mínimo 100),
--      máx. 1 a cada 7 dias por vila, ativos com >= 7 dias de jogo, aviso 24h antes, até 2 reforços de amigos limitados ao nível
--      do Pokémon mais forte do dono, força 100%-120% da defesa completa, vitória (75-200 moedas + 25% extra aos ajudantes + XP +
--      chance de Doce de Forja + conta em "defesas vencidas"), derrota (10% desprotegido até 200 + 1 construção danificada + escudo
--      24h; 0 derrubados leva 1 Pokémon do dono para base de resgate de 7 dias).
--   5. Revanches de ginásio: só as 3 primeiras revanches vencidas do dia (somando todos os ginásios) pagam moedas; as seguintes dão só XP.
--   7. Quiz: mantém visível o resultado completo do último quiz encerrado mesmo quando abre um novo ou passam 3 dias.
--   8. Lama na vila: sai sozinha 72h depois de aparecer (continua podendo limpar antes pagando).

-- ============================================================================
-- 1. GUERRA DE VILAS: ESCOLHA DE ATAQUES (PACOTE 1), TROCA E REGRA DE IMPASSE
-- ============================================================================

update public.game_config
   set config = jsonb_set(config, '{war,max_turns}', '50'::jsonb)
 where active and coalesce((config->'war'->>'max_turns')::int, 60) > 50;

-- verifica se _mon (vivo) tem pelo menos 1 ataque com PP que cause dano em _def
create or replace function public.war_mon_afeta(_mon jsonb, _def jsonb) returns boolean
language plpgsql stable security definer set search_path = public, extensions as $$
declare i int; mv pk_moves; eff numeric;
begin
  if _mon is null or _def is null or coalesce((_mon->>'hp')::int, 0) <= 0 or coalesce((_mon->>'oculto')::boolean, false) then
    return false;
  end if;
  for i in 0 .. coalesce(jsonb_array_length(_mon->'moves'), 0) - 1 loop
    continue when coalesce((_mon->'moves'->i->>'pp')::int, 0) <= 0;
    select * into mv from pk_moves where id = (_mon->'moves'->i->>'id')::int;
    continue when mv.id is null or public.ia_inutil(mv) or not public.ia_dano(mv);
    continue when mv.effect = 'DREAM_EATER_EFFECT' and coalesce(_def->>'status', '') <> 'SLP';
    if mv.effect in ('SPECIAL_DAMAGE_EFFECT', 'SUPER_FANG_EFFECT') then
      return true;
    end if;
    eff := public.bt_eff(mv.type, _def->>'t1', _def->>'t2');
    continue when eff <= 0;
    continue when mv.effect = 'OHKO_EFFECT' and coalesce((_mon->>'spd')::int, 0) < coalesce((_def->>'spd')::int, 0);
    return true;
  end loop;
  return false;
end $$;

-- escolhe outro Pokémon vivo do esquadrão que consiga causar dano no adversário atual (-1 se nenhum conseguir)
create or replace function public.war_troca_util(_s jsonb, _a int) returns int
language plpgsql stable security definer set search_path = public, extensions as $$
declare ai int := (_s->'sides'->_a->>'active')::int;
  D jsonb := _s->'sides'->(1 - _a)->'mons'->((_s->'sides'->(1 - _a)->>'active')::int);
  i int; m jsonb; sc numeric; bs numeric := -1; best int := -1;
begin
  for i in 0 .. jsonb_array_length(_s->'sides'->_a->'mons') - 1 loop
    m := _s->'sides'->_a->'mons'->i;
    continue when i = ai or coalesce((m->>'hp')::int, 0) <= 0 or coalesce((m->>'oculto')::boolean, false);
    continue when not public.war_mon_afeta(m, D);
    sc := greatest(public.bt_eff(m->>'t1', D->>'t1', D->>'t2'), coalesce(public.bt_eff(m->>'t2', D->>'t1', D->>'t2'), 0), 0.5)
          / greatest(0.25, greatest(public.bt_eff(D->>'t1', m->>'t1', m->>'t2'), coalesce(public.bt_eff(D->>'t2', m->>'t1', m->>'t2'), 0)));
    if sc > bs then bs := sc; best := i; end if;
  end loop;
  return best;
end $$;

-- verifica se há algum par (meu vivo, inimigo vivo) em que _a consegue causar dano
create or replace function public.war_lado_pode_dano(_s jsonb, _a int) returns boolean
language plpgsql stable security definer set search_path = public, extensions as $$
declare i int; j int; m jsonb; d jsonb;
begin
  for i in 0 .. jsonb_array_length(_s->'sides'->_a->'mons') - 1 loop
    m := _s->'sides'->_a->'mons'->i;
    continue when coalesce((m->>'hp')::int, 0) <= 0 or coalesce((m->>'oculto')::boolean, false);
    for j in 0 .. jsonb_array_length(_s->'sides'->(1 - _a)->'mons') - 1 loop
      d := _s->'sides'->(1 - _a)->'mons'->j;
      continue when coalesce((d->>'hp')::int, 0) <= 0 or coalesce((d->>'oculto')::boolean, false);
      if public.war_mon_afeta(m, d) then return true; end if;
    end loop;
  end loop;
  return false;
end $$;

-- troca após desmaio: dá preferência a quem consegue acertar o adversário em campo
create or replace function public.war_switch(_s jsonb, _a integer, _smart boolean) returns integer
language plpgsql security definer set search_path = public, extensions as $$
declare D jsonb := _s->'sides'->(1 - _a)->'mons'->((_s->'sides'->(1 - _a)->>'active')::int);
  i int; m jsonb; sc numeric; bs numeric := -1; best int := -1; util int;
begin
  util := public.war_troca_util(_s, _a);
  if util >= 0 and not _smart then
    for i in 0 .. jsonb_array_length(_s->'sides'->_a->'mons') - 1 loop
      m := _s->'sides'->_a->'mons'->i;
      continue when (m->>'hp')::int <= 0 or i = (_s->'sides'->_a->>'active')::int;
      if public.war_mon_afeta(m, D) then return i; end if;
    end loop;
  end if;
  if util >= 0 and _smart then return util; end if;
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

-- war_pick atualizada como segurança para qualquer chamada direta (corrige Night Shade / Super Fang contra imunes)
create or replace function public.war_pick(_s jsonb, _a integer, _tactic text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  return public.ia_pick(_s, _a, case when _tactic = 'segura' then 'selvagem' else 'lider' end, 1);
end $$;

-- roda os turnos automáticos de guerra (entre vilas ou ataque da Rocket à vila) com ia_pick, troca contra imune e impasse
create or replace function public.war_rodar_luta(_bid uuid, _u0 uuid, _u1 uuid, _tac0 text, _tac1 text, _sm0 boolean, _sm1 boolean, _max_turns int default 50)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b battles; it int := 0; side int; A jsonb; D jsonb; sw int; p jsonb;
  pct0 numeric; pct1 numeric; trocas_seg int := 0; teve_ataque boolean; impasse boolean;
begin
  loop
    select * into b from battles where id = _bid;
    exit when b.id is null or b.status <> 'ativa' or b.turn > coalesce(_max_turns, 50);
    it := it + 1; exit when it > 300;
    if b.phase = 'troca' then
      for side in 0 .. 1 loop
        if coalesce((b.state->'sides'->side->>'need_switch')::boolean, false) then
          insert into battle_actions(battle_id, turn, side, user_id, kind, value)
          values (b.id, b.turn, side, case when side = 0 then _u0 else _u1 end, 'switch',
                  public.war_switch(b.state, side, case when side = 0 then _sm0 else _sm1 end));
        end if;
      end loop;
      perform public.bt_resolve(b.id);
      continue;
    end if;

    -- checa impasse: nenhum lado tem como causar dano em ninguém do outro lado, ou os ativos não se afetam e ninguém tem troca útil
    A := b.state->'sides'->0->'mons'->((b.state->'sides'->0->>'active')::int);
    D := b.state->'sides'->1->'mons'->((b.state->'sides'->1->>'active')::int);
    impasse := (not public.war_lado_pode_dano(b.state, 0) and not public.war_lado_pode_dano(b.state, 1))
            or (not public.war_mon_afeta(A, D) and public.war_troca_util(b.state, 0) < 0
                and not public.war_mon_afeta(D, A) and public.war_troca_util(b.state, 1) < 0)
            or trocas_seg >= 6;
    if impasse then
      select sum((x->>'hp')::int)::numeric / greatest(1, sum((x->>'maxhp')::int)) into pct0 from jsonb_array_elements(b.state->'sides'->0->'mons') x;
      select sum((x->>'hp')::int)::numeric / greatest(1, sum((x->>'maxhp')::int)) into pct1 from jsonb_array_elements(b.state->'sides'->1->'mons') x;
      update battles set log = log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt',
        'Impasse! Nenhum lado consegue causar dano: vence quem ficou com maior % de vida no esquadrão.')))) where id = b.id;
      perform public.bt_finish(b.id, case when pct0 > pct1 then _u0 when pct1 > pct0 then _u1 else null end, 'impasse');
      return;
    end if;

    teve_ataque := false;
    for side in 0 .. 1 loop
      select * into b from battles where id = _bid;
      A := b.state->'sides'->side->'mons'->((b.state->'sides'->side->>'active')::int);
      D := b.state->'sides'->(1 - side)->'mons'->((b.state->'sides'->(1 - side)->>'active')::int);
      if coalesce(A->'fl'->>'charging', '') = '' and not coalesce((A->'fl'->>'recharge')::boolean, false)
         and not public.war_mon_afeta(A, D) then
        sw := public.war_troca_util(b.state, side);
        if sw >= 0 then
          insert into battle_actions(battle_id, turn, side, user_id, kind, value)
          values (b.id, b.turn, side, case when side = 0 then _u0 else _u1 end, 'switch', sw);
          continue;
        end if;
      end if;
      p := public.ia_pick(b.state, side, case when (case when side = 0 then _tac0 else _tac1 end) = 'segura' then 'selvagem' else 'lider' end, b.turn);
      update battles set state = public.ia_memo(state, side, p, b.turn) where id = b.id;
      insert into battle_actions(battle_id, turn, side, user_id, kind, value)
      values (b.id, b.turn, side, case when side = 0 then _u0 else _u1 end, p->>'kind', (p->>'value')::int);
      teve_ataque := true;
    end loop;
    if teve_ataque then trocas_seg := 0; else trocas_seg := trocas_seg + 1; end if;
    perform public.bt_resolve(b.id);
  end loop;

  select * into b from battles where id = _bid;
  if b.id is not null and b.status = 'ativa' then
    select sum((x->>'hp')::int)::numeric / greatest(1, sum((x->>'maxhp')::int)) into pct0 from jsonb_array_elements(b.state->'sides'->0->'mons') x;
    select sum((x->>'hp')::int)::numeric / greatest(1, sum((x->>'maxhp')::int)) into pct1 from jsonb_array_elements(b.state->'sides'->1->'mons') x;
    update battles set log = log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt',
      'Fim dos ' || coalesce(_max_turns, 50) || ' turnos da guerra! Vence quem ficou com maior % de vida no esquadrão.')))) where id = b.id;
    perform public.bt_finish(b.id, case when pct0 > pct1 then _u0 when pct1 > pct0 then _u1 else null end, 'limite');
  end if;
end $$;

-- war_attack (versão do 115 com war_rodar_luta e teto de 50 turnos)
create or replace function public.war_attack(_target uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); w jsonb := public.war_cfg(); t date := public.game_today(); tz text := coalesce(public.cfg()->>'timezone', 'America/Sao_Paulo');
  av villages; dv villages; ach characters; dch characters; tg jsonb; s0 jsonb; s1 jsonb; b battles; side int; m jsonb;
  bonus numeric; trap numeric; cap numeric; atac text; dtac text; asmart boolean; dsmart boolean; winner uuid;
  att_lost int; def_lost int; prot int; loot int := 0; nd int; k text; pool text[]; dmg text[] := '{}'; red numeric; wr wars; i int; reason text; pago int := 0;
  max_t int := least(50, coalesce((w->>'max_turns')::int, 50));
begin
  if _target = uid then raise exception 'Você não pode atacar a própria vila.'; end if;
  insert into villages(user_id) values (_target) on conflict do nothing;
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
    perform public.war_rodar_luta(b.id, uid, _target, atac, dtac, asmart, dsmart, max_t);
  end if;

  select * into b from battles where id = b.id;
  winner := b.winner;
  if winner = _target then
    pago := least(coalesce((public.guerra_cfg()->>'defesa_max')::int, 150),
                  floor(greatest(0, (select coins from characters where user_id = uid)) * coalesce((public.guerra_cfg()->>'defesa_pct')::numeric, 5) / 100))::int;
    if pago > 0 then
      update characters set coins = coins - pago where user_id = uid;
      update characters set coins = coins + pago where user_id = _target;
    end if;
  end if;

  for side in 0 .. 1 loop
    for m in select x from jsonb_array_elements(b.state->'sides'->side->'mons') x loop
      update monsters set war_hp = greatest(0, least(100, floor((m->>'hp')::int * 100.0 / greatest(1, (m->>'maxhp')::int))))::int,
                          war_hurt_at = case when (m->>'hp')::int < (m->>'maxhp')::int then now() else war_hurt_at end
       where id = (m->>'id')::uuid;
    end loop;
  end loop;
  select count(*) filter (where (x->>'hp')::int <= 0) into att_lost from jsonb_array_elements(b.state->'sides'->0->'mons') x;
  select count(*) filter (where (x->>'hp')::int <= 0) into def_lost from jsonb_array_elements(b.state->'sides'->1->'mons') x;

  if winner = uid then
    prot := (w->>'base_protect')::int + public.war_num('cofre', 'protect', public.vl_level(dv, 'cofre'))::int
          + public.war_num('quartel', 'protect', public.vl_level(dv, 'quartel'))::int;
    loot := least((w->>'loot_max')::int, floor(greatest(0, dch.coins - prot) * (w->>'loot_pct')::numeric / 100))::int;
    loot := greatest(0, least(loot, dch.coins));
    if loot > 0 then
      update characters set coins = coins - loot where user_id = _target;
      update characters set coins = coins + loot where user_id = uid;
    end if;
    nd := 1 + case when att_lost = 0 then 1 else 0 end;
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
                             'atk_tactic', atac, 'def_tactic', dtac, 'pago', pago, 'sem_quartel', coalesce(dv.barracks_level, 0) < 1))
  returning * into wr;
  reason := case when winner = uid then ach.name || ' invadiu a vila de ' || dch.name || ' e levou ' || loot || ' moedas!'
                 when winner = _target then 'A defesa de ' || dch.name || ' segurou o ataque de ' || ach.name || '!' || case when pago > 0 then ' ' || ach.name || ' pagou ' || pago || ' moedas a ' || dch.name || '.' else '' end
                 else ach.name || ' e ' || dch.name || ' empataram na guerra.' end;
  insert into event_log(user_id, kind, message) values (uid, 'guerra', reason);
  return to_jsonb(wr) || jsonb_build_object('message', reason);
end $$;


-- ============================================================================
-- 4 (TABELAS ANTES DO 2 E 3 PARA AS TRAVAS DE EMPRÉSTIMO FUNCIONAREM)
-- ============================================================================

create or replace function public.rocket_vila_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "por_semana": 2, "hora": 19, "aviso_horas": 24, "cooldown_dias": 7, "idade_min_dias": 7,
           "peso_min_moedas": 100, "reforcos_max": 2, "forca_min_pct": 100, "forca_max_pct": 120,
           "moedas_min": 75, "moedas_max": 200, "moedas_por_forca": 1.2, "ajudante_bonus_pct": 25,
           "saque_pct": 10, "saque_max": 200, "doce_pct": 25}'::jsonb
         || coalesce(public.cfg()->'rocket_vila', '{}'::jsonb)
$$;

create table if not exists public.rocket_vila_ataques (
  id           bigserial primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,
  nome         text not null,
  semana       date not null,
  dia_ataque   date not null,
  avisado_em   timestamptz not null default now(),
  ataca_em     timestamptz not null,
  resolvido_em timestamptz,
  status       text not null default 'agendado' check (status in ('agendado', 'vitoria', 'derrota', 'cancelado')),
  def_forca    int not null default 0,
  rk_forca     int not null default 0,
  rk_pct       int not null default 100,
  rk_time      jsonb,
  moedas       int not null default 0,
  saque        int not null default 0,
  doce         int not null default 0,
  damaged      text[] not null default '{}',
  rk_caidos    int not null default 0,
  def_caidos   int not null default 0,
  roubado_info jsonb,
  log          jsonb,
  def_seen     boolean not null default false
);
create index if not exists rocket_vila_ataques_user on public.rocket_vila_ataques (user_id, avisado_em desc);
create index if not exists rocket_vila_ataques_status on public.rocket_vila_ataques (status, ataca_em);
alter table public.rocket_vila_ataques enable row level security;

create table if not exists public.rocket_vila_reforcos (
  ataque_id   bigint not null references public.rocket_vila_ataques(id) on delete cascade,
  amigo_id    uuid not null references auth.users(id) on delete cascade,
  amigo_nome  text not null,
  mon_id      uuid not null references public.monsters(id) on delete cascade,
  mon_nome    text not null,
  species     int not null,
  level_real  int not null,
  xp          int not null default 0,
  moedas      int not null default 0,
  criado_em   timestamptz not null default now(),
  primary key (ataque_id, amigo_id)
);
alter table public.rocket_vila_reforcos enable row level security;

create or replace function public.rocket_vila_mon_preso(_mon uuid) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (
    select 1 from public.rocket_vila_reforcos rf
      join public.rocket_vila_ataques a on a.id = rf.ataque_id
     where rf.mon_id = _mon and a.status = 'agendado'
  )
$$;


-- ============================================================================
-- 2. TROCA DE POKÉMON: VITRINE ("ACEITO TROCAR") E APROVAÇÃO DUPLA EM 3 PASSOS
-- ============================================================================

alter table public.monsters add column if not exists aceita_troca boolean not null default false;

-- outros jogadores só enxergam os Pokémon marcados na vitrine (nunca a coleção inteira)
drop policy if exists p_mon on public.monsters;
create policy p_mon on public.monsters for select to authenticated
  using (user_id = auth.uid() or aceita_troca = true or public.is_admin());

alter table public.trocas alter column mon_para drop not null;
alter table public.trocas add column if not exists mon_pedido uuid;
alter table public.trocas add column if not exists moedas_para_guardadas boolean not null default false;
alter table public.trocas drop constraint if exists trocas_status_check;
alter table public.trocas add constraint trocas_status_check
  check (status in ('pendente', 'confirmar', 'aceita', 'recusada', 'cancelada', 'expirou'));

insert into public.moedas_origens(padrao, origem, tipo, prioridade) values
  ('troca_escolher', 'Troca de Pokémon (moedas guardadas)', 'trocas', 30),
  ('rocket_vila_%', 'Ataque da Rocket à vila', 'guerra', 30)
on conflict (padrao) do update set origem = excluded.origem, tipo = excluded.tipo, prioridade = excluded.prioridade;

create or replace function public.troca_motivo(_uid uuid, _mon uuid, _ignora bigint default null) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare m monsters; dias int := coalesce((public.troca_cfg()->>'trava_dias')::int, 7);
begin
  select * into m from monsters where id = _mon;
  if m.id is null or m.user_id is distinct from _uid then return 'Esse Pokémon não é mais de quem estava na troca.'; end if;
  if exists (select 1 from creche_pedidos where mon_id = _mon and status = 'treinando') then return 'Esse Pokémon está na Creche.'; end if;
  if exists (select 1 from war_squads where monster_id = _mon) then return 'Esse Pokémon está num esquadrão de guerra.'; end if;
  if exists (select 1 from characters where user_id = _uid and rpg_suporte = _mon) then return 'Esse Pokémon é o suporte da Aventura.'; end if;
  if public.rocket_vila_mon_preso(_mon) then return 'Esse Pokémon está emprestado na defesa contra a Equipe Rocket.'; end if;
  perform public.rpg_gin_expira(_uid);
  if public.gin_preso(_uid, _mon) then return 'Esse Pokémon está numa batalha de Ginásio em andamento.'; end if;
  if exists (select 1 from rpg_elite_run where user_id = _uid and status = 'andando' and meus ? _mon::text) then return 'Esse Pokémon está no Desafio do Planalto em andamento.'; end if;
  if exists (select 1 from battles b, jsonb_array_elements(b.state->'sides') sd, jsonb_array_elements(sd->'mons') mm
              where b.status = 'ativa' and _uid in (b.p1, b.p2) and mm->>'id' = _mon::text) then return 'Esse Pokémon está numa batalha em andamento.'; end if;
  if exists (select 1 from leiloes where mon_id = _mon and status = 'aberto') then return 'Esse Pokémon está no Leilão.'; end if;
  if m.troca_em is not null and m.troca_em > now() - make_interval(days => dias) then
    return 'Esse Pokémon chegou por troca há pouco: só pode ser trocado de novo ' || to_char(m.troca_em + make_interval(days => dias), 'DD/MM') || '.';
  end if;
  if exists (select 1 from trocas where status in ('pendente', 'confirmar') and (mon_de = _mon or mon_para = _mon) and id is distinct from _ignora) then
    return 'Esse Pokémon já está numa proposta de troca.'; end if;
  return null;
end $$;

-- marca ou desmarca um Pokémon da própria coleção na vitrine ("aceito trocar")
create or replace function public.mon_troca_vitrine(_mon uuid, _on boolean default true) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); m monsters; mot text;
begin
  select * into m from monsters where id = _mon and user_id = uid for update;
  if m.id is null then raise exception 'Escolha um Pokémon da sua coleção.'; end if;
  if coalesce(_on, false) then
    mot := public.troca_motivo(uid, _mon);
    if mot is not null then raise exception '%', mot; end if;
  end if;
  update monsters set aceita_troca = coalesce(_on, false) where id = _mon and user_id = uid;
  return coalesce(_on, false);
end $$;

create or replace function public.troca_passa(_mon uuid, _de uuid, _para uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare sp int;
begin
  update monsters set user_id = _para, team_slot = null, aceita_troca = false, troca_em = now()
   where id = _mon and user_id = _de returning species_id into sp;
  delete from war_squads where monster_id = _mon;
  update characters set mascot = null where user_id = _de and (mascot->>'id')::uuid = _mon;
  update characters set rpg_suporte = null where user_id = _de and rpg_suporte = _mon;
  perform public.pk_dex_mark(_para, sp, true);
end $$;

create or replace function public.troca_devolver(_t public.trocas) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if coalesce(_t.moedas_de, 0) > 0 then
    perform public.ext_origem('Troca de Pokémon (devolução)', 'trocas');
    update characters set coins = coins + _t.moedas_de where user_id = _t.de;
  end if;
  if coalesce(_t.moedas_para_guardadas, false) and coalesce(_t.moedas_para, 0) > 0 then
    perform public.ext_origem('Troca de Pokémon (devolução)', 'trocas');
    update characters set coins = coins + _t.moedas_para where user_id = _t.para;
  end if;
end $$;

create or replace function public.troca_tick() returns integer
language plpgsql security definer set search_path = public, extensions as $$
declare t trocas; n int := 0;
begin
  for t in select * from trocas where status in ('pendente', 'confirmar') and expira_em <= now() for update skip locked loop
    perform public.troca_devolver(t);
    update trocas set status = 'expirou', fim = now() where id = t.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- coleção para troca: para você mesmo traz a sua coleção inteira; para outro jogador traz SÓ a vitrine dele
create or replace function public.troca_colecao(_user uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  if _user = uid then
    return coalesce((select jsonb_agg(public.troca_mon_pub(m.id) || jsonb_build_object('aceita_troca', m.aceita_troca, 'motivo', public.troca_motivo(_user, m.id))
                       order by m.aceita_troca desc, m.level desc, m.species_id)
                       from monsters m where m.user_id = _user), '[]'::jsonb);
  end if;
  return coalesce((select jsonb_agg(public.troca_mon_pub(m.id) || jsonb_build_object('aceita_troca', true, 'motivo', public.troca_motivo(_user, m.id))
                     order by m.level desc, m.species_id)
                     from monsters m where m.user_id = _user and m.aceita_troca = true), '[]'::jsonb);
end $$;

-- passo 1: 1º jogador escolhe o Pokémon dele, com qual jogador, pedido opcional da vitrine do outro e moedas dele
drop function if exists public.troca_propor(uuid, uuid, uuid, integer, integer);
create or replace function public.troca_propor(_para uuid, _mon_de uuid, _mon_pedido uuid default null, _moedas_de int default 0) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.troca_cfg(); me characters; mot text; t trocas; lim int := (c->>'semana_max')::int;
begin
  if not coalesce((c->>'on')::boolean, true) then raise exception 'As trocas estão fechadas no momento.'; end if;
  perform public.troca_tick();
  if _para is null or _para = uid then raise exception 'Escolha outro jogador para trocar.'; end if;
  if not exists (select 1 from characters where user_id = _para) then raise exception 'Esse jogador não existe.'; end if;
  _moedas_de := coalesce(_moedas_de, 0);
  if _moedas_de < 0 then raise exception 'As moedas não podem ser negativas.'; end if;
  if _moedas_de > (c->>'moedas_max')::int then raise exception 'No máximo % moedas de cada lado.', c->>'moedas_max'; end if;
  if public.troca_semana(uid) >= lim then raise exception 'Você já fez % trocas esta semana, que é o limite. Volte na segunda!', lim; end if;
  if public.troca_semana(_para) >= lim then raise exception 'Esse jogador já fez as % trocas da semana.', lim; end if;
  if (select count(*) from trocas where de = uid and status in ('pendente', 'confirmar')) >= (c->>'pendentes_max')::int then
    raise exception 'Você já tem % propostas em andamento. Espere ou cancele alguma.', c->>'pendentes_max'; end if;
  mot := public.troca_motivo(uid, _mon_de);
  if mot is not null then raise exception '%', mot; end if;
  if _mon_pedido is not null then
    if not exists (select 1 from monsters where id = _mon_pedido and user_id = _para and aceita_troca = true) then
      raise exception 'Você só pode pedir um Pokémon que esteja na vitrine de troca desse jogador.';
    end if;
    mot := public.troca_motivo(_para, _mon_pedido);
    if mot is not null then
      raise exception '%', replace(replace(mot, 'Esse Pokémon', 'O Pokémon que você pediu'), 'não é mais de quem estava na troca', 'não está disponível agora');
    end if;
  end if;
  select * into me from characters where user_id = uid for update;
  if me.coins < _moedas_de then raise exception 'Você tem % moedas e ofereceu %.', me.coins, _moedas_de; end if;
  if _moedas_de > 0 then
    perform public.ext_origem('Troca de Pokémon (moedas guardadas)', 'trocas');
    update characters set coins = coins - _moedas_de where user_id = uid;
  end if;
  insert into trocas(de, para, mon_de, mon_para, mon_pedido, moedas_de, moedas_para, moedas_para_guardadas, status, resumo, expira_em)
  values (uid, _para, _mon_de, null, _mon_pedido, _moedas_de, 0, false, 'pendente',
          jsonb_strip_nulls(jsonb_build_object('de', public.troca_mon_pub(_mon_de), 'pedido', case when _mon_pedido is not null then public.troca_mon_pub(_mon_pedido) end)),
          now() + make_interval(hours => (c->>'expira_horas')::int))
  returning * into t;
  return jsonb_build_object('id', t.id, 'status', t.status, 'expira_em', t.expira_em, 'coins', me.coins - _moedas_de);
end $$;

-- passo 2: 2º jogador escolhe qualquer Pokémon elegível da coleção dele e moedas opcionais, enviando para aprovação final do 1º
create or replace function public.troca_escolher(_id bigint, _mon_para uuid, _moedas_para int default 0) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.troca_cfg(); t trocas; me characters; mot text; lim int := (c->>'semana_max')::int;
begin
  if not coalesce((c->>'on')::boolean, true) then raise exception 'As trocas estão fechadas no momento.'; end if;
  perform public.troca_tick();
  select * into t from trocas where id = _id for update;
  if t.id is null or t.para <> uid then raise exception 'Proposta não encontrada.'; end if;
  if t.status <> 'pendente' then raise exception 'Essa proposta não está mais aguardando a sua escolha.'; end if;
  if _mon_para is null then raise exception 'Escolha qual Pokémon seu você quer dar na troca.'; end if;
  _moedas_para := coalesce(_moedas_para, 0);
  if _moedas_para < 0 then raise exception 'As moedas não podem ser negativas.'; end if;
  if _moedas_para > (c->>'moedas_max')::int then raise exception 'No máximo % moedas de cada lado.', c->>'moedas_max'; end if;
  if public.troca_semana(uid) >= lim then raise exception 'Você já fez % trocas esta semana, que é o limite. Volte na segunda!', lim; end if;
  if public.troca_semana(t.de) >= lim then raise exception 'Quem propôs já fez as % trocas da semana.', lim; end if;
  mot := public.troca_motivo(t.de, t.mon_de, t.id);
  if mot is not null then raise exception 'O Pokémon oferecido não pode ser trocado agora: %', mot; end if;
  mot := public.troca_motivo(uid, _mon_para, t.id);
  if mot is not null then raise exception '%', mot; end if;
  select * into me from characters where user_id = uid for update;
  if me.coins < _moedas_para then raise exception 'Você tem % moedas e colocou %.', me.coins, _moedas_para; end if;
  if _moedas_para > 0 then
    perform public.ext_origem('Troca de Pokémon (moedas guardadas)', 'trocas');
    update characters set coins = coins - _moedas_para where user_id = uid;
  end if;
  update trocas
     set mon_para = _mon_para,
         moedas_para = _moedas_para,
         moedas_para_guardadas = (_moedas_para > 0),
         status = 'confirmar',
         resumo = coalesce(resumo, '{}'::jsonb) || jsonb_build_object('de', public.troca_mon_pub(t.mon_de), 'para', public.troca_mon_pub(_mon_para))
   where id = t.id;
  return jsonb_build_object('status', 'confirmar', 'coins', me.coins - _moedas_para);
end $$;

-- passo 3 (ou recusa no passo 2): 2º pode recusar em 'pendente'; 1º aprova ou recusa em 'confirmar'
create or replace function public.troca_responder(_id bigint, _aceita boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.troca_cfg(); t trocas; x trocas; mot text; lim int := (c->>'semana_max')::int;
  tx_de int := 0; tx_para int := 0; ev1 jsonb; ev2 jsonb; nde text; npara text; sp1 text; sp2 text;
begin
  perform public.troca_tick();
  select * into t from trocas where id = _id for update;
  if t.id is null or uid not in (t.de, t.para) then raise exception 'Proposta não encontrada.'; end if;

  if t.status = 'pendente' then
    if uid <> t.para then raise exception 'Aguarde o outro jogador escolher o Pokémon dele (ou cancele a proposta).'; end if;
    if coalesce(_aceita, false) then raise exception 'Escolha primeiro qual Pokémon seu vai entrar na troca.'; end if;
    perform public.troca_devolver(t);
    update trocas set status = 'recusada', fim = now() where id = t.id;
    return jsonb_build_object('status', 'recusada');
  end if;

  if t.status <> 'confirmar' then raise exception 'Essa proposta não está mais valendo.'; end if;
  if uid <> t.de then raise exception 'Agora falta quem enviou a proposta aprovar ou recusar.'; end if;

  if not coalesce(_aceita, false) then
    perform public.troca_devolver(t);
    update trocas set status = 'recusada', fim = now() where id = t.id;
    return jsonb_build_object('status', 'recusada');
  end if;

  if not coalesce((c->>'on')::boolean, true) then raise exception 'As trocas estão fechadas no momento.'; end if;
  if t.mon_para is null then raise exception 'O outro jogador ainda não escolheu o Pokémon.'; end if;
  if public.troca_semana(t.de) >= lim then raise exception 'Você já fez % trocas esta semana, que é o limite. Volte na segunda!', lim; end if;
  if public.troca_semana(t.para) >= lim then raise exception 'O outro jogador já fez as % trocas da semana.', lim; end if;
  mot := public.troca_motivo(t.de, t.mon_de, t.id);
  if mot is not null then raise exception '%', mot; end if;
  mot := public.troca_motivo(t.para, t.mon_para, t.id);
  if mot is not null then raise exception 'O Pokémon escolhido pelo outro jogador não pode ser trocado agora: %', mot; end if;

  perform 1 from characters where user_id in (t.de, t.para) order by user_id for update;
  if t.moedas_de > 0 then tx_para := floor(t.moedas_de * public.troca_taxa_de(t.para) / 100.0)::int; end if;
  if t.moedas_para > 0 then tx_de := floor(t.moedas_para * public.troca_taxa_de(t.de) / 100.0)::int; end if;

  if t.moedas_de - tx_para > 0 then
    perform public.ext_origem('Troca de Pokémon', 'trocas');
    update characters set coins = coins + (t.moedas_de - tx_para) where user_id = t.para;
  end if;
  if t.moedas_para - tx_de > 0 then
    perform public.ext_origem('Troca de Pokémon', 'trocas');
    update characters set coins = coins + (t.moedas_para - tx_de) where user_id = t.de;
  end if;

  select name into sp1 from pokemon where id = (select species_id from monsters where id = t.mon_de);
  select name into sp2 from pokemon where id = (select species_id from monsters where id = t.mon_para);
  perform public.troca_passa(t.mon_de, t.de, t.para);
  perform public.troca_passa(t.mon_para, t.para, t.de);
  ev1 := public.troca_evolui(t.mon_de);
  ev2 := public.troca_evolui(t.mon_para);
  update trocas set status = 'aceita', fim = now(), taxa_de = tx_de, taxa_para = tx_para,
         evoluiu = case when ev1 is null and ev2 is null then null else jsonb_strip_nulls(jsonb_build_object('de', ev1, 'para', ev2)) end
   where id = t.id;

  -- cancela e devolve moedas de outras propostas abertas envolvendo qualquer um dos dois Pokémon
  for x in select * from trocas where status in ('pendente', 'confirmar') and id <> t.id
              and (mon_de in (t.mon_de, t.mon_para) or mon_para in (t.mon_de, t.mon_para)) for update loop
    perform public.troca_devolver(x);
    update trocas set status = 'cancelada', fim = now() where id = x.id;
  end loop;

  select name into nde from characters where user_id = t.de;
  select name into npara from characters where user_id = t.para;
  insert into event_log(user_id, kind, message) values (uid, 'troca',
    '🔁 ' || nde || ' trocou ' || sp1 || ' com ' || npara || ' por ' || sp2
    || case when t.moedas_de > 0 then ' (+' || t.moedas_de || ' moedas de ' || nde || ')' else '' end
    || case when t.moedas_para > 0 then ' (+' || t.moedas_para || ' moedas de ' || npara || ')' else '' end || '!');
  return jsonb_build_object('status', 'aceita', 'taxa_de', tx_de, 'taxa_para', tx_para, 'evoluiu', jsonb_strip_nulls(jsonb_build_object('de', ev1, 'para', ev2)));
end $$;

-- qualquer um dos dois pode cancelar antes da conclusão
create or replace function public.troca_cancelar(_id bigint) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); t trocas;
begin
  select * into t from trocas where id = _id for update;
  if t.id is null or uid not in (t.de, t.para) then raise exception 'Proposta não encontrada.'; end if;
  if t.status not in ('pendente', 'confirmar') then raise exception 'Essa proposta não está mais valendo.'; end if;
  perform public.troca_devolver(t);
  update trocas set status = 'cancelada', fim = now() where id = t.id;
  return jsonb_build_object('status', 'cancelada');
end $$;

create or replace function public.troca_minhas() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.troca_cfg();
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  perform public.troca_tick();
  return jsonb_build_object(
    'on', coalesce((c->>'on')::boolean, true), 'semana', public.troca_semana(uid), 'semana_max', (c->>'semana_max')::int,
    'taxa_pct', public.troca_taxa_de(uid), 'trava_dias', (c->>'trava_dias')::int, 'expira_horas', (c->>'expira_horas')::int, 'moedas_max', (c->>'moedas_max')::int,
    'vitrines', coalesce((select jsonb_object_agg(user_id::text, qtd) from (select user_id, count(*)::int qtd from monsters where aceita_troca = true group by user_id) v), '{}'::jsonb),
    'propostas', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'status', t.status, 'de', t.de, 'para', t.para, 'de_nome', a.name, 'para_nome', b.name,
        'moedas_de', t.moedas_de, 'moedas_para', t.moedas_para, 'expira_em', t.expira_em, 'criada_em', t.criada_em,
        'mon_de', coalesce(public.troca_mon_pub(t.mon_de), t.resumo->'de'),
        'mon_para', case when t.mon_para is not null then coalesce(public.troca_mon_pub(t.mon_para), t.resumo->'para') end,
        'mon_pedido', case when t.mon_pedido is not null then coalesce(public.troca_mon_pub(t.mon_pedido), t.resumo->'pedido') end,
        'taxa_eu', public.troca_taxa_de(uid)) order by t.criada_em desc)
      from trocas t join characters a on a.user_id = t.de join characters b on b.user_id = t.para
      where t.status in ('pendente', 'confirmar') and (t.de = uid or t.para = uid)), '[]'::jsonb),
    'historico', coalesce((select jsonb_agg(x order by (x->>'fim') desc) from (
      select jsonb_build_object('id', t.id, 'status', t.status, 'de', t.de, 'para', t.para, 'de_nome', a.name, 'para_nome', b.name, 'fim', t.fim,
        'mon_de', t.resumo->'de', 'mon_para', t.resumo->'para', 'mon_pedido', t.resumo->'pedido', 'moedas_de', t.moedas_de, 'moedas_para', t.moedas_para,
        'taxa_de', t.taxa_de, 'taxa_para', t.taxa_para, 'evoluiu', t.evoluiu) x
      from trocas t join characters a on a.user_id = t.de join characters b on b.user_id = t.para
      where t.status not in ('pendente', 'confirmar') and (t.de = uid or t.para = uid) order by t.fim desc nulls last limit 15) y), '[]'::jsonb));
end $$;


-- ============================================================================
-- 3. EQUIPE ROCKET (INVASÃO): BARRA, 15 LINHAS POR NÍVEL, COBERTURA E ROUBO
-- ============================================================================

create or replace function public.rocket_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"days":[0,2,5],"hour":8,"hours":24,"reward":100,"max_turns":300,"level_bonus":2,
           "onda_menos":5,"onda_mais":3,"onda_min":5,"media_padrao":250,"media_invasoes":3,
           "mult_inicio":1.0,"mult_vitoria":0.05,"mult_derrota":0.1,"mult_min":0.8,"mult_max":1.2,
           "top_bonus":[50,30,20],"superacao":20,"xp_por_nivel":10,
           "roubo_pct":80,"resgate_dias":7,"resgate_bonus":50,"peso_participou":1,"peso_ausente":2,
           "giovanni_cada":5,"giovanni_fator":1.1,"giovanni_vitoria":0.05,"giovanni_derrota":0.1,"giovanni_min":0.9,"giovanni_max":1.3,
           "giovanni_alivio":0.1,"giovanni_dono_peso":1.25,"giovanni_premio_mult":2,"giovanni_devolve_bonus":50,"giovanni_chances":2}'::jsonb
         || coalesce(public.cfg()->'rocket', '{}'::jsonb)
$$;

-- média de dano por participante nas invasões em ondas disponíveis (desde a 1ª, até as _n últimas; ignora invasões antigas sem media)
create or replace function public.rocket_media(_n int) returns numeric
language plpgsql stable security definer set search_path = public, extensions as $$
declare ids bigint[]; v numeric;
begin
  select array_agg(id) into ids from (
    select r.id from rocket_raids r
     where r.status <> 'ativa' and r.media is not null
       and exists (select 1 from rocket_entries e where e.raid_id = r.id)
     order by r.id desc limit coalesce(_n, 1000000)) x;
  if ids is null or cardinality(ids) = 0 then return null; end if;
  select avg(e.damage) into v from rocket_entries e where e.raid_id = any(ids);
  return v;
end $$;

-- espécie exata da linha _linha (1..15) no nível _lv (null se a linha ainda não aparece nesse nível, ex.: Kadabra < 16)
create or replace function public.rocket_especie_linha(_linha int, _lv int) returns int
language sql immutable as $$
  select case _linha
    when 1  then case when _lv < 20 then 19  else 20  end                                    -- Rattata -> Raticate: 20
    when 2  then case when _lv < 21 then 69  when _lv < 35 then 70 else 71 end               -- Bellsprout -> Weepinbell: 21 -> Victreebel: 35
    when 3  then case when _lv < 22 then 23  else 24  end                                    -- Ekans -> Arbok: 22
    when 4  then case when _lv < 22 then 41  else 42  end                                    -- Zubat -> Golbat: 22
    when 5  then case when _lv < 22 then 27  else 28  end                                    -- Sandshrew -> Sandslash: 22
    when 6  then case when _lv < 26 then 96  else 97  end                                    -- Drowzee -> Hypno: 26
    when 7  then case when _lv < 28 then 104 else 105 end                                    -- Cubone -> Marowak: 28
    when 8  then case when _lv < 28 then 52  else 53  end                                    -- Meowth -> Persian: 28
    when 9  then case when _lv < 28 then 66  else 67  end                                    -- Machop -> Machoke: 28
    when 10 then case when _lv < 30 then 81  else 82  end                                    -- Magnemite -> Magneton: 30
    when 11 then case when _lv < 35 then 109 else 110 end                                    -- Koffing -> Weezing: 35
    when 12 then case when _lv < 35 then 58  else 59  end                                    -- Growlithe -> Arcanine: 35
    when 13 then case when _lv < 38 then 88  else 89  end                                    -- Grimer -> Muk: 38
    when 14 then case when _lv < 16 then null when _lv < 40 then 64 else 65 end              -- Kadabra: 16..39, Alakazam: 40+
    when 15 then 108                                                                         -- Lickitung: qualquer nível
    else null end
$$;

create or replace function public.rocket_especies_nivel(_lv int) returns int[]
language sql immutable as $$
  select coalesce(array_agg(s order by i), '{}')
    from generate_series(1, 15) i, lateral (select public.rocket_especie_linha(i, _lv) s) q
   where s is not null
$$;

-- ataques de cobertura dos Pokémon da Rocket (compatíveis em pk_tm_compat / learnset da espécie)
create or replace function public.rocket_moves(_sp int, _lv int) returns int[]
language plpgsql stable security definer set search_path = public, extensions as $$
declare p pokemon; pool jsonb; e jsonb; esc int[] := '{}'; tipos text[] := '{}'; imun text[]; achou boolean := false; pref int[];
begin
  select * into p from pokemon where id = _sp;
  if p.id is null then return '{}'; end if;
  pref := case
    when _sp in (52, 53) then array[61, 85]             -- Meowth/Persian: Bubblebeam, Thunderbolt
    when _sp in (23, 24) then array[89, 91, 157]        -- Ekans/Arbok: Earthquake, Dig, Rock Slide
    when _sp in (109, 110) then array[85, 126, 124]     -- Koffing/Weezing: Thunderbolt, Fire Blast, Sludge
    when _sp = 108 then array[89, 58, 61]               -- Lickitung: Earthquake, Ice Beam, Bubblebeam
    when _sp in (19, 20) then array[61, 85, 91]         -- Rattata/Raticate: Bubblebeam, Thunderbolt, Dig
    when _sp in (41, 42) then array[17, 72, 141]        -- Zubat/Golbat: Wing Attack, Mega Drain, Leech Life
    when _sp in (27, 28) then array[89, 157, 66]        -- Sandshrew/Sandslash: Earthquake, Rock Slide, Submission
    when _sp in (58, 59) then array[53, 126, 91]        -- Growlithe/Arcanine: Flamethrower, Fire Blast, Dig
    when _sp in (66, 67) then array[66, 89, 157]        -- Machop/Machoke: Submission, Earthquake, Rock Slide
    when _sp in (69, 70, 71) then array[75, 51, 34]     -- Bellsprout/Weepinbell/Victreebel: Razor Leaf, Acid, Body Slam
    when _sp in (88, 89) then array[124, 85, 72]        -- Grimer/Muk: Sludge, Thunderbolt, Mega Drain
    when _sp in (81, 82) then array[85, 49, 129]        -- Magnemite/Magneton: Thunderbolt, Sonicboom, Swift
    when _sp in (96, 97) then array[94, 66, 34]         -- Drowzee/Hypno: Psychic, Submission, Body Slam
    when _sp in (104, 105) then array[89, 58, 126]      -- Cubone/Marowak: Earthquake, Ice Beam, Fire Blast
    when _sp in (64, 65) then array[94, 91, 66]         -- Kadabra/Alakazam: Psychic, Dig, Submission
    when _sp in (111, 112) then array[89, 157, 57]      -- Rhyhorn/Rhydon (Giovanni)
    when _sp = 51 then array[89, 157, 163]              -- Dugtrio (Giovanni)
    when _sp in (31, 34) then array[89, 58, 85]         -- Nidoqueen/Nidoking (Giovanni)
    else '{}'::int[] end;
  select coalesce(jsonb_agg(jsonb_build_object('id', mv.id, 'type', mv.type, 'dano', public.ia_dano(mv),
           'v', (case when public.ia_dano(mv) then public.ia_valor(mv, p.g1_type1, p.g1_type2) else public.ia_status_valor(mv) end)
                + case when mv.id = any(pref) then 35 else 0 end)
           order by public.ia_dano(mv) desc,
                    ((case when public.ia_dano(mv) then public.ia_valor(mv, p.g1_type1, p.g1_type2) else public.ia_status_valor(mv) end)
                     + case when mv.id = any(pref) then 35 else 0 end) desc, mv.id), '[]'::jsonb)
    into pool
    from pk_moves mv
   where mv.id in (select unnest(p.start_moves)
                   union select move_id from pk_learnset where species_id = _sp and level <= _lv
                   union select move_id from pk_tm_compat where species_id = _sp and mv.code <> 'REST'
                         and (_lv >= 25 or coalesce(mv.power, 0) <= 100 or mv.id = any(pref)))
     and not public.ia_inutil(mv);

  for e in select value from jsonb_array_elements(pool) loop
    if (e->>'dano')::boolean then esc := esc || (e->>'id')::int; tipos := tipos || (e->>'type'); exit; end if;
  end loop;
  if cardinality(esc) = 1 then
    select coalesce(array_agg(def), '{}') into imun from pk_type_chart where atk = tipos[1] and mult = 0;
    for e in select value from jsonb_array_elements(pool) loop
      continue when not (e->>'dano')::boolean or (e->>'type') = any(tipos);
      if not exists (select 1 from unnest(imun) d where public.bt_eff(e->>'type', d, null) = 0) then
        esc := esc || (e->>'id')::int; tipos := tipos || (e->>'type'); achou := true; exit;
      end if;
    end loop;
    if not achou then
      for e in select value from jsonb_array_elements(pool) loop
        continue when not (e->>'dano')::boolean or (e->>'type') = any(tipos);
        esc := esc || (e->>'id')::int; tipos := tipos || (e->>'type'); exit;
      end loop;
    end if;
  end if;
  if cardinality(esc) = 2 then
    for e in select value from jsonb_array_elements(pool) loop
      continue when not (e->>'dano')::boolean or (e->>'type') = any(tipos);
      esc := esc || (e->>'id')::int; tipos := tipos || (e->>'type'); exit;
    end loop;
  end if;
  for e in select value from jsonb_array_elements(pool) order by (value->>'v')::numeric desc loop
    if not (e->>'dano')::boolean and not ((e->>'id')::int = any(esc)) then esc := esc || (e->>'id')::int; exit; end if;
  end loop;
  for e in select value from jsonb_array_elements(pool) loop
    exit when cardinality(esc) >= 4;
    continue when (e->>'id')::int = any(esc);
    esc := esc || (e->>'id')::int;
  end loop;
  return esc[1:4];
end $$;

create or replace function public.rocket_mon(_sp int, _lv int) returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select public.ia_mon(_sp, _lv, public.rocket_moves(_sp, _lv), true)
$$;

-- maior multiplicador de dano dos ataques de _mon contra (_t1, _t2)
create or replace function public.rocket_melhor_eff(_mon jsonb, _t1 text, _t2 text) returns numeric
language plpgsql stable security definer set search_path = public, extensions as $$
declare i int; mv pk_moves; best numeric := 0; eff numeric;
begin
  if _mon is null or _t1 is null then return 1; end if;
  for i in 0 .. coalesce(jsonb_array_length(_mon->'moves'), 0) - 1 loop
    select * into mv from pk_moves where id = (_mon->'moves'->i->>'id')::int;
    continue when mv.id is null or public.ia_inutil(mv) or not public.ia_dano(mv);
    if mv.effect in ('SPECIAL_DAMAGE_EFFECT', 'SUPER_FANG_EFFECT') then
      eff := 1;
    elsif mv.effect = 'OHKO_EFFECT' then
      eff := case when public.bt_eff(mv.type, _t1, _t2) > 0 then 1 else 0 end;
    else
      eff := public.bt_eff(mv.type, _t1, _t2);
    end if;
    if eff > best then best := eff; end if;
  end loop;
  return best;
end $$;

-- sorteia o Pokémon da onda respeitando evolução por nível, dano >= 1x no cedido e >= 1 em cada 3 ondas com vantagem (> 1x)
create or replace function public.rocket_onda_mon(_rk jsonb, _onda int, _giovanni boolean) returns jsonb
language plpgsql volatile security definer set search_path = public, extensions as $$
declare c jsonb := public.rocket_cfg(); lv int; sp int; w jsonb;
  time_g int[] := array[111, 51, 31, 34, 53, 112];
  dt1 text := _rk->>'def_t1'; dt2 text := _rk->>'def_t2';
  ult_sp int := coalesce((_rk->>'ult_sp')::int, 0);
  sem_vant int := coalesce((_rk->>'sem_vant')::int, 0);
  precisa_vant boolean := (sem_vant >= 2) or ((_onda % 3) = 0 and sem_vant >= 2);
  cands jsonb := '[]'::jsonb; normais jsonb := '[]'::jsonb; vants jsonb := '[]'::jsonb; pool jsonb; s int; eff numeric;
begin
  lv := least(100, greatest((c->>'onda_min')::int, (_rk->>'base')::int - (c->>'onda_menos')::int) + (_onda - 1) * (c->>'onda_mais')::int);
  if (_rk->>'roubo_onda')::int = _onda and (_rk->>'roubo_sp') is not null then
    w := public.rocket_mon((_rk->>'roubo_sp')::int, lv);
    if (_rk->>'roubo_nome') is not null then
      w := w || jsonb_build_object('name', (w->>'name') || ' de ' || (_rk->>'roubo_nome'));
    end if;
    return w;
  end if;
  if _giovanni then
    sp := time_g[1 + ((_onda - 1) % 6)];
    return public.rocket_mon(sp, lv);
  end if;

  foreach s in array public.rocket_especies_nivel(lv) loop
    w := public.rocket_mon(s, lv);
    eff := public.rocket_melhor_eff(w, dt1, dt2);
    cands := cands || jsonb_build_array(jsonb_build_object('sp', s, 'mon', w, 'eff', eff));
    if eff >= 1 then normais := normais || jsonb_build_array(jsonb_build_object('sp', s, 'mon', w, 'eff', eff)); end if;
    if eff > 1 then vants := vants || jsonb_build_array(jsonb_build_object('sp', s, 'mon', w, 'eff', eff)); end if;
  end loop;

  if precisa_vant and jsonb_array_length(vants) > 0 then
    pool := vants;
  elsif jsonb_array_length(normais) > 0 then
    pool := normais;
  else
    pool := cands;
  end if;

  -- evita repetir exatamente a mesma espécie seguida quando há mais opções
  if jsonb_array_length(pool) > 1 and exists (select 1 from jsonb_array_elements(pool) x where (x->>'sp')::int <> ult_sp) then
    select jsonb_agg(x) into pool from jsonb_array_elements(pool) x where (x->>'sp')::int <> ult_sp;
  end if;

  w := (pool->(floor(random() * jsonb_array_length(pool))::int))->'mon';
  return w;
end $$;

create or replace function public.rocket_onda_nova(_bid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b battles; rk jsonb; n int; w jsonb; idx int; g boolean; eff numeric; sem_v int;
begin
  select * into b from battles where id = _bid for update;
  rk := b.state->'rk';
  if rk is null then
    insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, b.p1, 'switch', public.war_switch(b.state, 1, true));
    return;
  end if;
  select coalesce(r.giovanni, false) into g from rocket_entries e join rocket_raids r on r.id = e.raid_id where e.battle_id = _bid;
  n := (rk->>'ondas')::int + 1;
  w := public.rocket_onda_mon(rk, n + 1, coalesce(g, false));
  eff := public.rocket_melhor_eff(w, rk->>'def_t1', rk->>'def_t2');
  sem_v := case when eff > 1 then 0 else coalesce((rk->>'sem_vant')::int, 0) + 1 end;
  idx := jsonb_array_length(b.state->'sides'->1->'mons');
  rk := rk || jsonb_build_object('ondas', n, 'onda', n + 1, 'ult_sp', (w->>'species')::int, 'sem_vant', sem_v);
  update battles set state = jsonb_set(jsonb_set(state, '{rk}', rk), array['sides', '1', 'mons'], (state->'sides'->1->'mons') || jsonb_build_array(w)),
         log = log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(
                 jsonb_build_object('txt', '🌊 Onda ' || n || ' vencida! Vem a onda ' || (n + 1) || ': ' || (w->>'name') || ' (nível ' || (w->>'level') || ').'))))
   where id = b.id;
  insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, b.p1, 'switch', idx);
end $$;

-- limpa vínculos (mascote, suporte e trocas abertas) ao levar um Pokémon roubado pela Rocket
create or replace function public.rocket_tira_mon(_mon uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare m monsters; snap jsonb; x trocas;
begin
  select * into m from monsters where id = _mon for update;
  if m.id is null then return null; end if;
  for x in select * from trocas where status in ('pendente', 'confirmar') and (mon_de = _mon or mon_para = _mon) for update loop
    perform public.troca_devolver(x);
    update trocas set status = 'cancelada', fim = now() where id = x.id;
  end loop;
  snap := to_jsonb(m);
  delete from monsters where id = _mon;
  update characters set mascot = null where user_id = m.user_id and (mascot->>'id')::uuid = _mon;
  update characters set rpg_suporte = null where user_id = m.user_id and rpg_suporte = _mon;
  return snap;
end $$;

-- cria base de resgate de 7 dias para qualquer Pokémon roubado (invasão comum ou ataque surpresa à vila)
create or replace function public.rocket_resgate_roubo(_dono uuid, _dono_nome text, _mon_id uuid, _mon_nome text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rocket_cfg(); snap jsonb; lv int; t jsonb; pool int[];
begin
  snap := public.rocket_tira_mon(_mon_id);
  if snap is null then return null; end if;
  lv := greatest(5, (snap->>'level')::int);
  pool := public.rocket_especies_nivel(lv);
  select jsonb_agg(jsonb_build_array(s, lv)) into t from (select unnest(pool) s order by random() limit 3) x;
  insert into rocket_bases(nome, tipo, nivel, time, ativa, mon_id, dono, prazo, mon_snap, mon_info)
  values ('Esconderijo com o ' || _mon_nome || ' de ' || _dono_nome, 'resgate', lv, t, true, _mon_id, _dono,
          now() + make_interval(days => (c->>'resgate_dias')::int), snap,
          jsonb_build_object('mon', _mon_nome, 'species', snap->'species_id', 'level', lv, 'dono_nome', _dono_nome));
  return snap;
end $$;

create or replace function public.rocket_resgate_criar(_raid bigint, _e public.rocket_entries) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.rocket_resgate_roubo(_e.user_id, _e.name, _e.mon_id, _e.mon_name);
end $$;

create or replace function public.rocket_begin(_starts timestamptz, _hours int) returns public.rocket_raids
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rocket_cfg(); r rocket_raids; lvl int; n int; team jsonb; hp int; mt rocket_meta; g boolean; med numeric; f numeric;
begin
  insert into rocket_meta(id) values (1) on conflict do nothing;
  select * into mt from rocket_meta where id = 1 for update;
  g := mt.giovanni_pendente;
  select count(distinct a.user_id) into n from public.day_active(public.game_today()) a where exists (select 1 from monsters m where m.user_id = a.user_id);
  select round(avg(m.level))::int into lvl from monsters m where m.team_slot is not null and m.user_id in (select user_id from public.day_active(public.game_today()));
  lvl := greatest(5, least(100, coalesce(lvl, 10)));
  if g then
    med := coalesce(public.rocket_media(null), (c->>'media_padrao')::numeric);
    f := mt.giovanni_fator - case when exists (select 1 from rocket_roubados where status = 'preso') then (c->>'giovanni_alivio')::numeric else 0 end;
    f := greatest(0.1, f);
    select jsonb_agg(jsonb_build_object('species', p.id, 'name', p.name) order by o) into team
      from unnest(array[111, 51, 31, 34, 53, 112]) with ordinality u(s, o) join pokemon p on p.id = u.s;
  else
    med := coalesce(public.rocket_media((c->>'media_invasoes')::int), (c->>'media_padrao')::numeric);
    f := mt.mult;
    select jsonb_agg(jsonb_build_object('species', p.id, 'name', p.name) order by p.id) into team
      from (select unnest(public.rocket_especies_nivel(lvl)) s order by random() limit 7) u join pokemon p on p.id = u.s;
  end if;
  hp := greatest(1, ceil(med * greatest(1, n) * f))::int;
  insert into rocket_raids(starts_at, ends_at, level, team, players, hp_total, hp_left, giovanni, mult, media)
  values (_starts, _starts + make_interval(hours => _hours), lvl, team, greatest(1, n), hp, hp, g, f, round(med, 1)) returning * into r;
  update rocket_meta set giovanni_pendente = false where id = 1;
  insert into event_log(kind, message) values ('rocket', case when g then
    '🕴️ GIOVANNI chegou com a Equipe Rocket! Ceda 1 Pokémon e vença o máximo de ondas para expulsá-lo em ' || _hours || ' horas. Quem não participar também pode perder um Pokémon se a turma for derrotada!'
    else '🚀 A Equipe Rocket invadiu! Ceda 1 Pokémon e vença o máximo de ondas para expulsar a Rocket em ' || _hours || ' horas. Quem não participar também pode perder um Pokémon se a turma for derrotada.' end);
  return r;
end $$;

create or replace function public.rocket_join(_mon uuid) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.rocket_cfg(); r rocket_raids; m monsters; p pokemon; ch characters;
  s0 jsonb; s1 jsonb; bid uuid; rk jsonb; w jsonb; rb rocket_roubados; peso numeric := 1; eff numeric;
begin
  perform public.rocket_tick();
  select * into r from rocket_raids where status = 'ativa' order by id desc limit 1 for update;
  if r.id is null then raise exception 'A Equipe Rocket não está invadindo agora.'; end if;
  if now() >= r.ends_at then raise exception 'A invasão já acabou.'; end if;
  if exists (select 1 from rocket_entries where raid_id = r.id and user_id = uid) then raise exception 'Você já cedeu um Pokémon nesta invasão.'; end if;
  select * into m from monsters where id = _mon and user_id = uid;
  if m.id is null then raise exception 'Escolha um Pokémon seu.'; end if;
  perform public.gin_trava(uid, array[_mon]);
  select * into p from pokemon where id = m.species_id;
  select * into ch from characters where user_id = uid;
  rk := jsonb_build_object('ondas', 0, 'onda', 1, 'base', m.level, 'def_t1', p.g1_type1, 'def_t2', p.g1_type2, 'sem_vant', 0, 'ult_sp', 0);
  if r.giovanni then
    select * into rb from rocket_roubados where status = 'preso' order by (user_id = uid) desc, random() limit 1;
    if rb.id is not null then
      rk := rk || jsonb_build_object('roubo_onda', 2 + floor(random() * 3)::int, 'roubo_sp', rb.species, 'roubo_nome', rb.nome);
    end if;
    if exists (select 1 from rocket_roubados where status = 'preso' and user_id = uid) then peso := (c->>'giovanni_dono_peso')::numeric; end if;
  end if;
  w := public.rocket_onda_mon(rk, 1, r.giovanni);
  eff := public.rocket_melhor_eff(w, p.g1_type1, p.g1_type2);
  rk := rk || jsonb_build_object('ult_sp', (w->>'species')::int, 'sem_vant', case when eff > 1 then 0 else 1 end);
  s0 := jsonb_build_object('user', uid, 'name', ch.name, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(public.bt_mon(m.id)));
  s1 := jsonb_build_object('user', uid, 'name', case when r.giovanni then 'Giovanni' else 'Equipe Rocket' end, 'npc', true, 'active', 0, 'need_switch', false,
                           'mons', jsonb_build_array(w, public.rocket_lugar()));
  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (uid, uid, 'rocket', 1, 'ativa', 1, 'normal', now(), jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb, 'rk', rk),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', case when r.giovanni then 'Giovanni sorri: "Vamos ver até onde você aguenta."' else 'Prepare-se para encrenca! A Equipe Rocket chegou!' end),
            jsonb_build_object('txt', ch.name || ' mandou ' || (s0->'mons'->0->>'name') || '!'),
            jsonb_build_object('txt', 'Onda 1: ' || (w->>'name') || ' (nível ' || (w->>'level') || ')!')))))
  returning id into bid;
  insert into rocket_entries(raid_id, user_id, name, mon_id, mon_name, species, level, battle_id, peso)
  values (r.id, uid, ch.name, m.id, p.name, m.species_id, m.level, bid, peso);
  return bid;
end $$;

-- roubo na derrota: sorteia entre todos os ativos (participou = peso 1 e perde o cedido; não participou = peso 2 e perde 1 da equipe)
create or replace function public.rocket_lose(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rocket_cfg(); r rocket_raids; rb rocket_roubados; snap jsonb;
  w_part int := greatest(1, coalesce((c->>'peso_participou')::int, 1));
  w_aus  int := greatest(1, coalesce((c->>'peso_ausente')::int, 2));
  escolhido record;
begin
  select * into r from rocket_raids where id = _id and status = 'ativa' for update;
  if r.id is null then return; end if;
  update rocket_raids set status = 'derrota', resolved_at = now() where id = _id;
  insert into rocket_meta(id) values (1) on conflict do nothing;

  with cands as (
    -- quem participou: peso 1, leva o Pokémon cedido
    select x.user_id, x.name, x.mon_id, x.mon_name, mm.species_id as species, mm.level, w_part as peso, true as participou
      from rocket_entries x
      join monsters mm on mm.id = x.mon_id and mm.user_id = x.user_id
     where x.raid_id = _id
    union all
    -- ativos que NÃO participaram e têm Pokémon elegível na equipe (slots 1..6): peso 2, sorteia 1 da equipe
    select a.user_id, ch.name, eq.id as mon_id, eq.mon_name, eq.species_id as species, eq.level, w_aus as peso, false as participou
      from (select distinct user_id from public.day_active(public.game_today())) a
      join characters ch on ch.user_id = a.user_id
      join lateral (
        select m.id, p.name as mon_name, m.species_id, m.level
          from monsters m join pokemon p on p.id = m.species_id
         where m.user_id = a.user_id and m.team_slot is not null
           and not public.gin_preso(a.user_id, m.id)
           and not exists (select 1 from battles b, jsonb_array_elements(b.state->'sides') sd, jsonb_array_elements(sd->'mons') bm
                            where b.status = 'ativa' and a.user_id in (b.p1, b.p2) and bm->>'id' = m.id::text)
         order by random() limit 1
      ) eq on true
     where not exists (select 1 from rocket_entries x where x.raid_id = _id and x.user_id = a.user_id)
  )
  select c2.* into escolhido
    from cands c2, generate_series(1, c2.peso) g
   order by random() limit 1;

  if r.giovanni then
    update rocket_meta set giovanni_fator = greatest((c->>'giovanni_min')::numeric, giovanni_fator - (c->>'giovanni_derrota')::numeric), giovanni_apos_vitoria = true where id = 1;
    update rocket_roubados set revanches = revanches + 1 where status = 'preso' and raid_id <> _id;
    for rb in select * from rocket_roubados where status = 'preso' and revanches >= (c->>'giovanni_chances')::int order by id limit 1 loop
      update rocket_roubados set status = 'perdido', resolved_at = now() where id = rb.id;
      insert into event_log(user_id, kind, message) values (rb.user_id, 'rocket', '😢 Giovanni venceu de novo e sumiu com o ' || rb.mon_nome || ' de ' || rb.nome || ' para sempre.');
    end loop;
    if escolhido.user_id is not null then
      snap := public.rocket_tira_mon(escolhido.mon_id);
      if snap is not null then
        insert into rocket_roubados(user_id, nome, mon_nome, species, level, snap, raid_id)
        values (escolhido.user_id, escolhido.name, escolhido.mon_name, (snap->>'species_id')::int, (snap->>'level')::int, snap, _id);
        update rocket_raids set stolen_user = escolhido.user_id, stolen_name = escolhido.name, stolen_mon = escolhido.mon_name,
               stolen_species = (snap->>'species_id')::int, stolen_level = (snap->>'level')::int where id = _id;
        insert into event_log(user_id, kind, message) values (escolhido.user_id, 'rocket',
          '🕴️ Giovanni venceu e levou o ' || escolhido.mon_name || ' de ' || escolhido.name
          || case when not escolhido.participou then ' (da equipe, sem ter participado da defesa)' else '' end
          || '! Vença o Giovanni na próxima vez para trazê-lo de volta.');
        return;
      end if;
    end if;
    insert into event_log(kind, message) values ('rocket', '🕴️ Giovanni venceu, mas foi embora sem levar nenhum Pokémon.');
    return;
  end if;

  update rocket_meta set mult = greatest((c->>'mult_min')::numeric, mult - (c->>'mult_derrota')::numeric) where id = 1;
  if escolhido.user_id is not null and r.dano_total < r.hp_total * (c->>'roubo_pct')::numeric / 100 then
    snap := public.rocket_resgate_roubo(escolhido.user_id, escolhido.name, escolhido.mon_id, escolhido.mon_name);
    if snap is not null then
      update rocket_raids set stolen_user = escolhido.user_id, stolen_name = escolhido.name, stolen_mon = escolhido.mon_name,
             stolen_species = escolhido.species, stolen_level = escolhido.level where id = _id;
      insert into event_log(user_id, kind, message) values (escolhido.user_id, 'rocket',
        '😱 A Equipe Rocket venceu e levou o ' || escolhido.mon_name || ' de ' || escolhido.name
        || case when not escolhido.participou then ' (sorteado da equipe por não ter participado)' else '' end
        || ' para um esconderijo! Quem tem Quartel pode atacar o esconderijo nas bases da Rocket (Guerras) em até ' || (c->>'resgate_dias') || ' dias para resgatá-lo.');
      return;
    end if;
  end if;
  insert into event_log(kind, message) values ('rocket', '🚀 A Equipe Rocket venceu, mas o grupo lutou bem e ela foi embora sem levar nenhum Pokémon.');
end $$;


-- ============================================================================
-- 4. ATAQUE SURPRESA DA EQUIPE ROCKET ÀS VILAS
-- ============================================================================

-- monta um esquadrão da Rocket (3 a 5 Pokémon das 15 linhas, respeitando nível de evolução) próximo à força-alvo
create or replace function public.rocket_vila_montar_time(_alvo_forca int, _qtd int default 3) returns jsonb
language plpgsql volatile security definer set search_path = public, extensions as $$
declare n int := greatest(3, least(5, coalesce(_qtd, 3))); linhas int[]; lv int := 10; lo int := 5; hi int := 100; mid int;
  tm jsonb; f int; best_tm jsonb; best_diff int := 999999; i int; sp int;
begin
  select array_agg(x order by random()) into linhas from (select generate_series(1, 15) x) q;
  linhas := linhas[1:n];
  for i in 1 .. 8 loop
    mid := (lo + hi) / 2;
    select jsonb_agg(jsonb_build_array(coalesce(public.rocket_especie_linha(l, mid), 19), mid) order by ord)
      into tm from unnest(linhas) with ordinality u(l, ord);
    f := public.rocket_base_forca(tm);
    if abs(f - _alvo_forca) < best_diff then best_diff := abs(f - _alvo_forca); best_tm := tm; lv := mid; end if;
    if f < _alvo_forca then lo := mid + 1; else hi := mid - 1; end if;
  end loop;
  -- ajuste fino de +-1 nível por vaga para bater na faixa pedida
  for i in 0 .. n - 1 loop
    f := public.rocket_base_forca(best_tm);
    exit when f = _alvo_forca;
    mid := greatest(5, least(100, (best_tm->i->>1)::int + case when f < _alvo_forca then 1 else -1 end));
    sp := coalesce(public.rocket_especie_linha(linhas[i + 1], mid), 19);
    best_tm := jsonb_set(best_tm, array[i::text], jsonb_build_array(sp, mid));
  end loop;
  return best_tm;
end $$;

-- sorteia 1 vila elegível (ou _forcar_alvo se informado) com peso proporcional às moedas (mínimo 100) e avisa 24h antes
create or replace function public.rocket_vila_sortear(_forcar_alvo uuid default null, _dia_ataque date default null) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rocket_vila_cfg(); tz text := coalesce(public.cfg()->>'timezone', 'America/Sao_Paulo');
  sem date := date_trunc('week', (now() at time zone tz)::date)::date;
  peso_min numeric := greatest(1, coalesce((c->>'peso_min_moedas')::numeric, 100));
  tot numeric := 0; sorteio numeric; acum numeric := 0; r record; esc_uid uuid; esc_nome text;
  ataca timestamptz := now() + make_interval(hours => coalesce((c->>'aviso_horas')::int, 24));
  dia_atk date := coalesce(_dia_ataque, (ataca at time zone tz)::date);
  aid bigint; adm uuid;
begin
  if _forcar_alvo is not null then
    select ch.user_id, ch.name into esc_uid, esc_nome
      from characters ch where ch.user_id = _forcar_alvo;
  else
    for r in
      select ch.user_id, ch.name, greatest(peso_min, coalesce(ch.coins, 0))::numeric as peso
        from characters ch
       where ch.user_id in (select user_id from public.day_active(public.game_today()))
         and ch.created_at <= now() - make_interval(days => coalesce((c->>'idade_min_dias')::int, 7))
         and exists (select 1 from monsters m where m.user_id = ch.user_id)
         and not exists (
           select 1 from rocket_vila_ataques a
            where a.user_id = ch.user_id and a.status <> 'cancelado'
              and (a.status = 'agendado' or a.avisado_em > now() - make_interval(days => coalesce((c->>'cooldown_dias')::int, 7)))
         )
       order by ch.user_id
    loop
      tot := tot + r.peso;
    end loop;
    if tot <= 0 then return null; end if;
    sorteio := random() * tot;
    for r in
      select ch.user_id, ch.name, greatest(peso_min, coalesce(ch.coins, 0))::numeric as peso
        from characters ch
       where ch.user_id in (select user_id from public.day_active(public.game_today()))
         and ch.created_at <= now() - make_interval(days => coalesce((c->>'idade_min_dias')::int, 7))
         and exists (select 1 from monsters m where m.user_id = ch.user_id)
         and not exists (
           select 1 from rocket_vila_ataques a
            where a.user_id = ch.user_id and a.status <> 'cancelado'
              and (a.status = 'agendado' or a.avisado_em > now() - make_interval(days => coalesce((c->>'cooldown_dias')::int, 7)))
         )
       order by ch.user_id
    loop
      acum := acum + r.peso;
      esc_uid := r.user_id; esc_nome := r.name;
      if sorteio <= acum then exit; end if;
    end loop;
  end if;

  if esc_uid is null then return null; end if;
  insert into villages(user_id) values (esc_uid) on conflict do nothing;

  insert into rocket_vila_ataques(user_id, nome, semana, dia_ataque, avisado_em, ataca_em, status)
  values (esc_uid, esc_nome, sem, dia_atk, now(), ataca, 'agendado')
  returning id into aid;

  insert into event_log(user_id, kind, message)
  values (esc_uid, 'rocket', '🚀 A Equipe Rocket vai atacar a vila de ' || esc_nome || ' em 24 horas! Prepare-se — até 2 amigos podem emprestar reforços.');

  select user_id into adm from user_roles where role = 'admin' order by user_id limit 1;
  if adm is not null then
    insert into posts(kind, title, body, created_by)
    values ('evento', '🚀 Ataque surpresa da Rocket à vila de ' || esc_nome || '!',
            '🚀 A Equipe Rocket vai atacar a vila de ' || esc_nome || ' em 24 horas. Prepare-se! Até 2 amigos podem emprestar 1 Pokémon cada na janela Guerras ou visitando a vila antes do ataque.',
            adm);
  end if;
  return aid;
end $$;

-- resolve o ataque surpresa na hora marcada (mesmo com o dono offline)
create or replace function public.rocket_vila_resolver(_id bigint) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare a rocket_vila_ataques; c jsonb := public.rocket_vila_cfg(); w jsonb := public.war_cfg();
  dv villages; dch characters; max_lv int; cap numeric; bonus numeric; trap numeric; dtac text; dsmart boolean;
  def_mons jsonb := '[]'::jsonb; rk_mons jsonb := '[]'::jsonb; r record; rf record; m jsonb; e jsonb;
  ref_forca numeric := 0; v_def_forca int; fmin int; fmax int; pct int; alvo_forca int; rk_tm jsonb; v_rk_forca int;
  s0 jsonb; s1 jsonb; b battles; venceu boolean; v_rk_caidos int := 0; v_def_caidos int := 0;
  v_moedas int := 0; v_saque int := 0; prot int := 0; v_doce int := 0; b_amigo int; xp_def int;
  pool text[]; k text; dmg text[] := '{}'; roub_id uuid; roub_nome text; roub_sp int; roub_lv int; snap jsonb; msg text;
begin
  select * into a from rocket_vila_ataques where id = _id and status = 'agendado' for update;
  if a.id is null then return null; end if;

  insert into villages(user_id) values (a.user_id) on conflict do nothing;
  perform public.war_free_heal(a.user_id);
  perform public.vl_autofix(a.user_id);
  select * into dv from villages where user_id = a.user_id for update;
  select * into dch from characters where user_id = a.user_id for update;

  select coalesce(max(level), 5) into max_lv from monsters where user_id = a.user_id;
  cap := coalesce((w->>'def_cap')::numeric, 20);
  bonus := least(cap, public.war_num('defesa', 'bonus', public.vl_level(dv, 'defesa')));
  trap := least(cap - bonus, public.war_num('armadilhas', 'pct', public.vl_level(dv, 'armadilhas')));
  dtac := case when public.vl_level(dv, 'academia') >= 2 then dv.def_tactic else 'forte' end;
  dsmart := public.vl_level(dv, 'academia') >= 3;

  -- defensores do próprio dono (esquadrão de defesa ou os 3 primeiros da equipe se não tem Quartel)
  for r in select m2.id, m2.war_hp from unnest(public.war_def_ids(a.user_id)) with ordinality u(mid, o)
             join monsters m2 on m2.id = u.mid where m2.user_id = a.user_id and m2.war_hp > 0 order by u.o loop
    m := public.bt_mon(r.id) || jsonb_build_object('emprestado', false);
    if bonus > 0 then
      m := jsonb_set(m, '{maxhp}', to_jsonb(ceil((m->>'maxhp')::int * (1 + bonus / 100))::int));
      m := jsonb_set(m, '{def}', to_jsonb(ceil((m->>'def')::int * (1 + bonus / 100))::int));
    end if;
    m := jsonb_set(m, '{hp}', to_jsonb(greatest(1, ceil((m->>'maxhp')::int * r.war_hp / 100.0))::int));
    def_mons := def_mons || jsonb_build_array(m);
  end loop;

  -- reforços emprestados por amigos (limitados ao nível do Pokémon mais forte do dono, com atributos recalculados)
  for rf in select x.* from rocket_vila_reforcos x join monsters m2 on m2.id = x.mon_id and m2.user_id = x.amigo_id
             where x.ataque_id = a.id order by x.criado_em limit coalesce((c->>'reforcos_max')::int, 2) loop
    m := public.bt_mon_teto(rf.mon_id, max_lv) || jsonb_build_object('emprestado', true, 'amigo_id', rf.amigo_id, 'amigo_nome', rf.amigo_nome);
    ref_forca := ref_forca + (((m->>'maxhp')::int + (m->>'atk')::int + (m->>'def')::int + (m->>'spd')::int + (m->>'spc')::int) / 10.0) * (1 + (bonus + trap) / 100.0);
    if bonus > 0 then
      m := jsonb_set(m, '{maxhp}', to_jsonb(ceil((m->>'maxhp')::int * (1 + bonus / 100))::int));
      m := jsonb_set(m, '{def}', to_jsonb(ceil((m->>'def')::int * (1 + bonus / 100))::int));
      m := jsonb_set(m, '{hp}', m->'maxhp');
    end if;
    def_mons := def_mons || jsonb_build_array(m);
  end loop;

  v_def_forca := greatest(15, round(public.war_power(a.user_id, 'defesa') + ref_forca)::int);
  fmin := coalesce((c->>'forca_min_pct')::int, 100);
  fmax := greatest(fmin, coalesce((c->>'forca_max_pct')::int, 120));
  pct := fmin + floor(random() * (fmax - fmin + 1))::int;
  alvo_forca := greatest(15, round(v_def_forca * pct / 100.0)::int);
  rk_tm := public.rocket_vila_montar_time(alvo_forca, greatest(3, least(5, jsonb_array_length(def_mons))));
  v_rk_forca := public.rocket_base_forca(rk_tm);

  for e in select x from jsonb_array_elements(rk_tm) x loop
    m := public.rocket_mon((e->>0)::int, (e->>1)::int);
    if jsonb_array_length(rk_mons) = 0 and trap > 0 then
      m := jsonb_set(m, '{hp}', to_jsonb(greatest(1, ceil((m->>'hp')::int * (1 - trap / 100))::int)));
    end if;
    rk_mons := rk_mons || jsonb_build_array(m);
  end loop;

  s0 := jsonb_build_object('user', a.user_id, 'name', 'Equipe Rocket', 'npc', true, 'active', 0, 'need_switch', false, 'mons', rk_mons);
  s1 := jsonb_build_object('user', a.user_id, 'name', dch.name, 'active', 0, 'need_switch', false, 'mons', def_mons);

  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (a.user_id, a.user_id, 'npc', greatest(3, jsonb_array_length(def_mons)), 'ativa', 1, 'normal', now(),
          jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', '🚀 A Equipe Rocket atacou a vila de ' || dch.name || '!'),
            jsonb_build_object('txt', 'A Equipe Rocket mandou ' || (rk_mons->0->>'name') || '!')) ||
            case when jsonb_array_length(def_mons) > 0 then jsonb_build_array(jsonb_build_object('txt', dch.name || ' defendeu com ' || (def_mons->0->>'name') || '!'))
                 else jsonb_build_array(jsonb_build_object('txt', 'Não havia Pokémon acordados na defesa!')) end)))
  returning * into b;

  if jsonb_array_length(def_mons) = 0 then
    venceu := false;
    perform public.bt_finish(b.id, null, 'sem_defesa');
  else
    perform public.war_rodar_luta(b.id, a.user_id, a.user_id, 'forte', dtac, true, dsmart, 50);
    select * into b from battles where id = b.id;
    -- lado 1 é a defesa da vila; lado 0 é a Rocket
    if b.end_reason in ('impasse', 'limite') then
      venceu := (select sum((x->>'hp')::int)::numeric / greatest(1, sum((x->>'maxhp')::int)) from jsonb_array_elements(b.state->'sides'->1->'mons') x)
              > (select sum((x->>'hp')::int)::numeric / greatest(1, sum((x->>'maxhp')::int)) from jsonb_array_elements(b.state->'sides'->0->'mons') x);
    else
      venceu := not exists (select 1 from jsonb_array_elements(b.state->'sides'->0->'mons') x where (x->>'hp')::int > 0)
                and exists (select 1 from jsonb_array_elements(b.state->'sides'->1->'mons') x where (x->>'hp')::int > 0);
    end if;
  end if;

  select * into b from battles where id = b.id;
  select count(*) filter (where (x->>'hp')::int <= 0) into v_rk_caidos from jsonb_array_elements(b.state->'sides'->0->'mons') x;
  select count(*) filter (where (x->>'hp')::int <= 0) into v_def_caidos from jsonb_array_elements(b.state->'sides'->1->'mons') x;

  -- desgaste só nos Pokémon do dono (os ajudantes nunca perdem nada)
  for m in select x from jsonb_array_elements(b.state->'sides'->1->'mons') x where not coalesce((x->>'emprestado')::boolean, false) loop
    update monsters set war_hp = greatest(0, least(100, floor((m->>'hp')::int * 100.0 / greatest(1, (m->>'maxhp')::int))))::int,
                        war_hurt_at = case when (m->>'hp')::int < (m->>'maxhp')::int then now() else war_hurt_at end
     where id = (m->>'id')::uuid and user_id = a.user_id;
  end loop;

  if venceu then
    v_moedas := greatest(coalesce((c->>'moedas_min')::int, 75),
                         least(coalesce((c->>'moedas_max')::int, 200), round(v_rk_forca * coalesce((c->>'moedas_por_forca')::numeric, 1.2))::int));
    perform public.ext_origem('Defesa contra a Rocket', 'guerra');
    update characters set coins = coins + v_moedas where user_id = a.user_id;

    xp_def := greatest(40, v_rk_forca * 2);
    for m in select x from jsonb_array_elements(b.state->'sides'->1->'mons') x where not coalesce((x->>'emprestado')::boolean, false) loop
      if exists (select 1 from monsters where id = (m->>'id')::uuid and user_id = a.user_id) then
        perform public.pk_give_xp((m->>'id')::uuid, xp_def, 'rocket');
      end if;
    end loop;

    if random() * 100 < coalesce((c->>'doce_pct')::numeric, 25) then
      v_doce := 1;
      insert into equip_doces(user_id, qty) values (a.user_id, 1) on conflict (user_id) do update set qty = equip_doces.qty + 1;
    end if;

    -- bônus extra de 25% para cada amigo que emprestou Pokémon (não sai do prêmio do defensor) + XP no Pokémon emprestado
    b_amigo := greatest(1, round(v_moedas * coalesce((c->>'ajudante_bonus_pct')::numeric, 25) / 100.0)::int);
    for rf in select * from rocket_vila_reforcos where ataque_id = a.id loop
      perform public.ext_origem('Reforço contra a Rocket', 'guerra');
      update characters set coins = coins + b_amigo where user_id = rf.amigo_id;
      if exists (select 1 from monsters where id = rf.mon_id and user_id = rf.amigo_id) then
        perform public.pk_give_xp(rf.mon_id, xp_def, 'rocket');
      end if;
      update rocket_vila_reforcos set moedas = b_amigo, xp = xp_def where ataque_id = a.id and amigo_id = rf.amigo_id;
    end loop;

    msg := '🛡️ A vila de ' || dch.name || ' derrotou o ataque surpresa da Equipe Rocket e ganhou ' || v_moedas || ' moedas'
           || case when v_doce > 0 then ' e um Doce de Forja' else '' end || '!';
    insert into event_log(user_id, kind, message) values (a.user_id, 'rocket', msg);
  else
    -- derrota: perde 10% das moedas desprotegidas (até 200; Cofre + base + Quartel protegem), 1 construção danificada (3 dias) e escudo de 24h
    prot := (w->>'base_protect')::int + public.war_num('cofre', 'protect', public.vl_level(dv, 'cofre'))::int
          + public.war_num('quartel', 'protect', public.vl_level(dv, 'quartel'))::int;
    v_saque := least(coalesce((c->>'saque_max')::int, 200),
                     floor(greatest(0, dch.coins - prot) * coalesce((c->>'saque_pct')::numeric, 10) / 100.0))::int;
    v_saque := greatest(0, least(v_saque, dch.coins));
    if v_saque > 0 then
      perform public.ext_origem('Saque da Equipe Rocket', 'guerra');
      update characters set coins = coins - v_saque where user_id = a.user_id;
    end if;

    select array_agg(x) into pool from jsonb_array_elements_text(w->'damage_pool') x
     where public.vl_level(dv, x, true) > 0 and not (dv.damaged ? x);
    if pool is not null and cardinality(pool) > 0 then
      k := pool[1 + floor(random() * cardinality(pool))::int];
      dmg := array[k];
      update villages
         set damaged = damaged || jsonb_build_object(k, jsonb_build_object('at', now(), 'fix', now() + make_interval(days => coalesce((w->>'auto_fix_days')::int, 3))))
       where user_id = a.user_id;
    end if;

    update villages
       set shield_until = greatest(coalesce(shield_until, now()), now() + make_interval(hours => coalesce((w->>'shield_hours')::int, 24)))
     where user_id = a.user_id;

    -- se não derrubou nenhum Pokémon da Rocket, leva 1 Pokémon DO DONO DA VILA (nunca um emprestado) para base de resgate de 7 dias
    if v_rk_caidos = 0 then
      select m2.id, p.name, m2.species_id, m2.level into roub_id, roub_nome, roub_sp, roub_lv
        from monsters m2 join pokemon p on p.id = m2.species_id
       where m2.user_id = a.user_id
         and not public.gin_preso(a.user_id, m2.id)
         and not exists (select 1 from battles b2, jsonb_array_elements(b2.state->'sides') sd, jsonb_array_elements(sd->'mons') bm
                          where b2.status = 'ativa' and b2.id <> b.id and a.user_id in (b2.p1, b2.p2) and bm->>'id' = m2.id::text)
       order by (m2.id = any(public.war_def_ids(a.user_id))) desc, (m2.team_slot is not null) desc, random()
       limit 1;
      if roub_id is not null then
        snap := public.rocket_resgate_roubo(a.user_id, dch.name, roub_id, roub_nome);
      end if;
    end if;

    msg := '🚀 A Equipe Rocket saqueou a vila de ' || dch.name || ' (' || v_saque || ' moedas)'
           || case when snap is not null then ' e levou o ' || roub_nome || ' para um esconderijo de 7 dias!' else '!' end;
    insert into event_log(user_id, kind, message) values (a.user_id, 'rocket', msg);
  end if;

  update rocket_vila_ataques
     set status = case when venceu then 'vitoria' else 'derrota' end,
         resolvido_em = now(),
         def_forca = v_def_forca, rk_forca = v_rk_forca, rk_pct = pct, rk_time = rk_tm,
         moedas = v_moedas, saque = v_saque, doce = v_doce, damaged = dmg,
         rk_caidos = v_rk_caidos, def_caidos = v_def_caidos,
         roubado_info = case when snap is not null then jsonb_build_object('mon', roub_nome, 'species', roub_sp, 'level', roub_lv) end,
         log = b.log
   where id = a.id;

  delete from battles where id = b.id;
  return jsonb_build_object('id', a.id, 'venceu', venceu, 'moedas', v_moedas, 'saque', v_saque, 'doce', v_doce, 'damaged', dmg,
                            'def_forca', v_def_forca, 'rk_forca', v_rk_forca, 'rk_caidos', v_rk_caidos, 'roubado', snap is not null);
end $$;

-- escolhe os N dias da semana que NÃO são dias de invasão da Rocket para os ataques surpresa da semana
create or replace function public.rocket_vila_dias_semana(_semana date) returns int[]
language plpgsql stable security definer set search_path = public, extensions as $$
declare rk_days int[]; livres int[]; qtd int := greatest(0, coalesce((public.rocket_vila_cfg()->>'por_semana')::int, 2));
begin
  select coalesce(array_agg(x::int), array[0, 2, 5]) into rk_days from jsonb_array_elements_text(coalesce(public.rocket_cfg()->'days', '[0,2,5]'::jsonb)) x;
  select coalesce(array_agg(d order by abs(hashtext('rkvila:' || _semana::text || ':' || d::text)), d), '{}')
    into livres
    from generate_series(0, 6) d
   where not (d = any(rk_days));
  return livres[1:least(qtd, cardinality(livres))];
end $$;

-- relógio dos ataques surpresa às vilas: resolve os vencidos sempre, e em produção agenda os 2 da semana com 24h de aviso
create or replace function public.rocket_vila_tick() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rocket_vila_cfg(); tz text := coalesce(public.cfg()->>'timezone', 'America/Sao_Paulo');
  loc timestamp := now() at time zone tz; hoje date := loc::date; amanha date := hoje + 1;
  sem_amanha date := date_trunc('week', amanha)::date; dias int[]; r record; st timestamptz;
begin
  if public.jogo_pausado() then return; end if;
  for r in select id from rocket_vila_ataques where status = 'agendado' and ataca_em <= now() order by ataca_em loop
    perform public.rocket_vila_resolver(r.id);
  end loop;

  if not coalesce((c->>'on')::boolean, true) then return; end if;
  if to_regclass('public.sql_aplicados') is null then return; end if;

  -- avisa 24h antes de um dia sorteado de ataque (amanhã), na hora configurada
  dias := public.rocket_vila_dias_semana(sem_amanha);
  if not (extract(dow from amanha)::int = any(dias)) then return; end if;
  st := (hoje + make_interval(hours => coalesce((c->>'hora')::int, 19))) at time zone tz;
  if now() < st or now() > st + interval '4 hours' then return; end if;
  if exists (select 1 from rocket_vila_ataques where dia_ataque = amanha and status <> 'cancelado') then return; end if;
  if (select count(*) from rocket_vila_ataques where semana = sem_amanha and status <> 'cancelado') >= coalesce((c->>'por_semana')::int, 2) then return; end if;

  perform pg_advisory_xact_lock(44125);
  if exists (select 1 from rocket_vila_ataques where dia_ataque = amanha and status <> 'cancelado') then return; end if;
  perform public.rocket_vila_sortear(null, amanha);
end $$;

-- amigo empresta 1 Pokémon para ajudar na defesa de uma vila sob aviso da Rocket
create or replace function public.rocket_vila_emprestar(_ataque_id bigint, _mon uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.rocket_vila_cfg(); a rocket_vila_ataques;
  m monsters; ch characters; p pokemon; max_lv int; n int;
begin
  perform public.rocket_vila_tick();
  select * into a from rocket_vila_ataques where id = _ataque_id for update;
  if a.id is null or a.status <> 'agendado' or now() >= a.ataca_em then
    raise exception 'Esse ataque da Rocket já começou ou não está mais aberto para reforços.';
  end if;
  if a.user_id = uid then raise exception 'Você é o dono da vila: monte seu esquadrão de defesa no Quartel ou na sua equipe.'; end if;
  select * into m from monsters where id = _mon and user_id = uid;
  if m.id is null then raise exception 'Escolha um Pokémon da sua coleção.'; end if;
  perform public.gin_trava(uid, array[_mon]);
  if exists (select 1 from creche_pedidos where mon_id = _mon and status = 'treinando') then raise exception 'Esse Pokémon está na Creche.'; end if;
  if exists (select 1 from leiloes where mon_id = _mon and status = 'aberto') then raise exception 'Esse Pokémon está no Leilão.'; end if;
  if exists (select 1 from trocas where status in ('pendente', 'confirmar') and (mon_de = _mon or mon_para = _mon)) then raise exception 'Esse Pokémon está numa proposta de troca.'; end if;
  if exists (select 1 from battles b, jsonb_array_elements(b.state->'sides') sd, jsonb_array_elements(sd->'mons') bm
              where b.status = 'ativa' and uid in (b.p1, b.p2) and bm->>'id' = _mon::text) then raise exception 'Esse Pokémon está numa batalha em andamento.'; end if;
  if exists (select 1 from rocket_vila_reforcos rf join rocket_vila_ataques a2 on a2.id = rf.ataque_id
              where rf.mon_id = _mon and a2.status = 'agendado' and a2.id <> a.id) then
    raise exception 'Esse Pokémon já está emprestado em outra vila.';
  end if;

  if not exists (select 1 from rocket_vila_reforcos where ataque_id = a.id and amigo_id = uid) then
    select count(*) into n from rocket_vila_reforcos where ataque_id = a.id;
    if n >= coalesce((c->>'reforcos_max')::int, 2) then
      raise exception 'Essa vila já recebeu o limite de % reforços.', coalesce((c->>'reforcos_max')::int, 2);
    end if;
  end if;

  select * into ch from characters where user_id = uid;
  select * into p from pokemon where id = m.species_id;
  select coalesce(max(level), 5) into max_lv from monsters where user_id = a.user_id;

  insert into rocket_vila_reforcos(ataque_id, amigo_id, amigo_nome, mon_id, mon_nome, species, level_real)
  values (a.id, uid, ch.name, m.id, p.name, m.species_id, m.level)
  on conflict (ataque_id, amigo_id) do update
     set mon_id = excluded.mon_id, mon_nome = excluded.mon_nome, species = excluded.species, level_real = excluded.level_real, criado_em = now();

  return jsonb_build_object('ok', true, 'teto_nivel', max_lv, 'nivel_luta', least(m.level, max_lv));
end $$;

create or replace function public.rocket_vila_retirar(_ataque_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); a rocket_vila_ataques;
begin
  select * into a from rocket_vila_ataques where id = _ataque_id for update;
  if a.id is null or a.status <> 'agendado' or now() >= a.ataca_em then
    raise exception 'Não dá mais para retirar o reforço.';
  end if;
  delete from rocket_vila_reforcos where ataque_id = a.id and amigo_id = uid;
end $$;

create or replace function public.rocket_vila_estado(_vila uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.rocket_vila_cfg(); alvo uuid := coalesce(_vila, uid);
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  perform public.rocket_vila_tick();
  return jsonb_build_object(
    'on', coalesce((c->>'on')::boolean, true),
    'reforcos_max', coalesce((c->>'reforcos_max')::int, 2),
    'ajudante_bonus_pct', coalesce((c->>'ajudante_bonus_pct')::int, 25),
    'agendados', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id, 'user_id', a.user_id, 'nome', a.nome, 'avisado_em', a.avisado_em, 'ataca_em', a.ataca_em,
        'meu', a.user_id = uid,
        'teto_nivel', coalesce((select max(m.level) from monsters m where m.user_id = a.user_id), 5),
        'def_forca', public.war_power(a.user_id, 'defesa'),
        'reforcos', coalesce((select jsonb_agg(jsonb_build_object(
            'amigo_id', rf.amigo_id, 'amigo_nome', rf.amigo_nome, 'mon_id', rf.mon_id, 'mon_nome', rf.mon_nome,
            'species', rf.species, 'level_real', rf.level_real,
            'level_luta', least(rf.level_real, coalesce((select max(m.level) from monsters m where m.user_id = a.user_id), 5))
          ) order by rf.criado_em) from rocket_vila_reforcos rf where rf.ataque_id = a.id), '[]'::jsonb)
      ) order by a.ataca_em)
      from rocket_vila_ataques a where a.status = 'agendado'
    ), '[]'::jsonb),
    'historico', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id, 'user_id', a.user_id, 'nome', a.nome, 'status', a.status, 'ataca_em', a.ataca_em, 'resolvido_em', a.resolvido_em,
        'def_forca', a.def_forca, 'rk_forca', a.rk_forca, 'moedas', a.moedas, 'saque', a.saque, 'doce', a.doce,
        'damaged', a.damaged, 'rk_caidos', a.rk_caidos, 'roubado_info', a.roubado_info, 'tem_log', a.log is not null,
        'reforcos', coalesce((select jsonb_agg(jsonb_build_object('amigo_id', rf.amigo_id, 'amigo_nome', rf.amigo_nome, 'mon_nome', rf.mon_nome, 'species', rf.species, 'moedas', rf.moedas, 'xp', rf.xp))
                                from rocket_vila_reforcos rf where rf.ataque_id = a.id), '[]'::jsonb)
      ) order by coalesce(a.resolvido_em, a.ataca_em) desc)
      from (select * from rocket_vila_ataques a2
             where a2.status in ('vitoria', 'derrota')
               and (a2.user_id in (uid, alvo) or exists (select 1 from rocket_vila_reforcos rf where rf.ataque_id = a2.id and rf.amigo_id = uid))
             order by coalesce(a2.resolvido_em, a2.ataca_em) desc limit 15) a
    ), '[]'::jsonb)
  );
end $$;

create or replace function public.rocket_vila_log(_id bigint) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); a rocket_vila_ataques;
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  select * into a from rocket_vila_ataques where id = _id and status in ('vitoria', 'derrota');
  if a.id is null then raise exception 'Relato não encontrado.'; end if;
  return jsonb_build_object('id', a.id, 'nome', a.nome, 'status', a.status, 'log', coalesce(a.log, '[]'::jsonb));
end $$;

-- proteções contra soltar ou leiloar um Pokémon emprestado num ataque agendado da Rocket
create or replace function public.mon_release(_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active();
begin
  if not exists (select 1 from monsters where id = _id and user_id = uid) then raise exception 'Esse Pokémon não é seu.'; end if;
  if public.rocket_vila_mon_preso(_id) then raise exception 'Esse Pokémon está emprestado na defesa contra a Equipe Rocket.'; end if;
  if exists (select 1 from trocas where status in ('pendente', 'confirmar') and (mon_de = _id or mon_para = _id)) then
    raise exception 'Esse Pokémon está numa proposta de troca.'; end if;
  if exists (select 1 from battles b, jsonb_array_elements(b.state->'sides') sd, jsonb_array_elements(sd->'mons') mm
             where b.status = 'ativa' and uid in (b.p1, b.p2) and mm->>'id' = _id::text) then
    raise exception 'Esse Pokémon está numa batalha em andamento.'; end if;
  if exists (select 1 from characters where user_id = uid and mascot->>'id' = _id::text) then update characters set mascot = null where user_id = uid; end if;
  delete from monsters where id = _id and user_id = uid;
end $$;

create or replace function public.leilao_criar(_mon uuid, _min integer) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.leilao_cfg(); m monsters; ult timestamptz; l leiloes;
begin
  perform public.gin_trava(uid, array[_mon]);
  if public.rocket_vila_mon_preso(_mon) then raise exception 'Esse Pokémon está emprestado na defesa contra a Equipe Rocket.'; end if;
  if exists (select 1 from trocas where status in ('pendente', 'confirmar') and (mon_de = _mon or mon_para = _mon)) then
    raise exception 'Esse Pokémon está numa proposta de troca.'; end if;
  if not coalesce((c->>'on')::boolean, true) then raise exception 'O Leilão está fechado no momento.'; end if;
  perform 1 from characters where user_id = uid for update;
  perform public.leilao_tick();
  select * into m from monsters where id = _mon and user_id = uid;
  if m.id is null then raise exception 'Escolha um Pokémon seu.'; end if;
  if exists (select 1 from leiloes where mon_id = m.id and status = 'aberto') then raise exception 'Esse Pokémon já está em leilão.'; end if;
  select max(created_at) into ult from leiloes where seller = uid and status <> 'cancelado';
  if ult is not null and now() < ult + make_interval(days => (c->>'intervalo_dias')::int) then
    raise exception 'Você pode pôr 1 Pokémon em leilão a cada % dias. O próximo libera em %.', c->>'intervalo_dias',
      to_char((ult + make_interval(days => (c->>'intervalo_dias')::int)) at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI');
  end if;
  if _min is null or _min < (c->>'min_preco')::int or _min > 1000000 then raise exception 'O lance mínimo precisa ser de pelo menos % moedas.', c->>'min_preco'; end if;
  insert into leiloes(seller, mon_id, species, level, info, min_price, ends_at)
  values (uid, m.id, m.species_id, m.level, public.bt_mon(m.id) - 'outfit' || jsonb_build_object('dvs', jsonb_build_array(m.dv_atk, m.dv_def, m.dv_spd, m.dv_spc)),
          _min, now() + make_interval(hours => (c->>'horas')::int))
  returning * into l;
  insert into event_log(user_id, kind, message) select uid, 'leilao', ch.name || ' pôs ' || (select name from pokemon where id = m.species_id) || ' (nível ' || m.level || ') no Leilão, a partir de ' || _min || ' moedas.' from characters ch where ch.user_id = uid;
  return to_jsonb(l);
end $$;

-- vitória contra ataque surpresa da Rocket conta em "defesas vencidas" nos prêmios da temporada
create or replace function public.season_rank(_cat text, _t0 timestamp with time zone, _t1 timestamp with time zone)
returns table(user_id uuid, val numeric)
language plpgsql stable security definer set search_path = public, extensions as $$
declare d0 date := (_t0 at time zone 'America/Sao_Paulo')::date;
        d1 date := ((_t1 at time zone 'America/Sao_Paulo') - interval '1 second')::date;
begin
  if _cat = 'casas' then return query
    select m.user_id, sum(m.base_steps + m.roll + m.bonus_steps + coalesce(m.skill_steps, 0))::numeric from daily_moves m where m.move_date between d0 and d1 group by 1;
  elsif _cat = 'moedas' then return query
    select m.user_id, sum(greatest(m.coins_gained, 0))::numeric from daily_moves m where m.move_date between d0 and d1 group by 1;
  elsif _cat = 'capturas' then return query
    select e.user_id, count(*)::numeric from encounters e where e.status = 'capturado' and e.resolved_at >= _t0 and e.resolved_at < _t1 group by 1;
  elsif _cat = 'rodadas' then return query
    select r.user_id, count(*)::numeric from round_results r where r.rank = 1 and r.d between d0 and d1 group by 1;
  elsif _cat = 'batalhas' then return query
    select b.winner, count(*)::numeric from battles b where b.status = 'encerrada' and b.winner is not null and b.p1 <> b.p2
      and coalesce(b.mode, 'duelo') in ('duelo', 'liga') and b.ended_at >= _t0 and b.ended_at < _t1 group by 1;
  elsif _cat = 'duelos' then return query
    select d.winner, count(*)::numeric from duels d where d.status = 'concluido' and d.winner is not null
      and coalesce(d.resolved_at, d.created_at) >= _t0 and coalesce(d.resolved_at, d.created_at) < _t1 group by 1;
  elsif _cat = 'rocket' then return query
    select e.user_id, sum(e.ondas)::numeric from rocket_entries e join rocket_raids r on r.id = e.raid_id
      where r.starts_at >= _t0 and r.starts_at < _t1 group by 1;
  elsif _cat = 'quiz' then return query
    select q.winner, count(*)::numeric from quizzes q where q.status = 'encerrado' and q.winner is not null
      and coalesce(q.closed_at, q.closes_at) >= _t0 and coalesce(q.closed_at, q.closes_at) < _t1 group by 1;
  elsif _cat = 'treinadores' then return query
    select f.user_id, count(*)::numeric from npc_fights f where f.won and f.created_at >= _t0 and f.created_at < _t1 group by 1;
  elsif _cat = 'primeira' then return query
    select g.user_id, count(*)::numeric from guess_sessions g where g.solved and g.attempts = 1 and not coalesce(g.recovered, false)
      and g.puzzle_date between d0 and d1 group by 1;
  elsif _cat = 'pokedex' then return query
    select p.user_id, count(*)::numeric from pokedex_entries p where p.caught_at >= _t0 and p.caught_at < _t1 group by 1;
  elsif _cat = 'cacadas' then return query
    select h.hunter, count(*)::numeric from hunts h where h.status = 'capturado' and h.hunter is not null
      and h.resolved_at >= _t0 and h.resolved_at < _t1 group by 1;
  elsif _cat = 'evolucoes' then return query
    select l.user_id, count(*)::numeric from event_log l where l.kind = 'evolucao' and l.user_id is not null and l.created_at >= _t0 and l.created_at < _t1 group by 1;
  elsif _cat = 'insignias' then return query
    select i.user_id, count(*)::numeric from rpg_insignias i where i.ganho_em >= _t0 and i.ganho_em < _t1 group by 1;
  elsif _cat = 'ataques' then return query
    select w.attacker, count(*)::numeric from wars w where w.winner = w.attacker and w.created_at >= _t0 and w.created_at < _t1 group by 1;
  elsif _cat = 'defesas' then return query
    select x.u, count(*)::numeric from (
      select w.defender u from wars w where w.winner = w.defender and w.created_at >= _t0 and w.created_at < _t1
      union all
      select rva.user_id u from rocket_vila_ataques rva
       where rva.status = 'vitoria' and coalesce(rva.resolvido_em, rva.ataca_em) >= _t0 and coalesce(rva.resolvido_em, rva.ataca_em) < _t1
    ) x group by 1;
  elsif _cat = 'cartas' then return query
    select t.winner, count(*)::numeric from tcg_duelos t where t.status = 'encerrada' and not t.treino and t.winner is not null
      and t.ended_at >= _t0 and t.ended_at < _t1 group by 1;
  elsif _cat = 'pokebound' then return query
    select p.vencedor, count(*)::numeric from pb_partidas p where p.status = 'fim' and p.vencedor is not null and p.fim >= _t0 and p.fim < _t1 group by 1;
  elsif _cat = 'missoes' then return query
    select m.user_id, count(*)::numeric from rpg_missoes m where m.resgatada and m.dia between d0 and d1 group by 1;
  elsif _cat = 'chefe' then return query
    select d.user_id, sum(d.dano)::numeric from rpg_chefe_dano d join rpg_chefes c on c.id = d.chefe_id
      where c.inicio >= _t0 and c.inicio < _t1 group by 1;
  elsif _cat = 'negociante' then return query
    select x.u, count(*)::numeric from (
      select l.seller_id u from market_listings l where l.status in ('vendido', 'trocado') and l.closed_at >= _t0 and l.closed_at < _t1
      union all select l.buyer_id from market_listings l where l.status in ('vendido', 'trocado') and l.buyer_id is not null and l.closed_at >= _t0 and l.closed_at < _t1
      union all select a.seller from leiloes a where a.status = 'vendido' and a.closed_at >= _t0 and a.closed_at < _t1
      union all select a.top_bidder from leiloes a where a.status = 'vendido' and a.top_bidder is not null and a.closed_at >= _t0 and a.closed_at < _t1
      union all select t.de from trocas t where t.status = 'aceita' and t.fim >= _t0 and t.fim < _t1
      union all select t.para from trocas t where t.status = 'aceita' and t.fim >= _t0 and t.fim < _t1) x
    where x.u is not null group by 1;
  elsif _cat = 'azarado' then return query
    select c.user_id, sum(c.casas)::numeric from casas_perdidas c where c.created_at >= _t0 and c.created_at < _t1 group by 1;
  end if;
end $$;


-- ============================================================================
-- 5. REVANCHES DE GINÁSIO: LIMITE DE 3 REVANCHES PAGAS POR DIA
-- ============================================================================

create table if not exists public.rpg_gin_revanches (
  user_id uuid not null references auth.users(id) on delete cascade,
  dia     date not null,
  pagas   int  not null default 0,
  primary key (user_id, dia)
);
alter table public.rpg_gin_revanches enable row level security;

create or replace function public.rpg_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_set(
    ('{"on": true, "batalhas_dia": 20, "chance_pct": 12, "espera_seg": 8, "envio_seg": 1.2, "fuga_base": 10, "fuga_por_ataque": 10, "nivel_pedra": 28, "nivel_troca": 36, "folga": 10, "lendarios": [144, 145, 146, 150, 151, 243, 244, 245, 249, 250, 251], "zonas": {"mato": {"nome": "Capim alto", "regiao": "vila", "tipos": ["INSETO", "PLANTA", "NORMAL"], "min": 2, "max": 6}, "escura": {"nome": "Grama escura", "regiao": "vila", "tipos": ["NORMAL", "VOADOR", "ELETRICO"], "min": 3, "max": 7}, "pantano": {"nome": "Pântano", "regiao": "vila", "tipos": ["AGUA", "VENENO"], "min": 3, "max": 7}, "pedra": {"nome": "Alto do penhasco", "regiao": "vila", "tipos": ["PEDRA", "TERRA", "LUTA"], "min": 4, "max": 8}, "bosque": {"nome": "Bosque: mato", "regiao": "bosque", "tipos": ["INSETO", "PLANTA", "VENENO", "NORMAL"], "min": 8, "max": 16}, "bosque_fundo": {"nome": "Bosque: mata funda", "regiao": "bosque", "tipos": ["INSETO", "PLANTA", "VENENO", "NORMAL", "VOADOR"], "min": 18, "max": 34}, "praia": {"nome": "Praia: dunas", "regiao": "praia", "tipos": ["AGUA", "ELETRICO", "NORMAL"], "min": 8, "max": 16}, "praia_fundo": {"nome": "Praia: costão", "regiao": "praia", "tipos": ["AGUA", "ELETRICO", "GELO", "VOADOR"], "min": 18, "max": 38}, "deserto": {"nome": "Deserto: capim seco", "regiao": "deserto", "tipos": ["FOGO", "TERRA", "NORMAL"], "min": 12, "max": 22}, "deserto_fundo": {"nome": "Deserto: oásis distante", "regiao": "deserto", "tipos": ["FOGO", "TERRA", "PEDRA", "LUTA"], "min": 24, "max": 42}, "pedreira": {"nome": "Pedreira: entrada", "regiao": "pedreira", "tipos": ["PEDRA", "TERRA", "LUTA", "METALICO"], "min": 12, "max": 22}, "pedreira_fundo": {"nome": "Pedreira: fundo da gruta", "regiao": "pedreira", "tipos": ["PEDRA", "TERRA", "LUTA", "METALICO", "DRAGAO"], "min": 24, "max": 44}, "charco": {"nome": "Charco: margem", "regiao": "charco", "tipos": ["VENENO", "FANTASMA", "PSIQUICO", "SOMBRIO"], "min": 20, "max": 32}, "charco_fundo": {"nome": "Charco: brejo escuro", "regiao": "charco", "tipos": ["FANTASMA", "PSIQUICO", "SOMBRIO", "VENENO", "NORMAL"], "min": 32, "max": 46}, "pico": {"nome": "Pico: encosta", "regiao": "pico", "tipos": ["GELO", "AGUA", "PSIQUICO", "VOADOR", "ELETRICO"], "min": 34, "max": 48}, "pico_fundo": {"nome": "Pico: cume", "regiao": "pico", "tipos": ["DRAGAO", "GELO", "VOADOR", "PSIQUICO", "FOGO", "LUTA", "NORMAL", "PEDRA"], "min": 45, "max": 60}, "vulcao": {"nome": "Vulcão: encosta", "regiao": "vulcao", "tipos": ["FOGO", "PEDRA", "TERRA", "LUTA"], "min": 40, "max": 50}, "vulcao_fundo": {"nome": "Vulcão: cratera", "regiao": "vulcao", "tipos": ["FOGO", "DRAGAO", "PEDRA", "TERRA", "VOADOR"], "min": 48, "max": 60}, "estrada": {"nome": "Estrada da Vitória: trilha", "regiao": "estrada", "tipos": ["LUTA", "PEDRA", "TERRA", "VENENO", "VOADOR", "NORMAL"], "min": 52, "max": 62}, "estrada_fundo": {"nome": "Estrada da Vitória: desfiladeiro", "regiao": "estrada", "tipos": ["DRAGAO", "PSIQUICO", "LUTA", "GELO", "FANTASMA", "AGUA"], "min": 58, "max": 70}}}'::jsonb
     || '{"pvp": {"on": true, "distancia": 2, "desafia_dia": 1, "recebe_dia": 3, "teto": true, "prazo_horas": 24, "oferta_min": 1}}'::jsonb
     || '{"noite": {"on": true, "inicio": 19, "fim": 5, "tipos": ["FANTASMA", "SOMBRIO"]}, "missoes": {"on": true, "por_dia": 3, "moedas_min": 15, "moedas_max": 40, "itens": ["pocao", "super_pocao", "hiper_pocao", "reviver", "antidoto", "despertar", "cura_paralisia", "x_ataque", "x_defesa", "x_velocidade", "x_especial"]}, "ginasios": {"on": true, "tentativas_dia": 3, "expira_min": 30, "moedas_por_nivel": 10, "revanche_on": true, "revanche_pct": 25, "revanche_pagas_dia": 3, "faixas": {"iniciais": {"rotas": ["bosque", "praia", "deserto"], "itens": {"super_pocao": 1, "reviver": 1}, "doces": 1}, "intermediarias": {"rotas": ["pedreira", "charco", "pico"], "itens": {"hiper_pocao": 1, "reviver": 2}, "doces": 2}, "finais": {"rotas": ["vulcao", "estrada"], "itens": {"max_pocao": 1, "restaurar_tudo": 1}, "doces": 3, "tm": 1}}, "moedas": 300, "itens": {"max_pocao": 2, "reviver": 2}, "todas_moedas": 1000, "todas_itens": {"restaurar_tudo": 5}}, "chefe": {"on": true, "dia_semana": 6, "hora": 10, "horas": 48, "nivel": 75, "vidas": 40, "turnos": 12, "tentativas_dia": 3, "especies": [149, 130, 143, 112, 94, 68, 131, 59, 6, 65], "moedas": 250, "itens": {"restaurar_tudo": 1, "reviver": 1}, "top_moedas": [300, 200, 100]}}'::jsonb
     || '{"elite": {"on": true, "insignias_min": 8, "tentativas_dia": 1, "time_max": 6, "moedas": 5000, "itens": {"restaurar_tudo": 5, "reviver": 5}, "doces": 5, "repetir_moedas": 1000, "repetir_doces": 1}}'::jsonb
     || coalesce(public.cfg()->'rpg', '{}'::jsonb)) #- '{ginasios,lideres}',
    '{ginasios,revanche_pagas_dia}',
    to_jsonb(coalesce((public.cfg()->'rpg'->'ginasios'->>'revanche_pagas_dia')::int, 3))
  )
$$;

create or replace function public.rpg_gin_vitoria(_uid uuid, _regiao text, _lider text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rpg_cfg(); pr jsonb := public.rpg_gin_premio(_regiao); nome text; n int; drop_ jsonb; tm text; k int;
  moedas int := 0; lim int := greatest(0, coalesce((c->'ginasios'->>'revanche_pagas_dia')::int, 3)); usadas int := 0;
begin
  select name into nome from characters where user_id = _uid;
  if exists (select 1 from rpg_insignias where user_id = _uid and regiao = _regiao) then
    insert into rpg_gin_revanches(user_id, dia, pagas) values (_uid, public.game_today(), 0) on conflict (user_id, dia) do nothing;
    select pagas into usadas from rpg_gin_revanches where user_id = _uid and dia = public.game_today() for update;
    if usadas < lim then
      moedas := floor((pr->>'moedas')::int * (pr->>'revanche_pct')::numeric / 100)::int;
      update rpg_gin_revanches set pagas = pagas + 1 where user_id = _uid and dia = public.game_today();
      if moedas > 0 then perform public.rpg_premiar(_uid, moedas, '{}'::jsonb); end if;
      usadas := usadas + 1;
    end if;
    insert into event_log(user_id, kind, message) values (_uid, 'ginasio', '🏟️ ' || nome || ' venceu a revanche contra ' || _lider || '!');
    return jsonb_build_object('revanche', true, 'revanche_sem_moedas', moedas = 0,
                              'revanche_pagas_dia', lim, 'revanche_restantes', greatest(0, lim - usadas),
                              'premio', jsonb_build_object('moedas', moedas));
  end if;

  insert into rpg_insignias(user_id, regiao) values (_uid, _regiao) on conflict do nothing;
  perform public.rpg_premiar(_uid, (pr->>'moedas')::int, pr->'itens');
  if (pr->>'doces')::int > 0 then
    insert into equip_doces(user_id, qty) values (_uid, (pr->>'doces')::int) on conflict (user_id) do update set qty = equip_doces.qty + (pr->>'doces')::int;
  end if;
  for k in 1 .. coalesce((pr->>'tm')::int, 0) loop
    select id into tm from pk_items where kind = 'tm' and coalesce(price, 0) > 0 order by random() limit 1;
    if tm is not null then insert into bag_items(user_id, item, qty) values (_uid, tm, 1) on conflict (user_id, item) do update set qty = bag_items.qty + 1; end if;
  end loop;
  drop_ := public.equip_drop(_uid, 'ginasio');
  insert into event_log(user_id, kind, message) values (_uid, 'ginasio', '🏅 ' || nome || ' venceu ' || _lider || ' e ganhou a insígnia do Ginásio!');
  select count(*) into n from rpg_insignias where user_id = _uid;
  if n >= (select count(*) from rpg_lideres) then
    perform public.rpg_premiar(_uid, (c->'ginasios'->>'todas_moedas')::int, c->'ginasios'->'todas_itens');
    insert into event_log(user_id, kind, message) values (_uid, 'ginasio', '👑 ' || nome || ' juntou TODAS as insígnias da Aventura!');
  end if;
  return coalesce(drop_, '{}'::jsonb) || jsonb_build_object('premio', pr || jsonb_build_object('tm_item', tm));
end $$;

create or replace function public.rpg_ginasio(_regiao text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.rpg_cfg()->'ginasios'; l rpg_lideres; n int; bat battles;
  lim int := greatest(0, coalesce((c->>'revanche_pagas_dia')::int, 3)); usadas int := 0;
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  select * into l from rpg_lideres where regiao = _regiao;
  if l.regiao is null then raise exception 'Não há Ginásio aqui.'; end if;
  perform public.treino_autocura(uid);
  update rpg_gin_tent set status = 'perdeu' where user_id = uid and status = 'andando' and dia < public.game_today();
  select * into bat from battles where mode = 'treino' and p1 = uid and status = 'ativa' and state->'treino' ? 'multi' order by created_at desc limit 1;
  select count(*) into n from rpg_gin_tent where user_id = uid and regiao = _regiao and dia = public.game_today()
     and not (status = 'andando' and batalha is null);
  select coalesce((select pagas from rpg_gin_revanches where user_id = uid and dia = public.game_today()), 0) into usadas;
  return jsonb_build_object('lider', jsonb_build_object('nome', l.nome, 'classe', l.classe, 'tipo', l.tipo, 'n', jsonb_array_length(l.time)),
    'insignia', exists (select 1 from rpg_insignias where user_id = uid and regiao = _regiao),
    'tentativas', n, 'tentativas_dia', (c->>'tentativas_dia')::int,
    'moedas', (public.rpg_gin_premio(_regiao)->>'moedas')::int, 'itens', public.rpg_gin_premio(_regiao)->'itens',
    'premio', public.rpg_gin_premio(_regiao), 'revanche', coalesce((c->>'revanche_on')::boolean, true),
    'revanche_pagas_dia', lim, 'revanche_pagas_hoje', usadas, 'revanche_restantes', greatest(0, lim - usadas),
    'itens_batalha', coalesce((public.items_cfg()->>'per_battle')::int, 2), 'expira_min', coalesce((c->>'expira_min')::int, 30),
    'batalha', case when bat.id is null then null else jsonb_build_object('id', bat.id, 'regiao', bat.state->'treino'->>'gym',
      'fim', bat.started_at + make_interval(mins => coalesce((c->>'expira_min')::int, 30))) end,
    'tentativa', null);
end $$;


-- ============================================================================
-- 7. RESULTADO DO ÚLTIMO QUIZ ENCERRADO SEMPRE VISÍVEL
-- ============================================================================

create or replace function public.quiz_resultado_json(_q public.quizzes) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare res jsonb; wname text;
begin
  if _q.id is null then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object('user_id', r.user_id, 'name', r.name, 'guess', r.guess, 'diff', r.diff, 'tempo', r.tempo)
                            order by r.diff, r.tempo, r.answered_at), '[]'::jsonb)
    into res
    from (select x.user_id, ch.name, x.guess, abs(x.guess - _q.answer) diff, x.answered_at,
                 round(extract(epoch from x.answered_at - x.revealed_at)::numeric, 1) tempo
            from quiz_entries x join characters ch on ch.user_id = x.user_id
           where x.quiz_id = _q.id and x.guess is not null) r;
  select name into wname from characters where user_id = _q.winner;
  return jsonb_build_object(
    'id', _q.id, 'title', _q.title, 'intro', _q.intro, 'prize', _q.prize, 'seconds', _q.seconds,
    'status', 'encerrado', 'closes_at', _q.closes_at, 'closed_at', _q.closed_at,
    'question', _q.question, 'answer', _q.answer,
    'winner', _q.winner, 'winner_name', wname, 'results', res
  );
end $$;

create or replace function public.quiz_current() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); q quizzes; ult quizzes; e quiz_entries; total int; done int; res jsonb; left_s numeric; ult_json jsonb;
begin
  perform public.quiz_auto_tick();
  select * into q from quizzes where status = 'aberto' order by id desc limit 1;
  if q.id is not null then perform public.quiz_tick(q.id); select * into q from quizzes where id = q.id; end if;

  select * into ult from quizzes where status = 'encerrado' order by closed_at desc nulls last, id desc limit 1;
  ult_json := public.quiz_resultado_json(ult);

  if q.id is null or q.status <> 'aberto' then
    q := ult;
  end if;
  if q.id is null then return null; end if;

  select * into e from quiz_entries where quiz_id = q.id and user_id = uid;
  select count(*) into total from public.day_active(public.game_today()) a where not public.has_role(a.user_id, 'admin');
  select count(*) into done from quiz_entries x where x.quiz_id = q.id and x.answered_at is not null and not public.has_role(x.user_id, 'admin');
  left_s := case when e.revealed_at is not null and e.answered_at is null
                 then greatest(0, extract(epoch from (e.revealed_at + make_interval(secs => q.seconds) - now()))) end;
  if q.status = 'encerrado' then
    res := ult_json->'results';
  end if;
  return jsonb_build_object(
    'id', q.id, 'title', q.title, 'intro', q.intro, 'prize', q.prize, 'seconds', q.seconds,
    'status', q.status, 'closes_at', q.closes_at, 'closed_at', q.closed_at,
    'answered', done, 'total', total,
    'me', case when e.user_id is null then 'novo' when e.answered_at is not null then 'respondeu'
               when left_s > 0 then 'respondendo' else 'perdeu' end,
    'my_guess', e.guess, 'left', left_s,
    'question', case when q.status = 'encerrado' or e.user_id is not null then q.question end,
    'answer', case when q.status = 'encerrado' then q.answer end,
    'winner', q.winner, 'winner_name', case when q.status = 'encerrado' then ult_json->>'winner_name' end,
    'results', res, 'ultimo', ult_json);
end $$;


-- ============================================================================
-- 8. LAMA NA VILA: SAI SOZINHA EM 72H (CONTINUA PODENDO LIMPAR ANTES PAGANDO)
-- ============================================================================

alter table public.villages add column if not exists mud_at timestamptz;
update public.villages set mud_at = now() where mud > 0 and mud_at is null;

update public.game_config
   set config = config || jsonb_build_object('mud_auto_hours', coalesce((config->>'mud_auto_hours')::int, 72))
 where active;

create or replace function public.vl_autolama(_uid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v villages; h int := coalesce((public.cfg()->>'mud_auto_hours')::int, 72);
begin
  if _uid is null or h <= 0 then return; end if;
  select * into v from villages where user_id = _uid;
  if v.user_id is null or v.mud <= 0 then return; end if;
  if v.mud_at is null then
    update villages set mud_at = now() where user_id = _uid and mud > 0 and mud_at is null;
  elsif v.mud_at <= now() - make_interval(hours => h) then
    update villages set mud = 0, mud_at = null where user_id = _uid;
  end if;
end $$;

create or replace function public.vl_autofix(_uid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v villages; k text;
begin
  perform public.vl_autolama(_uid);
  select * into v from villages where user_id = _uid;
  if v.user_id is null then return; end if;
  for k in select key from jsonb_each(v.damaged) where (value->>'fix')::timestamptz <= now() loop
    perform public.vl_unbreak(_uid, k);
  end loop;
end $$;

create or replace function public.village_clean() returns integer
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); v villages; cost int; me characters;
begin
  perform public.vl_autolama(uid);
  select * into v from villages where user_id = uid for update;
  if v.user_id is null or v.mud = 0 then raise exception 'Sua vila já está limpa.'; end if;
  cost := ceil(v.mud * (public.cfg()->>'mud_clean_per_level')::int * (100 - least(100, public.vb(uid, 'muralha', 'lama_desc_pct'))) / 100)::int;
  select * into me from characters where user_id = uid for update;
  if me.coins < cost then raise exception 'A limpeza custa % moedas.', cost; end if;
  update characters set coins = coins - cost where id = me.id;
  update villages set mud = 0, mud_at = null where user_id = uid;
  return cost;
end $$;

create or replace function public.catapult_fire(_target uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); t date := public.game_today(); v villages; me characters; tg characters;
begin
  select * into v from villages where user_id = uid for update;
  if v.user_id is null or v.catapult_level = 0 then raise exception 'Construa a Catapulta de Lama primeiro.'; end if;
  if v.catapult_used_at is not null and v.catapult_used_at > t - (c->>'catapult_days')::int then
    raise exception 'A catapulta está recarregando. Pronta em %.', to_char(v.catapult_used_at + (c->>'catapult_days')::int, 'DD/MM');
  end if;
  if _target = uid then raise exception 'Mire em outro jogador.'; end if;
  select * into me from characters where user_id = uid;
  select * into tg from characters where user_id = _target for update;
  if tg.id is null then raise exception 'Jogador não encontrado.'; end if;
  update villages set catapult_used_at = t where user_id = uid;
  insert into villages(user_id) values (_target) on conflict do nothing;
  perform public.vl_autolama(_target);
  if exists (select 1 from villages w where w.user_id = _target and w.wall_level > 0
             and (w.wall_used_at is null or w.wall_used_at <= t - (c->>'wall_days')::int)) then
    update villages set wall_used_at = t where user_id = _target;
    insert into event_log(user_id, kind, message) values (uid, 'catapulta', me.name || ' atirou lama em ' || tg.name || ', mas a Muralha segurou tudo!');
    return;
  end if;
  update characters set pending_mud = least(6, pending_mud + (c->>'catapult_push')::int) where id = tg.id;
  update villages set mud = least(3, mud + 1), mud_at = now() where user_id = _target;
  insert into event_log(user_id, kind, message) values (uid, 'catapulta',
    me.name || ' atirou lama na vila de ' || tg.name || '! ' || tg.name || ' vai perder ' || (c->>'catapult_push') || ' casas na próxima andada.');
end $$;

create or replace function public.village_state(_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); t date := public.game_today(); who uuid; v villages; ch characters; rep jsonb := '{}'::jsonb; k text;
begin
  perform public.rocket_vila_tick();
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
    'mud_free_at', case when v.mud > 0 and v.mud_at is not null then v.mud_at + make_interval(hours => coalesce((c->>'mud_auto_hours')::int, 72)) end,
    'repair_costs', rep, 'atk_tactic', case when who = uid then v.atk_tactic end, 'def_tactic', case when who = uid then v.def_tactic end);
end $$;

create or replace function public.war_state() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); w jsonb := public.war_cfg(); v villages; t date := public.game_today(); tz text := coalesce(public.cfg()->>'timezone', 'America/Sao_Paulo');
begin
  perform public.rocket_vila_tick();
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

create or replace function public.settle() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare d date := game_today(); c jsonb := cfg(); r record; x record; pos int; bs int; bc int; s seasons; names text := ''; lastu uuid; firstu uuid;
begin
  if public.jogo_pausado() then return; end if;
  perform pg_advisory_xact_lock(151151);
  for r in select distinct puzzle_date as pd from guess_sessions
           where puzzle_date < d and not recovered and puzzle_date not in (select rd.d from round_days rd) order by 1 loop
    insert into round_days(d) values (r.pd);
    pos := 0; names := ''; lastu := null; firstu := null;
    for x in
      select p.user_id,
             sum(public.rank_attempts(coalesce(gs.attempts,0), coalesce(gs.solved,false), coalesce(gs.hints_used,0), coalesce(gs.retries_used,0)))::int as total,
             count(*) filter (where gs.solved)::int as solved,
             max(gs.finished_at) as fin
      from (select distinct user_id from guess_sessions where puzzle_date = r.pd and not recovered) p
      join characters ch on ch.user_id = p.user_id
      cross join (select mode from daily_puzzles where puzzle_date = r.pd) m
      left join guess_sessions gs on gs.user_id = p.user_id and gs.puzzle_date = r.pd and gs.mode = m.mode
      group by p.user_id
      order by 2 asc, 4 asc nulls last
    loop
      pos := pos + 1;
      bs := coalesce((c->'round_bonus_steps'->>(pos-1))::int, 0);
      bc := coalesce((c->'round_bonus_coins'->>(pos-1))::int, 0);
      insert into round_results(d, user_id, rank, attempts, modes_solved, bonus_steps, bonus_coins)
      values (r.pd, x.user_id, pos, x.total, x.solved, bs, bc);
      if bs > 0 or bc > 0 then update characters set bonus_steps = bonus_steps + bs, coins = coins + bc where user_id = x.user_id; end if;
      if pos = 1 then names := (select name from characters where user_id = x.user_id) || ' venceu a rodada de ' || to_char(r.pd, 'DD/MM') || ' com ' || x.total || ' tentativas'; firstu := x.user_id; end if;
      lastu := x.user_id;
    end loop;
    if firstu is not null then
      insert into villages(user_id) values (firstu) on conflict do nothing;
      update villages set statues = statues + 1 where user_id = firstu;
    end if;
    if pos >= 2 and lastu is not null then
      insert into villages(user_id) values (lastu) on conflict do nothing;
      update villages set mud = 3, mud_at = now() where user_id = lastu;
    end if;
    if names <> '' then insert into event_log(kind, message) values ('rodada', names || '.'); end if;
  end loop;
  perform public.settle_bets();
  perform public.expire_duels();
  perform public.boss_tick();
  perform public.team_week_tick();
  perform public.league_tick();
  perform public.rocket_tick();
  perform public.rocket_vila_tick();
  perform public.hunt_tick();
  select * into s from seasons order by id desc limit 1;
  if s.status = 'encerrada' and s.ended_on < d then perform public.start_new_season(); end if;
end $$;


-- ============================================================================
-- ADMIN, PERMISSÕES E PUBLICAÇÃO AUTOMÁTICA NO JORNAL
-- ============================================================================

create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object(
    'treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'rocket_vila', public.rocket_vila_cfg(),
    'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'leilao', public.leilao_cfg(),
    'herois', public.herois_cfg(), 'temporada', public.temporada_cfg(), 'liga', public.liga_cfg(),
    'pausa', public.pausa_cfg(), 'teto', public.teto_cfg(), 'boas_vindas', public.boas_vindas_cfg(),
    'vila_bonus', public.vila_bonus_cfg(), 'tm_nivel', public.tm_nivel_cfg(), 'quiz_auto', public.quiz_auto_cfg(),
    'cartas', public.tcg_cfg(), 'pokebound', public.pokebound_cfg(), 'visual', public.visual_cfg(),
    'praca', public.praca_cfg(), 'rpg', public.rpg_cfg(), 'equip', public.equip_cfg(), 'base', public.cfg(),
    'exp', public.exp_cfg(), 'vale', public.vale_cfg(), 'fazenda', public.fazenda_cfg(), 'ia', public.ia_cfg(),
    'troca', public.troca_cfg(), 'guerra', public.guerra_cfg(), 'rocket_bases', public.rocket_bases_cfg(),
    'extrato', public.extrato_cfg()
  );
end $$;

grant execute on function public.mon_troca_vitrine(uuid, boolean) to authenticated;
grant execute on function public.troca_propor(uuid, uuid, uuid, integer) to authenticated;
grant execute on function public.troca_escolher(bigint, uuid, integer) to authenticated;
grant execute on function public.troca_responder(bigint, boolean) to authenticated;
grant execute on function public.troca_cancelar(bigint) to authenticated;
grant execute on function public.troca_minhas() to authenticated;
grant execute on function public.troca_colecao(uuid) to authenticated;
grant execute on function public.rocket_vila_estado(uuid) to authenticated;
grant execute on function public.rocket_vila_emprestar(bigint, uuid) to authenticated;
grant execute on function public.rocket_vila_retirar(bigint) to authenticated;
grant execute on function public.rocket_vila_log(bigint) to authenticated;

revoke execute on function public.war_mon_afeta(jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.war_troca_util(jsonb, integer) from public, anon, authenticated;
revoke execute on function public.war_lado_pode_dano(jsonb, integer) from public, anon, authenticated;
revoke execute on function public.war_rodar_luta(uuid, uuid, uuid, text, text, boolean, boolean, integer) from public, anon, authenticated;
revoke execute on function public.troca_devolver(public.trocas) from public, anon, authenticated;
revoke execute on function public.troca_passa(uuid, uuid, uuid) from public, anon, authenticated;
revoke execute on function public.troca_evolui(uuid) from public, anon, authenticated;
revoke execute on function public.rocket_especie_linha(integer, integer) from public, anon, authenticated;
revoke execute on function public.rocket_especies_nivel(integer) from public, anon, authenticated;
revoke execute on function public.rocket_moves(integer, integer) from public, anon, authenticated;
revoke execute on function public.rocket_mon(integer, integer) from public, anon, authenticated;
revoke execute on function public.rocket_melhor_eff(jsonb, text, text) from public, anon, authenticated;
revoke execute on function public.rocket_resgate_roubo(uuid, text, uuid, text) from public, anon, authenticated;
revoke execute on function public.rocket_resgate_criar(bigint, public.rocket_entries) from public, anon, authenticated;
revoke execute on function public.rocket_tira_mon(uuid) from public, anon, authenticated;
revoke execute on function public.rocket_vila_cfg() from public, anon, authenticated;
revoke execute on function public.rocket_vila_mon_preso(uuid) from public, anon, authenticated;
revoke execute on function public.rocket_vila_montar_time(integer, integer) from public, anon, authenticated;
revoke execute on function public.rocket_vila_sortear(uuid, date) from public, anon, authenticated;
revoke execute on function public.rocket_vila_resolver(bigint) from public, anon, authenticated;
revoke execute on function public.rocket_vila_dias_semana(date) from public, anon, authenticated;
revoke execute on function public.rocket_vila_tick() from public, anon, authenticated;
revoke execute on function public.rpg_gin_vitoria(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.quiz_resultado_json(public.quizzes) from public, anon, authenticated;
revoke execute on function public.vl_autolama(uuid) from public, anon, authenticated;

insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🚀 Pacote de novidades: Trocas com vitrine, Rocket reforçada, Ataques às vilas e mais!',
'Várias melhorias e regras novas acabam de entrar no jogo:
• Guerra sem travamento: os Pokémon agora nunca insistem em golpe que não afeta o alvo, trocam sozinhos se precisarem acertar o adversário e, em caso de impasse ou após 50 turnos, vence o esquadrão com maior % de vida somada.
• Troca de Pokémon com vitrine: marque na sua coleção quais Pokémon você aceita trocar. Os outros jogadores só veem a sua vitrine (nunca a coleção inteira), quem recebe a proposta escolhe qual Pokémon dar em troca e a troca só fecha com a aprovação dos dois lados!
• Invasão da Equipe Rocket reforçada: barra calculada pelo histórico das invasões em ondas e pelos jogadores ativos, 15 linhas de Pokémon da Rocket respeitando o nível de evolução, golpes de cobertura e ondas com vantagem de tipo. Atenção: se a turma for derrotada, quem está ativo e não participou também entra no sorteio de perder um Pokémon da equipe!
• Ataque surpresa da Rocket às vilas: 2 vezes por semana (fora dos dias de invasão), a Rocket avisa uma vila com 24h de antecedência. Até 2 amigos podem emprestar 1 Pokémon cada (limitado ao nível do Pokémon mais forte do dono) para ajudar na defesa e ganhar moedas e XP!
• Revanches de ginásio: as 3 primeiras revanches vencidas do dia (somando todos os ginásios) pagam moedas; as seguintes rendem XP.
• Descrição real dos golpes, último Quiz sempre visível e lama de 72h: veja o efeito real de cada golpe na ficha, nas TMs e na batalha; confira a qualquer momento o resultado do último Quiz encerrado; e a lama na vila agora seca sozinha após 72 horas (ou pode ser limpa antes pagando).')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
