-- 97_aventura_rotas.sql
-- Pedido do dono em 12/11/2026: acabar com a Grama de Treino e usar só a Aventura para evoluir os Pokémon.
--   (1) Todos os Pokémon aparecem na Aventura (menos lendários, lista em rpg.lendarios), cada um nas áreas do seu tipo.
--       Cada área (rpg.zonas) tem nome, região, tipos e faixa de nível FIXA (antes o nível seguia o do seu Pokémon).
--       Evoluído só aparece a partir do nível em que a forma anterior evolui (rpg_nivel_min: por nível = o nível
--       da evolução; por pedra = nivel_pedra 28; por troca = nivel_troca 36), e a forma anterior para de aparecer
--       "folga" (10) níveis depois de poder evoluir (rpg_nivel_max). Os mais raros (taxa de captura menor) saem menos.
--       A experiência continua a mesma conta da Grama (exp-base × nível ÷ 7): selvagem mais forte dá mais.
--   (2) Seis regiões novas no site (Bosque, Praia, Deserto, Pedreira, Charco, Pico), cada uma com duas áreas: o mato
--       de perto e o fundo, mais forte.
--   (3) Fugir de luta da Aventura custa moedas: fuga_base (10) + fuga_por_ataque (10) × ataques já feitos na luta.
--       Sem moedas, não foge. Nova battle_act (versão do 56) conta os ataques em state.treino.ataques.
--   (4) A Grama de Treino fecha (treino.on = false). O Centro Pokémon e a vida do treino continuam.
-- Nova rpg_cfg (o config antigo da Aventura troca as zonas pelo formato novo e perde nivel_menos/nivel_mais) e nova
-- rpg_encontro (mesma assinatura). Tudo ajustável em Ajustes do jogo → Aventura.

create or replace function public.rpg_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "batalhas_dia": 20, "chance_pct": 12, "espera_seg": 8, "envio_seg": 1.2, "fuga_base": 10, "fuga_por_ataque": 10, "nivel_pedra": 28, "nivel_troca": 36, "folga": 10, "lendarios": [144, 145, 146, 150, 151, 243, 244, 245, 249, 250, 251], "zonas": {"mato": {"nome": "Capim alto", "regiao": "vila", "tipos": ["INSETO", "PLANTA", "NORMAL"], "min": 2, "max": 6}, "escura": {"nome": "Grama escura", "regiao": "vila", "tipos": ["NORMAL", "VOADOR", "ELETRICO"], "min": 3, "max": 7}, "pantano": {"nome": "Pântano", "regiao": "vila", "tipos": ["AGUA", "VENENO"], "min": 3, "max": 7}, "pedra": {"nome": "Alto do penhasco", "regiao": "vila", "tipos": ["PEDRA", "TERRA", "LUTA"], "min": 4, "max": 8}, "bosque": {"nome": "Bosque: mato", "regiao": "bosque", "tipos": ["INSETO", "PLANTA", "VENENO", "NORMAL"], "min": 8, "max": 16}, "bosque_fundo": {"nome": "Bosque: mata funda", "regiao": "bosque", "tipos": ["INSETO", "PLANTA", "VENENO", "NORMAL", "VOADOR"], "min": 18, "max": 34}, "praia": {"nome": "Praia: dunas", "regiao": "praia", "tipos": ["AGUA", "ELETRICO", "NORMAL"], "min": 8, "max": 16}, "praia_fundo": {"nome": "Praia: costão", "regiao": "praia", "tipos": ["AGUA", "ELETRICO", "GELO", "VOADOR"], "min": 18, "max": 38}, "deserto": {"nome": "Deserto: capim seco", "regiao": "deserto", "tipos": ["FOGO", "TERRA", "NORMAL"], "min": 12, "max": 22}, "deserto_fundo": {"nome": "Deserto: oásis distante", "regiao": "deserto", "tipos": ["FOGO", "TERRA", "PEDRA", "LUTA"], "min": 24, "max": 42}, "pedreira": {"nome": "Pedreira: entrada", "regiao": "pedreira", "tipos": ["PEDRA", "TERRA", "LUTA", "METALICO"], "min": 12, "max": 22}, "pedreira_fundo": {"nome": "Pedreira: fundo da gruta", "regiao": "pedreira", "tipos": ["PEDRA", "TERRA", "LUTA", "METALICO", "DRAGAO"], "min": 24, "max": 44}, "charco": {"nome": "Charco: margem", "regiao": "charco", "tipos": ["VENENO", "FANTASMA", "PSIQUICO", "SOMBRIO"], "min": 20, "max": 32}, "charco_fundo": {"nome": "Charco: brejo escuro", "regiao": "charco", "tipos": ["FANTASMA", "PSIQUICO", "SOMBRIO", "VENENO", "NORMAL"], "min": 32, "max": 46}, "pico": {"nome": "Pico: encosta", "regiao": "pico", "tipos": ["GELO", "AGUA", "PSIQUICO", "VOADOR", "ELETRICO"], "min": 34, "max": 48}, "pico_fundo": {"nome": "Pico: cume", "regiao": "pico", "tipos": ["DRAGAO", "GELO", "VOADOR", "PSIQUICO", "FOGO", "LUTA", "NORMAL", "PEDRA"], "min": 45, "max": 60}}}'::jsonb
    || coalesce(public.cfg()->'rpg', '{}'::jsonb)
$$;
update public.game_config
   set config = jsonb_set(config, '{rpg}', (public.rpg_cfg() - 'zonas' - 'nivel_menos' - 'nivel_mais') || jsonb_build_object('zonas', '{"mato": {"nome": "Capim alto", "regiao": "vila", "tipos": ["INSETO", "PLANTA", "NORMAL"], "min": 2, "max": 6}, "escura": {"nome": "Grama escura", "regiao": "vila", "tipos": ["NORMAL", "VOADOR", "ELETRICO"], "min": 3, "max": 7}, "pantano": {"nome": "Pântano", "regiao": "vila", "tipos": ["AGUA", "VENENO"], "min": 3, "max": 7}, "pedra": {"nome": "Alto do penhasco", "regiao": "vila", "tipos": ["PEDRA", "TERRA", "LUTA"], "min": 4, "max": 8}, "bosque": {"nome": "Bosque: mato", "regiao": "bosque", "tipos": ["INSETO", "PLANTA", "VENENO", "NORMAL"], "min": 8, "max": 16}, "bosque_fundo": {"nome": "Bosque: mata funda", "regiao": "bosque", "tipos": ["INSETO", "PLANTA", "VENENO", "NORMAL", "VOADOR"], "min": 18, "max": 34}, "praia": {"nome": "Praia: dunas", "regiao": "praia", "tipos": ["AGUA", "ELETRICO", "NORMAL"], "min": 8, "max": 16}, "praia_fundo": {"nome": "Praia: costão", "regiao": "praia", "tipos": ["AGUA", "ELETRICO", "GELO", "VOADOR"], "min": 18, "max": 38}, "deserto": {"nome": "Deserto: capim seco", "regiao": "deserto", "tipos": ["FOGO", "TERRA", "NORMAL"], "min": 12, "max": 22}, "deserto_fundo": {"nome": "Deserto: oásis distante", "regiao": "deserto", "tipos": ["FOGO", "TERRA", "PEDRA", "LUTA"], "min": 24, "max": 42}, "pedreira": {"nome": "Pedreira: entrada", "regiao": "pedreira", "tipos": ["PEDRA", "TERRA", "LUTA", "METALICO"], "min": 12, "max": 22}, "pedreira_fundo": {"nome": "Pedreira: fundo da gruta", "regiao": "pedreira", "tipos": ["PEDRA", "TERRA", "LUTA", "METALICO", "DRAGAO"], "min": 24, "max": 44}, "charco": {"nome": "Charco: margem", "regiao": "charco", "tipos": ["VENENO", "FANTASMA", "PSIQUICO", "SOMBRIO"], "min": 20, "max": 32}, "charco_fundo": {"nome": "Charco: brejo escuro", "regiao": "charco", "tipos": ["FANTASMA", "PSIQUICO", "SOMBRIO", "VENENO", "NORMAL"], "min": 32, "max": 46}, "pico": {"nome": "Pico: encosta", "regiao": "pico", "tipos": ["GELO", "AGUA", "PSIQUICO", "VOADOR", "ELETRICO"], "min": 34, "max": 48}, "pico_fundo": {"nome": "Pico: cume", "regiao": "pico", "tipos": ["DRAGAO", "GELO", "VOADOR", "PSIQUICO", "FOGO", "LUTA", "NORMAL", "PEDRA"], "min": 45, "max": 60}}'::jsonb))
 where active and config->'rpg'->'zonas'->'bosque' is null;
update public.game_config set config = jsonb_set(config, '{treino,on}', 'false') where active and config ? 'treino';
update public.game_config set config = jsonb_set(config, '{treino}', '{"on": false}') where active and not config ? 'treino';
revoke execute on function public.rpg_cfg() from public, anon, authenticated;

-- menor nível em que a espécie aparece na Aventura (o da evolução que leva até ela)
create or replace function public.rpg_nivel_min(_sp int) returns int
language plpgsql stable security definer set search_path = public, extensions as $$
declare e pk_evolutions; c jsonb := public.rpg_cfg();
begin
  select * into e from pk_evolutions where to_id = _sp and public.gen_ok(from_id) order by from_id limit 1;
  if e.from_id is null or e.from_id = _sp then return 1; end if;
  return greatest(public.rpg_nivel_min(e.from_id), case e.method when 'nivel' then coalesce(e.level, 1)
    when 'pedra' then (c->>'nivel_pedra')::int else (c->>'nivel_troca')::int end);
end $$;
-- a partir de que nível ela deixa de aparecer (pouco depois de poder evoluir)
create or replace function public.rpg_nivel_max(_sp int) returns int
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((select min(public.rpg_nivel_min(e.to_id)) from pk_evolutions e where e.from_id = _sp and e.to_id <> _sp and public.gen_ok(e.to_id))
                  + (public.rpg_cfg()->>'folga')::int, 1000)
$$;
revoke execute on function public.rpg_nivel_min(int), public.rpg_nivel_max(int) from public, anon, authenticated;

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
            jsonb_build_object('txt', 'Um ' || (wild->>'name') || ' selvagem (nível ' || lvl || ') apareceu em ' || coalesce(z->>'nome', 'mato') || '!'),
            jsonb_build_object('txt', 'Vai, ' || (mine->>'name') || '!' || case when m.tr_hp < 100 then ' (com ' || m.tr_hp || '% da vida)' else '' end)))))
  returning id into bid;
  update rpg_dias set batalhas = batalhas + 1, ult = now() where user_id = uid and dia = public.game_today();
  return jsonb_build_object('battle', bid, 'batalhas', d.batalhas + 1, 'batalhas_dia', (c->>'batalhas_dia')::int);
end $$;
grant execute on function public.rpg_encontro(uuid, text, uuid) to authenticated;

create or replace function public.battle_act(_id uuid, _turn int, _kind text, _value int, _item text default null) returns public.battles
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); b battles; side int; s jsonb; A jsonb; kind text := _kind; ok boolean; pre int; p jsonb; k int; item text;
  rc jsonb; custo int := 0; moedas int;
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
    if b.mode = 'treino' then perform public.treino_after(b.id); end if;
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
    if b.status = 'ativa' and b.turn > (public.treino_cfg()->>'turnos')::int then
      update battles set log = log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt', 'A luta demorou demais e o selvagem fugiu para a grama.'))))
       where id = b.id;
      perform public.bt_finish(b.id, null, 'limite');
    end if;
    select * into b from battles where id = _id;
    if b.status <> 'ativa' then perform public.treino_after(_id); select * into b from battles where id = _id; end if;
    return b;
  end if;
  if side = 0 then update battles set ready1 = true where id = b.id returning * into b;
  else update battles set ready2 = true where id = b.id returning * into b; end if;
  if b.ready1 and b.ready2 then perform public.bt_resolve(b.id); end if;
  select * into b from battles where id = _id;
  return b;
end $$;
grant execute on function public.battle_act(uuid, int, text, int, text) to authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🧭 Aventura maior: 6 rotas novas e todos os Pokémon', 'A Aventura cresceu e agora é o lugar de treinar e evoluir os Pokémon:
• Seis rotas novas saindo da Vila Aurora: Bosque Sussurrante (oeste), Praia Coral (sul), Deserto Rubro (leste), Gruta da Pedreira (pela caverna do penhasco), e mais adiante o Charco Sombrio (depois do Bosque) e o Pico Gelado (depois da Pedreira).
• Todos os Pokémon aparecem por lá (menos os lendários), cada um no terreno do seu tipo. Os evoluídos só aparecem nas áreas de nível mais alto.
• Cada área tem a sua faixa de nível, que aparece na tela: perto da vila são fracos; no fundo das rotas e nas rotas mais distantes, bem mais fortes. Quanto mais forte o selvagem, mais experiência ele dá.
• Fugir de uma luta agora custa moedas: 10 para fugir logo, e mais 10 a cada ataque que você já fez naquela luta. Pense antes de entrar no mato fundo!
• A Grama de Treino fechou: o treino agora é todo na Aventura. O Centro Pokémon continua curando a vida dos seus Pokémon.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
