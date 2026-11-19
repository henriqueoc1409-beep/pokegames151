-- =====================================================================
-- POKEGAMES 129 — Vale do Treino: 8 estações, Lago e Saco mais difíceis e desempate no Top 3
-- (pedido do dono em 19/11/2026: "alguns vales estão muito fáceis, o da água e o de lutador;
-- crie mais 2 estações; e sempre que alguém empatar no top tem que ter desempate").
--  * 2 estações novas: Estande de Pontaria (🎯 Voador, Psíquico, Elétrico) e
--    Pomar das Frutas (🧺 Planta, Inseto, Normal). O minijogo e a dificuldade ficam no site.
--  * Desempate no Top 3: a nota (0 a 100) continua dando a XP; para a ordem do ranking valem,
--    nesta ordem, a nota, o "desempenho" (a pontuação exata do minijogo, sem arredondar e sem
--    o teto de 100: quem jogou melhor), o tempo do exercício (mais rápido na frente) e, por
--    último, quem fez primeiro. vale_treinos.nota_fina e vale_treinos.tempo_ms.
--  * Nada de XP, moedas ou prêmios muda.
-- =====================================================================

alter table public.vale_treinos add column if not exists nota_fina numeric;
alter table public.vale_treinos add column if not exists tempo_ms int;

-- ---------- ajustes (versão do 128 + 2 estações) ----------
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
      "fogueira": {"nome": "Fogueira do Fôlego",  "tipos": ["FOGO", "VENENO", "SOMBRIO"]},
      "alvo":     {"nome": "Estande de Pontaria", "tipos": ["VOADOR", "PSIQUICO", "ELETRICO"]},
      "frutas":   {"nome": "Pomar das Frutas",    "tipos": ["PLANTA", "INSETO", "NORMAL"]}}}'::jsonb
    || coalesce(public.cfg()->'vale', '{}'::jsonb)
$$;
revoke execute on function public.vale_cfg() from public, anon, authenticated;
-- o config guardado tem a lista antiga de estações: acrescenta as 2 novas (sem mexer nas que o admin mudou)
update public.game_config
   set config = jsonb_set(config, '{vale,estacoes}', coalesce(config->'vale'->'estacoes', '{}'::jsonb)
     || jsonb_build_object('alvo', coalesce(config->'vale'->'estacoes'->'alvo', '{"nome": "Estande de Pontaria", "tipos": ["VOADOR", "PSIQUICO", "ELETRICO"]}'::jsonb),
                           'frutas', coalesce(config->'vale'->'estacoes'->'frutas', '{"nome": "Pomar das Frutas", "tipos": ["PLANTA", "INSETO", "NORMAL"]}'::jsonb)))
 where active and (config ? 'vale');

-- ---------- top N com desempate (versão do 128) ----------
create or replace function public.vale_top(_estacao text, _t0 timestamptz, _t1 timestamptz, _n int)
returns table(pos int, user_id uuid, nome text, nota int, especie int, nivel int, em timestamptz)
language sql stable security definer set search_path = public, extensions as $$
  select (row_number() over (order by b.nota desc, coalesce(b.nota_fina, b.nota) desc, coalesce(b.tempo_ms, 2147483647), b.terminou_em, b.id))::int,
         b.user_id, ch.name, b.nota, b.especie, b.nivel, b.terminou_em
    from (select distinct on (t.user_id) t.*
            from vale_treinos t
           where t.estacao = _estacao and t.terminou_em is not null and t.nota is not null
             and t.terminou_em >= _t0 and t.terminou_em < _t1
             and not public.has_role(t.user_id, 'admin')
           order by t.user_id, t.nota desc, coalesce(t.nota_fina, t.nota) desc, coalesce(t.tempo_ms, 2147483647), t.terminou_em, t.id) b
    join characters ch on ch.user_id = b.user_id
   order by b.nota desc, coalesce(b.nota_fina, b.nota) desc, coalesce(b.tempo_ms, 2147483647), b.terminou_em, b.id
   limit greatest(1, coalesce(_n, 3))
$$;
revoke execute on function public.vale_top(text, timestamptz, timestamptz, int) from public, anon, authenticated;

-- ---------- terminar o treino (versão do 112 + desempenho e tempo para o desempate) ----------
drop function if exists public.vale_terminar(bigint, int);
create or replace function public.vale_terminar(_id bigint, _nota int, _fina numeric default null, _ms int default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); c jsonb := public.vale_cfg(); t vale_treinos; m monsters; seg numeric; nt int; ganho int := 0; lv0 int; lv1 int;
  fina numeric; ms int;
begin
  select * into t from vale_treinos where id = _id and user_id = uid for update;
  if t.id is null then raise exception 'Treino não encontrado.'; end if;
  if t.terminou_em is not null then raise exception 'Esse treino já terminou.'; end if;
  seg := extract(epoch from now() - t.comecou_em);
  if seg < (c->>'duracao_min_seg')::numeric - 1 then raise exception 'Treino rápido demais. Termine o exercício inteiro.'; end if;
  nt := greatest(0, least(100, coalesce(_nota, 0)));
  if seg > (c->>'duracao_max_min')::numeric * 60 then nt := 0; end if;   -- demorou demais: o treino venceu
  -- desempenho exato (só para o desempate): não pode ficar longe da nota, e o tempo não pode passar do treino de verdade
  fina := case when nt = 0 then 0 else round(greatest(nt - 1, least(coalesce(_fina, nt), nt + 40, 200))::numeric, 3) end;
  ms := case when _ms is null then null else greatest(0, least(_ms, (seg * 1000)::int)) end;
  select * into m from monsters where id = t.mon_id and user_id = uid;
  lv0 := m.level;
  if m.id is not null and nt >= coalesce((c->>'nota_min')::int, 0) and m.level < 100 then
    ganho := public.vale_xp_conta((c->>'exp_ref')::numeric, m.level, nt,
            coalesce((c->>'xp_mult')::numeric, 1) * case when t.afinidade then coalesce((c->>'afinidade_mult')::numeric, 1) else 1 end);
    perform public.pk_give_xp(m.id, ganho, 'vale');
  end if;
  update vale_treinos set terminou_em = now(), nota = nt, xp = ganho, nota_fina = fina, tempo_ms = ms where id = t.id;
  update vale_dias set xp = vale_dias.xp + ganho where user_id = uid and dia = public.game_today();
  select level into lv1 from monsters where id = t.mon_id;
  return jsonb_build_object('nota', nt, 'xp', ganho, 'afinidade', t.afinidade, 'nivel_antes', lv0, 'nivel_depois', coalesce(lv1, lv0), 'especie', t.especie,
    'estado', public.vale_estado(),
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.id) from mon_events e where e.user_id = uid and not e.seen), '[]'::jsonb));
end $$;
revoke execute on function public.vale_terminar(bigint, int, numeric, int) from public, anon;
grant execute on function public.vale_terminar(bigint, int, numeric, int) to authenticated;

-- ---------- Jornal (regra 10) ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🥋 Vale do Treino: 8 estações, treinos mais difíceis e desempate', 'O Vale do Treino cresceu e ficou mais puxado!
• Duas estações novas: 🎯 Estande de Pontaria (acerte o centro do alvo, que se mexe cada vez mais) e 🧺 Pomar das Frutas (pegue as frutas que caem e fuja das podres).
• 🏊 Lago das Correntes mais difícil: quatro raias, a correnteza acelera, vêm mais pedras juntas e só dá para bater 2 vezes.
• 🥊 Saco de Pancada mais difícil: sequências maiores, menos tempo e rodadas "ao contrário", em que você aperta a seta oposta.
• Desempate no Top 3: com a mesma nota, fica na frente quem jogou melhor (a pontuação exata do exercício); se ainda empatar, quem fez mais rápido; e por último quem fez primeiro.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
