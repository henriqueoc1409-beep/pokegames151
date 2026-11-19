-- =====================================================================
-- POKEGAMES 128 — Ranking das estações do Vale do Treino e fim da Praça Central
-- (pedido do dono em 19/11/2026: "tira a praça; no Vale quero um top 3 dos melhores
-- jogadores com os melhores Pokémon em cada estação e, no fim da temporada, premiar os melhores").
--  * Ranking: em cada uma das 6 estações, a MELHOR nota de cada jogador na temporada
--    (com o Pokémon e o nível daquele treino). Empate na nota: quem fez primeiro.
--    Vale só treino terminado. Aparece para todos no Vale (vale_estado).
--  * Prêmio no fim da temporada (season_awards_give chama vale_premiar): top 3 de cada
--    estação ganha moedas (vale.ranking.premios, padrão 150/100/50), presente no Correio e
--    entra em vale_premios (pública: os campeões da última temporada aparecem no Vale).
--    Uma vez por temporada. Números em Ajustes do jogo → 🥋 Vale do Treino.
--  * Praça Central: fechada para os jogadores (praca.on = false); o site tirou a entrada.
-- =====================================================================

-- ---------- ajustes (versão do 112 + ranking) ----------
create or replace function public.vale_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "treinos_dia": 8, "exp_ref": 120, "xp_mult": 1, "afinidade_mult": 1.5, "nota_min": 10,
    "duracao_min_seg": 12, "duracao_max_min": 15,
    "ranking": {"on": true, "top": 3, "premios": [150, 100, 50]},
    "estacoes": {
      "pista":    {"nome": "Pista de Corrida",    "tipos": ["NORMAL", "ELETRICO", "VOADOR"]},
      "saco":     {"nome": "Saco de Pancada",     "tipos": ["LUTA", "PEDRA", "METALICO"]},
      "templo":   {"nome": "Templo da Meditação", "tipos": ["PSIQUICO", "FANTASMA", "DRAGAO"]},
      "lago":     {"nome": "Lago das Correntes",  "tipos": ["AGUA", "GELO"]},
      "paredao":  {"nome": "Paredão de Escalada", "tipos": ["INSETO", "PLANTA", "TERRA"]},
      "fogueira": {"nome": "Fogueira do Fôlego",  "tipos": ["FOGO", "VENENO", "SOMBRIO"]}}}'::jsonb
    || coalesce(public.cfg()->'vale', '{}'::jsonb)
$$;
revoke execute on function public.vale_cfg() from public, anon, authenticated;
update public.game_config set config = jsonb_set(config, '{vale,ranking}', '{"on": true, "top": 3, "premios": [150, 100, 50]}'::jsonb)
 where active and (config ? 'vale') and not (config->'vale' ? 'ranking');

create index if not exists vale_treinos_rank_idx on public.vale_treinos(estacao, terminou_em) where terminou_em is not null;

-- prêmios entregues (públicos: mostram os campeões da última temporada)
create table if not exists public.vale_premios (
  season_id int not null,
  estacao   text not null,
  pos       int not null,
  user_id   uuid not null references auth.users(id) on delete cascade,
  nota      int not null,
  especie   int,
  nivel     int,
  coins     int not null default 0,
  created_at timestamptz not null default now(),
  primary key (season_id, estacao, pos));
alter table public.vale_premios enable row level security;
drop policy if exists vale_premios_ler on public.vale_premios;
create policy vale_premios_ler on public.vale_premios for select to authenticated using (true);
revoke all on public.vale_premios from anon, authenticated;
grant select on public.vale_premios to authenticated;

-- o top N de uma estação entre dois momentos (melhor nota de cada jogador)
create or replace function public.vale_top(_estacao text, _t0 timestamptz, _t1 timestamptz, _n int)
returns table(pos int, user_id uuid, nome text, nota int, especie int, nivel int, em timestamptz)
language sql stable security definer set search_path = public, extensions as $$
  select (row_number() over (order by b.nota desc, b.terminou_em, b.id))::int, b.user_id, ch.name, b.nota, b.especie, b.nivel, b.terminou_em
    from (select distinct on (t.user_id) t.*
            from vale_treinos t
           where t.estacao = _estacao and t.terminou_em is not null and t.nota is not null
             and t.terminou_em >= _t0 and t.terminou_em < _t1
             and not public.has_role(t.user_id, 'admin')
           order by t.user_id, t.nota desc, t.terminou_em, t.id) b
    join characters ch on ch.user_id = b.user_id
   order by b.nota desc, b.terminou_em, b.id
   limit greatest(1, coalesce(_n, 3))
$$;
revoke execute on function public.vale_top(text, timestamptz, timestamptz, int) from public, anon, authenticated;

-- começo da temporada atual
create or replace function public.vale_temporada_t0() returns timestamptz
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((select started_on::timestamp at time zone 'America/Sao_Paulo' from seasons order by id desc limit 1), '-infinity'::timestamptz)
$$;
revoke execute on function public.vale_temporada_t0() from public, anon, authenticated;

-- entrega os prêmios do Vale de uma temporada (uma vez só)
create or replace function public.vale_premiar(_season int) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare s seasons; c jsonb := public.vale_cfg(); rk jsonb := coalesce(public.vale_cfg()->'ranking', '{}'::jsonb);
  t0 timestamptz; t1 timestamptz; e record; r record; v int; n int := 0; linhas text := ''; nomes text;
begin
  select * into s from seasons where id = _season;
  if s.id is null or not coalesce((rk->>'on')::boolean, true) then return 0; end if;
  if exists (select 1 from vale_premios where season_id = s.id) then return 0; end if;
  perform pg_advisory_xact_lock(1128);
  if exists (select 1 from vale_premios where season_id = s.id) then return 0; end if;
  t0 := s.started_on::timestamp at time zone 'America/Sao_Paulo';
  t1 := coalesce((s.ended_on + 1)::timestamp at time zone 'America/Sao_Paulo', now());
  for e in select key, value from jsonb_each(coalesce(c->'estacoes', '{}'::jsonb)) order by key loop
    nomes := '';
    for r in select * from public.vale_top(e.key, t0, t1, coalesce((rk->>'top')::int, 3)) loop
      v := coalesce((rk->'premios'->>(r.pos - 1))::int, 0);
      insert into vale_premios(season_id, estacao, pos, user_id, nota, especie, nivel, coins)
      values (s.id, e.key, r.pos, r.user_id, r.nota, r.especie, r.nivel, v) on conflict do nothing;
      if v > 0 then
        perform public.ext_origem('Prêmio do Vale do Treino', 'premios');
        update characters set coins = coins + v where user_id = r.user_id;
      end if;
      insert into gifts(user_id, coins, message) values (r.user_id, v,
        '🥋 Vale do Treino, Temporada ' || s.id || ': você ficou em ' || r.pos || 'º lugar na ' || (e.value->>'nome')
        || ' com nota ' || r.nota || coalesce(' (' || (select name from pokemon where id = r.especie) || ')', '') || '!'
        || case when v > 0 then ' Prêmio: ' || v || ' moedas.' else '' end);
      nomes := nomes || case when nomes = '' then '' else ', ' end || r.pos || 'º ' || r.nome || ' (' || r.nota || ')';
      n := n + 1;
    end loop;
    if nomes <> '' then linhas := linhas || E'\n' || (e.value->>'nome') || ': ' || nomes; end if;
  end loop;
  if n > 0 then
    insert into event_log(kind, message) values ('temporada', '🥋 Campeões do Vale do Treino da Temporada ' || s.id || '!' || linhas);
  end if;
  return n;
end $$;
revoke execute on function public.vale_premiar(int) from public, anon, authenticated;

-- prêmios da temporada (versão do 120 + Vale do Treino)
create or replace function public.season_awards_give(_season int) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare s seasons; t0 timestamptz; t1 timestamptz; c jsonb; top numeric; r record; premio int := coalesce((public.cfg()->'season_awards'->>'coins')::int, 150);
  n int := 0; linhas text := ''; nomes text; k int; parte int;
begin
  select * into s from seasons where id = _season;
  if s.id is null then return 0; end if;
  perform public.vale_premiar(s.id);   -- arquivo 128: top 3 de cada estação do Vale (tem a própria trava de "uma vez só")
  if exists (select 1 from season_awards where season_id = s.id and category <> 'liga') then return 0; end if;
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
revoke execute on function public.season_awards_give(int) from public, anon, authenticated;

-- estado do Vale (versão do 112 + ranking da temporada, minha melhor nota e campeões da última temporada)
create or replace function public.vale_estado() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.vale_cfg(); rk jsonb := coalesce(public.vale_cfg()->'ranking', '{}'::jsonb); d vale_dias;
  t0 timestamptz := public.vale_temporada_t0(); ranking jsonb := '{}'::jsonb; meu jsonb := '{}'::jsonb; camp jsonb := '{}'::jsonb; e text; ult int;
begin
  if uid is null then return null; end if;
  select * into d from vale_dias where user_id = uid and dia = public.game_today();
  if coalesce((rk->>'on')::boolean, true) then
    select max(season_id) into ult from vale_premios;
    for e in select jsonb_object_keys(coalesce(c->'estacoes', '{}'::jsonb)) loop
      ranking := ranking || jsonb_build_object(e, coalesce((select jsonb_agg(jsonb_build_object('pos', x.pos, 'user_id', x.user_id, 'nome', x.nome, 'nota', x.nota,
                    'especie', x.especie, 'nivel', x.nivel) order by x.pos)
                  from public.vale_top(e, t0, now() + interval '1 minute', coalesce((rk->>'top')::int, 3)) x), '[]'::jsonb));
      meu := meu || coalesce((select jsonb_build_object(e, jsonb_build_object('nota', t.nota, 'especie', t.especie, 'nivel', t.nivel))
                from vale_treinos t where t.user_id = uid and t.estacao = e and t.terminou_em >= t0 and t.nota is not null
               order by t.nota desc, t.terminou_em limit 1), '{}'::jsonb);
      if ult is not null then
        camp := camp || jsonb_build_object(e, coalesce((select jsonb_agg(jsonb_build_object('pos', p.pos, 'nome', ch.name, 'nota', p.nota, 'especie', p.especie, 'coins', p.coins) order by p.pos)
                  from vale_premios p join characters ch on ch.user_id = p.user_id where p.season_id = ult and p.estacao = e), '[]'::jsonb));
      end if;
    end loop;
  end if;
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'treinos', coalesce(d.treinos, 0), 'treinos_dia', (c->>'treinos_dia')::int,
    'xp_hoje', coalesce(d.xp, 0), 'afinidade_mult', (c->>'afinidade_mult')::numeric, 'duracao_min_seg', (c->>'duracao_min_seg')::int,
    'estacoes', c->'estacoes',
    'ranking_on', coalesce((rk->>'on')::boolean, true), 'premios', coalesce(rk->'premios', '[]'::jsonb),
    'ranking', ranking, 'meu_melhor', meu, 'campeoes', camp, 'campeoes_temporada', ult,
    'recentes', coalesce((select jsonb_agg(jsonb_build_object('estacao', t.estacao, 'especie', t.especie, 'nota', t.nota, 'xp', t.xp, 'em', t.terminou_em) order by t.id desc)
                            from (select * from vale_treinos where user_id = uid and terminou_em is not null order by id desc limit 6) t), '[]'::jsonb));
end $$;
grant execute on function public.vale_estado() to authenticated;

-- ---------- Praça Central fechada ----------
update public.game_config set config = jsonb_set(config, '{praca}', coalesce(config->'praca', '{}'::jsonb) || '{"on": false}'::jsonb) where active;

-- ---------- Jornal (regra 10) ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🏆 Vale do Treino: Top 3 de cada estação e prêmio na temporada', 'O Vale do Treino agora tem ranking! Em cada uma das 6 estações (Pista, Saco de Pancada, Templo, Lago, Paredão e Fogueira do Fôlego) aparece o Top 3 da temporada: os jogadores com a melhor nota e o Pokémon que treinou.
• Vale a sua melhor nota em cada estação na temporada. Empate: fica na frente quem fez primeiro.
• No fim da temporada, o Top 3 de cada estação ganha moedas (1º 150, 2º 100, 3º 50), com o presente no Correio.
• A Praça Central saiu do jogo. Para passear e encontrar a turma, use a Aventura.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
