-- 90_praca_central.sql
-- Pedido do dono em 10/11/2026: Praça Central, uma área pequena e fechada para andar (como a Grama de
-- Treino), onde os jogadores se veem, conversam e entram nas lojas andando até a porta. Tudo no site:
-- não tem tabela nova nem regra nova (cada casa só abre uma janela que o jogo já tem) e o tabuleiro não muda.
-- Este arquivo só:
--   (1) cria os ajustes da Praça no game_config (praca_cfg);
--   (2) coloca o grupo na aba Administração → Ajustes do jogo (admin_cfg_efetiva, versão do 89 + praça);
--   (3) publica a novidade no Jornal.

create or replace function public.praca_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "envio_seg": 1.5, "mascote": true, "baloes": true}'::jsonb || coalesce(public.cfg()->'praca', '{}'::jsonb)
$$;
update public.game_config set config = jsonb_set(config, '{praca}', public.praca_cfg()) where active and not (config ? 'praca');
revoke execute on function public.praca_cfg() from public, anon, authenticated;

-- ---------- Ajustes do jogo (versão do 89 + Praça) ----------
create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'leilao', public.leilao_cfg(), 'herois', public.herois_cfg(), 'temporada', public.temporada_cfg(), 'liga', public.liga_cfg(), 'pausa', public.pausa_cfg(), 'teto', public.teto_cfg(), 'boas_vindas', public.boas_vindas_cfg(), 'vila_bonus', public.vila_bonus_cfg(), 'tm_nivel', public.tm_nivel_cfg(), 'quiz_auto', public.quiz_auto_cfg(), 'cartas', public.tcg_cfg(), 'pokebound', public.pokebound_cfg(), 'visual', public.visual_cfg(), 'praca', public.praca_cfg(), 'base', public.cfg());
end $$;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('⛲ Abriu a Praça Central!', 'Lugar novo para passear com a galera: a Praça Central (menu Comunidade, ou o botão ⛲ no alto do mapa).
• Ande com o seu herói (WASD ou setas; no celular, os botões na tela) e veja quem mais está na praça.
• O primeiro Pokémon da sua equipe anda atrás de você.
• Converse pelo chat: o que você escreve aparece num balão em cima da sua cabeça.
• Chegue na porta de uma casa e aperte E para entrar: lojas, Centro Pokémon, Creche, Leilão, Mercado, Arena, Cartas, Biblioteca, Ranking e mais.
• É só um jeito novo de chegar nas mesmas janelas: o tabuleiro e as regras não mudam.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
