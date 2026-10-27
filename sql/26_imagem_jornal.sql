-- =====================================================================
-- POKEGAMES — Imagem nos avisos do Jornal (pedido do dono em 21/10/2026).
--   * só o admin envia; todos veem (no Jornal e na janela de avisos novos);
--   * a imagem some sozinha depois de 3 dias e é APAGADA do banco
--     (não ocupa espaço). O aviso continua, só sem a imagem;
--   * o site diminui a foto antes de enviar (cerca de 100 a 300 KB).
-- Não precisa de tarefa agendada: a limpeza acontece quando alguém abre
-- o Jornal (post_images_purge) ou quando o admin envia outra imagem.
-- O prazo fica em game_config.config.post_image_days (padrão 3).
-- Depende do 22. Não apaga avisos nem votos. Antes, faça a cópia de segurança.
-- =====================================================================

alter table public.posts add column if not exists image_at timestamptz;   -- quando a imagem foi enviada (vazio = sem imagem)

create table if not exists public.post_images (
  post_id    bigint primary key references public.posts(id) on delete cascade,
  data       text not null check (char_length(data) <= 700000),        -- a imagem em texto (data:image/...;base64,...)
  created_at timestamptz not null default now()
);

create or replace function public.post_image_days() returns int
language sql stable security definer set search_path = public, extensions as $$
  select greatest(1, coalesce((public.cfg()->>'post_image_days')::int, 3))
$$;

alter table public.post_images enable row level security;
drop policy if exists p_pimg on public.post_images;
create policy p_pimg on public.post_images for select to authenticated
  using (created_at > now() - make_interval(days => public.post_image_days()));
revoke all on public.post_images from anon, authenticated;
grant select on public.post_images to authenticated;

-- apaga do banco as imagens vencidas (qualquer jogador pode chamar; só apaga o que já venceu)
create or replace function public.post_images_purge() returns int
language plpgsql security definer set search_path = public, extensions as $$
declare n int;
begin
  with gone as (delete from post_images where created_at <= now() - make_interval(days => public.post_image_days()) returning post_id)
  update posts set image_at = null where id in (select post_id from gone);
  get diagnostics n = row_count;
  update posts set image_at = null where image_at is not null and image_at <= now() - make_interval(days => public.post_image_days());
  return n;
end $$;

-- admin põe, troca ou tira (_data vazio) a imagem de um aviso
create or replace function public.admin_post_image(_post bigint, _data text) returns timestamptz
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); t timestamptz;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador publica imagens no Jornal.'; end if;
  if not exists (select 1 from posts where id = _post) then raise exception 'Aviso não encontrado.'; end if;
  perform public.post_images_purge();
  if coalesce(_data, '') = '' then
    delete from post_images where post_id = _post;
    update posts set image_at = null where id = _post;
    return null;
  end if;
  if _data !~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$' then raise exception 'Imagem inválida. Use uma foto JPG, PNG ou WEBP.'; end if;
  if char_length(_data) > 700000 then raise exception 'Imagem grande demais (máximo de cerca de 500 KB).'; end if;
  insert into post_images(post_id, data, created_at) values (_post, _data, now())
    on conflict (post_id) do update set data = excluded.data, created_at = now();
  t := now();
  update posts set image_at = t where id = _post;   -- o site dos jogadores recebe a mudança ao vivo
  insert into admin_audit_log(admin_id, action, target, after) values (uid, 'aviso_imagem', _post::text, jsonb_build_object('tamanho', char_length(_data)));
  return t;
end $$;

-- o prazo é lido pela regra de leitura da tabela, então quem está logado precisa poder chamá-lo (só devolve um número)
revoke execute on function public.post_image_days() from public, anon;
grant execute on function public.post_image_days() to authenticated;
revoke execute on function public.post_images_purge(), public.admin_post_image(bigint, text) from public, anon;
grant execute on function public.post_images_purge(), public.admin_post_image(bigint, text) to authenticated;
