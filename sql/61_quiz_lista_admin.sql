-- =====================================================================
-- POKEGAMES — Lista de quizzes do admin com todos os quizzes
-- (pedido do dono em 03/11/2026).
--
-- Antes a aba Administração → Quiz mostrava só os 10 últimos quizzes.
-- Agora mostra até 300 (o site fecha cada um num cartão que abre com um
-- clique e tem filtro por título, situação e vencedor). Só o admin usa;
-- não muda nada para os jogadores. Depende do 38.
-- Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

drop function if exists public.admin_quiz_list();

create or replace function public.admin_quiz_list(_limit int default 300) returns jsonb
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
      from quizzes q order by q.id desc limit greatest(1, least(coalesce(_limit, 300), 1000))) x;
  return r;
end $$;

revoke execute on function public.admin_quiz_list(int) from public, anon;
grant execute on function public.admin_quiz_list(int) to authenticated;
