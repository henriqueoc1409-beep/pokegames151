-- 93_rpg_aventura.sql
-- Pedido do dono em 11/11/2026: a Aventura, um RPG paralelo ao tabuleiro (o tabuleiro não muda), para até ~20
-- jogadores, usando os MESMOS Pokémon e moedas. Etapa 1: a primeira região (Vila Aurora) para andar, ver os
-- outros, entrar nas casas e lutar contra Pokémon selvagens em quatro tipos de terreno.
-- No banco, só a parte que não pode ficar no navegador:
--   (1) rpg_cfg(): ajustes (liga/desliga, limite de lutas por dia, espera, níveis e os tipos de cada terreno);
--   (2) rpg_dias: quantas lutas da Aventura cada um já fez no dia;
--   (3) rpg_estado() e rpg_encontro(_mon, _zona, _comp): o encontro cria uma batalha 'treino' igual à da Grama
--       de Treino (o selvagem joga sozinho pelo battle_act, e o treino_after dá a experiência, guarda a vida do
--       treino e o relato). A diferença: não gasta o relógio da Grama, tem limite próprio por dia, e o Pokémon
--       selvagem é do tipo do terreno. Não tem lendário nem "Pokémon forte" aqui.
--   (4) Ajustes do jogo (admin_cfg_efetiva, versão do 90 + rpg) e a novidade no Jornal.
-- ATENÇÃO (regra 5): as lutas da Aventura dão experiência pela MESMA conta da Grama. É uma fonte nova de XP,
-- por isso nasce com limite por dia (batalhas_dia) e o admin pode mudar ou zerar em Ajustes do jogo.

create or replace function public.rpg_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "batalhas_dia": 20, "chance_pct": 12, "espera_seg": 8, "nivel_menos": 3, "nivel_mais": 0, "envio_seg": 1.2,
    "zonas": {"mato": ["INSETO", "PLANTA", "NORMAL"], "escura": ["NORMAL", "VOADOR", "ELETRICO"], "pantano": ["AGUA", "VENENO"], "pedra": ["PEDRA", "TERRA", "LUTA"]}}'::jsonb
    || coalesce(public.cfg()->'rpg', '{}'::jsonb)
$$;
update public.game_config set config = jsonb_set(config, '{rpg}', public.rpg_cfg()) where active and not (config ? 'rpg');

create table if not exists public.rpg_dias (
  user_id  uuid not null references auth.users(id) on delete cascade,
  dia      date not null,
  batalhas int  not null default 0,
  ult      timestamptz,
  primary key (user_id, dia)
);
alter table public.rpg_dias enable row level security;
drop policy if exists rpg_dias_meus on public.rpg_dias;
create policy rpg_dias_meus on public.rpg_dias for select to authenticated using (user_id = auth.uid() or public.is_admin());
grant select on public.rpg_dias to authenticated;

-- o que a tela precisa saber: ligado, quantas lutas hoje, o limite e a luta que ficou aberta (se houver)
create or replace function public.rpg_estado() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.rpg_cfg(); n int;
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  select batalhas into n from rpg_dias where user_id = uid and dia = public.game_today();
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'batalhas', coalesce(n, 0), 'batalhas_dia', (c->>'batalhas_dia')::int,
    'chance_pct', (c->>'chance_pct')::numeric, 'espera_seg', (c->>'espera_seg')::int, 'batalha', public.treino_batalha(uid));
end $$;

-- encontro com um Pokémon selvagem do terreno onde o jogador está
create or replace function public.rpg_encontro(_mon uuid, _zona text, _comp uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.rpg_cfg(); me characters; m monsters; d rpg_dias; bid uuid;
  lvl int; sp int; wild jsonb; mine jsonb; hp0 int; s0 jsonb; s1 jsonb; tipos text[]; lugar text;
begin
  if not coalesce((c->>'on')::boolean, true) and not public.is_admin() then raise exception 'A Aventura está fechada no momento.'; end if;
  select * into me from characters where user_id = uid for update;
  bid := public.treino_batalha(uid);
  if bid is not null then return jsonb_build_object('battle', bid); end if;   -- termine a luta que já começou
  if not (c->'zonas' ? _zona) then raise exception 'Não há Pokémon selvagens neste lugar.'; end if;
  select array_agg(x) into tipos from jsonb_array_elements_text(c->'zonas'->_zona) x;
  insert into rpg_dias(user_id, dia) values (uid, public.game_today()) on conflict do nothing;
  select * into d from rpg_dias where user_id = uid and dia = public.game_today() for update;
  if d.batalhas >= (c->>'batalhas_dia')::int then
    raise exception 'Você já fez as % lutas de hoje na Aventura. Amanhã tem mais.', (c->>'batalhas_dia');
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
  lvl := greatest(1, least(100, m.level - (c->>'nivel_menos')::int + floor(random() * ((c->>'nivel_menos')::int + (c->>'nivel_mais')::int + 1))::int));
  select p.id into sp from pokemon p
   where p.catch_rate > 3 and public.gen_ok(p.id) and (p.g1_type1 = any(tipos) or p.g1_type2 = any(tipos))
     and (p.id = p.base_form or exists (select 1 from pk_evolutions e where e.to_id = p.id and ((e.method = 'nivel' and e.level <= lvl) or (e.method <> 'nivel' and lvl >= 30))))
   order by random() limit 1;
  if sp is null then raise exception 'Nenhum Pokémon por aqui… continue andando.'; end if;
  wild := public.npc_mon(sp, lvl);
  mine := public.bt_mon(m.id);
  hp0 := greatest(1, round((mine->>'maxhp')::int * m.tr_hp / 100.0))::int;
  mine := jsonb_set(mine, '{hp}', to_jsonb(hp0));
  lugar := case _zona when 'mato' then 'do capim alto' when 'escura' then 'da grama escura' when 'pantano' then 'do pântano' when 'pedra' then 'das pedras' else 'do mato' end;
  s0 := jsonb_build_object('user', uid, 'name', me.name, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(mine));
  s1 := jsonb_build_object('user', uid, 'name', 'Pokémon selvagem', 'npc', true, 'active', 0, 'need_switch', false, 'mons', jsonb_build_array(wild));
  insert into battles(p1, p2, mode, size, status, turn, phase, started_at, state, log)
  values (uid, uid, 'treino', 1, 'ativa', 1, 'normal', now(),
          jsonb_build_object('sides', jsonb_build_array(s0, s1), 'xp', '{}'::jsonb, 'treino', jsonb_build_object('mon', m.id, 'forte', false, 'comp', _comp, 'rpg', _zona)),
          jsonb_build_array(jsonb_build_object('turn', 0, 'lines', jsonb_build_array(
            jsonb_build_object('txt', 'Um ' || (wild->>'name') || ' selvagem (nível ' || lvl || ') saiu ' || lugar || '!'),
            jsonb_build_object('txt', 'Vai, ' || (mine->>'name') || '!' || case when m.tr_hp < 100 then ' (com ' || m.tr_hp || '% da vida)' else '' end)))))
  returning id into bid;
  update rpg_dias set batalhas = batalhas + 1, ult = now() where user_id = uid and dia = public.game_today();
  return jsonb_build_object('battle', bid, 'batalhas', d.batalhas + 1, 'batalhas_dia', (c->>'batalhas_dia')::int);
end $$;

grant execute on function public.rpg_estado(), public.rpg_encontro(uuid, text, uuid) to authenticated;
revoke execute on function public.rpg_cfg() from public, anon, authenticated;

-- ---------- Ajustes do jogo (versão do 90 + Aventura) ----------
create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'leilao', public.leilao_cfg(), 'herois', public.herois_cfg(), 'temporada', public.temporada_cfg(), 'liga', public.liga_cfg(), 'pausa', public.pausa_cfg(), 'teto', public.teto_cfg(), 'boas_vindas', public.boas_vindas_cfg(), 'vila_bonus', public.vila_bonus_cfg(), 'tm_nivel', public.tm_nivel_cfg(), 'quiz_auto', public.quiz_auto_cfg(), 'cartas', public.tcg_cfg(), 'pokebound', public.pokebound_cfg(), 'visual', public.visual_cfg(), 'praca', public.praca_cfg(), 'rpg', public.rpg_cfg(), 'base', public.cfg());
end $$;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🧭 Chegou a Aventura: o RPG do Pokegames!', 'Jogo novo dentro do Pokegames, para quem quer jogar mais tempo: a Aventura (menu Competir, ou o botão 🧭 no alto do mapa).
• Ande pela Vila Aurora com o seu herói: fazenda, feira, rio, pontes, penhascos e a cidade murada.
• Seus Pokémon e moedas são os mesmos do tabuleiro. O primeiro da equipe anda atrás de você.
• Pokémon selvagens aparecem no capim alto, na grama escura, no pântano e no alto do penhasco, cada lugar com os seus tipos. Você comanda a luta e ganha experiência.
• Há um limite de lutas por dia na Aventura, para manter o equilíbrio com o tabuleiro.
• Entre nas casas pela porta: Loja Pokémon, Loja & Visuais, Creche, Centro Pokémon, Mercado e mais.
• Os outros jogadores aparecem andando ao vivo, e o chat vira balão em cima da cabeça.
• O tabuleiro continua igual: a Aventura é um jogo a mais.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
