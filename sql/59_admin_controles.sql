-- =====================================================================
-- POKEGAMES — Controles do admin (pedido do dono em 29/10/2026: "fazer o que
-- quiser no jogo sem ficar pedindo").
--
-- 1) Tempo extra na Grama de Treino para um jogador, só no dia de hoje:
--    treino_dias.bonus e admin_treino_bonus(jogador, minutos, motivo).
--    Vai para a Auditoria. O jogador vê o tempo a mais no relógio.
-- 2) admin_cfg_efetiva(): mostra ao admin TODOS os números de cada sistema
--    (Grama de Treino, Pokémon, casas do mapa, itens, guerras, Rocket),
--    já com os valores padrão, para o site montar a aba "Ajustes do jogo".
--    Salvar usa o admin_set_config de sempre (vai para a Auditoria).
-- Não muda nada para quem não é admin. Depende do 56.
-- Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

alter table public.treino_dias add column if not exists bonus int not null default 0;

create or replace function public.admin_treino_bonus(_user uuid, _min int, _reason text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare d treino_dias; old int;
begin
  perform public.assert_admin();
  if _min is null or _min = 0 or _min not between -600 and 600 then raise exception 'Minutos: de -600 a 600 (sem o zero).'; end if;
  if not exists (select 1 from characters where user_id = _user) then raise exception 'Jogador não encontrado.'; end if;
  insert into treino_dias(user_id, dia) values (_user, public.game_today()) on conflict do nothing;
  select bonus into old from treino_dias where user_id = _user and dia = public.game_today();
  update treino_dias set bonus = bonus + _min where user_id = _user and dia = public.game_today() returning * into d;
  perform public.audit('treino_bonus', _user::text, jsonb_build_object('bonus', old), jsonb_build_object('bonus', d.bonus, 'minutos', _min), _reason);
  return jsonb_build_object('bonus', d.bonus, 'minutos', d.minutos, 'livre', (public.treino_cfg()->>'minutos_dia')::int + d.bonus - d.minutos);
end $$;

create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'base', public.cfg());
end $$;

-- entrar na grama (versão do 56 + tempo extra do admin)
create or replace function public.treino_entrar(_min int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.treino_cfg(); v treino_visitas; d treino_dias; m int;
begin
  if not coalesce((c->>'on')::boolean, true) then raise exception 'A Grama de Treino está fechada no momento.'; end if;
  perform 1 from characters where user_id = uid for update;
  v := public.treino_visita(uid);
  if v.id is not null then return public.treino_estado(); end if;   -- já está lá dentro
  if not (c->'visita_opcoes' @> to_jsonb(_min)) then raise exception 'Escolha quanto tempo quer ficar: % minutos.', (select string_agg(x, ' ou ') from jsonb_array_elements_text(c->'visita_opcoes') x); end if;
  insert into treino_dias(user_id, dia) values (uid, public.game_today()) on conflict do nothing;
  select * into d from treino_dias where user_id = uid and dia = public.game_today() for update;
  m := least(_min, (c->>'minutos_dia')::int + d.bonus - d.minutos);   -- bonus = tempo extra dado pelo admin hoje
  if m <= 0 then raise exception 'Seu tempo de treino de hoje acabou (% minutos). Volte amanhã!', c->>'minutos_dia'; end if;
  insert into treino_visitas(user_id, dia, fim, minutos) values (uid, d.dia, now() + make_interval(mins => m), m);
  update treino_dias set minutos = minutos + m where user_id = uid and dia = d.dia;
  return public.treino_estado();
end $$;

-- estado do treino (versão do 56 + tempo extra do admin)
create or replace function public.treino_estado() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.treino_cfg(); d treino_dias; v treino_visitas;
begin
  if uid is null then raise exception 'Entre na sua conta.'; end if;
  perform public.treino_autocura(uid);
  select * into d from treino_dias where user_id = uid and dia = public.game_today();
  v := public.treino_visita(uid);
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'modo', 'andar', 'minutos_dia', (c->>'minutos_dia')::int,
    'opcoes', c->'visita_opcoes', 'encontro_seg', (c->>'encontro_seg')::int,
    'nivel_menos', (c->>'nivel_menos')::int, 'nivel_mais', (c->>'nivel_mais')::int, 'gratis_horas', (c->>'gratis_horas')::int, 'agora', now(),
    'minutos', coalesce(d.minutos, 0), 'bonus', coalesce(d.bonus, 0), 'lutas', coalesce(d.lutas, 0), 'vitorias', coalesce(d.vitorias, 0), 'xp', coalesce(d.xp, 0),
    'visita', case when v.id is null then null else jsonb_build_object('id', v.id, 'fim', v.fim, 'minutos', v.minutos, 'inicio', v.inicio) end,
    'batalha', public.treino_batalha(uid),
    'feridos', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'tr_hp', m.tr_hp, 'preco', public.centro_preco(m.level, m.tr_hp),
        'gratis_em', coalesce(m.tr_hurt_at, now()) + make_interval(hours => (c->>'gratis_horas')::int)) order by m.tr_hp, m.level desc)
      from monsters m where m.user_id = uid and m.tr_hp < 100), '[]'::jsonb),
    'ultimas', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'mon_id', l.mon_id, 'species', l.species, 'wild', l.wild, 'wild_level', l.wild_level,
        'won', l.won, 'xp', l.xp, 'level_from', l.level_from, 'level_to', l.level_to, 'created_at', l.created_at) order by l.id desc)
      from treino_lutas l where l.user_id = uid), '[]'::jsonb));
end $$;

-- ---------- permissões ----------
revoke execute on function public.admin_treino_bonus(uuid, int, text), public.admin_cfg_efetiva() from public, anon;
grant execute on function public.admin_treino_bonus(uuid, int, text), public.admin_cfg_efetiva() to authenticated;
