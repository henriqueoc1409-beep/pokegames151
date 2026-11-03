-- =====================================================================
-- POKEGAMES — Acompanhante na Grama de Treino (pedido do dono em 03/11/2026).
--
-- Alguns Pokémon não conseguem vencer na Grama porque não têm ataque de
-- dano (o Magikarp só tem Splash até o nível 15). Agora, ao treinar, o
-- jogador pode escolher um ACOMPANHANTE: outro Pokémon seu que fica na
-- bolsa e ganha metade da experiência de cada vitória (como o Exp. Share).
-- Assim o Magikarp sobe junto com outro Pokémon que luta.
-- A porcentagem fica em Ajustes do jogo (treino.acompanhante_pct, 50).
-- Também: as estátuas de ouro saem do desenho da vila (só no site).
-- treino_encontro é apagada e criada de novo com o argumento _comp.
-- Depende do 56 e do 58. Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

-- configuração do treino (versão do 58 + acompanhante)
create or replace function public.treino_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "minutos_dia": 30, "visita_opcoes": [5, 10], "encontro_seg": 15, "lendario_pct": 1, "lendario_nivel": 70, "acompanhante_pct": 50, "xp_mult": 1, "nivel_menos": 3, "nivel_mais": 0,
           "forte_pct": 10, "forte_min": 3, "forte_max": 6, "forte_xp_mult": 1.5, "turnos": 40, "lutas_guardadas": 10,
           "centro_coef": 1.5, "centro_desmaiado": 2, "gratis_horas": 72}'::jsonb
         || coalesce(public.cfg()->'treino', '{}'::jsonb)
$$;

-- encontro na grama (versão do 58 + acompanhante)
drop function if exists public.treino_encontro(uuid);
create or replace function public.treino_encontro(_mon uuid, _comp uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.treino_cfg(); me characters; m monsters; v treino_visitas; bid uuid;
  lvl int; sp int; wild jsonb; mine jsonb; hp0 int; forte boolean; s0 jsonb; s1 jsonb; leg int; legn text;
begin
  select * into me from characters where user_id = uid for update;
  bid := public.treino_batalha(uid);
  if bid is not null then return jsonb_build_object('battle', bid); end if;   -- termine a luta que já começou
  v := public.treino_visita(uid);
  if v.id is null then raise exception 'Seu tempo na grama acabou. Entre de novo para continuar treinando.'; end if;
  if v.ult_encontro is not null and now() < v.ult_encontro + make_interval(secs => (c->>'encontro_seg')::int) then
    raise exception 'Nenhum Pokémon por aqui… continue andando.';
  end if;
  perform public.treino_autocura(uid);
  select * into m from monsters where id = _mon and user_id = uid;
  if m.id is null then raise exception 'Escolha um Pokémon seu para treinar.'; end if;
  if m.level >= 100 then raise exception 'Esse Pokémon já está no nível máximo.'; end if;
  -- acompanhante (arquivo 63): outro Pokémon seu, fica na bolsa e ganha parte da experiência de cada vitória
  if _comp is not null and (_comp = m.id or not exists (select 1 from monsters where id = _comp and user_id = uid)) then
    raise exception 'Escolha como acompanhante outro Pokémon seu.';
  end if;
  if m.tr_hp <= 0 then
    raise exception '% está desmaiado. Leve ao Centro Pokémon ou escolha outro Pokémon.', (select name from pokemon where id = m.species_id);
  end if;
  delete from battles where mode = 'treino' and p1 = uid and status <> 'ativa';   -- lutas antigas já contadas
  -- lendário (raro): acaba com o seu Pokémon na hora, sem batalha
  if random() * 100 < (c->>'lendario_pct')::numeric then
    select p.id, p.name into leg, legn from pokemon p where p.id in (144, 145, 146, 150, 151, 243, 244, 245, 249, 250, 251) and public.gen_ok(p.id) order by random() limit 1;
    update monsters set tr_hp = 0, tr_hurt_at = now() where id = m.id;
    update treino_visitas set ult_encontro = now() where id = v.id;
    insert into treino_dias(user_id, dia) values (uid, public.game_today()) on conflict do nothing;
    update treino_dias set lutas = lutas + 1 where user_id = uid and dia = public.game_today();
    insert into treino_lutas(user_id, mon_id, species, wild, wild_level, won, xp, level_from, level_to, log)
    values (uid, m.id, m.species_id, leg, (c->>'lendario_nivel')::int, false, 0, m.level, m.level,
            jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
              jsonb_build_object('txt', '⚠️ Um ' || legn || ' LENDÁRIO (nível ' || (c->>'lendario_nivel') || ') saiu da grama!'),
              jsonb_build_object('txt', 'O lendário acabou com você. ' || (select name from pokemon where id = m.species_id) || ' desmaiou na hora.')))));
    delete from treino_lutas where user_id = uid and id not in (select id from treino_lutas where user_id = uid order by id desc limit (c->>'lutas_guardadas')::int);
    return jsonb_build_object('lendario', jsonb_build_object('species', leg, 'name', legn, 'level', (c->>'lendario_nivel')::int,
      'mon', m.id, 'mon_species', m.species_id, 'gratis_horas', (c->>'gratis_horas')::int));
  end if;
  forte := random() * 100 < (c->>'forte_pct')::numeric;
  if forte then
    lvl := least(100, m.level + (c->>'forte_min')::int + floor(random() * ((c->>'forte_max')::int - (c->>'forte_min')::int + 1))::int);
  else
    lvl := greatest(1, least(100, m.level - (c->>'nivel_menos')::int + floor(random() * ((c->>'nivel_menos')::int + (c->>'nivel_mais')::int + 1))::int));
  end if;
  select p.id into sp from pokemon p
   where p.catch_rate > 3 and public.gen_ok(p.id)
     and (p.id = p.base_form or exists (select 1 from pk_evolutions e where e.to_id = p.id and ((e.method = 'nivel' and e.level <= lvl) or (e.method <> 'nivel' and lvl >= 30))))
   order by random() limit 1;
  wild := public.npc_mon(sp, lvl);
  mine := public.bt_mon(m.id);
  hp0 := greatest(1, round((mine->>'maxhp')::int * m.tr_hp / 100.0))::int;
  mine := jsonb_set(mine, '{hp}', to_jsonb(hp0));
  s0 := jsonb_build_object('user', uid, 'name', me.name, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(mine));
  s1 := jsonb_build_object('user', uid, 'name', case when forte then 'Pokémon forte' else 'Pokémon selvagem' end, 'npc', true, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(wild));
  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (uid, uid, 'treino', 1, 'ativa', 1, 'normal', now(),
          jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb, 'treino', jsonb_build_object('mon', m.id, 'forte', forte, 'comp', _comp)),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', case when forte then '⚡ Que sorte (ou azar)! Um ' || (wild->>'name') || ' FORTE (nível ' || lvl || ') saiu da grama!'
                                      else 'Um ' || (wild->>'name') || ' selvagem (nível ' || lvl || ') apareceu na grama!' end),
            jsonb_build_object('txt', 'Vai, ' || (mine->>'name') || '!' || case when m.tr_hp < 100 then ' (com ' || m.tr_hp || '% da vida)' else '' end)))))
  returning id into bid;
  update treino_visitas set ult_encontro = now() where id = v.id;
  return jsonb_build_object('battle', bid);
end $$;

-- fim da luta de treino (versão do 56 + experiência do acompanhante)
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
      perform public.pk_give_xp(m.id, ganho, 'treino');
      -- acompanhante (arquivo 63): ganha uma parte da experiência, como o Exp. Share
      if (t->>'comp') is not null then
        select species_id into csp from monsters where id = (t->>'comp')::uuid and user_id = b.p1;
        if csp is not null then
          cx := greatest(1, floor(ganho * coalesce((c->>'acompanhante_pct')::numeric, 50) / 100))::int;
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

-- ---------- permissões ----------
revoke execute on function public.treino_encontro(uuid, uuid) from public, anon;
grant execute on function public.treino_encontro(uuid, uuid) to authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🎒 Acompanhante na Grama de Treino', 'Tem Pokémon que não consegue vencer sozinho, como o Magikarp, que só sabe Splash? Agora tem jeito!
• Na Grama de Treino, escolha um ACOMPANHANTE: outro Pokémon seu que fica na bolsa.
• A cada vitória do Pokémon que está lutando, o acompanhante ganha metade da experiência.
• Assim dá para subir o Magikarp até ele virar Gyarados!
E mais: as estátuas de ouro saíram do desenho da vila. As vitórias na rodada continuam contadas no painel da vila (🏆).')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
