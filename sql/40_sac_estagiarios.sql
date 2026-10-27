-- =====================================================================
-- 40_sac_estagiarios.sql
-- Pedido do dono em 22/10/2026: além do Chupika, o admin cria outros "estagiários" do SAC
-- pelo próprio site, com nome, cargo e foto. Cada atendimento novo cai com um estagiário
-- de plantão (o que tem menos atendimentos abertos), que dá a resposta automática; as respostas
-- do admin saem com o nome e a foto desse estagiário.
--   * sac_agents: lista de estagiários (todos leem os ativos; o admin vê todos);
--   * a foto fica guardada em texto (imagem pequena, até ~150 KB), diminuída no aparelho do admin;
--   * o Chupika já vem cadastrado, sem foto (usa a arte em pixel do jogo).
-- Depende do 39. Antes, faça a cópia de segurança.
-- =====================================================================

create table if not exists public.sac_agents (
  id         bigserial primary key,
  name       text not null check (char_length(name) between 2 and 40),
  role       text not null default 'Estagiário' check (char_length(role) between 2 and 40),
  photo      text,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.sac_agents enable row level security;
drop policy if exists p_sac_agents on public.sac_agents;
create policy p_sac_agents on public.sac_agents for select to authenticated
  using (active or public.has_role(auth.uid(), 'admin'));
revoke all on public.sac_agents from anon, authenticated;
grant select on public.sac_agents to authenticated;
insert into public.sac_agents (name, role)
select 'Chupika', 'Estagiário do Jogo' where not exists (select 1 from public.sac_agents);

alter table public.sac_tickets add column if not exists agent_id bigint references public.sac_agents(id) on delete set null;
alter table public.sac_messages add column if not exists agent_id bigint references public.sac_agents(id) on delete set null;
-- atendimentos antigos ficam com o Chupika
update public.sac_tickets set agent_id = (select min(id) from public.sac_agents) where agent_id is null;
update public.sac_messages m set agent_id = t.agent_id from public.sac_tickets t where t.id = m.ticket_id and m.from_admin and m.agent_id is null;

-- jogador abre um atendimento: cai com o estagiário de plantão, que responde sozinho na hora
create or replace function public.sac_open(_kind text, _body text) returns public.sac_tickets
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); t sac_tickets; b text := btrim(coalesce(_body, '')); ag sac_agents;
begin
  if _kind not in ('duvida', 'pedido', 'informacao', 'problema') then raise exception 'Escolha o tipo da mensagem.'; end if;
  if char_length(b) not between 3 and 1000 then raise exception 'Escreva a mensagem (de 3 a 1000 letras).'; end if;
  if (select count(*) from sac_tickets where user_id = uid and status <> 'fechado') >= 3 then
    raise exception 'Você já tem 3 atendimentos abertos. Continue numa conversa que já existe.';
  end if;
  perform public.sac_rate(uid);
  -- de plantão: o ativo com menos atendimentos abertos (empate: sorteio)
  select a.* into ag from sac_agents a where a.active
   order by (select count(*) from sac_tickets x where x.agent_id = a.id and x.status <> 'fechado'), random() limit 1;
  insert into sac_tickets(user_id, kind, agent_id) values (uid, _kind, ag.id) returning * into t;
  insert into sac_messages(ticket_id, author, body) values (t.id, uid, b);
  insert into sac_messages(ticket_id, from_admin, auto, agent_id, body, created_at)
  values (t.id, true, true, ag.id, replace(case _kind
      when 'duvida' then 'Oi! Aqui é {N}, do SAC do Pokegames. Anotei sua dúvida e já levei pro chefe. A resposta chega aqui mesmo, fica de olho!'
      when 'pedido' then 'Oi! {N} aqui, do SAC. Seu pedido foi anotado com carinho e entregue ao chefe. Assim que ele decidir, eu te aviso aqui.'
      when 'problema' then 'Eita! {N} na área. Já passei o problema pro chefe. Se puder, conte o que estava fazendo quando aconteceu, isso ajuda muito.'
      else 'Valeu pela informação! Aqui é {N}, do SAC. Já repassei para o chefe.' end,
      '{N}', coalesce(ag.name, 'o Chupika')), now() + interval '1 millisecond');
  update sac_tickets set last_at = now(), last_admin = true, user_seen = now() + interval '1 millisecond' where id = t.id returning * into t;
  return t;
end $$;

-- responder: o admin responde com o nome e a foto do estagiário do atendimento
create or replace function public.sac_reply(_ticket bigint, _body text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); t sac_tickets; adm boolean := public.has_role(uid, 'admin'); b text := btrim(coalesce(_body, ''));
begin
  select * into t from sac_tickets where id = _ticket for update;
  if t.id is null or (t.user_id <> uid and not adm) then raise exception 'Atendimento não encontrado.'; end if;
  if char_length(b) not between 1 and 1000 then raise exception 'Escreva a mensagem (até 1000 letras).'; end if;
  perform public.sac_rate(uid);
  if adm and t.user_id <> uid then
    insert into sac_messages(ticket_id, author, from_admin, agent_id, body) values (_ticket, uid, true, t.agent_id, b);
    update sac_tickets set status = 'respondido', last_at = now(), last_admin = true, admin_seen = now() where id = _ticket;
  else
    insert into sac_messages(ticket_id, author, body) values (_ticket, uid, b);
    update sac_tickets set status = 'aberto', last_at = now(), last_admin = false, user_seen = now() where id = _ticket;
  end if;
end $$;

-- admin: passar o atendimento para outro estagiário
create or replace function public.admin_sac_assign(_ticket bigint, _agent bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active();
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador.'; end if;
  if not exists (select 1 from sac_agents where id = _agent) then raise exception 'Estagiário não encontrado.'; end if;
  update sac_tickets set agent_id = _agent where id = _ticket;
end $$;

-- admin: criar (sem _id) ou mudar um estagiário. _photo vazio = sem foto; null = mantém a atual
create or replace function public.admin_sac_agent_save(_id bigint, _name text, _role text, _photo text, _active boolean) returns public.sac_agents
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); a sac_agents; nm text := btrim(coalesce(_name, '')); rl text := btrim(coalesce(_role, ''));
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador cadastra estagiários.'; end if;
  if char_length(nm) not between 2 and 40 then raise exception 'Nome: de 2 a 40 letras.'; end if;
  if rl = '' then rl := 'Estagiário'; end if;
  if char_length(rl) > 40 then raise exception 'Cargo: até 40 letras.'; end if;
  if _photo is not null and _photo <> '' and (_photo !~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$' or char_length(_photo) > 200000) then
    raise exception 'Foto inválida ou grande demais.';
  end if;
  if _id is null then
    insert into sac_agents(name, role, photo, active) values (nm, rl, nullif(_photo, ''), coalesce(_active, true)) returning * into a;
  else
    update sac_agents set name = nm, role = rl, photo = case when _photo is null then photo else nullif(_photo, '') end, active = coalesce(_active, active)
     where id = _id returning * into a;
    if a.id is null then raise exception 'Estagiário não encontrado.'; end if;
  end if;
  if not exists (select 1 from sac_agents where active) then raise exception 'Precisa ficar pelo menos 1 estagiário ativo.'; end if;
  insert into admin_audit_log(admin_id, action, target, after) values (uid, 'estagiario', a.id::text, jsonb_build_object('name', a.name, 'role', a.role, 'active', a.active));
  return a;
end $$;

-- admin: apagar um estagiário (os atendimentos dele passam para outro ativo)
create or replace function public.admin_sac_agent_delete(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); other bigint;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador apaga estagiários.'; end if;
  select id into other from sac_agents where active and id <> _id order by id limit 1;
  if other is null then raise exception 'Precisa ficar pelo menos 1 estagiário ativo.'; end if;
  update sac_tickets set agent_id = other where agent_id = _id;
  delete from sac_agents where id = _id;
  insert into admin_audit_log(admin_id, action, target) values (uid, 'estagiario_apagado', _id::text);
end $$;

revoke execute on function public.admin_sac_assign(bigint, bigint), public.admin_sac_agent_save(bigint, text, text, text, boolean),
  public.admin_sac_agent_delete(bigint) from public, anon;
grant execute on function public.sac_open(text, text), public.sac_reply(bigint, text), public.admin_sac_assign(bigint, bigint),
  public.admin_sac_agent_save(bigint, text, text, text, boolean), public.admin_sac_agent_delete(bigint) to authenticated;
