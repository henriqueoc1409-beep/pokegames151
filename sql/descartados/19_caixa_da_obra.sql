-- =====================================================================
-- POKEGAMES — Caixa da Obra (doações em reais por PIX) e roupas novas
-- para os Pokémon.
--
-- 1) Itens podem ter preço em reais (shop_items.price_brl). Esses itens
--    NÃO são vendidos por moedas: o jogador faz o PIX para o admin e o
--    admin registra a doação, escolhendo quem doou, o valor, uma mensagem
--    de agradecimento e os itens que a pessoa ganha.
-- 2) Caixa da Obra: mural fixo com todas as doações (todos podem ler) e o
--    total arrecadado para melhorias do jogo.
-- 3) 31 roupas novas para Pokémon (pixel art original), algumas em moedas
--    e algumas em reais.
-- Não muda pontos, XP, moedas nem recompensas. Rode depois do 18.
-- Antes de rodar, faça a cópia de segurança.
-- =====================================================================

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

-- compra com moedas: itens em reais ficam de fora (versão nova da função do arquivo 01)
create or replace function public.buy_item(_item text) returns public.characters
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters; it shop_items;
begin
  select * into me from characters where user_id = uid for update;
  select * into it from shop_items where id = _item;
  if it.id is null then raise exception 'Item inexistente.'; end if;
  if it.price_brl is not null then raise exception 'Esse item é do Caixa da Obra: faça o PIX e o admin libera para você.'; end if;
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

-- roupas de Pokémon com moedas (versão nova da função do arquivo 17)
create or replace function public.pk_cosmetic_buy(_item text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters; it shop_items;
begin
  select * into it from shop_items where id = _item and slot like 'pk\_%';
  if it.id is null then raise exception 'Item inexistente.'; end if;
  if it.price_brl is not null then raise exception 'Esse item é do Caixa da Obra: faça o PIX e o admin libera para você.'; end if;
  select * into me from characters where user_id = uid for update;
  if _item = any(me.owned_items) then raise exception 'Você já tem esse item.'; end if;
  if me.level < it.min_level then raise exception 'Precisa do nível % para comprar.', it.min_level; end if;
  if me.coins < it.price then raise exception 'Moedas insuficientes.'; end if;
  update characters set coins = coins - it.price, owned_items = array_append(owned_items, _item) where id = me.id;
end $$;

-- admin registra a doação recebida no PIX (e entrega os itens escolhidos)
create or replace function public.admin_add_donation(_user uuid, _amount numeric, _message text, _items text[] default '{}') returns public.donations
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters; d donations; bad text; gave text[] := '{}'; it text;
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
  insert into donations(user_id, donor_name, amount, message, items, created_by)
  values (_user, me.name, round(_amount, 2), left(coalesce(btrim(_message), ''), 500), coalesce(_items, '{}'), uid) returning * into d;
  insert into event_log(user_id, kind, message) values (_user, 'caixa', me.name || ' ajudou o Caixa da Obra! Obrigado!');
  insert into admin_audit_log(admin_id, action, target, after) values (uid, 'doacao', _user::text, to_jsonb(d));
  return d;
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

-- ---------- roupas novas para Pokémon (pixel art original) ----------
-- "dy" desce o item algumas linhas (ex.: bigode fica abaixo dos olhos).
insert into public.shop_items (id, name, slot, price, min_level, rarity, data, price_brl) values
 ('pk_bone_azul',          'Boné azul',            'pk_cabeca', 0,   1, 'comum',    '{"px": ["..bbbb..", ".bbbbbb.", "bbbbbbbb", "......dddd"], "pal": {"b": "#3653A0", "d": "#25397A"}}', null),
 ('pk_gorro_natal',        'Gorro de Natal',       'pk_cabeca', 150, 1, 'incomum',  '{"px": ["......ww", ".....rr.", "....rrr.", "...rrrr.", "..rrrrr.", "wwwwwwww"], "pal": {"r": "#D1453B", "w": "#F4F1E8"}}', null),
 ('pk_chapeu_cowboy',      'Chapéu de caubói',     'pk_cabeca', 180, 2, 'incomum',  '{"px": ["...bbbb...", "..bbbbbb..", "..bkkkkb..", "bbbbbbbbbb", ".bbbbbbbb."], "pal": {"b": "#8A5A2B", "k": "#4A3424"}}', null),
 ('pk_bandana_ninja',      'Faixa ninja',          'pk_cabeca', 90,  1, 'comum',    '{"px": ["bbbbbbbbbb", "bbbwwwwbbb", "bbbbbbbbbb", "........bb", ".......b.b"], "pal": {"b": "#2C467E", "w": "#C6C1B6"}}', null),
 ('pk_tiara_flores',       'Tiara de flores',      'pk_cabeca', 120, 1, 'incomum',  '{"px": ["p.y.p.y.p", "gpgygpgyg"], "pal": {"p": "#F08FB6", "y": "#F5D547", "g": "#4C9A3E"}}', null),
 ('pk_chapeu_chef',        'Chapéu de chef',       'pk_cabeca', 140, 2, 'incomum',  '{"px": [".wwwww.", "wwwwwww", "wwwwwww", ".wwwww.", ".ggggg."], "pal": {"w": "#FFFFFF", "g": "#C6C1B6"}}', null),
 ('pk_orelhas_gato',       'Orelhas de gato',      'pk_cabeca', 150, 1, 'incomum',  '{"px": ["k......k", "kk....kk", "kpk..kpk", "kkk..kkk"], "pal": {"k": "#2A2236", "p": "#F08FB6"}}', null),
 ('pk_laco_rosa',          'Laço rosa',            'pk_cabeca', 80,  1, 'comum',    '{"px": ["pp...pp", "pppkppp", "pp...pp"], "pal": {"p": "#F08FB6", "k": "#C86E9C"}}', null),
 ('pk_chapeu_palha',       'Chapéu de palha',      'pk_cabeca', 100, 1, 'comum',    '{"px": ["...yyyy...", "..yyyyyy..", "..rrrrrr..", "yyyyyyyyyy"], "pal": {"y": "#E2C891", "r": "#C0392B"}}', null),
 ('pk_chifrinhos',         'Chifrinhos',           'pk_cabeca', 220, 3, 'raro',     '{"px": ["r......r", "rr....rr", ".rr..rr."], "pal": {"r": "#C0392B"}}', null),
 ('pk_chapeu_pirata',      'Chapéu de pirata',     'pk_cabeca', 0,   1, 'epico',    '{"px": ["..kkkkkk..", ".kkkwkkkk.", "kkkkkkkkkk", "kyyyyyyyyk"], "pal": {"k": "#1B1626", "w": "#F4F1E8", "y": "#E0B44C"}}', 4.00),
 ('pk_capacete_viking',    'Capacete viking',      'pk_cabeca', 0,   1, 'epico',    '{"px": ["w......w", "w.ssss.w", "wssssssw", "ssyyyyss"], "pal": {"w": "#EADFC2", "s": "#9D988F", "y": "#E0B44C"}}', 5.00),
 ('pk_aureola',            'Auréola',              'pk_cabeca', 0,   1, 'lendario', '{"px": [".yyyyy.", "y.....y", ".yyyyy."], "pal": {"y": "#F5D547"}}', 5.00),
 ('pk_oculos_nerd',        'Óculos de nerd',       'pk_rosto',  60,  1, 'comum',    '{"px": ["kkk.kkk", "kckkkck", "kkk.kkk"], "pal": {"k": "#1B1626", "c": "#BDE6F5"}}', null),
 ('pk_mascara_heroi',      'Máscara de herói',     'pk_rosto',  150, 2, 'incomum',  '{"px": ["rrrrrrrrr", "rr.rrr.rr", "rrrrrrrrr"], "pal": {"r": "#C0392B"}}', null),
 ('pk_monoculo',           'Monóculo',             'pk_rosto',  120, 2, 'incomum',  '{"px": ["....yyy", "....y.y", "....yyy", ".....y."], "pal": {"y": "#E0B44C"}}', null),
 ('pk_bigode',             'Bigode',               'pk_rosto',  90,  1, 'comum',    '{"dy": 4, "px": ["kk...kk", "kkkkkkk", ".kk.kk."], "pal": {"k": "#4A3424"}}', null),
 ('pk_tapa_olho',          'Tapa-olho de pirata',  'pk_rosto',  100, 1, 'comum',    '{"px": ["kkkkkkk", "kkk....", "kkk...."], "pal": {"k": "#1B1626"}}', null),
 ('pk_oculos_3d',          'Óculos 3D',            'pk_rosto',  120, 1, 'incomum',  '{"px": ["wwwwwwwww", "wrrwwwbbw", "wwwwwwwww"], "pal": {"w": "#F4F1E8", "r": "#D1453B", "b": "#3E8FC4"}}', null),
 ('pk_oculos_coracao',     'Óculos de coração',    'pk_rosto',  0,   1, 'epico',    '{"px": ["pp.pp.pp.pp", "ppppp.ppppp", ".ppp...ppp.", "..p.....p.."], "pal": {"p": "#E85A8A"}}', 3.00),
 ('pk_gravata_borboleta',  'Gravata-borboleta',    'pk_pescoco', 70, 1, 'comum',    '{"px": ["rr...rr", "rrrkrrr", "rr...rr"], "pal": {"r": "#C0392B", "k": "#7E2A22"}}', null),
 ('pk_colar_perolas',      'Colar de pérolas',     'pk_pescoco', 160, 2, 'incomum', '{"px": ["w.......w", ".w.....w.", "..w.w.w.."], "pal": {"w": "#F4F1E8"}}', null),
 ('pk_sininho',            'Sininho',              'pk_pescoco', 90, 1, 'comum',    '{"px": ["rrrrrrr", "...y...", "..yyy..", "..yyy.."], "pal": {"r": "#C0392B", "y": "#F5C542"}}', null),
 ('pk_colar_havaiano',     'Colar havaiano',       'pk_pescoco', 110, 1, 'incomum', '{"px": ["p.y.p.y.p", ".o.g.o.g.", "..p.y.p.."], "pal": {"p": "#F08FB6", "y": "#F5D547", "o": "#F08A2A", "g": "#6CC04E"}}', null),
 ('pk_cachecol_rubro',     'Cachecol de torcida (vermelho e preto)', 'pk_pescoco', 120, 1, 'incomum', '{"px": ["rkrkrkrkr", "rkrkrkrkr", "......rk.", "......kr."], "pal": {"r": "#C0392B", "k": "#1B1626"}}', null),
 ('pk_cachecol_celeste',   'Cachecol de torcida (azul e branco)',     'pk_pescoco', 120, 1, 'incomum', '{"px": ["bwbwbwbwb", "bwbwbwbwb", "......bw.", "......wb."], "pal": {"b": "#3653A0", "w": "#F4F1E8"}}', null),
 ('pk_gravata_social',     'Gravata social',       'pk_pescoco', 100, 1, 'comum',   '{"px": ["..ww..", ".wbbw.", "..bb..", "..bb..", ".bbbb.", "..bb.."], "pal": {"w": "#F4F1E8", "b": "#25397A"}}', null),
 ('pk_corrente_ouro',      'Corrente de ouro',     'pk_pescoco', 0,  1, 'lendario', '{"px": ["y.......y", ".y.....y.", "..yyyyy..", "...y.y...", "....y...."], "pal": {"y": "#F5C542"}}', 5.00),
 ('pk_aura_floresta',      'Aura da floresta',     'pk_aura',   350, 5, 'raro',     '{"glow": "#6CC04E"}', null),
 ('pk_aura_fogo',          'Aura de fogo',         'pk_aura',   0,   1, 'lendario', '{"glow": "#F08A2A"}', 8.00),
 ('pk_aura_gelo',          'Aura de gelo',         'pk_aura',   0,   1, 'lendario', '{"glow": "#8FE3EE"}', 8.00)
on conflict (id) do nothing;

-- ---------- permissões ----------
revoke execute on function public.admin_add_donation(uuid, numeric, text, text[]), public.admin_delete_donation(bigint), public.donation_thanks_seen(),
  public.buy_item(text), public.pk_cosmetic_buy(text) from public, anon;
grant execute on function public.admin_add_donation(uuid, numeric, text, text[]), public.admin_delete_donation(bigint), public.donation_thanks_seen(),
  public.buy_item(text), public.pk_cosmetic_buy(text) to authenticated;
