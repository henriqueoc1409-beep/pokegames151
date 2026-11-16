-- Arquivo 114 (pedido do dono em 16/11/2026, aprovado pelo grupo): troca de Pokémon entre jogadores.
-- Proposta de 1 Pokémon por 1 Pokémon, com moedas opcionais dos dois lados; os dois confirmam vendo o resumo; vale 24 horas.
-- O Pokémon vai com nível, XP, ataques e roupas. Não troca quem está na Creche, num esquadrão de guerra, como suporte da Aventura,
-- numa batalha de Ginásio ou no Desafio do Planalto em andamento, ou num Leilão aberto. 3 trocas por semana por jogador; quem chega por troca
-- fica 7 dias sem poder ser trocado de novo. Taxa de 5% sobre as moedas que cada um recebe (Ladino 2%, Mercador 0%); sem moedas, sem taxa.
-- Kadabra, Machoke, Graveler e Haunter evoluem ao chegar, como na Red/Blue (o Cabo Link continua na loja). Tudo vai para os Acontecimentos.
-- Números em game_config.config.troca (Ajustes do jogo). Também: o Pokémon de suporte da Aventura passa a ficar guardado no servidor.

alter table public.monsters add column if not exists troca_em timestamptz;       -- quando chegou por troca (trava de 7 dias)
alter table public.characters add column if not exists rpg_suporte uuid;          -- o Pokémon de suporte da Aventura

create table if not exists public.trocas (
  id          bigserial primary key,
  de          uuid not null references auth.users(id) on delete cascade,   -- quem propõe
  para        uuid not null references auth.users(id) on delete cascade,   -- quem recebe a proposta
  mon_de      uuid not null,                                               -- o Pokémon que quem propõe dá
  mon_para    uuid not null,                                               -- o Pokémon que quem propõe pede
  moedas_de   int  not null default 0 check (moedas_de >= 0),             -- moedas que quem propõe dá (ficam guardadas)
  moedas_para int  not null default 0 check (moedas_para >= 0),           -- moedas que quem recebe a proposta dá ao aceitar
  status      text not null default 'pendente' check (status in ('pendente', 'aceita', 'recusada', 'cancelada', 'expirou')),
  resumo      jsonb not null default '{}'::jsonb,                          -- foto dos dois Pokémon na hora (para o histórico)
  taxa_de     int  not null default 0, taxa_para int not null default 0,
  evoluiu     jsonb,
  criada_em   timestamptz not null default now(),
  expira_em   timestamptz not null,
  fim         timestamptz
);
create index if not exists trocas_de on public.trocas (de, status);
create index if not exists trocas_para on public.trocas (para, status);
alter table public.trocas enable row level security;
drop policy if exists trocas_minhas on public.trocas;
create policy trocas_minhas on public.trocas for select to authenticated using (de = auth.uid() or para = auth.uid() or public.is_admin());
grant select on public.trocas to authenticated;

create or replace function public.troca_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "taxa_pct": 5, "ladino_taxa_pct": 2, "mercador_taxa_pct": 0, "semana_max": 3, "trava_dias": 7, "expira_horas": 24, "pendentes_max": 5, "moedas_max": 100000}'::jsonb
         || coalesce(public.cfg()->'troca', '{}'::jsonb)
$$;

create or replace function public.troca_taxa_de(_uid uuid) returns numeric
language sql stable security definer set search_path = public, extensions as $$
  select greatest(0, case public.heroi(_uid) when 'ladino' then (c->>'ladino_taxa_pct')::numeric when 'mercador' then (c->>'mercador_taxa_pct')::numeric
                                             else (c->>'taxa_pct')::numeric end) from (select public.troca_cfg() c) x
$$;

-- trocas feitas na semana (de segunda a domingo, como a Creche)
create or replace function public.troca_semana(_uid uuid) returns int
language sql stable security definer set search_path = public, extensions as $$
  select count(*)::int from trocas where status = 'aceita' and (de = _uid or para = _uid) and fim >= public.creche_semana()
$$;

-- esse Pokémon pode ser trocado agora? (devolve o motivo, ou null)
create or replace function public.troca_motivo(_uid uuid, _mon uuid, _ignora bigint default null) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare m monsters; dias int := coalesce((public.troca_cfg()->>'trava_dias')::int, 7);
begin
  select * into m from monsters where id = _mon;
  if m.id is null or m.user_id is distinct from _uid then return 'Esse Pokémon não é mais de quem estava na troca.'; end if;
  if exists (select 1 from creche_pedidos where mon_id = _mon and status = 'treinando') then return 'Esse Pokémon está na Creche.'; end if;
  if exists (select 1 from war_squads where monster_id = _mon) then return 'Esse Pokémon está num esquadrão de guerra.'; end if;
  if exists (select 1 from characters where user_id = _uid and rpg_suporte = _mon) then return 'Esse Pokémon é o suporte da Aventura.'; end if;
  perform public.rpg_gin_expira(_uid);
  if public.gin_preso(_uid, _mon) then return 'Esse Pokémon está numa batalha de Ginásio em andamento.'; end if;
  if exists (select 1 from rpg_elite_run where user_id = _uid and status = 'andando' and meus ? _mon::text) then return 'Esse Pokémon está no Desafio do Planalto em andamento.'; end if;
  if exists (select 1 from battles b, jsonb_array_elements(b.state->'sides') sd, jsonb_array_elements(sd->'mons') mm
              where b.status = 'ativa' and _uid in (b.p1, b.p2) and mm->>'id' = _mon::text) then return 'Esse Pokémon está numa batalha em andamento.'; end if;
  if exists (select 1 from leiloes where mon_id = _mon and status = 'aberto') then return 'Esse Pokémon está no Leilão.'; end if;
  if m.troca_em is not null and m.troca_em > now() - make_interval(days => dias) then
    return 'Esse Pokémon chegou por troca há pouco: só pode ser trocado de novo ' || to_char(m.troca_em + make_interval(days => dias), 'DD/MM') || '.';
  end if;
  if exists (select 1 from trocas where status = 'pendente' and (mon_de = _mon or mon_para = _mon) and id is distinct from _ignora) then
    return 'Esse Pokémon já está numa proposta de troca.'; end if;
  return null;
end $$;

-- foto de um Pokémon para a tela de confirmação
create or replace function public.troca_mon_pub(_mon uuid) returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object('id', m.id, 'species', m.species_id, 'level', m.level, 'moves', to_jsonb(m.moves), 'outfit', coalesce(m.outfit, '{}'::jsonb))
    from monsters m where m.id = _mon
$$;

-- propostas vencidas: somem e as moedas voltam
create or replace function public.troca_tick() returns int
language plpgsql security definer set search_path = public, extensions as $$
declare t trocas; n int := 0;
begin
  for t in select * from trocas where status = 'pendente' and expira_em <= now() for update skip locked loop
    update characters set coins = coins + t.moedas_de where user_id = t.de;
    update trocas set status = 'expirou', fim = now() where id = t.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- evolução por troca (Kadabra, Machoke, Graveler e Haunter), como na Red/Blue
create or replace function public.troca_evolui(_mon uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare m monsters; ev pk_evolutions; mv int; de_nome text; para_nome text;
begin
  select * into m from monsters where id = _mon for update;
  if m.id is null then return null; end if;
  select * into ev from pk_evolutions where from_id = m.species_id and method = 'troca' and item is null order by to_id limit 1;
  if ev.from_id is null or not public.evo_ok(ev.from_id, ev.to_id) then return null; end if;
  m.species_id := ev.to_id;
  for mv in select move_id from pk_learnset where species_id = ev.to_id and level = m.level loop
    if mv = any(m.moves) then continue; end if;
    if cardinality(m.moves) < 4 then m.moves := m.moves || mv; else m.pending_moves := m.pending_moves || mv; end if;
  end loop;
  update monsters set species_id = m.species_id, moves = m.moves, pending_moves = m.pending_moves where id = m.id;
  perform public.pk_dex_mark(m.user_id, ev.to_id, true);
  perform public.pk_refresh_mascot(m.user_id);
  select name into de_nome from pokemon where id = ev.from_id;
  select name into para_nome from pokemon where id = ev.to_id;
  insert into event_log(user_id, kind, message) select m.user_id, 'evolucao', ch.name || ': ' || de_nome || ' evoluiu para ' || para_nome || ' com a troca!' from characters ch where ch.user_id = m.user_id;
  return jsonb_build_object('mon', m.id, 'de', ev.from_id, 'para', ev.to_id);
end $$;

-- passa um Pokémon para outro dono (sai da equipe, dos esquadrões e de mascote; entra na Pokédex de quem recebe)
create or replace function public.troca_passa(_mon uuid, _de uuid, _para uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare sp int;
begin
  update monsters set user_id = _para, team_slot = null, troca_em = now() where id = _mon and user_id = _de returning species_id into sp;
  delete from war_squads where monster_id = _mon;
  update characters set mascot = null where user_id = _de and (mascot->>'id')::uuid = _mon;
  update characters set rpg_suporte = null where user_id = _de and rpg_suporte = _mon;
  perform public.pk_dex_mark(_para, sp, true);
end $$;

-- propor: o seu Pokémon pelo Pokémon de outro jogador, com moedas opcionais
create or replace function public.troca_propor(_para uuid, _mon_de uuid, _mon_para uuid, _moedas_de int default 0, _moedas_para int default 0) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.troca_cfg(); me characters; mot text; t trocas; lim int := (c->>'semana_max')::int;
begin
  if not coalesce((c->>'on')::boolean, true) then raise exception 'As trocas estão fechadas no momento.'; end if;
  perform public.troca_tick();
  if _para is null or _para = uid then raise exception 'Escolha outro jogador para trocar.'; end if;
  if not exists (select 1 from characters where user_id = _para) then raise exception 'Esse jogador não existe.'; end if;
  _moedas_de := coalesce(_moedas_de, 0); _moedas_para := coalesce(_moedas_para, 0);
  if _moedas_de < 0 or _moedas_para < 0 then raise exception 'As moedas não podem ser negativas.'; end if;
  if _moedas_de > (c->>'moedas_max')::int or _moedas_para > (c->>'moedas_max')::int then raise exception 'No máximo % moedas de cada lado.', c->>'moedas_max'; end if;
  if public.troca_semana(uid) >= lim then raise exception 'Você já fez % trocas esta semana, que é o limite. Volte na segunda!', lim; end if;
  if public.troca_semana(_para) >= lim then raise exception 'Esse jogador já fez as % trocas da semana.', lim; end if;
  if (select count(*) from trocas where de = uid and status = 'pendente') >= (c->>'pendentes_max')::int then
    raise exception 'Você já tem % propostas esperando resposta. Espere ou cancele alguma.', c->>'pendentes_max'; end if;
  mot := public.troca_motivo(uid, _mon_de); if mot is not null then raise exception '%', mot; end if;
  mot := public.troca_motivo(_para, _mon_para);
  if mot is not null then raise exception '%', replace(replace(mot, 'Esse Pokémon', 'O Pokémon que você pediu'), 'não é mais de quem estava na troca', 'não é desse jogador'); end if;
  select * into me from characters where user_id = uid for update;
  if me.coins < _moedas_de then raise exception 'Você tem % moedas e ofereceu %.', me.coins, _moedas_de; end if;
  update characters set coins = coins - _moedas_de where user_id = uid;   -- as moedas oferecidas ficam guardadas até a resposta
  insert into trocas(de, para, mon_de, mon_para, moedas_de, moedas_para, resumo, expira_em)
  values (uid, _para, _mon_de, _mon_para, _moedas_de, _moedas_para,
          jsonb_build_object('de', public.troca_mon_pub(_mon_de), 'para', public.troca_mon_pub(_mon_para)),
          now() + make_interval(hours => (c->>'expira_horas')::int))
  returning * into t;
  return jsonb_build_object('id', t.id, 'expira_em', t.expira_em, 'coins', me.coins - _moedas_de);
end $$;

-- responder: aceitar faz a troca na hora; recusar devolve as moedas de quem propôs
create or replace function public.troca_responder(_id bigint, _aceita boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.troca_cfg(); t trocas; mot text; lim int := (c->>'semana_max')::int;
  tx_de int := 0; tx_para int := 0; ev1 jsonb; ev2 jsonb; nde text; npara text; sp1 text; sp2 text; coins_para int;
begin
  perform public.troca_tick();
  select * into t from trocas where id = _id for update;
  if t.id is null or t.para <> uid then raise exception 'Proposta não encontrada.'; end if;
  if t.status <> 'pendente' then raise exception 'Essa proposta não está mais valendo.'; end if;
  if not coalesce(_aceita, false) then
    update characters set coins = coins + t.moedas_de where user_id = t.de;
    update trocas set status = 'recusada', fim = now() where id = t.id;
    return jsonb_build_object('status', 'recusada');
  end if;
  if not coalesce((c->>'on')::boolean, true) then raise exception 'As trocas estão fechadas no momento.'; end if;
  if public.troca_semana(uid) >= lim then raise exception 'Você já fez % trocas esta semana, que é o limite. Volte na segunda!', lim; end if;
  if public.troca_semana(t.de) >= lim then raise exception 'Quem propôs já fez as % trocas da semana. A proposta continua aqui até vencer.', lim; end if;
  mot := public.troca_motivo(t.de, t.mon_de, t.id);
  if mot is not null then raise exception 'O Pokémon oferecido não pode ser trocado agora: %', mot; end if;
  mot := public.troca_motivo(uid, t.mon_para, t.id);
  if mot is not null then raise exception '%', mot; end if;
  select coins into coins_para from characters where user_id = uid for update;
  if coins_para < t.moedas_para then raise exception 'A proposta pede % moedas e você tem %.', t.moedas_para, coins_para; end if;
  perform 1 from characters where user_id = t.de for update;
  -- taxa sobre as moedas que cada um recebe (pelo herói de quem recebe); sem moedas, sem taxa
  if t.moedas_de > 0 then tx_para := floor(t.moedas_de * public.troca_taxa_de(uid) / 100.0)::int; end if;
  if t.moedas_para > 0 then tx_de := floor(t.moedas_para * public.troca_taxa_de(t.de) / 100.0)::int; end if;
  update characters set coins = coins - t.moedas_para + (t.moedas_de - tx_para) where user_id = uid;
  update characters set coins = coins + (t.moedas_para - tx_de) where user_id = t.de;
  -- os Pokémon trocam de dono (com nível, XP, ataques e roupas)
  select name into sp1 from pokemon where id = (select species_id from monsters where id = t.mon_de);
  select name into sp2 from pokemon where id = (select species_id from monsters where id = t.mon_para);
  perform public.troca_passa(t.mon_de, t.de, uid);
  perform public.troca_passa(t.mon_para, uid, t.de);
  ev1 := public.troca_evolui(t.mon_de);
  ev2 := public.troca_evolui(t.mon_para);
  update trocas set status = 'aceita', fim = now(), taxa_de = tx_de, taxa_para = tx_para,
         evoluiu = case when ev1 is null and ev2 is null then null else jsonb_strip_nulls(jsonb_build_object('de', ev1, 'para', ev2)) end where id = t.id;
  -- outras propostas com esses Pokémon perdem o sentido: somem e devolvem as moedas
  update characters ch set coins = ch.coins + x.moedas_de from trocas x
   where x.status = 'pendente' and x.id <> t.id and (x.mon_de in (t.mon_de, t.mon_para) or x.mon_para in (t.mon_de, t.mon_para)) and ch.user_id = x.de;
  update trocas set status = 'cancelada', fim = now()
   where status = 'pendente' and id <> t.id and (mon_de in (t.mon_de, t.mon_para) or mon_para in (t.mon_de, t.mon_para));
  select name into nde from characters where user_id = t.de;
  select name into npara from characters where user_id = uid;
  insert into event_log(user_id, kind, message) values (uid, 'troca',
    '🔁 ' || nde || ' trocou ' || sp1 || ' com ' || npara || ' por ' || sp2
    || case when t.moedas_de > 0 then ' (+' || t.moedas_de || ' moedas de ' || nde || ')' else '' end
    || case when t.moedas_para > 0 then ' (+' || t.moedas_para || ' moedas de ' || npara || ')' else '' end || '!');
  return jsonb_build_object('status', 'aceita', 'taxa_de', tx_de, 'taxa_para', tx_para, 'evoluiu', jsonb_strip_nulls(jsonb_build_object('de', ev1, 'para', ev2)));
end $$;

create or replace function public.troca_cancelar(_id bigint) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); t trocas;
begin
  select * into t from trocas where id = _id for update;
  if t.id is null or t.de <> uid then raise exception 'Proposta não encontrada.'; end if;
  if t.status <> 'pendente' then raise exception 'Essa proposta não está mais valendo.'; end if;
  update characters set coins = coins + t.moedas_de where user_id = uid;
  update trocas set status = 'cancelada', fim = now() where id = t.id;
  return jsonb_build_object('status', 'cancelada');
end $$;

-- tudo o que a tela de trocas precisa: regras, as propostas (com os dois Pokémon de agora) e o histórico
create or replace function public.troca_minhas() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.troca_cfg();
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  perform public.troca_tick();
  return jsonb_build_object(
    'on', coalesce((c->>'on')::boolean, true), 'semana', public.troca_semana(uid), 'semana_max', (c->>'semana_max')::int,
    'taxa_pct', public.troca_taxa_de(uid), 'trava_dias', (c->>'trava_dias')::int, 'expira_horas', (c->>'expira_horas')::int, 'moedas_max', (c->>'moedas_max')::int,
    'propostas', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'de', t.de, 'para', t.para, 'de_nome', a.name, 'para_nome', b.name,
        'moedas_de', t.moedas_de, 'moedas_para', t.moedas_para, 'expira_em', t.expira_em, 'criada_em', t.criada_em,
        'mon_de', coalesce(public.troca_mon_pub(t.mon_de), t.resumo->'de'), 'mon_para', coalesce(public.troca_mon_pub(t.mon_para), t.resumo->'para'),
        'taxa_eu', public.troca_taxa_de(uid)) order by t.criada_em desc)
      from trocas t join characters a on a.user_id = t.de join characters b on b.user_id = t.para
      where t.status = 'pendente' and (t.de = uid or t.para = uid)), '[]'::jsonb),
    'historico', coalesce((select jsonb_agg(x order by (x->>'fim') desc) from (
      select jsonb_build_object('id', t.id, 'status', t.status, 'de', t.de, 'para', t.para, 'de_nome', a.name, 'para_nome', b.name, 'fim', t.fim,
        'mon_de', t.resumo->'de', 'mon_para', t.resumo->'para', 'moedas_de', t.moedas_de, 'moedas_para', t.moedas_para,
        'taxa_de', t.taxa_de, 'taxa_para', t.taxa_para, 'evoluiu', t.evoluiu) x
      from trocas t join characters a on a.user_id = t.de join characters b on b.user_id = t.para
      where t.status <> 'pendente' and (t.de = uid or t.para = uid) order by t.fim desc nulls last limit 15) y), '[]'::jsonb));
end $$;

-- os Pokémon de um jogador para a troca (com o motivo de quem não pode)
create or replace function public.troca_colecao(_user uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  return coalesce((select jsonb_agg(public.troca_mon_pub(m.id) || jsonb_build_object('motivo', public.troca_motivo(_user, m.id)) order by m.level desc, m.species_id)
                     from monsters m where m.user_id = _user), '[]'::jsonb);
end $$;

-- o Pokémon de suporte da Aventura fica guardado no servidor (para a trava da troca)
create or replace function public.rpg_suporte_set(_mon uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active();
begin
  if _mon is not null and not exists (select 1 from monsters where id = _mon and user_id = uid) then raise exception 'Esse Pokémon não é seu.'; end if;
  update characters set rpg_suporte = _mon where user_id = uid;
end $$;

-- admin_cfg_efetiva: versão do 113 + troca
create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'leilao', public.leilao_cfg(), 'herois', public.herois_cfg(), 'temporada', public.temporada_cfg(), 'liga', public.liga_cfg(), 'pausa', public.pausa_cfg(), 'teto', public.teto_cfg(), 'boas_vindas', public.boas_vindas_cfg(), 'vila_bonus', public.vila_bonus_cfg(), 'tm_nivel', public.tm_nivel_cfg(), 'quiz_auto', public.quiz_auto_cfg(), 'cartas', public.tcg_cfg(), 'pokebound', public.pokebound_cfg(), 'visual', public.visual_cfg(), 'praca', public.praca_cfg(), 'rpg', public.rpg_cfg(), 'equip', public.equip_cfg(), 'base', public.cfg(), 'exp', public.exp_cfg(), 'vale', public.vale_cfg(), 'fazenda', public.fazenda_cfg(), 'ia', public.ia_cfg(), 'troca', public.troca_cfg());   -- arquivo 114: troca entre jogadores   -- arquivo 113: escolha de ataques   -- arquivo 112: Vale do Treino e Fazenda   -- arquivo 111: Expedições
end $$;

revoke execute on function public.troca_cfg(), public.troca_taxa_de(uuid), public.troca_semana(uuid), public.troca_motivo(uuid, uuid, bigint),
  public.troca_mon_pub(uuid), public.troca_tick(), public.troca_evolui(uuid), public.troca_passa(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.troca_propor(uuid, uuid, uuid, int, int), public.troca_responder(bigint, boolean), public.troca_cancelar(bigint),
  public.troca_minhas(), public.troca_colecao(uuid), public.rpg_suporte_set(uuid), public.admin_cfg_efetiva() to authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values
   ('🔁 Troca de Pokémon entre jogadores', 'Agora dá para trocar Pokémon com os amigos (menu Pokémon → 🔁 Trocas):
• Escolha um Pokémon seu e um Pokémon de outro jogador. Se quiser, coloque moedas de um lado ou do outro.
• Os dois confirmam numa tela com o resumo: Pokémon, nível, ataques e moedas de cada lado. A proposta vale 24 horas.
• O Pokémon vai inteiro: nível, experiência, ataques e roupas.
• Não dá para trocar Pokémon que está na Creche, num esquadrão de guerra, como suporte da Aventura, no Leilão ou numa batalha de Ginásio ou do Desafio do Planalto.
• São até 3 trocas por semana. Quem chega por troca só pode ser trocado de novo depois de 7 dias.
• Taxa de 5% sobre as moedas que você recebe (Ladino paga 2% e Mercador não paga). Troca sem moedas não tem taxa.
• Como na Red/Blue: Kadabra, Machoke, Graveler e Haunter evoluem quando são trocados! (O Cabo Link continua na loja.)
• Toda troca aparece nos Acontecimentos.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
