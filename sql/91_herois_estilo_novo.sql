-- 91_herois_estilo_novo.sql
-- Pedido do dono em 10/11/2026: os 8 heróis redesenhados num estilo novo (cabeça grande, traço grosso, cores
-- chapadas), arte original do Pokegames feita por código no site. As skins da loja continuam valendo no
-- desenho novo. Não muda regra nenhuma. Este arquivo só:
--   (1) acrescenta o liga/desliga "herois_novos" aos ajustes do visual (visual_cfg, versão do 89 + herois_novos);
--   (2) publica a novidade no Jornal.
-- A aba Ajustes do jogo já mostra o grupo "Visual novo" (admin_cfg_efetiva do 90 chama visual_cfg).

create or replace function public.visual_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "tela_cheia_padrao": true, "chat_fixo": true, "herois_novos": true}'::jsonb || coalesce(public.cfg()->'visual', '{}'::jsonb)
$$;
update public.game_config set config = jsonb_set(config, '{visual}', public.visual_cfg()) where active;
revoke execute on function public.visual_cfg() from public, anon, authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🧙 Os heróis ganharam visual novo!', 'Os 8 heróis foram redesenhados: cabeça grande, traço grosso e cores vivas, cada um com a sua marca.
• Guerreiro com espada e escudo, Mago de chapéu e cajado, Arqueiro com arco, Ladino de capuz, Clérigo com o cajado dourado, Domador de chapéu e chicote, Pesquisador de óculos e lupa, Mercador com a bolsa de moedas.
• Suas skins continuam valendo: roupas, capas, asas, os 12 chapéus, acessórios e auras aparecem no desenho novo.
• Vale no mapa, na Praça, na Grama, no chat, no ranking e na loja.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
