-- =====================================================================
-- 35_nome_itens_bandeira_verde.sql
-- Pedidos do dono em 22/10/2026:
--   1) o admin pode mudar o NOME de qualquer item da loja (Administração → Loja e PIX);
--   2) nova bandeira de vila "Bandeira Verde MG", desenhada pelo dono (escudo verde e
--      branco com estrela, faixa e listras), sem sigla nem bola de clube. 500 moedas.
-- Mudar o nome não mexe em quem já tem o item. Fica na Auditoria.
-- Depende do 21 e do 33. Antes, faça a cópia de segurança.
-- =====================================================================

create or replace function public.admin_set_item_name(_item text, _name text) returns public.shop_items
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); it shop_items; nw shop_items; nm text := btrim(coalesce(_name, ''));
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador muda o nome dos itens.'; end if;
  select * into it from shop_items where id = _item for update;
  if it.id is null then raise exception 'Item inexistente.'; end if;
  if char_length(nm) not between 2 and 60 then raise exception 'O nome precisa ter de 2 a 60 letras.'; end if;
  if nm = it.name then return it; end if;
  update shop_items set name = nm where id = _item returning * into nw;
  insert into admin_audit_log(admin_id, action, target, before, after)
  values (uid, 'nome_item', _item, jsonb_build_object('name', it.name), jsonb_build_object('name', nw.name));
  return nw;
end $$;

insert into public.shop_items (id, name, slot, price, min_level, rarity, data)
values ('vila_bandeira_verde', 'Bandeira Verde MG', 'vila_bandeira', 500, 1, 'epico',
        '{"rows":["................................................",".......................ww.......................",".......................ww.......................","......................wwww......................","..................wwwwwwwwwwww..................","...................wwwwwwwwwww..................","....................wwwwwwww....................","....................wwwwwwww....................",".....................wwwwww.....................","....................wwwwwwww....................","....................www..www....................","...................www....www...................","........www........ww.......w.........ww........",".......wggwww......................wwwggww......","......wwgggggwww................wwwwgggggw......",".....wwgggggggwwwwww.........wwwwwwgggggggw.....","....wwggggggggggwwwwwwwwwwwwwwwwggggggwwggww....","...wwggggggggggggggwwwwwwwwwwggggggggwwwwggww...","..wwgggggggggggggggggggggggggggggggwwwwwwwggww..",".wwggggggggggggggggggggggggggggggwwwwwwwwwwggww.","wwggggggggggggggggggggggggggggggwwwwwwwwwwwwggww","wwgggggggggggggggggggggggggggggwwwwwwwwwwwwgggww",".wwggggggggggggggggggggggggggwwwwwwwwwwwwwgggww.","..wwgggggggggggggggggggggggwwwwwwwwwwwwwggggww..","..wwgggggggggggggggggggggwwwwwwwwwwwwwggggggww..","...wggggggggggggggggggggwwwwwwwwwwwwwgggwwgww...","...wgggggggggggggggggggwwwwwwwwwwwwgggggwwgww...","...wwggggggggggggggggwwwwwwwwwwwwgggggggwwgww...","....wggggggggggggggwwwwwwwwwwwwgggwwggggwwgw....","....wgggggggggggggwwwwwwwwwwwgggwwwwggggwwgw....","....wggggggggggggwwwwwwwwwwwggggwwwwggggwwgw....","....wgggggggggwwwwwwwwwwwwggggggwwwwggggwwgw....","....wgggggggggwwwwwwwwwwggggggggwwwwggggwwgw....","...wwgggggggwwwwwwwwwwwgggwgggggwwwwggggwwgww...","...wwgggggwwwwwwwwwwwgggwwwgggggwwwwggggwwgww...","...wwgggwwwwwwwwwwwwgggwwwwgggggwwwwggggwwgww...","..wwggggwwwwwwwwwwgggggwwwwgggggwwwwggggwwggww..","..wwggwwwwwwwwwwgggggggwwwwgggggwwwwggggwwwgww..","..wggwwwwwwwwwwgggwggggwwwwgggggwwwwggggwwwggww.",".wwgwwwwwwwwwgggwwwggggwwwwgggggwwwwggggwwwwgww.",".wwgwwwwwwwgggwwwwwggggwwwwgggggwwwwggggwwwwgww.","wwggwwwwwwggggwwwwwggggwwwwgggggwwwwggggwwwwwgww","wwgwwwwwwgggggwwwwwggggwwwwgggggwwwwggggwwwwwgww","wwgwwwwgggggggwwwwwggggwwwwgggggwwwwggggwwwwwgww","wwgwwgggwwggggwwwwwggggwwwwgggggwwwwggggwwwwwgww","wwggggwwwwggggwwwwwggggwwwwgggggwwwwggggwwwwwgww",".wgggwwwwwggggwwwwwggggwwwwgggggwwwwggggwwwwggw.",".wwgwwwwwwggggwwwwwggggwwwwgggggwwwwggggwwwwgww.","..wwgwwwwwggggwwwwwggggwwwwgggggwwwwggggwwwggw..","..wwggwwwwggggwwwwwggggwwwwgggggwwwwggggwwggww..","...wwggwwwggggwwwwwggggwwwwgggggwwwwggggwwgww...","....wggwwwggggwwwwwggggwwwwgggggwwwwggggwggw....",".....wggwwggggwwwwwggggwwwwgggggwwwwggggggw.....","......wgggggggwwwwwggggwwwwgggggwwwwgggggw......",".......wggggggwwwwwggggwwwwgggggwwwwggggw.......","........wwggggwwwwwggggwwwwgggggwwwgggww........","..........wwggggwwwggggwwwwgggggwgggww..........","............wwgggwwggggwwwwgggggggwww...........",".............wwwgggggggwwwwgggggwww.............","..............wwwwgggggwwwwgggwwww..............","................wwwwgggwwwggwwww................","..................wwwwggwggwww..................",".....................wwgggw.....................","......................wwgww.....................","......................wwww......................"],"pal":{"g":"#0E4D27","w":"#F4F7F2"}}'::jsonb)
on conflict (id) do nothing;

revoke execute on function public.admin_set_item_name(text, text) from public, anon;
grant execute on function public.admin_set_item_name(text, text) to authenticated;

-- conferência
select id, name, price from public.shop_items where slot = 'vila_bandeira' order by id;
