-- 109_desmaio_72h.sql
-- Pedido do dono em 13/11/2026: do desmaio até a vida cheia são 72 horas NO TOTAL (treino.gratis_horas, menos com o Clérigo
-- e a vila): as primeiras 24 (treino.desmaio_espera_horas) parado, e a vida volta aos poucos nas 48 seguintes. Antes (arquivo
-- 98) a espera era somada às 72 e ficava em 96. Pokémon só ferido (sem desmaiar) continua igual: 1% a cada 72/100 horas.
-- Para lembrar o ritmo de quem acordou do desmaio, monsters.tr_ritmo (horas de 0 a 100% na recuperação atual; vazio = o normal),
-- que zera sozinho (gatilho) quando o Pokémon se fere de novo ou fica com a vida cheia.
-- Novas treino_autocura e tr_cura_em (versões do 98), tr_cura_em com o ritmo e treino_estado (versão do 95) usando ela.

alter table public.monsters add column if not exists tr_ritmo numeric;

create or replace function public.tr_ritmo_zera() returns trigger
language plpgsql as $$
begin
  if new.tr_hp < old.tr_hp or new.tr_hp >= 100 then new.tr_ritmo := null; end if;
  return new;
end $$;
drop trigger if exists tr_ritmo_zera on public.monsters;
create trigger tr_ritmo_zera before update of tr_hp on public.monsters for each row execute function public.tr_ritmo_zera();

-- horas de 0 a 100% para quem acordou do desmaio: o que sobra das horas totais depois da espera (no mínimo 1)
create or replace function public.tr_ritmo_desmaio(_uid uuid) returns numeric
language sql stable security definer set search_path = public, extensions as $$
  select greatest(1, public.cura_horas(_uid) - public.tr_espera_desmaio())
$$;
revoke execute on function public.tr_ritmo_desmaio(uuid) from public, anon, authenticated;

create or replace function public.tr_cura_em(_uid uuid, _hp int, _hurt_at timestamptz, _ritmo numeric) returns timestamptz
language sql stable security definer set search_path = public, extensions as $$
  select case when public.tr_gradual()
    then coalesce(_hurt_at, now())
         + make_interval(secs => case when _hp <= 0 then (public.tr_espera_desmaio() + public.tr_ritmo_desmaio(_uid)) * 3600
                                      else greatest(0, 100 - _hp) * coalesce(_ritmo, public.cura_horas(_uid)) * 36.0 end)
    else coalesce(_hurt_at, now()) + make_interval(hours => public.cura_horas(_uid)) end
$$;
create or replace function public.tr_cura_em(_uid uuid, _hp int, _hurt_at timestamptz) returns timestamptz
language sql stable security definer set search_path = public, extensions as $$
  select public.tr_cura_em(_uid, _hp, _hurt_at, null)
$$;
revoke execute on function public.tr_cura_em(uuid, int, timestamptz), public.tr_cura_em(uuid, int, timestamptz, numeric) from public, anon, authenticated;

create or replace function public.treino_autocura(_uid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare hh numeric := public.cura_horas(_uid);           -- horas de 0% a 100% (ferido)
  esp numeric := public.tr_espera_desmaio();               -- desmaiado: horas parado
  rf numeric := public.tr_ritmo_desmaio(_uid);              -- desmaiado: horas de 0% a 100% depois da espera
begin
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

-- treino_estado (versão do 95): a hora da vida cheia usa o ritmo de cada Pokémon
create or replace function public.treino_estado() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := auth.uid(); c jsonb := public.treino_cfg(); d treino_dias; v treino_visitas;
begin
  if uid is null then raise exception 'Entre na sua conta.'; end if;
  perform public.treino_autocura(uid);
  select * into d from treino_dias where user_id = uid and dia = public.game_today();
  v := public.treino_visita(uid);
  return jsonb_build_object('on', coalesce((c->>'on')::boolean, true), 'modo', 'andar', 'minutos_dia', (c->>'minutos_dia')::int + public.vb(uid, 'arena', 'grama_min')::int, 'vila_min', public.vb(uid, 'arena', 'grama_min')::int,
    'opcoes', c->'visita_opcoes', 'encontro_seg', (c->>'encontro_seg')::int,
    'nivel_menos', (c->>'nivel_menos')::int, 'nivel_mais', (c->>'nivel_mais')::int, 'gratis_horas', public.cura_horas(uid), 'cura_gradual', public.tr_gradual(), 'agora', now(),
    'espera_desmaio', public.tr_espera_desmaio(), 'ritmo_desmaio', public.tr_ritmo_desmaio(uid),
    'minutos', coalesce(d.minutos, 0), 'bonus', coalesce(d.bonus, 0), 'lutas', coalesce(d.lutas, 0), 'vitorias', coalesce(d.vitorias, 0), 'xp', coalesce(d.xp, 0),
    'visita', case when v.id is null then null else jsonb_build_object('id', v.id, 'fim', v.fim, 'minutos', v.minutos, 'inicio', v.inicio) end,
    'batalha', public.treino_batalha(uid),
    'feridos', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'tr_hp', m.tr_hp, 'preco', public.centro_preco_mon(uid, m.level, m.tr_hp, m.tr_hurt_at), 'preco_cheio', public.centro_preco_de(uid, m.level, m.tr_hp),
        'gratis_em', public.tr_cura_em(uid, m.tr_hp, m.tr_hurt_at, m.tr_ritmo)) order by m.tr_hp, m.level desc)
      from monsters m where m.user_id = uid and m.tr_hp < 100), '[]'::jsonb),
    'ultimas', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'mon_id', l.mon_id, 'species', l.species, 'wild', l.wild, 'wild_level', l.wild_level,
        'won', l.won, 'xp', l.xp, 'level_from', l.level_from, 'level_to', l.level_to, 'created_at', l.created_at) order by l.id desc)
      from treino_lutas l where l.user_id = uid), '[]'::jsonb));
end $$;
grant execute on function public.treino_estado() to authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('💤 Centro Pokémon: desmaiado fica bom em 72 horas', 'Acertamos a cura de graça do Pokémon desmaiado:
• Do desmaio até a vida cheia são 72 horas no total.
• Nas primeiras 24 horas ele fica parado, sem recuperar.
• Nas 48 horas seguintes a vida volta aos poucos, até ficar cheia.
• Pokémon só ferido (sem desmaiar) continua igual: a vida volta um pouco a cada hora.
• Com pressa? O Centro Pokémon cura na hora, pagando moedas.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
