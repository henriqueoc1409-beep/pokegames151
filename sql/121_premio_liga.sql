-- Arquivo 121 (pedido do dono em 17/11/2026, aprovado pelo grupo): prêmio da Liga Pokémon do tabuleiro.
-- Moedas na coroação (além dos prêmios do Castelo por posição): campeão 500, vice 300, 3º 150 (o perdedor da semifinal
-- com a melhor colocação). O campeão ganha +10% de XP na Aventura e +10% de salário até a coroação da próxima Liga, e o título
-- "Campeão da Temporada X" no cartão. Na caverna, se a captura falhar, o campeão recebe 3 Ultra Balls e 200 moedas.
-- Números em `liga` (Ajustes do jogo → Liga).

create or replace function public.liga_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"comeca_na_chegada":true,"mapa_parado":true,"fase_por_dia":false,"caverna_horas":0,"caverna_prazo_horas":24,"temporada_na_hora":true,
           "premio_campeao":500,"premio_vice":300,"premio_terceiro":150,"campeao_xp_pct":10,"campeao_salario_pct":10,
           "caverna_consolo_bolas":3,"caverna_consolo_moedas":200}'::jsonb
         || coalesce(public.cfg()->'liga', '{}'::jsonb);
$$;

-- títulos de campeão (públicos: aparecem no cartão do jogador)
create table if not exists public.liga_titulos (
  league_id int primary key,
  season_id int not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  vice uuid, terceiro uuid,
  created_at timestamptz not null default now()
);
alter table public.liga_titulos enable row level security;
drop policy if exists liga_titulos_ler on public.liga_titulos;
create policy liga_titulos_ler on public.liga_titulos for select to authenticated using (true);
grant select on public.liga_titulos to authenticated;

-- bônus do campeão da última Liga coroada (vale até a próxima coroação): tipo 'xp' ou 'salario'
create or replace function public.liga_campeao_pct(_uid uuid, _tipo text) returns numeric
language sql stable security definer set search_path = public, extensions as $$
  select case when _uid is not null and _uid = (select t.user_id from liga_titulos t order by t.league_id desc limit 1)
              then coalesce((public.liga_cfg()->>case _tipo when 'xp' then 'campeao_xp_pct' else 'campeao_salario_pct' end)::numeric, 0)
              else 0 end
$$;

-- paga o pódio da Liga e grava o título
create or replace function public.liga_podio(_lg int, _champ uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare lg leagues; c jsonb := public.liga_cfg(); fin league_matches; vice uuid; terc uuid; semi int; r record; v int;
begin
  select * into lg from leagues where id = _lg;
  if lg.id is null or exists (select 1 from liga_titulos where league_id = _lg) then return; end if;
  select * into fin from league_matches where league_id = _lg and kind = 'rodada' and (a = _champ or b = _champ) order by stage desc limit 1;
  if fin.id is not null then
    vice := case when fin.a = _champ then fin.b else fin.a end;
    select max(stage) into semi from league_matches where league_id = _lg and kind = 'rodada' and stage < fin.stage;
    select x.u into terc from (
      select case when m.winner = m.a then m.b else m.a end u from league_matches m where m.league_id = _lg and m.kind = 'rodada' and m.stage = semi and m.winner is not null) x
      join league_players p on p.league_id = _lg and p.user_id = x.u
     where x.u is not null and x.u <> _champ and x.u is distinct from vice
     order by p.seed limit 1;
  end if;
  insert into liga_titulos(league_id, season_id, user_id, vice, terceiro) values (_lg, lg.season_id, _champ, vice, terc);
  for r in select * from (values (_champ, 'premio_campeao', '🏆 Campeão'), (vice, 'premio_vice', '🥈 Vice-campeão'), (terc, 'premio_terceiro', '🥉 3º lugar')) t(u, k, nome) where t.u is not null loop
    v := coalesce((c->>r.k)::int, 0);
    continue when v <= 0;
    perform public.ext_origem('Prêmio da Liga', 'premios');
    update characters set coins = coins + v where user_id = r.u;
    insert into gifts(user_id, coins, message) values (r.u, v, r.nome || ' da ' || lg.name || '! Você ganhou ' || v || ' moedas.'
      || case when r.u = _champ then ' Até a próxima Liga você tem +' || (c->>'campeao_xp_pct') || '% de XP na Aventura e +' || (c->>'campeao_salario_pct') || '% de salário, e o título "Campeão da Temporada ' || lg.season_id || '".' else '' end);
  end loop;
  insert into event_log(kind, message) values ('liga', '🏆 Pódio da ' || lg.name || ': ' || coalesce((select name from characters where user_id = _champ), '?') || ' (' || (c->>'premio_campeao') || ' moedas)'
    || coalesce(', ' || (select name from characters where user_id = vice) || ' (' || (c->>'premio_vice') || ')', '')
    || coalesce(', ' || (select name from characters where user_id = terc) || ' (' || (c->>'premio_terceiro') || ')', '') || '.');
end $$;


-- league_crown: versão do 73 com a mudança do arquivo 121
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
         cave_open_at = now() + make_interval(hours => coalesce((public.liga_cfg()->>'caverna_horas')::int, 0)) where id = _lg;
  perform public.liga_podio(_lg, _champ);   -- arquivo 121: moedas do pódio, bônus e título
  insert into event_log(user_id, kind, message) values (_champ, 'liga', '🏆 ' || nm || ' é o CAMPEÃO da ' || lg.name || '! Ganhou a Aura do Campeão e uma estátua no mapa, e entrou na caverna do ' ||
    (select name from pokemon where id = leg) || case when coalesce((public.liga_cfg()->>'caverna_horas')::int, 0) > 0 then '. Daqui a ' || (public.liga_cfg()->>'caverna_horas') || ' horas terá UMA chance de capturá-lo. Torça a favor ou contra!' else '. Ele já pode tentar a captura: UMA chance só!' end);
end $$;


-- league_cave_try: versão do 74 com a mudança do arquivo 121
create or replace function public.league_cave_try() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); lg leagues; ok boolean;
begin
  select * into lg from leagues where status = 'caverna' order by id desc limit 1 for update;
  if lg.id is null then raise exception 'Não há ninguém na caverna agora.'; end if;
  if lg.champion <> uid then raise exception 'Só o campeão da Liga pode tentar capturar o lendário.'; end if;
  -- arquivo 74: com caverna_horas = 0 (padrão), o campeão tenta na hora, sem olhar o relógio
  if coalesce((public.liga_cfg()->>'caverna_horas')::int, 0) > 0 and now() < lg.cave_open_at then raise exception 'O lendário ainda não se aproximou. Tente depois de %.', to_char(lg.cave_open_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'); end if;
  ok := random() * 100 < coalesce((public.cfg()->>'league_capture_pct')::numeric, 5);
  update leagues set cave_tried_at = now() where id = lg.id;
  -- arquivo 121: se a captura falhar, o campeão leva um consolo
  if not ok then
    if coalesce((public.liga_cfg()->>'caverna_consolo_bolas')::int, 0) > 0 then
      insert into bag_items(user_id, item, qty) values (uid, 'ultra_ball', (public.liga_cfg()->>'caverna_consolo_bolas')::int)
      on conflict (user_id, item) do update set qty = bag_items.qty + excluded.qty;
    end if;
    if coalesce((public.liga_cfg()->>'caverna_consolo_moedas')::int, 0) > 0 then
      perform public.ext_origem('Consolo da caverna', 'premios');
      update characters set coins = coins + (public.liga_cfg()->>'caverna_consolo_moedas')::int where user_id = uid;
    end if;
  end if;
  perform public.league_cave_end(lg.id, ok);
  return jsonb_build_object('caught', ok, 'pokemon', lg.legend_id, 'level', lg.legend_level,
    'consolo', case when ok then null else jsonb_build_object('bolas', (public.liga_cfg()->>'caverna_consolo_bolas')::int, 'moedas', (public.liga_cfg()->>'caverna_consolo_moedas')::int) end);
end $$;


-- rpg_gin_xp: versão do 113 com a mudança do arquivo 121
create or replace function public.rpg_gin_xp(_bid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b battles; c jsonb := public.treino_cfg(); t jsonb; i int; j int; wi jsonb; ganho int; vivos int[]; parte int; gxp jsonb; xpd jsonb; tot int;
begin
  select * into b from battles where id = _bid for update;
  if b.id is null or not (b.state->'treino' ? 'multi') then return; end if;
  t := b.state->'treino'; gxp := coalesce(t->'gxp', '{}'::jsonb); xpd := coalesce(t->'xpd', '[]'::jsonb); tot := coalesce((t->>'gtot')::int, 0);
  for i in 0 .. jsonb_array_length(b.state->'sides'->1->'mons') - 1 loop
    wi := b.state->'sides'->1->'mons'->i;
    continue when (wi->>'hp')::int > 0 or xpd @> jsonb_build_array(i);
    xpd := xpd || jsonb_build_array(i);
    select coalesce(array_agg(x::int), '{}') into vivos from jsonb_array_elements_text(coalesce(t->'part'->(i::text), '[]'::jsonb)) x
     where (b.state->'sides'->0->'mons'->(x::int)->>'hp')::int > 0;
    continue when cardinality(vivos) = 0;
    ganho := greatest(1, floor((wi->>'bexp')::int * (wi->>'level')::int / 7.0 * (c->>'xp_mult')::numeric)::int);
    if public.heroi(b.p1) = 'domador' then ganho := ceil(ganho * (100 + (public.herois_cfg()->>'domador_grama_xp_pct')::numeric) / 100)::int; end if;
    ganho := ceil(ganho * (100 + public.vb(b.p1, 'academia', 'grama_xp_pct')) / 100)::int;
    ganho := ceil(ganho * (100 + public.eq_bonus(b.p1, 'calca') + public.liga_campeao_pct(b.p1, 'xp')) / 100)::int;   -- arquivo 121: campeão da Liga
    tot := tot + ganho;
    parte := greatest(1, ceil(ganho::numeric / cardinality(vivos)))::int;
    foreach j in array vivos loop gxp := gxp || jsonb_build_object(j::text, coalesce((gxp->>(j::text))::int, 0) + parte); end loop;
  end loop;
  update battles set state = jsonb_set(state, '{treino}', t || jsonb_build_object('gxp', gxp, 'xpd', xpd, 'gtot', tot)) where id = _bid;
end $$;


-- treino_after: versão do 113 com a mudança do arquivo 121
create or replace function public.treino_after(_bid uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.treino_cfg(); b battles; t jsonb; m monsters; won boolean; ganho int := 0; hp_fim int; lv2 int; res jsonb; me0 jsonb; wi jsonb; cx int := 0; csp int;
begin
  select * into b from battles where id = _bid for update;
  if b.id is null or b.mode <> 'treino' or b.status = 'ativa' then return null; end if;
  t := b.state->'treino';
  if coalesce((t->>'feito')::boolean, false) then return t->'res'; end if;
  if t ? 'multi' then return public.rpg_gin_fim(_bid); end if;   -- arquivo 113: Ginásio em batalha única
  select * into m from monsters where id = (t->>'mon')::uuid;
  me0 := b.state->'sides'->0->'mons'->0; wi := b.state->'sides'->1->'mons'->0;
  won := b.end_reason <> 'desistencia' and (me0->>'hp')::int > 0
         and ((wi->>'hp')::int <= 0 or (b.end_reason = 'limite' and b.winner is not null));
  hp_fim := greatest(0, least(100, floor((me0->>'hp')::numeric * 100 / greatest(1, (me0->>'maxhp')::int))))::int;
  if (me0->>'hp')::int > 0 then hp_fim := greatest(1, hp_fim); end if;
  if m.id is not null then
    update monsters set tr_hp = hp_fim, tr_hurt_at = case when hp_fim < m.tr_hp then now() else tr_hurt_at end where id = m.id;
    if won then
      ganho := greatest(1, floor((wi->>'bexp')::int * (wi->>'level')::int / 7.0 * (c->>'xp_mult')::numeric
               * case when (t->>'forte')::boolean then (c->>'forte_xp_mult')::numeric else 1 end)::int);
      if public.heroi(b.p1) = 'domador' then ganho := ceil(ganho * (100 + (public.herois_cfg()->>'domador_grama_xp_pct')::numeric) / 100)::int; end if;   -- Domador: +XP
      ganho := ceil(ganho * (100 + public.vb(b.p1, 'academia', 'grama_xp_pct')) / 100)::int;   -- arquivo 82: Academia da vila
      ganho := ceil(ganho * (100 + public.eq_bonus(b.p1, 'calca') + public.liga_campeao_pct(b.p1, 'xp')) / 100)::int;   -- arquivo 121: campeão da Liga   -- arquivo 103: Calça
      perform public.pk_give_xp(m.id, ganho, 'treino');
      -- acompanhante (arquivo 63): ganha uma parte da experiência, como o Exp. Share
      if (t->>'comp') is not null then
        select species_id into csp from monsters where id = (t->>'comp')::uuid and user_id = b.p1;
        if csp is not null then
          cx := greatest(1, floor(ganho * case when public.heroi(b.p1) = 'pesquisador' then (public.herois_cfg()->>'pesq_comp_pct')::numeric else coalesce((c->>'acompanhante_pct')::numeric, 50) end / 100))::int;   -- Pesquisador: acompanhante ganha mais
          perform public.pk_give_xp((t->>'comp')::uuid, cx, 'treino');
        end if;
      end if;
    end if;
    select level into lv2 from monsters where id = m.id;
  end if;
  insert into treino_dias(user_id, dia) values (b.p1, public.game_today()) on conflict do nothing;
  update treino_dias set lutas = lutas + 1, vitorias = vitorias + won::int, xp = treino_dias.xp + ganho where user_id = b.p1 and dia = public.game_today();
  if hp_fim = 0 then
    b.log := b.log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt',
      (me0->>'name') || ' desmaiou! Leve ao Centro Pokémon ou espere ' || (c->>'gratis_horas') || ' horas para ele se recuperar de graça.'))));
  end if;
  res := jsonb_build_object('won', won, 'xp', ganho, 'comp_xp', cx, 'comp_species', csp, 'forte', (t->>'forte')::boolean, 'wild', (wi->>'species')::int, 'wild_level', (wi->>'level')::int,
    'species', m.species_id, 'level_from', m.level, 'level_to', coalesce(lv2, m.level), 'hp', hp_fim, 'desmaiou', hp_fim = 0,
    'fugiu', b.end_reason = 'desistencia');
  insert into treino_lutas(user_id, mon_id, species, wild, wild_level, won, xp, level_from, level_to, log)
  values (b.p1, m.id, coalesce(m.species_id, (me0->>'species')::int), (wi->>'species')::int, (wi->>'level')::int, won, ganho, coalesce(m.level, 1), coalesce(lv2, m.level, 1), b.log);
  delete from treino_lutas where user_id = b.p1 and id not in (select id from treino_lutas where user_id = b.p1 order by id desc limit (c->>'lutas_guardadas')::int);
  update battles set log = b.log, state = jsonb_set(state, '{treino}', t || jsonb_build_object('feito', true, 'res', res)) where id = b.id;
  return res;
end $$;


-- walk: versão do 103 com a mudança do arquivo 121
create or replace function public.walk(_cid uuid, _steps int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare ch characters; n board_nodes; cur int; p int[]; sal int := 0; c jsonb := cfg(); i int;
begin
  select * into ch from characters where id = _cid;
  cur := ch.node; p := ch.path;
  for i in 1..greatest(_steps,0) loop
    select * into n from board_nodes where id = cur;
    exit when n.kind = 'castelo' or n.next_a is null;
    cur := case when n.next_b is not null and ch.route->>(n.id::text) = 'b' then n.next_b else n.next_a end;
    p := p || cur;
    if (select kind from board_nodes where id = cur) = 'pagamento' then
      sal := sal + (c->>'salary_base')::int + (c->>'salary_per_level')::int * ch.level;
    end if;
  end loop;
  -- Taverna aumenta o salário
  if sal > 0 and exists (select 1 from villages where user_id = ch.user_id and tavern_level > 0) then
    sal := ceil(sal * (100 + coalesce((c->>'tavern_pct')::int, 15)) / 100.0)::int;
  end if;
  -- Mercador (arquivo 67): salário maior
  if sal > 0 and ch.class::text = 'mercador' then sal := ceil(sal * (100 + (public.herois_cfg()->>'merc_salario_pct')::numeric) / 100.0)::int; end if;
  -- arquivo 82: a Mina da vila aumenta o salário
  if sal > 0 then sal := ceil(sal * (100 + public.vb(ch.user_id, 'mina', 'salario_pct') + public.eq_bonus(ch.user_id, 'capacete') + public.liga_campeao_pct(ch.user_id, 'salario')) / 100.0)::int; end if;   -- arquivo 103: Capacete
  -- Snorlax da rodada recebe menos no Dia de pagamento
  if sal > 0 and ch.user_id = public.snorlax_id() then
    sal := floor(sal * coalesce((c->>'snorlax_salary_pct')::int, 90) / 100.0)::int;
  end if;
  update characters set node = cur, path = p, coins = coins + sal where id = _cid;
  return jsonb_build_object('node', cur, 'salary', sal);
end $$;


revoke execute on function public.liga_podio(int, uuid) from public, anon, authenticated;
revoke execute on function public.liga_campeao_pct(uuid, text) from public, anon;
grant execute on function public.liga_campeao_pct(uuid, text) to authenticated;

insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values
   ('🏆 Liga Pokémon com prêmio para o pódio', 'A Liga Pokémon do tabuleiro agora paga o pódio, além dos prêmios do Castelo:
• Campeão: 500 moedas, +10% de XP na Aventura e +10% de salário até a próxima Liga, e o título "Campeão da Temporada" no cartão.
• Vice: 300 moedas.
• 3º lugar (quem perdeu na semifinal com a melhor colocação): 150 moedas.
• Na caverna, se o lendário escapar, o campeão leva 3 Ultra Balls e 200 moedas de consolo.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
