-- =====================================================================
-- 37_bandeiras_pelo_admin.sql
-- Pedido do dono em 22/10/2026: cadastrar bandeiras de vila pelo site, sem SQL novo.
-- Em Administração → Loja e PIX o admin escolhe uma imagem; o site transforma em pixel art
-- (linhas de letras + cores) e chama admin_save_flag. admin_delete_flag apaga uma bandeira
-- que ninguém tem. Tudo fica na Auditoria. Depende do 33.
-- Antes, faça a cópia de segurança.
-- =====================================================================

-- confere o desenho: até 120×120 pixels, linhas do mesmo tamanho, até 16 cores #RRGGBB,
-- cada letra usada precisa ter cor ('.' = transparente)
create or replace function public.flag_data_ok(_d jsonb) returns boolean
language plpgsql immutable security definer set search_path = public, extensions as $$
declare r text; w int; n int := 0; k text; v text; letters text := '';
begin
  if jsonb_typeof(_d->'rows') <> 'array' or jsonb_typeof(_d->'pal') <> 'object' then return false; end if;
  if (select count(*) from jsonb_object_keys(_d->'pal')) not between 1 and 16 then return false; end if;
  for k, v in select key, value from jsonb_each_text(_d->'pal') loop
    if k !~ '^[a-z]$' or v !~ '^#[0-9A-Fa-f]{6}$' then return false; end if;
    letters := letters || k;
  end loop;
  for r in select value from jsonb_array_elements_text(_d->'rows') loop
    n := n + 1;
    if w is null then w := char_length(r); end if;
    if char_length(r) <> w or w not between 4 and 120 then return false; end if;
    if r !~ ('^[.' || letters || ']+$') then return false; end if;
  end loop;
  return n between 4 and 120 and pg_column_size(_d) < 40000;
end $$;

-- criar (sem _id) ou trocar o desenho/nome/preço de uma bandeira
create or replace function public.admin_save_flag(_id text, _name text, _price int, _data jsonb) returns public.shop_items
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); nm text := btrim(coalesce(_name, '')); it shop_items; old shop_items; nid text;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador cadastra bandeiras.'; end if;
  if char_length(nm) not between 2 and 60 then raise exception 'O nome precisa ter de 2 a 60 letras.'; end if;
  if _price is null or _price not between 0 and 1000000 then raise exception 'Preço em moedas inválido.'; end if;
  if not public.flag_data_ok(_data) then raise exception 'Desenho da bandeira inválido (até 120×120 pixels e 16 cores).'; end if;
  if _id is null or _id = '' then
    nid := 'vila_bandeira_' || to_char(clock_timestamp(), 'YYMMDDHH24MISS') || substr(md5(random()::text), 1, 4);
    insert into shop_items (id, name, slot, price, min_level, rarity, data)
    values (nid, nm, 'vila_bandeira', _price, 1, 'epico', jsonb_build_object('rows', _data->'rows', 'pal', _data->'pal'))
    returning * into it;
  else
    select * into old from shop_items where id = _id and slot = 'vila_bandeira' for update;
    if old.id is null then raise exception 'Bandeira inexistente.'; end if;
    update shop_items set name = nm, price = _price, data = jsonb_build_object('rows', _data->'rows', 'pal', _data->'pal')
     where id = _id returning * into it;
  end if;
  insert into admin_audit_log(admin_id, action, target, before, after)
  values (uid, 'bandeira', it.id, case when old.id is null then null else jsonb_build_object('name', old.name, 'price', old.price) end,
          jsonb_build_object('name', it.name, 'price', it.price));
  return it;
end $$;

-- apagar uma bandeira que ninguém tem (quem já comprou não perde nada)
create or replace function public.admin_delete_flag(_id text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); old shop_items;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador apaga bandeiras.'; end if;
  select * into old from shop_items where id = _id and slot = 'vila_bandeira' for update;
  if old.id is null then raise exception 'Bandeira inexistente.'; end if;
  if exists (select 1 from characters where _id = any(owned_items)) then
    raise exception 'Alguém já tem essa bandeira, então ela não pode ser apagada. Para tirar da venda, desmarque "moedas" e deixe só PIX, ou mude o nome.';
  end if;
  if exists (select 1 from market_listings where item_id = _id or want_item = _id) then
    raise exception 'Essa bandeira aparece num anúncio do mercado.';
  end if;
  delete from shop_items where id = _id;
  insert into admin_audit_log(admin_id, action, target, before) values (uid, 'bandeira_apagada', _id, jsonb_build_object('name', old.name, 'price', old.price));
end $$;

revoke execute on function public.flag_data_ok(jsonb) from public, anon, authenticated;
revoke execute on function public.admin_save_flag(text, text, int, jsonb), public.admin_delete_flag(text) from public, anon;
grant execute on function public.admin_save_flag(text, text, int, jsonb), public.admin_delete_flag(text) to authenticated;
