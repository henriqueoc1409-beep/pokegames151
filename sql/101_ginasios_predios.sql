-- 101_ginasios_predios.sql
-- Pedido do dono em 12/11/2026: (1) o time do Líder é segredo: sai do game_config (que o site lê) e vai para a tabela
-- rpg_lideres, que só as funções leem; o jogador sabe só o nome, o tipo e QUANTOS Pokémon ele usa (rpg_lider_pub).
-- (2) Antes de lutar, o jogador escolhe a mesma quantidade de Pokémon seus (rpg_gin_tent.meus, na ordem em que entram);
-- a tentativa acaba quando os escolhidos caem. (3) O Líder usa os mesmos Pokémon numa ordem sorteada a cada tentativa
-- (rpg_gin_tent.ordem); tentativa nova = todos com a vida cheia. (4) O admin edita os Líderes (admin_rpg_lideres,
-- admin_rpg_lider_salvar), com Auditoria. Prédios e salões dos Ginásios, localizador e mapa completo são do site.
-- Novas rpg_cfg (versão do 99, sem os Líderes), rpg_ginasio, rpg_ginasio_lutar (com _meus), rpg_after (versão do 99)
-- e rpg_estado (versão do 100, com os Líderes públicos).

create table if not exists public.rpg_lideres (
  regiao text primary key, nome text not null, classe text not null, tipo text not null default '', time jsonb not null);
alter table public.rpg_lideres enable row level security;   -- sem política: ninguém lê pelo site
insert into public.rpg_lideres(regiao, nome, classe, tipo, time)
select key, value->>'nome', value->>'classe', coalesce(value->>'tipo', ''), value->'time'
  from jsonb_each(coalesce(public.rpg_cfg()->'ginasios'->'lideres', '{}'::jsonb))
on conflict (regiao) do nothing;
update public.game_config set config = config #- '{rpg,ginasios,lideres}' where active and config->'rpg'->'ginasios' ? 'lideres';
alter table public.rpg_gin_tent add column if not exists ordem jsonb;
alter table public.rpg_gin_tent add column if not exists meus jsonb;

create or replace function public.rpg_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select ('{"on": true, "batalhas_dia": 20, "chance_pct": 12, "espera_seg": 8, "envio_seg": 1.2, "fuga_base": 10, "fuga_por_ataque": 10, "nivel_pedra": 28, "nivel_troca": 36, "folga": 10, "lendarios": [144, 145, 146, 150, 151, 243, 244, 245, 249, 250, 251], "zonas": {"mato": {"nome": "Capim alto", "regiao": "vila", "tipos": ["INSETO", "PLANTA", "NORMAL"], "min": 2, "max": 6}, "escura": {"nome": "Grama escura", "regiao": "vila", "tipos": ["NORMAL", "VOADOR", "ELETRICO"], "min": 3, "max": 7}, "pantano": {"nome": "Pântano", "regiao": "vila", "tipos": ["AGUA", "VENENO"], "min": 3, "max": 7}, "pedra": {"nome": "Alto do penhasco", "regiao": "vila", "tipos": ["PEDRA", "TERRA", "LUTA"], "min": 4, "max": 8}, "bosque": {"nome": "Bosque: mato", "regiao": "bosque", "tipos": ["INSETO", "PLANTA", "VENENO", "NORMAL"], "min": 8, "max": 16}, "bosque_fundo": {"nome": "Bosque: mata funda", "regiao": "bosque", "tipos": ["INSETO", "PLANTA", "VENENO", "NORMAL", "VOADOR"], "min": 18, "max": 34}, "praia": {"nome": "Praia: dunas", "regiao": "praia", "tipos": ["AGUA", "ELETRICO", "NORMAL"], "min": 8, "max": 16}, "praia_fundo": {"nome": "Praia: costão", "regiao": "praia", "tipos": ["AGUA", "ELETRICO", "GELO", "VOADOR"], "min": 18, "max": 38}, "deserto": {"nome": "Deserto: capim seco", "regiao": "deserto", "tipos": ["FOGO", "TERRA", "NORMAL"], "min": 12, "max": 22}, "deserto_fundo": {"nome": "Deserto: oásis distante", "regiao": "deserto", "tipos": ["FOGO", "TERRA", "PEDRA", "LUTA"], "min": 24, "max": 42}, "pedreira": {"nome": "Pedreira: entrada", "regiao": "pedreira", "tipos": ["PEDRA", "TERRA", "LUTA", "METALICO"], "min": 12, "max": 22}, "pedreira_fundo": {"nome": "Pedreira: fundo da gruta", "regiao": "pedreira", "tipos": ["PEDRA", "TERRA", "LUTA", "METALICO", "DRAGAO"], "min": 24, "max": 44}, "charco": {"nome": "Charco: margem", "regiao": "charco", "tipos": ["VENENO", "FANTASMA", "PSIQUICO", "SOMBRIO"], "min": 20, "max": 32}, "charco_fundo": {"nome": "Charco: brejo escuro", "regiao": "charco", "tipos": ["FANTASMA", "PSIQUICO", "SOMBRIO", "VENENO", "NORMAL"], "min": 32, "max": 46}, "pico": {"nome": "Pico: encosta", "regiao": "pico", "tipos": ["GELO", "AGUA", "PSIQUICO", "VOADOR", "ELETRICO"], "min": 34, "max": 48}, "pico_fundo": {"nome": "Pico: cume", "regiao": "pico", "tipos": ["DRAGAO", "GELO", "VOADOR", "PSIQUICO", "FOGO", "LUTA", "NORMAL", "PEDRA"], "min": 45, "max": 60}}}'::jsonb || '{"noite": {"on": true, "inicio": 19, "fim": 5, "tipos": ["FANTASMA", "SOMBRIO"]}, "missoes": {"on": true, "por_dia": 3, "moedas_min": 15, "moedas_max": 40, "itens": ["pocao", "super_pocao", "hiper_pocao", "reviver", "antidoto", "despertar", "cura_paralisia", "x_ataque", "x_defesa", "x_velocidade", "x_especial"]}, "ginasios": {"on": true, "tentativas_dia": 3, "moedas": 300, "itens": {"max_pocao": 2, "reviver": 2}, "todas_moedas": 1000, "todas_itens": {"restaurar_tudo": 5}, "lideres": {"bosque": {"nome": "Líder Flora", "classe": "domador", "tipo": "Inseto e Planta", "time": [[12, 30], [47, 31], [71, 33], [3, 35]]}, "praia": {"nome": "Líder Marina", "classe": "arqueiro", "tipo": "Água e Elétrico", "time": [[55, 34], [101, 35], [131, 36], [121, 38]]}, "deserto": {"nome": "Líder Brasa", "classe": "guerreiro", "tipo": "Fogo e Terra", "time": [[51, 38], [59, 40], [112, 41], [6, 42]]}, "pedreira": {"nome": "Líder Rocha", "classe": "mercador", "tipo": "Pedra", "time": [[76, 40], [139, 42], [141, 43], [142, 44]]}, "charco": {"nome": "Líder Sombra", "classe": "mago", "tipo": "Fantasma e Psíquico", "time": [[93, 44], [97, 45], [65, 46], [94, 47]]}, "pico": {"nome": "Líder Neve", "classe": "clerigo", "tipo": "Gelo e Dragão", "time": [[87, 56], [91, 57], [131, 58], [149, 60]]}}}, "chefe": {"on": true, "dia_semana": 6, "hora": 10, "horas": 48, "nivel": 75, "vidas": 40, "turnos": 12, "tentativas_dia": 3, "especies": [149, 130, 143, 112, 94, 68, 131, 59, 6, 65], "moedas": 250, "itens": {"restaurar_tudo": 1, "reviver": 1}, "top_moedas": [300, 200, 100]}}'::jsonb
    || coalesce(public.cfg()->'rpg', '{}'::jsonb)) #- '{ginasios,lideres}'   -- arquivo 101: os times dos Líderes ficam na tabela rpg_lideres
$$;

-- o que todos podem saber dos Líderes: nome, herói, tipo e quantos Pokémon
create or replace function public.rpg_lider_pub() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_object_agg(regiao, jsonb_build_object('nome', nome, 'classe', classe, 'tipo', tipo, 'n', jsonb_array_length(time))), '{}'::jsonb) from rpg_lideres
$$;
revoke execute on function public.rpg_lider_pub() from public, anon;

create or replace function public.rpg_ginasio(_regiao text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.rpg_cfg()->'ginasios'; l rpg_lideres; t rpg_gin_tent; n int;
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  select * into l from rpg_lideres where regiao = _regiao;
  if l.regiao is null then raise exception 'Não há Ginásio aqui.'; end if;
  perform public.treino_autocura(uid);
  update rpg_gin_tent set status = 'perdeu' where user_id = uid and status = 'andando' and dia < public.game_today();
  select * into t from rpg_gin_tent where user_id = uid and regiao = _regiao and dia = public.game_today() and status = 'andando' order by id desc limit 1;
  select count(*) into n from rpg_gin_tent where user_id = uid and regiao = _regiao and dia = public.game_today();
  return jsonb_build_object('lider', jsonb_build_object('nome', l.nome, 'classe', l.classe, 'tipo', l.tipo, 'n', jsonb_array_length(l.time)),
    'insignia', exists (select 1 from rpg_insignias where user_id = uid and regiao = _regiao),
    'tentativas', n, 'tentativas_dia', (c->>'tentativas_dia')::int, 'moedas', (c->>'moedas')::int, 'itens', c->'itens',
    'tentativa', case when t.id is null then null else jsonb_build_object('id', t.id, 'idx', t.idx, 'total', jsonb_array_length(l.time),
      'meus', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'species', m.species_id, 'level', m.level, 'tr_hp', m.tr_hp) order by e.k)
                         from jsonb_array_elements_text(coalesce(t.meus, '[]'::jsonb)) with ordinality e(v, k) join monsters m on m.id::text = e.v), '[]'::jsonb)) end);
end $$;

drop function if exists public.rpg_ginasio_lutar(text, uuid);
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
  mine := public.bt_mon(m.id);
  hp0 := greatest(1, round((mine->>'maxhp')::int * m.tr_hp / 100.0))::int;
  mine := jsonb_set(mine, '{hp}', to_jsonb(hp0));
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

-- admin: ver e editar os Líderes
create or replace function public.admin_rpg_lideres() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_object_agg(regiao, to_jsonb(x) - 'regiao') from rpg_lideres x), '{}'::jsonb);
end $$;
create or replace function public.admin_rpg_lider_salvar(_regiao text, _nome text, _classe text, _tipo text, _time jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare antes jsonb; e jsonb;
begin
  perform public.assert_admin();
  if not exists (select 1 from rpg_lideres where regiao = _regiao) then raise exception 'Região sem Ginásio.'; end if;
  if length(btrim(coalesce(_nome, ''))) < 2 then raise exception 'Dê um nome ao Líder.'; end if;
  if jsonb_typeof(_time) <> 'array' or jsonb_array_length(_time) not between 1 and 6 then raise exception 'O time precisa ter de 1 a 6 Pokémon.'; end if;
  for e in select * from jsonb_array_elements(_time) loop
    if jsonb_typeof(e) <> 'array' or not exists (select 1 from pokemon where id = (e->>0)::int) or (e->>1)::int not between 1 and 100 then
      raise exception 'Pokémon ou nível inválido: %', e; end if;
  end loop;
  select to_jsonb(x) into antes from rpg_lideres x where regiao = _regiao;
  update rpg_lideres set nome = btrim(_nome), classe = coalesce(nullif(_classe, ''), classe), tipo = coalesce(_tipo, ''), time = _time where regiao = _regiao;
  insert into admin_audit_log(admin_id, action, target, after) values (auth.uid(), 'rpg_lider', _regiao, jsonb_build_object('antes', antes, 'nome', _nome, 'time', _time));
  return public.admin_rpg_lideres();
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
    res := jsonb_build_object('gym', t->>'gym', 'status', tt.status, 'idx', tt.idx, 'total', total, 'lider', l->>'nome');
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
    res := jsonb_build_object('missoes', (select count(*) from rpg_missoes where user_id = b.p1 and dia = public.game_today() and not resgatada and prog >= meta));
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
    'chefe', public.rpg_chefe_info(uid));
end $$;

grant execute on function public.rpg_estado(), public.rpg_ginasio(text), public.rpg_ginasio_lutar(text, uuid, uuid[]), public.admin_rpg_lideres(), public.admin_rpg_lider_salvar(text, text, text, text, jsonb) to authenticated;
revoke execute on function public.rpg_after(uuid) from public, anon, authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🏟️ Ginásios de verdade e o mapa com os nomes', 'Os Ginásios da Aventura ficaram de verdade:
• Cada rota tem agora o prédio do Ginásio. Entre pela porta: lá dentro tem o salão iluminado, o campo de batalha e o Líder esperando no fundo.
• O time do Líder é segredo: você só sabe quantos Pokémon ele usa. Antes de lutar, escolha a mesma quantidade de Pokémon seus, na ordem em que vão entrar.
• O Líder usa sempre os mesmos Pokémon, mas numa ordem sorteada a cada tentativa. Se perder e tentar de novo, todos os Pokémon dele voltam com a vida cheia.
• 📍 No alto da tela da Aventura aparece sempre onde você está (o nome do lugar e as coordenadas). O botão 🗺️ Mapa abre o mapa completo com todas as regiões, os nomes, os níveis e você marcado nele.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
