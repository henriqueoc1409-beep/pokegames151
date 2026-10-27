-- =====================================================================
-- 46_cacada.sql
-- Pedido do dono em 22/10/2026: Caçada, um evento criado pelo admin.
--   * O admin escolhe um Pokémon (sem lendários), o nível, uma casa do caminho onde nasce o atalho e,
--     clicando no mapa, os pontos das casas novas até o local do Pokémon. O prazo é em dias.
--   * A casa escolhida vira uma bifurcação temporária: quem passa escolhe entrar na Caçada ou seguir.
--     Andar no atalho gasta os passos do dia normalmente. A silhueta do Pokémon fica no fim do caminho.
--   * O PRIMEIRO a parar no fim tenta capturar, com as 3 bolas de sempre (fórmula da 1ª geração).
--     Dando certo ou não, ele volta para a casa onde o atalho começa; as casas da Caçada somem e
--     quem ainda estava nelas também volta. Se ninguém chegar no prazo, o Pokémon foge.
--   * As casas não são apagadas do banco (outras tabelas apontam para elas): ficam escondidas (hidden).
-- Depende do 17, 42, 43 e 44. Antes, faça a cópia de segurança.
-- =====================================================================

alter table public.board_nodes drop constraint if exists board_nodes_kind_check;
alter table public.board_nodes add constraint board_nodes_kind_check
  check (kind in ('inicio','normal','bifurcacao','avanco','recuo','bau','xp','raio','troca','pagamento','carta','castelo',
                  'mina','desafio','ladrao','fonte','treinador','cacada','alvo'));
alter table public.board_nodes add column if not exists hunt_id bigint;
alter table public.board_nodes add column if not exists hidden boolean not null default false;

create table if not exists public.hunts (
  id          bigserial primary key,
  species     int not null references public.pokemon(id),
  level       int not null check (level between 2 and 100),
  fork_node   int not null,
  target_node int not null,
  node_ids    int[] not null,
  status      text not null default 'ativa' check (status in ('ativa', 'tentando', 'capturado', 'escapou', 'fugiu', 'cancelada')),
  hunter      uuid,
  hunter_name text,
  starts_at   timestamptz not null default now(),
  ends_at     timestamptz not null,
  resolved_at timestamptz,
  created_by  uuid,
  created_at  timestamptz not null default now()
);
alter table public.hunts enable row level security;
drop policy if exists p_hunts on public.hunts;
create policy p_hunts on public.hunts for select to authenticated using (true);
revoke all on public.hunts from anon, authenticated;
grant select on public.hunts to authenticated;
alter table public.encounters add column if not exists hunt_id bigint;
do $$ begin
  begin alter publication supabase_realtime add table public.hunts; exception when duplicate_object then null; end;
end $$;

-- traz de volta para a casa de origem (onde o atalho começa) quem está nas casas da Caçada
create or replace function public.hunt_return(_hunt bigint, _uid uuid default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare h hunts;
begin
  select * into h from hunts where id = _hunt;
  if h.id is null then return; end if;
  update characters ch set node = h.fork_node,
         path = case when array_position(ch.path, h.fork_node) is null then array[h.fork_node] else ch.path[1:array_position(ch.path, h.fork_node)] end,
         route = coalesce(ch.route, '{}'::jsonb) - h.fork_node::text
   where (ch.node = any(h.node_ids)) and (_uid is null or ch.user_id = _uid);
end $$;

-- termina a Caçada: some com as casas e devolve todo mundo
create or replace function public.hunt_finish(_hunt bigint, _caught boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare h hunts; pn text;
begin
  select * into h from hunts where id = _hunt for update;
  if h.id is null or h.status not in ('ativa', 'tentando') then return; end if;
  select name into pn from pokemon where id = h.species;
  update hunts set status = case when _caught then 'capturado' when h.hunter is not null then 'escapou' else 'fugiu' end, resolved_at = now() where id = h.id;
  perform public.hunt_return(h.id);
  update characters set route = coalesce(route, '{}'::jsonb) - h.fork_node::text where route ? h.fork_node::text;
  update board_nodes set next_b = null where id = h.fork_node;
  update board_nodes set hidden = true where id = any(h.node_ids);
  insert into event_log(user_id, kind, message) values (h.hunter, 'cacada',
    case when _caught then '🎯 ' || h.hunter_name || ' chegou primeiro na Caçada e CAPTUROU o ' || pn || ' (Nv ' || h.level || ')!'
         when h.hunter is not null then '🎯 ' || h.hunter_name || ' chegou primeiro na Caçada, mas o ' || pn || ' escapou! As casas da Caçada sumiram.'
         else '🎯 Ninguém chegou a tempo: o ' || pn || ' da Caçada fugiu e as casas sumiram.' end);
end $$;

-- alguém parou no fim do caminho
create or replace function public.hunt_arrive(_cid uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare me characters; h hunts; pn text;
begin
  select * into me from characters where id = _cid;
  select * into h from hunts where target_node = me.node and status in ('ativa', 'tentando') for update;
  if h.id is null then return '[]'::jsonb; end if;
  select name into pn from pokemon where id = h.species;
  if h.status = 'ativa' and now() < h.ends_at then
    update hunts set status = 'tentando', hunter = me.user_id, hunter_name = me.name where id = h.id;
    insert into event_log(user_id, kind, message) values (me.user_id, 'cacada', '🎯 ' || me.name || ' chegou primeiro no fim da Caçada e vai tentar capturar o ' || pn || '!');
    return jsonb_build_array(jsonb_build_object('t', 'cacada', 'msg', '🎯 Você chegou primeiro! A silhueta era um ' || pn || ' (Nv ' || h.level || '). Prepare as Poké Bolas: são 3 tentativas. Depois você volta para a casa onde a Caçada começou.'));
  end if;
  if h.status = 'tentando' and h.hunter = me.user_id then
    -- quem chegou andou de novo sem tentar a captura: o Pokémon escapa
    perform public.hunt_finish(h.id, false);
    return jsonb_build_array(jsonb_build_object('t', 'cacada', 'msg', '🎯 Você não tentou capturar o ' || pn || ' e ele escapou! As casas da Caçada sumiram.'));
  end if;
  perform public.hunt_return(h.id, me.user_id);
  return jsonb_build_array(jsonb_build_object('t', 'cacada', 'msg', '🎯 Alguém chegou antes de você no fim da Caçada! Você voltou para a casa onde ela começa.'));
end $$;

-- prazo: se ninguém chegou, o Pokémon foge; se quem chegou sumiu sem tentar por 2 dias, ele escapa
create or replace function public.hunt_tick() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare h hunts;
begin
  for h in select * from hunts where status in ('ativa', 'tentando') loop
    if h.status = 'ativa' and now() >= h.ends_at then perform public.hunt_finish(h.id, false);
    elsif h.status = 'tentando' and now() >= h.ends_at + interval '2 days' then perform public.hunt_finish(h.id, false); end if;
  end loop;
end $$;

-- admin cria a Caçada: _points = [[x,y], ...] na ordem, do começo até o local do Pokémon
create or replace function public.admin_hunt_create(_species int, _level int, _fork int, _points jsonb, _days int default 3) returns public.hunts
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); f board_nodes; p pokemon; n int; i int; base int; ids int[] := '{}'; h hunts; x int; y int; mw int; mh int;
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador cria Caçadas.'; end if;
  if exists (select 1 from hunts where status in ('ativa', 'tentando')) then raise exception 'Já existe uma Caçada em andamento.'; end if;
  select * into p from pokemon where id = _species;
  if p.id is null or not public.gen_ok(p.id) then raise exception 'Escolha um Pokémon da Pokédex liberada.'; end if;
  if p.id in (144, 145, 146, 150, 151, 243, 244, 245, 249, 250, 251) then raise exception 'Lendários não entram na Caçada.'; end if;
  if coalesce(_level, 0) not between 2 and 100 then raise exception 'Nível: de 2 a 100.'; end if;
  if coalesce(_days, 0) not between 1 and 14 then raise exception 'Prazo: de 1 a 14 dias.'; end if;
  select * into f from board_nodes where id = _fork;
  if f.id is null or f.hidden then raise exception 'Escolha uma casa do mapa para começar.'; end if;
  if f.next_b is not null or f.kind in ('bifurcacao', 'castelo', 'inicio') or f.next_a is null then raise exception 'Essa casa não pode virar começo de Caçada (escolha uma casa comum do caminho).'; end if;
  n := jsonb_array_length(coalesce(_points, '[]'::jsonb));
  if n not between 2 and 60 then raise exception 'O caminho precisa ter de 2 a 60 casas.'; end if;
  mw := coalesce((public.cfg()->'map_meta'->>'w')::int, 4000); mh := coalesce((public.cfg()->'map_meta'->>'h')::int, 4000);
  select coalesce(max(id), 0) + 1 into base from board_nodes;
  for i in 0 .. n - 1 loop
    x := (_points->i->>0)::numeric::int; y := (_points->i->>1)::numeric::int;
    if x is null or y is null or x < 0 or y < 0 or x > mw + 400 or y > mh + 400 then raise exception 'Ponto % fora do mapa.', i + 1; end if;
    insert into board_nodes(id, x, y, kind, value, region, branch, next_a, next_b, dist)
    values (base + i, x, y, case when i = n - 1 then 'alvo' else 'cacada' end, 0, f.region, f.branch,
            case when i = n - 1 then null else base + i + 1 end, null, f.dist);
    ids := ids || (base + i);
  end loop;
  insert into hunts(species, level, fork_node, target_node, node_ids, ends_at, created_by)
  values (_species, _level, _fork, base + n - 1, ids, now() + make_interval(days => _days), uid) returning * into h;
  update board_nodes set hunt_id = h.id where id = any(ids);
  update board_nodes set next_b = base where id = _fork;
  insert into event_log(kind, message) values ('cacada', '🎯 Caçada aberta! Um Pokémon misterioso apareceu no mapa, em ' || f.region || '. Quem chegar primeiro tenta capturar. Prazo: ' || _days || ' dia(s).');
  insert into admin_audit_log(admin_id, action, target, after) values (uid, 'cacada', h.id::text, to_jsonb(h));
  return h;
end $$;

create or replace function public.admin_hunt_cancel(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active();
begin
  if not public.has_role(uid, 'admin') then raise exception 'Só o administrador.'; end if;
  perform public.hunt_finish(_id, false);
  update hunts set status = 'cancelada' where id = _id;
  insert into admin_audit_log(admin_id, action, target) values (uid, 'cacada_cancelada', _id::text);
end $$;

create or replace function public.house_extra(_cid uuid, _kind text, _modes jsonb, _dodge boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.casas_cfg(); me characters; ev jsonb := '[]'::jsonb; coins int := 0; sal int := 0; w jsonb; amt int; stone text; solved int; ball text;
begin
  select * into me from characters where id = _cid;
  if _kind = 'mina' then
    -- Mina de pedras: chance de achar uma pedra de evolução; senão, umas moedas
    if random() * 100 < (c->>'mina_stone_pct')::numeric then
      stone := public.random_stone();
      insert into bag_items(user_id, item, qty) values (me.user_id, stone, 1) on conflict (user_id, item) do update set qty = bag_items.qty + 1;
      ev := ev || jsonb_build_object('t', 'mina', 'msg', '⛏️ Mina de pedras: você achou uma ' || public.stone_name(stone) || '! Ela foi para a bolsa.');
      insert into event_log(user_id, kind, message) values (me.user_id, 'mina', me.name || ' achou uma ' || public.stone_name(stone) || ' na mina!');
    else
      coins := (c->>'mina_coins')::int;
      ev := ev || jsonb_build_object('t', 'mina', 'msg', '⛏️ Mina de pedras: nenhuma pedra hoje, mas você juntou ' || coins || ' moedas de minério.');
    end if;
  elsif _kind = 'desafio' then
    -- Casa do Desafio: premia quem acertou os 4 modos do dia; quem errou algum volta casas
    select count(*) into solved from jsonb_each(_modes) x where (x.value->>'solved')::boolean;
    if solved >= 4 then
      coins := (c->>'desafio_coins')::int;
      w := public.walk(_cid, (c->>'desafio_steps')::int); sal := (w->>'salary')::int;
      ev := ev || jsonb_build_object('t', 'desafio', 'msg', '🎯 Casa do Desafio: você acertou os 4 modos! Ganhou ' || coins || ' moedas e avançou ' || (c->>'desafio_steps') || ' casas.');
    else
      amt := (c->>'desafio_back')::int;
      if _dodge then ev := ev || jsonb_build_object('t', 'desafio', 'msg', '🎯 Casa do Desafio: você não acertou os 4 modos, mas o Atalho te livrou da punição.');
      elsif public.is_shielded(_cid) then ev := ev || jsonb_build_object('t', 'desafio', 'msg', '🎯 Casa do Desafio: você não acertou os 4 modos, mas a Bênção te segurou.');
      else
        perform public.go_back(_cid, amt);
        ev := ev || jsonb_build_object('t', 'desafio', 'msg', '🎯 Casa do Desafio: só acertou ' || solved || ' de 4 modos. Voltou ' || amt || ' casas.');
      end if;
    end if;
  elsif _kind = 'ladrao' then
    -- Ladrão de estrada: leva uma parte das moedas (o Clérigo perde metade)
    amt := least((c->>'ladrao_max')::int, floor(me.coins * (c->>'ladrao_pct')::numeric / 100))::int;
    if me.class::text = 'clerigo' then amt := ceil(amt / 2.0)::int; end if;
    if amt <= 0 then ev := ev || jsonb_build_object('t', 'ladrao', 'msg', '🦹 Um ladrão de estrada revirou sua mochila, mas não achou nenhuma moeda. Ufa!');
    elsif _dodge then ev := ev || jsonb_build_object('t', 'ladrao', 'msg', '🦹 Um ladrão de estrada apareceu, mas o Atalho te tirou do caminho dele.');
    elsif public.is_shielded(_cid) then ev := ev || jsonb_build_object('t', 'ladrao', 'msg', '🦹 Um ladrão de estrada tentou te roubar, mas a Bênção te protegeu.');
    else
      coins := -amt;
      ev := ev || jsonb_build_object('t', 'ladrao', 'msg', '🦹 Ladrão de estrada! Ele levou ' || amt || ' moedas da sua mochila.');
    end if;
  elsif _kind = 'fonte' then
    -- Fonte das Bolas: ganha uma Great Ball ou, com sorte, uma Ultra Ball
    ball := case when random() * 100 < (c->>'fonte_ultra_pct')::numeric then 'ultra_ball' else 'great_ball' end;
    insert into bag_items(user_id, item, qty) values (me.user_id, ball, 1) on conflict (user_id, item) do update set qty = bag_items.qty + 1;
    ev := ev || jsonb_build_object('t', 'fonte', 'msg', '⛲ Fonte das Bolas: saiu uma ' || case when ball = 'ultra_ball' then 'Ultra Ball' else 'Great Ball' end || ' para a sua bolsa!');
  elsif _kind = 'treinador' then
    -- Treinador no caminho: batalha automática 3x3 contra um treinador do jogo (arquivo 43)
    w := public.npc_fight(_cid);
    ev := ev || coalesce(w->'ev', '[]'::jsonb); coins := coins + coalesce((w->>'coins')::int, 0);
  elsif _kind = 'alvo' then
    -- fim do caminho da Caçada (arquivo 46): o primeiro a chegar tenta capturar; os outros voltam
    ev := ev || public.hunt_arrive(_cid);
  end if;
  return jsonb_build_object('ev', ev, 'coins', coins, 'sal', sal);
end $$;

create or replace function public.do_move(_d date, _recovery boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := auth.uid(); c jsonb := public.cfg(); today date := public.game_today();
  me characters; other characters; nd board_nodes; tr traps; w jsonb; x record;
  m public.puzzle_mode; s guess_sessions; st int; modes jsonb := '{}'::jsonb;
  base int := 0; roll int; r2 int; i int; bonus int; skill_steps int := 0; total int; from_node int; landed int; path0 int;
  ev jsonb := '[]'::jsonb; sal int := 0; extra_coins int := 0; extra_xp int := 0; cls text; sv int; skill_on boolean; dodge boolean := false;
  card int; chance int; steal int; my_dist int; tmp_node int; tmp_path int[]; msg text; amt int;
  xp_gain int; coin_gain int; new_level int; old_level int;
  leader uuid; prop properties; toll int; bounty int := coalesce((public.cfg()->>'bounty_coins')::int, 60);
  boss world_bosses; mud int; passed int[]; champ uuid; hx jsonb;
begin
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
  if skill_on and cls = 'arqueiro' then
    for i in 2..greatest(sv,2) loop
      r2 := (c->>'roll_min')::int + floor(random() * ((c->>'roll_max')::int - (c->>'roll_min')::int + 1))::int;
      roll := greatest(roll, r2);
    end loop;
    ev := ev || jsonb_build_object('t','habilidade','msg','Tiro certeiro: a roleta girou ' || greatest(sv,2) || ' vezes e ficou com ' || roll || '.');
  end if;
  if cls = 'arqueiro' and roll < (c->>'arqueiro_min_die')::int then
    roll := (c->>'arqueiro_min_die')::int;
    ev := ev || jsonb_build_object('t','arqueiro','msg','Olho de arqueiro: a roleta vale no mínimo ' || roll || '.');
  end if;
  if skill_on and cls = 'domador' then
    roll := roll * greatest(sv,2);
    ev := ev || jsonb_build_object('t','habilidade','msg','Montaria: a roleta valeu ' || greatest(sv,2) || ' vezes mais (' || roll || ').');
  end if;
  if skill_on and cls in ('guerreiro','ladino','clerigo') and sv > 0 then
    skill_steps := sv;
    ev := ev || jsonb_build_object('t','habilidade','msg',
      case cls when 'guerreiro' then 'Investida' when 'ladino' then 'Atalho' else 'Bênção' end || ': +' || sv || ' casas.');
  end if;
  if skill_on and cls = 'mago' then
    skill_steps := public.next_good_steps(me.id, sv);
    ev := ev || jsonb_build_object('t','habilidade','msg', case when skill_steps > 0 then 'Teleporte: saltou ' || skill_steps || ' casas até uma casa especial.' else 'Teleporte: nenhuma casa especial ao alcance.' end);
  end if;
  if skill_on and cls = 'ladino' then dodge := true; end if;
  if skill_on and cls = 'clerigo' then ev := ev || jsonb_build_object('t','habilidade','msg','Bênção ativa: nada te empurra para trás hoje.'); end if;

  bonus := me.bonus_steps;
  total := base + roll + bonus + skill_steps;
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

  if me.arrived_rank is not null then
    ev := ev || jsonb_build_object('t','castelo','msg','Você já está no Castelo. Continue jogando para ganhar moedas, XP e vencer rodadas.');
    total := 0;
  else
    update characters set bonus_steps = 0 where id = me.id;
    path0 := coalesce(array_length(me.path,1),1);
    w := public.walk(me.id, total);
    sal := sal + (w->>'salary')::int;
    landed := (w->>'node')::int;

    -- encontro com o lendário (passando ou parando)
    select * into boss from world_bosses where status = 'ativo' order by id desc limit 1;
    if boss.id is not null then
      passed := (select path from characters where id = me.id)[path0 : coalesce(array_length((select path from characters where id = me.id),1),1)];
      if boss.node = any(passed) and not exists (select 1 from boss_contacts bc where bc.boss_id = boss.id and bc.user_id = uid) then
        insert into boss_contacts(boss_id, user_id) values (boss.id, uid);
        ev := ev || jsonb_build_object('t','lendario','msg','Você encontrou o lendário ' || (select name from pokemon where id = boss.pokemon_id) || '! Agora pode atacá-lo pelo painel.');
      end if;
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
          update characters set coins = coins - steal where id = x.id;
          extra_coins := extra_coins + steal;
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
        update characters set coins = coins + (c->>'trap_reward')::int where user_id = tr.owner_id;
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
        extra_coins := extra_coins + (c->>'chest_coins')::int;
        ev := ev || jsonb_build_object('t','bau','msg','Achou um baú com ' || (c->>'chest_coins') || ' moedas.');
      elsif nd.kind = 'xp' then
        extra_xp := extra_xp + (c->>'xp_square')::int;
        ev := ev || jsonb_build_object('t','xp','msg','Treino na clareira: +' || (c->>'xp_square') || ' XP.');
      elsif nd.kind = 'pagamento' then
        ev := ev || jsonb_build_object('t','pagamento','msg','Parou no Dia de pagamento.');
      elsif nd.kind = 'carta' then
        card := floor(random() * 6)::int;
        if card = 0 then
          extra_coins := extra_coins + (c->>'card_coins_win')::int;
          ev := ev || jsonb_build_object('t','carta','msg','Carta da sorte: um treinador agradecido te deu ' || (c->>'card_coins_win') || ' moedas.');
        elsif card = 1 then
          amt := (c->>'card_coins_lose')::int; if cls = 'clerigo' then amt := ceil(amt / 2.0); end if;
          extra_coins := extra_coins - amt;
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
            extra_coins := extra_coins + bounty;
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
        update characters set coins = coins - steal where id = other.id;
        perform public.go_back(other.id, (c->>'duel_push')::int);
        extra_coins := extra_coins + steal;
        ev := ev || jsonb_build_object('t','duelo','msg','Encontro com ' || other.name || ': você venceu o duelo, ganhou ' || steal || ' moedas' || case when public.is_shielded(other.id) then '.' else ' e empurrou o rival.' end);
        if other.user_id = leader then
          extra_coins := extra_coins + bounty;
          ev := ev || jsonb_build_object('t','procurado','msg','Recompensa: você venceu o procurado e ganhou ' || bounty || ' moedas.');
        end if;
        insert into event_log(user_id, kind, message) values (uid, 'duelo', me.name || ' venceu um duelo contra ' || other.name || '.');
      else
        steal := least((c->>'duel_coins')::int, greatest(0, me.coins + extra_coins));
        update characters set coins = coins + steal where id = other.id;
        extra_coins := extra_coins - steal;
        perform public.go_back(me.id, (c->>'duel_push')::int);
        ev := ev || jsonb_build_object('t','duelo','msg','Encontro com ' || other.name || ': você perdeu o duelo e ' || steal || ' moedas' || case when public.is_shielded(me.id) then ', mas a Bênção te manteve no lugar.' else ' e voltou ' || (c->>'duel_push') || ' casas.' end);
        insert into event_log(user_id, kind, message) values (uid, 'duelo', other.name || ' defendeu sua casa contra ' || me.name || '.');
      end if;
    end if;

    -- 4) pedágio da pousada de outro jogador
    select * into me from characters where id = me.id;
    select * into prop from properties where node = me.node and owner <> uid for update;
    if prop.node is not null then
      toll := greatest((c->>'property_min_toll')::int, ceil(prop.price * (c->>'property_toll_pct')::numeric / 100)::int);
      toll := least(toll, greatest(0, me.coins + extra_coins + base * (c->>'coins_per_step')::int));
      if toll > 0 then
        extra_coins := extra_coins - toll;
        update characters set coins = coins + toll where user_id = prop.owner;
        update properties set tolls_earned = tolls_earned + toll where node = prop.node;
        ev := ev || jsonb_build_object('t','pousada','msg','Pedágio na pousada de ' || (select name from characters where user_id = prop.owner) || ': -' || toll || ' moedas.');
        insert into event_log(user_id, kind, message) values (uid, 'pousada', me.name || ' pagou ' || toll || ' moedas de pedágio na pousada de ' || (select name from characters where user_id = prop.owner) || '.');
      end if;
    end if;
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
  update characters set xp_total = xp_total + xp_gain, level = new_level,
         coins = greatest(0, coins + coin_gain), last_move_date = greatest(coalesce(last_move_date, _d), _d)
   where id = me.id returning * into me;

  insert into daily_moves(user_id, move_date, modes, base_steps, roll, bonus_steps, skill_steps, from_node, to_node, xp_gained, coins_gained, events, recovered)
  values (uid, _d, modes, base, roll, bonus, skill_steps, from_node, me.node, xp_gain, coin_gain + sal, ev, _recovery);
  insert into event_log(user_id, kind, message, data)
  values (uid, 'andou', me.name || ' andou ' || total || ' casas' || case when _recovery then ' recuperando o dia ' || to_char(_d, 'DD/MM') else '' end || '.', jsonb_build_object('steps', total));

  return jsonb_build_object('date', _d, 'recovery', _recovery, 'base', base, 'roll', roll, 'bonus', bonus, 'skill', skill_steps, 'total', total, 'modes', modes,
    'from', from_node, 'to', me.node, 'path', to_jsonb(me.path), 'events', ev,
    'xp', xp_gain, 'coins', coin_gain + sal, 'level', new_level, 'leveled', new_level > old_level);
end $$;

create or replace function public.pk_sync() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.pk_cfg(); dm record; pool int; team uuid[]; each_xp int; mid uuid;
  sp int; lv int; maxd int; nd board_nodes; enc encounters; hh hunts; old encounters; start_at timestamptz := coalesce((public.cfg()->>'pk_start_at')::timestamptz, now());
begin
  select max(dist) into maxd from board_nodes;
  for dm in select d.* from daily_moves d where d.user_id = uid and d.created_at >= start_at
             and not exists (select 1 from pk_move_sync s where s.move_id = d.id) order by d.created_at loop
    -- XP dos Pokémon da equipe: dividido igualmente
    pool := (c->'xp'->>'move_base')::int + (c->'xp'->>'per_step')::int * coalesce(dm.base_steps, 0)
          + (c->'xp'->>'per_mode')::int * (select count(*) from jsonb_each(case when jsonb_typeof(dm.modes->'modes') = 'object' then dm.modes->'modes' else dm.modes end) e
                                           where jsonb_typeof(e.value) = 'object' and coalesce((e.value->>'solved')::boolean, false));
    select array_agg(id order by team_slot) into team from monsters where user_id = uid and team_slot is not null;
    insert into pk_move_sync(move_id, user_id, xp_pool) values (dm.id, uid, case when team is null then 0 else pool end);
    if team is not null then
      each_xp := greatest(1, pool / cardinality(team));
      foreach mid in array team loop perform public.pk_give_xp(mid, each_xp, 'tabuleiro'); end loop;
    end if;
    -- encontro na casa onde parou (o anterior que ficou aberto foge)
    for old in select * from encounters where user_id = uid and status = 'aberto' loop
      update encounters set status = 'fugiu', resolved_at = now() where id = old.id;
      if old.hunt_id is not null then perform public.hunt_finish(old.hunt_id, false); end if;   -- não tentou: o Pokémon da Caçada foge
    end loop;
    select * into nd from board_nodes where id = dm.to_node;
    hh := null;
    if nd.kind = 'alvo' then select * into hh from hunts where target_node = nd.id and status = 'tentando' and hunter = uid; end if;
    if hh.id is not null then
      sp := hh.species; lv := hh.level;   -- Caçada: o Pokémon escolhido pelo admin
    else
    sp := public.pk_pick_species(nd.region);
    lv := least(100, greatest(2, (c->'encounter'->>'level_min')::int
                + floor((1 - coalesce(nd.dist, maxd)::numeric / greatest(maxd, 1)) * (c->'encounter'->>'level_span')::int)::int
                + floor(random() * ((c->'encounter'->>'level_spread')::int + 1))::int));
    end if;
    insert into encounters(user_id, move_id, node, species_id, level, throws_left, hunt_id)
    values (uid, dm.id, dm.to_node, sp, lv, (c->'capture'->>'throws')::int, hh.id) on conflict (move_id) do nothing;
    perform public.pk_dex_mark(uid, sp, false);
  end loop;
  select * into enc from encounters where user_id = uid and status = 'aberto' order by created_at desc limit 1;
  return jsonb_build_object('encounter', case when enc.id is null then null else to_jsonb(enc) end,
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.id) from mon_events e where e.user_id = uid and not e.seen), '[]'::jsonb));
end $$;

create or replace function public.encounter_throw(_id uuid, _ball text default 'poke') returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); e encounters; p pokemon; b jsonb := public.pk_cfg()->'capture'->'balls'->_ball;
  r1 int; f int; caught boolean; shakes int; m monsters; have int;
begin
  if b is null then raise exception 'Bola inválida.'; end if;
  select * into e from encounters where id = _id and user_id = uid for update;
  if e.id is null then raise exception 'Encontro não encontrado.'; end if;
  if e.status <> 'aberto' then raise exception 'Esse encontro já terminou.'; end if;
  if (b->>'price')::int > 0 then
    select qty into have from bag_items where user_id = uid and item = _ball || '_ball' for update;
    if coalesce(have, 0) < 1 then raise exception 'Você não tem %.', b->>'name'; end if;
    update bag_items set qty = qty - 1 where user_id = uid and item = _ball || '_ball';
  end if;
  select * into p from pokemon where id = e.species_id;
  r1 := floor(random() * ((b->>'range')::int + 1));
  f := least(255, floor(255 * 4 / (b->>'factor')::numeric))::int;
  caught := r1 <= p.catch_rate and floor(random() * 256) <= f;
  if caught then
    m := public.pk_new_monster(uid, e.species_id, e.level);
    update encounters set status = 'capturado', throws_left = throws_left - 1, mon_id = m.id, resolved_at = now() where id = e.id;
    insert into event_log(user_id, kind, message) select uid, 'captura', ch.name || ' capturou um ' || p.name || ' (Nv ' || e.level || ')!' from characters ch where ch.user_id = uid;
    if e.hunt_id is not null then perform public.hunt_finish(e.hunt_id, true); end if;
    return jsonb_build_object('caught', true, 'shakes', 3, 'monster', to_jsonb(m), 'throws_left', e.throws_left - 1);
  end if;
  shakes := case when r1 > p.catch_rate then 0 else 1 + floor(random() * 2)::int end;
  update encounters set throws_left = throws_left - 1,
         status = case when throws_left - 1 <= 0 then 'fugiu' else status end,
         resolved_at = case when throws_left - 1 <= 0 then now() end
   where id = e.id returning * into e;
  if e.status = 'fugiu' and e.hunt_id is not null then perform public.hunt_finish(e.hunt_id, false); end if;
  return jsonb_build_object('caught', false, 'shakes', shakes, 'throws_left', e.throws_left, 'fled', e.status = 'fugiu');
end $$;

create or replace function public.encounter_skip(_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); e encounters;
begin
  update encounters set status = 'recusado', resolved_at = now() where id = _id and user_id = uid and status = 'aberto' returning * into e;
  if e.hunt_id is not null then perform public.hunt_finish(e.hunt_id, false); end if;
end $$;

create or replace function public.settle() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare d date := game_today(); c jsonb := cfg(); r record; x record; pos int; bs int; bc int; s seasons; names text := ''; lastu uuid; firstu uuid;
begin
  perform pg_advisory_xact_lock(151151);
  for r in select distinct puzzle_date as pd from guess_sessions
           where puzzle_date < d and not recovered and puzzle_date not in (select rd.d from round_days rd) order by 1 loop
    insert into round_days(d) values (r.pd);
    pos := 0; names := ''; lastu := null; firstu := null;
    for x in
      select p.user_id,
             sum(public.rank_attempts(coalesce(gs.attempts,0), coalesce(gs.solved,false), coalesce(gs.hints_used,0), coalesce(gs.retries_used,0)))::int as total,
             count(*) filter (where gs.solved)::int as solved,
             max(gs.finished_at) as fin
      from (select distinct user_id from guess_sessions where puzzle_date = r.pd and not recovered) p
      join characters ch on ch.user_id = p.user_id
      cross join (select mode from daily_puzzles where puzzle_date = r.pd) m
      left join guess_sessions gs on gs.user_id = p.user_id and gs.puzzle_date = r.pd and gs.mode = m.mode
      group by p.user_id
      order by 2 asc, 4 asc nulls last
    loop
      pos := pos + 1;
      bs := coalesce((c->'round_bonus_steps'->>(pos-1))::int, 0);
      bc := coalesce((c->'round_bonus_coins'->>(pos-1))::int, 0);
      insert into round_results(d, user_id, rank, attempts, modes_solved, bonus_steps, bonus_coins)
      values (r.pd, x.user_id, pos, x.total, x.solved, bs, bc);
      if bs > 0 or bc > 0 then update characters set bonus_steps = bonus_steps + bs, coins = coins + bc where user_id = x.user_id; end if;
      if pos = 1 then names := (select name from characters where user_id = x.user_id) || ' venceu a rodada de ' || to_char(r.pd, 'DD/MM') || ' com ' || x.total || ' tentativas'; firstu := x.user_id; end if;
      lastu := x.user_id;
    end loop;
    if firstu is not null then
      insert into villages(user_id) values (firstu) on conflict do nothing;
      update villages set statues = statues + 1 where user_id = firstu;
    end if;
    if pos >= 2 and lastu is not null then
      insert into villages(user_id) values (lastu) on conflict do nothing;
      update villages set mud = 3 where user_id = lastu;
    end if;
    if names <> '' then insert into event_log(kind, message) values ('rodada', names || '.'); end if;
  end loop;
  perform public.settle_bets();
  perform public.expire_duels();
  perform public.boss_tick();
  perform public.team_week_tick();
  perform public.league_tick();
  perform public.rocket_tick();
  perform public.hunt_tick();
  select * into s from seasons order by id desc limit 1;
  if s.status = 'encerrada' and s.ended_on < d then perform public.start_new_season(); end if;
end $$;

revoke execute on function public.hunt_return(bigint, uuid), public.hunt_finish(bigint, boolean), public.hunt_arrive(uuid), public.hunt_tick() from public, anon, authenticated;
revoke execute on function public.admin_hunt_create(int, int, int, jsonb, int), public.admin_hunt_cancel(bigint) from public, anon;
grant execute on function public.admin_hunt_create(int, int, int, jsonb, int), public.admin_hunt_cancel(bigint), public.pk_sync(), public.encounter_throw(uuid, text),
  public.encounter_skip(uuid), public.do_move(date, boolean) to authenticated;
