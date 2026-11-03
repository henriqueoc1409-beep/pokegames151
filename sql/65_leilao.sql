-- =====================================================================
-- POKEGAMES — Leilão de Pokémon (pedido do dono em 03/11/2026).
--
-- • Cada jogador pode pôr 1 Pokémon em leilão a cada 3 dias, por 24 horas,
--   com um lance mínimo.
-- • Só vale lance a partir do mínimo e maior que o atual (+5 moedas). Qualquer
--   jogador cobre a qualquer momento. O valor do lance fica RESERVADO na hora;
--   quem é coberto recebe as moedas de volta na hora.
-- • Lance nos últimos 5 minutos estica o leilão mais 5 minutos.
-- • No fim, se teve lance, o Pokémon passa sozinho para quem deu o maior lance
--   (sai da equipe, da guerra e do mascote de quem vendeu) e o vendedor recebe
--   o valor menos a taxa (5%, como no Mercado). Sem lance, nada muda.
-- • O Pokémon continua com o dono durante o leilão. Se ele sumir (solto ou
--   roubado pela Equipe Rocket), o leilão é cancelado e o lance devolvido.
-- • O fechamento acontece sozinho na próxima vez que alguém abrir o leilão
--   (ou entrar no jogo). Números em Ajustes do jogo → Leilão (leilao_cfg).
-- Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

create or replace function public.leilao_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "intervalo_dias": 3, "horas": 24, "taxa_pct": 5, "min_preco": 10, "incremento": 5, "anti_sniper_min": 5}'::jsonb
         || coalesce(public.cfg()->'leilao', '{}'::jsonb)
$$;

create table if not exists public.leiloes (
  id          bigserial primary key,
  seller      uuid not null references auth.users(id) on delete cascade,
  mon_id      uuid,
  species     int  not null,
  level       int  not null,
  info        jsonb not null default '{}'::jsonb,     -- foto do Pokémon na hora do leilão (atributos e ataques)
  min_price   int  not null,
  top_bid     int,
  top_bidder  uuid references auth.users(id) on delete set null,
  status      text not null default 'aberto' check (status in ('aberto', 'vendido', 'sem_lance', 'cancelado')),
  ends_at     timestamptz not null,
  created_at  timestamptz not null default now(),
  closed_at   timestamptz
);
create index if not exists leiloes_aberto on public.leiloes (status, ends_at);
create index if not exists leiloes_seller on public.leiloes (seller, created_at desc);
create table if not exists public.leilao_lances (
  id         bigserial primary key,
  leilao_id  bigint not null references public.leiloes(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  valor      int not null,
  created_at timestamptz not null default now()
);
create index if not exists leilao_lances_l on public.leilao_lances (leilao_id, id desc);
alter table public.leiloes enable row level security;
alter table public.leilao_lances enable row level security;
drop policy if exists leiloes_read on public.leiloes;
create policy leiloes_read on public.leiloes for select to authenticated using (true);
drop policy if exists leilao_lances_read on public.leilao_lances;
create policy leilao_lances_read on public.leilao_lances for select to authenticated using (true);
grant select on public.leiloes, public.leilao_lances to authenticated;

-- devolve o lance reservado de quem está na frente
create or replace function public.leilao_devolve(_l leiloes) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if _l.top_bidder is not null and coalesce(_l.top_bid, 0) > 0 then
    update characters set coins = coins + _l.top_bid where user_id = _l.top_bidder;
  end if;
end $$;

-- fecha os leilões que já venceram: entrega o Pokémon e paga o vendedor
create or replace function public.leilao_tick() returns int
language plpgsql security definer set search_path = public, extensions as $$
declare l leiloes; m monsters; c jsonb := public.leilao_cfg(); taxa int; n int := 0; sn text; bn text;
begin
  for l in select * from leiloes where status = 'aberto' and ends_at <= now() for update skip locked loop
    select * into m from monsters where id = l.mon_id and user_id = l.seller for update;
    if m.id is null then   -- o Pokémon sumiu: cancela e devolve
      perform public.leilao_devolve(l);
      update leiloes set status = 'cancelado', closed_at = now() where id = l.id;
    elsif l.top_bidder is null then
      update leiloes set status = 'sem_lance', closed_at = now() where id = l.id;
    else
      taxa := floor(l.top_bid * (c->>'taxa_pct')::numeric / 100)::int;
      update monsters set user_id = l.top_bidder, team_slot = null where id = m.id;
      delete from war_squads where monster_id = m.id;
      update characters set mascot = null where user_id = l.seller and (mascot->>'id')::uuid = m.id;
      update characters set coins = coins + l.top_bid - taxa where user_id = l.seller;
      perform public.pk_dex_mark(l.top_bidder, m.species_id, true);
      update leiloes set status = 'vendido', closed_at = now() where id = l.id;
      select name into sn from characters where user_id = l.seller;
      select name into bn from characters where user_id = l.top_bidder;
      insert into event_log(user_id, kind, message) values (l.top_bidder, 'leilao',
        bn || ' arrematou ' || (select name from pokemon where id = m.species_id) || ' (nível ' || m.level || ') de ' || sn || ' por ' || l.top_bid || ' moedas no Leilão!');
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- se o Pokémon do leilão for apagado (solto ou roubado), o leilão é cancelado e o lance devolvido
create or replace function public.leilao_mon_apagado() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare l leiloes;
begin
  for l in select * from leiloes where mon_id = old.id and status = 'aberto' for update loop
    perform public.leilao_devolve(l);
    update leiloes set status = 'cancelado', closed_at = now() where id = l.id;
  end loop;
  return old;
end $$;
drop trigger if exists leilao_mon_apagado on public.monsters;
create trigger leilao_mon_apagado after delete on public.monsters for each row execute function public.leilao_mon_apagado();

create or replace function public.leilao_criar(_mon uuid, _min int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.leilao_cfg(); m monsters; ult timestamptz; l leiloes;
begin
  if not coalesce((c->>'on')::boolean, true) then raise exception 'O Leilão está fechado no momento.'; end if;
  perform 1 from characters where user_id = uid for update;
  perform public.leilao_tick();
  select * into m from monsters where id = _mon and user_id = uid;
  if m.id is null then raise exception 'Escolha um Pokémon seu.'; end if;
  if exists (select 1 from leiloes where mon_id = m.id and status = 'aberto') then raise exception 'Esse Pokémon já está em leilão.'; end if;
  select max(created_at) into ult from leiloes where seller = uid and status <> 'cancelado';
  if ult is not null and now() < ult + make_interval(days => (c->>'intervalo_dias')::int) then
    raise exception 'Você pode pôr 1 Pokémon em leilão a cada % dias. O próximo libera em %.', c->>'intervalo_dias',
      to_char((ult + make_interval(days => (c->>'intervalo_dias')::int)) at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI');
  end if;
  if _min is null or _min < (c->>'min_preco')::int or _min > 1000000 then raise exception 'O lance mínimo precisa ser de pelo menos % moedas.', c->>'min_preco'; end if;
  insert into leiloes(seller, mon_id, species, level, info, min_price, ends_at)
  values (uid, m.id, m.species_id, m.level, public.bt_mon(m.id) - 'outfit' || jsonb_build_object('dvs', jsonb_build_array(m.dv_atk, m.dv_def, m.dv_spd, m.dv_spc)),
          _min, now() + make_interval(hours => (c->>'horas')::int))
  returning * into l;
  insert into event_log(user_id, kind, message) select uid, 'leilao', ch.name || ' pôs ' || (select name from pokemon where id = m.species_id) || ' (nível ' || m.level || ') no Leilão, a partir de ' || _min || ' moedas.' from characters ch where ch.user_id = uid;
  return to_jsonb(l);
end $$;

create or replace function public.leilao_lance(_id bigint, _valor int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.leilao_cfg(); l leiloes; me characters; minimo int; precisa int;
begin
  perform public.leilao_tick();
  select * into l from leiloes where id = _id for update;
  if l.id is null or l.status <> 'aberto' or l.ends_at <= now() then raise exception 'Esse leilão já terminou.'; end if;
  if l.seller = uid then raise exception 'Você não pode dar lance no seu próprio leilão.'; end if;
  minimo := case when l.top_bid is null then l.min_price else l.top_bid + (c->>'incremento')::int end;
  if _valor is null or _valor < minimo then raise exception 'O lance precisa ser de pelo menos % moedas.', minimo; end if;
  select * into me from characters where user_id = uid for update;
  -- quem já está na frente só paga a diferença
  precisa := case when l.top_bidder = uid then _valor - l.top_bid else _valor end;
  if me.coins < precisa then raise exception 'Você tem % moedas; esse lance precisa de %.', me.coins, precisa; end if;
  if l.top_bidder is distinct from uid and (select count(*) from monsters where user_id = uid) >= coalesce((public.pk_cfg()->'storage'->>'max_monsters')::int, 300) then
    raise exception 'Sua coleção está cheia. Solte algum Pokémon antes.';
  end if;
  if l.top_bidder is distinct from uid then perform public.leilao_devolve(l); end if;
  update characters set coins = coins - precisa where id = me.id;
  update leiloes set top_bid = _valor, top_bidder = uid,
         ends_at = greatest(ends_at, now() + make_interval(mins => (c->>'anti_sniper_min')::int))
   where id = l.id returning * into l;
  insert into leilao_lances(leilao_id, user_id, valor) values (l.id, uid, _valor);
  return to_jsonb(l);
end $$;

create or replace function public.leilao_estado() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.leilao_cfg(); ult timestamptz;
begin
  if uid is null then raise exception 'Entre na sua conta.'; end if;
  perform public.leilao_tick();
  select max(created_at) into ult from leiloes where seller = uid and status <> 'cancelado';
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'cfg', c, 'agora', now(),
    'proximo', case when ult is null then null else ult + make_interval(days => (c->>'intervalo_dias')::int) end,
    'abertos', coalesce((select jsonb_agg(to_jsonb(l) || jsonb_build_object('seller_name', s.name, 'bidder_name', b.name,
        'lances', (select count(*) from leilao_lances x where x.leilao_id = l.id)) order by l.ends_at)
      from leiloes l join characters s on s.user_id = l.seller left join characters b on b.user_id = l.top_bidder where l.status = 'aberto'), '[]'::jsonb),
    'encerrados', coalesce((select jsonb_agg(to_jsonb(l) || jsonb_build_object('seller_name', s.name, 'bidder_name', b.name) order by l.closed_at desc)
      from (select * from leiloes where status in ('vendido', 'sem_lance', 'cancelado') order by closed_at desc limit 20) l
      join characters s on s.user_id = l.seller left join characters b on b.user_id = l.top_bidder), '[]'::jsonb));
end $$;

-- números para a aba Ajustes do jogo (versão do 64 + Leilão)
create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'leilao', public.leilao_cfg(), 'base', public.cfg());
end $$;

-- ---------- permissões ----------
revoke execute on function public.leilao_cfg(), public.leilao_devolve(leiloes), public.leilao_tick(), public.leilao_mon_apagado() from public, anon, authenticated;
revoke execute on function public.leilao_criar(uuid, int), public.leilao_lance(bigint, int), public.leilao_estado() from public, anon;
grant execute on function public.leilao_criar(uuid, int), public.leilao_lance(bigint, int), public.leilao_estado() to authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🔨 Novo: Leilão de Pokémon', 'Abriu o Leilão de Pokémon (menu Pokémon)!
• Cada jogador pode pôr 1 Pokémon em leilão a cada 3 dias. O leilão dura 24 horas, com um lance mínimo que você escolhe.
• Qualquer jogador pode cobrir o lance a qualquer momento. As moedas do seu lance ficam reservadas; se alguém cobrir, elas voltam na hora.
• Lance nos últimos 5 minutos estica o leilão mais 5 minutos.
• No fim, o Pokémon vai sozinho para quem deu o maior lance, e quem vendeu recebe as moedas (menos 5% de taxa).')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
