-- =====================================================================
-- POKEGAMES — Aviso do menu novo no Jornal (pedido do dono em 03/11/2026).
-- A mudança é só no site (menu com atalhos, grupos, símbolos e ordem
-- alfabética); este arquivo só publica a novidade no Jornal, sozinha.
-- =====================================================================
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🧭 Menu novo, mais fácil de achar tudo', 'O menu do jogo foi reorganizado:
• No topo, atalhos rápidos para o que mais se usa: Desafio, Pokédex, Grama, Batalhas, Vila e Ranking.
• As opções ficaram em grupos (Pokémon, Vila e lojas, Competir, Comunidade e Ajuda), cada uma com o seu símbolo e em ordem alfabética.
• Clique no nome do grupo para abrir ou fechar. O jogo lembra como você deixou.
• O "Jogar hoje" ficou compacto no computador: clique em "Mais" para ver tudo.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
