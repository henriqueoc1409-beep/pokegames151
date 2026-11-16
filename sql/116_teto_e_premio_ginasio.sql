-- Arquivo 116 (pedido do dono em 17/11/2026, aprovado pelo grupo):
-- (1) Teto escolhido no desafio: nas batalhas Pokémon entre jogadores valendo moedas, quem desafia escolhe o teto (`teto.opcoes`:
--     5, 10, 15, 20, 25, 30, 40 ou 0 = sem teto); sem escolher, vale o teto da temporada (`teto.nivel`). Quem está abaixo luta no nível real;
--     acima, luta no teto com todos os atributos daquele nível (a mesma conta de sempre, `bt_mon_teto`). O desafio da Aventura continua com 20.
-- (2) Prêmio dos Ginásios pela dificuldade: moedas = nível médio do time do Líder × `ginasios.moedas_por_nivel` (10); itens, Doces de
--     Forja e TM pela faixa da rota (`ginasios.faixas`). Revanche liberada: quem já tem a insígnia pode enfrentar o Líder de novo (nas mesmas
--     tentativas do dia) e ganha `ginasios.revanche_pct` (25) % das moedas.

alter table public.battles add column if not exists teto int;   -- null = teto da temporada; 0 = sem teto

drop function if exists public.battle_challenge(uuid, int);
create or replace function public.battle_challenge(_opponent uuid, _bet int, _teto int default null) returns public.battles
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.pk_cfg()->'battle'; b battles; nm text; tx text;
  bmin int := coalesce((public.cfg()->>'battle_bet_min')::int, 10); bmax int := coalesce((public.cfg()->>'battle_bet_max')::int, 100); mc int; oc int;
begin
  if _opponent = uid then raise exception 'Você não pode batalhar contra você mesmo.'; end if;
  if not exists (select 1 from characters where user_id = _opponent) then raise exception 'Jogador não encontrado.'; end if;
  if (select count(*) from monsters where user_id = uid) < (c->>'min_captured')::int then
    raise exception 'Você precisa de pelo menos % Pokémon capturados para batalhar.', c->>'min_captured'; end if;
  if (select count(*) from monsters where user_id = _opponent) < (c->>'min_captured')::int then
    raise exception 'Esse jogador ainda não tem % Pokémon capturados.', c->>'min_captured'; end if;
  if not exists (select 1 from monsters where user_id = uid and team_slot is not null) then raise exception 'Monte sua equipe antes de desafiar alguém.'; end if;
  if exists (select 1 from battles where status in ('convite','ativa') and ((p1 = uid and p2 = _opponent) or (p1 = _opponent and p2 = uid))) then
    raise exception 'Já existe uma batalha aberta entre vocês.'; end if;
  if _bet is null or _bet < bmin or _bet > bmax then raise exception 'A aposta vai de % a % moedas.', bmin, bmax; end if;
  -- arquivo 116: o teto escolhido precisa estar na lista dos Ajustes
  if _teto is not null and not (public.teto_cfg()->'opcoes' @> to_jsonb(_teto)) then
    raise exception 'Escolha o teto entre: %.', (select string_agg(case when x::int = 0 then 'sem teto' else x end, ', ') from jsonb_array_elements_text(public.teto_cfg()->'opcoes') x);
  end if;
  select coins into mc from characters where user_id = uid for update;
  select coins into oc from characters where user_id = _opponent;
  if mc < _bet then raise exception 'Você não tem % moedas para apostar.', _bet; end if;
  if oc < _bet then raise exception 'Esse jogador só tem % moedas: aposte menos.', oc; end if;
  update characters set coins = coins - _bet where user_id = uid;
  insert into battles(p1, p2, size, bet, bet_held, teto) values (uid, _opponent, (c->>'size')::int, _bet, true, _teto) returning * into b;
  select name into nm from characters where user_id = uid;
  tx := case when _teto = 0 then ', sem teto de nível' when _teto is not null then ', com teto no nível ' || _teto else '' end;
  insert into event_log(user_id, kind, message) select uid, 'batalha', nm || ' desafiou ' || ch.name || ' para uma batalha Pokémon valendo ' || _bet || ' moedas' || tx || '!' from characters ch where ch.user_id = _opponent;
  return b;
end $$;

-- prêmio do Ginásio pela dificuldade (o que o site mostra e o que a vitória paga)
create or replace function public.rpg_gin_premio(_regiao text) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare c jsonb := public.rpg_cfg()->'ginasios'; l rpg_lideres; media numeric; f jsonb;
begin
  select * into l from rpg_lideres where regiao = _regiao;
  if l.regiao is null then return null; end if;
  select avg((e->>1)::int) into media from jsonb_array_elements(l.time) e;
  select value into f from jsonb_each(coalesce(c->'faixas', '{}'::jsonb)) where value->'rotas' ? _regiao limit 1;
  return jsonb_build_object('moedas', round(coalesce(media, 0) * coalesce((c->>'moedas_por_nivel')::numeric, 10))::int, 'nivel_medio', round(coalesce(media, 0))::int,
    'itens', coalesce(f->'itens', '{}'::jsonb), 'doces', coalesce((f->>'doces')::int, 0), 'tm', coalesce((f->>'tm')::int, 0),
    'revanche_pct', coalesce((c->>'revanche_pct')::int, 25));
end $$;

-- vitória no Ginásio: a 1ª vez dá a insígnia e o prêmio da faixa; a revanche, uma parte das moedas
create or replace function public.rpg_gin_vitoria(_uid uuid, _regiao text, _lider text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rpg_cfg(); pr jsonb := public.rpg_gin_premio(_regiao); nome text; n int; drop_ jsonb; tm text; k int; moedas int;
begin
  select name into nome from characters where user_id = _uid;
  if exists (select 1 from rpg_insignias where user_id = _uid and regiao = _regiao) then   -- revanche
    moedas := floor((pr->>'moedas')::int * (pr->>'revanche_pct')::numeric / 100)::int;
    perform public.rpg_premiar(_uid, moedas, '{}'::jsonb);
    insert into event_log(user_id, kind, message) values (_uid, 'ginasio', '🏟️ ' || nome || ' venceu a revanche contra ' || _lider || '!');
    return jsonb_build_object('revanche', true, 'premio', jsonb_build_object('moedas', moedas));
  end if;
  insert into rpg_insignias(user_id, regiao) values (_uid, _regiao) on conflict do nothing;
  perform public.rpg_premiar(_uid, (pr->>'moedas')::int, pr->'itens');
  if (pr->>'doces')::int > 0 then
    insert into equip_doces(user_id, qty) values (_uid, (pr->>'doces')::int) on conflict (user_id) do update set qty = equip_doces.qty + (pr->>'doces')::int;
  end if;
  for k in 1 .. coalesce((pr->>'tm')::int, 0) loop
    select id into tm from pk_items where kind = 'tm' and coalesce(price, 0) > 0 order by random() limit 1;
    if tm is not null then insert into bag_items(user_id, item, qty) values (_uid, tm, 1) on conflict (user_id, item) do update set qty = bag_items.qty + 1; end if;
  end loop;
  drop_ := public.equip_drop(_uid, 'ginasio');
  insert into event_log(user_id, kind, message) values (_uid, 'ginasio', '🏅 ' || nome || ' venceu ' || _lider || ' e ganhou a insígnia do Ginásio!');
  select count(*) into n from rpg_insignias where user_id = _uid;
  if n >= (select count(*) from rpg_lideres) then
    perform public.rpg_premiar(_uid, (c->'ginasios'->>'todas_moedas')::int, c->'ginasios'->'todas_itens');
    insert into event_log(user_id, kind, message) values (_uid, 'ginasio', '👑 ' || nome || ' juntou TODAS as insígnias da Aventura!');
  end if;
  return coalesce(drop_, '{}'::jsonb) || jsonb_build_object('premio', pr || jsonb_build_object('tm_item', tm));
end $$;


-- teto_cfg: versão do 81 com a mudança do arquivo 116
create or replace function public.teto_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "nivel": 20, "opcoes": [5, 10, 15, 20, 25, 30, 40, 0]}'::jsonb || coalesce(public.cfg()->'teto', '{}'::jsonb)
$$;


-- battle_respond: versão do 77 com a mudança do arquivo 116
create or replace function public.battle_respond(_id uuid, _accept boolean) returns public.battles
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); b battles; c jsonb := public.pk_cfg()->'battle'; s1 jsonb; s2 jsonb; c1 int; c2 int; tt int;
begin
  select * into b from battles where id = _id for update;
  if b.id is null or b.p2 <> uid then raise exception 'Convite não encontrado.'; end if;
  if b.status <> 'convite' then raise exception 'Esse convite já foi respondido.'; end if;
  if not _accept then
    if b.bet > 0 and b.bet_held then update characters set coins = coins + b.bet where user_id = b.p1; end if;   -- devolve a reserva
    update battles set status = 'recusada', ended_at = now(), bet_held = false where id = b.id returning * into b; return b;
  end if;
  if (select count(*) from monsters where user_id = uid) < (c->>'min_captured')::int then
    raise exception 'Você precisa de pelo menos % Pokémon capturados para batalhar.', c->>'min_captured'; end if;
  if not exists (select 1 from monsters where user_id = uid and team_slot is not null) then raise exception 'Monte sua equipe antes de aceitar.'; end if;
  if not exists (select 1 from monsters where user_id = b.p1 and team_slot is not null) then raise exception 'O desafiante está sem equipe agora.'; end if;
  -- aposta: as moedas dos dois ficam guardadas na batalha até o fim (quem vence leva tudo; empate devolve)
  if b.bet > 0 then
    perform 1 from characters where user_id in (b.p1, b.p2) order by user_id for update;
    select coins into c1 from characters where user_id = b.p1;
    select coins into c2 from characters where user_id = b.p2;
    if c2 < b.bet then raise exception 'A aposta é de % moedas e você tem %.', b.bet, c2; end if;
    if not b.bet_held and c1 < b.bet then raise exception 'O desafiante não tem mais as % moedas da aposta.', b.bet; end if;
    -- quem desafiou já pagou ao desafiar (convites antigos, de antes deste arquivo, pagam agora)
    update characters set coins = coins - b.bet where user_id = b.p2 or (user_id = b.p1 and not b.bet_held);
  end if;
  -- arquivo 77: batalha valendo moedas = ninguém luta acima do teto da temporada
  tt := case when b.bet > 0 and coalesce(b.mode, 'duelo') not in ('liga', 'guerra') then case when b.teto = 0 then null else coalesce(b.teto, public.teto_nivel()) end end;   -- arquivo 116: o teto escolhido no desafio
  select jsonb_build_object('user', b.p1, 'name', (select name from characters where user_id = b.p1), 'active', 0, 'need_switch', false,
         'mons', jsonb_agg(public.bt_mon_teto(m.id, tt) order by m.team_slot)) into s1
    from (select id, team_slot from monsters where user_id = b.p1 and team_slot is not null order by team_slot limit b.size) m;
  select jsonb_build_object('user', b.p2, 'name', (select name from characters where user_id = b.p2), 'active', 0, 'need_switch', false,
         'mons', jsonb_agg(public.bt_mon_teto(m.id, tt) order by m.team_slot)) into s2
    from (select id, team_slot from monsters where user_id = b.p2 and team_slot is not null order by team_slot limit b.size) m;
  update battles set status = 'ativa', turn = 1, phase = 'normal', started_at = now(), bet_paid = b.bet > 0,
         deadline = now() + make_interval(hours => (c->>'turn_hours')::int),
         state = jsonb_build_object('sides', jsonb_build_array(s1, s2), 'xp', '{}'::jsonb),
         log = jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
                 jsonb_build_object('txt', (s1->>'name') || ' mandou ' || (s1->'mons'->0->>'name') || '!'),
                 jsonb_build_object('txt', (s2->>'name') || ' mandou ' || (s2->'mons'->0->>'name') || '!'))))
   where id = b.id returning * into b;
  return b;
end $$;


-- rpg_cfg: versão do 113 com a mudança do arquivo 116
create or replace function public.rpg_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select ('{"on": true, "batalhas_dia": 20, "chance_pct": 12, "espera_seg": 8, "envio_seg": 1.2, "fuga_base": 10, "fuga_por_ataque": 10, "nivel_pedra": 28, "nivel_troca": 36, "folga": 10, "lendarios": [144, 145, 146, 150, 151, 243, 244, 245, 249, 250, 251], "zonas": {"mato": {"nome": "Capim alto", "regiao": "vila", "tipos": ["INSETO", "PLANTA", "NORMAL"], "min": 2, "max": 6}, "escura": {"nome": "Grama escura", "regiao": "vila", "tipos": ["NORMAL", "VOADOR", "ELETRICO"], "min": 3, "max": 7}, "pantano": {"nome": "Pântano", "regiao": "vila", "tipos": ["AGUA", "VENENO"], "min": 3, "max": 7}, "pedra": {"nome": "Alto do penhasco", "regiao": "vila", "tipos": ["PEDRA", "TERRA", "LUTA"], "min": 4, "max": 8}, "bosque": {"nome": "Bosque: mato", "regiao": "bosque", "tipos": ["INSETO", "PLANTA", "VENENO", "NORMAL"], "min": 8, "max": 16}, "bosque_fundo": {"nome": "Bosque: mata funda", "regiao": "bosque", "tipos": ["INSETO", "PLANTA", "VENENO", "NORMAL", "VOADOR"], "min": 18, "max": 34}, "praia": {"nome": "Praia: dunas", "regiao": "praia", "tipos": ["AGUA", "ELETRICO", "NORMAL"], "min": 8, "max": 16}, "praia_fundo": {"nome": "Praia: costão", "regiao": "praia", "tipos": ["AGUA", "ELETRICO", "GELO", "VOADOR"], "min": 18, "max": 38}, "deserto": {"nome": "Deserto: capim seco", "regiao": "deserto", "tipos": ["FOGO", "TERRA", "NORMAL"], "min": 12, "max": 22}, "deserto_fundo": {"nome": "Deserto: oásis distante", "regiao": "deserto", "tipos": ["FOGO", "TERRA", "PEDRA", "LUTA"], "min": 24, "max": 42}, "pedreira": {"nome": "Pedreira: entrada", "regiao": "pedreira", "tipos": ["PEDRA", "TERRA", "LUTA", "METALICO"], "min": 12, "max": 22}, "pedreira_fundo": {"nome": "Pedreira: fundo da gruta", "regiao": "pedreira", "tipos": ["PEDRA", "TERRA", "LUTA", "METALICO", "DRAGAO"], "min": 24, "max": 44}, "charco": {"nome": "Charco: margem", "regiao": "charco", "tipos": ["VENENO", "FANTASMA", "PSIQUICO", "SOMBRIO"], "min": 20, "max": 32}, "charco_fundo": {"nome": "Charco: brejo escuro", "regiao": "charco", "tipos": ["FANTASMA", "PSIQUICO", "SOMBRIO", "VENENO", "NORMAL"], "min": 32, "max": 46}, "pico": {"nome": "Pico: encosta", "regiao": "pico", "tipos": ["GELO", "AGUA", "PSIQUICO", "VOADOR", "ELETRICO"], "min": 34, "max": 48}, "pico_fundo": {"nome": "Pico: cume", "regiao": "pico", "tipos": ["DRAGAO", "GELO", "VOADOR", "PSIQUICO", "FOGO", "LUTA", "NORMAL", "PEDRA"], "min": 45, "max": 60}, "vulcao": {"nome": "Vulcão: encosta", "regiao": "vulcao", "tipos": ["FOGO", "PEDRA", "TERRA", "LUTA"], "min": 40, "max": 50}, "vulcao_fundo": {"nome": "Vulcão: cratera", "regiao": "vulcao", "tipos": ["FOGO", "DRAGAO", "PEDRA", "TERRA", "VOADOR"], "min": 48, "max": 60}, "estrada": {"nome": "Estrada da Vitória: trilha", "regiao": "estrada", "tipos": ["LUTA", "PEDRA", "TERRA", "VENENO", "VOADOR", "NORMAL"], "min": 52, "max": 62}, "estrada_fundo": {"nome": "Estrada da Vitória: desfiladeiro", "regiao": "estrada", "tipos": ["DRAGAO", "PSIQUICO", "LUTA", "GELO", "FANTASMA", "AGUA"], "min": 58, "max": 70}}}'::jsonb || '{"pvp": {"on": true, "distancia": 2, "desafia_dia": 1, "recebe_dia": 3, "teto": true, "prazo_horas": 24, "oferta_min": 1}}'::jsonb || '{"noite": {"on": true, "inicio": 19, "fim": 5, "tipos": ["FANTASMA", "SOMBRIO"]}, "missoes": {"on": true, "por_dia": 3, "moedas_min": 15, "moedas_max": 40, "itens": ["pocao", "super_pocao", "hiper_pocao", "reviver", "antidoto", "despertar", "cura_paralisia", "x_ataque", "x_defesa", "x_velocidade", "x_especial"]}, "ginasios": {"on": true, "tentativas_dia": 3, "expira_min": 30, "moedas_por_nivel": 10, "revanche_on": true, "revanche_pct": 25, "faixas": {"iniciais": {"rotas": ["bosque", "praia", "deserto"], "itens": {"super_pocao": 1, "reviver": 1}, "doces": 1}, "intermediarias": {"rotas": ["pedreira", "charco", "pico"], "itens": {"hiper_pocao": 1, "reviver": 2}, "doces": 2}, "finais": {"rotas": ["vulcao", "estrada"], "itens": {"max_pocao": 1, "restaurar_tudo": 1}, "doces": 3, "tm": 1}}, "moedas": 300, "itens": {"max_pocao": 2, "reviver": 2}, "todas_moedas": 1000, "todas_itens": {"restaurar_tudo": 5}, "lideres": {"bosque": {"nome": "Líder Flora", "classe": "domador", "tipo": "Inseto e Planta", "time": [[12, 30], [47, 31], [71, 33], [3, 35]]}, "praia": {"nome": "Líder Marina", "classe": "arqueiro", "tipo": "Água e Elétrico", "time": [[55, 34], [101, 35], [131, 36], [121, 38]]}, "deserto": {"nome": "Líder Brasa", "classe": "guerreiro", "tipo": "Fogo e Terra", "time": [[51, 38], [59, 40], [112, 41], [6, 42]]}, "pedreira": {"nome": "Líder Rocha", "classe": "mercador", "tipo": "Pedra", "time": [[76, 40], [139, 42], [141, 43], [142, 44]]}, "charco": {"nome": "Líder Sombra", "classe": "mago", "tipo": "Fantasma e Psíquico", "time": [[93, 44], [97, 45], [65, 46], [94, 47]]}, "pico": {"nome": "Líder Neve", "classe": "clerigo", "tipo": "Gelo e Dragão", "time": [[87, 56], [91, 57], [131, 58], [149, 60]]}}}, "chefe": {"on": true, "dia_semana": 6, "hora": 10, "horas": 48, "nivel": 75, "vidas": 40, "turnos": 12, "tentativas_dia": 3, "especies": [149, 130, 143, 112, 94, 68, 131, 59, 6, 65], "moedas": 250, "itens": {"restaurar_tudo": 1, "reviver": 1}, "top_moedas": [300, 200, 100]}}'::jsonb
    || '{"elite": {"on": true, "insignias_min": 8, "tentativas_dia": 1, "time_max": 6, "moedas": 5000, "itens": {"restaurar_tudo": 5, "reviver": 5}, "doces": 5, "repetir_moedas": 1000, "repetir_doces": 1}}'::jsonb
    || coalesce(public.cfg()->'rpg', '{}'::jsonb)) #- '{ginasios,lideres}'   -- arquivo 101: os times dos Líderes ficam na tabela rpg_lideres
$$;

update public.game_config set config = jsonb_set(config, '{rpg,ginasios}', (public.rpg_cfg()->'ginasios') || (config->'rpg'->'ginasios') ||
       jsonb_build_object('moedas_por_nivel', coalesce(config->'rpg'->'ginasios'->'moedas_por_nivel', '10'::jsonb), 'revanche_on', coalesce(config->'rpg'->'ginasios'->'revanche_on', 'true'::jsonb),
         'revanche_pct', coalesce(config->'rpg'->'ginasios'->'revanche_pct', '25'::jsonb), 'faixas', coalesce(config->'rpg'->'ginasios'->'faixas', '{"iniciais": {"rotas": ["bosque", "praia", "deserto"], "itens": {"super_pocao": 1, "reviver": 1}, "doces": 1}, "intermediarias": {"rotas": ["pedreira", "charco", "pico"], "itens": {"hiper_pocao": 1, "reviver": 2}, "doces": 2}, "finais": {"rotas": ["vulcao", "estrada"], "itens": {"max_pocao": 1, "restaurar_tudo": 1}, "doces": 3, "tm": 1}}'::jsonb)))
 where active and jsonb_typeof(config->'rpg'->'ginasios') = 'object';


-- rpg_ginasio_lutar: versão do 113 com a mudança do arquivo 116
create or replace function public.rpg_ginasio_lutar(_regiao text, _comp uuid default null, _meus uuid[] default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.rpg_cfg()->'ginasios'; l rpg_lideres; me characters; t rpg_gin_tent; bid uuid; n int; nl int;
  e jsonb; k int; pos int := 0; w jsonb; ocultos jsonb := '[]'::jsonb; mine jsonb := '[]'::jsonb; wild jsonb := '[]'::jsonb; x uuid; hp int; s0 jsonb; s1 jsonb;
begin
  if not coalesce((c->>'on')::boolean, true) and not public.is_admin() then raise exception 'Os Ginásios estão fechados no momento.'; end if;
  select * into l from rpg_lideres where regiao = _regiao;
  if l.regiao is null then raise exception 'Não há Ginásio aqui.'; end if;
  nl := jsonb_array_length(l.time);
  if not coalesce((c->>'revanche_on')::boolean, true) and exists (select 1 from rpg_insignias where user_id = uid and regiao = _regiao) then raise exception 'Você já tem a insígnia deste Ginásio.'; end if;   -- arquivo 116: revanche
  select * into me from characters where user_id = uid for update;
  perform public.treino_autocura(uid);   -- também encerra a batalha de Ginásio que passou do prazo
  bid := public.treino_batalha(uid);
  if bid is not null then return jsonb_build_object('battle', bid); end if;   -- volta para a batalha em andamento
  update rpg_gin_tent set status = 'perdeu' where user_id = uid and status = 'andando' and dia < public.game_today();
  if _meus is null or cardinality(_meus) <> nl or (select count(distinct y) from unnest(_meus) y) <> nl then
    raise exception 'Escolha % Pokémon diferentes para enfrentar o Líder.', nl;
  end if;
  if (select count(*) from monsters where user_id = uid and id = any(_meus) and tr_hp > 0) <> nl then
    raise exception 'Escolha só Pokémon seus que estejam com vida.';
  end if;
  -- tentativa do dia (uma tentativa antiga, da regra de antes, sem batalha, é aproveitada e não gasta outra)
  select * into t from rpg_gin_tent where user_id = uid and regiao = _regiao and dia = public.game_today() and status = 'andando' order by id desc limit 1;
  if t.id is null then
    select count(*) into n from rpg_gin_tent where user_id = uid and regiao = _regiao and dia = public.game_today();
    if n >= (c->>'tentativas_dia')::int then raise exception 'Você já usou as % tentativas de hoje neste Ginásio. Volte amanhã!', (c->>'tentativas_dia'); end if;
    insert into rpg_gin_tent(user_id, regiao, dia, hp, meus, ordem)
    values (uid, _regiao, public.game_today(), (select jsonb_agg(100) from generate_series(1, nl)), to_jsonb(_meus),
            (select jsonb_agg(i order by random()) from generate_series(0, nl - 1) i))   -- ordem do Líder sorteada
    returning * into t;
  else
    update rpg_gin_tent set meus = to_jsonb(_meus), idx = 0, hp = (select jsonb_agg(100) from generate_series(1, nl)),
           ordem = (select jsonb_agg(i order by random()) from generate_series(0, nl - 1) i) where id = t.id returning * into t;
  end if;
  if _comp is not null and (_comp = any(_meus) or not exists (select 1 from monsters where id = _comp and user_id = uid)
     or coalesce((select tr_hp from monsters where id = _comp), 100) <= 0) then _comp := null; end if;
  delete from battles where mode = 'treino' and p1 = uid and status <> 'ativa';
  -- os seus, na ordem escolhida (o Peitoral dá resistência, como nas outras lutas da Aventura)
  foreach x in array _meus loop
    select tr_hp into hp from monsters where id = x;
    mine := mine || public.rpg_mine(x, uid, hp);
  end loop;
  -- os do Líder, na ordem sorteada, com os ataques guardados no time
  for k in select v::int from jsonb_array_elements_text(t.ordem) with ordinality o(v, ord) order by ord loop
    e := l.time->k;
    w := public.ia_mon((e->>0)::int, (e->>1)::int,
      case when jsonb_typeof(e->2) = 'array' and jsonb_array_length(e->2) > 0 then (select array_agg(v::int order by ord) from jsonb_array_elements_text(e->2) with ordinality z(v, ord)) end, true);
    if pos = 0 then wild := wild || jsonb_build_array(w);
    else   -- ainda não entrou: na batalha fica só um lugar guardado, sem nome nem espécie
      ocultos := ocultos || jsonb_build_array(jsonb_build_object('idx', pos, 'mon', w));
      wild := wild || jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'name', 'Pokémon do Líder', 'known', false, 'oculto', true, 'level', 0,
        'hp', 1, 'maxhp', 1, 'atk', 1, 'def', 1, 'spd', 1, 'spc', 1, 'bspd', 1, 'bexp', 0, 'moves', '[]'::jsonb, 'status', null, 'sleep', 0, 'conf', 0,
        'st', '{"atk":0,"def":0,"spd":0,"spc":0,"acc":0,"eva":0}'::jsonb, 'fl', '{}'::jsonb, 'outfit', '{}'::jsonb));
    end if;
    pos := pos + 1;
  end loop;
  s0 := jsonb_build_object('user', uid, 'name', me.name, 'active', 0, 'need_switch', false, 'mons', mine);
  s1 := jsonb_build_object('user', uid, 'name', l.nome, 'npc', true, 'active', 0, 'need_switch', false, 'mons', wild);
  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (uid, uid, 'treino', nl, 'ativa', 1, 'normal', now(),
          jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb, 'treino', jsonb_build_object('mon', _meus[1], 'forte', false, 'comp', _comp,
            'gym', _regiao, 'gym_try', t.id, 'multi', true, 'part', jsonb_build_object('0', jsonb_build_array(0)))),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', l.nome || ' aceitou o desafio! São ' || nl || ' contra ' || nl || '.'),
            jsonb_build_object('txt', l.nome || ' manda ' || (wild->0->>'name') || ' (nível ' || (wild->0->>'level') || ')!'),
            jsonb_build_object('txt', 'Vai, ' || (mine->0->>'name') || '!' || case when (mine->0->>'hp')::int < (mine->0->>'maxhp')::int then ' (ferido)' else '' end)))))
  returning id into bid;
  update rpg_gin_tent set batalha = bid where id = t.id;
  insert into rpg_gin_ocultos(battle_id, idx, mon) select bid, (o->>'idx')::int, o->'mon' from jsonb_array_elements(ocultos) o;
  return jsonb_build_object('battle', bid);
end $$;


-- rpg_ginasio: versão do 113 com a mudança do arquivo 116
create or replace function public.rpg_ginasio(_regiao text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.rpg_cfg()->'ginasios'; l rpg_lideres; n int; bat battles;
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  select * into l from rpg_lideres where regiao = _regiao;
  if l.regiao is null then raise exception 'Não há Ginásio aqui.'; end if;
  perform public.treino_autocura(uid);
  update rpg_gin_tent set status = 'perdeu' where user_id = uid and status = 'andando' and dia < public.game_today();
  select * into bat from battles where mode = 'treino' and p1 = uid and status = 'ativa' and state->'treino' ? 'multi' order by created_at desc limit 1;
  select count(*) into n from rpg_gin_tent where user_id = uid and regiao = _regiao and dia = public.game_today()
     and not (status = 'andando' and batalha is null);   -- a tentativa antiga sem batalha não conta
  return jsonb_build_object('lider', jsonb_build_object('nome', l.nome, 'classe', l.classe, 'tipo', l.tipo, 'n', jsonb_array_length(l.time)),
    'insignia', exists (select 1 from rpg_insignias where user_id = uid and regiao = _regiao),
    'tentativas', n, 'tentativas_dia', (c->>'tentativas_dia')::int, 'moedas', (public.rpg_gin_premio(_regiao)->>'moedas')::int, 'itens', public.rpg_gin_premio(_regiao)->'itens', 'premio', public.rpg_gin_premio(_regiao), 'revanche', coalesce((c->>'revanche_on')::boolean, true),
    'itens_batalha', coalesce((public.items_cfg()->>'per_battle')::int, 2), 'expira_min', coalesce((c->>'expira_min')::int, 30),
    'batalha', case when bat.id is null then null else jsonb_build_object('id', bat.id, 'regiao', bat.state->'treino'->>'gym',
      'fim', bat.started_at + make_interval(mins => coalesce((c->>'expira_min')::int, 30))) end,
    'tentativa', null);
end $$;


revoke execute on function public.rpg_gin_premio(text), public.rpg_gin_vitoria(uuid, text, text) from public, anon, authenticated;
grant execute on function public.battle_challenge(uuid, int, int), public.battle_respond(uuid, boolean), public.rpg_ginasio(text), public.rpg_ginasio_lutar(text, uuid, uuid[]) to authenticated;

-- ---------- novidades no Jornal, publicadas sozinhas ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values
   ('📏 Batalhas: quem desafia escolhe o teto de nível', 'Nas batalhas Pokémon valendo moedas, quem desafia agora escolhe o teto de nível: 5, 10, 15, 20, 25, 30, 40 ou sem teto (sem escolher, vale o teto da temporada).
• Quem recebe o desafio vê o teto e a aposta antes de aceitar.
• Pokémon abaixo do teto lutam no nível de verdade. Acima, lutam com a força do nível do teto (vida, ataque, defesa, velocidade e especial).
• As TMs e a experiência seguem o nível da batalha.
• O desafio dentro da Aventura continua com teto 20.'),
   ('🏅 Ginásios: prêmio pela dificuldade e revanche', 'O prêmio dos Ginásios da Aventura agora acompanha a dificuldade:
• Moedas: nível médio do time do Líder × 10.
• Rotas iniciais (Bosque, Praia, Deserto): Super Potion, Revive e 1 Doce de Forja.
• Rotas intermediárias (Pedreira, Charco, Pico): Hyper Potion, 2 Revives e 2 Doces de Forja.
• Rotas finais (Vulcão Cinzento, Estrada da Vitória): Max Potion, Full Restore, 1 TM surpresa e 3 Doces de Forja.
• Revanche: quem já tem a insígnia pode enfrentar o Líder de novo e ganha 25% das moedas.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
