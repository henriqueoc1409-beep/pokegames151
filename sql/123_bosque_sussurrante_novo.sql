-- 123_bosque_sussurrante_novo.sql
-- Pedido do dono em 17/11/2026: cenário novo e artesanal no Bosque Sussurrante e no Ginásio da Líder Flora
-- (cachoeira, riacho com pontes e píer, recanto do Lenhador Davi, mata funda escura a oeste, pátio de pedra,
-- fachada e salão em estilo estufa botânica, vagalumes à noite e chamas vivas). Tudo visual no site: níveis,
-- encontros, insígnia e regras continuam iguais. Este arquivo só:
--   (1) acrescenta o liga/desliga "aventura_viva" aos ajustes do visual (visual_cfg, versão do 112 + aventura_viva);
--   (2) publica a novidade no Jornal.

create or replace function public.visual_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "tela_cheia_padrao": true, "chat_fixo": true, "herois_novos": true, "mapa_novo": true, "corrida": true, "vila_nova": true, "aventura_viva": true}'::jsonb || coalesce(public.cfg()->'visual', '{}'::jsonb)
$$;
update public.game_config set config = jsonb_set(config, '{visual}', public.visual_cfg()) where active;
revoke execute on function public.visual_cfg() from public, anon, authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🌲 Bosque Sussurrante e Ginásio da Líder Flora de cara nova', 'O Bosque Sussurrante e o Ginásio da Líder Flora ganharam cenário novo, feito nos detalhes (os níveis dos Pokémon, os encontros e os caminhos continuam os mesmos):
• Cachoeira no paredão norte, riacho cristalino cortando o bosque, duas pontes de madeira e um píer na lagoa de vitórias-régias.
• Recanto do Lenhador Davi com cabana, pilha de lenha, tocos e fogueira acesa na beira da estrada.
• Mata funda a oeste do riacho com chão sombreado, cogumelos e árvores antigas, marcando bem onde moram os Pokémon mais fortes.
• Pátio de pedra do santuário e fachada em estilo estufa botânica para o Ginásio da Líder Flora, com vitrais, heras e lanternas acesas.
• Salão interno do Ginásio reformado com canais de água, colunas floridas, vitrais iluminados e palco de madeira.
• Vagalumes brilhando à noite, pólen dourado de dia, chamas vivas nas tochas e brilho na água.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
