-- =====================================================================
-- POKEGAMES — Creche Pokémon (pedido do dono em 03/11/2026).
--
-- O jogador paga moedas para a Creche treinar um Pokémon: ele sobe de
-- nível na hora (e pode evoluir como sempre, quando o jogador quiser).
-- Limites (Administração → Ajustes do jogo → Creche):
--   • cada nível custa (nível que ele vai alcançar × preco_por_nivel) moedas, 10;
--   • no máximo niveis_semana níveis por semana, somando todos os Pokémon, 5;
--   • só até o nível nivel_max, 40.
-- A semana começa na segunda-feira (horário do jogo).
-- Tabela creche_log (cada um lê o seu). Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

create or replace function public.creche_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "preco_por_nivel": 10, "niveis_semana": 5, "nivel_max": 40}'::jsonb || coalesce(public.cfg()->'creche', '{}'::jsonb)
$$;

create table if not exists public.creche_log (
  id         bigserial primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  mon_id     uuid,
  species    int  not null,
  level_from int  not null,
  level_to   int  not null,
  niveis     int  not null,
  custo      int  not null,
  created_at timestamptz not null default now()
);
create index if not exists creche_log_user on public.creche_log (user_id, created_at desc);
alter table public.creche_log enable row level security;
drop policy if exists creche_log_read on public.creche_log;
create policy creche_log_read on public.creche_log for select to authenticated using (user_id = auth.uid());
grant select on public.creche_log to authenticated;

-- início da semana do jogo (segunda-feira)
create or replace function public.creche_semana() returns timestamptz
language sql stable security definer set search_path = public, extensions as $$
  select date_trunc('week', public.game_today()::timestamp) at time zone coalesce(public.cfg()->>'timezone', 'America/Sao_Paulo')
$$;

-- preço para subir um Pokémon de _lvl até _lvl + _n
create or replace function public.creche_preco(_lvl int, _n int) returns int
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(sum(l * (public.creche_cfg()->>'preco_por_nivel')::int), 0)::int from generate_series(_lvl + 1, _lvl + greatest(_n, 0)) l
$$;

create or replace function public.creche_estado() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.creche_cfg(); usados int;
begin
  if uid is null then raise exception 'Entre na sua conta.'; end if;
  select coalesce(sum(niveis), 0) into usados from creche_log where user_id = uid and created_at >= public.creche_semana();
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'preco_por_nivel', (c->>'preco_por_nivel')::int,
    'niveis_semana', (c->>'niveis_semana')::int, 'nivel_max', (c->>'nivel_max')::int, 'usados', usados,
    'restante', greatest(0, (c->>'niveis_semana')::int - usados),
    'renova', public.creche_semana() + interval '7 days',
    'historico', coalesce((select jsonb_agg(jsonb_build_object('species', l.species, 'level_from', l.level_from, 'level_to', l.level_to, 'custo', l.custo, 'created_at', l.created_at) order by l.id desc)
      from (select * from creche_log where user_id = uid order by id desc limit 10) l), '[]'::jsonb));
end $$;

create or replace function public.creche_treinar(_mon uuid, _niveis int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.creche_cfg(); me characters; m monsters; p pokemon; usados int; alvo int; custo int; falta int;
begin
  if not coalesce((c->>'on')::boolean, true) then raise exception 'A Creche está fechada no momento.'; end if;
  select * into me from characters where user_id = uid for update;
  select * into m from monsters where id = _mon and user_id = uid for update;
  if m.id is null then raise exception 'Escolha um Pokémon seu.'; end if;
  if _niveis is null or _niveis < 1 then raise exception 'Escolha quantos níveis.'; end if;
  select coalesce(sum(niveis), 0) into usados from creche_log where user_id = uid and created_at >= public.creche_semana();
  if usados + _niveis > (c->>'niveis_semana')::int then
    raise exception 'A Creche treina no máximo % níveis por semana. Você ainda pode usar %.', c->>'niveis_semana', greatest(0, (c->>'niveis_semana')::int - usados);
  end if;
  alvo := m.level + _niveis;
  if alvo > (c->>'nivel_max')::int then raise exception 'A Creche só treina até o nível %.', c->>'nivel_max'; end if;
  custo := public.creche_preco(m.level, _niveis);
  if me.coins < custo then raise exception 'Custa % moedas e você tem %.', custo, me.coins; end if;
  select * into p from pokemon where id = m.species_id;
  falta := greatest(1, public.pk_exp_for(p.growth_rate, alvo) - m.exp);
  update characters set coins = coins - custo where id = me.id;
  perform public.pk_give_xp(m.id, falta, 'creche');
  select * into m from monsters where id = m.id;
  insert into creche_log(user_id, mon_id, species, level_from, level_to, niveis, custo) values (uid, m.id, m.species_id, alvo - _niveis, m.level, _niveis, custo);
  return jsonb_build_object('custo', custo, 'level', m.level, 'coins', me.coins - custo,
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.id) from mon_events e where e.user_id = uid and not e.seen), '[]'::jsonb));
end $$;

-- números para a aba Ajustes do jogo (versão do 60 + Creche)
create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'base', public.cfg());
end $$;

-- ---------- permissões ----------
revoke execute on function public.creche_cfg(), public.creche_semana(), public.creche_preco(int, int) from public, anon, authenticated;
revoke execute on function public.creche_estado(), public.creche_treinar(uuid, int) from public, anon;
grant execute on function public.creche_estado(), public.creche_treinar(uuid, int) to authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🏡 Nova: Creche Pokémon', 'Abriu a Creche Pokémon (menu Pokémon)!
• Escolha um Pokémon e quantos níveis ele vai treinar: ele sobe na hora.
• Cada nível custa moedas: o nível que ele vai alcançar × 10 (do 10 para o 11 custa 110).
• Limite: até 5 níveis por semana (somando todos os seus Pokémon) e só até o nível 40.
• Se ele chegar no nível de evoluir, você escolhe a hora, como sempre.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
