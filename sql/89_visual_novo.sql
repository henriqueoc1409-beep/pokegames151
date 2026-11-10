-- 89_visual_novo.sql
-- Pedido do dono em 10/11/2026: tela nova no computador (painéis por cima do mapa, chat fixo, Mochila
-- em quadradinhos e a Grama de Treino no mesmo estilo). A mudança é toda no site e não mexe em regra
-- nenhuma. Este arquivo só:
--   (1) cria os liga/desliga do visual no game_config (visual_cfg);
--   (2) coloca o grupo na aba Administração → Ajustes do jogo (admin_cfg_efetiva, versão do 88 + visual);
--   (3) publica a novidade no Jornal.

create or replace function public.visual_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "tela_cheia_padrao": true, "chat_fixo": true}'::jsonb || coalesce(public.cfg()->'visual', '{}'::jsonb)
$$;
update public.game_config set config = jsonb_set(config, '{visual}', public.visual_cfg()) where active and not (config ? 'visual');
revoke execute on function public.visual_cfg() from public, anon, authenticated;

-- ---------- Ajustes do jogo (versão do 88 + Visual novo) ----------
create or replace function public.admin_cfg_efetiva() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('treino', public.treino_cfg(), 'pk', public.pk_cfg(), 'casas', public.casas_cfg(), 'itens', public.items_cfg(),
    'war', public.war_cfg(), 'rocket', public.rocket_cfg(), 'desafio', public.desafio_cfg(), 'creche', public.creche_cfg(), 'leilao', public.leilao_cfg(), 'herois', public.herois_cfg(), 'temporada', public.temporada_cfg(), 'liga', public.liga_cfg(), 'pausa', public.pausa_cfg(), 'teto', public.teto_cfg(), 'boas_vindas', public.boas_vindas_cfg(), 'vila_bonus', public.vila_bonus_cfg(), 'tm_nivel', public.tm_nivel_cfg(), 'quiz_auto', public.quiz_auto_cfg(), 'cartas', public.tcg_cfg(), 'pokebound', public.pokebound_cfg(), 'visual', public.visual_cfg(), 'base', public.cfg());
end $$;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🖥️ Tela nova no computador!', 'O jogo ganhou cara nova para quem joga no computador (no celular nada muda):
• O mapa agora ocupa a tela toda. O menu fica em ícones na lateral: o botão » abre o menu completo e « recolhe.
• No alto: mapinha, sua barra com nível e EXP e a Missão diária (o próximo passo de hoje: é só clicar).
• À direita: temporada, casa, região e botões rápidos (🎒 Mochila, Pokémon, Pokédex, Ranking, Biblioteca e som).
• Embaixo: chat fixo com as abas Chat, Jornal e Missões. A setinha recolhe.
• 🎒 Mochila nova: seus itens, bolas e visuais em quadradinhos, com a equipe e as moedas.
• A Grama de Treino ganhou o mesmo visual, com mapinha e chat.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
