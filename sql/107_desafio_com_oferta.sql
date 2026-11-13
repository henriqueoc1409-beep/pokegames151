-- 107_desafio_com_oferta.sql
-- Pedido do dono em 13/11/2026 ("o encontro obrigatório está atrapalhando o jogo"): na Aventura, o desafio entre jogadores
-- deixa de ser obrigatório na hora. (1) Cada um desafia 1 jogador por dia (rpg.pvp.desafia_dia). (2) O desafio vira um convite
-- (rpg_pvp_desafios); quem foi desafiado escolhe: lutar (a batalha começa) ou oferecer moedas para não lutar (as moedas ficam
-- guardadas). (3) Quem desafiou decide: aceita as moedas (não tem batalha) ou recusa (as moedas voltam e a batalha acontece).
-- (4) Sem resposta em rpg.pvp.prazo_horas (24), o desafio some sem batalha e a oferta volta. A batalha é a mesma do arquivo 102.
-- Nova rpg_cfg (versão do 106); rpg_desafiar agora devolve o convite (jsonb). Funções do site: rpg_desafiar,
-- rpg_desafio_responder, rpg_desafio_decidir, rpg_pvp_pendentes.

create or replace function public.rpg_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select ('{"on": true, "batalhas_dia": 20, "chance_pct": 12, "espera_seg": 8, "envio_seg": 1.2, "fuga_base": 10, "fuga_por_ataque": 10, "nivel_pedra": 28, "nivel_troca": 36, "folga": 10, "lendarios": [144, 145, 146, 150, 151, 243, 244, 245, 249, 250, 251], "zonas": {"mato": {"nome": "Capim alto", "regiao": "vila", "tipos": ["INSETO", "PLANTA", "NORMAL"], "min": 2, "max": 6}, "escura": {"nome": "Grama escura", "regiao": "vila", "tipos": ["NORMAL", "VOADOR", "ELETRICO"], "min": 3, "max": 7}, "pantano": {"nome": "Pântano", "regiao": "vila", "tipos": ["AGUA", "VENENO"], "min": 3, "max": 7}, "pedra": {"nome": "Alto do penhasco", "regiao": "vila", "tipos": ["PEDRA", "TERRA", "LUTA"], "min": 4, "max": 8}, "bosque": {"nome": "Bosque: mato", "regiao": "bosque", "tipos": ["INSETO", "PLANTA", "VENENO", "NORMAL"], "min": 8, "max": 16}, "bosque_fundo": {"nome": "Bosque: mata funda", "regiao": "bosque", "tipos": ["INSETO", "PLANTA", "VENENO", "NORMAL", "VOADOR"], "min": 18, "max": 34}, "praia": {"nome": "Praia: dunas", "regiao": "praia", "tipos": ["AGUA", "ELETRICO", "NORMAL"], "min": 8, "max": 16}, "praia_fundo": {"nome": "Praia: costão", "regiao": "praia", "tipos": ["AGUA", "ELETRICO", "GELO", "VOADOR"], "min": 18, "max": 38}, "deserto": {"nome": "Deserto: capim seco", "regiao": "deserto", "tipos": ["FOGO", "TERRA", "NORMAL"], "min": 12, "max": 22}, "deserto_fundo": {"nome": "Deserto: oásis distante", "regiao": "deserto", "tipos": ["FOGO", "TERRA", "PEDRA", "LUTA"], "min": 24, "max": 42}, "pedreira": {"nome": "Pedreira: entrada", "regiao": "pedreira", "tipos": ["PEDRA", "TERRA", "LUTA", "METALICO"], "min": 12, "max": 22}, "pedreira_fundo": {"nome": "Pedreira: fundo da gruta", "regiao": "pedreira", "tipos": ["PEDRA", "TERRA", "LUTA", "METALICO", "DRAGAO"], "min": 24, "max": 44}, "charco": {"nome": "Charco: margem", "regiao": "charco", "tipos": ["VENENO", "FANTASMA", "PSIQUICO", "SOMBRIO"], "min": 20, "max": 32}, "charco_fundo": {"nome": "Charco: brejo escuro", "regiao": "charco", "tipos": ["FANTASMA", "PSIQUICO", "SOMBRIO", "VENENO", "NORMAL"], "min": 32, "max": 46}, "pico": {"nome": "Pico: encosta", "regiao": "pico", "tipos": ["GELO", "AGUA", "PSIQUICO", "VOADOR", "ELETRICO"], "min": 34, "max": 48}, "pico_fundo": {"nome": "Pico: cume", "regiao": "pico", "tipos": ["DRAGAO", "GELO", "VOADOR", "PSIQUICO", "FOGO", "LUTA", "NORMAL", "PEDRA"], "min": 45, "max": 60}, "vulcao": {"nome": "Vulcão: encosta", "regiao": "vulcao", "tipos": ["FOGO", "PEDRA", "TERRA", "LUTA"], "min": 40, "max": 50}, "vulcao_fundo": {"nome": "Vulcão: cratera", "regiao": "vulcao", "tipos": ["FOGO", "DRAGAO", "PEDRA", "TERRA", "VOADOR"], "min": 48, "max": 60}, "estrada": {"nome": "Estrada da Vitória: trilha", "regiao": "estrada", "tipos": ["LUTA", "PEDRA", "TERRA", "VENENO", "VOADOR", "NORMAL"], "min": 52, "max": 62}, "estrada_fundo": {"nome": "Estrada da Vitória: desfiladeiro", "regiao": "estrada", "tipos": ["DRAGAO", "PSIQUICO", "LUTA", "GELO", "FANTASMA", "AGUA"], "min": 58, "max": 70}}}'::jsonb || '{"pvp": {"on": true, "distancia": 2, "desafia_dia": 1, "recebe_dia": 3, "teto": true, "prazo_horas": 24, "oferta_min": 1}}'::jsonb || '{"noite": {"on": true, "inicio": 19, "fim": 5, "tipos": ["FANTASMA", "SOMBRIO"]}, "missoes": {"on": true, "por_dia": 3, "moedas_min": 15, "moedas_max": 40, "itens": ["pocao", "super_pocao", "hiper_pocao", "reviver", "antidoto", "despertar", "cura_paralisia", "x_ataque", "x_defesa", "x_velocidade", "x_especial"]}, "ginasios": {"on": true, "tentativas_dia": 3, "moedas": 300, "itens": {"max_pocao": 2, "reviver": 2}, "todas_moedas": 1000, "todas_itens": {"restaurar_tudo": 5}, "lideres": {"bosque": {"nome": "Líder Flora", "classe": "domador", "tipo": "Inseto e Planta", "time": [[12, 30], [47, 31], [71, 33], [3, 35]]}, "praia": {"nome": "Líder Marina", "classe": "arqueiro", "tipo": "Água e Elétrico", "time": [[55, 34], [101, 35], [131, 36], [121, 38]]}, "deserto": {"nome": "Líder Brasa", "classe": "guerreiro", "tipo": "Fogo e Terra", "time": [[51, 38], [59, 40], [112, 41], [6, 42]]}, "pedreira": {"nome": "Líder Rocha", "classe": "mercador", "tipo": "Pedra", "time": [[76, 40], [139, 42], [141, 43], [142, 44]]}, "charco": {"nome": "Líder Sombra", "classe": "mago", "tipo": "Fantasma e Psíquico", "time": [[93, 44], [97, 45], [65, 46], [94, 47]]}, "pico": {"nome": "Líder Neve", "classe": "clerigo", "tipo": "Gelo e Dragão", "time": [[87, 56], [91, 57], [131, 58], [149, 60]]}}}, "chefe": {"on": true, "dia_semana": 6, "hora": 10, "horas": 48, "nivel": 75, "vidas": 40, "turnos": 12, "tentativas_dia": 3, "especies": [149, 130, 143, 112, 94, 68, 131, 59, 6, 65], "moedas": 250, "itens": {"restaurar_tudo": 1, "reviver": 1}, "top_moedas": [300, 200, 100]}}'::jsonb
    || '{"elite": {"on": true, "insignias_min": 8, "tentativas_dia": 1, "time_max": 6, "moedas": 5000, "itens": {"restaurar_tudo": 5, "reviver": 5}, "doces": 5, "repetir_moedas": 1000, "repetir_doces": 1}}'::jsonb
    || coalesce(public.cfg()->'rpg', '{}'::jsonb)) #- '{ginasios,lideres}'   -- arquivo 101: os times dos Líderes ficam na tabela rpg_lideres
$$;

-- os números novos também na configuração guardada (1 desafio por dia; o resto fica como o admin deixou)
update public.game_config
   set config = jsonb_set(config, '{rpg,pvp}', '{"prazo_horas": 24, "oferta_min": 1}'::jsonb || (config->'rpg'->'pvp') || '{"desafia_dia": 1}'::jsonb)
 where active and config->'rpg' ? 'pvp';

create table if not exists public.rpg_pvp_desafios (
  id bigserial primary key, de uuid not null references auth.users(id) on delete cascade, para uuid not null references auth.users(id) on delete cascade,
  regiao text, dia date not null, status text not null default 'pendente' check (status in ('pendente', 'oferta', 'batalha', 'pago', 'expirou')),
  moedas int not null default 0, battle_id uuid, criado timestamptz not null default now(), resolvido timestamptz);
create index if not exists rpg_pvp_desafios_de on public.rpg_pvp_desafios(de, dia);
create index if not exists rpg_pvp_desafios_para on public.rpg_pvp_desafios(para, dia);
alter table public.rpg_pvp_desafios enable row level security;   -- sem política: o site lê pelo rpg_pvp_pendentes()

-- desafio que ninguém respondeu no prazo: some sem batalha (a oferta volta para quem ofereceu)
create or replace function public.rpg_pvp_tick() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare d rpg_pvp_desafios; h numeric := coalesce((public.rpg_cfg()->'pvp'->>'prazo_horas')::numeric, 24);
begin
  for d in select * from rpg_pvp_desafios where status in ('pendente', 'oferta') and criado < now() - make_interval(secs => (h * 3600)::int) for update loop
    if d.status = 'oferta' and d.moedas > 0 then update characters set coins = coins + d.moedas where user_id = d.para; end if;
    update rpg_pvp_desafios set status = 'expirou', resolvido = now() where id = d.id;
  end loop;
end $$;
revoke execute on function public.rpg_pvp_tick() from public, anon, authenticated;

-- a batalha em si (a mesma do arquivo 102: 3 contra 3, sem moedas, com o teto de nível)
create or replace function public.rpg_pvp_batalha(_de uuid, _para uuid, _regiao text) returns public.battles
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rpg_cfg()->'pvp'; pc jsonb := public.pk_cfg()->'battle'; b battles; n1 text; n2 text; s1 jsonb; s2 jsonb; tt int;
begin
  select name into n1 from characters where user_id = _de;
  select name into n2 from characters where user_id = _para;
  if exists (select 1 from battles where status in ('convite', 'ativa') and ((p1 = _de and p2 = _para) or (p1 = _para and p2 = _de))) then
    raise exception 'Já existe uma batalha aberta entre vocês.'; end if;
  if not exists (select 1 from monsters where user_id = _de and team_slot is not null) or not exists (select 1 from monsters where user_id = _para and team_slot is not null) then
    raise exception 'Um dos dois ficou sem equipe para batalhar.'; end if;
  tt := case when coalesce((c->>'teto')::boolean, true) then public.teto_nivel() end;
  select jsonb_build_object('user', _de, 'name', n1, 'active', 0, 'need_switch', false, 'mons', jsonb_agg(public.bt_mon_teto(m.id, tt) order by m.team_slot)) into s1
    from (select id, team_slot from monsters where user_id = _de and team_slot is not null order by team_slot limit (pc->>'size')::int) m;
  select jsonb_build_object('user', _para, 'name', n2, 'active', 0, 'need_switch', false, 'mons', jsonb_agg(public.bt_mon_teto(m.id, tt) order by m.team_slot)) into s2
    from (select id, team_slot from monsters where user_id = _para and team_slot is not null order by team_slot limit (pc->>'size')::int) m;
  insert into battles(p1, p2, size, bet, status, turn, phase, started_at, state, log)
  values (_de, _para, (pc->>'size')::int, 0, 'ativa', 1, 'normal', now(),
          jsonb_build_object('sides', jsonb_build_array(s1, s2), 'xp', '{}'::jsonb, 'rpg_pvp', true, 'regiao', _regiao),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', '⚔️ ' || n1 || ' desafiou ' || n2 || ' na Aventura, e a batalha vai acontecer!'),
            jsonb_build_object('txt', n1 || ' mandou ' || (s1->'mons'->0->>'name') || '!'),
            jsonb_build_object('txt', n2 || ' mandou ' || (s2->'mons'->0->>'name') || '!')))))
  returning * into b;
  insert into event_log(user_id, kind, message) values (_de, 'batalha', '⚔️ ' || n1 || ' e ' || n2 || ' vão batalhar na Aventura!');
  return b;
end $$;
revoke execute on function public.rpg_pvp_batalha(uuid, uuid, text) from public, anon, authenticated;

-- desafiar: cria só o convite (a batalha só sai se o outro quiser lutar, ou se quem desafiou recusar a oferta)
drop function if exists public.rpg_desafiar(uuid, text);
create or replace function public.rpg_desafiar(_opponent uuid, _regiao text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.rpg_cfg()->'pvp'; pc jsonb := public.pk_cfg()->'battle'; n1 text; n2 text; hoje date := public.game_today(); d rpg_pvp_desafios;
begin
  perform public.rpg_pvp_tick();
  if not coalesce((c->>'on')::boolean, true) and not public.is_admin() then raise exception 'As batalhas na Aventura estão desligadas.'; end if;
  if _opponent is null or _opponent = uid then raise exception 'Você não pode desafiar você mesmo.'; end if;
  select name into n2 from characters where user_id = _opponent;
  if n2 is null then raise exception 'Jogador não encontrado.'; end if;
  select name into n1 from characters where user_id = uid;
  if (select count(*) from monsters where user_id = uid) < (pc->>'min_captured')::int or not exists (select 1 from monsters where user_id = uid and team_slot is not null) then
    raise exception 'Você precisa de pelo menos % Pokémon e da equipe montada para batalhar.', pc->>'min_captured'; end if;
  if (select count(*) from monsters where user_id = _opponent) < (pc->>'min_captured')::int or not exists (select 1 from monsters where user_id = _opponent and team_slot is not null) then
    raise exception '% ainda não tem equipe para batalhar.', n2; end if;
  if exists (select 1 from battles where status in ('convite', 'ativa') and ((p1 = uid and p2 = _opponent) or (p1 = _opponent and p2 = uid))) then
    raise exception 'Já existe uma batalha aberta entre vocês.'; end if;
  if exists (select 1 from rpg_pvp_desafios where dia = hoje and ((de = uid and para = _opponent) or (de = _opponent and para = uid))) then
    raise exception 'Vocês dois já tiveram um desafio hoje na Aventura. Amanhã tem mais!'; end if;
  if (select count(*) from rpg_pvp_desafios where de = uid and dia = hoje) >= (c->>'desafia_dia')::int then
    raise exception 'Você já usou % de hoje na Aventura. Amanhã tem mais!', case when (c->>'desafia_dia')::int = 1 then 'o seu desafio' else 'os seus ' || (c->>'desafia_dia') || ' desafios' end; end if;
  if (select count(*) from rpg_pvp_desafios where para = _opponent and dia = hoje) >= (c->>'recebe_dia')::int then
    raise exception '% já foi desafiado(a) % vezes hoje. Deixe para amanhã!', n2, c->>'recebe_dia'; end if;
  insert into rpg_pvp_desafios(de, para, regiao, dia) values (uid, _opponent, _regiao, hoje) returning * into d;
  return jsonb_build_object('id', d.id, 'para', n2, 'prazo_horas', (c->>'prazo_horas')::numeric);
end $$;

-- quem foi desafiado: lutar, ou oferecer moedas para não lutar (as moedas ficam guardadas até quem desafiou decidir)
create or replace function public.rpg_desafio_responder(_id bigint, _lutar boolean, _moedas int default 0) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.rpg_cfg()->'pvp'; d rpg_pvp_desafios; b battles; tenho int;
begin
  perform public.rpg_pvp_tick();
  select * into d from rpg_pvp_desafios where id = _id and para = uid for update;
  if d.id is null then raise exception 'Desafio não encontrado.'; end if;
  if d.status <> 'pendente' then raise exception 'Esse desafio já foi respondido (ou passou do prazo).'; end if;
  if _lutar then
    b := public.rpg_pvp_batalha(d.de, d.para, d.regiao);
    update rpg_pvp_desafios set status = 'batalha', battle_id = b.id, resolvido = now() where id = d.id;
    return jsonb_build_object('battle', b.id);
  end if;
  if coalesce(_moedas, 0) < greatest(1, coalesce((c->>'oferta_min')::int, 1)) then raise exception 'Ofereça pelo menos % moedas.', greatest(1, coalesce((c->>'oferta_min')::int, 1)); end if;
  select coins into tenho from characters where user_id = uid for update;
  if coalesce(tenho, 0) < _moedas then raise exception 'Você só tem % moedas.', coalesce(tenho, 0); end if;
  update characters set coins = coins - _moedas where user_id = uid;
  update rpg_pvp_desafios set status = 'oferta', moedas = _moedas where id = d.id;
  return jsonb_build_object('oferta', _moedas);
end $$;

-- quem desafiou: aceitar as moedas (sem batalha) ou recusar (as moedas voltam e a batalha acontece)
create or replace function public.rpg_desafio_decidir(_id bigint, _aceita boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d rpg_pvp_desafios; b battles; n1 text; n2 text;
begin
  perform public.rpg_pvp_tick();
  select * into d from rpg_pvp_desafios where id = _id and de = uid for update;
  if d.id is null then raise exception 'Desafio não encontrado.'; end if;
  if d.status <> 'oferta' then raise exception 'Não há oferta para decidir neste desafio.'; end if;
  if _aceita then
    update characters set coins = coins + d.moedas where user_id = uid;
    update rpg_pvp_desafios set status = 'pago', resolvido = now() where id = d.id;
    select name into n1 from characters where user_id = d.de; select name into n2 from characters where user_id = d.para;
    insert into event_log(user_id, kind, message) values (d.para, 'batalha', '💰 ' || n2 || ' pagou ' || d.moedas || ' moedas para ' || n1 || ' e escapou da batalha na Aventura!');
    return jsonb_build_object('pago', d.moedas);
  end if;
  update characters set coins = coins + d.moedas where user_id = d.para;
  b := public.rpg_pvp_batalha(d.de, d.para, d.regiao);
  update rpg_pvp_desafios set status = 'batalha', battle_id = b.id, resolvido = now() where id = d.id;
  return jsonb_build_object('battle', b.id);
end $$;

-- o que está esperando resposta (para o site mostrar ao entrar na Aventura)
create or replace function public.rpg_pvp_pendentes() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  perform public.rpg_pvp_tick();
  return jsonb_build_object(
    'recebidos', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'de', d.de, 'nome', c.name, 'criado', d.criado) order by d.id)
                           from rpg_pvp_desafios d join characters c on c.user_id = d.de where d.para = uid and d.status = 'pendente'), '[]'::jsonb),
    'ofertas', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'para', d.para, 'nome', c.name, 'moedas', d.moedas) order by d.id)
                         from rpg_pvp_desafios d join characters c on c.user_id = d.para where d.de = uid and d.status = 'oferta'), '[]'::jsonb),
    'enviados', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'para', d.para, 'nome', c.name, 'status', d.status) order by d.id)
                          from rpg_pvp_desafios d join characters c on c.user_id = d.para where d.de = uid and d.status = 'pendente'), '[]'::jsonb),
    'esperando', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'de', d.de, 'nome', c.name, 'moedas', d.moedas) order by d.id)
                           from rpg_pvp_desafios d join characters c on c.user_id = d.de where d.para = uid and d.status = 'oferta'), '[]'::jsonb),
    'hoje', (select count(*) from rpg_pvp_desafios where de = uid and dia = public.game_today()),
    'por_dia', (public.rpg_cfg()->'pvp'->>'desafia_dia')::int);
end $$;

grant execute on function public.rpg_desafiar(uuid, text), public.rpg_desafio_responder(bigint, boolean, int), public.rpg_desafio_decidir(bigint, boolean), public.rpg_pvp_pendentes() to authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('⚔️ Aventura: desafio com escolha', 'O desafio entre jogadores na Aventura mudou:
• Cada um pode desafiar 1 jogador por dia.
• O desafio não começa sozinho: quem foi desafiado escolhe se quer lutar ou se oferece moedas para não lutar.
• Quem desafiou decide: aceita as moedas (e não tem batalha) ou recusa (as moedas voltam e a batalha acontece).
• Se ninguém responder em 24 horas, o desafio some sem batalha, e as moedas oferecidas voltam.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
