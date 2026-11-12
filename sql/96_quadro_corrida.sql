-- 96_quadro_corrida.sql
-- Pedido do dono em 12/11/2026 ("está poluído"): quadro da corrida no mapa (quem está em 1º e quantas casas os outros
-- estão atrás) e botão da equipe mais limpo, tudo no site. Usa só as posições do mapa, que todos já veem.
-- Nova visual_cfg (versão do 92) com "corrida" (Ajustes do jogo → 🖥️ Visual novo). Publica a novidade no Jornal.

create or replace function public.visual_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "tela_cheia_padrao": true, "chat_fixo": true, "herois_novos": true, "mapa_novo": true, "corrida": true}'::jsonb || coalesce(public.cfg()->'visual', '{}'::jsonb)
$$;
update public.game_config set config = jsonb_set(config, '{visual}', public.visual_cfg()) where active;
revoke execute on function public.visual_cfg() from public, anon, authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🏁 Quadro da corrida no mapa', 'Novidade na tela do mapa:
• Quadro da corrida: no canto da tela aparece quem está em 1º e quantas casas cada um está atrás dele, com a sua posição destacada. Toque num nome para ver o jogador no mapa; "Ver todos" abre o ranking da temporada. Dá para fechar e deixar só uma linha (no celular ele já começa assim).
• O botão dos seus Pokémon ficou menor e mais limpo: mostra o primeiro da equipe e uma bolinha de vida para cada um (verde, amarela ou vermelha).')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
