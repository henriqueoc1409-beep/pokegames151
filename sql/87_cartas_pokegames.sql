-- =====================================================================
-- POKEGAMES — Cartas Pokegames (pedido do dono em 09/11/2026).
-- Jogo de cartas NOSSO (moldura, regras e números nossos; não é cópia do TCG oficial).
-- Só a 1ª geração (1 a 151). A imagem do Pokémon vem da PokeAPI, como no resto do jogo.
--  * tcg_cartas: 1 carta por espécie (PV, 2 ataques com o nome dos golpes do próprio
--    Pokémon, fraqueza, resistência e raridade), calculada dos dados do jogo.
--  * Coleção, pacotes de 5 (3 comuns, 1 incomum ou melhor, 1 rara ou melhor),
--    carta brilhante (1%), carta do dia ao andar, pacote pela vitória na rodada,
--    pelo Quiz, nos baús (às vezes), nos prêmios da temporada e na loja por moedas;
--    2 pacotes de boas-vindas. Repetidas: desmanchar em moedas ou vender no
--    Mercado de cartas (taxa de 5%).
--  * Duelo com energia: +1 por turno (até 5), ataque fraco custa 1, forte custa 3,
--    trocar custa 1; deck de 10 (no máximo 2 iguais), 1 em campo e 3 na mão;
--    vence quem derrubar 3. Contra jogador valendo moedas (10 a 100, como as
--    batalhas); contra o computador só treino, sem prêmio.
--  * Números em game_config.config.cartas (Ajustes do jogo → 🃏 Cartas).
-- Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

create or replace function public.tcg_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "pacote_preco": 300, "pacote_inicial": 2, "carta_dia": true, "pacote_rodada": 1, "pacote_quiz": 1, "pacote_temporada": 2, "bau_pct": 15,
    "chances": {"comum": 60, "incomum": 25, "rara": 12, "ultra": 3}, "brilhante_pct": 1, "brilhante_bonus": 10,
    "desmanchar": {"comum": 5, "incomum": 10, "rara": 25, "ultra": 60, "brilhante": 150},
    "deck": 10, "max_iguais": 2, "mao": 3, "nocautes": 3, "energia_max": 5, "custo_fraco": 1, "custo_forte": 3, "custo_trocar": 1, "turnos_max": 80,
    "aposta_min": 10, "aposta_max": 100, "taxa_venda_pct": 5}'::jsonb || coalesce(public.cfg()->'cartas', '{}'::jsonb)
$$;
update public.game_config set config = jsonb_set(config, '{cartas}', public.tcg_cfg()) where active and not (config ? 'cartas');

-- ---------- as cartas (1 por espécie da 1ª geração) ----------
create table if not exists public.tcg_cartas (
  species     int primary key references public.pokemon(id),
  nome        text not null,
  t1          text not null,
  t2          text,
  pv          int not null,
  raridade    text not null check (raridade in ('comum', 'incomum', 'rara', 'ultra')),
  fraco_nome  text not null,
  fraco_dano  int not null,
  forte_nome  text not null,
  forte_dano  int not null,
  fraqueza    text,
  resistencia text
);
insert into public.tcg_cartas (species, nome, t1, t2, pv, raridade, fraco_nome, fraco_dano, forte_nome, forte_dano, fraqueza, resistencia)
select p.id, p.name, p.g1_type1, nullif(p.g1_type2, p.g1_type1),
  least(300, greatest(30, round(p.base_hp * 1.5 / 10.0) * 10))::int,
  case when p.id in (144, 145, 146, 150, 151) then 'ultra' else case public.pk_rarity(p.catch_rate) when 'comum' then 'comum' when 'incomum' then 'incomum' when 'raro' then 'rara' else 'ultra' end end,
  coalesce((select m.name from pk_moves m where m.power > 0 and (m.id = any(p.start_moves) or m.id in (select move_id from pk_learnset l where l.species_id = p.id))
            order by (m.type = p.g1_type1) desc, (m.power >= 30) desc, m.power, m.id limit 1), 'Struggle'),
  greatest(10, round(greatest(p.base_atk, p.base_spc) * 0.35 / 10.0) * 10)::int,
  coalesce((select m.name from pk_moves m where m.power > 0 and (m.id = any(p.start_moves) or m.id in (select move_id from pk_learnset l where l.species_id = p.id))
            order by (m.name <> coalesce((select m2.name from pk_moves m2 where m2.power > 0 and (m2.id = any(p.start_moves) or m2.id in (select move_id from pk_learnset l2 where l2.species_id = p.id))
                                         order by (m2.type = p.g1_type1) desc, (m2.power >= 30) desc, m2.power, m2.id limit 1), '')) desc,
                     (m.type = p.g1_type1) desc, m.power desc, m.id limit 1), 'Struggle'),
  greatest(20, round(greatest(p.base_atk, p.base_spc) * 1.05 / 10.0) * 10)::int,
  (select tc.atk from pk_type_chart tc where tc.def = p.g1_type1 and tc.mult > 1 order by tc.atk limit 1),
  (select tc.atk from pk_type_chart tc where tc.def = p.g1_type1 and tc.mult < 1 order by tc.mult, tc.atk limit 1)
from public.pokemon p where p.id between 1 and 151
on conflict (species) do update set nome = excluded.nome, t1 = excluded.t1, t2 = excluded.t2, pv = excluded.pv, raridade = excluded.raridade,
  fraco_nome = excluded.fraco_nome, fraco_dano = excluded.fraco_dano, forte_nome = excluded.forte_nome, forte_dano = excluded.forte_dano,
  fraqueza = excluded.fraqueza, resistencia = excluded.resistencia;

-- ---------- coleção, saldo de pacotes, prêmios já dados, aberturas, deck ----------
create table if not exists public.tcg_colecao (
  user_id   uuid not null references auth.users(id) on delete cascade,
  species   int  not null references public.tcg_cartas(species),
  brilhante boolean not null default false,
  qtd       int  not null default 0 check (qtd >= 0),
  primeira  timestamptz not null default now(),
  primary key (user_id, species, brilhante)
);
create table if not exists public.tcg_saldo (
  user_id uuid primary key references auth.users(id) on delete cascade,
  pacotes int not null default 0 check (pacotes >= 0),
  desde   timestamptz not null default now()
);
create table if not exists public.tcg_premios (
  user_id uuid not null references auth.users(id) on delete cascade,
  ref     text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, ref)
);
create table if not exists public.tcg_aberturas (
  id      bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  origem  text not null,
  cartas  jsonb not null,
  visto   boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists public.tcg_decks (
  user_id uuid primary key references auth.users(id) on delete cascade,
  cartas  jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);
create table if not exists public.tcg_ofertas (
  id        bigserial primary key,
  seller    uuid not null references auth.users(id) on delete cascade,
  species   int not null references public.tcg_cartas(species),
  brilhante boolean not null default false,
  preco     int not null check (preco between 1 and 100000),
  status    text not null default 'aberta' check (status in ('aberta', 'vendida', 'cancelada')),
  buyer     uuid,
  created_at timestamptz not null default now(),
  closed_at timestamptz
);
create table if not exists public.tcg_duelos (
  id        bigserial primary key,
  p1        uuid not null references auth.users(id) on delete cascade,
  p2        uuid references auth.users(id) on delete cascade,
  treino    boolean not null default false,
  status    text not null default 'convite' check (status in ('convite', 'ativa', 'encerrada', 'recusada', 'cancelada')),
  aposta    int not null default 0,
  pago      boolean not null default false,   -- as apostas dos dois estão guardadas
  quitado   boolean not null default false,   -- o prêmio já foi pago
  state     jsonb,
  winner    uuid,
  motivo    text,
  created_at timestamptz not null default now(),
  turno_at  timestamptz,
  ended_at  timestamptz
);
create index if not exists tcg_duelos_p1 on public.tcg_duelos (p1, status);
create index if not exists tcg_duelos_p2 on public.tcg_duelos (p2, status);

alter table public.tcg_cartas enable row level security;
alter table public.tcg_colecao enable row level security;
alter table public.tcg_saldo enable row level security;
alter table public.tcg_premios enable row level security;
alter table public.tcg_aberturas enable row level security;
alter table public.tcg_decks enable row level security;
alter table public.tcg_ofertas enable row level security;
alter table public.tcg_duelos enable row level security;
drop policy if exists tcg_cartas_r on public.tcg_cartas;       create policy tcg_cartas_r on public.tcg_cartas for select to authenticated using (true);
drop policy if exists tcg_colecao_r on public.tcg_colecao;     create policy tcg_colecao_r on public.tcg_colecao for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists tcg_saldo_r on public.tcg_saldo;         create policy tcg_saldo_r on public.tcg_saldo for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists tcg_aberturas_r on public.tcg_aberturas; create policy tcg_aberturas_r on public.tcg_aberturas for select to authenticated using (user_id = auth.uid());
drop policy if exists tcg_decks_r on public.tcg_decks;         create policy tcg_decks_r on public.tcg_decks for select to authenticated using (user_id = auth.uid());
drop policy if exists tcg_ofertas_r on public.tcg_ofertas;     create policy tcg_ofertas_r on public.tcg_ofertas for select to authenticated using (true);
revoke all on public.tcg_cartas, public.tcg_colecao, public.tcg_saldo, public.tcg_premios, public.tcg_aberturas, public.tcg_decks, public.tcg_ofertas, public.tcg_duelos from anon, authenticated;
grant select on public.tcg_cartas, public.tcg_colecao, public.tcg_saldo, public.tcg_aberturas, public.tcg_decks, public.tcg_ofertas to authenticated;
-- tcg_duelos e tcg_premios: ninguém lê direto (a mão e o baralho do outro são segredo); o site usa as funções

-- ---------- sortear e dar cartas ----------
create or replace function public.tcg_sorteia(_min text default 'comum') returns jsonb
language plpgsql volatile security definer set search_path = public, extensions as $$
declare c jsonb := public.tcg_cfg(); ords text[] := array['comum', 'incomum', 'rara', 'ultra']; mi int := coalesce(array_position(ords, _min), 1);
  tot numeric := 0; x numeric; acc numeric := 0; r text; i int; sp int;
begin
  for i in mi .. 4 loop tot := tot + coalesce((c->'chances'->>ords[i])::numeric, 0); end loop;
  x := random() * greatest(tot, 0.0001); r := ords[4];
  for i in mi .. 4 loop acc := acc + coalesce((c->'chances'->>ords[i])::numeric, 0); if x < acc then r := ords[i]; exit; end if; end loop;
  select species into sp from tcg_cartas where raridade = r order by random() limit 1;
  if sp is null then select species into sp from tcg_cartas order by random() limit 1; end if;
  return jsonb_build_object('s', sp, 'b', random() * 100 < coalesce((c->>'brilhante_pct')::numeric, 1));
end $$;

-- põe as cartas na coleção e guarda a abertura (o site mostra a animação); devolve as cartas com "nova"
create or replace function public.tcg_dar(_uid uuid, _cartas jsonb, _origem text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare x jsonb; res jsonb := '[]'::jsonb; novo boolean;
begin
  for x in select * from jsonb_array_elements(_cartas) loop
    novo := not exists (select 1 from tcg_colecao where user_id = _uid and species = (x->>'s')::int and qtd > 0);
    insert into tcg_colecao(user_id, species, brilhante, qtd) values (_uid, (x->>'s')::int, coalesce((x->>'b')::boolean, false), 1)
      on conflict (user_id, species, brilhante) do update set qtd = tcg_colecao.qtd + 1;
    res := res || (x || jsonb_build_object('nova', novo));
  end loop;
  insert into tcg_aberturas(user_id, origem, cartas) values (_uid, _origem, res);
  return res;
end $$;

-- prêmios automáticos (carta do dia, rodada, Quiz, baús, temporada), só do que aconteceu depois de entrar nas Cartas
create or replace function public.tcg_tick(_uid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.tcg_cfg(); s tcg_saldo; r record; d date := public.game_today(); n int := 0;
begin
  if _uid is null or not coalesce((c->>'on')::boolean, true) then return; end if;
  if not exists (select 1 from characters where user_id = _uid) then return; end if;
  insert into tcg_saldo(user_id, pacotes) values (_uid, coalesce((c->>'pacote_inicial')::int, 2)) on conflict do nothing;
  select * into s from tcg_saldo where user_id = _uid for update;
  -- carta do dia: quem andou hoje
  if coalesce((c->>'carta_dia')::boolean, true) and exists (select 1 from daily_moves where user_id = _uid and move_date = d)
     and not exists (select 1 from tcg_premios where user_id = _uid and ref = 'dia:' || d) then
    insert into tcg_premios(user_id, ref) values (_uid, 'dia:' || d);
    perform public.tcg_dar(_uid, jsonb_build_array(public.tcg_sorteia('comum')), 'Carta do dia');
  end if;
  -- vitória na rodada do dia
  for r in select rr.d from round_results rr where rr.user_id = _uid and rr.rank = 1 and rr.d >= (s.desde at time zone 'America/Sao_Paulo')::date - 1
             and not exists (select 1 from tcg_premios p where p.user_id = _uid and p.ref = 'rodada:' || rr.d) loop
    insert into tcg_premios(user_id, ref) values (_uid, 'rodada:' || r.d); n := n + coalesce((c->>'pacote_rodada')::int, 1);
  end loop;
  -- Quiz vencido
  for r in select q.id from quizzes q where q.winner = _uid and coalesce(q.closed_at, q.closes_at) >= s.desde
             and not exists (select 1 from tcg_premios p where p.user_id = _uid and p.ref = 'quiz:' || q.id) loop
    insert into tcg_premios(user_id, ref) values (_uid, 'quiz:' || r.id); n := n + coalesce((c->>'pacote_quiz')::int, 1);
  end loop;
  -- prêmios da temporada
  for r in select a.id from season_awards a where a.user_id = _uid and a.created_at >= s.desde
             and not exists (select 1 from tcg_premios p where p.user_id = _uid and p.ref = 'temporada:' || a.id) loop
    insert into tcg_premios(user_id, ref) values (_uid, 'temporada:' || r.id); n := n + coalesce((c->>'pacote_temporada')::int, 2);
  end loop;
  -- baús achados no tabuleiro (às vezes vêm com um pacote)
  for r in select dm.id from daily_moves dm where dm.user_id = _uid and dm.created_at >= s.desde and dm.events @> '[{"t": "bau"}]'
             and not exists (select 1 from tcg_premios p where p.user_id = _uid and p.ref = 'bau:' || dm.id) loop
    insert into tcg_premios(user_id, ref) values (_uid, 'bau:' || r.id);
    if random() * 100 < coalesce((c->>'bau_pct')::numeric, 15) then n := n + 1; end if;
  end loop;
  if n > 0 then update tcg_saldo set pacotes = pacotes + n where user_id = _uid; end if;
end $$;

create or replace function public.tcg_abrir_pacote() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); s tcg_saldo; cs jsonb;
begin
  perform public.tcg_tick(uid);
  select * into s from tcg_saldo where user_id = uid for update;
  if coalesce(s.pacotes, 0) < 1 then raise exception 'Você não tem pacote para abrir. Compre na loja das Cartas ou ganhe jogando.'; end if;
  update tcg_saldo set pacotes = pacotes - 1 where user_id = uid;
  cs := jsonb_build_array(public.tcg_sorteia('comum'), public.tcg_sorteia('comum'), public.tcg_sorteia('comum'), public.tcg_sorteia('incomum'), public.tcg_sorteia('rara'));
  cs := public.tcg_dar(uid, cs, 'Pacote');
  update tcg_aberturas set visto = true where id = (select max(id) from tcg_aberturas where user_id = uid);   -- o site já mostra a abertura
  return cs;
end $$;

create or replace function public.tcg_comprar_pacote(_qtd int default 1) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.tcg_cfg(); preco int; me characters;
begin
  if _qtd is null or _qtd < 1 or _qtd > 10 then raise exception 'Compre de 1 a 10 pacotes por vez.'; end if;
  preco := public.preco_heroi(uid, (c->>'pacote_preco')::int) * _qtd;   -- Mercador: desconto
  select * into me from characters where user_id = uid for update;
  if me.coins < preco then raise exception 'Custa % moedas e você tem %.', preco, me.coins; end if;
  perform public.tcg_tick(uid);
  update characters set coins = coins - preco where id = me.id;
  update tcg_saldo set pacotes = pacotes + _qtd where user_id = uid;
  return jsonb_build_object('pacotes', (select pacotes from tcg_saldo where user_id = uid), 'coins', me.coins - preco, 'preco', preco);
end $$;

-- quantas cópias de uma carta o deck usa
create or replace function public.tcg_no_deck(_uid uuid, _s int, _b boolean) returns int
language sql stable security definer set search_path = public, extensions as $$
  select count(*)::int from tcg_decks d, jsonb_array_elements(d.cartas) x
   where d.user_id = _uid and (x->>'s')::int = _s and coalesce((x->>'b')::boolean, false) = _b
$$;

create or replace function public.tcg_deck_salvar(_cartas jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.tcg_cfg(); r record;
begin
  if jsonb_typeof(_cartas) <> 'array' or jsonb_array_length(_cartas) <> (c->>'deck')::int then
    raise exception 'O deck precisa ter exatamente % cartas.', c->>'deck'; end if;
  for r in select (x->>'s')::int s, coalesce((x->>'b')::boolean, false) b, count(*) n from jsonb_array_elements(_cartas) x group by 1, 2 loop
    if coalesce((select qtd from tcg_colecao where user_id = uid and species = r.s and brilhante = r.b), 0) < r.n then
      raise exception 'Você não tem % cópia(s) de %.', r.n, (select nome from tcg_cartas where species = r.s); end if;
  end loop;
  for r in select (x->>'s')::int s, count(*) n from jsonb_array_elements(_cartas) x group by 1 loop
    if r.n > (c->>'max_iguais')::int then raise exception 'No máximo % cartas iguais no deck (% está com %).', c->>'max_iguais', (select nome from tcg_cartas where species = r.s), r.n; end if;
  end loop;
  insert into tcg_decks(user_id, cartas, updated_at) values (uid, (select jsonb_agg(jsonb_build_object('s', (x->>'s')::int, 'b', coalesce((x->>'b')::boolean, false))) from jsonb_array_elements(_cartas) x), now())
    on conflict (user_id) do update set cartas = excluded.cartas, updated_at = now();
  return (select cartas from tcg_decks where user_id = uid);
end $$;

-- desmanchar repetidas em moedas (fica pelo menos 1 e as que o deck usa)
create or replace function public.tcg_desmanchar(_s int, _b boolean, _qtd int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.tcg_cfg(); have int; val int; rar text;
begin
  if _qtd is null or _qtd < 1 then raise exception 'Quantidade inválida.'; end if;
  select qtd into have from tcg_colecao where user_id = uid and species = _s and brilhante = coalesce(_b, false) for update;
  if coalesce(have, 0) - _qtd < greatest(1, public.tcg_no_deck(uid, _s, coalesce(_b, false))) then
    raise exception 'Só dá para desmanchar as repetidas: fica pelo menos 1 e as que estão no seu deck.'; end if;
  select raridade into rar from tcg_cartas where species = _s;
  val := case when _b then (c->'desmanchar'->>'brilhante')::int else (c->'desmanchar'->>rar)::int end * _qtd;
  update tcg_colecao set qtd = qtd - _qtd where user_id = uid and species = _s and brilhante = coalesce(_b, false);
  update characters set coins = coins + val where user_id = uid;
  return jsonb_build_object('moedas', val);
end $$;

-- ---------- Mercado de cartas ----------
create or replace function public.tcg_ofertar(_s int, _b boolean, _preco int) returns public.tcg_ofertas
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); have int; o tcg_ofertas;
begin
  if _preco is null or _preco < 1 or _preco > 100000 then raise exception 'Preço de 1 a 100.000 moedas.'; end if;
  select qtd into have from tcg_colecao where user_id = uid and species = _s and brilhante = coalesce(_b, false) for update;
  if coalesce(have, 0) - 1 < public.tcg_no_deck(uid, _s, coalesce(_b, false)) or coalesce(have, 0) < 1 then
    raise exception 'Você não tem essa carta sobrando (as do deck ficam).'; end if;
  if (select count(*) from tcg_ofertas where seller = uid and status = 'aberta') >= 10 then raise exception 'No máximo 10 cartas à venda ao mesmo tempo.'; end if;
  update tcg_colecao set qtd = qtd - 1 where user_id = uid and species = _s and brilhante = coalesce(_b, false);
  insert into tcg_ofertas(seller, species, brilhante, preco) values (uid, _s, coalesce(_b, false), _preco) returning * into o;
  return o;
end $$;
create or replace function public.tcg_oferta_cancelar(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); o tcg_ofertas;
begin
  select * into o from tcg_ofertas where id = _id for update;
  if o.id is null or o.seller <> uid or o.status <> 'aberta' then raise exception 'Oferta não encontrada.'; end if;
  update tcg_ofertas set status = 'cancelada', closed_at = now() where id = o.id;
  insert into tcg_colecao(user_id, species, brilhante, qtd) values (uid, o.species, o.brilhante, 1)
    on conflict (user_id, species, brilhante) do update set qtd = tcg_colecao.qtd + 1;
end $$;
create or replace function public.tcg_oferta_comprar(_id bigint) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); o tcg_ofertas; me characters; taxa int; c jsonb := public.tcg_cfg();
begin
  select * into o from tcg_ofertas where id = _id for update;
  if o.id is null or o.status <> 'aberta' then raise exception 'Essa carta já foi vendida.'; end if;
  if o.seller = uid then raise exception 'Essa carta é sua.'; end if;
  select * into me from characters where user_id = uid for update;
  if me.coins < o.preco then raise exception 'Custa % moedas e você tem %.', o.preco, me.coins; end if;
  taxa := ceil(o.preco * coalesce((c->>'taxa_venda_pct')::numeric, 5) / 100)::int;
  update characters set coins = coins - o.preco where id = me.id;
  update characters set coins = coins + o.preco - taxa where user_id = o.seller;
  update tcg_ofertas set status = 'vendida', buyer = uid, closed_at = now() where id = o.id;
  perform public.tcg_dar(uid, jsonb_build_array(jsonb_build_object('s', o.species, 'b', o.brilhante)), 'Mercado de cartas');
  update tcg_aberturas set visto = true where user_id = uid and not visto and origem = 'Mercado de cartas';
  insert into event_log(user_id, kind, message) select uid, 'cartas', me.name || ' comprou a carta ' || t.nome || case when o.brilhante then ' ✨' else '' end || ' de ' || ch.name || ' por ' || o.preco || ' moedas.'
    from tcg_cartas t, characters ch where t.species = o.species and ch.user_id = o.seller;
  return jsonb_build_object('coins', me.coins - o.preco);
end $$;

-- ---------- duelo de cartas ----------
-- carta em jogo (com o bônus da brilhante)
create or replace function public.tcg_inst(_s int, _b boolean) returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object('s', t.species, 'b', coalesce(_b, false), 'nome', t.nome, 't1', t.t1, 't2', t.t2, 'r', t.raridade,
    'pv', t.pv + k.bo, 'hp', t.pv + k.bo, 'fn', t.fraco_nome, 'fd', t.fraco_dano + k.bo, 'Fn', t.forte_nome, 'Fd', t.forte_dano + k.bo)
  from tcg_cartas t, (select case when coalesce(_b, false) then coalesce((public.tcg_cfg()->>'brilhante_bonus')::int, 10) else 0 end bo) k
  where t.species = _s
$$;

-- um lado da mesa: deck embaralhado, 1 em campo, mão e pilha (o do computador é sorteado)
create or replace function public.tcg_lado(_uid uuid, _cpu boolean default false) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.tcg_cfg(); cs jsonb; dk jsonb; r record; mao int := (c->>'mao')::int;
begin
  if _cpu then
    select jsonb_agg(jsonb_build_object('s', species, 'b', false)) into cs from (
      (select species from tcg_cartas where raridade in ('comum', 'incomum') order by random() limit 8)
      union all (select species from tcg_cartas where raridade = 'rara' order by random() limit 2)) x;
  else
    select cartas into cs from tcg_decks where user_id = _uid;
    if cs is null or jsonb_array_length(cs) <> (c->>'deck')::int then
      raise exception 'Monte seu deck de % cartas na aba Cartas → Deck antes de duelar.', c->>'deck'; end if;
    for r in select (x->>'s')::int s, coalesce((x->>'b')::boolean, false) b, count(*) n from jsonb_array_elements(cs) x group by 1, 2 loop
      if coalesce((select qtd from tcg_colecao where user_id = _uid and species = r.s and brilhante = r.b), 0) < r.n then
        raise exception 'Seu deck tem cartas que você não tem mais. Monte o deck de novo na aba Cartas → Deck.'; end if;
    end loop;
  end if;
  select jsonb_agg(public.tcg_inst((x->>'s')::int, (x->>'b')::boolean) order by random()) into dk from jsonb_array_elements(cs) x;
  return jsonb_build_object('user', _uid, 'nome', case when _cpu then 'Treinador do computador' else (select name from characters where user_id = _uid) end,
    'ativo', dk->0,
    'mao', coalesce((select jsonb_agg(v order by o) from jsonb_array_elements(dk) with ordinality t(v, o) where o between 2 and 1 + mao), '[]'::jsonb),
    'pilha', coalesce((select jsonb_agg(v order by o) from jsonb_array_elements(dk) with ordinality t(v, o) where o > 1 + mao), '[]'::jsonb),
    'energia', 0, 'perdidos', 0);
end $$;

-- começo do turno de um lado: +1 de energia (até o máximo) e completa a mão
create or replace function public.tcg_vez_inicio(_l jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.tcg_cfg();
begin
  _l := jsonb_set(_l, '{energia}', to_jsonb(least((c->>'energia_max')::int, (_l->>'energia')::int + 1)));
  while jsonb_array_length(_l->'mao') < (c->>'mao')::int and jsonb_array_length(_l->'pilha') > 0 loop
    _l := jsonb_set(_l, '{mao}', (_l->'mao') || jsonb_build_array(_l->'pilha'->0));
    _l := jsonb_set(_l, '{pilha}', (_l->'pilha') - 0);
  end loop;
  return _l;
end $$;

-- multiplicador de tipo (a mesma tabela das batalhas)
create or replace function public.tcg_mult(_atk text, _d jsonb) returns numeric
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((select mult from pk_type_chart where atk = _atk and def = _d->>'t1'), 1)
       * case when _d->>'t2' is null then 1 else coalesce((select mult from pk_type_chart where atk = _atk and def = _d->>'t2'), 1) end
$$;

create or replace function public.tcg_log(_st jsonb, _t text) returns jsonb
language sql immutable as $$
  select jsonb_set(_st, '{log}', coalesce((select jsonb_agg(v order by o) from jsonb_array_elements(coalesce(_st->'log', '[]'::jsonb) || to_jsonb(_t)) with ordinality t(v, o)
                                            where o > jsonb_array_length(coalesce(_st->'log', '[]'::jsonb)) + 1 - 40), '[]'::jsonb))
$$;

-- aplica a jogada de quem tem a vez e passa o turno (o banco confere tudo)
create or replace function public.tcg_aplicar(_st jsonb, _acao text, _idx int default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.tcg_cfg(); v int := (_st->>'vez')::int; me jsonb := _st->'l'->v; op jsonb := _st->'l'->(1 - v);
  custo int; base int; mult numeric; d int; m2 jsonb; best int; tn int; pa int; pb int;
begin
  if _st ? 'fim' then raise exception 'Esse duelo já acabou.'; end if;
  if _acao in ('fraco', 'forte') then
    custo := (c->>(case when _acao = 'fraco' then 'custo_fraco' else 'custo_forte' end))::int;
    if (me->>'energia')::int < custo then raise exception 'Energia insuficiente: esse ataque custa % ⚡.', custo; end if;
    base := (me->'ativo'->>(case when _acao = 'fraco' then 'fd' else 'Fd' end))::int;
    mult := public.tcg_mult(me->'ativo'->>'t1', op->'ativo');
    d := round(base * mult)::int;
    me := jsonb_set(me, '{energia}', to_jsonb((me->>'energia')::int - custo));
    op := jsonb_set(op, '{ativo,hp}', to_jsonb(greatest(0, (op->'ativo'->>'hp')::int - d)));
    _st := public.tcg_log(_st, (me->'ativo'->>'nome') || ' de ' || (me->>'nome') || ' usou ' || (me->'ativo'->>(case when _acao = 'fraco' then 'fn' else 'Fn' end))
      || ': ' || d || ' de dano' || case when mult > 1 then ' (super efetivo!)' when mult = 0 then ' (não fez efeito!)' when mult < 1 then ' (pouco efetivo)' else '' end || '.');
    if (op->'ativo'->>'hp')::int <= 0 then
      _st := public.tcg_log(_st, (op->'ativo'->>'nome') || ' de ' || (op->>'nome') || ' foi derrotado!');
      op := jsonb_set(op, '{perdidos}', to_jsonb((op->>'perdidos')::int + 1));
      if jsonb_array_length(op->'mao') > 0 then   -- entra o de mais vida da mão
        select (o - 1)::int into best from jsonb_array_elements(op->'mao') with ordinality t(x, o) order by (x->>'hp')::int desc, o limit 1;
        op := jsonb_set(op, '{ativo}', op->'mao'->best); op := jsonb_set(op, '{mao}', (op->'mao') - best);
      elsif jsonb_array_length(op->'pilha') > 0 then
        op := jsonb_set(op, '{ativo}', op->'pilha'->0); op := jsonb_set(op, '{pilha}', (op->'pilha') - 0);
      else op := jsonb_set(op, '{ativo}', 'null'::jsonb); end if;
      if jsonb_typeof(op->'ativo') = 'object' and (op->>'perdidos')::int < (c->>'nocautes')::int then
        _st := public.tcg_log(_st, (op->>'nome') || ' mandou ' || (op->'ativo'->>'nome') || '.'); end if;
    end if;
  elsif _acao = 'trocar' then
    custo := (c->>'custo_trocar')::int;
    if (me->>'energia')::int < custo then raise exception 'Trocar custa % ⚡.', custo; end if;
    if _idx is null or _idx < 0 or _idx >= jsonb_array_length(me->'mao') then raise exception 'Escolha uma carta da sua mão.'; end if;
    m2 := me->'ativo';
    me := jsonb_set(me, '{ativo}', me->'mao'->_idx);
    me := jsonb_set(me, array['mao', _idx::text], m2);
    me := jsonb_set(me, '{energia}', to_jsonb((me->>'energia')::int - custo));
    _st := public.tcg_log(_st, (me->>'nome') || ' trocou: entrou ' || (me->'ativo'->>'nome') || '.');
  elsif _acao = 'passar' then
    _st := public.tcg_log(_st, (me->>'nome') || ' guardou energia.');
  else
    raise exception 'Jogada inválida.';
  end if;
  _st := jsonb_set(jsonb_set(_st, array['l', v::text], me), array['l', (1 - v)::text], op);
  if (op->>'perdidos')::int >= (c->>'nocautes')::int or jsonb_typeof(op->'ativo') <> 'object' then
    return public.tcg_log(_st, '🏆 ' || (me->>'nome') || ' venceu o duelo!') || jsonb_build_object('fim', jsonb_build_object('lado', v, 'motivo', 'nocaute'));
  end if;
  tn := coalesce((_st->>'turno')::int, 1) + 1;
  if tn > (c->>'turnos_max')::int then   -- turnos demais: vence quem perdeu menos Pokémon
    pa := (_st->'l'->0->>'perdidos')::int; pb := (_st->'l'->1->>'perdidos')::int;
    return public.tcg_log(_st, 'Acabou o tempo do duelo.') || jsonb_build_object('fim', jsonb_build_object('lado', case when pa < pb then 0 when pb < pa then 1 end, 'motivo', 'tempo'));
  end if;
  _st := jsonb_set(jsonb_set(_st, '{vez}', to_jsonb(1 - v)), '{turno}', to_jsonb(tn));
  return jsonb_set(_st, array['l', (1 - v)::text], public.tcg_vez_inicio(_st->'l'->(1 - v)));
end $$;

-- o computador escolhe a jogada (só no treino)
create or replace function public.tcg_cpu_acao(_st jsonb) returns text[]
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.tcg_cfg(); me jsonb := _st->'l'->((_st->>'vez')::int); op jsonb := _st->'l'->(1 - (_st->>'vez')::int); e int := (me->>'energia')::int; best int;
begin
  if e >= (c->>'custo_forte')::int then return array['forte', null]; end if;
  if (me->'ativo'->>'hp')::int * 100 < (me->'ativo'->>'pv')::int * 30 and e >= (c->>'custo_trocar')::int then
    select (o - 1)::int into best from jsonb_array_elements(me->'mao') with ordinality t(x, o) where (x->>'hp')::int > (me->'ativo'->>'hp')::int * 2 order by (x->>'hp')::int desc limit 1;
    if best is not null then return array['trocar', best::text]; end if;
  end if;
  if e >= (c->>'custo_fraco')::int and ((op->'ativo'->>'hp')::int <= round((me->'ativo'->>'fd')::int * public.tcg_mult(me->'ativo'->>'t1', op->'ativo')) or random() < 0.4) then
    return array['fraco', null]; end if;
  return array['passar', null];
end $$;

create or replace function public.tcg_cpu_joga(_st jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare a text[]; i int := 0;
begin
  while not (_st ? 'fim') and (_st->>'vez')::int = 1 and i < 5 loop
    a := public.tcg_cpu_acao(_st);
    _st := public.tcg_aplicar(_st, a[1], a[2]::int); i := i + 1;
  end loop;
  return _st;
end $$;

-- fecha o duelo e paga a aposta (uma vez só)
create or replace function public.tcg_fechar(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare d tcg_duelos; w uuid; wn text; ln text;
begin
  select * into d from tcg_duelos where id = _id for update;
  if d.status <> 'ativa' or not (d.state ? 'fim') then return; end if;
  w := case (d.state->'fim'->>'lado')::int when 0 then d.p1 when 1 then d.p2 end;
  update tcg_duelos set status = 'encerrada', winner = w, motivo = d.state->'fim'->>'motivo', ended_at = now() where id = d.id;
  if not d.treino and d.pago and not d.quitado and d.aposta > 0 then
    if w is not null then update characters set coins = coins + 2 * d.aposta where user_id = w;
    else update characters set coins = coins + d.aposta where user_id in (d.p1, d.p2); end if;
    update tcg_duelos set quitado = true where id = d.id;
  end if;
  if not d.treino and w is not null then
    select name into wn from characters where user_id = w;
    select name into ln from characters where user_id = case when w = d.p1 then d.p2 else d.p1 end;
    insert into event_log(user_id, kind, message) values (w, 'cartas', wn || ' venceu ' || ln || ' num duelo de cartas' || case when d.aposta > 0 then ' e levou ' || 2 * d.aposta || ' moedas' else '' end || '!');
  end if;
end $$;

-- o que o jogador vê do duelo (a mão e o baralho do outro ficam escondidos)
create or replace function public.tcg_duelo_estado(_id bigint) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); d tcg_duelos; lado int; me jsonb; op jsonb; st jsonb;
begin
  select * into d from tcg_duelos where id = _id;
  if d.id is null or (uid is distinct from d.p1 and uid is distinct from d.p2 and not public.is_admin()) then raise exception 'Duelo não encontrado.'; end if;
  lado := case when uid = d.p2 then 1 else 0 end;
  st := coalesce(d.state, '{}'::jsonb);
  me := st->'l'->lado; op := st->'l'->(1 - lado);
  return jsonb_build_object('id', d.id, 'status', d.status, 'treino', d.treino, 'aposta', d.aposta, 'lado', lado,
    'p1', d.p1, 'p2', d.p2, 'p1_nome', (select name from characters where user_id = d.p1),
    'p2_nome', case when d.treino then 'Treinador do computador' else (select name from characters where user_id = d.p2) end,
    'minha_vez', d.status = 'ativa' and (st->>'vez')::int = lado, 'turno', st->'turno', 'winner', d.winner, 'motivo', d.motivo, 'fim', st->'fim',
    'eu', case when me is null then null else (me - 'pilha') || jsonb_build_object('pilha_n', jsonb_array_length(coalesce(me->'pilha', '[]'::jsonb))) end,
    'op', case when op is null then null else (op - 'pilha' - 'mao') || jsonb_build_object('pilha_n', jsonb_array_length(coalesce(op->'pilha', '[]'::jsonb)), 'mao_n', jsonb_array_length(coalesce(op->'mao', '[]'::jsonb))) end,
    'log', coalesce(st->'log', '[]'::jsonb), 'created_at', d.created_at, 'ended_at', d.ended_at);
end $$;

create or replace function public.tcg_jogar(_id bigint, _acao text, _idx int default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d tcg_duelos; lado int; st jsonb;
begin
  select * into d from tcg_duelos where id = _id for update;
  if d.id is null or (uid is distinct from d.p1 and uid is distinct from d.p2) then raise exception 'Duelo não encontrado.'; end if;
  if d.status <> 'ativa' then raise exception 'Esse duelo não está em andamento.'; end if;
  lado := case when uid = d.p1 then 0 else 1 end;
  if _acao = 'desistir' then
    st := public.tcg_log(d.state, (d.state->'l'->lado->>'nome') || ' desistiu.') || jsonb_build_object('fim', jsonb_build_object('lado', 1 - lado, 'motivo', 'desistencia'));
  else
    if (d.state->>'vez')::int <> lado then raise exception 'Ainda não é a sua vez.'; end if;
    st := public.tcg_aplicar(d.state, _acao, _idx);
    if d.treino then st := public.tcg_cpu_joga(st); end if;
  end if;
  update tcg_duelos set state = st, turno_at = now() where id = d.id;
  if st ? 'fim' then perform public.tcg_fechar(d.id); end if;
  return public.tcg_duelo_estado(d.id);
end $$;

create or replace function public.tcg_desafiar(_op uuid, _aposta int) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.tcg_cfg(); me characters; nid bigint;
begin
  if not coalesce((c->>'on')::boolean, true) then raise exception 'As Cartas estão fechadas no momento.'; end if;
  if _op = uid then raise exception 'Você não pode duelar contra você mesmo.'; end if;
  if not exists (select 1 from characters where user_id = _op) then raise exception 'Jogador não encontrado.'; end if;
  if _aposta is null or _aposta < (c->>'aposta_min')::int or _aposta > (c->>'aposta_max')::int then
    raise exception 'A aposta é de % a % moedas.', c->>'aposta_min', c->>'aposta_max'; end if;
  perform public.tcg_lado(uid);   -- confere o deck
  if exists (select 1 from tcg_duelos where status in ('convite', 'ativa') and not treino and ((p1 = uid and p2 = _op) or (p1 = _op and p2 = uid))) then
    raise exception 'Já existe um duelo de cartas aberto entre vocês.'; end if;
  select * into me from characters where user_id = uid for update;
  if me.coins < _aposta then raise exception 'A aposta é de % moedas e você tem %.', _aposta, me.coins; end if;
  update characters set coins = coins - _aposta where id = me.id;   -- a sua parte fica guardada
  insert into tcg_duelos(p1, p2, aposta) values (uid, _op, _aposta) returning tcg_duelos.id into nid;
  insert into event_log(user_id, kind, message) select uid, 'cartas', me.name || ' desafiou ' || ch.name || ' para um duelo de cartas valendo ' || _aposta || ' moedas!' from characters ch where ch.user_id = _op;
  return nid;
end $$;

create or replace function public.tcg_responder(_id bigint, _aceitar boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d tcg_duelos; me characters; s1 jsonb; s2 jsonb; v int; st jsonb;
begin
  select * into d from tcg_duelos where id = _id for update;
  if d.id is null or d.p2 is distinct from uid then raise exception 'Convite não encontrado.'; end if;
  if d.status <> 'convite' then raise exception 'Esse convite já foi respondido.'; end if;
  if not _aceitar then
    update characters set coins = coins + d.aposta where user_id = d.p1;   -- devolve a parte de quem desafiou
    update tcg_duelos set status = 'recusada', ended_at = now() where id = d.id;
    return public.tcg_duelo_estado(d.id);
  end if;
  s2 := public.tcg_lado(uid);
  s1 := public.tcg_lado(d.p1);
  select * into me from characters where user_id = uid for update;
  if me.coins < d.aposta then raise exception 'A aposta é de % moedas e você tem %.', d.aposta, me.coins; end if;
  update characters set coins = coins - d.aposta where id = me.id;
  v := floor(random() * 2)::int;
  st := jsonb_build_object('l', jsonb_build_array(s1, s2), 'vez', v, 'turno', 1, 'log', '[]'::jsonb);
  st := jsonb_set(st, array['l', v::text], public.tcg_vez_inicio(st->'l'->v));
  st := public.tcg_log(st, 'O duelo começou! ' || (st->'l'->v->>'nome') || ' começa.');
  update tcg_duelos set status = 'ativa', pago = true, state = st, turno_at = now() where id = d.id;
  return public.tcg_duelo_estado(d.id);
end $$;

create or replace function public.tcg_cancelar(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d tcg_duelos;
begin
  select * into d from tcg_duelos where id = _id for update;
  if d.id is null or d.p1 <> uid or d.status <> 'convite' then raise exception 'Convite não encontrado.'; end if;
  update characters set coins = coins + d.aposta where user_id = uid;
  update tcg_duelos set status = 'cancelada', ended_at = now() where id = d.id;
end $$;

-- treino contra o computador: sem aposta e sem prêmio
create or replace function public.tcg_treino() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); v int; st jsonb; nid bigint;
begin
  update tcg_duelos set status = 'cancelada', ended_at = now() where p1 = uid and treino and status = 'ativa';
  v := floor(random() * 2)::int;
  st := jsonb_build_object('l', jsonb_build_array(public.tcg_lado(uid), public.tcg_lado(null, true)), 'vez', v, 'turno', 1, 'log', '[]'::jsonb);
  st := jsonb_set(st, array['l', v::text], public.tcg_vez_inicio(st->'l'->v));
  st := public.tcg_log(st, 'Treino começou! ' || (st->'l'->v->>'nome') || ' começa.');
  st := public.tcg_cpu_joga(st);
  insert into tcg_duelos(p1, p2, treino, status, state, turno_at) values (uid, null, true, 'ativa', st, now()) returning tcg_duelos.id into nid;
  if st ? 'fim' then perform public.tcg_fechar(nid); end if;
  return public.tcg_duelo_estado(nid);
end $$;

create or replace function public.tcg_meus_duelos() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'status', d.status, 'treino', d.treino, 'aposta', d.aposta, 'p1', d.p1, 'p2', d.p2,
      'p1_nome', (select name from characters where user_id = d.p1),
      'p2_nome', case when d.treino then 'Computador' else (select name from characters where user_id = d.p2) end,
      'minha_vez', d.status = 'ativa' and (d.state->>'vez')::int = case when d.p1 = auth.uid() then 0 else 1 end,
      'winner', d.winner, 'motivo', d.motivo, 'created_at', d.created_at, 'ended_at', d.ended_at, 'turno_at', d.turno_at) order by d.id desc), '[]'::jsonb)
  from (select * from tcg_duelos where (p1 = auth.uid() or p2 = auth.uid()) and (status in ('convite', 'ativa') or ended_at > now() - interval '7 days')
        order by id desc limit 30) d
$$;

create or replace function public.tcg_ranking() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'duelos', coalesce((select jsonb_agg(x order by x.v desc, x.j) from (
        select ch.user_id, ch.name, count(*) filter (where d.winner = ch.user_id)::int v, count(*)::int j
          from tcg_duelos d join characters ch on ch.user_id in (d.p1, d.p2)
         where not d.treino and d.status = 'encerrada'
           and d.ended_at >= coalesce((select started_on from seasons where status = 'ativa' order by id desc limit 1), '2000-01-01'::date)
         group by ch.user_id, ch.name order by 3 desc, 4 limit 20) x), '[]'::jsonb),
    'colecao', coalesce((select jsonb_agg(y order by y.n desc) from (
        select ch.user_id, ch.name, count(distinct t.species)::int n from tcg_colecao t join characters ch on ch.user_id = t.user_id
         where t.qtd > 0 group by ch.user_id, ch.name order by 3 desc limit 20) y), '[]'::jsonb))
$$;

-- tudo o que a aba Cartas precisa
create or replace function public.tcg_estado() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.tcg_cfg();
begin
  perform public.tcg_tick(uid);
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true),
    'pacotes', coalesce((select pacotes from tcg_saldo where user_id = uid), 0),
    'preco', public.preco_heroi(uid, (c->>'pacote_preco')::int),
    'colecao', coalesce((select jsonb_agg(jsonb_build_object('s', species, 'b', brilhante, 'q', qtd)) from tcg_colecao where user_id = uid and qtd > 0), '[]'::jsonb),
    'deck', coalesce((select cartas from tcg_decks where user_id = uid), '[]'::jsonb),
    'novas', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'origem', origem, 'cartas', cartas) order by id) from tcg_aberturas where user_id = uid and not visto), '[]'::jsonb),
    'duelos', public.tcg_meus_duelos());
end $$;

-- resumo leve para o sino (e dá os prêmios automáticos)
create or replace function public.tcg_resumo() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active();
begin
  perform public.tcg_tick(uid);
  return jsonb_build_object('pacotes', coalesce((select pacotes from tcg_saldo where user_id = uid), 0),
    'novas', (select count(*) from tcg_aberturas where user_id = uid and not visto),
    'convites', (select count(*) from tcg_duelos where p2 = uid and status = 'convite'),
    'vez', (select count(*) from tcg_duelos where not treino and status = 'ativa' and (state->>'vez')::int = case when p1 = uid then 0 else 1 end and (p1 = uid or p2 = uid)));
end $$;

create or replace function public.tcg_visto() returns void
language sql security definer set search_path = public, extensions as $$
  update tcg_aberturas set visto = true where user_id = auth.uid() and not visto
$$;

-- ---------- Ajustes do jogo (versão do 86 + Cartas) ----------
create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'leilao', public.leilao_cfg(), 'herois', public.herois_cfg(), 'temporada', public.temporada_cfg(), 'liga', public.liga_cfg(), 'pausa', public.pausa_cfg(), 'teto', public.teto_cfg(), 'boas_vindas', public.boas_vindas_cfg(), 'vila_bonus', public.vila_bonus_cfg(), 'tm_nivel', public.tm_nivel_cfg(), 'quiz_auto', public.quiz_auto_cfg(), 'cartas', public.tcg_cfg(), 'base', public.cfg());
end $$;

grant execute on function public.tcg_estado(), public.tcg_resumo(), public.tcg_visto(), public.tcg_abrir_pacote(), public.tcg_comprar_pacote(int),
  public.tcg_deck_salvar(jsonb), public.tcg_desmanchar(int, boolean, int), public.tcg_ofertar(int, boolean, int), public.tcg_oferta_cancelar(bigint),
  public.tcg_oferta_comprar(bigint), public.tcg_desafiar(uuid, int), public.tcg_responder(bigint, boolean), public.tcg_cancelar(bigint),
  public.tcg_treino(), public.tcg_jogar(bigint, text, int), public.tcg_duelo_estado(bigint), public.tcg_meus_duelos(), public.tcg_ranking() to authenticated;
revoke execute on function public.tcg_cfg(), public.tcg_sorteia(text), public.tcg_dar(uuid, jsonb, text), public.tcg_tick(uuid), public.tcg_no_deck(uuid, int, boolean),
  public.tcg_inst(int, boolean), public.tcg_lado(uuid, boolean), public.tcg_vez_inicio(jsonb), public.tcg_mult(text, jsonb), public.tcg_log(jsonb, text),
  public.tcg_aplicar(jsonb, text, int), public.tcg_cpu_acao(jsonb), public.tcg_cpu_joga(jsonb), public.tcg_fechar(bigint) from public, anon, authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🃏 Chegaram as Cartas Pokegames!', 'Aba nova no menu Pokémon: as Cartas Pokegames, com as 151 da 1ª geração.
• Junte a coleção no álbum: comum, incomum, rara, ultra rara e a ✨ brilhante (1% das cartas, dourada e mais forte).
• Todo mundo ganha 2 pacotes de boas-vindas. Depois: 1 carta por dia ao andar, pacote pela vitória na rodada, pelo Quiz, nos prêmios da temporada, às vezes nos baús e na loja por moedas.
• Monte um deck de 10 cartas e duele: cada turno dá +1 de energia ⚡, o ataque fraco custa 1 e o forte custa 3. Vence quem derrubar 3 Pokémon do outro.
• Contra outro jogador vale moedas (de 10 a 100). Contra o computador é só treino.
• Repetidas: desmanche em moedas ou venda no Mercado de cartas.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
