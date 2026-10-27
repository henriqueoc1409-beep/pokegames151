-- =====================================================================
-- POKEGAMES — Interruptor da 2ª geração (Pokémon 152 a 251), pedido do dono em 21/10/2026.
--   * coloca no jogo os dados que o 27 guardou escondidos (Pokémon, descrições, ataques,
--     evoluções, ataques por nível, tipos Sombrio e Metálico);
--   * cria o botão do admin: admin_set_gen2(true/false). Pode ligar e desligar quando quiser;
--   * DESLIGADA (padrão ao rodar): o jogo continua exatamente como hoje (só os 151 nos desafios,
--     palpites, encontros, duelos e evoluções);
--   * LIGADA: encontros e evoluções na hora; desafios do dia a partir do dia seguinte
--     (o desafio já sorteado não muda no meio do dia);
--   * quem já capturou Pokémon da 2ª geração nunca perde nada ao desligar: eles continuam na
--     coleção e batalham; só as evoluções da 2ª ficam esperando.
-- Regras da 1ª geração em tudo (ver PLANO_SEGUNDA_GERACAO.md). Ataques novos sem efeito
-- equivalente avisam "ainda não funciona". Depende do 27 (e do 16 a 18 e 25).
-- Não apaga nada. Antes, faça a cópia de segurança.
-- =====================================================================
do $$ begin
  if to_regclass('public.gen2_species') is null then raise exception 'Rode antes o arquivo 27_dados_gen2.sql.'; end if;
end $$;

-- ---------- 1) os dados entram nas tabelas do jogo (marcados como 2ª geração) ----------
alter table public.pokemon drop constraint if exists pokemon_id_check;
alter table public.pokemon add constraint pokemon_id_check check (id between 1 and 251);
alter table public.pokemon add column if not exists gen int not null default 1;          -- 1 ou 2
alter table public.pokemon add column if not exists base_form2 int;                     -- forma inicial da linha com a 2ª ligada (Pikachu -> Pichu)

insert into public.pokemon (id, name, type1, type2, habitat, color, stage, height_dm, weight_hg, g1_type1, g1_type2, base_hp, base_atk, base_def,
                            base_spd, base_spc, catch_rate, base_exp, growth_rate, start_moves, base_form, gen)
select id, name, type1, type2, habitat, color, stage, height_dm, weight_hg, g1_type1, g1_type2, base_hp, base_atk, base_def,
       base_spd, base_spc, catch_rate, base_exp, growth_rate, start_moves, base_form, 2 from public.gen2_species
on conflict (id) do update set name = excluded.name, type1 = excluded.type1, type2 = excluded.type2, habitat = excluded.habitat, color = excluded.color,
  stage = excluded.stage, height_dm = excluded.height_dm, weight_hg = excluded.weight_hg, g1_type1 = excluded.g1_type1, g1_type2 = excluded.g1_type2,
  base_hp = excluded.base_hp, base_atk = excluded.base_atk, base_def = excluded.base_def, base_spd = excluded.base_spd, base_spc = excluded.base_spc,
  catch_rate = excluded.catch_rate, base_exp = excluded.base_exp, growth_rate = excluded.growth_rate, start_moves = excluded.start_moves,
  base_form = excluded.base_form, gen = 2;
update public.pokemon p set base_form2 = b.base_form from public.gen2_base_forms b where b.id = p.id;

-- descrições do modo Descrição (as imagens de Cartão e Silhueta vêm pelo botão de importar do admin, como na 1ª)
insert into public.pokemon_media (pokemon_id, description) select id, description from public.gen2_species
on conflict (pokemon_id) do update set description = excluded.description;

-- ataques novos: quem não tem efeito equivalente fica marcado e avisa "ainda não funciona"
insert into public.pk_moves (id, code, name, type, power, accuracy, pp, effect)
select id, code, name, type, power, accuracy, pp, coalesce(effect_g1, 'G2_NAO_FUNCIONA') from public.gen2_moves
on conflict (id) do update set code = excluded.code, name = excluded.name, type = excluded.type, power = excluded.power, accuracy = excluded.accuracy,
  pp = excluded.pp, effect = excluded.effect;
insert into public.pk_learnset (species_id, level, move_id) select species_id, level, move_id from public.gen2_learnset on conflict do nothing;
insert into public.pk_evolutions (from_id, to_id, method, level, item) select from_id, to_id, method, level, item from public.gen2_evolutions
on conflict (from_id, to_id) do update set method = excluded.method, level = excluded.level, item = excluded.item;
insert into public.pk_type_chart (atk, def, mult) select atk, def, mult from public.gen2_type_chart
on conflict (atk, def) do update set mult = excluded.mult;

-- começa DESLIGADA (só grava se ainda não existir)
update public.game_config set config = config || '{"gen2": false}'::jsonb where active and not (config ? 'gen2');

-- ---------- 2) o interruptor ----------
create or replace function public.gen2_on() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((public.cfg()->>'gen2')::boolean, false)
$$;
-- esse Pokémon está em jogo agora? (1ª sempre; 2ª só ligada)
create or replace function public.gen_ok(_id int) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select _id <= 151 or public.gen2_on()
$$;
-- para o desafio do dia: a 2ª só entra a partir do dia seguinte ao ligar
create or replace function public.gen_ok_puzzle(_id int, _d date) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select _id <= 151 or (public.gen2_on() and _d >= coalesce((public.cfg()->>'gen2_from')::date, '1900-01-01'::date))
$$;
-- evolução: as que envolvem a 2ª (Golbat -> Crobat, Pichu -> Pikachu...) só com ela ligada
create or replace function public.evo_ok(_from int, _to int) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select (_from <= 151 and _to <= 151) or public.gen2_on()
$$;

create or replace function public.admin_set_gen2(_on boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb; was boolean := public.gen2_on();
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador liga ou desliga a 2ª geração.'; end if;
  if _on is null then raise exception 'Escolha ligar ou desligar.'; end if;
  if _on = was then return public.cfg(); end if;
  update game_config set config = config || jsonb_build_object('gen2', _on,
           'gen2_from', case when _on then to_char(public.game_today() + 1, 'YYYY-MM-DD') else config->>'gen2_from' end)
   where active returning config into c;
  insert into admin_audit_log(admin_id, action, target, before, after) values (uid, 'gen2', 'game_config', jsonb_build_object('ligada', was), jsonb_build_object('ligada', _on));
  insert into event_log(kind, message) values ('novidade', case when _on
    then 'A 2ª geração chegou! Os Pokémon novos já aparecem nos encontros e, a partir de amanhã, nos desafios do dia.'
    else 'A 2ª geração foi desligada por enquanto. Quem já tem Pokémon dela continua com eles.' end);
  return c;
end $$;

-- tipo Metálico é físico (Sombrio é especial), como na 2ª geração
create or replace function public.bt_physical(_type text) returns boolean
language sql immutable as $$ select _type in ('NORMAL','LUTA','VOADOR','VENENO','TERRA','PEDRA','INSETO','FANTASMA','METALICO') $$;

-- sorteio do desafio do dia (versão do 01 + respeita o interruptor, a partir do dia seguinte ao ligar)
create or replace function public.ensure_puzzles(_d date) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare m public.puzzle_mode; pid int;
begin
  foreach m in array enum_range(null::public.puzzle_mode) loop
    if exists (select 1 from daily_puzzles where puzzle_date = _d and mode = m) then continue; end if;
    select p.id into pid
    from pokemon p left join pokemon_media pm on pm.pokemon_id = p.id
    where (m = 'classico'
        or (m = 'descricao' and pm.description is not null)
        or (m in ('cartao','silhueta') and pm.silhouette is not null and pm.pixel_levels is not null))
      and public.gen_ok_puzzle(p.id, _d)
      and p.id not in (select pokemon_id from daily_puzzles where puzzle_date > _d - 30 and puzzle_date <= _d)
    order by random() limit 1;
    if pid is null then   -- poucos Pokémon com mídia: aceita repetir
      select p.id into pid
      from pokemon p left join pokemon_media pm on pm.pokemon_id = p.id
      where (m = 'classico'
          or (m = 'descricao' and pm.description is not null)
          or (m in ('cartao','silhueta') and pm.silhouette is not null and pm.pixel_levels is not null))
        and public.gen_ok_puzzle(p.id, _d)
        and p.id not in (select pokemon_id from daily_puzzles where puzzle_date = _d)
      order by random() limit 1;
    end if;
    if pid is not null then
      insert into daily_puzzles(puzzle_date, mode, pokemon_id) values (_d, m, pid) on conflict do nothing;
    end if;
  end loop;
end $$;

-- palpite (versão do 06 + com a 2ª desligada só aceita palpite da 1ª)
create or replace function public.make_guess(_mode public.puzzle_mode, _pokemon_id int, _date date default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d date := public.play_date(_date);
  ans int; s guess_sessions; ok boolean; fb jsonb; maxg int := (public.cfg()->>'max_guesses')::int;
begin
  if not exists (select 1 from characters where user_id = uid) then raise exception 'Crie seu personagem primeiro.'; end if;
  if exists (select 1 from daily_moves where user_id = uid and move_date = d) then raise exception 'Você já andou nesse dia. O desafio dele está encerrado para você.'; end if;
  if not exists (select 1 from pokemon where id = _pokemon_id) then raise exception 'Pokémon desconhecido.'; end if;
  perform public.ensure_puzzles(d);
  select pokemon_id into ans from daily_puzzles where puzzle_date = d and mode = _mode;
  if ans is null then raise exception 'Este modo ainda não está disponível. O administrador precisa importar a Pokédex.'; end if;
  -- com a 2ª geração desligada, só vale palpite da 1ª (a não ser que a resposta de um dia antigo seja da 2ª)
  if _pokemon_id > 151 and not public.gen2_on() and _pokemon_id <> ans then raise exception 'Esse Pokémon ainda não faz parte do jogo.'; end if;
  insert into guess_sessions(user_id, puzzle_date, mode, recovered) values (uid, d, _mode, d < public.game_today()) on conflict do nothing;
  select * into s from guess_sessions where user_id = uid and puzzle_date = d and mode = _mode for update;
  if s.solved or s.failed then raise exception 'Você já concluiu este modo.'; end if;
  if exists (select 1 from guesses where user_id = uid and puzzle_date = d and mode = _mode and pokemon_id = _pokemon_id) then
    raise exception 'Você já tentou esse Pokémon neste modo.';
  end if;
  ok := _pokemon_id = ans;
  if _mode = 'classico' then fb := public.compare_pokemon(_pokemon_id, ans); end if;
  insert into guesses(user_id, puzzle_date, mode, pokemon_id, correct, feedback) values (uid, d, _mode, _pokemon_id, ok, fb);
  update guess_sessions set attempts = attempts + 1, solved = ok, failed = (not ok and attempts + 1 >= maxg),
         finished_at = case when ok or attempts + 1 >= maxg then now() end
   where user_id = uid and puzzle_date = d and mode = _mode;
  return public.puzzle_state(_mode, d);
end $$;

-- duelo de quiz (versão do 07 + Pokémon secreto respeita o interruptor)
create or replace function public.accept_duel(_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); t date := public.game_today(); tz text := coalesce(public.cfg()->>'timezone','America/Sao_Paulo');
  d duels; me characters; ch characters; pid int;
begin
  perform public.expire_duels();
  select * into d from duels where id = _id for update;
  if d.id is null or d.opponent <> uid then raise exception 'Desafio não encontrado.'; end if;
  if d.status <> 'pendente' then raise exception 'Esse desafio não está mais aberto.'; end if;
  if exists (select 1 from duels where opponent = uid and accepted_at is not null and (accepted_at at time zone tz)::date = t) then
    raise exception 'Você já aceitou um duelo hoje. Volte amanhã.';
  end if;
  select * into me from characters where user_id = uid for update;
  select * into ch from characters where user_id = d.challenger;
  if d.stake_kind = 'moedas' then
    if me.coins < d.stake then raise exception 'Você precisa de % moedas para aceitar.', d.stake; end if;
    update characters set coins = coins - d.stake where id = me.id;
  elsif me.arrived_rank is not null or ch.arrived_rank is not null then
    raise exception 'Quem já chegou ao Castelo só duela valendo moedas.';
  end if;
  if d.kind = 'quiz' then
    select p.id into pid from pokemon p join pokemon_media m on m.pokemon_id = p.id where m.silhouette is not null and public.gen_ok(p.id) order by random() limit 1;
    if pid is null then raise exception 'Duelos de quiz precisam das imagens da Pokédex. Peça ao administrador para importá-las.'; end if;
  end if;
  update duels set status = 'aceito', accepted_at = now(), pokemon_id = pid,
         expires_at = now() + make_interval(hours => (c->>'duel_hours')::int) where id = _id;
  insert into event_log(user_id, kind, message) values (uid, 'duelo', me.name || ' aceitou o desafio de ' || ch.name || '!');
  if d.kind = 'sorte' then perform public.resolve_duel(_id); end if;
end $$;

-- XP dos Pokémon (versão do 17 + evoluções da 2ª só com ela ligada)
create or replace function public.pk_give_xp(_mon uuid, _xp int, _source text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare m monsters; p pokemon; newlvl int; lv int; mv int; ev record;
begin
  if _xp <= 0 then return; end if;
  select * into m from monsters where id = _mon for update;
  if m.id is null or m.level >= 100 then return; end if;
  select * into p from pokemon where id = m.species_id;
  m.exp := least(m.exp + _xp, public.pk_exp_for(p.growth_rate, 100));
  newlvl := m.level;
  while newlvl < 100 and m.exp >= public.pk_exp_for(p.growth_rate, newlvl + 1) loop newlvl := newlvl + 1; end loop;
  if newlvl > m.level then
    insert into mon_events(user_id, mon_id, kind, data) values (m.user_id, m.id, 'nivel', jsonb_build_object('species', m.species_id, 'from', m.level, 'to', newlvl, 'source', _source));
    for lv in m.level + 1 .. newlvl loop
      for mv in select move_id from pk_learnset where species_id = m.species_id and level = lv order by move_id loop
        if mv = any(m.moves) or mv = any(m.pending_moves) then continue; end if;
        if cardinality(m.moves) < 4 then
          m.moves := m.moves || mv;
          insert into mon_events(user_id, mon_id, kind, data) values (m.user_id, m.id, 'golpe', jsonb_build_object('species', m.species_id, 'move', mv, 'learned', true));
        else
          m.pending_moves := m.pending_moves || mv;
          insert into mon_events(user_id, mon_id, kind, data) values (m.user_id, m.id, 'golpe', jsonb_build_object('species', m.species_id, 'move', mv, 'learned', false));
        end if;
      end loop;
    end loop;
    for ev in select * from pk_evolutions where from_id = m.species_id and method = 'nivel' and level > m.level and level <= newlvl and public.evo_ok(from_id, to_id) loop
      insert into mon_events(user_id, mon_id, kind, data) values (m.user_id, m.id, 'evolucao', jsonb_build_object('species', m.species_id, 'to', ev.to_id));
    end loop;
  end if;
  update monsters set exp = m.exp, level = newlvl, moves = m.moves, pending_moves = m.pending_moves where id = m.id;
  if newlvl > m.level then perform public.pk_refresh_mascot(m.user_id); end if;
end $$;

-- encontro (versão do 17 + com a 2ª ligada a linha começa na forma da 2ª, como Pichu; sem lendários das duas;
--   e correção do sorteio: antes cada linha usava um número aleatório diferente e os primeiros da Pokédex saíam muito mais)
create or replace function public.pk_pick_species(_region text) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.pk_cfg()->'encounter'; tps text[] := public.pk_region_types(_region); pick int; r numeric := random();
begin
  with pool as (
    select p.id, (coalesce((c->'rarity_weight'->>public.pk_rarity(p.catch_rate))::numeric, 1)
                  * case when p.g1_type1 = any(tps) or p.g1_type2 = any(tps) then coalesce((c->>'region_bonus')::numeric, 1) else 1 end) as w
    from pokemon p
    where (case when public.gen2_on() then coalesce(p.base_form2, p.base_form) else p.base_form end) = p.id and p.catch_rate is not null and public.gen_ok(p.id)
      and (coalesce((c->>'legendaries')::boolean, false) or p.id not in (144, 145, 146, 150, 151, 243, 244, 245, 249, 250, 251))),
  acc as (select id, sum(w) over (order by id) as hi, sum(w) over () as tot from pool)
  select id into pick from acc where hi >= r * tot order by hi limit 1;
  return pick;
end $$;

-- evoluir (versão do 17 + evoluções da 2ª só com ela ligada)
create or replace function public.mon_evolve(_id uuid, _to int) returns public.monsters
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); m monsters; ev pk_evolutions; have int; mv int; tp pokemon;
begin
  select * into m from monsters where id = _id and user_id = uid for update;
  if m.id is null then raise exception 'Esse Pokémon não é seu.'; end if;
  select * into ev from pk_evolutions where from_id = m.species_id and to_id = _to;
  if ev.from_id is null then raise exception 'Essa evolução não existe.'; end if;
  if not public.evo_ok(ev.from_id, ev.to_id) then raise exception 'Essa evolução é da 2ª geração, que está desligada no momento. Seu Pokémon espera, sem perder nada.'; end if;
  if ev.method = 'troca' then raise exception 'Essa evolução acontece por troca entre jogadores, que ainda não existe no Pokegames.'; end if;
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

-- bolsa (versão do 17 + pedras novas só com a 2ª ligada)
create or replace function public.pk_buy(_item text, _qty int default 1) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.pk_cfg(); price int; me characters;
begin
  if _qty is null or _qty < 1 or _qty > 20 then raise exception 'Quantidade inválida.'; end if;
  if _item like '%\_ball' and c->'capture'->'balls' ? replace(_item, '_ball', '') then price := (c->'capture'->'balls'->replace(_item, '_ball', '')->>'price')::int;
  elsif _item in ('pedra_fogo','pedra_agua','pedra_trovao','pedra_folha','pedra_lua')
     or (public.gen2_on() and _item in ('pedra_sol','pedra_lua_nova','pedra_metal','pedra_rei')) then price := (c->'stones'->>'price')::int;
  else raise exception 'Item inválido.'; end if;
  if price <= 0 then raise exception 'Esse item é grátis.'; end if;
  select * into me from characters where user_id = uid for update;
  if me.coins < price * _qty then raise exception 'Moedas insuficientes.'; end if;
  update characters set coins = coins - price * _qty where id = me.id;
  insert into bag_items(user_id, item, qty) values (uid, _item, _qty) on conflict (user_id, item) do update set qty = bag_items.qty + _qty;
  return jsonb_build_object('item', _item, 'qty', (select qty from bag_items where user_id = uid and item = _item), 'coins', me.coins - price * _qty);
end $$;

-- motor: um ataque (versão do 18 + ataques da 2ª sem efeito avisam; Metronome só sorteia da 2ª com ela ligada)
create or replace function public.bt_use_move(_s jsonb, _a int, _mid int, _first boolean, _depth int default 0) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare ds int := 1 - _a; A jsonb := _s->'sides'->_a->'mons'->((_s->'sides'->_a->>'active')::int); D jsonb := _s->'sides'->ds->'mons'->((_s->'sides'->ds->>'active')::int);
  mv pk_moves; eff numeric; crit boolean; hits int := 1; dmg int; total int := 0; i int; t int; acc numeric; lvl int; vatk numeric; vdef numeric; base int;
  phys boolean; chance int; st text; delta int; key text; target jsonb; tgt int; heal int; nm text := A->>'name'; dn text := D->>'name';
  ai int := (_s->'sides'->_a->>'active')::int; di int := (_s->'sides'->ds->>'active')::int; stab boolean; _lines jsonb := coalesce(_s->'_lines', '[]'::jsonb);
begin
  select * into mv from pk_moves where id = _mid;
  -- golpes que chamam outros
  if mv.effect = 'METRONOME_EFFECT' and _depth = 0 then
    select id into t from pk_moves where id not in (118, 165) and (id <= 165 or public.gen2_on()) order by random() limit 1;
    _lines := _lines || jsonb_build_object('txt', nm || ' usou Metronome!');
    return public.bt_use_move(jsonb_set(_s, '{_lines}', _lines), _a, t, _first, 1);
  end if;
  if mv.effect = 'MIRROR_MOVE_EFFECT' and _depth = 0 then
    if D->>'last' is null or (D->>'last')::int = 119 then _lines := _lines || jsonb_build_object('txt', nm || ' usou Mirror Move, mas falhou!'); return jsonb_set(_s, '{_lines}', _lines); end if;
    _lines := _lines || jsonb_build_object('txt', nm || ' usou Mirror Move!');
    return public.bt_use_move(jsonb_set(_s, '{_lines}', _lines), _a, (D->>'last')::int, _first, 1);
  end if;
  _lines := _lines || jsonb_build_object('txt', nm || ' usou ' || mv.name || '!', 'side', _a, 'move', mv.id, 'mtype', mv.type);
  A := jsonb_set(A, '{last}', to_jsonb(mv.id));
  -- primeiro turno dos ataques de dois turnos
  if mv.effect in ('CHARGE_EFFECT','FLY_EFFECT') and coalesce(A->'fl'->>'charging', '') = '' then
    A := jsonb_set(A, '{fl,charging}', to_jsonb(mv.id));
    if mv.effect = 'FLY_EFFECT' then A := jsonb_set(A, '{fl,invul}', 'true'); end if;
    _lines := _lines || jsonb_build_object('txt', nm || ' está se preparando…');
    return jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{_lines}', _lines);
  end if;
  A := A #- '{fl,charging}'; A := A #- '{fl,invul}';
  -- efeitos que ainda não existem no Pokegames
  if mv.effect in ('TRANSFORM_EFFECT','MIMIC_EFFECT','DISABLE_EFFECT','CONVERSION_EFFECT','BIDE_EFFECT','SUBSTITUTE_EFFECT','G2_NAO_FUNCIONA') or mv.id = 68 then
    _lines := _lines || jsonb_build_object('txt', 'Esse ataque ainda não funciona no Pokegames: não aconteceu nada.');
    return jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{_lines}', _lines);
  end if;
  if mv.effect in ('SWITCH_AND_TELEPORT_EFFECT','SPLASH_EFFECT') then
    _lines := _lines || jsonb_build_object('txt', 'Mas não aconteceu nada!');
    return jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{_lines}', _lines);
  end if;
  -- precisão (1ª geração: sorteio de 0 a 255, então até 100% erra 1 vez em 256)
  if mv.effect <> 'SWIFT_EFFECT' and mv.accuracy > 0 and not (mv.power = 0 and mv.effect in ('HEAL_EFFECT','FOCUS_ENERGY_EFFECT','REFLECT_EFFECT','LIGHT_SCREEN_EFFECT','MIST_EFFECT','HAZE_EFFECT')
       or mv.effect like '%\_UP1\_EFFECT' or mv.effect like '%\_UP2\_EFFECT') then
    acc := floor(mv.accuracy * 255 / 100.0) * public.bt_stage((A->'st'->>'acc')::int) / public.bt_stage((D->'st'->>'eva')::int);
    if coalesce((D->'fl'->>'invul')::boolean, false) or floor(random() * 256) >= least(255, acc)
       or (mv.effect = 'OHKO_EFFECT' and public.bt_speed(A) < public.bt_speed(D))
       or (mv.effect = 'DREAM_EATER_EFFECT' and coalesce(D->>'status', '') <> 'SLP') then
      _lines := _lines || jsonb_build_object('txt', 'O ataque de ' || nm || ' errou!');
      if mv.effect = 'JUMP_KICK_EFFECT' then
        A := jsonb_set(A, '{hp}', to_jsonb(greatest(0, (A->>'hp')::int - 1)));
        _lines := _lines || jsonb_build_object('txt', nm || ' caiu e se machucou!', 'side', _a, 'hp', (A->>'hp')::int);
      end if;
      return jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{_lines}', _lines);
    end if;
  end if;

  if mv.power > 0 or mv.effect in ('SPECIAL_DAMAGE_EFFECT','SUPER_FANG_EFFECT','OHKO_EFFECT') then
    eff := public.bt_eff(mv.type, D->>'t1', D->>'t2');
    if eff = 0 and mv.effect not in ('SPECIAL_DAMAGE_EFFECT','SUPER_FANG_EFFECT') then
      _lines := _lines || jsonb_build_object('txt', 'Não afeta ' || dn || '…');
      return jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{_lines}', _lines);
    end if;
    if mv.effect = 'TWO_TO_FIVE_ATTACKS_EFFECT' then t := floor(random() * 8); hits := case when t < 3 then 2 when t < 6 then 3 when t < 7 then 4 else 5 end;
    elsif mv.effect in ('ATTACK_TWICE_EFFECT','TWINEEDLE_EFFECT') then hits := 2; end if;
    -- crítico pela velocidade-base (golpes de crítico alto x8; Focus Energy reduz, como o defeito original)
    base := floor((A->>'bspd')::int / 2);
    if mv.code in ('KARATE_CHOP','RAZOR_LEAF','CRABHAMMER','SLASH') then base := least(255, base * 8); end if;
    if coalesce((A->'fl'->>'focus')::boolean, false) then base := floor(base / 4); end if;
    crit := mv.effect not in ('SPECIAL_DAMAGE_EFFECT','SUPER_FANG_EFFECT','OHKO_EFFECT') and floor(random() * 256) < base;
    for i in 1 .. hits loop
      if mv.effect = 'OHKO_EFFECT' then dmg := (D->>'hp')::int;
      elsif mv.effect = 'SUPER_FANG_EFFECT' then dmg := greatest(1, (D->>'hp')::int / 2);
      elsif mv.effect = 'SPECIAL_DAMAGE_EFFECT' then
        dmg := case mv.code when 'SONICBOOM' then 20 when 'DRAGON_RAGE' then 40 when 'PSYWAVE' then 1 + floor(random() * floor((A->>'level')::int * 1.5))::int
               else (A->>'level')::int end;
      else
        phys := public.bt_physical(mv.type); lvl := (A->>'level')::int * case when crit then 2 else 1 end;
        if phys then
          vatk := (A->>'atk')::int * case when crit then 1 else public.bt_stage((A->'st'->>'atk')::int) end;
          if A->>'status' = 'BRN' and not crit then vatk := vatk / 2; end if;
          vdef := (D->>'def')::int * case when crit then 1 else public.bt_stage((D->'st'->>'def')::int) end;
          if coalesce((D->'fl'->>'reflect')::boolean, false) and not crit then vdef := vdef * 2; end if;
        else
          vatk := (A->>'spc')::int * case when crit then 1 else public.bt_stage((A->'st'->>'spc')::int) end;
          vdef := (D->>'spc')::int * case when crit then 1 else public.bt_stage((D->'st'->>'spc')::int) end;
          if coalesce((D->'fl'->>'light')::boolean, false) and not crit then vdef := vdef * 2; end if;
        end if;
        vatk := greatest(1, floor(vatk)); vdef := greatest(1, floor(vdef));
        if mv.effect = 'EXPLODE_EFFECT' then vdef := greatest(1, floor(vdef / 2)); end if;
        if vatk > 255 or vdef > 255 then vatk := greatest(1, floor(vatk / 4)); vdef := greatest(1, floor(vdef / 4)); end if;
        dmg := least(997, floor(floor(floor(2 * lvl / 5 + 2) * vatk * mv.power / vdef) / 50)::int) + 2;
        stab := mv.type in (A->>'t1', coalesce(A->>'t2', ''));
        if stab then dmg := dmg + dmg / 2; end if;
        dmg := floor(dmg * coalesce((select mult from pk_type_chart where atk = mv.type and def = D->>'t1'), 1))::int;
        if D->>'t2' is not null and D->>'t2' <> D->>'t1' then dmg := floor(dmg * coalesce((select mult from pk_type_chart where atk = mv.type and def = D->>'t2'), 1))::int; end if;
        if dmg > 1 then dmg := floor(dmg * (217 + floor(random() * 39)) / 255)::int; end if;
        dmg := greatest(1, dmg);
      end if;
      dmg := least(dmg, (D->>'hp')::int);
      D := jsonb_set(D, '{hp}', to_jsonb((D->>'hp')::int - dmg));
      total := total + dmg;
      _lines := _lines || jsonb_build_object('txt', case when hits > 1 then 'Acertou! ' else '' end || dn || ' perdeu ' || dmg || ' de vida.', 'side', ds, 'hp', (D->>'hp')::int, 'dmg', dmg);
      exit when (D->>'hp')::int <= 0;
    end loop;
    if hits > 1 then _lines := _lines || jsonb_build_object('txt', 'Acertou ' || least(i, hits) || ' vezes!'); end if;
    if crit then _lines := _lines || jsonb_build_object('txt', 'Acerto crítico!'); end if;
    if mv.effect not in ('SPECIAL_DAMAGE_EFFECT','SUPER_FANG_EFFECT','OHKO_EFFECT') then
      if eff > 1 then _lines := _lines || jsonb_build_object('txt', 'É super eficaz!');
      elsif eff < 1 then _lines := _lines || jsonb_build_object('txt', 'Não é muito eficaz…'); end if;
    end if;
    if mv.effect = 'OHKO_EFFECT' then _lines := _lines || jsonb_build_object('txt', 'Nocaute de um golpe só!'); end if;
    -- congelado acertado por fogo descongela
    if mv.type = 'FOGO' and D->>'status' = 'FRZ' then D := jsonb_set(D, '{status}', 'null'); _lines := _lines || jsonb_build_object('txt', dn || ' descongelou!'); end if;
    -- recuo, dreno e explosão
    if mv.effect = 'RECOIL_EFFECT' then
      heal := greatest(1, total / case when mv.code = 'STRUGGLE' then 2 else 4 end);
      A := jsonb_set(A, '{hp}', to_jsonb(greatest(0, (A->>'hp')::int - heal)));
      _lines := _lines || jsonb_build_object('txt', nm || ' sofreu o impacto do próprio golpe.', 'side', _a, 'hp', (A->>'hp')::int);
    elsif mv.effect in ('DRAIN_HP_EFFECT','DREAM_EATER_EFFECT') then
      heal := greatest(1, total / 2);
      A := jsonb_set(A, '{hp}', to_jsonb(least((A->>'maxhp')::int, (A->>'hp')::int + heal)));
      _lines := _lines || jsonb_build_object('txt', dn || ' teve a energia sugada!', 'side', _a, 'hp', (A->>'hp')::int);
    elsif mv.effect = 'EXPLODE_EFFECT' then
      A := jsonb_set(A, '{hp}', '0');
      _lines := _lines || jsonb_build_object('txt', nm || ' explodiu!', 'side', _a, 'hp', 0);
    elsif mv.effect = 'HYPER_BEAM_EFFECT' and (D->>'hp')::int > 0 then
      A := jsonb_set(A, '{fl,recharge}', 'true');
    end if;
    -- efeitos secundários (chances da 1ª geração, em 256)
    if (D->>'hp')::int > 0 then
      chance := case mv.effect
        when 'BURN_SIDE_EFFECT1' then 26 when 'BURN_SIDE_EFFECT2' then 77 when 'FREEZE_SIDE_EFFECT1' then 26 when 'PARALYZE_SIDE_EFFECT1' then 26
        when 'PARALYZE_SIDE_EFFECT2' then 77 when 'POISON_SIDE_EFFECT1' then 52 when 'POISON_SIDE_EFFECT2' then 103 when 'TWINEEDLE_EFFECT' then 52
        when 'FLINCH_SIDE_EFFECT1' then 26 when 'FLINCH_SIDE_EFFECT2' then 77 when 'CONFUSION_SIDE_EFFECT' then 26
        when 'ATTACK_DOWN_SIDE_EFFECT' then 85 when 'DEFENSE_DOWN_SIDE_EFFECT' then 85 when 'SPEED_DOWN_SIDE_EFFECT' then 85 when 'SPECIAL_DOWN_SIDE_EFFECT' then 85
        else 0 end;
      if chance > 0 and floor(random() * 256) < chance then
        st := case when mv.effect like 'BURN%' then 'BRN' when mv.effect like 'FREEZE%' then 'FRZ' when mv.effect like 'PARALYZE%' then 'PAR'
                   when mv.effect like 'POISON%' or mv.effect = 'TWINEEDLE_EFFECT' then 'PSN' end;
        if st is not null then
          -- a 1ª geração não aplica o estado se o alvo for do mesmo tipo do golpe
          if D->>'status' is null and mv.type not in (D->>'t1', coalesce(D->>'t2', '')) then
            D := jsonb_set(D, '{status}', to_jsonb(st));
            _lines := _lines || jsonb_build_object('txt', dn || case st when 'BRN' then ' foi queimado!' when 'FRZ' then ' congelou!' when 'PAR' then ' ficou paralisado!' else ' foi envenenado!' end, 'side', ds, 'status', st);
          end if;
        elsif mv.effect like 'FLINCH%' then
          if _first then D := jsonb_set(D, '{fl,flinch}', 'true'); end if;
        elsif mv.effect = 'CONFUSION_SIDE_EFFECT' then
          if (D->>'conf')::int = 0 then D := jsonb_set(D, '{conf}', to_jsonb(2 + floor(random() * 4)::int)); _lines := _lines || jsonb_build_object('txt', dn || ' ficou confuso!'); end if;
        elsif not coalesce((D->'fl'->>'mist')::boolean, false) then
          key := case when mv.effect like 'ATTACK%' then 'atk' when mv.effect like 'DEFENSE%' then 'def' when mv.effect like 'SPEED%' then 'spd' else 'spc' end;
          if (D->'st'->>key)::int > -6 then
            D := jsonb_set(D, array['st', key], to_jsonb((D->'st'->>key)::int - 1));
            _lines := _lines || jsonb_build_object('txt', case key when 'atk' then 'O ataque' when 'def' then 'A defesa' when 'spd' then 'A velocidade' else 'O especial' end || ' de ' || dn || ' caiu!');
          end if;
        end if;
      end if;
    end if;
  else
    -- ataques sem dano
    if mv.effect = 'SLEEP_EFFECT' then
      if D->>'status' is not null then _lines := _lines || jsonb_build_object('txt', 'Mas falhou!');
      else D := jsonb_set(jsonb_set(D, '{status}', '"SLP"'), '{sleep}', to_jsonb(1 + floor(random() * 7)::int)); _lines := _lines || jsonb_build_object('txt', dn || ' adormeceu!', 'side', ds, 'status', 'SLP'); end if;
    elsif mv.effect = 'POISON_EFFECT' then
      if D->>'status' is not null or 'VENENO' in (D->>'t1', coalesce(D->>'t2', '')) then _lines := _lines || jsonb_build_object('txt', 'Mas falhou!');
      else D := jsonb_set(D, '{status}', '"PSN"'); _lines := _lines || jsonb_build_object('txt', dn || ' foi envenenado!', 'side', ds, 'status', 'PSN'); end if;
    elsif mv.effect = 'PARALYZE_EFFECT' then
      if D->>'status' is not null or (mv.type = 'ELETRICO' and public.bt_eff('ELETRICO', D->>'t1', D->>'t2') = 0) then _lines := _lines || jsonb_build_object('txt', 'Mas falhou!');
      else D := jsonb_set(D, '{status}', '"PAR"'); _lines := _lines || jsonb_build_object('txt', dn || ' ficou paralisado! Talvez não consiga se mover.', 'side', ds, 'status', 'PAR'); end if;
    elsif mv.effect = 'CONFUSION_EFFECT' then
      if (D->>'conf')::int > 0 then _lines := _lines || jsonb_build_object('txt', 'Mas falhou!');
      else D := jsonb_set(D, '{conf}', to_jsonb(2 + floor(random() * 4)::int)); _lines := _lines || jsonb_build_object('txt', dn || ' ficou confuso!'); end if;
    elsif mv.effect like '%\_UP1\_EFFECT' or mv.effect like '%\_UP2\_EFFECT' or mv.effect like '%\_DOWN1\_EFFECT' or mv.effect like '%\_DOWN2\_EFFECT' then
      key := case when mv.effect like 'ATTACK%' then 'atk' when mv.effect like 'DEFENSE%' then 'def' when mv.effect like 'SPEED%' then 'spd'
                  when mv.effect like 'SPECIAL%' then 'spc' when mv.effect like 'ACCURACY%' then 'acc' else 'eva' end;
      delta := case when mv.effect like '%UP2%' then 2 when mv.effect like '%UP1%' then 1 when mv.effect like '%DOWN2%' then -2 else -1 end;
      if delta > 0 then tgt := _a; target := A; else tgt := ds; target := D; end if;
      if delta < 0 and coalesce((D->'fl'->>'mist')::boolean, false) then _lines := _lines || jsonb_build_object('txt', dn || ' está protegido pela névoa!');
      elsif (delta > 0 and (target->'st'->>key)::int >= 6) or (delta < 0 and (target->'st'->>key)::int <= -6) then _lines := _lines || jsonb_build_object('txt', 'Nada aconteceu!');
      else
        target := jsonb_set(target, array['st', key], to_jsonb(greatest(-6, least(6, (target->'st'->>key)::int + delta))));
        _lines := _lines || jsonb_build_object('txt', case key when 'atk' then 'O ataque' when 'def' then 'A defesa' when 'spd' then 'A velocidade'
            when 'spc' then 'O especial' when 'acc' then 'A precisão' else 'A evasão' end || ' de ' || (target->>'name') || case when delta > 0 then ' subiu' else ' caiu' end || case when abs(delta) > 1 then ' muito!' else '!' end);
        if tgt = _a then A := target; else D := target; end if;
      end if;
    elsif mv.effect = 'HEAL_EFFECT' then
      if (A->>'hp')::int >= (A->>'maxhp')::int then _lines := _lines || jsonb_build_object('txt', 'Mas falhou!');
      elsif mv.code = 'REST' then
        A := jsonb_set(jsonb_set(jsonb_set(A, '{hp}', to_jsonb((A->>'maxhp')::int)), '{status}', '"SLP"'), '{sleep}', '2');
        _lines := _lines || jsonb_build_object('txt', nm || ' dormiu e recuperou toda a vida!', 'side', _a, 'hp', (A->>'hp')::int, 'status', 'SLP');
      else
        A := jsonb_set(A, '{hp}', to_jsonb(least((A->>'maxhp')::int, (A->>'hp')::int + (A->>'maxhp')::int / 2)));
        _lines := _lines || jsonb_build_object('txt', nm || ' recuperou vida!', 'side', _a, 'hp', (A->>'hp')::int);
      end if;
    elsif mv.effect = 'FOCUS_ENERGY_EFFECT' then A := jsonb_set(A, '{fl,focus}', 'true'); _lines := _lines || jsonb_build_object('txt', nm || ' está concentrado!');
    elsif mv.effect = 'REFLECT_EFFECT' then A := jsonb_set(A, '{fl,reflect}', 'true'); _lines := _lines || jsonb_build_object('txt', nm || ' ficou mais resistente a golpes físicos!');
    elsif mv.effect = 'LIGHT_SCREEN_EFFECT' then A := jsonb_set(A, '{fl,light}', 'true'); _lines := _lines || jsonb_build_object('txt', nm || ' ficou mais resistente a golpes especiais!');
    elsif mv.effect = 'MIST_EFFECT' then A := jsonb_set(A, '{fl,mist}', 'true'); _lines := _lines || jsonb_build_object('txt', nm || ' se cobriu de névoa!');
    elsif mv.effect = 'HAZE_EFFECT' then
      A := jsonb_set(A, '{st}', '{"atk":0,"def":0,"spd":0,"spc":0,"acc":0,"eva":0}'); D := jsonb_set(D, '{st}', '{"atk":0,"def":0,"spd":0,"spc":0,"acc":0,"eva":0}');
      A := jsonb_set(A, '{conf}', '0'); D := jsonb_set(jsonb_set(D, '{conf}', '0'), '{status}', 'null'); D := D #- '{fl,leech}'; A := A #- '{fl,leech}';
      _lines := _lines || jsonb_build_object('txt', 'Todas as mudanças de atributos foram desfeitas!', 'side', ds, 'status', null);
    elsif mv.effect = 'LEECH_SEED_EFFECT' then
      if 'PLANTA' in (D->>'t1', coalesce(D->>'t2', '')) or coalesce((D->'fl'->>'leech')::boolean, false) then _lines := _lines || jsonb_build_object('txt', 'Mas falhou!');
      else D := jsonb_set(D, '{fl,leech}', 'true'); _lines := _lines || jsonb_build_object('txt', dn || ' foi semeado!'); end if;
    else
      _lines := _lines || jsonb_build_object('txt', 'Mas não aconteceu nada!');
    end if;
  end if;
  _s := jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A);
  _s := jsonb_set(_s, array['sides', ds::text, 'mons', di::text], D);
  return jsonb_set(_s, '{_lines}', _lines);
end $$;

-- guerra: escolha do ataque (versão do 25 + evita ataques que ainda não funcionam)
create or replace function public.war_pick(_s jsonb, _a int, _tactic text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare A jsonb := _s->'sides'->_a->'mons'->((_s->'sides'->_a->>'active')::int);
  D jsonb := _s->'sides'->(1 - _a)->'mons'->((_s->'sides'->(1 - _a)->>'active')::int);
  i int; mv pk_moves; sc numeric; bs numeric := -1; best int := -1; ratio numeric;
begin
  if coalesce(A->'fl'->>'charging', '') <> '' or coalesce((A->'fl'->>'recharge')::boolean, false) then return '{"kind": "forced", "value": 0}'; end if;
  for i in 0 .. jsonb_array_length(A->'moves') - 1 loop
    continue when (A->'moves'->i->>'pp')::int <= 0;
    select * into mv from pk_moves where id = (A->'moves'->i->>'id')::int;
    if mv.effect in ('TRANSFORM_EFFECT','MIMIC_EFFECT','DISABLE_EFFECT','CONVERSION_EFFECT','BIDE_EFFECT','SUBSTITUTE_EFFECT','SPLASH_EFFECT','SWITCH_AND_TELEPORT_EFFECT','G2_NAO_FUNCIONA') or mv.id = 68 then sc := 0.01;
    elsif mv.effect = 'DREAM_EATER_EFFECT' and coalesce(D->>'status', '') <> 'SLP' then sc := 0.01;
    elsif mv.effect = 'OHKO_EFFECT' then sc := 30 * mv.accuracy / 100.0 * case when public.bt_eff(mv.type, D->>'t1', D->>'t2') = 0 then 0 else 1 end;
    elsif mv.effect = 'SPECIAL_DAMAGE_EFFECT' or mv.power = 1 then sc := 40 * case when public.bt_eff(mv.type, D->>'t1', D->>'t2') = 0 then 0 else 1 end;
    elsif mv.power > 1 then
      ratio := case when public.bt_physical(mv.type) then greatest(1, (A->>'atk')::numeric) / greatest(1, (D->>'def')::numeric)
                    else greatest(1, (A->>'spc')::numeric) / greatest(1, (D->>'spc')::numeric) end;
      sc := mv.power * public.bt_eff(mv.type, D->>'t1', D->>'t2') * case when mv.type in (A->>'t1', coalesce(A->>'t2', '')) then 1.5 else 1 end * ratio
            * case when _tactic = 'segura' then power(mv.accuracy / 100.0, 2) else mv.accuracy / 100.0 end;
      if mv.effect in ('CHARGE_EFFECT', 'FLY_EFFECT', 'HYPER_BEAM_EFFECT') then sc := sc * 0.6; end if;
      if mv.effect = 'EXPLODE_EFFECT' then sc := sc * 0.3; end if;
    else
      sc := case when _tactic = 'segura' and D->>'status' is null and mv.effect in ('SLEEP_EFFECT', 'PARALYZE_EFFECT') then 200 * mv.accuracy / 100.0 else 3 end;
    end if;
    sc := sc * (0.9 + random() * 0.2);
    if sc > bs then bs := sc; best := i; end if;
  end loop;
  if best < 0 then return '{"kind": "move", "value": -1}'; end if;   -- sem PP: Struggle
  return jsonb_build_object('kind', 'move', 'value', best);
end $$;


-- ---------- permissões ----------
revoke execute on function public.gen2_on(), public.gen_ok(int), public.gen_ok_puzzle(int, date), public.evo_ok(int, int) from public, anon, authenticated;
revoke execute on function public.admin_set_gen2(boolean) from public, anon;
grant execute on function public.admin_set_gen2(boolean) to authenticated;
