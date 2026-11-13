-- 106_elite_quatro.sql
-- Pedido do dono em 13/11/2026: mais 2 Ginásios (mapa maior) e a Liga no fim da Aventura, muito difícil de chegar e de vencer:
-- (1) rotas novas Vulcão Cinzento (saída leste do Deserto) e Estrada da Vitória (saída norte do Pico), com 4 áreas de nível alto
--     e os Líderes Magma (Fogo, 5 Pokémon) e Titã (Terra e Pedra, 6 Pokémon) em rpg_lideres; as missões e o chefe valem lá também.
-- (2) Planalto da Liga (saída norte da Estrada): só entra quem tem as 8 insígnias (elite.insignias_min). A Elite 4 e o Campeão
--     (personagens nossos) ficam em rpg_elite (time secreto, o admin edita). Uma tentativa por dia (elite.tentativas_dia): o jogador
--     escolhe de 1 a 6 Pokémon e enfrenta os 5 em sequência, Pokémon por Pokémon, como no Ginásio, mas a vida dos escolhidos fica
--     guardada na tentativa (rpg_elite_run.vida) e NUNCA volta entre as lutas: nem com o tempo, nem no Centro. Começou, só acaba
--     vencendo o Campeão ou com todos desmaiados; fugir de uma luta é desistir. Quem vence entra no Hall da Fama (rpg_campeoes),
--     ganha o prêmio grande na 1ª vez (elite.moedas, itens e Doces de Forja) e um menor nas outras.
-- Novas rpg_cfg (versão do 102), rpg_after (versão do 103), rpg_estado (versão do 101), rpg_missoes_gerar e rpg_chefe_criar
-- (versões do 99). Funções do site: rpg_elite, rpg_elite_lutar, rpg_elite_desistir, admin_rpg_elite, admin_rpg_elite_salvar.

create or replace function public.rpg_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select ('{"on": true, "batalhas_dia": 20, "chance_pct": 12, "espera_seg": 8, "envio_seg": 1.2, "fuga_base": 10, "fuga_por_ataque": 10, "nivel_pedra": 28, "nivel_troca": 36, "folga": 10, "lendarios": [144, 145, 146, 150, 151, 243, 244, 245, 249, 250, 251], "zonas": {"mato": {"nome": "Capim alto", "regiao": "vila", "tipos": ["INSETO", "PLANTA", "NORMAL"], "min": 2, "max": 6}, "escura": {"nome": "Grama escura", "regiao": "vila", "tipos": ["NORMAL", "VOADOR", "ELETRICO"], "min": 3, "max": 7}, "pantano": {"nome": "Pântano", "regiao": "vila", "tipos": ["AGUA", "VENENO"], "min": 3, "max": 7}, "pedra": {"nome": "Alto do penhasco", "regiao": "vila", "tipos": ["PEDRA", "TERRA", "LUTA"], "min": 4, "max": 8}, "bosque": {"nome": "Bosque: mato", "regiao": "bosque", "tipos": ["INSETO", "PLANTA", "VENENO", "NORMAL"], "min": 8, "max": 16}, "bosque_fundo": {"nome": "Bosque: mata funda", "regiao": "bosque", "tipos": ["INSETO", "PLANTA", "VENENO", "NORMAL", "VOADOR"], "min": 18, "max": 34}, "praia": {"nome": "Praia: dunas", "regiao": "praia", "tipos": ["AGUA", "ELETRICO", "NORMAL"], "min": 8, "max": 16}, "praia_fundo": {"nome": "Praia: costão", "regiao": "praia", "tipos": ["AGUA", "ELETRICO", "GELO", "VOADOR"], "min": 18, "max": 38}, "deserto": {"nome": "Deserto: capim seco", "regiao": "deserto", "tipos": ["FOGO", "TERRA", "NORMAL"], "min": 12, "max": 22}, "deserto_fundo": {"nome": "Deserto: oásis distante", "regiao": "deserto", "tipos": ["FOGO", "TERRA", "PEDRA", "LUTA"], "min": 24, "max": 42}, "pedreira": {"nome": "Pedreira: entrada", "regiao": "pedreira", "tipos": ["PEDRA", "TERRA", "LUTA", "METALICO"], "min": 12, "max": 22}, "pedreira_fundo": {"nome": "Pedreira: fundo da gruta", "regiao": "pedreira", "tipos": ["PEDRA", "TERRA", "LUTA", "METALICO", "DRAGAO"], "min": 24, "max": 44}, "charco": {"nome": "Charco: margem", "regiao": "charco", "tipos": ["VENENO", "FANTASMA", "PSIQUICO", "SOMBRIO"], "min": 20, "max": 32}, "charco_fundo": {"nome": "Charco: brejo escuro", "regiao": "charco", "tipos": ["FANTASMA", "PSIQUICO", "SOMBRIO", "VENENO", "NORMAL"], "min": 32, "max": 46}, "pico": {"nome": "Pico: encosta", "regiao": "pico", "tipos": ["GELO", "AGUA", "PSIQUICO", "VOADOR", "ELETRICO"], "min": 34, "max": 48}, "pico_fundo": {"nome": "Pico: cume", "regiao": "pico", "tipos": ["DRAGAO", "GELO", "VOADOR", "PSIQUICO", "FOGO", "LUTA", "NORMAL", "PEDRA"], "min": 45, "max": 60}, "vulcao": {"nome": "Vulcão: encosta", "regiao": "vulcao", "tipos": ["FOGO", "PEDRA", "TERRA", "LUTA"], "min": 40, "max": 50}, "vulcao_fundo": {"nome": "Vulcão: cratera", "regiao": "vulcao", "tipos": ["FOGO", "DRAGAO", "PEDRA", "TERRA", "VOADOR"], "min": 48, "max": 60}, "estrada": {"nome": "Estrada da Vitória: trilha", "regiao": "estrada", "tipos": ["LUTA", "PEDRA", "TERRA", "VENENO", "VOADOR", "NORMAL"], "min": 52, "max": 62}, "estrada_fundo": {"nome": "Estrada da Vitória: desfiladeiro", "regiao": "estrada", "tipos": ["DRAGAO", "PSIQUICO", "LUTA", "GELO", "FANTASMA", "AGUA"], "min": 58, "max": 70}}}'::jsonb || '{"pvp": {"on": true, "distancia": 2, "desafia_dia": 5, "recebe_dia": 3, "teto": true}}'::jsonb || '{"noite": {"on": true, "inicio": 19, "fim": 5, "tipos": ["FANTASMA", "SOMBRIO"]}, "missoes": {"on": true, "por_dia": 3, "moedas_min": 15, "moedas_max": 40, "itens": ["pocao", "super_pocao", "hiper_pocao", "reviver", "antidoto", "despertar", "cura_paralisia", "x_ataque", "x_defesa", "x_velocidade", "x_especial"]}, "ginasios": {"on": true, "tentativas_dia": 3, "moedas": 300, "itens": {"max_pocao": 2, "reviver": 2}, "todas_moedas": 1000, "todas_itens": {"restaurar_tudo": 5}, "lideres": {"bosque": {"nome": "Líder Flora", "classe": "domador", "tipo": "Inseto e Planta", "time": [[12, 30], [47, 31], [71, 33], [3, 35]]}, "praia": {"nome": "Líder Marina", "classe": "arqueiro", "tipo": "Água e Elétrico", "time": [[55, 34], [101, 35], [131, 36], [121, 38]]}, "deserto": {"nome": "Líder Brasa", "classe": "guerreiro", "tipo": "Fogo e Terra", "time": [[51, 38], [59, 40], [112, 41], [6, 42]]}, "pedreira": {"nome": "Líder Rocha", "classe": "mercador", "tipo": "Pedra", "time": [[76, 40], [139, 42], [141, 43], [142, 44]]}, "charco": {"nome": "Líder Sombra", "classe": "mago", "tipo": "Fantasma e Psíquico", "time": [[93, 44], [97, 45], [65, 46], [94, 47]]}, "pico": {"nome": "Líder Neve", "classe": "clerigo", "tipo": "Gelo e Dragão", "time": [[87, 56], [91, 57], [131, 58], [149, 60]]}}}, "chefe": {"on": true, "dia_semana": 6, "hora": 10, "horas": 48, "nivel": 75, "vidas": 40, "turnos": 12, "tentativas_dia": 3, "especies": [149, 130, 143, 112, 94, 68, 131, 59, 6, 65], "moedas": 250, "itens": {"restaurar_tudo": 1, "reviver": 1}, "top_moedas": [300, 200, 100]}}'::jsonb
    || '{"elite": {"on": true, "insignias_min": 8, "tentativas_dia": 1, "time_max": 6, "moedas": 5000, "itens": {"restaurar_tudo": 5, "reviver": 5}, "doces": 5, "repetir_moedas": 1000, "repetir_doces": 1}}'::jsonb
    || coalesce(public.cfg()->'rpg', '{}'::jsonb)) #- '{ginasios,lideres}'   -- arquivo 101: os times dos Líderes ficam na tabela rpg_lideres
$$;

-- ---------- 2 rotas novas e os 2 Ginásios delas ----------
insert into public.rpg_lideres(regiao, nome, classe, tipo, time) values
  ('vulcao', 'Líder Magma', 'guerreiro', 'Fogo', '[[78, 58], [126, 59], [38, 60], [136, 60], [59, 62]]'),
  ('estrada', 'Líder Titã', 'ladino', 'Terra e Pedra', '[[51, 60], [105, 61], [31, 62], [34, 62], [76, 63], [112, 64]]')
on conflict (regiao) do nothing;
-- as áreas novas entram na configuração guardada (a do arquivo 97 tem as 16 antigas)
update public.game_config set config = jsonb_set(config, '{rpg,zonas}', (config->'rpg'->'zonas') || (
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from jsonb_each('{"vulcao": {"nome": "Vulcão: encosta", "regiao": "vulcao", "tipos": ["FOGO", "PEDRA", "TERRA", "LUTA"], "min": 40, "max": 50}, "vulcao_fundo": {"nome": "Vulcão: cratera", "regiao": "vulcao", "tipos": ["FOGO", "DRAGAO", "PEDRA", "TERRA", "VOADOR"], "min": 48, "max": 60}, "estrada": {"nome": "Estrada da Vitória: trilha", "regiao": "estrada", "tipos": ["LUTA", "PEDRA", "TERRA", "VENENO", "VOADOR", "NORMAL"], "min": 52, "max": 62}, "estrada_fundo": {"nome": "Estrada da Vitória: desfiladeiro", "regiao": "estrada", "tipos": ["DRAGAO", "PSIQUICO", "LUTA", "GELO", "FANTASMA", "AGUA"], "min": 58, "max": 70}}'::jsonb) where true
     and not ((config->'rpg'->'zonas') ? key)))
 where active and config->'rpg' ? 'zonas';

-- ---------- Elite 4 e o Campeão ----------
create table if not exists public.rpg_elite (
  ordem int primary key check (ordem between 1 and 9), nome text not null, classe text not null, tipo text not null default '', time jsonb not null);
alter table public.rpg_elite enable row level security;   -- sem política: o time é segredo, só as funções leem
insert into public.rpg_elite(ordem, nome, classe, tipo, time) values
  (1, 'Elite Inverna', 'clerigo', 'Gelo e Água', '[[87, 63], [91, 64], [80, 64], [124, 65], [131, 66]]'),
  (2, 'Elite Bravo', 'guerreiro', 'Luta e Pedra', '[[95, 64], [107, 65], [106, 65], [76, 66], [68, 68]]'),
  (3, 'Elite Lúgubre', 'mago', 'Fantasma e Veneno', '[[93, 65], [42, 66], [89, 66], [24, 67], [94, 69]]'),
  (4, 'Elite Escama', 'domador', 'Dragão e Voador', '[[130, 67], [148, 67], [148, 68], [142, 68], [149, 71]]'),
  (5, 'Campeão Gael', 'arqueiro', 'de tudo um pouco', '[[18, 70], [65, 70], [112, 71], [103, 71], [59, 72], [9, 74]]')
on conflict (ordem) do nothing;

-- uma tentativa na Liga: começou, só acaba vencendo o Campeão ou com todos os escolhidos desmaiados (a vida não volta)
create table if not exists public.rpg_elite_run (
  id bigserial primary key, user_id uuid not null references auth.users(id) on delete cascade, dia date not null,
  status text not null default 'andando' check (status in ('andando', 'venceu', 'perdeu')),
  etapa int not null default 0, idx int not null default 0, hp jsonb not null, meus jsonb not null, vida jsonb not null,
  criado timestamptz not null default now(), fim timestamptz);
create index if not exists rpg_elite_run_user on public.rpg_elite_run(user_id, status);
alter table public.rpg_elite_run enable row level security;   -- sem política: o site lê pelo rpg_elite()

-- Hall da Fama: quem venceu o Campeão (todos veem)
create table if not exists public.rpg_campeoes (
  user_id uuid primary key references auth.users(id) on delete cascade, vezes int not null default 1,
  primeira_em timestamptz not null default now(), ultima_em timestamptz not null default now(), time jsonb not null default '[]');
alter table public.rpg_campeoes enable row level security;
drop policy if exists rpg_campeoes_ler on public.rpg_campeoes;
create policy rpg_campeoes_ler on public.rpg_campeoes for select to authenticated using (true);
grant select on public.rpg_campeoes to authenticated;

create or replace function public.rpg_elite_pub() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_agg(jsonb_build_object('ordem', ordem, 'nome', nome, 'classe', classe, 'tipo', tipo, 'n', jsonb_array_length(time)) order by ordem), '[]'::jsonb) from rpg_elite
$$;
revoke execute on function public.rpg_elite_pub() from public, anon;

-- o que o jogador vê da Liga: os 5 (sem os times), a tentativa em andamento, prêmios e o Hall da Fama
create or replace function public.rpg_elite() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.rpg_cfg()->'elite'; er rpg_elite_run; n int; total int;
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  select * into er from rpg_elite_run where user_id = uid and status = 'andando' order by id desc limit 1;
  select count(*) into n from rpg_elite_run where user_id = uid and dia = public.game_today();
  select jsonb_array_length(time) into total from rpg_elite where ordem = er.etapa + 1;
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'membros', public.rpg_elite_pub(),
    'insignias', (select count(*) from rpg_insignias where user_id = uid), 'insignias_min', (c->>'insignias_min')::int,
    'tentativas', n, 'tentativas_dia', (c->>'tentativas_dia')::int, 'time_max', (c->>'time_max')::int,
    'moedas', (c->>'moedas')::int, 'itens', c->'itens', 'doces', (c->>'doces')::int, 'repetir_moedas', (c->>'repetir_moedas')::int,
    'campeao', (select vezes from rpg_campeoes where user_id = uid),
    'hall', coalesce((select jsonb_agg(jsonb_build_object('name', ch.name, 'class', ch.class, 'vezes', h.vezes, 'em', h.primeira_em, 'time', h.time) order by h.primeira_em)
                      from rpg_campeoes h join characters ch on ch.user_id = h.user_id), '[]'::jsonb),
    'tentativa', case when er.id is null then null else jsonb_build_object('id', er.id, 'etapa', er.etapa, 'idx', er.idx, 'total', total,
      'meus', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'species', m.species_id, 'level', m.level, 'outfit', m.outfit, 'vida', coalesce((er.vida->>e.v)::int, 0)) order by e.k)
                         from jsonb_array_elements_text(er.meus) with ordinality e(v, k) join monsters m on m.id::text = e.v and m.user_id = uid), '[]'::jsonb)) end);
end $$;

create or replace function public.rpg_elite_lutar(_comp uuid default null, _meus uuid[] default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.rpg_cfg()->'elite'; er rpg_elite_run; el rpg_elite; me characters; bid uuid; n int; tmax int;
  m monsters; vida int; sp int; lv int; wild jsonb; mine jsonb; whp int; s0 jsonb; s1 jsonb; total int;
begin
  if not coalesce((c->>'on')::boolean, true) and not public.is_admin() then raise exception 'O Planalto da Liga está fechado no momento.'; end if;
  select count(*) into n from rpg_insignias where user_id = uid;
  if n < (c->>'insignias_min')::int then raise exception 'A Liga só recebe quem tem as % insígnias. Você tem %.', (c->>'insignias_min'), n; end if;
  select * into me from characters where user_id = uid for update;
  bid := public.treino_batalha(uid);
  if bid is not null then return jsonb_build_object('battle', bid); end if;
  perform public.treino_autocura(uid);
  select * into er from rpg_elite_run where user_id = uid and status = 'andando' order by id desc limit 1 for update;
  if er.id is null then
    select count(*) into n from rpg_elite_run where user_id = uid and dia = public.game_today();
    if n >= (c->>'tentativas_dia')::int then raise exception 'Você já entrou na Liga hoje. Volte amanhã!'; end if;
    tmax := greatest(1, least(6, (c->>'time_max')::int));
    if _meus is null or cardinality(_meus) not between 1 and tmax or (select count(distinct x) from unnest(_meus) x) <> cardinality(_meus) then
      raise exception 'Escolha de 1 a % Pokémon diferentes para entrar na Liga.', tmax;
    end if;
    if (select count(*) from monsters where user_id = uid and id = any(_meus) and tr_hp > 0) <> cardinality(_meus) then
      raise exception 'Escolha só Pokémon seus que estejam com vida.';
    end if;
    select jsonb_array_length(time) into total from rpg_elite where ordem = 1;
    if total is null then raise exception 'A Liga ainda não tem treinadores.'; end if;
    insert into rpg_elite_run(user_id, dia, meus, vida, hp)
    values (uid, public.game_today(), to_jsonb(_meus), (select jsonb_object_agg(id::text, tr_hp) from monsters where id = any(_meus)),
            (select jsonb_agg(100) from generate_series(1, total)))
    returning * into er;
    insert into event_log(user_id, kind, message) values (uid, 'elite', '🏛️ ' || me.name || ' entrou no Planalto da Liga para enfrentar a Elite 4!');
  end if;
  -- o próximo escolhido com vida (a vida da Liga não volta: fica guardada na tentativa)
  select m2.* into m from jsonb_array_elements_text(er.meus) with ordinality e(v, k) join monsters m2 on m2.id::text = e.v
   where m2.user_id = uid and coalesce((er.vida->>e.v)::int, 0) > 0 order by e.k limit 1;
  if m.id is null then
    update rpg_elite_run set status = 'perdeu', fim = now() where id = er.id;
    return jsonb_build_object('fim', 'perdeu', 'msg', 'Todos os Pokémon que você levou para a Liga desmaiaram. A tentativa acabou.');
  end if;
  vida := (er.vida->>m.id::text)::int;
  if _comp is not null and (_comp = m.id or not exists (select 1 from monsters where id = _comp and user_id = uid)
     or coalesce((select tr_hp from monsters where id = _comp), 100) <= 0) then _comp := null; end if;
  delete from battles where mode = 'treino' and p1 = uid and status <> 'ativa';
  select * into el from rpg_elite where ordem = er.etapa + 1;
  total := jsonb_array_length(el.time);
  sp := (el.time->er.idx->>0)::int; lv := (el.time->er.idx->>1)::int;
  wild := public.npc_mon(sp, lv);
  whp := greatest(1, ceil((wild->>'maxhp')::int * coalesce((er.hp->>er.idx)::numeric, 100) / 100))::int;
  wild := jsonb_set(wild, '{hp}', to_jsonb(whp));
  mine := public.rpg_mine(m.id, uid, vida);   -- o Peitoral vale aqui, como nos Ginásios
  s0 := jsonb_build_object('user', uid, 'name', me.name, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(mine));
  s1 := jsonb_build_object('user', uid, 'name', el.nome, 'npc', true, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(wild));
  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (uid, uid, 'treino', 1, 'ativa', 1, 'normal', now(),
          jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb, 'treino', jsonb_build_object('mon', m.id, 'forte', false, 'comp', _comp, 'elite', er.id, 'elite_etapa', er.etapa, 'elite_idx', er.idx)),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', '🏛️ Liga Pokémon · ' || el.nome || ' (' || (er.etapa + 1) || 'º de ' || (select count(*) from rpg_elite) || ')'),
            jsonb_build_object('txt', el.nome || ' manda ' || (wild->>'name') || ' (nível ' || lv || ')' || case when whp < (wild->>'maxhp')::int then ', ainda ferido,' else '' end || ' para a luta! (' || (er.idx + 1) || 'º de ' || total || ')'),
            jsonb_build_object('txt', 'Vai, ' || (mine->>'name') || '!' || case when vida < 100 then ' (com ' || vida || '% da vida)' else '' end)))))
  returning id into bid;
  return jsonb_build_object('battle', bid);
end $$;

-- desistir da tentativa (conta como derrota)
create or replace function public.rpg_elite_desistir() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); n int; bid uuid;
begin
  bid := public.treino_batalha(uid);
  if bid is not null and exists (select 1 from battles where id = bid and state->'treino' ? 'elite') then
    raise exception 'Termine a luta que está acontecendo antes.';
  end if;
  update rpg_elite_run set status = 'perdeu', fim = now() where user_id = uid and status = 'andando';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Você não tem tentativa na Liga.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- vencer o Campeão: Hall da Fama e prêmio (o grande só na primeira vez)
create or replace function public.rpg_elite_coroar(_uid uuid, _run bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rpg_cfg()->'elite'; er rpg_elite_run; v int; nome text; tm jsonb; nd int;
begin
  select * into er from rpg_elite_run where id = _run;
  select coalesce(jsonb_agg(jsonb_build_object('species', m.species_id, 'level', m.level) order by e.k), '[]'::jsonb) into tm
    from jsonb_array_elements_text(er.meus) with ordinality e(v, k) join monsters m on m.id::text = e.v;
  insert into rpg_campeoes(user_id, time) values (_uid, tm)
  on conflict (user_id) do update set vezes = rpg_campeoes.vezes + 1, ultima_em = now(), time = excluded.time
  returning vezes into v;
  if v = 1 then
    perform public.rpg_premiar(_uid, (c->>'moedas')::int, c->'itens'); nd := coalesce((c->>'doces')::int, 0);
  else
    perform public.rpg_premiar(_uid, (c->>'repetir_moedas')::int, null); nd := coalesce((c->>'repetir_doces')::int, 0);
  end if;
  if nd > 0 then insert into equip_doces(user_id, qty) values (_uid, nd) on conflict (user_id) do update set qty = equip_doces.qty + nd; end if;
  select name into nome from characters where user_id = _uid;
  insert into event_log(user_id, kind, message) values (_uid, 'elite', case when v = 1
    then '👑 ' || nome || ' venceu a Elite 4 e o Campeão e entrou para o Hall da Fama da Aventura!'
    else '👑 ' || nome || ' venceu a Liga de novo (' || v || 'ª vez)!' end);
end $$;
revoke execute on function public.rpg_elite_coroar(uuid, bigint) from public, anon, authenticated;

-- admin: ver e editar a Elite (como os Líderes)
create or replace function public.admin_rpg_elite() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(to_jsonb(x) order by ordem) from rpg_elite x), '[]'::jsonb);
end $$;
create or replace function public.admin_rpg_elite_salvar(_ordem int, _nome text, _classe text, _tipo text, _time jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare antes jsonb; e jsonb;
begin
  perform public.assert_admin();
  if not exists (select 1 from rpg_elite where ordem = _ordem) then raise exception 'Esse treinador da Liga não existe.'; end if;
  if length(btrim(coalesce(_nome, ''))) < 2 then raise exception 'Dê um nome ao treinador.'; end if;
  if jsonb_typeof(_time) <> 'array' or jsonb_array_length(_time) not between 1 and 6 then raise exception 'O time precisa ter de 1 a 6 Pokémon.'; end if;
  for e in select * from jsonb_array_elements(_time) loop
    if jsonb_typeof(e) <> 'array' or not exists (select 1 from pokemon where id = (e->>0)::int) or (e->>1)::int not between 1 and 100 then
      raise exception 'Pokémon ou nível inválido: %', e; end if;
  end loop;
  select to_jsonb(x) into antes from rpg_elite x where ordem = _ordem;
  update rpg_elite set nome = btrim(_nome), classe = coalesce(nullif(_classe, ''), classe), tipo = coalesce(_tipo, ''), time = _time where ordem = _ordem;
  insert into admin_audit_log(admin_id, action, target, after) values (auth.uid(), 'rpg_elite', _ordem::text, jsonb_build_object('antes', antes, 'nome', _nome, 'time', _time));
  return public.admin_rpg_elite();
end $$;

create or replace function public.rpg_after(_bid uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare b battles; t jsonb; me0 jsonb; wi jsonb; won boolean; res jsonb := '{}'::jsonb; tt rpg_gin_tent; l jsonb; c jsonb := public.rpg_cfg();
  dn int; ch rpg_chefes; er rpg_elite_run; el rpg_elite; ne int; hpme int; prox int; nome text; z jsonb; p pokemon; total int; n int;
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
  elsif t ? 'elite' then   -- arquivo 106: a Liga (a vida dos escolhidos fica guardada na tentativa e não volta)
    select * into er from rpg_elite_run where id = (t->>'elite')::bigint for update;
    select count(*) into ne from rpg_elite;
    if er.id is not null and er.status = 'andando' then
      select * into el from rpg_elite where ordem = er.etapa + 1;
      total := jsonb_array_length(el.time);
      hpme := greatest(0, least(100, floor((me0->>'hp')::numeric * 100 / greatest(1, (me0->>'maxhp')::int))))::int;
      if (me0->>'hp')::int > 0 then hpme := greatest(1, hpme); end if;
      er.vida := jsonb_set(er.vida, array[t->>'mon'], to_jsonb(hpme));
      if b.end_reason = 'desistencia' then
        er.status := 'perdeu';   -- fugir na Liga é desistir
      elsif (wi->>'hp')::int <= 0 then
        er.hp := jsonb_set(er.hp, array[er.idx::text], '0'); er.idx := er.idx + 1;
        if er.idx >= total then
          select name into nome from characters where user_id = b.p1;
          er.etapa := er.etapa + 1; er.idx := 0;
          if er.etapa >= ne then
            er.status := 'venceu';
          else
            insert into event_log(user_id, kind, message) values (b.p1, 'elite', '⚔️ ' || nome || ' venceu ' || el.nome || ' na Liga (' || er.etapa || ' de ' || ne || ')!');
            select jsonb_array_length(time) into prox from rpg_elite where ordem = er.etapa + 1;
            er.hp := (select jsonb_agg(100) from generate_series(1, prox));
          end if;
        end if;
      else
        er.hp := jsonb_set(er.hp, array[er.idx::text], to_jsonb(greatest(1, ceil((wi->>'hp')::numeric * 100 / greatest(1, (wi->>'maxhp')::int)))::int));
      end if;
      if er.status = 'andando' and not exists (select 1 from jsonb_each_text(er.vida) x join monsters mm on mm.id::text = x.key and mm.user_id = b.p1 where x.value::int > 0) then
        er.status := 'perdeu';
      end if;
      update rpg_elite_run set etapa = er.etapa, idx = er.idx, hp = er.hp, vida = er.vida, status = er.status,
             fim = case when er.status <> 'andando' then now() end where id = er.id;
      if er.status = 'venceu' then perform public.rpg_elite_coroar(b.p1, er.id); end if;
    end if;
    select * into el from rpg_elite where ordem = least(ne, er.etapa + 1);
    res := jsonb_build_object('elite', true, 'status', er.status, 'etapa', er.etapa, 'idx', er.idx, 'n_etapas', ne,
      'total', jsonb_array_length(el.time), 'membro', el.nome);
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

create or replace function public.rpg_estado() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.rpg_cfg(); nb int;
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  select batalhas into nb from rpg_dias where user_id = uid and dia = public.game_today();
  perform public.rpg_chefe_tick();
  perform public.rpg_missoes_gerar(uid);
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'batalhas', coalesce(nb, 0), 'batalhas_dia', (c->>'batalhas_dia')::int + public.vb(uid, 'arena', 'rpg_lutas')::int, 'vila_lutas', public.vb(uid, 'arena', 'rpg_lutas')::int,
    'acompanhante_pct', case when public.heroi(uid) = 'pesquisador' then (public.herois_cfg()->>'pesq_comp_pct')::numeric else coalesce((public.treino_cfg()->>'acompanhante_pct')::numeric, 50) end,
    'chance_pct', (c->>'chance_pct')::numeric, 'espera_seg', (c->>'espera_seg')::int, 'batalha', public.treino_batalha(uid),
    'noite', public.rpg_noite(), 'lideres', public.rpg_lider_pub(),
    'insignias', coalesce((select jsonb_agg(regiao order by ganho_em) from rpg_insignias where user_id = uid), '[]'::jsonb),
    'missoes', coalesce((select jsonb_agg(jsonb_build_object('n', n, 'regiao', regiao, 'tipo', tipo, 'alvo', alvo, 'meta', meta, 'prog', prog, 'premio', premio, 'resgatada', resgatada) order by n)
                         from rpg_missoes where user_id = uid and dia = public.game_today()), '[]'::jsonb),
    'chefe', public.rpg_chefe_info(uid),
    'elite', jsonb_build_object('membros', (select count(*) from rpg_elite), 'insignias_min', (c->'elite'->>'insignias_min')::int,
      'andando', exists (select 1 from rpg_elite_run where user_id = uid and status = 'andando'), 'campeao', (select vezes from rpg_campeoes where user_id = uid)),
    'campeoes', coalesce((select jsonb_agg(user_id) from rpg_campeoes), '[]'::jsonb));   -- arquivo 106
end $$;

create or replace function public.rpg_missoes_gerar(_uid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rpg_cfg()->'missoes'; regs text[] := array['vila', 'bosque', 'praia', 'deserto', 'pedreira', 'charco', 'pico', 'vulcao', 'estrada'];
  tipos text[] := array['NORMAL', 'INSETO', 'PLANTA', 'AGUA', 'VOADOR', 'VENENO', 'ELETRICO', 'PEDRA', 'TERRA', 'FOGO', 'LUTA', 'PSIQUICO', 'FANTASMA', 'GELO'];
  itens text[]; k int; tp text; alvo text; meta int; reg text; melhor int; mn int; mx int;
begin
  if not coalesce((c->>'on')::boolean, true) or exists (select 1 from rpg_missoes where user_id = _uid and dia = public.game_today()) then return; end if;
  select array_agg(x) into itens from jsonb_array_elements_text(c->'itens') x;
  select coalesce(max(level), 5) into melhor from monsters where user_id = _uid and team_slot is not null;
  mn := coalesce((c->>'moedas_min')::int, 15); mx := greatest(mn, coalesce((c->>'moedas_max')::int, 40));
  for k in 1 .. greatest(1, least(6, coalesce((c->>'por_dia')::int, 3))) loop
    tp := (array['regiao', 'tipo', 'nivel'])[1 + (k - 1) % 3];
    reg := regs[1 + floor(random() * case when melhor < 15 then 2 when melhor < 25 then 4 when melhor < 35 then 5 when melhor < 45 then 7 else 9 end)::int];
    if tp = 'regiao' then alvo := reg; meta := case when reg = 'vila' then 4 else 3 end;
    elsif tp = 'tipo' then alvo := tipos[1 + floor(random() * array_length(tipos, 1))::int]; meta := 2 + floor(random() * 2)::int;
    else alvo := greatest(5, melhor - 2)::text; meta := 1; end if;
    insert into rpg_missoes(user_id, dia, n, regiao, tipo, alvo, meta, premio)
    values (_uid, public.game_today(), k, reg, tp, alvo, meta,
            jsonb_build_object('coins', mn + floor(random() * (mx - mn + 1))::int, 'bag', jsonb_build_object(itens[1 + floor(random() * array_length(itens, 1))::int], 1)))
    on conflict do nothing;
  end loop;
end $$;

create or replace function public.rpg_chefe_criar(_regiao text, _especie int) returns rpg_chefes
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rpg_cfg()->'chefe'; regs text[] := array['bosque', 'praia', 'deserto', 'pedreira', 'charco', 'pico', 'vulcao', 'estrada']; r text; sp int; w jsonb; ch rpg_chefes;
begin
  update rpg_chefes set status = 'fugiu' where status = 'ativo';
  r := coalesce(_regiao, regs[1 + floor(random() * array_length(regs, 1))::int]);
  sp := coalesce(_especie, (select (x)::int from jsonb_array_elements_text(c->'especies') x order by random() limit 1), 143);
  w := public.npc_mon(sp, (c->>'nivel')::int);
  insert into rpg_chefes(regiao, especie, nivel, hp_total, fim)
  values (r, sp, (c->>'nivel')::int, (w->>'maxhp')::int * greatest(1, (c->>'vidas')::int), now() + make_interval(hours => (c->>'horas')::int))
  returning * into ch;
  insert into event_log(kind, message) values ('chefe', '👹 Um ' || (w->>'name') || ' gigante (nível ' || ch.nivel || ') apareceu na Aventura! Todos juntos contra ele por ' || (c->>'horas') || ' horas.');
  return ch;
end $$;

grant execute on function public.rpg_elite(), public.rpg_elite_lutar(uuid, uuid[]), public.rpg_elite_desistir(), public.rpg_estado(),
  public.admin_rpg_elite(), public.admin_rpg_elite_salvar(int, text, text, text, jsonb) to authenticated;
revoke execute on function public.rpg_after(uuid), public.rpg_missoes_gerar(uuid), public.rpg_chefe_criar(text, int) from public, anon, authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🏛️ Aventura: 2 Ginásios novos e a Elite 4', 'A Aventura cresceu e agora tem um fim de verdade:
• 🌋 Vulcão Cinzento (saída leste do Deserto Rubro) e 🏆 Estrada da Vitória (saída norte do Pico Gelado): duas rotas novas, as mais fortes do mapa, cada uma com o seu Ginásio. Agora são 8 insígnias.
• 🏛️ No fim da Estrada da Vitória fica o Planalto da Liga. Só entra quem tem as 8 insígnias.
• Lá esperam a Elite 4 e, depois deles, o Campeão. São 5 lutas seguidas, uma atrás da outra.
• Antes de entrar, escolha até 6 Pokémon. A vida deles NUNCA volta durante a Liga: nem com o tempo, nem no Centro Pokémon. Começou, tem que terminar: ou vence o Campeão, ou cai com a equipe toda. Fugir de uma luta é desistir da Liga.
• Só dá para entrar uma vez por dia.
• Quem vencer o Campeão entra para o Hall da Fama da Aventura, ganha um prêmio grande e uma coroa no boneco que todos veem.
Boa sorte: é muito, muito difícil.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
