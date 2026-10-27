-- =====================================================================
-- 32_chance_lendarios.sql
-- Pedido do dono em 22/10/2026: chance de cada lendário na caverna da Liga.
--   Articuno, Zapdos e Moltres: 30% cada · Mewtwo: 7% · Mew: 3%.
-- Os números ficam em game_config.config.league_legend_pct e podem ser
-- trocados sem site (ex.: incluir os lendários da 2ª geração: 243, 244,
-- 245, 249, 250, 251). Os da 2ª só entram com ela ligada E com chance > 0.
-- Depende do 31. Só muda o sorteio; a captura continua 5%.
-- =====================================================================

update public.game_config
   set config = config || jsonb_build_object('league_legend_pct',
       '{"144":30,"145":30,"146":30,"150":7,"151":3}'::jsonb)
 where active and not (config ? 'league_legend_pct');

create or replace function public.league_crown(_lg int, _champ uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare lg leagues; nm text; leg int; lv int; item text; w jsonb := coalesce(public.cfg()->'league_legend_pct', '{"144":30,"145":30,"146":30,"150":7,"151":3}'::jsonb); tot numeric; r numeric;
begin
  select * into lg from leagues where id = _lg for update;
  if lg.status <> 'rodada' or _champ is null then return; end if;
  select name into nm from characters where user_id = _champ;
  -- sorteio com peso: cada lendário tem a sua chance (league_legend_pct)
  select sum((e.value)::numeric) into tot from jsonb_each_text(w) e
   where (e.value)::numeric > 0 and exists (select 1 from pokemon p where p.id = e.key::int and (p.id <= 151 or public.gen2_on()));
  if coalesce(tot, 0) <= 0 then w := '{"144":30,"145":30,"146":30,"150":7,"151":3}'::jsonb; tot := 100; end if;
  r := random() * tot;
  select k into leg from (
    select e.key::int k, sum((e.value)::numeric) over (order by e.key::int) acc
      from jsonb_each_text(w) e
     where (e.value)::numeric > 0 and exists (select 1 from pokemon p where p.id = e.key::int and (p.id <= 151 or public.gen2_on()))
  ) t where acc > r order by acc limit 1;
  leg := coalesce(leg, 144);
  select greatest(5, least(100, round(avg(level))))::int into lv from monsters;
  item := 'aura_campeao_' || lg.season_id;
  insert into shop_items(id, name, slot, price, min_level, rarity, data, exclusive, coins_ok)
  values (item, 'Aura do Campeão: ' || lg.name, 'aura', 0, 1, 'lendario', jsonb_build_object('c1', '#FFD54A', 'shiny', true, 'league', lg.name), true, false)
  on conflict (id) do nothing;
  update characters set owned_items = case when item = any(owned_items) then owned_items else array_append(owned_items, item) end where user_id = _champ;
  insert into villages(user_id) values (_champ) on conflict do nothing;
  update villages set castles = castles + 1 where user_id = _champ;
  update leagues set status = 'caverna', champion = _champ, champion_name = nm, legend_id = leg, legend_level = coalesce(lv, 30), aura_item = item,
         cave_open_at = now() + make_interval(hours => coalesce((public.cfg()->>'league_cave_hours')::int, 24)) where id = _lg;
  insert into event_log(user_id, kind, message) values (_champ, 'liga', '🏆 ' || nm || ' é o CAMPEÃO da ' || lg.name || '! Ganhou a Aura do Campeão e uma estátua no mapa, e entrou na caverna do ' ||
    (select name from pokemon where id = leg) || '. Daqui a 24 horas terá UMA chance de capturá-lo. Torça a favor ou contra!');
end $$;

-- conferência: mostra as chances gravadas
select p.name as lendario, (e.value)::numeric as chance_pct
  from public.game_config g, jsonb_each_text(g.config->'league_legend_pct') e
  join public.pokemon p on p.id = e.key::int
 where g.active order by (e.value)::numeric desc, p.id;
