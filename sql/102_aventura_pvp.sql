-- 102_aventura_pvp.sql
-- Pedido do dono em 12/11/2026: na Aventura, quem passa perto de outro jogador pode desafiá-lo, e o outro é OBRIGADO
-- a batalhar (na hora ou depois, na vez dele: a batalha por turnos não tem prazo). rpg_desafiar(_opponent, _regiao) cria
-- a batalha já ativa (sem convite), com os 3 primeiros da equipe de cada um, SEM moedas (só a experiência das batalhas,
-- no limite do dia) e com o teto de nível (rpg.pvp.teto). Limites em rpg.pvp: o mesmo par 1 vez por dia, desafia_dia (5)
-- e recebe_dia (3). A distância (2 casas) é conferida no site, que é quem sabe onde cada um está.
-- Nova rpg_cfg (versão do 101 + pvp).

create or replace function public.rpg_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select ('{"on": true, "batalhas_dia": 20, "chance_pct": 12, "espera_seg": 8, "envio_seg": 1.2, "fuga_base": 10, "fuga_por_ataque": 10, "nivel_pedra": 28, "nivel_troca": 36, "folga": 10, "lendarios": [144, 145, 146, 150, 151, 243, 244, 245, 249, 250, 251], "zonas": {"mato": {"nome": "Capim alto", "regiao": "vila", "tipos": ["INSETO", "PLANTA", "NORMAL"], "min": 2, "max": 6}, "escura": {"nome": "Grama escura", "regiao": "vila", "tipos": ["NORMAL", "VOADOR", "ELETRICO"], "min": 3, "max": 7}, "pantano": {"nome": "Pântano", "regiao": "vila", "tipos": ["AGUA", "VENENO"], "min": 3, "max": 7}, "pedra": {"nome": "Alto do penhasco", "regiao": "vila", "tipos": ["PEDRA", "TERRA", "LUTA"], "min": 4, "max": 8}, "bosque": {"nome": "Bosque: mato", "regiao": "bosque", "tipos": ["INSETO", "PLANTA", "VENENO", "NORMAL"], "min": 8, "max": 16}, "bosque_fundo": {"nome": "Bosque: mata funda", "regiao": "bosque", "tipos": ["INSETO", "PLANTA", "VENENO", "NORMAL", "VOADOR"], "min": 18, "max": 34}, "praia": {"nome": "Praia: dunas", "regiao": "praia", "tipos": ["AGUA", "ELETRICO", "NORMAL"], "min": 8, "max": 16}, "praia_fundo": {"nome": "Praia: costão", "regiao": "praia", "tipos": ["AGUA", "ELETRICO", "GELO", "VOADOR"], "min": 18, "max": 38}, "deserto": {"nome": "Deserto: capim seco", "regiao": "deserto", "tipos": ["FOGO", "TERRA", "NORMAL"], "min": 12, "max": 22}, "deserto_fundo": {"nome": "Deserto: oásis distante", "regiao": "deserto", "tipos": ["FOGO", "TERRA", "PEDRA", "LUTA"], "min": 24, "max": 42}, "pedreira": {"nome": "Pedreira: entrada", "regiao": "pedreira", "tipos": ["PEDRA", "TERRA", "LUTA", "METALICO"], "min": 12, "max": 22}, "pedreira_fundo": {"nome": "Pedreira: fundo da gruta", "regiao": "pedreira", "tipos": ["PEDRA", "TERRA", "LUTA", "METALICO", "DRAGAO"], "min": 24, "max": 44}, "charco": {"nome": "Charco: margem", "regiao": "charco", "tipos": ["VENENO", "FANTASMA", "PSIQUICO", "SOMBRIO"], "min": 20, "max": 32}, "charco_fundo": {"nome": "Charco: brejo escuro", "regiao": "charco", "tipos": ["FANTASMA", "PSIQUICO", "SOMBRIO", "VENENO", "NORMAL"], "min": 32, "max": 46}, "pico": {"nome": "Pico: encosta", "regiao": "pico", "tipos": ["GELO", "AGUA", "PSIQUICO", "VOADOR", "ELETRICO"], "min": 34, "max": 48}, "pico_fundo": {"nome": "Pico: cume", "regiao": "pico", "tipos": ["DRAGAO", "GELO", "VOADOR", "PSIQUICO", "FOGO", "LUTA", "NORMAL", "PEDRA"], "min": 45, "max": 60}}}'::jsonb || '{"pvp": {"on": true, "distancia": 2, "desafia_dia": 5, "recebe_dia": 3, "teto": true}}'::jsonb || '{"noite": {"on": true, "inicio": 19, "fim": 5, "tipos": ["FANTASMA", "SOMBRIO"]}, "missoes": {"on": true, "por_dia": 3, "moedas_min": 15, "moedas_max": 40, "itens": ["pocao", "super_pocao", "hiper_pocao", "reviver", "antidoto", "despertar", "cura_paralisia", "x_ataque", "x_defesa", "x_velocidade", "x_especial"]}, "ginasios": {"on": true, "tentativas_dia": 3, "moedas": 300, "itens": {"max_pocao": 2, "reviver": 2}, "todas_moedas": 1000, "todas_itens": {"restaurar_tudo": 5}, "lideres": {"bosque": {"nome": "Líder Flora", "classe": "domador", "tipo": "Inseto e Planta", "time": [[12, 30], [47, 31], [71, 33], [3, 35]]}, "praia": {"nome": "Líder Marina", "classe": "arqueiro", "tipo": "Água e Elétrico", "time": [[55, 34], [101, 35], [131, 36], [121, 38]]}, "deserto": {"nome": "Líder Brasa", "classe": "guerreiro", "tipo": "Fogo e Terra", "time": [[51, 38], [59, 40], [112, 41], [6, 42]]}, "pedreira": {"nome": "Líder Rocha", "classe": "mercador", "tipo": "Pedra", "time": [[76, 40], [139, 42], [141, 43], [142, 44]]}, "charco": {"nome": "Líder Sombra", "classe": "mago", "tipo": "Fantasma e Psíquico", "time": [[93, 44], [97, 45], [65, 46], [94, 47]]}, "pico": {"nome": "Líder Neve", "classe": "clerigo", "tipo": "Gelo e Dragão", "time": [[87, 56], [91, 57], [131, 58], [149, 60]]}}}, "chefe": {"on": true, "dia_semana": 6, "hora": 10, "horas": 48, "nivel": 75, "vidas": 40, "turnos": 12, "tentativas_dia": 3, "especies": [149, 130, 143, 112, 94, 68, 131, 59, 6, 65], "moedas": 250, "itens": {"restaurar_tudo": 1, "reviver": 1}, "top_moedas": [300, 200, 100]}}'::jsonb
    || coalesce(public.cfg()->'rpg', '{}'::jsonb)) #- '{ginasios,lideres}'   -- arquivo 101: os times dos Líderes ficam na tabela rpg_lideres
$$;

create or replace function public.rpg_desafiar(_opponent uuid, _regiao text default null) returns public.battles
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.rpg_cfg()->'pvp'; pc jsonb := public.pk_cfg()->'battle'; b battles; n1 text; n2 text;
  s1 jsonb; s2 jsonb; tt int; hoje date := public.game_today(); tz text := coalesce(public.cfg()->>'timezone', 'America/Sao_Paulo'); lugar text;
begin
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
  if exists (select 1 from battles where coalesce((state->>'rpg_pvp')::boolean, false) and ((p1 = uid and p2 = _opponent) or (p1 = _opponent and p2 = uid))
             and (created_at at time zone tz)::date = hoje) then
    raise exception 'Vocês já batalharam hoje na Aventura. Amanhã tem mais!'; end if;
  if (select count(*) from battles where coalesce((state->>'rpg_pvp')::boolean, false) and p1 = uid and (created_at at time zone tz)::date = hoje) >= (c->>'desafia_dia')::int then
    raise exception 'Você já desafiou % jogadores hoje na Aventura.', c->>'desafia_dia'; end if;
  if (select count(*) from battles where coalesce((state->>'rpg_pvp')::boolean, false) and p2 = _opponent and (created_at at time zone tz)::date = hoje) >= (c->>'recebe_dia')::int then
    raise exception '% já foi desafiado(a) % vezes hoje. Deixe para amanhã!', n2, c->>'recebe_dia'; end if;
  tt := case when coalesce((c->>'teto')::boolean, true) then public.teto_nivel() end;
  select jsonb_build_object('user', uid, 'name', n1, 'active', 0, 'need_switch', false, 'mons', jsonb_agg(public.bt_mon_teto(m.id, tt) order by m.team_slot)) into s1
    from (select id, team_slot from monsters where user_id = uid and team_slot is not null order by team_slot limit (pc->>'size')::int) m;
  select jsonb_build_object('user', _opponent, 'name', n2, 'active', 0, 'need_switch', false, 'mons', jsonb_agg(public.bt_mon_teto(m.id, tt) order by m.team_slot)) into s2
    from (select id, team_slot from monsters where user_id = _opponent and team_slot is not null order by team_slot limit (pc->>'size')::int) m;
  lugar := coalesce((public.rpg_cfg()->'zonas'->_regiao->>'nome'), initcap(coalesce(_regiao, 'Aventura')));
  insert into battles(p1, p2, size, bet, status, turn, phase, started_at, state, log)
  values (uid, _opponent, (pc->>'size')::int, 0, 'ativa', 1, 'normal', now(),
          jsonb_build_object('sides', jsonb_build_array(s1, s2), 'xp', '{}'::jsonb, 'rpg_pvp', true, 'regiao', _regiao),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', '⚔️ ' || n1 || ' encontrou ' || n2 || ' na Aventura e desafiou para uma batalha!'),
            jsonb_build_object('txt', n1 || ' mandou ' || (s1->'mons'->0->>'name') || '!'),
            jsonb_build_object('txt', n2 || ' mandou ' || (s2->'mons'->0->>'name') || '!')))))
  returning * into b;
  insert into event_log(user_id, kind, message) values (uid, 'batalha', '⚔️ ' || n1 || ' encontrou ' || n2 || ' na Aventura e os dois vão batalhar!');
  return b;
end $$;
grant execute on function public.rpg_desafiar(uuid, text) to authenticated;
update public.game_config set config = jsonb_set(config, '{rpg,pvp}', public.rpg_cfg()->'pvp') where active and config ? 'rpg' and not (config->'rpg' ? 'pvp');

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('⚔️ Aventura: encontrou, pode desafiar!', 'Agora a Aventura tem batalha entre jogadores:
• Chegou perto de outro jogador (até 2 casas)? Aparece o botão ⚔️ Desafiar.
• O desafio é obrigatório: a batalha já começa, por turnos, com os 3 primeiros da equipe de cada um. Quem foi desafiado joga na hora ou quando entrar no jogo (não tem prazo por turno).
• Não vale moedas, só a experiência das batalhas, e ninguém luta acima do nível 20 (o teto das batalhas).
• Para ninguém virar alvo o dia todo: o mesmo par luta 1 vez por dia, cada um desafia até 5 por dia e pode ser desafiado até 3 vezes por dia.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
