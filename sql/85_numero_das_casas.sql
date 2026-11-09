-- =====================================================================
-- POKEGAMES — Número das casas (pedido do dono em 09/11/2026).
-- A mudança é toda no site (deploy/index.html): cada casa do mapa mostra o
-- número dela, e o painel, os balões e o ranking mostram em que casa cada um
-- está. Este arquivo só publica a novidade no Jornal, como manda a regra.
-- =====================================================================
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🔢 Agora toda casa tem número', 'Ficou fácil saber onde cada um está:
• Cada casa do mapa mostra o número dela, embaixo do círculo.
• No seu painel aparece "Você está na casa nº ...".
• Ao tocar numa casa ou num jogador, aparece o número da casa.
• No ranking, ao lado da região, aparece a casa de cada um.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
