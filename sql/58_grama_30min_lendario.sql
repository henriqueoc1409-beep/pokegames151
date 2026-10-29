-- =====================================================================
-- POKEGAMES — Grama de Treino: 30 minutos, tempo perdido ao sair e
-- lendário raro (pedido do dono em 29/10/2026).
--
-- 1) O relógio do dia passa de 60 para 30 minutos.
-- 2) Entrou, o tempo conta: saindo antes, o que sobrou da visita é perdido
--    (não volta mais para o relógio). O site avisa antes de sair.
-- 3) Pokémon aparecem um pouco menos: no mínimo 15 segundos entre um
--    encontro e outro (antes 8), e o site sorteia menos na grama alta.
-- 4) Lendário raro: em 1% dos encontros sai um lendário (Articuno, Zapdos,
--    Moltres, Mewtwo, Mew; com a 2ª geração ligada, também Raikou, Entei,
--    Suicune, Lugia, Ho-Oh e Celebi). Não tem batalha: o seu Pokémon
--    desmaia na hora (Centro Pokémon ou 72 h) e aparece a mensagem
--    "O lendário acabou com você." Não dá experiência.
-- treino_encontro passa a devolver {battle} ou {lendario} (por isso é
-- apagada e criada de novo). Números em game_config.config.treino.
-- Depende do 56. Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

-- configuração do treino (versão do 56 + 30 minutos, encontros mais espaçados e lendário)
create or replace function public.treino_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "minutos_dia": 30, "visita_opcoes": [5, 10], "encontro_seg": 15, "lendario_pct": 1, "lendario_nivel": 70, "xp_mult": 1, "nivel_menos": 3, "nivel_mais": 0,
           "forte_pct": 10, "forte_min": 3, "forte_max": 6, "forte_xp_mult": 1.5, "turnos": 40, "lutas_guardadas": 10,
           "centro_coef": 1.5, "centro_desmaiado": 2, "gratis_horas": 72}'::jsonb
         || coalesce(public.cfg()->'treino', '{}'::jsonb)
$$;

-- sair da grama: o tempo que sobrou é perdido
create or replace function public.treino_sair() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); v treino_visitas;
begin
  perform 1 from characters where user_id = uid for update;
  v := public.treino_visita(uid);
  if v.id is not null then
    update treino_visitas set saiu_em = now() where id = v.id;   -- o tempo que sobrou é perdido (decisão do dono)
  end if;
  return public.treino_estado();
end $$;

-- encontro na grama (versão do 56 + lendário raro; agora devolve um objeto)
drop function if exists public.treino_encontro(uuid);
create or replace function public.treino_encontro(_mon uuid) returns jsonb
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
          jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb, 'treino', jsonb_build_object('mon', m.id, 'forte', forte)),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', case when forte then '⚡ Que sorte (ou azar)! Um ' || (wild->>'name') || ' FORTE (nível ' || lvl || ') saiu da grama!'
                                      else 'Um ' || (wild->>'name') || ' selvagem (nível ' || lvl || ') apareceu na grama!' end),
            jsonb_build_object('txt', 'Vai, ' || (mine->>'name') || '!' || case when m.tr_hp < 100 then ' (com ' || m.tr_hp || '% da vida)' else '' end)))))
  returning id into bid;
  update treino_visitas set ult_encontro = now() where id = v.id;
  return jsonb_build_object('battle', bid);
end $$;

-- ---------- permissões ----------
revoke execute on function public.treino_encontro(uuid), public.treino_sair() from public, anon;
grant execute on function public.treino_encontro(uuid), public.treino_sair() to authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🌿 Grama de Treino: 30 minutos, lendários e amigos na grama', 'Mudanças na Grama de Treino:
• Agora são 30 minutos por dia.
• Entrou, o tempo conta: se sair antes, o tempo que sobrou da visita é perdido.
• Os Pokémon aparecem um pouco menos: ande mais pela grama alta.
• ⚠️ Muito raramente aparece um Pokémon LENDÁRIO… e ele acaba com o seu Pokémon na hora (desmaia; Centro Pokémon ou 72 horas).
• Pokémon selvagens passeiam pela grama, só de enfeite.
• Quem está na grama ao mesmo tempo que você aparece andando por lá!')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
