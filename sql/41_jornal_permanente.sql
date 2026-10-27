-- =====================================================================
-- 41_jornal_permanente.sql
-- Pedido do dono em 22/10/2026: fica só o Jornal (o Mural de contribuições vai para o Caixa da Obra,
-- isso é só no site) e NADA do que foi postado no Jornal é apagado:
--   * "Apagar aviso" passa a ARQUIVAR: o aviso sai do topo e vai para o arquivo, que todos podem ver;
--     o admin pode tirar do arquivo quando quiser (admin_archive_post);
--   * as imagens dos avisos deixam de vencer (antes sumiam em 3 dias). O site agora diminui as fotos
--     para ~150 KB, para o banco gratuito não encher.
-- Depende do 22 e do 26. Antes, faça a cópia de segurança.
-- =====================================================================

alter table public.posts add column if not exists archived boolean not null default false;
alter table public.posts add column if not exists archived_at timestamptz;

-- imagens não vencem mais (100 anos); o número continua em game_config.config.post_image_days
update public.game_config set config = jsonb_set(config, '{post_image_days}', '36500'::jsonb, true) where active;
create or replace function public.post_image_days() returns int
language sql stable security definer set search_path = public, extensions as $$
  select greatest(1, coalesce((public.cfg()->>'post_image_days')::int, 36500))
$$;

-- arquivar ou tirar do arquivo
create or replace function public.admin_archive_post(_id bigint, _archived boolean default true) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); p posts;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador arquiva avisos.'; end if;
  update posts set archived = coalesce(_archived, true), archived_at = case when coalesce(_archived, true) then now() end, pinned = case when coalesce(_archived, true) then false else pinned end
   where id = _id returning * into p;
  if p.id is null then raise exception 'Aviso não encontrado.'; end if;
  insert into admin_audit_log(admin_id, action, target) values (uid, case when p.archived then 'aviso_arquivado' else 'aviso_desarquivado' end, _id::text);
end $$;

-- o antigo "apagar" agora só arquiva (nada some do Jornal)
create or replace function public.admin_delete_post(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.admin_archive_post(_id, true);
end $$;

revoke execute on function public.admin_archive_post(bigint, boolean) from public, anon;
grant execute on function public.admin_archive_post(bigint, boolean), public.admin_delete_post(bigint) to authenticated;
