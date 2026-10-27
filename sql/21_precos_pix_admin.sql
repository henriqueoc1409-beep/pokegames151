-- =====================================================================
-- POKEGAMES — Caixa da Obra, preços em PIX controlados pelo admin e
-- Mural de contribuições. ARQUIVO COMPLETO: não precisa do 19 nem do 20.
--
-- 1) Caixa da Obra: doações recebidas por PIX (tabela donations), com o
--    total, a mensagem do admin para cada pessoa e o agradecimento.
-- 2) Preços: o admin define, em cada item da loja, o preço em moedas, o
--    preço em PIX (vazio = não vende por PIX) e se ele também sai por moedas.
-- 3) Ofertas extras em PIX (pix_offers): moedas, dicas, "tente outra vez",
--    Poké Bolas e pedras, com liga/desliga e data de fim (eventos).
-- 4) Mural de contribuições (contributions): o admin escreve, para cada
--    jogador, um texto livre sobre como ele ajudou o jogo.
-- Não muda pontos, XP, moedas nem recompensas. Rode depois do 17 (e do 18).
-- Pode rodar mesmo que o 19 já tenha rodado. Antes, faça a cópia de segurança.
-- =====================================================================

-- ---------- Caixa da Obra ----------
alter table public.shop_items add column if not exists price_brl numeric(10,2) check (price_brl is null or price_brl > 0);

create table if not exists public.donations (
  id         bigserial primary key,
  user_id    uuid references auth.users(id) on delete set null,   -- quem doou (pode ficar vazio se a conta for apagada)
  donor_name text not null,                                         -- nome no momento da doação
  amount     numeric(10,2) not null check (amount > 0),
  message    text not null default '' check (char_length(message) <= 500),
  items      text[] not null default '{}',
  thanked    boolean not null default false,                      -- o doador já viu o agradecimento?
  created_by uuid not null,
  created_at timestamptz not null default now()
);
create index if not exists donations_recentes on public.donations (created_at desc);
alter table public.donations enable row level security;
drop policy if exists p_don on public.donations;
create policy p_don on public.donations for select to authenticated using (true);
revoke all on public.donations from anon, authenticated;
revoke all on sequence public.donations_id_seq from anon, authenticated;
grant select on public.donations to authenticated;
do $$ begin
  begin alter publication supabase_realtime add table public.donations; exception when duplicate_object then null; end;
end $$;

create or replace function public.admin_delete_donation(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d donations;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador apaga doações.'; end if;
  delete from donations where id = _id returning * into d;
  if d.id is null then raise exception 'Doação não encontrada.'; end if;
  insert into admin_audit_log(admin_id, action, target, before) values (uid, 'doacao_apagada', d.user_id::text, to_jsonb(d));
end $$;

-- o doador marca que já viu o agradecimento
create or replace function public.donation_thanks_seen() returns void
language sql security definer set search_path = public, extensions as $$
  update donations set thanked = true where user_id = auth.uid() and not thanked
$$;


-- ---------- Preços em PIX ----------
alter table public.shop_items add column if not exists coins_ok boolean not null default true;
-- itens que já eram só PIX (se o 19 tiver rodado) continuam só PIX
update public.shop_items set coins_ok = false where price_brl is not null and coins_ok;

create table if not exists public.pix_offers (
  id         bigserial primary key,
  kind       text not null check (kind in ('bolsa','dica','outra_vez','moedas')),
  ref        text,                                 -- para "bolsa": great_ball, ultra_ball, pedra_fogo...
  qty        int not null check (qty between 1 and 100000),
  name       text not null check (char_length(name) between 1 and 80),
  price_brl  numeric(10,2) not null check (price_brl > 0),
  active     boolean not null default true,
  ends_at    timestamptz,                          -- vazio = sem data de fim
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.pix_offers enable row level security;
drop policy if exists p_pixo on public.pix_offers;
create policy p_pixo on public.pix_offers for select to authenticated using (true);
revoke all on public.pix_offers from anon, authenticated;
revoke all on sequence public.pix_offers_id_seq from anon, authenticated;
grant select on public.pix_offers to authenticated;
do $$ begin
  begin alter publication supabase_realtime add table public.pix_offers; exception when duplicate_object then null; end;
end $$;

alter table public.donations add column if not exists extras jsonb not null default '[]'::jsonb;

-- itens válidos para a bolsa
create or replace function public.pix_bag_ok(_ref text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select _ref in ('pedra_fogo','pedra_agua','pedra_trovao','pedra_folha','pedra_lua')
      or (_ref like '%\_ball' and public.pk_cfg()->'capture'->'balls' ? replace(_ref, '_ball', ''))
$$;

-- ---------- admin: preços dos itens da loja ----------
create or replace function public.admin_set_item_prices(_item text, _price int, _price_brl numeric, _coins_ok boolean) returns public.shop_items
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); it shop_items; nw shop_items;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador muda preços.'; end if;
  select * into it from shop_items where id = _item for update;
  if it.id is null then raise exception 'Item inexistente.'; end if;
  if _price is null or _price < 0 or _price > 1000000 then raise exception 'Preço em moedas inválido.'; end if;
  if _price_brl is not null and (_price_brl <= 0 or _price_brl > 10000) then raise exception 'Preço em reais inválido.'; end if;
  if not coalesce(_coins_ok, true) and _price_brl is null then raise exception 'Um item que não sai por moedas precisa ter preço em PIX.'; end if;
  update shop_items set price = _price, price_brl = round(_price_brl, 2), coins_ok = coalesce(_coins_ok, true) where id = _item returning * into nw;
  insert into admin_audit_log(admin_id, action, target, before, after)
  values (uid, 'preco_item', _item, jsonb_build_object('price', it.price, 'price_brl', it.price_brl, 'coins_ok', it.coins_ok),
          jsonb_build_object('price', nw.price, 'price_brl', nw.price_brl, 'coins_ok', nw.coins_ok));
  return nw;
end $$;

-- ---------- admin: ofertas extras (criar ou alterar; _id vazio = nova) ----------
create or replace function public.admin_save_pix_offer(_id bigint, _kind text, _ref text, _qty int, _name text, _price_brl numeric, _active boolean, _ends_at timestamptz)
returns public.pix_offers
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); o pix_offers; old pix_offers;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador mexe nas ofertas.'; end if;
  if _kind not in ('bolsa','dica','outra_vez','moedas') then raise exception 'Tipo de oferta inválido.'; end if;
  if _kind = 'bolsa' and not public.pix_bag_ok(_ref) then raise exception 'Escolha uma bola ou pedra válida.'; end if;
  if _qty is null or _qty < 1 or _qty > 100000 then raise exception 'Quantidade inválida.'; end if;
  if _price_brl is null or _price_brl <= 0 or _price_brl > 10000 then raise exception 'Preço em reais inválido.'; end if;
  if btrim(coalesce(_name, '')) = '' then raise exception 'Dê um nome para a oferta.'; end if;
  if _id is null then
    insert into pix_offers(kind, ref, qty, name, price_brl, active, ends_at)
    values (_kind, case when _kind = 'bolsa' then _ref end, _qty, left(btrim(_name), 80), round(_price_brl, 2), coalesce(_active, true), _ends_at)
    returning * into o;
  else
    select * into old from pix_offers where id = _id for update;
    if old.id is null then raise exception 'Oferta não encontrada.'; end if;
    update pix_offers set kind = _kind, ref = case when _kind = 'bolsa' then _ref end, qty = _qty, name = left(btrim(_name), 80),
           price_brl = round(_price_brl, 2), active = coalesce(_active, true), ends_at = _ends_at, updated_at = now()
     where id = _id returning * into o;
  end if;
  insert into admin_audit_log(admin_id, action, target, before, after) values (uid, 'oferta_pix', o.id::text, to_jsonb(old), to_jsonb(o));
  return o;
end $$;

create or replace function public.admin_delete_pix_offer(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); o pix_offers;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador mexe nas ofertas.'; end if;
  delete from pix_offers where id = _id returning * into o;
  if o.id is null then raise exception 'Oferta não encontrada.'; end if;
  insert into admin_audit_log(admin_id, action, target, before) values (uid, 'oferta_pix_apagada', _id::text, to_jsonb(o));
end $$;

-- ---------- compras com moedas: respeitam "só PIX" (versões novas do arquivo 19) ----------
create or replace function public.buy_item(_item text) returns public.characters
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters; it shop_items;
begin
  select * into me from characters where user_id = uid for update;
  select * into it from shop_items where id = _item;
  if it.id is null then raise exception 'Item inexistente.'; end if;
  if not it.coins_ok then raise exception 'Esse item só sai por PIX: faça o PIX e o admin libera para você.'; end if;
  if _item = any(me.owned_items) then raise exception 'Você já tem esse item.'; end if;
  if me.level < it.min_level then raise exception 'Precisa do nível % para comprar.', it.min_level; end if;
  if me.coins < it.price then raise exception 'Moedas insuficientes.'; end if;
  update characters set coins = coins - it.price, owned_items = array_append(owned_items, _item),
         outfit = outfit || jsonb_build_object(it.slot, it.id)
   where id = me.id returning * into me;
  if it.rarity in ('epico','lendario') then
    insert into event_log(user_id, kind, message) values (uid, 'loja', me.name || ' conseguiu ' || it.name || '!');
  end if;
  return me;
end $$;

create or replace function public.pk_cosmetic_buy(_item text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters; it shop_items;
begin
  select * into it from shop_items where id = _item and slot like 'pk\_%';
  if it.id is null then raise exception 'Item inexistente.'; end if;
  if not it.coins_ok then raise exception 'Esse item só sai por PIX: faça o PIX e o admin libera para você.'; end if;
  select * into me from characters where user_id = uid for update;
  if _item = any(me.owned_items) then raise exception 'Você já tem esse item.'; end if;
  if me.level < it.min_level then raise exception 'Precisa do nível % para comprar.', it.min_level; end if;
  if me.coins < it.price then raise exception 'Moedas insuficientes.'; end if;
  update characters set coins = coins - it.price, owned_items = array_append(owned_items, _item) where id = me.id;
end $$;

-- ---------- registro de doação: entrega itens e ofertas extras ----------
drop function if exists public.admin_add_donation(uuid, numeric, text, text[]);
create or replace function public.admin_add_donation(_user uuid, _amount numeric, _message text, _items text[] default '{}', _offers bigint[] default '{}')
returns public.donations
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters; d donations; bad text; gave text[] := '{}'; it text; oid bigint; o pix_offers;
  extras jsonb := '[]'::jsonb;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador registra doações.'; end if;
  if _amount is null or _amount <= 0 then raise exception 'Informe o valor recebido.'; end if;
  select * into me from characters where user_id = _user for update;
  if me.id is null then raise exception 'Escolha um jogador que tenha herói.'; end if;
  select string_agg(x, ', ') into bad from unnest(coalesce(_items, '{}')) x where not exists (select 1 from shop_items s where s.id = x);
  if bad is not null then raise exception 'Item inexistente: %', bad; end if;
  foreach it in array coalesce(_items, '{}') loop
    if not (it = any(me.owned_items)) and not (it = any(gave)) then gave := gave || it; end if;
  end loop;
  if cardinality(gave) > 0 then update characters set owned_items = owned_items || gave where id = me.id; end if;
  -- ofertas extras (a mesma oferta pode vir mais de uma vez = comprou mais de uma)
  foreach oid in array coalesce(_offers, '{}') loop
    select * into o from pix_offers where id = oid;
    if o.id is null then raise exception 'Oferta inexistente: %', oid; end if;
    if o.kind = 'bolsa' then
      insert into bag_items(user_id, item, qty) values (_user, o.ref, o.qty) on conflict (user_id, item) do update set qty = bag_items.qty + o.qty;
    elsif o.kind = 'dica' then update characters set hints = hints + o.qty where id = me.id;
    elsif o.kind = 'outra_vez' then update characters set retries = retries + o.qty where id = me.id;
    elsif o.kind = 'moedas' then update characters set coins = coins + o.qty where id = me.id;
    end if;
    extras := extras || jsonb_build_object('offer', o.id, 'kind', o.kind, 'ref', o.ref, 'qty', o.qty, 'name', o.name);
  end loop;
  insert into donations(user_id, donor_name, amount, message, items, extras, created_by)
  values (_user, me.name, round(_amount, 2), left(coalesce(btrim(_message), ''), 500), coalesce(_items, '{}'), extras, uid) returning * into d;
  insert into event_log(user_id, kind, message) values (_user, 'caixa', me.name || ' ajudou o Caixa da Obra! Obrigado!');
  insert into admin_audit_log(admin_id, action, target, after) values (uid, 'doacao', _user::text, to_jsonb(d));
  return d;
end $$;

-- ---------- permissões ----------
revoke execute on function public.pix_bag_ok(text) from public, anon, authenticated;
revoke execute on function public.admin_set_item_prices(text, int, numeric, boolean), public.admin_save_pix_offer(bigint, text, text, int, text, numeric, boolean, timestamptz),
  public.admin_delete_pix_offer(bigint), public.admin_add_donation(uuid, numeric, text, text[], bigint[]), public.buy_item(text), public.pk_cosmetic_buy(text) from public, anon;
grant execute on function public.admin_set_item_prices(text, int, numeric, boolean), public.admin_save_pix_offer(bigint, text, text, int, text, numeric, boolean, timestamptz),
  public.admin_delete_pix_offer(bigint), public.admin_add_donation(uuid, numeric, text, text[], bigint[]), public.buy_item(text), public.pk_cosmetic_buy(text) to authenticated;
revoke execute on function public.admin_delete_donation(bigint), public.donation_thanks_seen() from public, anon;
grant execute on function public.admin_delete_donation(bigint), public.donation_thanks_seen() to authenticated;

-- ---------- Mural de contribuições (texto livre do admin por jogador) ----------
create table if not exists public.contributions (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  text       text not null check (char_length(text) between 1 and 1000),
  sort       int not null default 0,                     -- ordem no mural (menor aparece primeiro)
  updated_at timestamptz not null default now()
);
alter table public.contributions enable row level security;
drop policy if exists p_contrib on public.contributions;
create policy p_contrib on public.contributions for select to authenticated using (true);
revoke all on public.contributions from anon, authenticated;
grant select on public.contributions to authenticated;
do $$ begin
  begin alter publication supabase_realtime add table public.contributions; exception when duplicate_object then null; end;
end $$;

-- escrever, mudar ou apagar (texto vazio apaga) a contribuição de um jogador
create or replace function public.admin_set_contribution(_user uuid, _text text, _sort int default 0) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); old contributions;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador edita o mural de contribuições.'; end if;
  if not exists (select 1 from characters where user_id = _user) then raise exception 'Escolha um jogador que tenha herói.'; end if;
  select * into old from contributions where user_id = _user;
  if btrim(coalesce(_text, '')) = '' then
    delete from contributions where user_id = _user;
  else
    insert into contributions(user_id, text, sort) values (_user, left(btrim(_text), 1000), coalesce(_sort, 0))
    on conflict (user_id) do update set text = excluded.text, sort = excluded.sort, updated_at = now();
  end if;
  insert into admin_audit_log(admin_id, action, target, before, after)
  values (uid, 'contribuicao', _user::text, to_jsonb(old), (select to_jsonb(c) from contributions c where c.user_id = _user));
end $$;
revoke execute on function public.admin_set_contribution(uuid, text, int) from public, anon;
grant execute on function public.admin_set_contribution(uuid, text, int) to authenticated;
