-- =====================================================================
-- POKEGAMES — Desempate justo nos duelos de quiz (pedido do dono).
-- Antes: com o mesmo número de tentativas, vencia quem terminou primeiro
-- no relógio (ou seja, quase sempre quem jogou primeiro no dia).
-- Agora: vence quem levou MENOS TEMPO entre abrir o duelo e terminar.
-- O cronômetro de cada jogador começa quando ele abre o duelo já aceito.
-- Duelos começados antes deste arquivo continuam com a regra antiga.
-- Só muda o desempate; tentativas, apostas e prêmios continuam iguais.
-- Rode depois do 22. Antes, faça a cópia de segurança.
-- =====================================================================
alter table public.duels add column if not exists c_started_at timestamptz;
alter table public.duels add column if not exists o_started_at timestamptz;

create or replace function public.duel_state(_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); d duels; side text; mine int; img text;
begin
  perform public.expire_duels();
  select * into d from duels where id = _id;
  if d.id is null or uid not in (d.challenger, d.opponent) then raise exception 'Duelo não encontrado.'; end if;
  side := case when uid = d.challenger then 'c' else 'o' end;
  -- o cronômetro de cada um começa na primeira vez que abre o duelo aceito
  if d.status = 'aceito' and d.kind = 'quiz' then
    if side = 'c' and d.c_started_at is null and d.c_done_at is null then update duels set c_started_at = now() where id = d.id returning * into d;
    elsif side = 'o' and d.o_started_at is null and d.o_done_at is null then update duels set o_started_at = now() where id = d.id returning * into d; end if;
  end if;
  mine := case side when 'c' then d.c_attempts else d.o_attempts end;
  if d.kind = 'quiz' and d.pokemon_id is not null then select silhouette into img from pokemon_media where pokemon_id = d.pokemon_id; end if;
  return jsonb_build_object('id', d.id, 'kind', d.kind, 'stake_kind', d.stake_kind, 'stake', d.stake, 'status', d.status,
    'challenger', d.challenger, 'opponent', d.opponent, 'expires_at', d.expires_at, 'winner', d.winner, 'result', d.result,
    'max_guesses', (cfg()->>'duel_quiz_max_guesses')::int,
    'me', jsonb_build_object('attempts', mine, 'solved', case side when 'c' then d.c_solved else d.o_solved end,
                             'done', case side when 'c' then d.c_done_at is not null else d.o_done_at is not null end),
    'other_done', case side when 'c' then d.o_done_at is not null else d.c_done_at is not null end,
    'my_seconds', case side when 'c' then extract(epoch from coalesce(d.c_done_at, now()) - d.c_started_at) else extract(epoch from coalesce(d.o_done_at, now()) - d.o_started_at) end,
    'other_seconds', case when d.status = 'concluido' then case side when 'c' then extract(epoch from d.o_done_at - d.o_started_at) else extract(epoch from d.c_done_at - d.c_started_at) end end,
    'other_attempts', case when d.status = 'concluido' then case side when 'c' then d.o_attempts else d.c_attempts end end,
    'clue', case when img is not null then jsonb_build_object('image', img, 'zoom_step', mine) end,
    'answer', case when d.status = 'concluido' and d.pokemon_id is not null then (select jsonb_build_object('id', id, 'name', name) from pokemon where id = d.pokemon_id) end,
    'guesses', coalesce((select jsonb_agg(jsonb_build_object('pokemon_id', pokemon_id, 'correct', correct) order by id) from duel_guesses where duel_id = d.id and user_id = uid), '[]'::jsonb));
end $$;

create or replace function public.resolve_duel(_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare ct interval; ot interval; d duels; c jsonb := cfg(); w uuid; l uuid; cs int; os int; ch characters; op characters; chance int; leader uuid := public.leader_id(); bounty int := coalesce((cfg()->>'bounty_coins')::int, 60);
  wc characters; lc characters; msg text; what text;
begin
  select * into d from duels where id = _id for update;
  if d.status <> 'aceito' then return; end if;
  select * into ch from characters where user_id = d.challenger for update;
  select * into op from characters where user_id = d.opponent for update;
  if d.kind = 'quiz' then
    cs := case when d.c_solved then d.c_attempts else 99 end;
    os := case when d.o_solved then d.o_attempts else 99 end;
    if cs < os then w := d.challenger;
    elsif os < cs then w := d.opponent;
    elsif cs = 99 then w := null;
    else
      -- empate em tentativas: vence quem levou MENOS TEMPO entre abrir o duelo e terminar
      -- (sem a hora de início, que só existe a partir deste arquivo, vale a regra antiga: quem terminou antes)
      ct := case when d.c_started_at is not null then d.c_done_at - d.c_started_at end;
      ot := case when d.o_started_at is not null then d.o_done_at - d.o_started_at end;
      if ct is not null and ot is not null and ct <> ot then w := case when ct < ot then d.challenger else d.opponent end;
      else w := case when coalesce(d.c_done_at, 'infinity') <= coalesce(d.o_done_at, 'infinity') then d.challenger else d.opponent end;
      end if;
    end if;
  else
    chance := 50 + (ch.level - op.level) * (c->>'duel_level_factor')::int
                 + case when ch.class::text = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end
                 - case when op.class::text = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end;
    chance := greatest(25, least(75, chance));
    w := case when random() * 100 < chance then d.challenger else d.opponent end;
  end if;
  what := case d.stake_kind when 'moedas' then d.stake || ' moedas' else d.stake || ' casas' end;
  if w is null then
    if d.stake_kind = 'moedas' then
      update characters set coins = coins + d.stake where user_id in (d.challenger, d.opponent);
    end if;
    msg := 'Duelo entre ' || ch.name || ' e ' || op.name || ' terminou sem vencedor. Ninguém acertou o Pokémon.';
  else
    l := case when w = d.challenger then d.opponent else d.challenger end;
    select * into wc from characters where user_id = w;
    select * into lc from characters where user_id = l;
    if d.stake_kind = 'moedas' then
      update characters set coins = coins + 2 * d.stake where user_id = w;
    else
      if wc.arrived_rank is null then perform public.walk(wc.id, d.stake); perform public.check_arrival(wc.id); end if;
      if lc.arrived_rank is null then perform public.go_back(lc.id, d.stake); end if;
    end if;
    msg := wc.name || ' venceu o duelo contra ' || lc.name || ' e levou ' || what || '.';
    if l = leader then
      update characters set coins = coins + bounty where user_id = w;
      msg := msg || ' Venceu o procurado e ganhou mais ' || bounty || ' moedas de recompensa!';
    end if;
  end if;
  update duels set status = 'concluido', winner = w, result = msg, resolved_at = now() where id = _id;
  insert into event_log(user_id, kind, message) values (coalesce(w, d.challenger), 'duelo', msg);
end $$;

revoke execute on function public.resolve_duel(uuid) from public, anon, authenticated;
revoke execute on function public.duel_state(uuid) from public, anon;
grant execute on function public.duel_state(uuid) to authenticated;
