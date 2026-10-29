-- =====================================================================
-- POKEGAMES — Dig protege como o Fly (pedido do dono em 29/10/2026).
--
-- Na Red/Blue, no primeiro turno do Dig o Pokémon cava e fica debaixo da
-- terra: nenhum ataque o acerta, e no turno seguinte ele sai atacando.
-- Aqui só o Fly protegia; o Dig deixava o Pokémon levar dano enquanto
-- "se preparava". Agora o Dig protege igual ao Fly, e o relato diz o que
-- aconteceu ("cavou um buraco…", "não acertou: está debaixo da terra!").
-- Vale para todas as batalhas (jogadores, Liga, guerras, Rocket, treino).
-- Nova versão de bt_use_move (a mais recente era a do 28).
-- Antes de rodar à mão, faça a cópia de segurança.
-- =====================================================================

-- usa um ataque (versão do 28 + Dig protege no turno de preparo)
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
    select id into t from pk_moves where id not in (118, 165) and (id <= 165 or public.gen2_on()) order by random() limit 1;
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
    -- Fly e Dig (como na Red/Blue): no turno de preparo o Pokémon fica no alto ou debaixo da terra e nada o acerta
    if mv.effect = 'FLY_EFFECT' or mv.id = 91 then A := jsonb_set(A, '{fl,invul}', 'true'); end if;
    _lines := _lines || jsonb_build_object('txt', case when mv.id = 91 then nm || ' cavou um buraco e se escondeu debaixo da terra!'
                                                       when mv.effect = 'FLY_EFFECT' then nm || ' voou bem alto!'
                                                       else nm || ' está se preparando…' end);
    return jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{_lines}', _lines);
  end if;
  A := A #- '{fl,charging}'; A := A #- '{fl,invul}';
  -- efeitos que ainda não existem no Pokegames
  if mv.effect in ('TRANSFORM_EFFECT','MIMIC_EFFECT','DISABLE_EFFECT','CONVERSION_EFFECT','BIDE_EFFECT','SUBSTITUTE_EFFECT','G2_NAO_FUNCIONA') or mv.id = 68 then
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
    if coalesce((D->'fl'->>'invul')::boolean, false) then   -- o alvo está no alto (Fly) ou debaixo da terra (Dig)
      _lines := _lines || jsonb_build_object('txt', 'O ataque de ' || nm || ' não acertou: ' || (D->>'name')
        || case when (D->'fl'->>'charging')::int = 91 then ' está debaixo da terra!' else ' está lá no alto!' end);
      if mv.effect = 'JUMP_KICK_EFFECT' then
        A := jsonb_set(A, '{hp}', to_jsonb(greatest(0, (A->>'hp')::int - 1)));
        _lines := _lines || jsonb_build_object('txt', nm || ' caiu e se machucou!', 'side', _a, 'hp', (A->>'hp')::int);
      end if;
      return jsonb_set(jsonb_set(_s, array['sides', _a::text, 'mons', ai::text], A), '{_lines}', _lines);
    end if;
    if floor(random() * 256) >= least(255, acc)
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

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('⛏️ Dig agora funciona como no jogo', 'Corrigimos o ataque Dig nas batalhas:
• No primeiro turno, o Pokémon cava um buraco e fica debaixo da terra: nenhum ataque o acerta.
• No turno seguinte, ele sai do chão e ataca.
É igual ao Fly, que já funcionava assim, e igual aos jogos de Pokémon. Vale para todas as batalhas.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
