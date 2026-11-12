-- 103_equipamentos.sql
-- Pedido do dono em 12/11/2026: equipamentos do herói, do +0 ao +9 (decisões dele: falha até +4 só gasta o doce, do +5
-- para cima volta 1 nível; Luvas e Capacete valem no tabuleiro; 5.000 moedas na loja; Peitoral não vale contra jogadores).
--   Peças (equip_cfg.pecas, bônus por nível de 1% a 18%): capacete (+moedas: salário e baús), luvas (+captura),
--   calca (+XP nas vitórias da Aventura), peitoral (−dano nas lutas da Aventura = mais vida: vida × 100/(100−%)),
--   botas (+chance de Pokémon com taxa de captura até 120 no mato da Aventura).
--   Doce de Forja (equip_doces): cai em doce_pct das vitórias contra selvagens, ginasio_doces ao ganhar insígnia,
--   chefe_doces para quem lutou no chefe derrubado. Peça nova (+0, parte sorteada) em peca_pct das vitórias,
--   ginasio_peca_pct e chefe_peca_pct; ou na loja por preco. Refino: chances por nível; volta_a_partir.
--   Feira de Equipamentos (equip_ofertas): vender peça ou doces entre jogadores, com taxa_pct.
-- Novas: rpg_encontro (do 100), rpg_ginasio_lutar (do 101), rpg_chefe_lutar (do 100), rpg_after (do 101),
-- rpg_chefe_premiar (do 99), treino_after, encounter_throw, walk (do 82), do_move (do 84), admin_cfg_efetiva (do 93).

create or replace function public.equip_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "pecas": {"capacete": {"nome": "Capacete", "bonus": [1, 2, 3, 4, 5, 7, 9, 11, 14, 18]}, "luvas": {"nome": "Luvas", "bonus": [1, 2, 3, 4, 5, 7, 9, 11, 14, 18]}, "calca": {"nome": "Calça", "bonus": [1, 2, 3, 4, 5, 7, 9, 11, 14, 18]}, "peitoral": {"nome": "Peitoral", "bonus": [1, 2, 3, 4, 5, 7, 9, 11, 14, 18]}, "botas": {"nome": "Botas", "bonus": [1, 2, 3, 4, 5, 7, 9, 11, 14, 18]}}, "chances": [100, 90, 80, 70, 55, 40, 30, 20, 10], "volta_a_partir": 5, "preco": 5000, "doce_pct": 2, "peca_pct": 0.08, "ginasio_doces": 3, "ginasio_peca_pct": 10, "chefe_doces": 2, "chefe_peca_pct": 15, "taxa_pct": 5}'::jsonb || coalesce(public.cfg()->'equip', '{}'::jsonb)
$$;
revoke execute on function public.equip_cfg() from public, anon, authenticated;

create table if not exists public.equip_pecas (
  id bigserial primary key, user_id uuid not null references auth.users(id) on delete cascade,
  slot text not null check (slot in ('capacete', 'luvas', 'calca', 'peitoral', 'botas')),
  nivel int not null default 0 check (nivel between 0 and 9), equipada boolean not null default false, a_venda boolean not null default false,
  origem text, criado timestamptz not null default now());
create unique index if not exists equip_pecas_uma_por_slot on public.equip_pecas(user_id, slot) where equipada;
alter table public.equip_pecas enable row level security;
drop policy if exists equip_pecas_ler on public.equip_pecas;
create policy equip_pecas_ler on public.equip_pecas for select to authenticated using (true);   -- todos veem as peças (como as roupas)
grant select on public.equip_pecas to authenticated;
create table if not exists public.equip_doces (user_id uuid primary key references auth.users(id) on delete cascade, qty int not null default 0 check (qty >= 0));
alter table public.equip_doces enable row level security;
drop policy if exists equip_doces_meus on public.equip_doces;
create policy equip_doces_meus on public.equip_doces for select to authenticated using (user_id = auth.uid() or public.is_admin());
grant select on public.equip_doces to authenticated;
create table if not exists public.equip_ofertas (
  id bigserial primary key, vendedor uuid not null references auth.users(id) on delete cascade, tipo text not null check (tipo in ('peca', 'doce')),
  peca_id bigint references public.equip_pecas(id) on delete cascade, qty int not null default 1, preco int not null check (preco > 0), criado timestamptz not null default now());
alter table public.equip_ofertas enable row level security;
drop policy if exists equip_ofertas_ler on public.equip_ofertas;
create policy equip_ofertas_ler on public.equip_ofertas for select to authenticated using (true);
grant select on public.equip_ofertas to authenticated;

-- bônus da peça equipada (em %)
create or replace function public.eq_bonus(_uid uuid, _slot text) returns numeric
language sql stable security definer set search_path = public, extensions as $$
  select case when not coalesce((public.equip_cfg()->>'on')::boolean, true) then 0 else coalesce((
    select (public.equip_cfg()->'pecas'->_slot->'bonus'->>p.nivel)::numeric from equip_pecas p where p.user_id = _uid and p.slot = _slot and p.equipada limit 1), 0) end
$$;
-- o Pokémon que luta na Aventura: com o Peitoral, mais vida (o mesmo que levar menos dano)
create or replace function public.rpg_mine(_mon uuid, _uid uuid, _tr int) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare mine jsonb := public.bt_mon(_mon); p numeric := least(80, public.eq_bonus(_uid, 'peitoral')); mx int;
begin
  mx := round((mine->>'maxhp')::int * 100.0 / (100 - p))::int;
  return jsonb_set(jsonb_set(mine, '{maxhp}', to_jsonb(mx)), '{hp}', to_jsonb(greatest(1, round(mx * _tr / 100.0))::int));
end $$;
-- prêmios: doce e peça
create or replace function public.equip_drop(_uid uuid, _fonte text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.equip_cfg(); nd int := 0; pp numeric; sl text; out jsonb := '{}'::jsonb;
begin
  if not coalesce((c->>'on')::boolean, true) then return null; end if;
  if _fonte = 'mato' then nd := case when random() * 100 < (c->>'doce_pct')::numeric then 1 else 0 end; pp := (c->>'peca_pct')::numeric;
  elsif _fonte = 'ginasio' then nd := (c->>'ginasio_doces')::int; pp := (c->>'ginasio_peca_pct')::numeric;
  else nd := (c->>'chefe_doces')::int; pp := (c->>'chefe_peca_pct')::numeric; end if;
  if nd > 0 then
    insert into equip_doces(user_id, qty) values (_uid, nd) on conflict (user_id) do update set qty = equip_doces.qty + nd;
    out := out || jsonb_build_object('doces', nd);
  end if;
  if random() * 100 < pp then
    sl := (array['capacete', 'luvas', 'calca', 'peitoral', 'botas'])[1 + floor(random() * 5)::int];
    insert into equip_pecas(user_id, slot, origem) values (_uid, sl, _fonte);
    out := out || jsonb_build_object('peca', sl);
    insert into event_log(user_id, kind, message) select _uid, 'equip', '🛡️ ' || name || ' achou uma peça rara: ' || (c->'pecas'->sl->>'nome') || '!' from characters where user_id = _uid;
  end if;
  return case when out = '{}'::jsonb then null else out end;
end $$;
revoke execute on function public.eq_bonus(uuid, text), public.rpg_mine(uuid, uuid, int), public.equip_drop(uuid, text) from public, anon, authenticated;

-- ---------- o que o site usa ----------
create or replace function public.equip_estado() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.equip_cfg();
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'pecas_cfg', c->'pecas', 'chances', c->'chances', 'volta_a_partir', (c->>'volta_a_partir')::int,
    'preco', (c->>'preco')::int, 'taxa_pct', (c->>'taxa_pct')::numeric, 'doces', coalesce((select qty from equip_doces where user_id = uid), 0),
    'minhas', coalesce((select jsonb_agg(to_jsonb(p) order by p.equipada desc, p.slot, p.nivel desc) from equip_pecas p where p.user_id = uid), '[]'::jsonb),
    'ofertas', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'vendedor', o.vendedor, 'nome', ch.name, 'tipo', o.tipo, 'qty', o.qty, 'preco', o.preco,
                 'slot', p.slot, 'nivel', p.nivel, 'criado', o.criado) order by o.criado desc)
               from equip_ofertas o join characters ch on ch.user_id = o.vendedor left join equip_pecas p on p.id = o.peca_id), '[]'::jsonb));
end $$;

create or replace function public.equip_comprar(_slot text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.equip_cfg(); me characters; pr int := (c->>'preco')::int;
begin
  if not coalesce((c->>'on')::boolean, true) then raise exception 'Os equipamentos estão desligados.'; end if;
  if c->'pecas'->_slot is null then raise exception 'Peça inválida.'; end if;
  select * into me from characters where user_id = uid for update;
  if me.coins < pr then raise exception 'A peça custa % moedas e você tem %.', pr, me.coins; end if;
  update characters set coins = coins - pr where user_id = uid;
  insert into equip_pecas(user_id, slot, origem) values (uid, _slot, 'loja');
  return jsonb_build_object('ok', true, 'coins', me.coins - pr);
end $$;

create or replace function public.equip_equipar(_id bigint, _on boolean default true) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); p equip_pecas;
begin
  select * into p from equip_pecas where id = _id and user_id = uid for update;
  if p.id is null then raise exception 'Peça não encontrada.'; end if;
  if p.a_venda then raise exception 'Essa peça está à venda. Cancele a venda primeiro.'; end if;
  if _on then
    update equip_pecas set equipada = false where user_id = uid and slot = p.slot and equipada and id <> p.id;
    update equip_pecas set equipada = true where id = p.id;
  else update equip_pecas set equipada = false where id = p.id; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.equip_refinar(_id bigint) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.equip_cfg(); p equip_pecas; d int; ch numeric; ok boolean; novo int; nome text;
begin
  select * into p from equip_pecas where id = _id and user_id = uid for update;
  if p.id is null then raise exception 'Peça não encontrada.'; end if;
  if p.a_venda then raise exception 'Essa peça está à venda. Cancele a venda primeiro.'; end if;
  if p.nivel >= 9 then raise exception 'Essa peça já está no +9, o máximo!'; end if;
  select qty into d from equip_doces where user_id = uid for update;
  if coalesce(d, 0) < 1 then raise exception 'Você não tem Doce de Forja.'; end if;
  update equip_doces set qty = qty - 1 where user_id = uid;
  ch := coalesce((c->'chances'->>p.nivel)::numeric, 0);
  ok := random() * 100 < ch;
  novo := case when ok then p.nivel + 1 when p.nivel >= (c->>'volta_a_partir')::int then p.nivel - 1 else p.nivel end;
  update equip_pecas set nivel = novo where id = p.id;
  if ok and novo = 9 then
    select name into nome from characters where user_id = uid;
    insert into event_log(user_id, kind, message) values (uid, 'equip', '🔥 ' || nome || ' levou ' || (c->'pecas'->p.slot->>'nome') || ' ao +9!');
  end if;
  return jsonb_build_object('ok', ok, 'antes', p.nivel, 'nivel', novo, 'chance', ch, 'doces', d - 1);
end $$;

create or replace function public.equip_ofertar(_tipo text, _peca bigint, _qty int, _preco int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); p equip_pecas; d int;
begin
  if _preco is null or _preco < 1 or _preco > 1000000 then raise exception 'Preço de 1 a 1.000.000 moedas.'; end if;
  if (select count(*) from equip_ofertas where vendedor = uid) >= 10 then raise exception 'Você já tem 10 coisas à venda.'; end if;
  if _tipo = 'peca' then
    select * into p from equip_pecas where id = _peca and user_id = uid for update;
    if p.id is null then raise exception 'Peça não encontrada.'; end if;
    if p.a_venda then raise exception 'Essa peça já está à venda.'; end if;
    update equip_pecas set a_venda = true, equipada = false where id = p.id;
    insert into equip_ofertas(vendedor, tipo, peca_id, qty, preco) values (uid, 'peca', p.id, 1, _preco);
  elsif _tipo = 'doce' then
    if _qty is null or _qty < 1 then raise exception 'Quantos doces?'; end if;
    select qty into d from equip_doces where user_id = uid for update;
    if coalesce(d, 0) < _qty then raise exception 'Você só tem % Doces de Forja.', coalesce(d, 0); end if;
    update equip_doces set qty = qty - _qty where user_id = uid;
    insert into equip_ofertas(vendedor, tipo, qty, preco) values (uid, 'doce', _qty, _preco);
  else raise exception 'O que você quer vender?'; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.equip_oferta_cancelar(_id bigint) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); o equip_ofertas;
begin
  select * into o from equip_ofertas where id = _id and vendedor = uid for update;
  if o.id is null then raise exception 'Oferta não encontrada.'; end if;
  if o.tipo = 'peca' then update equip_pecas set a_venda = false where id = o.peca_id;
  else insert into equip_doces(user_id, qty) values (uid, o.qty) on conflict (user_id) do update set qty = equip_doces.qty + o.qty; end if;
  delete from equip_ofertas where id = o.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.equip_oferta_comprar(_id bigint) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); o equip_ofertas; me characters; taxa int;
begin
  select * into o from equip_ofertas where id = _id for update;
  if o.id is null then raise exception 'Essa oferta já foi vendida ou cancelada.'; end if;
  if o.vendedor = uid then raise exception 'Essa oferta é sua.'; end if;
  select * into me from characters where user_id = uid for update;
  if me.coins < o.preco then raise exception 'Custa % moedas e você tem %.', o.preco, me.coins; end if;
  taxa := ceil(o.preco * (public.equip_cfg()->>'taxa_pct')::numeric / 100)::int;
  update characters set coins = coins - o.preco where user_id = uid;
  update characters set coins = coins + o.preco - taxa where user_id = o.vendedor;
  if o.tipo = 'peca' then update equip_pecas set user_id = uid, a_venda = false, equipada = false where id = o.peca_id;
  else insert into equip_doces(user_id, qty) values (uid, o.qty) on conflict (user_id) do update set qty = equip_doces.qty + o.qty; end if;
  delete from equip_ofertas where id = o.id;
  return jsonb_build_object('ok', true, 'coins', me.coins - o.preco);
end $$;

grant execute on function public.equip_estado(), public.equip_comprar(text), public.equip_equipar(bigint, boolean), public.equip_refinar(bigint),
  public.equip_ofertar(text, bigint, int, int), public.equip_oferta_cancelar(bigint), public.equip_oferta_comprar(bigint) to authenticated;

create or replace function public.rpg_encontro(_mon uuid, _zona text, _comp uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.rpg_cfg(); z jsonb; me characters; m monsters; d rpg_dias; bid uuid;
  lvl int; sp int; wild jsonb; mine jsonb; hp0 int; s0 jsonb; s1 jsonb; tipos text[]; lend int[]; mn int; mx int;
begin
  if not coalesce((c->>'on')::boolean, true) and not public.is_admin() then raise exception 'A Aventura está fechada no momento.'; end if;
  select * into me from characters where user_id = uid for update;
  bid := public.treino_batalha(uid);
  if bid is not null then return jsonb_build_object('battle', bid); end if;   -- termine a luta que já começou
  z := c->'zonas'->_zona;
  if z is null or jsonb_typeof(z) <> 'object' then raise exception 'Não há Pokémon selvagens neste lugar.'; end if;
  select array_agg(x) into tipos from jsonb_array_elements_text(z->'tipos') x;
  if public.rpg_noite() then   -- arquivo 99: de noite aparecem também os tipos da noite (Fantasma e Sombrio)
    tipos := tipos || array(select jsonb_array_elements_text(coalesce(c->'noite'->'tipos', '[]'::jsonb)));
  end if;
  select array_agg(x::int) into lend from jsonb_array_elements_text(coalesce(c->'lendarios', '[]'::jsonb)) x;
  mn := greatest(1, least(100, coalesce((z->>'min')::int, 2))); mx := greatest(mn, least(100, coalesce((z->>'max')::int, mn)));
  insert into rpg_dias(user_id, dia) values (uid, public.game_today()) on conflict do nothing;
  select * into d from rpg_dias where user_id = uid and dia = public.game_today() for update;
  if d.batalhas >= (c->>'batalhas_dia')::int + public.vb(uid, 'arena', 'rpg_lutas')::int then   -- arquivo 100: Arena da vila dá lutas a mais
    raise exception 'Você já fez as % lutas de hoje na Aventura. Amanhã tem mais.', (c->>'batalhas_dia')::int + public.vb(uid, 'arena', 'rpg_lutas')::int;
  end if;
  if d.ult is not null and now() < d.ult + make_interval(secs => (c->>'espera_seg')::int) then
    raise exception 'Nenhum Pokémon por aqui… continue andando.';
  end if;
  perform public.treino_autocura(uid);
  select * into m from monsters where id = _mon and user_id = uid;
  if m.id is null then raise exception 'Coloque um Pokémon seu na frente da equipe.'; end if;
  if _comp is not null and (_comp = m.id or not exists (select 1 from monsters where id = _comp and user_id = uid)
     or coalesce((select tr_hp from monsters where id = _comp), 100) <= 0) then _comp := null; end if;
  if m.tr_hp <= 0 then
    raise exception '% está desmaiado. Leve ao Centro Pokémon ou ponha outro Pokémon na frente da equipe.', (select name from pokemon where id = m.species_id);
  end if;
  delete from battles where mode = 'treino' and p1 = uid and status <> 'ativa';   -- lutas antigas já contadas
  lvl := mn + floor(random() * (mx - mn + 1))::int;
  if random() * 100 < public.eq_bonus(uid, 'botas') then   -- arquivo 103: Botas = chance de Pokémon mais raro (taxa de captura até 120)
    select p.id into sp from pokemon p
     where public.gen_ok(p.id) and not (p.id = any(coalesce(lend, '{}'::int[]))) and p.catch_rate <= 120
       and (p.g1_type1 = any(tipos) or p.g1_type2 = any(tipos))
       and public.rpg_nivel_min(p.id) <= lvl and lvl < public.rpg_nivel_max(p.id)
     order by -ln(1 - random()) / greatest(p.catch_rate, 1) limit 1;
  end if;
  if sp is null then
  select p.id into sp from pokemon p
   where public.gen_ok(p.id) and not (p.id = any(coalesce(lend, '{}'::int[])))
     and (p.g1_type1 = any(tipos) or p.g1_type2 = any(tipos))
     and public.rpg_nivel_min(p.id) <= lvl and lvl < public.rpg_nivel_max(p.id)
   order by -ln(1 - random()) / greatest(p.catch_rate, 1) limit 1;   -- sorteio com peso: os de captura difícil saem menos
  end if;
  if sp is null then raise exception 'Nenhum Pokémon por aqui… continue andando.'; end if;
  wild := public.npc_mon(sp, lvl);
  mine := public.rpg_mine(m.id, uid, m.tr_hp);   -- arquivo 103: o Peitoral dá resistência (mais vida) nas lutas da Aventura
  s0 := jsonb_build_object('user', uid, 'name', me.name, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(mine));
  s1 := jsonb_build_object('user', uid, 'name', 'Pokémon selvagem', 'npc', true, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(wild));
  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (uid, uid, 'treino', 1, 'ativa', 1, 'normal', now(),
          jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb, 'treino', jsonb_build_object('mon', m.id, 'forte', false, 'comp', _comp, 'rpg', _zona, 'ataques', 0)),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', 'Um ' || (wild->>'name') || ' selvagem (nível ' || lvl || ') apareceu em ' || coalesce(z->>'nome', 'mato') || case when public.rpg_noite() then ' 🌙' else '' end || '!'),
            jsonb_build_object('txt', 'Vai, ' || (mine->>'name') || '!' || case when m.tr_hp < 100 then ' (com ' || m.tr_hp || '% da vida)' else '' end)))))
  returning id into bid;
  update rpg_dias set batalhas = batalhas + 1, ult = now() where user_id = uid and dia = public.game_today();
  return jsonb_build_object('battle', bid, 'batalhas', d.batalhas + 1, 'batalhas_dia', (c->>'batalhas_dia')::int + public.vb(uid, 'arena', 'rpg_lutas')::int);
end $$;

create or replace function public.rpg_ginasio_lutar(_regiao text, _comp uuid default null, _meus uuid[] default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.rpg_cfg()->'ginasios'; l rpg_lideres; me characters; t rpg_gin_tent; bid uuid; n int; nl int; k int;
  m monsters; sp int; lv int; wild jsonb; mine jsonb; hp0 int; whp int; s0 jsonb; s1 jsonb;
begin
  if not coalesce((c->>'on')::boolean, true) and not public.is_admin() then raise exception 'Os Ginásios estão fechados no momento.'; end if;
  select * into l from rpg_lideres where regiao = _regiao;
  if l.regiao is null then raise exception 'Não há Ginásio aqui.'; end if;
  nl := jsonb_array_length(l.time);
  if exists (select 1 from rpg_insignias where user_id = uid and regiao = _regiao) then raise exception 'Você já tem a insígnia deste Ginásio.'; end if;
  select * into me from characters where user_id = uid for update;
  bid := public.treino_batalha(uid);
  if bid is not null then return jsonb_build_object('battle', bid); end if;
  perform public.treino_autocura(uid);
  update rpg_gin_tent set status = 'perdeu' where user_id = uid and status = 'andando' and dia < public.game_today();
  select * into t from rpg_gin_tent where user_id = uid and regiao = _regiao and dia = public.game_today() and status = 'andando' order by id desc limit 1;
  if t.id is null then
    select count(*) into n from rpg_gin_tent where user_id = uid and regiao = _regiao and dia = public.game_today();
    if n >= (c->>'tentativas_dia')::int then raise exception 'Você já usou as % tentativas de hoje neste Ginásio. Volte amanhã!', (c->>'tentativas_dia'); end if;
    -- arquivo 101: escolha a mesma quantidade de Pokémon que o Líder usa, todos seus, diferentes e com vida
    if _meus is null or cardinality(_meus) <> nl or (select count(distinct x) from unnest(_meus) x) <> nl then
      raise exception 'Escolha % Pokémon diferentes para enfrentar o Líder.', nl;
    end if;
    if (select count(*) from monsters where user_id = uid and id = any(_meus) and tr_hp > 0) <> nl then
      raise exception 'Escolha só Pokémon seus que estejam com vida.';
    end if;
    insert into rpg_gin_tent(user_id, regiao, dia, hp, meus, ordem)
    values (uid, _regiao, public.game_today(), (select jsonb_agg(100) from generate_series(1, nl)),
            to_jsonb(_meus), (select jsonb_agg(i order by random()) from generate_series(0, nl - 1) i))   -- ordem sorteada, vida cheia
    returning * into t;
  end if;
  select m2.* into m from jsonb_array_elements_text(coalesce(t.meus, '[]'::jsonb)) with ordinality e(v, k2) join monsters m2 on m2.id::text = e.v
   where m2.user_id = uid and m2.tr_hp > 0 order by e.k2 limit 1;
  if m.id is null then
    update rpg_gin_tent set status = 'perdeu' where id = t.id;
    return jsonb_build_object('fim', 'perdeu', 'msg', 'Os Pokémon que você escolheu estão desmaiados. A tentativa acabou.');
  end if;
  if _comp is not null and (_comp = m.id or not exists (select 1 from monsters where id = _comp and user_id = uid)
     or coalesce((select tr_hp from monsters where id = _comp), 100) <= 0) then _comp := null; end if;
  delete from battles where mode = 'treino' and p1 = uid and status <> 'ativa';
  k := coalesce((t.ordem->>t.idx)::int, t.idx);
  sp := (l.time->k->>0)::int; lv := (l.time->k->>1)::int;
  wild := public.npc_mon(sp, lv);
  whp := greatest(1, ceil((wild->>'maxhp')::int * coalesce((t.hp->>t.idx)::numeric, 100) / 100))::int;
  wild := jsonb_set(wild, '{hp}', to_jsonb(whp));
  mine := public.rpg_mine(m.id, uid, m.tr_hp);   -- arquivo 103: o Peitoral dá resistência (mais vida) nas lutas da Aventura
  s0 := jsonb_build_object('user', uid, 'name', me.name, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(mine));
  s1 := jsonb_build_object('user', uid, 'name', l.nome, 'npc', true, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(wild));
  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (uid, uid, 'treino', 1, 'ativa', 1, 'normal', now(),
          jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb, 'treino', jsonb_build_object('mon', m.id, 'forte', false, 'comp', _comp, 'gym', _regiao, 'gym_try', t.id, 'gym_idx', t.idx)),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', l.nome || ' manda ' || (wild->>'name') || ' (nível ' || lv || ')' || case when whp < (wild->>'maxhp')::int then ', ainda ferido,' else '' end || ' para a luta! (' || (t.idx + 1) || 'º de ' || nl || ')'),
            jsonb_build_object('txt', 'Vai, ' || (mine->>'name') || '!' || case when m.tr_hp < 100 then ' (com ' || m.tr_hp || '% da vida)' else '' end)))))
  returning id into bid;
  return jsonb_build_object('battle', bid);
end $$;

create or replace function public.rpg_chefe_lutar(_comp uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.rpg_cfg()->'chefe'; me characters; ch rpg_chefes; d rpg_chefe_dano; bid uuid; m monsters;
  wild jsonb; mine jsonb; hp0 int; s0 jsonb; s1 jsonb;
begin
  select * into me from characters where user_id = uid for update;
  bid := public.treino_batalha(uid);
  if bid is not null then return jsonb_build_object('battle', bid); end if;
  select * into ch from rpg_chefes where status = 'ativo' and fim > now() order by id desc limit 1;
  if ch.id is null then raise exception 'Não há nenhum chefe na Aventura agora.'; end if;
  insert into rpg_chefe_dano(chefe_id, user_id, dia) values (ch.id, uid, public.game_today()) on conflict do nothing;
  select * into d from rpg_chefe_dano where chefe_id = ch.id and user_id = uid for update;
  if d.dia is distinct from public.game_today() then update rpg_chefe_dano set dia = public.game_today(), lutas_dia = 0 where chefe_id = ch.id and user_id = uid; d.lutas_dia := 0; end if;
  if d.lutas_dia >= (c->>'tentativas_dia')::int then raise exception 'Você já lutou % vezes hoje contra o chefe. Volte amanhã!', (c->>'tentativas_dia'); end if;
  perform public.treino_autocura(uid);
  select * into m from monsters where user_id = uid and team_slot is not null and tr_hp > 0 order by team_slot limit 1;
  if m.id is null then raise exception 'Todos os Pokémon da sua equipe estão desmaiados. Leve ao Centro Pokémon.'; end if;
  if _comp is not null and (_comp = m.id or not exists (select 1 from monsters where id = _comp and user_id = uid)
     or coalesce((select tr_hp from monsters where id = _comp), 100) <= 0) then _comp := null; end if;
  delete from battles where mode = 'treino' and p1 = uid and status <> 'ativa';
  wild := public.npc_mon(ch.especie, ch.nivel);
  mine := public.rpg_mine(m.id, uid, m.tr_hp);   -- arquivo 103: o Peitoral dá resistência (mais vida) nas lutas da Aventura
  s0 := jsonb_build_object('user', uid, 'name', me.name, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(mine));
  s1 := jsonb_build_object('user', uid, 'name', 'Chefe da rota', 'npc', true, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(wild));
  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (uid, uid, 'treino', 1, 'ativa', 1, 'normal', now(),
          jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb, 'treino', jsonb_build_object('mon', m.id, 'forte', true, 'comp', _comp, 'chefe', ch.id)),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', '👹 O ' || (wild->>'name') || ' gigante (nível ' || ch.nivel || ') ruge! Você tem ' || (c->>'turnos') || ' turnos para causar o máximo de dano.'),
            jsonb_build_object('txt', 'Vai, ' || (mine->>'name') || '!' || case when m.tr_hp < 100 then ' (com ' || m.tr_hp || '% da vida)' else '' end)))))
  returning id into bid;
  update rpg_chefe_dano set lutas = lutas + 1, lutas_dia = lutas_dia + 1 where chefe_id = ch.id and user_id = uid;
  return jsonb_build_object('battle', bid);
end $$;

create or replace function public.rpg_after(_bid uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare b battles; t jsonb; me0 jsonb; wi jsonb; won boolean; res jsonb := '{}'::jsonb; tt rpg_gin_tent; l jsonb; c jsonb := public.rpg_cfg();
  dn int; ch rpg_chefes; nome text; z jsonb; p pokemon; total int; n int;
begin
  select * into b from battles where id = _bid for update;
  if b.id is null or b.mode <> 'treino' or b.status = 'ativa' then return null; end if;
  t := b.state->'treino';
  if coalesce((t->>'pos_feito')::boolean, false) then return t->'pos'; end if;
  me0 := b.state->'sides'->0->'mons'->0; wi := b.state->'sides'->1->'mons'->0;
  won := (wi->>'hp')::int <= 0 and (me0->>'hp')::int > 0;
  if t ? 'gym' then
    select * into tt from rpg_gin_tent where id = (t->>'gym_try')::bigint for update;
    select to_jsonb(x) into l from rpg_lideres x where regiao = t->>'gym';
    total := jsonb_array_length(l->'time');
    if tt.id is not null and tt.status = 'andando' then
      if b.end_reason = 'desistencia' then
        update rpg_gin_tent set status = 'perdeu' where id = tt.id; tt.status := 'perdeu';
      elsif (wi->>'hp')::int <= 0 then
        tt.hp := jsonb_set(tt.hp, array[tt.idx::text], '0'); tt.idx := tt.idx + 1;
        if tt.idx >= total then
          tt.status := 'venceu';
          insert into rpg_insignias(user_id, regiao) values (b.p1, t->>'gym') on conflict do nothing;
          perform public.rpg_premiar(b.p1, (c->'ginasios'->>'moedas')::int, c->'ginasios'->'itens');
          res := res || jsonb_build_object('drop', public.equip_drop(b.p1, 'ginasio'));   -- arquivo 103
          select name into nome from characters where user_id = b.p1;
          insert into event_log(user_id, kind, message) values (b.p1, 'ginasio', '🏅 ' || nome || ' venceu ' || (l->>'nome') || ' e ganhou a insígnia do Ginásio!');
          select count(*) into n from rpg_insignias where user_id = b.p1;
          if n >= (select count(*) from rpg_lideres) then
            perform public.rpg_premiar(b.p1, (c->'ginasios'->>'todas_moedas')::int, c->'ginasios'->'todas_itens');
            insert into event_log(user_id, kind, message) values (b.p1, 'ginasio', '👑 ' || nome || ' juntou TODAS as insígnias da Aventura!');
          end if;
        end if;
        update rpg_gin_tent set idx = tt.idx, hp = tt.hp, status = tt.status where id = tt.id;
      else
        tt.hp := jsonb_set(tt.hp, array[tt.idx::text], to_jsonb(greatest(1, ceil((wi->>'hp')::numeric * 100 / greatest(1, (wi->>'maxhp')::int)))::int));
        if not exists (select 1 from monsters where user_id = b.p1 and tr_hp > 0 and id::text in (select jsonb_array_elements_text(coalesce(tt.meus, '[]'::jsonb)))) then tt.status := 'perdeu'; end if;   -- arquivo 101: só os escolhidos
        update rpg_gin_tent set hp = tt.hp, status = tt.status where id = tt.id;
      end if;
    end if;
    res := res || jsonb_build_object('gym', t->>'gym', 'status', tt.status, 'idx', tt.idx, 'total', total, 'lider', l->>'nome');
  elsif t ? 'chefe' then
    dn := greatest(0, (wi->>'maxhp')::int - greatest(0, (wi->>'hp')::int));
    select * into ch from rpg_chefes where id = (t->>'chefe')::bigint for update;
    if ch.id is not null and ch.status = 'ativo' then
      update rpg_chefes set dano = least(hp_total, rpg_chefes.dano + dn) where id = ch.id returning * into ch;
      update rpg_chefe_dano set dano = rpg_chefe_dano.dano + dn where chefe_id = ch.id and user_id = b.p1;
      if ch.dano >= ch.hp_total then perform public.rpg_chefe_premiar(ch.id); ch.status := 'vencido'; end if;
    end if;
    res := jsonb_build_object('chefe', ch.id, 'dano', dn, 'total_dano', ch.dano, 'hp_total', ch.hp_total, 'status', ch.status);
  elsif t->>'rpg' is not null and won then
    z := c->'zonas'->(t->>'rpg');
    select * into p from pokemon where id = (wi->>'species')::int;
    update rpg_missoes set prog = least(meta, prog + 1)
     where user_id = b.p1 and dia = public.game_today() and not resgatada and prog < meta
       and ((tipo = 'regiao' and alvo = z->>'regiao') or (tipo = 'tipo' and alvo in (p.g1_type1, coalesce(p.g1_type2, ''))));
    update rpg_missoes set prog = meta
     where user_id = b.p1 and dia = public.game_today() and not resgatada and tipo = 'nivel' and (wi->>'level')::int >= alvo::int;
    res := jsonb_build_object('missoes', (select count(*) from rpg_missoes where user_id = b.p1 and dia = public.game_today() and not resgatada and prog >= meta),
      'drop', public.equip_drop(b.p1, 'mato'));   -- arquivo 103: Doce de Forja e peças
  end if;
  update battles set state = jsonb_set(jsonb_set(state, '{treino,pos}', res), '{treino,pos_feito}', 'true') where id = b.id;
  return res;
end $$;

create or replace function public.rpg_chefe_premiar(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rpg_cfg()->'chefe'; ch rpg_chefes; d record; k int := 0; n int := 0; nome text;
begin
  select * into ch from rpg_chefes where id = _id for update;
  if ch.premiado then return; end if;
  update rpg_chefes set premiado = true, status = 'vencido' where id = _id;
  for d in select * from rpg_chefe_dano where chefe_id = _id and dano > 0 order by dano desc loop
    k := k + 1; n := n + 1;
    perform public.rpg_premiar(d.user_id, (c->>'moedas')::int + coalesce((c->'top_moedas'->>(k - 1))::int, 0), c->'itens');
    perform public.equip_drop(d.user_id, 'chefe');   -- arquivo 103
  end loop;
  select name into nome from pokemon where id = ch.especie;
  insert into event_log(kind, message) values ('chefe', '🎉 O ' || nome || ' gigante foi derrotado! Os ' || n || ' treinadores que lutaram ganharam o prêmio, e os 3 que mais bateram levaram um extra.');
end $$;

create or replace function public.treino_after(_bid uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.treino_cfg(); b battles; t jsonb; m monsters; won boolean; ganho int := 0; hp_fim int; lv2 int; res jsonb; me0 jsonb; wi jsonb; cx int := 0; csp int;
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
      if public.heroi(b.p1) = 'domador' then ganho := ceil(ganho * (100 + (public.herois_cfg()->>'domador_grama_xp_pct')::numeric) / 100)::int; end if;   -- Domador: +XP
      ganho := ceil(ganho * (100 + public.vb(b.p1, 'academia', 'grama_xp_pct')) / 100)::int;   -- arquivo 82: Academia da vila
      ganho := ceil(ganho * (100 + public.eq_bonus(b.p1, 'calca')) / 100)::int;   -- arquivo 103: Calça
      perform public.pk_give_xp(m.id, ganho, 'treino');
      -- acompanhante (arquivo 63): ganha uma parte da experiência, como o Exp. Share
      if (t->>'comp') is not null then
        select species_id into csp from monsters where id = (t->>'comp')::uuid and user_id = b.p1;
        if csp is not null then
          cx := greatest(1, floor(ganho * case when public.heroi(b.p1) = 'pesquisador' then (public.herois_cfg()->>'pesq_comp_pct')::numeric else coalesce((c->>'acompanhante_pct')::numeric, 50) end / 100))::int;   -- Pesquisador: acompanhante ganha mais
          perform public.pk_give_xp((t->>'comp')::uuid, cx, 'treino');
        end if;
      end if;
    end if;
    select level into lv2 from monsters where id = m.id;
  end if;
  insert into treino_dias(user_id, dia) values (b.p1, public.game_today()) on conflict do nothing;
  update treino_dias set lutas = lutas + 1, vitorias = vitorias + won::int, xp = treino_dias.xp + ganho where user_id = b.p1 and dia = public.game_today();
  if hp_fim = 0 then
    b.log := b.log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt',
      (me0->>'name') || ' desmaiou! Leve ao Centro Pokémon ou espere ' || (c->>'gratis_horas') || ' horas para ele se recuperar de graça.'))));
  end if;
  res := jsonb_build_object('won', won, 'xp', ganho, 'comp_xp', cx, 'comp_species', csp, 'forte', (t->>'forte')::boolean, 'wild', (wi->>'species')::int, 'wild_level', (wi->>'level')::int,
    'species', m.species_id, 'level_from', m.level, 'level_to', coalesce(lv2, m.level), 'hp', hp_fim, 'desmaiou', hp_fim = 0,
    'fugiu', b.end_reason = 'desistencia');
  insert into treino_lutas(user_id, mon_id, species, wild, wild_level, won, xp, level_from, level_to, log)
  values (b.p1, m.id, coalesce(m.species_id, (me0->>'species')::int), (wi->>'species')::int, (wi->>'level')::int, won, ganho, coalesce(m.level, 1), coalesce(lv2, m.level, 1), b.log);
  delete from treino_lutas where user_id = b.p1 and id not in (select id from treino_lutas where user_id = b.p1 order by id desc limit (c->>'lutas_guardadas')::int);
  update battles set log = b.log, state = jsonb_set(state, '{treino}', t || jsonb_build_object('feito', true, 'res', res)) where id = b.id;
  return res;
end $$;

create or replace function public.encounter_throw(_id uuid, _ball text default 'poke') returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); e encounters; p pokemon; b jsonb := public.pk_cfg()->'capture'->'balls'->_ball;
  r1 int; f int; caught boolean; shakes int; m monsters; have int;
begin
  if b is null then raise exception 'Bola inválida.'; end if;
  select * into e from encounters where id = _id and user_id = uid for update;
  if e.id is null then raise exception 'Encontro não encontrado.'; end if;
  if e.status <> 'aberto' then raise exception 'Esse encontro já terminou.'; end if;
  if (b->>'price')::int > 0 then
    select qty into have from bag_items where user_id = uid and item = _ball || '_ball' for update;
    if coalesce(have, 0) < 1 then raise exception 'Você não tem %.', b->>'name'; end if;
    update bag_items set qty = qty - 1 where user_id = uid and item = _ball || '_ball';
  end if;
  select * into p from pokemon where id = e.species_id;
  r1 := floor(random() * ((b->>'range')::int + 1));
  f := least(255, floor(255 * 4 / (b->>'factor')::numeric))::int;
  caught := r1 <= floor(p.catch_rate * case when public.heroi(uid) = 'arqueiro' then (100 + (public.herois_cfg()->>'arqueiro_captura_pct')::numeric) / 100 else 1 end
                       * (100 + public.vb(uid, 'pomar', 'captura_pct') + public.eq_bonus(uid, 'luvas')) / 100) and floor(random() * 256) <= f;   -- arquivo 103: Luvas   -- Arqueiro: mais captura
  if caught then
    m := public.pk_new_monster(uid, e.species_id, e.level);
    update encounters set status = 'capturado', throws_left = throws_left - 1, mon_id = m.id, resolved_at = now() where id = e.id;
    insert into event_log(user_id, kind, message) select uid, 'captura', ch.name || ' capturou um ' || p.name || ' (Nv ' || e.level || ')!' from characters ch where ch.user_id = uid;
    if e.hunt_id is not null then perform public.hunt_finish(e.hunt_id, true); end if;
    return jsonb_build_object('caught', true, 'shakes', 3, 'monster', to_jsonb(m), 'throws_left', e.throws_left - 1);
  end if;
  shakes := case when r1 > p.catch_rate then 0 else 1 + floor(random() * 2)::int end;
  update encounters set throws_left = throws_left - 1,
         status = case when throws_left - 1 <= 0 then 'fugiu' else status end,
         resolved_at = case when throws_left - 1 <= 0 then now() end
   where id = e.id returning * into e;
  if e.status = 'fugiu' and e.hunt_id is not null then perform public.hunt_finish(e.hunt_id, false); end if;
  return jsonb_build_object('caught', false, 'shakes', shakes, 'throws_left', e.throws_left, 'fled', e.status = 'fugiu');
end $$;

create or replace function public.walk(_cid uuid, _steps int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare ch characters; n board_nodes; cur int; p int[]; sal int := 0; c jsonb := cfg(); i int;
begin
  select * into ch from characters where id = _cid;
  cur := ch.node; p := ch.path;
  for i in 1..greatest(_steps,0) loop
    select * into n from board_nodes where id = cur;
    exit when n.kind = 'castelo' or n.next_a is null;
    cur := case when n.next_b is not null and ch.route->>(n.id::text) = 'b' then n.next_b else n.next_a end;
    p := p || cur;
    if (select kind from board_nodes where id = cur) = 'pagamento' then
      sal := sal + (c->>'salary_base')::int + (c->>'salary_per_level')::int * ch.level;
    end if;
  end loop;
  -- Taverna aumenta o salário
  if sal > 0 and exists (select 1 from villages where user_id = ch.user_id and tavern_level > 0) then
    sal := ceil(sal * (100 + coalesce((c->>'tavern_pct')::int, 15)) / 100.0)::int;
  end if;
  -- Mercador (arquivo 67): salário maior
  if sal > 0 and ch.class::text = 'mercador' then sal := ceil(sal * (100 + (public.herois_cfg()->>'merc_salario_pct')::numeric) / 100.0)::int; end if;
  -- arquivo 82: a Mina da vila aumenta o salário
  if sal > 0 then sal := ceil(sal * (100 + public.vb(ch.user_id, 'mina', 'salario_pct') + public.eq_bonus(ch.user_id, 'capacete')) / 100.0)::int; end if;   -- arquivo 103: Capacete
  -- Snorlax da rodada recebe menos no Dia de pagamento
  if sal > 0 and ch.user_id = public.snorlax_id() then
    sal := floor(sal * coalesce((c->>'snorlax_salary_pct')::int, 90) / 100.0)::int;
  end if;
  update characters set node = cur, path = p, coins = coins + sal where id = _cid;
  return jsonb_build_object('node', cur, 'salary', sal);
end $$;

create or replace function public.do_move(_d date, _recovery boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := auth.uid(); c jsonb := public.cfg(); today date := public.game_today();
  me characters; other characters; nd board_nodes; tr traps; w jsonb; x record;
  m public.puzzle_mode; s guess_sessions; st int; modes jsonb := '{}'::jsonb;
  base int := 0; roll int; r2 int; i int; bonus int; skill_steps int := 0; vcasas int := 0; total int; from_node int; landed int; path0 int;
  ev jsonb := '[]'::jsonb; sal int := 0; extra_coins int := 0; extra_xp int := 0; cls text; sv int; skill_on boolean; dodge boolean := false;
  card int; chance int; steal int; my_dist int; tmp_node int; tmp_path int[]; msg text; amt int;
  xp_gain int; coin_gain int; new_level int; old_level int;
  leader uuid; prop properties; toll int; bounty int := coalesce((public.cfg()->>'bounty_coins')::int, 60);
  boss world_bosses; mud int; passed int[]; tn int; champ uuid; hx jsonb; hh hunts; he hunt_entries; hgo int;
begin
  perform public.settle();
  leader := public.leader_id(); champ := public.round_champion();
  select * into me from characters where user_id = uid for update;
  if me.id is null then raise exception 'Crie seu personagem primeiro.'; end if;
  if exists (select 1 from daily_moves where user_id = uid and move_date = _d) then raise exception 'Você já andou nesse dia.'; end if;
  old_level := me.level; cls := me.class::text;
  skill_on := not _recovery and me.skill_date = today;
  sv := public.skill_value(cls, me.level);

  foreach m in array enum_range(null::public.puzzle_mode) loop
    s := null;
    select * into s from guess_sessions where user_id = uid and puzzle_date = _d and mode = m;
    st := public.mode_steps(coalesce(s.attempts,0), coalesce(s.solved,false));
    base := base + st;
    modes := modes || jsonb_build_object(m::text, jsonb_build_object('attempts', coalesce(s.attempts,0), 'solved', coalesce(s.solved,false), 'steps', st));
  end loop;

  roll := (c->>'roll_min')::int + floor(random() * ((c->>'roll_max')::int - (c->>'roll_min')::int + 1))::int;
  if skill_on and cls = 'arqueiro' then   -- Tiro certeiro (arquivo 67): a roleta vale o máximo
    roll := (c->>'roll_max')::int;
    ev := ev || jsonb_build_object('t','habilidade','msg','Tiro certeiro: a roleta ficou no máximo (' || roll || ').');
  end if;
  if cls = 'arqueiro' and roll < (c->>'arqueiro_min_die')::int then
    roll := (c->>'arqueiro_min_die')::int;
    ev := ev || jsonb_build_object('t','arqueiro','msg','Olho de arqueiro: a roleta vale no mínimo ' || roll || '.');
  end if;
  if skill_on and cls = 'domador' then
    roll := roll * greatest(sv,2);
    ev := ev || jsonb_build_object('t','habilidade','msg','Montaria: a roleta valeu ' || greatest(sv,2) || ' vezes mais (' || roll || ').');
  end if;
  if skill_on and cls in ('guerreiro','ladino','clerigo','pesquisador','mercador') and sv > 0 then
    skill_steps := sv;
    ev := ev || jsonb_build_object('t','habilidade','msg',
      case cls when 'guerreiro' then 'Investida' when 'ladino' then 'Atalho' when 'pesquisador' then 'Isca de frutas' when 'mercador' then 'Negócio da China' else 'Bênção' end || ': +' || sv || ' casas.');
  end if;
  if skill_on and cls = 'mago' then
    skill_steps := public.next_good_steps(me.id, sv);
    ev := ev || jsonb_build_object('t','habilidade','msg', case when skill_steps > 0 then 'Teleporte: saltou ' || skill_steps || ' casas até uma casa especial.' else 'Teleporte: nenhuma casa especial ao alcance.' end);
  end if;
  if skill_on and cls = 'ladino' then dodge := true; end if;
  if skill_on and cls = 'clerigo' then ev := ev || jsonb_build_object('t','habilidade','msg','Bênção ativa: nada te empurra para trás hoje.'); end if;

  bonus := me.bonus_steps;
  total := base + roll + bonus + skill_steps;
  -- arquivo 82: o Centro da Vila dá casas extras na andada
  vcasas := public.vb(uid, 'centro', 'casas')::int;
  if vcasas > 0 then total := total + vcasas; ev := ev || jsonb_build_object('t', 'vila', 'msg', '🏰 Centro da Vila: +' || vcasas || case when vcasas = 1 then ' casa.' else ' casas.' end); end if;
  -- lama da catapulta de um rival
  mud := coalesce(me.pending_mud, 0);
  if mud > 0 and not _recovery then
    update characters set pending_mud = 0 where id = me.id;
    if public.is_shielded(me.id) then
      ev := ev || jsonb_build_object('t','lama','msg','Atiraram lama em você, mas a Bênção te protegeu.');
    else
      total := greatest(0, total - mud);
      ev := ev || jsonb_build_object('t','lama','msg','Lama da catapulta: você perdeu ' || mud || ' casas nesta andada.');
    end if;
  end if;
  from_node := me.node;

  if me.arrived_rank is null and public.liga_mapa_parado() then   -- arquivo 73: durante a Liga ninguém anda
    ev := ev || jsonb_build_object('t','castelo','msg','A corrida acabou e a Liga Pokémon está acontecendo: o mapa fica parado até a temporada nova. Seus acertos de hoje continuam valendo moedas, XP e a rodada do dia.');
    total := 0;
  elsif me.arrived_rank is not null then
    ev := ev || jsonb_build_object('t','castelo','msg','Você já está no Castelo. Continue jogando para ganhar moedas, XP e vencer rodadas.');
    total := 0;
  else
    update characters set bonus_steps = 0 where id = me.id;
    -- Caçada (arquivo 48): quem escolheu ir atrás do Pokémon vai para o começo do caminho dela;
    -- quem escolheu o jogo (ou não escolheu) segue a corrida normal
    select * into hh from hunts where status in ('ativa', 'tentando') order by id desc limit 1;
    if hh.id is not null then
      select * into he from hunt_entries where hunt_id = hh.id and user_id = uid;
      if coalesce(he.go, false) and not he.done and hh.status = 'ativa' and not (me.node = any(hh.node_ids)) then
        update hunt_entries set origin_node = me.node, origin_len = coalesce(array_length(me.path, 1), 1) where hunt_id = hh.id and user_id = uid;
        update characters set node = hh.fork_node, path = path || hh.fork_node,
               route = coalesce(route, '{}'::jsonb) || jsonb_build_object(hh.fork_node::text, 'b') where id = me.id;
        hgo := hh.fork_node;
        ev := ev || jsonb_build_object('t', 'cacada', 'msg', '🎯 Você foi atrás do Pokémon misterioso! Suas andadas agora são pelo caminho da Caçada. Pegando ou não o Pokémon, você volta para a casa onde estava.');
      elsif not coalesce(he.go, false) or he.done then
        update characters set route = coalesce(route, '{}'::jsonb) - hh.fork_node::text where id = me.id and route ? hh.fork_node::text;
      end if;
      select * into me from characters where id = me.id;
    end if;
    path0 := coalesce(array_length(me.path,1),1);
    w := public.walk(me.id, total);
    sal := sal + (w->>'salary')::int;
    landed := (w->>'node')::int;

    -- atalhos das HMs (arquivo 47): Cut, Surf, Strength e Flash nas casas com obstáculo; Fly de tempos em tempos
    hx := public.hm_shortcut(me.id, path0);
    ev := ev || coalesce(hx->'ev', '[]'::jsonb);
    if coalesce((hx->>'steps')::int, 0) > 0 then
      w := public.walk(me.id, (hx->>'steps')::int); sal := sal + (w->>'salary')::int;
      landed := (w->>'node')::int;
    end if;

    -- encontro com o lendário (passando ou parando)
    select * into boss from world_bosses where status = 'ativo' order by id desc limit 1;
    if boss.id is not null then
      passed := (select path from characters where id = me.id)[path0 : coalesce(array_length((select path from characters where id = me.id),1),1)];
      if boss.node = any(passed) and not exists (select 1 from boss_contacts bc where bc.boss_id = boss.id and bc.user_id = uid) then
        insert into boss_contacts(boss_id, user_id) values (boss.id, uid);
        ev := ev || jsonb_build_object('t','lendario','msg','Você encontrou o lendário ' || (select name from pokemon where id = boss.pokemon_id) || '! Agora pode atacá-lo pelo painel.');
      end if;
    end if;

    -- Treinadores no caminho (arquivo 70): passou pela casa, tem que batalhar (quem para nela luta pelo house_extra)
    if coalesce((public.casas_cfg()->>'passar_luta')::boolean, true) then
      for tn in select p.id from unnest((select path from characters where id = me.id)[path0 + 1 : coalesce(array_length((select path from characters where id = me.id),1),1) - 1]) with ordinality p(id, o)
                 join board_nodes b on b.id = p.id where b.kind = 'treinador' order by p.o loop
        w := public.npc_fight(me.id, tn);
        ev := ev || coalesce(w->'ev', '[]'::jsonb); extra_coins := extra_coins + coalesce((w->>'coins')::int, 0);
      end loop;
    end if;

    -- Ladino: pega moedas de quem ultrapassa
    if cls = 'ladino' then
      amt := public.passive_value('ladino', me.level);
      for x in
        select ch.id, ch.name, ch.coins from characters ch
        where ch.user_id <> uid and ch.arrived_rank is null
          and ch.node = any ((select path from characters where id = me.id)[path0 + 1 : coalesce(array_length((select path from characters where id = me.id),1),1) - 1])
        for update
      loop
        steal := least(amt, x.coins);
        if steal > 0 then
          update characters set coins = coins - steal where id = x.id;
          extra_coins := extra_coins + steal;
          ev := ev || jsonb_build_object('t','ladino','msg','Mão leve: pegou ' || steal || ' moedas de ' || x.name || ' ao passar.');
        end if;
      end loop;
    end if;

    -- 1) armadilha de outro jogador
    select * into tr from traps where node = landed and triggered_at is null and owner_id <> uid for update;
    if tr.id is not null then
      update traps set triggered_by = uid, triggered_at = now() where id = tr.id;
      select * into other from characters where user_id = tr.owner_id;
      if dodge then
        ev := ev || jsonb_build_object('t','armadilha','msg','Atalho: você desviou da armadilha de ' || other.name || '.');
      elsif cls = 'mago' and random() * 100 < (c->>'mago_resist_pct')::int then
        ev := ev || jsonb_build_object('t','armadilha','msg','Você desfez com magia a armadilha de ' || other.name || '.');
      elsif public.is_shielded(me.id) then
        ev := ev || jsonb_build_object('t','armadilha','msg','A Bênção te protegeu da armadilha de ' || other.name || '.');
      else
        perform public.go_back(me.id, (c->>'trap_push')::int);
        update characters set coins = coins + (c->>'trap_reward')::int where user_id = tr.owner_id;
        ev := ev || jsonb_build_object('t','armadilha','msg','Você caiu na armadilha de ' || other.name || ' e voltou ' || (c->>'trap_push') || ' casas.');
        insert into event_log(user_id, kind, message) values (uid, 'armadilha', me.name || ' caiu na armadilha de ' || other.name || '.');
      end if;
    else
      -- 2) efeito da casa
      select * into nd from board_nodes where id = landed;
      if nd.kind = 'avanco' then
        w := public.walk(me.id, nd.value); sal := sal + (w->>'salary')::int;
        ev := ev || jsonb_build_object('t','avanco','msg','Vento a favor! Avançou mais ' || nd.value || ' casas.');
      elsif nd.kind = 'recuo' then
        if dodge then ev := ev || jsonb_build_object('t','recuo','msg','Atalho: você contornou o lamaçal.');
        elsif public.is_shielded(me.id) then ev := ev || jsonb_build_object('t','recuo','msg','A Bênção te segurou no lamaçal.');
        elsif cls = 'mago' and random() * 100 < (c->>'mago_resist_pct')::int then ev := ev || jsonb_build_object('t','recuo','msg','Escorregou, mas a magia segurou você no lugar.');
        else perform public.go_back(me.id, nd.value); ev := ev || jsonb_build_object('t','recuo','msg','Lamaçal! Voltou ' || nd.value || ' casas.');
        end if;
      elsif nd.kind = 'bau' then
        extra_coins := extra_coins + ceil((c->>'chest_coins')::int * case when skill_on and cls = 'mercador' then 2 else 1 end * (100 + public.eq_bonus(uid, 'capacete')) / 100.0)::int;   -- arquivo 103: Capacete
        ev := ev || jsonb_build_object('t','bau','msg','Achou um baú com ' || ceil((c->>'chest_coins')::int * case when skill_on and cls = 'mercador' then 2 else 1 end * (100 + public.eq_bonus(uid, 'capacete')) / 100.0)::int || ' moedas.' || case when skill_on and cls = 'mercador' then ' (Negócio da China: em dobro!)' else '' end);
        hx := public.item_drop(uid, 'bau');
        if hx is not null then ev := ev || hx; end if;
        hx := public.hm_drop(uid, 'bau');
        if hx is not null then ev := ev || hx; end if;
      elsif nd.kind = 'xp' then
        extra_xp := extra_xp + (c->>'xp_square')::int;
        ev := ev || jsonb_build_object('t','xp','msg','Treino na clareira: +' || (c->>'xp_square') || ' XP.');
      elsif nd.kind = 'pagamento' then
        ev := ev || jsonb_build_object('t','pagamento','msg','Parou no Dia de pagamento.');
      elsif nd.kind = 'carta' then
        card := floor(random() * 6)::int;
        if card = 0 then
          extra_coins := extra_coins + (c->>'card_coins_win')::int;
          ev := ev || jsonb_build_object('t','carta','msg','Carta da sorte: um treinador agradecido te deu ' || (c->>'card_coins_win') || ' moedas.');
        elsif card = 1 then
          amt := (c->>'card_coins_lose')::int; if cls = 'clerigo' then amt := ceil(amt / 2.0); end if;
          extra_coins := extra_coins - amt;
          ev := ev || jsonb_build_object('t','carta','msg','Carta do azar: sua mochila rasgou e você perdeu ' || amt || ' moedas.');
        elsif card = 2 then
          w := public.walk(me.id, (c->>'card_steps')::int); sal := sal + (w->>'salary')::int;
          ev := ev || jsonb_build_object('t','carta','msg','Carta da sorte: atalho secreto! Avançou ' || (c->>'card_steps') || ' casas.');
        elsif card = 3 then
          amt := (c->>'card_steps')::int; if cls = 'clerigo' then amt := ceil(amt / 2.0); end if;
          if public.is_shielded(me.id) then ev := ev || jsonb_build_object('t','carta','msg','Carta do azar: você ia se perder, mas a Bênção te guiou.');
          else perform public.go_back(me.id, amt); ev := ev || jsonb_build_object('t','carta','msg','Carta do azar: você se perdeu e voltou ' || amt || ' casas.');
          end if;
        elsif card = 4 then
          update characters set hints = hints + 1 where id = me.id;
          ev := ev || jsonb_build_object('t','carta','msg','Carta da sorte: ganhou 1 Dica.');
        else
          update characters set retries = retries + 1 where id = me.id;
          ev := ev || jsonb_build_object('t','carta','msg','Carta da sorte: ganhou 1 Tente outra vez.');
        end if;
      elsif nd.kind = 'raio' then
        select ch.* into other from characters ch join board_nodes b on b.id = ch.node
         where ch.arrived_rank is null and ch.user_id <> uid order by b.dist asc limit 1 for update of ch;
        my_dist := (select dist from board_nodes where id = landed);
        if other.id is null or (select dist from board_nodes where id = other.node) >= my_dist then
          ev := ev || jsonb_build_object('t','raio','msg','A tempestade caiu longe: ninguém está à sua frente.');
        elsif public.is_shielded(other.id) then
          ev := ev || jsonb_build_object('t','raio','msg','Você chamou um raio em ' || other.name || ', mas a Bênção dele o protegeu.');
        elsif other.class::text = 'mago' and random() * 100 < (c->>'mago_resist_pct')::int then
          ev := ev || jsonb_build_object('t','raio','msg','Você chamou um raio em ' || other.name || ', mas a magia dele desviou.');
        else
          perform public.go_back(other.id, (c->>'storm_push')::int);
          ev := ev || jsonb_build_object('t','raio','msg','Você chamou um raio no líder ' || other.name || ': ele voltou ' || (c->>'storm_push') || ' casas.');
          insert into event_log(user_id, kind, message) values (uid, 'raio', me.name || ' derrubou um raio no líder ' || other.name || '.');
          if other.user_id = leader then
            extra_coins := extra_coins + bounty;
            ev := ev || jsonb_build_object('t','procurado','msg','Recompensa: você acertou o procurado e ganhou ' || bounty || ' moedas.');
          end if;
        end if;
      elsif nd.kind = 'troca' then
        my_dist := (select dist from board_nodes where id = landed);
        select ch.* into other from characters ch join board_nodes b on b.id = ch.node
         where ch.arrived_rank is null and ch.user_id <> uid and b.dist < my_dist order by b.dist desc limit 1 for update of ch;
        if other.id is not null and public.is_shielded(other.id) then
          ev := ev || jsonb_build_object('t','troca','msg','O portal tentou te trocar com ' || other.name || ', mas a Bênção dele impediu.');
        elsif other.id is not null then
          select node, path into tmp_node, tmp_path from characters where id = me.id;
          update characters set node = other.node, path = other.path where id = me.id;
          update characters set node = tmp_node, path = tmp_path where id = other.id;
          ev := ev || jsonb_build_object('t','troca','msg','Portal! Você trocou de lugar com ' || other.name || '.');
          insert into event_log(user_id, kind, message) values (uid, 'troca', me.name || ' trocou de lugar com ' || other.name || ' pelo portal.');
        else
          ev := ev || jsonb_build_object('t','troca','msg','O portal não encontrou ninguém à sua frente.');
        end if;
      elsif nd.kind in ('mina', 'desafio', 'ladrao', 'fonte', 'treinador', 'alvo') then
        -- casas novas (arquivo 42) e treinadores (arquivo 43)
        hx := public.house_extra(me.id, nd.kind, modes, dodge);
        ev := ev || coalesce(hx->'ev', '[]'::jsonb);
        extra_coins := extra_coins + coalesce((hx->>'coins')::int, 0);
        extra_xp := extra_xp + coalesce((hx->>'xp')::int, 0);
        sal := sal + coalesce((hx->>'sal')::int, 0);
      end if;
    end if;

    -- 3) encontro na mesma casa vira duelo
    select * into me from characters where id = me.id;
    select ch.* into other from characters ch join board_nodes b on b.id = ch.node
     where ch.user_id <> uid and ch.node = me.node and ch.arrived_rank is null and b.kind not in ('inicio','castelo')
       -- com o líder, só há encontro se o outro for o melhor da última rodada (se o líder for o melhor, nada acontece)
       and (leader is null or (ch.user_id <> leader and uid <> leader) or (champ is not null and champ <> leader and champ in (uid, ch.user_id)))
     order by random() limit 1 for update of ch;
    if other.id is not null then
      chance := 50 + (me.level - other.level) * (c->>'duel_level_factor')::int
                   + case when cls = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end
                   - case when other.class::text = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end;
      chance := chance
        + case when exists (select 1 from villages where user_id = uid and arena_level > 0) then coalesce((c->>'arena_bonus')::int, 10) else 0 end
        - case when exists (select 1 from villages where user_id = other.user_id and arena_level > 0) then coalesce((c->>'arena_bonus')::int, 10) else 0 end;
      chance := greatest(25, least(75, chance));
      if random() * 100 < chance then
        steal := least((c->>'duel_coins')::int, other.coins);
        update characters set coins = coins - steal where id = other.id;
        perform public.go_back(other.id, (c->>'duel_push')::int);
        extra_coins := extra_coins + steal;
        ev := ev || jsonb_build_object('t','duelo','msg','Encontro com ' || other.name || ': você venceu o duelo, ganhou ' || steal || ' moedas' || case when public.is_shielded(other.id) then '.' else ' e empurrou o rival.' end);
        if other.user_id = leader then
          extra_coins := extra_coins + bounty;
          ev := ev || jsonb_build_object('t','procurado','msg','Recompensa: você venceu o procurado e ganhou ' || bounty || ' moedas.');
        end if;
        insert into event_log(user_id, kind, message) values (uid, 'duelo', me.name || ' venceu um duelo contra ' || other.name || '.');
      else
        steal := least((c->>'duel_coins')::int, greatest(0, me.coins + extra_coins));
        update characters set coins = coins + steal where id = other.id;
        extra_coins := extra_coins - steal;
        perform public.go_back(me.id, (c->>'duel_push')::int);
        ev := ev || jsonb_build_object('t','duelo','msg','Encontro com ' || other.name || ': você perdeu o duelo e ' || steal || ' moedas' || case when public.is_shielded(me.id) then ', mas a Bênção te manteve no lugar.' else ' e voltou ' || (c->>'duel_push') || ' casas.' end);
        insert into event_log(user_id, kind, message) values (uid, 'duelo', other.name || ' defendeu sua casa contra ' || me.name || '.');
      end if;
    end if;

    -- 4) pedágio das pousadas de outros jogadores (arquivo 84: quem PASSA também paga, uma vez por pousada)
    select * into me from characters where id = me.id;
    for prop in select * from properties
                 where owner <> uid and (node = me.node or (coalesce((c->>'property_pedagio_passou')::boolean, true)
                       and node = any(coalesce(me.path[path0 + 1 : coalesce(array_length(me.path, 1), 1)], '{}'::int[]))))
                 order by node for update loop
      toll := greatest((c->>'property_min_toll')::int, ceil(prop.price * (c->>'property_toll_pct')::numeric / 100)::int);
      toll := least(toll, greatest(0, me.coins + extra_coins + base * (c->>'coins_per_step')::int));
      if toll > 0 then
        extra_coins := extra_coins - toll;
        update characters set coins = coins + toll where user_id = prop.owner;
        update properties set tolls_earned = tolls_earned + toll where node = prop.node;
        ev := ev || jsonb_build_object('t','pousada','msg','Pedágio na pousada de ' || (select name from characters where user_id = prop.owner) || ': -' || toll || ' moedas.');
        insert into event_log(user_id, kind, message) values (uid, 'pousada', me.name || ' pagou ' || toll || ' moedas de pedágio na pousada de ' || (select name from characters where user_id = prop.owner) || '.');
      end if;
    end loop;
    if sal > 0 then ev := ev || jsonb_build_object('t','pagamento','msg','Dia de pagamento: +' || sal || ' moedas de salário' ||
      case when uid = public.snorlax_id() then ' (10% a menos por ser o Snorlax da rodada).' else '.' end); end if;
    msg := public.check_arrival(me.id);
    if msg is not null then ev := ev || jsonb_build_object('t','castelo','msg', msg); end if;
  end if;

  xp_gain := base * (c->>'xp_per_step')::int + (c->>'xp_daily_bonus')::int + extra_xp;
  if (select xp_buff_until from characters where id = me.id) >= today then
    xp_gain := round(xp_gain * coalesce((c->>'boss_xp_mult')::numeric, 1.5))::int;
    ev := ev || jsonb_build_object('t','buff','msg','Bênção do lendário derrotado: XP aumentado.');
  end if;
  coin_gain := base * (c->>'coins_per_step')::int + extra_coins;
  select * into me from characters where id = me.id;
  new_level := public.level_for_xp(me.xp_total + xp_gain);
  if new_level > old_level then
    ev := ev || jsonb_build_object('t','nivel','msg','Subiu para o nível ' || new_level || '!');
    insert into event_log(user_id, kind, message) values (uid, 'nivel', me.name || ' chegou ao nível ' || new_level || '.');
  end if;
  update characters set xp_total = xp_total + xp_gain, level = new_level,
         coins = greatest(0, coins + coin_gain), last_move_date = greatest(coalesce(last_move_date, _d), _d)
   where id = me.id returning * into me;

  -- Mercador com a habilidade do dia: o salário dos Dias de pagamento vem em dobro
  if skill_on and cls = 'mercador' and sal > 0 then
    update characters set coins = coins + sal where id = me.id;
    ev := ev || jsonb_build_object('t','habilidade','msg','Negócio da China: o salário veio em dobro (+' || sal || ' moedas).');
    sal := sal * 2;
  end if;
  insert into daily_moves(user_id, move_date, modes, base_steps, roll, bonus_steps, skill_steps, from_node, to_node, xp_gained, coins_gained, events, recovered)
  values (uid, _d, modes, base, roll, bonus, skill_steps, from_node, me.node, xp_gain, coin_gain + sal, ev, _recovery);
  insert into event_log(user_id, kind, message, data)
  values (uid, 'andou', me.name || ' andou ' || total || ' casas' || case when _recovery then ' recuperando o dia ' || to_char(_d, 'DD/MM') else '' end || '.', jsonb_build_object('steps', total));

  return jsonb_build_object('date', _d, 'recovery', _recovery, 'base', base, 'roll', roll, 'bonus', bonus, 'skill', skill_steps, 'total', total, 'modes', modes,
    'from', from_node, 'to', me.node, 'path', to_jsonb(me.path), 'events', ev, 'hunt_go', hgo,
    'xp', xp_gain, 'coins', coin_gain + sal, 'level', new_level, 'leveled', new_level > old_level);
end $$;

create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'leilao', public.leilao_cfg(), 'herois', public.herois_cfg(), 'temporada', public.temporada_cfg(), 'liga', public.liga_cfg(), 'pausa', public.pausa_cfg(), 'teto', public.teto_cfg(), 'boas_vindas', public.boas_vindas_cfg(), 'vila_bonus', public.vila_bonus_cfg(), 'tm_nivel', public.tm_nivel_cfg(), 'quiz_auto', public.quiz_auto_cfg(), 'cartas', public.tcg_cfg(), 'pokebound', public.pokebound_cfg(), 'visual', public.visual_cfg(), 'praca', public.praca_cfg(), 'rpg', public.rpg_cfg(), 'equip', public.equip_cfg(), 'base', public.cfg());
end $$;

grant execute on function public.rpg_encontro(uuid, text, uuid), public.rpg_ginasio_lutar(text, uuid, uuid[]), public.rpg_chefe_lutar(uuid), public.encounter_throw(uuid, text) to authenticated;
revoke execute on function public.rpg_after(uuid), public.rpg_chefe_premiar(bigint) from public, anon, authenticated;
update public.game_config set config = jsonb_set(config, '{equip}', public.equip_cfg()) where active and not (config ? 'equip');

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🛡️ Equipamentos da Aventura: do +0 ao +9', 'Chegaram os Equipamentos do seu herói (botão 🛡️ Equipamentos, na Aventura):
• 5 peças, cada uma com o seu bônus: 🪖 Capacete (+moedas no Dia de Pagamento e nos baús), 🧤 Luvas (+chance de captura), 👖 Calça (+experiência por vitória na Aventura), 🥋 Peitoral (−dano recebido nas lutas da Aventura) e 👢 Botas (+chance de Pokémon raro no mato).
• Cada peça vai do +0 ao +9: o bônus cresce de 1% até 18%.
• 🍬 Doce de Forja: use para subir a peça. A chance cai a cada nível (100% no +1, 10% no +9). Até o +4, se falhar, só perde o doce; do +5 para cima, falhar faz a peça voltar 1 nível.
• Onde conseguir: o Doce cai às vezes ao vencer selvagens na Aventura (mais nos Ginásios e no Chefe). As peças são raríssimas nos bichos, ou custam 5.000 moedas na loja.
• Doces e peças podem ser vendidos e comprados entre jogadores, na feira dos Equipamentos.
• O Peitoral não vale nas batalhas entre jogadores: lá todo mundo fica igual.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
