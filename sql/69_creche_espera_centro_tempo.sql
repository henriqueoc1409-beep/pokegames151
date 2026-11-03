-- =====================================================================
-- POKEGAMES — Creche com espera e Centro com preço que cai com o tempo
-- (pedido do dono em 03/11/2026).
--
-- 1) Creche: continua pagando na hora, mas os níveis chegam AOS POUCOS:
--    1 nível a cada horas_por_nivel horas (12), para ninguém subir tudo de
--    uma vez só porque tem muitas moedas. Um treino por vez por jogador. O
--    Pokémon continua sendo usado normalmente enquanto treina. Dá para
--    cancelar: as moedas dos níveis que ainda não chegaram voltam. Se o
--    Pokémon sair da coleção (solto, vendido no Leilão, roubado pela Rocket),
--    o treino é cancelado e o que faltava volta. O limite de níveis por
--    semana conta na hora de pagar, como antes.
-- 2) Centro Pokémon: o preço da cura cai junto com o tempo de espera. Logo
--    depois do ferimento custa o preço cheio; na metade da espera, metade;
--    quando a cura grátis libera, zero.
-- Números em Ajustes do jogo → Creche (horas_por_nivel). Depende do 64 e do 67.
-- Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

create or replace function public.creche_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "preco_por_nivel": 10, "niveis_semana": 5, "nivel_max": 40, "horas_por_nivel": 12}'::jsonb || coalesce(public.cfg()->'creche', '{}'::jsonb)
$$;

create table if not exists public.creche_pedidos (
  id          bigserial primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  mon_id      uuid not null,
  species     int  not null,
  level_from  int  not null,
  niveis      int  not null,
  entregues   int  not null default 0,
  custos      jsonb not null default '[]'::jsonb,     -- quanto custou cada nível (para devolver o que não chegou)
  horas       int  not null,
  status      text not null default 'treinando' check (status in ('treinando', 'pronto', 'cancelado')),
  created_at  timestamptz not null default now(),
  closed_at   timestamptz
);
create index if not exists creche_pedidos_user on public.creche_pedidos (user_id, status);
alter table public.creche_pedidos enable row level security;
drop policy if exists creche_pedidos_read on public.creche_pedidos;
create policy creche_pedidos_read on public.creche_pedidos for select to authenticated using (user_id = auth.uid());
grant select on public.creche_pedidos to authenticated;

-- devolve as moedas dos níveis que ainda não chegaram e encerra o treino
create or replace function public.creche_devolve(_p creche_pedidos, _motivo text) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare volta int;
begin
  select coalesce(sum(x::int), 0) into volta from jsonb_array_elements_text(_p.custos) with ordinality t(x, o) where o > _p.entregues;
  if volta > 0 then update characters set coins = coins + volta where user_id = _p.user_id; end if;
  update creche_pedidos set status = 'cancelado', closed_at = now() where id = _p.id;
  insert into event_log(user_id, kind, message) values (_p.user_id, 'creche', 'Treino na Creche encerrado (' || _motivo || '). ' || volta || ' moedas devolvidas.');
  return volta;
end $$;

-- entrega os níveis cujo tempo já passou (chamado ao abrir a Creche e depois de andar)
create or replace function public.creche_tick(_uid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare p creche_pedidos; m monsters; pr pokemon; devidos int; k int;
begin
  for p in select * from creche_pedidos where user_id = _uid and status = 'treinando' for update loop
    select * into m from monsters where id = p.mon_id and user_id = _uid for update;
    if m.id is null then perform public.creche_devolve(p, 'o Pokémon saiu da sua coleção'); continue; end if;
    devidos := least(p.niveis, floor(extract(epoch from (now() - p.created_at)) / (p.horas * 3600.0))::int);
    if devidos <= p.entregues then continue; end if;
    select * into pr from pokemon where id = m.species_id;
    for k in p.entregues + 1 .. devidos loop
      select * into m from monsters where id = p.mon_id;
      exit when m.level >= 100;
      perform public.pk_give_xp(m.id, greatest(1, public.pk_exp_for(pr.growth_rate, m.level + 1) - m.exp), 'creche');
    end loop;
    update creche_pedidos set entregues = devidos, status = case when devidos >= niveis then 'pronto' else status end,
           closed_at = case when devidos >= niveis then now() else closed_at end where id = p.id;
  end loop;
end $$;

-- deixa um Pokémon treinando: paga agora, os níveis chegam 1 a cada horas_por_nivel horas
create or replace function public.creche_treinar(_mon uuid, _niveis int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.creche_cfg(); me characters; m monsters; usados int; alvo int; custo int := 0; custos jsonb := '[]'::jsonb;
  l int; v int; p creche_pedidos;
begin
  if not coalesce((c->>'on')::boolean, true) then raise exception 'A Creche está fechada no momento.'; end if;
  select * into me from characters where user_id = uid for update;
  perform public.creche_tick(uid);
  if exists (select 1 from creche_pedidos where user_id = uid and status = 'treinando') then
    raise exception 'A Creche já está treinando um Pokémon seu. Espere terminar (ou cancele) para começar outro.';
  end if;
  select * into m from monsters where id = _mon and user_id = uid;
  if m.id is null then raise exception 'Escolha um Pokémon seu.'; end if;
  if _niveis is null or _niveis < 1 then raise exception 'Escolha quantos níveis.'; end if;
  select coalesce(sum(niveis), 0) into usados from creche_log where user_id = uid and created_at >= public.creche_semana();
  if usados + _niveis > (c->>'niveis_semana')::int then
    raise exception 'A Creche treina no máximo % níveis por semana. Você ainda pode usar %.', c->>'niveis_semana', greatest(0, (c->>'niveis_semana')::int - usados);
  end if;
  alvo := m.level + _niveis;
  if alvo > (c->>'nivel_max')::int then raise exception 'A Creche só treina até o nível %.', c->>'nivel_max'; end if;
  for l in m.level + 1 .. alvo loop
    v := ceil(l * (c->>'preco_por_nivel')::int * (100 - public.creche_desc(uid)) / 100.0)::int;   -- Domador: desconto
    custo := custo + v; custos := custos || to_jsonb(v);
  end loop;
  if me.coins < custo then raise exception 'Custa % moedas e você tem %.', custo, me.coins; end if;
  update characters set coins = coins - custo where id = me.id;
  insert into creche_pedidos(user_id, mon_id, species, level_from, niveis, custos, horas)
  values (uid, m.id, m.species_id, m.level, _niveis, custos, (c->>'horas_por_nivel')::int) returning * into p;
  insert into creche_log(user_id, mon_id, species, level_from, level_to, niveis, custo) values (uid, m.id, m.species_id, m.level, alvo, _niveis, custo);
  return jsonb_build_object('custo', custo, 'coins', me.coins - custo, 'level', m.level, 'alvo', alvo,
    'proximo_em', p.created_at + make_interval(hours => p.horas), 'termina_em', p.created_at + make_interval(hours => p.horas * _niveis));
end $$;

create or replace function public.creche_cancelar() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); p creche_pedidos; volta int;
begin
  perform 1 from characters where user_id = uid for update;
  perform public.creche_tick(uid);
  select * into p from creche_pedidos where user_id = uid and status = 'treinando' for update;
  if p.id is null then raise exception 'Nenhum Pokémon treinando na Creche.'; end if;
  volta := public.creche_devolve(p, 'cancelado por você');
  return jsonb_build_object('devolvido', volta, 'entregues', p.entregues);
end $$;

create or replace function public.creche_estado() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.creche_cfg(); usados int; p creche_pedidos;
begin
  if uid is null then raise exception 'Entre na sua conta.'; end if;
  perform public.creche_tick(uid);
  select coalesce(sum(niveis), 0) into usados from creche_log where user_id = uid and created_at >= public.creche_semana();
  select * into p from creche_pedidos where user_id = uid and status = 'treinando';
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'preco_por_nivel', (c->>'preco_por_nivel')::int,
    'niveis_semana', (c->>'niveis_semana')::int, 'nivel_max', (c->>'nivel_max')::int, 'horas_por_nivel', (c->>'horas_por_nivel')::int,
    'usados', usados, 'desconto_pct', public.creche_desc(uid), 'agora', now(),
    'restante', greatest(0, (c->>'niveis_semana')::int - usados),
    'renova', public.creche_semana() + interval '7 days',
    'treino', case when p.id is null then null else jsonb_build_object('mon_id', p.mon_id, 'species', p.species, 'level_from', p.level_from, 'niveis', p.niveis,
        'entregues', p.entregues, 'proximo_em', p.created_at + make_interval(hours => p.horas * (p.entregues + 1)),
        'termina_em', p.created_at + make_interval(hours => p.horas * p.niveis),
        'devolve', (select coalesce(sum(x::int), 0) from jsonb_array_elements_text(p.custos) with ordinality t(x, o) where o > p.entregues)) end,
    'historico', coalesce((select jsonb_agg(jsonb_build_object('species', l.species, 'level_from', l.level_from, 'level_to', l.level_to, 'custo', l.custo, 'created_at', l.created_at) order by l.id desc)
      from (select * from creche_log where user_id = uid order by id desc limit 10) l), '[]'::jsonb));
end $$;

-- preço da cura no Centro para um Pokémon: cai junto com o tempo que falta para a cura grátis
create or replace function public.centro_preco_mon(_uid uuid, _level int, _hp int, _hurt_at timestamptz) returns int
language sql stable security definer set search_path = public, extensions as $$
  select case when public.centro_preco_de(_uid, _level, _hp) = 0 then 0
    else greatest(0, ceil(public.centro_preco_de(_uid, _level, _hp)
           * greatest(0, extract(epoch from (coalesce(_hurt_at, now()) + make_interval(hours => public.cura_horas(_uid)) - now())))
           / (public.cura_horas(_uid) * 3600.0)))::int end
$$;

-- estado do treino (versão do 67 + preço do Centro que cai com o tempo)
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

-- Centro Pokémon (versão do 67 + preço que cai com o tempo)
create or replace function public.centro_curar(_ids uuid[] default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters; cost int; n int;
begin
  select * into me from characters where user_id = uid for update;
  perform public.treino_autocura(uid);
  select coalesce(sum(public.centro_preco_mon(uid, level, tr_hp, tr_hurt_at)), 0), count(*) into cost, n
    from monsters where user_id = uid and tr_hp < 100 and (_ids is null or id = any(_ids));
  if n = 0 then raise exception 'Nenhum Pokémon precisa de cura.'; end if;
  if me.coins < cost then raise exception 'A cura custa % moedas e você tem %. Se preferir, espere: eles se recuperam de graça % horas depois do último ferimento.', cost, me.coins, public.cura_horas(uid); end if;
  update characters set coins = coins - cost where id = me.id;
  update monsters set tr_hp = 100, tr_hurt_at = null where user_id = uid and tr_hp < 100 and (_ids is null or id = any(_ids));
  return jsonb_build_object('cost', cost, 'curados', n, 'coins', me.coins - cost);
end $$;

-- encontro depois de andar (versão do 67 + entrega os níveis da Creche)
create or replace function public.pk_sync() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.pk_cfg(); dm record; pool int; hcls text := public.heroi(uid); k int; team uuid[]; each_xp int; mid uuid;
  sp int; lv int; maxd int; nd board_nodes; enc encounters; hh hunts; old encounters; start_at timestamptz := coalesce((public.cfg()->>'pk_start_at')::timestamptz, now());
begin
  perform public.creche_tick(uid);   -- níveis da Creche que já chegaram (arquivo 69)
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

-- ---------- permissões ----------
revoke execute on function public.creche_devolve(creche_pedidos, text), public.creche_tick(uuid), public.centro_preco_mon(uuid, int, int, timestamptz) from public, anon, authenticated;
revoke execute on function public.creche_treinar(uuid, int), public.creche_cancelar(), public.creche_estado() from public, anon;
grant execute on function public.creche_treinar(uuid, int), public.creche_cancelar(), public.creche_estado() to authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('⏳ Creche com espera e Centro mais barato com o tempo', 'Dois ajustes:
• 🏡 Creche: você paga na hora, mas os níveis chegam aos poucos, 1 a cada 12 horas. O Pokémon continua jogando enquanto treina. Um treino por vez; se cancelar, as moedas dos níveis que ainda não chegaram voltam.
• 🏥 Centro Pokémon: o preço da cura cai com o tempo. Logo depois do ferimento custa o preço cheio; na metade da espera, metade; e quando a cura grátis libera, não custa nada.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
