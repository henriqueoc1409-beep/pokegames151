-- =====================================================================
-- POKEGAMES — Festa da Liga e troca de herói grátis na temporada nova
-- (pedido do dono em 03/11/2026).
--
-- No banco, só a troca de herói: quando a Liga acaba e começa a temporada
-- nova, cada jogador pode trocar de herói UMA vez, de graça, nos primeiros
-- `temporada.troca_heroi_dias` (3) dias. Nível, moedas, itens e Pokémon
-- continuam iguais (é a mesma troca da loja, sem cobrar). Liga/desliga:
-- `temporada.troca_heroi_gratis` (aba Ajustes do jogo).
-- O resto (animação do começo da Liga, Estádio da Liga no mapa com o
-- chaveamento e a tela maior das lutas da Liga) é só no site.
-- Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

alter table public.characters add column if not exists troca_gratis_season int;

create or replace function public.temporada_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"troca_heroi_gratis":true,"troca_heroi_dias":3}'::jsonb || coalesce(public.cfg()->'temporada', '{}'::jsonb);
$$;

-- a janela da troca grátis: temporada ativa, dentro dos primeiros dias, ainda não usada
create or replace function public.heroi_troca_estado() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); s seasons; c jsonb := public.temporada_cfg(); usada boolean; ate date;
begin
  select * into s from seasons order by id desc limit 1;
  if s.id is null then return jsonb_build_object('pode', false); end if;
  ate := s.started_on + greatest(1, (c->>'troca_heroi_dias')::int) - 1;
  usada := coalesce((select troca_gratis_season = s.id from characters where user_id = uid), false);
  return jsonb_build_object('season', s.id, 'started_on', s.started_on, 'ate', ate, 'usada', usada,
    'pode', coalesce((c->>'troca_heroi_gratis')::boolean, true) and s.status = 'ativa' and public.game_today() <= ate and not usada);
end $$;

create or replace function public.heroi_troca_gratis(_class public.char_class) returns public.characters
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters; st jsonb := public.heroi_troca_estado();
begin
  select * into me from characters where user_id = uid for update;
  if me.id is null then raise exception 'Crie seu personagem primeiro.'; end if;
  if not coalesce((st->>'pode')::boolean, false) then
    raise exception '%', case when (st->>'usada')::boolean then 'Você já usou a troca grátis desta temporada.' else 'A troca grátis de herói só vale nos primeiros dias da temporada.' end;
  end if;
  if me.class = _class then raise exception 'Você já é desse herói.'; end if;
  update characters set class = _class, skill_date = null, troca_gratis_season = (st->>'season')::int where id = me.id returning * into me;
  insert into event_log(user_id, kind, message) values (uid, 'heroi', me.name || ' aproveitou a temporada nova e trocou de herói.');
  return me;
end $$;

-- temporada nova (versão do 68 + aviso da troca grátis)
create or replace function public.start_new_season() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare nid int;
begin
  perform public.board_swap();   -- mapa novo guardado (arquivo 68): troca agora, com todos voltando à largada
  update seasons set status = 'encerrada', ended_on = coalesce(ended_on, game_today()) where status = 'ativa';
  insert into seasons(started_on) values (game_today()) returning id into nid;
  update characters set node = 0, path = '{0}', route = '{}'::jsonb, arrived_rank = null, arrived_at = null, bonus_steps = 0;
  update traps set triggered_at = now() where triggered_at is null;
  insert into event_log(kind, message) values ('temporada', 'A temporada ' || nid || ' começou! Todos voltaram para a largada.'
    || case when coalesce((public.temporada_cfg()->>'troca_heroi_gratis')::boolean, true)
            then ' Nos primeiros ' || (public.temporada_cfg()->>'troca_heroi_dias') || ' dias, cada um pode trocar de herói de graça, uma vez.' else '' end);
end $$;

-- números para a aba Ajustes do jogo (versão do 67 + temporada)
create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'leilao', public.leilao_cfg(), 'herois', public.herois_cfg(), 'temporada', public.temporada_cfg(), 'base', public.cfg());
end $$;

grant execute on function public.heroi_troca_estado(), public.heroi_troca_gratis(public.char_class) to authenticated;
revoke execute on function public.temporada_cfg() from public, anon, authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🏟️ Festa da Liga: Estádio, chaveamento e troca de herói grátis', 'A Liga ficou com cara de final de campeonato:
• 🎆 Quando a Liga começa, todo mundo vê a abertura com os confrontos da primeira fase.
• 🏟️ O Estádio da Liga apareceu ao lado do Castelo. Durante a Liga, todos os treinadores ficam lá, e um toque abre o chaveamento: quem enfrenta quem, fase por fase.
• ⚔️ As lutas da Liga têm uma tela própria, maior e dourada.
• 🛡️ Quando a Liga acaba e começa a temporada nova, cada um pode trocar de herói de graça, uma vez, nos primeiros 3 dias. Nível, moedas, itens e Pokémon continuam iguais.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
