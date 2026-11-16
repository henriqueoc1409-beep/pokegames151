-- 112_vale_fazenda.sql
-- Pedido do dono em 16/11/2026: dois jeitos novos de evoluir os Pokémon, sem a grama e sem a batalha de sempre.
-- (1) Vale do Treino: região nova da Aventura (trilha ao norte da Vila Aurora) com 6 estações de treino. Em cada uma o
--     Pokémon faz um exercício, que é um minijogo rápido no site (ritmo, combo, memória, desvio, reflexo e equilíbrio).
--     A nota (0 a 100) vira experiência: exp_ref × nível ÷ 7 × nota/100 (a mesma conta da luta da Aventura contra um
--     selvagem do mesmo nível) × afinidade (o tipo do Pokémon combina com a estação) × xp_mult. Limite de treinos por dia.
--     O treino conta quando começa (vale_comecar); o servidor confere o tempo mínimo e máximo no vale_terminar.
-- (2) Fazenda de Frutas, dentro da Minha Vila: canteiros para plantar frutas (semente em moedas), que crescem em horas de
--     verdade; colhe, guarda na cesta e dá de comer aos Pokémon (XP pela mesma conta, mais forte quando o tipo gosta da
--     fruta). Regar a horta de outro jogador faz a planta dele crescer mais rápido e dá uma fruta para quem regou.
--     O Pomar da vila dá canteiros a mais; dá para comprar canteiros extras.
-- Fontes NOVAS de XP, cada uma com limite por dia (treinos_dia e frutas_dia). As contas de XP que já existem não mudam.
-- Números em game_config.config.vale e .fazenda (vale_cfg, fazenda_cfg; Ajustes do jogo → 🥋 Vale do Treino e 🍓 Fazenda).
-- Nova admin_cfg_efetiva (versão do 111 + vale e fazenda).

-- =================================================================
-- VALE DO TREINO
-- =================================================================
create or replace function public.vale_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "treinos_dia": 8, "exp_ref": 120, "xp_mult": 1, "afinidade_mult": 1.5, "nota_min": 10,
    "duracao_min_seg": 12, "duracao_max_min": 15,
    "estacoes": {
      "pista":    {"nome": "Pista de Corrida",    "tipos": ["NORMAL", "ELETRICO", "VOADOR"]},
      "saco":     {"nome": "Saco de Pancada",     "tipos": ["LUTA", "PEDRA", "METALICO"]},
      "templo":   {"nome": "Templo da Meditação", "tipos": ["PSIQUICO", "FANTASMA", "DRAGAO"]},
      "lago":     {"nome": "Lago das Correntes",  "tipos": ["AGUA", "GELO"]},
      "paredao":  {"nome": "Paredão de Escalada", "tipos": ["INSETO", "PLANTA", "TERRA"]},
      "fogueira": {"nome": "Fogueira do Fôlego",  "tipos": ["FOGO", "VENENO", "SOMBRIO"]}}}'::jsonb
    || coalesce(public.cfg()->'vale', '{}'::jsonb)
$$;
revoke execute on function public.vale_cfg() from public, anon, authenticated;
update public.game_config set config = jsonb_set(config, '{vale}', public.vale_cfg()) where active and not (config ? 'vale');

create table if not exists public.vale_dias (
  user_id uuid not null references auth.users(id) on delete cascade,
  dia     date not null,
  treinos int  not null default 0,
  xp      int  not null default 0,
  primary key (user_id, dia));
alter table public.vale_dias enable row level security;   -- sem política: o site lê pelo vale_estado

create table if not exists public.vale_treinos (
  id          bigserial primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  mon_id      uuid not null,
  estacao     text not null,
  especie     int,
  nivel       int,
  afinidade   boolean not null default false,
  semente     int not null default 0,
  comecou_em  timestamptz not null default now(),
  terminou_em timestamptz,
  nota        int,
  xp          int);
create index if not exists vale_treinos_user on public.vale_treinos(user_id, comecou_em desc);
alter table public.vale_treinos enable row level security;   -- sem política: o site lê pelo vale_estado

-- o tipo do Pokémon combina com a estação?
create or replace function public.vale_afinidade(_especie int, _estacao text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from pokemon p, jsonb_array_elements_text(public.vale_cfg()->'estacoes'->_estacao->'tipos') t(v)
                  where p.id = _especie and (p.g1_type1 = t.v or p.g1_type2 = t.v))
$$;
revoke execute on function public.vale_afinidade(int, text) from public, anon, authenticated;

-- a conta da experiência (igual à luta da Aventura contra um selvagem do mesmo nível, vezes a nota e a afinidade)
create or replace function public.vale_xp_conta(_ref numeric, _nivel int, _nota int, _mult numeric) returns int
language sql immutable as $$
  select greatest(0, floor(_ref * _nivel / 7.0 * greatest(0, least(100, _nota)) / 100.0 * _mult + 0.5))::int
$$;

create or replace function public.vale_estado() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.vale_cfg(); d vale_dias;
begin
  if uid is null then return null; end if;
  select * into d from vale_dias where user_id = uid and dia = public.game_today();
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'treinos', coalesce(d.treinos, 0), 'treinos_dia', (c->>'treinos_dia')::int,
    'xp_hoje', coalesce(d.xp, 0), 'afinidade_mult', (c->>'afinidade_mult')::numeric, 'duracao_min_seg', (c->>'duracao_min_seg')::int,
    'estacoes', c->'estacoes',
    'recentes', coalesce((select jsonb_agg(jsonb_build_object('estacao', t.estacao, 'especie', t.especie, 'nota', t.nota, 'xp', t.xp, 'em', t.terminou_em) order by t.id desc)
                            from (select * from vale_treinos where user_id = uid and terminou_em is not null order by id desc limit 6) t), '[]'::jsonb));
end $$;

-- começar um treino: conta no limite do dia já aqui (começou, contou)
create or replace function public.vale_comecar(_estacao text, _mon uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.vale_cfg(); m monsters; d vale_dias; vid bigint; sem int := floor(random() * 2000000000)::int; af boolean;
begin
  if not coalesce((c->>'on')::boolean, true) and not public.is_admin() then raise exception 'O Vale do Treino está fechado no momento.'; end if;
  if c->'estacoes'->_estacao is null then raise exception 'Estação inválida.'; end if;
  select * into m from monsters where id = _mon and user_id = uid;
  if m.id is null then raise exception 'Esse Pokémon não é seu.'; end if;
  if m.level >= 100 then raise exception 'Esse Pokémon já está no nível máximo.'; end if;
  insert into vale_dias(user_id, dia) values (uid, public.game_today()) on conflict do nothing;
  select * into d from vale_dias where user_id = uid and dia = public.game_today() for update;
  if d.treinos >= (c->>'treinos_dia')::int then raise exception 'Você já fez os % treinos de hoje no Vale. Volte amanhã!', (c->>'treinos_dia')::int; end if;
  update vale_dias set treinos = treinos + 1 where user_id = uid and dia = d.dia;
  -- um treino que ficou aberto (fechou a página) termina sem experiência
  update vale_treinos set terminou_em = now(), nota = 0, xp = 0 where user_id = uid and terminou_em is null;
  af := public.vale_afinidade(m.species_id, _estacao);
  insert into vale_treinos(user_id, mon_id, estacao, especie, nivel, afinidade, semente) values (uid, m.id, _estacao, m.species_id, m.level, af, sem) returning id into vid;
  return jsonb_build_object('id', vid, 'semente', sem, 'estacao', _estacao, 'afinidade', af, 'treinos', d.treinos + 1, 'treinos_dia', (c->>'treinos_dia')::int,
    'duracao_min_seg', (c->>'duracao_min_seg')::int);
end $$;

-- terminar: a nota vira experiência (o servidor confere o tempo e a nota; nada de chance)
create or replace function public.vale_terminar(_id bigint, _nota int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.vale_cfg(); t vale_treinos; m monsters; seg numeric; nt int; ganho int := 0; lv0 int; lv1 int;
begin
  select * into t from vale_treinos where id = _id and user_id = uid for update;
  if t.id is null then raise exception 'Treino não encontrado.'; end if;
  if t.terminou_em is not null then raise exception 'Esse treino já terminou.'; end if;
  seg := extract(epoch from now() - t.comecou_em);
  if seg < (c->>'duracao_min_seg')::numeric - 1 then raise exception 'Treino rápido demais. Termine o exercício inteiro.'; end if;
  nt := greatest(0, least(100, coalesce(_nota, 0)));
  if seg > (c->>'duracao_max_min')::numeric * 60 then nt := 0; end if;   -- demorou demais: o treino venceu
  select * into m from monsters where id = t.mon_id and user_id = uid;
  lv0 := m.level;
  if m.id is not null and nt >= coalesce((c->>'nota_min')::int, 0) and m.level < 100 then
    ganho := public.vale_xp_conta((c->>'exp_ref')::numeric, m.level, nt,
            coalesce((c->>'xp_mult')::numeric, 1) * case when t.afinidade then coalesce((c->>'afinidade_mult')::numeric, 1) else 1 end);
    perform public.pk_give_xp(m.id, ganho, 'vale');
  end if;
  update vale_treinos set terminou_em = now(), nota = nt, xp = ganho where id = t.id;
  update vale_dias set xp = vale_dias.xp + ganho where user_id = uid and dia = public.game_today();
  select level into lv1 from monsters where id = t.mon_id;
  return jsonb_build_object('nota', nt, 'xp', ganho, 'afinidade', t.afinidade, 'nivel_antes', lv0, 'nivel_depois', coalesce(lv1, lv0), 'especie', t.especie,
    'estado', public.vale_estado(),
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.id) from mon_events e where e.user_id = uid and not e.seen), '[]'::jsonb));
end $$;

-- =================================================================
-- FAZENDA DE FRUTAS (na Minha Vila)
-- =================================================================
create or replace function public.fazenda_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "canteiros": 4, "canteiros_pomar": 2, "canteiros_precos": [400, 800], "frutas_dia": 10, "xp_mult": 1, "gosta_mult": 1.5,
    "regas_dia": 5, "rega_pct": 15, "regas_max": 3, "rega_fruta": 1,
    "frutas": {
      "mel":    {"nome": "Fruta-Mel",    "sabor": "doce",        "horas": 2, "semente": 5,  "colheita": 3, "xp": 40,  "tipos": ["NORMAL", "PLANTA", "INSETO"]},
      "gota":   {"nome": "Fruta-Gota",   "sabor": "refrescante", "horas": 4, "semente": 10, "colheita": 3, "xp": 70,  "tipos": ["AGUA", "GELO", "VOADOR"]},
      "brasa":  {"nome": "Fruta-Brasa",  "sabor": "picante",     "horas": 4, "semente": 10, "colheita": 3, "xp": 70,  "tipos": ["FOGO", "LUTA", "DRAGAO"]},
      "faisca": {"nome": "Fruta-Faísca", "sabor": "azedinha",    "horas": 6, "semente": 15, "colheita": 3, "xp": 90,  "tipos": ["ELETRICO", "PSIQUICO", "METALICO"]},
      "sombra": {"nome": "Fruta-Sombra", "sabor": "amarga",      "horas": 6, "semente": 15, "colheita": 3, "xp": 90,  "tipos": ["VENENO", "FANTASMA", "SOMBRIO"]},
      "rocha":  {"nome": "Fruta-Rocha",  "sabor": "crocante",    "horas": 8, "semente": 20, "colheita": 3, "xp": 110, "tipos": ["PEDRA", "TERRA"]}}}'::jsonb
    || coalesce(public.cfg()->'fazenda', '{}'::jsonb)
$$;
revoke execute on function public.fazenda_cfg() from public, anon, authenticated;
update public.game_config set config = jsonb_set(config, '{fazenda}', public.fazenda_cfg()) where active and not (config ? 'fazenda');

create table if not exists public.fazenda_donos (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  extra     int not null default 0,
  criado_em timestamptz not null default now());
create table if not exists public.fazenda_canteiros (
  user_id     uuid not null references auth.users(id) on delete cascade,
  slot        int  not null,
  fruta       text not null,
  plantado_em timestamptz not null default now(),
  pronto_em   timestamptz not null,
  regadores   uuid[] not null default '{}',
  primary key (user_id, slot));
create table if not exists public.fazenda_cesta (
  user_id uuid not null references auth.users(id) on delete cascade,
  fruta   text not null,
  qtd     int  not null default 0 check (qtd >= 0),
  primary key (user_id, fruta));
create table if not exists public.fazenda_dias (
  user_id uuid not null references auth.users(id) on delete cascade,
  dia     date not null,
  comidas int  not null default 0,
  regas   int  not null default 0,
  xp      int  not null default 0,
  primary key (user_id, dia));
alter table public.fazenda_donos enable row level security;       -- sem política: o site lê pelo fazenda_estado
alter table public.fazenda_canteiros enable row level security;
alter table public.fazenda_cesta enable row level security;
alter table public.fazenda_dias enable row level security;

-- quantos canteiros a pessoa tem: os de começo + os do Pomar (construído e sem dano) + os comprados
create or replace function public.fazenda_total(_uid uuid) returns int
language sql stable security definer set search_path = public, extensions as $$
  select (public.fazenda_cfg()->>'canteiros')::int
       + case when coalesce((select public.vl_level(v, 'pomar') from villages v where v.user_id = _uid), 0) > 0   -- danificado na guerra = 0
              then coalesce((public.fazenda_cfg()->>'canteiros_pomar')::int, 0) else 0 end
       + least(coalesce((select extra from fazenda_donos where user_id = _uid), 0), jsonb_array_length(coalesce(public.fazenda_cfg()->'canteiros_precos', '[]'::jsonb)))
$$;
revoke execute on function public.fazenda_total(uuid) from public, anon, authenticated;

-- a horta de alguém (a sua, ou a de outro jogador para visitar e regar)
create or replace function public.fazenda_estado(_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); alvo uuid := coalesce(_user, auth.uid()); c jsonb := public.fazenda_cfg(); d fazenda_dias; ex int; pr jsonb;
begin
  if uid is null then return null; end if;
  select * into d from fazenda_dias where user_id = uid and dia = public.game_today();
  select extra into ex from fazenda_donos where user_id = alvo; ex := coalesce(ex, 0);
  pr := coalesce(c->'canteiros_precos', '[]'::jsonb);
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'mine', alvo = uid, 'dono', alvo,
    'nome', (select name from characters where user_id = alvo),
    'total', public.fazenda_total(alvo), 'extra', ex, 'proximo_preco', case when ex < jsonb_array_length(pr) then (pr->>ex)::int end,
    'tem_pomar', coalesce((select orchard_level from villages where user_id = alvo), 0) > 0,
    'canteiros', coalesce((select jsonb_agg(jsonb_build_object('slot', k.slot, 'fruta', k.fruta, 'plantado_em', k.plantado_em, 'pronto_em', k.pronto_em,
                       'pronto', k.pronto_em <= now(), 'regas', cardinality(k.regadores), 'eu_reguei', uid = any(k.regadores),
                       'regadores', (select coalesce(jsonb_agg(ch.name), '[]'::jsonb) from characters ch where ch.user_id = any(k.regadores))) order by k.slot)
                     from fazenda_canteiros k where k.user_id = alvo), '[]'::jsonb),
    'cesta', case when alvo = uid then coalesce((select jsonb_object_agg(fruta, qtd) from fazenda_cesta where user_id = uid and qtd > 0), '{}'::jsonb) end,
    'hoje', jsonb_build_object('comidas', coalesce(d.comidas, 0), 'regas', coalesce(d.regas, 0), 'xp', coalesce(d.xp, 0)),
    'limites', jsonb_build_object('frutas_dia', (c->>'frutas_dia')::int, 'regas_dia', (c->>'regas_dia')::int, 'regas_max', (c->>'regas_max')::int,
                                  'rega_pct', (c->>'rega_pct')::int, 'rega_fruta', (c->>'rega_fruta')::int, 'gosta_mult', (c->>'gosta_mult')::numeric,
                                  'canteiros', (c->>'canteiros')::int, 'canteiros_pomar', (c->>'canteiros_pomar')::int),
    'frutas', c->'frutas', 'agora', now());
end $$;

-- plantar: um canteiro, ou todos os vazios (_slot vazio). A semente custa moedas.
create or replace function public.fazenda_plantar(_slot int, _fruta text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.fazenda_cfg(); f jsonb := c->'frutas'->_fruta; me characters; tot int; sl int[]; custo int;
begin
  if not coalesce((c->>'on')::boolean, true) and not public.is_admin() then raise exception 'A Fazenda está fechada no momento.'; end if;
  if f is null then raise exception 'Fruta inválida.'; end if;
  tot := public.fazenda_total(uid);
  if _slot is null then
    select coalesce(array_agg(s order by s), '{}') into sl from generate_series(1, tot) s where not exists (select 1 from fazenda_canteiros k where k.user_id = uid and k.slot = s);
  else
    if _slot < 1 or _slot > tot then raise exception 'Esse canteiro não existe.'; end if;
    if exists (select 1 from fazenda_canteiros where user_id = uid and slot = _slot) then raise exception 'Esse canteiro já está plantado.'; end if;
    sl := array[_slot];
  end if;
  if cardinality(sl) = 0 then raise exception 'Não há canteiro vazio.'; end if;
  custo := (f->>'semente')::int * cardinality(sl);
  select * into me from characters where user_id = uid for update;
  if me.coins < custo then raise exception 'As sementes custam % moedas e você tem %.', custo, me.coins; end if;
  update characters set coins = coins - custo where user_id = uid;
  insert into fazenda_donos(user_id) values (uid) on conflict do nothing;
  insert into fazenda_canteiros(user_id, slot, fruta, pronto_em)
    select uid, s, _fruta, now() + (f->>'horas')::numeric * interval '1 hour' from unnest(sl) s;
  return jsonb_build_object('plantados', cardinality(sl), 'custo', custo, 'coins', me.coins - custo, 'estado', public.fazenda_estado(null));
end $$;

-- colher: um canteiro pronto, ou todos os prontos (_slot vazio). As frutas vão para a cesta.
create or replace function public.fazenda_colher(_slot int default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.fazenda_cfg(); k record; got jsonb := '{}'::jsonb; q int; n int := 0;
begin
  for k in select * from fazenda_canteiros where user_id = uid and pronto_em <= now() and (_slot is null or slot = _slot) order by slot for update loop
    q := coalesce((c->'frutas'->k.fruta->>'colheita')::int, 3);
    insert into fazenda_cesta(user_id, fruta, qtd) values (uid, k.fruta, q) on conflict (user_id, fruta) do update set qtd = fazenda_cesta.qtd + excluded.qtd;
    got := jsonb_set(got, array[k.fruta], to_jsonb(coalesce((got->>k.fruta)::int, 0) + q));
    delete from fazenda_canteiros where user_id = uid and slot = k.slot;
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Nada pronto para colher ainda.'; end if;
  return jsonb_build_object('colhidos', n, 'frutas', got, 'estado', public.fazenda_estado(null));
end $$;

-- regar a horta de outro jogador: a planta dele cresce mais rápido e quem regou ganha uma fruta igual
create or replace function public.fazenda_regar(_dono uuid, _slot int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.fazenda_cfg(); k fazenda_canteiros; d fazenda_dias; q int := coalesce((c->>'rega_fruta')::int, 1);
begin
  if not coalesce((c->>'on')::boolean, true) and not public.is_admin() then raise exception 'A Fazenda está fechada no momento.'; end if;
  if _dono = uid then raise exception 'A sua horta quem rega são os amigos!'; end if;
  select * into k from fazenda_canteiros where user_id = _dono and slot = _slot for update;
  if k.user_id is null then raise exception 'Esse canteiro está vazio.'; end if;
  if k.pronto_em <= now() then raise exception 'Essa fruta já está pronta para colher.'; end if;
  if uid = any(k.regadores) then raise exception 'Você já regou esse canteiro.'; end if;
  if cardinality(k.regadores) >= (c->>'regas_max')::int then raise exception 'Esse canteiro já foi regado o bastante.'; end if;
  insert into fazenda_dias(user_id, dia) values (uid, public.game_today()) on conflict do nothing;
  select * into d from fazenda_dias where user_id = uid and dia = public.game_today() for update;
  if d.regas >= (c->>'regas_dia')::int then raise exception 'Você já regou % canteiros hoje. Volte amanhã!', (c->>'regas_dia')::int; end if;
  update fazenda_dias set regas = regas + 1 where user_id = uid and dia = d.dia;
  update fazenda_canteiros set pronto_em = now() + (pronto_em - now()) * (1 - (c->>'rega_pct')::numeric / 100), regadores = regadores || uid
   where user_id = _dono and slot = _slot;
  if q > 0 then insert into fazenda_cesta(user_id, fruta, qtd) values (uid, k.fruta, q) on conflict (user_id, fruta) do update set qtd = fazenda_cesta.qtd + excluded.qtd; end if;
  return jsonb_build_object('ok', true, 'fruta', k.fruta, 'ganhou', q, 'regas', d.regas + 1, 'estado', public.fazenda_estado(_dono));
end $$;

-- hortas que você ainda pode regar (para achar rápido)
create or replace function public.fazenda_regaveis() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.fazenda_cfg();
begin
  if uid is null then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('user_id', x.user_id, 'nome', x.name, 'n', x.n) order by x.n desc, x.name)
    from (select k.user_id, ch.name, count(*) n from fazenda_canteiros k join characters ch on ch.user_id = k.user_id
           where k.user_id <> uid and k.pronto_em > now() and not (uid = any(k.regadores)) and cardinality(k.regadores) < (c->>'regas_max')::int
           group by k.user_id, ch.name order by count(*) desc limit 30) x), '[]'::jsonb);
end $$;

-- dar uma fruta para um Pokémon seu: experiência, mais quando o tipo dele gosta da fruta
create or replace function public.fazenda_dar(_mon uuid, _fruta text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.fazenda_cfg(); f jsonb := c->'frutas'->_fruta; m monsters; d fazenda_dias; tem int; gosta boolean; ganho int; lv1 int;
begin
  if not coalesce((c->>'on')::boolean, true) and not public.is_admin() then raise exception 'A Fazenda está fechada no momento.'; end if;
  if f is null then raise exception 'Fruta inválida.'; end if;
  select * into m from monsters where id = _mon and user_id = uid;
  if m.id is null then raise exception 'Esse Pokémon não é seu.'; end if;
  if m.level >= 100 then raise exception 'Esse Pokémon já está no nível máximo.'; end if;
  select qtd into tem from fazenda_cesta where user_id = uid and fruta = _fruta for update;
  if coalesce(tem, 0) < 1 then raise exception 'Você não tem essa fruta na cesta.'; end if;
  insert into fazenda_dias(user_id, dia) values (uid, public.game_today()) on conflict do nothing;
  select * into d from fazenda_dias where user_id = uid and dia = public.game_today() for update;
  if d.comidas >= (c->>'frutas_dia')::int then raise exception 'Seus Pokémon já comeram % frutas hoje. Amanhã tem mais!', (c->>'frutas_dia')::int; end if;
  gosta := exists (select 1 from pokemon p, jsonb_array_elements_text(f->'tipos') t(v) where p.id = m.species_id and (p.g1_type1 = t.v or p.g1_type2 = t.v));
  ganho := public.vale_xp_conta((f->>'xp')::numeric, m.level, 100, coalesce((c->>'xp_mult')::numeric, 1) * case when gosta then coalesce((c->>'gosta_mult')::numeric, 1) else 1 end);
  update fazenda_cesta set qtd = qtd - 1 where user_id = uid and fruta = _fruta;
  update fazenda_dias set comidas = comidas + 1, xp = fazenda_dias.xp + ganho where user_id = uid and dia = d.dia;
  perform public.pk_give_xp(m.id, ganho, 'fazenda');
  select level into lv1 from monsters where id = m.id;
  return jsonb_build_object('xp', ganho, 'gosta', gosta, 'nivel_antes', m.level, 'nivel_depois', lv1, 'especie', m.species_id, 'comidas', d.comidas + 1,
    'estado', public.fazenda_estado(null),
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.id) from mon_events e where e.user_id = uid and not e.seen), '[]'::jsonb));
end $$;

-- comprar um canteiro a mais
create or replace function public.fazenda_comprar_canteiro() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.fazenda_cfg(); pr jsonb := coalesce(c->'canteiros_precos', '[]'::jsonb); ex int; preco int; me characters;
begin
  insert into fazenda_donos(user_id) values (uid) on conflict do nothing;
  select extra into ex from fazenda_donos where user_id = uid for update;
  if ex >= jsonb_array_length(pr) then raise exception 'Sua fazenda já tem todos os canteiros que dá para comprar.'; end if;
  preco := (pr->>ex)::int;
  select * into me from characters where user_id = uid for update;
  if me.coins < preco then raise exception 'O canteiro custa % moedas e você tem %.', preco, me.coins; end if;
  update characters set coins = coins - preco where user_id = uid;
  update fazenda_donos set extra = extra + 1 where user_id = uid;
  return jsonb_build_object('ok', true, 'preco', preco, 'coins', me.coins - preco, 'estado', public.fazenda_estado(null));
end $$;

grant execute on function public.vale_estado(), public.vale_comecar(text, uuid), public.vale_terminar(bigint, int),
  public.fazenda_estado(uuid), public.fazenda_plantar(int, text), public.fazenda_colher(int), public.fazenda_regar(uuid, int),
  public.fazenda_regaveis(), public.fazenda_dar(uuid, text), public.fazenda_comprar_canteiro() to authenticated;
revoke execute on function public.vale_xp_conta(numeric, int, int, numeric) from public, anon, authenticated;

create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'leilao', public.leilao_cfg(), 'herois', public.herois_cfg(), 'temporada', public.temporada_cfg(), 'liga', public.liga_cfg(), 'pausa', public.pausa_cfg(), 'teto', public.teto_cfg(), 'boas_vindas', public.boas_vindas_cfg(), 'vila_bonus', public.vila_bonus_cfg(), 'tm_nivel', public.tm_nivel_cfg(), 'quiz_auto', public.quiz_auto_cfg(), 'cartas', public.tcg_cfg(), 'pokebound', public.pokebound_cfg(), 'visual', public.visual_cfg(), 'praca', public.praca_cfg(), 'rpg', public.rpg_cfg(), 'equip', public.equip_cfg(), 'base', public.cfg(), 'exp', public.exp_cfg(), 'vale', public.vale_cfg(), 'fazenda', public.fazenda_cfg());   -- arquivo 112: Vale do Treino e Fazenda   -- arquivo 111: Expedições
end $$;

grant execute on function public.admin_cfg_efetiva() to authenticated;

-- liga/desliga da vila nova (versão do 96 + vila_nova; Ajustes do jogo → 🖥️ Visual novo)
create or replace function public.visual_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "tela_cheia_padrao": true, "chat_fixo": true, "herois_novos": true, "mapa_novo": true, "corrida": true, "vila_nova": true}'::jsonb || coalesce(public.cfg()->'visual', '{}'::jsonb)
$$;
update public.game_config set config = jsonb_set(config, '{visual}', public.visual_cfg()) where active;
revoke execute on function public.visual_cfg() from public, anon, authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values
   ('🥋 Vale do Treino na Aventura', 'Agora dá para evoluir os Pokémon sem lutar na grama: chegou o Vale do Treino, na trilha ao norte da Vila Aurora (Aventura).
• São 6 estações: Pista de Corrida, Saco de Pancada, Templo da Meditação, Lago das Correntes, Paredão de Escalada e Fogueira do Fôlego.
• Em cada uma o seu Pokémon faz um exercício rápido (uns 20 segundos): acertar o ritmo, repetir a sequência, lembrar das luzes, desviar das pedras, escalar rápido e segurar a chama.
• Quanto melhor você joga, mais experiência o Pokémon ganha.
• Cada estação combina com alguns tipos (⭐): treinar o Pokémon no lugar certo rende mais.
• Tem um limite de treinos por dia. Os outros jogadores que estão no Vale aparecem andando por lá.'),
   ('🍓 Fazenda de Frutas e vila nova', 'A Minha Vila ficou maior e mais bonita (no computador ela abre em tela grande), e ganhou uma Fazenda de Frutas.
• Plante sementes nos canteiros (custam poucas moedas). As frutas crescem em algumas horas de verdade; depois é só colher.
• Dê as frutas para os seus Pokémon: eles ganham experiência. Cada tipo de Pokémon tem a sua fruta preferida (❤️), que rende mais.
• Visite a vila dos amigos e regue a horta deles: a planta cresce mais rápido e você ganha uma fruta igual.
• Quem tem o Pomar na vila ganha canteiros a mais, e dá para comprar outros.
• Os Pokémon comem um número de frutas por dia.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
