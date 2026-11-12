-- 95_cura_gradual.sql
-- Pedido do dono em 12/11/2026: a vida do treino (Grama de Treino e Aventura) volta AOS POUCOS com o tempo, de graça,
-- em vez de o Pokémon ficar ferido/desmaiado até o fim da espera e só então voltar inteiro.
-- Ritmo: de 0% a 100% em cura_horas (72 h por padrão; Clérigo e Centro Pokémon de Guerra da vila continuam encurtando),
-- ou seja, +1% a cada 0,72 h. Desmaiado que recuperou 1% ou mais já pode lutar, com a vida que tem.
-- tr_hurt_at passa a marcar "de quando conta a próxima recuperação": a cada % recuperado ele anda junto, e ao chegar a
-- 100% fica vazio. Ferir de novo na luta continua marcando agora (treino_after não muda).
-- Preço do Centro: só pela vida que falta (centro_preco_de com a vida de agora). O desconto antigo pelo tempo de espera
-- deixaria o preço caindo duas vezes, porque a vida que falta já diminui com o tempo.
-- Liga/desliga em treino.cura_gradual (Ajustes do jogo → Grama de Treino); desligado volta a regra antiga inteira.
-- Novas treino_cfg (versão do 63), treino_autocura (do 67), centro_preco_mon (do 69), centro_curar (do 69),
-- treino_estado (do 82; devolve cura_gradual e o gratis_em certo). Funções novas tr_gradual e tr_cura_em (só internas).

create or replace function public.treino_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "minutos_dia": 30, "visita_opcoes": [5, 10], "encontro_seg": 15, "lendario_pct": 1, "lendario_nivel": 70, "acompanhante_pct": 50, "xp_mult": 1, "nivel_menos": 3, "nivel_mais": 0,
           "forte_pct": 10, "forte_min": 3, "forte_max": 6, "forte_xp_mult": 1.5, "turnos": 40, "lutas_guardadas": 10,
           "centro_coef": 1.5, "centro_desmaiado": 2, "gratis_horas": 72, "cura_gradual": true}'::jsonb
         || coalesce(public.cfg()->'treino', '{}'::jsonb)
$$;

create or replace function public.tr_gradual() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((public.treino_cfg()->>'cura_gradual')::boolean, true)
$$;

-- quando o Pokémon fica com a vida cheia de graça
create or replace function public.tr_cura_em(_uid uuid, _hp int, _hurt_at timestamptz) returns timestamptz
language sql stable security definer set search_path = public, extensions as $$
  select case when public.tr_gradual()
    then coalesce(_hurt_at, now()) + make_interval(secs => greatest(0, 100 - _hp) * public.cura_horas(_uid) * 36.0)
    else coalesce(_hurt_at, now()) + make_interval(hours => public.cura_horas(_uid)) end
$$;

create or replace function public.treino_autocura(_uid uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare h numeric := public.cura_horas(_uid) * 3600.0;   -- segundos de 0% a 100%
begin
  if public.tr_gradual() then
    update monsters m
       set tr_hp = least(100, m.tr_hp + x.g),
           tr_hurt_at = case when m.tr_hp + x.g >= 100 then null else m.tr_hurt_at + make_interval(secs => x.g * h / 100) end
      from (select id, case when tr_hurt_at is null then 100
                            else floor(greatest(0, extract(epoch from now() - tr_hurt_at)) * 100 / h)::int end g
              from monsters where user_id = _uid and tr_hp < 100) x
     where m.id = x.id and x.g > 0;
  else
    update monsters set tr_hp = 100, tr_hurt_at = null
     where user_id = _uid and tr_hp < 100
       and coalesce(tr_hurt_at, '-infinity'::timestamptz) <= now() - make_interval(hours => public.cura_horas(_uid));
  end if;
end $$;

create or replace function public.centro_preco_mon(_uid uuid, _level int, _hp int, _hurt_at timestamptz) returns int
language sql stable security definer set search_path = public, extensions as $$
  select case when public.centro_preco_de(_uid, _level, _hp) = 0 then 0
    when public.tr_gradual() then public.centro_preco_de(_uid, _level, _hp)   -- arquivo 95: só a vida que falta
    else greatest(0, ceil(public.centro_preco_de(_uid, _level, _hp)
           * greatest(0, extract(epoch from (coalesce(_hurt_at, now()) + make_interval(hours => public.cura_horas(_uid)) - now())))
           / (public.cura_horas(_uid) * 3600.0)))::int end
$$;

create or replace function public.centro_curar(_ids uuid[] default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := public.assert_active(); me characters; cost int; n int;
begin
  select * into me from characters where user_id = uid for update;
  perform public.treino_autocura(uid);
  select coalesce(sum(public.centro_preco_mon(uid, level, tr_hp, tr_hurt_at)), 0), count(*) into cost, n
    from monsters where user_id = uid and tr_hp < 100 and (_ids is null or id = any(_ids));
  if n = 0 then raise exception 'Nenhum Pokémon precisa de cura.'; end if;
  if me.coins < cost then raise exception 'A cura custa % moedas e você tem %. Se preferir, espere: a vida volta sozinha, de graça (de desmaiado a inteiro em % horas).', cost, me.coins, public.cura_horas(uid); end if;
  update characters set coins = coins - cost where id = me.id;
  update monsters set tr_hp = 100, tr_hurt_at = null where user_id = uid and tr_hp < 100 and (_ids is null or id = any(_ids));
  return jsonb_build_object('cost', cost, 'curados', n, 'coins', me.coins - cost);
end $$;

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
    'minutos', coalesce(d.minutos, 0), 'bonus', coalesce(d.bonus, 0), 'lutas', coalesce(d.lutas, 0), 'vitorias', coalesce(d.vitorias, 0), 'xp', coalesce(d.xp, 0),
    'visita', case when v.id is null then null else jsonb_build_object('id', v.id, 'fim', v.fim, 'minutos', v.minutos, 'inicio', v.inicio) end,
    'batalha', public.treino_batalha(uid),
    'feridos', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'tr_hp', m.tr_hp, 'preco', public.centro_preco_mon(uid, m.level, m.tr_hp, m.tr_hurt_at), 'preco_cheio', public.centro_preco_de(uid, m.level, m.tr_hp),
        'gratis_em', public.tr_cura_em(uid, m.tr_hp, m.tr_hurt_at)) order by m.tr_hp, m.level desc)
      from monsters m where m.user_id = uid and m.tr_hp < 100), '[]'::jsonb),
    'ultimas', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'mon_id', l.mon_id, 'species', l.species, 'wild', l.wild, 'wild_level', l.wild_level,
        'won', l.won, 'xp', l.xp, 'level_from', l.level_from, 'level_to', l.level_to, 'created_at', l.created_at) order by l.id desc)
      from treino_lutas l where l.user_id = uid), '[]'::jsonb));
end $$;

grant execute on function public.treino_estado() to authenticated;
grant execute on function public.centro_curar(uuid[]) to authenticated;
revoke execute on function public.tr_cura_em(uuid, int, timestamptz) from public, anon, authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('❤️ Centro Pokémon: a vida agora volta aos poucos', 'Mudou a cura de graça dos Pokémon feridos na Grama de Treino (e na Aventura):
• Antes, o Pokémon ficava ferido (ou desmaiado) até completar o tempo de espera e só então voltava inteiro.
• Agora a vida volta um pouquinho a cada hora, sozinha e de graça. Um desmaiado que recuperou um pouco já pode lutar de novo, com a vida que tem.
• De desmaiado até a vida cheia leva o mesmo tempo de antes; quem está pouco ferido fica bom bem mais rápido.
• Curar no Centro Pokémon continua valendo para quem tem pressa, e o preço é só da vida que falta: quanto mais ele já se recuperou, mais barato.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
