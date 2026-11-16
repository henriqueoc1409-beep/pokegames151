-- Arquivo 119 (pedido do dono em 17/11/2026, aprovado pelo grupo):
-- (1) Creche com vagas: 1 vaga + 1 por nível do Poço dos Desejos (danificado não conta). O limite de níveis por semana continua somando todos.
-- (2) Mercado aceita itens da bolsa: pedras de evolução, TMs (não usadas: as que estão na bolsa), Pokébolas e curas/poções.
--     Só por moedas, preço livre, mesma taxa de sempre (5%). HMs e a Poké Ball grátis ficam de fora.

-- 1) Creche ------------------------------------------------------------------------------------------------
create or replace function public.creche_vagas(_uid uuid) returns int
language sql stable security definer set search_path = public, extensions as $$
  select 1 + coalesce((select public.vl_level(v, 'poco') from villages v where v.user_id = _uid), 0)
$$;

drop function if exists public.creche_cancelar();
create or replace function public.creche_cancelar(_id bigint default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); p creche_pedidos; volta int;
begin
  perform 1 from characters where user_id = uid for update;
  perform public.creche_tick(uid);
  select * into p from creche_pedidos where user_id = uid and status = 'treinando' and (_id is null or id = _id) order by id limit 1 for update;
  if p.id is null then raise exception 'Nenhum Pokémon treinando na Creche.'; end if;
  volta := public.creche_devolve(p, 'cancelado por você');
  return jsonb_build_object('devolvido', volta, 'entregues', p.entregues);
end $$;

-- 2) Mercado -----------------------------------------------------------------------------------------------
alter table public.market_listings add column if not exists bolsa text;   -- item da bolsa (pedra, TM, bola, cura)
alter table public.market_listings drop constraint if exists market_listings_item_kind_check;
alter table public.market_listings add constraint market_listings_item_kind_check check (item_kind in ('item', 'dica', 'retry', 'bolsa'));

-- o que pode ir para o Mercado
create or replace function public.bolsa_mercado_ok(_ref text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select _ref is not null and _ref <> 'poke_ball'
     and (_ref like 'pedra\_%' and public.gift_bag_ok(_ref)
          or (_ref like '%\_ball' and public.pix_bag_ok(_ref))
          or exists (select 1 from public.pk_items where id = _ref and kind <> 'hm'))
$$;

-- nome de um item da bolsa
create or replace function public.bolsa_nome(_ref text) returns text
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((select name from public.pk_items where id = _ref),
                  case when _ref like 'pedra\_%' then public.stone_name(_ref) end,
                  case when _ref like '%\_ball' then public.pk_cfg()->'capture'->'balls'->replace(_ref, '_ball', '')->>'name' end,
                  _ref)
$$;

-- nome do que está no anúncio
create or replace function public.mercado_nome(_kind text, _item text, _qty int) returns text
language sql stable security definer set search_path = public, extensions as $$
  select case _kind when 'item' then (select name from public.shop_items where id = _item)
                    when 'dica' then _qty || ' Dica(s)'
                    when 'bolsa' then _qty || '× ' || public.bolsa_nome(_item)
                    else _qty || ' Tente outra vez' end
$$;

create or replace function public.inv_take(_uid uuid, _kind text, _item text, _qty int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me characters; tem int;
begin
  select * into me from characters where user_id = _uid for update;
  if _kind = 'item' then
    if not (_item = any(me.owned_items)) then raise exception 'Item não encontrado no inventário.'; end if;
    update characters set owned_items = array_remove(owned_items, _item),
      outfit = (select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from jsonb_each(outfit) e(k, v) where v <> to_jsonb(_item))
    where id = me.id;
  elsif _kind = 'dica' then
    if me.hints < _qty then raise exception 'Dicas insuficientes.'; end if;
    update characters set hints = hints - _qty where id = me.id;
  elsif _kind = 'bolsa' then   -- arquivo 119
    select qty into tem from bag_items where user_id = _uid and item = _item for update;
    if coalesce(tem, 0) < _qty then raise exception 'Você não tem % desse item na bolsa.', _qty; end if;
    update bag_items set qty = qty - _qty where user_id = _uid and item = _item;
  else
    if me.retries < _qty then raise exception 'Tente outra vez insuficientes.'; end if;
    update characters set retries = retries - _qty where id = me.id;
  end if;
end $$;

create or replace function public.inv_give(_uid uuid, _kind text, _item text, _qty int) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if _kind = 'item' then
    update characters set owned_items = case when _item = any(owned_items) then owned_items else array_append(owned_items, _item) end where user_id = _uid;
  elsif _kind = 'dica' then update characters set hints = hints + _qty where user_id = _uid;
  elsif _kind = 'bolsa' then   -- arquivo 119
    insert into bag_items(user_id, item, qty) values (_uid, _item, _qty)
    on conflict (user_id, item) do update set qty = bag_items.qty + excluded.qty;
  else update characters set retries = retries + _qty where user_id = _uid;
  end if;
end $$;

-- anúncios com item da bolsa guardam o item em `bolsa` (o item_id aponta para a loja)
create or replace function public.market_create(_kind text, _item text, _qty int, _price int, _want_kind text, _want_item text, _want_qty int) returns public.market_listings
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); l market_listings; nm text; it text; mine text[]; ref text;
begin
  perform public.expire_listings();
  if _kind not in ('item','dica','retry','bolsa') then raise exception 'Tipo de item inválido.'; end if;
  if _kind = 'item' then
    _qty := 1;
    if not exists (select 1 from shop_items where id = _item) then raise exception 'Item inválido.'; end if;
  elsif _kind = 'bolsa' then
    if not public.bolsa_mercado_ok(_item) then raise exception 'Esse item da bolsa não pode ser vendido no Mercado.'; end if;
    _qty := coalesce(_qty, 1);
    if _qty < 1 or _qty > 20 then raise exception 'Venda de 1 a 20 de uma vez.'; end if;
    if _want_kind is not null then raise exception 'Itens da bolsa só são vendidos por moedas.'; end if;
    ref := _item; _item := null;
  else _item := null; _qty := coalesce(_qty, 1);
  end if;
  if (coalesce(_price,0) > 0) = (_want_kind is not null) then raise exception 'Escolha vender por moedas ou trocar por um item, não os dois.'; end if;
  if _want_kind is not null then
    if _want_kind not in ('item','dica','retry') then raise exception 'Troca inválida.'; end if;
    if _want_kind = 'item' then
      _want_qty := 1;
      if not exists (select 1 from shop_items where id = _want_item) then raise exception 'Item pedido inválido.'; end if;
      select owned_items into mine from characters where user_id = uid;
      if _want_item = any(mine) then raise exception 'Você já tem o item que está pedindo.'; end if;
    else _want_item := null; _want_qty := coalesce(_want_qty, 1);
    end if;
    _price := null;
  end if;
  if (select count(*) from market_listings where seller_id = uid and status = 'aberto') >= (c->>'market_max_open')::int then
    raise exception 'Você já tem % anúncios abertos.', (c->>'market_max_open');
  end if;
  perform public.inv_take(uid, _kind, coalesce(ref, _item), _qty);
  insert into market_listings(seller_id, item_kind, item_id, bolsa, qty, price, want_kind, want_item, want_qty, expires_at)
  values (uid, _kind, _item, ref, _qty, nullif(_price,0), _want_kind, _want_item, _want_qty, now() + make_interval(hours => (c->>'market_hours')::int))
  returning * into l;
  nm := (select name from characters where user_id = uid);
  it := public.mercado_nome(_kind, coalesce(ref, _item), _qty);
  insert into event_log(user_id, kind, message) values (uid, 'mercado', nm || ' anunciou ' || it || ' no mercado.');
  return l;
end $$;

create or replace function public.market_cancel(_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); l market_listings;
begin
  select * into l from market_listings where id = _id for update;
  if l.id is null or l.seller_id <> uid then raise exception 'Anúncio não encontrado.'; end if;
  if l.status <> 'aberto' then raise exception 'Esse anúncio já foi encerrado.'; end if;
  update market_listings set status = 'cancelado', closed_at = now() where id = _id;
  perform public.inv_give(uid, l.item_kind, coalesce(l.bolsa, l.item_id), l.qty);
end $$;

create or replace function public.expire_listings() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare l market_listings;
begin
  for l in update market_listings set status = 'expirado', closed_at = now()
           where status = 'aberto' and expires_at < now() returning * loop
    perform public.inv_give(l.seller_id, l.item_kind, coalesce(l.bolsa, l.item_id), l.qty);
  end loop;
end $$;


-- creche_treinar: versão do 113 com a mudança do arquivo 119
create or replace function public.creche_treinar(_mon uuid, _niveis int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.creche_cfg(); me characters; m monsters; usados int; alvo int; custo int := 0; custos jsonb := '[]'::jsonb;
  l int; v int; p creche_pedidos; A int := (c->>'nivel_alto')::int; usados_alto int; pede_baixo int; pede_alto int;
begin
  perform public.gin_trava(uid, array[_mon]);   -- arquivo 113
  if not coalesce((c->>'on')::boolean, true) then raise exception 'A Creche está fechada no momento.'; end if;
  select * into me from characters where user_id = uid for update;
  perform public.creche_tick(uid);
  -- arquivo 119: 1 vaga + 1 por nível do Poço dos Desejos
  if (select count(*) from creche_pedidos where user_id = uid and status = 'treinando') >= public.creche_vagas(uid) then
    raise exception 'As % vaga(s) da sua Creche estão ocupadas. Espere terminar (ou cancele) para começar outro. Cada nível do Poço dos Desejos dá mais 1 vaga.', public.creche_vagas(uid);
  end if;
  if exists (select 1 from creche_pedidos where user_id = uid and status = 'treinando' and mon_id = _mon) then
    raise exception 'Esse Pokémon já está treinando na Creche.';
  end if;
  select * into m from monsters where id = _mon and user_id = uid;
  if m.id is null then raise exception 'Escolha um Pokémon seu.'; end if;
  if _niveis is null or _niveis < 1 then raise exception 'Escolha quantos níveis.'; end if;
  -- arquivo 77: dois limites por semana, um até o nível alto (30) e outro acima dele
  select coalesce(sum(greatest(0, least(level_to, A) - least(level_from, A))), 0), coalesce(sum(greatest(0, level_to - greatest(level_from, A))), 0)
    into usados, usados_alto from creche_log where user_id = uid and created_at >= public.creche_inicio_semana();
  alvo := m.level + _niveis;
  pede_baixo := greatest(0, least(alvo, A) - least(m.level, A)); pede_alto := greatest(0, alvo - greatest(m.level, A));
  if usados + pede_baixo > (c->>'niveis_semana')::int then
    raise exception 'Até o nível %, a Creche treina no máximo % níveis por semana. Você ainda pode usar %.', A, c->>'niveis_semana', greatest(0, (c->>'niveis_semana')::int - usados);
  end if;
  if usados_alto + pede_alto > (c->>'niveis_semana_alto')::int then
    raise exception 'Acima do nível %, a Creche treina no máximo % níveis por semana. Você ainda pode usar %.', A, c->>'niveis_semana_alto', greatest(0, (c->>'niveis_semana_alto')::int - usados_alto);
  end if;
  if alvo > (c->>'nivel_max')::int then raise exception 'A Creche só treina até o nível %.', c->>'nivel_max'; end if;
  for l in m.level + 1 .. alvo loop
    v := ceil(l * (case when l > A then (c->>'preco_por_nivel_alto')::int else (c->>'preco_por_nivel')::int end) * (100 - public.creche_desc(uid)) / 100.0)::int;   -- Domador: desconto
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


-- creche_estado: versão do 77 com a mudança do arquivo 119
create or replace function public.creche_estado() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.creche_cfg(); usados int; usados_alto int; p creche_pedidos; A int := (c->>'nivel_alto')::int;
begin
  if uid is null then raise exception 'Entre na sua conta.'; end if;
  perform public.creche_tick(uid);
  select coalesce(sum(greatest(0, least(level_to, A) - least(level_from, A))), 0), coalesce(sum(greatest(0, level_to - greatest(level_from, A))), 0)
    into usados, usados_alto from creche_log where user_id = uid and created_at >= public.creche_inicio_semana();
  select * into p from creche_pedidos where user_id = uid and status = 'treinando' order by id limit 1;
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'preco_por_nivel', (c->>'preco_por_nivel')::int,
    'niveis_semana', (c->>'niveis_semana')::int, 'nivel_max', (c->>'nivel_max')::int, 'horas_por_nivel', (c->>'horas_por_nivel')::int,
    'usados', usados, 'desconto_pct', public.creche_desc(uid), 'agora', now(),
    'restante', greatest(0, (c->>'niveis_semana')::int - usados),
    'preco_por_nivel_alto', (c->>'preco_por_nivel_alto')::int, 'nivel_alto', A, 'niveis_semana_alto', (c->>'niveis_semana_alto')::int,
    'usados_alto', usados_alto, 'restante_alto', greatest(0, (c->>'niveis_semana_alto')::int - usados_alto),
    'renova', public.creche_semana() + interval '7 days',
    'vagas', public.creche_vagas(uid),   -- arquivo 119
    'treinos', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'mon_id', q.mon_id, 'species', q.species, 'level_from', q.level_from, 'niveis', q.niveis,
        'entregues', q.entregues, 'proximo_em', q.created_at + make_interval(hours => q.horas * (q.entregues + 1)),
        'termina_em', q.created_at + make_interval(hours => q.horas * q.niveis),
        'devolve', (select coalesce(sum(x::int), 0) from jsonb_array_elements_text(q.custos) with ordinality t(x, o) where o > q.entregues)) order by q.id)
      from creche_pedidos q where q.user_id = uid and q.status = 'treinando'), '[]'::jsonb),
    'treino', case when p.id is null then null else jsonb_build_object('mon_id', p.mon_id, 'species', p.species, 'level_from', p.level_from, 'niveis', p.niveis,
        'entregues', p.entregues, 'proximo_em', p.created_at + make_interval(hours => p.horas * (p.entregues + 1)),
        'termina_em', p.created_at + make_interval(hours => p.horas * p.niveis),
        'devolve', (select coalesce(sum(x::int), 0) from jsonb_array_elements_text(p.custos) with ordinality t(x, o) where o > p.entregues)) end,
    'historico', coalesce((select jsonb_agg(jsonb_build_object('species', l.species, 'level_from', l.level_from, 'level_to', l.level_to, 'custo', l.custo, 'created_at', l.created_at) order by l.id desc)
      from (select * from creche_log where user_id = uid order by id desc limit 10) l), '[]'::jsonb));
end $$;


-- market_buy: versão do 82 com a mudança do arquivo 119
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
  perform public.inv_give(uid, l.item_kind, coalesce(l.bolsa, l.item_id), l.qty);   -- arquivo 119: item da bolsa
  it := public.mercado_nome(l.item_kind, coalesce(l.bolsa, l.item_id), l.qty);
  sname := (select name from characters where user_id = l.seller_id);
  insert into event_log(user_id, kind, message) values (uid, 'mercado', me.name || case when l.price is not null then ' comprou ' else ' trocou com ' || sname || ' e levou ' end || it || case when l.price is not null then ' de ' || sname || '.' else '.' end);
  select * into me from characters where id = me.id;
  return me;
end $$;


revoke execute on function public.creche_vagas(uuid) from public, anon;
grant execute on function public.creche_vagas(uuid) to authenticated;
grant execute on function public.creche_cancelar(bigint) to authenticated;
grant execute on function public.bolsa_nome(text) to authenticated;
grant execute on function public.bolsa_mercado_ok(text) to authenticated;
revoke execute on function public.inv_take(uuid, text, text, int) from public, anon, authenticated;
revoke execute on function public.inv_give(uuid, text, text, int) from public, anon, authenticated;
grant execute on function public.market_create(text, text, int, int, text, text, int) to authenticated;
grant execute on function public.market_cancel(uuid) to authenticated;
grant execute on function public.market_buy(uuid) to authenticated;

insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values
   ('🏡 Creche com mais vagas e 🛒 Mercado com itens da bolsa', 'Duas mudanças:
• Creche: agora ela treina mais de um Pokémon ao mesmo tempo. Você tem 1 vaga, mais 1 para cada nível do Poço dos Desejos da sua vila. O limite de níveis por semana continua o mesmo, somando todos.
• Mercado: além de visuais, Dicas e Tente outra vez, dá para vender pedras de evolução, TMs que você ainda não usou, Pokébolas e poções/curas da bolsa. Preço livre, em moedas, com a taxa de sempre (5%). HMs não são vendidas.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
