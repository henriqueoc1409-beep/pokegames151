-- =====================================================================
-- 34_presentes_admin.sql
-- Pedido do dono em 22/10/2026: o admin dá presentes a um jogador que ele escolher,
-- de graça para o jogador: itens da loja (inclusive os vendidos só por PIX,
-- roupas de Pokémon e a bandeira da vila), moedas, dicas, "tente outra vez",
-- bolas e pedras. O jogador vê uma janela "Você ganhou um presente!" ao entrar.
-- Não conta no Caixa da Obra (para doação de verdade, continue usando o Caixa).
-- Fica tudo na Auditoria. Não mexe em nada que já existe.
-- Antes, faça a cópia de segurança.
-- =====================================================================

create table if not exists public.gifts (
  id         bigserial primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  items      text[] not null default '{}',
  bag        jsonb not null default '{}'::jsonb,
  coins      int not null default 0,
  hints      int not null default 0,
  retries    int not null default 0,
  message    text not null default '',
  seen       boolean not null default false,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists gifts_user on public.gifts (user_id, seen);
alter table public.gifts enable row level security;
drop policy if exists p_gifts on public.gifts;
create policy p_gifts on public.gifts for select to authenticated
  using (user_id = auth.uid() or public.has_role(auth.uid(), 'admin'));
revoke all on public.gifts from anon, authenticated;
grant select on public.gifts to authenticated;

-- bolas e pedras que podem ir de presente (as da 2ª geração também, mesmo desligada)
create or replace function public.gift_bag_ok(_ref text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select public.pix_bag_ok(_ref) or _ref in ('pedra_sol','pedra_lua_nova','pedra_metal','pedra_rei')
$$;

create or replace function public.admin_gift(_user uuid, _message text, _items text[] default '{}', _coins int default 0,
  _hints int default 0, _retries int default 0, _bag jsonb default '{}'::jsonb)
returns public.gifts
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters; g gifts; bad text; gave text[] := '{}'; it text; k text; q int;
  bag jsonb := '{}'::jsonb;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador dá presentes.'; end if;
  select * into me from characters where user_id = _user for update;
  if me.id is null then raise exception 'Escolha um jogador que tenha herói.'; end if;
  _coins := coalesce(_coins, 0); _hints := coalesce(_hints, 0); _retries := coalesce(_retries, 0);
  if _coins not between 0 and 100000 then raise exception 'Moedas: de 0 a 100000.'; end if;
  if _hints not between 0 and 99 or _retries not between 0 and 99 then raise exception 'Dicas e "tente outra vez": de 0 a 99.'; end if;
  select string_agg(x, ', ') into bad from unnest(coalesce(_items, '{}')) x where not exists (select 1 from shop_items s where s.id = x);
  if bad is not null then raise exception 'Item inexistente: %', bad; end if;
  foreach it in array coalesce(_items, '{}') loop
    if not (it = any(me.owned_items)) and not (it = any(gave)) then gave := gave || it; end if;
  end loop;
  for k, q in select key, value::int from jsonb_each_text(coalesce(_bag, '{}'::jsonb)) loop
    if q is null or q = 0 then continue; end if;
    if not public.gift_bag_ok(k) then raise exception 'Bola ou pedra inválida: %', k; end if;
    if q not between 1 and 99 then raise exception 'Quantidade de bolas e pedras: de 1 a 99.'; end if;
    bag := bag || jsonb_build_object(k, q);
  end loop;
  if cardinality(gave) = 0 and bag = '{}'::jsonb and _coins = 0 and _hints = 0 and _retries = 0 then
    raise exception 'Escolha pelo menos um presente (o jogador já tem os itens marcados).';
  end if;
  update characters set owned_items = owned_items || gave, coins = coins + _coins, hints = hints + _hints, retries = retries + _retries
   where id = me.id;
  for k, q in select key, value::int from jsonb_each_text(bag) loop
    insert into bag_items(user_id, item, qty) values (_user, k, q) on conflict (user_id, item) do update set qty = bag_items.qty + q;
  end loop;
  insert into gifts(user_id, items, bag, coins, hints, retries, message, created_by)
  values (_user, gave, bag, _coins, _hints, _retries, left(coalesce(btrim(_message), ''), 500), uid) returning * into g;
  insert into admin_audit_log(admin_id, action, target, after) values (uid, 'presente', _user::text, to_jsonb(g));
  return g;
end $$;

-- o jogador viu a janela do presente
create or replace function public.gifts_seen() returns void
language sql security definer set search_path = public, extensions as $$
  update gifts set seen = true where user_id = auth.uid() and not seen;
$$;

revoke execute on function public.gift_bag_ok(text) from public, anon, authenticated;
revoke execute on function public.admin_gift(uuid, text, text[], int, int, int, jsonb), public.gifts_seen() from public, anon;
grant execute on function public.admin_gift(uuid, text, text[], int, int, int, jsonb), public.gifts_seen() to authenticated;
