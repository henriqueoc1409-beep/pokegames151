-- =====================================================================
-- POKEGAMES — Grama de Treino para andar (pedido do dono em 29/10/2026).
--
-- A Grama de Treino vira uma área pequena e fechada, fora do tabuleiro
-- (o tabuleiro não muda), onde o jogador anda com o personagem, como na
-- Safari Zone:
-- 1) Visita: ao entrar, o jogador escolhe ficar 5 ou 10 minutos. O tempo
--    sai do relógio de 60 minutos do dia e corre o tempo todo, inclusive
--    nas batalhas. Saindo antes, o tempo que sobrou volta para o relógio.
-- 2) Encontro: andando na grama alta, aparece um Pokémon selvagem. O site
--    pede o encontro; o servidor confere a visita aberta, o intervalo
--    mínimo entre encontros e o Pokémon escolhido, e sorteia o selvagem
--    (como antes: do nível do seu ou abaixo; 10% de chance de um forte).
-- 3) Batalha: o jogador dá todos os comandos (atacar, trocar não existe
--    porque é 1 contra 1, usar item da bolsa, fugir). O selvagem joga
--    sozinho na hora, como a Equipe Rocket. Se o tempo acabar no meio da
--    luta, a luta termina normalmente.
-- 4) Fim da luta: XP como antes (só vencendo; forte vale 1,5×), a vida que
--    sobrou fica para a próxima (Centro Pokémon ou 72 h para curar).
-- Só batalha para treinar: não há captura na grama (decisão do dono).
-- A luta automática do 54/55 (treino_lutar) sai do site.
-- Depende do 54 e do 55. Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

create or replace function public.treino_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "minutos_dia": 60, "visita_opcoes": [5, 10], "encontro_seg": 8, "xp_mult": 1, "nivel_menos": 3, "nivel_mais": 0,
           "forte_pct": 10, "forte_min": 3, "forte_max": 6, "forte_xp_mult": 1.5, "turnos": 40, "lutas_guardadas": 10,
           "centro_coef": 1.5, "centro_desmaiado": 2, "gratis_horas": 72}'::jsonb
         || coalesce(public.cfg()->'treino', '{}'::jsonb)
$$;

-- cada visita à grama
create table if not exists public.treino_visitas (
  id            bigserial primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  dia           date not null,
  inicio        timestamptz not null default now(),
  fim           timestamptz not null,
  minutos       int not null,
  saiu_em       timestamptz,
  ult_encontro  timestamptz
);
create index if not exists treino_visitas_user on public.treino_visitas (user_id, id desc);
alter table public.treino_visitas enable row level security;
drop policy if exists treino_visitas_read on public.treino_visitas;
create policy treino_visitas_read on public.treino_visitas for select to authenticated using (user_id = auth.uid());
grant select on public.treino_visitas to authenticated;

-- visita aberta agora (ou vazio)
create or replace function public.treino_visita(_uid uuid) returns public.treino_visitas
language sql stable security definer set search_path = public, extensions as $$
  select * from treino_visitas where user_id = _uid and saiu_em is null and fim > now() order by id desc limit 1
$$;

-- luta de treino ainda em andamento (ou vazio)
create or replace function public.treino_batalha(_uid uuid) returns uuid
language sql stable security definer set search_path = public, extensions as $$
  select id from battles where mode = 'treino' and p1 = _uid and status = 'ativa' order by created_at desc limit 1
$$;

-- entrar na grama por 5 ou 10 minutos
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
  m := least(_min, (c->>'minutos_dia')::int - d.minutos);
  if m <= 0 then raise exception 'Seu tempo de treino de hoje acabou (% minutos). Volte amanhã!', c->>'minutos_dia'; end if;
  insert into treino_visitas(user_id, dia, fim, minutos) values (uid, d.dia, now() + make_interval(mins => m), m);
  update treino_dias set minutos = minutos + m where user_id = uid and dia = d.dia;
  return public.treino_estado();
end $$;

-- sair da grama antes do tempo: o que sobrou volta para o relógio do dia
create or replace function public.treino_sair() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); v treino_visitas; volta int;
begin
  perform 1 from characters where user_id = uid for update;
  v := public.treino_visita(uid);
  if v.id is not null then
    volta := greatest(0, least(v.minutos, floor(extract(epoch from (v.fim - now())) / 60)::int));
    update treino_visitas set saiu_em = now(), minutos = minutos - volta where id = v.id;
    update treino_dias set minutos = greatest(0, minutos - volta) where user_id = uid and dia = v.dia;
  end if;
  return public.treino_estado();
end $$;

-- fim de uma luta de treino: XP, vida, contagem do dia e relato (uma vez só)
create or replace function public.treino_after(_bid uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.treino_cfg(); b battles; t jsonb; m monsters; won boolean; ganho int := 0; hp_fim int; lv2 int; res jsonb; me0 jsonb; wi jsonb;
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
    end if;
    select level into lv2 from monsters where id = m.id;
  end if;
  insert into treino_dias(user_id, dia) values (b.p1, public.game_today()) on conflict do nothing;
  update treino_dias set lutas = lutas + 1, vitorias = vitorias + won::int, xp = treino_dias.xp + ganho where user_id = b.p1 and dia = public.game_today();
  if hp_fim = 0 then
    b.log := b.log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt',
      (me0->>'name') || ' desmaiou! Leve ao Centro Pokémon ou espere ' || (c->>'gratis_horas') || ' horas para ele se recuperar de graça.'))));
  end if;
  res := jsonb_build_object('won', won, 'xp', ganho, 'forte', (t->>'forte')::boolean, 'wild', (wi->>'species')::int, 'wild_level', (wi->>'level')::int,
    'species', m.species_id, 'level_from', m.level, 'level_to', coalesce(lv2, m.level), 'hp', hp_fim, 'desmaiou', hp_fim = 0,
    'fugiu', b.end_reason = 'desistencia');
  insert into treino_lutas(user_id, mon_id, species, wild, wild_level, won, xp, level_from, level_to, log)
  values (b.p1, m.id, coalesce(m.species_id, (me0->>'species')::int), (wi->>'species')::int, (wi->>'level')::int, won, ganho, coalesce(m.level, 1), coalesce(lv2, m.level, 1), b.log);
  delete from treino_lutas where user_id = b.p1 and id not in (select id from treino_lutas where user_id = b.p1 order by id desc limit (c->>'lutas_guardadas')::int);
  update battles set log = b.log, state = jsonb_set(state, '{treino}', t || jsonb_build_object('feito', true, 'res', res)) where id = b.id;
  return res;
end $$;

-- encontro na grama alta: cria a luta (ou devolve a que já está em andamento)
create or replace function public.treino_encontro(_mon uuid) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.treino_cfg(); me characters; m monsters; v treino_visitas; bid uuid;
  lvl int; sp int; wild jsonb; mine jsonb; hp0 int; forte boolean; s0 jsonb; s1 jsonb;
begin
  select * into me from characters where user_id = uid for update;
  bid := public.treino_batalha(uid);
  if bid is not null then return bid; end if;   -- termine a luta que já começou
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
  return bid;
end $$;

-- estado do treino (para o site): relógio, visita aberta, luta em andamento, feridos e últimas lutas
create or replace function public.treino_estado() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.treino_cfg(); d treino_dias; v treino_visitas;
begin
  if uid is null then raise exception 'Entre na sua conta.'; end if;
  perform public.treino_autocura(uid);
  select * into d from treino_dias where user_id = uid and dia = public.game_today();
  v := public.treino_visita(uid);
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'modo', 'andar', 'minutos_dia', (c->>'minutos_dia')::int,
    'opcoes', c->'visita_opcoes', 'encontro_seg', (c->>'encontro_seg')::int,
    'nivel_menos', (c->>'nivel_menos')::int, 'nivel_mais', (c->>'nivel_mais')::int, 'gratis_horas', (c->>'gratis_horas')::int, 'agora', now(),
    'minutos', coalesce(d.minutos, 0), 'lutas', coalesce(d.lutas, 0), 'vitorias', coalesce(d.vitorias, 0), 'xp', coalesce(d.xp, 0),
    'visita', case when v.id is null then null else jsonb_build_object('id', v.id, 'fim', v.fim, 'minutos', v.minutos, 'inicio', v.inicio) end,
    'batalha', public.treino_batalha(uid),
    'feridos', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'tr_hp', m.tr_hp, 'preco', public.centro_preco(m.level, m.tr_hp),
        'gratis_em', coalesce(m.tr_hurt_at, now()) + make_interval(hours => (c->>'gratis_horas')::int)) order by m.tr_hp, m.level desc)
      from monsters m where m.user_id = uid and m.tr_hp < 100), '[]'::jsonb),
    'ultimas', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'mon_id', l.mon_id, 'species', l.species, 'wild', l.wild, 'wild_level', l.wild_level,
        'won', l.won, 'xp', l.xp, 'level_from', l.level_from, 'level_to', l.level_to, 'created_at', l.created_at) order by l.id desc)
      from treino_lutas l where l.user_id = uid), '[]'::jsonb));
end $$;

-- ação na batalha (versão do 47 + Grama de Treino: o selvagem joga sozinho e o fim conta pelo treino_after)
create or replace function public.battle_act(_id uuid, _turn int, _kind text, _value int, _item text default null) returns public.battles
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); b battles; side int; s jsonb; A jsonb; kind text := _kind; ok boolean; pre int; p jsonb; k int; item text;
begin
  select * into b from battles where id = _id for update;
  if b.id is null or uid not in (b.p1, b.p2) then raise exception 'Batalha não encontrada.'; end if;
  if b.status <> 'ativa' then raise exception 'Essa batalha não está em andamento.'; end if;
  side := case when uid = b.p1 then 0 else 1 end;
  if _kind = 'forfeit' then
    update battles set log = log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt', case when b.mode = 'treino' then 'Você fugiu da luta.' else (b.state->'sides'->side->>'name') || ' desistiu da batalha.' end))))
     where id = b.id;
    perform public.bt_finish(b.id, case when side = 0 then b.p2 else b.p1 end, 'desistencia');
    if b.mode = 'rocket' then perform public.rocket_after(b.id, public.rocket_dmg(b.state)); end if;
    if b.mode = 'treino' then perform public.treino_after(b.id); end if;
    select * into b from battles where id = _id; return b;
  end if;
  if _turn <> b.turn then raise exception 'Esse turno já passou. Atualize a tela.'; end if;
  if (side = 0 and b.ready1) or (side = 1 and b.ready2) then raise exception 'Você já escolheu a ação deste turno. Espere o adversário.'; end if;
  s := b.state; A := s->'sides'->side->'mons'->((s->'sides'->side->>'active')::int);
  if b.phase = 'troca' or coalesce((s->'sides'->side->>'need_switch')::boolean, false) then
    if _kind <> 'switch' then raise exception 'Escolha qual Pokémon vai entrar.'; end if;
  end if;
  if _kind = 'switch' then
    if _value is null or _value < 0 or _value >= jsonb_array_length(s->'sides'->side->'mons') then raise exception 'Pokémon inválido.'; end if;
    if _value = (s->'sides'->side->>'active')::int then raise exception 'Esse Pokémon já está em campo.'; end if;
    if (s->'sides'->side->'mons'->_value->>'hp')::int <= 0 then raise exception 'Esse Pokémon desmaiou.'; end if;
    if (A->>'hp')::int > 0 and b.phase <> 'troca' and (coalesce(A->'fl'->>'charging', '') <> '' or coalesce((A->'fl'->>'recharge')::boolean, false)) then raise exception 'Não dá para trocar agora.'; end if;
  elsif _kind = 'move' then
    if coalesce(A->'fl'->>'charging', '') <> '' or coalesce((A->'fl'->>'recharge')::boolean, false) then kind := 'forced';
    elsif _value = -1 then
      select bool_and((x->>'pp')::int = 0) into ok from jsonb_array_elements(A->'moves') x;
      if not ok then raise exception 'Ainda há ataques com PP.'; end if;
    else
      if _value is null or _value < 0 or _value >= jsonb_array_length(A->'moves') then raise exception 'Ataque inválido.'; end if;
      if (A->'moves'->_value->>'pp')::int <= 0 then raise exception 'Esse ataque está sem PP.'; end if;
    end if;
  elsif _kind = 'item' then
    perform public.bt_item_check(s, side, uid, _item, _value);
    item := _item;
  else raise exception 'Ação inválida.'; end if;
  insert into battle_actions(battle_id, turn, side, user_id, kind, value, item) values (b.id, b.turn, side, uid, kind, _value, item);
  -- Equipe Rocket (arquivo 44): o servidor joga pelo lado da Rocket na hora e conta o dano na barra coletiva
  if b.mode = 'rocket' then
    pre := public.rocket_dmg(b.state);
    p := public.war_pick(b.state, 1, 'forte');
    insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, uid, p->>'kind', (p->>'value')::int);
    perform public.bt_resolve(b.id);
    for k in 1 .. 3 loop
      select * into b from battles where id = _id;
      exit when b.status <> 'ativa' or b.phase <> 'troca' or not coalesce((b.state->'sides'->1->>'need_switch')::boolean, false);
      insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, uid, 'switch', public.war_switch(b.state, 1, true));
      perform public.bt_resolve(b.id);
    end loop;
    perform public.rocket_after(_id, pre);
    select * into b from battles where id = _id;
    return b;
  end if;
  -- Grama de Treino (arquivo 56): o selvagem joga sozinho na hora; no fim, XP e vida pelo treino_after
  if b.mode = 'treino' then
    p := public.war_pick(b.state, 1, 'forte');
    insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, uid, p->>'kind', (p->>'value')::int);
    perform public.bt_resolve(b.id);
    select * into b from battles where id = _id;
    if b.status = 'ativa' and b.turn > (public.treino_cfg()->>'turnos')::int then
      update battles set log = log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt', 'A luta demorou demais e o selvagem fugiu para a grama.'))))
       where id = b.id;
      perform public.bt_finish(b.id, null, 'limite');
    end if;
    select * into b from battles where id = _id;
    if b.status <> 'ativa' then perform public.treino_after(_id); select * into b from battles where id = _id; end if;
    return b;
  end if;
  if side = 0 then update battles set ready1 = true where id = b.id returning * into b;
  else update battles set ready2 = true where id = b.id returning * into b; end if;
  if b.ready1 and b.ready2 then perform public.bt_resolve(b.id); end if;
  select * into b from battles where id = _id;
  return b;
end $$;

-- ---------- permissões ----------
revoke execute on function public.treino_visita(uuid), public.treino_batalha(uuid), public.treino_after(uuid) from public, anon, authenticated;
revoke execute on function public.treino_lutar(uuid) from authenticated;   -- a luta automática saiu do site
revoke execute on function public.treino_entrar(int), public.treino_sair(), public.treino_encontro(uuid), public.treino_estado() from public, anon;
grant execute on function public.treino_entrar(int), public.treino_sair(), public.treino_encontro(uuid), public.treino_estado() to authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🌿 Grama de Treino: agora você anda por ela!', 'A Grama de Treino virou uma área de verdade, como a Safari Zone!
• Entre pelo menu Pokémon, escolha quem vai treinar e quanto tempo quer ficar: 5 ou 10 minutos.
• Ande com o seu personagem (WASD ou as setas no computador; botões na tela no celular).
• Na grama alta aparecem Pokémon selvagens, e VOCÊ dá os comandos da batalha: ataques, itens da bolsa ou fugir.
• O tempo corre o tempo todo, inclusive nas batalhas. São 60 minutos por dia; saindo antes, o que sobrou volta para o relógio.
• A vida que o Pokémon perde continua valendo: desmaiou, Centro Pokémon ou 72 horas de espera.
• Às vezes aparece um Pokémon FORTE. Vencer dá mais experiência!')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
