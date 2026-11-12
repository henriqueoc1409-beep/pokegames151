-- 99_aventura_ginasios.sql
-- Pedido do dono em 12/11/2026 (Aventura com mais cara de RPG):
--   (1) Ginásios e insígnias: um Líder por rota (rpg.ginasios.lideres: nome, classe, tipo e time de 4 Pokémon com nível).
--       A luta usa o mesmo motor da Aventura (batalha 'treino' 1 contra 1): o primeiro da sua equipe com vida enfrenta o
--       Pokémon atual do Líder; quem cai sai e entra o próximo. A vida do Líder fica guardada na tentativa (rpg_gin_tent)
--       e a sua é a vida do treino. Vencer os 4 = insígnia (rpg_insignias, pública) + prêmio; as 6 = prêmio extra.
--       tentativas_dia por Ginásio; desistir perde a tentativa. Experiência pela mesma conta (treino_after).
--   (2) Missões dos moradores (rpg_missoes): por_dia (3) sorteadas por dia: vencer N selvagens numa região, N de um
--       tipo, ou 1 selvagem de nível alto (pelo nível do melhor da equipe). Prêmio de itens e poucas moedas.
--   (3) Dia e noite (rpg.noite): das 19h às 5h (horário do jogo) os tipos da noite entram em todas as áreas.
--   (4) Chefe da rota (rpg_chefes, rpg_chefe_dano): no dia/hora da semana (sábado 10h) um Pokémon de nível 75 aparece
--       numa rota sorteada por 48 h; cada luta (12 turnos no máximo) tira dano de uma barra coletiva (vida × vidas).
--       Se vencerem: todos os que lutaram ganham moedas e itens; os 3 que mais bateram ganham mais. Admin solta na hora.
-- Nova rpg_cfg (versão do 97 + noite, missoes, ginasios, chefe), rpg_encontro (do 97, com a noite), battle_act (do 97,
-- chama rpg_after no fim das lutas e usa os turnos do chefe) e rpg_estado (do 93, com insígnias, missões e chefe).

create or replace function public.rpg_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "batalhas_dia": 20, "chance_pct": 12, "espera_seg": 8, "envio_seg": 1.2, "fuga_base": 10, "fuga_por_ataque": 10, "nivel_pedra": 28, "nivel_troca": 36, "folga": 10, "lendarios": [144, 145, 146, 150, 151, 243, 244, 245, 249, 250, 251], "zonas": {"mato": {"nome": "Capim alto", "regiao": "vila", "tipos": ["INSETO", "PLANTA", "NORMAL"], "min": 2, "max": 6}, "escura": {"nome": "Grama escura", "regiao": "vila", "tipos": ["NORMAL", "VOADOR", "ELETRICO"], "min": 3, "max": 7}, "pantano": {"nome": "Pântano", "regiao": "vila", "tipos": ["AGUA", "VENENO"], "min": 3, "max": 7}, "pedra": {"nome": "Alto do penhasco", "regiao": "vila", "tipos": ["PEDRA", "TERRA", "LUTA"], "min": 4, "max": 8}, "bosque": {"nome": "Bosque: mato", "regiao": "bosque", "tipos": ["INSETO", "PLANTA", "VENENO", "NORMAL"], "min": 8, "max": 16}, "bosque_fundo": {"nome": "Bosque: mata funda", "regiao": "bosque", "tipos": ["INSETO", "PLANTA", "VENENO", "NORMAL", "VOADOR"], "min": 18, "max": 34}, "praia": {"nome": "Praia: dunas", "regiao": "praia", "tipos": ["AGUA", "ELETRICO", "NORMAL"], "min": 8, "max": 16}, "praia_fundo": {"nome": "Praia: costão", "regiao": "praia", "tipos": ["AGUA", "ELETRICO", "GELO", "VOADOR"], "min": 18, "max": 38}, "deserto": {"nome": "Deserto: capim seco", "regiao": "deserto", "tipos": ["FOGO", "TERRA", "NORMAL"], "min": 12, "max": 22}, "deserto_fundo": {"nome": "Deserto: oásis distante", "regiao": "deserto", "tipos": ["FOGO", "TERRA", "PEDRA", "LUTA"], "min": 24, "max": 42}, "pedreira": {"nome": "Pedreira: entrada", "regiao": "pedreira", "tipos": ["PEDRA", "TERRA", "LUTA", "METALICO"], "min": 12, "max": 22}, "pedreira_fundo": {"nome": "Pedreira: fundo da gruta", "regiao": "pedreira", "tipos": ["PEDRA", "TERRA", "LUTA", "METALICO", "DRAGAO"], "min": 24, "max": 44}, "charco": {"nome": "Charco: margem", "regiao": "charco", "tipos": ["VENENO", "FANTASMA", "PSIQUICO", "SOMBRIO"], "min": 20, "max": 32}, "charco_fundo": {"nome": "Charco: brejo escuro", "regiao": "charco", "tipos": ["FANTASMA", "PSIQUICO", "SOMBRIO", "VENENO", "NORMAL"], "min": 32, "max": 46}, "pico": {"nome": "Pico: encosta", "regiao": "pico", "tipos": ["GELO", "AGUA", "PSIQUICO", "VOADOR", "ELETRICO"], "min": 34, "max": 48}, "pico_fundo": {"nome": "Pico: cume", "regiao": "pico", "tipos": ["DRAGAO", "GELO", "VOADOR", "PSIQUICO", "FOGO", "LUTA", "NORMAL", "PEDRA"], "min": 45, "max": 60}}}'::jsonb || '{"noite": {"on": true, "inicio": 19, "fim": 5, "tipos": ["FANTASMA", "SOMBRIO"]}, "missoes": {"on": true, "por_dia": 3, "moedas_min": 15, "moedas_max": 40, "itens": ["pocao", "super_pocao", "hiper_pocao", "reviver", "antidoto", "despertar", "cura_paralisia", "x_ataque", "x_defesa", "x_velocidade", "x_especial"]}, "ginasios": {"on": true, "tentativas_dia": 3, "moedas": 300, "itens": {"max_pocao": 2, "reviver": 2}, "todas_moedas": 1000, "todas_itens": {"restaurar_tudo": 5}, "lideres": {"bosque": {"nome": "Líder Flora", "classe": "domador", "tipo": "Inseto e Planta", "time": [[12, 30], [47, 31], [71, 33], [3, 35]]}, "praia": {"nome": "Líder Marina", "classe": "arqueiro", "tipo": "Água e Elétrico", "time": [[55, 34], [101, 35], [131, 36], [121, 38]]}, "deserto": {"nome": "Líder Brasa", "classe": "guerreiro", "tipo": "Fogo e Terra", "time": [[51, 38], [59, 40], [112, 41], [6, 42]]}, "pedreira": {"nome": "Líder Rocha", "classe": "mercador", "tipo": "Pedra", "time": [[76, 40], [139, 42], [141, 43], [142, 44]]}, "charco": {"nome": "Líder Sombra", "classe": "mago", "tipo": "Fantasma e Psíquico", "time": [[93, 44], [97, 45], [65, 46], [94, 47]]}, "pico": {"nome": "Líder Neve", "classe": "clerigo", "tipo": "Gelo e Dragão", "time": [[87, 56], [91, 57], [131, 58], [149, 60]]}}}, "chefe": {"on": true, "dia_semana": 6, "hora": 10, "horas": 48, "nivel": 75, "vidas": 40, "turnos": 12, "tentativas_dia": 3, "especies": [149, 130, 143, 112, 94, 68, 131, 59, 6, 65], "moedas": 250, "itens": {"restaurar_tudo": 1, "reviver": 1}, "top_moedas": [300, 200, 100]}}'::jsonb
    || coalesce(public.cfg()->'rpg', '{}'::jsonb)
$$;

-- ---------- tabelas ----------
create table if not exists public.rpg_insignias (
  user_id uuid not null references auth.users(id) on delete cascade, regiao text not null, ganho_em timestamptz not null default now(),
  primary key (user_id, regiao));
alter table public.rpg_insignias enable row level security;
drop policy if exists rpg_insignias_ler on public.rpg_insignias;
create policy rpg_insignias_ler on public.rpg_insignias for select to authenticated using (true);
grant select on public.rpg_insignias to authenticated;

create table if not exists public.rpg_gin_tent (
  id bigserial primary key, user_id uuid not null references auth.users(id) on delete cascade, regiao text not null,
  dia date not null, idx int not null default 0, hp jsonb not null, status text not null default 'andando', criado timestamptz not null default now());
create index if not exists rpg_gin_tent_user on public.rpg_gin_tent(user_id, regiao, dia);
alter table public.rpg_gin_tent enable row level security;
drop policy if exists rpg_gin_tent_meus on public.rpg_gin_tent;
create policy rpg_gin_tent_meus on public.rpg_gin_tent for select to authenticated using (user_id = auth.uid() or public.is_admin());
grant select on public.rpg_gin_tent to authenticated;

create table if not exists public.rpg_missoes (
  user_id uuid not null references auth.users(id) on delete cascade, dia date not null, n int not null,
  regiao text not null, tipo text not null, alvo text not null, meta int not null, prog int not null default 0,
  premio jsonb not null default '{}'::jsonb, resgatada boolean not null default false, primary key (user_id, dia, n));
alter table public.rpg_missoes enable row level security;
drop policy if exists rpg_missoes_meus on public.rpg_missoes;
create policy rpg_missoes_meus on public.rpg_missoes for select to authenticated using (user_id = auth.uid() or public.is_admin());
grant select on public.rpg_missoes to authenticated;

create table if not exists public.rpg_chefes (
  id bigserial primary key, regiao text not null, especie int not null, nivel int not null, hp_total int not null,
  dano int not null default 0, inicio timestamptz not null default now(), fim timestamptz not null, status text not null default 'ativo',
  premiado boolean not null default false);
alter table public.rpg_chefes enable row level security;
drop policy if exists rpg_chefes_ler on public.rpg_chefes;
create policy rpg_chefes_ler on public.rpg_chefes for select to authenticated using (true);
grant select on public.rpg_chefes to authenticated;
create table if not exists public.rpg_chefe_dano (
  chefe_id bigint not null references public.rpg_chefes(id) on delete cascade, user_id uuid not null references auth.users(id) on delete cascade,
  dano int not null default 0, lutas int not null default 0, dia date, lutas_dia int not null default 0, primary key (chefe_id, user_id));
alter table public.rpg_chefe_dano enable row level security;
drop policy if exists rpg_chefe_dano_ler on public.rpg_chefe_dano;
create policy rpg_chefe_dano_ler on public.rpg_chefe_dano for select to authenticated using (true);
grant select on public.rpg_chefe_dano to authenticated;

-- ---------- noite ----------
create or replace function public.rpg_noite() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((c->'noite'->>'on')::boolean, true) and (
    case when (c->'noite'->>'inicio')::int > (c->'noite'->>'fim')::int
      then h >= (c->'noite'->>'inicio')::int or h < (c->'noite'->>'fim')::int
      else h >= (c->'noite'->>'inicio')::int and h < (c->'noite'->>'fim')::int end)
  from (select public.rpg_cfg() c, extract(hour from now() at time zone coalesce(public.cfg()->>'timezone', 'America/Sao_Paulo'))::int h) x
$$;

-- dá moedas e itens da bolsa (prêmios da Aventura)
create or replace function public.rpg_premiar(_uid uuid, _coins int, _bag jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare k text; v int;
begin
  if coalesce(_coins, 0) > 0 then update characters set coins = coins + _coins where user_id = _uid; end if;
  for k, v in select key, value::int from jsonb_each_text(coalesce(_bag, '{}'::jsonb)) loop
    if v > 0 and exists (select 1 from pk_items where id = k) then
      insert into bag_items(user_id, item, qty) values (_uid, k, v) on conflict (user_id, item) do update set qty = bag_items.qty + v;
    end if;
  end loop;
end $$;

-- ---------- missões ----------
create or replace function public.rpg_missoes_gerar(_uid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rpg_cfg()->'missoes'; regs text[] := array['vila', 'bosque', 'praia', 'deserto', 'pedreira', 'charco', 'pico'];
  tipos text[] := array['NORMAL', 'INSETO', 'PLANTA', 'AGUA', 'VOADOR', 'VENENO', 'ELETRICO', 'PEDRA', 'TERRA', 'FOGO', 'LUTA', 'PSIQUICO', 'FANTASMA', 'GELO'];
  itens text[]; k int; tp text; alvo text; meta int; reg text; melhor int; mn int; mx int;
begin
  if not coalesce((c->>'on')::boolean, true) or exists (select 1 from rpg_missoes where user_id = _uid and dia = public.game_today()) then return; end if;
  select array_agg(x) into itens from jsonb_array_elements_text(c->'itens') x;
  select coalesce(max(level), 5) into melhor from monsters where user_id = _uid and team_slot is not null;
  mn := coalesce((c->>'moedas_min')::int, 15); mx := greatest(mn, coalesce((c->>'moedas_max')::int, 40));
  for k in 1 .. greatest(1, least(6, coalesce((c->>'por_dia')::int, 3))) loop
    tp := (array['regiao', 'tipo', 'nivel'])[1 + (k - 1) % 3];
    reg := regs[1 + floor(random() * case when melhor < 15 then 2 when melhor < 25 then 4 when melhor < 35 then 5 else 7 end)::int];
    if tp = 'regiao' then alvo := reg; meta := case when reg = 'vila' then 4 else 3 end;
    elsif tp = 'tipo' then alvo := tipos[1 + floor(random() * array_length(tipos, 1))::int]; meta := 2 + floor(random() * 2)::int;
    else alvo := greatest(5, melhor - 2)::text; meta := 1; end if;
    insert into rpg_missoes(user_id, dia, n, regiao, tipo, alvo, meta, premio)
    values (_uid, public.game_today(), k, reg, tp, alvo, meta,
            jsonb_build_object('coins', mn + floor(random() * (mx - mn + 1))::int, 'bag', jsonb_build_object(itens[1 + floor(random() * array_length(itens, 1))::int], 1)))
    on conflict do nothing;
  end loop;
end $$;

create or replace function public.rpg_missao_resgatar(_n int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); m rpg_missoes;
begin
  select * into m from rpg_missoes where user_id = uid and dia = public.game_today() and n = _n for update;
  if m.user_id is null then raise exception 'Missão não encontrada.'; end if;
  if m.resgatada then raise exception 'Você já pegou o prêmio desta missão.'; end if;
  if m.prog < m.meta then raise exception 'A missão ainda não está completa (% de %).', m.prog, m.meta; end if;
  update rpg_missoes set resgatada = true where user_id = uid and dia = m.dia and n = m.n;
  perform public.rpg_premiar(uid, (m.premio->>'coins')::int, m.premio->'bag');
  return m.premio;
end $$;

-- ---------- Ginásios ----------
create or replace function public.rpg_ginasio(_regiao text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.rpg_cfg()->'ginasios'; l jsonb := c->'lideres'->_regiao; t rpg_gin_tent; n int;
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  if l is null then raise exception 'Não há Ginásio aqui.'; end if;
  select * into t from rpg_gin_tent where user_id = uid and regiao = _regiao and dia = public.game_today() and status = 'andando' order by id desc limit 1;
  select count(*) into n from rpg_gin_tent where user_id = uid and regiao = _regiao and dia = public.game_today();
  return jsonb_build_object('lider', l, 'insignia', exists (select 1 from rpg_insignias where user_id = uid and regiao = _regiao),
    'tentativas', n, 'tentativas_dia', (c->>'tentativas_dia')::int, 'moedas', (c->>'moedas')::int, 'itens', c->'itens',
    'tentativa', case when t.id is null then null else jsonb_build_object('id', t.id, 'idx', t.idx, 'hp', t.hp) end);
end $$;

create or replace function public.rpg_ginasio_lutar(_regiao text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.rpg_cfg()->'ginasios'; l jsonb := c->'lideres'->_regiao; me characters; t rpg_gin_tent; bid uuid; n int;
  m monsters; sp int; lv int; wild jsonb; mine jsonb; hp0 int; whp int; s0 jsonb; s1 jsonb;
begin
  if not coalesce((c->>'on')::boolean, true) and not public.is_admin() then raise exception 'Os Ginásios estão fechados no momento.'; end if;
  if l is null then raise exception 'Não há Ginásio aqui.'; end if;
  if exists (select 1 from rpg_insignias where user_id = uid and regiao = _regiao) then raise exception 'Você já tem a insígnia deste Ginásio.'; end if;
  select * into me from characters where user_id = uid for update;
  bid := public.treino_batalha(uid);
  if bid is not null then return jsonb_build_object('battle', bid); end if;
  update rpg_gin_tent set status = 'perdeu' where user_id = uid and status = 'andando' and dia < public.game_today();
  select * into t from rpg_gin_tent where user_id = uid and regiao = _regiao and dia = public.game_today() and status = 'andando' order by id desc limit 1;
  if t.id is null then
    select count(*) into n from rpg_gin_tent where user_id = uid and regiao = _regiao and dia = public.game_today();
    if n >= (c->>'tentativas_dia')::int then raise exception 'Você já usou as % tentativas de hoje neste Ginásio. Volte amanhã!', (c->>'tentativas_dia'); end if;
    insert into rpg_gin_tent(user_id, regiao, dia, hp) values (uid, _regiao, public.game_today(), (select jsonb_agg(100) from jsonb_array_elements(l->'time')))
    returning * into t;
  end if;
  perform public.treino_autocura(uid);
  select * into m from monsters where user_id = uid and team_slot is not null and tr_hp > 0 order by team_slot limit 1;
  if m.id is null then
    update rpg_gin_tent set status = 'perdeu' where id = t.id;
    return jsonb_build_object('fim', 'perdeu', 'msg', 'Todos os Pokémon da sua equipe estão desmaiados. A tentativa acabou.');
  end if;
  delete from battles where mode = 'treino' and p1 = uid and status <> 'ativa';
  sp := (l->'time'->t.idx->>0)::int; lv := (l->'time'->t.idx->>1)::int;
  wild := public.npc_mon(sp, lv);
  whp := greatest(1, ceil((wild->>'maxhp')::int * coalesce((t.hp->>t.idx)::numeric, 100) / 100))::int;
  wild := jsonb_set(wild, '{hp}', to_jsonb(whp));
  mine := public.bt_mon(m.id);
  hp0 := greatest(1, round((mine->>'maxhp')::int * m.tr_hp / 100.0))::int;
  mine := jsonb_set(mine, '{hp}', to_jsonb(hp0));
  s0 := jsonb_build_object('user', uid, 'name', me.name, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(mine));
  s1 := jsonb_build_object('user', uid, 'name', l->>'nome', 'npc', true, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(wild));
  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (uid, uid, 'treino', 1, 'ativa', 1, 'normal', now(),
          jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb, 'treino', jsonb_build_object('mon', m.id, 'forte', false, 'gym', _regiao, 'gym_try', t.id, 'gym_idx', t.idx)),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', (l->>'nome') || ' manda ' || (wild->>'name') || ' (nível ' || lv || ')' || case when whp < (wild->>'maxhp')::int then ', ainda ferido,' else '' end || ' para a luta! (' || (t.idx + 1) || 'º de ' || jsonb_array_length(l->'time') || ')'),
            jsonb_build_object('txt', 'Vai, ' || (mine->>'name') || '!' || case when m.tr_hp < 100 then ' (com ' || m.tr_hp || '% da vida)' else '' end)))))
  returning id into bid;
  return jsonb_build_object('battle', bid);
end $$;

-- ---------- Chefe da rota ----------
create or replace function public.rpg_chefe_criar(_regiao text, _especie int) returns rpg_chefes
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rpg_cfg()->'chefe'; regs text[] := array['bosque', 'praia', 'deserto', 'pedreira', 'charco', 'pico']; r text; sp int; w jsonb; ch rpg_chefes;
begin
  update rpg_chefes set status = 'fugiu' where status = 'ativo';
  r := coalesce(_regiao, regs[1 + floor(random() * 6)::int]);
  sp := coalesce(_especie, (select (x)::int from jsonb_array_elements_text(c->'especies') x order by random() limit 1), 143);
  w := public.npc_mon(sp, (c->>'nivel')::int);
  insert into rpg_chefes(regiao, especie, nivel, hp_total, fim)
  values (r, sp, (c->>'nivel')::int, (w->>'maxhp')::int * greatest(1, (c->>'vidas')::int), now() + make_interval(hours => (c->>'horas')::int))
  returning * into ch;
  insert into event_log(kind, message) values ('chefe', '👹 Um ' || (w->>'name') || ' gigante (nível ' || ch.nivel || ') apareceu na Aventura! Todos juntos contra ele por ' || (c->>'horas') || ' horas.');
  return ch;
end $$;
revoke execute on function public.rpg_chefe_criar(text, int) from public, anon, authenticated;

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
  end loop;
  select name into nome from pokemon where id = ch.especie;
  insert into event_log(kind, message) values ('chefe', '🎉 O ' || nome || ' gigante foi derrotado! Os ' || n || ' treinadores que lutaram ganharam o prêmio, e os 3 que mais bateram levaram um extra.');
end $$;
revoke execute on function public.rpg_chefe_premiar(bigint) from public, anon, authenticated;

create or replace function public.rpg_chefe_tick() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rpg_cfg()->'chefe'; tz text := coalesce(public.cfg()->>'timezone', 'America/Sao_Paulo'); agora timestamp := now() at time zone tz;
begin
  update rpg_chefes set status = 'fugiu' where status = 'ativo' and fim < now();
  if not coalesce((c->>'on')::boolean, true) or to_regclass('public.sql_aplicados') is null then return; end if;   -- automático só em produção
  if extract(dow from agora)::int = (c->>'dia_semana')::int and extract(hour from agora)::int >= (c->>'hora')::int
     and not exists (select 1 from rpg_chefes where (inicio at time zone tz)::date = agora::date) and not exists (select 1 from rpg_chefes where status = 'ativo') then
    perform public.rpg_chefe_criar(null, null);
  end if;
end $$;

create or replace function public.rpg_chefe_info(_uid uuid) returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select case when ch.id is null then null else jsonb_build_object('id', ch.id, 'regiao', ch.regiao, 'especie', ch.especie, 'nivel', ch.nivel, 'hp_total', ch.hp_total,
    'dano', ch.dano, 'fim', ch.fim, 'status', ch.status, 'tentativas_dia', (public.rpg_cfg()->'chefe'->>'tentativas_dia')::int,
    'minhas_lutas', coalesce((select case when d.dia = public.game_today() then d.lutas_dia else 0 end from rpg_chefe_dano d where d.chefe_id = ch.id and d.user_id = _uid), 0),
    'meu_dano', coalesce((select d.dano from rpg_chefe_dano d where d.chefe_id = ch.id and d.user_id = _uid), 0),
    'ranking', coalesce((select jsonb_agg(jsonb_build_object('name', c2.name, 'dano', d.dano) order by d.dano desc) from (select * from rpg_chefe_dano where chefe_id = ch.id and dano > 0 order by dano desc limit 5) d join characters c2 on c2.user_id = d.user_id), '[]'::jsonb)) end
  from (select * from rpg_chefes where status = 'ativo' or (status = 'vencido' and fim > now() - interval '1 day') order by id desc limit 1) ch
  right join (select 1) um on true
$$;

create or replace function public.rpg_chefe_lutar() returns jsonb
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
  delete from battles where mode = 'treino' and p1 = uid and status <> 'ativa';
  wild := public.npc_mon(ch.especie, ch.nivel);
  mine := public.bt_mon(m.id);
  hp0 := greatest(1, round((mine->>'maxhp')::int * m.tr_hp / 100.0))::int;
  mine := jsonb_set(mine, '{hp}', to_jsonb(hp0));
  s0 := jsonb_build_object('user', uid, 'name', me.name, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(mine));
  s1 := jsonb_build_object('user', uid, 'name', 'Chefe da rota', 'npc', true, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(wild));
  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (uid, uid, 'treino', 1, 'ativa', 1, 'normal', now(),
          jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb, 'treino', jsonb_build_object('mon', m.id, 'forte', true, 'chefe', ch.id)),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', '👹 O ' || (wild->>'name') || ' gigante (nível ' || ch.nivel || ') ruge! Você tem ' || (c->>'turnos') || ' turnos para causar o máximo de dano.'),
            jsonb_build_object('txt', 'Vai, ' || (mine->>'name') || '!' || case when m.tr_hp < 100 then ' (com ' || m.tr_hp || '% da vida)' else '' end)))))
  returning id into bid;
  update rpg_chefe_dano set lutas = lutas + 1, lutas_dia = lutas_dia + 1 where chefe_id = ch.id and user_id = uid;
  return jsonb_build_object('battle', bid);
end $$;

create or replace function public.admin_rpg_chefe(_regiao text default null, _especie int default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare ch rpg_chefes;
begin
  perform public.assert_admin();
  ch := public.rpg_chefe_criar(nullif(_regiao, ''), _especie);
  insert into admin_audit_log(admin_id, action, target, after) values (auth.uid(), 'rpg_chefe', ch.regiao, jsonb_build_object('especie', ch.especie, 'id', ch.id));
  return to_jsonb(ch);
end $$;

-- ---------- depois de cada luta da Aventura: Ginásio, Chefe e missões ----------
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
    l := c->'ginasios'->'lideres'->(t->>'gym');
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
          if n >= jsonb_array_length(jsonb_path_query_array(c->'ginasios'->'lideres', '$.*')) then
            perform public.rpg_premiar(b.p1, (c->'ginasios'->>'todas_moedas')::int, c->'ginasios'->'todas_itens');
            insert into event_log(user_id, kind, message) values (b.p1, 'ginasio', '👑 ' || nome || ' juntou TODAS as insígnias da Aventura!');
          end if;
        end if;
        update rpg_gin_tent set idx = tt.idx, hp = tt.hp, status = tt.status where id = tt.id;
      else
        tt.hp := jsonb_set(tt.hp, array[tt.idx::text], to_jsonb(greatest(1, ceil((wi->>'hp')::numeric * 100 / greatest(1, (wi->>'maxhp')::int)))::int));
        if not exists (select 1 from monsters where user_id = b.p1 and team_slot is not null and tr_hp > 0) then tt.status := 'perdeu'; end if;
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
revoke execute on function public.rpg_after(uuid), public.rpg_missoes_gerar(uuid), public.rpg_chefe_tick(), public.rpg_chefe_info(uuid), public.rpg_premiar(uuid, int, jsonb), public.rpg_noite() from public, anon, authenticated;

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
  if d.batalhas >= (c->>'batalhas_dia')::int then
    raise exception 'Você já fez as % lutas de hoje na Aventura. Amanhã tem mais.', (c->>'batalhas_dia');
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
  select p.id into sp from pokemon p
   where public.gen_ok(p.id) and not (p.id = any(coalesce(lend, '{}'::int[])))
     and (p.g1_type1 = any(tipos) or p.g1_type2 = any(tipos))
     and public.rpg_nivel_min(p.id) <= lvl and lvl < public.rpg_nivel_max(p.id)
   order by -ln(1 - random()) / greatest(p.catch_rate, 1) limit 1;   -- sorteio com peso: os de captura difícil saem menos
  if sp is null then raise exception 'Nenhum Pokémon por aqui… continue andando.'; end if;
  wild := public.npc_mon(sp, lvl);
  mine := public.bt_mon(m.id);
  hp0 := greatest(1, round((mine->>'maxhp')::int * m.tr_hp / 100.0))::int;
  mine := jsonb_set(mine, '{hp}', to_jsonb(hp0));
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
  return jsonb_build_object('battle', bid, 'batalhas', d.batalhas + 1, 'batalhas_dia', (c->>'batalhas_dia')::int);
end $$;

create or replace function public.battle_act(_id uuid, _turn int, _kind text, _value int, _item text default null) returns public.battles
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); b battles; side int; s jsonb; A jsonb; kind text := _kind; ok boolean; pre int; p jsonb; k int; item text;
  rc jsonb; custo int := 0; moedas int; lim int;
begin
  select * into b from battles where id = _id for update;
  if b.id is null or uid not in (b.p1, b.p2) then raise exception 'Batalha não encontrada.'; end if;
  if b.status <> 'ativa' then raise exception 'Essa batalha não está em andamento.'; end if;
  side := case when uid = b.p1 then 0 else 1 end;
  if _kind = 'forfeit' then
    -- arquivo 97: fugir de uma luta da Aventura custa moedas (base + um tanto por ataque já feito)
    if b.mode = 'treino' and b.state->'treino'->>'rpg' is not null then
      rc := public.rpg_cfg();
      custo := greatest(0, coalesce((rc->>'fuga_base')::int, 0) + coalesce((rc->>'fuga_por_ataque')::int, 0) * coalesce((b.state->'treino'->>'ataques')::int, 0));
      if custo > 0 then
        select coins into moedas from characters where user_id = uid for update;
        if coalesce(moedas, 0) < custo then raise exception 'Fugir agora custa % moedas e você tem %. Continue lutando!', custo, coalesce(moedas, 0); end if;
        update characters set coins = coins - custo where user_id = uid;
        update battles set state = jsonb_set(state, '{treino,fuga_paga}', to_jsonb(custo)) where id = b.id;
      end if;
    end if;
    update battles set log = log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt', case when b.mode = 'treino' then case when custo > 0 then 'Você pagou ' || custo || ' moedas e fugiu da luta.' else 'Você fugiu da luta.' end else (b.state->'sides'->side->>'name') || ' desistiu da batalha.' end))))
     where id = b.id;
    perform public.bt_finish(b.id, case when side = 0 then b.p2 else b.p1 end, 'desistencia');
    if b.mode = 'rocket' then perform public.rocket_after(b.id, public.rocket_dmg(b.state)); end if;
    if b.mode = 'treino' then perform public.treino_after(b.id); perform public.rpg_after(b.id); end if;
    select * into b from battles where id = _id; return b;
  end if;
  if _turn <> b.turn then raise exception 'Esse turno já passou. Atualize a tela.'; end if;
  if (side = 0 and b.ready1) or (side = 1 and b.ready2) then raise exception 'Você já escolheu a ação deste turno. Espere o adversário.'; end if;
  s := b.state; A := s->'sides'->side->'mons'->((s->'sides'->side->>'active')::int);
  if b.phase = 'troca' or coalesce((s->'sides'->side->>'need_switch')::boolean, false) then
    if _kind <> 'switch' then raise exception 'Escolha qual Pokémon vai entrar.'; end if;
  end if;
  if _kind = 'switch' then
    if _value is null or _value < 0 or _value >= jsonb_array_length(s->'sides'->side->'mons') then raise exception 'Pokémon inválido.'; end if;
    if _value = (s->'sides'->side->>'active')::int then raise exception 'Esse Pokémon já está em campo.'; end if;
    if (s->'sides'->side->'mons'->_value->>'hp')::int <= 0 then raise exception 'Esse Pokémon desmaiou.'; end if;
    if (A->>'hp')::int > 0 and b.phase <> 'troca' and (coalesce(A->'fl'->>'charging', '') <> '' or coalesce((A->'fl'->>'recharge')::boolean, false)) then raise exception 'Não dá para trocar agora.'; end if;
  elsif _kind = 'move' then
    if coalesce(A->'fl'->>'charging', '') <> '' or coalesce((A->'fl'->>'recharge')::boolean, false) then kind := 'forced';
    elsif _value = -1 then
      select bool_and((x->>'pp')::int = 0) into ok from jsonb_array_elements(A->'moves') x;
      if not ok then raise exception 'Ainda há ataques com PP.'; end if;
    else
      if _value is null or _value < 0 or _value >= jsonb_array_length(A->'moves') then raise exception 'Ataque inválido.'; end if;
      if (A->'moves'->_value->>'pp')::int <= 0 then raise exception 'Esse ataque está sem PP.'; end if;
    end if;
  elsif _kind = 'item' then
    perform public.bt_item_check(s, side, uid, _item, _value);
    item := _item;
  else raise exception 'Ação inválida.'; end if;
  insert into battle_actions(battle_id, turn, side, user_id, kind, value, item) values (b.id, b.turn, side, uid, kind, _value, item);
  -- Equipe Rocket (arquivo 44): o servidor joga pelo lado da Rocket na hora e conta o dano na barra coletiva
  if b.mode = 'rocket' then
    pre := public.rocket_dmg(b.state);
    p := public.war_pick(b.state, 1, 'forte');
    insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, uid, p->>'kind', (p->>'value')::int);
    perform public.bt_resolve(b.id);
    for k in 1 .. 3 loop
      select * into b from battles where id = _id;
      exit when b.status <> 'ativa' or b.phase <> 'troca' or not coalesce((b.state->'sides'->1->>'need_switch')::boolean, false);
      insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, uid, 'switch', public.war_switch(b.state, 1, true));
      perform public.bt_resolve(b.id);
    end loop;
    perform public.rocket_after(_id, pre);
    select * into b from battles where id = _id;
    return b;
  end if;
  -- Grama de Treino (arquivo 56): o selvagem joga sozinho na hora; no fim, XP e vida pelo treino_after
  if b.mode = 'treino' then
    if kind = 'move' and b.state->'treino'->>'rpg' is not null then   -- arquivo 97: conta os ataques (a fuga fica mais cara)
      update battles set state = jsonb_set(state, '{treino,ataques}', to_jsonb(coalesce((state->'treino'->>'ataques')::int, 0) + 1)) where id = b.id;
    end if;
    p := public.war_pick(b.state, 1, 'forte');
    insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, uid, p->>'kind', (p->>'value')::int);
    perform public.bt_resolve(b.id);
    select * into b from battles where id = _id;
    lim := case when b.state->'treino' ? 'chefe' then coalesce((public.rpg_cfg()->'chefe'->>'turnos')::int, 12) else (public.treino_cfg()->>'turnos')::int end;
    if b.status = 'ativa' and b.turn > lim then
      update battles set log = log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt',
        case when b.state->'treino' ? 'chefe' then 'O chefe rugiu e jogou você para longe! Fim da luta.' else 'A luta demorou demais e o selvagem fugiu para a grama.' end))))
       where id = b.id;
      perform public.bt_finish(b.id, null, 'limite');
    end if;
    select * into b from battles where id = _id;
    if b.status <> 'ativa' then perform public.treino_after(_id); perform public.rpg_after(_id); select * into b from battles where id = _id; end if;
    return b;
  end if;
  if side = 0 then update battles set ready1 = true where id = b.id returning * into b;
  else update battles set ready2 = true where id = b.id returning * into b; end if;
  if b.ready1 and b.ready2 then perform public.bt_resolve(b.id); end if;
  select * into b from battles where id = _id;
  return b;
end $$;

create or replace function public.rpg_estado() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.rpg_cfg(); nb int;
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  select batalhas into nb from rpg_dias where user_id = uid and dia = public.game_today();
  perform public.rpg_chefe_tick();
  perform public.rpg_missoes_gerar(uid);
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'batalhas', coalesce(nb, 0), 'batalhas_dia', (c->>'batalhas_dia')::int,
    'chance_pct', (c->>'chance_pct')::numeric, 'espera_seg', (c->>'espera_seg')::int, 'batalha', public.treino_batalha(uid),
    'noite', public.rpg_noite(),
    'insignias', coalesce((select jsonb_agg(regiao order by ganho_em) from rpg_insignias where user_id = uid), '[]'::jsonb),
    'missoes', coalesce((select jsonb_agg(jsonb_build_object('n', n, 'regiao', regiao, 'tipo', tipo, 'alvo', alvo, 'meta', meta, 'prog', prog, 'premio', premio, 'resgatada', resgatada) order by n)
                         from rpg_missoes where user_id = uid and dia = public.game_today()), '[]'::jsonb),
    'chefe', public.rpg_chefe_info(uid));
end $$;

grant execute on function public.rpg_estado(), public.rpg_encontro(uuid, text, uuid), public.battle_act(uuid, int, text, int, text),
  public.rpg_missao_resgatar(int), public.rpg_ginasio(text), public.rpg_ginasio_lutar(text), public.rpg_chefe_lutar(), public.admin_rpg_chefe(text, int) to authenticated;
update public.game_config set config = jsonb_set(config, '{rpg}', public.rpg_cfg()) where active and not (config->'rpg' ? 'ginasios');

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🏟️ Aventura: Ginásios, missões, noite e o Chefe da rota', 'Novidades na Aventura:
• 🏟️ Ginásios: cada rota tem um Líder de Ginásio com 4 Pokémon fortes. Você luta com a sua equipe, um Pokémon de cada vez, e a vida que ele perde continua perdida. Vença os 4 e ganhe a insígnia da rota (e um prêmio). São 6 insígnias; quem juntar todas ganha um prêmio especial. São 3 tentativas por dia em cada Ginásio.
• 📜 Missões: os moradores com "!" dão 3 missões por dia (vencer Pokémon de um tipo, numa rota, ou um selvagem forte). Volte a falar com quem deu a missão para pegar o prêmio.
• 🌙 Dia e noite: das 19h às 5h a Aventura escurece, e Fantasmas e Sombrios aparecem em todas as áreas.
• 👹 Chefe da rota: todo sábado um Pokémon gigante (nível 75) aparece numa rota por 48 horas. Todos lutam contra ele e cada golpe tira da mesma barra de vida. Se a turma vencer, todos que lutaram ganham prêmio, e os 3 que mais bateram ganham mais. É difícil: vá com a equipe forte e curada!')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
