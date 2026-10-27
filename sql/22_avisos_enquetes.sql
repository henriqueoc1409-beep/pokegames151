-- =====================================================================
-- POKEGAMES — Avisos do admin no Jornal e enquetes.
--
-- 1) O admin escreve e publica avisos (promoção, evento, banimento,
--    novidade ou aviso geral). Todos leem; ninguém mais escreve.
-- 2) Um aviso pode ser uma enquete: o admin dá de 2 a 6 opções e,
--    se quiser, uma data para encerrar. Cada jogador vota uma vez
--    (pode mudar o voto enquanto a enquete estiver aberta). Todos veem
--    o resultado (quantos votos em cada opção), mas não quem votou.
-- Não muda pontos, XP, moedas nem recompensas. Rode depois do 21.
-- Antes, faça a cópia de segurança.
-- =====================================================================

create table if not exists public.posts (
  id         bigserial primary key,
  kind       text not null default 'aviso' check (kind in ('aviso','promocao','evento','banido','novidade','enquete')),
  title      text not null check (char_length(title) between 1 and 120),
  body       text not null default '' check (char_length(body) <= 3000),
  options    text[] not null default '{}',          -- só nas enquetes (2 a 6 opções)
  closes_at  timestamptz,                            -- enquete: vazio = sem prazo
  pinned     boolean not null default false,         -- fixado no topo do Jornal
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (kind <> 'enquete' or cardinality(options) between 2 and 6)
);
create index if not exists posts_recentes on public.posts (created_at desc);

create table if not exists public.poll_votes (
  post_id    bigint not null references public.posts(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  option     int not null check (option >= 0),
  voted_at   timestamptz not null default now(),
  primary key (post_id, user_id)
);

alter table public.posts enable row level security;
alter table public.poll_votes enable row level security;
drop policy if exists p_posts on public.posts;      create policy p_posts on public.posts for select to authenticated using (true);
drop policy if exists p_votes on public.poll_votes; create policy p_votes on public.poll_votes for select to authenticated using (user_id = auth.uid());
revoke all on public.posts, public.poll_votes from anon, authenticated;
revoke all on sequence public.posts_id_seq from anon, authenticated;
grant select on public.posts, public.poll_votes to authenticated;
do $$ begin
  begin alter publication supabase_realtime add table public.posts; exception when duplicate_object then null; end;
end $$;

-- admin publica ou edita um aviso (_id vazio = novo)
create or replace function public.admin_save_post(_id bigint, _kind text, _title text, _body text, _options text[], _closes_at timestamptz, _pinned boolean)
returns public.posts
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); p posts; old posts; opts text[];
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador publica no Jornal.'; end if;
  if _kind not in ('aviso','promocao','evento','banido','novidade','enquete') then raise exception 'Tipo de aviso inválido.'; end if;
  if btrim(coalesce(_title, '')) = '' then raise exception 'Escreva um título.'; end if;
  select coalesce(array_agg(left(btrim(o), 80) order by n), '{}') into opts
    from unnest(coalesce(_options, '{}')) with ordinality u(o, n) where btrim(o) <> '';
  if _kind = 'enquete' and (cardinality(opts) < 2 or cardinality(opts) > 6) then raise exception 'A enquete precisa de 2 a 6 opções.'; end if;
  if _kind <> 'enquete' then opts := '{}'; end if;
  if _id is null then
    insert into posts(kind, title, body, options, closes_at, pinned, created_by)
    values (_kind, left(btrim(_title), 120), left(coalesce(btrim(_body), ''), 3000), opts, case when _kind = 'enquete' then _closes_at end, coalesce(_pinned, false), uid)
    returning * into p;
  else
    select * into old from posts where id = _id for update;
    if old.id is null then raise exception 'Aviso não encontrado.'; end if;
    if old.kind = 'enquete' and opts is distinct from old.options and exists (select 1 from poll_votes where post_id = _id) then
      raise exception 'Essa enquete já tem votos: não dá para mudar as opções (dá para mudar o texto e o prazo).'; end if;
    update posts set kind = _kind, title = left(btrim(_title), 120), body = left(coalesce(btrim(_body), ''), 3000), options = opts,
           closes_at = case when _kind = 'enquete' then _closes_at end, pinned = coalesce(_pinned, false), updated_at = now()
     where id = _id returning * into p;
  end if;
  insert into admin_audit_log(admin_id, action, target, before, after) values (uid, 'aviso', p.id::text, to_jsonb(old), to_jsonb(p));
  return p;
end $$;

create or replace function public.admin_delete_post(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); p posts;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador apaga avisos.'; end if;
  delete from posts where id = _id returning * into p;
  if p.id is null then raise exception 'Aviso não encontrado.'; end if;
  insert into admin_audit_log(admin_id, action, target, before) values (uid, 'aviso_apagado', _id::text, to_jsonb(p));
end $$;

-- votar (ou mudar o voto) numa enquete aberta
create or replace function public.poll_vote(_post bigint, _option int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); p posts;
begin
  select * into p from posts where id = _post;
  if p.id is null or p.kind <> 'enquete' then raise exception 'Enquete não encontrada.'; end if;
  if p.closes_at is not null and p.closes_at <= now() then raise exception 'Essa enquete já foi encerrada.'; end if;
  if _option is null or _option < 0 or _option >= cardinality(p.options) then raise exception 'Opção inválida.'; end if;
  insert into poll_votes(post_id, user_id, option) values (_post, uid, _option)
  on conflict (post_id, user_id) do update set option = excluded.option, voted_at = now();
end $$;

-- resultado das enquetes: votos por opção (sem dizer quem votou) e o seu voto
create or replace function public.poll_results() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active();
begin
  return coalesce((
    select jsonb_object_agg(p.id::text, jsonb_build_object(
      'counts', (select jsonb_agg(coalesce((select count(*) from poll_votes v where v.post_id = p.id and v.option = i - 1), 0) order by i)
                 from generate_series(1, cardinality(p.options)) i),
      'total', (select count(*) from poll_votes v where v.post_id = p.id),
      'mine', (select v.option from poll_votes v where v.post_id = p.id and v.user_id = uid)))
    from posts p where p.kind = 'enquete'), '{}'::jsonb);
end $$;

revoke execute on function public.admin_save_post(bigint, text, text, text, text[], timestamptz, boolean), public.admin_delete_post(bigint),
  public.poll_vote(bigint, int), public.poll_results() from public, anon;
grant execute on function public.admin_save_post(bigint, text, text, text, text[], timestamptz, boolean), public.admin_delete_post(bigint),
  public.poll_vote(bigint, int), public.poll_results() to authenticated;
