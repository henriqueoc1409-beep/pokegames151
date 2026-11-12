-- 100_aventura_suporte.sql
-- Pedido do dono em 12/11/2026: (1) o que a vila dava na Grama de Treino passa para a Aventura: a Arena
-- (vila_bonus.arena.rpg_lutas, [5]) dá lutas a mais por dia na Aventura no lugar dos minutos na Grama; a Academia
-- (grama_xp_pct) e o Domador já valiam porque a Aventura usa o treino_after (só mudam os textos do site).
-- (2) Pokémon de suporte (o acompanhante da Grama, arquivo 63): ganha acompanhante_pct (50; Pesquisador 75) da
-- experiência de cada vitória. O rpg_encontro já aceitava _comp; agora o Ginásio e o Chefe também
-- (rpg_ginasio_lutar(_regiao, _comp) e rpg_chefe_lutar(_comp); as versões antigas foram apagadas).
-- Novas vila_bonus_cfg (versão do 82), rpg_encontro e rpg_estado (versões do 99).

create or replace function public.vila_bonus_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true,
    "centro": {"casas": [0, 0, 1, 1, 1, 2]},
    "pomar": {"captura_pct": [10]},
    "taverna": {"bolas": [1]},
    "vigia": {"raro_pct": [15, 25, 35]},
    "academia": {"grama_xp_pct": [10, 20, 30]},
    "arena": {"grama_min": [10], "rpg_lutas": [5]},
    "centropk": {"centro_desc_pct": [10, 20, 30, 40], "cura_rapida_pct": [10, 20, 30, 40]},
    "poco": {"creche_desc_pct": [10]},
    "defesa": {"rocket_dano_pct": [10, 20, 30]},
    "muralha": {"lama_desc_pct": [30, 60, 100]},
    "mina": {"salario_pct": [5, 10, 15]},
    "cofre": {"taxa_menos": [1, 2, 3, 4]}}'::jsonb || coalesce(public.cfg()->'vila_bonus', '{}'::jsonb)
$$;
update public.game_config set config = jsonb_set(config, '{vila_bonus,arena,rpg_lutas}', '[5]')
 where active and config ? 'vila_bonus' and config->'vila_bonus' ? 'arena' and not (config->'vila_bonus'->'arena' ? 'rpg_lutas');

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
  if d.batalhas >= (c->>'batalhas_dia')::int + public.vb(uid, 'arena', 'rpg_lutas')::int then   -- arquivo 100: Arena da vila dá lutas a mais
    raise exception 'Você já fez as % lutas de hoje na Aventura. Amanhã tem mais.', (c->>'batalhas_dia')::int + public.vb(uid, 'arena', 'rpg_lutas')::int;
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
  return jsonb_build_object('battle', bid, 'batalhas', d.batalhas + 1, 'batalhas_dia', (c->>'batalhas_dia')::int + public.vb(uid, 'arena', 'rpg_lutas')::int);
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
    'noite', public.rpg_noite(),
    'insignias', coalesce((select jsonb_agg(regiao order by ganho_em) from rpg_insignias where user_id = uid), '[]'::jsonb),
    'missoes', coalesce((select jsonb_agg(jsonb_build_object('n', n, 'regiao', regiao, 'tipo', tipo, 'alvo', alvo, 'meta', meta, 'prog', prog, 'premio', premio, 'resgatada', resgatada) order by n)
                         from rpg_missoes where user_id = uid and dia = public.game_today()), '[]'::jsonb),
    'chefe', public.rpg_chefe_info(uid));
end $$;

drop function if exists public.rpg_ginasio_lutar(text);
drop function if exists public.rpg_chefe_lutar();
create or replace function public.rpg_ginasio_lutar(_regiao text, _comp uuid default null) returns jsonb
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
  if _comp is not null and (_comp = m.id or not exists (select 1 from monsters where id = _comp and user_id = uid)
     or coalesce((select tr_hp from monsters where id = _comp), 100) <= 0) then _comp := null; end if;
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
          jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb, 'treino', jsonb_build_object('mon', m.id, 'forte', false, 'comp', _comp, 'gym', _regiao, 'gym_try', t.id, 'gym_idx', t.idx)),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', (l->>'nome') || ' manda ' || (wild->>'name') || ' (nível ' || lv || ')' || case when whp < (wild->>'maxhp')::int then ', ainda ferido,' else '' end || ' para a luta! (' || (t.idx + 1) || 'º de ' || jsonb_array_length(l->'time') || ')'),
            jsonb_build_object('txt', 'Vai, ' || (mine->>'name') || '!' || case when m.tr_hp < 100 then ' (com ' || m.tr_hp || '% da vida)' else '' end)))))
  returning id into bid;
  return jsonb_build_object('battle', bid);
end $$;

create or replace function public.rpg_chefe_lutar(_comp uuid default null) returns jsonb
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
  if _comp is not null and (_comp = m.id or not exists (select 1 from monsters where id = _comp and user_id = uid)
     or coalesce((select tr_hp from monsters where id = _comp), 100) <= 0) then _comp := null; end if;
  delete from battles where mode = 'treino' and p1 = uid and status <> 'ativa';
  wild := public.npc_mon(ch.especie, ch.nivel);
  mine := public.bt_mon(m.id);
  hp0 := greatest(1, round((mine->>'maxhp')::int * m.tr_hp / 100.0))::int;
  mine := jsonb_set(mine, '{hp}', to_jsonb(hp0));
  s0 := jsonb_build_object('user', uid, 'name', me.name, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(mine));
  s1 := jsonb_build_object('user', uid, 'name', 'Chefe da rota', 'npc', true, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(wild));
  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (uid, uid, 'treino', 1, 'ativa', 1, 'normal', now(),
          jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb, 'treino', jsonb_build_object('mon', m.id, 'forte', true, 'comp', _comp, 'chefe', ch.id)),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', '👹 O ' || (wild->>'name') || ' gigante (nível ' || ch.nivel || ') ruge! Você tem ' || (c->>'turnos') || ' turnos para causar o máximo de dano.'),
            jsonb_build_object('txt', 'Vai, ' || (mine->>'name') || '!' || case when m.tr_hp < 100 then ' (com ' || m.tr_hp || '% da vida)' else '' end)))))
  returning id into bid;
  update rpg_chefe_dano set lutas = lutas + 1, lutas_dia = lutas_dia + 1 where chefe_id = ch.id and user_id = uid;
  return jsonb_build_object('battle', bid);
end $$;

grant execute on function public.rpg_estado(), public.rpg_encontro(uuid, text, uuid), public.rpg_ginasio_lutar(text, uuid), public.rpg_chefe_lutar(uuid) to authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🎒 Aventura: Pokémon de suporte e a vila ajudando no treino', 'Mais ajuda para evoluir na Aventura:
• 🎒 Pokémon de suporte: escolha um Pokémon seu para ir na bolsa (botão 🎒 Suporte, no alto da Aventura). A cada vitória ele ganha metade da experiência de quem lutou (o Pesquisador dá 75%). Vale contra selvagens, nos Ginásios e no Chefe. Ótimo para quem não tem ataque de dano, como o Magikarp.
• 🏟️ A Arena da vila agora dá lutas a mais por dia na Aventura (no lugar dos minutos na Grama).
• 🎓 A Academia da vila e o herói Domador continuam dando experiência a mais, agora nas lutas da Aventura.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
