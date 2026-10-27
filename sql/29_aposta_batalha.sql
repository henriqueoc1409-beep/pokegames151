-- =====================================================================
-- POKEGAMES — Aposta obrigatória nas batalhas Pokémon 3x3 (pedido do dono em 21/10/2026).
--   * quem desafia escolhe o valor (padrão de 10 a 100 moedas; o admin muda em
--     game_config: battle_bet_min e battle_bet_max, também na aba Regras);
--   * os dois precisam ter o valor; as moedas saem dos dois quando o desafio é ACEITO
--     e ficam guardadas na batalha (recusar ou cancelar não custa nada);
--   * quem vence leva tudo (as duas partes); empate devolve a parte de cada um;
--     desistir conta como derrota;
--   * o pagamento acontece uma única vez (bet_paid_out), no fim da batalha;
--   * batalhas que já estavam abertas antes deste arquivo continuam sem aposta;
--   * guerras entre vilas não têm aposta (continuam com o saque do arquivo 25).
-- Não muda o motor de batalha nem o XP. Depende do 18, 24 e 25. Antes, faça a cópia de segurança.
-- =====================================================================
alter table public.battles add column if not exists bet int not null default 0 check (bet >= 0);
alter table public.battles add column if not exists bet_paid boolean not null default false;      -- moedas dos dois já guardadas
alter table public.battles add column if not exists bet_paid_out boolean not null default false;  -- prêmio já entregue
alter table public.arena_battles add column if not exists bet int not null default 0;
update public.game_config set config = config || '{"battle_bet_min": 10, "battle_bet_max": 100}'::jsonb where active and not (config ? 'battle_bet_max');

-- a versão antiga (sem valor) agora só explica que a aposta é obrigatória
create or replace function public.battle_challenge(_opponent uuid) returns public.battles
language plpgsql security definer set search_path = public, extensions as $$
begin
  raise exception 'Agora toda batalha Pokémon tem aposta. Atualize a página (Ctrl+F5) e escolha o valor.';
end $$;

-- desafiar (versão do 18 + valor da aposta)
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
  select coins into mc from characters where user_id = uid;
  select coins into oc from characters where user_id = _opponent;
  if mc < _bet then raise exception 'Você não tem % moedas para apostar.', _bet; end if;
  if oc < _bet then raise exception 'Esse jogador só tem % moedas: aposte menos.', oc; end if;
  insert into battles(p1, p2, size, bet) values (uid, _opponent, (c->>'size')::int, _bet) returning * into b;
  select name into nm from characters where user_id = uid;
  insert into event_log(user_id, kind, message) select uid, 'batalha', nm || ' desafiou ' || ch.name || ' para uma batalha Pokémon valendo ' || _bet || ' moedas!' from characters ch where ch.user_id = _opponent;
  return b;
end $$;

-- responder (versão do 18 + guarda as moedas dos dois ao aceitar)
create or replace function public.battle_respond(_id uuid, _accept boolean) returns public.battles
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); b battles; c jsonb := public.pk_cfg()->'battle'; s1 jsonb; s2 jsonb; c1 int; c2 int;
begin
  select * into b from battles where id = _id for update;
  if b.id is null or b.p2 <> uid then raise exception 'Convite não encontrado.'; end if;
  if b.status <> 'convite' then raise exception 'Esse convite já foi respondido.'; end if;
  if not _accept then update battles set status = 'recusada', ended_at = now() where id = b.id returning * into b; return b; end if;
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
    if c1 < b.bet then raise exception 'O desafiante não tem mais as % moedas da aposta.', b.bet; end if;
    update characters set coins = coins - b.bet where user_id in (b.p1, b.p2);
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

-- encerramento (versão do 25 + paga a aposta uma única vez)
create or replace function public.bt_finish(_id uuid, _winner uuid, _reason text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b battles; c jsonb := public.pk_cfg(); k text; v int; owner uuid; limit_n int := (c->'xp'->>'battles_per_day')::int; wn text; ln text;
begin
  select * into b from battles where id = _id for update;
  if b.status <> 'ativa' then return; end if;
  update battles set status = 'encerrada', winner = _winner, end_reason = _reason, ended_at = now(), deadline = null where id = b.id;
  -- aposta: quem vence leva as duas partes; empate devolve a de cada um (uma única vez)
  if b.bet > 0 and b.bet_paid and not b.bet_paid_out then
    if _winner is null then update characters set coins = coins + b.bet where user_id in (b.p1, b.p2);
    else update characters set coins = coins + 2 * b.bet where user_id = _winner; end if;
    update battles set bet_paid_out = true where id = b.id;
  end if;
  if b.rewarded then return; end if;
  -- XP dos Pokémon que derrubaram adversários, só nas primeiras batalhas do dia de cada dono (guerras contam no mesmo limite)
  for k, v in select key, value::int from jsonb_each_text(coalesce(b.state->'xp', '{}'::jsonb)) loop
    select user_id into owner from monsters where id = k::uuid;
    if owner is null then continue; end if;
    if (select count(*) from battles x where x.status = 'encerrada' and x.rewarded and owner in (x.p1, x.p2)
          and (x.ended_at at time zone coalesce(public.cfg()->>'timezone','America/Sao_Paulo'))::date = public.game_today()) >= limit_n then continue; end if;
    perform public.pk_give_xp(k::uuid, v, 'batalha');
  end loop;
  update battles set rewarded = true where id = b.id;
  if b.mode = 'guerra' then return; end if;
  select name into wn from characters where user_id = _winner;
  select name into ln from characters where user_id = case when _winner = b.p1 then b.p2 else b.p1 end;
  if _winner is not null then insert into event_log(user_id, kind, message) values (_winner, 'batalha', wn || ' venceu a batalha Pokémon contra ' || ln || case when b.bet > 0 and b.bet_paid then ' e levou ' || 2 * b.bet || ' moedas' else '' end || '!'); end if;
end $$;

-- resumo público da Arena (versão do 24 + mostra quanto está em jogo)
create or replace function public.arena_sync(_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b battles; s jsonb; a0 jsonb; a1 jsonb; ln text; tm jsonb;
begin
  select * into b from battles where id = _id;
  if b.id is null then return; end if;
  if b.status not in ('ativa', 'encerrada') then delete from arena_battles where battle_id = b.id; return; end if;
  s := b.state;
  a0 := s->'sides'->0->'mons'->((s->'sides'->0->>'active')::int);
  a1 := s->'sides'->1->'mons'->((s->'sides'->1->>'active')::int);
  select l->>'txt' into ln from jsonb_array_elements(coalesce(b.log->-1->'lines', '[]'::jsonb)) with ordinality x(l, o) order by o desc limit 1;
  if b.status = 'encerrada' then
    select jsonb_agg(jsonb_build_object('user', sd->'user', 'mons',
             (select jsonb_agg(jsonb_build_object('species', m->'species', 'name', m->'name', 'level', m->'level', 'out', (m->>'hp')::int <= 0)) from jsonb_array_elements(sd->'mons') m)))
      into tm from jsonb_array_elements(s->'sides') sd;
  end if;
  insert into arena_battles as a (battle_id, p1, p2, name1, name2, status, turn, phase, wait1, wait2, mon1, mon2, left1, left2, size,
                                  last_line, turn_at, acted_at, away1, away2, winner, end_reason, teams, started_at, ended_at, updated_at, bet)
  values (b.id, b.p1, b.p2, s->'sides'->0->>'name', s->'sides'->1->>'name', b.status, b.turn, b.phase,
          b.status = 'ativa' and not b.ready1, b.status = 'ativa' and not b.ready2,
          public.arena_mon(a0), public.arena_mon(a1),
          (select count(*) from jsonb_array_elements(s->'sides'->0->'mons') m where (m->>'hp')::int > 0),
          (select count(*) from jsonb_array_elements(s->'sides'->1->'mons') m where (m->>'hp')::int > 0),
          jsonb_array_length(coalesce(s->'sides'->0->'mons', '[]'::jsonb)),
          ln, b.turn_at, b.acted_at, b.away1, b.away2, b.winner, b.end_reason, tm, b.started_at, b.ended_at, now(), b.bet)
  on conflict (battle_id) do update set status = excluded.status, turn = excluded.turn, phase = excluded.phase, wait1 = excluded.wait1, wait2 = excluded.wait2,
    mon1 = excluded.mon1, mon2 = excluded.mon2, left1 = excluded.left1, left2 = excluded.left2, size = excluded.size, last_line = excluded.last_line,
    turn_at = excluded.turn_at, acted_at = excluded.acted_at, away1 = excluded.away1, away2 = excluded.away2, winner = excluded.winner,
    end_reason = excluded.end_reason, teams = excluded.teams, started_at = excluded.started_at, ended_at = excluded.ended_at, updated_at = now(), bet = excluded.bet;
end $$;

-- ---------- permissões ----------
revoke execute on function public.battle_challenge(uuid, int) from public, anon;
grant execute on function public.battle_challenge(uuid, int) to authenticated;
