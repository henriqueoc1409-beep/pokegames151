-- 94_quiz_desempate_tempo.sql
-- Pedido do dono em 12/11/2026: no Quiz, o desempate (mesma distância da resposta) passa a ser o TEMPO GASTO por cada
-- um: do momento em que a pergunta apareceu na tela dele (revealed_at, gravado pelo servidor no quiz_reveal) até o envio
-- (answered_at). Antes valia a hora do envio, que favorecia quem abriu o quiz mais cedo. Persistindo o empate, vale a
-- hora do envio. Novas versões de quiz_tick (versão do 51), quiz_current (versão do 86) e admin_quiz_list (versão do
-- 61), que também devolvem o "tempo" de cada um (em segundos, com uma casa) para o site mostrar.
-- Vale para os quizzes que fecharem depois que este arquivo rodar (o que já fechou não muda de vencedor).

create or replace function public.quiz_tick(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare q quizzes; total int; done int; w uuid; g gifts;
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
   order by abs(e.guess - q.answer), e.answered_at - e.revealed_at, e.answered_at limit 1;   -- empate: quem gastou menos tempo dos segundos do quiz
  update quizzes set status = 'encerrado', closed_at = now(), winner = w where id = _id;
  if w is not null then
    -- prêmio de verdade (arquivo 51): entregue na hora, com presente no Correio
    if q.prize_coins > 0 or q.prize_hints > 0 or q.prize_retries > 0 or q.prize_bag <> '{}'::jsonb or cardinality(q.prize_items) > 0 then
      g := public.gift_give(w, '🏆 Prêmio do Quiz "' || q.title || '"' || case when q.prize <> '' then ': ' || q.prize else '' end || '. Parabéns!',
             q.prize_items, q.prize_coins, q.prize_hints, q.prize_retries, q.prize_bag, null);
      update quizzes set prize_given_at = now() where id = _id;
    end if;
    insert into event_log(user_id, kind, message)
    select w, 'quiz', ch.name || ' venceu o Quiz surpresa "' || q.title || '"' || case when q.prize <> '' then ' e ganhou ' || q.prize else '' end || '!' from characters ch where ch.user_id = w;
  end if;
end $$;

create or replace function public.quiz_current() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); q quizzes; e quiz_entries; total int; done int; res jsonb; left_s numeric;
begin
  perform public.quiz_auto_tick();   -- arquivo 86: abre o quiz automático na hora marcada
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
    select coalesce(jsonb_agg(jsonb_build_object('user_id', r.user_id, 'name', r.name, 'guess', r.guess, 'diff', r.diff, 'tempo', r.tempo) order by r.diff, r.tempo, r.answered_at), '[]'::jsonb)
      into res
      from (select x.user_id, ch.name, x.guess, abs(x.guess - q.answer) diff, x.answered_at, round(extract(epoch from x.answered_at - x.revealed_at)::numeric, 1) tempo
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

create or replace function public.admin_quiz_list(_limit int default 300) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); r jsonb;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador.'; end if;
  perform public.quiz_tick(id) from quizzes where status = 'aberto';
  select coalesce(jsonb_agg(x order by x.id desc), '[]'::jsonb) into r from (
    select q.*, (select coalesce(jsonb_agg(jsonb_build_object('user_id', e.user_id, 'name', ch.name, 'guess', e.guess,
                   'diff', abs(e.guess - q.answer), 'answered_at', e.answered_at, 'tempo', round(extract(epoch from e.answered_at - e.revealed_at)::numeric, 1)) order by abs(e.guess - q.answer) nulls last, e.answered_at - e.revealed_at, e.answered_at), '[]'::jsonb)
                 from quiz_entries e join characters ch on ch.user_id = e.user_id where e.quiz_id = q.id) entries,
           (select count(*) from public.day_active(public.game_today()) a where not public.has_role(a.user_id, 'admin')) total
      from quizzes q order by q.id desc limit greatest(1, least(coalesce(_limit, 300), 1000))) x;
  return r;
end $$;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('⏱️ Quiz: empate agora vai pelo tempo de resposta', 'Mudou o desempate do Quiz: quando dois ou mais chegam igualmente perto da resposta, vence quem respondeu mais rápido depois que a pergunta apareceu na tela (por exemplo, 3,2 s contra 7,5 s).
Antes valia quem enviou primeiro no relógio, o que favorecia quem abriu o quiz mais cedo.
No resultado do quiz agora aparece o tempo de cada um.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
