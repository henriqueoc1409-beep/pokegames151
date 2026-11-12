-- 98_desmaio_espera.sql
-- Pedido do dono em 12/11/2026: com a cura aos poucos (arquivo 95), um Pokémon desmaiado voltava a lutar logo (com 1%)
-- e se curava na luta (Dream Eater, por exemplo). Agora o DESMAIADO (tr_hp = 0) só começa a recuperar depois de
-- treino.desmaio_espera_horas (24, Ajustes do jogo → Grama de Treino). Quem tem vida continua igual.
-- Novas treino_cfg, treino_autocura e tr_cura_em (versões do 95) e tr_espera_desmaio(). O Centro continua curando na hora.

create or replace function public.treino_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "minutos_dia": 30, "visita_opcoes": [5, 10], "encontro_seg": 15, "lendario_pct": 1, "lendario_nivel": 70, "acompanhante_pct": 50, "xp_mult": 1, "nivel_menos": 3, "nivel_mais": 0,
           "forte_pct": 10, "forte_min": 3, "forte_max": 6, "forte_xp_mult": 1.5, "turnos": 40, "lutas_guardadas": 10,
           "centro_coef": 1.5, "centro_desmaiado": 2, "gratis_horas": 72, "cura_gradual": true, "desmaio_espera_horas": 24}'::jsonb
         || coalesce(public.cfg()->'treino', '{}'::jsonb)
$$;

create or replace function public.tr_espera_desmaio() returns numeric
language sql stable security definer set search_path = public, extensions as $$
  select greatest(0, coalesce((public.treino_cfg()->>'desmaio_espera_horas')::numeric, 24))
$$;
revoke execute on function public.tr_espera_desmaio() from public, anon, authenticated;

create or replace function public.tr_cura_em(_uid uuid, _hp int, _hurt_at timestamptz) returns timestamptz
language sql stable security definer set search_path = public, extensions as $$
  select case when public.tr_gradual()
    then coalesce(_hurt_at, now()) + make_interval(secs => case when _hp <= 0 then public.tr_espera_desmaio() * 3600 else 0 end)
         + make_interval(secs => greatest(0, 100 - _hp) * public.cura_horas(_uid) * 36.0)
    else coalesce(_hurt_at, now()) + make_interval(hours => public.cura_horas(_uid)) end
$$;

create or replace function public.treino_autocura(_uid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare h numeric := public.cura_horas(_uid) * 3600.0;   -- segundos de 0% a 100%
  esp numeric := public.tr_espera_desmaio() * 3600.0;     -- arquivo 98: desmaiado só começa a recuperar depois disso
begin
  if public.tr_gradual() then
    update monsters m
       set tr_hp = least(100, m.tr_hp + x.g),
           tr_hurt_at = case when m.tr_hp + x.g >= 100 then null else m.tr_hurt_at + make_interval(secs => x.e + x.g * h / 100) end
      from (select id, case when tr_hp <= 0 then esp else 0 end e,
                   case when tr_hurt_at is null then 100
                        else floor(greatest(0, extract(epoch from now() - tr_hurt_at) - case when tr_hp <= 0 then esp else 0 end) * 100 / h)::int end g
              from monsters where user_id = _uid and tr_hp < 100) x
     where m.id = x.id and x.g > 0;
  else
    update monsters set tr_hp = 100, tr_hurt_at = null
     where user_id = _uid and tr_hp < 100
       and coalesce(tr_hurt_at, '-infinity'::timestamptz) <= now() - make_interval(hours => public.cura_horas(_uid));
  end if;
end $$;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('💤 Centro Pokémon: desmaiado só começa a se recuperar depois de 24 h', 'Ajuste na cura de graça dos Pokémon:
• Pokémon com vida volta a se recuperar aos poucos, como antes.
• Pokémon DESMAIADO agora fica 24 horas parado antes de a vida começar a voltar. Depois disso ela sobe aos poucos, como nos outros.
• Assim desmaiar volta a ter peso: não dá mais para esperar um pouquinho e voltar à luta.
• Com pressa? O Centro Pokémon cura na hora, pagando moedas.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('📜 Acontecimentos no chat', 'Na janelinha do chat (computador) tem uma aba nova: Acontecimentos. Ela mostra o que aconteceu no jogo (batalhas, capturas, prêmios, chegadas…), com o botão para ler o Jornal do dia, sem precisar abrir a Comunidade. O número vermelho mostra quantos acontecimentos novos você ainda não viu.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
