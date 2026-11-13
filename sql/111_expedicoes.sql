-- 111_expedicoes.sql
-- Pedido do dono em 13/11/2026: minigame "Expedições Pokegames", começando pela Mina Esquecida (região da Pedreira).
-- Partida individual de 5 etapas (5 a 10 min): escolha do caminho, exploração, desafio, consequência e câmara final.
-- O MOTOR é genérico: cada expedição é um ROTEIRO em JSON (exp_cenarios.def) com eventos por etapa, condições (caminho,
-- marcas do que já aconteceu, golpes da equipe como Força e Flash, herói, equipamentos, recursos), opções com custo
-- (⚡ energia e 🔦 luz) e resultados com peso escondido (mod = muda o peso conforme o que aconteceu; "ruim" pesa com a
-- dificuldade). Efeitos: recursos, marcas, moedas, itens da bolsa, Doces de Forja, peça de equipamento, relíquias,
-- segredos, Pokémon avistados, batalha (a MESMA da Aventura, modo treino, com captura pelo encounter_throw de sempre).
-- Expedição nova (floresta, templo…) = um roteiro novo pelo admin, sem programar.
-- Segurança: o site só manda a escolha; tudo é sorteado e aplicado aqui. A mochila é entregue UMA vez (exp_finalizar,
-- entregue_em). Uma expedição ativa por jogador, limite por dia, expiração (perde a mochila), histórico em exp_runs.log.
-- Diário do Explorador (exp_diario): relíquias, segredos, chefes, avistados, caminhos e conquistas (prêmio uma vez).
-- Cooperação: exp_runs.membros já existe (hoje só o dono), para a versão em grupo.
-- Números em game_config.config.exp (exp_cfg, Ajustes do jogo → ⛏️ Expedições). Novas admin_cfg_efetiva (versão do 103)
-- e rpg_after (versão do 106, + o fim das lutas da expedição). Não muda XP, moedas, captura nem evolução.

create or replace function public.exp_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "limite_dia": 3, "expira_horas": 24, "dificuldade": 1, "recompensa_mult": 1, "especiais_on": true, "captura_on": true,
    "chefe_vida": 1.6, "nivel_min": 3, "nivel_max": 80}'::jsonb || coalesce(public.cfg()->'exp', '{}'::jsonb)
$$;
revoke execute on function public.exp_cfg() from public, anon, authenticated;

-- ---------- tabelas ----------
-- cada expedição é um roteiro em JSON (eventos, escolhas, resultados e efeitos): expedição nova = roteiro novo, sem código novo
create table if not exists public.exp_cenarios (
  id text primary key, def jsonb not null, ativo boolean not null default true, ordem int not null default 1, atualizado timestamptz not null default now());
alter table public.exp_cenarios enable row level security;   -- sem política: as chances ficam escondidas; o site lê pelo exp_lista

-- uma expedição em andamento ou terminada. "membros" já existe para a cooperação futura (hoje só o dono).
create table if not exists public.exp_runs (
  id bigserial primary key, cenario text not null references public.exp_cenarios(id), dono uuid not null references auth.users(id) on delete cascade,
  membros uuid[] not null, status text not null default 'andando' check (status in ('andando', 'batalha', 'concluida', 'recuou', 'exausta', 'expirou')),
  etapa int not null default 1, recursos jsonb not null, flags text[] not null default '{}', caminho text, evento_id text, evento jsonb, usados text[] not null default '{}',
  mochila jsonb not null default '{"moedas": 0, "itens": {}, "doces": 0, "pecas": 0, "reliquias": [], "segredos": [], "chefes": [], "avistados": []}'::jsonb,
  ultimo jsonb, pendente jsonb, batalha uuid, encontro uuid, log jsonb not null default '[]'::jsonb,
  dia date not null, criado timestamptz not null default now(), expira timestamptz not null, fim timestamptz, entregue_em timestamptz, resultado jsonb);
create unique index if not exists exp_runs_uma_ativa on public.exp_runs(dono) where status in ('andando', 'batalha');
create index if not exists exp_runs_dono on public.exp_runs(dono, dia);
alter table public.exp_runs enable row level security;   -- sem política: o site lê pelo exp_estado

-- Diário do Explorador: o que cada um já descobriu (uma linha por descoberta; a 1ª vez fica marcada)
create table if not exists public.exp_diario (
  user_id uuid not null references auth.users(id) on delete cascade, tipo text not null, chave text not null, cenario text,
  qtd int not null default 1, primeira_em timestamptz not null default now(), ultima_em timestamptz not null default now(),
  primary key (user_id, tipo, chave));
alter table public.exp_diario enable row level security;
drop policy if exists exp_diario_ler on public.exp_diario;
create policy exp_diario_ler on public.exp_diario for select to authenticated using (user_id = auth.uid());
grant select on public.exp_diario to authenticated;

-- ---------- regras ----------
-- uma condição do roteiro vale para este jogador agora?
create or replace function public.exp_cond_ok(_uid uuid, _r exp_runs, _c jsonb) returns boolean
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if _c is null or jsonb_typeof(_c) <> 'object' then return true; end if;
  if _c ? 'flag' and not ((_c->>'flag') = any(_r.flags)) then return false; end if;
  if _c ? 'nao_flag' and (_c->>'nao_flag') = any(_r.flags) then return false; end if;
  if _c ? 'heroi' and public.heroi(_uid) <> (_c->>'heroi') then return false; end if;
  if _c ? 'golpe' and not exists (select 1 from monsters where user_id = _uid and team_slot is not null and (_c->>'golpe')::int = any(moves)) then return false; end if;
  if _c ? 'equip' and coalesce((select max(nivel) from equip_pecas where user_id = _uid and equipada and slot = _c->>'equip'), -1) < coalesce((_c->>'min')::int, 0) then return false; end if;
  if _c ? 'recurso' and (coalesce((_r.recursos->>(_c->>'recurso'))::int, 0) < coalesce((_c->>'min')::int, -999)
                         or coalesce((_r.recursos->>(_c->>'recurso'))::int, 0) > coalesce((_c->>'max')::int, 999)) then return false; end if;
  return true;
end $$;

-- o que o jogador vê do acontecimento (sem os resultados nem as chances)
create or replace function public.exp_evento_pub(_uid uuid, _r exp_runs, _ev jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare o jsonb; out jsonb := '[]'::jsonb; okr boolean; okc boolean; mot text;
begin
  for o in select * from jsonb_array_elements(coalesce(_ev->'opcoes', '[]'::jsonb)) loop
    okr := public.exp_cond_ok(_uid, _r, o->'req');
    okc := coalesce((_r.recursos->>'energia')::int, 0) >= coalesce((o->'custo'->>'energia')::int, 0) and coalesce((_r.recursos->>'luz')::int, 0) >= coalesce((o->'custo'->>'luz')::int, 0);
    mot := case when not okr then case when o->'req' ? 'golpe' then 'Precisa de um Pokémon na equipe que saiba ' || coalesce((select name from pk_moves where id = (o->'req'->>'golpe')::int), 'esse golpe')
                                        when o->'req' ? 'flag' then 'Você ainda não tem o que precisa para isso.'
                                        when o->'req' ? 'heroi' then 'Só para o herói ' || (o->'req'->>'heroi') else 'Não dá para fazer isso agora.' end
                when not okc then 'Falta ' || case when coalesce((_r.recursos->>'energia')::int, 0) < coalesce((o->'custo'->>'energia')::int, 0) then 'energia' else 'luz' end || '.' end;
    out := out || jsonb_build_array(jsonb_build_object('id', o->>'id', 'txt', o->>'txt', 'custo', coalesce(o->'custo', '{}'::jsonb), 'ok', okr and okc, 'motivo', mot));
  end loop;
  return jsonb_build_object('id', _ev->>'id', 'titulo', _ev->>'titulo', 'texto', _ev->>'texto', 'cena', coalesce(_ev->>'cena', 'tunel'), 'opcoes', out);
end $$;

-- sorteia o acontecimento da etapa (pelo caminho, pelo que já aconteceu e pelo peso de cada um)
create or replace function public.exp_sortear(_run bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare r exp_runs; d jsonb; ev jsonb; tot numeric := 0; x numeric; esc jsonb; cands jsonb := '[]'::jsonb; pass int;
begin
  select * into r from exp_runs where id = _run for update;
  select def into d from exp_cenarios where id = r.cenario;
  for pass in 1 .. 2 loop
    for ev in select * from jsonb_array_elements(d->'eventos') loop
      if not (to_jsonb(r.etapa) <@ (ev->'etapa')) or (ev->>'id') = any(r.usados) then continue; end if;
      if pass = 1 then
        if exists (select 1 from jsonb_array_elements_text(coalesce(ev->'tags_req', '[]'::jsonb)) t where not (t = any(r.flags))) then continue; end if;
        if exists (select 1 from jsonb_array_elements_text(coalesce(ev->'flags_req', '[]'::jsonb)) t where not (t = any(r.flags))) then continue; end if;
        if ev ? 'flags_algum' and not exists (select 1 from jsonb_array_elements_text(ev->'flags_algum') t where t = any(r.flags)) then continue; end if;
        if exists (select 1 from jsonb_array_elements_text(coalesce(ev->'flags_nao', '[]'::jsonb)) t where t = any(r.flags)) then continue; end if;
      end if;
      cands := cands || jsonb_build_array(ev); tot := tot + greatest(0.01, coalesce((ev->>'peso')::numeric, 1));
    end loop;
    exit when jsonb_array_length(cands) > 0;
  end loop;
  if jsonb_array_length(cands) = 0 then raise exception 'O roteiro não tem acontecimento para a etapa %.', r.etapa; end if;
  x := random() * tot;
  for ev in select * from jsonb_array_elements(cands) loop
    x := x - greatest(0.01, coalesce((ev->>'peso')::numeric, 1)); esc := ev; exit when x <= 0;
  end loop;
  update exp_runs set evento_id = esc->>'id', usados = array_append(usados, esc->>'id') where id = _run returning * into r;
  update exp_runs set evento = public.exp_evento_pub(r.dono, r, esc) where id = _run;
end $$;

-- aplica os efeitos de um resultado na expedição (recursos, marcas, mochila); devolve o resumo para a tela
create or replace function public.exp_efeitos(_run bigint, _e jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r exp_runs; c jsonb := public.exp_cfg(); res jsonb := '[]'::jsonb; mo jsonb; n int; k text; v int; d jsonb; nm text;
begin
  select * into r from exp_runs where id = _run for update;
  if _e is null or jsonb_typeof(_e) <> 'object' then return res; end if;
  select def into d from exp_cenarios where id = r.cenario;
  mo := r.mochila;
  if _e ? 'energia' then r.recursos := jsonb_set(r.recursos, '{energia}', to_jsonb(greatest(0, least(9, (r.recursos->>'energia')::int + (_e->>'energia')::int))));
    res := res || to_jsonb(case when (_e->>'energia')::int > 0 then '⚡ +' else '⚡ ' end || (_e->>'energia')); end if;
  if _e ? 'luz' then r.recursos := jsonb_set(r.recursos, '{luz}', to_jsonb(greatest(0, least(9, (r.recursos->>'luz')::int + (_e->>'luz')::int))));
    res := res || to_jsonb(case when (_e->>'luz')::int > 0 then '🔦 +' else '🔦 ' end || (_e->>'luz')); end if;
  if _e ? 'flags' then r.flags := array(select distinct x from unnest(r.flags || array(select jsonb_array_elements_text(_e->'flags'))) x); end if;
  if _e ? 'tags' then r.flags := array(select distinct x from unnest(r.flags || array(select jsonb_array_elements_text(_e->'tags'))) x); end if;
  if _e ? 'tira_flag' then r.flags := array_remove(r.flags, _e->>'tira_flag'); end if;
  if _e ? 'caminho' then r.caminho := _e->>'caminho'; end if;
  if _e ? 'moedas' then
    n := ceil(((_e->'moedas'->>0)::int + floor(random() * ((_e->'moedas'->>1)::int - (_e->'moedas'->>0)::int + 1))) * coalesce((c->>'recompensa_mult')::numeric, 1))::int;
    mo := jsonb_set(mo, '{moedas}', to_jsonb((mo->>'moedas')::int + n)); res := res || to_jsonb('💰 +' || n || ' moedas');
  end if;
  if _e ? 'perde_moedas' then
    n := floor((mo->>'moedas')::int * (_e->>'perde_moedas')::numeric)::int;
    if n > 0 then mo := jsonb_set(mo, '{moedas}', to_jsonb((mo->>'moedas')::int - n)); res := res || to_jsonb('💸 −' || n || ' moedas da mochila'); end if;
  end if;
  if _e ? 'itens' then
    for k, v in select key, value::int from jsonb_each_text(_e->'itens') loop
      mo := jsonb_set(mo, array['itens', k], to_jsonb(coalesce((mo->'itens'->>k)::int, 0) + v));
      res := res || to_jsonb('🎒 ' || v || '× ' || coalesce((select name from pk_items where id = k), k));
    end loop;
  end if;
  if _e ? 'doces' then mo := jsonb_set(mo, '{doces}', to_jsonb((mo->>'doces')::int + (_e->>'doces')::int)); res := res || to_jsonb('🍬 +' || (_e->>'doces') || ' Doce de Forja'); end if;
  if coalesce((_e->>'peca')::boolean, false) then mo := jsonb_set(mo, '{pecas}', to_jsonb((mo->>'pecas')::int + 1)); res := res || to_jsonb('🛡️ Uma peça de equipamento!'::text); end if;
  if _e ? 'reliquia' and not (mo->'reliquias' ? (_e->>'reliquia')) then
    mo := jsonb_set(mo, '{reliquias}', (mo->'reliquias') || to_jsonb(_e->>'reliquia'));
    res := res || to_jsonb('🏺 Relíquia: ' || coalesce(d->'reliquias'->(_e->>'reliquia')->>'nome', _e->>'reliquia'));
  end if;
  if _e ? 'segredo' and not (mo->'segredos' ? (_e->>'segredo')) then
    mo := jsonb_set(mo, '{segredos}', (mo->'segredos') || to_jsonb(_e->>'segredo'));
    res := res || to_jsonb('🔍 Segredo descoberto: ' || coalesce(d->'segredos'->(_e->>'segredo')->>'nome', _e->>'segredo'));
  end if;
  if _e ? 'chefe' and not (mo->'chefes' ? (_e->>'chefe')) then mo := jsonb_set(mo, '{chefes}', (mo->'chefes') || to_jsonb(_e->>'chefe')); res := res || to_jsonb('👑 Guardião derrotado!'::text); end if;
  if _e ? 'avistou' and not (mo->'avistados' ? (_e->>'avistou')) then
    select name into nm from pokemon where id = (_e->>'avistou')::int;
    mo := jsonb_set(mo, '{avistados}', (mo->'avistados') || to_jsonb(_e->>'avistou')); res := res || to_jsonb('👀 Avistou: ' || coalesce(nm, '?'));
  end if;
  update exp_runs set recursos = r.recursos, flags = r.flags, caminho = r.caminho, mochila = mo where id = _run;
  return res;
end $$;

-- entrega a mochila (uma vez só), escreve o Diário e confere as conquistas
create or replace function public.exp_finalizar(_run bigint, _status text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare r exp_runs; d jsonb; mo jsonb; u uuid; novos jsonb := '[]'::jsonb; conq jsonb := '[]'::jsonb; cq jsonb; k text; v int; n int; vtipo text; vch text; ok boolean;
  pr jsonb; sl text; nome text; ehnovo boolean;
begin
  select * into r from exp_runs where id = _run for update;
  if r.id is null or r.entregue_em is not null then return; end if;
  select def into d from exp_cenarios where id = r.cenario;
  mo := r.mochila;
  update exp_runs set status = _status, fim = now(), entregue_em = now(), pendente = null, evento = null where id = _run;
  if _status = 'expirou' then
    update exp_runs set resultado = jsonb_build_object('status', _status, 'mochila', mo, 'entregue', false, 'novos', '[]'::jsonb, 'conquistas', '[]'::jsonb) where id = _run;
    return;
  end if;
  foreach u in array r.membros loop
    -- a mochila
    if (mo->>'moedas')::int > 0 then update characters set coins = coins + (mo->>'moedas')::int where user_id = u; end if;
    perform public.rpg_premiar(u, 0, mo->'itens');
    if (mo->>'doces')::int > 0 then insert into equip_doces(user_id, qty) values (u, (mo->>'doces')::int) on conflict (user_id) do update set qty = equip_doces.qty + (mo->>'doces')::int; end if;
    for n in 1 .. coalesce((mo->>'pecas')::int, 0) loop
      sl := (array['capacete', 'luvas', 'calca', 'peitoral', 'botas'])[1 + floor(random() * 5)::int];
      insert into equip_pecas(user_id, slot, origem) values (u, sl, 'expedicao');
    end loop;
    -- o Diário: o que é novo fica marcado
    for vtipo, vch in
      select 'reliquia', x from jsonb_array_elements_text(mo->'reliquias') x
      union all select 'segredo', x from jsonb_array_elements_text(mo->'segredos') x
      union all select 'chefe', x from jsonb_array_elements_text(mo->'chefes') x
      union all select 'avistado', x from jsonb_array_elements_text(mo->'avistados') x
      union all select 'caminho', r.cenario || ':' || r.caminho where r.caminho is not null
      union all select 'expedicao', r.cenario where _status = 'concluida'
    loop
      ehnovo := not exists (select 1 from exp_diario dd where dd.user_id = u and dd.tipo = vtipo and dd.chave = vch);
      insert into exp_diario(user_id, tipo, chave, cenario) values (u, vtipo, vch, r.cenario)
      on conflict (user_id, tipo, chave) do update set qtd = exp_diario.qtd + 1, ultima_em = now();
      if ehnovo and vtipo in ('reliquia', 'segredo', 'chefe', 'avistado') then
        nome := case vtipo when 'reliquia' then d->'reliquias'->vch->>'nome' when 'segredo' then d->'segredos'->vch->>'nome' when 'chefe' then 'Guardião da ' || (d->>'nome')
                          else (select name from pokemon where id = vch::int) end;
        novos := novos || jsonb_build_array(jsonb_build_object('tipo', vtipo, 'chave', vch, 'nome', nome));
      end if;
    end loop;
    -- conquistas (uma vez cada, prêmio uma vez só)
    for cq in select * from jsonb_array_elements(coalesce(d->'conquistas', '[]'::jsonb)) loop
      if exists (select 1 from exp_diario where user_id = u and exp_diario.tipo = 'conquista' and chave = r.cenario || ':' || (cq->>'id')) then continue; end if;
      n := case cq->'cond'->>'tipo'
        when 'concluidas' then coalesce((select qtd from exp_diario where user_id = u and exp_diario.tipo = 'expedicao' and chave = r.cenario), 0)
        when 'caminhos' then (select count(*) from exp_diario where user_id = u and exp_diario.tipo = 'caminho' and chave like r.cenario || ':%')
        when 'reliquias' then (select count(*) from exp_diario where user_id = u and exp_diario.tipo = 'reliquia' and cenario = r.cenario)
        when 'segredos' then (select count(*) from exp_diario where user_id = u and exp_diario.tipo = 'segredo' and cenario = r.cenario)
        when 'chefes' then (select count(*) from exp_diario where user_id = u and exp_diario.tipo = 'chefe' and cenario = r.cenario)
        else 0 end;
      if n < coalesce((cq->'cond'->>'min')::int, 1) then continue; end if;
      insert into exp_diario(user_id, tipo, chave, cenario) values (u, 'conquista', r.cenario || ':' || (cq->>'id'), r.cenario) on conflict do nothing;
      pr := coalesce(cq->'premio', '{}'::jsonb);
      if coalesce((pr->>'moedas')::int, 0) > 0 then update characters set coins = coins + (pr->>'moedas')::int where user_id = u; end if;
      if coalesce((pr->>'doces')::int, 0) > 0 then insert into equip_doces(user_id, qty) values (u, (pr->>'doces')::int) on conflict (user_id) do update set qty = equip_doces.qty + (pr->>'doces')::int; end if;
      if coalesce((pr->>'peca')::boolean, false) then insert into equip_pecas(user_id, slot, origem) values (u, (array['capacete', 'luvas', 'calca', 'peitoral', 'botas'])[1 + floor(random() * 5)::int], 'conquista'); end if;
      if jsonb_typeof(pr->'loja') = 'array' and jsonb_array_length(pr->'loja') > 0 then
        perform public.gift_give(u, '🏆 Conquista da expedição: ' || (cq->>'nome'), array(select jsonb_array_elements_text(pr->'loja')), 0, 0, 0, '{}'::jsonb, null);
      end if;
      conq := conq || jsonb_build_array(jsonb_build_object('id', cq->>'id', 'nome', cq->>'nome', 'desc', cq->>'desc', 'premio', pr, 'titulo', cq->>'titulo'));
      insert into event_log(user_id, kind, message) select u, 'expedicao', '🏆 ' || name || ' ganhou a conquista "' || (cq->>'nome') || '" na ' || (d->>'nome') || '!' from characters where user_id = u;
    end loop;
  end loop;
  update exp_runs set resultado = jsonb_build_object('status', _status, 'mochila', mo, 'entregue', true, 'novos', novos, 'conquistas', conq,
    'moedas', (mo->>'moedas')::int) where id = _run;
  insert into event_log(user_id, kind, message) select r.dono, 'expedicao', case _status
    when 'concluida' then '⛏️ ' || name || ' voltou da ' || (d->>'nome') || case when jsonb_array_length(mo->'chefes') > 0 then ' depois de vencer o guardião!' else ' com a mochila cheia!' end
    when 'exausta' then '😮‍💨 ' || name || ' saiu exausto(a) da ' || (d->>'nome') || '.'
    else '🚪 ' || name || ' voltou mais cedo da ' || (d->>'nome') || '.' end from characters where user_id = r.dono;
end $$;

-- depois de cada resultado: acabou a energia, chegou ao fim, ou próxima etapa
create or replace function public.exp_avancar(_run bigint, _fim boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare r exp_runs; et int;
begin
  select * into r from exp_runs where id = _run for update;
  select coalesce((def->>'etapas')::int, 5) into et from exp_cenarios where id = r.cenario;
  if _fim or r.etapa >= et then perform public.exp_finalizar(_run, 'concluida');
  elsif coalesce((r.recursos->>'energia')::int, 0) <= 0 then perform public.exp_finalizar(_run, 'exausta');
  else update exp_runs set etapa = etapa + 1, status = 'andando' where id = _run; perform public.exp_sortear(_run); end if;
end $$;

-- a luta da expedição: a mesma batalha da Aventura (modo treino), com quem estiver na frente da equipe
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
  wild := public.npc_mon(sp, lv);
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

-- fim da luta (chamado pelo rpg_after): aplica o que acontece se venceu ou perdeu, a captura e segue a expedição
create or replace function public.exp_pos_batalha(_run bigint, _bid uuid, _won boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r exp_runs; c jsonb := public.exp_cfg(); p jsonb; ef jsonb; res jsonb; enc uuid; fim boolean;
begin
  select * into r from exp_runs where id = _run for update;
  if r.id is null or r.status <> 'batalha' or r.batalha is distinct from _bid then return null; end if;
  p := r.pendente; ef := case when _won then coalesce(p->'se_venceu', '{}'::jsonb) else coalesce(p->'se_perdeu', '{}'::jsonb) end;
  update exp_runs set status = 'andando', pendente = null, batalha = null where id = _run;
  res := public.exp_efeitos(_run, ef);
  if _won and coalesce((p->>'captura')::boolean, false) and coalesce((c->>'captura_on')::boolean, true) then
    insert into encounters(user_id, move_id, species_id, level, throws_left)
    values (r.dono, gen_random_uuid(), (p->>'especie')::int, greatest(1, (p->>'nivel')::int - 2), (public.pk_cfg()->'capture'->>'throws')::int)
    returning id into enc;
    update exp_runs set encontro = enc where id = _run;
    res := res || to_jsonb('🎯 Dá para tentar capturar!'::text);
  end if;
  perform public.exp_efeitos(_run, jsonb_build_object('avistou', p->>'especie'));
  update exp_runs set ultimo = jsonb_build_object('txt', case when _won then '🏆 Você venceu a luta!' else '💥 Você perdeu a luta… mas segue na mina.' end, 'resumo', res, 'batalha', true, 'venceu', _won),
         log = log || jsonb_build_array(jsonb_build_object('etapa', etapa, 'luta', p->>'especie', 'venceu', _won, 'em', now())) where id = _run;
  fim := coalesce((ef->>'fim')::boolean, false);
  perform public.exp_avancar(_run, fim);
  return jsonb_build_object('exp', _run, 'venceu', _won, 'resumo', res);
end $$;

create or replace function public.exp_tick(_uid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare r exp_runs;
begin
  for r in select * from exp_runs where dono = _uid and status in ('andando', 'batalha') and expira < now() loop
    perform public.exp_finalizar(r.id, 'expirou');
  end loop;
end $$;

-- o que o site mostra da expedição (sem as chances nem os resultados escondidos)
create or replace function public.exp_pub(_r exp_runs) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare d jsonb;
begin
  select def into d from exp_cenarios where id = _r.cenario;
  return jsonb_build_object('id', _r.id, 'cenario', _r.cenario, 'nome', d->>'nome', 'ic', d->>'ic', 'status', _r.status, 'etapa', _r.etapa, 'etapas', coalesce((d->>'etapas')::int, 5),
    'recursos', _r.recursos, 'recursos_ini', d->'recursos', 'caminho', _r.caminho,
    'evento', case when _r.status = 'andando' and _r.evento_id is not null and _r.evento is not null   -- recalculado a cada olhada (equipe e recursos podem ter mudado)
                   then public.exp_evento_pub(_r.dono, _r, (select x.v from jsonb_array_elements(d->'eventos') x(v) where x.v->>'id' = _r.evento_id)) else _r.evento end, 'ultimo', _r.ultimo, 'mochila', _r.mochila, 'expira', _r.expira,
    'batalha', case when _r.status = 'batalha' then _r.batalha end,
    'encontro', (select to_jsonb(e) from encounters e where e.id = _r.encontro and e.status = 'aberto'),
    'resultado', _r.resultado, 'log', _r.log,
    'reliquias_nomes', coalesce((select jsonb_object_agg(k, d->'reliquias'->k->>'nome') from jsonb_array_elements_text(_r.mochila->'reliquias') k), '{}'::jsonb),
    'segredos_nomes', coalesce((select jsonb_object_agg(k, d->'segredos'->k->>'nome') from jsonb_array_elements_text(_r.mochila->'segredos') k), '{}'::jsonb));
end $$;
revoke execute on function public.exp_cond_ok(uuid, exp_runs, jsonb), public.exp_evento_pub(uuid, exp_runs, jsonb), public.exp_sortear(bigint), public.exp_efeitos(bigint, jsonb),
  public.exp_finalizar(bigint, text), public.exp_avancar(bigint, boolean), public.exp_batalha(bigint, jsonb), public.exp_pos_batalha(bigint, uuid, boolean), public.exp_tick(uuid), public.exp_pub(exp_runs)
  from public, anon, authenticated;

-- ---------- funções do site ----------
create or replace function public.exp_lista() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.exp_cfg();
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  perform public.exp_tick(uid);
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'limite_dia', (c->>'limite_dia')::int,
    'hoje', (select count(*) from exp_runs where dono = uid and dia = public.game_today()),
    'cenarios', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'nome', x.def->>'nome', 'ic', x.def->>'ic', 'historia', x.def->>'historia', 'local', x.def->>'local',
        'regiao', x.def->>'regiao', 'dificuldade', x.def->>'dificuldade', 'premios_txt', x.def->'premios_txt', 'etapas', coalesce((x.def->>'etapas')::int, 5), 'recursos', x.def->'recursos',
        'reliquias_total', (select count(*) from jsonb_object_keys(coalesce(x.def->'reliquias', '{}'::jsonb))),
        'segredos_total', (select count(*) from jsonb_object_keys(coalesce(x.def->'segredos', '{}'::jsonb))),
        'reliquias', (select count(*) from exp_diario where user_id = uid and tipo = 'reliquia' and cenario = x.id),
        'segredos', (select count(*) from exp_diario where user_id = uid and tipo = 'segredo' and cenario = x.id),
        'concluidas', coalesce((select qtd from exp_diario where user_id = uid and tipo = 'expedicao' and chave = x.id), 0)) order by x.ordem)
      from exp_cenarios x where x.ativo or public.is_admin()), '[]'::jsonb));
end $$;

create or replace function public.exp_estado() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); r exp_runs; ult exp_runs;
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  perform public.exp_tick(uid);
  select * into r from exp_runs where uid = any(membros) and status in ('andando', 'batalha') order by id desc limit 1;
  select * into ult from exp_runs where uid = any(membros) and status not in ('andando', 'batalha') order by id desc limit 1;
  return jsonb_build_object('run', case when r.id is null then null else public.exp_pub(r) end,
    'ultimo_fim', case when ult.id is null then null else public.exp_pub(ult) end);
end $$;

create or replace function public.exp_iniciar(_cenario text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.exp_cfg(); x exp_cenarios; n int; rid bigint;
begin
  if not coalesce((c->>'on')::boolean, true) and not public.is_admin() then raise exception 'As Expedições estão fechadas no momento.'; end if;
  perform public.exp_tick(uid);
  select * into x from exp_cenarios where id = _cenario;
  if x.id is null or (not x.ativo and not public.is_admin()) then raise exception 'Expedição não encontrada.'; end if;
  if exists (select 1 from exp_runs where uid = any(membros) and status in ('andando', 'batalha')) then raise exception 'Você já tem uma expedição em andamento. Termine (ou volte) antes de começar outra.'; end if;
  select count(*) into n from exp_runs where dono = uid and dia = public.game_today();
  if n >= (c->>'limite_dia')::int then raise exception 'Você já fez % expedições hoje. Volte amanhã!', c->>'limite_dia'; end if;
  insert into exp_runs(cenario, dono, membros, recursos, dia, expira)
  values (x.id, uid, array[uid], coalesce(x.def->'recursos', '{"energia": 5, "luz": 3}'::jsonb), public.game_today(), now() + make_interval(hours => (c->>'expira_horas')::int))
  returning id into rid;
  perform public.exp_sortear(rid);
  return public.exp_estado();
end $$;

create or replace function public.exp_escolher(_run bigint, _opcao text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.exp_cfg(); r exp_runs; d jsonb; ev jsonb; o jsonb; rs jsonb; esc jsonb; tot numeric := 0; x numeric; w numeric;
  md jsonb; ef jsonb; res jsonb; bid uuid; fim boolean;
begin
  perform public.exp_tick(uid);
  select * into r from exp_runs where id = _run for update;
  if r.id is null or not (uid = any(r.membros)) then raise exception 'Expedição não encontrada.'; end if;
  if r.dono <> uid then raise exception 'Só quem lidera a expedição escolhe.'; end if;
  if r.status = 'batalha' then raise exception 'Termine a luta primeiro.'; end if;
  if r.status <> 'andando' then raise exception 'Essa expedição já terminou.'; end if;
  select def into d from exp_cenarios where id = r.cenario;
  select x.v into ev from jsonb_array_elements(d->'eventos') x(v) where x.v->>'id' = r.evento_id;
  select x.v into o from jsonb_array_elements(ev->'opcoes') x(v) where x.v->>'id' = _opcao;
  if o is null then raise exception 'Essa escolha não existe aqui.'; end if;
  if not public.exp_cond_ok(uid, r, o->'req') then raise exception 'Você não pode escolher isso agora.'; end if;
  if (r.recursos->>'energia')::int < coalesce((o->'custo'->>'energia')::int, 0) or (r.recursos->>'luz')::int < coalesce((o->'custo'->>'luz')::int, 0) then raise exception 'Faltam recursos para essa escolha.'; end if;
  -- o Pokémon do encontro anterior que ninguém tentou capturar foge
  update encounters set status = 'fugiu', resolved_at = now() where id = r.encontro and status = 'aberto';
  -- paga o custo
  update exp_runs set encontro = null, recursos = jsonb_set(jsonb_set(recursos, '{energia}', to_jsonb((recursos->>'energia')::int - coalesce((o->'custo'->>'energia')::int, 0))),
         '{luz}', to_jsonb((recursos->>'luz')::int - coalesce((o->'custo'->>'luz')::int, 0))) where id = _run returning * into r;
  -- sorteia o resultado (os pesos mudam com o que já aconteceu, o herói, os golpes e os equipamentos; o "ruim" pesa com a dificuldade)
  for rs in select * from jsonb_array_elements(o->'resultados') loop
    w := greatest(0, coalesce((rs->>'peso')::numeric, 1));
    for md in select * from jsonb_array_elements(coalesce(rs->'mod', '[]'::jsonb)) loop
      if public.exp_cond_ok(uid, r, md - 'peso') then w := greatest(0, w + coalesce((md->>'peso')::numeric, 0)); end if;
    end loop;
    if coalesce((rs->>'ruim')::boolean, false) then w := w * greatest(0, coalesce((c->>'dificuldade')::numeric, 1)); end if;
    tot := tot + w;
  end loop;
  x := random() * tot;
  for rs in select * from jsonb_array_elements(o->'resultados') loop
    w := greatest(0, coalesce((rs->>'peso')::numeric, 1));
    for md in select * from jsonb_array_elements(coalesce(rs->'mod', '[]'::jsonb)) loop
      if public.exp_cond_ok(uid, r, md - 'peso') then w := greatest(0, w + coalesce((md->>'peso')::numeric, 0)); end if;
    end loop;
    if coalesce((rs->>'ruim')::boolean, false) then w := w * greatest(0, coalesce((c->>'dificuldade')::numeric, 1)); end if;
    esc := rs; x := x - w; exit when x <= 0 and w > 0;
  end loop;
  ef := coalesce(esc->'efeitos', '{}'::jsonb);
  -- encontro especial desligado pelo admin: o Pokémon some
  if ef ? 'batalha' and coalesce((ef->'batalha'->>'especial')::boolean, false) and not coalesce((c->>'especiais_on')::boolean, true) then ef := ef - 'batalha' - 'avistou'; end if;
  res := public.exp_efeitos(_run, ef - 'batalha' - 'fim');
  update exp_runs set ultimo = jsonb_build_object('txt', esc->>'txt', 'resumo', res, 'evento', ev->>'titulo', 'opcao', o->>'txt'),
         log = log || jsonb_build_array(jsonb_build_object('etapa', etapa, 'evento', ev->>'id', 'titulo', ev->>'titulo', 'opcao', o->>'id', 'escolha', o->>'txt', 'txt', esc->>'txt', 'em', now())),
         evento = null where id = _run;
  if ef ? 'batalha' then
    bid := public.exp_batalha(_run, ef->'batalha');
    if bid is not null then return public.exp_estado() || jsonb_build_object('battle', bid); end if;
    -- ninguém na equipe pode lutar: conta como derrota
    update exp_runs set status = 'batalha', pendente = ef->'batalha', batalha = null where id = _run;
    perform public.exp_pos_batalha(_run, null, false);
    update exp_runs set ultimo = jsonb_set(ultimo, '{txt}', to_jsonb('Nenhum Pokémon da equipe tinha vida para lutar. Você recua do perigo.'::text)) where id = _run;
    return public.exp_estado();
  end if;
  fim := coalesce((ef->>'fim')::boolean, false);
  perform public.exp_avancar(_run, fim);
  return public.exp_estado();
end $$;

-- voltar mais cedo: sai com o que já está na mochila
create or replace function public.exp_recuar(_run bigint) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); r exp_runs;
begin
  select * into r from exp_runs where id = _run and dono = uid for update;
  if r.id is null then raise exception 'Expedição não encontrada.'; end if;
  if r.status = 'batalha' then raise exception 'Termine a luta primeiro.'; end if;
  if r.status <> 'andando' then raise exception 'Essa expedição já terminou.'; end if;
  update encounters set status = 'fugiu', resolved_at = now() where id = r.encontro and status = 'aberto';
  perform public.exp_finalizar(_run, 'recuou');
  return public.exp_estado();
end $$;

-- o Diário do Explorador (o que ainda não achou aparece como ???)
create or replace function public.exp_diario_ver() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'nome', x.def->>'nome', 'ic', x.def->>'ic',
    'concluidas', coalesce((select qtd from exp_diario where user_id = uid and tipo = 'expedicao' and chave = x.id), 0),
    'tentativas', (select count(*) from exp_runs where dono = uid and cenario = x.id and status <> 'andando' and status <> 'batalha'),
    'caminhos', (select coalesce(jsonb_agg(split_part(chave, ':', 2)), '[]'::jsonb) from exp_diario where user_id = uid and tipo = 'caminho' and chave like x.id || ':%'),
    'reliquias', (select jsonb_agg(jsonb_build_object('id', k, 'achou', a.chave is not null, 'nome', case when a.chave is not null then x.def->'reliquias'->k->>'nome' else '???' end,
                    'desc', case when a.chave is not null then x.def->'reliquias'->k->>'desc' end, 'em', a.primeira_em))
                  from jsonb_object_keys(coalesce(x.def->'reliquias', '{}'::jsonb)) k left join exp_diario a on a.user_id = uid and a.tipo = 'reliquia' and a.chave = k),
    'segredos', (select jsonb_agg(jsonb_build_object('id', k, 'achou', a.chave is not null, 'nome', case when a.chave is not null then x.def->'segredos'->k->>'nome' else '???' end, 'em', a.primeira_em))
                  from jsonb_object_keys(coalesce(x.def->'segredos', '{}'::jsonb)) k left join exp_diario a on a.user_id = uid and a.tipo = 'segredo' and a.chave = k),
    'chefes', (select count(*) from exp_diario where user_id = uid and tipo = 'chefe' and cenario = x.id),
    'avistados', (select coalesce(jsonb_agg(chave::int), '[]'::jsonb) from exp_diario where user_id = uid and tipo = 'avistado' and cenario = x.id),
    'conquistas', (select jsonb_agg(jsonb_build_object('id', cq->>'id', 'nome', cq->>'nome', 'desc', cq->>'desc', 'titulo', cq->>'titulo', 'premio', cq->'premio',
                     'tem', exists (select 1 from exp_diario where user_id = uid and tipo = 'conquista' and chave = x.id || ':' || (cq->>'id')))) from jsonb_array_elements(coalesce(x.def->'conquistas', '[]'::jsonb)) cq),
    'historico', (select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'status', h.status, 'caminho', h.caminho, 'fim', h.fim, 'moedas', (h.mochila->>'moedas')::int,
                     'reliquias', jsonb_array_length(h.mochila->'reliquias'), 'chefe', jsonb_array_length(h.mochila->'chefes') > 0) order by h.id desc), '[]'::jsonb)
                  from (select * from exp_runs where dono = uid and cenario = x.id and status not in ('andando', 'batalha') order by id desc limit 15) h))
    order by x.ordem) from exp_cenarios x where x.ativo or public.is_admin()), '[]'::jsonb);
end $$;

-- admin: ver e editar os roteiros (com conferência e Auditoria)
create or replace function public.admin_exp_cenarios() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'ativo', ativo, 'ordem', ordem, 'def', def) order by ordem) from exp_cenarios), '[]'::jsonb);
end $$;
create or replace function public.admin_exp_cenario_salvar(_id text, _def jsonb, _ativo boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare et int; i int; ev jsonb; o jsonb; antes jsonb;
begin
  perform public.assert_admin();
  if _id !~ '^[a-z0-9_]{2,30}$' then raise exception 'O código da expedição deve ter só letras minúsculas, números e _.'; end if;
  if jsonb_typeof(_def) <> 'object' or jsonb_typeof(_def->'eventos') <> 'array' or coalesce(_def->>'nome', '') = '' then raise exception 'O roteiro precisa de "nome" e da lista "eventos".'; end if;
  et := coalesce((_def->>'etapas')::int, 5);
  if et not between 1 and 10 then raise exception 'Use de 1 a 10 etapas.'; end if;
  for i in 1 .. et loop
    if not exists (select 1 from jsonb_array_elements(_def->'eventos') e where to_jsonb(i) <@ (e->'etapa')) then raise exception 'Falta acontecimento para a etapa %.', i; end if;
  end loop;
  for ev in select * from jsonb_array_elements(_def->'eventos') loop
    if coalesce(ev->>'id', '') = '' or jsonb_typeof(ev->'etapa') <> 'array' or jsonb_typeof(ev->'opcoes') <> 'array' or jsonb_array_length(ev->'opcoes') = 0 then
      raise exception 'Acontecimento sem id, etapa ou opções: %', left(ev::text, 120); end if;
    for o in select * from jsonb_array_elements(ev->'opcoes') loop
      if coalesce(o->>'id', '') = '' or jsonb_typeof(o->'resultados') <> 'array' or jsonb_array_length(o->'resultados') = 0 then
        raise exception 'Opção sem id ou sem resultados em "%".', ev->>'id'; end if;
    end loop;
  end loop;
  select def into antes from exp_cenarios where id = _id;
  insert into exp_cenarios(id, def, ativo) values (_id, _def, coalesce(_ativo, true))
  on conflict (id) do update set def = excluded.def, ativo = excluded.ativo, atualizado = now();
  insert into admin_audit_log(admin_id, action, target, after) values (auth.uid(), 'exp_cenario', _id, jsonb_build_object('ativo', _ativo, 'tinha_antes', antes is not null, 'eventos', jsonb_array_length(_def->'eventos')));
  return public.admin_exp_cenarios();
end $$;

grant execute on function public.exp_lista(), public.exp_estado(), public.exp_iniciar(text), public.exp_escolher(bigint, text), public.exp_recuar(bigint), public.exp_diario_ver(),
  public.admin_exp_cenarios(), public.admin_exp_cenario_salvar(text, jsonb, boolean) to authenticated;

-- ---------- o primeiro roteiro: Mina Esquecida (o admin pode editar depois) ----------
insert into public.exp_cenarios(id, def, ativo, ordem) values ('mina', '{"id": "mina", "nome": "Mina Esquecida", "regiao": "pedreira", "local": "Gruta da Pedreira (Aventura)", "dificuldade": "Média", "ic": "⛏️", "historia": "Há muitos anos, mineradores da Pedreira acharam uma passagem subterrânea cheia de cristais raros. Depois de barulhos estranhos, luzes que se mexiam sozinhas e um sumiço que ninguém explica, a mina foi fechada às pressas. Dizem que algo enorme protege um tesouro lá no fundo.", "premios_txt": ["Moedas", "Itens da bolsa", "Doces de Forja", "Peças de equipamento (raro)", "Relíquias para o Diário", "Pokémon especiais para capturar"], "recursos": {"energia": 5, "luz": 3}, "etapas": 5, "reliquias": {"lampiao": {"nome": "Lampião do Capataz", "desc": "Ainda tem um resto de querosene. Alguém saiu daqui com muita pressa."}, "selo": {"nome": "Selo da Porta Antiga", "desc": "Um disco de pedra com três símbolos gastos: fogo, água e folha."}, "cristal_estelar": {"nome": "Cristal Estelar", "desc": "Brilha mesmo no escuro total. Parece pulsar devagar."}, "picareta": {"nome": "Picareta de Prata", "desc": "Gravado no cabo: ''para o próximo que tiver coragem''."}, "coracao": {"nome": "Coração da Montanha", "desc": "Uma pedra quente que o guardião protegia. Dá para sentir um batimento."}, "diario_mineiro": {"nome": "Diário do Minerador", "desc": "A última página diz: ''não acenda a luz perto do veio azul''."}}, "segredos": {"veio_azul": {"nome": "O veio azul que canta"}, "trilho_secreto": {"nome": "O trilho que leva ao fundo"}, "sala_selada": {"nome": "A sala atrás da porta dos símbolos"}, "minerador_salvo": {"nome": "O minerador que voltou para casa"}, "guardiao_calmo": {"nome": "O guardião que não precisou lutar"}}, "conquistas": [{"id": "primeira_descida", "nome": "Primeira descida", "desc": "Termine a Mina Esquecida pela primeira vez.", "cond": {"tipo": "concluidas", "min": 1}, "premio": {"moedas": 100}}, {"id": "tres_caminhos", "nome": "Conhece todas as entradas", "desc": "Entre na mina pelos 3 caminhos diferentes.", "cond": {"tipo": "caminhos", "min": 3}, "premio": {"moedas": 150, "doces": 1}}, {"id": "colecionador", "nome": "Colecionador de relíquias", "desc": "Encontre 4 relíquias diferentes.", "cond": {"tipo": "reliquias", "min": 4}, "premio": {"moedas": 200, "doces": 2}, "titulo": "Arqueólogo da Pedreira"}, {"id": "guardiao", "nome": "Venceu o Guardião", "desc": "Derrote o guardião da câmara final.", "cond": {"tipo": "chefes", "min": 1}, "premio": {"moedas": 250, "doces": 2}, "titulo": "Domador da Montanha"}, {"id": "todos_segredos", "nome": "A mina não tem mais segredos", "desc": "Descubra os 5 segredos da Mina Esquecida.", "cond": {"tipo": "segredos", "min": 5}, "premio": {"moedas": 500, "doces": 3, "peca": true}, "titulo": "Lenda da Mina Esquecida"}], "eventos": [{"id": "entrada", "etapa": [1], "peso": 1, "cena": "entrada", "titulo": "A boca da mina", "texto": "Atrás das tábuas podres, o ar é frio e cheira a ferrugem. Três caminhos se abrem na escuridão: um túnel com trilhos, uma fenda que brilha em azul e um poço fundo com uma corda velha.", "opcoes": [{"id": "tunel", "txt": "🚃 Túnel abandonado: parece mais seguro, e tem pegadas de Pokémon.", "resultados": [{"peso": 1, "txt": "Você segue os trilhos enferrujados. O túnel é largo e silencioso… quase demais.", "efeitos": {"tags": ["tunel"], "caminho": "tunel"}}]}, {"id": "cristais", "txt": "💎 Passagem dos cristais: misteriosa, cheia de brilho e de coisas para achar.", "custo": {"luz": 1}, "resultados": [{"peso": 1, "txt": "Você se espreme pela fenda. As paredes refletem a sua luz em mil pontinhos azuis.", "efeitos": {"tags": ["cristais"], "caminho": "cristais"}}]}, {"id": "poco", "txt": "🕳️ Poço profundo: perigoso, mas dizem que esconde salas secretas.", "custo": {"energia": 1}, "resultados": [{"peso": 1, "txt": "Você desce pela corda até o fundo do poço. Lá em cima, a luz do dia vira um pontinho.", "efeitos": {"tags": ["poco"], "caminho": "poco"}}]}]}, {"id": "carrinho", "etapa": [2], "tags_req": ["tunel"], "peso": 10, "cena": "carrinho", "titulo": "O carrinho tombado", "texto": "Um carrinho de minério está caído sobre o trilho, bloqueando metade do túnel. Tem alguma coisa brilhando lá dentro.", "opcoes": [{"id": "empurrar", "txt": "Empurrar o carrinho de volta para o trilho", "custo": {"energia": 1}, "resultados": [{"peso": 6, "txt": "Com um rangido, o carrinho volta para o trilho. Mais à frente, você vê que o trilho desce para o fundo da mina…", "efeitos": {"flags": ["trilho_livre"], "segredo": "trilho_secreto"}}, {"peso": 4, "ruim": true, "txt": "O carrinho escapa e desce o túnel batendo em tudo. O barulho ecoa pela mina inteira.", "efeitos": {"flags": ["barulho"]}}]}, {"id": "revistar", "txt": "Revistar o carrinho", "resultados": [{"peso": 5, "txt": "No meio do minério, um saquinho esquecido de moedas.", "efeitos": {"moedas": [25, 60]}}, {"peso": 3, "txt": "Era um Geodude dormindo no minério, e ele não gostou de ser acordado!", "efeitos": {"batalha": {"especies": [74], "delta": [-2, 1], "se_venceu": {"moedas": [20, 40]}, "se_perdeu": {"energia": -1}}}}, {"peso": 2, "txt": "Embaixo do carrinho, um lampião antigo ainda funciona.", "efeitos": {"luz": 1, "reliquia": "lampiao"}}]}, {"id": "seguir", "txt": "Passar pelo cantinho sem mexer em nada", "resultados": [{"peso": 1, "txt": "Você passa espremido e segue em silêncio. Nada acontece, e isso já é alguma coisa.", "efeitos": {"flags": ["cauteloso"]}}]}]}, {"id": "pegadas", "etapa": [2, 3], "tags_req": ["tunel"], "peso": 8, "cena": "tunel", "titulo": "Pegadas no pó", "texto": "Marcas grandes e redondas no chão de pó. Algo pesado passou por aqui há pouco tempo.", "opcoes": [{"id": "seguir", "txt": "Seguir as pegadas", "resultados": [{"peso": 6, "txt": "As pegadas terminam num Pokémon selvagem que vigia o túnel!", "efeitos": {"batalha": {"especies": [95, 66, 111, 27], "delta": [-1, 2], "captura": true, "se_venceu": {"moedas": [15, 35]}, "se_perdeu": {"energia": -1}}}}, {"peso": 2, "txt": "As pegadas levam a um ninho vazio, com uma relíquia no meio.", "efeitos": {"reliquia": "picareta"}}]}, {"id": "apagar", "txt": "Apagar os seus rastros e andar em silêncio", "custo": {"energia": 1}, "resultados": [{"peso": 1, "txt": "Você anda devagar, pisando nas pedras. Se algo morar lá no fundo, não vai te ouvir chegar.", "efeitos": {"flags": ["furtivo"]}}]}, {"id": "ignorar", "txt": "Ignorar e seguir o trilho", "resultados": [{"peso": 1, "txt": "Melhor não procurar briga. O trilho continua.", "efeitos": {}}]}]}, {"id": "cristais_azuis", "etapa": [2], "tags_req": ["cristais"], "peso": 10, "cena": "cristais", "titulo": "Os cristais azuis", "texto": "A passagem se abre numa galeria coberta de cristais azuis. Eles brilham sozinhos, e a luz parece vir de algum lugar mais fundo.", "opcoes": [{"id": "coletar", "txt": "Coletar os cristais", "custo": {"energia": 1}, "resultados": [{"peso": 6, "txt": "Você enche a mochila de lascas de cristal. Vão valer umas boas moedas.", "efeitos": {"moedas": [40, 80], "flags": ["cristal"]}}, {"peso": 4, "ruim": true, "txt": "Um cristal racha com um estalo alto. A galeria inteira vibra… e algo lá no fundo acorda.", "efeitos": {"moedas": [20, 40], "flags": ["barulho", "cristal"]}}]}, {"id": "investigar", "txt": "Investigar de onde vem a luz", "custo": {"luz": 1}, "resultados": [{"peso": 7, "txt": "Seguindo o brilho, você acha um veio de cristal que parece cantar baixinho. Ninguém chegou aqui antes.", "efeitos": {"flags": ["veio"], "segredo": "veio_azul"}}, {"peso": 3, "txt": "A luz vinha de um Pokémon escondido entre os cristais!", "efeitos": {"batalha": {"especies": [81, 100, 120], "delta": [-1, 1], "captura": true, "se_venceu": {"flags": ["veio"]}, "se_perdeu": {"luz": -1}}}}]}, {"id": "respeitar", "txt": "Passar sem tocar em nada", "resultados": [{"peso": 1, "txt": "Você passa devagar e não toca em nenhum cristal. Por um instante, eles parecem brilhar mais forte, como se agradecessem.", "efeitos": {"flags": ["respeito"]}}]}]}, {"id": "minerador", "etapa": [2, 3], "tags_req": ["cristais"], "peso": 7, "cena": "minerador", "titulo": "O minerador perdido", "texto": "Encostado na parede, um minerador idoso, com o capacete torto. ''Faz dias que não acho a saída'', ele diz, com a voz fraca.", "opcoes": [{"id": "ajudar", "txt": "Dividir a sua comida e ensinar o caminho de volta", "custo": {"energia": 1}, "resultados": [{"peso": 1, "txt": "Ele se levanta, agradece e, antes de ir, desenha um mapa no seu braço com carvão: ''a câmara tem uma entrada pelos fundos''.", "efeitos": {"flags": ["aliado"], "segredo": "minerador_salvo", "reliquia": "diario_mineiro"}}]}, {"id": "perguntar", "txt": "Perguntar o que ele sabe da mina", "resultados": [{"peso": 6, "txt": "''O guardião não gosta de barulho'', ele sussurra. ''E adora cristais.''", "efeitos": {"flags": ["dica"]}}, {"peso": 4, "txt": "Ele fala coisas sem sentido sobre luzes que andam. Mas te dá umas moedas pela companhia.", "efeitos": {"moedas": [15, 30]}}]}, {"id": "deixar", "txt": "Seguir em frente (alguém vai achar ele)", "resultados": [{"peso": 1, "txt": "Você segue. A voz dele vai ficando para trás até sumir.", "efeitos": {"flags": ["frio"]}}]}]}, {"id": "corda", "etapa": [2], "tags_req": ["poco"], "peso": 10, "cena": "poco", "titulo": "A corda podre", "texto": "No fundo do poço há um segundo poço, ainda mais fundo. A corda que desce nele está cheia de fiapos.", "opcoes": [{"id": "descer", "txt": "Descer assim mesmo", "resultados": [{"peso": 6, "txt": "A corda aguenta. Lá embaixo, uma porta antiga coberta de símbolos.", "efeitos": {"flags": ["fundo"]}}, {"peso": 4, "ruim": true, "txt": "A corda arrebenta no meio do caminho! Você cai, se machuca, mas chega ao fundo.", "efeitos": {"energia": -2, "flags": ["fundo"]}}]}, {"id": "amarrar", "txt": "Reforçar a corda antes", "custo": {"luz": 1}, "resultados": [{"peso": 1, "txt": "Demora, e a sua luz gasta um bom tanto, mas você desce com segurança.", "efeitos": {"flags": ["fundo", "cauteloso"]}}]}, {"id": "golpe_forca", "txt": "💪 Usar Força para descer pelas pedras", "req": {"golpe": 70}, "resultados": [{"peso": 1, "txt": "Seu Pokémon abre caminho entre as pedras. Rápido, seguro e ainda sobra energia.", "efeitos": {"flags": ["fundo"], "energia": 1}}]}]}, {"id": "bau", "etapa": [2, 3], "tags_req": ["poco"], "peso": 8, "cena": "bau", "titulo": "O baú com cadeado", "texto": "Um baú de ferro, trancado com um cadeado enorme e enferrujado.", "opcoes": [{"id": "arrombar", "txt": "Arrombar o cadeado", "custo": {"energia": 1}, "resultados": [{"peso": 5, "txt": "O cadeado cede! Dentro, itens que alguém guardou com carinho.", "efeitos": {"itens": {"super_pocao": 1, "reviver": 1}}}, {"peso": 3, "ruim": true, "txt": "Era uma armadilha: uma nuvem de pó apaga a sua luz.", "efeitos": {"luz": -1}}, {"peso": 2, "txt": "Lá dentro, um Doce de Forja ainda embrulhado!", "efeitos": {"doces": 1}}]}, {"id": "chave", "txt": "Procurar a chave por perto", "custo": {"luz": 1}, "resultados": [{"peso": 6, "txt": "A chave estava pendurada num prego, e ainda tem outra presa no mesmo chaveiro…", "efeitos": {"itens": {"super_pocao": 1}, "flags": ["chave"]}}, {"peso": 4, "txt": "Nada da chave. Mas você acha umas moedas no chão.", "efeitos": {"moedas": [15, 35]}}]}, {"id": "deixar", "txt": "Deixar o baú para lá", "resultados": [{"peso": 1, "txt": "Nem todo baú vale o risco.", "efeitos": {"flags": ["cauteloso"]}}]}]}, {"id": "bloqueio", "etapa": [2, 3], "peso": 5, "cena": "rochas", "titulo": "Passagem bloqueada", "texto": "Um desmoronamento fechou a passagem. Dá para ver um vão estreito no alto.", "opcoes": [{"id": "cavar", "txt": "Tirar as pedras com as mãos", "custo": {"energia": 1}, "resultados": [{"peso": 7, "txt": "Pedra por pedra, você abre caminho. Embaixo das pedras, algumas moedas antigas.", "efeitos": {"moedas": [20, 45]}}, {"peso": 3, "ruim": true, "txt": "Mais pedras caem do teto. Você escapa por pouco, cansado.", "efeitos": {"energia": -1}}]}, {"id": "forca", "txt": "💪 Pedir para um Pokémon usar Força", "req": {"golpe": 70}, "resultados": [{"peso": 1, "txt": "As pedras rolam para o lado como se fossem de papel.", "efeitos": {"flags": ["forte"]}}]}, {"id": "vao", "txt": "Escalar até o vão no alto", "resultados": [{"peso": 5, "txt": "Você passa pelo vão e encontra um caminho que ninguém usa há anos.", "efeitos": {"flags": ["atalho_alto"]}}, {"peso": 5, "ruim": true, "txt": "Você escorrega e machuca o braço, mas passa.", "efeitos": {"energia": -1}}]}]}, {"id": "escuro", "etapa": [2, 3, 4], "peso": 6, "cena": "tunel", "titulo": "A escuridão completa", "texto": "Um sopro de vento apaga a chama por um instante. No escuro, você ouve asas batendo.", "opcoes": [{"id": "flash", "txt": "✨ Usar Flash", "req": {"golpe": 148}, "resultados": [{"peso": 1, "txt": "A luz do Flash enche o túnel. Os Zubat fogem, e você enxerga uma passagem escondida.", "efeitos": {"luz": 2, "flags": ["atalho_alto"]}}]}, {"id": "acender", "txt": "Reacender a tocha", "custo": {"luz": 1}, "resultados": [{"peso": 6, "txt": "A luz volta, e uma revoada de Zubat passa por cima de você e some.", "efeitos": {}}, {"peso": 4, "txt": "A luz acorda um Pokémon que estava no teto!", "efeitos": {"batalha": {"especies": [41, 42, 92], "delta": [-1, 2], "se_venceu": {"moedas": [15, 30]}, "se_perdeu": {"energia": -1}}}}]}, {"id": "esperar", "txt": "Ficar parado no escuro e esperar", "resultados": [{"peso": 5, "txt": "As asas passam e somem. Você acende a tocha de novo, com calma.", "efeitos": {}}, {"peso": 5, "ruim": true, "txt": "Algo esbarra em você no escuro e leva parte da sua mochila!", "efeitos": {"perde_moedas": 0.3, "flags": ["roubado"]}}]}]}, {"id": "porta", "etapa": [3, 4], "peso": 9, "cena": "porta", "titulo": "A porta dos símbolos", "texto": "Uma porta de pedra enorme, com três símbolos: uma chama, uma gota e uma folha. Embaixo está escrito: ''abre para quem escolhe o que vence quem vence o fogo''.", "opcoes": [{"id": "fogo", "txt": "🔥 Tocar na chama", "resultados": [{"peso": 1, "ruim": true, "txt": "A pedra esquenta e solta um jato de vapor. A porta não se mexe.", "efeitos": {"energia": -1}}]}, {"id": "agua", "txt": "💧 Tocar na gota", "resultados": [{"peso": 1, "ruim": true, "txt": "Um estalo, e o chão treme. A porta continua fechada… e o barulho ecoa longe.", "efeitos": {"flags": ["barulho"]}}]}, {"id": "folha", "txt": "🌿 Tocar na folha", "resultados": [{"peso": 1, "txt": "A água vence o fogo, e a folha vence a água. A porta range e se abre devagar.", "efeitos": {"flags": ["porta_aberta"], "reliquia": "selo"}}]}, {"id": "chave", "txt": "🗝️ Usar a chave do baú", "req": {"flag": "chave"}, "resultados": [{"peso": 1, "txt": "A chave encaixa numa fechadura escondida embaixo dos símbolos. A porta se abre sem esforço.", "efeitos": {"flags": ["porta_aberta"], "reliquia": "selo"}}]}]}, {"id": "vagonete", "etapa": [3], "peso": 7, "cena": "trilhos", "titulo": "Vagonete desgovernado", "texto": "Um barulho de ferro raspando: um vagonete solto vem descendo o trilho na sua direção, muito rápido!", "opcoes": [{"id": "pular", "txt": "Pular para o lado", "resultados": [{"peso": 7, "txt": "Você pula a tempo. O vagonete passa e bate lá embaixo, abrindo um buraco na parede.", "efeitos": {"flags": ["parede_aberta"]}}, {"peso": 3, "ruim": true, "txt": "Você pula, mas bate o joelho na pedra.", "efeitos": {"energia": -1}}]}, {"id": "subir", "txt": "Subir no vagonete!", "resultados": [{"peso": 5, "txt": "Que viagem! O vagonete te leva direto para as profundezas.", "efeitos": {"flags": ["atalho_alto"], "energia": 1}}, {"peso": 5, "ruim": true, "txt": "O vagonete descarrila e você sai rolando. Perdeu umas moedas no caminho.", "efeitos": {"perde_moedas": 0.4, "energia": -1}}]}, {"id": "nicho", "txt": "Se esconder num nicho da parede", "custo": {"luz": 1}, "resultados": [{"peso": 1, "txt": "Apertado, mas seguro. Dentro do nicho, alguém esqueceu um item.", "efeitos": {"itens": {"pocao": 2}}}]}]}, {"id": "ponte", "etapa": [3, 4], "peso": 7, "cena": "ponte", "titulo": "A ponte sobre o abismo", "texto": "Uma ponte de madeira atravessa um abismo sem fundo. Metade das tábuas sumiu.", "opcoes": [{"id": "correr", "txt": "Atravessar correndo", "resultados": [{"peso": 6, "txt": "Tábua, buraco, tábua… você chega do outro lado com o coração na boca.", "efeitos": {}}, {"peso": 4, "ruim": true, "txt": "Uma tábua cede e você se segura com as mãos. Chega do outro lado, mas exausto.", "efeitos": {"energia": -2}}]}, {"id": "reforcar", "txt": "Usar as tábuas do carrinho para reforçar", "req": {"flag": "trilho_livre"}, "resultados": [{"peso": 1, "txt": "Com as tábuas do carrinho, a ponte fica firme. Do outro lado, um baú pendurado na rocha!", "efeitos": {"moedas": [30, 70], "doces": 1}}]}, {"id": "contornar", "txt": "Procurar outro caminho pela borda", "custo": {"luz": 1}, "resultados": [{"peso": 6, "txt": "Pela borda, devagar. Demora, mas você passa.", "efeitos": {}}, {"peso": 4, "txt": "Pela borda você encontra uma caverninha com um Pokémon raro!", "efeitos": {"avistou": 147, "batalha": {"especies": [147, 138, 140], "delta": [-2, 0], "captura": true, "especial": true, "se_venceu": {}, "se_perdeu": {"energia": -1}}}}]}]}, {"id": "mercadora", "etapa": [3, 4], "peso": 4, "cena": "misterio", "titulo": "A mercadora encapuzada", "texto": "Uma figura encapuzada está sentada num caixote, com uma lanterna roxa. ''Troco coisas, viajante. Tudo tem um preço aqui embaixo.''", "opcoes": [{"id": "trocar_energia", "txt": "Trocar energia por luz", "custo": {"energia": 1}, "resultados": [{"peso": 1, "txt": "''Negócio fechado.'' Ela te entrega duas tochas novas.", "efeitos": {"luz": 2}}]}, {"id": "trocar_cristal", "txt": "Oferecer os cristais da mochila", "req": {"flag": "cristal"}, "resultados": [{"peso": 1, "txt": "Os olhos dela brilham. Em troca dos cristais, uma relíquia que ela jura ser verdadeira.", "efeitos": {"reliquia": "cristal_estelar", "tira_flag": "cristal"}}]}, {"id": "recusar", "txt": "Recusar e seguir", "resultados": [{"peso": 1, "txt": "''Volte quando tiver algo interessante'', ela ri, e some no escuro.", "efeitos": {}}]}]}, {"id": "sala_secreta", "etapa": [4], "flags_algum": ["porta_aberta", "fundo"], "peso": 30, "cena": "sala", "titulo": "A sala selada", "texto": "Atrás da passagem, uma sala que ninguém abre há décadas: estantes, caixotes e um brilho dourado no fundo.", "opcoes": [{"id": "tudo", "txt": "Pegar tudo o que der", "custo": {"energia": 1}, "resultados": [{"peso": 6, "txt": "A mochila fica pesada de tanta coisa boa.", "efeitos": {"moedas": [60, 120], "itens": {"hiper_pocao": 1}, "segredo": "sala_selada"}}, {"peso": 4, "txt": "No fundo de um caixote, uma peça de equipamento brilhando!", "efeitos": {"peca": true, "segredo": "sala_selada"}}]}, {"id": "escolher", "txt": "Examinar com calma e escolher só uma coisa", "custo": {"luz": 1}, "resultados": [{"peso": 1, "txt": "Entre tudo, você escolhe o que parece mais antigo: uma relíquia e dois Doces de Forja.", "efeitos": {"reliquia": "picareta", "doces": 2, "segredo": "sala_selada"}}]}, {"id": "deixar", "txt": "Fechar a porta e não mexer", "resultados": [{"peso": 1, "txt": "Alguns segredos é melhor deixar quietos. Você sente que o fundo da mina está mais calmo.", "efeitos": {"flags": ["respeito"], "segredo": "sala_selada"}}]}]}, {"id": "atalho_trilhos", "etapa": [4], "flags_algum": ["trilho_livre", "atalho_alto", "parede_aberta"], "peso": 20, "cena": "trilhos", "titulo": "O caminho escondido", "texto": "O caminho que você abriu leva por dentro da rocha, direto para perto da câmara final. Dá para chegar descansado… ou explorar os túneis do lado.", "opcoes": [{"id": "descansar", "txt": "Ir direto e chegar descansado", "resultados": [{"peso": 1, "txt": "Você chega perto da câmara sem pressa e recupera o fôlego.", "efeitos": {"energia": 2, "flags": ["surpresa"]}}]}, {"id": "explorar", "txt": "Explorar os túneis do lado", "custo": {"energia": 1}, "resultados": [{"peso": 6, "txt": "Os túneis do lado estão cheios de minério esquecido.", "efeitos": {"moedas": [40, 90]}}, {"peso": 4, "txt": "Um Pokémon raro mora nesses túneis!", "efeitos": {"batalha": {"especies": [142, 139, 141], "delta": [-2, 0], "captura": true, "especial": true, "se_venceu": {"moedas": [20, 40]}, "se_perdeu": {"energia": -1}}}}]}]}, {"id": "despertou", "etapa": [4], "flags_req": ["barulho"], "peso": 25, "cena": "camara", "titulo": "Algo despertou", "texto": "O barulho que você fez antes acordou alguma coisa. Um Pokémon enorme bloqueia o caminho, furioso.", "opcoes": [{"id": "lutar", "txt": "Enfrentar", "resultados": [{"peso": 1, "txt": "Não tem como fugir dessa!", "efeitos": {"batalha": {"especies": [95, 76, 112], "delta": [1, 3], "captura": true, "se_venceu": {"moedas": [40, 80], "tira_flag": "barulho"}, "se_perdeu": {"energia": -2}}}}]}, {"id": "fugir", "txt": "Correr de volta e dar a volta", "custo": {"energia": 2}, "resultados": [{"peso": 1, "txt": "Você foge e dá uma volta enorme. Chega na câmara, mas o guardião já está acordado.", "efeitos": {}}]}]}, {"id": "minerador_volta", "etapa": [4], "flags_req": ["aliado"], "peso": 25, "cena": "minerador", "titulo": "Um velho conhecido", "texto": "O minerador que você ajudou aparece com uma lanterna e um sorriso. ''Voltei para te ajudar, não ia te deixar sozinho aqui!''", "opcoes": [{"id": "aceitar", "txt": "Aceitar a ajuda dele", "resultados": [{"peso": 1, "txt": "Ele te dá suprimentos e mostra a entrada pelos fundos da câmara.", "efeitos": {"energia": 2, "luz": 1, "flags": ["surpresa"], "itens": {"super_pocao": 1}}}]}, {"id": "presente", "txt": "Pedir só um presente de lembrança", "resultados": [{"peso": 1, "txt": "Ele tira do bolso o Lampião do Capataz. ''Era do meu chefe. Fica com você.''", "efeitos": {"reliquia": "lampiao", "moedas": [20, 40]}}]}]}, {"id": "veio_cristal", "etapa": [4], "flags_req": ["veio"], "peso": 25, "cena": "cristais", "titulo": "O coração do veio", "texto": "O canto do veio azul está mais forte. No centro, um cristal maior que os outros pulsa como um coração.", "opcoes": [{"id": "pegar", "txt": "Arrancar o cristal grande", "custo": {"energia": 1}, "resultados": [{"peso": 5, "txt": "O cristal se solta na sua mão, quente e brilhante.", "efeitos": {"reliquia": "cristal_estelar", "flags": ["cristal"]}}, {"peso": 5, "ruim": true, "txt": "O cristal se solta, mas o veio para de cantar… e a mina inteira treme.", "efeitos": {"reliquia": "cristal_estelar", "flags": ["cristal", "barulho"]}}]}, {"id": "ouvir", "txt": "Ficar ouvindo o canto", "resultados": [{"peso": 1, "txt": "O canto te acalma. Você descansa, e quando segue, está com outra energia.", "efeitos": {"energia": 2, "flags": ["respeito"]}}]}]}, {"id": "galeria", "etapa": [4], "peso": 3, "cena": "galeria", "titulo": "A galeria silenciosa", "texto": "Uma galeria grande e vazia, com picaretas largadas e uma fogueira apagada. Parece um acampamento abandonado às pressas.", "opcoes": [{"id": "descansar", "txt": "Descansar na fogueira", "resultados": [{"peso": 1, "txt": "Você reacende a fogueira e descansa um pouco.", "efeitos": {"energia": 1, "luz": 1}}]}, {"id": "vasculhar", "txt": "Vasculhar o acampamento", "custo": {"energia": 1}, "resultados": [{"peso": 6, "txt": "Moedas e um item esquecido numa mochila velha.", "efeitos": {"moedas": [30, 60], "itens": {"pocao": 1}}}, {"peso": 4, "txt": "Um diário rasgado dos mineradores!", "efeitos": {"reliquia": "diario_mineiro"}}]}]}, {"id": "camara", "etapa": [5], "peso": 1, "cena": "camara", "titulo": "A câmara do guardião", "texto": "Uma caverna enorme, com o teto cheio de cristais. No centro, sobre um monte de tesouros, um Onix gigante abre os olhos devagar.", "opcoes": [{"id": "enfrentar", "txt": "⚔️ Enfrentar o guardião", "resultados": [{"peso": 1, "txt": "O guardião ruge e vem para cima de você!", "efeitos": {"batalha": {"especies": [95], "delta": [3, 5], "chefe": true, "se_venceu": {"moedas": [120, 220], "doces": 2, "reliquia": "coracao", "chefe": "guardiao_onix", "fim": true}, "se_perdeu": {"fim": true}}}}]}, {"id": "furtivo", "txt": "🤫 Pegar o tesouro sem acordar o guardião", "resultados": [{"peso": 4, "mod": [{"flag": "furtivo", "peso": 8}, {"flag": "surpresa", "peso": 6}, {"heroi": "ladino", "peso": 6}, {"flag": "barulho", "peso": -4}], "txt": "Pé ante pé, você pega um punhado do tesouro e sai sem ninguém ver.", "efeitos": {"moedas": [80, 160], "doces": 1, "fim": true}}, {"peso": 6, "ruim": true, "txt": "Uma moeda cai e tilinta no chão. O guardião acorda furioso!", "efeitos": {"batalha": {"especies": [95], "delta": [4, 6], "chefe": true, "se_venceu": {"moedas": [120, 220], "doces": 2, "reliquia": "coracao", "chefe": "guardiao_onix", "fim": true}, "se_perdeu": {"perde_moedas": 0.3, "fim": true}}}}]}, {"id": "oferecer", "txt": "💎 Oferecer um cristal ao guardião", "req": {"flag": "cristal"}, "resultados": [{"peso": 3, "mod": [{"flag": "respeito", "peso": 10}, {"flag": "barulho", "peso": -2}], "txt": "O guardião cheira o cristal, abaixa a cabeça e se afasta do tesouro. Você pode pegar o que quiser.", "efeitos": {"moedas": [100, 180], "reliquia": "coracao", "segredo": "guardiao_calmo", "peca": true, "fim": true}}, {"peso": 3, "ruim": true, "txt": "O guardião engole o cristal… e continua com fome. De você.", "efeitos": {"batalha": {"especies": [95], "delta": [3, 5], "chefe": true, "se_venceu": {"moedas": [120, 220], "doces": 2, "reliquia": "coracao", "chefe": "guardiao_onix", "fim": true}, "se_perdeu": {"fim": true}}}}]}, {"id": "recuar", "txt": "🚪 Sair da mina com o que já tem", "resultados": [{"peso": 1, "txt": "Às vezes, voltar inteiro é a melhor vitória. Você sai com a mochila cheia.", "efeitos": {"fim": true}}]}]}]}'::jsonb, true, 1) on conflict (id) do nothing;
update public.game_config set config = jsonb_set(config, '{exp}', public.exp_cfg()) where active and not (config ? 'exp');

create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'leilao', public.leilao_cfg(), 'herois', public.herois_cfg(), 'temporada', public.temporada_cfg(), 'liga', public.liga_cfg(), 'pausa', public.pausa_cfg(), 'teto', public.teto_cfg(), 'boas_vindas', public.boas_vindas_cfg(), 'vila_bonus', public.vila_bonus_cfg(), 'tm_nivel', public.tm_nivel_cfg(), 'quiz_auto', public.quiz_auto_cfg(), 'cartas', public.tcg_cfg(), 'pokebound', public.pokebound_cfg(), 'visual', public.visual_cfg(), 'praca', public.praca_cfg(), 'rpg', public.rpg_cfg(), 'equip', public.equip_cfg(), 'base', public.cfg(), 'exp', public.exp_cfg());   -- arquivo 111: Expedições
end $$;

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
  if t ? 'gym' then
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
            insert into event_log(user_id, kind, message) values (b.p1, 'elite', '⚔️ ' || nome || ' venceu ' || el.nome || ' na Liga (' || er.etapa || ' de ' || ne || ')!');
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

grant execute on function public.admin_cfg_efetiva() to authenticated;
revoke execute on function public.rpg_after(uuid) from public, anon, authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('⛏️ Expedições: a Mina Esquecida', 'Chegou um minigame novo: as Expedições (menu Competir, ou pela entrada da mina na Gruta da Pedreira, na Aventura).
• A primeira é a Mina Esquecida: 5 etapas, de 5 a 10 minutos. Escolha o caminho, explore, enfrente desafios e chegue à câmara do guardião.
• Cada escolha muda o que vem depois. Não existe resposta sempre certa: tem risco, recompensa e o que você já fez antes.
• Cuide da ⚡ energia e da 🔦 luz: se a energia acabar, você sai da mina antes do fim.
• Pokémon da equipe com Força ou Flash abrem caminhos novos. Os encontros usam as batalhas da Aventura, e alguns Pokémon especiais podem ser capturados.
• Tudo o que você achar vai para a mochila e é entregue quando você sai: moedas, itens, Doces de Forja, peças de equipamento e relíquias.
• O 📖 Diário do Explorador guarda as relíquias, os segredos e as conquistas. Será que você acha tudo?')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
