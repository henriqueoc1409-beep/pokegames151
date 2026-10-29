-- =====================================================================
-- POKEGAMES — Grama de Treino com espera, Pokémon fortes e Centro Pokémon
-- (pedido do dono em 29/10/2026).
--
-- 1) Espera de verdade: depois de cada luta, a próxima só libera 5 minutos
--    depois. Cada luta gasta 5 dos 60 minutos do dia (12 lutas por dia).
-- 2) Pokémon forte por sorte: em 10% das lutas aparece um selvagem de 3 a 6
--    níveis ACIMA do seu. Vencendo, a experiência vale 1,5 vez mais.
-- 3) Vida do treino: o Pokémon sai da luta com a vida que sobrou e entra na
--    próxima assim. Com a vida zerada, ele desmaia e não treina até ser
--    curado. A vida do treino só vale na Grama de Treino (as outras
--    batalhas continuam começando com a vida cheia).
-- 4) Centro Pokémon: cura na hora pagando moedas, pela mesma conta da cura
--    da guerra: nível × vida que falta × 1,5 (desmaiado custa o dobro).
--    Ou de graça: 72 horas depois do último ferimento ele volta inteiro.
-- 5) Avisos no Jornal: este arquivo já publica sozinho as novidades do 53,
--    do 54 e do 55 (pedido do dono), se ainda não estiverem lá.
-- Números em game_config.config.treino (treino_cfg). Depende do 54.
-- Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

alter table public.monsters add column if not exists tr_hp int not null default 100;   -- vida do treino, em %
alter table public.monsters add column if not exists tr_hurt_at timestamptz;          -- último ferimento no treino

create or replace function public.treino_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "minutos_dia": 60, "minutos_luta": 5, "espera_min": 5, "xp_mult": 1, "nivel_menos": 3, "nivel_mais": 0,
           "forte_pct": 10, "forte_min": 3, "forte_max": 6, "forte_xp_mult": 1.5, "turnos": 30, "lutas_guardadas": 10,
           "centro_coef": 1.5, "centro_desmaiado": 2, "gratis_horas": 72}'::jsonb
         || coalesce(public.cfg()->'treino', '{}'::jsonb)
$$;

-- quem foi ferido há mais de 72 horas volta inteiro, de graça
create or replace function public.treino_autocura(_uid uuid) returns void
language sql security definer set search_path = public, extensions as $$
  update monsters set tr_hp = 100, tr_hurt_at = null
   where user_id = _uid and tr_hp < 100
     and coalesce(tr_hurt_at, '-infinity'::timestamptz) <= now() - make_interval(hours => (public.treino_cfg()->>'gratis_horas')::int)
$$;

-- preço da cura no Centro Pokémon
create or replace function public.centro_preco(_level int, _hp int) returns int
language sql stable security definer set search_path = public, extensions as $$
  select case when _hp >= 100 then 0
    else greatest(1, ceil(_level * (100 - _hp) / 100.0 * (public.treino_cfg()->>'centro_coef')::numeric))::int
         * case when _hp <= 0 then (public.treino_cfg()->>'centro_desmaiado')::int else 1 end end
$$;

-- estado do treino de hoje (para o site): agora com a espera, os feridos e os preços do Centro
create or replace function public.treino_estado() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.treino_cfg(); d treino_dias; ult timestamptz;
begin
  if uid is null then raise exception 'Entre na sua conta.'; end if;
  perform public.treino_autocura(uid);
  select * into d from treino_dias where user_id = uid and dia = public.game_today();
  select max(created_at) into ult from treino_lutas where user_id = uid;
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'minutos_dia', (c->>'minutos_dia')::int, 'minutos_luta', (c->>'minutos_luta')::int,
    'espera_min', (c->>'espera_min')::int, 'nivel_menos', (c->>'nivel_menos')::int, 'nivel_mais', (c->>'nivel_mais')::int,
    'gratis_horas', (c->>'gratis_horas')::int, 'agora', now(),
    'proxima', case when ult is null then null else ult + make_interval(mins => (c->>'espera_min')::int) end,
    'minutos', coalesce(d.minutos, 0), 'lutas', coalesce(d.lutas, 0), 'vitorias', coalesce(d.vitorias, 0), 'xp', coalesce(d.xp, 0),
    'feridos', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'tr_hp', m.tr_hp, 'preco', public.centro_preco(m.level, m.tr_hp),
        'gratis_em', coalesce(m.tr_hurt_at, now()) + make_interval(hours => (c->>'gratis_horas')::int)) order by m.tr_hp, m.level desc)
      from monsters m where m.user_id = uid and m.tr_hp < 100), '[]'::jsonb),
    'ultimas', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'mon_id', l.mon_id, 'species', l.species, 'wild', l.wild, 'wild_level', l.wild_level,
        'won', l.won, 'xp', l.xp, 'level_from', l.level_from, 'level_to', l.level_to, 'created_at', l.created_at) order by l.id desc)
      from treino_lutas l where l.user_id = uid), '[]'::jsonb));
end $$;

-- uma luta de treino (versão do 54 + espera, Pokémon forte e vida que fica)
create or replace function public.treino_lutar(_mon uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.treino_cfg(); me characters; m monsters; d treino_dias;
  per int := (c->>'minutos_luta')::int; lvl int; sp int; wild jsonb; s0 jsonb; s1 jsonb; b battles; it int := 0; side int; p jsonb;
  won boolean; ganho int := 0; pct0 numeric; pct1 numeric; lv2 int; lid bigint; ult timestamptz; wait_s int; forte boolean; hp0 int; mine jsonb; hp_fim int;
begin
  if not coalesce((c->>'on')::boolean, true) then raise exception 'A Grama de Treino está fechada no momento.'; end if;
  select * into me from characters where user_id = uid for update;   -- uma luta por vez
  perform public.treino_autocura(uid);
  select * into m from monsters where id = _mon and user_id = uid;
  if m.id is null then raise exception 'Escolha um Pokémon seu para treinar.'; end if;
  if m.level >= 100 then raise exception 'Esse Pokémon já está no nível máximo.'; end if;
  if m.tr_hp <= 0 then
    raise exception '% está desmaiado. Leve ao Centro Pokémon ou espere: ele se recupera de graça % horas depois de desmaiar.', (select name from pokemon where id = m.species_id), c->>'gratis_horas';
  end if;
  select max(created_at) into ult from treino_lutas where user_id = uid;
  if ult is not null and now() < ult + make_interval(mins => (c->>'espera_min')::int) then
    wait_s := ceil(extract(epoch from (ult + make_interval(mins => (c->>'espera_min')::int) - now())))::int;
    raise exception 'Seus Pokémon ainda estão descansando da última luta. Próxima luta em % min e % s.', wait_s / 60, wait_s % 60;
  end if;
  insert into treino_dias(user_id, dia) values (uid, public.game_today()) on conflict do nothing;
  select * into d from treino_dias where user_id = uid and dia = public.game_today();
  if d.minutos + per > (c->>'minutos_dia')::int then
    raise exception 'Seu tempo de treino de hoje acabou (% minutos). Volte amanhã!', c->>'minutos_dia';
  end if;

  -- o selvagem: quase sempre do nível do seu Pokémon ou abaixo; às vezes (sorte) um forte, acima
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
  hp0 := greatest(1, round((mine->>'maxhp')::int * m.tr_hp / 100.0))::int;   -- entra com a vida que sobrou do treino
  mine := jsonb_set(mine, '{hp}', to_jsonb(hp0));
  s0 := jsonb_build_object('user', uid, 'name', me.name, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(mine));
  s1 := jsonb_build_object('user', uid, 'name', 'Pokémon selvagem', 'npc', true, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(wild));

  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (uid, uid, 'treino', 1, 'ativa', 1, 'normal', now(), jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', case when forte then '⚡ Que sorte (ou azar)! Um ' || (wild->>'name') || ' FORTE (nível ' || lvl || ') saiu da grama!'
                                      else 'Um ' || (wild->>'name') || ' selvagem (nível ' || lvl || ') apareceu na grama!' end),
            jsonb_build_object('txt', me.name || ' mandou ' || (s0->'mons'->0->>'name') || case when m.tr_hp < 100 then ' (com ' || m.tr_hp || '% da vida)' else '' end || '!')))))
  returning * into b;
  loop
    select * into b from battles where id = b.id;
    exit when b.status <> 'ativa' or b.turn > (c->>'turnos')::int;
    it := it + 1; exit when it > 200;
    for side in 0 .. 1 loop
      if b.phase = 'troca' then
        if coalesce((b.state->'sides'->side->>'need_switch')::boolean, false) then
          insert into battle_actions(battle_id, turn, side, user_id, kind, value)
          values (b.id, b.turn, side, uid, 'switch', public.war_switch(b.state, side, true));
        end if;
      else
        p := public.war_pick(b.state, side, 'forte');
        insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, side, uid, p->>'kind', (p->>'value')::int);
      end if;
    end loop;
    perform public.bt_resolve(b.id);
  end loop;
  select * into b from battles where id = b.id;
  if b.status = 'ativa' then   -- muitos turnos: vence quem tem mais vida (em %)
    pct0 := (b.state->'sides'->0->'mons'->0->>'hp')::numeric / greatest(1, (b.state->'sides'->0->'mons'->0->>'maxhp')::int);
    pct1 := (b.state->'sides'->1->'mons'->0->>'hp')::numeric / greatest(1, (b.state->'sides'->1->'mons'->0->>'maxhp')::int);
    won := pct0 > pct1;
    perform public.bt_finish(b.id, case when won then uid end, 'limite');
    select * into b from battles where id = b.id;
    b.log := b.log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt',
      'A luta demorou demais. ' || case when won then 'O selvagem cansou e fugiu: vitória sua!' else 'Seu Pokémon cansou e o selvagem fugiu.' end))));
  else
    won := (b.state->'sides'->0->'mons'->0->>'hp')::int > 0 and (b.state->'sides'->1->'mons'->0->>'hp')::int <= 0;
  end if;
  -- a vida que sobrou fica para a próxima luta
  hp_fim := greatest(0, least(100, floor((b.state->'sides'->0->'mons'->0->>'hp')::numeric * 100 / greatest(1, (b.state->'sides'->0->'mons'->0->>'maxhp')::int))))::int;
  if (b.state->'sides'->0->'mons'->0->>'hp')::int > 0 then hp_fim := greatest(1, hp_fim); end if;
  update monsters set tr_hp = hp_fim, tr_hurt_at = case when hp_fim < m.tr_hp then now() else tr_hurt_at end where id = m.id;
  if hp_fim = 0 then
    b.log := b.log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt',
      (s0->'mons'->0->>'name') || ' desmaiou! Leve ao Centro Pokémon ou espere ' || (c->>'gratis_horas') || ' horas para ele se recuperar de graça.'))));
  end if;
  if won then
    ganho := greatest(1, floor((wild->>'bexp')::int * lvl / 7.0 * (c->>'xp_mult')::numeric * case when forte then (c->>'forte_xp_mult')::numeric else 1 end)::int);
    perform public.pk_give_xp(m.id, ganho, 'treino');
  end if;
  select level into lv2 from monsters where id = m.id;
  update treino_dias set minutos = minutos + per, lutas = lutas + 1, vitorias = vitorias + won::int, xp = treino_dias.xp + ganho
   where user_id = uid and dia = d.dia;
  insert into treino_lutas(user_id, mon_id, species, wild, wild_level, won, xp, level_from, level_to, log)
  values (uid, m.id, m.species_id, sp, lvl, won, ganho, m.level, lv2, b.log) returning id into lid;
  delete from treino_lutas where user_id = uid and id not in (select id from treino_lutas where user_id = uid order by id desc limit (c->>'lutas_guardadas')::int);
  delete from battles where id = b.id;
  return jsonb_build_object('id', lid, 'won', won, 'xp', ganho, 'wild', sp, 'wild_level', lvl, 'forte', forte, 'level_from', m.level, 'level_to', lv2, 'log', b.log,
    'hp_antes', m.tr_hp, 'hp', hp_fim, 'desmaiou', hp_fim = 0,
    'minutos', d.minutos + per, 'minutos_dia', (c->>'minutos_dia')::int,
    'proxima', now() + make_interval(mins => (c->>'espera_min')::int),
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.id) from mon_events e where e.user_id = uid and not e.seen), '[]'::jsonb));
end $$;

-- Centro Pokémon: cura na hora pagando moedas (_ids vazio = todos os feridos)
create or replace function public.centro_curar(_ids uuid[] default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters; cost int; n int;
begin
  select * into me from characters where user_id = uid for update;
  perform public.treino_autocura(uid);
  select coalesce(sum(public.centro_preco(level, tr_hp)), 0), count(*) into cost, n
    from monsters where user_id = uid and tr_hp < 100 and (_ids is null or id = any(_ids));
  if n = 0 then raise exception 'Nenhum Pokémon precisa de cura.'; end if;
  if me.coins < cost then raise exception 'A cura custa % moedas e você tem %. Se preferir, espere: eles se recuperam de graça % horas depois do último ferimento.', cost, me.coins, public.treino_cfg()->>'gratis_horas'; end if;
  update characters set coins = coins - cost where id = me.id;
  update monsters set tr_hp = 100, tr_hurt_at = null where user_id = uid and tr_hp < 100 and (_ids is null or id = any(_ids));
  return jsonb_build_object('cost', cost, 'curados', n, 'coins', me.coins - cost);
end $$;

-- ---------- permissões ----------
revoke execute on function public.treino_cfg(), public.treino_autocura(uuid), public.centro_preco(int, int) from public, anon, authenticated;
revoke execute on function public.treino_estado(), public.treino_lutar(uuid), public.centro_curar(uuid[]) from public, anon;
grant execute on function public.treino_estado(), public.treino_lutar(uuid), public.centro_curar(uuid[]) to authenticated;

-- ---------- novidades no Jornal, publicadas sozinhas (pedido do dono em 29/10/2026) ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values
    (1, '🌱 Pokémon selvagens agora aparecem fracos', 'Os Pokémon que aparecem depois de andar agora vêm sempre entre os níveis 1 e 5, em qualquer parte do tabuleiro.
• A chance de captura continua a mesma: os raros seguem difíceis.
• Quer um time forte? Treine os seus Pokémon!
Os Pokémon que você já tem não mudam.'),
    (2, '🌿 Nova: Grama de Treino', 'Agora dá para treinar os seus Pokémon na Grama de Treino, no menu Pokémon!
• Escolha um Pokémon e ele luta sozinho contra Pokémon selvagens do nível dele.
• Venceu? Ganha experiência. Perdeu? Não ganha nada.
• Todo dia você tem 60 minutos de treino. Cada luta gasta 5 minutos, e depois de cada luta é preciso esperar 5 minutos de verdade para lutar de novo (12 lutas por dia).
O treino é lento: evoluir agora dá trabalho. Volte várias vezes ao dia!'),
    (3, '🏥 Novo: Centro Pokémon e Pokémon fortes na grama', 'Mudanças na Grama de Treino:
• Cada luta agora gasta 5 dos 60 minutos do dia, e depois de cada luta é preciso esperar 5 minutos de verdade para lutar de novo (12 lutas por dia).
E a vida agora conta:
• Seu Pokémon sai de cada luta com a vida que sobrou e entra assim na próxima.
• Se a vida zerar, ele DESMAIA e não pode treinar até se recuperar.
• Para recuperar na hora, leve ao 🏥 Centro Pokémon (menu Pokémon) e pague em moedas. Quanto maior o nível e mais ferido, mais caro; desmaiado custa o dobro.
• Ou espere: 72 horas depois do último ferimento ele volta inteiro, de graça.
⚡ E às vezes, por sorte, sai da grama um Pokémon FORTE, acima do nível do seu. Vencer dá 50% a mais de experiência, mas cuidado: o risco de desmaiar é grande!
A vida do treino só vale na Grama de Treino: nas outras batalhas seus Pokémon continuam começando com a vida cheia.')) x(ord, title, body)
 where not exists (select 1 from public.posts p where p.title = x.title)
 order by x.ord;
