-- =====================================================================
-- 39_sac_chupika.sql
-- Pedido do dono em 22/10/2026: SAC do jogo. O jogador fala com o Chupika, o "Estagiário do Jogo"
-- (personagem com arte original), mandando dúvidas, pedidos, informações ou problemas.
-- O admin responde pelo próprio site, assinando como Chupika. Cada conversa é um "atendimento".
--   * cada jogador só vê os próprios atendimentos; o admin vê todos;
--   * o Chupika responde sozinho na hora a 1ª mensagem ("recebi e passei para o chefe");
--   * limites: até 3 atendimentos abertos por jogador, mensagens de até 1000 letras, 1 a cada 5 s.
-- Depende só do 01. Antes, faça a cópia de segurança.
-- =====================================================================

create table if not exists public.sac_tickets (
  id          bigserial primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  kind        text not null check (kind in ('duvida', 'pedido', 'informacao', 'problema')),
  status      text not null default 'aberto' check (status in ('aberto', 'respondido', 'fechado')),
  user_seen   timestamptz not null default now(),   -- até quando o jogador já leu
  admin_seen  timestamptz,                          -- até quando o admin já leu
  last_at     timestamptz not null default now(),   -- última mensagem
  last_admin  boolean not null default false,       -- a última mensagem foi do Chupika/admin?
  created_at  timestamptz not null default now()
);
create index if not exists sac_tickets_user on public.sac_tickets (user_id, last_at desc);
create table if not exists public.sac_messages (
  id         bigserial primary key,
  ticket_id  bigint not null references public.sac_tickets(id) on delete cascade,
  author     uuid,
  from_admin boolean not null default false,
  auto       boolean not null default false,        -- resposta automática do Chupika
  body       text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index if not exists sac_messages_ticket on public.sac_messages (ticket_id, id);

alter table public.sac_tickets enable row level security;
alter table public.sac_messages enable row level security;
drop policy if exists p_sac_tickets on public.sac_tickets;
create policy p_sac_tickets on public.sac_tickets for select to authenticated
  using (user_id = auth.uid() or public.has_role(auth.uid(), 'admin'));
drop policy if exists p_sac_messages on public.sac_messages;
create policy p_sac_messages on public.sac_messages for select to authenticated
  using (exists (select 1 from public.sac_tickets t where t.id = ticket_id and (t.user_id = auth.uid() or public.has_role(auth.uid(), 'admin'))));
revoke all on public.sac_tickets, public.sac_messages from anon, authenticated;
grant select on public.sac_tickets, public.sac_messages to authenticated;
do $$ begin
  begin alter publication supabase_realtime add table public.sac_messages; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.sac_tickets; exception when duplicate_object then null; end;
end $$;

-- limite de 1 mensagem a cada 5 segundos por pessoa
create or replace function public.sac_rate(_uid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if exists (select 1 from sac_messages where author = _uid and not auto and created_at > now() - interval '5 seconds') then
    raise exception 'Calma! Espere uns segundos antes de mandar outra mensagem.';
  end if;
end $$;

-- jogador abre um atendimento com a 1ª mensagem; o Chupika responde sozinho na hora
create or replace function public.sac_open(_kind text, _body text) returns public.sac_tickets
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); t sac_tickets; b text := btrim(coalesce(_body, ''));
begin
  if _kind not in ('duvida', 'pedido', 'informacao', 'problema') then raise exception 'Escolha o tipo da mensagem.'; end if;
  if char_length(b) not between 3 and 1000 then raise exception 'Escreva a mensagem (de 3 a 1000 letras).'; end if;
  if (select count(*) from sac_tickets where user_id = uid and status <> 'fechado') >= 3 then
    raise exception 'Você já tem 3 atendimentos abertos. Continue numa conversa que já existe.';
  end if;
  perform public.sac_rate(uid);
  insert into sac_tickets(user_id, kind) values (uid, _kind) returning * into t;
  insert into sac_messages(ticket_id, author, body) values (t.id, uid, b);
  insert into sac_messages(ticket_id, from_admin, auto, body, created_at)
  values (t.id, true, true, case _kind
      when 'duvida' then 'Oi! Aqui é o Chupika, estagiário do Pokegames. Anotei sua dúvida e já levei pro chefe. A resposta chega aqui mesmo, fica de olho!'
      when 'pedido' then 'Oi! Chupika aqui, o estagiário. Seu pedido foi anotado com carinho e entregue ao chefe. Assim que ele decidir, eu te aviso aqui.'
      when 'problema' then 'Eita! Chupika na área. Já passei o problema pro chefe. Se puder, conte o que estava fazendo quando aconteceu, isso ajuda muito.'
      else 'Valeu pela informação! Aqui é o Chupika, estagiário do jogo. Já repassei para o chefe.' end,
    now() + interval '1 millisecond');
  update sac_tickets set last_at = now(), last_admin = true, user_seen = now() + interval '1 millisecond' where id = t.id returning * into t;
  return t;
end $$;

-- responder num atendimento (o jogador no dele; o admin em qualquer um, assinando como Chupika)
create or replace function public.sac_reply(_ticket bigint, _body text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); t sac_tickets; adm boolean := public.has_role(uid, 'admin'); b text := btrim(coalesce(_body, ''));
begin
  select * into t from sac_tickets where id = _ticket for update;
  if t.id is null or (t.user_id <> uid and not adm) then raise exception 'Atendimento não encontrado.'; end if;
  if char_length(b) not between 1 and 1000 then raise exception 'Escreva a mensagem (até 1000 letras).'; end if;
  perform public.sac_rate(uid);
  insert into sac_messages(ticket_id, author, from_admin, body) values (_ticket, uid, adm and t.user_id <> uid, b);
  if adm and t.user_id <> uid then
    update sac_tickets set status = 'respondido', last_at = now(), last_admin = true, admin_seen = now() where id = _ticket;
  else
    update sac_tickets set status = 'aberto', last_at = now(), last_admin = false, user_seen = now() where id = _ticket;
  end if;
end $$;

-- marcar como lido (jogador ou admin)
create or replace function public.sac_seen(_ticket bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active();
begin
  update sac_tickets set user_seen = now() where id = _ticket and user_id = uid;
  if public.has_role(uid, 'admin') then update sac_tickets set admin_seen = now() where id = _ticket and user_id <> uid; end if;
end $$;

-- encerrar (o jogador no dele ou o admin); reabrir = mandar nova mensagem
create or replace function public.sac_close(_ticket bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); t sac_tickets;
begin
  select * into t from sac_tickets where id = _ticket;
  if t.id is null or (t.user_id <> uid and not public.has_role(uid, 'admin')) then raise exception 'Atendimento não encontrado.'; end if;
  update sac_tickets set status = 'fechado' where id = _ticket;
end $$;

revoke execute on function public.sac_rate(uuid) from public, anon, authenticated;
revoke execute on function public.sac_open(text, text), public.sac_reply(bigint, text), public.sac_seen(bigint), public.sac_close(bigint) from public, anon;
grant execute on function public.sac_open(text, text), public.sac_reply(bigint, text), public.sac_seen(bigint), public.sac_close(bigint) to authenticated;
