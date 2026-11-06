-- =====================================================================
-- POKEGAMES — Sino de avisos e botão dos Pokémon (pedido do dono em 06/11/2026).
-- A mudança é toda no site (deploy/index.html): este arquivo só publica a
-- novidade no Jornal, como manda a regra (uma vez só, pelo título).
-- =====================================================================
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🔔 Sino de avisos e botão dos Pokémon', 'Ficou bem mais fácil saber o que está acontecendo:
• 🔔 Sino no mapa (no celular, no alto da tela): mostra tudo o que é novo, com atalho para abrir. Item novo no Mercado, leilão novo, lance coberto, mensagens no Chat, presentes, Jornal, SAC, batalhas, duelos, Quiz, Rocket, Caçada, Liga, ataques à vila e Pokémon prontos para evoluir.
• 🔊 Chegou algo novo com o jogo aberto? Aparece um aviso na tela com som.
• 🔴 Selos vermelhos no menu também no Mercado, no Leilão e no Chat.
• 🐾 Botão "Meus Pokémon" no canto do mapa: sua equipe com vida e XP, quem pode evoluir ou está ferido, e atalhos para equipe, Pokédex, Grama, Centro, Creche, batalhas, Leilão e Loja.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
