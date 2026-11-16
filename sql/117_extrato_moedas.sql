-- Arquivo 117 (pedido do dono em 17/11/2026, aprovado pelo grupo): Extrato de moedas.
-- Um gatilho na tabela characters anota TODA mudança de moedas (data e hora, valor, saldo depois, origem e tipo), então nenhuma
-- movimentação escapa. A origem vem (1) do que a função marcou antes de pagar (`ext_origem`, uma vez só) ou (2) do nome da função que
-- mexeu nas moedas (tabela `moedas_origens`; ganha a de maior prioridade, e no empate a mais de dentro). A andada (do_move) junta várias
-- coisas num pagamento só: ela anota cada parte (`ext_parte`: baú, pedágio, Ladino, Ladrão, duelo, carta…) e o gatilho separa em linhas;
-- o que sobra é "Casas andadas". Na publicação, cada jogador ganha uma linha de "Saldo inicial" (o extrato bate com o saldo).
-- Fica guardado `extrato.dias` (30) dias. O site abre ao tocar no saldo.

create or replace function public.extrato_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "dias": 30}'::jsonb || coalesce(public.cfg()->'extrato', '{}'::jsonb)
$$;

create table if not exists public.moedas_extrato (
  id bigserial primary key, user_id uuid not null references auth.users(id) on delete cascade, em timestamptz not null default now(),
  valor int not null, saldo int not null, origem text not null, tipo text not null default 'outros');
create index if not exists moedas_extrato_user on public.moedas_extrato (user_id, id desc);
create index if not exists moedas_extrato_em on public.moedas_extrato (em);
alter table public.moedas_extrato enable row level security;
drop policy if exists moedas_extrato_meu on public.moedas_extrato;
create policy moedas_extrato_meu on public.moedas_extrato for select to authenticated using (user_id = auth.uid() or public.is_admin());
grant select on public.moedas_extrato to authenticated;

-- de onde vem a moeda, pelo nome da função (padrão do LIKE); a de maior prioridade vence
create table if not exists public.moedas_origens (padrao text primary key, origem text not null, tipo text not null, prioridade int not null default 30);
alter table public.moedas_origens enable row level security;
insert into public.moedas_origens(padrao, origem, tipo, prioridade) values
  ('do_move', 'Andada', 'tabuleiro', 10), ('walk', 'Dia de pagamento', 'tabuleiro', 30), ('spin_wheel', 'Roleta', 'tabuleiro', 30),
  ('settle', 'Prêmio da rodada (fechamento do dia)', 'tabuleiro', 15), ('check_arrival', 'Castelo (prêmio de chegada)', 'tabuleiro', 40),
  ('league_maybe_start', 'Castelo (prêmio pela posição)', 'tabuleiro', 40), ('boss_attack', 'Lendário do mapa', 'tabuleiro', 30),
  ('buy_property', 'Pousada (compra)', 'tabuleiro', 30), ('sell_property', 'Pousada (venda)', 'tabuleiro', 30), ('board_swap', 'Pousada devolvida (mapa novo)', 'tabuleiro', 40),
  ('place_trap', 'Armadilha (compra)', 'tabuleiro', 30), ('npc_fight', 'Treinador do mapa', 'tabuleiro', 30), ('admin_undo_move', 'Andada desfeita (admin)', 'outros', 60),
  ('village_collect', 'Vila: salário e soldo do Quartel', 'vila', 30), ('village_build', 'Vila (construção)', 'vila', 30), ('village_upgrade', 'Vila (construção)', 'vila', 30),
  ('village_repair', 'Vila (conserto)', 'vila', 30), ('village_clean', 'Vila (limpar a lama)', 'vila', 30),
  ('fazenda_plantar', 'Fazenda (sementes)', 'vila', 30), ('fazenda_comprar_canteiro', 'Fazenda (canteiro)', 'vila', 30),
  ('war_attack', 'Guerra', 'guerra', 30), ('war_heal', 'Guerra (cura)', 'guerra', 30), ('rocket_base_atacar', 'Base da Equipe Rocket', 'guerra', 30),
  ('battle_challenge', 'Batalha Pokémon (aposta)', 'batalhas', 30), ('battle_respond', 'Batalha Pokémon (aposta)', 'batalhas', 30),
  ('battle_cancel', 'Batalha Pokémon (aposta devolvida)', 'batalhas', 30), ('bt_finish', 'Batalha Pokémon (resultado da aposta)', 'batalhas', 30),
  ('battle_act', 'Aventura (fuga)', 'aventura', 20), ('rocket_win', 'Equipe Rocket (vitória da turma)', 'premios', 40),
  ('accept_duel', 'Duelo (aposta)', 'social', 30), ('create_duel', 'Duelo (aposta)', 'social', 30), ('decline_duel', 'Duelo (aposta devolvida)', 'social', 30),
  ('expire_duels', 'Duelo (aposta devolvida)', 'social', 30), ('resolve_duel', 'Duelo (resultado)', 'social', 30),
  ('place_bet', 'Bolão (aposta)', 'social', 30), ('settle_bets', 'Bolão (resultado)', 'social', 30), ('choose_team', 'Times', 'social', 30), ('team_week_tick', 'Times (prêmio da semana)', 'social', 30),
  ('buy_item', 'Loja & Visuais', 'compras', 30), ('pk_buy', 'Loja Pokémon', 'compras', 30), ('pk_cosmetic_buy', 'Roupas de Pokémon', 'compras', 30),
  ('buy_help', 'Ajudas (dica e tente outra vez)', 'compras', 30), ('change_class', 'Troca de herói', 'compras', 30), ('equip_comprar', 'Equipamentos (loja)', 'compras', 30),
  ('tcg_%', 'Cartas Pokegames', 'compras', 30),
  ('centro_curar', 'Centro Pokémon', 'pokemon', 30), ('creche_treinar', 'Creche', 'pokemon', 30), ('creche_devolve', 'Creche (devolução)', 'pokemon', 35),
  ('market_buy', 'Mercado', 'trocas', 30), ('leilao_lance', 'Leilão (lance)', 'trocas', 30), ('leilao_devolve', 'Leilão (lance devolvido)', 'trocas', 35),
  ('leilao_tick', 'Leilão (venda)', 'trocas', 30), ('equip_oferta_comprar', 'Feira de Equipamentos', 'trocas', 30),
  ('troca_propor', 'Troca de Pokémon (moedas guardadas)', 'trocas', 30), ('troca_responder', 'Troca de Pokémon', 'trocas', 30),
  ('troca_cancelar', 'Troca de Pokémon (devolução)', 'trocas', 30), ('troca_tick', 'Troca de Pokémon (devolução)', 'trocas', 30),
  ('rpg_premiar', 'Aventura (prêmio)', 'aventura', 20), ('rpg_gin_vitoria', 'Ginásio', 'aventura', 40), ('rpg_chefe_premiar', 'Chefe da rota', 'aventura', 40),
  ('rpg_elite_coroar', 'Desafio do Planalto', 'aventura', 40), ('rpg_missao_resgatar', 'Missão da Aventura', 'aventura', 40),
  ('rpg_desafio_%', 'Desafio na Aventura', 'aventura', 30), ('rpg_pvp_tick', 'Desafio na Aventura (devolução)', 'aventura', 30), ('exp_finalizar', 'Expedição', 'aventura', 30),
  ('gift_give', 'Presente', 'premios', 10), ('admin_gift', 'Presente do admin', 'premios', 40), ('quiz_%', 'Quiz', 'premios', 40),
  ('season_awards_give', 'Prêmios da temporada', 'premios', 40), ('admin_add_donation', 'Doação (PIX)', 'premios', 40),
  ('admin_adjust', 'Ajuste do admin', 'outros', 40), ('nivelamento_aplicar', 'Nivelamento da temporada', 'outros', 40)
on conflict (padrao) do nothing;

-- marca a origem do próximo pagamento (vale uma vez)
create or replace function public.ext_origem(_origem text, _tipo text default 'outros') returns void
language plpgsql volatile security definer set search_path = public, extensions as $$
begin
  perform set_config('pg.origem', coalesce(_origem, ''), true); perform set_config('pg.tipo', coalesce(_tipo, 'outros'), true);
end $$;
-- a andada junta as partes (baú, pedágio…) num pagamento só: aqui cada parte fica anotada
create or replace function public.ext_parte(_origem text, _valor int) returns void
language plpgsql volatile security definer set search_path = public, extensions as $$
declare p jsonb := coalesce(nullif(current_setting('pg.partes', true), '')::jsonb, '[]'::jsonb);
begin
  if coalesce(_valor, 0) = 0 then return; end if;
  perform set_config('pg.partes', (p || jsonb_build_array(jsonb_build_array(_origem, _valor)))::text, true);
end $$;

create or replace function public.moedas_trg() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare d int; o text; tp text; ctx text; partes jsonb; e jsonb; s int; resto int;
begin
  if tg_op = 'INSERT' then
    if coalesce(new.coins, 0) <> 0 then insert into moedas_extrato(user_id, valor, saldo, origem, tipo) values (new.user_id, new.coins, new.coins, 'Saldo inicial', 'outros'); end if;
    return new;
  end if;
  d := coalesce(new.coins, 0) - coalesce(old.coins, 0);
  o := nullif(current_setting('pg.origem', true), ''); tp := coalesce(nullif(current_setting('pg.tipo', true), ''), 'outros');
  perform set_config('pg.origem', '', true);   -- a marca vale uma vez só
  if o = 'andada' then partes := coalesce(nullif(current_setting('pg.partes', true), '')::jsonb, '[]'::jsonb); perform set_config('pg.partes', '', true); end if;
  if d = 0 then return new; end if;
  if o = 'andada' then   -- a andada: uma linha para cada parte, e o resto são as casas andadas
    s := old.coins; resto := d;
    for e in select x from jsonb_array_elements(partes) x loop
      continue when (e->>1)::int = 0;
      s := s + (e->>1)::int; resto := resto - (e->>1)::int;
      insert into moedas_extrato(user_id, valor, saldo, origem, tipo) values (new.user_id, (e->>1)::int, s, e->>0, 'tabuleiro');
    end loop;
    if resto <> 0 then insert into moedas_extrato(user_id, valor, saldo, origem, tipo) values (new.user_id, resto, new.coins, 'Casas andadas', 'tabuleiro'); end if;
    return new;
  end if;
  if o is null then   -- pelo nome da função que mexeu nas moedas
    get diagnostics ctx = pg_context;
    select m.origem, m.tipo into o, tp
      from (select (r.x)[1] fn, r.ord from regexp_matches(ctx, 'function "?(?:public\.)?([a-z_0-9]+)', 'g') with ordinality r(x, ord)) f
      join moedas_origens m on f.fn like m.padrao
     where f.fn <> 'moedas_trg'
     order by m.prioridade desc, f.ord limit 1;
    if o is null then
      select 'Outros (' || (r.x)[1] || ')' into o from regexp_matches(ctx, 'function "?(?:public\.)?([a-z_0-9]+)', 'g') with ordinality r(x, ord)
       where (r.x)[1] not in ('moedas_trg') order by r.ord desc limit 1;
      o := coalesce(o, 'Outros'); tp := 'outros';
    end if;
  end if;
  insert into moedas_extrato(user_id, valor, saldo, origem, tipo) values (new.user_id, d, new.coins, o, tp);
  return new;
end $$;
drop trigger if exists moedas_extrato_trg on public.characters;
create trigger moedas_extrato_trg after insert or update of coins on public.characters for each row execute function public.moedas_trg();

-- saldo inicial de quem já joga (o extrato começa batendo com o saldo)
insert into public.moedas_extrato(user_id, valor, saldo, origem, tipo)
select ch.user_id, ch.coins, ch.coins, 'Saldo inicial', 'outros' from public.characters ch
 where not exists (select 1 from public.moedas_extrato x where x.user_id = ch.user_id);

-- o extrato para o site: últimos dias, filtro por tipo e o resumo da semana
create or replace function public.moedas_extrato_ver(_tipo text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.extrato_cfg(); dias int := coalesce((c->>'dias')::int, 30); sem timestamptz := public.creche_semana();
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  delete from moedas_extrato where em < now() - make_interval(days => dias + 1);   -- limpeza: só os últimos dias ficam guardados
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'dias', dias, 'saldo', (select coins from characters where user_id = uid),
    'semana', jsonb_build_object('ganhou', coalesce((select sum(valor) from moedas_extrato where user_id = uid and em >= sem and valor > 0 and origem <> 'Saldo inicial'), 0),
                                 'gastou', coalesce((select -sum(valor) from moedas_extrato where user_id = uid and em >= sem and valor < 0), 0), 'desde', sem),
    'tipos', coalesce((select jsonb_agg(distinct tipo) from moedas_extrato where user_id = uid and em >= now() - make_interval(days => dias)), '[]'::jsonb),
    'linhas', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'em', x.em, 'valor', x.valor, 'saldo', x.saldo, 'origem', x.origem, 'tipo', x.tipo) order by x.id desc)
      from (select * from moedas_extrato where user_id = uid and em >= now() - make_interval(days => dias) and (_tipo is null or tipo = _tipo) order by id desc limit 600) x), '[]'::jsonb));
end $$;


-- do_move: versão do 103 com a mudança do arquivo 117
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
  boss world_bosses; mud int; passed int[]; tn int; champ uuid; hx jsonb; hh hunts; he hunt_entries; hgo int;
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
        perform public.go_back(me.id, (c->>'trap_push')::int);
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
        else perform public.go_back(me.id, nd.value); ev := ev || jsonb_build_object('t','recuo','msg','Lamaçal! Voltou ' || nd.value || ' casas.');
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
          perform public.go_back(other.id, (c->>'storm_push')::int);
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
        perform public.go_back(other.id, (c->>'duel_push')::int);
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
        perform public.go_back(me.id, (c->>'duel_push')::int);
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


-- admin_cfg_efetiva: versão do 115 com a mudança do arquivo 117
create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'leilao', public.leilao_cfg(), 'herois', public.herois_cfg(), 'temporada', public.temporada_cfg(), 'liga', public.liga_cfg(), 'pausa', public.pausa_cfg(), 'teto', public.teto_cfg(), 'boas_vindas', public.boas_vindas_cfg(), 'vila_bonus', public.vila_bonus_cfg(), 'tm_nivel', public.tm_nivel_cfg(), 'quiz_auto', public.quiz_auto_cfg(), 'cartas', public.tcg_cfg(), 'pokebound', public.pokebound_cfg(), 'visual', public.visual_cfg(), 'praca', public.praca_cfg(), 'rpg', public.rpg_cfg(), 'equip', public.equip_cfg(), 'base', public.cfg(), 'exp', public.exp_cfg(), 'vale', public.vale_cfg(), 'fazenda', public.fazenda_cfg(), 'ia', public.ia_cfg(), 'troca', public.troca_cfg(), 'guerra', public.guerra_cfg(), 'rocket_bases', public.rocket_bases_cfg(), 'extrato', public.extrato_cfg());   -- arquivo 117   -- arquivo 115   -- arquivo 114: troca entre jogadores   -- arquivo 113: escolha de ataques   -- arquivo 112: Vale do Treino e Fazenda   -- arquivo 111: Expedições
end $$;


revoke execute on function public.extrato_cfg(), public.ext_origem(text, text), public.ext_parte(text, int), public.moedas_trg() from public, anon, authenticated;
grant execute on function public.moedas_extrato_ver(text), public.admin_cfg_efetiva() to authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values
   ('💰 Extrato de moedas', 'Agora dá para ver de onde vêm e para onde vão as suas moedas: toque no seu saldo de moedas.
• Aparecem os últimos 30 dias: data e hora, de onde veio (Dia de pagamento, baú, pedágio, Ladino, Ladrão de estrada, vila, Quartel, Quiz, duelos, batalhas, Leilão, Mercado, troca, Creche, Centro Pokémon, lojas, guerra, Ginásio e tudo mais), quanto entrou ou saiu e o saldo depois.
• Dá para filtrar por tipo e ver o resumo da semana: quanto você ganhou e quanto gastou.
• O extrato começa hoje, com o seu saldo de agora.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
