-- =====================================================================
-- POKEGAMES — TMs com nível mínimo e nível de evolução escondido (pedido do dono em 09/11/2026).
-- (1) TM por força do ataque (game_config.config.tm_nivel, Ajustes do jogo):
--     fraca (até 60 de poder, ou sem dano) a partir do nível 10, média (até 90)
--     a partir do 25, forte (acima de 90) a partir do 40. HMs continuam livres.
--     Quem já ensinou fica com o ataque, mas ele fica BLOQUEADO até o Pokémon
--     chegar ao nível: na batalha ele não aparece (bt_mon). Com o teto das
--     batalhas valendo moedas, conta o nível de batalha (bt_mon_teto).
--     Ataque que a espécie (ou a forma anterior) aprende sozinha nunca é bloqueado.
-- (2) Nível de evolução escondido: os jogadores não leem mais a tabela
--     pk_evolutions. O site recebe as evoluções sem o nível (pk_evolucoes) e só
--     fica sabendo quando um Pokémon SEU já pode evoluir (pk_meus_extras).
-- Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

create or replace function public.tm_nivel_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "fraca_poder": 60, "fraca_nivel": 10, "media_poder": 90, "media_nivel": 25, "forte_nivel": 40}'::jsonb || coalesce(public.cfg()->'tm_nivel', '{}'::jsonb)
$$;
update public.game_config set config = jsonb_set(config, '{tm_nivel}', public.tm_nivel_cfg()) where active and not (config ? 'tm_nivel');

-- nível mínimo para usar um ataque de TM, pela força dele
create or replace function public.tm_nivel_move(_move int) returns int
language sql stable security definer set search_path = public, extensions as $$
  select case when not coalesce((c->>'on')::boolean, true) then 0
    when coalesce(mv.power, 0) <= (c->>'fraca_poder')::int then (c->>'fraca_nivel')::int
    when coalesce(mv.power, 0) <= (c->>'media_poder')::int then (c->>'media_nivel')::int
    else (c->>'forte_nivel')::int end
  from (select public.tm_nivel_cfg() c) x, pk_moves mv where mv.id = _move
$$;

-- a espécie (ou alguma forma anterior dela) aprende esse ataque sozinha?
create or replace function public.mon_move_natural(_species int, _move int) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  with recursive linha(id) as (
    select _species
    union select e.from_id from pk_evolutions e join linha l on e.to_id = l.id)
  select exists (select 1 from pk_learnset ls join linha l on ls.species_id = l.id where ls.move_id = _move)
      or exists (select 1 from pokemon p join linha l on p.id = l.id where _move = any(p.start_moves))
$$;

-- nível em que um ataque que o Pokémon já sabe fica liberado (0 = sempre)
create or replace function public.mon_move_req(_species int, _move int) returns int
language sql stable security definer set search_path = public, extensions as $$
  select case
    when not exists (select 1 from pk_tm_list t where t.move_id = _move and not t.hm) then 0   -- não é de TM
    when exists (select 1 from pk_tm_list t where t.move_id = _move and t.hm) then 0             -- HM continua livre
    when public.mon_move_natural(_species, _move) then 0                                           -- aprende sozinho
    else coalesce(public.tm_nivel_move(_move), 0) end
$$;

-- ataques que valem num nível (os bloqueados ficam de fora; se não sobrar nenhum, os ataques naturais do nível)
create or replace function public.mon_moves_ok(_species int, _moves int[], _lvl int) returns int[]
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(nullif((select array_agg(mv order by o) from unnest(_moves) with ordinality u(mv, o) where public.mon_move_req(_species, mv) <= _lvl), '{}'),
                  public.pk_moves_at(_species, _lvl))
$$;

-- Pokémon na batalha (versão do 18 + ataques bloqueados de fora)
create or replace function public.bt_mon(_id uuid) returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'id', m.id, 'species', m.species_id, 'name', p.name, 'level', m.level, 't1', p.g1_type1, 't2', p.g1_type2, 'outfit', m.outfit,
    'maxhp', public.pk_stat(p.base_hp, public.pk_hp_dv(m.dv_atk, m.dv_def, m.dv_spd, m.dv_spc), m.level, true),
    'hp',    public.pk_stat(p.base_hp, public.pk_hp_dv(m.dv_atk, m.dv_def, m.dv_spd, m.dv_spc), m.level, true),
    'atk', public.pk_stat(p.base_atk, m.dv_atk, m.level, false), 'def', public.pk_stat(p.base_def, m.dv_def, m.level, false),
    'spd', public.pk_stat(p.base_spd, m.dv_spd, m.level, false), 'spc', public.pk_stat(p.base_spc, m.dv_spc, m.level, false),
    'bspd', p.base_spd, 'bexp', p.base_exp,
    'moves', (select jsonb_agg(jsonb_build_object('id', mv.id, 'pp', mv.pp, 'max', mv.pp) order by u.ord) from unnest(public.mon_moves_ok(m.species_id, m.moves, m.level)) with ordinality u(mid, ord) join pk_moves mv on mv.id = u.mid),
    'status', null, 'sleep', 0, 'conf', 0, 'st', '{"atk":0,"def":0,"spd":0,"spc":0,"acc":0,"eva":0}'::jsonb, 'fl', '{}'::jsonb, 'last', null)
  from monsters m join pokemon p on p.id = m.species_id where m.id = _id
$$;

-- Pokémon na batalha com teto (versão do 77 + ataques pelo nível de batalha)
create or replace function public.bt_mon_teto(_id uuid, _teto int) returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select case when _teto is null or m.level <= _teto then public.bt_mon(_id) else
    public.bt_mon(_id) || jsonb_build_object('level', _teto, 'real_level', m.level,
      'maxhp', public.pk_stat(p.base_hp, public.pk_hp_dv(m.dv_atk, m.dv_def, m.dv_spd, m.dv_spc), _teto, true),
      'hp',    public.pk_stat(p.base_hp, public.pk_hp_dv(m.dv_atk, m.dv_def, m.dv_spd, m.dv_spc), _teto, true),
      'atk', public.pk_stat(p.base_atk, m.dv_atk, _teto, false), 'def', public.pk_stat(p.base_def, m.dv_def, _teto, false),
      'spd', public.pk_stat(p.base_spd, m.dv_spd, _teto, false), 'spc', public.pk_stat(p.base_spc, m.dv_spc, _teto, false),
      'moves', (select jsonb_agg(jsonb_build_object('id', mv.id, 'pp', mv.pp, 'max', mv.pp) order by u.ord)
                  from unnest(public.mon_moves_ok(m.species_id, m.moves, _teto)) with ordinality u(mid, ord) join pk_moves mv on mv.id = u.mid)) end
  from monsters m join pokemon p on p.id = m.species_id where m.id = _id
$$;

-- ---------- evoluções sem o nível ----------
drop policy if exists p_pke on public.pk_evolutions;
revoke select on public.pk_evolutions from authenticated;

create or replace function public.pk_evolucoes() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_agg(jsonb_build_object('from_id', from_id, 'to_id', to_id, 'method', method, 'item', item) order by from_id, to_id), '[]'::jsonb) from pk_evolutions
$$;

-- só os meus: quais já podem evoluir por nível e quais ataques estão bloqueados (e até que nível)
create or replace function public.pk_meus_extras() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'evo', coalesce((select jsonb_agg(jsonb_build_array(m.id, e.to_id)) from monsters m join pk_evolutions e on e.from_id = m.species_id
                      where m.user_id = auth.uid() and e.method = 'nivel' and m.level >= e.level and public.evo_ok(e.from_id, e.to_id)), '[]'::jsonb),
    'travas', coalesce((select jsonb_object_agg(x.id, x.t) from (
        select m.id, jsonb_object_agg(mv, public.mon_move_req(m.species_id, mv)) t
          from monsters m, unnest(m.moves) mv
         where m.user_id = auth.uid() and public.mon_move_req(m.species_id, mv) > m.level group by m.id) x), '{}'::jsonb))
$$;

-- ---------- ensinar TM/HM (versão do 47 + nível mínimo da TM) ----------
create or replace function public.mon_teach(_mon uuid, _item text, _forget int default null) returns public.monsters
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); m monsters; t pk_tm_list; mv pk_moves;
begin
  select * into m from monsters where id = _mon and user_id = uid for update;
  if m.id is null then raise exception 'Esse Pokémon não é seu.'; end if;
  select * into t from pk_tm_list where item = _item;
  if t.item is null then raise exception 'Isso não é uma TM nem uma HM.'; end if;
  select * into mv from pk_moves where id = t.move_id;
  if coalesce((select qty from bag_items where user_id = uid and item = _item for update), 0) < 1 then raise exception 'Você não tem essa % na bolsa.', upper(left(_item, 2)); end if;
  if not exists (select 1 from pk_tm_compat where species_id = m.species_id and move_id = t.move_id) then
    raise exception '% não consegue aprender %.', (select name from pokemon where id = m.species_id), mv.name;
  end if;
  if t.move_id = any(m.moves) then raise exception 'Esse Pokémon já sabe %.', mv.name; end if;
  -- arquivo 83: TM tem nível mínimo pela força do ataque (HM continua livre)
  if not t.hm and m.level < coalesce(public.tm_nivel_move(t.move_id), 0) then
    raise exception '% só pode ser ensinado a partir do nível %.', mv.name, public.tm_nivel_move(t.move_id);
  end if;
  if cardinality(m.moves) < 4 then
    m.moves := m.moves || t.move_id;
  else
    if _forget is null or _forget < 1 or _forget > cardinality(m.moves) then raise exception 'Escolha um ataque para esquecer.'; end if;
    m.moves[_forget] := t.move_id;
  end if;
  update monsters set moves = m.moves, pending_moves = array_remove(pending_moves, t.move_id) where id = m.id returning * into m;
  if not t.hm then update bag_items set qty = qty - 1 where user_id = uid and item = _item; end if;
  insert into mon_events(user_id, mon_id, kind, data, seen) values (uid, m.id, 'golpe', jsonb_build_object('species', m.species_id, 'move', t.move_id, 'learned', true, 'item', _item), true);
  return m;
end $$;

-- ---------- evoluir (versão do 77 + não conta o nível) ----------
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
  if ev.method = 'nivel' and m.level < ev.level then raise exception 'Ainda não chegou a hora de evoluir. Continue treinando!'; end if;   -- arquivo 83: não conta o nível
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

-- ---------- Ajustes do jogo (versão do 82 + TMs) ----------
create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'leilao', public.leilao_cfg(), 'herois', public.herois_cfg(), 'temporada', public.temporada_cfg(), 'liga', public.liga_cfg(), 'pausa', public.pausa_cfg(), 'teto', public.teto_cfg(), 'boas_vindas', public.boas_vindas_cfg(), 'vila_bonus', public.vila_bonus_cfg(), 'tm_nivel', public.tm_nivel_cfg(), 'base', public.cfg());
end $$;

grant execute on function public.pk_evolucoes(), public.pk_meus_extras() to authenticated;
revoke execute on function public.tm_nivel_cfg(), public.tm_nivel_move(int), public.mon_move_natural(int, int), public.mon_move_req(int, int),
  public.mon_moves_ok(int, int[], int) from public, anon, authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('📀 TMs agora têm nível mínimo', 'As TMs agora pedem um nível mínimo, pela força do ataque:
• Ataque fraco (até 60 de poder, ou sem dano): a partir do nível 10.
• Ataque médio (até 90 de poder): a partir do nível 25.
• Ataque forte (acima de 90, como Earthquake, Thunder e Hyper Beam): a partir do nível 40.
• Quem já ensinou não perde nada: o ataque fica na ficha com um cadeado 🔒 e só aparece na batalha quando o Pokémon chegar ao nível. Nas batalhas com limite de nível, conta o nível da batalha.
• As HMs continuam livres.
• E agora o nível em que cada Pokémon evolui é segredo: o jogo só avisa quando o seu Pokémon já pode evoluir.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
