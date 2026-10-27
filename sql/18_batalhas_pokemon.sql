-- =====================================================================
-- POKEGAMES — Batalhas Pokémon por turnos entre jogadores (1ª geração).
--
-- Regras do Pokegames (configuráveis em pk_cfg()->'battle'):
--   * só duela quem tem pelo menos 3 Pokémon capturados (min_captured);
--   * cada lado usa os primeiros Pokémon da equipe, até "size" (padrão 3);
--   * os dois escolhem a ação do turno em segredo; o servidor resolve
--     quando os dois escolheram (ordem: trocas, prioridade, velocidade);
--   * cada turno tem prazo (turn_hours). Quem já escolheu pode reivindicar
--     a vitória se o outro passou do prazo;
--   * a vida e os PP valem só dentro da batalha: no fim, todos voltam
--     inteiros (como num Centro Pokémon);
--   * XP: quem derruba um Pokémon ganha a experiência da 1ª geração para
--     batalhas contra treinador (exp-base x nível / 7 x 1,5), entregue no
--     fim, uma única vez, e só nas primeiras "battles_per_day" do dia.
-- Fórmulas da 1ª geração: dano, crítico pela velocidade-base, bônus de
-- mesmo tipo (STAB), tabela de tipos da Red/Blue, precisão em 256,
-- estágios de atributo, sono, veneno, queimadura, paralisia, congelamento
-- e confusão. Efeitos ainda não programados avisam na batalha.
-- Depende do 16 e do 17. Antes de rodar, faça a cópia de segurança.
-- =====================================================================

create table if not exists public.battles (
  id         uuid primary key default gen_random_uuid(),
  p1         uuid not null references auth.users(id) on delete cascade,   -- quem desafiou
  p2         uuid not null references auth.users(id) on delete cascade,
  status     text not null default 'convite' check (status in ('convite','ativa','encerrada','recusada','cancelada')),
  size       int not null default 3,
  turn       int not null default 0,
  phase      text not null default 'normal' check (phase in ('normal','troca')),
  ready1     boolean not null default false,
  ready2     boolean not null default false,
  deadline   timestamptz,
  state      jsonb,
  log        jsonb not null default '[]'::jsonb,
  winner     uuid,
  end_reason text,
  rewarded   boolean not null default false,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  ended_at   timestamptz,
  check (p1 <> p2)
);
create index if not exists battles_p1 on public.battles (p1, status);
create index if not exists battles_p2 on public.battles (p2, status);

-- ação escolhida em cada turno: cada jogador só vê a sua
create table if not exists public.battle_actions (
  battle_id  uuid not null references public.battles(id) on delete cascade,
  turn       int not null,
  side       int not null check (side in (0, 1)),
  user_id    uuid not null,
  kind       text not null check (kind in ('move','switch','forced')),
  value      int,
  created_at timestamptz not null default now(),
  primary key (battle_id, turn, side)
);

alter table public.battles enable row level security;
alter table public.battle_actions enable row level security;
drop policy if exists p_bat on public.battles;        create policy p_bat on public.battles for select to authenticated using (auth.uid() in (p1, p2) or public.is_admin());
drop policy if exists p_bac on public.battle_actions; create policy p_bac on public.battle_actions for select to authenticated using (user_id = auth.uid());
revoke all on public.battles, public.battle_actions from anon, authenticated;
grant select on public.battles, public.battle_actions to authenticated;
do $$ begin
  begin alter publication supabase_realtime add table public.battles; exception when duplicate_object then null; end;
end $$;

-- ---------- utilidades do motor ----------
create or replace function public.bt_stage(_s int) returns numeric
language sql immutable as $$
  select case greatest(-6, least(6, coalesce(_s, 0)))
    when -6 then 0.25 when -5 then 0.28 when -4 then 0.33 when -3 then 0.40 when -2 then 0.50 when -1 then 0.66
    when 0 then 1 when 1 then 1.5 when 2 then 2 when 3 then 2.5 when 4 then 3 when 5 then 3.5 else 4 end
$$;
create or replace function public.bt_physical(_type text) returns boolean
language sql immutable as $$ select _type in ('NORMAL','LUTA','VOADOR','VENENO','TERRA','PEDRA','INSETO','FANTASMA') $$;
create or replace function public.bt_eff(_type text, _t1 text, _t2 text) returns numeric
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((select mult from pk_type_chart where atk = _type and def = _t1), 1)
       * case when _t2 is null or _t2 = _t1 then 1 else coalesce((select mult from pk_type_chart where atk = _type and def = _t2), 1) end
$$;
create or replace function public.bt_speed(_m jsonb) returns numeric
language sql immutable as $$
  select (_m->>'spd')::int * public.bt_stage((_m->'st'->>'spd')::int) * case when _m->>'status' = 'PAR' then 0.25 else 1 end
$$;

-- monta o Pokémon de batalha a partir do Pokémon guardado (vida cheia)
create or replace function public.bt_mon(_id uuid) returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'id', m.id, 'species', m.species_id, 'name', p.name, 'level', m.level, 't1', p.g1_type1, 't2', p.g1_type2, 'outfit', m.outfit,
    'maxhp', public.pk_stat(p.base_hp, public.pk_hp_dv(m.dv_atk, m.dv_def, m.dv_spd, m.dv_spc), m.level, true),
    'hp',    public.pk_stat(p.base_hp, public.pk_hp_dv(m.dv_atk, m.dv_def, m.dv_spd, m.dv_spc), m.level, true),
    'atk', public.pk_stat(p.base_atk, m.dv_atk, m.level, false), 'def', public.pk_stat(p.base_def, m.dv_def, m.level, false),
    'spd', public.pk_stat(p.base_spd, m.dv_spd, m.level, false), 'spc', public.pk_stat(p.base_spc, m.dv_spc, m.level, false),
    'bspd', p.base_spd, 'bexp', p.base_exp,
    'moves', (select jsonb_agg(jsonb_build_object('id', mv.id, 'pp', mv.pp, 'max', mv.pp) order by u.ord) from unnest(m.moves) with ordinality u(mid, ord) join pk_moves mv on mv.id = u.mid),
    'status', null, 'sleep', 0, 'conf', 0, 'st', '{"atk":0,"def":0,"spd":0,"spc":0,"acc":0,"eva":0}'::jsonb, 'fl', '{}'::jsonb, 'last', null)
  from monsters m join pokemon p on p.id = m.species_id where m.id = _id
$$;

-- ---------- convite, resposta e desistência ----------
create or replace function public.battle_challenge(_opponent uuid) returns public.battles
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.pk_cfg()->'battle'; b battles; nm text;
begin
  if _opponent = uid then raise exception 'Você não pode batalhar contra você mesmo.'; end if;
  if not exists (select 1 from characters where user_id = _opponent) then raise exception 'Jogador não encontrado.'; end if;
  if (select count(*) from monsters where user_id = uid) < (c->>'min_captured')::int then
    raise exception 'Você precisa de pelo menos % Pokémon capturados para batalhar.', c->>'min_captured'; end if;
  if (select count(*) from monsters where user_id = _opponent) < (c->>'min_captured')::int then
    raise exception 'Esse jogador ainda não tem % Pokémon capturados.', c->>'min_captured'; end if;
  if not exists (select 1 from monsters where user_id = uid and team_slot is not null) then raise exception 'Monte sua equipe antes de desafiar alguém.'; end if;
  if exists (select 1 from battles where status in ('convite','ativa') and ((p1 = uid and p2 = _opponent) or (p1 = _opponent and p2 = uid))) then
    raise exception 'Já existe uma batalha aberta entre vocês.'; end if;
  insert into battles(p1, p2, size) values (uid, _opponent, (c->>'size')::int) returning * into b;
  select name into nm from characters where user_id = uid;
  insert into event_log(user_id, kind, message) select uid, 'batalha', nm || ' desafiou ' || ch.name || ' para uma batalha Pokémon!' from characters ch where ch.user_id = _opponent;
  return b;
end $$;

create or replace function public.battle_respond(_id uuid, _accept boolean) returns public.battles
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); b battles; c jsonb := public.pk_cfg()->'battle'; s1 jsonb; s2 jsonb;
begin
  select * into b from battles where id = _id for update;
  if b.id is null or b.p2 <> uid then raise exception 'Convite não encontrado.'; end if;
  if b.status <> 'convite' then raise exception 'Esse convite já foi respondido.'; end if;
  if not _accept then update battles set status = 'recusada', ended_at = now() where id = b.id returning * into b; return b; end if;
  if (select count(*) from monsters where user_id = uid) < (c->>'min_captured')::int then
    raise exception 'Você precisa de pelo menos % Pokémon capturados para batalhar.', c->>'min_captured'; end if;
  if not exists (select 1 from monsters where user_id = uid and team_slot is not null) then raise exception 'Monte sua equipe antes de aceitar.'; end if;
  if not exists (select 1 from monsters where user_id = b.p1 and team_slot is not null) then raise exception 'O desafiante está sem equipe agora.'; end if;
  select jsonb_build_object('user', b.p1, 'name', (select name from characters where user_id = b.p1), 'active', 0, 'need_switch', false,
         'mons', jsonb_agg(public.bt_mon(m.id) order by m.team_slot)) into s1
    from (select id, team_slot from monsters where user_id = b.p1 and team_slot is not null order by team_slot limit b.size) m;
  select jsonb_build_object('user', b.p2, 'name', (select name from characters where user_id = b.p2), 'active', 0, 'need_switch', false,
         'mons', jsonb_agg(public.bt_mon(m.id) order by m.team_slot)) into s2
    from (select id, team_slot from monsters where user_id = b.p2 and team_slot is not null order by team_slot limit b.size) m;
  update battles set status = 'ativa', turn = 1, phase = 'normal', started_at = now(),
         deadline = now() + make_interval(hours => (c->>'turn_hours')::int),
         state = jsonb_build_object('sides', jsonb_build_array(s1, s2), 'xp', '{}'::jsonb),
         log = jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
                 jsonb_build_object('txt', (s1->>'name') || ' mandou ' || (s1->'mons'->0->>'name') || '!'),
                 jsonb_build_object('txt', (s2->>'name') || ' mandou ' || (s2->'mons'->0->>'name') || '!'))))
   where id = b.id returning * into b;
  return b;
end $$;

create or replace function public.battle_cancel(_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active();
begin
  update battles set status = 'cancelada', ended_at = now() where id = _id and p1 = uid and status = 'convite';
  if not found then raise exception 'Só dá para cancelar um convite seu que ainda não foi aceito.'; end if;
end $$;

-- ---------- encerramento e recompensa (uma única vez) ----------
create or replace function public.bt_finish(_id uuid, _winner uuid, _reason text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b battles; c jsonb := public.pk_cfg(); k text; v int; owner uuid; limit_n int := (c->'xp'->>'battles_per_day')::int; wn text; ln text;
begin
  select * into b from battles where id = _id for update;
  if b.status <> 'ativa' then return; end if;
  update battles set status = 'encerrada', winner = _winner, end_reason = _reason, ended_at = now(), deadline = null where id = b.id;
  if b.rewarded then return; end if;
  -- XP dos Pokémon que derrubaram adversários, só nas primeiras batalhas do dia de cada dono
  for k, v in select key, value::int from jsonb_each_text(coalesce(b.state->'xp', '{}'::jsonb)) loop
    select user_id into owner from monsters where id = k::uuid;
    if owner is null then continue; end if;
    if (select count(*) from battles x where x.status = 'encerrada' and x.rewarded and owner in (x.p1, x.p2)
          and (x.ended_at at time zone coalesce(public.cfg()->>'timezone','America/Sao_Paulo'))::date = public.game_today()) >= limit_n then continue; end if;
    perform public.pk_give_xp(k::uuid, v, 'batalha');
  end loop;
  update battles set rewarded = true where id = b.id;
  select name into wn from characters where user_id = _winner;
  select name into ln from characters where user_id = case when _winner = b.p1 then b.p2 else b.p1 end;
  if _winner is not null then insert into event_log(user_id, kind, message) values (_winner, 'batalha', wn || ' venceu a batalha Pokémon contra ' || ln || '!'); end if;
end $$;

-- ---------- motor: um ataque ----------
-- Recebe o estado inteiro e devolve o novo estado; as linhas do relato vão em "_lines".
create or replace function public.bt_use_move(_s jsonb, _a int, _mid int, _first boolean, _depth int default 0) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare ds int := 1 - _a; A jsonb := _s->'sides'->_a->'mons'->((_s->'sides'->_a->>'active')::int); D jsonb := _s->'sides'->ds->'mons'->((_s->'sides'->ds->>'active')::int);
  mv pk_moves; eff numeric; crit boolean; hits int := 1; dmg int; total int := 0; i int; t int; acc numeric; lvl int; vatk numeric; vdef numeric; base int;
  phys boolean; chance int; st text; delta int; key text; target jsonb; tgt int; heal int; nm text := A->>'name'; dn text := D->>'name';
  ai int := (_s->'sides'->_a->>'active')::int; di int := (_s->'sides'->ds->>'active')::int; stab boolean; _lines jsonb := coalesce(_s->'_lines', '[]'::jsonb);
begin
  select * into mv from pk_moves where id = _mid;
  -- golpes que chamam outros
  if mv.effect = 'METRONOME_EFFECT' and _depth = 0 then
    select id into t from pk_moves where id not in (118, 165) order by random() limit 1;
    _lines := _lines || jsonb_build_object('txt', nm || ' usou Metronome!');
    return public.bt_use_move(jsonb_set(_s, '{_lines}', _lines), _a, t, _first, 1);
  end if;
  if mv.effect = 'MIRROR_MOVE_EFFECT' and _depth = 0 then
    if D->>'last' is null or (D->>'last')::int = 119 then _lines := _lines || jsonb_build_object('txt', nm || ' usou Mirror Move, mas falhou!'); return jsonb_set(_s, '{_lines}', _lines); end if;
    _lines := _lines || jsonb_build_object('txt', nm || ' usou Mirror Move!');
    return public.bt_use_move(jsonb_set(_s, '{_lines}', _lines), _a, (D->>'last')::int, _first, 1);
  end if;
  _lines := _lines || jsonb_build_object('txt', nm || ' usou ' || mv.name || '!', 'side', _a, 'move', mv.id, 'mtype', mv.type);
  A := jsonb_set(A, '{last}', to_jsonb(mv.id));
  -- primeiro turno dos ataques de dois turnos
  if mv.effect in ('CHARGE_EFFECT','FLY_EFFECT') and coalesce(A->'fl'->>'charging', '') = '' then
    A := jsonb_set(A, '{fl,charging}', to_jsonb(mv.id));
    if mv.effect = 'FLY_EFFECT' then A := jsonb_set(A, '{fl,invul}', 'true'); end if;
    _lines := _lines || jsonb_build_object('txt', nm || ' está se preparando…');
    return jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{_lines}', _lines);
  end if;
  A := A #- '{fl,charging}'; A := A #- '{fl,invul}';
  -- efeitos que ainda não existem no Pokegames
  if mv.effect in ('TRANSFORM_EFFECT','MIMIC_EFFECT','DISABLE_EFFECT','CONVERSION_EFFECT','BIDE_EFFECT','SUBSTITUTE_EFFECT') or mv.id = 68 then
    _lines := _lines || jsonb_build_object('txt', 'Esse ataque ainda não funciona no Pokegames: não aconteceu nada.');
    return jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{_lines}', _lines);
  end if;
  if mv.effect in ('SWITCH_AND_TELEPORT_EFFECT','SPLASH_EFFECT') then
    _lines := _lines || jsonb_build_object('txt', 'Mas não aconteceu nada!');
    return jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{_lines}', _lines);
  end if;
  -- precisão (1ª geração: sorteio de 0 a 255, então até 100% erra 1 vez em 256)
  if mv.effect <> 'SWIFT_EFFECT' and mv.accuracy > 0 and not (mv.power = 0 and mv.effect in ('HEAL_EFFECT','FOCUS_ENERGY_EFFECT','REFLECT_EFFECT','LIGHT_SCREEN_EFFECT','MIST_EFFECT','HAZE_EFFECT')
       or mv.effect like '%\_UP1\_EFFECT' or mv.effect like '%\_UP2\_EFFECT') then
    acc := floor(mv.accuracy * 255 / 100.0) * public.bt_stage((A->'st'->>'acc')::int) / public.bt_stage((D->'st'->>'eva')::int);
    if coalesce((D->'fl'->>'invul')::boolean, false) or floor(random() * 256) >= least(255, acc)
       or (mv.effect = 'OHKO_EFFECT' and public.bt_speed(A) < public.bt_speed(D))
       or (mv.effect = 'DREAM_EATER_EFFECT' and coalesce(D->>'status', '') <> 'SLP') then
      _lines := _lines || jsonb_build_object('txt', 'O ataque de ' || nm || ' errou!');
      if mv.effect = 'JUMP_KICK_EFFECT' then
        A := jsonb_set(A, '{hp}', to_jsonb(greatest(0, (A->>'hp')::int - 1)));
        _lines := _lines || jsonb_build_object('txt', nm || ' caiu e se machucou!', 'side', _a, 'hp', (A->>'hp')::int);
      end if;
      return jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{_lines}', _lines);
    end if;
  end if;

  if mv.power > 0 or mv.effect in ('SPECIAL_DAMAGE_EFFECT','SUPER_FANG_EFFECT','OHKO_EFFECT') then
    eff := public.bt_eff(mv.type, D->>'t1', D->>'t2');
    if eff = 0 and mv.effect not in ('SPECIAL_DAMAGE_EFFECT','SUPER_FANG_EFFECT') then
      _lines := _lines || jsonb_build_object('txt', 'Não afeta ' || dn || '…');
      return jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{_lines}', _lines);
    end if;
    if mv.effect = 'TWO_TO_FIVE_ATTACKS_EFFECT' then t := floor(random() * 8); hits := case when t < 3 then 2 when t < 6 then 3 when t < 7 then 4 else 5 end;
    elsif mv.effect in ('ATTACK_TWICE_EFFECT','TWINEEDLE_EFFECT') then hits := 2; end if;
    -- crítico pela velocidade-base (golpes de crítico alto x8; Focus Energy reduz, como o defeito original)
    base := floor((A->>'bspd')::int / 2);
    if mv.code in ('KARATE_CHOP','RAZOR_LEAF','CRABHAMMER','SLASH') then base := least(255, base * 8); end if;
    if coalesce((A->'fl'->>'focus')::boolean, false) then base := floor(base / 4); end if;
    crit := mv.effect not in ('SPECIAL_DAMAGE_EFFECT','SUPER_FANG_EFFECT','OHKO_EFFECT') and floor(random() * 256) < base;
    for i in 1 .. hits loop
      if mv.effect = 'OHKO_EFFECT' then dmg := (D->>'hp')::int;
      elsif mv.effect = 'SUPER_FANG_EFFECT' then dmg := greatest(1, (D->>'hp')::int / 2);
      elsif mv.effect = 'SPECIAL_DAMAGE_EFFECT' then
        dmg := case mv.code when 'SONICBOOM' then 20 when 'DRAGON_RAGE' then 40 when 'PSYWAVE' then 1 + floor(random() * floor((A->>'level')::int * 1.5))::int
               else (A->>'level')::int end;
      else
        phys := public.bt_physical(mv.type); lvl := (A->>'level')::int * case when crit then 2 else 1 end;
        if phys then
          vatk := (A->>'atk')::int * case when crit then 1 else public.bt_stage((A->'st'->>'atk')::int) end;
          if A->>'status' = 'BRN' and not crit then vatk := vatk / 2; end if;
          vdef := (D->>'def')::int * case when crit then 1 else public.bt_stage((D->'st'->>'def')::int) end;
          if coalesce((D->'fl'->>'reflect')::boolean, false) and not crit then vdef := vdef * 2; end if;
        else
          vatk := (A->>'spc')::int * case when crit then 1 else public.bt_stage((A->'st'->>'spc')::int) end;
          vdef := (D->>'spc')::int * case when crit then 1 else public.bt_stage((D->'st'->>'spc')::int) end;
          if coalesce((D->'fl'->>'light')::boolean, false) and not crit then vdef := vdef * 2; end if;
        end if;
        vatk := greatest(1, floor(vatk)); vdef := greatest(1, floor(vdef));
        if mv.effect = 'EXPLODE_EFFECT' then vdef := greatest(1, floor(vdef / 2)); end if;
        if vatk > 255 or vdef > 255 then vatk := greatest(1, floor(vatk / 4)); vdef := greatest(1, floor(vdef / 4)); end if;
        dmg := least(997, floor(floor(floor(2 * lvl / 5 + 2) * vatk * mv.power / vdef) / 50)::int) + 2;
        stab := mv.type in (A->>'t1', coalesce(A->>'t2', ''));
        if stab then dmg := dmg + dmg / 2; end if;
        dmg := floor(dmg * coalesce((select mult from pk_type_chart where atk = mv.type and def = D->>'t1'), 1))::int;
        if D->>'t2' is not null and D->>'t2' <> D->>'t1' then dmg := floor(dmg * coalesce((select mult from pk_type_chart where atk = mv.type and def = D->>'t2'), 1))::int; end if;
        if dmg > 1 then dmg := floor(dmg * (217 + floor(random() * 39)) / 255)::int; end if;
        dmg := greatest(1, dmg);
      end if;
      dmg := least(dmg, (D->>'hp')::int);
      D := jsonb_set(D, '{hp}', to_jsonb((D->>'hp')::int - dmg));
      total := total + dmg;
      _lines := _lines || jsonb_build_object('txt', case when hits > 1 then 'Acertou! ' else '' end || dn || ' perdeu ' || dmg || ' de vida.', 'side', ds, 'hp', (D->>'hp')::int, 'dmg', dmg);
      exit when (D->>'hp')::int <= 0;
    end loop;
    if hits > 1 then _lines := _lines || jsonb_build_object('txt', 'Acertou ' || least(i, hits) || ' vezes!'); end if;
    if crit then _lines := _lines || jsonb_build_object('txt', 'Acerto crítico!'); end if;
    if mv.effect not in ('SPECIAL_DAMAGE_EFFECT','SUPER_FANG_EFFECT','OHKO_EFFECT') then
      if eff > 1 then _lines := _lines || jsonb_build_object('txt', 'É super eficaz!');
      elsif eff < 1 then _lines := _lines || jsonb_build_object('txt', 'Não é muito eficaz…'); end if;
    end if;
    if mv.effect = 'OHKO_EFFECT' then _lines := _lines || jsonb_build_object('txt', 'Nocaute de um golpe só!'); end if;
    -- congelado acertado por fogo descongela
    if mv.type = 'FOGO' and D->>'status' = 'FRZ' then D := jsonb_set(D, '{status}', 'null'); _lines := _lines || jsonb_build_object('txt', dn || ' descongelou!'); end if;
    -- recuo, dreno e explosão
    if mv.effect = 'RECOIL_EFFECT' then
      heal := greatest(1, total / case when mv.code = 'STRUGGLE' then 2 else 4 end);
      A := jsonb_set(A, '{hp}', to_jsonb(greatest(0, (A->>'hp')::int - heal)));
      _lines := _lines || jsonb_build_object('txt', nm || ' sofreu o impacto do próprio golpe.', 'side', _a, 'hp', (A->>'hp')::int);
    elsif mv.effect in ('DRAIN_HP_EFFECT','DREAM_EATER_EFFECT') then
      heal := greatest(1, total / 2);
      A := jsonb_set(A, '{hp}', to_jsonb(least((A->>'maxhp')::int, (A->>'hp')::int + heal)));
      _lines := _lines || jsonb_build_object('txt', dn || ' teve a energia sugada!', 'side', _a, 'hp', (A->>'hp')::int);
    elsif mv.effect = 'EXPLODE_EFFECT' then
      A := jsonb_set(A, '{hp}', '0');
      _lines := _lines || jsonb_build_object('txt', nm || ' explodiu!', 'side', _a, 'hp', 0);
    elsif mv.effect = 'HYPER_BEAM_EFFECT' and (D->>'hp')::int > 0 then
      A := jsonb_set(A, '{fl,recharge}', 'true');
    end if;
    -- efeitos secundários (chances da 1ª geração, em 256)
    if (D->>'hp')::int > 0 then
      chance := case mv.effect
        when 'BURN_SIDE_EFFECT1' then 26 when 'BURN_SIDE_EFFECT2' then 77 when 'FREEZE_SIDE_EFFECT1' then 26 when 'PARALYZE_SIDE_EFFECT1' then 26
        when 'PARALYZE_SIDE_EFFECT2' then 77 when 'POISON_SIDE_EFFECT1' then 52 when 'POISON_SIDE_EFFECT2' then 103 when 'TWINEEDLE_EFFECT' then 52
        when 'FLINCH_SIDE_EFFECT1' then 26 when 'FLINCH_SIDE_EFFECT2' then 77 when 'CONFUSION_SIDE_EFFECT' then 26
        when 'ATTACK_DOWN_SIDE_EFFECT' then 85 when 'DEFENSE_DOWN_SIDE_EFFECT' then 85 when 'SPEED_DOWN_SIDE_EFFECT' then 85 when 'SPECIAL_DOWN_SIDE_EFFECT' then 85
        else 0 end;
      if chance > 0 and floor(random() * 256) < chance then
        st := case when mv.effect like 'BURN%' then 'BRN' when mv.effect like 'FREEZE%' then 'FRZ' when mv.effect like 'PARALYZE%' then 'PAR'
                   when mv.effect like 'POISON%' or mv.effect = 'TWINEEDLE_EFFECT' then 'PSN' end;
        if st is not null then
          -- a 1ª geração não aplica o estado se o alvo for do mesmo tipo do golpe
          if D->>'status' is null and mv.type not in (D->>'t1', coalesce(D->>'t2', '')) then
            D := jsonb_set(D, '{status}', to_jsonb(st));
            _lines := _lines || jsonb_build_object('txt', dn || case st when 'BRN' then ' foi queimado!' when 'FRZ' then ' congelou!' when 'PAR' then ' ficou paralisado!' else ' foi envenenado!' end, 'side', ds, 'status', st);
          end if;
        elsif mv.effect like 'FLINCH%' then
          if _first then D := jsonb_set(D, '{fl,flinch}', 'true'); end if;
        elsif mv.effect = 'CONFUSION_SIDE_EFFECT' then
          if (D->>'conf')::int = 0 then D := jsonb_set(D, '{conf}', to_jsonb(2 + floor(random() * 4)::int)); _lines := _lines || jsonb_build_object('txt', dn || ' ficou confuso!'); end if;
        elsif not coalesce((D->'fl'->>'mist')::boolean, false) then
          key := case when mv.effect like 'ATTACK%' then 'atk' when mv.effect like 'DEFENSE%' then 'def' when mv.effect like 'SPEED%' then 'spd' else 'spc' end;
          if (D->'st'->>key)::int > -6 then
            D := jsonb_set(D, array['st', key], to_jsonb((D->'st'->>key)::int - 1));
            _lines := _lines || jsonb_build_object('txt', case key when 'atk' then 'O ataque' when 'def' then 'A defesa' when 'spd' then 'A velocidade' else 'O especial' end || ' de ' || dn || ' caiu!');
          end if;
        end if;
      end if;
    end if;
  else
    -- ataques sem dano
    if mv.effect = 'SLEEP_EFFECT' then
      if D->>'status' is not null then _lines := _lines || jsonb_build_object('txt', 'Mas falhou!');
      else D := jsonb_set(jsonb_set(D, '{status}', '"SLP"'), '{sleep}', to_jsonb(1 + floor(random() * 7)::int)); _lines := _lines || jsonb_build_object('txt', dn || ' adormeceu!', 'side', ds, 'status', 'SLP'); end if;
    elsif mv.effect = 'POISON_EFFECT' then
      if D->>'status' is not null or 'VENENO' in (D->>'t1', coalesce(D->>'t2', '')) then _lines := _lines || jsonb_build_object('txt', 'Mas falhou!');
      else D := jsonb_set(D, '{status}', '"PSN"'); _lines := _lines || jsonb_build_object('txt', dn || ' foi envenenado!', 'side', ds, 'status', 'PSN'); end if;
    elsif mv.effect = 'PARALYZE_EFFECT' then
      if D->>'status' is not null or (mv.type = 'ELETRICO' and public.bt_eff('ELETRICO', D->>'t1', D->>'t2') = 0) then _lines := _lines || jsonb_build_object('txt', 'Mas falhou!');
      else D := jsonb_set(D, '{status}', '"PAR"'); _lines := _lines || jsonb_build_object('txt', dn || ' ficou paralisado! Talvez não consiga se mover.', 'side', ds, 'status', 'PAR'); end if;
    elsif mv.effect = 'CONFUSION_EFFECT' then
      if (D->>'conf')::int > 0 then _lines := _lines || jsonb_build_object('txt', 'Mas falhou!');
      else D := jsonb_set(D, '{conf}', to_jsonb(2 + floor(random() * 4)::int)); _lines := _lines || jsonb_build_object('txt', dn || ' ficou confuso!'); end if;
    elsif mv.effect like '%\_UP1\_EFFECT' or mv.effect like '%\_UP2\_EFFECT' or mv.effect like '%\_DOWN1\_EFFECT' or mv.effect like '%\_DOWN2\_EFFECT' then
      key := case when mv.effect like 'ATTACK%' then 'atk' when mv.effect like 'DEFENSE%' then 'def' when mv.effect like 'SPEED%' then 'spd'
                  when mv.effect like 'SPECIAL%' then 'spc' when mv.effect like 'ACCURACY%' then 'acc' else 'eva' end;
      delta := case when mv.effect like '%UP2%' then 2 when mv.effect like '%UP1%' then 1 when mv.effect like '%DOWN2%' then -2 else -1 end;
      if delta > 0 then tgt := _a; target := A; else tgt := ds; target := D; end if;
      if delta < 0 and coalesce((D->'fl'->>'mist')::boolean, false) then _lines := _lines || jsonb_build_object('txt', dn || ' está protegido pela névoa!');
      elsif (delta > 0 and (target->'st'->>key)::int >= 6) or (delta < 0 and (target->'st'->>key)::int <= -6) then _lines := _lines || jsonb_build_object('txt', 'Nada aconteceu!');
      else
        target := jsonb_set(target, array['st', key], to_jsonb(greatest(-6, least(6, (target->'st'->>key)::int + delta))));
        _lines := _lines || jsonb_build_object('txt', case key when 'atk' then 'O ataque' when 'def' then 'A defesa' when 'spd' then 'A velocidade'
            when 'spc' then 'O especial' when 'acc' then 'A precisão' else 'A evasão' end || ' de ' || (target->>'name') || case when delta > 0 then ' subiu' else ' caiu' end || case when abs(delta) > 1 then ' muito!' else '!' end);
        if tgt = _a then A := target; else D := target; end if;
      end if;
    elsif mv.effect = 'HEAL_EFFECT' then
      if (A->>'hp')::int >= (A->>'maxhp')::int then _lines := _lines || jsonb_build_object('txt', 'Mas falhou!');
      elsif mv.code = 'REST' then
        A := jsonb_set(jsonb_set(jsonb_set(A, '{hp}', to_jsonb((A->>'maxhp')::int)), '{status}', '"SLP"'), '{sleep}', '2');
        _lines := _lines || jsonb_build_object('txt', nm || ' dormiu e recuperou toda a vida!', 'side', _a, 'hp', (A->>'hp')::int, 'status', 'SLP');
      else
        A := jsonb_set(A, '{hp}', to_jsonb(least((A->>'maxhp')::int, (A->>'hp')::int + (A->>'maxhp')::int / 2)));
        _lines := _lines || jsonb_build_object('txt', nm || ' recuperou vida!', 'side', _a, 'hp', (A->>'hp')::int);
      end if;
    elsif mv.effect = 'FOCUS_ENERGY_EFFECT' then A := jsonb_set(A, '{fl,focus}', 'true'); _lines := _lines || jsonb_build_object('txt', nm || ' está concentrado!');
    elsif mv.effect = 'REFLECT_EFFECT' then A := jsonb_set(A, '{fl,reflect}', 'true'); _lines := _lines || jsonb_build_object('txt', nm || ' ficou mais resistente a golpes físicos!');
    elsif mv.effect = 'LIGHT_SCREEN_EFFECT' then A := jsonb_set(A, '{fl,light}', 'true'); _lines := _lines || jsonb_build_object('txt', nm || ' ficou mais resistente a golpes especiais!');
    elsif mv.effect = 'MIST_EFFECT' then A := jsonb_set(A, '{fl,mist}', 'true'); _lines := _lines || jsonb_build_object('txt', nm || ' se cobriu de névoa!');
    elsif mv.effect = 'HAZE_EFFECT' then
      A := jsonb_set(A, '{st}', '{"atk":0,"def":0,"spd":0,"spc":0,"acc":0,"eva":0}'); D := jsonb_set(D, '{st}', '{"atk":0,"def":0,"spd":0,"spc":0,"acc":0,"eva":0}');
      A := jsonb_set(A, '{conf}', '0'); D := jsonb_set(jsonb_set(D, '{conf}', '0'), '{status}', 'null'); D := D #- '{fl,leech}'; A := A #- '{fl,leech}';
      _lines := _lines || jsonb_build_object('txt', 'Todas as mudanças de atributos foram desfeitas!', 'side', ds, 'status', null);
    elsif mv.effect = 'LEECH_SEED_EFFECT' then
      if 'PLANTA' in (D->>'t1', coalesce(D->>'t2', '')) or coalesce((D->'fl'->>'leech')::boolean, false) then _lines := _lines || jsonb_build_object('txt', 'Mas falhou!');
      else D := jsonb_set(D, '{fl,leech}', 'true'); _lines := _lines || jsonb_build_object('txt', dn || ' foi semeado!'); end if;
    else
      _lines := _lines || jsonb_build_object('txt', 'Mas não aconteceu nada!');
    end if;
  end if;
  _s := jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A);
  _s := jsonb_set(_s, array['sides', ds::text, 'mons', di::text], D);
  return jsonb_set(_s, '{_lines}', _lines);
end $$;

-- antes de agir: sono, congelamento, recarga, paralisia, susto e confusão
create or replace function public.bt_can_act(_s jsonb, _a int) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare ai int := (_s->'sides'->_a->>'active')::int; A jsonb := _s->'sides'->_a->'mons'->ai; nm text := A->>'name'; dmg int; vatk numeric; vdef numeric; _lines jsonb := coalesce(_s->'_lines', '[]'::jsonb);
begin
  A := jsonb_set(A, '{fl,acted}', 'true');
  if coalesce((A->'fl'->>'recharge')::boolean, false) then
    A := A #- '{fl,recharge}'; _lines := _lines || jsonb_build_object('txt', nm || ' precisa recarregar!');
    return jsonb_set(jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{blocked}', 'true'), '{_lines}', _lines);
  end if;
  if A->>'status' = 'SLP' then
    A := jsonb_set(A, '{sleep}', to_jsonb((A->>'sleep')::int - 1));
    if (A->>'sleep')::int <= 0 then A := jsonb_set(A, '{status}', 'null'); _lines := _lines || jsonb_build_object('txt', nm || ' acordou!', 'side', _a, 'status', null);
    else _lines := _lines || jsonb_build_object('txt', nm || ' está dormindo.'); end if;
    return jsonb_set(jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{blocked}', 'true'), '{_lines}', _lines);
  end if;
  if A->>'status' = 'FRZ' then
    _lines := _lines || jsonb_build_object('txt', nm || ' está congelado e não se mexe!');
    return jsonb_set(jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{blocked}', 'true'), '{_lines}', _lines);
  end if;
  if coalesce((A->'fl'->>'flinch')::boolean, false) then
    A := A #- '{fl,flinch}'; _lines := _lines || jsonb_build_object('txt', nm || ' se assustou e não atacou!');
    return jsonb_set(jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{blocked}', 'true'), '{_lines}', _lines);
  end if;
  if (A->>'conf')::int > 0 then
    A := jsonb_set(A, '{conf}', to_jsonb((A->>'conf')::int - 1));
    if (A->>'conf')::int = 0 then _lines := _lines || jsonb_build_object('txt', nm || ' não está mais confuso!');
    else
      _lines := _lines || jsonb_build_object('txt', nm || ' está confuso…');
      if random() < 0.5 then
        vatk := greatest(1, (A->>'atk')::int * public.bt_stage((A->'st'->>'atk')::int)); vdef := greatest(1, (A->>'def')::int * public.bt_stage((A->'st'->>'def')::int));
        dmg := least((A->>'hp')::int, floor(floor(floor(2 * (A->>'level')::int / 5 + 2) * vatk * 40 / vdef) / 50)::int + 2);
        A := jsonb_set(A, '{hp}', to_jsonb((A->>'hp')::int - dmg));
        _lines := _lines || jsonb_build_object('txt', 'Ele se machucou na confusão!', 'side', _a, 'hp', (A->>'hp')::int, 'dmg', dmg);
        return jsonb_set(jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{blocked}', 'true'), '{_lines}', _lines);
      end if;
    end if;
  end if;
  if A->>'status' = 'PAR' and random() < 0.25 then
    _lines := _lines || jsonb_build_object('txt', nm || ' está totalmente paralisado!');
    return jsonb_set(jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{blocked}', 'true'), '{_lines}', _lines);
  end if;
  return jsonb_set(jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{blocked}', 'false'), '{_lines}', _lines);
end $$;

-- ---------- motor: resolve um turno ----------
create or replace function public.bt_resolve(_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare b battles; s jsonb; lines jsonb := '[]'::jsonb; act record; acts jsonb := '{}'::jsonb; order_ int[]; side int; ds int; A jsonb; D jsonb; ai int;
  mid int; slot int; pr0 int; pr1 int; sp0 numeric; sp1 numeric; alive0 int; alive1 int; i int; m jsonb; dmg int; xp int; winner uuid; reason text;
  c jsonb := public.pk_cfg(); first_done boolean := false; nm text;
begin
  select * into b from battles where id = _id for update;
  s := b.state;
  for act in select * from battle_actions where battle_id = b.id and turn = b.turn loop
    acts := acts || jsonb_build_object(act.side::text, jsonb_build_object('kind', act.kind, 'value', act.value));
  end loop;
  -- trocas primeiro (inclusive as trocas obrigatórias depois de um nocaute)
  for side in 0 .. 1 loop
    if acts->side::text->>'kind' = 'switch' then
      ai := (s->'sides'->side->>'active')::int; A := s->'sides'->side->'mons'->ai;
      if (A->>'hp')::int > 0 then lines := lines || jsonb_build_object('txt', (s->'sides'->side->>'name') || ' chamou ' || (A->>'name') || ' de volta.'); end if;
      -- ao sair, perde mudanças de atributo, confusão, semente, tela e preparo
      A := jsonb_set(jsonb_set(A, '{st}', '{"atk":0,"def":0,"spd":0,"spc":0,"acc":0,"eva":0}'), '{conf}', '0');
      A := jsonb_set(A, '{fl}', '{}');
      s := jsonb_set(s, array['sides', side::text, 'mons', ai::text], A);
      s := jsonb_set(s, array['sides', side::text, 'active'], to_jsonb((acts->side::text->>'value')::int));
      s := jsonb_set(s, array['sides', side::text, 'need_switch'], 'false');
      lines := lines || jsonb_build_object('txt', (s->'sides'->side->>'name') || ' mandou ' || (s->'sides'->side->'mons'->((acts->side::text->>'value')::int)->>'name') || '!', 'side', side, 'switch', (acts->side::text->>'value')::int);
    end if;
  end loop;
  if b.phase = 'troca' then
    update battles set state = s, phase = 'normal', turn = turn + 1, ready1 = false, ready2 = false,
           deadline = now() + make_interval(hours => (c->'battle'->>'turn_hours')::int),
           log = log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', lines)) where id = b.id;
    return;
  end if;
  -- ordem dos ataques: prioridade (Quick Attack) e velocidade
  pr0 := case when acts->'0'->>'kind' = 'move' and (select code from pk_moves where id = (s->'sides'->0->'mons'->((s->'sides'->0->>'active')::int)->'moves'->((acts->'0'->>'value')::int)->>'id')::int) = 'QUICK_ATTACK' then 1 else 0 end;
  pr1 := case when acts->'1'->>'kind' = 'move' and (select code from pk_moves where id = (s->'sides'->1->'mons'->((s->'sides'->1->>'active')::int)->'moves'->((acts->'1'->>'value')::int)->>'id')::int) = 'QUICK_ATTACK' then 1 else 0 end;
  sp0 := public.bt_speed(s->'sides'->0->'mons'->((s->'sides'->0->>'active')::int));
  sp1 := public.bt_speed(s->'sides'->1->'mons'->((s->'sides'->1->>'active')::int));
  order_ := case when pr0 > pr1 or (pr0 = pr1 and (sp0 > sp1 or (sp0 = sp1 and random() < 0.5))) then array[0, 1] else array[1, 0] end;
  foreach side in array order_ loop
    ds := 1 - side;
    continue when acts->side::text->>'kind' = 'switch';
    ai := (s->'sides'->side->>'active')::int; A := s->'sides'->side->'mons'->ai;
    continue when (A->>'hp')::int <= 0;
    continue when (s->'sides'->ds->'mons'->((s->'sides'->ds->>'active')::int)->>'hp')::int <= 0;
    s := public.bt_can_act(jsonb_set(s, '{_lines}', lines), side); lines := s->'_lines'; s := s - '_lines';
    if not (s->>'blocked')::boolean then
      A := s->'sides'->side->'mons'->ai;
      if coalesce(A->'fl'->>'charging', '') <> '' then mid := (A->'fl'->>'charging')::int;   -- segundo turno do ataque de dois turnos
      elsif acts->side::text->>'kind' = 'forced' or (acts->side::text->>'value')::int < 0 then mid := 165;  -- Struggle
      else
        slot := (acts->side::text->>'value')::int; mid := (A->'moves'->slot->>'id')::int;
        s := jsonb_set(s, array['sides', side::text, 'mons', ai::text, 'moves', slot::text, 'pp'], to_jsonb(greatest(0, (A->'moves'->slot->>'pp')::int - 1)));
      end if;
      s := public.bt_use_move(jsonb_set(s, '{_lines}', lines), side, mid, not first_done); lines := s->'_lines'; s := s - '_lines';
    end if;
    s := s - 'blocked';
    first_done := true;
    -- nocautes depois de cada ação (XP para quem derrubou)
    for i in 0 .. 1 loop
      m := s->'sides'->i->'mons'->((s->'sides'->i->>'active')::int);
      if (m->>'hp')::int <= 0 and not coalesce((m->'fl'->>'fainted')::boolean, false) then
        s := jsonb_set(s, array['sides', i::text, 'mons', (s->'sides'->i->>'active'), 'fl', 'fainted'], 'true');
        lines := lines || jsonb_build_object('txt', (m->>'name') || ' desmaiou!', 'side', i, 'faint', true);
        A := s->'sides'->(1 - i)->'mons'->((s->'sides'->(1 - i)->>'active')::int);
        if (A->>'hp')::int > 0 then
          xp := floor(floor((m->>'bexp')::int * (m->>'level')::int / 7.0) * (c->'xp'->>'battle_mult')::numeric);
          s := jsonb_set(s, array['xp', A->>'id'], to_jsonb(coalesce((s->'xp'->>(A->>'id'))::int, 0) + xp));
        end if;
      end if;
    end loop;
  end loop;
  -- dano no fim do turno: veneno, queimadura e semente (1/16 da vida)
  for side in 0 .. 1 loop
    ai := (s->'sides'->side->>'active')::int; A := s->'sides'->side->'mons'->ai; nm := A->>'name';
    continue when (A->>'hp')::int <= 0;
    A := A #- '{fl,flinch}';
    if A->>'status' in ('PSN','BRN') then
      dmg := greatest(1, (A->>'maxhp')::int / 16); A := jsonb_set(A, '{hp}', to_jsonb(greatest(0, (A->>'hp')::int - dmg)));
      lines := lines || jsonb_build_object('txt', nm || case when A->>'status' = 'PSN' then ' sofre com o veneno.' else ' sofre com a queimadura.' end, 'side', side, 'hp', (A->>'hp')::int);
    end if;
    if coalesce((A->'fl'->>'leech')::boolean, false) and (A->>'hp')::int > 0 then
      dmg := least((A->>'hp')::int, greatest(1, (A->>'maxhp')::int / 16)); A := jsonb_set(A, '{hp}', to_jsonb((A->>'hp')::int - dmg));
      lines := lines || jsonb_build_object('txt', 'A semente sugou a vida de ' || nm || '!', 'side', side, 'hp', (A->>'hp')::int);
      D := s->'sides'->(1 - side)->'mons'->((s->'sides'->(1 - side)->>'active')::int);
      if (D->>'hp')::int > 0 then
        D := jsonb_set(D, '{hp}', to_jsonb(least((D->>'maxhp')::int, (D->>'hp')::int + dmg)));
        s := jsonb_set(s, array['sides', (1 - side)::text, 'mons', (s->'sides'->(1 - side)->>'active')], D);
        lines := lines || jsonb_build_object('txt', (D->>'name') || ' recuperou vida.', 'side', 1 - side, 'hp', (D->>'hp')::int);
      end if;
    end if;
    s := jsonb_set(s, array['sides', side::text, 'mons', ai::text], A);
    if (A->>'hp')::int <= 0 then
      s := jsonb_set(s, array['sides', side::text, 'mons', ai::text, 'fl', 'fainted'], 'true');
      lines := lines || jsonb_build_object('txt', nm || ' desmaiou!', 'side', side, 'faint', true);
      D := s->'sides'->(1 - side)->'mons'->((s->'sides'->(1 - side)->>'active')::int);
      if (D->>'hp')::int > 0 then
        xp := floor(floor((A->>'bexp')::int * (A->>'level')::int / 7.0) * (c->'xp'->>'battle_mult')::numeric);
        s := jsonb_set(s, array['xp', D->>'id'], to_jsonb(coalesce((s->'xp'->>(D->>'id'))::int, 0) + xp));
      end if;
    end if;
  end loop;
  -- fim de jogo?
  select count(*) filter (where (x->>'hp')::int > 0) into alive0 from jsonb_array_elements(s->'sides'->0->'mons') x;
  select count(*) filter (where (x->>'hp')::int > 0) into alive1 from jsonb_array_elements(s->'sides'->1->'mons') x;
  update battles set state = s, log = log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', lines)) where id = b.id;
  if alive0 = 0 or alive1 = 0 then
    winner := case when alive0 = 0 and alive1 = 0 then null when alive0 = 0 then b.p2 else b.p1 end;
    reason := case when winner is null then 'empate' else 'nocaute' end;
    perform public.bt_finish(b.id, winner, reason);
    return;
  end if;
  -- quem ficou sem Pokémon em campo precisa trocar
  for side in 0 .. 1 loop
    if (s->'sides'->side->'mons'->((s->'sides'->side->>'active')::int)->>'hp')::int <= 0 then
      s := jsonb_set(s, array['sides', side::text, 'need_switch'], 'true');
    end if;
  end loop;
  if coalesce((s->'sides'->0->>'need_switch')::boolean, false) or coalesce((s->'sides'->1->>'need_switch')::boolean, false) then
    update battles set state = s, phase = 'troca', turn = turn + 1,
           ready1 = not coalesce((s->'sides'->0->>'need_switch')::boolean, false), ready2 = not coalesce((s->'sides'->1->>'need_switch')::boolean, false),
           deadline = now() + make_interval(hours => (c->'battle'->>'turn_hours')::int) where id = b.id;
  else
    update battles set state = s, turn = turn + 1, ready1 = false, ready2 = false,
           deadline = now() + make_interval(hours => (c->'battle'->>'turn_hours')::int) where id = b.id;
  end if;
end $$;

-- ---------- ação do jogador num turno ----------
-- _kind: 'move' (_value = posição do ataque, 0 a 3; -1 = Struggle quando não há PP),
--        'switch' (_value = posição do Pokémon no time da batalha), 'forfeit' (desistir).
create or replace function public.battle_act(_id uuid, _turn int, _kind text, _value int) returns public.battles
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); b battles; side int; s jsonb; A jsonb; kind text := _kind; ok boolean;
begin
  select * into b from battles where id = _id for update;
  if b.id is null or uid not in (b.p1, b.p2) then raise exception 'Batalha não encontrada.'; end if;
  if b.status <> 'ativa' then raise exception 'Essa batalha não está em andamento.'; end if;
  side := case when uid = b.p1 then 0 else 1 end;
  if _kind = 'forfeit' then
    update battles set log = log || jsonb_build_array(jsonb_build_object('turn', b.turn, 'lines', jsonb_build_array(jsonb_build_object('txt', (b.state->'sides'->side->>'name') || ' desistiu da batalha.'))))
     where id = b.id;
    perform public.bt_finish(b.id, case when side = 0 then b.p2 else b.p1 end, 'desistencia');
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
  else raise exception 'Ação inválida.'; end if;
  insert into battle_actions(battle_id, turn, side, user_id, kind, value) values (b.id, b.turn, side, uid, kind, _value);
  if side = 0 then update battles set ready1 = true where id = b.id returning * into b;
  else update battles set ready2 = true where id = b.id returning * into b; end if;
  if b.ready1 and b.ready2 then perform public.bt_resolve(b.id); end if;
  select * into b from battles where id = _id;
  return b;
end $$;

-- quem já escolheu pode encerrar a batalha se o outro passou do prazo do turno
create or replace function public.battle_claim(_id uuid) returns public.battles
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); b battles; side int;
begin
  select * into b from battles where id = _id for update;
  if b.id is null or uid not in (b.p1, b.p2) or b.status <> 'ativa' then raise exception 'Batalha não encontrada.'; end if;
  side := case when uid = b.p1 then 0 else 1 end;
  if b.deadline > now() then raise exception 'O adversário ainda está no prazo.'; end if;
  if not ((side = 0 and b.ready1 and not b.ready2) or (side = 1 and b.ready2 and not b.ready1)) then
    raise exception 'Escolha a sua ação primeiro; só dá para reivindicar se o outro não jogou.'; end if;
  perform public.bt_finish(b.id, uid, 'tempo');
  select * into b from battles where id = _id; return b;
end $$;

-- equipe (versão definitiva da função do arquivo 17). Mudar a equipe não afeta batalhas já começadas: elas usam uma cópia.
create or replace function public.mon_team_set(_ids uuid[]) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); n int := coalesce(cardinality(_ids), 0); i int;
begin
  if n > 6 then raise exception 'A equipe tem no máximo 6 Pokémon.'; end if;
  if n <> (select count(distinct x) from unnest(coalesce(_ids, '{}')) x) then raise exception 'Pokémon repetido na equipe.'; end if;
  if n <> (select count(*) from monsters where user_id = uid and id = any(coalesce(_ids, '{}'))) then raise exception 'Só dá para usar Pokémon da sua coleção.'; end if;
  update monsters set team_slot = null where user_id = uid and team_slot is not null;
  for i in 1 .. n loop update monsters set team_slot = i where id = _ids[i] and user_id = uid; end loop;
end $$;

-- soltar não pode apagar Pokémon que está numa batalha em andamento
create or replace function public.mon_release(_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active();
begin
  if not exists (select 1 from monsters where id = _id and user_id = uid) then raise exception 'Esse Pokémon não é seu.'; end if;
  if exists (select 1 from battles b, jsonb_array_elements(b.state->'sides') sd, jsonb_array_elements(sd->'mons') mm
             where b.status = 'ativa' and uid in (b.p1, b.p2) and mm->>'id' = _id::text) then
    raise exception 'Esse Pokémon está numa batalha em andamento.'; end if;
  if exists (select 1 from characters where user_id = uid and mascot->>'id' = _id::text) then update characters set mascot = null where user_id = uid; end if;
  delete from monsters where id = _id and user_id = uid;
end $$;

-- ---------- permissões ----------
revoke execute on function public.bt_stage(int), public.bt_physical(text), public.bt_eff(text, text, text), public.bt_speed(jsonb), public.bt_mon(uuid),
  public.bt_finish(uuid, uuid, text), public.bt_use_move(jsonb, int, int, boolean, int), public.bt_can_act(jsonb, int), public.bt_resolve(uuid)
  from public, anon, authenticated;
revoke execute on function public.battle_challenge(uuid), public.battle_respond(uuid, boolean), public.battle_cancel(uuid), public.battle_act(uuid, int, text, int),
  public.battle_claim(uuid), public.mon_team_set(uuid[]), public.mon_release(uuid) from public, anon;
grant execute on function public.battle_challenge(uuid), public.battle_respond(uuid, boolean), public.battle_cancel(uuid), public.battle_act(uuid, int, text, int),
  public.battle_claim(uuid), public.mon_team_set(uuid[]), public.mon_release(uuid) to authenticated;
