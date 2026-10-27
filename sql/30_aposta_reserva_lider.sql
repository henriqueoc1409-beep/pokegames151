-- =====================================================================
-- POKEGAMES — Ajustes pedidos pelos jogadores (dono em 22/10/2026):
--  1) APOSTA DA BATALHA POKÉMON RESERVADA AO DESAFIAR: as moedas de quem desafia saem
--     na hora do convite (como nos Duelos) e voltam se o outro recusar ou se o convite for
--     cancelado. Não dá mais para mandar vários convites com dinheiro que não tem.
--     Quem aceita paga a parte dele ao aceitar. Convites antigos (de antes deste arquivo)
--     continuam cobrando os dois na hora de aceitar.
--  2) O LÍDER (Procurado) SÓ ENFRENTA O MELHOR DA ÚLTIMA RODADA:
--     * Duelos: só o 1º colocado da última rodada pode desafiar o líder, e o líder é obrigado
--       a duelar (o duelo já começa aceito). Se o líder for o próprio melhor da rodada,
--       ninguém pode desafiá-lo;
--     * encontros no mapa (cair na mesma casa): com o líder, só acontece duelo se o outro for
--       o melhor da última rodada; nos outros casos, nada acontece.
--     A recompensa por vencer o Procurado continua igual. Raio e portal não mudam.
-- Depende do 07, 11 e 29. Antes, faça a cópia de segurança.
-- =====================================================================
alter table public.battles add column if not exists bet_held boolean not null default false;   -- parte de quem desafiou já guardada

-- o melhor da última rodada fechada (1º lugar)
create or replace function public.round_champion() returns uuid
language sql stable security definer set search_path = public, extensions as $$
  select user_id from round_results where rank = 1 order by d desc limit 1
$$;

-- desafiar para batalha Pokémon (versão do 29 + reserva a aposta de quem desafia)
create or replace function public.battle_challenge(_opponent uuid, _bet int) returns public.battles
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.pk_cfg()->'battle'; b battles; nm text;
  bmin int := coalesce((public.cfg()->>'battle_bet_min')::int, 10); bmax int := coalesce((public.cfg()->>'battle_bet_max')::int, 100); mc int; oc int;
begin
  if _opponent = uid then raise exception 'Você não pode batalhar contra você mesmo.'; end if;
  if not exists (select 1 from characters where user_id = _opponent) then raise exception 'Jogador não encontrado.'; end if;
  if (select count(*) from monsters where user_id = uid) < (c->>'min_captured')::int then
    raise exception 'Você precisa de pelo menos % Pokémon capturados para batalhar.', c->>'min_captured'; end if;
  if (select count(*) from monsters where user_id = _opponent) < (c->>'min_captured')::int then
    raise exception 'Esse jogador ainda não tem % Pokémon capturados.', c->>'min_captured'; end if;
  if not exists (select 1 from monsters where user_id = uid and team_slot is not null) then raise exception 'Monte sua equipe antes de desafiar alguém.'; end if;
  if exists (select 1 from battles where status in ('convite','ativa') and ((p1 = uid and p2 = _opponent) or (p1 = _opponent and p2 = uid))) then
    raise exception 'Já existe uma batalha aberta entre vocês.'; end if;
  -- aposta obrigatória: os dois precisam ter o valor; as moedas só saem na hora em que o desafio é aceito
  if _bet is null or _bet < bmin or _bet > bmax then raise exception 'A aposta vai de % a % moedas.', bmin, bmax; end if;
  select coins into mc from characters where user_id = uid for update;
  select coins into oc from characters where user_id = _opponent;
  if mc < _bet then raise exception 'Você não tem % moedas para apostar.', _bet; end if;
  if oc < _bet then raise exception 'Esse jogador só tem % moedas: aposte menos.', oc; end if;
  -- as moedas de quem desafia saem agora e voltam se o outro recusar ou se o convite for cancelado
  update characters set coins = coins - _bet where user_id = uid;
  insert into battles(p1, p2, size, bet, bet_held) values (uid, _opponent, (c->>'size')::int, _bet, true) returning * into b;
  select name into nm from characters where user_id = uid;
  insert into event_log(user_id, kind, message) select uid, 'batalha', nm || ' desafiou ' || ch.name || ' para uma batalha Pokémon valendo ' || _bet || ' moedas!' from characters ch where ch.user_id = _opponent;
  return b;
end $$;

-- responder (versão do 29 + devolve a reserva ao recusar; ao aceitar só paga quem aceita)
create or replace function public.battle_respond(_id uuid, _accept boolean) returns public.battles
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); b battles; c jsonb := public.pk_cfg()->'battle'; s1 jsonb; s2 jsonb; c1 int; c2 int;
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
  select jsonb_build_object('user', b.p1, 'name', (select name from characters where user_id = b.p1), 'active', 0, 'need_switch', false,
         'mons', jsonb_agg(public.bt_mon(m.id) order by m.team_slot)) into s1
    from (select id, team_slot from monsters where user_id = b.p1 and team_slot is not null order by team_slot limit b.size) m;
  select jsonb_build_object('user', b.p2, 'name', (select name from characters where user_id = b.p2), 'active', 0, 'need_switch', false,
         'mons', jsonb_agg(public.bt_mon(m.id) order by m.team_slot)) into s2
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

-- cancelar convite (versão do 18 + devolve a reserva)
create or replace function public.battle_cancel(_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); b battles;
begin
  update battles set status = 'cancelada', ended_at = now() where id = _id and p1 = uid and status = 'convite' returning * into b;
  if b.id is null then raise exception 'Só dá para cancelar um convite seu que ainda não foi aceito.'; end if;
  if b.bet > 0 and b.bet_held then
    update characters set coins = coins + b.bet where user_id = uid;   -- devolve a reserva
    update battles set bet_held = false where id = b.id;
  end if;
end $$;

-- desafiar para duelo (versão do 07 + o líder só pelo melhor da rodada, e obrigatório)
create or replace function public.create_duel(_opponent uuid, _kind text, _stake_kind text, _stake int) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); t date := public.game_today(); tz text := coalesce(public.cfg()->>'timezone','America/Sao_Paulo');
  me characters; op characters; maxc int; nid uuid; leader uuid := public.leader_id(); champ uuid := public.round_champion(); forced boolean := false; pid int;
begin
  perform public.expire_duels();
  if _opponent = uid then raise exception 'Você não pode desafiar a si mesmo.'; end if;
  if _kind not in ('quiz','sorte') or _stake_kind not in ('moedas','casas') then raise exception 'Tipo de duelo inválido.'; end if;
  select * into me from characters where user_id = uid for update;
  select * into op from characters where user_id = _opponent;
  if me.id is null or op.id is null then raise exception 'Jogador não encontrado.'; end if;
  if not exists (select 1 from profiles where id = _opponent and status = 'ativo') then raise exception 'Esse jogador está bloqueado.'; end if;
  -- o líder só pode ser desafiado pelo melhor da última rodada, e aí é obrigado a duelar
  if _opponent = leader then
    if champ is null or champ = leader then raise exception 'O líder também é o melhor da última rodada: ninguém pode desafiá-lo agora.'; end if;
    if uid <> champ then raise exception 'O líder só pode ser desafiado pelo melhor da última rodada (%).', (select name from characters where user_id = champ); end if;
    forced := true;
  end if;
  if exists (select 1 from duels where challenger = uid and (created_at at time zone tz)::date = t) then raise exception 'Você já enviou um desafio hoje. Volte amanhã.'; end if;
  if exists (select 1 from duels where status in ('pendente','aceito') and ((challenger = uid and opponent = _opponent) or (challenger = _opponent and opponent = uid))) then
    raise exception 'Já existe um duelo entre vocês em andamento.';
  end if;
  if coalesce(_stake,0) < 1 then raise exception 'Escolha um valor para a aposta.'; end if;
  if _stake_kind = 'moedas' then
    maxc := greatest((c->>'duel_min_coins')::int, floor(me.coins * (c->>'duel_max_coin_pct')::numeric / 100)::int);
    if _stake > maxc then raise exception 'Agora você pode apostar no máximo % moedas.', maxc; end if;
    if me.coins < _stake then raise exception 'Moedas insuficientes.'; end if;
    if forced and op.coins < _stake then raise exception 'O líder só tem % moedas: aposte menos.', op.coins; end if;
    update characters set coins = coins - _stake where id = me.id;
  else
    if _stake > (c->>'duel_max_steps')::int then raise exception 'A aposta máxima é de % casas.', (c->>'duel_max_steps'); end if;
    if me.arrived_rank is not null or op.arrived_rank is not null then raise exception 'Quem já chegou ao Castelo só duela valendo moedas.'; end if;
  end if;
  insert into duels(challenger, opponent, kind, stake_kind, stake, expires_at)
  values (uid, _opponent, _kind, _stake_kind, _stake, now() + make_interval(hours => (c->>'duel_hours')::int)) returning id into nid;
  insert into event_log(user_id, kind, message) values (uid, 'duelo',
    me.name || ' desafiou ' || op.name || ' para um duelo de ' || case _kind when 'quiz' then 'quiz' else 'sorte' end || ' valendo ' || _stake || case _stake_kind when 'moedas' then ' moedas.' else ' casas.' end);
  -- duelo obrigatório: já começa aceito pelo líder (ele paga a parte dele e não pode recusar)
  if forced then
    if _stake_kind = 'moedas' then update characters set coins = coins - _stake where user_id = _opponent; end if;
    if _kind = 'quiz' then
      select p.id into pid from pokemon p join pokemon_media m on m.pokemon_id = p.id where m.silhouette is not null and public.gen_ok(p.id) order by random() limit 1;
      if pid is null then raise exception 'Duelos de quiz precisam das imagens da Pokédex. Peça ao administrador para importá-las.'; end if;
    end if;
    update duels set status = 'aceito', accepted_at = now(), pokemon_id = pid, expires_at = now() + make_interval(hours => (c->>'duel_hours')::int) where id = nid;
    insert into event_log(user_id, kind, message) values (uid, 'duelo', me.name || ', o melhor da rodada, chamou o líder ' || op.name || ' para um duelo obrigatório!');
    if _kind = 'sorte' then perform public.resolve_duel(nid); end if;
  end if;
  return nid;
end $$;

-- andar (versão do 11 + encontros com o líder só contra o melhor da rodada)
create or replace function public.do_move(_d date, _recovery boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := auth.uid(); c jsonb := public.cfg(); today date := public.game_today();
  me characters; other characters; nd board_nodes; tr traps; w jsonb; x record;
  m public.puzzle_mode; s guess_sessions; st int; modes jsonb := '{}'::jsonb;
  base int := 0; roll int; r2 int; i int; bonus int; skill_steps int := 0; total int; from_node int; landed int; path0 int;
  ev jsonb := '[]'::jsonb; sal int := 0; extra_coins int := 0; extra_xp int := 0; cls text; sv int; skill_on boolean; dodge boolean := false;
  card int; chance int; steal int; my_dist int; tmp_node int; tmp_path int[]; msg text; amt int;
  xp_gain int; coin_gain int; new_level int; old_level int;
  leader uuid; prop properties; toll int; bounty int := coalesce((public.cfg()->>'bounty_coins')::int, 60);
  boss world_bosses; mud int; passed int[]; champ uuid;
begin
  perform public.settle();
  leader := public.leader_id(); champ := public.round_champion();
  select * into me from characters where user_id = uid for update;
  if me.id is null then raise exception 'Crie seu personagem primeiro.'; end if;
  if exists (select 1 from daily_moves where user_id = uid and move_date = _d) then raise exception 'Você já andou nesse dia.'; end if;
  old_level := me.level; cls := me.class::text;
  skill_on := not _recovery and me.skill_date = today;
  sv := public.skill_value(cls, me.level);

  foreach m in array enum_range(null::public.puzzle_mode) loop
    s := null;
    select * into s from guess_sessions where user_id = uid and puzzle_date = _d and mode = m;
    st := public.mode_steps(coalesce(s.attempts,0), coalesce(s.solved,false));
    base := base + st;
    modes := modes || jsonb_build_object(m::text, jsonb_build_object('attempts', coalesce(s.attempts,0), 'solved', coalesce(s.solved,false), 'steps', st));
  end loop;

  roll := (c->>'roll_min')::int + floor(random() * ((c->>'roll_max')::int - (c->>'roll_min')::int + 1))::int;
  if skill_on and cls = 'arqueiro' then
    for i in 2..greatest(sv,2) loop
      r2 := (c->>'roll_min')::int + floor(random() * ((c->>'roll_max')::int - (c->>'roll_min')::int + 1))::int;
      roll := greatest(roll, r2);
    end loop;
    ev := ev || jsonb_build_object('t','habilidade','msg','Tiro certeiro: a roleta girou ' || greatest(sv,2) || ' vezes e ficou com ' || roll || '.');
  end if;
  if cls = 'arqueiro' and roll < (c->>'arqueiro_min_die')::int then
    roll := (c->>'arqueiro_min_die')::int;
    ev := ev || jsonb_build_object('t','arqueiro','msg','Olho de arqueiro: a roleta vale no mínimo ' || roll || '.');
  end if;
  if skill_on and cls = 'domador' then
    roll := roll * greatest(sv,2);
    ev := ev || jsonb_build_object('t','habilidade','msg','Montaria: a roleta valeu ' || greatest(sv,2) || ' vezes mais (' || roll || ').');
  end if;
  if skill_on and cls in ('guerreiro','ladino','clerigo') and sv > 0 then
    skill_steps := sv;
    ev := ev || jsonb_build_object('t','habilidade','msg',
      case cls when 'guerreiro' then 'Investida' when 'ladino' then 'Atalho' else 'Bênção' end || ': +' || sv || ' casas.');
  end if;
  if skill_on and cls = 'mago' then
    skill_steps := public.next_good_steps(me.id, sv);
    ev := ev || jsonb_build_object('t','habilidade','msg', case when skill_steps > 0 then 'Teleporte: saltou ' || skill_steps || ' casas até uma casa especial.' else 'Teleporte: nenhuma casa especial ao alcance.' end);
  end if;
  if skill_on and cls = 'ladino' then dodge := true; end if;
  if skill_on and cls = 'clerigo' then ev := ev || jsonb_build_object('t','habilidade','msg','Bênção ativa: nada te empurra para trás hoje.'); end if;

  bonus := me.bonus_steps;
  total := base + roll + bonus + skill_steps;
  -- lama da catapulta de um rival
  mud := coalesce(me.pending_mud, 0);
  if mud > 0 and not _recovery then
    update characters set pending_mud = 0 where id = me.id;
    if public.is_shielded(me.id) then
      ev := ev || jsonb_build_object('t','lama','msg','Atiraram lama em você, mas a Bênção te protegeu.');
    else
      total := greatest(0, total - mud);
      ev := ev || jsonb_build_object('t','lama','msg','Lama da catapulta: você perdeu ' || mud || ' casas nesta andada.');
    end if;
  end if;
  from_node := me.node;

  if me.arrived_rank is not null then
    ev := ev || jsonb_build_object('t','castelo','msg','Você já está no Castelo. Continue jogando para ganhar moedas, XP e vencer rodadas.');
    total := 0;
  else
    update characters set bonus_steps = 0 where id = me.id;
    path0 := coalesce(array_length(me.path,1),1);
    w := public.walk(me.id, total);
    sal := sal + (w->>'salary')::int;
    landed := (w->>'node')::int;

    -- encontro com o lendário (passando ou parando)
    select * into boss from world_bosses where status = 'ativo' order by id desc limit 1;
    if boss.id is not null then
      passed := (select path from characters where id = me.id)[path0 : coalesce(array_length((select path from characters where id = me.id),1),1)];
      if boss.node = any(passed) and not exists (select 1 from boss_contacts bc where bc.boss_id = boss.id and bc.user_id = uid) then
        insert into boss_contacts(boss_id, user_id) values (boss.id, uid);
        ev := ev || jsonb_build_object('t','lendario','msg','Você encontrou o lendário ' || (select name from pokemon where id = boss.pokemon_id) || '! Agora pode atacá-lo pelo painel.');
      end if;
    end if;

    -- Ladino: pega moedas de quem ultrapassa
    if cls = 'ladino' then
      amt := public.passive_value('ladino', me.level);
      for x in
        select ch.id, ch.name, ch.coins from characters ch
        where ch.user_id <> uid and ch.arrived_rank is null
          and ch.node = any ((select path from characters where id = me.id)[path0 + 1 : coalesce(array_length((select path from characters where id = me.id),1),1) - 1])
        for update
      loop
        steal := least(amt, x.coins);
        if steal > 0 then
          update characters set coins = coins - steal where id = x.id;
          extra_coins := extra_coins + steal;
          ev := ev || jsonb_build_object('t','ladino','msg','Mão leve: pegou ' || steal || ' moedas de ' || x.name || ' ao passar.');
        end if;
      end loop;
    end if;

    -- 1) armadilha de outro jogador
    select * into tr from traps where node = landed and triggered_at is null and owner_id <> uid for update;
    if tr.id is not null then
      update traps set triggered_by = uid, triggered_at = now() where id = tr.id;
      select * into other from characters where user_id = tr.owner_id;
      if dodge then
        ev := ev || jsonb_build_object('t','armadilha','msg','Atalho: você desviou da armadilha de ' || other.name || '.');
      elsif cls = 'mago' and random() * 100 < (c->>'mago_resist_pct')::int then
        ev := ev || jsonb_build_object('t','armadilha','msg','Você desfez com magia a armadilha de ' || other.name || '.');
      elsif public.is_shielded(me.id) then
        ev := ev || jsonb_build_object('t','armadilha','msg','A Bênção te protegeu da armadilha de ' || other.name || '.');
      else
        perform public.go_back(me.id, (c->>'trap_push')::int);
        update characters set coins = coins + (c->>'trap_reward')::int where user_id = tr.owner_id;
        ev := ev || jsonb_build_object('t','armadilha','msg','Você caiu na armadilha de ' || other.name || ' e voltou ' || (c->>'trap_push') || ' casas.');
        insert into event_log(user_id, kind, message) values (uid, 'armadilha', me.name || ' caiu na armadilha de ' || other.name || '.');
      end if;
    else
      -- 2) efeito da casa
      select * into nd from board_nodes where id = landed;
      if nd.kind = 'avanco' then
        w := public.walk(me.id, nd.value); sal := sal + (w->>'salary')::int;
        ev := ev || jsonb_build_object('t','avanco','msg','Vento a favor! Avançou mais ' || nd.value || ' casas.');
      elsif nd.kind = 'recuo' then
        if dodge then ev := ev || jsonb_build_object('t','recuo','msg','Atalho: você contornou o lamaçal.');
        elsif public.is_shielded(me.id) then ev := ev || jsonb_build_object('t','recuo','msg','A Bênção te segurou no lamaçal.');
        elsif cls = 'mago' and random() * 100 < (c->>'mago_resist_pct')::int then ev := ev || jsonb_build_object('t','recuo','msg','Escorregou, mas a magia segurou você no lugar.');
        else perform public.go_back(me.id, nd.value); ev := ev || jsonb_build_object('t','recuo','msg','Lamaçal! Voltou ' || nd.value || ' casas.');
        end if;
      elsif nd.kind = 'bau' then
        extra_coins := extra_coins + (c->>'chest_coins')::int;
        ev := ev || jsonb_build_object('t','bau','msg','Achou um baú com ' || (c->>'chest_coins') || ' moedas.');
      elsif nd.kind = 'xp' then
        extra_xp := extra_xp + (c->>'xp_square')::int;
        ev := ev || jsonb_build_object('t','xp','msg','Treino na clareira: +' || (c->>'xp_square') || ' XP.');
      elsif nd.kind = 'pagamento' then
        ev := ev || jsonb_build_object('t','pagamento','msg','Parou no Dia de pagamento.');
      elsif nd.kind = 'carta' then
        card := floor(random() * 6)::int;
        if card = 0 then
          extra_coins := extra_coins + (c->>'card_coins_win')::int;
          ev := ev || jsonb_build_object('t','carta','msg','Carta da sorte: um treinador agradecido te deu ' || (c->>'card_coins_win') || ' moedas.');
        elsif card = 1 then
          amt := (c->>'card_coins_lose')::int; if cls = 'clerigo' then amt := ceil(amt / 2.0); end if;
          extra_coins := extra_coins - amt;
          ev := ev || jsonb_build_object('t','carta','msg','Carta do azar: sua mochila rasgou e você perdeu ' || amt || ' moedas.');
        elsif card = 2 then
          w := public.walk(me.id, (c->>'card_steps')::int); sal := sal + (w->>'salary')::int;
          ev := ev || jsonb_build_object('t','carta','msg','Carta da sorte: atalho secreto! Avançou ' || (c->>'card_steps') || ' casas.');
        elsif card = 3 then
          amt := (c->>'card_steps')::int; if cls = 'clerigo' then amt := ceil(amt / 2.0); end if;
          if public.is_shielded(me.id) then ev := ev || jsonb_build_object('t','carta','msg','Carta do azar: você ia se perder, mas a Bênção te guiou.');
          else perform public.go_back(me.id, amt); ev := ev || jsonb_build_object('t','carta','msg','Carta do azar: você se perdeu e voltou ' || amt || ' casas.');
          end if;
        elsif card = 4 then
          update characters set hints = hints + 1 where id = me.id;
          ev := ev || jsonb_build_object('t','carta','msg','Carta da sorte: ganhou 1 Dica.');
        else
          update characters set retries = retries + 1 where id = me.id;
          ev := ev || jsonb_build_object('t','carta','msg','Carta da sorte: ganhou 1 Tente outra vez.');
        end if;
      elsif nd.kind = 'raio' then
        select ch.* into other from characters ch join board_nodes b on b.id = ch.node
         where ch.arrived_rank is null and ch.user_id <> uid order by b.dist asc limit 1 for update of ch;
        my_dist := (select dist from board_nodes where id = landed);
        if other.id is null or (select dist from board_nodes where id = other.node) >= my_dist then
          ev := ev || jsonb_build_object('t','raio','msg','A tempestade caiu longe: ninguém está à sua frente.');
        elsif public.is_shielded(other.id) then
          ev := ev || jsonb_build_object('t','raio','msg','Você chamou um raio em ' || other.name || ', mas a Bênção dele o protegeu.');
        elsif other.class::text = 'mago' and random() * 100 < (c->>'mago_resist_pct')::int then
          ev := ev || jsonb_build_object('t','raio','msg','Você chamou um raio em ' || other.name || ', mas a magia dele desviou.');
        else
          perform public.go_back(other.id, (c->>'storm_push')::int);
          ev := ev || jsonb_build_object('t','raio','msg','Você chamou um raio no líder ' || other.name || ': ele voltou ' || (c->>'storm_push') || ' casas.');
          insert into event_log(user_id, kind, message) values (uid, 'raio', me.name || ' derrubou um raio no líder ' || other.name || '.');
          if other.user_id = leader then
            extra_coins := extra_coins + bounty;
            ev := ev || jsonb_build_object('t','procurado','msg','Recompensa: você acertou o procurado e ganhou ' || bounty || ' moedas.');
          end if;
        end if;
      elsif nd.kind = 'troca' then
        my_dist := (select dist from board_nodes where id = landed);
        select ch.* into other from characters ch join board_nodes b on b.id = ch.node
         where ch.arrived_rank is null and ch.user_id <> uid and b.dist < my_dist order by b.dist desc limit 1 for update of ch;
        if other.id is not null and public.is_shielded(other.id) then
          ev := ev || jsonb_build_object('t','troca','msg','O portal tentou te trocar com ' || other.name || ', mas a Bênção dele impediu.');
        elsif other.id is not null then
          select node, path into tmp_node, tmp_path from characters where id = me.id;
          update characters set node = other.node, path = other.path where id = me.id;
          update characters set node = tmp_node, path = tmp_path where id = other.id;
          ev := ev || jsonb_build_object('t','troca','msg','Portal! Você trocou de lugar com ' || other.name || '.');
          insert into event_log(user_id, kind, message) values (uid, 'troca', me.name || ' trocou de lugar com ' || other.name || ' pelo portal.');
        else
          ev := ev || jsonb_build_object('t','troca','msg','O portal não encontrou ninguém à sua frente.');
        end if;
      end if;
    end if;

    -- 3) encontro na mesma casa vira duelo
    select * into me from characters where id = me.id;
    select ch.* into other from characters ch join board_nodes b on b.id = ch.node
     where ch.user_id <> uid and ch.node = me.node and ch.arrived_rank is null and b.kind not in ('inicio','castelo')
       -- com o líder, só há encontro se o outro for o melhor da última rodada (se o líder for o melhor, nada acontece)
       and (leader is null or (ch.user_id <> leader and uid <> leader) or (champ is not null and champ <> leader and champ in (uid, ch.user_id)))
     order by random() limit 1 for update of ch;
    if other.id is not null then
      chance := 50 + (me.level - other.level) * (c->>'duel_level_factor')::int
                   + case when cls = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end
                   - case when other.class::text = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end;
      chance := chance
        + case when exists (select 1 from villages where user_id = uid and arena_level > 0) then coalesce((c->>'arena_bonus')::int, 10) else 0 end
        - case when exists (select 1 from villages where user_id = other.user_id and arena_level > 0) then coalesce((c->>'arena_bonus')::int, 10) else 0 end;
      chance := greatest(25, least(75, chance));
      if random() * 100 < chance then
        steal := least((c->>'duel_coins')::int, other.coins);
        update characters set coins = coins - steal where id = other.id;
        perform public.go_back(other.id, (c->>'duel_push')::int);
        extra_coins := extra_coins + steal;
        ev := ev || jsonb_build_object('t','duelo','msg','Encontro com ' || other.name || ': você venceu o duelo, ganhou ' || steal || ' moedas' || case when public.is_shielded(other.id) then '.' else ' e empurrou o rival.' end);
        if other.user_id = leader then
          extra_coins := extra_coins + bounty;
          ev := ev || jsonb_build_object('t','procurado','msg','Recompensa: você venceu o procurado e ganhou ' || bounty || ' moedas.');
        end if;
        insert into event_log(user_id, kind, message) values (uid, 'duelo', me.name || ' venceu um duelo contra ' || other.name || '.');
      else
        steal := least((c->>'duel_coins')::int, greatest(0, me.coins + extra_coins));
        update characters set coins = coins + steal where id = other.id;
        extra_coins := extra_coins - steal;
        perform public.go_back(me.id, (c->>'duel_push')::int);
        ev := ev || jsonb_build_object('t','duelo','msg','Encontro com ' || other.name || ': você perdeu o duelo e ' || steal || ' moedas' || case when public.is_shielded(me.id) then ', mas a Bênção te manteve no lugar.' else ' e voltou ' || (c->>'duel_push') || ' casas.' end);
        insert into event_log(user_id, kind, message) values (uid, 'duelo', other.name || ' defendeu sua casa contra ' || me.name || '.');
      end if;
    end if;

    -- 4) pedágio da pousada de outro jogador
    select * into me from characters where id = me.id;
    select * into prop from properties where node = me.node and owner <> uid for update;
    if prop.node is not null then
      toll := greatest((c->>'property_min_toll')::int, ceil(prop.price * (c->>'property_toll_pct')::numeric / 100)::int);
      toll := least(toll, greatest(0, me.coins + extra_coins + base * (c->>'coins_per_step')::int));
      if toll > 0 then
        extra_coins := extra_coins - toll;
        update characters set coins = coins + toll where user_id = prop.owner;
        update properties set tolls_earned = tolls_earned + toll where node = prop.node;
        ev := ev || jsonb_build_object('t','pousada','msg','Pedágio na pousada de ' || (select name from characters where user_id = prop.owner) || ': -' || toll || ' moedas.');
        insert into event_log(user_id, kind, message) values (uid, 'pousada', me.name || ' pagou ' || toll || ' moedas de pedágio na pousada de ' || (select name from characters where user_id = prop.owner) || '.');
      end if;
    end if;
    if sal > 0 then ev := ev || jsonb_build_object('t','pagamento','msg','Dia de pagamento: +' || sal || ' moedas de salário' ||
      case when uid = public.snorlax_id() then ' (10% a menos por ser o Snorlax da rodada).' else '.' end); end if;
    msg := public.check_arrival(me.id);
    if msg is not null then ev := ev || jsonb_build_object('t','castelo','msg', msg); end if;
  end if;

  xp_gain := base * (c->>'xp_per_step')::int + (c->>'xp_daily_bonus')::int + extra_xp;
  if (select xp_buff_until from characters where id = me.id) >= today then
    xp_gain := round(xp_gain * coalesce((c->>'boss_xp_mult')::numeric, 1.5))::int;
    ev := ev || jsonb_build_object('t','buff','msg','Bênção do lendário derrotado: XP aumentado.');
  end if;
  coin_gain := base * (c->>'coins_per_step')::int + extra_coins;
  select * into me from characters where id = me.id;
  new_level := public.level_for_xp(me.xp_total + xp_gain);
  if new_level > old_level then
    ev := ev || jsonb_build_object('t','nivel','msg','Subiu para o nível ' || new_level || '!');
    insert into event_log(user_id, kind, message) values (uid, 'nivel', me.name || ' chegou ao nível ' || new_level || '.');
  end if;
  update characters set xp_total = xp_total + xp_gain, level = new_level,
         coins = greatest(0, coins + coin_gain), last_move_date = greatest(coalesce(last_move_date, _d), _d)
   where id = me.id returning * into me;

  insert into daily_moves(user_id, move_date, modes, base_steps, roll, bonus_steps, skill_steps, from_node, to_node, xp_gained, coins_gained, events, recovered)
  values (uid, _d, modes, base, roll, bonus, skill_steps, from_node, me.node, xp_gain, coin_gain + sal, ev, _recovery);
  insert into event_log(user_id, kind, message, data)
  values (uid, 'andou', me.name || ' andou ' || total || ' casas' || case when _recovery then ' recuperando o dia ' || to_char(_d, 'DD/MM') else '' end || '.', jsonb_build_object('steps', total));

  return jsonb_build_object('date', _d, 'recovery', _recovery, 'base', base, 'roll', roll, 'bonus', bonus, 'skill', skill_steps, 'total', total, 'modes', modes,
    'from', from_node, 'to', me.node, 'path', to_jsonb(me.path), 'events', ev,
    'xp', xp_gain, 'coins', coin_gain + sal, 'level', new_level, 'leveled', new_level > old_level);
end $$;

-- ---------- permissões ----------
revoke execute on function public.round_champion() from public, anon;
grant execute on function public.round_champion() to authenticated;   -- o site mostra quem pode desafiar o líder
