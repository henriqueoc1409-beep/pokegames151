-- =====================================================================
-- 38_quiz_surpresa.sql
-- Pedido do dono em 22/10/2026: Quiz surpresa criado pelo admin dentro do jogo.
--   * 1 pergunta com resposta em número; vence quem chegar mais perto (empate: quem respondeu antes).
--   * Ao entrar no jogo, o jogador vê uma tela grande com o aviso e o prêmio (textos do admin).
--   * "Revelar pergunta": a partir daí o jogador tem N segundos (padrão 15) para responder.
--     O tempo é contado AQUI no servidor; a pergunta não pode ser lida antes de revelar,
--     e cada um tem uma só tentativa (recarregar a página não dá mais tempo).
--   * Fecha sozinho quando todos os jogadores ativos responderem ou no prazo (padrão 24 h);
--     o admin também pode encerrar na hora. Depois todos veem o resultado.
--   * O prêmio é entregue pelo admin com os Presentes (arquivo 34).
-- Ninguém lê as tabelas direto: tudo passa pelas funções abaixo.
-- Depende do 15 (day_active) e do 34. Antes, faça a cópia de segurança.
-- =====================================================================

create table if not exists public.quizzes (
  id         bigserial primary key,
  title      text not null,
  intro      text not null default '',
  prize      text not null default '',
  question   text not null,
  answer     numeric not null,
  seconds    int not null default 15 check (seconds between 5 and 120),
  status     text not null default 'aberto' check (status in ('aberto', 'encerrado')),
  closes_at  timestamptz not null,
  closed_at  timestamptz,
  winner     uuid,
  created_by uuid,
  created_at timestamptz not null default now()
);
create table if not exists public.quiz_entries (
  quiz_id     bigint not null references public.quizzes(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  revealed_at timestamptz not null default now(),
  answered_at timestamptz,
  guess       numeric,
  primary key (quiz_id, user_id)
);
alter table public.quizzes enable row level security;
alter table public.quiz_entries enable row level security;
revoke all on public.quizzes, public.quiz_entries from anon, authenticated;

-- folga de rede: a resposta vale até N + 3 segundos depois de revelar
create or replace function public.quiz_grace() returns interval language sql immutable as $$ select interval '3 seconds' $$;

-- fecha o quiz se passou do prazo ou se todos os ativos (menos o admin) já responderam; escolhe o vencedor
create or replace function public.quiz_tick(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare q quizzes; total int; done int; w uuid;
begin
  select * into q from quizzes where id = _id for update;
  if q.id is null or q.status <> 'aberto' then return; end if;
  select count(*) into total from public.day_active(public.game_today()) a where not public.has_role(a.user_id, 'admin');
  -- já participou = respondeu ou deixou o tempo acabar
  select count(*) into done from quiz_entries e where e.quiz_id = _id and not public.has_role(e.user_id, 'admin')
     and (e.answered_at is not null or now() > e.revealed_at + make_interval(secs => q.seconds) + public.quiz_grace());
  if now() < q.closes_at and (total = 0 or done < total) then return; end if;
  select e.user_id into w from quiz_entries e
   where e.quiz_id = _id and e.guess is not null
   order by abs(e.guess - q.answer), e.answered_at limit 1;
  update quizzes set status = 'encerrado', closed_at = now(), winner = w where id = _id;
  if w is not null then
    insert into event_log(user_id, kind, message)
    select w, 'quiz', ch.name || ' venceu o Quiz surpresa "' || q.title || '"!' from characters ch where ch.user_id = w;
  end if;
end $$;

-- o quiz atual (aberto, ou o último encerrado há menos de 3 dias), do jeito que o jogador pode ver
create or replace function public.quiz_current() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); q quizzes; e quiz_entries; total int; done int; res jsonb; left_s numeric;
begin
  select * into q from quizzes where status = 'aberto' order by id desc limit 1;
  if q.id is not null then perform public.quiz_tick(q.id); select * into q from quizzes where id = q.id; end if;
  if q.id is null or q.status <> 'aberto' then
    select * into q from quizzes where status = 'encerrado' and closed_at > now() - interval '3 days' order by closed_at desc limit 1;
  end if;
  if q.id is null then return null; end if;
  select * into e from quiz_entries where quiz_id = q.id and user_id = uid;
  select count(*) into total from public.day_active(public.game_today()) a where not public.has_role(a.user_id, 'admin');
  select count(*) into done from quiz_entries x where x.quiz_id = q.id and x.answered_at is not null and not public.has_role(x.user_id, 'admin');
  left_s := case when e.revealed_at is not null and e.answered_at is null
                 then greatest(0, extract(epoch from (e.revealed_at + make_interval(secs => q.seconds) - now()))) end;
  if q.status = 'encerrado' then
    select coalesce(jsonb_agg(jsonb_build_object('user_id', r.user_id, 'name', r.name, 'guess', r.guess, 'diff', r.diff) order by r.diff, r.answered_at), '[]'::jsonb)
      into res
      from (select x.user_id, ch.name, x.guess, abs(x.guess - q.answer) diff, x.answered_at
              from quiz_entries x join characters ch on ch.user_id = x.user_id
             where x.quiz_id = q.id and x.guess is not null) r;
  end if;
  return jsonb_build_object(
    'id', q.id, 'title', q.title, 'intro', q.intro, 'prize', q.prize, 'seconds', q.seconds,
    'status', q.status, 'closes_at', q.closes_at, 'closed_at', q.closed_at,
    'answered', done, 'total', total,
    'me', case when e.user_id is null then 'novo' when e.answered_at is not null then 'respondeu'
               when left_s > 0 then 'respondendo' else 'perdeu' end,
    'my_guess', e.guess, 'left', left_s,
    'question', case when q.status = 'encerrado' or e.user_id is not null then q.question end,
    'answer', case when q.status = 'encerrado' then q.answer end,
    'winner', q.winner, 'results', res);
end $$;

-- revela a pergunta e começa a contar o tempo (uma vez só)
create or replace function public.quiz_reveal(_id bigint) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); q quizzes; e quiz_entries;
begin
  perform public.quiz_tick(_id);
  select * into q from quizzes where id = _id;
  if q.id is null then raise exception 'Quiz inexistente.'; end if;
  if q.status <> 'aberto' then raise exception 'Esse quiz já foi encerrado.'; end if;
  insert into quiz_entries(quiz_id, user_id) values (_id, uid) on conflict do nothing;
  select * into e from quiz_entries where quiz_id = _id and user_id = uid;
  if e.answered_at is not null then raise exception 'Você já respondeu esse quiz.'; end if;
  return jsonb_build_object('question', q.question, 'seconds', q.seconds,
    'left', greatest(0, extract(epoch from (e.revealed_at + make_interval(secs => q.seconds) - now()))));
end $$;

-- responde (só depois de revelar e dentro do tempo)
create or replace function public.quiz_answer(_id bigint, _guess numeric) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); q quizzes; e quiz_entries;
begin
  select * into q from quizzes where id = _id;
  if q.id is null then raise exception 'Quiz inexistente.'; end if;
  select * into e from quiz_entries where quiz_id = _id and user_id = uid for update;
  if e.user_id is null then raise exception 'Revele a pergunta primeiro.'; end if;
  if e.answered_at is not null then raise exception 'Você já respondeu esse quiz.'; end if;
  if _guess is null then raise exception 'Digite um número.'; end if;
  if now() > e.revealed_at + make_interval(secs => q.seconds) + public.quiz_grace() then raise exception 'O tempo acabou! Não deu para responder.'; end if;
  if q.status <> 'aberto' then raise exception 'Esse quiz já foi encerrado.'; end if;
  update quiz_entries set guess = _guess, answered_at = now() where quiz_id = _id and user_id = uid;
  perform public.quiz_tick(_id);
end $$;

-- ---------- admin ----------
create or replace function public.admin_quiz_save(_title text, _intro text, _prize text, _question text, _answer numeric, _seconds int default 15, _hours int default 24)
returns public.quizzes
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); q quizzes;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador cria quiz.'; end if;
  if exists (select 1 from quizzes where status = 'aberto') then raise exception 'Já existe um quiz aberto. Encerre ele antes de criar outro.'; end if;
  if char_length(btrim(coalesce(_title, ''))) not between 2 and 80 then raise exception 'Título: de 2 a 80 letras.'; end if;
  if char_length(btrim(coalesce(_question, ''))) not between 5 and 300 then raise exception 'Pergunta: de 5 a 300 letras.'; end if;
  if _answer is null then raise exception 'Informe a resposta certa (um número).'; end if;
  if coalesce(_seconds, 15) not between 5 and 120 then raise exception 'Tempo para responder: de 5 a 120 segundos.'; end if;
  if coalesce(_hours, 24) not between 1 and 168 then raise exception 'Prazo: de 1 a 168 horas.'; end if;
  insert into quizzes(title, intro, prize, question, answer, seconds, closes_at, created_by)
  values (btrim(_title), left(btrim(coalesce(_intro, '')), 500), left(btrim(coalesce(_prize, '')), 200), btrim(_question), _answer,
          coalesce(_seconds, 15), now() + make_interval(hours => coalesce(_hours, 24)), uid)
  returning * into q;
  insert into admin_audit_log(admin_id, action, target, after) values (uid, 'quiz', q.id::text, to_jsonb(q));
  return q;
end $$;

create or replace function public.admin_quiz_close(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active();
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador encerra quiz.'; end if;
  update quizzes set closes_at = now() where id = _id and status = 'aberto';
  perform public.quiz_tick(_id);
  insert into admin_audit_log(admin_id, action, target) values (uid, 'quiz_encerrado', _id::text);
end $$;

create or replace function public.admin_quiz_delete(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); q quizzes;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador apaga quiz.'; end if;
  select * into q from quizzes where id = _id;
  delete from quizzes where id = _id;
  insert into admin_audit_log(admin_id, action, target, before) values (uid, 'quiz_apagado', _id::text, to_jsonb(q));
end $$;

-- admin: os últimos quizzes com pergunta, resposta e todas as respostas (mesmo abertos)
create or replace function public.admin_quiz_list() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); r jsonb;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador.'; end if;
  perform public.quiz_tick(id) from quizzes where status = 'aberto';
  select coalesce(jsonb_agg(x order by x.id desc), '[]'::jsonb) into r from (
    select q.*, (select coalesce(jsonb_agg(jsonb_build_object('user_id', e.user_id, 'name', ch.name, 'guess', e.guess,
                   'diff', abs(e.guess - q.answer), 'answered_at', e.answered_at) order by abs(e.guess - q.answer) nulls last, e.answered_at), '[]'::jsonb)
                 from quiz_entries e join characters ch on ch.user_id = e.user_id where e.quiz_id = q.id) entries,
           (select count(*) from public.day_active(public.game_today()) a where not public.has_role(a.user_id, 'admin')) total
      from quizzes q order by q.id desc limit 10) x;
  return r;
end $$;

revoke execute on function public.quiz_tick(bigint), public.quiz_grace() from public, anon, authenticated;
revoke execute on function public.quiz_current(), public.quiz_reveal(bigint), public.quiz_answer(bigint, numeric),
  public.admin_quiz_save(text, text, text, text, numeric, int, int), public.admin_quiz_close(bigint), public.admin_quiz_delete(bigint),
  public.admin_quiz_list() from public, anon;
grant execute on function public.quiz_current(), public.quiz_reveal(bigint), public.quiz_answer(bigint, numeric),
  public.admin_quiz_save(text, text, text, text, numeric, int, int), public.admin_quiz_close(bigint), public.admin_quiz_delete(bigint),
  public.admin_quiz_list() to authenticated;
