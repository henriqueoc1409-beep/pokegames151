-- =====================================================================
-- 33_bandeira_vila.sql
-- Pedido do dono em 22/10/2026: bandeira para hastear na vila, compra opcional.
-- A arte é do próprio dono (escudo tricolor com 3 estrelas), guardada como
-- pixel art em shop_items.data (rows + pal), no novo espaço 'vila_bandeira'.
-- Compra e uso pelas funções de sempre (buy_item / equip_item).
-- Preço inicial: 500 moedas. O admin muda em Administração → Loja e PIX
-- (preço em moedas, preço em PIX ou só PIX).
-- Não mexe em nada que já existe. Antes, faça a cópia de segurança.
-- =====================================================================

alter table public.shop_items drop constraint if exists shop_items_slot_check;
alter table public.shop_items add constraint shop_items_slot_check
  check (slot in ('chapeu','capa','roupa','aura','acessorio','pk_cabeca','pk_rosto','pk_pescoco','pk_aura','vila_bandeira'));

insert into public.shop_items (id, name, slot, price, min_level, rarity, data)
values ('vila_bandeira_tricolor', 'Bandeira Tricolor', 'vila_bandeira', 500, 1, 'epico',
        '{"rows":[".............ss.............",".....o......ssss......o.....","...ooooo..ssssssss..ooooo...","....ooo...ssssssss...ooo....","...oo.oo...ssssss...oo.oo...","...........ssssss...........","rrr........ss..ss........rrr","rwrrrrr..............rrrrrwr","rwwwwwrrrrr......rrrrrwwwwwr","rwwwwwwwwrwrr..rrwrwwwwwwwwr","rwwrwwwwwrwwwrrwwwrwwwwwrrrr","rwwrrrrwwrwwwwwwwwrwwrrrrrrr","rwwrrrrwwrwwrwwrwwrwwrrrrrrr","rwwrrrrwwrwwrrrrwwrwwrrrrrrr","rwwrrrrwwrwwrrrrwwrwwrrrrrrr","rwwrrrrwwrwwrrrrwwrwwrrrrrrr","rwwrrrrwwrwwrrrrwwrwwrrrrrrr","rwwrrrrwwrwwrrrrwwrwwrrrrrrr","rwwrrrrwwrwwrrrrwrrwwrrrrwwr","kwwwwrrwwrwwrrrrrrrwwrrwwwwr","kwwwwwwwwrwwrrrrrrrwwrrwwwwk","kwwkkwwwwrwwrrrrrrrwwrrkkwwk","kwwkkkkwwrwwrrrrrrrwwkkkkwwk","kwwkkkkwwrwwrrrrrrrwwkkkkwwk","kwwkkkkwwkwwrrrrrkkwwkkkkwwk","kwwkkkkwwkwwkrrkkkkwwkkkkwwk","kwwkkkkwwkwwkkkkkkkwwkkkkwwk","kwwkkkkwwkwwkkkkkwkwwkkkkwwk","kwwkkkkwwkwwkkkkwwkwwkkkkwwk","kwwkkkkwwkwwkkkkwwkwwkkkkwwk","kwwkkkkwwkwwkkkkwwkwwkkkkwwk","kwwkkkkwwkwwkkkkwwkwwkkkkwwk","kwwkkkkwwkwwkkkkwwkwwkkkkwwk","kwwkkkkwwkwwkkkkwwkwwkkkkwwk",".kwkkkkwwkwwkkkkwwkwwkkkwwk.","..kkkkkwwkwwkkkkwwkwwkkwwk..","...kkkkwwkwwkkkkwwkwwkwwk...","....kkkwwkwwkkkkwwkwwwwk....",".....kkwwkwwkkkkwwkwwwk.....","......kwwkwwkkkkwwkwwk......",".......kwkwwkkkkwwkwk.......","........kkwwkkkkwwkk........",".........kwwkkkkwwk.........","..........kwwkkwwk..........","...........kwwwwk...........","............kwwk............",".............kk............."],"pal":{"w":"#FFFFFF","s":"#CED0D1","o":"#CAB274","r":"#DF1011","k":"#000000"}}'::jsonb)
on conflict (id) do nothing;

-- conferência
select id, name, slot, price from public.shop_items where slot = 'vila_bandeira';
