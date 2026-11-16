-- Arquivo 113 (pedido do dono em 16/11/2026, aprovado pelo grupo):
-- (1) Ginásio da Aventura em UMA batalha só, como na Red/Blue: você escala a mesma quantidade de Pokémon do Líder, na ordem que quiser;
--     a cada turno ataca, troca (gasta o turno) ou usa item (até 2 na batalha inteira); quem desmaia, você escolhe quem entra; Revive volta
--     com metade da vida. XP de cada Pokémon do Líder derrotado dividida entre os seus que lutaram contra ele (como na Red/Blue). Os escalados
--     ficam travados até o fim (Centro, Creche, Leilão, sair da equipe). Batalha não terminada vira derrota em `rpg.ginasios.expira_min` (30) minutos.
-- (2) Ataques dos Pokémon controlados pelo jogo (Líderes, selvagens da Aventura e das Expedições, Chefe da rota, Equipe Rocket): 4 ataques com
--     cobertura (pelo menos 2 de dano de tipos diferentes; Líderes também com TMs) e escolha nova (`ia_pick`): nunca usa ataque que não afeta,
--     no máximo 1 status a cada 3 turnos, não repete status que já fez efeito, prefere o super efetivo; Líderes usam o mais forte em 70% das vezes.
--     Números em `game_config.config.ia` (Ajustes do jogo). A Liga do Planalto (Elite 4) continua exatamente como era.
-- Também: a Liga da Aventura passa a se chamar "Desafio do Planalto" nas mensagens (só o texto).

alter table public.rpg_gin_tent add column if not exists batalha uuid;
-- o time do Líder continua secreto: na batalha só fica quem já entrou em campo; os outros esperam aqui (ninguém lê pelo site)
create table if not exists public.rpg_gin_ocultos (
  battle_id uuid not null references public.battles(id) on delete cascade, idx int not null, mon jsonb not null, primary key (battle_id, idx));
alter table public.rpg_gin_ocultos enable row level security;

-- ---------- (2) ataques dos Pokémon controlados pelo jogo ----------
create or replace function public.ia_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "lider_melhor_pct": 70, "status_cada": 3, "status_max": 2}'::jsonb || coalesce(public.cfg()->'ia', '{}'::jsonb)
$$;

-- ataque de dano (inclui os de dano fixo e os de um golpe só)
create or replace function public.ia_dano(_mv public.pk_moves) returns boolean
language sql immutable as $$
  select coalesce(_mv.power, 0) > 0 or coalesce(_mv.effect, '') in ('SPECIAL_DAMAGE_EFFECT', 'SUPER_FANG_EFFECT', 'OHKO_EFFECT')
$$;
-- ataques que não funcionam (ou não fazem nada) no nosso motor
create or replace function public.ia_inutil(_mv public.pk_moves) returns boolean
language sql immutable as $$
  select coalesce(_mv.effect, '') in ('TRANSFORM_EFFECT', 'MIMIC_EFFECT', 'DISABLE_EFFECT', 'CONVERSION_EFFECT', 'BIDE_EFFECT', 'SUBSTITUTE_EFFECT',
    'SPLASH_EFFECT', 'SWITCH_AND_TELEPORT_EFFECT', 'G2_NAO_FUNCIONA') or _mv.id = 68
$$;
-- valor de um ataque de dano para montar o time (força × mesmo tipo × precisão, com desconto nos que gastam turno ou o próprio Pokémon)
create or replace function public.ia_valor(_mv public.pk_moves, _t1 text, _t2 text) returns numeric
language sql immutable as $$
  select (case when _mv.effect in ('SPECIAL_DAMAGE_EFFECT', 'SUPER_FANG_EFFECT') then 45 when _mv.effect = 'OHKO_EFFECT' then 30
               else coalesce(_mv.power, 0) * case when _mv.type in (_t1, coalesce(_t2, '')) then 1.5 else 1 end end)
       * coalesce(_mv.accuracy, 100) / 100.0
       * case when _mv.effect in ('CHARGE_EFFECT', 'FLY_EFFECT', 'HYPER_BEAM_EFFECT') then 0.6 when _mv.effect = 'EXPLODE_EFFECT' then 0.3
              when _mv.effect = 'DREAM_EATER_EFFECT' then 0.2 when _mv.effect in ('JUMP_KICK_EFFECT', 'RECOIL_EFFECT') then 0.9 else 1 end
$$;
-- utilidade de um ataque de status para montar o time
create or replace function public.ia_status_valor(_mv public.pk_moves) returns numeric
language sql immutable as $$
  select (case when _mv.effect = 'SLEEP_EFFECT' then 100 when _mv.effect = 'PARALYZE_EFFECT' then 80 when _mv.effect = 'CONFUSION_EFFECT' then 60
               when _mv.effect = 'LEECH_SEED_EFFECT' then 55 when _mv.effect like '%\_UP2\_EFFECT' then 50 when _mv.effect = 'HEAL_EFFECT' then 45
               when _mv.effect in ('REFLECT_EFFECT', 'LIGHT_SCREEN_EFFECT') then 40 when _mv.effect like '%\_UP1\_EFFECT' then 35
               when _mv.effect = 'POISON_EFFECT' then 30 when _mv.effect like '%\_DOWN2\_EFFECT' then 28 when _mv.effect like '%\_DOWN1\_EFFECT' then 20 else 10 end)
       * coalesce(_mv.accuracy, 100) / 100.0
$$;

-- os 4 ataques de um Pokémon do jogo: do que ele aprende até o nível (Líderes: + TMs compatíveis), com cobertura:
-- o de dano mais forte; outro de dano de tipo diferente (de preferência um que acerte quem o 1º não acerta); mais um tipo novo se houver;
-- o status mais útil; e completa com os de dano mais fortes
create or replace function public.ia_moves(_sp int, _lv int, _tm boolean default false) returns int[]
language plpgsql stable security definer set search_path = public, extensions as $$
declare p pokemon; pool jsonb; extra jsonb := '[]'::jsonb; e jsonb; esc int[] := '{}'; tipos text[] := '{}'; imun text[]; achou boolean := false;
begin
  select * into p from pokemon where id = _sp;
  if p.id is null then return '{}'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', mv.id, 'type', mv.type, 'dano', public.ia_dano(mv),
           'v', case when public.ia_dano(mv) then public.ia_valor(mv, p.g1_type1, p.g1_type2) else public.ia_status_valor(mv) end)
           order by public.ia_dano(mv) desc, case when public.ia_dano(mv) then public.ia_valor(mv, p.g1_type1, p.g1_type2) else public.ia_status_valor(mv) end desc, mv.id), '[]'::jsonb)
    into pool
    from pk_moves mv
   where mv.id in (select unnest(p.start_moves)
                   union select move_id from pk_learnset where species_id = _sp and level <= _lv
                   union select move_id from pk_tm_compat where _tm and species_id = _sp and public.tm_nivel_move(move_id) <= _lv)   -- Líderes: TMs pela mesma regra de nível dos jogadores
     and not public.ia_inutil(mv);
  -- reserva só para a cobertura: TMs de dano acima do nível (quando o Pokémon não tem 2 tipos de dano sem elas, como o Electrode)
  if _tm then
    select coalesce(jsonb_agg(jsonb_build_object('id', mv.id, 'type', mv.type, 'dano', true, 'v', public.ia_valor(mv, p.g1_type1, p.g1_type2))
             order by public.ia_valor(mv, p.g1_type1, p.g1_type2), mv.id), '[]'::jsonb)   -- a mais fraca primeiro: o mínimo para cobrir
      into extra from pk_moves mv
     where mv.id in (select move_id from pk_tm_compat where species_id = _sp and public.tm_nivel_move(move_id) > _lv)
       and public.ia_dano(mv) and not public.ia_inutil(mv);
  end if;
  -- 1º: o de dano mais forte
  for e in select value from jsonb_array_elements(pool) loop
    if (e->>'dano')::boolean then esc := esc || (e->>'id')::int; tipos := tipos || (e->>'type'); exit; end if;
  end loop;
  -- 2º: outro tipo; de preferência um que acerte os tipos que o 1º não acerta (ex.: Normal não acerta Fantasma)
  if cardinality(esc) = 1 then
    select coalesce(array_agg(def), '{}') into imun from pk_type_chart where atk = tipos[1] and mult = 0;
    for e in select value from jsonb_array_elements(pool) loop
      continue when not (e->>'dano')::boolean or (e->>'type') = any(tipos);
      if not exists (select 1 from unnest(imun) d where public.bt_eff(e->>'type', d, null) = 0) then
        esc := esc || (e->>'id')::int; tipos := tipos || (e->>'type'); achou := true; exit;
      end if;
    end loop;
    if not achou then
      for e in select value from jsonb_array_elements(pool) loop
        continue when not (e->>'dano')::boolean or (e->>'type') = any(tipos);
        esc := esc || (e->>'id')::int; tipos := tipos || (e->>'type'); achou := true; exit;
      end loop;
    end if;
    if not achou then   -- sem 2º tipo no nível: usa a TM mais fraca que cubra
      for e in select value from jsonb_array_elements(extra) loop
        continue when (e->>'type') = any(tipos);
        esc := esc || (e->>'id')::int; tipos := tipos || (e->>'type'); exit;
      end loop;
    end if;
  end if;
  -- 3º: um tipo novo, se houver
  if cardinality(esc) = 2 then
    for e in select value from jsonb_array_elements(pool) loop
      continue when not (e->>'dano')::boolean or (e->>'type') = any(tipos);
      esc := esc || (e->>'id')::int; tipos := tipos || (e->>'type'); exit;
    end loop;
  end if;
  -- 1 de status (o mais útil)
  for e in select value from jsonb_array_elements(pool) order by (value->>'v')::numeric desc loop
    if not (e->>'dano')::boolean and not ((e->>'id')::int = any(esc)) then esc := esc || (e->>'id')::int; exit; end if;
  end loop;
  -- completa: os de dano mais fortes e depois os de status
  for e in select value from jsonb_array_elements(pool) loop
    exit when cardinality(esc) >= 4;
    continue when (e->>'id')::int = any(esc);
    esc := esc || (e->>'id')::int;
  end loop;
  return esc[1:4];
end $$;

-- Pokémon do jogo com os ataques escolhidos (os do time do Líder, se vierem; senão pela regra de cobertura)
create or replace function public.ia_mon(_sp int, _lv int, _moves int[] default null, _tm boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare m jsonb := public.npc_mon(_sp, _lv); ids int[];
begin
  if m is null then return null; end if;
  if _moves is null and not coalesce((public.ia_cfg()->>'on')::boolean, true) then return m; end if;
  ids := coalesce(_moves, public.ia_moves(_sp, _lv, _tm));
  if cardinality(ids) = 0 then return m; end if;
  return jsonb_set(m, '{moves}', (select jsonb_agg(jsonb_build_object('id', mv.id, 'pp', mv.pp, 'max', mv.pp) order by u.o)
                                     from unnest(ids) with ordinality u(mid, o) join pk_moves mv on mv.id = u.mid));
end $$;

-- um ataque de status ainda faz sentido agora?
create or replace function public.ia_status_util(_mv public.pk_moves, _A jsonb, _D jsonb, _usos int, _max int) returns boolean
language plpgsql stable security definer set search_path = public, extensions as $$
declare ef text := coalesce(_mv.effect, ''); st text;
begin
  if _usos >= _max then return false; end if;   -- não repete o mesmo status mais que o limite (ex.: Growl 2 vezes)
  if ef in ('SLEEP_EFFECT', 'PARALYZE_EFFECT', 'POISON_EFFECT') then
    if _D->>'status' is not null then return false; end if;   -- já dorme, já está paralisado ou envenenado
    if public.bt_eff(_mv.type, _D->>'t1', _D->>'t2') = 0 then return false; end if;
    if ef = 'POISON_EFFECT' and 'VENENO' in (_D->>'t1', coalesce(_D->>'t2', '')) then return false; end if;
    return true;
  end if;
  if ef = 'CONFUSION_EFFECT' then return coalesce((_D->>'conf')::int, 0) <= 0; end if;
  if ef = 'LEECH_SEED_EFFECT' then return not coalesce((_D->'fl'->>'leech')::boolean, false) and 'PLANTA' not in (_D->>'t1', coalesce(_D->>'t2', '')); end if;
  if ef = 'HEAL_EFFECT' then return (_A->>'hp')::int * 2 <= (_A->>'maxhp')::int; end if;
  if ef = 'REFLECT_EFFECT' then return not coalesce((_A->'fl'->>'reflect')::boolean, false); end if;
  if ef = 'LIGHT_SCREEN_EFFECT' then return not coalesce((_A->'fl'->>'light')::boolean, false); end if;
  if ef = 'FOCUS_ENERGY_EFFECT' then return not coalesce((_A->'fl'->>'focus')::boolean, false); end if;
  if ef = 'MIST_EFFECT' then return not coalesce((_A->'fl'->>'mist')::boolean, false); end if;
  if ef = 'HAZE_EFFECT' then
    return exists (select 1 from jsonb_each_text(coalesce(_D->'st', '{}'::jsonb)) x where x.value::int > 0)
        or exists (select 1 from jsonb_each_text(coalesce(_A->'st', '{}'::jsonb)) x where x.value::int < 0);
  end if;
  st := case split_part(ef, '_', 1) when 'ATTACK' then 'atk' when 'DEFENSE' then 'def' when 'SPEED' then 'spd' when 'SPECIAL' then 'spc'
          when 'ACCURACY' then 'acc' when 'EVASION' then 'eva' end;
  if st is not null and ef like '%\_DOWN_\_EFFECT' then
    return not coalesce((_D->'fl'->>'mist')::boolean, false) and coalesce((_D->'st'->>st)::int, 0) > -6;
  end if;
  if st is not null and ef like '%\_UP_\_EFFECT' then return coalesce((_A->'st'->>st)::int, 0) < 6; end if;
  return true;
end $$;

-- a escolha do ataque. _perfil: 'lider' (o mais forte em lider_melhor_pct% das vezes) ou 'selvagem' (sorteio dentro das regras).
-- Devolve {kind, value} e, para lembrar, st (foi status), mid (ataque) e ai (quem usou).
create or replace function public.ia_pick(_s jsonb, _a int, _perfil text, _turno int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.ia_cfg(); ai int := (_s->'sides'->_a->>'active')::int;
  A jsonb := _s->'sides'->_a->'mons'->((_s->'sides'->_a->>'active')::int);
  D jsonb := _s->'sides'->(1 - _a)->'mons'->((_s->'sides'->(1 - _a)->>'active')::int);
  mem jsonb := coalesce(_s->'ia'->(_a::text), '{}'::jsonb); i int; mv pk_moves; eff numeric; sc numeric; ratio numeric;
  dano jsonb := '[]'::jsonb; sts jsonb := '[]'::jsonb; todos jsonb := '[]'::jsonb; alt jsonb := '[]'::jsonb; pool jsonb; esc jsonb; usos int;
begin
  if coalesce(A->'fl'->>'charging', '') <> '' or coalesce((A->'fl'->>'recharge')::boolean, false) then return '{"kind": "forced", "value": 0}'; end if;
  if not coalesce((c->>'on')::boolean, true) then return public.war_pick(_s, _a, 'forte'); end if;
  for i in 0 .. jsonb_array_length(A->'moves') - 1 loop
    continue when (A->'moves'->i->>'pp')::int <= 0;
    todos := todos || to_jsonb(i);
    select * into mv from pk_moves where id = (A->'moves'->i->>'id')::int;
    continue when mv.id is null or public.ia_inutil(mv);
    if public.ia_dano(mv) then
      eff := public.bt_eff(mv.type, D->>'t1', D->>'t2');
      continue when eff = 0 and mv.effect not in ('SPECIAL_DAMAGE_EFFECT', 'SUPER_FANG_EFFECT');   -- nunca usa ataque que não afeta o alvo
      continue when mv.effect = 'OHKO_EFFECT' and (A->>'spd')::int < (D->>'spd')::int;            -- na Red/Blue falha em quem é mais rápido
      continue when mv.effect = 'DREAM_EATER_EFFECT' and coalesce(D->>'status', '') <> 'SLP';
      if mv.effect in ('SPECIAL_DAMAGE_EFFECT', 'SUPER_FANG_EFFECT') then sc := 40; eff := 1;
      elsif mv.effect = 'OHKO_EFFECT' then sc := 30 * coalesce(mv.accuracy, 100) / 100.0;
      else
        ratio := case when public.bt_physical(mv.type) then greatest(1, (A->>'atk')::numeric) / greatest(1, (D->>'def')::numeric)
                      else greatest(1, (A->>'spc')::numeric) / greatest(1, (D->>'spc')::numeric) end;
        sc := mv.power * eff * case when mv.type in (A->>'t1', coalesce(A->>'t2', '')) then 1.5 else 1 end * ratio * coalesce(mv.accuracy, 100) / 100.0;
        if mv.effect in ('CHARGE_EFFECT', 'FLY_EFFECT', 'HYPER_BEAM_EFFECT') then sc := sc * 0.6; end if;
        if mv.effect = 'EXPLODE_EFFECT' then sc := sc * 0.3; end if;
      end if;
      dano := dano || jsonb_build_object('i', i, 'sc', sc, 'eff', eff, 'mid', mv.id);
    else
      usos := coalesce((mem->'usos'->>(ai::text || ':' || mv.id::text))::int, 0);
      if public.ia_status_util(mv, A, D, 0, 999) then alt := alt || to_jsonb(i); end if;   -- reserva: status que ainda faz algum efeito
      continue when not public.ia_status_util(mv, A, D, usos, coalesce((c->>'status_max')::int, 2));
      sts := sts || jsonb_build_object('i', i, 'mid', mv.id);
    end if;
  end loop;
  -- no máximo 1 ataque de status a cada N turnos, a não ser que nenhum ataque de dano acerte o alvo
  if jsonb_array_length(dano) > 0 and _turno - coalesce((mem->>'st')::int, -999) < coalesce((c->>'status_cada')::int, 3) then sts := '[]'::jsonb; end if;
  -- quando há ataque super efetivo, a preferência é dele (o sorteio fica só entre os super efetivos)
  if exists (select 1 from jsonb_array_elements(dano) x where (x->>'eff')::numeric > 1) then
    select jsonb_agg(x) into dano from jsonb_array_elements(dano) x where (x->>'eff')::numeric > 1;
    sts := '[]'::jsonb;
  end if;
  if _perfil = 'lider' and jsonb_array_length(dano) > 0 and random() * 100 < coalesce((c->>'lider_melhor_pct')::numeric, 70) then
    select x into esc from jsonb_array_elements(dano) x order by (x->>'sc')::numeric desc limit 1;
  else
    pool := dano || sts;
    if jsonb_array_length(pool) > 0 then esc := pool->(floor(random() * jsonb_array_length(pool))::int); end if;
  end if;
  if esc is null then
    if jsonb_array_length(todos) = 0 then return '{"kind": "move", "value": -1}'; end if;   -- sem PP: Struggle
    if jsonb_array_length(alt) > 0 then todos := alt; end if;   -- nada acerta: um status que ainda faz efeito (mesmo repetido) antes de um ataque que não afeta
    return jsonb_build_object('kind', 'move', 'value', (todos->(floor(random() * jsonb_array_length(todos))::int))::int, 'st', false);
  end if;
  return jsonb_build_object('kind', 'move', 'value', (esc->>'i')::int, 'st', not (esc ? 'sc'), 'mid', (esc->>'mid')::int, 'ai', ai);
end $$;

-- lembra quando o lado usou status e quantas vezes cada Pokémon usou cada um (fica no estado da batalha)
create or replace function public.ia_memo(_s jsonb, _a int, _p jsonb, _turno int) returns jsonb
language sql immutable as $$
  select case when coalesce((_p->>'st')::boolean, false) then
    _s || jsonb_build_object('ia', coalesce(_s->'ia', '{}'::jsonb) || jsonb_build_object(_a::text,
      coalesce(_s->'ia'->(_a::text), '{}'::jsonb) || jsonb_build_object('st', _turno,
        'usos', coalesce(_s->'ia'->(_a::text)->'usos', '{}'::jsonb) || jsonb_build_object((_p->>'ai') || ':' || (_p->>'mid'),
          coalesce((_s->'ia'->(_a::text)->'usos'->>((_p->>'ai') || ':' || (_p->>'mid')))::int, 0) + 1))))
  else _s end
$$;

-- os times dos Líderes passam a guardar os 4 ataques de cada Pokémon (regra de cobertura, com TMs); o admin pode trocar
update public.rpg_lideres l set time = (
  select jsonb_agg(case when jsonb_array_length(e) >= 3 then e
                        else jsonb_build_array((e->>0)::int, (e->>1)::int, to_jsonb(public.ia_moves((e->>0)::int, (e->>1)::int, true))) end order by o)
    from jsonb_array_elements(l.time) with ordinality x(e, o))
 where exists (select 1 from jsonb_array_elements(l.time) e where jsonb_array_length(e) < 3);

-- ---------- (1) Ginásio em uma batalha só ----------
-- os Pokémon escalados numa batalha de Ginásio em andamento ficam travados
create or replace function public.gin_preso(_uid uuid, _mon uuid) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from battles b, jsonb_array_elements(b.state->'sides'->0->'mons') mm
                  where b.mode = 'treino' and b.p1 = _uid and b.status = 'ativa' and b.state->'treino' ? 'multi' and mm->>'id' = _mon::text)
$$;

-- a batalha de Ginásio que passou do prazo vira derrota
create or replace function public.rpg_gin_expira(_uid uuid) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare b battles; n int := 0; mins int := coalesce((public.rpg_cfg()->'ginasios'->>'expira_min')::int, 30);
begin
  if _uid is null or mins <= 0 then return 0; end if;
  for b in select * from battles where mode = 'treino' and p1 = _uid and status = 'ativa' and state->'treino' ? 'multi'
              and started_at < now() - make_interval(mins => mins) loop
    update battles set log = log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt',
      '⌛ O tempo da batalha (' || mins || ' minutos) acabou. A tentativa no Ginásio terminou em derrota.')))) where id = b.id;
    perform public.bt_finish(b.id, null, 'tempo');
    perform public.treino_after(b.id);
    perform public.rpg_after(b.id);
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.gin_trava(_uid uuid, _ids uuid[]) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.rpg_gin_expira(_uid);
  if exists (select 1 from unnest(coalesce(_ids, '{}'::uuid[])) x where public.gin_preso(_uid, x)) then
    raise exception 'Esse Pokémon está numa batalha de Ginásio em andamento. Termine a batalha (ou desista) antes.';
  end if;
end $$;

-- quem do seu lado lutou contra cada Pokémon do Líder (para dividir a XP, como na Red/Blue)
create or replace function public.rpg_gin_par(_bid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b battles; a0 int; a1 int; lst jsonb;
begin
  select * into b from battles where id = _bid for update;
  if b.id is null or b.status <> 'ativa' or not (b.state->'treino' ? 'multi') then return; end if;
  a0 := (b.state->'sides'->0->>'active')::int; a1 := (b.state->'sides'->1->>'active')::int;
  if (b.state->'sides'->0->'mons'->a0->>'hp')::int <= 0 or (b.state->'sides'->1->'mons'->a1->>'hp')::int <= 0 then return; end if;
  lst := coalesce(b.state->'treino'->'part'->(a1::text), '[]'::jsonb);
  if not (lst @> jsonb_build_array(a0)) then
    update battles set state = jsonb_set(state, '{treino,part}', coalesce(state->'treino'->'part', '{}'::jsonb) || jsonb_build_object(a1::text, lst || jsonb_build_array(a0)))
     where id = _bid;
  end if;
end $$;

-- XP de cada Pokémon do Líder que acabou de cair: a mesma conta das lutas da Aventura (com Domador, Academia e Calça),
-- dividida entre os seus que lutaram contra ele e ainda estão de pé
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
    ganho := ceil(ganho * (100 + public.eq_bonus(b.p1, 'calca')) / 100)::int;
    tot := tot + ganho;
    parte := greatest(1, ceil(ganho::numeric / cardinality(vivos)))::int;
    foreach j in array vivos loop gxp := gxp || jsonb_build_object(j::text, coalesce((gxp->>(j::text))::int, 0) + parte); end loop;
  end loop;
  update battles set state = jsonb_set(state, '{treino}', t || jsonb_build_object('gxp', gxp, 'xpd', xpd, 'gtot', tot)) where id = _bid;
end $$;

-- o Líder manda o próximo: ele sai do esconderijo e entra na batalha
create or replace function public.rpg_gin_revela(_bid uuid, _idx int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare m jsonb;
begin
  select mon into m from rpg_gin_ocultos where battle_id = _bid and idx = _idx;
  if m is null then return; end if;
  update battles set state = jsonb_set(state, array['sides', '1', 'mons', _idx::text], m) where id = _bid;
  delete from rpg_gin_ocultos where battle_id = _bid and idx = _idx;
end $$;

-- depois de cada turno: conta a XP, anota quem lutou e, se o Pokémon do Líder caiu, ele manda o próximo da ordem
create or replace function public.rpg_gin_depois(_bid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b battles; k int; vez int;
begin
  for vez in 1 .. 4 loop
    perform public.rpg_gin_xp(_bid);
    perform public.rpg_gin_par(_bid);
    select * into b from battles where id = _bid;
    exit when b.status <> 'ativa' or b.phase <> 'troca' or not coalesce((b.state->'sides'->1->>'need_switch')::boolean, false)
              or coalesce((b.state->'sides'->0->>'need_switch')::boolean, false);
    k := public.war_switch(b.state, 1, false);
    perform public.rpg_gin_revela(b.id, k);
    insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, b.p1, 'switch', k);
    perform public.bt_resolve(b.id);
  end loop;
end $$;

-- fim da batalha: a vida de cada um fica como terminou; XP de quem lutou; o suporte ganha a parte dele
create or replace function public.rpg_gin_fim(_bid uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.treino_cfg(); b battles; t jsonb; won boolean; i int; mm jsonb; m monsters; hp_fim int; xp int; lv2 int;
  lst jsonb := '[]'::jsonb; tot int := 0; cx int := 0; csp int; res jsonb;
begin
  select * into b from battles where id = _bid for update;
  if b.id is null or b.status = 'ativa' then return null; end if;
  t := b.state->'treino';
  if coalesce((t->>'feito')::boolean, false) then return t->'res'; end if;
  perform public.rpg_gin_xp(_bid);
  select * into b from battles where id = _bid;
  t := b.state->'treino';
  won := coalesce(b.end_reason, '') not in ('desistencia', 'tempo')
         and not exists (select 1 from jsonb_array_elements(b.state->'sides'->1->'mons') x where (x->>'hp')::int > 0);
  for i in 0 .. jsonb_array_length(b.state->'sides'->0->'mons') - 1 loop
    mm := b.state->'sides'->0->'mons'->i;
    select * into m from monsters where id = (mm->>'id')::uuid and user_id = b.p1;
    continue when m.id is null;
    hp_fim := greatest(0, least(100, floor((mm->>'hp')::numeric * 100 / greatest(1, (mm->>'maxhp')::int))))::int;
    if (mm->>'hp')::int > 0 then hp_fim := greatest(1, hp_fim); end if;
    update monsters set tr_hp = hp_fim, tr_hurt_at = case when hp_fim < m.tr_hp then now() else tr_hurt_at end where id = m.id;
    xp := coalesce((t->'gxp'->>(i::text))::int, 0);
    if xp > 0 then perform public.pk_give_xp(m.id, xp, 'treino'); end if;
    select level into lv2 from monsters where id = m.id;
    tot := tot + xp;
    lst := lst || jsonb_build_object('species', m.species_id, 'xp', xp, 'hp', hp_fim, 'desmaiou', hp_fim = 0, 'level_from', m.level, 'level_to', coalesce(lv2, m.level));
  end loop;
  if (t->>'comp') is not null and coalesce((t->>'gtot')::int, 0) > 0 then
    select species_id into csp from monsters where id = (t->>'comp')::uuid and user_id = b.p1;
    if csp is not null then
      cx := greatest(1, floor((t->>'gtot')::int * case when public.heroi(b.p1) = 'pesquisador' then (public.herois_cfg()->>'pesq_comp_pct')::numeric
                                                          else coalesce((c->>'acompanhante_pct')::numeric, 50) end / 100))::int;
      perform public.pk_give_xp((t->>'comp')::uuid, cx, 'treino');
    end if;
  end if;
  insert into treino_dias(user_id, dia) values (b.p1, public.game_today()) on conflict do nothing;
  update treino_dias set lutas = lutas + 1, vitorias = vitorias + won::int, xp = treino_dias.xp + tot where user_id = b.p1 and dia = public.game_today();
  res := jsonb_build_object('won', won, 'multi', true, 'xp', tot, 'mons', lst, 'comp_xp', cx, 'comp_species', csp,
    'fugiu', b.end_reason = 'desistencia', 'tempo', b.end_reason = 'tempo', 'species', (lst->0->>'species')::int,
    'derrotados', (select count(*) from jsonb_array_elements(b.state->'sides'->1->'mons') x where (x->>'hp')::int <= 0),
    'total', jsonb_array_length(b.state->'sides'->1->'mons'));
  update battles set state = jsonb_set(state, '{treino}', t || jsonb_build_object('feito', true, 'res', res)) where id = b.id;
  return res;
end $$;

-- vitória no Ginásio: insígnia, prêmio, achado e Acontecimentos (o mesmo de antes)
create or replace function public.rpg_gin_vitoria(_uid uuid, _regiao text, _lider text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rpg_cfg(); nome text; n int; drop_ jsonb;
begin
  insert into rpg_insignias(user_id, regiao) values (_uid, _regiao) on conflict do nothing;
  perform public.rpg_premiar(_uid, (c->'ginasios'->>'moedas')::int, c->'ginasios'->'itens');
  drop_ := public.equip_drop(_uid, 'ginasio');
  select name into nome from characters where user_id = _uid;
  insert into event_log(user_id, kind, message) values (_uid, 'ginasio', '🏅 ' || nome || ' venceu ' || _lider || ' e ganhou a insígnia do Ginásio!');
  select count(*) into n from rpg_insignias where user_id = _uid;
  if n >= (select count(*) from rpg_lideres) then
    perform public.rpg_premiar(_uid, (c->'ginasios'->>'todas_moedas')::int, c->'ginasios'->'todas_itens');
    insert into event_log(user_id, kind, message) values (_uid, 'ginasio', '👑 ' || nome || ' juntou TODAS as insígnias da Aventura!');
  end if;
  return drop_;
end $$;

-- começar (ou voltar para) a batalha do Ginásio
create or replace function public.rpg_ginasio_lutar(_regiao text, _comp uuid default null, _meus uuid[] default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.rpg_cfg()->'ginasios'; l rpg_lideres; me characters; t rpg_gin_tent; bid uuid; n int; nl int;
  e jsonb; k int; pos int := 0; w jsonb; ocultos jsonb := '[]'::jsonb; mine jsonb := '[]'::jsonb; wild jsonb := '[]'::jsonb; x uuid; hp int; s0 jsonb; s1 jsonb;
begin
  if not coalesce((c->>'on')::boolean, true) and not public.is_admin() then raise exception 'Os Ginásios estão fechados no momento.'; end if;
  select * into l from rpg_lideres where regiao = _regiao;
  if l.regiao is null then raise exception 'Não há Ginásio aqui.'; end if;
  nl := jsonb_array_length(l.time);
  if exists (select 1 from rpg_insignias where user_id = uid and regiao = _regiao) then raise exception 'Você já tem a insígnia deste Ginásio.'; end if;
  select * into me from characters where user_id = uid for update;
  perform public.treino_autocura(uid);   -- também encerra a batalha de Ginásio que passou do prazo
  bid := public.treino_batalha(uid);
  if bid is not null then return jsonb_build_object('battle', bid); end if;   -- volta para a batalha em andamento
  update rpg_gin_tent set status = 'perdeu' where user_id = uid and status = 'andando' and dia < public.game_today();
  if _meus is null or cardinality(_meus) <> nl or (select count(distinct y) from unnest(_meus) y) <> nl then
    raise exception 'Escolha % Pokémon diferentes para enfrentar o Líder.', nl;
  end if;
  if (select count(*) from monsters where user_id = uid and id = any(_meus) and tr_hp > 0) <> nl then
    raise exception 'Escolha só Pokémon seus que estejam com vida.';
  end if;
  -- tentativa do dia (uma tentativa antiga, da regra de antes, sem batalha, é aproveitada e não gasta outra)
  select * into t from rpg_gin_tent where user_id = uid and regiao = _regiao and dia = public.game_today() and status = 'andando' order by id desc limit 1;
  if t.id is null then
    select count(*) into n from rpg_gin_tent where user_id = uid and regiao = _regiao and dia = public.game_today();
    if n >= (c->>'tentativas_dia')::int then raise exception 'Você já usou as % tentativas de hoje neste Ginásio. Volte amanhã!', (c->>'tentativas_dia'); end if;
    insert into rpg_gin_tent(user_id, regiao, dia, hp, meus, ordem)
    values (uid, _regiao, public.game_today(), (select jsonb_agg(100) from generate_series(1, nl)), to_jsonb(_meus),
            (select jsonb_agg(i order by random()) from generate_series(0, nl - 1) i))   -- ordem do Líder sorteada
    returning * into t;
  else
    update rpg_gin_tent set meus = to_jsonb(_meus), idx = 0, hp = (select jsonb_agg(100) from generate_series(1, nl)),
           ordem = (select jsonb_agg(i order by random()) from generate_series(0, nl - 1) i) where id = t.id returning * into t;
  end if;
  if _comp is not null and (_comp = any(_meus) or not exists (select 1 from monsters where id = _comp and user_id = uid)
     or coalesce((select tr_hp from monsters where id = _comp), 100) <= 0) then _comp := null; end if;
  delete from battles where mode = 'treino' and p1 = uid and status <> 'ativa';
  -- os seus, na ordem escolhida (o Peitoral dá resistência, como nas outras lutas da Aventura)
  foreach x in array _meus loop
    select tr_hp into hp from monsters where id = x;
    mine := mine || public.rpg_mine(x, uid, hp);
  end loop;
  -- os do Líder, na ordem sorteada, com os ataques guardados no time
  for k in select v::int from jsonb_array_elements_text(t.ordem) with ordinality o(v, ord) order by ord loop
    e := l.time->k;
    w := public.ia_mon((e->>0)::int, (e->>1)::int,
      case when jsonb_typeof(e->2) = 'array' and jsonb_array_length(e->2) > 0 then (select array_agg(v::int order by ord) from jsonb_array_elements_text(e->2) with ordinality z(v, ord)) end, true);
    if pos = 0 then wild := wild || jsonb_build_array(w);
    else   -- ainda não entrou: na batalha fica só um lugar guardado, sem nome nem espécie
      ocultos := ocultos || jsonb_build_array(jsonb_build_object('idx', pos, 'mon', w));
      wild := wild || jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'name', 'Pokémon do Líder', 'known', false, 'oculto', true, 'level', 0,
        'hp', 1, 'maxhp', 1, 'atk', 1, 'def', 1, 'spd', 1, 'spc', 1, 'bspd', 1, 'bexp', 0, 'moves', '[]'::jsonb, 'status', null, 'sleep', 0, 'conf', 0,
        'st', '{"atk":0,"def":0,"spd":0,"spc":0,"acc":0,"eva":0}'::jsonb, 'fl', '{}'::jsonb, 'outfit', '{}'::jsonb));
    end if;
    pos := pos + 1;
  end loop;
  s0 := jsonb_build_object('user', uid, 'name', me.name, 'active', 0, 'need_switch', false, 'mons', mine);
  s1 := jsonb_build_object('user', uid, 'name', l.nome, 'npc', true, 'active', 0, 'need_switch', false, 'mons', wild);
  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (uid, uid, 'treino', nl, 'ativa', 1, 'normal', now(),
          jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb, 'treino', jsonb_build_object('mon', _meus[1], 'forte', false, 'comp', _comp,
            'gym', _regiao, 'gym_try', t.id, 'multi', true, 'part', jsonb_build_object('0', jsonb_build_array(0)))),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', l.nome || ' aceitou o desafio! São ' || nl || ' contra ' || nl || '.'),
            jsonb_build_object('txt', l.nome || ' manda ' || (wild->0->>'name') || ' (nível ' || (wild->0->>'level') || ')!'),
            jsonb_build_object('txt', 'Vai, ' || (mine->0->>'name') || '!' || case when (mine->0->>'hp')::int < (mine->0->>'maxhp')::int then ' (ferido)' else '' end)))))
  returning id into bid;
  update rpg_gin_tent set batalha = bid where id = t.id;
  insert into rpg_gin_ocultos(battle_id, idx, mon) select bid, (o->>'idx')::int, o->'mon' from jsonb_array_elements(ocultos) o;
  return jsonb_build_object('battle', bid);
end $$;

-- o que o site mostra do Ginásio (agora com a batalha em andamento e o prazo)
create or replace function public.rpg_ginasio(_regiao text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.rpg_cfg()->'ginasios'; l rpg_lideres; n int; bat battles;
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  select * into l from rpg_lideres where regiao = _regiao;
  if l.regiao is null then raise exception 'Não há Ginásio aqui.'; end if;
  perform public.treino_autocura(uid);
  update rpg_gin_tent set status = 'perdeu' where user_id = uid and status = 'andando' and dia < public.game_today();
  select * into bat from battles where mode = 'treino' and p1 = uid and status = 'ativa' and state->'treino' ? 'multi' order by created_at desc limit 1;
  select count(*) into n from rpg_gin_tent where user_id = uid and regiao = _regiao and dia = public.game_today()
     and not (status = 'andando' and batalha is null);   -- a tentativa antiga sem batalha não conta
  return jsonb_build_object('lider', jsonb_build_object('nome', l.nome, 'classe', l.classe, 'tipo', l.tipo, 'n', jsonb_array_length(l.time)),
    'insignia', exists (select 1 from rpg_insignias where user_id = uid and regiao = _regiao),
    'tentativas', n, 'tentativas_dia', (c->>'tentativas_dia')::int, 'moedas', (c->>'moedas')::int, 'itens', c->'itens',
    'itens_batalha', coalesce((public.items_cfg()->>'per_battle')::int, 2), 'expira_min', coalesce((c->>'expira_min')::int, 30),
    'batalha', case when bat.id is null then null else jsonb_build_object('id', bat.id, 'regiao', bat.state->'treino'->>'gym',
      'fim', bat.started_at + make_interval(mins => coalesce((c->>'expira_min')::int, 30))) end,
    'tentativa', null);
end $$;

-- o admin edita o Líder; os ataques de cada Pokémon são opcionais (sem eles, entra a regra de cobertura)
create or replace function public.admin_rpg_lider_salvar(_regiao text, _nome text, _classe text, _tipo text, _time jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare antes jsonb; e jsonb; novo jsonb := '[]'::jsonb; mv jsonb;
begin
  perform public.assert_admin();
  if not exists (select 1 from rpg_lideres where regiao = _regiao) then raise exception 'Região sem Ginásio.'; end if;
  if length(btrim(coalesce(_nome, ''))) < 2 then raise exception 'Dê um nome ao Líder.'; end if;
  if jsonb_typeof(_time) <> 'array' or jsonb_array_length(_time) not between 1 and 6 then raise exception 'O time precisa ter de 1 a 6 Pokémon.'; end if;
  for e in select * from jsonb_array_elements(_time) loop
    if jsonb_typeof(e) <> 'array' or not exists (select 1 from pokemon where id = (e->>0)::int) or (e->>1)::int not between 1 and 100 then
      raise exception 'Pokémon ou nível inválido: %', e; end if;
    mv := case when jsonb_typeof(e->2) = 'array' and jsonb_array_length(e->2) > 0 then e->2 end;
    if mv is not null and (jsonb_array_length(mv) > 4 or exists (select 1 from jsonb_array_elements_text(mv) z where not exists (select 1 from pk_moves where id = z::int))) then
      raise exception 'Ataques inválidos em %: até 4 números de ataque.', e; end if;
    novo := novo || jsonb_build_array(jsonb_build_array((e->>0)::int, (e->>1)::int, coalesce(mv, to_jsonb(public.ia_moves((e->>0)::int, (e->>1)::int, true)))));
  end loop;
  select to_jsonb(x) into antes from rpg_lideres x where regiao = _regiao;
  update rpg_lideres set nome = btrim(_nome), classe = coalesce(nullif(_classe, ''), classe), tipo = coalesce(_tipo, ''), time = novo where regiao = _regiao;
  insert into admin_audit_log(admin_id, action, target, after) values (auth.uid(), 'rpg_lider', _regiao, jsonb_build_object('antes', antes, 'nome', _nome, 'time', novo));
  return public.admin_rpg_lideres();
end $$;


-- rpg_cfg: versão do 107 com a mudança do arquivo 113
create or replace function public.rpg_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select ('{"on": true, "batalhas_dia": 20, "chance_pct": 12, "espera_seg": 8, "envio_seg": 1.2, "fuga_base": 10, "fuga_por_ataque": 10, "nivel_pedra": 28, "nivel_troca": 36, "folga": 10, "lendarios": [144, 145, 146, 150, 151, 243, 244, 245, 249, 250, 251], "zonas": {"mato": {"nome": "Capim alto", "regiao": "vila", "tipos": ["INSETO", "PLANTA", "NORMAL"], "min": 2, "max": 6}, "escura": {"nome": "Grama escura", "regiao": "vila", "tipos": ["NORMAL", "VOADOR", "ELETRICO"], "min": 3, "max": 7}, "pantano": {"nome": "Pântano", "regiao": "vila", "tipos": ["AGUA", "VENENO"], "min": 3, "max": 7}, "pedra": {"nome": "Alto do penhasco", "regiao": "vila", "tipos": ["PEDRA", "TERRA", "LUTA"], "min": 4, "max": 8}, "bosque": {"nome": "Bosque: mato", "regiao": "bosque", "tipos": ["INSETO", "PLANTA", "VENENO", "NORMAL"], "min": 8, "max": 16}, "bosque_fundo": {"nome": "Bosque: mata funda", "regiao": "bosque", "tipos": ["INSETO", "PLANTA", "VENENO", "NORMAL", "VOADOR"], "min": 18, "max": 34}, "praia": {"nome": "Praia: dunas", "regiao": "praia", "tipos": ["AGUA", "ELETRICO", "NORMAL"], "min": 8, "max": 16}, "praia_fundo": {"nome": "Praia: costão", "regiao": "praia", "tipos": ["AGUA", "ELETRICO", "GELO", "VOADOR"], "min": 18, "max": 38}, "deserto": {"nome": "Deserto: capim seco", "regiao": "deserto", "tipos": ["FOGO", "TERRA", "NORMAL"], "min": 12, "max": 22}, "deserto_fundo": {"nome": "Deserto: oásis distante", "regiao": "deserto", "tipos": ["FOGO", "TERRA", "PEDRA", "LUTA"], "min": 24, "max": 42}, "pedreira": {"nome": "Pedreira: entrada", "regiao": "pedreira", "tipos": ["PEDRA", "TERRA", "LUTA", "METALICO"], "min": 12, "max": 22}, "pedreira_fundo": {"nome": "Pedreira: fundo da gruta", "regiao": "pedreira", "tipos": ["PEDRA", "TERRA", "LUTA", "METALICO", "DRAGAO"], "min": 24, "max": 44}, "charco": {"nome": "Charco: margem", "regiao": "charco", "tipos": ["VENENO", "FANTASMA", "PSIQUICO", "SOMBRIO"], "min": 20, "max": 32}, "charco_fundo": {"nome": "Charco: brejo escuro", "regiao": "charco", "tipos": ["FANTASMA", "PSIQUICO", "SOMBRIO", "VENENO", "NORMAL"], "min": 32, "max": 46}, "pico": {"nome": "Pico: encosta", "regiao": "pico", "tipos": ["GELO", "AGUA", "PSIQUICO", "VOADOR", "ELETRICO"], "min": 34, "max": 48}, "pico_fundo": {"nome": "Pico: cume", "regiao": "pico", "tipos": ["DRAGAO", "GELO", "VOADOR", "PSIQUICO", "FOGO", "LUTA", "NORMAL", "PEDRA"], "min": 45, "max": 60}, "vulcao": {"nome": "Vulcão: encosta", "regiao": "vulcao", "tipos": ["FOGO", "PEDRA", "TERRA", "LUTA"], "min": 40, "max": 50}, "vulcao_fundo": {"nome": "Vulcão: cratera", "regiao": "vulcao", "tipos": ["FOGO", "DRAGAO", "PEDRA", "TERRA", "VOADOR"], "min": 48, "max": 60}, "estrada": {"nome": "Estrada da Vitória: trilha", "regiao": "estrada", "tipos": ["LUTA", "PEDRA", "TERRA", "VENENO", "VOADOR", "NORMAL"], "min": 52, "max": 62}, "estrada_fundo": {"nome": "Estrada da Vitória: desfiladeiro", "regiao": "estrada", "tipos": ["DRAGAO", "PSIQUICO", "LUTA", "GELO", "FANTASMA", "AGUA"], "min": 58, "max": 70}}}'::jsonb || '{"pvp": {"on": true, "distancia": 2, "desafia_dia": 1, "recebe_dia": 3, "teto": true, "prazo_horas": 24, "oferta_min": 1}}'::jsonb || '{"noite": {"on": true, "inicio": 19, "fim": 5, "tipos": ["FANTASMA", "SOMBRIO"]}, "missoes": {"on": true, "por_dia": 3, "moedas_min": 15, "moedas_max": 40, "itens": ["pocao", "super_pocao", "hiper_pocao", "reviver", "antidoto", "despertar", "cura_paralisia", "x_ataque", "x_defesa", "x_velocidade", "x_especial"]}, "ginasios": {"on": true, "tentativas_dia": 3, "expira_min": 30, "moedas": 300, "itens": {"max_pocao": 2, "reviver": 2}, "todas_moedas": 1000, "todas_itens": {"restaurar_tudo": 5}, "lideres": {"bosque": {"nome": "Líder Flora", "classe": "domador", "tipo": "Inseto e Planta", "time": [[12, 30], [47, 31], [71, 33], [3, 35]]}, "praia": {"nome": "Líder Marina", "classe": "arqueiro", "tipo": "Água e Elétrico", "time": [[55, 34], [101, 35], [131, 36], [121, 38]]}, "deserto": {"nome": "Líder Brasa", "classe": "guerreiro", "tipo": "Fogo e Terra", "time": [[51, 38], [59, 40], [112, 41], [6, 42]]}, "pedreira": {"nome": "Líder Rocha", "classe": "mercador", "tipo": "Pedra", "time": [[76, 40], [139, 42], [141, 43], [142, 44]]}, "charco": {"nome": "Líder Sombra", "classe": "mago", "tipo": "Fantasma e Psíquico", "time": [[93, 44], [97, 45], [65, 46], [94, 47]]}, "pico": {"nome": "Líder Neve", "classe": "clerigo", "tipo": "Gelo e Dragão", "time": [[87, 56], [91, 57], [131, 58], [149, 60]]}}}, "chefe": {"on": true, "dia_semana": 6, "hora": 10, "horas": 48, "nivel": 75, "vidas": 40, "turnos": 12, "tentativas_dia": 3, "especies": [149, 130, 143, 112, 94, 68, 131, 59, 6, 65], "moedas": 250, "itens": {"restaurar_tudo": 1, "reviver": 1}, "top_moedas": [300, 200, 100]}}'::jsonb
    || '{"elite": {"on": true, "insignias_min": 8, "tentativas_dia": 1, "time_max": 6, "moedas": 5000, "itens": {"restaurar_tudo": 5, "reviver": 5}, "doces": 5, "repetir_moedas": 1000, "repetir_doces": 1}}'::jsonb
    || coalesce(public.cfg()->'rpg', '{}'::jsonb)) #- '{ginasios,lideres}'   -- arquivo 101: os times dos Líderes ficam na tabela rpg_lideres
$$;

update public.game_config set config = jsonb_set(config, '{rpg,ginasios,expira_min}', '30')
 where active and jsonb_typeof(config->'rpg'->'ginasios') = 'object' and not (config->'rpg'->'ginasios' ? 'expira_min');


-- admin_cfg_efetiva: versão do 112 com a mudança do arquivo 113
create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'leilao', public.leilao_cfg(), 'herois', public.herois_cfg(), 'temporada', public.temporada_cfg(), 'liga', public.liga_cfg(), 'pausa', public.pausa_cfg(), 'teto', public.teto_cfg(), 'boas_vindas', public.boas_vindas_cfg(), 'vila_bonus', public.vila_bonus_cfg(), 'tm_nivel', public.tm_nivel_cfg(), 'quiz_auto', public.quiz_auto_cfg(), 'cartas', public.tcg_cfg(), 'pokebound', public.pokebound_cfg(), 'visual', public.visual_cfg(), 'praca', public.praca_cfg(), 'rpg', public.rpg_cfg(), 'equip', public.equip_cfg(), 'base', public.cfg(), 'exp', public.exp_cfg(), 'vale', public.vale_cfg(), 'fazenda', public.fazenda_cfg(), 'ia', public.ia_cfg());   -- arquivo 113: escolha de ataques   -- arquivo 112: Vale do Treino e Fazenda   -- arquivo 111: Expedições
end $$;


-- treino_autocura: versão do 109 com a mudança do arquivo 113
create or replace function public.treino_autocura(_uid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare hh numeric := public.cura_horas(_uid);           -- horas de 0% a 100% (ferido)
  esp numeric := public.tr_espera_desmaio();               -- desmaiado: horas parado
  rf numeric := public.tr_ritmo_desmaio(_uid);              -- desmaiado: horas de 0% a 100% depois da espera
begin
  perform public.rpg_gin_expira(_uid);   -- arquivo 113: batalha de Ginásio que passou do prazo vira derrota
  if public.tr_gradual() then
    update monsters m
       set tr_hp = least(100, m.tr_hp + x.g),
           tr_ritmo = case when m.tr_hp + x.g >= 100 then null when m.tr_hp <= 0 then rf else m.tr_ritmo end,
           tr_hurt_at = case when m.tr_hp + x.g >= 100 then null else m.tr_hurt_at + make_interval(secs => x.e + x.g * x.r * 36) end
      from (select id, e, r, case when tr_hurt_at is null then 100 else floor(greatest(0, extract(epoch from now() - tr_hurt_at) - e) * 100 / (r * 3600))::int end g
              from (select id, tr_hurt_at, case when tr_hp <= 0 then esp * 3600 else 0 end e,
                           case when tr_hp <= 0 then rf else coalesce(tr_ritmo, hh) end r
                      from monsters where user_id = _uid and tr_hp < 100) y) x
     where m.id = x.id and x.g > 0;
  else
    update monsters set tr_hp = 100, tr_hurt_at = null
     where user_id = _uid and tr_hp < 100
       and coalesce(tr_hurt_at, '-infinity'::timestamptz) <= now() - make_interval(hours => public.cura_horas(_uid));
  end if;
end $$;


-- centro_curar: versão do 95 com a mudança do arquivo 113
create or replace function public.centro_curar(_ids uuid[] default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters; cost int; n int;
begin
  select * into me from characters where user_id = uid for update;
  perform public.treino_autocura(uid);
  if _ids is not null then perform public.gin_trava(uid, _ids); end if;   -- arquivo 113: escalados no Ginásio não se curam
  select coalesce(sum(public.centro_preco_mon(uid, level, tr_hp, tr_hurt_at)), 0), count(*) into cost, n
    from monsters where user_id = uid and tr_hp < 100 and (_ids is null or id = any(_ids)) and not public.gin_preso(uid, id);
  if n = 0 then raise exception 'Nenhum Pokémon precisa de cura.'; end if;
  if me.coins < cost then raise exception 'A cura custa % moedas e você tem %. Se preferir, espere: a vida volta sozinha, de graça (de desmaiado a inteiro em % horas).', cost, me.coins, public.cura_horas(uid); end if;
  update characters set coins = coins - cost where id = me.id;
  update monsters set tr_hp = 100, tr_hurt_at = null where user_id = uid and tr_hp < 100 and (_ids is null or id = any(_ids)) and not public.gin_preso(uid, id);
  return jsonb_build_object('cost', cost, 'curados', n, 'coins', me.coins - cost);
end $$;


-- creche_treinar: versão do 77 com a mudança do arquivo 113
create or replace function public.creche_treinar(_mon uuid, _niveis int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.creche_cfg(); me characters; m monsters; usados int; alvo int; custo int := 0; custos jsonb := '[]'::jsonb;
  l int; v int; p creche_pedidos; A int := (c->>'nivel_alto')::int; usados_alto int; pede_baixo int; pede_alto int;
begin
  perform public.gin_trava(uid, array[_mon]);   -- arquivo 113
  if not coalesce((c->>'on')::boolean, true) then raise exception 'A Creche está fechada no momento.'; end if;
  select * into me from characters where user_id = uid for update;
  perform public.creche_tick(uid);
  if exists (select 1 from creche_pedidos where user_id = uid and status = 'treinando') then
    raise exception 'A Creche já está treinando um Pokémon seu. Espere terminar (ou cancele) para começar outro.';
  end if;
  select * into m from monsters where id = _mon and user_id = uid;
  if m.id is null then raise exception 'Escolha um Pokémon seu.'; end if;
  if _niveis is null or _niveis < 1 then raise exception 'Escolha quantos níveis.'; end if;
  -- arquivo 77: dois limites por semana, um até o nível alto (30) e outro acima dele
  select coalesce(sum(greatest(0, least(level_to, A) - least(level_from, A))), 0), coalesce(sum(greatest(0, level_to - greatest(level_from, A))), 0)
    into usados, usados_alto from creche_log where user_id = uid and created_at >= public.creche_inicio_semana();
  alvo := m.level + _niveis;
  pede_baixo := greatest(0, least(alvo, A) - least(m.level, A)); pede_alto := greatest(0, alvo - greatest(m.level, A));
  if usados + pede_baixo > (c->>'niveis_semana')::int then
    raise exception 'Até o nível %, a Creche treina no máximo % níveis por semana. Você ainda pode usar %.', A, c->>'niveis_semana', greatest(0, (c->>'niveis_semana')::int - usados);
  end if;
  if usados_alto + pede_alto > (c->>'niveis_semana_alto')::int then
    raise exception 'Acima do nível %, a Creche treina no máximo % níveis por semana. Você ainda pode usar %.', A, c->>'niveis_semana_alto', greatest(0, (c->>'niveis_semana_alto')::int - usados_alto);
  end if;
  if alvo > (c->>'nivel_max')::int then raise exception 'A Creche só treina até o nível %.', c->>'nivel_max'; end if;
  for l in m.level + 1 .. alvo loop
    v := ceil(l * (case when l > A then (c->>'preco_por_nivel_alto')::int else (c->>'preco_por_nivel')::int end) * (100 - public.creche_desc(uid)) / 100.0)::int;   -- Domador: desconto
    custo := custo + v; custos := custos || to_jsonb(v);
  end loop;
  if me.coins < custo then raise exception 'Custa % moedas e você tem %.', custo, me.coins; end if;
  update characters set coins = coins - custo where id = me.id;
  insert into creche_pedidos(user_id, mon_id, species, level_from, niveis, custos, horas)
  values (uid, m.id, m.species_id, m.level, _niveis, custos, (c->>'horas_por_nivel')::int) returning * into p;
  insert into creche_log(user_id, mon_id, species, level_from, level_to, niveis, custo) values (uid, m.id, m.species_id, m.level, alvo, _niveis, custo);
  return jsonb_build_object('custo', custo, 'coins', me.coins - custo, 'level', m.level, 'alvo', alvo,
    'proximo_em', p.created_at + make_interval(hours => p.horas), 'termina_em', p.created_at + make_interval(hours => p.horas * _niveis));
end $$;


-- leilao_criar: versão do 65 com a mudança do arquivo 113
create or replace function public.leilao_criar(_mon uuid, _min int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.leilao_cfg(); m monsters; ult timestamptz; l leiloes;
begin
  perform public.gin_trava(uid, array[_mon]);   -- arquivo 113
  if not coalesce((c->>'on')::boolean, true) then raise exception 'O Leilão está fechado no momento.'; end if;
  perform 1 from characters where user_id = uid for update;
  perform public.leilao_tick();
  select * into m from monsters where id = _mon and user_id = uid;
  if m.id is null then raise exception 'Escolha um Pokémon seu.'; end if;
  if exists (select 1 from leiloes where mon_id = m.id and status = 'aberto') then raise exception 'Esse Pokémon já está em leilão.'; end if;
  select max(created_at) into ult from leiloes where seller = uid and status <> 'cancelado';
  if ult is not null and now() < ult + make_interval(days => (c->>'intervalo_dias')::int) then
    raise exception 'Você pode pôr 1 Pokémon em leilão a cada % dias. O próximo libera em %.', c->>'intervalo_dias',
      to_char((ult + make_interval(days => (c->>'intervalo_dias')::int)) at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI');
  end if;
  if _min is null or _min < (c->>'min_preco')::int or _min > 1000000 then raise exception 'O lance mínimo precisa ser de pelo menos % moedas.', c->>'min_preco'; end if;
  insert into leiloes(seller, mon_id, species, level, info, min_price, ends_at)
  values (uid, m.id, m.species_id, m.level, public.bt_mon(m.id) - 'outfit' || jsonb_build_object('dvs', jsonb_build_array(m.dv_atk, m.dv_def, m.dv_spd, m.dv_spc)),
          _min, now() + make_interval(hours => (c->>'horas')::int))
  returning * into l;
  insert into event_log(user_id, kind, message) select uid, 'leilao', ch.name || ' pôs ' || (select name from pokemon where id = m.species_id) || ' (nível ' || m.level || ') no Leilão, a partir de ' || _min || ' moedas.' from characters ch where ch.user_id = uid;
  return to_jsonb(l);
end $$;


-- mon_team_set: versão do 18 com a mudança do arquivo 113
create or replace function public.mon_team_set(_ids uuid[]) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); n int := coalesce(cardinality(_ids), 0); i int;
begin
  perform public.rpg_gin_expira(uid);   -- arquivo 113: quem está numa batalha de Ginásio não sai da equipe
  if exists (select 1 from monsters m where m.user_id = uid and m.team_slot is not null and not (m.id = any(coalesce(_ids, '{}'::uuid[]))) and public.gin_preso(uid, m.id)) then
    raise exception 'Um Pokémon da equipe está numa batalha de Ginásio em andamento: ele não pode sair da equipe agora.';
  end if;
  if n > 6 then raise exception 'A equipe tem no máximo 6 Pokémon.'; end if;
  if n <> (select count(distinct x) from unnest(coalesce(_ids, '{}')) x) then raise exception 'Pokémon repetido na equipe.'; end if;
  if n <> (select count(*) from monsters where user_id = uid and id = any(coalesce(_ids, '{}'))) then raise exception 'Só dá para usar Pokémon da sua coleção.'; end if;
  update monsters set team_slot = null where user_id = uid and team_slot is not null;
  for i in 1 .. n loop update monsters set team_slot = i where id = _ids[i] and user_id = uid; end loop;
end $$;


-- rpg_encontro: versão do 103 com a mudança do arquivo 113
create or replace function public.rpg_encontro(_mon uuid, _zona text, _comp uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.rpg_cfg(); z jsonb; me characters; m monsters; d rpg_dias; bid uuid;
  lvl int; sp int; wild jsonb; mine jsonb; hp0 int; s0 jsonb; s1 jsonb; tipos text[]; lend int[]; mn int; mx int;
begin
  if not coalesce((c->>'on')::boolean, true) and not public.is_admin() then raise exception 'A Aventura está fechada no momento.'; end if;
  select * into me from characters where user_id = uid for update;
  bid := public.treino_batalha(uid);
  if bid is not null then return jsonb_build_object('battle', bid); end if;   -- termine a luta que já começou
  z := c->'zonas'->_zona;
  if z is null or jsonb_typeof(z) <> 'object' then raise exception 'Não há Pokémon selvagens neste lugar.'; end if;
  select array_agg(x) into tipos from jsonb_array_elements_text(z->'tipos') x;
  if public.rpg_noite() then   -- arquivo 99: de noite aparecem também os tipos da noite (Fantasma e Sombrio)
    tipos := tipos || array(select jsonb_array_elements_text(coalesce(c->'noite'->'tipos', '[]'::jsonb)));
  end if;
  select array_agg(x::int) into lend from jsonb_array_elements_text(coalesce(c->'lendarios', '[]'::jsonb)) x;
  mn := greatest(1, least(100, coalesce((z->>'min')::int, 2))); mx := greatest(mn, least(100, coalesce((z->>'max')::int, mn)));
  insert into rpg_dias(user_id, dia) values (uid, public.game_today()) on conflict do nothing;
  select * into d from rpg_dias where user_id = uid and dia = public.game_today() for update;
  if d.batalhas >= (c->>'batalhas_dia')::int + public.vb(uid, 'arena', 'rpg_lutas')::int then   -- arquivo 100: Arena da vila dá lutas a mais
    raise exception 'Você já fez as % lutas de hoje na Aventura. Amanhã tem mais.', (c->>'batalhas_dia')::int + public.vb(uid, 'arena', 'rpg_lutas')::int;
  end if;
  if d.ult is not null and now() < d.ult + make_interval(secs => (c->>'espera_seg')::int) then
    raise exception 'Nenhum Pokémon por aqui… continue andando.';
  end if;
  perform public.treino_autocura(uid);
  select * into m from monsters where id = _mon and user_id = uid;
  if m.id is null then raise exception 'Coloque um Pokémon seu na frente da equipe.'; end if;
  if _comp is not null and (_comp = m.id or not exists (select 1 from monsters where id = _comp and user_id = uid)
     or coalesce((select tr_hp from monsters where id = _comp), 100) <= 0) then _comp := null; end if;
  if m.tr_hp <= 0 then
    raise exception '% está desmaiado. Leve ao Centro Pokémon ou ponha outro Pokémon na frente da equipe.', (select name from pokemon where id = m.species_id);
  end if;
  delete from battles where mode = 'treino' and p1 = uid and status <> 'ativa';   -- lutas antigas já contadas
  lvl := mn + floor(random() * (mx - mn + 1))::int;
  if random() * 100 < public.eq_bonus(uid, 'botas') then   -- arquivo 103: Botas = chance de Pokémon mais raro (taxa de captura até 120)
    select p.id into sp from pokemon p
     where public.gen_ok(p.id) and not (p.id = any(coalesce(lend, '{}'::int[]))) and p.catch_rate <= 120
       and (p.g1_type1 = any(tipos) or p.g1_type2 = any(tipos))
       and public.rpg_nivel_min(p.id) <= lvl and lvl < public.rpg_nivel_max(p.id)
     order by -ln(1 - random()) / greatest(p.catch_rate, 1) limit 1;
  end if;
  if sp is null then
  select p.id into sp from pokemon p
   where public.gen_ok(p.id) and not (p.id = any(coalesce(lend, '{}'::int[])))
     and (p.g1_type1 = any(tipos) or p.g1_type2 = any(tipos))
     and public.rpg_nivel_min(p.id) <= lvl and lvl < public.rpg_nivel_max(p.id)
   order by -ln(1 - random()) / greatest(p.catch_rate, 1) limit 1;   -- sorteio com peso: os de captura difícil saem menos
  end if;
  if sp is null then raise exception 'Nenhum Pokémon por aqui… continue andando.'; end if;
  wild := public.ia_mon(sp, lvl);
  mine := public.rpg_mine(m.id, uid, m.tr_hp);   -- arquivo 103: o Peitoral dá resistência (mais vida) nas lutas da Aventura
  s0 := jsonb_build_object('user', uid, 'name', me.name, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(mine));
  s1 := jsonb_build_object('user', uid, 'name', 'Pokémon selvagem', 'npc', true, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(wild));
  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (uid, uid, 'treino', 1, 'ativa', 1, 'normal', now(),
          jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb, 'treino', jsonb_build_object('mon', m.id, 'forte', false, 'comp', _comp, 'rpg', _zona, 'ataques', 0)),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', 'Um ' || (wild->>'name') || ' selvagem (nível ' || lvl || ') apareceu em ' || coalesce(z->>'nome', 'mato') || case when public.rpg_noite() then ' 🌙' else '' end || '!'),
            jsonb_build_object('txt', 'Vai, ' || (mine->>'name') || '!' || case when m.tr_hp < 100 then ' (com ' || m.tr_hp || '% da vida)' else '' end)))))
  returning id into bid;
  update rpg_dias set batalhas = batalhas + 1, ult = now() where user_id = uid and dia = public.game_today();
  return jsonb_build_object('battle', bid, 'batalhas', d.batalhas + 1, 'batalhas_dia', (c->>'batalhas_dia')::int + public.vb(uid, 'arena', 'rpg_lutas')::int);
end $$;


-- rpg_chefe_lutar: versão do 103 com a mudança do arquivo 113
create or replace function public.rpg_chefe_lutar(_comp uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.rpg_cfg()->'chefe'; me characters; ch rpg_chefes; d rpg_chefe_dano; bid uuid; m monsters;
  wild jsonb; mine jsonb; hp0 int; s0 jsonb; s1 jsonb;
begin
  select * into me from characters where user_id = uid for update;
  bid := public.treino_batalha(uid);
  if bid is not null then return jsonb_build_object('battle', bid); end if;
  select * into ch from rpg_chefes where status = 'ativo' and fim > now() order by id desc limit 1;
  if ch.id is null then raise exception 'Não há nenhum chefe na Aventura agora.'; end if;
  insert into rpg_chefe_dano(chefe_id, user_id, dia) values (ch.id, uid, public.game_today()) on conflict do nothing;
  select * into d from rpg_chefe_dano where chefe_id = ch.id and user_id = uid for update;
  if d.dia is distinct from public.game_today() then update rpg_chefe_dano set dia = public.game_today(), lutas_dia = 0 where chefe_id = ch.id and user_id = uid; d.lutas_dia := 0; end if;
  if d.lutas_dia >= (c->>'tentativas_dia')::int then raise exception 'Você já lutou % vezes hoje contra o chefe. Volte amanhã!', (c->>'tentativas_dia'); end if;
  perform public.treino_autocura(uid);
  select * into m from monsters where user_id = uid and team_slot is not null and tr_hp > 0 order by team_slot limit 1;
  if m.id is null then raise exception 'Todos os Pokémon da sua equipe estão desmaiados. Leve ao Centro Pokémon.'; end if;
  if _comp is not null and (_comp = m.id or not exists (select 1 from monsters where id = _comp and user_id = uid)
     or coalesce((select tr_hp from monsters where id = _comp), 100) <= 0) then _comp := null; end if;
  delete from battles where mode = 'treino' and p1 = uid and status <> 'ativa';
  wild := public.ia_mon(ch.especie, ch.nivel);
  mine := public.rpg_mine(m.id, uid, m.tr_hp);   -- arquivo 103: o Peitoral dá resistência (mais vida) nas lutas da Aventura
  s0 := jsonb_build_object('user', uid, 'name', me.name, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(mine));
  s1 := jsonb_build_object('user', uid, 'name', 'Chefe da rota', 'npc', true, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(wild));
  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (uid, uid, 'treino', 1, 'ativa', 1, 'normal', now(),
          jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb, 'treino', jsonb_build_object('mon', m.id, 'forte', true, 'comp', _comp, 'chefe', ch.id)),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', '👹 O ' || (wild->>'name') || ' gigante (nível ' || ch.nivel || ') ruge! Você tem ' || (c->>'turnos') || ' turnos para causar o máximo de dano.'),
            jsonb_build_object('txt', 'Vai, ' || (mine->>'name') || '!' || case when m.tr_hp < 100 then ' (com ' || m.tr_hp || '% da vida)' else '' end)))))
  returning id into bid;
  update rpg_chefe_dano set lutas = lutas + 1, lutas_dia = lutas_dia + 1 where chefe_id = ch.id and user_id = uid;
  return jsonb_build_object('battle', bid);
end $$;


-- exp_batalha: versão do 111 com a mudança do arquivo 113
create or replace function public.exp_batalha(_run bigint, _b jsonb) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare r exp_runs; c jsonb := public.exp_cfg(); m monsters; me characters; sp int; lv int; wild jsonb; mine jsonb; bid uuid; d0 int; d1 int; s0 jsonb; s1 jsonb;
begin
  select * into r from exp_runs where id = _run for update;
  select * into m from monsters where user_id = r.dono and team_slot is not null and tr_hp > 0 order by team_slot limit 1;
  if m.id is null then return null; end if;
  select * into me from characters where user_id = r.dono;
  sp := (_b->'especies'->>floor(random() * jsonb_array_length(_b->'especies'))::int)::int;
  d0 := coalesce((_b->'delta'->>0)::int, 0); d1 := coalesce((_b->'delta'->>1)::int, d0);
  lv := m.level + d0 + floor(random() * (d1 - d0 + 1))::int + round((coalesce((c->>'dificuldade')::numeric, 1) - 1) * 3)::int;
  lv := greatest((c->>'nivel_min')::int, least((c->>'nivel_max')::int, lv));
  wild := public.ia_mon(sp, lv);
  if coalesce((_b->>'chefe')::boolean, false) then
    wild := jsonb_set(jsonb_set(wild, '{maxhp}', to_jsonb(ceil((wild->>'maxhp')::int * (c->>'chefe_vida')::numeric)::int)), '{hp}', to_jsonb(ceil((wild->>'maxhp')::int * (c->>'chefe_vida')::numeric)::int));
  end if;
  mine := public.rpg_mine(m.id, r.dono, m.tr_hp);
  delete from battles where mode = 'treino' and p1 = r.dono and status <> 'ativa';
  s0 := jsonb_build_object('user', r.dono, 'name', me.name, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(mine));
  s1 := jsonb_build_object('user', r.dono, 'name', case when coalesce((_b->>'chefe')::boolean, false) then 'Guardião' else 'Selvagem' end, 'npc', true, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(wild));
  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (r.dono, r.dono, 'treino', 1, 'ativa', 1, 'normal', now(),
          jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb, 'treino', jsonb_build_object('mon', m.id, 'forte', false, 'comp', null, 'exp', _run)),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', case when coalesce((_b->>'chefe')::boolean, false) then '⛏️ O guardião ' || (wild->>'name') || ' (nível ' || lv || ') acordou!' else '⛏️ Um ' || (wild->>'name') || ' (nível ' || lv || ') aparece na mina!' end),
            jsonb_build_object('txt', 'Vai, ' || (mine->>'name') || '!' || case when m.tr_hp < 100 then ' (com ' || m.tr_hp || '% da vida)' else '' end)))))
  returning id into bid;
  update exp_runs set batalha = bid, status = 'batalha', pendente = _b || jsonb_build_object('especie', sp, 'nivel', lv) where id = _run;
  return bid;
end $$;


-- rocket_side: versão do 44 com a mudança do arquivo 113
create or replace function public.rocket_side(_raid rocket_raids, _uid uuid) returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object('user', _uid, 'name', 'Equipe Rocket', 'npc', true, 'active', 0, 'need_switch', false,
    'mons', (select jsonb_agg(public.ia_mon((t->>'species')::int, _raid.level) order by o) from jsonb_array_elements(_raid.team) with ordinality x(t, o)))
$$;


-- battle_act: versão do 99 com a mudança do arquivo 113
create or replace function public.battle_act(_id uuid, _turn int, _kind text, _value int, _item text default null) returns public.battles
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); b battles; side int; s jsonb; A jsonb; kind text := _kind; ok boolean; pre int; p jsonb; k int; item text;
  rc jsonb; custo int := 0; moedas int; lim int;
begin
  select * into b from battles where id = _id for update;
  if b.id is null or uid not in (b.p1, b.p2) then raise exception 'Batalha não encontrada.'; end if;
  if b.status <> 'ativa' then raise exception 'Essa batalha não está em andamento.'; end if;
  -- arquivo 113: a batalha do Ginásio que passou do prazo vira derrota
  if b.mode = 'treino' and b.state->'treino' ? 'multi' and coalesce((public.rpg_cfg()->'ginasios'->>'expira_min')::int, 30) > 0
     and b.started_at < now() - make_interval(mins => coalesce((public.rpg_cfg()->'ginasios'->>'expira_min')::int, 30)) then
    perform public.rpg_gin_expira(b.p1);
    select * into b from battles where id = _id;
    return b;
  end if;
  side := case when uid = b.p1 then 0 else 1 end;
  if _kind = 'forfeit' then
    -- arquivo 97: fugir de uma luta da Aventura custa moedas (base + um tanto por ataque já feito)
    if b.mode = 'treino' and b.state->'treino'->>'rpg' is not null then
      rc := public.rpg_cfg();
      custo := greatest(0, coalesce((rc->>'fuga_base')::int, 0) + coalesce((rc->>'fuga_por_ataque')::int, 0) * coalesce((b.state->'treino'->>'ataques')::int, 0));
      if custo > 0 then
        select coins into moedas from characters where user_id = uid for update;
        if coalesce(moedas, 0) < custo then raise exception 'Fugir agora custa % moedas e você tem %. Continue lutando!', custo, coalesce(moedas, 0); end if;
        update characters set coins = coins - custo where user_id = uid;
        update battles set state = jsonb_set(state, '{treino,fuga_paga}', to_jsonb(custo)) where id = b.id;
      end if;
    end if;
    update battles set log = log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt', case when b.mode = 'treino' then case when custo > 0 then 'Você pagou ' || custo || ' moedas e fugiu da luta.' else case when b.state->'treino' ? 'multi' then 'Você desistiu do Ginásio.' else 'Você fugiu da luta.' end end else (b.state->'sides'->side->>'name') || ' desistiu da batalha.' end))))
     where id = b.id;
    perform public.bt_finish(b.id, case when side = 0 then b.p2 else b.p1 end, 'desistencia');
    if b.mode = 'rocket' then perform public.rocket_after(b.id, public.rocket_dmg(b.state)); end if;
    if b.mode = 'treino' then perform public.treino_after(b.id); perform public.rpg_after(b.id); end if;
    select * into b from battles where id = _id; return b;
  end if;
  if _turn <> b.turn then raise exception 'Esse turno já passou. Atualize a tela.'; end if;
  if (side = 0 and b.ready1) or (side = 1 and b.ready2) then raise exception 'Você já escolheu a ação deste turno. Espere o adversário.'; end if;
  s := b.state; A := s->'sides'->side->'mons'->((s->'sides'->side->>'active')::int);
  if b.phase = 'troca' or coalesce((s->'sides'->side->>'need_switch')::boolean, false) then
    if _kind <> 'switch' then raise exception 'Escolha qual Pokémon vai entrar.'; end if;
  end if;
  if _kind = 'switch' then
    if _value is null or _value < 0 or _value >= jsonb_array_length(s->'sides'->side->'mons') then raise exception 'Pokémon inválido.'; end if;
    if _value = (s->'sides'->side->>'active')::int then raise exception 'Esse Pokémon já está em campo.'; end if;
    if (s->'sides'->side->'mons'->_value->>'hp')::int <= 0 then raise exception 'Esse Pokémon desmaiou.'; end if;
    if (A->>'hp')::int > 0 and b.phase <> 'troca' and (coalesce(A->'fl'->>'charging', '') <> '' or coalesce((A->'fl'->>'recharge')::boolean, false)) then raise exception 'Não dá para trocar agora.'; end if;
  elsif _kind = 'move' then
    if coalesce(A->'fl'->>'charging', '') <> '' or coalesce((A->'fl'->>'recharge')::boolean, false) then kind := 'forced';
    elsif _value = -1 then
      select bool_and((x->>'pp')::int = 0) into ok from jsonb_array_elements(A->'moves') x;
      if not ok then raise exception 'Ainda há ataques com PP.'; end if;
    else
      if _value is null or _value < 0 or _value >= jsonb_array_length(A->'moves') then raise exception 'Ataque inválido.'; end if;
      if (A->'moves'->_value->>'pp')::int <= 0 then raise exception 'Esse ataque está sem PP.'; end if;
    end if;
  elsif _kind = 'item' then
    perform public.bt_item_check(s, side, uid, _item, _value);
    item := _item;
  else raise exception 'Ação inválida.'; end if;
  insert into battle_actions(battle_id, turn, side, user_id, kind, value, item) values (b.id, b.turn, side, uid, kind, _value, item);
  -- Equipe Rocket (arquivo 44): o servidor joga pelo lado da Rocket na hora e conta o dano na barra coletiva
  if b.mode = 'rocket' then
    pre := public.rocket_dmg(b.state);
    p := public.ia_pick(b.state, 1, 'lider', b.turn);   -- arquivo 113: escolha nova
    update battles set state = public.ia_memo(state, 1, p, b.turn) where id = b.id;
    insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, uid, p->>'kind', (p->>'value')::int);
    perform public.bt_resolve(b.id);
    for k in 1 .. 3 loop
      select * into b from battles where id = _id;
      exit when b.status <> 'ativa' or b.phase <> 'troca' or not coalesce((b.state->'sides'->1->>'need_switch')::boolean, false);
      insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, uid, 'switch', public.war_switch(b.state, 1, true));
      perform public.bt_resolve(b.id);
    end loop;
    perform public.rocket_after(_id, pre);
    select * into b from battles where id = _id;
    return b;
  end if;
  -- arquivo 113: Ginásio em uma batalha só. O Líder escolhe pela regra nova; quando o Pokémon dele cai, entra o próximo da ordem
  if b.mode = 'treino' and b.state->'treino' ? 'multi' then
    if b.phase = 'troca' then
      if coalesce((b.state->'sides'->1->>'need_switch')::boolean, false) and not exists (select 1 from battle_actions ba where ba.battle_id = b.id and ba.turn = b.turn and ba.side = 1) then
        k := public.war_switch(b.state, 1, false);
        perform public.rpg_gin_revela(b.id, k);
        insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, uid, 'switch', k);
      end if;
    else
      perform public.rpg_gin_par(b.id);
      select * into b from battles where id = _id;
      p := public.ia_pick(b.state, 1, 'lider', b.turn);
      update battles set state = public.ia_memo(state, 1, p, b.turn) where id = b.id;
      insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, uid, p->>'kind', (p->>'value')::int);
    end if;
    perform public.bt_resolve(b.id);
    perform public.rpg_gin_depois(b.id);
    select * into b from battles where id = _id;
    if b.status <> 'ativa' then perform public.treino_after(_id); perform public.rpg_after(_id); select * into b from battles where id = _id; end if;
    return b;
  end if;
  -- Grama de Treino (arquivo 56): o selvagem joga sozinho na hora; no fim, XP e vida pelo treino_after
  if b.mode = 'treino' then
    if kind = 'move' and b.state->'treino'->>'rpg' is not null then   -- arquivo 97: conta os ataques (a fuga fica mais cara)
      update battles set state = jsonb_set(state, '{treino,ataques}', to_jsonb(coalesce((state->'treino'->>'ataques')::int, 0) + 1)) where id = b.id;
    end if;
    if b.state->'treino' ? 'elite' then p := public.war_pick(b.state, 1, 'forte');   -- a Liga do Planalto continua como era
    else
      p := public.ia_pick(b.state, 1, 'selvagem', b.turn);   -- arquivo 113: selvagens, Chefe e Expedições
      update battles set state = public.ia_memo(state, 1, p, b.turn) where id = b.id;
    end if;
    insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, 1, uid, p->>'kind', (p->>'value')::int);
    perform public.bt_resolve(b.id);
    select * into b from battles where id = _id;
    lim := case when b.state->'treino' ? 'chefe' then coalesce((public.rpg_cfg()->'chefe'->>'turnos')::int, 12) else (public.treino_cfg()->>'turnos')::int end;
    if b.status = 'ativa' and b.turn > lim then
      update battles set log = log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt',
        case when b.state->'treino' ? 'chefe' then 'O chefe rugiu e jogou você para longe! Fim da luta.' else 'A luta demorou demais e o selvagem fugiu para a grama.' end))))
       where id = b.id;
      perform public.bt_finish(b.id, null, 'limite');
    end if;
    select * into b from battles where id = _id;
    if b.status <> 'ativa' then perform public.treino_after(_id); perform public.rpg_after(_id); select * into b from battles where id = _id; end if;
    return b;
  end if;
  if side = 0 then update battles set ready1 = true where id = b.id returning * into b;
  else update battles set ready2 = true where id = b.id returning * into b; end if;
  if b.ready1 and b.ready2 then perform public.bt_resolve(b.id); end if;
  select * into b from battles where id = _id;
  return b;
end $$;


-- treino_after: versão do 103 com a mudança do arquivo 113
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
      ganho := ceil(ganho * (100 + public.eq_bonus(b.p1, 'calca')) / 100)::int;   -- arquivo 103: Calça
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


-- rpg_after: versão do 111 com a mudança do arquivo 113
create or replace function public.rpg_after(_bid uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare b battles; t jsonb; me0 jsonb; wi jsonb; won boolean; res jsonb := '{}'::jsonb; tt rpg_gin_tent; l jsonb; c jsonb := public.rpg_cfg();
  dn int; ch rpg_chefes; er rpg_elite_run; el rpg_elite; ne int; hpme int; prox int; nome text; z jsonb; p pokemon; total int; n int;
begin
  select * into b from battles where id = _bid for update;
  if b.id is null or b.mode <> 'treino' or b.status = 'ativa' then return null; end if;
  t := b.state->'treino';
  if coalesce((t->>'pos_feito')::boolean, false) then return t->'pos'; end if;
  me0 := b.state->'sides'->0->'mons'->0; wi := b.state->'sides'->1->'mons'->0;
  won := (wi->>'hp')::int <= 0 and (me0->>'hp')::int > 0;
  if t ? 'gym' and t ? 'multi' then   -- arquivo 113: Ginásio em batalha única
    select * into tt from rpg_gin_tent where id = (t->>'gym_try')::bigint for update;
    select to_jsonb(x) into l from rpg_lideres x where regiao = t->>'gym';
    total := jsonb_array_length(b.state->'sides'->1->'mons');
    dn := (select count(*) from jsonb_array_elements(b.state->'sides'->1->'mons') x where (x->>'hp')::int <= 0);
    if tt.id is not null and tt.status = 'andando' then
      if coalesce(b.end_reason, '') not in ('desistencia', 'tempo') and dn >= total then
        tt.status := 'venceu';
        res := res || jsonb_build_object('drop', public.rpg_gin_vitoria(b.p1, t->>'gym', l->>'nome'));
      else
        tt.status := 'perdeu';
      end if;
      update rpg_gin_tent set status = tt.status, idx = dn where id = tt.id;
    end if;
    res := res || jsonb_build_object('gym', t->>'gym', 'status', tt.status, 'idx', dn, 'total', total, 'lider', l->>'nome', 'multi', true, 'tempo', b.end_reason = 'tempo');
  elsif t ? 'gym' then
    select * into tt from rpg_gin_tent where id = (t->>'gym_try')::bigint for update;
    select to_jsonb(x) into l from rpg_lideres x where regiao = t->>'gym';
    total := jsonb_array_length(l->'time');
    if tt.id is not null and tt.status = 'andando' then
      if b.end_reason = 'desistencia' then
        update rpg_gin_tent set status = 'perdeu' where id = tt.id; tt.status := 'perdeu';
      elsif (wi->>'hp')::int <= 0 then
        tt.hp := jsonb_set(tt.hp, array[tt.idx::text], '0'); tt.idx := tt.idx + 1;
        if tt.idx >= total then
          tt.status := 'venceu';
          insert into rpg_insignias(user_id, regiao) values (b.p1, t->>'gym') on conflict do nothing;
          perform public.rpg_premiar(b.p1, (c->'ginasios'->>'moedas')::int, c->'ginasios'->'itens');
          res := res || jsonb_build_object('drop', public.equip_drop(b.p1, 'ginasio'));   -- arquivo 103
          select name into nome from characters where user_id = b.p1;
          insert into event_log(user_id, kind, message) values (b.p1, 'ginasio', '🏅 ' || nome || ' venceu ' || (l->>'nome') || ' e ganhou a insígnia do Ginásio!');
          select count(*) into n from rpg_insignias where user_id = b.p1;
          if n >= (select count(*) from rpg_lideres) then
            perform public.rpg_premiar(b.p1, (c->'ginasios'->>'todas_moedas')::int, c->'ginasios'->'todas_itens');
            insert into event_log(user_id, kind, message) values (b.p1, 'ginasio', '👑 ' || nome || ' juntou TODAS as insígnias da Aventura!');
          end if;
        end if;
        update rpg_gin_tent set idx = tt.idx, hp = tt.hp, status = tt.status where id = tt.id;
      else
        tt.hp := jsonb_set(tt.hp, array[tt.idx::text], to_jsonb(greatest(1, ceil((wi->>'hp')::numeric * 100 / greatest(1, (wi->>'maxhp')::int)))::int));
        if not exists (select 1 from monsters where user_id = b.p1 and tr_hp > 0 and id::text in (select jsonb_array_elements_text(coalesce(tt.meus, '[]'::jsonb)))) then tt.status := 'perdeu'; end if;   -- arquivo 101: só os escolhidos
        update rpg_gin_tent set hp = tt.hp, status = tt.status where id = tt.id;
      end if;
    end if;
    res := res || jsonb_build_object('gym', t->>'gym', 'status', tt.status, 'idx', tt.idx, 'total', total, 'lider', l->>'nome');
  elsif t ? 'elite' then   -- arquivo 106: a Liga (a vida dos escolhidos fica guardada na tentativa e não volta)
    select * into er from rpg_elite_run where id = (t->>'elite')::bigint for update;
    select count(*) into ne from rpg_elite;
    if er.id is not null and er.status = 'andando' then
      select * into el from rpg_elite where ordem = er.etapa + 1;
      total := jsonb_array_length(el.time);
      hpme := greatest(0, least(100, floor((me0->>'hp')::numeric * 100 / greatest(1, (me0->>'maxhp')::int))))::int;
      if (me0->>'hp')::int > 0 then hpme := greatest(1, hpme); end if;
      er.vida := jsonb_set(er.vida, array[t->>'mon'], to_jsonb(hpme));
      if b.end_reason = 'desistencia' then
        er.status := 'perdeu';   -- fugir na Liga é desistir
      elsif (wi->>'hp')::int <= 0 then
        er.hp := jsonb_set(er.hp, array[er.idx::text], '0'); er.idx := er.idx + 1;
        if er.idx >= total then
          select name into nome from characters where user_id = b.p1;
          er.etapa := er.etapa + 1; er.idx := 0;
          if er.etapa >= ne then
            er.status := 'venceu';
          else
            insert into event_log(user_id, kind, message) values (b.p1, 'elite', '⚔️ ' || nome || ' venceu ' || el.nome || ' no Desafio do Planalto (' || er.etapa || ' de ' || ne || ')!');
            select jsonb_array_length(time) into prox from rpg_elite where ordem = er.etapa + 1;
            er.hp := (select jsonb_agg(100) from generate_series(1, prox));
          end if;
        end if;
      else
        er.hp := jsonb_set(er.hp, array[er.idx::text], to_jsonb(greatest(1, ceil((wi->>'hp')::numeric * 100 / greatest(1, (wi->>'maxhp')::int)))::int));
      end if;
      if er.status = 'andando' and not exists (select 1 from jsonb_each_text(er.vida) x join monsters mm on mm.id::text = x.key and mm.user_id = b.p1 where x.value::int > 0) then
        er.status := 'perdeu';
      end if;
      update rpg_elite_run set etapa = er.etapa, idx = er.idx, hp = er.hp, vida = er.vida, status = er.status,
             fim = case when er.status <> 'andando' then now() end where id = er.id;
      if er.status = 'venceu' then perform public.rpg_elite_coroar(b.p1, er.id); end if;
    end if;
    select * into el from rpg_elite where ordem = least(ne, er.etapa + 1);
    res := jsonb_build_object('elite', true, 'status', er.status, 'etapa', er.etapa, 'idx', er.idx, 'n_etapas', ne,
      'total', jsonb_array_length(el.time), 'membro', el.nome);
  elsif t ? 'exp' then   -- arquivo 111: luta da Expedição
    res := coalesce(public.exp_pos_batalha((t->>'exp')::bigint, b.id, won), '{}'::jsonb);
  elsif t ? 'chefe' then
    dn := greatest(0, (wi->>'maxhp')::int - greatest(0, (wi->>'hp')::int));
    select * into ch from rpg_chefes where id = (t->>'chefe')::bigint for update;
    if ch.id is not null and ch.status = 'ativo' then
      update rpg_chefes set dano = least(hp_total, rpg_chefes.dano + dn) where id = ch.id returning * into ch;
      update rpg_chefe_dano set dano = rpg_chefe_dano.dano + dn where chefe_id = ch.id and user_id = b.p1;
      if ch.dano >= ch.hp_total then perform public.rpg_chefe_premiar(ch.id); ch.status := 'vencido'; end if;
    end if;
    res := jsonb_build_object('chefe', ch.id, 'dano', dn, 'total_dano', ch.dano, 'hp_total', ch.hp_total, 'status', ch.status);
  elsif t->>'rpg' is not null and won then
    z := c->'zonas'->(t->>'rpg');
    select * into p from pokemon where id = (wi->>'species')::int;
    update rpg_missoes set prog = least(meta, prog + 1)
     where user_id = b.p1 and dia = public.game_today() and not resgatada and prog < meta
       and ((tipo = 'regiao' and alvo = z->>'regiao') or (tipo = 'tipo' and alvo in (p.g1_type1, coalesce(p.g1_type2, ''))));
    update rpg_missoes set prog = meta
     where user_id = b.p1 and dia = public.game_today() and not resgatada and tipo = 'nivel' and (wi->>'level')::int >= alvo::int;
    res := jsonb_build_object('missoes', (select count(*) from rpg_missoes where user_id = b.p1 and dia = public.game_today() and not resgatada and prog >= meta),
      'drop', public.equip_drop(b.p1, 'mato'));   -- arquivo 103: Doce de Forja e peças
  end if;
  update battles set state = jsonb_set(jsonb_set(state, '{treino,pos}', res), '{treino,pos_feito}', 'true') where id = b.id;
  return res;
end $$;


-- rpg_elite_lutar: versão do 106, só o nome: "Desafio do Planalto" (arquivo 113)
create or replace function public.rpg_elite_lutar(_comp uuid default null, _meus uuid[] default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.rpg_cfg()->'elite'; er rpg_elite_run; el rpg_elite; me characters; bid uuid; n int; tmax int;
  m monsters; vida int; sp int; lv int; wild jsonb; mine jsonb; whp int; s0 jsonb; s1 jsonb; total int;
begin
  if not coalesce((c->>'on')::boolean, true) and not public.is_admin() then raise exception 'O Desafio do Planalto está fechado no momento.'; end if;
  select count(*) into n from rpg_insignias where user_id = uid;
  if n < (c->>'insignias_min')::int then raise exception 'O Desafio do Planalto só recebe quem tem as % insígnias. Você tem %.', (c->>'insignias_min'), n; end if;
  select * into me from characters where user_id = uid for update;
  bid := public.treino_batalha(uid);
  if bid is not null then return jsonb_build_object('battle', bid); end if;
  perform public.treino_autocura(uid);
  select * into er from rpg_elite_run where user_id = uid and status = 'andando' order by id desc limit 1 for update;
  if er.id is null then
    select count(*) into n from rpg_elite_run where user_id = uid and dia = public.game_today();
    if n >= (c->>'tentativas_dia')::int then raise exception 'Você já entrou no Desafio do Planalto hoje. Volte amanhã!'; end if;
    tmax := greatest(1, least(6, (c->>'time_max')::int));
    if _meus is null or cardinality(_meus) not between 1 and tmax or (select count(distinct x) from unnest(_meus) x) <> cardinality(_meus) then
      raise exception 'Escolha de 1 a % Pokémon diferentes para entrar no Desafio do Planalto.', tmax;
    end if;
    if (select count(*) from monsters where user_id = uid and id = any(_meus) and tr_hp > 0) <> cardinality(_meus) then
      raise exception 'Escolha só Pokémon seus que estejam com vida.';
    end if;
    select jsonb_array_length(time) into total from rpg_elite where ordem = 1;
    if total is null then raise exception 'O Desafio do Planalto ainda não tem treinadores.'; end if;
    insert into rpg_elite_run(user_id, dia, meus, vida, hp)
    values (uid, public.game_today(), to_jsonb(_meus), (select jsonb_object_agg(id::text, tr_hp) from monsters where id = any(_meus)),
            (select jsonb_agg(100) from generate_series(1, total)))
    returning * into er;
    insert into event_log(user_id, kind, message) values (uid, 'elite', '🏛️ ' || me.name || ' entrou no Desafio do Planalto para enfrentar a Elite 4!');
  end if;
  -- o próximo escolhido com vida (a vida da Liga não volta: fica guardada na tentativa)
  select m2.* into m from jsonb_array_elements_text(er.meus) with ordinality e(v, k) join monsters m2 on m2.id::text = e.v
   where m2.user_id = uid and coalesce((er.vida->>e.v)::int, 0) > 0 order by e.k limit 1;
  if m.id is null then
    update rpg_elite_run set status = 'perdeu', fim = now() where id = er.id;
    return jsonb_build_object('fim', 'perdeu', 'msg', 'Todos os Pokémon que você levou para o Desafio do Planalto desmaiaram. A tentativa acabou.');
  end if;
  vida := (er.vida->>m.id::text)::int;
  if _comp is not null and (_comp = m.id or not exists (select 1 from monsters where id = _comp and user_id = uid)
     or coalesce((select tr_hp from monsters where id = _comp), 100) <= 0) then _comp := null; end if;
  delete from battles where mode = 'treino' and p1 = uid and status <> 'ativa';
  select * into el from rpg_elite where ordem = er.etapa + 1;
  total := jsonb_array_length(el.time);
  sp := (el.time->er.idx->>0)::int; lv := (el.time->er.idx->>1)::int;
  wild := public.npc_mon(sp, lv);
  whp := greatest(1, ceil((wild->>'maxhp')::int * coalesce((er.hp->>er.idx)::numeric, 100) / 100))::int;
  wild := jsonb_set(wild, '{hp}', to_jsonb(whp));
  mine := public.rpg_mine(m.id, uid, vida);   -- o Peitoral vale aqui, como nos Ginásios
  s0 := jsonb_build_object('user', uid, 'name', me.name, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(mine));
  s1 := jsonb_build_object('user', uid, 'name', el.nome, 'npc', true, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(wild));
  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (uid, uid, 'treino', 1, 'ativa', 1, 'normal', now(),
          jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb, 'treino', jsonb_build_object('mon', m.id, 'forte', false, 'comp', _comp, 'elite', er.id, 'elite_etapa', er.etapa, 'elite_idx', er.idx)),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', '🏛️ Desafio do Planalto · ' || el.nome || ' (' || (er.etapa + 1) || 'º de ' || (select count(*) from rpg_elite) || ')'),
            jsonb_build_object('txt', el.nome || ' manda ' || (wild->>'name') || ' (nível ' || lv || ')' || case when whp < (wild->>'maxhp')::int then ', ainda ferido,' else '' end || ' para a luta! (' || (er.idx + 1) || 'º de ' || total || ')'),
            jsonb_build_object('txt', 'Vai, ' || (mine->>'name') || '!' || case when vida < 100 then ' (com ' || vida || '% da vida)' else '' end)))))
  returning id into bid;
  return jsonb_build_object('battle', bid);
end $$;


-- rpg_elite_desistir: versão do 106, só o nome: "Desafio do Planalto" (arquivo 113)
create or replace function public.rpg_elite_desistir() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); n int; bid uuid;
begin
  bid := public.treino_batalha(uid);
  if bid is not null and exists (select 1 from battles where id = bid and state->'treino' ? 'elite') then
    raise exception 'Termine a luta que está acontecendo antes.';
  end if;
  update rpg_elite_run set status = 'perdeu', fim = now() where user_id = uid and status = 'andando';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Você não tem tentativa no Desafio do Planalto.'; end if;
  return jsonb_build_object('ok', true);
end $$;


-- rpg_elite_coroar: versão do 106, só o nome: "Desafio do Planalto" (arquivo 113)
create or replace function public.rpg_elite_coroar(_uid uuid, _run bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb := public.rpg_cfg()->'elite'; er rpg_elite_run; v int; nome text; tm jsonb; nd int;
begin
  select * into er from rpg_elite_run where id = _run;
  select coalesce(jsonb_agg(jsonb_build_object('species', m.species_id, 'level', m.level) order by e.k), '[]'::jsonb) into tm
    from jsonb_array_elements_text(er.meus) with ordinality e(v, k) join monsters m on m.id::text = e.v;
  insert into rpg_campeoes(user_id, time) values (_uid, tm)
  on conflict (user_id) do update set vezes = rpg_campeoes.vezes + 1, ultima_em = now(), time = excluded.time
  returning vezes into v;
  if v = 1 then
    perform public.rpg_premiar(_uid, (c->>'moedas')::int, c->'itens'); nd := coalesce((c->>'doces')::int, 0);
  else
    perform public.rpg_premiar(_uid, (c->>'repetir_moedas')::int, null); nd := coalesce((c->>'repetir_doces')::int, 0);
  end if;
  if nd > 0 then insert into equip_doces(user_id, qty) values (_uid, nd) on conflict (user_id) do update set qty = equip_doces.qty + nd; end if;
  select name into nome from characters where user_id = _uid;
  insert into event_log(user_id, kind, message) values (_uid, 'elite', case when v = 1
    then '👑 ' || nome || ' venceu a Elite 4 e o Campeão e entrou para o Hall da Fama da Aventura!'
    else '👑 ' || nome || ' venceu o Desafio do Planalto de novo (' || v || 'ª vez)!' end);
end $$;


-- admin_rpg_elite_salvar: versão do 106, só o nome: "Desafio do Planalto" (arquivo 113)
create or replace function public.admin_rpg_elite_salvar(_ordem int, _nome text, _classe text, _tipo text, _time jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare antes jsonb; e jsonb;
begin
  perform public.assert_admin();
  if not exists (select 1 from rpg_elite where ordem = _ordem) then raise exception 'Esse treinador do Desafio do Planalto não existe.'; end if;
  if length(btrim(coalesce(_nome, ''))) < 2 then raise exception 'Dê um nome ao treinador.'; end if;
  if jsonb_typeof(_time) <> 'array' or jsonb_array_length(_time) not between 1 and 6 then raise exception 'O time precisa ter de 1 a 6 Pokémon.'; end if;
  for e in select * from jsonb_array_elements(_time) loop
    if jsonb_typeof(e) <> 'array' or not exists (select 1 from pokemon where id = (e->>0)::int) or (e->>1)::int not between 1 and 100 then
      raise exception 'Pokémon ou nível inválido: %', e; end if;
  end loop;
  select to_jsonb(x) into antes from rpg_elite x where ordem = _ordem;
  update rpg_elite set nome = btrim(_nome), classe = coalesce(nullif(_classe, ''), classe), tipo = coalesce(_tipo, ''), time = _time where ordem = _ordem;
  insert into admin_audit_log(admin_id, action, target, after) values (auth.uid(), 'rpg_elite', _ordem::text, jsonb_build_object('antes', antes, 'nome', _nome, 'time', _time));
  return public.admin_rpg_elite();
end $$;


-- funções internas: o site não chama
revoke execute on function public.ia_cfg(), public.ia_dano(public.pk_moves), public.ia_inutil(public.pk_moves), public.ia_valor(public.pk_moves, text, text),
  public.ia_status_valor(public.pk_moves), public.ia_moves(int, int, boolean), public.ia_mon(int, int, int[], boolean),
  public.ia_status_util(public.pk_moves, jsonb, jsonb, int, int), public.ia_pick(jsonb, int, text, int), public.ia_memo(jsonb, int, jsonb, int),
  public.gin_preso(uuid, uuid), public.rpg_gin_expira(uuid), public.gin_trava(uuid, uuid[]), public.rpg_gin_par(uuid), public.rpg_gin_xp(uuid),
  public.rpg_gin_depois(uuid), public.rpg_gin_revela(uuid, int), public.rpg_gin_fim(uuid), public.rpg_gin_vitoria(uuid, text, text) from public, anon, authenticated;
grant execute on function public.rpg_ginasio(text), public.rpg_ginasio_lutar(text, uuid, uuid[]), public.admin_rpg_lider_salvar(text, text, text, text, jsonb),
  public.admin_cfg_efetiva(), public.battle_act(uuid, int, text, int, text), public.centro_curar(uuid[]), public.creche_treinar(uuid, int),
  public.leilao_criar(uuid, int), public.mon_team_set(uuid[]) to authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values
   ('🏟️ Ginásio em uma batalha só, como na Red/Blue', 'Os Ginásios da Aventura mudaram, a pedido da turma:
• Antes de começar, escolha a mesma quantidade de Pokémon que o Líder usa e a ordem em que entram. O primeiro começa em campo.
• Agora é UMA batalha só. A cada turno você ataca, troca de Pokémon (gasta o turno, e o Líder ataca quem entrou) ou usa um item.
• Quando um Pokémon seu desmaia, VOCÊ escolhe quem entra. O Revive funciona em quem desmaiou e ele volta com metade da vida.
• São até 2 itens na batalha inteira. O Líder segue a ordem dele e só troca quando o Pokémon dele cai.
• A experiência de cada Pokémon do Líder derrotado é dividida entre os seus que lutaram contra ele, como na Red/Blue.
• Durante a batalha, os escalados ficam travados: não vão ao Centro, à Creche, ao Leilão nem saem da equipe. Saiu da tela? Volte e continue de onde parou.
• A batalha tem prazo: se não terminar a tempo, conta como derrota.
• Os Pokémon dos Líderes, os selvagens, o Chefe da rota e a Equipe Rocket também ficaram mais espertos: escolhem ataques que acertam você.
• E a Liga da Aventura (Elite 4 e Campeão) agora se chama Desafio do Planalto, para não confundir com a Liga Pokémon do tabuleiro.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
