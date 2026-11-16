-- Arquivo 120 (pedido do dono em 17/11/2026, aprovado pelo grupo): prêmios da temporada.
-- (1) Empate: as 150 moedas da categoria são divididas entre os empatados (a medalha vai para todos).
-- (2) 10 categorias novas: evoluções, insígnias (1ª vitória em cada Ginásio), ataques vencidos e defesas vencidas nas guerras,
--     Rei das cartas (duelos de cartas, sem treino), Rei do PokeBound (partidas entre jogadores), missões da Aventura, dano no Chefe,
--     Maior negociante (compras + vendas no Mercado e no Leilão + trocas) e Azarado da Temporada (casas perdidas no Lamaçal, no Raio,
--     na Armadilha e no Duelo, guardadas em `casas_perdidas` a partir de agora).
-- (3) "Mais dano na Equipe Rocket" vira "Mais ondas vencidas contra a Rocket" (`rocket_entries.ondas`, usado pelo arquivo 122).

alter table public.rocket_entries add column if not exists ondas int not null default 0;

-- casas perdidas (Azarado da Temporada)
create table if not exists public.casas_perdidas (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  casas int not null,
  motivo text not null,
  created_at timestamptz not null default now()
);
create index if not exists casas_perdidas_user on public.casas_perdidas (user_id, created_at);
alter table public.casas_perdidas enable row level security;
drop policy if exists casas_perdidas_minhas on public.casas_perdidas;
create policy casas_perdidas_minhas on public.casas_perdidas for select to authenticated using (user_id = auth.uid() or public.is_admin());
grant select on public.casas_perdidas to authenticated;

-- marca o motivo da próxima volta de casas (vale uma vez)
create or replace function public.perda_motivo(_m text) returns void
language sql volatile as $$ select set_config('pg.perda', coalesce(_m, ''), true) $$;

create or replace function public.go_back(_cid uuid, _k int) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare p int[]; l int; cur int; mot text := nullif(current_setting('pg.perda', true), ''); uid uuid;
begin
  perform set_config('pg.perda', '', true);
  select path, node, user_id into p, cur, uid from characters where id = _cid;
  if public.is_shielded(_cid) then return cur; end if;
  l := greatest(1, coalesce(array_length(p,1),1) - _k);
  update characters set path = p[1:l], node = p[l] where id = _cid;
  -- arquivo 120: casas perdidas no Lamaçal, Raio, Armadilha e Duelo (Azarado da Temporada)
  if mot is not null and coalesce(array_length(p,1),1) - l > 0 then
    insert into casas_perdidas(user_id, casas, motivo) values (uid, coalesce(array_length(p,1),1) - l, mot);
  end if;
  return p[l];
end $$;

create or replace function public.season_award_cats() returns jsonb
language sql immutable as $$
  select '[
    {"id":"casas","nome":"Mais casas andadas","titulo":"Andarilho da Temporada","ic":"🥾","un":"casas"},
    {"id":"capturas","nome":"Mais Pokémon capturados","titulo":"Rei das Capturas","ic":"🎯","un":"capturas"},
    {"id":"rodadas","nome":"Mais vitórias na rodada do dia","titulo":"Mestre do Desafio","ic":"🧠","un":"vitórias"},
    {"id":"batalhas","nome":"Mais batalhas Pokémon vencidas","titulo":"Campeão das Batalhas","ic":"⚔️","un":"vitórias"},
    {"id":"duelos","nome":"Mais duelos vencidos","titulo":"Duelista da Temporada","ic":"🤺","un":"vitórias"},
    {"id":"rocket","nome":"Mais ondas vencidas contra a Rocket","titulo":"Terror da Rocket","ic":"🚀","un":"ondas"},
    {"id":"quiz","nome":"Mais vitórias no Quiz","titulo":"Gênio do Quiz","ic":"❓","un":"vitórias"},
    {"id":"treinadores","nome":"Mais treinadores vencidos","titulo":"Caçador de Treinadores","ic":"🧢","un":"vitórias"},
    {"id":"moedas","nome":"Mais moedas ganhas andando","titulo":"Magnata","ic":"💰","un":"moedas"},
    {"id":"primeira","nome":"Mais acertos de primeira","titulo":"Olho de Águia","ic":"👁️","un":"acertos"},
    {"id":"pokedex","nome":"Mais espécies novas na Pokédex","titulo":"Pesquisador Pokémon","ic":"📖","un":"espécies"},
    {"id":"cacadas","nome":"Mais Caçadas vencidas","titulo":"Caçador de Lendas","ic":"🔍","un":"Caçadas"},
    {"id":"evolucoes","nome":"Mais evoluções","titulo":"Mestre das Evoluções","ic":"✨","un":"evoluções"},
    {"id":"insignias","nome":"Mais insígnias","titulo":"Colecionador de Insígnias","ic":"🏅","un":"insígnias"},
    {"id":"ataques","nome":"Mais ataques vencidos","titulo":"Conquistador","ic":"🏹","un":"vitórias"},
    {"id":"defesas","nome":"Mais defesas vencidas","titulo":"Muralha Viva","ic":"🛡️","un":"defesas"},
    {"id":"cartas","nome":"Rei das cartas","titulo":"Rei das Cartas","ic":"🃏","un":"vitórias"},
    {"id":"pokebound","nome":"Rei do PokeBound","titulo":"Rei do PokeBound","ic":"💥","un":"vitórias"},
    {"id":"missoes","nome":"Mais missões","titulo":"Aventureiro Dedicado","ic":"📜","un":"missões"},
    {"id":"chefe","nome":"Maior dano no Chefe","titulo":"Matador de Chefes","ic":"👹","un":"de dano"},
    {"id":"negociante","nome":"Maior negociante","titulo":"Maior Negociante","ic":"🤝","un":"negócios"},
    {"id":"azarado","nome":"Azarado da Temporada","titulo":"Azarado da Temporada","ic":"🍀","un":"casas perdidas"}
  ]'::jsonb
$$;

create or replace function public.season_rank(_cat text, _t0 timestamptz, _t1 timestamptz)
returns table(user_id uuid, val numeric)
language plpgsql stable security definer set search_path = public, extensions as $$
declare d0 date := (_t0 at time zone 'America/Sao_Paulo')::date;
        d1 date := ((_t1 at time zone 'America/Sao_Paulo') - interval '1 second')::date;   -- último dia que conta
begin
  if _cat = 'casas' then return query
    select m.user_id, sum(m.base_steps + m.roll + m.bonus_steps + coalesce(m.skill_steps, 0))::numeric from daily_moves m where m.move_date between d0 and d1 group by 1;
  elsif _cat = 'moedas' then return query
    select m.user_id, sum(greatest(m.coins_gained, 0))::numeric from daily_moves m where m.move_date between d0 and d1 group by 1;
  elsif _cat = 'capturas' then return query
    select e.user_id, count(*)::numeric from encounters e where e.status = 'capturado' and e.resolved_at >= _t0 and e.resolved_at < _t1 group by 1;
  elsif _cat = 'rodadas' then return query
    select r.user_id, count(*)::numeric from round_results r where r.rank = 1 and r.d between d0 and d1 group by 1;
  elsif _cat = 'batalhas' then return query
    select b.winner, count(*)::numeric from battles b where b.status = 'encerrada' and b.winner is not null and b.p1 <> b.p2
      and coalesce(b.mode, 'duelo') in ('duelo', 'liga') and b.ended_at >= _t0 and b.ended_at < _t1 group by 1;
  elsif _cat = 'duelos' then return query
    select d.winner, count(*)::numeric from duels d where d.status = 'concluido' and d.winner is not null
      and coalesce(d.resolved_at, d.created_at) >= _t0 and coalesce(d.resolved_at, d.created_at) < _t1 group by 1;
  elsif _cat = 'rocket' then return query   -- arquivo 120: ondas vencidas
    select e.user_id, sum(e.ondas)::numeric from rocket_entries e join rocket_raids r on r.id = e.raid_id
      where r.starts_at >= _t0 and r.starts_at < _t1 group by 1;
  elsif _cat = 'quiz' then return query
    select q.winner, count(*)::numeric from quizzes q where q.status = 'encerrado' and q.winner is not null
      and coalesce(q.closed_at, q.closes_at) >= _t0 and coalesce(q.closed_at, q.closes_at) < _t1 group by 1;
  elsif _cat = 'treinadores' then return query
    select f.user_id, count(*)::numeric from npc_fights f where f.won and f.created_at >= _t0 and f.created_at < _t1 group by 1;
  elsif _cat = 'primeira' then return query
    select g.user_id, count(*)::numeric from guess_sessions g where g.solved and g.attempts = 1 and not coalesce(g.recovered, false)
      and g.puzzle_date between d0 and d1 group by 1;
  elsif _cat = 'pokedex' then return query
    select p.user_id, count(*)::numeric from pokedex_entries p where p.caught_at >= _t0 and p.caught_at < _t1 group by 1;
  elsif _cat = 'cacadas' then return query
    select h.hunter, count(*)::numeric from hunts h where h.status = 'capturado' and h.hunter is not null
      and h.resolved_at >= _t0 and h.resolved_at < _t1 group by 1;
  -- arquivo 120: categorias novas
  elsif _cat = 'evolucoes' then return query
    select l.user_id, count(*)::numeric from event_log l where l.kind = 'evolucao' and l.user_id is not null and l.created_at >= _t0 and l.created_at < _t1 group by 1;
  elsif _cat = 'insignias' then return query
    select i.user_id, count(*)::numeric from rpg_insignias i where i.ganho_em >= _t0 and i.ganho_em < _t1 group by 1;
  elsif _cat = 'ataques' then return query
    select w.attacker, count(*)::numeric from wars w where w.winner = w.attacker and w.created_at >= _t0 and w.created_at < _t1 group by 1;
  elsif _cat = 'defesas' then return query
    select w.defender, count(*)::numeric from wars w where w.winner = w.defender and w.created_at >= _t0 and w.created_at < _t1 group by 1;
  elsif _cat = 'cartas' then return query
    select t.winner, count(*)::numeric from tcg_duelos t where t.status = 'encerrada' and not t.treino and t.winner is not null
      and t.ended_at >= _t0 and t.ended_at < _t1 group by 1;
  elsif _cat = 'pokebound' then return query
    select p.vencedor, count(*)::numeric from pb_partidas p where p.status = 'fim' and p.vencedor is not null and p.fim >= _t0 and p.fim < _t1 group by 1;
  elsif _cat = 'missoes' then return query
    select m.user_id, count(*)::numeric from rpg_missoes m where m.resgatada and m.dia between d0 and d1 group by 1;
  elsif _cat = 'chefe' then return query
    select d.user_id, sum(d.dano)::numeric from rpg_chefe_dano d join rpg_chefes c on c.id = d.chefe_id
      where c.inicio >= _t0 and c.inicio < _t1 group by 1;
  elsif _cat = 'negociante' then return query
    select x.u, count(*)::numeric from (
      select l.seller_id u from market_listings l where l.status in ('vendido', 'trocado') and l.closed_at >= _t0 and l.closed_at < _t1
      union all select l.buyer_id from market_listings l where l.status in ('vendido', 'trocado') and l.buyer_id is not null and l.closed_at >= _t0 and l.closed_at < _t1
      union all select a.seller from leiloes a where a.status = 'vendido' and a.closed_at >= _t0 and a.closed_at < _t1
      union all select a.top_bidder from leiloes a where a.status = 'vendido' and a.top_bidder is not null and a.closed_at >= _t0 and a.closed_at < _t1
      union all select t.de from trocas t where t.status = 'aceita' and t.fim >= _t0 and t.fim < _t1
      union all select t.para from trocas t where t.status = 'aceita' and t.fim >= _t0 and t.fim < _t1) x
    where x.u is not null group by 1;
  elsif _cat = 'azarado' then return query
    select c.user_id, sum(c.casas)::numeric from casas_perdidas c where c.created_at >= _t0 and c.created_at < _t1 group by 1;
  end if;
end $$;

-- empate: as moedas da categoria são divididas entre os empatados
create or replace function public.season_awards_give(_season int) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare s seasons; t0 timestamptz; t1 timestamptz; c jsonb; top numeric; r record; premio int := coalesce((public.cfg()->'season_awards'->>'coins')::int, 150);
  n int := 0; linhas text := ''; nomes text; k int; parte int;
begin
  select * into s from seasons where id = _season;
  if s.id is null or exists (select 1 from season_awards where season_id = s.id and category <> 'liga') then return 0; end if;
  t0 := s.started_on::timestamp at time zone 'America/Sao_Paulo';
  t1 := now();
  for c in select * from jsonb_array_elements(public.season_award_cats()) loop
    select max(val) into top from public.season_rank(c->>'id', t0, t1) where val > 0;
    continue when top is null;
    select count(*) into k from public.season_rank(c->>'id', t0, t1) x join characters ch on ch.user_id = x.user_id where x.val = top;
    parte := floor(premio::numeric / greatest(k, 1))::int;
    nomes := '';
    for r in select x.user_id, ch.name from public.season_rank(c->>'id', t0, t1) x join characters ch on ch.user_id = x.user_id where x.val = top order by ch.name loop
      insert into season_awards(season_id, category, user_id, value, coins) values (s.id, c->>'id', r.user_id, top, parte) on conflict do nothing;
      perform public.ext_origem('Prêmio da temporada', 'premios');
      update characters set coins = coins + parte where user_id = r.user_id;
      insert into gifts(user_id, coins, message) values (r.user_id, parte,
        '🏅 Prêmio da Temporada ' || s.id || ': ' || (c->>'nome') || ' (' || trim(to_char(top, 'FM999G999G990')) || ' ' || (c->>'un') || '). Você ganhou a medalha "' || (c->>'titulo') || '"'
        || case when k > 1 then ' e ' || parte || ' moedas (empate entre ' || k || ' jogadores: as ' || premio || ' moedas foram divididas)!' else '!' end);
      nomes := nomes || case when nomes = '' then '' else ' e ' end || r.name;
      n := n + 1;
    end loop;
    linhas := linhas || E'\n' || (c->>'ic') || ' ' || (c->>'nome') || ': ' || nomes || ' (' || trim(to_char(top, 'FM999G999G990')) || ')';
  end loop;
  if n > 0 then
    insert into event_log(kind, message) values ('temporada', '🏅 Prêmios da Temporada ' || s.id || '! Cada categoria vale ' || premio || ' moedas (divididas no empate) e uma medalha:' || linhas);
  end if;
  return n;
end $$;


-- do_move: versão do 118 com a mudança do arquivo 120
create or replace function public.do_move(_d date, _recovery boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := auth.uid(); c jsonb := public.cfg(); today date := public.game_today();
  me characters; other characters; nd board_nodes; tr traps; w jsonb; x record;
  m public.puzzle_mode; s guess_sessions; st int; modes jsonb := '{}'::jsonb;
  base int := 0; roll int; r2 int; i int; bonus int; skill_steps int := 0; vcasas int := 0; total int; from_node int; landed int; path0 int;
  ev jsonb := '[]'::jsonb; sal int := 0; extra_coins int := 0; extra_xp int := 0; cls text; sv int; skill_on boolean; dodge boolean := false;
  card int; chance int; steal int; my_dist int; tmp_node int; tmp_path int[]; msg text; amt int;
  xp_gain int; coin_gain int; new_level int; old_level int;
  leader uuid; prop properties; toll int; bounty int := coalesce((public.cfg()->>'bounty_coins')::int, 60);
  boss world_bosses; mud int; passed int[]; tn int; champ uuid; hx jsonb; hh hunts; he hunt_entries; hgo int; hdist int;
begin
  perform set_config('pg.partes', '', true);   -- arquivo 117: as partes da andada para o extrato
  perform public.settle();
  leader := public.leader_id(); champ := public.round_champion();
  select * into me from characters where user_id = uid for update;
  if me.id is null then raise exception 'Crie seu personagem primeiro.'; end if;
  if exists (select 1 from daily_moves where user_id = uid and move_date = _d) then raise exception 'Você já andou nesse dia.'; end if;
  old_level := me.level; cls := me.class::text;
  skill_on := not _recovery and me.skill_date = today;
  sv := public.skill_value(cls, me.level);

  foreach m in array enum_range(null::public.puzzle_mode) loop
    s := null;
    select * into s from guess_sessions where user_id = uid and puzzle_date = _d and mode = m;
    st := public.mode_steps(coalesce(s.attempts,0), coalesce(s.solved,false));
    base := base + st;
    modes := modes || jsonb_build_object(m::text, jsonb_build_object('attempts', coalesce(s.attempts,0), 'solved', coalesce(s.solved,false), 'steps', st));
  end loop;

  roll := (c->>'roll_min')::int + floor(random() * ((c->>'roll_max')::int - (c->>'roll_min')::int + 1))::int;
  if skill_on and cls = 'arqueiro' then   -- Tiro certeiro (arquivo 67): a roleta vale o máximo
    roll := (c->>'roll_max')::int;
    ev := ev || jsonb_build_object('t','habilidade','msg','Tiro certeiro: a roleta ficou no máximo (' || roll || ').');
  end if;
  if cls = 'arqueiro' and roll < (c->>'arqueiro_min_die')::int then
    roll := (c->>'arqueiro_min_die')::int;
    ev := ev || jsonb_build_object('t','arqueiro','msg','Olho de arqueiro: a roleta vale no mínimo ' || roll || '.');
  end if;
  if skill_on and cls = 'domador' then
    roll := roll * greatest(sv,2);
    ev := ev || jsonb_build_object('t','habilidade','msg','Montaria: a roleta valeu ' || greatest(sv,2) || ' vezes mais (' || roll || ').');
  end if;
  if skill_on and cls in ('guerreiro','ladino','clerigo','pesquisador','mercador') and sv > 0 then
    skill_steps := sv;
    ev := ev || jsonb_build_object('t','habilidade','msg',
      case cls when 'guerreiro' then 'Investida' when 'ladino' then 'Atalho' when 'pesquisador' then 'Isca de frutas' when 'mercador' then 'Negócio da China' else 'Bênção' end || ': +' || sv || ' casas.');
  end if;
  if skill_on and cls = 'mago' then
    skill_steps := public.next_good_steps(me.id, sv);
    ev := ev || jsonb_build_object('t','habilidade','msg', case when skill_steps > 0 then 'Teleporte: saltou ' || skill_steps || ' casas até uma casa especial.' else 'Teleporte: nenhuma casa especial ao alcance.' end);
  end if;
  if skill_on and cls = 'ladino' then dodge := true; end if;
  if skill_on and cls = 'clerigo' then ev := ev || jsonb_build_object('t','habilidade','msg','Bênção ativa: nada te empurra para trás hoje.'); end if;

  bonus := me.bonus_steps;
  total := base + roll + bonus + skill_steps;
  -- arquivo 82: o Centro da Vila dá casas extras na andada
  vcasas := public.vb(uid, 'centro', 'casas')::int;
  if vcasas > 0 then total := total + vcasas; ev := ev || jsonb_build_object('t', 'vila', 'msg', '🏰 Centro da Vila: +' || vcasas || case when vcasas = 1 then ' casa.' else ' casas.' end); end if;
  -- lama da catapulta de um rival
  mud := coalesce(me.pending_mud, 0);
  if mud > 0 and not _recovery then
    update characters set pending_mud = 0 where id = me.id;
    if public.is_shielded(me.id) then
      ev := ev || jsonb_build_object('t','lama','msg','Atiraram lama em você, mas a Bênção te protegeu.');
    else
      total := greatest(0, total - mud);
      ev := ev || jsonb_build_object('t','lama','msg','Lama da catapulta: você perdeu ' || mud || ' casas nesta andada.');
    end if;
  end if;
  from_node := me.node;

  if me.arrived_rank is null and public.liga_mapa_parado() then   -- arquivo 73: durante a Liga ninguém anda
    ev := ev || jsonb_build_object('t','castelo','msg','A corrida acabou e a Liga Pokémon está acontecendo: o mapa fica parado até a temporada nova. Seus acertos de hoje continuam valendo moedas, XP e a rodada do dia.');
    total := 0;
  elsif me.arrived_rank is not null then
    ev := ev || jsonb_build_object('t','castelo','msg','Você já está no Castelo. Continue jogando para ganhar moedas, XP e vencer rodadas.');
    total := 0;
  else
    update characters set bonus_steps = 0 where id = me.id;
    -- Caçada (arquivo 48): quem escolheu ir atrás do Pokémon vai para o começo do caminho dela;
    -- quem escolheu o jogo (ou não escolheu) segue a corrida normal
    select * into hh from hunts where status in ('ativa', 'tentando') order by id desc limit 1;
    if hh.id is not null then
      select * into he from hunt_entries where hunt_id = hh.id and user_id = uid;
      if coalesce(he.go, false) and not he.done and hh.status = 'ativa' and not (me.node = any(hh.node_ids)) then
        update hunt_entries set origin_node = me.node, origin_len = coalesce(array_length(me.path, 1), 1) where hunt_id = hh.id and user_id = uid;
        update characters set node = hh.fork_node, path = path || hh.fork_node,
               route = coalesce(route, '{}'::jsonb) || jsonb_build_object(hh.fork_node::text, 'b') where id = me.id;
        hgo := hh.fork_node;
        ev := ev || jsonb_build_object('t', 'cacada', 'msg', '🎯 Você foi atrás do Pokémon misterioso! Suas andadas agora são pelo caminho da Caçada. Pegando ou não o Pokémon, você volta para a casa onde estava.');
      elsif not coalesce(he.go, false) or he.done then
        update characters set route = coalesce(route, '{}'::jsonb) - hh.fork_node::text where id = me.id and route ? hh.fork_node::text;
      end if;
      select * into me from characters where id = me.id;
    end if;
    -- arquivo 118: no caminho da Caçada, a andada gasta só as casas até o Pokémon; o resto fica guardado para depois da volta
    if hh.id is not null then
      select * into he from hunt_entries where hunt_id = hh.id and user_id = uid;
      if coalesce(he.go, false) and not he.done and (me.node = hh.fork_node or me.node = any(hh.node_ids)) then
        hdist := public.hunt_dist(me.node, hh.target_node, hh.fork_node);
        if hdist is not null and total > hdist then
          update hunt_entries set sobra = sobra + (total - hdist), gastas = gastas + hdist where hunt_id = hh.id and user_id = uid;
          ev := ev || jsonb_build_object('t', 'cacada', 'msg', '🎯 Até o Pokémon eram ' || hdist || case when hdist = 1 then ' casa' else ' casas' end || '. As outras ' || (total - hdist)
                || ' ficam guardadas: você anda com elas a partir da sua casa quando voltar da Caçada.');
          total := hdist;
        elsif hdist is not null then
          update hunt_entries set gastas = gastas + total where hunt_id = hh.id and user_id = uid;
        end if;
      end if;
    end if;
    path0 := coalesce(array_length(me.path,1),1);
    w := public.walk(me.id, total);
    sal := sal + (w->>'salary')::int;
    landed := (w->>'node')::int;

    -- atalhos das HMs (arquivo 47): Cut, Surf, Strength e Flash nas casas com obstáculo; Fly de tempos em tempos
    hx := public.hm_shortcut(me.id, path0);
    ev := ev || coalesce(hx->'ev', '[]'::jsonb);
    if coalesce((hx->>'steps')::int, 0) > 0 then
      w := public.walk(me.id, (hx->>'steps')::int); sal := sal + (w->>'salary')::int;
      landed := (w->>'node')::int;
    end if;

    -- encontro com o lendário (passando ou parando)
    select * into boss from world_bosses where status = 'ativo' order by id desc limit 1;
    if boss.id is not null then
      passed := (select path from characters where id = me.id)[path0 : coalesce(array_length((select path from characters where id = me.id),1),1)];
      if boss.node = any(passed) and not exists (select 1 from boss_contacts bc where bc.boss_id = boss.id and bc.user_id = uid) then
        insert into boss_contacts(boss_id, user_id) values (boss.id, uid);
        ev := ev || jsonb_build_object('t','lendario','msg','Você encontrou o lendário ' || (select name from pokemon where id = boss.pokemon_id) || '! Agora pode atacá-lo pelo painel.');
      end if;
    end if;

    -- Treinadores no caminho (arquivo 70): passou pela casa, tem que batalhar (quem para nela luta pelo house_extra)
    if coalesce((public.casas_cfg()->>'passar_luta')::boolean, true) then
      for tn in select p.id from unnest((select path from characters where id = me.id)[path0 + 1 : coalesce(array_length((select path from characters where id = me.id),1),1) - 1]) with ordinality p(id, o)
                 join board_nodes b on b.id = p.id where b.kind = 'treinador' order by p.o loop
        w := public.npc_fight(me.id, tn);
        ev := ev || coalesce(w->'ev', '[]'::jsonb); extra_coins := extra_coins + coalesce((w->>'coins')::int, 0); perform public.ext_parte('Treinador do mapa', coalesce((w->>'coins')::int, 0));
      end loop;
    end if;

    -- Ladino: pega moedas de quem ultrapassa
    if cls = 'ladino' then
      amt := public.passive_value('ladino', me.level);
      for x in
        select ch.id, ch.name, ch.coins from characters ch
        where ch.user_id <> uid and ch.arrived_rank is null
          and ch.node = any ((select path from characters where id = me.id)[path0 + 1 : coalesce(array_length((select path from characters where id = me.id),1),1) - 1])
        for update
      loop
        steal := least(amt, x.coins);
        if steal > 0 then
          perform public.ext_origem('Ladino (pegou de você ao passar)', 'tabuleiro');
          update characters set coins = coins - steal where id = x.id;
          extra_coins := extra_coins + steal; perform public.ext_parte('Ladino (mão leve)', steal);
          ev := ev || jsonb_build_object('t','ladino','msg','Mão leve: pegou ' || steal || ' moedas de ' || x.name || ' ao passar.');
        end if;
      end loop;
    end if;

    -- 1) armadilha de outro jogador
    select * into tr from traps where node = landed and triggered_at is null and owner_id <> uid for update;
    if tr.id is not null then
      update traps set triggered_by = uid, triggered_at = now() where id = tr.id;
      select * into other from characters where user_id = tr.owner_id;
      if dodge then
        ev := ev || jsonb_build_object('t','armadilha','msg','Atalho: você desviou da armadilha de ' || other.name || '.');
      elsif cls = 'mago' and random() * 100 < (c->>'mago_resist_pct')::int then
        ev := ev || jsonb_build_object('t','armadilha','msg','Você desfez com magia a armadilha de ' || other.name || '.');
      elsif public.is_shielded(me.id) then
        ev := ev || jsonb_build_object('t','armadilha','msg','A Bênção te protegeu da armadilha de ' || other.name || '.');
      else
        perform public.perda_motivo('armadilha'); perform public.go_back(me.id, (c->>'trap_push')::int);
        perform public.ext_origem('Armadilha (alguém caiu na sua)', 'tabuleiro'); update characters set coins = coins + (c->>'trap_reward')::int where user_id = tr.owner_id;
        ev := ev || jsonb_build_object('t','armadilha','msg','Você caiu na armadilha de ' || other.name || ' e voltou ' || (c->>'trap_push') || ' casas.');
        insert into event_log(user_id, kind, message) values (uid, 'armadilha', me.name || ' caiu na armadilha de ' || other.name || '.');
      end if;
    else
      -- 2) efeito da casa
      select * into nd from board_nodes where id = landed;
      if nd.kind = 'avanco' then
        w := public.walk(me.id, nd.value); sal := sal + (w->>'salary')::int;
        ev := ev || jsonb_build_object('t','avanco','msg','Vento a favor! Avançou mais ' || nd.value || ' casas.');
      elsif nd.kind = 'recuo' then
        if dodge then ev := ev || jsonb_build_object('t','recuo','msg','Atalho: você contornou o lamaçal.');
        elsif public.is_shielded(me.id) then ev := ev || jsonb_build_object('t','recuo','msg','A Bênção te segurou no lamaçal.');
        elsif cls = 'mago' and random() * 100 < (c->>'mago_resist_pct')::int then ev := ev || jsonb_build_object('t','recuo','msg','Escorregou, mas a magia segurou você no lugar.');
        else perform public.perda_motivo('lamacal'); perform public.go_back(me.id, nd.value); ev := ev || jsonb_build_object('t','recuo','msg','Lamaçal! Voltou ' || nd.value || ' casas.');
        end if;
      elsif nd.kind = 'bau' then
        amt := ceil((c->>'chest_coins')::int * case when skill_on and cls = 'mercador' then 2 else 1 end * (100 + public.eq_bonus(uid, 'capacete')) / 100.0)::int; extra_coins := extra_coins + amt; perform public.ext_parte('Baú', amt);   -- arquivo 103: Capacete
        ev := ev || jsonb_build_object('t','bau','msg','Achou um baú com ' || ceil((c->>'chest_coins')::int * case when skill_on and cls = 'mercador' then 2 else 1 end * (100 + public.eq_bonus(uid, 'capacete')) / 100.0)::int || ' moedas.' || case when skill_on and cls = 'mercador' then ' (Negócio da China: em dobro!)' else '' end);
        hx := public.item_drop(uid, 'bau');
        if hx is not null then ev := ev || hx; end if;
        hx := public.hm_drop(uid, 'bau');
        if hx is not null then ev := ev || hx; end if;
      elsif nd.kind = 'xp' then
        extra_xp := extra_xp + (c->>'xp_square')::int;
        ev := ev || jsonb_build_object('t','xp','msg','Treino na clareira: +' || (c->>'xp_square') || ' XP.');
      elsif nd.kind = 'pagamento' then
        ev := ev || jsonb_build_object('t','pagamento','msg','Parou no Dia de pagamento.');
      elsif nd.kind = 'carta' then
        card := floor(random() * 6)::int;
        if card = 0 then
          extra_coins := extra_coins + (c->>'card_coins_win')::int; perform public.ext_parte('Carta da sorte', (c->>'card_coins_win')::int);
          ev := ev || jsonb_build_object('t','carta','msg','Carta da sorte: um treinador agradecido te deu ' || (c->>'card_coins_win') || ' moedas.');
        elsif card = 1 then
          amt := (c->>'card_coins_lose')::int; if cls = 'clerigo' then amt := ceil(amt / 2.0); end if;
          extra_coins := extra_coins - amt; perform public.ext_parte('Carta da sorte', -amt);
          ev := ev || jsonb_build_object('t','carta','msg','Carta do azar: sua mochila rasgou e você perdeu ' || amt || ' moedas.');
        elsif card = 2 then
          w := public.walk(me.id, (c->>'card_steps')::int); sal := sal + (w->>'salary')::int;
          ev := ev || jsonb_build_object('t','carta','msg','Carta da sorte: atalho secreto! Avançou ' || (c->>'card_steps') || ' casas.');
        elsif card = 3 then
          amt := (c->>'card_steps')::int; if cls = 'clerigo' then amt := ceil(amt / 2.0); end if;
          if public.is_shielded(me.id) then ev := ev || jsonb_build_object('t','carta','msg','Carta do azar: você ia se perder, mas a Bênção te guiou.');
          else perform public.go_back(me.id, amt); ev := ev || jsonb_build_object('t','carta','msg','Carta do azar: você se perdeu e voltou ' || amt || ' casas.');
          end if;
        elsif card = 4 then
          update characters set hints = hints + 1 where id = me.id;
          ev := ev || jsonb_build_object('t','carta','msg','Carta da sorte: ganhou 1 Dica.');
        else
          update characters set retries = retries + 1 where id = me.id;
          ev := ev || jsonb_build_object('t','carta','msg','Carta da sorte: ganhou 1 Tente outra vez.');
        end if;
      elsif nd.kind = 'raio' then
        select ch.* into other from characters ch join board_nodes b on b.id = ch.node
         where ch.arrived_rank is null and ch.user_id <> uid order by b.dist asc limit 1 for update of ch;
        my_dist := (select dist from board_nodes where id = landed);
        if other.id is null or (select dist from board_nodes where id = other.node) >= my_dist then
          ev := ev || jsonb_build_object('t','raio','msg','A tempestade caiu longe: ninguém está à sua frente.');
        elsif public.is_shielded(other.id) then
          ev := ev || jsonb_build_object('t','raio','msg','Você chamou um raio em ' || other.name || ', mas a Bênção dele o protegeu.');
        elsif other.class::text = 'mago' and random() * 100 < (c->>'mago_resist_pct')::int then
          ev := ev || jsonb_build_object('t','raio','msg','Você chamou um raio em ' || other.name || ', mas a magia dele desviou.');
        else
          perform public.perda_motivo('raio'); perform public.go_back(other.id, (c->>'storm_push')::int);
          ev := ev || jsonb_build_object('t','raio','msg','Você chamou um raio no líder ' || other.name || ': ele voltou ' || (c->>'storm_push') || ' casas.');
          insert into event_log(user_id, kind, message) values (uid, 'raio', me.name || ' derrubou um raio no líder ' || other.name || '.');
          if other.user_id = leader then
            extra_coins := extra_coins + bounty; perform public.ext_parte('Recompensa do Procurado', bounty);
            ev := ev || jsonb_build_object('t','procurado','msg','Recompensa: você acertou o procurado e ganhou ' || bounty || ' moedas.');
          end if;
        end if;
      elsif nd.kind = 'troca' then
        my_dist := (select dist from board_nodes where id = landed);
        select ch.* into other from characters ch join board_nodes b on b.id = ch.node
         where ch.arrived_rank is null and ch.user_id <> uid and b.dist < my_dist order by b.dist desc limit 1 for update of ch;
        if other.id is not null and public.is_shielded(other.id) then
          ev := ev || jsonb_build_object('t','troca','msg','O portal tentou te trocar com ' || other.name || ', mas a Bênção dele impediu.');
        elsif other.id is not null then
          select node, path into tmp_node, tmp_path from characters where id = me.id;
          update characters set node = other.node, path = other.path where id = me.id;
          update characters set node = tmp_node, path = tmp_path where id = other.id;
          ev := ev || jsonb_build_object('t','troca','msg','Portal! Você trocou de lugar com ' || other.name || '.');
          insert into event_log(user_id, kind, message) values (uid, 'troca', me.name || ' trocou de lugar com ' || other.name || ' pelo portal.');
        else
          ev := ev || jsonb_build_object('t','troca','msg','O portal não encontrou ninguém à sua frente.');
        end if;
      elsif nd.kind in ('mina', 'desafio', 'ladrao', 'fonte', 'treinador', 'alvo') then
        -- casas novas (arquivo 42) e treinadores (arquivo 43)
        hx := public.house_extra(me.id, nd.kind, modes, dodge);
        ev := ev || coalesce(hx->'ev', '[]'::jsonb);
        extra_coins := extra_coins + coalesce((hx->>'coins')::int, 0);
        perform public.ext_parte(case nd.kind when 'mina' then 'Casa da Mina' when 'desafio' then 'Casa do Desafio' when 'ladrao' then 'Ladrão de estrada' when 'fonte' then 'Fonte' when 'treinador' then 'Treinador do mapa' else 'Casa especial' end, coalesce((hx->>'coins')::int, 0));
        extra_xp := extra_xp + coalesce((hx->>'xp')::int, 0);
        sal := sal + coalesce((hx->>'sal')::int, 0);
      end if;
    end if;

    -- 3) encontro na mesma casa vira duelo
    select * into me from characters where id = me.id;
    select ch.* into other from characters ch join board_nodes b on b.id = ch.node
     where ch.user_id <> uid and ch.node = me.node and ch.arrived_rank is null and b.kind not in ('inicio','castelo')
       -- com o líder, só há encontro se o outro for o melhor da última rodada (se o líder for o melhor, nada acontece)
       and (leader is null or (ch.user_id <> leader and uid <> leader) or (champ is not null and champ <> leader and champ in (uid, ch.user_id)))
     order by random() limit 1 for update of ch;
    if other.id is not null then
      chance := 50 + (me.level - other.level) * (c->>'duel_level_factor')::int
                   + case when cls = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end
                   - case when other.class::text = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end;
      chance := chance
        + case when exists (select 1 from villages where user_id = uid and arena_level > 0) then coalesce((c->>'arena_bonus')::int, 10) else 0 end
        - case when exists (select 1 from villages where user_id = other.user_id and arena_level > 0) then coalesce((c->>'arena_bonus')::int, 10) else 0 end;
      chance := greatest(25, least(75, chance));
      if random() * 100 < chance then
        steal := least((c->>'duel_coins')::int, other.coins);
        perform public.ext_origem('Duelo no mapa', 'tabuleiro');
        update characters set coins = coins - steal where id = other.id;
        perform public.perda_motivo('duelo'); perform public.go_back(other.id, (c->>'duel_push')::int);
        extra_coins := extra_coins + steal; perform public.ext_parte('Duelo no mapa', steal);
        ev := ev || jsonb_build_object('t','duelo','msg','Encontro com ' || other.name || ': você venceu o duelo, ganhou ' || steal || ' moedas' || case when public.is_shielded(other.id) then '.' else ' e empurrou o rival.' end);
        if other.user_id = leader then
          extra_coins := extra_coins + bounty; perform public.ext_parte('Recompensa do Procurado', bounty);
          ev := ev || jsonb_build_object('t','procurado','msg','Recompensa: você venceu o procurado e ganhou ' || bounty || ' moedas.');
        end if;
        insert into event_log(user_id, kind, message) values (uid, 'duelo', me.name || ' venceu um duelo contra ' || other.name || '.');
      else
        steal := least((c->>'duel_coins')::int, greatest(0, me.coins + extra_coins));
        perform public.ext_origem('Duelo no mapa', 'tabuleiro');
        update characters set coins = coins + steal where id = other.id;
        extra_coins := extra_coins - steal; perform public.ext_parte('Duelo no mapa', -steal);
        perform public.perda_motivo('duelo'); perform public.go_back(me.id, (c->>'duel_push')::int);
        ev := ev || jsonb_build_object('t','duelo','msg','Encontro com ' || other.name || ': você perdeu o duelo e ' || steal || ' moedas' || case when public.is_shielded(me.id) then ', mas a Bênção te manteve no lugar.' else ' e voltou ' || (c->>'duel_push') || ' casas.' end);
        insert into event_log(user_id, kind, message) values (uid, 'duelo', other.name || ' defendeu sua casa contra ' || me.name || '.');
      end if;
    end if;

    -- 4) pedágio das pousadas de outros jogadores (arquivo 84: quem PASSA também paga, uma vez por pousada)
    select * into me from characters where id = me.id;
    for prop in select * from properties
                 where owner <> uid and (node = me.node or (coalesce((c->>'property_pedagio_passou')::boolean, true)
                       and node = any(coalesce(me.path[path0 + 1 : coalesce(array_length(me.path, 1), 1)], '{}'::int[]))))
                 order by node for update loop
      toll := greatest((c->>'property_min_toll')::int, ceil(prop.price * (c->>'property_toll_pct')::numeric / 100)::int);
      toll := least(toll, greatest(0, me.coins + extra_coins + base * (c->>'coins_per_step')::int));
      if toll > 0 then
        extra_coins := extra_coins - toll; perform public.ext_parte('Pedágio pago', -toll);
        perform public.ext_origem('Pedágio recebido', 'tabuleiro');
        update characters set coins = coins + toll where user_id = prop.owner;
        update properties set tolls_earned = tolls_earned + toll where node = prop.node;
        ev := ev || jsonb_build_object('t','pousada','msg','Pedágio na pousada de ' || (select name from characters where user_id = prop.owner) || ': -' || toll || ' moedas.');
        insert into event_log(user_id, kind, message) values (uid, 'pousada', me.name || ' pagou ' || toll || ' moedas de pedágio na pousada de ' || (select name from characters where user_id = prop.owner) || '.');
      end if;
    end loop;
    if sal > 0 then ev := ev || jsonb_build_object('t','pagamento','msg','Dia de pagamento: +' || sal || ' moedas de salário' ||
      case when uid = public.snorlax_id() then ' (10% a menos por ser o Snorlax da rodada).' else '.' end); end if;
    msg := public.check_arrival(me.id);
    if msg is not null then ev := ev || jsonb_build_object('t','castelo','msg', msg); end if;
  end if;

  xp_gain := base * (c->>'xp_per_step')::int + (c->>'xp_daily_bonus')::int + extra_xp;
  if (select xp_buff_until from characters where id = me.id) >= today then
    xp_gain := round(xp_gain * coalesce((c->>'boss_xp_mult')::numeric, 1.5))::int;
    ev := ev || jsonb_build_object('t','buff','msg','Bênção do lendário derrotado: XP aumentado.');
  end if;
  coin_gain := base * (c->>'coins_per_step')::int + extra_coins;
  select * into me from characters where id = me.id;
  new_level := public.level_for_xp(me.xp_total + xp_gain);
  if new_level > old_level then
    ev := ev || jsonb_build_object('t','nivel','msg','Subiu para o nível ' || new_level || '!');
    insert into event_log(user_id, kind, message) values (uid, 'nivel', me.name || ' chegou ao nível ' || new_level || '.');
  end if;
  perform public.ext_origem('andada', 'tabuleiro');   -- arquivo 117: o gatilho separa as partes no extrato
  update characters set xp_total = xp_total + xp_gain, level = new_level,
         coins = greatest(0, coins + coin_gain), last_move_date = greatest(coalesce(last_move_date, _d), _d)
   where id = me.id returning * into me;

  -- Mercador com a habilidade do dia: o salário dos Dias de pagamento vem em dobro
  if skill_on and cls = 'mercador' and sal > 0 then
    perform public.ext_origem('Dia de pagamento (Negócio da China)', 'tabuleiro');
    update characters set coins = coins + sal where id = me.id;
    ev := ev || jsonb_build_object('t','habilidade','msg','Negócio da China: o salário veio em dobro (+' || sal || ' moedas).');
    sal := sal * 2;
  end if;
  insert into daily_moves(user_id, move_date, modes, base_steps, roll, bonus_steps, skill_steps, from_node, to_node, xp_gained, coins_gained, events, recovered)
  values (uid, _d, modes, base, roll, bonus, skill_steps, from_node, me.node, xp_gain, coin_gain + sal, ev, _recovery);
  insert into event_log(user_id, kind, message, data)
  values (uid, 'andou', me.name || ' andou ' || total || ' casas' || case when _recovery then ' recuperando o dia ' || to_char(_d, 'DD/MM') else '' end || '.', jsonb_build_object('steps', total));

  return jsonb_build_object('date', _d, 'recovery', _recovery, 'base', base, 'roll', roll, 'bonus', bonus, 'skill', skill_steps, 'total', total, 'modes', modes,
    'from', from_node, 'to', me.node, 'path', to_jsonb(me.path), 'events', ev, 'hunt_go', hgo,
    'xp', xp_gain, 'coins', coin_gain + sal, 'level', new_level, 'leveled', new_level > old_level);
end $$;


-- resolve_duel: versão do 23 com a mudança do arquivo 120
create or replace function public.resolve_duel(_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare ct interval; ot interval; d duels; c jsonb := cfg(); w uuid; l uuid; cs int; os int; ch characters; op characters; chance int; leader uuid := public.leader_id(); bounty int := coalesce((cfg()->>'bounty_coins')::int, 60);
  wc characters; lc characters; msg text; what text;
begin
  select * into d from duels where id = _id for update;
  if d.status <> 'aceito' then return; end if;
  select * into ch from characters where user_id = d.challenger for update;
  select * into op from characters where user_id = d.opponent for update;
  if d.kind = 'quiz' then
    cs := case when d.c_solved then d.c_attempts else 99 end;
    os := case when d.o_solved then d.o_attempts else 99 end;
    if cs < os then w := d.challenger;
    elsif os < cs then w := d.opponent;
    elsif cs = 99 then w := null;
    else
      -- empate em tentativas: vence quem levou MENOS TEMPO entre abrir o duelo e terminar
      -- (sem a hora de início, que só existe a partir deste arquivo, vale a regra antiga: quem terminou antes)
      ct := case when d.c_started_at is not null then d.c_done_at - d.c_started_at end;
      ot := case when d.o_started_at is not null then d.o_done_at - d.o_started_at end;
      if ct is not null and ot is not null and ct <> ot then w := case when ct < ot then d.challenger else d.opponent end;
      else w := case when coalesce(d.c_done_at, 'infinity') <= coalesce(d.o_done_at, 'infinity') then d.challenger else d.opponent end;
      end if;
    end if;
  else
    chance := 50 + (ch.level - op.level) * (c->>'duel_level_factor')::int
                 + case when ch.class::text = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end
                 - case when op.class::text = 'guerreiro' then (c->>'guerreiro_duel_bonus')::int else 0 end;
    chance := greatest(25, least(75, chance));
    w := case when random() * 100 < chance then d.challenger else d.opponent end;
  end if;
  what := case d.stake_kind when 'moedas' then d.stake || ' moedas' else d.stake || ' casas' end;
  if w is null then
    if d.stake_kind = 'moedas' then
      update characters set coins = coins + d.stake where user_id in (d.challenger, d.opponent);
    end if;
    msg := 'Duelo entre ' || ch.name || ' e ' || op.name || ' terminou sem vencedor. Ninguém acertou o Pokémon.';
  else
    l := case when w = d.challenger then d.opponent else d.challenger end;
    select * into wc from characters where user_id = w;
    select * into lc from characters where user_id = l;
    if d.stake_kind = 'moedas' then
      update characters set coins = coins + 2 * d.stake where user_id = w;
    else
      if wc.arrived_rank is null then perform public.walk(wc.id, d.stake); perform public.check_arrival(wc.id); end if;
      if lc.arrived_rank is null then perform public.perda_motivo('duelo'); perform public.go_back(lc.id, d.stake); end if;
    end if;
    msg := wc.name || ' venceu o duelo contra ' || lc.name || ' e levou ' || what || '.';
    if l = leader then
      update characters set coins = coins + bounty where user_id = w;
      msg := msg || ' Venceu o procurado e ganhou mais ' || bounty || ' moedas de recompensa!';
    end if;
  end if;
  update duels set status = 'concluido', winner = w, result = msg, resolved_at = now() where id = _id;
  insert into event_log(user_id, kind, message) values (coalesce(w, d.challenger), 'duelo', msg);
end $$;


revoke execute on function public.perda_motivo(text) from public, anon, authenticated;
revoke execute on function public.go_back(uuid, int) from public, anon, authenticated;

insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values
   ('🏅 Prêmios da temporada: 10 categorias novas', 'Os prêmios da temporada ganharam 10 categorias: Mais evoluções, Mais insígnias, Mais ataques vencidos e Mais defesas vencidas (guerras), Rei das cartas, Rei do PokeBound, Mais missões da Aventura, Maior dano no Chefe, Maior negociante (compras e vendas no Mercado e no Leilão, mais trocas) e o Azarado da Temporada (quem mais perdeu casas no Lamaçal, no Raio, na Armadilha e no Duelo).
"Mais dano na Equipe Rocket" virou "Mais ondas vencidas contra a Rocket".
No empate, as 150 moedas da categoria agora são divididas entre os empatados; a medalha continua para todos.
Acompanhe em Ranking → 🏅 Prêmios.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
