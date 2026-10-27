-- =====================================================================
-- POKEGAMES — Ranking só depois que todos os ativos jogarem, lista de
-- quem já jogou e Chat dos Aventureiros.
--
-- 1) Regra nova contra spoiler (troca a do arquivo 12):
--    as jogadas, respostas e números dos outros num dia só aparecem quando
--    VOCÊ já andou naquele dia E TODOS OS JOGADORES ATIVOS também andaram.
--    Ativo = conta liberada que andou pelo menos 1 vez nos 7 dias anteriores,
--    ou que tem herói criado há menos de 7 dias (quem acabou de entrar conta).
--    Passado o prazo de recuperação (3 dias), o dia libera para todos.
--    O admin continua vendo tudo.
-- 2) day_presence: quem já jogou e quem ainda não jogou (sem mostrar números).
-- 3) Chat: tabela de mensagens, envio com limite de velocidade e bloqueio de
--    mensagens que contenham a resposta do dia (enquanto o ranking estiver
--    travado). O admin pode apagar mensagens.
-- Não muda pontos, moedas nem recompensas. Rode depois do 14.
-- Antes de rodar, faça a cópia de segurança.
-- =====================================================================

-- O jogador já terminou o dia? (andou, ou o herói nem existia naquele dia)
create or replace function public.day_done_for(_uid uuid, _d date) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from daily_moves dm where dm.user_id = _uid and dm.move_date = _d)
      or coalesce((select (ch.created_at at time zone coalesce(public.cfg()->>'timezone','America/Sao_Paulo'))::date > _d
                   from characters ch where ch.user_id = _uid), true)
$$;

-- Jogadores ativos num dia
create or replace function public.day_active(_d date) returns table (user_id uuid)
language sql stable security definer set search_path = public, extensions as $$
  select ch.user_id
  from characters ch join profiles p on p.id = ch.user_id and p.status = 'ativo'
  where (ch.created_at at time zone coalesce(public.cfg()->>'timezone','America/Sao_Paulo'))::date <= _d
    and ((ch.created_at at time zone coalesce(public.cfg()->>'timezone','America/Sao_Paulo'))::date > _d - 7
         or exists (select 1 from daily_moves dm where dm.user_id = ch.user_id and dm.move_date between _d - 7 and _d))
$$;

-- Todos os ativos já andaram naquele dia?
create or replace function public.day_released(_d date) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select not exists (
    select 1 from public.day_active(_d) a
    where not exists (select 1 from daily_moves dm where dm.user_id = a.user_id and dm.move_date = _d))
$$;

-- Regra contra spoiler (substitui a do arquivo 12; round_board, play_detail e mode_stats já a usam)
create or replace function public.can_view_day(_d date) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select public.has_role(auth.uid(), 'admin')
      or _d < public.game_today() - coalesce((public.cfg()->>'recovery_days')::int, 3)
      or (public.day_done_for(auth.uid(), _d) and public.day_released(_d))
$$;

-- Quem já jogou num dia (só sim/não: nada de números nem respostas)
create or replace function public.day_presence(_date date default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); dia date := coalesce(_date, public.game_today());
begin
  if dia > public.game_today() then raise exception 'Esse dia ainda não aconteceu.'; end if;
  return jsonb_build_object(
    'date', dia,
    'released', public.day_released(dia),
    'can_see', public.can_view_day(dia),
    'players', coalesce((
      select jsonb_agg(jsonb_build_object(
          'user_id', ch.user_id, 'name', ch.name, 'class', ch.class, 'level', ch.level, 'outfit', ch.outfit, 'team', ch.team,
          'active', a.user_id is not null,
          'moved', exists (select 1 from daily_moves dm where dm.user_id = ch.user_id and dm.move_date = dia),
          'started', exists (select 1 from guess_sessions gs where gs.user_id = ch.user_id and gs.puzzle_date = dia))
        order by ch.name)
      from characters ch
      join profiles p on p.id = ch.user_id and p.status = 'ativo'
      left join public.day_active(dia) a on a.user_id = ch.user_id
      where (ch.created_at at time zone coalesce(public.cfg()->>'timezone','America/Sao_Paulo'))::date <= dia), '[]'::jsonb));
end $$;

-- ---------- Chat dos Aventureiros ----------
create table if not exists public.chat_messages (
  id         bigserial primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  name       text not null,
  body       text not null check (char_length(body) between 1 and 300),
  created_at timestamptz not null default now()
);
create index if not exists chat_messages_recentes on public.chat_messages (created_at desc);
alter table public.chat_messages enable row level security;
drop policy if exists p_chat on public.chat_messages;
create policy p_chat on public.chat_messages for select to authenticated using (true);
revoke all on public.chat_messages from anon, authenticated;
revoke all on sequence public.chat_messages_id_seq from anon, authenticated;
grant select on public.chat_messages to authenticated;
do $$ begin
  begin alter publication supabase_realtime add table public.chat_messages; exception when duplicate_object then null; end;
end $$;

-- Texto simplificado para comparar nomes: minúsculas, sem acento, só letras e números
create or replace function public.chat_norm(_t text) returns text
language sql immutable set search_path = public, extensions as $$
  select ' ' || btrim(regexp_replace(translate(lower(coalesce(_t, '')), 'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn'), '[^a-z0-9]+', ' ', 'g')) || ' '
$$;

create or replace function public.chat_send(_body text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters; txt text := btrim(coalesce(_body, '')); r chat_messages;
  hoje date := public.game_today(); norm text; flat text; p record;
begin
  select * into me from characters where user_id = uid;
  if me.id is null then raise exception 'Crie seu herói antes de usar o chat.'; end if;
  if txt = '' then raise exception 'Escreva alguma coisa.'; end if;
  if char_length(txt) > 300 then raise exception 'A mensagem pode ter no máximo 300 letras.'; end if;
  if exists (select 1 from chat_messages c where c.user_id = uid and c.created_at > now() - interval '3 seconds') then
    raise exception 'Calma! Espere alguns segundos para mandar outra mensagem.';
  end if;
  if (select count(*) from chat_messages c where c.user_id = uid and c.created_at > now() - interval '1 minute') >= 15 then
    raise exception 'Muitas mensagens seguidas. Espere um minuto.';
  end if;
  -- sem spoiler: enquanto o ranking de hoje estiver travado, a resposta do dia não pode ir para o chat
  if not public.day_released(hoje) then
    norm := public.chat_norm(txt); flat := replace(norm, ' ', '');
    for p in select pk.name from daily_puzzles dp join pokemon pk on pk.id = dp.pokemon_id where dp.puzzle_date = hoje loop
      if position(public.chat_norm(p.name) in norm) > 0
         or (char_length(replace(public.chat_norm(p.name), ' ', '')) >= 5 and position(replace(public.chat_norm(p.name), ' ', '') in flat) > 0) then
        raise exception 'Sem spoiler! A mensagem tem a resposta de um desafio de hoje. Ela libera quando todos jogarem.';
      end if;
    end loop;
  end if;
  insert into chat_messages(user_id, name, body) values (uid, me.name, txt) returning * into r;
  return to_jsonb(r);
end $$;

create or replace function public.chat_delete(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active();
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador pode apagar mensagens.'; end if;
  delete from chat_messages where id = _id;
end $$;

-- Permissões: as funções internas não ficam abertas; as do site, só para quem está logado
revoke execute on function public.day_done_for(uuid, date), public.day_active(date), public.day_released(date), public.can_view_day(date), public.chat_norm(text) from public, anon, authenticated;
revoke execute on function public.day_presence(date), public.chat_send(text), public.chat_delete(bigint) from public, anon;
grant execute on function public.day_presence(date), public.chat_send(text), public.chat_delete(bigint) to authenticated;
