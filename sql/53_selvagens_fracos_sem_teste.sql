-- =====================================================================
-- POKEGAMES — Pokémon selvagens fracos e saída do jogador "teste"
-- (pedido do dono em 29/10/2026).
--
-- 1) Os Pokémon selvagens que aparecem depois de andar ficam SEMPRE entre
--    os níveis 1 e 5, em qualquer parte do tabuleiro, para valer a pena
--    treinar. A chance de captura não muda (a fórmula da 1ª geração com
--    vida cheia não depende do nível). Os números ficam na configuração
--    (pk.encounter: level_min 1, level_span 0, level_spread 4) e o admin
--    pode mudar depois. A Caçada continua com o nível que o admin escolher.
-- 2) Apaga em definitivo a conta do jogador "teste" (login, herói,
--    Pokémon, vila, jogadas, mensagens: tudo o que é dele sai junto).
--    Se houver mais de uma conta com esse nome, ou se for admin, o arquivo
--    para sem mudar nada.
-- Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

-- 1) nível dos encontros: 1 + sorteio de 0 a 4 = 1 a 5
update public.game_config
   set config = jsonb_set(config, '{pk}', coalesce(config->'pk', '{}'::jsonb)
         || jsonb_build_object('encounter', (public.pk_cfg()->'encounter')
              || '{"level_min": 1, "level_span": 0, "level_spread": 4}'::jsonb))
 where active;

-- encontro depois de andar (versão do 46; o nível mínimo agora é 1, antes era 2)
create or replace function public.pk_sync() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.pk_cfg(); dm record; pool int; team uuid[]; each_xp int; mid uuid;
  sp int; lv int; maxd int; nd board_nodes; enc encounters; hh hunts; old encounters; start_at timestamptz := coalesce((public.cfg()->>'pk_start_at')::timestamptz, now());
begin
  select max(dist) into maxd from board_nodes;
  for dm in select d.* from daily_moves d where d.user_id = uid and d.created_at >= start_at
             and not exists (select 1 from pk_move_sync s where s.move_id = d.id) order by d.created_at loop
    -- XP dos Pokémon da equipe: dividido igualmente
    pool := (c->'xp'->>'move_base')::int + (c->'xp'->>'per_step')::int * coalesce(dm.base_steps, 0)
          + (c->'xp'->>'per_mode')::int * (select count(*) from jsonb_each(case when jsonb_typeof(dm.modes->'modes') = 'object' then dm.modes->'modes' else dm.modes end) e
                                           where jsonb_typeof(e.value) = 'object' and coalesce((e.value->>'solved')::boolean, false));
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
    lv := least(100, greatest(1, (c->'encounter'->>'level_min')::int
                + floor((1 - coalesce(nd.dist, maxd)::numeric / greatest(maxd, 1)) * (c->'encounter'->>'level_span')::int)::int
                + floor(random() * ((c->'encounter'->>'level_spread')::int + 1))::int));
    end if;
    insert into encounters(user_id, move_id, node, species_id, level, throws_left, hunt_id)
    values (uid, dm.id, dm.to_node, sp, lv, (c->'capture'->>'throws')::int, hh.id) on conflict (move_id) do nothing;
    perform public.pk_dex_mark(uid, sp, false);
  end loop;
  select * into enc from encounters where user_id = uid and status = 'aberto' order by created_at desc limit 1;
  return jsonb_build_object('encounter', case when enc.id is null then null else to_jsonb(enc) end,
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.id) from mon_events e where e.user_id = uid and not e.seen), '[]'::jsonb));
end $$;

-- 2) jogador "teste" sai do jogo em definitivo
do $$
declare ids uuid[];
begin
  select array_agg(distinct u) into ids from (
    select c.user_id u from public.characters c where lower(btrim(c.name)) = 'teste'
    union select p.id from public.profiles p where lower(p.username::text) = 'teste') x;
  if ids is null then raise notice 'Nenhum jogador "teste" encontrado: nada a apagar.'; return; end if;
  if cardinality(ids) > 1 then raise exception 'Há % contas com o nome "teste". Nada foi apagado: confira qual é.', cardinality(ids); end if;
  if exists (select 1 from public.user_roles r where r.user_id = ids[1] and r.role = 'admin') then
    raise exception 'A conta "teste" é de administrador. Nada foi apagado.'; end if;
  delete from auth.users where id = ids[1];   -- o resto do jogador sai junto (on delete cascade)
  raise notice 'Jogador "teste" apagado.';
end $$;
