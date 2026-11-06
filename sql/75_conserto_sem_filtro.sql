-- =====================================================================
-- POKEGAMES — Conserto: "DELETE requires a WHERE clause" (06/11/2026).
-- O Supabase bloqueia, nas chamadas que vêm do site, UPDATE e DELETE sem
-- WHERE na tabela inteira. Isso travava a tentativa de captura da caverna
-- (o fim da caverna começa a temporada nova, que troca o mapa e devolve
-- todos à largada) e travaria o prêmio do Lendário do mapa.
-- Aqui as mesmas funções voltam com "where true": o resultado é igual.
-- Novas versões de board_swap (versão do 70), start_new_season (versão do 71)
-- e boss_attack (versão do 09). Nada mais muda.
-- Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

-- troca do mapa na temporada nova (versão do 70)
create or replace function public.board_swap() returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare n int;
begin
  select count(*) into n from board_next;
  if n = 0 then return false; end if;
  -- pousadas devolvidas, lendário e Caçada fogem
  update characters ch set coins = ch.coins + p.total
    from (select owner, sum(price)::int as total from properties group by owner) p where p.owner = ch.user_id;
  delete from properties where true;
  update world_bosses set status = 'fugiu' where status = 'ativo';
  update world_bosses set node = 0 where true;
  update hunts set status = 'fugiu' where status in ('ativa', 'tentando');
  update characters set node = 0, path = '{0}', route = '{}'::jsonb where true;
  -- casas novas
  insert into board_nodes (id, x, y, kind, value, region, branch, next_a, next_b, dist)
  select id, x, y, kind, value, region, branch, next_a, next_b, dist from board_next
  on conflict (id) do update set x = excluded.x, y = excluded.y, kind = excluded.kind, value = excluded.value, region = excluded.region,
    branch = excluded.branch, next_a = excluded.next_a, next_b = excluded.next_b, dist = excluded.dist, hm = null, hunt_id = null, hidden = false, npc = null;
  delete from board_nodes where id not in (select id from board_next);
  -- casas especiais pelas mesmas regras do arquivo 42 (Mina, Desafio, Ladrão, Fonte) e do 43 (Treinador)
  with cand as (select id, row_number() over (order by id) rn from board_nodes where kind = 'normal' and dist between 8 and (select max(dist) - 8 from board_nodes))
  update board_nodes b set kind = (array['mina', 'desafio', 'ladrao', 'fonte'])[((c.rn / 6) % 4) + 1] from cand c where b.id = c.id and c.rn % 6 = 3;
  with cand as (select id, row_number() over (order by id) rn from board_nodes where kind = 'normal' and dist between 10 and (select max(dist) - 6 from board_nodes))
  update board_nodes b set kind = 'treinador' from cand c where b.id = c.id and c.rn % 11 = 5;
  -- obstáculos das HMs pelas regras do arquivo 47
  update board_nodes b set hm = x.hm from (
    select id, hm, row_number() over (partition by region order by id) rn, count(*) over (partition by region) n from (
      select id, region, case
        when region in ('Floresta', 'Bosque Antigo', 'Jardins Reais') then 'CUT'
        when region in ('Praia', 'Aldeia dos Pescadores', 'Cidade Portuária', 'Ponte Velha') then 'SURF'
        when region in ('Montanha', 'Desfiladeiro', 'Cratera', 'Escadaria do Trovão', 'Vale dos Ventos') then 'STRENGTH'
        when region in ('Caverna Escura', 'Atalho das Sombras', 'Bosque Enevoado', 'Mosteiro') then 'FLASH' end hm
      from board_nodes where kind = 'normal' and next_b is null and hunt_id is null and not hidden) y
    where hm is not null) x
  where b.id = x.id and (x.rn % 8 = 4 or (x.n < 8 and x.rn = (x.n + 1) / 2));
  perform public.red_colocar();   -- o Red perto do Castelo (arquivo 70)
  delete from board_next where true;
  insert into event_log(kind, message) values ('temporada', 'O mundo cresceu! O tabuleiro agora tem ' || n || ' casas. Boa sorte na nova temporada.');
  insert into posts(kind, title, body, created_by)
  select 'novidade', '🗺️ O mapa cresceu: ' || n || ' casas!', 'Nesta temporada o tabuleiro ficou maior: agora são ' || n || ' casas, ' || (n - 443) || ' a mais que antes.
• As 9 bifurcações continuam, com o mesmo equilíbrio entre a rota segura e a arriscada.
• As casas especiais (Mina, Desafio, Ladrão, Fonte, Treinadores) e os obstáculos das HMs foram espalhados de novo.
• As pousadas foram devolvidas aos donos com 100% do valor, porque as casas mudaram de lugar.
Boa corrida!', coalesce((select user_id from user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  where not exists (select 1 from posts where title = '🗺️ O mapa cresceu: ' || n || ' casas!');
  return true;
end $$;

-- temporada nova (versão do 71)
create or replace function public.start_new_season() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare nid int;
begin
  perform public.board_swap();   -- mapa novo guardado (arquivo 68): troca agora, com todos voltando à largada
  update seasons set status = 'encerrada', ended_on = coalesce(ended_on, game_today()) where status = 'ativa';
  insert into seasons(started_on) values (game_today()) returning id into nid;
  update characters set node = 0, path = '{0}', route = '{}'::jsonb, arrived_rank = null, arrived_at = null, bonus_steps = 0 where true;
  update traps set triggered_at = now() where triggered_at is null;
  insert into event_log(kind, message) values ('temporada', 'A temporada ' || nid || ' começou! Todos voltaram para a largada.'
    || case when coalesce((public.temporada_cfg()->>'troca_heroi_gratis')::boolean, true)
            then ' Nos primeiros ' || (public.temporada_cfg()->>'troca_heroi_dias') || ' dias, cada um pode trocar de herói de graça, uma vez.' else '' end);
end $$;

-- ataque ao Lendário do mapa (versão do 09)
create or replace function public.boss_attack(_coins int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.cfg(); t date := public.game_today(); b world_bosses; me characters; dmg int; bname text;
begin
  select * into b from world_bosses where status = 'ativo' order by id desc limit 1 for update;
  if b.id is null then raise exception 'Não há nenhum lendário no mapa agora.'; end if;
  if not exists (select 1 from boss_contacts where boss_id = b.id and user_id = uid) then raise exception 'Passe pela casa do lendário no mapa para poder atacar.'; end if;
  if exists (select 1 from boss_attacks where boss_id = b.id and user_id = uid and d = t) then raise exception 'Você já atacou hoje. Volte amanhã.'; end if;
  if _coins < (c->>'boss_min_attack')::int or _coins > (c->>'boss_max_attack')::int then
    raise exception 'O ataque deve usar de % a % moedas.', (c->>'boss_min_attack'), (c->>'boss_max_attack');
  end if;
  select * into me from characters where user_id = uid for update;
  if me.coins < _coins then raise exception 'Moedas insuficientes.'; end if;
  dmg := round(_coins * (1 + me.level * 0.02) * case when me.class::text = 'guerreiro' then 1.25 else 1 end)::int;
  update characters set coins = coins - _coins where id = me.id;
  insert into boss_attacks(boss_id, user_id, d, coins, damage) values (b.id, uid, t, _coins, dmg);
  update world_bosses set hp = greatest(0, hp - dmg) where id = b.id returning * into b;
  bname := (select name from pokemon where id = b.pokemon_id);
  if b.hp = 0 then
    update world_bosses set status = 'derrotado', defeated_at = now() where id = b.id;
    update characters set xp_buff_until = greatest(coalesce(xp_buff_until, t), t + (c->>'boss_buff_days')::int - 1) where true;
    insert into event_log(user_id, kind, message) values (uid, 'lendario', me.name || ' deu o golpe final! ' || bname || ' foi derrotado e todos ganharam XP extra por ' || (c->>'boss_buff_days') || ' dias.');
  else
    insert into event_log(user_id, kind, message) values (uid, 'lendario', me.name || ' atacou ' || bname || ' e causou ' || dmg || ' de dano.');
  end if;
  return public.boss_state() || jsonb_build_object('damage', dmg);
end $$;
