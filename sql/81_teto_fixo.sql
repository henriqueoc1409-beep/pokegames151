-- =====================================================================
-- POKEGAMES — Teto de nível fixo nas batalhas valendo moedas (pedido do dono em 09/11/2026).
-- Antes (arquivo 77) o teto começava em 20 e subia 5 por temporada até 40.
-- Agora ele é SEMPRE o mesmo número, game_config.config.teto.nivel (padrão 20),
-- e não muda sozinho com a temporada. O admin troca em Ajustes do jogo →
-- 📏 Teto de nível nas batalhas. A Liga continua sem teto (league_side não usa).
-- Nada no Pokémon salvo muda: o teto vale só para a cópia da batalha (bt_mon_teto).
-- Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

create or replace function public.teto_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "nivel": 20}'::jsonb || coalesce(public.cfg()->'teto', '{}'::jsonb)
$$;

-- o teto é sempre o número da configuração (não sobe mais com a temporada)
create or replace function public.teto_calc() returns int
language sql stable security definer set search_path = public, extensions as $$
  select greatest(1, least(100, coalesce((public.teto_cfg()->>'nivel')::int, 20)))
$$;

-- tira os números antigos (que faziam subir por temporada) e deixa só liga/desliga e o nível
update public.game_config
   set config = jsonb_set(config, '{teto}', jsonb_build_object('on', coalesce((config->'teto'->>'on')::boolean, true), 'nivel', 20))
 where active;

revoke execute on function public.teto_cfg(), public.teto_calc() from public, anon, authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('📏 Batalhas sempre niveladas no 20', 'Nas batalhas Pokémon valendo moedas, ninguém luta acima do nível 20, em todas as temporadas (o limite não sobe mais).
• Quem está acima do 20 luta com a força do nível 20 (vida, ataque, defesa, velocidade e especial), e o XP também sai pelo 20.
• Ataques e evolução continuam os mesmos, e o Pokémon não perde nada: acabou a batalha, ele segue no nível dele.
• Na batalha aparece "Nv 20 (25)" para quem foi limitado.
• A Liga Pokémon continua sem limite: cada um luta no nível real.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
