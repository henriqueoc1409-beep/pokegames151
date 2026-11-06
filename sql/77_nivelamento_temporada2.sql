-- =====================================================================
-- POKEGAMES — Nivelamento da Temporada 2 (pedido do dono em 06/11/2026).
--  1. Reset único: todo Pokémon acima do nível 5 volta ao nível 5 (ataques e
--     evoluções ficam); todos voltam com vida cheia (Grama e Guerra), de graça.
--  2. Compensação no Correio: 10 moedas por nível perdido. Quem não perdeu
--     nada ganha a menor compensação, com mínimo de 300 moedas.
--  3. Antes do reset, no mesmo instante: creches em andamento canceladas
--     (moedas dos níveis que não chegaram voltam), leilões abertos cancelados
--     (lances devolvidos) e batalhas em andamento sem o XP acumulado.
--  4. Teto nas batalhas entre jogadores valendo moedas: nível 20 nesta
--     temporada, +5 por temporada, até 40 (game_config.config.teto). O XP sai
--     pelo nível de batalha. A Liga não tem teto.
--  5. Todos ganham um inicial nível 5 (Bulbasaur, Charmander, Squirtle,
--     Pikachu ou Eevee). Jogador novo ganha também 3 Pokémon sorteados 10
--     níveis abaixo do teto (game_config.config.boas_vindas).
--  6. Creche: nível × 5 até o 30, nível × 10 acima; 10 níveis por semana até o
--     30 e 5 acima (contando a partir do nivelamento).
--  7. Cabo Link na Loja Pokémon: faz as evoluções por troca (Kadabra,
--     Machoke, Graveler, Haunter). Acaba ao usar.
-- Em produção (onde existe sql_aplicados) o reset roda na hora e o jogo é
-- DESPAUSADO no fim. Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

-- ---------- números (aba Ajustes do jogo) ----------
create or replace function public.teto_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "nivel_inicial": 20, "por_temporada": 5, "nivel_max": 40, "temporada_ref": null}'::jsonb || coalesce(public.cfg()->'teto', '{}'::jsonb)
$$;
create or replace function public.boas_vindas_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "iniciais": [1, 4, 7, 25, 133], "inicial_nivel": 5, "pacote_qtd": 3, "pacote_abaixo_teto": 10}'::jsonb || coalesce(public.cfg()->'boas_vindas', '{}'::jsonb)
$$;

-- teto da temporada atual: nível inicial + por_temporada × temporadas desde a de referência (a de quando este arquivo rodou)
create or replace function public.teto_calc() returns int
language sql stable security definer set search_path = public, extensions as $$
  with c as (select public.teto_cfg() c), s as (select max(id) cur from seasons where status = 'ativa')
  select least((c->>'nivel_max')::int, (c->>'nivel_inicial')::int + (c->>'por_temporada')::int *
    (select count(*)::int from seasons x where x.id > coalesce((c->>'temporada_ref')::int, s.cur) and x.id <= s.cur))
  from c, s
$$;
create or replace function public.teto_nivel() returns int
language sql stable security definer set search_path = public, extensions as $$
  select case when coalesce((public.teto_cfg()->>'on')::boolean, true) then public.teto_calc() end
$$;
-- para o site mostrar "nesta temporada, os Pokémon lutam no máximo no nível X"
create or replace function public.teto_estado() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object('on', coalesce((public.teto_cfg()->>'on')::boolean, true), 'nivel', public.teto_calc())
$$;

-- Pokémon da batalha no nível do teto (atributos e XP pelo nível de batalha); sem teto = bt_mon de sempre
create or replace function public.bt_mon_teto(_id uuid, _teto int) returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select case when _teto is null or m.level <= _teto then public.bt_mon(_id) else
    public.bt_mon(_id) || jsonb_build_object('level', _teto, 'real_level', m.level,
      'maxhp', public.pk_stat(p.base_hp, public.pk_hp_dv(m.dv_atk, m.dv_def, m.dv_spd, m.dv_spc), _teto, true),
      'hp',    public.pk_stat(p.base_hp, public.pk_hp_dv(m.dv_atk, m.dv_def, m.dv_spd, m.dv_spc), _teto, true),
      'atk', public.pk_stat(p.base_atk, m.dv_atk, _teto, false), 'def', public.pk_stat(p.base_def, m.dv_def, _teto, false),
      'spd', public.pk_stat(p.base_spd, m.dv_spd, _teto, false), 'spc', public.pk_stat(p.base_spc, m.dv_spc, _teto, false)) end
  from monsters m join pokemon p on p.id = m.species_id where m.id = _id
$$;

-- ---------- Cabo Link ----------
alter table public.pk_items drop constraint if exists pk_items_kind_check;
alter table public.pk_items add constraint pk_items_kind_check check (kind in ('cura','estado','reviver','x','tm','hm','evo'));
insert into public.pk_items(id, name, kind, descr, price, drop_w, sort)
values ('cabo_link', 'Cabo Link', 'evo', 'Faz evoluir os Pokémon que, na Red/Blue, só evoluem por troca (Kadabra, Machoke, Graveler e Haunter). Acaba ao usar.', 250, 0, 900)
on conflict (id) do nothing;

-- ---------- presentes de Pokémon ----------
alter table public.characters add column if not exists boas_vindas_at timestamptz;

-- cria o Pokémon e põe no primeiro lugar livre da equipe (coleção cheia = não dá)
create or replace function public.mon_dar(_uid uuid, _species int, _lvl int) returns public.monsters
language plpgsql security definer set search_path = public, extensions as $$
declare m monsters; slot int;
begin
  begin
    m := public.pk_new_monster(_uid, _species, greatest(1, least(100, _lvl)));
  exception when others then return null;
  end;
  select s into slot from generate_series(1, 6) s where not exists (select 1 from monsters x where x.user_id = _uid and x.team_slot = s) order by s limit 1;
  if slot is not null then update monsters set team_slot = slot where id = m.id returning * into m; end if;
  return m;
end $$;

create or replace function public.inicial_sorteado() returns int
language sql volatile security definer set search_path = public, extensions as $$
  select x::int from jsonb_array_elements_text(public.boas_vindas_cfg()->'iniciais') x order by random() limit 1
$$;

-- jogador novo (herói criado depois do nivelamento): inicial + pacote de boas-vindas, uma vez só (chamado pelo pk_sync)
create or replace function public.boas_vindas_dar(_uid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.boas_vindas_cfg(); me characters; m monsters; nomes text[] := '{}'; lv int; i int; sp int;
begin
  select * into me from characters where user_id = _uid for update;
  if me.id is null or me.boas_vindas_at is not null or not coalesce((c->>'on')::boolean, true) then return; end if;
  -- só quem criou o herói depois do nivelamento (quem já jogava ganhou o inicial no próprio nivelamento)
  if not (public.cfg() ? 'nivelamento_at') or me.created_at < (public.cfg()->>'nivelamento_at')::timestamptz then return; end if;
  update characters set boas_vindas_at = now() where id = me.id;
  sp := public.inicial_sorteado();
  m := public.mon_dar(_uid, sp, (c->>'inicial_nivel')::int);
  if m.id is not null then nomes := nomes || ((select name from pokemon where id = sp) || ' (nível ' || m.level || ')'); end if;
  lv := greatest(1, public.teto_calc() - (c->>'pacote_abaixo_teto')::int);
  for i in 1 .. coalesce((c->>'pacote_qtd')::int, 0) loop
    sp := public.pk_pick_species(null);
    if sp is null then continue; end if;
    m := public.mon_dar(_uid, sp, lv);
    if m.id is not null then nomes := nomes || ((select name from pokemon where id = sp) || ' (nível ' || m.level || ')'); end if;
  end loop;
  if cardinality(nomes) > 0 then
    insert into gifts(user_id, message, created_by)
    values (_uid, 'Bem-vindo ao Pokegames! Sua equipe inicial já está na sua coleção: ' || array_to_string(nomes, ', ') || '.',
            (select user_id from user_roles where role = 'admin' order by user_id limit 1));
  end if;
end $$;

-- semana da Creche, contando só a partir do nivelamento
create or replace function public.creche_inicio_semana() returns timestamptz
language sql stable security definer set search_path = public, extensions as $$
  select greatest(public.creche_semana(), coalesce((public.cfg()->>'nivelamento_at')::timestamptz, '-infinity'::timestamptz))
$$;

-- ---------- o nivelamento (uma vez só) ----------
create or replace function public.nivelamento_aplicar(_nivel int default 5, _por_nivel int default 10, _minimo int default 300) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r record; minc int; adm uuid; sp int; m monsters; moedas int; txt text; p creche_pedidos; l leiloes; n_jog int := 0; n_mon int; total int := 0;
begin
  if public.cfg() ? 'nivelamento_at' then return jsonb_build_object('ja_feito', true); end if;
  update game_config set config = jsonb_set(config, '{nivelamento_at}', to_jsonb(now())) where active;
  select user_id into adm from user_roles where role = 'admin' order by user_id limit 1;

  -- creches em andamento: devolve as moedas dos níveis que ainda não chegaram
  for p in select * from creche_pedidos where status = 'treinando' for update loop
    perform public.creche_devolve(p, 'nivelamento da temporada');
  end loop;
  -- leilões abertos: cancelados, lance devolvido
  for l in select * from leiloes where status = 'aberto' for update loop
    perform public.leilao_devolve(l);
    update leiloes set status = 'cancelado', closed_at = now() where id = l.id;
  end loop;
  -- batalhas em andamento: o XP acumulado com os níveis antigos não vale
  update battles set state = jsonb_set(state, '{xp}', '{}'::jsonb) where status = 'ativa' and state ? 'xp';

  -- a menor compensação de quem perdeu níveis
  select min(niv) into minc from (select sum(level - _nivel) niv from monsters where level > _nivel group by user_id) x;

  for r in select ch.user_id, ch.name, coalesce((select sum(mm.level - _nivel) from monsters mm where mm.user_id = ch.user_id and mm.level > _nivel), 0)::int niv
             from characters ch order by ch.name loop
    n_jog := n_jog + 1;
    if r.niv > 0 then
      moedas := r.niv * _por_nivel;
      txt := 'Nivelamento da Temporada 2: seus Pokémon acima do nível ' || _nivel || ' voltaram ao nível ' || _nivel || ' (' || r.niv || ' níveis no total). '
          || 'Compensação: ' || _por_nivel || ' moedas por nível = ' || moedas || ' moedas.';
    else
      moedas := greatest(coalesce(minc, 0) * _por_nivel, _minimo);
      txt := 'Nivelamento da Temporada 2: você não tinha níveis a perder, então ganhou um bônus de ' || moedas
          || ' moedas (a menor compensação dos outros jogadores, com mínimo de ' || _minimo || ').';
    end if;
    sp := public.inicial_sorteado();
    m := public.mon_dar(r.user_id, sp, (public.boas_vindas_cfg()->>'inicial_nivel')::int);
    if m.id is not null then txt := txt || ' E de presente: um ' || (select name from pokemon where id = sp) || ' nível ' || m.level || ' já está na sua coleção!'; end if;
    update characters set coins = coins + moedas, boas_vindas_at = now() where user_id = r.user_id;
    insert into gifts(user_id, coins, message, created_by) values (r.user_id, moedas, txt, adm);
    total := total + moedas;
  end loop;

  -- o reset: nível 5, XP do nível 5; ataques e evoluções ficam
  update monsters mo set level = _nivel, exp = public.pk_exp_for(pk.growth_rate, _nivel)
    from pokemon pk where pk.id = mo.species_id and mo.level > _nivel;
  get diagnostics n_mon = row_count;
  -- vida cheia para todos, de graça
  update monsters set tr_hp = 100, war_hp = 100, tr_hurt_at = null, war_hurt_at = null
   where tr_hp < 100 or war_hp < 100 or tr_hurt_at is not null or war_hurt_at is not null;
  for r in select distinct user_id from characters where mascot is not null loop perform public.pk_refresh_mascot(r.user_id); end loop;

  insert into event_log(user_id, kind, message) values (adm, 'nivelamento',
    'Nivelamento da Temporada 2: ' || n_mon || ' Pokémon voltaram ao nível ' || _nivel || '; ' || total || ' moedas de compensação para ' || n_jog || ' jogadores.');
  return jsonb_build_object('pokemon', n_mon, 'jogadores', n_jog, 'moedas', total, 'menor', coalesce(minc, 0) * _por_nivel);
end $$;

-- ---------- batalha valendo moedas com teto (versão do 30 + teto) ----------
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
  tt := case when b.bet > 0 and coalesce(b.mode, 'duelo') not in ('liga', 'guerra') then public.teto_nivel() end;
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

-- ---------- evolução por troca com o Cabo Link (versão do 28) ----------
create or replace function public.mon_evolve(_id uuid, _to int) returns public.monsters
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); m monsters; ev pk_evolutions; have int; mv int; tp pokemon;
begin
  select * into m from monsters where id = _id and user_id = uid for update;
  if m.id is null then raise exception 'Esse Pokémon não é seu.'; end if;
  select * into ev from pk_evolutions where from_id = m.species_id and to_id = _to;
  if ev.from_id is null then raise exception 'Essa evolução não existe.'; end if;
  if not public.evo_ok(ev.from_id, ev.to_id) then raise exception 'Essa evolução é da 2ª geração, que está desligada no momento. Seu Pokémon espera, sem perder nada.'; end if;
  -- arquivo 77: evolução por troca usa o Cabo Link (compra na Loja Pokémon; acaba ao usar)
  if ev.method = 'troca' then
    select qty into have from bag_items where user_id = uid and item = 'cabo_link' for update;
    if coalesce(have, 0) < 1 then raise exception 'Essa evolução é por troca: você precisa de um Cabo Link (Loja Pokémon).'; end if;
    update bag_items set qty = qty - 1 where user_id = uid and item = 'cabo_link';
  end if;
  if ev.method = 'nivel' and m.level < ev.level then raise exception 'Precisa chegar ao nível %.', ev.level; end if;
  if ev.method = 'pedra' then
    select qty into have from bag_items where user_id = uid and item = ev.item for update;
    if coalesce(have, 0) < 1 then raise exception 'Você precisa de uma pedra para essa evolução.'; end if;
    update bag_items set qty = qty - 1 where user_id = uid and item = ev.item;
  end if;
  select * into tp from pokemon where id = _to;
  m.species_id := _to;
  -- ataques que a nova espécie aprende exatamente no nível atual
  for mv in select move_id from pk_learnset where species_id = _to and level = m.level loop
    if mv = any(m.moves) then continue; end if;
    if cardinality(m.moves) < 4 then m.moves := m.moves || mv; else m.pending_moves := m.pending_moves || mv; end if;
  end loop;
  update monsters set species_id = m.species_id, moves = m.moves, pending_moves = m.pending_moves where id = m.id returning * into m;
  perform public.pk_dex_mark(uid, _to, true);
  perform public.pk_refresh_mascot(uid);
  insert into event_log(user_id, kind, message) select uid, 'evolucao', ch.name || ': ' || (select name from pokemon where id = ev.from_id) || ' evoluiu para ' || tp.name || '!' from characters ch where ch.user_id = uid;
  return m;
end $$;

-- ---------- Creche nova: ×5 até o 30, ×10 acima; 10 níveis por semana até o 30 e 5 acima ----------
create or replace function public.creche_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "preco_por_nivel": 5, "preco_por_nivel_alto": 10, "nivel_alto": 30, "niveis_semana": 10, "niveis_semana_alto": 5, "nivel_max": 40, "horas_por_nivel": 12}'::jsonb || coalesce(public.cfg()->'creche', '{}'::jsonb)
$$;

create or replace function public.creche_treinar(_mon uuid, _niveis int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.creche_cfg(); me characters; m monsters; usados int; alvo int; custo int := 0; custos jsonb := '[]'::jsonb;
  l int; v int; p creche_pedidos; A int := (c->>'nivel_alto')::int; usados_alto int; pede_baixo int; pede_alto int;
begin
  if not coalesce((c->>'on')::boolean, true) then raise exception 'A Creche está fechada no momento.'; end if;
  select * into me from characters where user_id = uid for update;
  perform public.creche_tick(uid);
  if exists (select 1 from creche_pedidos where user_id = uid and status = 'treinando') then
    raise exception 'A Creche já está treinando um Pokémon seu. Espere terminar (ou cancele) para começar outro.';
  end if;
  select * into m from monsters where id = _mon and user_id = uid;
  if m.id is null then raise exception 'Escolha um Pokémon seu.'; end if;
  if _niveis is null or _niveis < 1 then raise exception 'Escolha quantos níveis.'; end if;
  -- arquivo 77: dois limites por semana, um até o nível alto (30) e outro acima dele
  select coalesce(sum(greatest(0, least(level_to, A) - least(level_from, A))), 0), coalesce(sum(greatest(0, level_to - greatest(level_from, A))), 0)
    into usados, usados_alto from creche_log where user_id = uid and created_at >= public.creche_inicio_semana();
  alvo := m.level + _niveis;
  pede_baixo := greatest(0, least(alvo, A) - least(m.level, A)); pede_alto := greatest(0, alvo - greatest(m.level, A));
  if usados + pede_baixo > (c->>'niveis_semana')::int then
    raise exception 'Até o nível %, a Creche treina no máximo % níveis por semana. Você ainda pode usar %.', A, c->>'niveis_semana', greatest(0, (c->>'niveis_semana')::int - usados);
  end if;
  if usados_alto + pede_alto > (c->>'niveis_semana_alto')::int then
    raise exception 'Acima do nível %, a Creche treina no máximo % níveis por semana. Você ainda pode usar %.', A, c->>'niveis_semana_alto', greatest(0, (c->>'niveis_semana_alto')::int - usados_alto);
  end if;
  if alvo > (c->>'nivel_max')::int then raise exception 'A Creche só treina até o nível %.', c->>'nivel_max'; end if;
  for l in m.level + 1 .. alvo loop
    v := ceil(l * (case when l > A then (c->>'preco_por_nivel_alto')::int else (c->>'preco_por_nivel')::int end) * (100 - public.creche_desc(uid)) / 100.0)::int;   -- Domador: desconto
    custo := custo + v; custos := custos || to_jsonb(v);
  end loop;
  if me.coins < custo then raise exception 'Custa % moedas e você tem %.', custo, me.coins; end if;
  update characters set coins = coins - custo where id = me.id;
  insert into creche_pedidos(user_id, mon_id, species, level_from, niveis, custos, horas)
  values (uid, m.id, m.species_id, m.level, _niveis, custos, (c->>'horas_por_nivel')::int) returning * into p;
  insert into creche_log(user_id, mon_id, species, level_from, level_to, niveis, custo) values (uid, m.id, m.species_id, m.level, alvo, _niveis, custo);
  return jsonb_build_object('custo', custo, 'coins', me.coins - custo, 'level', m.level, 'alvo', alvo,
    'proximo_em', p.created_at + make_interval(hours => p.horas), 'termina_em', p.created_at + make_interval(hours => p.horas * _niveis));
end $$;

create or replace function public.creche_estado() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.creche_cfg(); usados int; usados_alto int; p creche_pedidos; A int := (c->>'nivel_alto')::int;
begin
  if uid is null then raise exception 'Entre na sua conta.'; end if;
  perform public.creche_tick(uid);
  select coalesce(sum(greatest(0, least(level_to, A) - least(level_from, A))), 0), coalesce(sum(greatest(0, level_to - greatest(level_from, A))), 0)
    into usados, usados_alto from creche_log where user_id = uid and created_at >= public.creche_inicio_semana();
  select * into p from creche_pedidos where user_id = uid and status = 'treinando';
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'preco_por_nivel', (c->>'preco_por_nivel')::int,
    'niveis_semana', (c->>'niveis_semana')::int, 'nivel_max', (c->>'nivel_max')::int, 'horas_por_nivel', (c->>'horas_por_nivel')::int,
    'usados', usados, 'desconto_pct', public.creche_desc(uid), 'agora', now(),
    'restante', greatest(0, (c->>'niveis_semana')::int - usados),
    'preco_por_nivel_alto', (c->>'preco_por_nivel_alto')::int, 'nivel_alto', A, 'niveis_semana_alto', (c->>'niveis_semana_alto')::int,
    'usados_alto', usados_alto, 'restante_alto', greatest(0, (c->>'niveis_semana_alto')::int - usados_alto),
    'renova', public.creche_semana() + interval '7 days',
    'treino', case when p.id is null then null else jsonb_build_object('mon_id', p.mon_id, 'species', p.species, 'level_from', p.level_from, 'niveis', p.niveis,
        'entregues', p.entregues, 'proximo_em', p.created_at + make_interval(hours => p.horas * (p.entregues + 1)),
        'termina_em', p.created_at + make_interval(hours => p.horas * p.niveis),
        'devolve', (select coalesce(sum(x::int), 0) from jsonb_array_elements_text(p.custos) with ordinality t(x, o) where o > p.entregues)) end,
    'historico', coalesce((select jsonb_agg(jsonb_build_object('species', l.species, 'level_from', l.level_from, 'level_to', l.level_to, 'custo', l.custo, 'created_at', l.created_at) order by l.id desc)
      from (select * from creche_log where user_id = uid order by id desc limit 10) l), '[]'::jsonb));
end $$;

-- ---------- pk_sync (versão do 69 + boas-vindas) ----------
create or replace function public.pk_sync() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.pk_cfg(); dm record; pool int; hcls text := public.heroi(uid); k int; team uuid[]; each_xp int; mid uuid;
  sp int; lv int; maxd int; nd board_nodes; enc encounters; hh hunts; old encounters; start_at timestamptz := coalesce((public.cfg()->>'pk_start_at')::timestamptz, now());
begin
  perform public.creche_tick(uid);   -- níveis da Creche que já chegaram (arquivo 69)
  perform public.boas_vindas_dar(uid);   -- arquivo 77: inicial e pacote de boas-vindas (uma vez só)
  select max(dist) into maxd from board_nodes;
  for dm in select d.* from daily_moves d where d.user_id = uid and d.created_at >= start_at
             and not exists (select 1 from pk_move_sync s where s.move_id = d.id) order by d.created_at loop
    -- XP dos Pokémon da equipe: dividido igualmente
    pool := (c->'xp'->>'move_base')::int + (c->'xp'->>'per_step')::int * coalesce(dm.base_steps, 0)
          + (c->'xp'->>'per_mode')::int * (select count(*) from jsonb_each(case when jsonb_typeof(dm.modes->'modes') = 'object' then dm.modes->'modes' else dm.modes end) e
                                           where jsonb_typeof(e.value) = 'object' and coalesce((e.value->>'solved')::boolean, false));
    if hcls = 'pesquisador' then pool := ceil(pool * (100 + (public.herois_cfg()->>'pesq_xp_pct')::numeric) / 100)::int; end if;   -- Pesquisador: +XP da equipe
    select array_agg(id order by team_slot) into team from monsters where user_id = uid and team_slot is not null;
    insert into pk_move_sync(move_id, user_id, xp_pool) values (dm.id, uid, case when team is null then 0 else pool end);
    if team is not null then
      each_xp := greatest(1, pool / cardinality(team));
      foreach mid in array team loop perform public.pk_give_xp(mid, each_xp, 'tabuleiro'); end loop;
    end if;
    -- encontro na casa onde parou (o anterior que ficou aberto foge)
    for old in select * from encounters where user_id = uid and status = 'aberto' loop
      update encounters set status = 'fugiu', resolved_at = now() where id = old.id;
      if old.hunt_id is not null then perform public.hunt_finish(old.hunt_id, false); end if;   -- não tentou: o Pokémon da Caçada foge
    end loop;
    select * into nd from board_nodes where id = dm.to_node;
    hh := null;
    if nd.kind = 'alvo' then select * into hh from hunts where target_node = nd.id and status = 'tentando' and hunter = uid; end if;
    if hh.id is not null then
      sp := hh.species; lv := hh.level;   -- Caçada: o Pokémon escolhido pelo admin
    else
    sp := public.pk_pick_species(nd.region);
    -- Pesquisador com a habilidade do dia (Isca de frutas): Pokémon incomum ou mais raro
    if hcls = 'pesquisador' and coalesce(dm.skill_steps, 0) > 0 then
      for k in 1 .. 20 loop
        exit when (select catch_rate from pokemon where id = sp) < (c->'rarity'->>'comum')::int;
        sp := public.pk_pick_species(nd.region);
      end loop;
    end if;
    lv := least(100, greatest(1, (c->'encounter'->>'level_min')::int
                + floor((1 - coalesce(nd.dist, maxd)::numeric / greatest(maxd, 1)) * (c->'encounter'->>'level_span')::int)::int
                + floor(random() * ((c->'encounter'->>'level_spread')::int + 1))::int));
    end if;
    insert into encounters(user_id, move_id, node, species_id, level, throws_left, hunt_id)
    values (uid, dm.id, dm.to_node, sp, lv, (c->'capture'->>'throws')::int + case when hcls = 'pesquisador' then (public.herois_cfg()->>'pesq_bolas')::int else 0 end, hh.id) on conflict (move_id) do nothing;
    perform public.pk_dex_mark(uid, sp, false);
  end loop;
  select * into enc from encounters where user_id = uid and status = 'aberto' order by created_at desc limit 1;
  return jsonb_build_object('encounter', case when enc.id is null then null else to_jsonb(enc) end,
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.id) from mon_events e where e.user_id = uid and not e.seen), '[]'::jsonb));
end $$;

-- ---------- Ajustes do jogo (versão do 76 + teto e boas-vindas) ----------
create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'leilao', public.leilao_cfg(), 'herois', public.herois_cfg(), 'temporada', public.temporada_cfg(), 'liga', public.liga_cfg(), 'pausa', public.pausa_cfg(), 'teto', public.teto_cfg(), 'boas_vindas', public.boas_vindas_cfg(), 'base', public.cfg());
end $$;

-- ---------- permissões ----------
grant execute on function public.teto_estado() to authenticated;
revoke execute on function public.teto_cfg(), public.boas_vindas_cfg(), public.teto_calc(), public.teto_nivel(), public.bt_mon_teto(uuid, int),
  public.mon_dar(uuid, int, int), public.inicial_sorteado(), public.boas_vindas_dar(uuid), public.creche_inicio_semana(),
  public.nivelamento_aplicar(int, int, int) from public, anon, authenticated;

-- ---------- números de agora ----------
-- o teto começa nesta temporada (a de referência é a ativa agora)
update public.game_config
   set config = jsonb_set(config, '{teto}', coalesce(config->'teto', '{}'::jsonb)
         || jsonb_build_object('temporada_ref', (select max(id) from public.seasons where status = 'ativa')))
 where active and coalesce(config->'teto'->>'temporada_ref', '') = '';
-- Creche nova (pedido do dono): troca os números mesmo que o admin já tenha mexido neles
update public.game_config
   set config = jsonb_set(config, '{creche}', coalesce(config->'creche', '{}'::jsonb)
         || '{"preco_por_nivel": 5, "preco_por_nivel_alto": 10, "nivel_alto": 30, "niveis_semana": 10, "niveis_semana_alto": 5}'::jsonb)
 where active;

-- ---------- no banco de verdade: nivelamento agora e o jogo volta (despausa) ----------
do $$
begin
  if to_regclass('public.sql_aplicados') is not null then
    perform public.nivelamento_aplicar();
    update public.game_config set config = jsonb_set(config, '{pausa,on}', 'false'::jsonb) where active and config ? 'pausa';
  end if;
end $$;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('⚖️ Nivelamento da Temporada 2', 'A Temporada 2 começa com todo mundo mais perto:
• 🔄 Todos os Pokémon acima do nível 5 voltaram ao nível 5 (ataques e evoluções ficam) e todos estão com a vida cheia.
• 💰 Compensação no Correio: 10 moedas por nível perdido. Quem não perdeu nada ganhou um bônus de, no mínimo, 300 moedas.
• 🎁 Todo mundo ganhou um inicial nível 5: Bulbasaur, Charmander, Squirtle, Pikachu ou Eevee. Jogador novo ganha também 3 Pokémon de boas-vindas.
• ⚔️ Nas batalhas valendo moedas, ninguém luta acima do nível 20 nesta temporada (+5 por temporada, até 40). A Liga não tem limite.
• 🏡 Creche mais barata: nível × 5 até o 30 (nível × 10 acima), 10 níveis por semana até o 30 e 5 acima.
• 🔌 Cabo Link na Loja Pokémon: Kadabra, Machoke, Graveler e Haunter finalmente evoluem!')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
