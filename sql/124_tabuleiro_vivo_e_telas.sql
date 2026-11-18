-- 124_tabuleiro_vivo_e_telas.sql
-- Pedido do dono em 17/11/2026: gráfico, cores, interação e caminhada do tabuleiro renovados,
-- mais telas e menus compactos e organizados. Não muda nenhuma regra, conta, moeda, XP nem posição das casas.
-- Este arquivo só:
--   (1) acrescenta os interruptores "tabuleiro_vivo" e "telas_compactas" em Ajustes do jogo → Visual (visual_cfg, versão do 123);
--   (2) publica a novidade sozinha no Jornal.

create or replace function public.visual_cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select '{"on": true, "tela_cheia_padrao": true, "chat_fixo": true, "herois_novos": true, "mapa_novo": true, "corrida": true, "vila_nova": true, "aventura_viva": true, "tabuleiro_vivo": true, "telas_compactas": true}'::jsonb || coalesce(public.cfg()->'visual', '{}'::jsonb)
$$;
update public.game_config set config = jsonb_set(config, '{visual}', public.visual_cfg()) where active;
revoke execute on function public.visual_cfg() from public, anon, authenticated;

-- ---------- novidade no Jornal, publicada sozinha ----------
insert into public.posts(kind, title, body, created_by)
select 'novidade', x.title, x.body, coalesce((select user_id from public.user_roles where role = 'admin' order by user_id limit 1), '00000000-0000-0000-0000-000000000000'::uuid)
  from (values ('🎲 Tabuleiro renovado, caminhada ao vivo e telas mais compactas', 'O tabuleiro e as janelas do jogo ganharam um acabamento novo (todas as regras, casas, moedas e XP continuam iguais):
• Cenário mais rico: trilhas em curvas suaves (estrada clara no caminho seguro e trilha avermelhada no arriscado), cores próprias por região, água e mar com movimento suave, nuvens passando e brilho no Castelo e nos Portais.
• Casas redesenhadas como peças de tabuleiro em relevo, com ícones nítidos e plaquinha limpa com o número da casa.
• Prévia no próprio chão: antes de andar no dia, o mapa acende as casas à sua frente (os passos já garantidos pelos acertos e a faixa extra da roleta) para ajudar a planejar a jogada.
• Interação direto no mapa: escolha o caminho nas placas das bifurcações, deslize o mapa com suavidade, dê dois toques para aproximar e veja os detalhes num cartão pertinho da casa ou do jogador clicado (já mostrando a quantas casas está de você).
• Novo jeito de andar: sem spoiler antes da caminhada! Seu herói salta de casa em casa com rastro dourado, moedas e efeitos aparecem na hora em que acontecem (com botão para pular a animação) e o resumo abre ao chegar.
• Menus e telas mais enxutos: menu em grade compacta com filtro rápido, janelas organizadas por categoria com avisos e o seu saldo de moedas sempre visível no topo.')) x(title, body)
 where not exists (select 1 from public.posts p where p.title = x.title);
