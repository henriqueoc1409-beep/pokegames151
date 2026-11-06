-- =====================================================================
-- POKEGAMES — Caverna liberada na hora (pedido do dono em 06/11/2026).
-- O 73 fez a caverna abrir na hora só para as próximas Ligas. Este arquivo:
-- 1) abre AGORA a caverna que já estava esperando (a do campeão da Liga 1);
-- 2) a tentativa de captura não espera nada quando liga.caverna_horas = 0.
-- O prazo para o campeão tentar (liga.caverna_prazo_horas, 24 h) passa a
-- contar de agora. Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

update public.leagues set cave_open_at = now()
 where status = 'caverna' and cave_tried_at is null and cave_open_at > now()
   and coalesce((public.liga_cfg()->>'caverna_horas')::int, 0) = 0;

-- tentativa de captura (versão do 31 + sem espera)
create or replace function public.league_cave_try() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); lg leagues; ok boolean;
begin
  select * into lg from leagues where status = 'caverna' order by id desc limit 1 for update;
  if lg.id is null then raise exception 'Não há ninguém na caverna agora.'; end if;
  if lg.champion <> uid then raise exception 'Só o campeão da Liga pode tentar capturar o lendário.'; end if;
  -- arquivo 74: com caverna_horas = 0 (padrão), o campeão tenta na hora, sem olhar o relógio
  if coalesce((public.liga_cfg()->>'caverna_horas')::int, 0) > 0 and now() < lg.cave_open_at then raise exception 'O lendário ainda não se aproximou. Tente depois de %.', to_char(lg.cave_open_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'); end if;
  ok := random() * 100 < coalesce((public.cfg()->>'league_capture_pct')::numeric, 5);
  update leagues set cave_tried_at = now() where id = lg.id;
  perform public.league_cave_end(lg.id, ok);
  return jsonb_build_object('caught', ok, 'pokemon', lg.legend_id, 'level', lg.legend_level);
end $$;

-- ---------- aviso no Jornal, publicado sozinho ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🕳️ A caverna abriu!', 'Chega de esperar: a caverna do lendário abre assim que a Liga tem um campeão. Quem já estava esperando pode tentar a captura agora mesmo. Uma chance só!')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
