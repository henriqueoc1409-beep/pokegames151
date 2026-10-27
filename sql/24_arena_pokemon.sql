-- =====================================================================
-- POKEGAMES — Arena Pokémon pública, torcida e cobrança de jogada.
--
-- O que este arquivo faz (pedido do dono em 21/10/2026):
--   * acaba o prazo por turno das batalhas: ninguém perde por demora,
--     nada é jogado sozinho e "reivindicar vitória por tempo" deixa de existir;
--   * cria o resumo público de cada batalha (arena_battles), que todos podem
--     ver e que chega ao vivo pelo Realtime, sem mostrar o que é segredo
--     (a ação escolhida no turno e os Pokémon que ainda não entraram em campo);
--   * arena_battle(id): a batalha vista de fora (vida, turno e relato);
--   * torcida (arena_fans), mensagens e reações (arena_cheers) e o botão
--     "Cobrar jogada" (arena_nudges), com limites contra spam;
--   * o duelista pode avisar "volto mais tarde" (sem cobranças por 12 h);
--   * o admin apaga mensagens e pode silenciar alguém na Arena.
-- As regras de combate (dano, turnos, vida, XP) NÃO mudam.
-- Depende do 15 (chat) e do 16, 17 e 18 (Pokémon). Não apaga nenhum dado.
-- Antes de rodar, faça a cópia de segurança.
-- =====================================================================

-- ---------- 1) sem prazo por turno ----------
alter table public.battles add column if not exists turn_at timestamptz;   -- desde quando o turno atual espera
alter table public.battles add column if not exists acted_at timestamptz;  -- última jogada de alguém
alter table public.battles add column if not exists away1 timestamptz;     -- "volto mais tarde" de cada lado (até quando)
alter table public.battles add column if not exists away2 timestamptz;

-- quando o turno muda, marca a hora; o prazo antigo fica sempre vazio
create or replace function public.bt_stamp() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  new.deadline := null;
  if tg_op = 'INSERT' or new.turn is distinct from old.turn or new.status is distinct from old.status then new.turn_at := now(); end if;
  if tg_op = 'UPDATE' and (new.ready1 and not old.ready1 or new.ready2 and not old.ready2 or new.turn is distinct from old.turn) then new.acted_at := now(); end if;
  return new;
end $$;
drop trigger if exists bt_stamp on public.battles;
create trigger bt_stamp before insert or update on public.battles for each row execute function public.bt_stamp();
update public.battles set deadline = null, turn_at = coalesce(turn_at, started_at, created_at) where deadline is not null or turn_at is null;

-- a função antiga continua existindo (sites antigos ainda a chamam), mas não encerra mais nada
create or replace function public.battle_claim(_id uuid) returns public.battles
language plpgsql security definer set search_path = public, extensions as $$
begin
  raise exception 'As batalhas não têm mais prazo por turno: ninguém perde por demora. Cobre a jogada pela Arena!';
end $$;

-- ---------- 2) resumo público de cada batalha ----------
create table if not exists public.arena_battles (
  battle_id  uuid primary key references public.battles(id) on delete cascade,
  p1         uuid not null,
  p2         uuid not null,
  name1      text,
  name2      text,
  status     text not null,
  turn       int not null default 0,
  phase      text,
  wait1      boolean not null default false,   -- falta o lado 1 jogar
  wait2      boolean not null default false,
  mon1       jsonb,                            -- Pokémon em campo (espécie, nome, nível, vida, estado)
  mon2       jsonb,
  left1      int, left2 int, size int,          -- quantos ainda de pé
  last_line  text,                             -- último acontecimento do relato
  turn_at    timestamptz,
  acted_at   timestamptz,
  away1      timestamptz, away2 timestamptz,
  winner     uuid,
  end_reason text,
  teams      jsonb,                            -- só depois do fim: todos os Pokémon de cada lado
  started_at timestamptz,
  ended_at   timestamptz,
  updated_at timestamptz not null default now()
);
create index if not exists arena_battles_status on public.arena_battles (status, ended_at desc);

create or replace function public.arena_mon(_m jsonb) returns jsonb
language sql immutable as $$
  select case when _m is null then null else jsonb_build_object('species', _m->'species', 'name', _m->'name', 'level', _m->'level',
    'hp', greatest(0, (_m->>'hp')::int), 'maxhp', _m->'maxhp', 'status', _m->'status', 'outfit', coalesce(_m->'outfit', '{}'::jsonb)) end
$$;

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
                                  last_line, turn_at, acted_at, away1, away2, winner, end_reason, teams, started_at, ended_at, updated_at)
  values (b.id, b.p1, b.p2, s->'sides'->0->>'name', s->'sides'->1->>'name', b.status, b.turn, b.phase,
          b.status = 'ativa' and not b.ready1, b.status = 'ativa' and not b.ready2,
          public.arena_mon(a0), public.arena_mon(a1),
          (select count(*) from jsonb_array_elements(s->'sides'->0->'mons') m where (m->>'hp')::int > 0),
          (select count(*) from jsonb_array_elements(s->'sides'->1->'mons') m where (m->>'hp')::int > 0),
          jsonb_array_length(coalesce(s->'sides'->0->'mons', '[]'::jsonb)),
          ln, b.turn_at, b.acted_at, b.away1, b.away2, b.winner, b.end_reason, tm, b.started_at, b.ended_at, now())
  on conflict (battle_id) do update set status = excluded.status, turn = excluded.turn, phase = excluded.phase, wait1 = excluded.wait1, wait2 = excluded.wait2,
    mon1 = excluded.mon1, mon2 = excluded.mon2, left1 = excluded.left1, left2 = excluded.left2, size = excluded.size, last_line = excluded.last_line,
    turn_at = excluded.turn_at, acted_at = excluded.acted_at, away1 = excluded.away1, away2 = excluded.away2, winner = excluded.winner,
    end_reason = excluded.end_reason, teams = excluded.teams, started_at = excluded.started_at, ended_at = excluded.ended_at, updated_at = now();
end $$;

create or replace function public.bt_arena_trigger() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.arena_sync(new.id);
  return null;
end $$;
drop trigger if exists bt_arena on public.battles;
create trigger bt_arena after insert or update on public.battles for each row execute function public.bt_arena_trigger();

-- preenche o resumo das batalhas que já existem
do $$ declare r record; begin
  for r in select id from public.battles where status in ('ativa', 'encerrada') loop perform public.arena_sync(r.id); end loop;
end $$;

-- ---------- 3) torcida, mensagens, reações e cobranças ----------
create table if not exists public.arena_fans (
  battle_id  uuid not null references public.battles(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  side       int not null check (side in (0, 1)),
  created_at timestamptz not null default now(),
  primary key (battle_id, user_id)
);

create table if not exists public.arena_cheers (
  id         bigint generated always as identity primary key,
  battle_id  uuid not null references public.battles(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  name       text not null,
  kind       text not null check (kind in ('msg', 'reacao', 'cobrar', 'aviso')),
  side       int check (side in (0, 1)),          -- para quem é (torcida ou cobrança)
  body       text not null,
  created_at timestamptz not null default now()
);
create index if not exists arena_cheers_battle on public.arena_cheers (battle_id, created_at desc);
create index if not exists arena_cheers_user on public.arena_cheers (user_id, created_at desc);

-- uma cobrança por pessoa por turno (é o que vira "7 jogadores estão esperando")
create table if not exists public.arena_nudges (
  battle_id  uuid not null references public.battles(id) on delete cascade,
  turn       int not null,
  side       int not null check (side in (0, 1)),
  user_id    uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (battle_id, turn, side, user_id)
);

-- silenciados na Arena pelo admin
create table if not exists public.arena_mutes (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  until      timestamptz not null,
  reason     text,
  created_at timestamptz not null default now()
);

alter table public.arena_battles enable row level security;
alter table public.arena_fans enable row level security;
alter table public.arena_cheers enable row level security;
alter table public.arena_nudges enable row level security;
alter table public.arena_mutes enable row level security;
drop policy if exists p_arena on public.arena_battles; create policy p_arena on public.arena_battles for select to authenticated using (true);
drop policy if exists p_afans on public.arena_fans;   create policy p_afans on public.arena_fans for select to authenticated using (true);
drop policy if exists p_acheer on public.arena_cheers; create policy p_acheer on public.arena_cheers for select to authenticated using (true);
drop policy if exists p_anudge on public.arena_nudges; create policy p_anudge on public.arena_nudges for select to authenticated using (true);
drop policy if exists p_amute on public.arena_mutes;  create policy p_amute on public.arena_mutes for select to authenticated using (user_id = auth.uid() or public.is_admin());
revoke all on public.arena_battles, public.arena_fans, public.arena_cheers, public.arena_nudges, public.arena_mutes from anon, authenticated;
grant select on public.arena_battles, public.arena_fans, public.arena_cheers, public.arena_nudges, public.arena_mutes to authenticated;
do $$ begin
  begin alter publication supabase_realtime add table public.arena_battles; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.arena_cheers; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.arena_fans; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.arena_nudges; exception when duplicate_object then null; end;
end $$;

-- confere se a pessoa pode falar na Arena (silêncio do admin e limite de frequência)
create or replace function public.arena_guard(_uid uuid) returns characters
language plpgsql security definer set search_path = public, extensions as $$
declare me characters; mu arena_mutes;
begin
  select * into me from characters where user_id = _uid;
  if me.id is null then raise exception 'Crie seu herói antes de usar a Arena.'; end if;
  select * into mu from arena_mutes where user_id = _uid and until > now();
  if mu.user_id is not null then raise exception 'O administrador silenciou você na Arena até %.', to_char(mu.until at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'); end if;
  if exists (select 1 from arena_cheers c where c.user_id = _uid and c.created_at > now() - interval '3 seconds') then
    raise exception 'Calma! Espere alguns segundos.'; end if;
  if (select count(*) from arena_cheers c where c.user_id = _uid and c.created_at > now() - interval '1 minute') >= 10 then
    raise exception 'Muitas mensagens seguidas na Arena. Espere um minuto.'; end if;
  return me;
end $$;

-- reações rápidas permitidas (o site mostra os mesmos botões)
create or replace function public.arena_reactions() returns text[]
language sql immutable as $$
  select array['Bora atacar!', 'Estamos esperando!', 'Vai, treinador!', 'Que batalha!', 'Finaliza logo!', 'Boa jogada!', 'Não desiste!', '🔥', '👏', '😱', '😂', '💪']
$$;

-- _kind: 'msg' (texto livre, até 120 letras) ou 'reacao' (uma das reações prontas). _side: para quem (opcional).
create or replace function public.arena_cheer(_battle uuid, _kind text, _body text, _side int default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters; b battles; txt text := btrim(coalesce(_body, '')); r arena_cheers; norm text; flat text; p record;
begin
  me := public.arena_guard(uid);
  select * into b from battles where id = _battle;
  if b.id is null or b.status not in ('ativa', 'encerrada') then raise exception 'Batalha não encontrada.'; end if;
  if b.status = 'encerrada' and b.ended_at < now() - interval '2 days' then raise exception 'Essa batalha já acabou faz tempo.'; end if;
  if _side is not null and _side not in (0, 1) then raise exception 'Lado inválido.'; end if;
  if _kind = 'reacao' then
    if not txt = any(public.arena_reactions()) then raise exception 'Reação inválida.'; end if;
  elsif _kind = 'msg' then
    if txt = '' then raise exception 'Escreva alguma coisa.'; end if;
    if char_length(txt) > 120 then raise exception 'A mensagem pode ter no máximo 120 letras.'; end if;
    -- mesma regra do chat: sem a resposta do desafio de hoje enquanto o ranking estiver travado
    if not public.day_released(public.game_today()) then
      norm := public.chat_norm(txt); flat := replace(norm, ' ', '');
      for p in select pk.name from daily_puzzles dp join pokemon pk on pk.id = dp.pokemon_id where dp.puzzle_date = public.game_today() loop
        if position(public.chat_norm(p.name) in norm) > 0
           or (char_length(replace(public.chat_norm(p.name), ' ', '')) >= 5 and position(replace(public.chat_norm(p.name), ' ', '') in flat) > 0) then
          raise exception 'Sem spoiler! A mensagem tem a resposta de um desafio de hoje.';
        end if;
      end loop;
    end if;
  else raise exception 'Tipo inválido.'; end if;
  insert into arena_cheers(battle_id, user_id, name, kind, side, body) values (b.id, uid, me.name, _kind, _side, txt) returning * into r;
  return to_jsonb(r);
end $$;

-- torcer por um lado (_side = null tira a torcida). Duelista não torce na própria batalha.
create or replace function public.arena_fan(_battle uuid, _side int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); b battles; me characters;
begin
  select * into b from battles where id = _battle;
  if b.id is null or b.status <> 'ativa' then raise exception 'Só dá para torcer em batalha em andamento.'; end if;
  if uid in (b.p1, b.p2) then raise exception 'Você está nessa batalha: a torcida é para quem assiste.'; end if;
  if _side is null then delete from arena_fans where battle_id = b.id and user_id = uid; return; end if;
  if _side not in (0, 1) then raise exception 'Lado inválido.'; end if;
  select * into me from characters where user_id = uid;
  if not exists (select 1 from arena_fans where battle_id = b.id and user_id = uid and side = _side) then
    insert into arena_fans(battle_id, user_id, side) values (b.id, uid, _side)
      on conflict (battle_id, user_id) do update set side = excluded.side, created_at = now();
  end if;
end $$;

-- "Cobrar jogada": social, sem nenhuma punição.
--   * só cobra quem está devendo a jogada do turno atual;
--   * só depois de 10 minutos de espera e se a pessoa não avisou "volto mais tarde";
--   * cada pessoa cobra no máximo 1 vez por turno, e no máximo 1 cobrança a cada 10 minutos na mesma batalha;
--   * as cobranças do turno viram um número só ("7 jogadores estão esperando").
create or replace function public.arena_nudge(_battle uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); b battles; me characters; tgt int; nm text; n int;
begin
  select * into b from battles where id = _battle;
  if b.id is null or b.status <> 'ativa' then raise exception 'Essa batalha não está em andamento.'; end if;
  select * into me from characters where user_id = uid;
  if me.id is null then raise exception 'Crie seu herói antes de usar a Arena.'; end if;
  if exists (select 1 from arena_mutes where user_id = uid and until > now()) then raise exception 'O administrador silenciou você na Arena.'; end if;
  -- quem está devendo
  if not b.ready1 and not b.ready2 then
    if uid = b.p1 then tgt := 1; elsif uid = b.p2 then tgt := 0;
    else raise exception 'Os dois treinadores ainda estão escolhendo. Dá para cobrar quando um deles já tiver jogado.'; end if;
  elsif not b.ready1 then tgt := 0;
  elsif not b.ready2 then tgt := 1;
  else raise exception 'Ninguém está devendo jogada agora.'; end if;
  if (tgt = 0 and uid = b.p1) or (tgt = 1 and uid = b.p2) then raise exception 'A vez é sua! Faça a sua jogada.'; end if;
  nm := b.state->'sides'->tgt->>'name';
  if coalesce(b.turn_at, b.started_at) > now() - interval '10 minutes' then raise exception 'Calma: o turno começou agora. Dá para cobrar depois de 10 minutos de espera.'; end if;
  if (case when tgt = 0 then b.away1 else b.away2 end) > now() then raise exception '% avisou que volta mais tarde. Deixe uma mensagem de torcida!', nm; end if;
  if exists (select 1 from arena_nudges where battle_id = b.id and turn = b.turn and side = tgt and user_id = uid) then
    raise exception 'Você já cobrou essa jogada. % vai ver!', nm; end if;
  if exists (select 1 from arena_nudges where battle_id = b.id and user_id = uid and created_at > now() - interval '10 minutes') then
    raise exception 'Você cobrou há pouco. Espere 10 minutos.'; end if;
  insert into arena_nudges(battle_id, turn, side, user_id) values (b.id, b.turn, tgt, uid);
  select count(*) into n from arena_nudges where battle_id = b.id and turn = b.turn and side = tgt;
  return jsonb_build_object('side', tgt, 'name', nm, 'count', n);
end $$;

-- duelista avisa "volto mais tarde" (até 12 h sem cobranças) ou desfaz o aviso
create or replace function public.arena_away(_battle uuid, _on boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); b battles; v timestamptz := case when _on then now() + interval '12 hours' end;
begin
  select * into b from battles where id = _battle for update;
  if b.id is null or b.status <> 'ativa' or uid not in (b.p1, b.p2) then raise exception 'Batalha não encontrada.'; end if;
  if uid = b.p1 then update battles set away1 = v where id = b.id; else update battles set away2 = v where id = b.id; end if;
  if _on then
    insert into arena_cheers(battle_id, user_id, name, kind, side, body)
    values (b.id, uid, (select name from characters where user_id = uid), 'aviso', case when uid = b.p1 then 0 else 1 end, 'Avisou que volta mais tarde para jogar.');
  end if;
end $$;

-- a batalha vista de fora: vida, turno, relato. Não mostra a ação escolhida no turno
-- nem os Pokémon que ainda não entraram em campo (só quantos são).
create or replace function public.arena_battle(_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); b battles; s jsonb; sides jsonb := '[]'::jsonb; i int; sd jsonb; seen int[]; mons jsonb; k int; m jsonb;
begin
  select * into b from battles where id = _id;
  if b.id is null or b.status not in ('ativa', 'encerrada') then raise exception 'Batalha não encontrada.'; end if;
  s := b.state;
  for i in 0 .. 1 loop
    sd := s->'sides'->i;
    -- quem já entrou em campo: o primeiro e todo mundo que aparece numa troca no relato
    select array_agg(distinct x) into seen from (
      select 0 as x
      union select (l->>'switch')::int from jsonb_array_elements(b.log) t, jsonb_array_elements(t->'lines') l where (l->>'side')::int = i and l ? 'switch') q;
    mons := '[]'::jsonb;
    for k in 0 .. jsonb_array_length(sd->'mons') - 1 loop
      m := sd->'mons'->k;
      if b.status = 'encerrada' or k = any(seen) or k = (sd->>'active')::int then
        mons := mons || jsonb_build_array(public.arena_mon(m) || jsonb_build_object('known', true));
      else
        mons := mons || jsonb_build_array(jsonb_build_object('known', false, 'out', (m->>'hp')::int <= 0));
      end if;
    end loop;
    sides := sides || jsonb_build_object('user', sd->'user', 'name', sd->'name', 'active', sd->'active', 'need_switch', sd->'need_switch', 'mons', mons);
  end loop;
  return jsonb_build_object('id', b.id, 'p1', b.p1, 'p2', b.p2, 'status', b.status, 'turn', b.turn, 'phase', b.phase,
    'ready1', b.ready1, 'ready2', b.ready2, 'turn_at', b.turn_at, 'acted_at', b.acted_at, 'away1', b.away1, 'away2', b.away2,
    'winner', b.winner, 'end_reason', b.end_reason, 'started_at', b.started_at, 'ended_at', b.ended_at,
    'state', jsonb_build_object('sides', sides), 'log', b.log);
end $$;

-- ---------- 4) moderação do admin ----------
create or replace function public.arena_cheer_delete(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active();
begin
  if not public.is_admin() then raise exception 'Só o administrador pode apagar mensagens da Arena.'; end if;
  insert into admin_audit_log(admin_id, action, target, before) select uid, 'arena_apagar', _id::text, to_jsonb(c) from arena_cheers c where c.id = _id;
  delete from arena_cheers where id = _id;
end $$;

-- silencia alguém na Arena por _hours horas (0 tira o silêncio)
create or replace function public.arena_mute(_user uuid, _hours int, _reason text default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active();
begin
  if not public.is_admin() then raise exception 'Só o administrador pode silenciar alguém.'; end if;
  if coalesce(_hours, 0) <= 0 then delete from arena_mutes where user_id = _user;
  else insert into arena_mutes(user_id, until, reason) values (_user, now() + make_interval(hours => _hours), _reason)
       on conflict (user_id) do update set until = excluded.until, reason = excluded.reason, created_at = now();
  end if;
  insert into admin_audit_log(admin_id, action, target, after, reason) values (uid, 'arena_silenciar', _user::text, jsonb_build_object('horas', _hours), _reason);
end $$;

-- ---------- permissões ----------
revoke execute on function public.bt_stamp(), public.arena_mon(jsonb), public.arena_sync(uuid), public.bt_arena_trigger(), public.arena_guard(uuid)
  from public, anon, authenticated;
revoke execute on function public.battle_claim(uuid), public.arena_reactions(), public.arena_cheer(uuid, text, text, int), public.arena_fan(uuid, int),
  public.arena_nudge(uuid), public.arena_away(uuid, boolean), public.arena_battle(uuid), public.arena_cheer_delete(bigint), public.arena_mute(uuid, int, text)
  from public, anon;
grant execute on function public.battle_claim(uuid), public.arena_reactions(), public.arena_cheer(uuid, text, text, int), public.arena_fan(uuid, int),
  public.arena_nudge(uuid), public.arena_away(uuid, boolean), public.arena_battle(uuid), public.arena_cheer_delete(bigint), public.arena_mute(uuid, int, text)
  to authenticated;
