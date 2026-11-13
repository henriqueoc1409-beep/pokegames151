-- 110_pokebound_ranqueado.sql
-- Pedido do dono em 13/11/2026: PokeBound entre jogadores, valendo um ranking.
-- Um jogador desafia outro (os dois no computador), o outro aceita e escolhe o Pokémon, e a partida é AO VIVO:
-- cada um tem pokebound.turno_seg (45) segundos por turno. Para o ranking não ter trapaça, quem calcula tudo é o
-- SERVIDOR (a "etapa 2" planejada no arquivo 88): o terreno, o andar, o voo de cada tiro, a explosão, o dano, a
-- cratera e o vento. O site manda só a jogada (onde parou, para onde olha, ângulo, força, especial) e desenha o
-- caminho que o servidor devolve. As contas são as mesmas do pbSimular/pbExplodir/pbAndar do site.
-- Ranking (pb_rank): pontos que começam em pvp.pontos_inicio (1000); quem vence ganha e quem perde perde, mais
-- quando ganha de alguém acima (conta de xadrez, pvp.k = 32). Não vale moedas.
-- Quem some: depois do tempo do turno + pvp.folga_seg, o turno pula; pvp.pulos_max (3) pulos seguidos = derrota.
-- Limites: pvp.partidas_dia (10) por jogador e pvp.mesmo_par_dia (3) contra o mesmo adversário.
-- Nova pokebound_cfg (versão do 88 + pvp). Funções do site: pb_desafiar, pb_responder, pb_cancelar, pb_meus,
-- pb_estado, pb_jogar, pb_desistir, pb_ranking.

create or replace function public.pokebound_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "gravidade": 520, "vento_max": 10, "vento_forca": 14, "vento_turnos": 4, "vel_max": 1600, "carga_vel": 90,
    "turno_seg": 45, "recarga": 3, "raio_jogador": 42, "folego": 160, "zoom": 1.45,
    "pvp": {"on": true, "folga_seg": 15, "pulos_max": 3, "convite_seg": 120, "partidas_dia": 10, "mesmo_par_dia": 3, "pontos_inicio": 1000, "k": 32}}'::jsonb
    || coalesce(public.cfg()->'pokebound', '{}'::jsonb)
$$;
update public.game_config set config = jsonb_set(config, '{pokebound,pvp}', public.pokebound_cfg()->'pvp')
 where active and config ? 'pokebound' and not (config->'pokebound' ? 'pvp');
revoke execute on function public.pokebound_cfg() from public, anon, authenticated;

-- os 4 Pokémon (mesmos números do PB_CHARS do site)
create or replace function public.pb_char(_k text) returns jsonb
language sql immutable as $$
  select case _k
    when 'blastoise' then '{"hp": 1000, "dano": 300, "raio": 80, "vel": 0.95, "vento": 0.7}'
    when 'electrode' then '{"hp": 900, "dano": 240, "raio": 65, "vel": 1.15, "vento": 0.5}'
    when 'golem' then '{"hp": 1100, "dano": 260, "raio": 105, "vel": 0.9, "vento": 1.2}'
    when 'dragonite' then '{"hp": 950, "dano": 270, "raio": 80, "vel": 1.0, "vento": 0.9}' end::jsonb
$$;

create table if not exists public.pb_partidas (
  id bigserial primary key, p1 uuid not null references auth.users(id) on delete cascade, p2 uuid not null references auth.users(id) on delete cascade,
  c1 text not null, c2 text, status text not null default 'convite' check (status in ('convite', 'ativa', 'fim', 'recusada', 'cancelada', 'expirou')),
  tema text, terr double precision[], pos jsonb, jogadores jsonb, vez int, vento int default 0, vento_left int default 0, turno_fim timestamptz,
  jogada int not null default 0, ultimo jsonb, vencedor uuid, motivo text, pontos jsonb, criado timestamptz not null default now(), inicio timestamptz, fim timestamptz);
create index if not exists pb_partidas_p1 on public.pb_partidas(p1, status);
create index if not exists pb_partidas_p2 on public.pb_partidas(p2, status);
alter table public.pb_partidas enable row level security;   -- sem política: o site lê pelo pb_estado / pb_meus

create table if not exists public.pb_rank (
  user_id uuid primary key references auth.users(id) on delete cascade, pontos int not null, vitorias int not null default 0, derrotas int not null default 0,
  empates int not null default 0, partidas int not null default 0, melhor int not null, atualizado timestamptz not null default now());
alter table public.pb_rank enable row level security;
drop policy if exists pb_rank_ler on public.pb_rank;
create policy pb_rank_ler on public.pb_rank for select to authenticated using (true);
grant select on public.pb_rank to authenticated;

-- ---------- a física (a mesma conta do site) ----------
create or replace function public.pb_chao(_t double precision[], _x double precision) returns double precision
language plpgsql immutable as $$
declare n int := array_length(_t, 1); f double precision; i int; k double precision;
begin
  f := greatest(0, least(n - 1.001, _x / 4)); i := floor(f)::int; k := f - i;
  return _t[i + 1] * (1 - k) + _t[i + 2] * k;
end $$;

create or replace function public.pb_suavizar(_t double precision[]) returns double precision[]
language plpgsql immutable as $$
declare n int := array_length(_t, 1); i int;
begin
  for i in 2 .. n loop if _t[i] < _t[i - 1] - 6 then _t[i] := _t[i - 1] - 6; end if; end loop;
  for i in reverse n - 1 .. 1 loop if _t[i] < _t[i + 1] - 6 then _t[i] := _t[i + 1] - 6; end if; end loop;
  return _t;
end $$;

-- terreno novo (601 alturas, 1 a cada 4 px) e onde cada um começa
create or replace function public.pb_terreno() returns jsonb
language plpgsql volatile as $$
declare n int := 601; h double precision[] := array_fill(0::double precision, array[601]); a double precision[]; f double precision[]; p double precision[];
  i int; k int; x double precision; y double precision; pos double precision[]; c int; base double precision; d int;
begin
  a := array[100, 70, 48, 24, 8]; f := array[2, 4.5, 8.5, 16, 32]; p := array[0, 0, 0, 0, 0];
  for k in 1 .. 5 loop a[k] := a[k] * (0.6 + random() * 0.8); f[k] := f[k] * (0.7 + random() * 0.6); p[k] := random() * 6.28; end loop;
  for i in 0 .. n - 1 loop
    x := i::double precision / (n - 1); y := 640;
    for k in 1 .. 5 loop y := y + a[k] * sin(x * f[k] * pi() + p[k]); end loop;
    h[i + 1] := greatest(380, least(880, y));
  end loop;
  pos := array[0.07 + random() * 0.13, 0.93 - random() * 0.13];
  for k in 1 .. 2 loop
    c := floor(pos[k] * (n - 1) + 0.5)::int; base := h[c + 1];
    for d in -14 .. 14 loop i := c + d; if i >= 0 and i < n then h[i + 1] := base + (h[i + 1] - base) * least(1, abs(d) / 14.0); end if; end loop;
  end loop;
  return jsonb_build_object('terr', to_jsonb(public.pb_suavizar(h)), 'pos', to_jsonb(pos));
end $$;

-- o voo de um tiro: devolve o caminho e onde bateu (no chão ou direto num jogador)
create or replace function public.pb_simular(_t double precision[], _js jsonb, _o jsonb) returns jsonb
language plpgsql stable as $$
declare c jsonb := public.pokebound_cfg(); dt double precision := 1.0 / 60; rad double precision; v double precision; vx double precision; vy double precision;
  x double precision; y double precision; mg boolean := false; i int; q int; path jsonb := '[]'::jsonb; rj double precision := (c->>'raio_jogador')::double precision;
  g double precision := (c->>'gravidade')::double precision; vf double precision := (c->>'vento_forca')::double precision;
  w double precision := (_o->>'wind')::double precision; vk double precision := (_o->>'ventoK')::double precision; pts text[] := '{}';
begin
  rad := (_o->>'ang')::double precision * pi() / 180;
  v := (c->>'vel_max')::double precision * ((_o->>'pot')::double precision / 100) * (_o->>'vel')::double precision;
  vx := cos(rad) * v; vy := -sin(rad) * v; x := (_o->>'x')::double precision; y := (_o->>'y')::double precision;
  pts := array_append(pts, '[' || round(x::numeric, 1) || ',' || round(y::numeric, 1) || ']');
  for i in 0 .. 1999 loop
    vx := vx + w * vf * vk * dt; vy := vy + g * dt;
    if coalesce((_o->>'mergulho')::boolean, false) and not mg and vy > 0 then mg := true; vx := vx * 0.15; vy := 680; end if;
    x := x + vx * dt; y := y + vy * dt;
    pts := array_append(pts, '[' || round(x::numeric, 1) || ',' || round(y::numeric, 1) || ']');
    if x < -80 or x > 2480 or y > 1080 then return jsonb_build_object('path', ('[' || array_to_string(pts, ',') || ']')::jsonb, 'hit', null); end if;
    if i > 10 then
      for q in 0 .. jsonb_array_length(_js) - 1 loop
        if sqrt(power(x - (_js->q->>'x')::double precision, 2) + power(y - ((_js->q->>'y')::double precision - 52), 2)) < rj then
          return jsonb_build_object('path', ('[' || array_to_string(pts, ',') || ']')::jsonb, 'hit', jsonb_build_object('x', x, 'y', y, 'direto', q));
        end if;
      end loop;
    end if;
    if x >= 0 and x <= 2400 and y >= public.pb_chao(_t, x) then
      return jsonb_build_object('path', ('[' || array_to_string(pts, ',') || ']')::jsonb, 'hit', jsonb_build_object('x', x, 'y', y));
    end if;
  end loop;
  return jsonb_build_object('path', ('[' || array_to_string(pts, ',') || ']')::jsonb, 'hit', null);
end $$;

-- andar até _x (como o pbAndar do site): sobe ladeira não muito em pé, com fôlego; devolve onde conseguiu chegar
create or replace function public.pb_andar(_t double precision[], _x0 double precision, _alvo double precision) returns double precision
language plpgsql stable as $$
declare dt double precision := 1.0 / 60; fol double precision := (public.pokebound_cfg()->>'folego')::double precision; x double precision := _x0;
  dir int; y double precision; inc double precision; passo double precision; nx double precision; ny double precision; i int;
begin
  _alvo := greatest(30, least(2370, coalesce(_alvo, _x0)));
  for i in 1 .. 5000 loop
    exit when abs(_alvo - x) < 0.5 or fol <= 0;
    dir := sign(_alvo - x)::int; y := public.pb_chao(_t, x);
    inc := (public.pb_chao(_t, x + dir * 6) - y) / 6;
    passo := 80 * dt * case when inc < 0 then greatest(0.35, 1 + inc * 0.5) else 1 end;
    passo := least(passo, abs(_alvo - x), fol);
    nx := greatest(30, least(2370, x + dir * passo)); ny := public.pb_chao(_t, nx);
    exit when ny < y - passo * 2.2 - 0.5;   -- parede em pé demais
    fol := fol - abs(nx - x); x := nx;
  end loop;
  return x;
end $$;

-- ---------- ranking ----------
create or replace function public.pb_rank_de(_uid uuid) returns pb_rank
language plpgsql security definer set search_path = public, extensions as $$
declare r pb_rank; ini int := coalesce((public.pokebound_cfg()->'pvp'->>'pontos_inicio')::int, 1000);
begin
  insert into pb_rank(user_id, pontos, melhor) values (_uid, ini, ini) on conflict (user_id) do nothing;
  select * into r from pb_rank where user_id = _uid for update;
  return r;
end $$;

create or replace function public.pb_finalizar(_id bigint, _venc uuid, _motivo text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare m pb_partidas; r1 pb_rank; r2 pb_rank; k numeric := coalesce((public.pokebound_cfg()->'pvp'->>'k')::numeric, 32); e1 numeric; s1 numeric; d1 int; n1 text; n2 text;
begin
  select * into m from pb_partidas where id = _id for update;
  if m.status <> 'ativa' then return; end if;
  r1 := public.pb_rank_de(m.p1); r2 := public.pb_rank_de(m.p2);
  e1 := 1 / (1 + power(10, (r2.pontos - r1.pontos) / 400.0));
  s1 := case when _venc = m.p1 then 1 when _venc = m.p2 then 0 else 0.5 end;
  d1 := round(k * (s1 - e1))::int;
  update pb_rank set pontos = greatest(0, pontos + d1), melhor = greatest(melhor, pontos + d1), partidas = partidas + 1,
         vitorias = vitorias + (s1 = 1)::int, derrotas = derrotas + (s1 = 0)::int, empates = empates + (s1 = 0.5)::int, atualizado = now() where user_id = m.p1;
  update pb_rank set pontos = greatest(0, pontos - d1), melhor = greatest(melhor, pontos - d1), partidas = partidas + 1,
         vitorias = vitorias + (s1 = 0)::int, derrotas = derrotas + (s1 = 1)::int, empates = empates + (s1 = 0.5)::int, atualizado = now() where user_id = m.p2;
  update pb_partidas set status = 'fim', vencedor = _venc, motivo = _motivo, fim = now(), turno_fim = null,
         pontos = jsonb_build_object(m.p1::text, d1, m.p2::text, -d1) where id = _id;
  select name into n1 from characters where user_id = m.p1; select name into n2 from characters where user_id = m.p2;
  insert into event_log(user_id, kind, message) values (coalesce(_venc, m.p1), 'pokebound', case
    when _venc is null then '💥 ' || n1 || ' e ' || n2 || ' empataram no PokeBound!'
    else '💥 ' || case when _venc = m.p1 then n1 else n2 end || ' venceu ' || case when _venc = m.p1 then n2 else n1 end || ' no PokeBound' ||
         case when _motivo = 'ausente' then ' (o outro sumiu)' when _motivo = 'desistiu' then ' (o outro desistiu)' else '' end || '!' end);
end $$;
revoke execute on function public.pb_finalizar(bigint, uuid, text), public.pb_rank_de(uuid) from public, anon, authenticated;

-- próximo turno: vento (dura alguns turnos), recarga do especial e o relógio
create or replace function public.pb_proximo(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare m pb_partidas; c jsonb := public.pokebound_cfg(); v int; cd int;
begin
  select * into m from pb_partidas where id = _id for update;
  v := 1 - m.vez;
  if m.vento_left - 1 <= 0 then
    update pb_partidas set vento = round((random() * 2 - 1) * (c->>'vento_max')::numeric)::int, vento_left = (c->>'vento_turnos')::int where id = _id;
  else update pb_partidas set vento_left = vento_left - 1 where id = _id; end if;
  cd := greatest(0, coalesce((m.jogadores->v->>'cd')::int, 0) - 1);
  update pb_partidas set vez = v, jogadores = jsonb_set(jogadores, array[v::text, 'cd'], to_jsonb(cd)),
         turno_fim = now() + make_interval(secs => (c->>'turno_seg')::int), jogada = jogada + 1 where id = _id;
end $$;
revoke execute on function public.pb_proximo(bigint) from public, anon, authenticated;

-- relógio: convite vencido some; turno vencido pula; pulos demais = derrota
create or replace function public.pb_tick(_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare m pb_partidas; pv jsonb := public.pokebound_cfg()->'pvp'; pul int;
begin
  select * into m from pb_partidas where id = _id for update;
  if m.id is null then return; end if;
  if m.status = 'convite' and m.criado < now() - make_interval(secs => coalesce((pv->>'convite_seg')::int, 120)) then
    update pb_partidas set status = 'expirou' where id = _id; return;
  end if;
  if m.status = 'ativa' and now() > m.turno_fim + make_interval(secs => coalesce((pv->>'folga_seg')::int, 15)) then
    pul := coalesce((m.jogadores->m.vez->>'pulos')::int, 0) + 1;
    update pb_partidas set jogadores = jsonb_set(jogadores, array[m.vez::text, 'pulos'], to_jsonb(pul)),
           ultimo = jsonb_build_object('pulou', m.vez, 'jogada', m.jogada + 1) where id = _id;
    if pul >= coalesce((pv->>'pulos_max')::int, 3) then
      perform public.pb_finalizar(_id, case when m.vez = 0 then m.p2 else m.p1 end, 'ausente');
    else perform public.pb_proximo(_id); end if;
  end if;
end $$;
revoke execute on function public.pb_tick(bigint) from public, anon, authenticated;

-- ---------- desafiar e responder ----------
create or replace function public.pb_desafiar(_op uuid, _ch text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); pv jsonb := public.pokebound_cfg()->'pvp'; n int; nm text; nid bigint; tz text := coalesce(public.cfg()->>'timezone', 'America/Sao_Paulo');
begin
  if not coalesce((public.pokebound_cfg()->>'on')::boolean, true) or not coalesce((pv->>'on')::boolean, true) then raise exception 'O PokeBound entre jogadores está desligado.'; end if;
  if public.pb_char(_ch) is null then raise exception 'Escolha um Pokémon do PokeBound.'; end if;
  if _op is null or _op = uid then raise exception 'Escolha outro jogador para desafiar.'; end if;
  select name into nm from characters where user_id = _op;
  if nm is null then raise exception 'Jogador não encontrado.'; end if;
  perform public.pb_tick(x.id) from pb_partidas x where x.status in ('convite', 'ativa') and uid in (x.p1, x.p2);
  if exists (select 1 from pb_partidas where status in ('convite', 'ativa') and (uid in (p1, p2) or _op in (p1, p2))) then
    raise exception 'Você ou % já tem uma partida (ou desafio) de PokeBound em andamento.', nm; end if;
  select count(*) into n from pb_partidas where status = 'fim' and uid in (p1, p2) and (inicio at time zone tz)::date = public.game_today();
  if n >= (pv->>'partidas_dia')::int then raise exception 'Você já jogou % partidas de PokeBound valendo ranking hoje.', pv->>'partidas_dia'; end if;
  select count(*) into n from pb_partidas where status = 'fim' and ((p1 = uid and p2 = _op) or (p1 = _op and p2 = uid)) and (inicio at time zone tz)::date = public.game_today();
  if n >= (pv->>'mesmo_par_dia')::int then raise exception 'Vocês dois já jogaram % vezes hoje. Desafie outra pessoa!', pv->>'mesmo_par_dia'; end if;
  insert into pb_partidas(p1, p2, c1) values (uid, _op, _ch) returning pb_partidas.id into nid;
  return jsonb_build_object('id', nid, 'para', nm, 'expira_seg', (pv->>'convite_seg')::int);
end $$;

create or replace function public.pb_responder(_id bigint, _aceita boolean, _ch text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); m pb_partidas; t jsonb; tr double precision[]; js jsonb; c jsonb := public.pokebound_cfg(); x1 double precision; x2 double precision;
begin
  perform public.pb_tick(_id);
  select * into m from pb_partidas where id = _id and p2 = uid for update;
  if m.id is null then raise exception 'Desafio não encontrado.'; end if;
  if m.status <> 'convite' then raise exception 'Esse desafio não está mais valendo.'; end if;
  if not _aceita then update pb_partidas set status = 'recusada' where id = _id; return jsonb_build_object('ok', true); end if;
  if public.pb_char(_ch) is null then raise exception 'Escolha um Pokémon do PokeBound.'; end if;
  if exists (select 1 from pb_partidas where status = 'ativa' and uid in (p1, p2)) then raise exception 'Termine a sua outra partida antes.'; end if;
  t := public.pb_terreno(); tr := array(select jsonb_array_elements_text(t->'terr')::double precision);
  x1 := (t->'pos'->>0)::double precision * 2400; x2 := (t->'pos'->>1)::double precision * 2400;
  js := jsonb_build_array(
    jsonb_build_object('ch', m.c1, 'x', x1, 'y', public.pb_chao(tr, x1), 'hp', (public.pb_char(m.c1)->>'hp')::int, 'face', 1, 'ang', 45, 'cd', 0, 'pulos', 0),
    jsonb_build_object('ch', _ch, 'x', x2, 'y', public.pb_chao(tr, x2), 'hp', (public.pb_char(_ch)->>'hp')::int, 'face', -1, 'ang', 45, 'cd', 0, 'pulos', 0));
  update pb_partidas set c2 = _ch, status = 'ativa', inicio = now(), terr = tr, pos = t->'pos', jogadores = js,
         tema = (array['campo', 'deserto', 'neve', 'vulcao'])[1 + floor(random() * 4)::int], vez = floor(random() * 2)::int,
         vento = round((random() * 2 - 1) * (c->>'vento_max')::numeric)::int, vento_left = (c->>'vento_turnos')::int,
         turno_fim = now() + make_interval(secs => (c->>'turno_seg')::int), jogada = 0, ultimo = null
   where id = _id;
  return jsonb_build_object('id', _id);
end $$;

create or replace function public.pb_cancelar(_id bigint) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); n int;
begin
  update pb_partidas set status = 'cancelada' where id = _id and p1 = uid and status = 'convite';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Desafio não encontrado.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- o que está acontecendo comigo (convites e partida em andamento)
create or replace function public.pb_meus() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Entre no jogo primeiro.'; end if;
  perform public.pb_tick(x.id) from pb_partidas x where x.status in ('convite', 'ativa') and uid in (x.p1, x.p2);
  return jsonb_build_object(
    'recebidos', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'de', m.p1, 'nome', c.name, 'ch', m.c1, 'criado', m.criado)) from pb_partidas m join characters c on c.user_id = m.p1 where m.p2 = uid and m.status = 'convite'), '[]'::jsonb),
    'enviados', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'para', m.p2, 'nome', c.name, 'criado', m.criado)) from pb_partidas m join characters c on c.user_id = m.p2 where m.p1 = uid and m.status = 'convite'), '[]'::jsonb),
    'ativa', (select id from pb_partidas where status = 'ativa' and uid in (p1, p2) limit 1),
    'agora', now());
end $$;

-- o estado da partida para as duas telas
create or replace function public.pb_estado(_id bigint) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); m pb_partidas;
begin
  perform public.pb_tick(_id);
  select * into m from pb_partidas where id = _id;
  if m.id is null or uid not in (m.p1, m.p2) then raise exception 'Partida não encontrada.'; end if;
  return jsonb_build_object('id', m.id, 'status', m.status, 'eu', case when uid = m.p1 then 0 else 1 end, 'p1', m.p1, 'p2', m.p2,
    'nomes', jsonb_build_array((select name from characters where user_id = m.p1), (select name from characters where user_id = m.p2)),
    'tema', m.tema, 'terr', to_jsonb(m.terr), 'pos', m.pos, 'jogadores', m.jogadores, 'vez', m.vez, 'vento', m.vento, 'vento_left', m.vento_left,
    'turno_fim', m.turno_fim, 'agora', now(), 'jogada', m.jogada, 'ultimo', m.ultimo, 'vencedor', m.vencedor, 'motivo', m.motivo, 'pontos', m.pontos,
    'rank', jsonb_build_array((select pontos from pb_rank where user_id = m.p1), (select pontos from pb_rank where user_id = m.p2)));
end $$;

-- a jogada: andar, mirar e atirar (o servidor calcula tudo)
create or replace function public.pb_jogar(_id bigint, _x double precision, _face int, _ang double precision, _pot double precision, _esp boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.pokebound_cfg(); m pb_partidas; v int; js jsonb; me jsonb; ck jsonb; ch text; esp boolean;
  tr double precision[]; x double precision; y double precision; a double precision; boca_x double precision; boca_y double precision; base jsonb; tiros jsonb := '[]'::jsonb;
  t jsonb; r jsonb; res jsonb := '[]'::jsonb; h jsonb; raio double precision; q int; d double precision; dmg int; hits jsonb; cr double precision; larg double precision;
  i int; i0 int; i1 int; dx double precision; vivos int; rj double precision := (c->>'raio_jogador')::double precision; hx double precision; hy double precision;
begin
  perform public.pb_tick(_id);
  select * into m from pb_partidas where id = _id for update;
  if m.id is null or uid not in (m.p1, m.p2) then raise exception 'Partida não encontrada.'; end if;
  if m.status <> 'ativa' then raise exception 'A partida já terminou.'; end if;
  v := case when uid = m.p1 then 0 else 1 end;
  if m.vez <> v then raise exception 'Não é a sua vez.'; end if;
  js := m.jogadores; me := js->v; ch := me->>'ch'; ck := public.pb_char(ch); tr := m.terr;
  esp := coalesce(_esp, false) and coalesce((me->>'cd')::int, 0) = 0;
  _ang := greatest(0, least(85, coalesce(_ang, 45))); _pot := greatest(0, least(100, coalesce(_pot, 0)));
  _face := case when _face = -1 then -1 else 1 end;
  -- andar (com fôlego e sem subir parede) e virar
  x := public.pb_andar(tr, (me->>'x')::double precision, _x); y := public.pb_chao(tr, x);
  me := me || jsonb_build_object('x', x, 'y', y, 'face', _face, 'ang', _ang, 'pulos', 0);
  js := jsonb_set(js, array[v::text], me);
  -- a boca do canhão e os tiros (o especial muda os números)
  a := (case when _face = 1 then _ang else 180 - _ang end) * pi() / 180;
  boca_x := x + cos(a) * 58; boca_y := y - 52 - sin(a) * 58;
  base := jsonb_build_object('x', boca_x, 'y', boca_y, 'pot', _pot, 'vel', (ck->>'vel')::double precision, 'ventoK', (ck->>'vento')::double precision, 'wind', m.vento);
  a := case when _face = 1 then _ang else 180 - _ang end;
  if esp and ch = 'blastoise' then tiros := jsonb_build_array(base || jsonb_build_object('ang', a + 3, 'mult', 0.6), base || jsonb_build_object('ang', a - 3, 'mult', 0.6));
  elsif esp and ch = 'electrode' then tiros := jsonb_build_array(base || jsonb_build_object('ang', a, 'vel', (ck->>'vel')::double precision * 1.25, 'ventoK', (ck->>'vento')::double precision * 0.15, 'mult', 1));
  elsif esp and ch = 'golem' then tiros := jsonb_build_array(base || jsonb_build_object('ang', a, 'mult', 0.7, 'raioMult', 2));
  elsif esp and ch = 'dragonite' then tiros := jsonb_build_array(base || jsonb_build_object('ang', a, 'mergulho', true, 'mult', 1));
  else tiros := jsonb_build_array(base || jsonb_build_object('ang', a, 'mult', 1)); end if;
  if esp then js := jsonb_set(js, array[v::text, 'cd'], to_jsonb((c->>'recarga')::int + 1)); end if;
  -- todos os caminhos primeiro (como no site), depois as explosões na ordem
  for t in select * from jsonb_array_elements(tiros) loop
    r := public.pb_simular(tr, js, t);
    res := res || jsonb_build_array(t || jsonb_build_object('path', r->'path', 'hit', r->'hit'));
  end loop;
  for t in select * from jsonb_array_elements(res) loop
    h := t->'hit'; hits := '[]'::jsonb;
    if h is null or jsonb_typeof(h) = 'null' then continue; end if;
    hx := (h->>'x')::double precision; hy := (h->>'y')::double precision;
    raio := (ck->>'raio')::double precision * coalesce((t->>'raioMult')::double precision, 1);
    for q in 0 .. 1 loop
      d := greatest(0, sqrt(power(hx - (js->q->>'x')::double precision, 2) + power(hy - ((js->q->>'y')::double precision - 52), 2)) - rj * 0.8);
      if d < raio then
        dmg := floor((ck->>'dano')::double precision * (t->>'mult')::double precision * (1 - d / raio) + 0.5)::int;
        if (h->>'direto') is not null and (h->>'direto')::int = q then dmg := floor(dmg * 1.2 + 0.5)::int; end if;
        js := jsonb_set(js, array[q::text, 'hp'], to_jsonb(greatest(0, (js->q->>'hp')::int - dmg)));
      end if;
    end loop;
    cr := raio * 0.6; larg := cr * 1.3;
    i0 := greatest(0, floor((hx - larg - 80) / 4)::int); i1 := least(600, ceil((hx + larg + 80) / 4)::int);
    for i in i0 .. i1 loop
      dx := i * 4 - hx; if abs(dx) > larg then continue; end if;
      tr[i + 1] := least(970, greatest(tr[i + 1], hy + cr * (0.5 + 0.5 * cos(pi() * dx / larg))));
    end loop;
    tr := public.pb_suavizar(tr);
    for q in 0 .. 1 loop js := jsonb_set(js, array[q::text, 'y'], to_jsonb(public.pb_chao(tr, (js->q->>'x')::double precision))); end loop;
  end loop;
  update pb_partidas set terr = tr, jogadores = js,
         ultimo = jsonb_build_object('jogada', m.jogada + 1, 'vez', v, 'x', x, 'face', _face, 'ang', _ang, 'pot', _pot, 'esp', esp, 'tiros', res)
   where id = _id;
  select count(*) into vivos from jsonb_array_elements(js) e(jv) where (jv->>'hp')::int > 0;
  if vivos < 2 then
    perform public.pb_finalizar(_id, case when vivos = 0 then null when (js->0->>'hp')::int > 0 then m.p1 else m.p2 end, 'tiro');
    update pb_partidas set jogada = jogada + 1 where id = _id;
  else perform public.pb_proximo(_id); end if;
  return public.pb_estado(_id);
end $$;

create or replace function public.pb_desistir(_id bigint) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); m pb_partidas;
begin
  select * into m from pb_partidas where id = _id and uid in (p1, p2) for update;
  if m.id is null or m.status <> 'ativa' then raise exception 'Partida não encontrada.'; end if;
  perform public.pb_finalizar(_id, case when uid = m.p1 then m.p2 else m.p1 end, 'desistiu');
  update pb_partidas set jogada = jogada + 1, ultimo = jsonb_build_object('desistiu', case when uid = m.p1 then 0 else 1 end, 'jogada', m.jogada + 1) where id = _id;
  return public.pb_estado(_id);
end $$;

create or replace function public.pb_ranking() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid();
begin
  return jsonb_build_object(
    'top', coalesce((select jsonb_agg(jsonb_build_object('user_id', r.user_id, 'name', c.name, 'class', c.class, 'pontos', r.pontos, 'vitorias', r.vitorias, 'derrotas', r.derrotas, 'empates', r.empates, 'melhor', r.melhor) order by r.pontos desc, r.vitorias desc)
                     from (select * from pb_rank where partidas > 0 order by pontos desc limit 50) r join characters c on c.user_id = r.user_id), '[]'::jsonb),
    'eu', (select to_jsonb(r) from pb_rank r where user_id = uid),
    'posicao', (select count(*) + 1 from pb_rank where partidas > 0 and pontos > coalesce((select pontos from pb_rank where user_id = uid), -1)),
    'hoje', (select count(*) from pb_partidas where status = 'fim' and uid in (p1, p2) and (inicio at time zone coalesce(public.cfg()->>'timezone', 'America/Sao_Paulo'))::date = public.game_today()));
end $$;

grant execute on function public.pb_desafiar(uuid, text), public.pb_responder(bigint, boolean, text), public.pb_cancelar(bigint), public.pb_meus(),
  public.pb_estado(bigint), public.pb_jogar(bigint, double precision, int, double precision, double precision, boolean), public.pb_desistir(bigint), public.pb_ranking() to authenticated;
revoke execute on function public.pb_simular(double precision[], jsonb, jsonb), public.pb_andar(double precision[], double precision, double precision), public.pb_terreno() from public, anon, authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('💥 PokeBound entre jogadores, valendo ranking!', 'Agora dá para jogar PokeBound contra os amigos (no computador):
• Abra o PokeBound (menu Competir), vá em ⚔️ Desafiar, escolha o jogador e o seu Pokémon.
• Quem foi desafiado recebe o aviso na hora: aceita, escolhe o Pokémon dele e a partida começa ao vivo.
• Cada um tem 45 segundos por turno. Quem sumir perde a vez, e quem perder a vez 3 vezes seguidas perde a partida.
• Vale pontos no 🏆 Ranking do PokeBound: ganhar de quem está acima de você vale mais, perder para quem está abaixo custa mais.
• Os tiros são calculados no servidor: é a mira e a leitura do vento que decidem, para os dois lados igual.
• Não vale moedas, só a glória. Contra o computador continua valendo para treinar.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
